import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
// ★ ショートカット (.lnk) は Windows 本来の作り方 (IShellLink) で書く。
//   PowerShell を起動して作ると、 セキュリティソフトの振る舞い検知に
//   「悪意ある動作」 として止められる (= ユーザー報告)。
import 'package:win32/win32.dart';

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

  /// Windows 起動引数 `--command=<id>` から取り出したボタン ID (main で設定)。
  /// (= ユーザー要望: カスタムボタンを一発で呼び出すショートカット)
  static String? windowsLaunchCommandId;

  /// このプラットフォームでショートカット作成に対応しているか。
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  /// 起動引数からマップ(ページ) ID を取り出す (Windows: `--page=<id>`)。
  static String? pageIdFromArgs(List<String> args) => _argValue(args, '--page=');

  /// 起動引数からボタン (コマンド) ID を取り出す (Windows: `--command=<id>`)。
  static String? commandIdFromArgs(List<String> args) =>
      _argValue(args, '--command=');

  static String? _argValue(List<String> args, String prefix) {
    for (final a in args) {
      if (a.startsWith(prefix)) {
        final v = a.substring(prefix.length).trim();
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

  /// 起動時、 ショートカットから実行すべきボタン ID を返す (無ければ null)。
  static Future<String?> initialCommandId() async {
    if (kIsWeb) return null;
    try {
      if (Platform.isWindows) return windowsLaunchCommandId;
      if (Platform.isAndroid) {
        return await _ch.invokeMethod<String>('getInitialCommandId');
      }
    } catch (_) {}
    return null;
  }

  static void Function(String pageId)? _onOpenPage;
  static void Function(String commandId)? _onOpenCommand;
  static bool _handlerInstalled = false;

  /// ネイティブからの呼び出しを 1 箇所で受ける (チャンネルのハンドラは
  /// 1 つしか持てないため、 ページ用とボタン用をここで振り分ける)。
  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _ch.setMethodCallHandler((call) async {
      final id = call.arguments as String?;
      if (id == null || id.isEmpty) return null;
      if (call.method == 'openPage') _onOpenPage?.call(id);
      if (call.method == 'openCommand') _onOpenCommand?.call(id);
      return null;
    });
  }

  /// 既にアプリ起動中にショートカットから開かれた時のコールバック (Android)。
  static void setOpenPageHandler(void Function(String pageId) handler) {
    if (kIsWeb || !Platform.isAndroid) return;
    _onOpenPage = handler;
    _ensureHandler();
  }

  /// 既に起動中にボタンのショートカットが押された時のコールバック (Android)。
  static void setOpenCommandHandler(void Function(String commandId) handler) {
    if (kIsWeb || !Platform.isAndroid) return;
    _onOpenCommand = handler;
    _ensureHandler();
  }

  /// ホーム画面 (Android) / デスクトップ (Windows) にマップのショートカットを作成。
  /// 成功で true。
  /// [iconPath] は Windows 用の .ico のパス、 [iconPng] は Android 用の PNG。
  /// どちらも省略するとアプリ本体のアイコンになる (= 従来の動き)。
  /// ★ = ユーザー要望「ショートカットを作成する時にアイコンをユーザーが
  ///   決められるように」。
  static Future<bool> pinMapShortcut({
    required String pageId,
    required String label,
    String? destDir,
    String? iconPath,
    Uint8List? iconPng,
  }) async {
    if (kIsWeb) return false;
    try {
      if (Platform.isAndroid) {
        final ok = await _ch.invokeMethod<bool>('pinMapShortcut', {
          'pageId': pageId,
          'label': label,
          'iconPng': iconPng,
        });
        return ok ?? false;
      }
      if (Platform.isWindows) {
        return _createWindowsShortcut('--page=$pageId', label,
            destDir: destDir, iconPath: iconPath);
      }
    } catch (_) {}
    return false;
  }

  /// ホーム画面 (Android) / デスクトップ (Windows) に「ボタンを一発で呼び出す」
  /// ショートカットを作成する (= ユーザー要望)。
  ///
  /// 押すとアプリが起動し (既に起動中ならその窓が前に出て)、 指定した
  /// カスタムボタンの動作がそのまま実行される。
  /// [iconPath] は Windows 用の .ico のパス、 [iconPng] は Android 用の
  /// PNG バイト列 (= ユーザー要望: ショートカットのアイコンを設定できる
  /// ように。 ボタンのアイコンがそのままショートカットのアイコンになる)。
  /// [destDir] を渡すと、 デスクトップではなくそのフォルダーに作る
  /// (= ユーザー要望: ショートカットを作成する場所を指定できるように)。
  /// Windows 専用。 Android のピン留めはホーム画面固定なので無視される。
  static Future<bool> pinCommandShortcut({
    required String commandId,
    required String label,
    String? iconPath,
    Uint8List? iconPng,
    String? destDir,
  }) async {
    if (kIsWeb) return false;
    try {
      if (Platform.isAndroid) {
        final ok = await _ch.invokeMethod<bool>('pinCommandShortcut', {
          'commandId': commandId,
          'label': label,
          if (iconPng != null) 'iconPng': iconPng,
        });
        return ok ?? false;
      }
      if (Platform.isWindows) {
        return _createWindowsShortcut('--command=$commandId', label,
            iconPath: iconPath, destDir: destDir);
      }
    } catch (_) {}
    return false;
  }

  /// `.lnk` を作成する。
  ///
  /// ★ PowerShell + WScript.Shell はやめた (= ユーザー報告: ショートカットを
  ///   作ろうとするとセキュリティソフトに「悪意ある動作」 としてブロック
  ///   される)。 「スクリプトを起動してデスクトップに .lnk を書く」 は
  ///   マルウェアの常套手段そのもので、 振る舞い検知に必ず引っかかる。
  ///   代わりに Windows 本来の作り方 (IShellLink + IPersistFile) を
  ///   このプロセスの中から直接呼ぶ。 外部プロセスを一切起動しないので、
  ///   ふつうのアプリがショートカットを作るのと同じ動きになる。
  ///
  /// [arguments] は起動引数 (`--page=<id>` / `--command=<id>`)。
  /// [iconPath] を渡すとその .ico をショートカットのアイコンにする。
  /// [destDir] は作成先フォルダー。 省略 / 存在しない時はデスクトップ。
  static Future<bool> _createWindowsShortcut(String arguments, String label,
      {String? iconPath, String? destDir}) async {
    try {
      final exe = Platform.resolvedExecutable;
      final wd = File(exe).parent.path;
      // ファイル名に使えない文字を除去
      var name = label.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      if (name.isEmpty) name = 'Map';
      // 作成先。 指定が無い / 消えているフォルダーならデスクトップへ。
      var dir = (destDir ?? '').trim();
      if (dir.isNotEmpty && !Directory(dir).existsSync()) dir = '';
      if (dir.isEmpty) dir = _desktopDir() ?? '';
      if (dir.isEmpty) return false;
      final lnkPath = '$dir${Platform.pathSeparator}$name.lnk';
      final icon = (iconPath != null && iconPath.isNotEmpty) ? iconPath : exe;
      // ★ 既に同じ名前のショートカットがあると、 上書き保存でシェルの処理を
      //   待って画面が固まることがある (= ユーザー報告: 既にショートカットが
      //   存在する状態で作ろうとするとフリーズ)。 先に消してから書く。
      try {
        final old = File(lnkPath);
        if (await old.exists()) await old.delete();
      } catch (_) {}
      // ★ COM の呼び出しは画面のスレッドで行わない (= 固まる原因)。
      //   別のアイソレートで動かし、 念のため時間制限も付ける。
      return await Isolate.run(() => _writeShellLink(
                lnkPath: lnkPath,
                target: exe,
                arguments: arguments,
                workingDir: wd,
                iconPath: icon,
              ))
          .timeout(const Duration(seconds: 12), onTimeout: () => false);
    } catch (e) {
      debugPrint('ショートカットの作成に失敗: $e');
      return false;
    }
  }

  /// デスクトップの場所。 OneDrive へ移されている環境も見る。
  static String? _desktopDir() {
    // ① Windows に正式に尋ねる (リダイレクトされていても正しい場所が返る)。
    final guid = calloc<GUID>()..ref.setGUID(FOLDERID_Desktop);
    final out = calloc<Pointer<Utf16>>();
    try {
      final hr = SHGetKnownFolderPath(guid, 0, NULL, out);
      if (hr == S_OK) {
        final path = out.value.toDartString();
        if (path.isNotEmpty && Directory(path).existsSync()) return path;
      }
    } catch (_) {
    } finally {
      try {
        if (out.value != nullptr) CoTaskMemFree(out.value);
      } catch (_) {}
      calloc
        ..free(guid)
        ..free(out);
    }
    // ② 念のための手作業 (①が使えない環境向け)。
    final home = Platform.environment['USERPROFILE'] ?? '';
    if (home.isEmpty) return null;
    for (final c in ['Desktop', r'OneDrive\Desktop']) {
      final d = '$home${Platform.pathSeparator}$c';
      if (Directory(d).existsSync()) return d;
    }
    return null;
  }

  /// IShellLink (COM) で .lnk を書く。 外部プロセスは起動しない。
  static bool _writeShellLink({
    required String lnkPath,
    required String target,
    required String arguments,
    required String workingDir,
    required String iconPath,
  }) {
    // このスレッドで COM を使えるようにする。 既に初期化済み
    // (S_FALSE / RPC_E_CHANGED_MODE) でも続行してよい。
    final init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    final needUninit = init == S_OK || init == S_FALSE;
    ShellLink? link;
    IPersistFile? file;
    final pTarget = target.toNativeUtf16();
    final pArgs = arguments.toNativeUtf16();
    final pDir = workingDir.toNativeUtf16();
    final pIcon = iconPath.toNativeUtf16();
    final pLnk = lnkPath.toNativeUtf16();
    try {
      link = ShellLink.createInstance();
      if (link.setPath(pTarget) != S_OK) return false;
      link.setArguments(pArgs);
      link.setWorkingDirectory(pDir);
      link.setIconLocation(pIcon, 0);
      file = IPersistFile.from(link);
      final hr = file.save(pLnk, TRUE);
      return hr == S_OK;
    } catch (e) {
      debugPrint('IShellLink での .lnk 作成に失敗: $e');
      return false;
    } finally {
      try {
        file?.release();
      } catch (_) {}
      try {
        link?.release();
      } catch (_) {}
      calloc
        ..free(pTarget)
        ..free(pArgs)
        ..free(pDir)
        ..free(pIcon)
        ..free(pLnk);
      if (needUninit) {
        try {
          CoUninitialize();
        } catch (_) {}
      }
    }
  }
}
