// オートクリッカーの位置決め。
//
// ★ = ユーザー要望「スクショ位置はカーソルが 3 秒後に乗っている位置ではなく、
//   ユーザーが指定した左上、 右下の座標ベースにして欲しい」
//   「Android アプリのオートクリッカーの様に、 画面上に操作の始点と終点の
//   アイコンが配置されるようにして欲しい」。
//
// 画面ぜんたいを 1 枚写し、 その上に印 (1 = 始点 / 2 = 終点、 範囲なら
// 左上 / 右下) を並べる。 印を引きずって合わせ、「決定」 で物理ピクセルの
// 座標として返す。 アプリの窓の外は覆えないので、 写しの上で選んでもらう
// (画面録画の範囲選びと同じ考え方)。 別窓のパレットからは、 窓を画面
// いっぱいに広げてから出すので、 写しはほぼ等倍で重なって見える。
//
// ★ ルートではなく**根っこの Overlay** に重ねる。 アプリ内の浮かせた窓は
//   根っこの Overlay に挿してあり、 ルートに積むとその窓の裏に隠れる。
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/screen_capture.dart';

/// 決めた位置 (物理ピクセル、 仮想デスクトップの座標)。
/// 範囲は (x1, y1) = 左上 / (x2, y2) = 右下 にそろえて返す。
class AutoClickPick {
  const AutoClickPick(this.x1, this.y1, this.x2, this.y2);
  final int x1;
  final int y1;
  final int x2;
  final int y2;
}

/// 印の置き方。
enum AutoClickPickMode {
  /// 1 点 (押す / 連打 / ホイールの位置)。
  point,

  /// 始点 → 終点 (スワイプ)。
  line,

  /// 左上 → 右下 (範囲のスクショ)。
  rect,
}

/// 画面の写しを撮り、 印を置く層を一番上に出す。 決めたら座標を返す
/// (やめたら null)。 写しが撮れない環境では [onUnavailable] を呼んで null。
///
/// [onFullScreen] は別窓のパレット用: true で窓を画面いっぱいに広げ、
/// false で元の大きさへ戻す。 写しはその**前**に撮る (広げた窓を写さない)。
Future<AutoClickPick?> showAutoClickPointPicker({
  required BuildContext context,
  required String Function(String key) t,
  required AutoClickPickMode mode,
  required String title,
  required IconData icon,
  required int x1,
  required int y1,
  required int x2,
  required int y2,
  Future<void> Function(bool on)? onFullScreen,
  VoidCallback? onUnavailable,
}) async {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  final v = virtualScreenRect();
  if (overlay == null || v == null) {
    onUnavailable?.call();
    return null;
  }
  final shot = captureScreenRectPng(v.x, v.y, v.width, v.height);
  if (shot == null || shot.isEmpty) {
    onUnavailable?.call();
    return null;
  }
  try {
    await onFullScreen?.call(true);
  } catch (_) {}
  final done = Completer<AutoClickPick?>();
  final entry = OverlayEntry(
    builder: (_) => _AutoClickPointPickerView(
      shot: shot,
      vx: v.x,
      vy: v.y,
      vw: v.width,
      vh: v.height,
      mode: mode,
      title: title,
      icon: icon,
      t: t,
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      onDone: (r) {
        if (!done.isCompleted) done.complete(r);
      },
    ),
  );
  overlay.insert(entry);
  final result = await done.future;
  entry.remove();
  try {
    await onFullScreen?.call(false);
  } catch (_) {}
  return result;
}

class _AutoClickPointPickerView extends StatefulWidget {
  const _AutoClickPointPickerView({
    required this.shot,
    required this.vx,
    required this.vy,
    required this.vw,
    required this.vh,
    required this.mode,
    required this.title,
    required this.icon,
    required this.t,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.onDone,
  });

  final Uint8List shot;
  final int vx;
  final int vy;
  final int vw;
  final int vh;
  final AutoClickPickMode mode;
  final String title;
  final IconData icon;
  final String Function(String key) t;
  final int x1;
  final int y1;
  final int x2;
  final int y2;
  final ValueChanged<AutoClickPick?> onDone;

  @override
  State<_AutoClickPointPickerView> createState() =>
      _AutoClickPointPickerViewState();
}

class _AutoClickPointPickerViewState extends State<_AutoClickPointPickerView> {
  static const Color _c1 = Color(0xFF4DD0E1);
  static const Color _c2 = Color(0xFFFF8A65);

  /// 印の位置 (物理ピクセル)。 範囲では 1 = 左上 / 2 = 右下。
  late Offset _p1;
  late Offset _p2;

  /// 写しを描いている所 (この層の中の論理座標)。
  Rect _img = Rect.zero;

  /// 範囲をなぞって描いている時の起点 (物理ピクセル)。
  Offset? _drawFrom;

  /// 操作の札をずらした量 (印と重なった時に退けられるように)。
  Offset _panelShift = Offset.zero;

  final FocusNode _focus = FocusNode(debugLabel: 'autoClickPicker');

  String _t(String k) => widget.t(k);

  @override
  void initState() {
    super.initState();
    final cx = widget.vx + widget.vw / 2;
    final cy = widget.vy + widget.vh / 2;
    bool unset(int x, int y) => x == 0 && y == 0;
    switch (widget.mode) {
      case AutoClickPickMode.point:
        _p1 = unset(widget.x1, widget.y1)
            ? Offset(cx, cy)
            : Offset(widget.x1.toDouble(), widget.y1.toDouble());
        _p2 = _p1;
        break;
      case AutoClickPickMode.line:
        _p1 = unset(widget.x1, widget.y1)
            ? Offset(cx - widget.vw * 0.12, cy)
            : Offset(widget.x1.toDouble(), widget.y1.toDouble());
        _p2 = unset(widget.x2, widget.y2)
            ? Offset(cx + widget.vw * 0.12, cy)
            : Offset(widget.x2.toDouble(), widget.y2.toDouble());
        break;
      case AutoClickPickMode.rect:
        final hasRect = !unset(widget.x1, widget.y1) &&
            !unset(widget.x2, widget.y2) &&
            widget.x1 != widget.x2 &&
            widget.y1 != widget.y2;
        if (hasRect) {
          _p1 = Offset(math.min(widget.x1, widget.x2).toDouble(),
              math.min(widget.y1, widget.y2).toDouble());
          _p2 = Offset(math.max(widget.x1, widget.x2).toDouble(),
              math.max(widget.y1, widget.y2).toDouble());
        } else {
          _p1 = Offset(cx - widget.vw * 0.2, cy - widget.vh * 0.2);
          _p2 = Offset(cx + widget.vw * 0.2, cy + widget.vh * 0.2);
        }
        break;
    }
    _p1 = _clampPhys(_p1);
    _p2 = _clampPhys(_p2);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  // ─── 座標の換算 ───────────────────────────────────────────────────────

  Offset _clampPhys(Offset p) => Offset(
        p.dx.clamp(widget.vx.toDouble(), (widget.vx + widget.vw - 1).toDouble()),
        p.dy.clamp(widget.vy.toDouble(), (widget.vy + widget.vh - 1).toDouble()),
      );

  Offset _toLocal(Offset phys) {
    if (_img.width <= 0 || _img.height <= 0) return Offset.zero;
    return Offset(
      _img.left + (phys.dx - widget.vx) / widget.vw * _img.width,
      _img.top + (phys.dy - widget.vy) / widget.vh * _img.height,
    );
  }

  Offset _toPhys(Offset local) {
    if (_img.width <= 0 || _img.height <= 0) return Offset.zero;
    return _clampPhys(Offset(
      widget.vx + (local.dx - _img.left) / _img.width * widget.vw,
      widget.vy + (local.dy - _img.top) / _img.height * widget.vh,
    ));
  }

  /// 論理座標の動き → 物理ピクセルの動き。
  Offset _deltaToPhys(Offset d) => _img.width <= 0
      ? Offset.zero
      : Offset(d.dx * widget.vw / _img.width, d.dy * widget.vh / _img.height);

  /// 範囲の印を「1 = 左上 / 2 = 右下」 にそろえ直す。
  void _normalizeRect() {
    if (widget.mode != AutoClickPickMode.rect) return;
    final a = _p1, b = _p2;
    _p1 = Offset(math.min(a.dx, b.dx), math.min(a.dy, b.dy));
    _p2 = Offset(math.max(a.dx, b.dx), math.max(a.dy, b.dy));
  }

  // ─── 決める / やめる ─────────────────────────────────────────────────

  void _confirm() {
    _normalizeRect();
    if (widget.mode == AutoClickPickMode.rect &&
        ((_p2.dx - _p1.dx) < 2 || (_p2.dy - _p1.dy) < 2)) {
      return;
    }
    widget.onDone(AutoClickPick(
      _p1.dx.round(),
      _p1.dy.round(),
      (widget.mode == AutoClickPickMode.point ? _p1 : _p2).dx.round(),
      (widget.mode == AutoClickPickMode.point ? _p1 : _p2).dy.round(),
    ));
  }

  void _cancel() => widget.onDone(null);

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _confirm();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ─── 何もない所の操作 ──────────────────────────────────────────────────

  /// 1 点 / スワイプ: 押した所へ近い方の印を寄せる。
  void _onBackgroundTap(Offset local) {
    if (widget.mode == AutoClickPickMode.rect) return;
    final p = _toPhys(local);
    setState(() {
      if (widget.mode == AutoClickPickMode.point) {
        _p1 = p;
        _p2 = p;
        return;
      }
      final d1 = (_toLocal(_p1) - local).distance;
      final d2 = (_toLocal(_p2) - local).distance;
      if (d1 <= d2) {
        _p1 = p;
      } else {
        _p2 = p;
      }
    });
  }

  /// 範囲: 何もない所をなぞると、 新しい範囲を描く。
  void _onBackgroundPanStart(Offset local) {
    if (widget.mode != AutoClickPickMode.rect) return;
    final p = _toPhys(local);
    setState(() {
      _drawFrom = p;
      _p1 = p;
      _p2 = p;
    });
  }

  void _onBackgroundPanUpdate(Offset local) {
    final from = _drawFrom;
    if (from == null) return;
    setState(() {
      _p1 = from;
      _p2 = _toPhys(local);
    });
  }

  void _onBackgroundPanEnd() {
    if (_drawFrom == null) return;
    setState(() {
      _drawFrom = null;
      _normalizeRect();
    });
  }

  // ─── 描く ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(builder: (ctx, c) {
          final s = math.min(c.maxWidth / widget.vw, c.maxHeight / widget.vh);
          final w = widget.vw * s;
          final h = widget.vh * s;
          _img = Rect.fromLTWH(
              (c.maxWidth - w) / 2, (c.maxHeight - h) / 2, w, h);
          final l1 = _toLocal(_p1);
          final l2 = _toLocal(_p2);
          return Stack(children: [
            Positioned.fromRect(
              rect: _img,
              child: Image.memory(widget.shot,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium),
            ),
            // 何もない所 (= 写しの上) の押し / なぞり。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _onBackgroundTap(d.localPosition),
                onPanStart: (d) => _onBackgroundPanStart(d.localPosition),
                onPanUpdate: (d) => _onBackgroundPanUpdate(d.localPosition),
                onPanEnd: (_) => _onBackgroundPanEnd(),
                onPanCancel: _onBackgroundPanEnd,
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _PickPainter(
                    mode: widget.mode,
                    a: l1,
                    b: l2,
                    img: _img,
                  ),
                ),
              ),
            ),
            if (widget.mode == AutoClickPickMode.rect) ...[
              _cornerHandle(l1, 1),
              _cornerHandle(l2, 2),
            ] else ...[
              if (widget.mode == AutoClickPickMode.line) _targetHandle(l2, 2),
              _targetHandle(l1, 1),
            ],
            _panel(c),
          ]);
        }),
      ),
    );
  }

  /// Android のオートクリッカーのような丸い的 (1 = 始点 / 2 = 終点)。
  Widget _targetHandle(Offset at, int which) {
    const r = 24.0;
    final color = which == 1 ? _c1 : _c2;
    return Positioned(
      left: at.dx - r,
      top: at.dy - r,
      width: r * 2,
      height: r * 2,
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => setState(() {
            final dp = _deltaToPhys(d.delta);
            if (which == 1) {
              _p1 = _clampPhys(_p1 + dp);
              if (widget.mode == AutoClickPickMode.point) _p2 = _p1;
            } else {
              _p2 = _clampPhys(_p2 + dp);
            }
          }),
          child: CustomPaint(
            painter: _TargetPainter(color: color, label: '$which'),
          ),
        ),
      ),
    );
  }

  /// 範囲の角の掴み (1 = 左上 / 2 = 右下)。
  Widget _cornerHandle(Offset at, int which) {
    const r = 11.0;
    final color = which == 1 ? _c1 : _c2;
    final label = _t(which == 1 ? 'palette.topLeft' : 'palette.bottomRight');
    return Positioned(
      left: at.dx - r,
      top: at.dy - r,
      child: MouseRegion(
        cursor: which == 1
            ? SystemMouseCursors.resizeUpLeft
            : SystemMouseCursors.resizeDownRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => setState(() {
            final dp = _deltaToPhys(d.delta);
            if (which == 1) {
              _p1 = _clampPhys(_p1 + dp);
            } else {
              _p2 = _clampPhys(_p2 + dp);
            }
          }),
          onPanEnd: (_) => setState(_normalizeRect),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: r * 2,
              height: r * 2,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 4),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(label,
                  style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
    );
  }

  String _xy(Offset p) => '(${p.dx.round()}, ${p.dy.round()})';

  /// 上に浮かせる操作の札 (説明 / 座標 / 決定・やめる)。
  Widget _panel(BoxConstraints c) {
    const panelW = 430.0;
    final double left = ((c.maxWidth - panelW) / 2 + _panelShift.dx)
        .clamp(0.0, math.max(0.0, c.maxWidth - panelW))
        .toDouble();
    final double top = (16 + _panelShift.dy)
        .clamp(0.0, math.max(0.0, c.maxHeight - 60))
        .toDouble();
    final String hint;
    final String coords;
    switch (widget.mode) {
      case AutoClickPickMode.point:
        hint = _t('palette.pickerHintPoint');
        coords = '${_t('palette.point')} ${_xy(_p1)}';
        break;
      case AutoClickPickMode.line:
        hint = _t('palette.pickerHintLine');
        coords = '1 ${_t('palette.startPoint')} ${_xy(_p1)}   →   '
            '2 ${_t('palette.endPoint')} ${_xy(_p2)}';
        break;
      case AutoClickPickMode.rect:
        final a = Offset(math.min(_p1.dx, _p2.dx), math.min(_p1.dy, _p2.dy));
        final b = Offset(math.max(_p1.dx, _p2.dx), math.max(_p1.dy, _p2.dy));
        hint = _t('palette.pickerHintRect');
        coords = '${_t('palette.topLeft')} ${_xy(a)}   '
            '${_t('palette.bottomRight')} ${_xy(b)}   '
            '${(b.dx - a.dx).round()} x ${(b.dy - a.dy).round()}';
        break;
    }
    return Positioned(
      left: left,
      top: top,
      width: panelW,
      child: Material(
        color: const Color(0xEE1B1B2A),
        elevation: 8,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                // 札そのものを掴んで退ける (印と重なった時用)。
                MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) =>
                        setState(() => _panelShift += d.delta),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.drag_indicator_rounded,
                          color: Colors.white38, size: 18),
                    ),
                  ),
                ),
                Icon(widget.icon, color: _c1, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700)),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 2),
                child: Text(hint,
                    style: const TextStyle(
                        color: Colors.white60, fontSize: 11.5, height: 1.4)),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 6),
                child: Text(coords,
                    style: const TextStyle(
                        color: Color(0xFF9CCC65),
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: _cancel,
                  child: Text('${_t('btn.cancel')} (Esc)',
                      style: const TextStyle(color: Colors.white60)),
                ),
                const SizedBox(width: 6),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: _c1, foregroundColor: Colors.black87),
                  icon: const Icon(Icons.check_rounded, size: 17),
                  label: Text('${_t('palette.pickerOk')} (Enter)'),
                  onPressed: _confirm,
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// 丸い的 (外の輪 + 十字 + 番号)。 十字の真ん中が押す所。
class _TargetPainter extends CustomPainter {
  _TargetPainter({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 2;
    canvas.drawCircle(c, r, Paint()..color = color.withValues(alpha: 0.28));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Colors.white);
    canvas.drawCircle(
        c,
        r - 3,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color);
    final cross = Paint()
      ..strokeWidth = 1.5
      ..color = Colors.white;
    canvas.drawLine(c - Offset(r * 0.55, 0), c + Offset(r * 0.55, 0), cross);
    canvas.drawLine(c - Offset(0, r * 0.55), c + Offset(0, r * 0.55), cross);
    canvas.drawCircle(c, 2, Paint()..color = color);
    // 番号は右上の小さな札に (真ん中を隠さない)。
    final tp = TextPainter(
      text: TextSpan(
          text: label,
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    )..layout();
    final badge = Offset(c.dx + r * 0.62, c.dy - r * 0.62);
    canvas.drawCircle(badge, 8.5, Paint()..color = color);
    tp.paint(canvas, badge - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_TargetPainter old) =>
      old.color != color || old.label != label;
}

/// 範囲の外を暗くする / スワイプの矢印を引く。
class _PickPainter extends CustomPainter {
  _PickPainter({
    required this.mode,
    required this.a,
    required this.b,
    required this.img,
  });

  final AutoClickPickMode mode;
  final Offset a;
  final Offset b;
  final Rect img;

  @override
  void paint(Canvas canvas, Size size) {
    switch (mode) {
      case AutoClickPickMode.point:
        return;
      case AutoClickPickMode.line:
        final v = b - a;
        final len = v.distance;
        if (len < 4) return;
        final line = Paint()
          ..color = const Color(0xFFFFFFFF)
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round;
        final inner = Paint()
          ..color = const Color(0xFF4DD0E1)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(a, b, line);
        canvas.drawLine(a, b, inner);
        // 終点の手前に矢じり (的に隠れないよう少し手前)。
        final u = v / len;
        final tip = b - u * 26;
        final n = Offset(-u.dy, u.dx);
        final head = Path()
          ..moveTo(tip.dx + u.dx * 10, tip.dy + u.dy * 10)
          ..lineTo(tip.dx - u.dx * 6 + n.dx * 8, tip.dy - u.dy * 6 + n.dy * 8)
          ..lineTo(tip.dx - u.dx * 6 - n.dx * 8, tip.dy - u.dy * 6 - n.dy * 8)
          ..close();
        canvas.drawPath(head, Paint()..color = const Color(0xFF4DD0E1));
        return;
      case AutoClickPickMode.rect:
        final r = Rect.fromPoints(a, b);
        final dim = Paint()..color = Colors.black.withValues(alpha: 0.45);
        final outer = Path()..addRect(img);
        final hole = Path()..addRect(r);
        canvas.drawPath(
            Path.combine(PathOperation.difference, outer, hole), dim);
        canvas.drawRect(
            r,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = const Color(0xFF4DD0E1));
        return;
    }
  }

  @override
  bool shouldRepaint(_PickPainter old) =>
      old.a != a || old.b != b || old.img != img || old.mode != mode;
}
