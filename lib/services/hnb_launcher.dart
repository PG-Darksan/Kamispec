// 端末から `hnb <ファイル / フォルダー>` でこのアプリに開かせる薄皮
// (= ユーザー要望: vscode の `code` と同じ使い方をしたい)。
//
// 仕組みはごく薄い .cmd を 1 枚置くだけ。 中では本体の exe を `start` で
// 呼ぶので、 端末は待たされない。 渡された道筋は cmd の `%~f1` で絶対に
// 直してから渡す (= 端末の今いる場所を失わないため)。 2 個目の起動は
// 既に動いている本体へ引き渡して自分は終わるので、 窓は増えない。
//
// ★ 隠した powershell は安全対策に撃たれるので使わない
//   (= 実測: 画面のあるアプリからの隠し powershell が止められる)。

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter/foundation.dart';
import 'package:win32_registry/win32_registry.dart';

/// `hnb` を置く場所。 使えない環境では null。
///
/// アプリの中の端末にも、 この場所を PATH として渡す
/// (環境変数は起動時に配られるので、 足した直後の端末には届かないため)。
String? hnbLauncherDir() {
  if (kIsWeb || !Platform.isWindows) return null;
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null || local.isEmpty) return null;
  return '$local\\HisatorNotebook\\bin';
}

/// `hnb.cmd` を置いて、 ユーザーの PATH に置き場所を足す。
/// 何度呼んでも同じ結果になる (変わっていなければ書かない)。
Future<void> installTerminalLauncher() async {
  if (kIsWeb || !Platform.isWindows) return;
  try {
    final exe = Platform.resolvedExecutable;
    final dirPath = hnbLauncherDir();
    if (dirPath == null) return;
    final binDir = Directory(dirPath);
    if (!binDir.existsSync()) binDir.createSync(recursive: true);
    final cmdFile = File('${binDir.path}\\hnb.cmd');
    // `%~f1` = その引数の絶対の道筋。 `.` を渡されても今いる場所に直る。
    // 中の文は英数字だけにする (端末の文字コードは 932 なので、 UTF-8 で
    // 書いた日本語はそのままでは化ける)。
    final body = '@echo off\r\n'
        'setlocal enabledelayedexpansion\r\n'
        'set "HNB_EXE=$exe"\r\n'
        'if not exist "%HNB_EXE%" (\r\n'
        '  echo HisatorNotebook not found: "%HNB_EXE%"\r\n'
        '  exit /b 1\r\n'
        ')\r\n'
        'set "HNB_ARGS="\r\n'
        ':hnb_loop\r\n'
        'if "%~1"=="" goto hnb_run\r\n'
        'set "HNB_ARGS=!HNB_ARGS! "%~f1""\r\n'
        'shift\r\n'
        'goto hnb_loop\r\n'
        ':hnb_run\r\n'
        'start "" "%HNB_EXE%"!HNB_ARGS!\r\n'
        'endlocal\r\n';
    // 中身が同じなら書き直さない (起動の度にディスクへ書かない)。
    String? old;
    try {
      if (cmdFile.existsSync()) old = cmdFile.readAsStringSync();
    } catch (_) {}
    if (old != body) cmdFile.writeAsStringSync(body);

    // ── PATH に置き場所を足す (ユーザーの環境変数だけ) ──
    //    既に入っているなら何もしない。
    final envKey = Registry.currentUser.createKey('Environment');
    String cur = '';
    try {
      // 展開前 (%USERPROFILE% のまま) で読む。 書き戻す時に実体へ
      // 化けさせないため。
      cur = envKey.getStringValue('Path') ?? '';
    } catch (_) {}
    final has = cur
        .split(';')
        .map((e) => e.trim().replaceAll(RegExp(r'\\+$'), '').toLowerCase())
        .contains(binDir.path.toLowerCase());
    if (!has) {
      final next = cur.isEmpty
          ? binDir.path
          : (cur.endsWith(';') ? '$cur${binDir.path}' : '$cur;${binDir.path}');
      // 元の値が展開型 (%USERPROFILE% 等を含む) なら、 型を保つ。
      envKey.createValue(cur.contains('%')
          ? RegistryValue.unexpandedString('Path', next)
          : RegistryValue.string('Path', next));
      // 開いている端末には届かない。 次に開いた端末から効く。
      _broadcastEnvironmentChange();
    }
    envKey.close();
  } catch (e) {
    debugPrint('端末から開く薄皮 (hnb) の用意に失敗 (続行): $e');
  }
}

/// 環境変数を変えた事を他のアプリへ知らせる (エクスプローラー等が拾って、
/// 次に開く端末に新しい PATH が入る)。
///
/// win32 パッケージの名前は版で動くので、 user32.dll を直に引く。
void _broadcastEnvironmentChange() {
  if (kIsWeb || !Platform.isWindows) return;
  try {
    final user32 = ffi.DynamicLibrary.open('user32.dll');
    final sendMessageTimeout = user32.lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr, ffi.Uint32, ffi.IntPtr,
            ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32,
            ffi.Pointer<ffi.IntPtr>),
        int Function(int, int, int, ffi.Pointer<ffi.Void>, int, int,
            ffi.Pointer<ffi.IntPtr>)>('SendMessageTimeoutW');
    const hwndBroadcast = 0xFFFF;
    const wmSettingChange = 0x001A;
    const smtoAbortIfHung = 0x0002;
    final name = 'Environment'.toNativeUtf16(allocator: pkgffi.malloc);
    final out = pkgffi.calloc<ffi.IntPtr>();
    try {
      sendMessageTimeout(hwndBroadcast, wmSettingChange, 0,
          name.cast<ffi.Void>(), smtoAbortIfHung, 1000, out);
    } finally {
      pkgffi.malloc.free(name);
      pkgffi.calloc.free(out);
    }
  } catch (_) {}
}
