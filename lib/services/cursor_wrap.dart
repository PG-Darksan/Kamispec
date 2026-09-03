import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart' as w32;

/// 画面の両端をつないで、 マウスを回り込ませる (Windows 専用)。
///
/// = ユーザー要望「サブモニターが接続されている時、 メインの右とサブの左しか
///   繋がっていなくて使いにくい。 両端から行き来できるようにして欲しい」。
///
/// Windows は並べたモニターの間に継ぎ目を 1 か所しか作らないので、 いちばん外
/// 側の端どうしは繋がっていない。 ここでは一番外の端に着いたマウスを反対側の
/// 外の端へ移し、 輪のように繋げる。
///
/// **仕組み**: 20ms ごとに今のマウスの場所を見て、 仮想画面 (全モニターを囲む
/// 四角) の外周に着いていたら反対の端へ移す。 低水準フックは使わない。
///
/// **やらない時**:
///   * モニターが 1 枚だけ (繋ぐ相手がいない)
///   * ボタンを押している最中 (窓や物を運んでいる途中で飛ばすと壊れる)
///   * 移した直後の 300ms (行ったり来たりを防ぐ)
class CursorWrap {
  CursorWrap._();

  static final CursorWrap instance = CursorWrap._();

  /// 本体の窓だけで動かすための札。 サブ窓や外窓 (別のエンジン) でも
  /// MindMapProvider は作られるので、 何も守らないと同じ処理が二重に走り、
  /// 二重に飛ばして元の場所へ戻ってしまう。 main() の本体の道でだけ立てる。
  static bool allowed = false;

  Timer? _timer;
  bool _enabled = false;

  /// 移した直後に、 また移してしまわないための待ち時間。
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);


  bool get isRunning => _timer != null;

  static bool get isSupported {
    try {
      return !kIsWeb && Platform.isWindows;
    } catch (_) {
      return false;
    }
  }

  /// 設定の入り切りをそのまま渡す。 使えない環境なら何もしない。
  void apply(bool enabled) {
    _enabled = enabled;
    if (!isSupported || !allowed || !enabled) {
      stop();
      return;
    }
    start();
  }

  void start() {
    if (!isSupported || !allowed || !_enabled || _timer != null) return;
    _timer = Timer.periodic(const Duration(milliseconds: 15), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  int _metric(int index) {
    try {
      return w32.GetSystemMetrics(index);
    } catch (_) {
      return 0;
    }
  }

  /// モニターが 2 枚以上あるか。
  bool get hasMultipleMonitors => _metric(w32.SM_CMONITORS) > 1;

  void _tick() {
    if (!_enabled) return;
    if (DateTime.now().isBefore(_quietUntil)) return;
    try {
      if (!hasMultipleMonitors) return;
      // 何かを掴んで運んでいる最中は触らない。
      if (_anyMouseButtonDown()) return;

      final vx = _metric(w32.SM_XVIRTUALSCREEN);
      final vy = _metric(w32.SM_YVIRTUALSCREEN);
      final vw = _metric(w32.SM_CXVIRTUALSCREEN);
      final vh = _metric(w32.SM_CYVIRTUALSCREEN);
      if (vw <= 0 || vh <= 0) return;
      final vRight = vx + vw - 1;
      final vBottom = vy + vh - 1;

      final pos = _cursorPos();
      if (pos == null) return;
      final x = pos.$1, y = pos.$2;

      int? nx, ny;
      var kind = '';
      if (x <= vx) {
        nx = vRight - 2;
        ny = y;
        kind = 'L';
      } else if (x >= vRight) {
        nx = vx + 2;
        ny = y;
        kind = 'R';
      } else if (y <= vy) {
        nx = x;
        ny = vBottom - 2;
        kind = 'T';
      } else if (y >= vBottom) {
        nx = x;
        ny = vy + 2;
        kind = 'B';
      }
      if (nx == null || ny == null) return;

      // ★ 向きは「仮想画面と主モニターの大きさ比べ」 では決められない。
      //   高さの違う 2 枚を横に並べただけで縦にも回り込んでしまい、 下端の
      //   タスクバーを狙うと画面の上へ飛ばされる (= 点検で判明)。
      //   今いるモニターと行き先のモニターが、 その向きに並んで離れている
      //   時だけ回り込む。
      final from = _monitorRectAt(x, y);
      final to = _monitorRectAt(nx, ny);
      if (from == null || to == null) return;
      final horizontal = kind == 'L' || kind == 'R';
      final apart = horizontal
          ? (to.$3 <= from.$1 || to.$1 >= from.$3)
          : (to.$4 <= from.$2 || to.$2 >= from.$4);
      if (!apart) return;

      // ★ 端に着いたら待たずにすぐ移す (= ユーザー報告: 一瞬止まるのが
      //   気になる)。 行き先のモニターの内側へ収めてから移す。
      _setCursorPos(
          nx.clamp(to.$1 + 1, to.$3 - 2), ny.clamp(to.$2 + 1, to.$4 - 2));
      _quietUntil =
          DateTime.now().add(const Duration(milliseconds: 300));
    } catch (_) {
      // 何かおかしければ黙って止める (マウスを人質に取らない)。
      stop();
    }
  }

  bool _anyMouseButtonDown() {
    try {
      const down = 0x8000;
      for (final vk in const [
        w32.VK_LBUTTON,
        w32.VK_RBUTTON,
        w32.VK_MBUTTON,
      ]) {
        if ((w32.GetAsyncKeyState(vk) & down) != 0) return true;
      }
    } catch (_) {}
    return false;
  }

  (int, int)? _cursorPos() {
    final p = calloc<w32.POINT>();
    try {
      if (w32.GetCursorPos(p) == 0) return null;
      return (p.ref.x, p.ref.y);
    } catch (_) {
      return null;
    } finally {
      calloc.free(p);
    }
  }

  void _setCursorPos(int x, int y) {
    try {
      w32.SetCursorPos(x, y);
    } catch (_) {}
  }

  /// [x],[y] にいちばん近いモニターの四角 (left, top, right, bottom)。
  (int, int, int, int)? _monitorRectAt(int x, int y) {
    final pt = calloc<w32.POINT>();
    final mi = calloc<w32.MONITORINFO>();
    try {
      pt.ref.x = x;
      pt.ref.y = y;
      final hm = w32.MonitorFromPoint(pt.ref, w32.MONITOR_DEFAULTTONEAREST);
      if (hm == 0) return null;
      mi.ref.cbSize = sizeOf<w32.MONITORINFO>();
      if (w32.GetMonitorInfo(hm, mi) == 0) return null;
      final r = mi.ref.rcMonitor;
      return (r.left, r.top, r.right, r.bottom);
    } catch (_) {
      return null;
    } finally {
      calloc.free(pt);
      calloc.free(mi);
    }
  }
}
