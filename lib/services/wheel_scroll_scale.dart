// マウスホイールの「1 段で何行」 を、 アプリを入れ直さずに効かせる。
//
// ── なぜ要るのか ────────────────────────────────────────────────────
// Flutter の Windows 側 (engine の flutter_window.cc) は、 窓を作る時に一度
// だけ SPI_GETWHEELSCROLLLINES を読み、 1 段あたり
//     行数 x 100 / 3  (画素)
// を送ると決めてしまう (UpdateScrollOffsetMultiplier)。 読み直す仕組みが
// 無い (engine 側に "TODO: Listen to changes for this value" と
// https://github.com/flutter/flutter/issues/107248 が書いてある)。 なので
// PC 設定のつまみで行数を変えても、 このアプリだけは入れ直すまで前の行数の
// ままだった (= ユーザー要望「アプリ内でも変更後に効くようにできないの?」)。
//
// ── どう直すか ──────────────────────────────────────────────────────
// engine が焼き込んだ行数 [_bakedLines] と、 今 Windows に入っている行数
// [_osLines] の比を、 届いた PointerScrollEvent の量に掛け直す。
//     倍率 = 今の行数 / 起動時の行数
// 掛ける場所はアプリの一番外側 ([WheelScrollScaling] を混ぜた binding) なので、
// 巻物 (Scrollable) も自前の onPointerSignal も、 全部まとめて直る。
//
// ★ 触るのは「マウスのホイール」 だけ。
//   ・精密タッチパッドの 2 本指送りは、 engine では Direct Manipulation を
//     通って PointerPanZoom* になる (= 元々 scroll_offset_multiplier_ が
//     掛かっていない) ので、 ここでも触らない。 その為 kind == mouse で絞る。
//     ただし「精密でない」 タッチパッドや、 Direct Manipulation が受け持た
//     なかった動きは WM_MOUSEWHEEL として届き、 kind は mouse になる。
//     そちらは engine 側でも同じ倍率が掛かっているので、 一緒に直して正しい
//     (= 入れ直した時と同じ動きになる)。
//   ・Windows 以外と Web は倍率 1.0 のまま (dart:ffi を一切触らない)。
//   ・「1 画面ぶん」 (WHEEL_PAGESCROLL = -1) と 0 は比が作れないので何もしない。
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'pc_settings.dart';

/// ホイールの行数の「起動時の値」 と「今の値」 を持ち、 倍率を出す。
class WheelScrollScale {
  WheelScrollScale._();

  /// この窓の engine が焼き込んだ行数。 0 = 分からなかった / 使えない値。
  static int _bakedLines = 0;

  /// 今 Windows に入っている行数。
  static int _osLines = 0;

  /// 掛ける倍率。 1.0 = 何もしない。
  static double _factor = 1.0;

  /// 最後に OS から読み直した時刻。 常駐タイマーを増やさない為、 ホイールを
  /// 回している間だけ、 これを見てたまに読み直す。
  static final Stopwatch _sinceRead = Stopwatch();
  static const int _rereadEveryMs = 1500;

  /// 試験中は OS を読み直さない。
  @visibleForTesting
  static bool debugDisableReread = false;

  /// 今の倍率。
  static double get factor => _factor;

  /// engine が焼き込んだ行数 (0 = 分からなかった)。
  static int get bakedLines => _bakedLines;

  /// 今 Windows に入っている行数 (0 = 分からなかった)。
  static int get osLines => _osLines;

  /// この仕組みが働く場所か。
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// ★ main() の一番最初に呼ぶ。
  ///
  /// engine は「窓を作る時」 に読む。 窓は Dart の main() より前に作られるので、
  /// ここで読んだ値 = engine が焼き込んだ値、 とみなして良い (その間に他の
  /// アプリが変える隙はほぼ無い)。 副窓 (desktop_multi_window) もそれぞれ別の
  /// engine を持ち、 その窓が作られた直後に同じ main() が走るので、 窓ごとに
  /// 正しい控えが取れる。
  /// ※ デバッグ実行の hot restart では main() だけが走り直すので、 engine が
  ///   焼き込んだ倍率は前のままなのに、 ここの基準だけが今の値に取り直される。
  ///   その結果、 変えた後に hot restart すると倍率が 1.0 に戻って合わなく
  ///   なる。 デバッグ中だけの話で、 配布した物では起きない (起動 = 新しい
  ///   engine なので必ず揃う)。
  static void captureBaseline() {
    if (!isSupported) return;
    final int n = _readOsLines();
    if (n <= 0) return; // 1 画面ぶん / 読めなかった → 何もしない。
    _bakedLines = n;
    _osLines = n;
    _factor = 1.0;
    _sinceRead
      ..reset()
      ..start();
  }

  /// OS から読み直して倍率を作り直す。
  /// PC 設定の画面で行数を書き換えた直後と、 ホイールを回している間にたまに
  /// 呼ばれる (= Windows の設定アプリで変えられた時 / 副窓の為)。
  static void refreshFromOs() {
    if (!isSupported || _bakedLines <= 0) return;
    final int n = _readOsLines();
    _sinceRead
      ..reset()
      ..start();
    if (n <= 0) return; // 1 画面ぶん / 読めなかった → 前の倍率のまま。
    _osLines = n;
    _factor = n / _bakedLines;
  }

  /// 試験用に「起動時の行数」 と「今の行数」 を直に入れる。
  @visibleForTesting
  static void debugSetLines({required int baked, required int os}) {
    _bakedLines = baked;
    _osLines = os;
    _factor = (baked > 0 && os > 0) ? os / baked : 1.0;
    _sinceRead
      ..reset()
      ..start();
  }

  static int _readOsLines() {
    try {
      return PcSettings.readWheelScrollLines();
    } catch (_) {
      return 0;
    }
  }

  /// 届いた出来事に倍率を掛け直す。
  ///
  /// 掛ける必要が無ければ**同じ物をそのまま**返す。 これは大事で、
  /// [PointerSignalResolver] は register した物と resolve する物が同じかどうかを
  /// (`original ?? this` の) 同一性で見ている。 入口で 1 回だけ差し替えて、
  /// その後はずっと同じ物を流すので、 突き合わせは狂わない。
  static PointerEvent scaleEvent(PointerEvent event) {
    if (event is! PointerScrollEvent) return event;
    // engine が掛けているのは WM_MOUSEWHEEL / WM_MOUSEHWHEEL (= マウス) だけ。
    if (event.kind != PointerDeviceKind.mouse) return event;
    if (!debugDisableReread &&
        _bakedLines > 0 &&
        _sinceRead.elapsedMilliseconds >= _rereadEveryMs) {
      refreshFromOs();
    }
    final double f = _factor;
    if (f == 1.0 || !f.isFinite || f <= 0) return event;
    // 既に座標を変換された物が来ても壊れないように、 元を取り出して作り直し、
    // 同じ変換を掛け直す (入口では transform は常に null だが念の為)。
    final PointerScrollEvent src =
        (event.original as PointerScrollEvent?) ?? event;
    final PointerScrollEvent scaled = PointerScrollEvent(
      viewId: src.viewId,
      timeStamp: src.timeStamp,
      kind: src.kind,
      device: src.device,
      position: src.position,
      scrollDelta: src.scrollDelta * f,
      embedderId: src.embedderId,
      // 返事の通り道は元へ繋ぎ直す (copyWith と同じやり方)。
      onRespond: src.respond,
    );
    // transform が null なら transformed は自分をそのまま返す。
    return scaled.transformed(event.transform);
  }
}

/// [GestureBinding.handlePointerEvent] の入口で 1 回だけ掛け直す。
/// 試験でも同じ物を混ぜられるように、 binding 本体とは分けてある。
mixin WheelScrollScaling on GestureBinding {
  @override
  void handlePointerEvent(PointerEvent event) {
    super.handlePointerEvent(WheelScrollScale.scaleEvent(event));
  }
}

/// アプリが使う binding。 [WidgetsFlutterBinding] にホイールの掛け直しだけを
/// 足した物。 これ以外の振る舞いは何も変えない。
class WheelScrollBinding extends WidgetsFlutterBinding with WheelScrollScaling {
  static WheelScrollBinding? _instance;

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  /// [WidgetsFlutterBinding.ensureInitialized] の代わり。 まだ binding が
  /// 作られていなければ、 こちらを作る。 一度これで作っておけば、 後から
  /// runApp やプラグインが ensureInitialized を呼んでも、 この binding が返る。
  static WidgetsBinding ensureInitialized() {
    if (_instance == null) {
      WheelScrollBinding();
    }
    return WidgetsBinding.instance;
  }
}
