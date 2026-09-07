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
///
/// ★ ここが上限の理由 ── Windows がマウスのボタンとして扱えるのは **5 つ**
///   (左/ 右/ ホイール押し込み/ 横 2 つ) までで、 これは OS の入り口である
///   mouhid の作りで決まっている。 6 個目から先のボタンは OS に届く前に
///   捨てられるので、 どんな道具を足しても増やせない。 説明書にもはっきり
///   書いてある ──「Windows supports mice with up to five buttons: left,
///   middle, and right, plus two additional buttons called XBUTTON1 and
///   XBUTTON2」(WM_XBUTTONDOWN)。 MSLLHOOKSTRUCT.mouseData の上位 16 ビットも
///   XBUTTON1(0x0001) と XBUTTON2(0x0002) の 2 つしか決まっていない。
///   Raw Input (RAWMOUSE.usButtonFlags) も RI_MOUSE_BUTTON_5 止まりで同じ。
///   ボタンの多いマウスは、 6 個目から先を付属ソフトで「キーボードのキー」に
///   していることが多い。 その時は普通のショートカットとして拾える。
class MouseButtonId {
  /// ホイールの押し込み。
  static const int middle = 1;

  /// 横の手前のボタン (ブラウザの「戻る」)。 = XBUTTON1
  static const int back = 2;

  /// 横の奥のボタン (ブラウザの「進む」)。 = XBUTTON2
  static const int forward = 3;

  /// ホイールを左に倒す (横チルト)。 WM_MOUSEHWHEEL の左向き。
  static const int tiltLeft = 4;

  /// ホイールを右に倒す (横チルト)。 WM_MOUSEHWHEEL の右向き。
  static const int tiltRight = 5;

  static const List<int> all = [middle, back, forward, tiltLeft, tiltRight];
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
  bool _detecting = false;
  void Function(int button)? _onDetect;

  /// 今フックが立っているか。
  bool get active => _iso != null;

  /// 立てようとして駄目だった (= セキュリティソフトなどに阻まれた)。
  bool get failed => _failed;

  /// 「押して検出」 の最中か。
  bool get detecting => _detecting;

  /// [bindings] の通りに割り当てて立ち上げ直す。 空なら止めるだけ。
  Future<void> apply(List<MouseKeyBinding> bindings) async {
    // 検出中に入れ替えるとフックが二重になる。 終わってから入れ直す。
    if (_detecting) return;
    await stop();
    if (!isSupported || bindings.isEmpty) return;
    await _spawn([for (final b in bindings) b.toWire()], detect: false);
  }

  /// 「押して検出」。 割り当てはせず、 押されたボタンの番号を [onButton] に
  /// 流すだけの見張りを立てる。 **元のボタンは握り潰さない**ので、 検出中も
  /// パソコンは普通に操作できる (取り消しも押せる)。 終わったら必ず
  /// [stopDetect] を呼ぶこと。
  Future<void> startDetect(void Function(int button) onButton) async {
    if (!isSupported) return;
    await stop();
    _onDetect = onButton;
    _detecting = true;
    await _spawn(const <List<int>>[], detect: true);
  }

  /// 検出をやめる。 元の割り当ては呼び出し側が入れ直す。
  Future<void> stopDetect() async {
    _onDetect = null;
    _detecting = false;
    await stop();
  }

  Future<void> _spawn(List<List<int>> wire, {required bool detect}) async {
    final rp = ReceivePort();
    _rp = rp;
    rp.listen((msg) {
      if (msg is List && msg.length == 2 && msg[0] == 'tid') {
        _threadId = (msg[1] as num).toInt();
      } else if (msg is List && msg.length == 2 && msg[0] == 'btn') {
        _onDetect?.call((msg[1] as num).toInt());
      } else if (msg == 'fail') {
        _failed = true;
      }
    });
    _failed = false;
    _iso = await Isolate.spawn(_loop, [rp.sendPort, wire, detect]);
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

  /// 検出中だけ入る戻り口。 入っている間は握り潰さず、 押された番号を送る。
  static SendPort? _detectPort;

  /// 横チルトの溜め。 刻みの細かいホイールで連打にならないように 120 ずつ。
  static int _hAccum = 0;

  static int Function(int, Pointer<Uint8>, int)? _sendInput;
  static int Function(int, int, int, int)? _callNext;
  static int _hookHandle = 0;

  /// 送った物が自分のだと分かるようにしておく目印。
  static const int _kTag = 0x484E4B59; // 'HNKY'

  static void _loop(List<Object?> args) {
    final send = args[0] as SendPort;
    final wire = (args[1] as List).cast<List>();
    final detect = args.length > 2 && args[2] == true;
    _detectPort = detect ? send : null;
    _hAccum = 0;
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
  ///   (既定 300 ミリ秒。 Windows 10 1709 以降は上限 1 秒) 内に返らない
  ///   フックを黙って外してしまう。
  static int _hookProc(int nCode, int wParam, int lParam) {
    final port = _detectPort;
    if (nCode < 0 || (port == null && _map.isEmpty)) {
      return _callNext?.call(0, nCode, wParam, lParam) ?? 0;
    }
    // WM_MBUTTONDOWN/UP = 0x0207/0x0208、 WM_XBUTTONDOWN/UP = 0x020B/0x020C、
    // WM_MOUSEHWHEEL = 0x020E
    int? button;
    var isDown = false;
    if (wParam == 0x0207 || wParam == 0x0208) {
      button = MouseButtonId.middle;
      isDown = wParam == 0x0207;
    } else if (wParam == 0x020B || wParam == 0x020C) {
      isDown = wParam == 0x020B;
      // MSLLHOOKSTRUCT.mouseData は先頭から 8 バイト目。 上位 16 ビットが
      // どちらの横ボタンか。 決まっている値は XBUTTON1(1) と XBUTTON2(2) の
      // 2 つだけで、 3 つ目は**来ない** (Windows はボタン 5 つまで)。
      final data = Pointer<Uint32>.fromAddress(lParam + 8).value;
      final which = (data >> 16) & 0xFFFF;
      if (which == 1) {
        button = MouseButtonId.back;
      } else if (which == 2) {
        button = MouseButtonId.forward;
      }
    } else if (wParam == 0x020E) {
      // 横チルト。 上位 16 ビットが符号付きの傾き量 (右が +)。 刻みの細かい
      // ホイールがあるので 120 溜まるまで待ってから 1 回とする。
      // ※ この message も、 ここで読む mouseData も、 LowLevelMouseProc の
      //   説明書には**載っていない** (説明書は 横チルトについて「mouseData は
      //   使わない」 と書いている)。 実際には届くので使うが、 届かない環境が
      //   あっても「チルトが効かない」 だけで他は何も壊れない。
      final data = Pointer<Uint32>.fromAddress(lParam + 8).value;
      var d = (data >> 16) & 0xFFFF;
      if (d >= 0x8000) d -= 0x10000;
      if (d == 0) return _callNext?.call(0, nCode, wParam, lParam) ?? 0;
      final dir = d > 0 ? MouseButtonId.tiltRight : MouseButtonId.tiltLeft;
      // その向きに何も割り当てていない (検出中でもない) なら素通し。
      if (port == null && !_map.containsKey(dir)) {
        return _callNext?.call(0, nCode, wParam, lParam) ?? 0;
      }
      if ((_hAccum < 0) != (d < 0)) _hAccum = 0; // 向きが変わったら溜め直し
      _hAccum += d;
      final reached = _hAccum.abs() >= 120;
      if (reached) _hAccum = 0;
      if (port != null) {
        // 検出中は握り潰さない (他のボタンと同じ扱い)。
        if (reached) port.send(['btn', dir]);
        return _callNext?.call(0, nCode, wParam, lParam) ?? 0;
      }
      // ★ 割り当てのある向きは、 **溜め中も含めて必ず**握り潰す。
      //   120 に届くまでを素通ししていると、 3 回に 2 回だけ横スクロールが
      //   効いて、 3 回目にキーが飛ぶという中途半端な状態になる。
      if (reached) {
        final b = _map[dir];
        if (b != null) _sendKey(b[0], b[1]);
      }
      return 1;
    }
    if (button == null) {
      return _callNext?.call(0, nCode, wParam, lParam) ?? 0;
    }
    if (port != null) {
      // 検出中。 番号を知らせるだけで**握り潰さない**。
      if (isDown) port.send(['btn', button]);
      return _callNext?.call(0, nCode, wParam, lParam) ?? 0;
    }
    final bind = _map[button];
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
