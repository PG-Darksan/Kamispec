// ─── PDF 図形・線 描き込みレイヤー (= ユーザー要望: PDF 上に図形や線を
//     書き込める機能) ─────────────────────────────────────────────────
//
// SfPdfViewer を包んで使う。 [active] が true の間、 ビューアの上に透明な
// 描画オーバーレイを重ね、 ドラッグで ペン / 直線 / 矢印 / 四角 / 楕円 を
// 描けるようにする。 「✓ (保存して終了)」 でセッション中の描画をまとめて
// PDF ファイル本体へ焼き込む (= page.graphics で本文コンテンツに描くので、
// ビューアのネイティブ描画 (PDFium / PdfRenderer は注釈を描画しない) でも
// 確実に表示される。 既存の _PdfInkWriter (テキスト / チェック書き込み) と
// 同じ方式)。 保存後はホスト側が reload tick を進めてビューアを読み直す。
//
// 座標変換: syncfusion 内部の PdfPageView (1 ページ = 1 widget) を
// Element ツリーから探し、 その RenderBox の globalToLocal でページ内
// ローカル座標を得て、 `元ページ高さ(pt) / 表示高さ` (= syncfusion 自身の
// _heightPercentage と同じ式) を掛けて PDF ページ座標 (pt、 左上原点) に
// 変換する。 ズーム (InteractiveViewer の Transform) は RenderBox の変換
// チェーンに含まれるので追加の補正は不要。 内部クラス名 ('PdfPageView') と
// dynamic アクセスに依存するため、 syncfusion のバージョン更新時は要確認
// (= _addHighlightForSelection と同じ「version-drift via dynamic」 方針)。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sfpdf;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart' as sf_pdf;

/// 描画ツール。 hand はスクロール用 (= オーバーレイを素通しにする)。
enum PdfDrawTool { hand, pen, line, arrow, rect, ellipse }

/// 1 本の描画 (ページ番号 + PDF ページ座標 pt の点列)。
class PdfDrawStroke {
  final int pageNumber; // 1 始まり
  final PdfDrawTool tool;
  final List<Offset> points; // ページ座標 (pt、 左上原点)
  final Color color;
  final double width; // 線の太さ (pt)

  PdfDrawStroke({
    required this.pageNumber,
    required this.tool,
    required this.points,
    required this.color,
    required this.width,
  });
}

/// ページ 1 枚分の画面上の配置情報。
class _PageGeom {
  final int pageNumber; // 1 始まり
  final RenderBox box;
  final Size contentSize; // ページ表示部分の大きさ (spacing を含まない)
  final double heightPercentage; // 元ページ pt / 表示 px

  _PageGeom(this.pageNumber, this.box, this.contentSize, this.heightPercentage);
}

class PdfDrawLayer extends StatefulWidget {
  /// 包む対象 (SfPdfViewer を含むサブツリー)。
  final Widget child;

  /// 描き込みモードが ON か (ホスト側の状態)。
  final bool active;

  /// 描き込み先のローカル PDF パス。 null なら描き込み不可 (child 素通し)。
  final String? filePath;

  /// スクロール転送用 (ペンツール中のホイール)。 無くても動く。
  final sf_pdf.PdfViewerController? controller;

  /// 翻訳 (provider.t)。
  final String Function(String key) tr;

  /// 「✓ 保存して終了」 でモードを閉じてもらう。
  final VoidCallback onExit;

  /// ファイル保存に成功した後に呼ぶ (= ホストは reload tick を進める)。
  final VoidCallback onSaved;

  const PdfDrawLayer({
    super.key,
    required this.child,
    required this.active,
    required this.filePath,
    required this.tr,
    required this.onExit,
    required this.onSaved,
    this.controller,
  });

  @override
  State<PdfDrawLayer> createState() => _PdfDrawLayerState();
}

class _PdfDrawLayerState extends State<PdfDrawLayer> {
  final GlobalKey _childKey = GlobalKey();
  final GlobalKey _overlayKey = GlobalKey();

  PdfDrawTool _tool = PdfDrawTool.pen;
  Color _color = const Color(0xFFE53935);
  double _width = 2.5;

  final List<PdfDrawStroke> _strokes = [];
  PdfDrawStroke? _current;
  _PageGeom? _currentGeom;
  int? _activePointer;
  bool _saving = false;
  bool _committed = false;

  /// ハンドツールやホイールでスクロールした時にも描画位置を追従させる
  /// ための軽い再描画タイマー (モード ON の間だけ)。
  Timer? _repaintTimer;

  static const List<Color> _palette = [
    Color(0xFFE53935), // 赤
    Color(0xFFFB8C00), // 橙
    Color(0xFF43A047), // 緑
    Color(0xFF1E88E5), // 青
    Color(0xFF8E24AA), // 紫
    Color(0xFF000000), // 黒
  ];
  static const List<double> _widths = [1.5, 2.5, 5.0];

  @override
  void didUpdateWidget(covariant PdfDrawLayer old) {
    super.didUpdateWidget(old);
    if (old.active && !widget.active) {
      // ホスト側がモードを閉じた → 未保存の描画は自動で保存する
      // (= 描いたものが黙って消えないように)。
      unawaited(_commit(exitAfter: false));
    }
    _syncTimer();
  }

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  void _syncTimer() {
    if (widget.active && _repaintTimer == null) {
      _repaintTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
        if (mounted && (_strokes.isNotEmpty || _current != null)) {
          setState(() {});
        }
      });
    } else if (!widget.active) {
      _repaintTimer?.cancel();
      _repaintTimer = null;
    }
  }

  @override
  void dispose() {
    _repaintTimer?.cancel();
    // 閉じられた時も未保存分を書き込む (リロード通知は出来ないが、 次に
    // 開いた時には反映されている)。
    if (_strokes.isNotEmpty && !_saving && !_committed) {
      final path = widget.filePath;
      final pending = List<PdfDrawStroke>.from(_strokes);
      if (path != null) {
        unawaited(writeStrokesToPdf(path, pending));
      }
    }
    super.dispose();
  }

  // ─── ページ配置の収集 (Element ツリー探索) ──────────────────────────
  List<_PageGeom> _collectPageGeoms() {
    final result = <_PageGeom>[];
    final ctx = _childKey.currentContext;
    if (ctx == null) return result;
    void visit(Element e) {
      final w = e.widget;
      if (w.runtimeType.toString() == 'PdfPageView') {
        try {
          final rb = e.renderObject;
          if (rb is RenderBox && rb.attached && rb.hasSize) {
            final dyn = w as dynamic;
            final int pageIndex = dyn.pageIndex as int; // 0 始まり
            final double w0 = (dyn.width as num).toDouble();
            final double h0 = (dyn.height as num).toDouble();
            double hp = 1.0;
            final doc = dyn.pdfDocument;
            if (doc is sfpdf.PdfDocument &&
                pageIndex >= 0 &&
                pageIndex < doc.pages.count &&
                h0 > 0) {
              final pg = doc.pages[pageIndex];
              final rot = pg.rotation;
              final bool rot90 =
                  rot == sfpdf.PdfPageRotateAngle.rotateAngle90 ||
                      rot == sfpdf.PdfPageRotateAngle.rotateAngle270;
              final orig = pg.size;
              hp = (rot90 ? orig.width : orig.height) / h0;
            }
            if (hp > 0 && w0 > 0 && h0 > 0) {
              result.add(_PageGeom(pageIndex + 1, rb, Size(w0, h0), hp));
            }
          }
        } catch (_) {
          // 内部構造が変わっていても落とさない (描けないだけ)。
        }
        return; // ページの中まで潜る必要はない
      }
      e.visitChildElements(visit);
    }

    (ctx as Element).visitChildElements(visit);
    return result;
  }

  /// グローバル座標 → (ページ, ページ座標 pt)。 ページ外なら null。
  (_PageGeom, Offset)? _pageAt(Offset globalPos) {
    for (final g in _collectPageGeoms()) {
      try {
        final local = g.box.globalToLocal(globalPos);
        if (local.dx >= -4 &&
            local.dy >= -4 &&
            local.dx <= g.contentSize.width + 4 &&
            local.dy <= g.contentSize.height + 4) {
          final clamped = Offset(
            local.dx.clamp(0.0, g.contentSize.width),
            local.dy.clamp(0.0, g.contentSize.height),
          );
          return (g, clamped * g.heightPercentage);
        }
      } catch (_) {}
    }
    return null;
  }

  // ─── 入力処理 ───────────────────────────────────────────────────────
  void _onPointerDown(PointerDownEvent e) {
    if (_activePointer != null || _saving) return;
    final hit = _pageAt(e.position);
    if (hit == null) return;
    final (geom, pt) = hit;
    _activePointer = e.pointer;
    _currentGeom = geom;
    setState(() {
      _current = PdfDrawStroke(
        pageNumber: geom.pageNumber,
        tool: _tool,
        points: [pt, pt],
        color: _color,
        width: _width,
      );
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer || _current == null) return;
    final geom = _currentGeom;
    if (geom == null) return;
    Offset pt;
    try {
      final local = geom.box.globalToLocal(e.position);
      pt = Offset(
            local.dx.clamp(0.0, geom.contentSize.width),
            local.dy.clamp(0.0, geom.contentSize.height),
          ) *
          geom.heightPercentage;
    } catch (_) {
      return;
    }
    setState(() {
      final cur = _current!;
      if (cur.tool == PdfDrawTool.pen) {
        // 細かすぎる点は間引く (pt 換算でおよそ 0.7pt 以上動いた時だけ)。
        if ((pt - cur.points.last).distance >= 0.7) cur.points.add(pt);
      } else {
        cur.points[cur.points.length - 1] = pt;
      }
    });
  }

  void _onPointerUp(PointerEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    _currentGeom = null;
    final cur = _current;
    if (cur == null) return;
    setState(() {
      _current = null;
      // 動きがほぼ無い図形はゴミになるので捨てる (ペンの点は残す)。
      final span = (cur.points.last - cur.points.first).distance;
      if (cur.tool == PdfDrawTool.pen || span >= 1.0) {
        _strokes.add(cur);
      }
    });
  }

  void _onPointerSignal(PointerSignalEvent e) {
    // ペン等のツール中でもホイールでスクロールできるようにする。
    if (e is! PointerScrollEvent) return;
    final c = widget.controller;
    if (c == null) return;
    try {
      final o = c.scrollOffset;
      c.jumpTo(
        xOffset: math.max(0, o.dx + e.scrollDelta.dx),
        yOffset: math.max(0, o.dy + e.scrollDelta.dy),
      );
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // ─── 保存 ───────────────────────────────────────────────────────────
  Future<void> _commit({bool exitAfter = true}) async {
    final path = widget.filePath;
    if (_saving) return;
    if (path == null || _strokes.isEmpty) {
      if (exitAfter) widget.onExit();
      return;
    }
    setState(() => _saving = true);
    final pending = List<PdfDrawStroke>.from(_strokes);
    final ok = await writeStrokesToPdf(path, pending);
    if (!mounted) {
      _saving = false;
      _committed = ok;
      return;
    }
    setState(() {
      _saving = false;
      if (ok) {
        _committed = true;
        _strokes.clear();
      }
    });
    if (ok) {
      widget.onSaved();
      if (exitAfter) widget.onExit();
      _committed = false; // 次のセッションに備えてリセット
    } else {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(SnackBar(
        content: Text(widget.tr('pdf.writeFailed')),
        backgroundColor: const Color(0xFFE57373),
      ));
    }
  }

  /// 図形・線を PDF ファイル本体へ焼き込む (静的処理)。
  /// 初回のみアプリサポート領域へ元ファイルのバックアップを取る。
  static Future<bool> writeStrokesToPdf(
      String path, List<PdfDrawStroke> strokes) async {
    try {
      final f = File(path);
      final bytes = await f.readAsBytes();
      // ── 一度だけバックアップ (描き込みは元に戻せないため) ──
      try {
        final dir = await getApplicationSupportDirectory();
        final bdir = Directory('${dir.path}${Platform.pathSeparator}pdf_draw_backups');
        if (!bdir.existsSync()) bdir.createSync(recursive: true);
        final bak = File(
            '${bdir.path}${Platform.pathSeparator}${path.hashCode.toRadixString(16)}.pdf');
        if (!bak.existsSync()) await bak.writeAsBytes(bytes);
      } catch (_) {}
      final doc = sfpdf.PdfDocument(inputBytes: bytes);
      for (final s in strokes) {
        if (s.pageNumber < 1 || s.pageNumber > doc.pages.count) continue;
        if (s.points.length < 2) continue;
        final page = doc.pages[s.pageNumber - 1];
        final g = page.graphics;
        final pen = sfpdf.PdfPen(
          sfpdf.PdfColor((s.color.r * 255).round(), (s.color.g * 255).round(),
              (s.color.b * 255).round()),
          width: s.width,
          lineCap: sfpdf.PdfLineCap.round,
          lineJoin: sfpdf.PdfLineJoin.round,
        );
        final p1 = s.points.first;
        final p2 = s.points.last;
        switch (s.tool) {
          case PdfDrawTool.pen:
            for (var i = 0; i + 1 < s.points.length; i++) {
              g.drawLine(pen, s.points[i], s.points[i + 1]);
            }
            break;
          case PdfDrawTool.line:
            g.drawLine(pen, p1, p2);
            break;
          case PdfDrawTool.arrow:
            g.drawLine(pen, p1, p2);
            final d = p2 - p1;
            if (d.distance > 0.5) {
              final ang = math.atan2(d.dy, d.dx);
              final hl = math.max(7.0, s.width * 3.5);
              const spread = 0.48;
              final h1 = p2 -
                  Offset(math.cos(ang - spread), math.sin(ang - spread)) * hl;
              final h2 = p2 -
                  Offset(math.cos(ang + spread), math.sin(ang + spread)) * hl;
              g.drawLine(pen, p2, h1);
              g.drawLine(pen, p2, h2);
            }
            break;
          case PdfDrawTool.rect:
            g.drawRectangle(pen: pen, bounds: Rect.fromPoints(p1, p2));
            break;
          case PdfDrawTool.ellipse:
            g.drawEllipse(Rect.fromPoints(p1, p2), pen: pen);
            break;
          case PdfDrawTool.hand:
            break;
        }
      }
      final out = await doc.save();
      doc.dispose();
      await f.writeAsBytes(out, flush: true);
      return true;
    } catch (e) {
      debugPrint('PDF 図形書き込み失敗: $e');
      return false;
    }
  }

  // ─── UI ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _childKey, child: widget.child);
    if (!widget.active || widget.filePath == null) return child;
    final passThrough = _tool == PdfDrawTool.hand;
    return Stack(children: [
      Positioned.fill(child: child),
      // ── 描画オーバーレイ ──
      Positioned.fill(
        child: IgnorePointer(
          ignoring: passThrough,
          child: Listener(
            key: _overlayKey,
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerUp,
            onPointerSignal: _onPointerSignal,
            child: MouseRegion(
              cursor: SystemMouseCursors.precise,
              child: ClipRect(
                child: CustomPaint(
                  painter: _PdfDrawPainter(
                    strokes: _strokes,
                    current: _current,
                    geomsGetter: _collectPageGeoms,
                    overlayBoxGetter: () => _overlayKey.currentContext
                        ?.findRenderObject() as RenderBox?,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ),
      // ── ツールバー ──
      Positioned(
        top: 6,
        left: 6,
        right: 6,
        child: Align(
          alignment: Alignment.topCenter,
          child: _buildToolbar(context),
        ),
      ),
    ]);
  }

  Widget _buildToolbar(BuildContext context) {
    Widget toolBtn(PdfDrawTool t, IconData ic, String tipKey) {
      final on = _tool == t;
      return Tooltip(
        message: widget.tr(tipKey),
        child: InkWell(
          onTap: () => setState(() => _tool = t),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: on ? const Color(0xFF6C63FF) : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(ic, size: 18, color: on ? Colors.white : Colors.white70),
          ),
        ),
      );
    }

    Widget colorBtn(Color c) {
      final on = _color.toARGB32() == c.toARGB32();
      return InkWell(
        onTap: () => setState(() => _color = c),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 22,
          height: 22,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(
                color: on ? Colors.white : Colors.white30, width: on ? 2.5 : 1),
          ),
        ),
      );
    }

    Widget widthBtn() {
      final idx = _widths.indexOf(_width);
      return Tooltip(
        message: widget.tr('pdfdraw.width'),
        child: InkWell(
          onTap: () => setState(
              () => _width = _widths[(idx + 1) % _widths.length]),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            child: Container(
              width: 16,
              height: (_width * 1.6).clamp(2.0, 10.0),
              decoration: BoxDecoration(
                color: Colors.white70,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      );
    }

    Widget actBtn(IconData ic, String tipKey, VoidCallback? onTap,
        {Color color = Colors.white70}) {
      return Tooltip(
        message: widget.tr(tipKey),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(ic, size: 18, color: onTap == null ? Colors.white24 : color),
          ),
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xE61E1E32),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 2,
          runSpacing: 2,
          children: [
            // 「移動 (スクロール)」 は外した (= ユーザー要望: 使い所が
            //   無い)。 表示の上下移動はマウスのホイールでできる。
            toolBtn(PdfDrawTool.pen, Icons.gesture_rounded, 'pdfdraw.pen'),
            toolBtn(PdfDrawTool.line, Icons.horizontal_rule_rounded, 'pdfdraw.line'),
            toolBtn(PdfDrawTool.arrow, Icons.north_east_rounded, 'pdfdraw.arrow'),
            toolBtn(PdfDrawTool.rect, Icons.crop_square_rounded, 'pdfdraw.rect'),
            toolBtn(PdfDrawTool.ellipse, Icons.circle_outlined, 'pdfdraw.ellipse'),
            Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: Colors.white24),
            for (final c in _palette) colorBtn(c),
            Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: Colors.white24),
            widthBtn(),
            actBtn(Icons.undo_rounded, 'pdfdraw.undo',
                _strokes.isEmpty || _saving
                    ? null
                    : () => setState(() => _strokes.removeLast())),
            actBtn(Icons.delete_outline_rounded, 'pdfdraw.clear',
                _strokes.isEmpty || _saving
                    ? null
                    : () => setState(_strokes.clear)),
            _saving
                ? const SizedBox(
                    width: 30,
                    height: 30,
                    child: Padding(
                      padding: EdgeInsets.all(7),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Color(0xFF5FD3B2)),
                    ),
                  )
                : actBtn(Icons.check_rounded, 'pdfdraw.finish',
                    () => unawaited(_commit()),
                    color: const Color(0xFF5FD3B2)),
          ],
        ),
      ),
    );
  }
}

class _PdfDrawPainter extends CustomPainter {
  final List<PdfDrawStroke> strokes;
  final PdfDrawStroke? current;
  final List<_PageGeom> Function() geomsGetter;
  final RenderBox? Function() overlayBoxGetter;

  _PdfDrawPainter({
    required this.strokes,
    required this.current,
    required this.geomsGetter,
    required this.overlayBoxGetter,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = overlayBoxGetter();
    if (overlay == null || !overlay.attached) return;
    final geoms = geomsGetter();
    if (geoms.isEmpty) return;
    final byPage = <int, _PageGeom>{};
    for (final g in geoms) {
      byPage[g.pageNumber] = g;
    }

    void draw(PdfDrawStroke s) {
      final g = byPage[s.pageNumber];
      if (g == null || s.points.length < 2) return;
      Offset toOverlay(Offset pagePt) {
        final local = pagePt / g.heightPercentage;
        return overlay.globalToLocal(g.box.localToGlobal(local));
      }

      // 画面上での線の太さ (ページ pt → 画面 px)。
      double pxScale;
      try {
        final a = g.box.localToGlobal(Offset.zero);
        final b = g.box.localToGlobal(const Offset(0, 10));
        pxScale = ((b - a).distance / 10.0) / g.heightPercentage;
      } catch (_) {
        pxScale = 1.0 / g.heightPercentage;
      }
      final paint = Paint()
        ..color = s.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = (s.width * pxScale).clamp(0.6, 40.0)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final p1 = toOverlay(s.points.first);
      final p2 = toOverlay(s.points.last);
      switch (s.tool) {
        case PdfDrawTool.pen:
          final path = Path()..moveTo(p1.dx, p1.dy);
          for (var i = 1; i < s.points.length; i++) {
            final o = toOverlay(s.points[i]);
            path.lineTo(o.dx, o.dy);
          }
          canvas.drawPath(path, paint);
          break;
        case PdfDrawTool.line:
          canvas.drawLine(p1, p2, paint);
          break;
        case PdfDrawTool.arrow:
          canvas.drawLine(p1, p2, paint);
          final d = p2 - p1;
          if (d.distance > 0.5) {
            final ang = math.atan2(d.dy, d.dx);
            final hl = math.max(7.0, s.width * 3.5) * pxScale;
            const spread = 0.48;
            canvas.drawLine(
                p2,
                p2 -
                    Offset(math.cos(ang - spread), math.sin(ang - spread)) * hl,
                paint);
            canvas.drawLine(
                p2,
                p2 -
                    Offset(math.cos(ang + spread), math.sin(ang + spread)) * hl,
                paint);
          }
          break;
        case PdfDrawTool.rect:
          canvas.drawRect(Rect.fromPoints(p1, p2), paint);
          break;
        case PdfDrawTool.ellipse:
          canvas.drawOval(Rect.fromPoints(p1, p2), paint);
          break;
        case PdfDrawTool.hand:
          break;
      }
    }

    for (final s in strokes) {
      draw(s);
    }
    final cur = current;
    if (cur != null) draw(cur);
  }

  @override
  bool shouldRepaint(covariant _PdfDrawPainter old) => true;
}
