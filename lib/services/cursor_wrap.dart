import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart' as w32;

/// 画面の両端をつないでマウスを回り込ませ、 モニターごとにカーソルの
/// 大きさを切り替える (Windows 専用)。
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
///   * ボタンを押している最中 (物を運んでいる途中で飛ばすと壊れる)。
///     ただし **窓の題名帯を掴んで動かしている時だけは例外** で、 窓ごと
///     回り込ませる (= ユーザー要望: カーソルは両端から出せるのに、 掴んだ
///     窓は出せない)。 窓の大きさを変えている最中は形が壊れるのでやらない。
///   * 移した直後の 300ms (行ったり来たりを防ぐ)
/// モニター 1 枚ぶんの情報 (画面の座標)。
class MonitorInfo {
  final int left;
  final int top;
  final int right;
  final int bottom;

  /// Windows の「主ディスプレイ」 か。
  final bool primary;
  const MonitorInfo(
      this.left, this.top, this.right, this.bottom, this.primary);

  int get width => right - left;
  int get height => bottom - top;

  /// 見分けが付くよう「幅x高さ」 で表す。
  String get sizeLabel => '${width}x$height';

  @override
  bool operator ==(Object other) =>
      other is MonitorInfo &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

class CursorWrap {
  CursorWrap._();

  static final CursorWrap instance = CursorWrap._();

  /// 本体の窓だけで動かすための札。 サブ窓や外窓 (別のエンジン) でも
  /// MindMapProvider は作られるので、 何も守らないと同じ処理が二重に走り、
  /// 二重に飛ばして元の場所へ戻ってしまう。 main() の本体の道でだけ立てる。
  static bool allowed = false;

  Timer? _timer;
  bool _enabled = false;

  // ── カーソルの大きさ (= ユーザー要望: アプリから設定 / サブモニターでは
  //    別の大きさに) ──
  //    Windows の「マウス ポインターのサイズ」 (1〜15) をレジストリ +
  //    SPI_SETCURSORS で書き換える。 15 = 最大 (256px)、 1 = 標準 (32px)。
  /// メインモニターでの大きさ (0 = 触らない)。
  int _sizeMain = 0;

  /// サブモニターでの大きさ (0 = 切り替えない)。
  int _sizeSub = 0;

  /// 最後に適用した大きさ (無駄な書き込みをしないため)。
  int _appliedSize = 0;

  /// 前回カーソルが居たのが主モニターだったか。
  bool? _wasOnPrimary;

  /// 機能を使い始める前の Windows 設定 (メイン側の指定が無い時の戻し先)。
  /// 自分で書き換えた後にレジストリを読むとサブの値が返ってしまうため、
  /// 書き換える前に控えておく。
  int _baselineSize = 0;

  /// 今の Windows 設定の大きさ (1〜15、 読めなければ 1)。
  static int readSystemCursorSize() {
    if (!isSupported) return 1;
    final data = calloc<Uint32>();
    final cb = calloc<Uint32>()..value = 4;
    final sub = 'Software\\Microsoft\\Accessibility'.toNativeUtf16();
    final name = 'CursorSize'.toNativeUtf16();
    try {
      final r = w32.RegGetValue(w32.HKEY_CURRENT_USER, sub, name,
          w32.RRF_RT_REG_DWORD, nullptr, data.cast(), cb);
      if (r != 0) return 1;
      final v = data.value;
      return v < 1 ? 1 : (v > 15 ? 15 : v);
    } catch (_) {
      return 1;
    } finally {
      calloc.free(data);
      calloc.free(cb);
      calloc.free(sub);
      calloc.free(name);
    }
  }

  /// カーソルの大きさを今すぐ変える (1〜15)。
  static bool applyCursorSize(int size) {
    if (!isSupported) return false;
    final n = size.clamp(1, 15);
    try {
      _writeDword('Software\\Microsoft\\Accessibility', 'CursorSize', n);
      _writeDword(
          'Control Panel\\Cursors', 'CursorBaseSize', 32 + (n - 1) * 16);
      // 0x57 = SPI_SETCURSORS。 これでシステム全体に反映される。
      w32.SystemParametersInfo(w32.SPI_SETCURSORS, 0, nullptr,
          w32.SPIF_UPDATEINIFILE | w32.SPIF_SENDCHANGE);
      return true;
    } catch (_) {
      return false;
    }
  }

  static void _writeDword(String subKey, String name, int value) {
    final subP = subKey.toNativeUtf16();
    final nameP = name.toNativeUtf16();
    final data = calloc<Uint32>()..value = value;
    try {
      w32.RegSetKeyValue(
          w32.HKEY_CURRENT_USER, subP, nameP, w32.REG_DWORD, data.cast(), 4);
    } finally {
      calloc.free(subP);
      calloc.free(nameP);
      calloc.free(data);
    }
  }

  /// カーソルの大きさを、 アプリが書き換えた分だけ Windows の既定へ戻す。
  ///
  /// = ユーザー要望「変えることができないのであれば項目自体消して」。
  /// 実測すると、 レジストリ (Accessibility\CursorSize と
  /// Cursors\CursorBaseSize) は書けても、 実際のカーソルの絵は 32px の
  /// ままだった (SystemParametersInfo(SPI_SETCURSORS) は成功するのに
  /// 反映されない。 Windows 11 はサインインし直すまで読み直さない)。
  /// このまま控えを残すと、 次のサインインで急に大きなカーソルになって
  /// しまうので、 機能を消すのと一緒に既定へ戻す。
  static void resetCursorSizeToDefault() {
    if (!isSupported) return;
    try {
      _writeDword('Software\\Microsoft\\Accessibility', 'CursorSize', 1);
      _writeDword('Control Panel\\Cursors', 'CursorBaseSize', 32);
      w32.SystemParametersInfo(w32.SPI_SETCURSORS, 0, nullptr, 0);
    } catch (_) {}
  }

  /// モニターごとの大きさ設定を渡す (0 = その画面では触らない)。
  ///
  /// ★ 中身は空にした。 上のとおり実際には効かないため
  ///   (= ユーザー要望で項目ごと削除)。 呼び出し側を一度に消すと差分が
  ///   大きくなるので、 受け口だけ残して何もしない。
  // ignore: unused_element
  void applySizesDisabled({required int main, required int sub}) {
    _sizeMain = main.clamp(0, 15);
    _sizeSub = sub.clamp(0, 15);
    // まだ何も書き換えていない時だけ、 今の設定を戻し先として控える。
    if (_appliedSize == 0 && _sizeMain > 0) {
      _baselineSize = readSystemCursorSize();
    }
    _wasOnPrimary = null;
    _appliedSize = 0;
    // ★ メインの指定があれば、 その場で当てる。
    //
    //   ここは前まで「サブの指定もある時だけ」 当てていた
    //   (`_sizeMain > 0 && _sizeSub > 0`)。 そのせいで、 「サブモニターでは
    //   別の大きさにする」 を切ったまま大きさだけ変えても**何も起きなかった**
    //   (= ユーザー報告: マウスカーソルの大きさが変わらない)。
    //   モニターごとの切り替えと、 今の大きさを当てる事は別の話なので分けた。
    if (isSupported && allowed && _sizeMain > 0) {
      if (applyCursorSize(_sizeMain)) _appliedSize = _sizeMain;
    }
    _syncTimer();
  }

  /// 移した直後に、 また移してしまわないための待ち時間。
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // ── 窓を掴んで運んでいる最中か (= ユーザー要望: 掴んだ窓も両端から) ──
  //    Windows は題名帯を掴むと「移動の輪」 に入り、 GUI_INMOVESIZE が立つ。
  //    輪の中では窓の位置が「今のカーソル - 掴んだ時のずれ」 で決まるので、
  //    カーソルを反対の端へ移せば窓も付いて来る。
  //    ただし GUI_INMOVESIZE は**大きさ変更**でも立つ。 そちらで飛ばすと形が
  //    壊れるため、 掴んだ時の大きさと見比べて移動だけを通す。
  /// いま輪に入っている窓 (0 = 入っていない)。
  int _moveHwnd = 0;

  /// その窓を掴んだ時の大きさ。 変わったら「大きさ変更」 と見なす。
  int _moveW = 0;
  int _moveH = 0;


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
    _syncTimer();
  }

  /// どちらかの機能が要る間だけ見回りを回す。
  void _syncTimer() {
    final want =
        isSupported && allowed && (_enabled || _edgeTargets.isNotEmpty);
    if (!want) {
      stop();
      return;
    }
    _timer ??=
        Timer.periodic(const Duration(milliseconds: 15), (_) => _tick());
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
    try {
      // カーソルの大きさの切り替えは廃止 (= 実際に効かないため)。
    } catch (_) {}
    if (!_enabled) return;
    if (DateTime.now().isBefore(_quietUntil)) return;
    try {
      if (!hasMultipleMonitors) return;
      // 何かを掴んで運んでいる最中は触らない。 ただし窓を掴んで**動かして**
      // いる時だけは通す (= ユーザー要望: カーソルは両端から出せるのに、
      // 掴んだ窓は出せない)。
      // ★ 調べるのはボタンが押されている時だけ。 押していない間まで毎回
      //   (15ms ごと) OS に問い合わせると、 ただの無駄になる。
      var movingWindow = 0;
      if (_anyMouseButtonDown()) {
        movingWindow = _movingWindowHandle();
        if (movingWindow == 0) return;
      } else {
        _moveHwnd = 0;
      }

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

      // ── まず「今いるモニターのどの端に着いたか」 を見る ──
      //    仮想画面の端だけを見ていると、 高さの違うモニターを並べた時に
      //    サブの上端が仮想画面の上端にならず、 上から行き来できなかった
      //    (= ユーザー要望: 上下からもアクセスしたい)。
      final here = _monitorRectAt(x, y);
      if (here == null) return;
      final mons = listMonitors();
      MonitorInfo? hereInfo;
      for (final m in mons) {
        if (m.left == here.$1 &&
            m.top == here.$2 &&
            m.right == here.$3 &&
            m.bottom == here.$4) {
          hereInfo = m;
          break;
        }
      }

      var kind = '';
      if (x <= here.$1) {
        kind = 'L';
      } else if (x >= here.$3 - 1) {
        kind = 'R';
      } else if (y <= here.$2) {
        kind = 'T';
      } else if (y >= here.$4 - 1) {
        kind = 'B';
      }
      if (kind.isEmpty) return;

      // OS がその側で既に隣のモニターへ繋いでいるなら、 何もしない
      //   (= そのまま歩いて行けるので、 飛ばすと邪魔になるだけ)。
      if (hereInfo != null && hasNeighbor(hereInfo, kind, mons)) return;

      // どのモニターに居るか (一覧での番号)。
      var hereIndex = -1;
      for (var i = 0; i < mons.length; i++) {
        if (mons[i] == hereInfo) {
          hereIndex = i;
          break;
        }
      }
      final target = hereIndex < 0 ? null : _targetFor(hereIndex, kind);
      // 行き先が決まっていない辺は、 全体のトグルが入っていれば昔どおり
      //   「反対の端へ回り込む」。 入っていなければ何もしない。
      if (target == null && !_enabled) return;

      int? nx, ny;
      if (target != null && target >= 0) {
        // ── 指定したモニターへ飛ぶ (= ユーザー要望: 3 台目の設定なども) ──
        //    出た辺の反対側から入り、 直交方向の位置は割合で引き継ぐ。
        if (target >= mons.length) return;
        final to = mons[target];
        double ratio(int v, int lo, int hi) =>
            hi <= lo ? 0.5 : ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
        int lerp(double r, int lo, int hi) =>
            (lo + (hi - lo) * r).round().clamp(lo + 1, hi - 2);
        if (kind == 'L' || kind == 'R') {
          final r = ratio(y, here.$2, here.$4);
          nx = kind == 'L' ? to.right - 2 : to.left + 1;
          ny = lerp(r, to.top, to.bottom);
        } else {
          final r = ratio(x, here.$1, here.$3);
          ny = kind == 'T' ? to.bottom - 2 : to.top + 1;
          nx = lerp(r, to.left, to.right);
        }
        if (nx == null || ny == null) return;
        // 窓を掴んでいる時は窓も一緒に運ぶ (= 反対の端へ回り込む時と同じ)。
        if (movingWindow != 0) _moveWindowBy(movingWindow, nx - x, ny - y);
        _setCursorPos(nx, ny);
        _quietUntil = DateTime.now().add(const Duration(milliseconds: 300));
        return;
      }

      // ── 行き先の指定が無い時 = 「仮想画面の反対の端」 へ回り込む ──
      //    こちらは仮想画面の外周に着いた時だけ (= 昔からの動き)。
      if (kind == 'L') {
        if (x > vx) return;
        nx = vRight - 2;
        ny = y;
      } else if (kind == 'R') {
        if (x < vRight) return;
        nx = vx + 2;
        ny = y;
      } else if (kind == 'T') {
        if (y > vy) return;
        nx = x;
        ny = vBottom - 2;
      } else {
        if (y < vBottom) return;
        nx = x;
        ny = vy + 2;
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
      final tx = nx.clamp(to.$1 + 1, to.$3 - 2);
      final ty = ny.clamp(to.$2 + 1, to.$4 - 2);
      // 窓を掴んでいる時は、 窓も同じだけ先に運んでおく。 移動の輪が自分で
      // カーソルに追従する場合は次の更新で上書きされるだけなので、 追従
      // しない環境への保険になる (窓だけ置き去りにしない)。
      if (movingWindow != 0) _moveWindowBy(movingWindow, tx - x, ty - y);
      _setCursorPos(tx, ty);
      _quietUntil =
          DateTime.now().add(const Duration(milliseconds: 300));
    } catch (_) {
      // 何かおかしければ黙って止める (マウスを人質に取らない)。
      stop();
    }
  }

  /// カーソルが主モニターとサブモニターを行き来したら、 大きさを合わせる。
  void _sizeTick() {
    if (_sizeSub <= 0) return;
    if (!hasMultipleMonitors) {
      // ★ サブ用の大きさを当てたまま 1 枚になったら (取り外し等)、
      //   メイン側の大きさへ戻す (= 点検で判明: 大きいまま残っていた)。
      if (_appliedSize != 0 && _appliedSize == _sizeSub) {
        final back = _sizeMain > 0
            ? _sizeMain
            : (_baselineSize > 0 ? _baselineSize : 1);
        if (back != _appliedSize) applyCursorSize(back);
        _appliedSize = 0;
        _wasOnPrimary = null;
      }
      return;
    }
    final pos = _cursorPos();
    if (pos == null) return;
    final onPrimary = _isOnPrimary(pos.$1, pos.$2);
    if (onPrimary == null || onPrimary == _wasOnPrimary) return;
    _wasOnPrimary = onPrimary;
    // メイン側の指定が無ければ、 今の Windows 設定を「戻し先」 にする。
    final want = onPrimary
        ? (_sizeMain > 0
            ? _sizeMain
            : (_baselineSize > 0 ? _baselineSize : readSystemCursorSize()))
        : _sizeSub;
    if (want == _appliedSize) return;
    if (applyCursorSize(want)) _appliedSize = want;
  }

  /// [x],[y] が主モニターの上か (分からなければ null)。
  bool? _isOnPrimary(int x, int y) {
    final pt = calloc<w32.POINT>();
    final mi = calloc<w32.MONITORINFO>();
    try {
      pt.ref.x = x;
      pt.ref.y = y;
      final hm = w32.MonitorFromPoint(pt.ref, w32.MONITOR_DEFAULTTONEAREST);
      if (hm == 0) return null;
      mi.ref.cbSize = sizeOf<w32.MONITORINFO>();
      if (w32.GetMonitorInfo(hm, mi) == 0) return null;
      return (mi.ref.dwFlags & w32.MONITORINFOF_PRIMARY) != 0;
    } catch (_) {
      return null;
    } finally {
      calloc.free(pt);
      calloc.free(mi);
    }
  }

  /// 掴んで**動かしている**窓のハンドル。 掴んでいない / 大きさを変えて
  /// いる最中は 0 (= ユーザー要望: 掴んだ窓も両端から出せるように)。
  int _movingWindowHandle() {
    final gti = calloc<w32.GUITHREADINFO>();
    try {
      gti.ref.cbSize = sizeOf<w32.GUITHREADINFO>();
      // 0 を渡すと今いちばん手前の窓の担当を見てくれる。
      if (w32.GetGUIThreadInfo(0, gti) == 0 ||
          (gti.ref.flags & w32.GUI_INMOVESIZE) == 0) {
        _moveHwnd = 0;
        return 0;
      }
      final hwnd = gti.ref.hwndMoveSize;
      if (hwnd == 0) {
        _moveHwnd = 0;
        return 0;
      }
      final r = _windowRect(hwnd);
      if (r == null) return 0;
      final w = r.$3 - r.$1;
      final h = r.$4 - r.$2;
      if (hwnd != _moveHwnd) {
        // 掴んだ直後。 大きさを覚えておく。
        _moveHwnd = hwnd;
        _moveW = w;
        _moveH = h;
        return hwnd;
      }
      // 大きさが変わっている = 移動ではなく大きさ変更。
      if (w != _moveW || h != _moveH) return 0;
      return hwnd;
    } catch (_) {
      _moveHwnd = 0;
      return 0;
    } finally {
      calloc.free(gti);
    }
  }

  /// 窓の四角 (left, top, right, bottom)。
  (int, int, int, int)? _windowRect(int hwnd) {
    final r = calloc<w32.RECT>();
    try {
      if (w32.GetWindowRect(hwnd, r) == 0) return null;
      return (r.ref.left, r.ref.top, r.ref.right, r.ref.bottom);
    } catch (_) {
      return null;
    } finally {
      calloc.free(r);
    }
  }

  /// 窓を [dx],[dy] だけ運ぶ (大きさと重なりの順は変えない)。
  ///
  /// ★ 必ず **非同期** (SWP_ASYNCWINDOWPOS) で頼む。 相手は「移動の輪」 の
  ///   中にいる別プロセスの窓かもしれず、 同期で頼むと相手の返事を待って
  ///   こちらの画面まで止まってしまう。 この関数の中で起きた不具合は
  ///   ここで握り潰す (外側まで飛ぶと見回りごと止まり、 カーソルの大きさ
  ///   切り替えまで道連れになる)。
  void _moveWindowBy(int hwnd, int dx, int dy) {
    try {
      if (w32.IsWindow(hwnd) == 0) return;
      final r = _windowRect(hwnd);
      if (r == null) return;
      w32.SetWindowPos(
          hwnd,
          0,
          r.$1 + dx,
          r.$2 + dy,
          0,
          0,
          w32.SWP_NOSIZE |
              w32.SWP_NOZORDER |
              w32.SWP_NOACTIVATE |
              w32.SWP_ASYNCWINDOWPOS);
    } catch (_) {}
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

  /// 今つながっているモニターの一覧 (左上から順)。
  ///
  /// EnumDisplayMonitors は「関数を OS に渡す」 形なので、 ここでは仮想画面を
  /// 粗く突いて (MonitorFromPoint) 見つかった四角を集める。 モニターはどれも
  /// 十分大きいので、 200px 刻みで取りこぼす事はない。
  static List<MonitorInfo> listMonitors() {
    if (!isSupported) return const [];
    final out = <MonitorInfo>[];
    try {
      final vx = _staticMetric(w32.SM_XVIRTUALSCREEN);
      final vy = _staticMetric(w32.SM_YVIRTUALSCREEN);
      final vw = _staticMetric(w32.SM_CXVIRTUALSCREEN);
      final vh = _staticMetric(w32.SM_CYVIRTUALSCREEN);
      if (vw <= 0 || vh <= 0) return const [];
      const step = 200;
      for (var y = vy + 1; y < vy + vh; y += step) {
        for (var x = vx + 1; x < vx + vw; x += step) {
          final m = _staticMonitorAt(x, y);
          if (m != null && !out.contains(m)) out.add(m);
        }
      }
      // 右端 / 下端も必ず見る (刻みで飛ばしてしまう事があるため)。
      for (final pt in [
        (vx + vw - 2, vy + 1),
        (vx + 1, vy + vh - 2),
        (vx + vw - 2, vy + vh - 2),
      ]) {
        final m = _staticMonitorAt(pt.$1, pt.$2);
        if (m != null && !out.contains(m)) out.add(m);
      }
    } catch (_) {
      return out;
    }
    out.sort((a, b) => a.left != b.left
        ? a.left.compareTo(b.left)
        : a.top.compareTo(b.top));
    return out;
  }

  static int _staticMetric(int index) {
    try {
      return w32.GetSystemMetrics(index);
    } catch (_) {
      return 0;
    }
  }

  static MonitorInfo? _staticMonitorAt(int x, int y) {
    final pt = calloc<w32.POINT>();
    final mi = calloc<w32.MONITORINFO>();
    try {
      pt.ref.x = x;
      pt.ref.y = y;
      final hm = w32.MonitorFromPoint(pt.ref, w32.MONITOR_DEFAULTTONULL);
      if (hm == 0) return null;
      mi.ref.cbSize = sizeOf<w32.MONITORINFO>();
      if (w32.GetMonitorInfo(hm, mi) == 0) return null;
      final r = mi.ref.rcMonitor;
      return MonitorInfo(r.left, r.top, r.right, r.bottom,
          (mi.ref.dwFlags & w32.MONITORINFOF_PRIMARY) != 0);
    } catch (_) {
      return null;
    } finally {
      calloc.free(pt);
      calloc.free(mi);
    }
  }

  /// [m] の [kind] 側 ('L'/'R'/'T'/'B') に、 別のモニターが隣接しているか。
  ///
  /// = ユーザー要望「サブモニターに windows のカーソルからアクセスできる
  ///   方向を調べて」。 隣がある側は OS がそのまま繋いでいるので、 こちらで
  ///   回り込ませる必要はない (むしろ邪魔になる)。
  static bool hasNeighbor(MonitorInfo m, String kind,
      [List<MonitorInfo>? all]) {
    final mons = all ?? listMonitors();
    for (final o in mons) {
      if (o == m) continue;
      switch (kind) {
        case 'L':
          if (o.right == m.left && o.bottom > m.top && o.top < m.bottom) {
            return true;
          }
          break;
        case 'R':
          if (o.left == m.right && o.bottom > m.top && o.top < m.bottom) {
            return true;
          }
          break;
        case 'T':
          if (o.bottom == m.top && o.right > m.left && o.left < m.right) {
            return true;
          }
          break;
        default:
          if (o.top == m.bottom && o.right > m.left && o.left < m.right) {
            return true;
          }
      }
    }
    return false;
  }

  /// 辺ごとの行き先。 キーは **'モニター番号:辺'** ('0:L' など)。
  ///   * 入っていない → その辺では何もしない
  ///     (ただし「両サイドからアクセス」 が入っていれば、 昔どおり反対の端へ
  ///      回り込む。 = ユーザー要望: 端ごとに「反対の端へ回り込む」 を選ぶのは
  ///      くどいので、 それは全体のトグルに任せる)
  ///   * 0 以上 → [listMonitors] の何番目のモニターへ飛ぶか
  Map<String, int> _edgeTargets = const {};

  /// [monIndex] のモニターの [kind] 側の行き先 (無ければ null)。
  int? _targetFor(int monIndex, String kind) {
    final v = _edgeTargets['$monIndex:$kind'];
    if (v != null) return v;
    // 昔の控え (辺だけの鍵) は主モニターの物として読む。
    if (monIndex == 0) {
      final old = _edgeTargets[kind];
      if (old != null && old >= 0) return old;
    }
    return null;
  }

  /// 設定を渡す (= ユーザー要望: どの方向から行き来するかを選べるように)。
  void applyEdgeTargets(Map<String, int> v) {
    _edgeTargets = Map<String, int>.from(v);
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
