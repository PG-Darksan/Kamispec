import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// ホーム画面 (Android) / デスクトップ (Windows) に「特定のマップ(ページ)を
/// 直接開くショートカット」 を作る仕組み。 ユーザー要望「ホーム画面にショート
/// カットみたいな感じで別のマップを持つアプリみたいな感じにできない？」 への対応。
///
/// - **Android**: `ShortcutManagerCompat.requestPinShortcut` (= ネイティブ
///   `MainActivity.kt` の MethodChannel 'app/shortcuts') でホーム画面に
///   ピン留めショートカットを作る。 タップすると intent extra `mindmap_page_id`
///   付きでアプリが起動し、 そのページを開く。
/// - **Windows**: デスクトップに `.lnk` を作成し、 起動引数 `--page=<id>` を渡す。
///   Windows ランナーは引数を dart の `main(List<String> args)` に渡すので、
///   起動時に解析して該当ページを開く。
class HomeShortcutService {
  static const MethodChannel _ch = MethodChannel('app/shortcuts');

  /// Windows 起動引数 `--page=<id>` から取り出したページ ID (main で設定)。
  static String? windowsLaunchPageId;

  /// このプラットフォームでショートカット作成に対応しているか。
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  /// 起動引数からマップ(ページ) ID を取り出す (Windows: `--page=<id>`)。
  static String? pageIdFromArgs(List<String> args) {
    for (final a in args) {
      if (a.startsWith('--page=')) {
        final v = a.substring('--page='.length).trim();
        if (v.isNotEmpty) return v;
      }
    }
    return null;
  }

  /// 起動時、 ショートカットから開くべきページ ID を返す (無ければ null)。
  /// - Windows: 起動引数から取得した値。
  /// - Android: ネイティブ側が保持している起動 intent の extra。
  static Future<String?> initialPageId() async {
    if (kIsWeb) return null;
    try {
      if (Platform.isWindows) return windowsLaunchPageId;
      if (Platform.isAndroid) {
        return await _ch.invokeMethod<String>('getInitialPageId');
      }
    } catch (_) {}
    return null;
  }

  /// 既にアプリ起動中にショートカットから開かれた時のコールバック (Android)。
  static void setOpenPageHandler(void Function(String pageId) handler) {
    if (kIsWeb || !Platform.isAndroid) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'openPage') {
        final id = call.arguments as String?;
        if (id != null && id.isNotEmpty) handler(id);
      }
      return null;
    });
  }

  /// ホーム画面 (Android) / デスクトップ (Windows) にマップのショートカットを作成。
  /// 成功で true。
  static Future<bool> pinMapShortcut({
    required String pageId,
    required String label,
  }) async {
    if (kIsWeb) return false;
    try {
      if (Platform.isAndroid) {
        final ok = await _ch.invokeMethod<bool>('pinMapShortcut', {
          'pageId': pageId,
          'label': label,
        });
        return ok ?? false;
      }
      if (Platform.isWindows) {
        return _createWindowsShortcut(pageId, label);
      }
    } catch (_) {}
    return false;
  }

  /// デスクトップに `.lnk` を作成 (PowerShell の WScript.Shell 経由)。
  static Future<bool> _createWindowsShortcut(
      String pageId, String label) async {
    try {
      final exe = Platform.resolvedExecutable;
      final wd = File(exe).parent.path;
      // ファイル名に使えない文字を除去
      var name = label.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      if (name.isEmpty) name = 'Map';
      // 生文字列テンプレートに置換 (PowerShell の $ を Dart 補間と誤認しない)。
      const tmpl = r'''
$ws = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = $ws.CreateShortcut((Join-Path $desktop '@@NAME@@.lnk'))
$lnk.TargetPath = '@@EXE@@'
$lnk.Arguments = '--page=@@PID@@'
$lnk.WorkingDirectory = '@@WD@@'
$lnk.IconLocation = '@@EXE@@,0'
$lnk.Save()
''';
      // 単一引用符は PowerShell で '' にエスケープ
      String esc(String s) => s.replaceAll("'", "''");
      final ps = tmpl
          .replaceAll('@@NAME@@', esc(name))
          .replaceAll('@@EXE@@', esc(exe))
          .replaceAll('@@PID@@', esc(pageId))
          .replaceAll('@@WD@@', esc(wd));
      final res = await Process.run(
          'powershell', ['-NoProfile', '-NonInteractive', '-Command', ps]);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
