// マウスのボタンに、 キーボードのキーを割り当てる
// (= ユーザー要望「マウスのボタンに色んなキーをショートカットキーとして
//  割り当てられるようにして欲しい」)。
//
// Windows 専用。 他の OS では [isSupported] が false で、 何もしない。
//
// ── 仕組み ──────────────────────────────────────────────────────────
// Windows には「マウスのボタンを別のキーにする」 表向きの API が無いので、
// 低水準マウスフック (WH_MOUSE_LL) で押されたのを受け取り、 割り当てられて
// いたら SendInput でキーを送り、 **元のボタンは握り潰す** (そうしないと
// 例えば「戻る」 が二重に効く)。 フックは専用の isolate に置き、 そこで
// メッセージを回す。 本体の UI は一切止まらない。
//
// ★ 注意 (利用者へ伝えるべきこと)
//   ・これは **パソコン全体**に効く。 アプリの外でも割り当てが働く。
//   ・押されたボタンを横取りする作りなので、 セキュリティソフトによっては
//     見張りの対象になることがある。 そのため **既定では動かない**。
//     割り当てを 1 つでも入れて、 スイッチを入れた時だけ立ち上がる。
//   ・左/ 右ボタンは選べないようにしてある。 万一の時にパソコンを操作
//     できなくなるのを防ぐため。
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// 割り当てられるボタン。
class MouseButtonId {
  /// ホイールの押し込み。
  static const int middle = 1;

  /// 横の手前のボタン (ブラウザの「戻る」)。
  static const int back = 2;

  /// 横の奥のボタン (ブラウザの「進む」)。
  static const int forward = 3;

  static const List<int> all = [middle, back, forward];
}

/// ボタン 1 つぶんの割り当て。
class MouseKeyBinding {
  /// [MouseButtonId] のどれか。
  final int button;

  /// 一緒に押す修飾キー。 Alt=1 / Ctrl=2 / Shift=4 / Win=8 の足し合わせ。
  final int modifiers;

  /// 送るキーの仮想キーコード。
  final int vk;

  const MouseKeyBinding({
    required this.button,
    required this.modifiers,
    required this.vk,
  });

  Map<String, dynamic> toJson() =>
      {'b': button, 'm': modifiers, 'k': vk};

  static MouseKeyBinding? fromJson(dynamic j) {
    if (j is! Map) return null;
    final b = (j['b'] as num?)?.toInt();
    final k = (j['k'] as num?)?.toInt();
    if (b == null || k == null) return null;
    if (!MouseButtonId.all.contains(b)) return null;
    return MouseKeyBinding(
      button: b,
      modifiers: (j['m'] as num?)?.toInt() ?? 0,
      vk: k,
    );
  }

  List<int> toWire() => [button, modifiers, vk];
}

/// フックの入り切り。
class MouseRemap {
  MouseRemap._();
  static final MouseRemap instance = MouseRemap._();

  static bool get isSupported => Platform.isWindows;

  Isolate? _iso;
  ReceivePort? _rp;
  int _threadId = 0;
  bool _failed = false;

  /// 今フックが立っているか。
  bool get active => _iso != null;

  /// 立てようとして駄目だった (= セキュリティソフトなどに阻まれた)。
  bool get failed => _failed;

  /// [bindings] の通りに割り当てて立ち上げ直す。 空なら止めるだけ。
  Future<void> apply(List<MouseKeyBinding> bindings) async {
    await stop();
    if (!isSupported || bindings.isEmpty) return;
    final rp = ReceivePort();
    _rp = rp;
    rp.listen((msg) {
      if (msg is List && msg.length == 2 && msg[0] == 'tid') {
        _threadId = (msg[1] as num).toInt();
      } else if (msg == 'fail') {
        _failed = true;
      }
    });
    _failed = false;
    _iso = await Isolate.spawn(
      _loop,
      [rp.sendPort, [for (final b in bindings) b.toWire()]],
    );
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
      // 抜けてくれなかった時の保険。
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        try {
          iso.kill(priority: Isolate.immediate);
        } catch (_) {}
      });
    }
    _rp?.close();
    _rp = null;
  }

  // ── ここから下はフック用の isolate の中の話 ──────────────────────

  /// 割り当て表 (ボタン -> [修飾, キー])。 isolate ごとに別物。
  static final Map<int, List<int>> _map = {};

  static int Function(int, Pointer<Uint8>, int)? _sendInput;
  static int Function(int, int, int, int)? _callNext;
  static int _hookHandle = 0;

  /// 送った物が自分のだと分かるようにしておく目印。
  static const int _kTag = 0x484E4B59; // 'HNKY'

  static void _loop(List<Object?> args) {
    final send = args[0] as SendPort;
    final wire = (args[1] as List).cast<List>();
    _map.clear();
    for (final w in wire) {
      _map[(w[0] as num).toInt()] = [
        (w[1] as num).toInt(),
        (w[2] as num).toInt(),
      ];
    }

    final user32 = DynamicLibrary.open('user32.dll');
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    _sendInput = user32.lookupFunction<
        Uint32 Function(Uint32, Pointer<Uint8>, Int32),
        int Function(int, Pointer<Uint8>, int)>('SendInput');
    _callNext = user32.lookupFunction<
        IntPtr Function(IntPtr, Int32, UintPtr, IntPtr),
        int Function(int, int, int, int)>('CallNextHookEx');
    final setHook = user32.lookupFunction<
        IntPtr Function(Int32, Pointer<NativeFunction<_HookProcNative>>,
            IntPtr, Uint32),
        int Function(int, Pointer<NativeFunction<_HookProcNative>>, int,
            int)>('SetWindowsHookExW');
    final unhook = user32.lookupFunction<Int32 Function(IntPtr),
        int Function(int)>('UnhookWindowsHookEx');
    final getModuleHandle = kernel32.lookupFunction<
        IntPtr Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)>('GetModuleHandleW');
    final getCurrentThreadId = kernel32
        .lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');
    final getMessage = user32.lookupFunction<
        Int32 Function(Pointer<Uint8>, IntPtr, Uint32, Uint32),
        int Function(Pointer<Uint8>, int, int, int)>('GetMessageW');

    send.send(['tid', getCurrentThreadId()]);

    final proc = Pointer.fromFunction<_HookProcNative>(_hookProc, 0);
    // WH_MOUSE_LL = 14。 低水準フックは「入れたスレッド」 で呼ばれるので、
    // この isolate がメッセージを回している限り生きている。
    _hookHandle = setHook(14, proc, getModuleHandle(nullptr), 0);
    if (_hookHandle == 0) {
      send.send('fail');
      return;
    }
    final msg = calloc<Uint8>(48);
    try {
      while (getMessage(msg, 0, 0, 0) > 0) {
        // 何もしない。 フックは OS がこのスレッドで直に呼んでくる。
      }
    } finally {
      unhook(_hookHandle);
      _hookHandle = 0;
      calloc.free(msg);
    }
  }

  /// 低水準マウスフックの受け口。
  ///
  /// ★ ここは**とても短く**しないといけない。 Windows は決められた時間
  ///   (既定 300 ミリ秒) 内に返らないフックを黙って外してしまう。
  static int _hookProc(int nCode, int wParam, int lParam) {
    if (nCode < 0 || _map.isEmpty) {
      return _callNext?.call(0, nCode, wParam, lParam) ?? 0;
    }
    // WM_MBUTTONDOWN/UP = 0x0207/0x0208、 WM_XBUTTONDOWN/UP = 0x020B/0x020C
    int? button;
    var isDown = false;
    if (wParam == 0x0207 || wParam == 0x0208) {
      button = MouseButtonId.middle;
      isDown = wParam == 0x0207;
    } else if (wParam == 0x020B || wParam == 0x020C) {
      isDown = wParam == 0x020B;
      // MSLLHOOKSTRUCT.mouseData は先頭から 8 バイト目。 上位 16 ビットが
      // どちらの横ボタンか (1 = 手前 / 2 = 奥)。
      final data = Pointer<Uint32>.fromAddress(lParam + 8).value;
      final which = (data >> 16) & 0xFFFF;
      button = which == 2 ? MouseButtonId.forward : MouseButtonId.back;
    }
    final bind = button == null ? null : _map[button];
    if (bind == null) {
      return _callNext?.call(0, nCode, wParam, lParam) ?? 0;
    }
    // 押した時だけキーを送る。 離した方は握り潰すだけ
    // (元のボタンが後から効いてしまわないように)。
    if (isDown) _sendKey(bind[0], bind[1]);
    return 1;
  }

  /// 修飾キーを押しながら [vk] を叩く。
  static void _sendKey(int modifiers, int vk) {
    final send = _sendInput;
    if (send == null || vk <= 0) return;
    // 押す順: 修飾 -> 本体 -> 本体を離す -> 修飾を離す。
    final mods = <int>[
      if (modifiers & 2 != 0) 0x11, // Ctrl
      if (modifiers & 4 != 0) 0x10, // Shift
      if (modifiers & 1 != 0) 0x12, // Alt
      if (modifiers & 8 != 0) 0x5B, // Win
    ];
    final seq = <(int, bool)>[
      for (final m in mods) (m, false),
      (vk, false),
      (vk, true),
      for (final m in mods.reversed) (m, true),
    ];
    const inputSize = 40;
    final buf = calloc<Uint8>(inputSize * seq.length);
    try {
      for (var i = 0; i < seq.length; i++) {
        final base = buf.address + inputSize * i;
        // INPUT.type = INPUT_KEYBOARD(1)
        Pointer<Uint32>.fromAddress(base).value = 1;
        // KEYBDINPUT は 8 バイト目から。 wVk(2) wScan(2) dwFlags(4)
        //   time(4) 詰め物(4) dwExtraInfo(8)
        Pointer<Uint16>.fromAddress(base + 8).value = seq[i].$1 & 0xFFFF;
        Pointer<Uint16>.fromAddress(base + 10).value = 0;
        var flags = seq[i].$2 ? 0x0002 : 0; // KEYEVENTF_KEYUP
        if (_isExtendedKey(seq[i].$1)) flags |= 0x0001;
        Pointer<Uint32>.fromAddress(base + 12).value = flags;
        Pointer<Uint32>.fromAddress(base + 16).value = 0;
        Pointer<Uint64>.fromAddress(base + 24).value = _kTag;
      }
      send(seq.length, buf, inputSize);
    } catch (_) {
    } finally {
      calloc.free(buf);
    }
  }

  /// 「拡張キー」 (テンキーではない矢印や Home など) は目印が要る。
  static bool _isExtendedKey(int vk) {
    switch (vk) {
      case 0x21: // PageUp
      case 0x22: // PageDown
      case 0x23: // End
      case 0x24: // Home
      case 0x25: // ←
      case 0x26: // ↑
      case 0x27: // →
      case 0x28: // ↓
      case 0x2D: // Insert
      case 0x2E: // Delete
      case 0x5B: // 左 Win
      case 0x5C: // 右 Win
      case 0x90: // NumLock
      case 0x2C: // PrintScreen
        return true;
      default:
        return false;
    }
  }
}

typedef _HookProcNative = IntPtr Function(Int32, UintPtr, IntPtr);
