import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// 録画停止のグローバルホットキー (= ユーザー要望: 録画を止めるショート
/// カットキーを設定できるように。 アプリの外にいても効くように)。
///
/// Windows の RegisterHotKey は「登録したスレッドのメッセージループ」 に
/// WM_HOTKEY が届く仕組みなので、 専用の isolate を立てて GetMessage で
/// 待ち受ける。 本体の UI スレッドは一切ブロックしない。
/// 終わる時は PostThreadMessage(WM_QUIT) でループを抜けさせて片付ける
/// (isolate を kill だけすると登録が残ることがあるため)。
class RecStopHotkey {
  RecStopHotkey._();
  static final RecStopHotkey instance = RecStopHotkey._();

  Isolate? _iso;
  ReceivePort? _rp;
  int _threadId = 0;

  /// ホットキーが押された時に呼ばれる (本体の isolate 側で実行される)。
  void Function()? onPressed;

  bool get active => _iso != null;

  /// [modifiers] は MOD_ALT=1 / MOD_CONTROL=2 / MOD_SHIFT=4 / MOD_WIN=8 の
  /// 組み合わせ、 [vk] は仮想キーコード。
  Future<void> start(int modifiers, int vk) async {
    await stop();
    final rp = ReceivePort();
    _rp = rp;
    rp.listen((msg) {
      if (msg is List && msg.length == 2 && msg[0] == 'tid') {
        _threadId = (msg[1] as num).toInt();
      } else if (msg == 'hot') {
        onPressed?.call();
      }
      // 'fail' = 他のアプリが同じキーを使っている等。 静かに諦める
      // (画面のボタンからは変わらず止められる)。
    });
    _iso = await Isolate.spawn(_loop, [rp.sendPort, modifiers, vk]);
  }

  Future<void> stop() async {
    final tid = _threadId;
    _threadId = 0;
    if (tid != 0) {
      try {
        final user32 = DynamicLibrary.open('user32.dll');
        final postThreadMessage = user32.lookupFunction<
            Int32 Function(Uint32, Uint32, IntPtr, IntPtr),
            int Function(int, int, int, int)>('PostThreadMessageW');
        postThreadMessage(tid, 0x0012 /* WM_QUIT */, 0, 0);
      } catch (_) {}
    }
    final iso = _iso;
    _iso = null;
    if (iso != null) {
      // WM_QUIT が効かなかった時の保険 (少し待ってから強制終了)。
      Future<void>.delayed(const Duration(milliseconds: 500), () {
        try {
          iso.kill(priority: Isolate.immediate);
        } catch (_) {}
      });
    }
    _rp?.close();
    _rp = null;
  }

  /// ホットキー専用のメッセージループ (専用 isolate で走る)。
  static void _loop(List<Object?> args) {
    final send = args[0] as SendPort;
    final mods = (args[1] as num).toInt();
    final vk = (args[2] as num).toInt();
    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getCurrentThreadId = kernel32.lookupFunction<Uint32 Function(),
        int Function()>('GetCurrentThreadId');
    final registerHotKey = user32.lookupFunction<
        Int32 Function(IntPtr, Int32, Uint32, Uint32),
        int Function(int, int, int, int)>('RegisterHotKey');
    final unregisterHotKey = user32.lookupFunction<
        Int32 Function(IntPtr, Int32),
        int Function(int, int)>('UnregisterHotKey');
    final getMessage = user32.lookupFunction<
        Int32 Function(Pointer<Uint8>, IntPtr, Uint32, Uint32),
        int Function(Pointer<Uint8>, int, int, int)>('GetMessageW');
    send.send(['tid', getCurrentThreadId()]);
    const hotkeyId = 0xB0B;
    // MOD_NOREPEAT (0x4000): 押しっぱなしで連打にならないように。
    if (registerHotKey(0, hotkeyId, mods | 0x4000, vk) == 0) {
      send.send('fail');
      return;
    }
    // MSG 構造体は x64 で 48 バイト。 message は先頭から 8 バイト目。
    final msg = calloc<Uint8>(48);
    try {
      while (getMessage(msg, 0, 0, 0) > 0) {
        // MSG.message = 先頭から 8 バイト目 (= Uint32 で 3 個目)。
        final message = msg.cast<Uint32>()[2];
        if (message == 0x0312 /* WM_HOTKEY */) send.send('hot');
      }
    } finally {
      unregisterHotKey(0, hotkeyId);
      calloc.free(msg);
    }
  }
}
