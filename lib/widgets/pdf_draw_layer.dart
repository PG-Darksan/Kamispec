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
import 'dart:ui' show FontFeature;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sfpdf;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart' as sf_pdf;

/// 描画ツール。 hand はスクロール用 (= オーバーレイを素通しにする)。
enum PdfDrawTool {
  hand,
  pen,
  line,
  arrow,
  rect,
  ellipse,
  /// なぞった所の描き込みを消す (= ユーザー要望)。 まだ保存していない線が
  /// 対象。 保存済みの線は PDF に焼き付いているので消せない。
  eraser,

  /// チェック (✓) を置く (= ユーザー要望: 簡単に出せるように)。
  check,
}

/// 描き込みを PDF へ焼き込み終えた事を知らせる (値は「パス + 時刻」)。
///
/// widget の onSaved と違い、 ビューアを閉じた後の自動保存でも必ず飛ぶので、
/// ホスト (マップ画面) はこれを見てノードのサムネイルを作り直す
/// (= ユーザー報告: PDF に手書きしてもサムネイルが古いまま)。
final ValueNotifier<String> pdfDrawBurnedNotifier = ValueNotifier<String>('');

/// 描き込みを PDF ファイル本体へ焼き込む (別 isolate 用のエントリ)。
///
/// [msg] は `{path, backup, strokes:[{page,tool,color,width,pts:[x,y,...]}]}`。
/// compute で渡すため、 プリミティブだけで構成すること。
Future<bool> burnPdfStrokes(Map<String, Object?> msg) async {
  try {
    final path = msg['path'] as String;
    final backup = msg['backup'] as String?;
    final raw = (msg['strokes'] as List).cast<Map<String, Object?>>();
    final f = File(path);
    final bytes = await f.readAsBytes();
    // ── 一度だけバックアップ (描き込みは元に戻せないため) ──
    if (backup != null) {
      try {
        final bak = File(backup);
        if (!bak.existsSync()) await bak.writeAsBytes(bytes);
      } catch (_) {}
    }
    final doc = sfpdf.PdfDocument(inputBytes: bytes);
    for (final m in raw) {
      final pageNumber = m['page'] as int;
      if (pageNumber < 1 || pageNumber > doc.pages.count) continue;
      final flat = (m['pts'] as List).cast<num>();
      if (flat.length < 4) continue;
      final points = <Offset>[
        for (var i = 0; i + 1 < flat.length; i += 2)
          Offset(flat[i].toDouble(), flat[i + 1].toDouble()),
      ];
      final tool = PdfDrawTool.values[(m['tool'] as int)
          .clamp(0, PdfDrawTool.values.length - 1)];
      final argb = m['color'] as int;
      final width = (m['width'] as num).toDouble();
      final page = doc.pages[pageNumber - 1];
      final g = page.graphics;
      final pen = sfpdf.PdfPen(
        sfpdf.PdfColor((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF),
        width: width,
        lineCap: sfpdf.PdfLineCap.round,
        lineJoin: sfpdf.PdfLineJoin.round,
      );
      final p1 = points.first;
      final p2 = points.last;
      switch (tool) {
        case PdfDrawTool.pen:
          for (var i = 0; i + 1 < points.length; i++) {
            g.drawLine(pen, points[i], points[i + 1]);
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
            final hl = math.max(7.0, width * 3.5);
            const spread = 0.48;
            final h1 =
                p2 - Offset(math.cos(ang - spread), math.sin(ang - spread)) * hl;
            final h2 =
                p2 - Offset(math.cos(ang + spread), math.sin(ang + spread)) * hl;
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
        case PdfDrawTool.eraser:
        case PdfDrawTool.check:
          // 消しゴムは線を残さない。 チェックはペンの線として積むので、
          // ここへは来ない。
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

  /// 消しゴムの大きさ (pt)。 ペンとは別に持つ (= ユーザー要望)。
  double _eraserSize = 14.0;

  /// 消しゴムの「今の大きさの丸」 をページの上に出すための位置 (グローバル
  /// 座標)。 = ユーザー要望: 消しゴムの太さが見て分からない。 実際に消える
  /// 範囲をそのままの大きさで見せる。
  Offset? _cursorGlobal;

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
  /// 消しゴムの丸を指/カーソルに追従させる。
  void _trackCursor(Offset? globalPos) {
    if (_tool != PdfDrawTool.eraser) {
      if (_cursorGlobal != null && mounted) {
        setState(() => _cursorGlobal = null);
      }
      return;
    }
    if (_cursorGlobal == globalPos) return;
    if (mounted) setState(() => _cursorGlobal = globalPos);
  }

  void _onPointerDown(PointerDownEvent e) {
    _trackCursor(e.position);
    if (_activePointer != null || _saving) return;
    final hit = _pageAt(e.position);
    if (hit == null) return;
    final (geom, pt) = hit;
    _activePointer = e.pointer;
    _currentGeom = geom;
    // ── 消しゴム: なぞった所の線を消す (= ユーザー要望) ──
    if (_tool == PdfDrawTool.eraser) {
      _eraseAt(geom.pageNumber, pt);
      return;
    }
    // ── チェック: 押した所に ✓ を置く (= ユーザー要望) ──
    if (_tool == PdfDrawTool.check) {
      setState(() {
        _strokes.add(_checkStroke(geom.pageNumber, pt));
      });
      _activePointer = null;
      _currentGeom = null;
      return;
    }
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
    _trackCursor(e.position);
    if (e.pointer != _activePointer) return;
    final geom = _currentGeom;
    if (geom == null) return;
    // 消しゴムはなぞり続けている間ずっと消す。
    if (_tool == PdfDrawTool.eraser) {
      try {
        final local = geom.box.globalToLocal(e.position);
        final pt = Offset(
              local.dx.clamp(0.0, geom.contentSize.width),
              local.dy.clamp(0.0, geom.contentSize.height),
            ) *
            geom.heightPercentage;
        _eraseAt(geom.pageNumber, pt);
      } catch (_) {}
      return;
    }
    if (_current == null) return;
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
    // 指を離したら丸も消す (マウスは hover で出続ける)。
    if (e.kind != PointerDeviceKind.mouse) _trackCursor(null);
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

  /// [pt] (ページ座標 pt) の周りにある、 まだ保存していない線を消す。
  ///
  /// 手書きの線は「触れた所だけ」 を切り取り、 残りは前後 2 本に分ける
  /// (= ユーザー要望: 部分的に、 指定した太さで消せるように)。
  /// 直線や四角などの図形は形が崩れるので、 触れたら 1 個ごと消す。
  void _eraseAt(int pageNumber, Offset pt) {
    final r = _eraserSize / 2;
    var changed = false;
    final next = <PdfDrawStroke>[];
    for (final st in _strokes) {
      if (st.pageNumber != pageNumber) {
        next.add(st);
        continue;
      }
      // ── 図形は丸ごと消す ──
      if (st.tool != PdfDrawTool.pen) {
        var hit = false;
        if (st.points.length >= 2) {
          final a = st.points.first;
          final b = st.points.last;
          final ab = b - a;
          final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
          if (len2 > 0) {
            final t = (((pt - a).dx * ab.dx + (pt - a).dy * ab.dy) / len2)
                .clamp(0.0, 1.0);
            final proj = a + Offset(ab.dx * t, ab.dy * t);
            hit = (proj - pt).distance <= r;
          } else {
            hit = (a - pt).distance <= r;
          }
        }
        if (hit) {
          changed = true;
        } else {
          next.add(st);
        }
        continue;
      }
      // ── 手書き: 消しゴムに入った点を落として、 残りを繋ぎ直す ──
      final keep = <List<Offset>>[];
      var run = <Offset>[];
      var touched = false;
      for (final q in st.points) {
        if ((q - pt).distance <= r) {
          touched = true;
          if (run.length >= 2) keep.add(run);
          run = <Offset>[];
        } else {
          run.add(q);
        }
      }
      if (run.length >= 2) keep.add(run);
      if (!touched) {
        next.add(st);
        continue;
      }
      changed = true;
      for (final seg in keep) {
        next.add(PdfDrawStroke(
          pageNumber: st.pageNumber,
          tool: PdfDrawTool.pen,
          points: seg,
          color: st.color,
          width: st.width,
        ));
      }
    }
    if (!changed) return;
    _strokes
      ..clear()
      ..addAll(next);
    if (mounted) setState(() {});
  }

  /// チェック (✓) 1 個ぶんの線 (= ユーザー要望: 簡単に出せるように)。
  /// 太さに合わせて大きさも変える。
  PdfDrawStroke _checkStroke(int pageNumber, Offset at) {
    final k = (_width / 2.5).clamp(0.6, 6.0);
    return PdfDrawStroke(
      pageNumber: pageNumber,
      tool: PdfDrawTool.pen,
      points: [
        at + Offset(-7 * k, 0),
        at + Offset(-2 * k, 6 * k),
        at + Offset(9 * k, -8 * k),
      ],
      color: _color,
      width: _width,
    );
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
  ///
  /// ★ 実際の書き込みは別 isolate (compute) で行う。 PdfDocument の解析と
  ///   save() は同期的に CPU を使い切るので、 UI isolate でやると画面が
  ///   固まる (= ユーザー報告: 「閉じるとフリーズする」)。 ビューアを閉じる
  ///   時の自動保存もここを通るため、 必ず逃がしておく。
  static Future<bool> writeStrokesToPdf(
      String path, List<PdfDrawStroke> strokes) async {
    if (strokes.isEmpty) return true;
    // バックアップ先はプラグイン (path_provider) 経由なので UI isolate 側で
    // 先に解決してから渡す (別 isolate ではプラグインを呼べない)。
    String? backupPath;
    try {
      final dir = await getApplicationSupportDirectory();
      final sep = Platform.pathSeparator;
      final bdir = Directory('${dir.path}${sep}pdf_draw_backups');
      if (!bdir.existsSync()) bdir.createSync(recursive: true);
      backupPath = '${bdir.path}$sep${path.hashCode.toRadixString(16)}.pdf';
    } catch (_) {}
    final msg = <String, Object?>{
      'path': path,
      'backup': backupPath,
      'strokes': [
        for (final st in strokes)
          <String, Object?>{
            'page': st.pageNumber,
            'tool': st.tool.index,
            'color': st.color.toARGB32(),
            'width': st.width,
            'pts': <double>[
              for (final pt in st.points) ...[pt.dx, pt.dy]
            ],
          },
      ],
    };
    bool ok;
    try {
      ok = await compute(burnPdfStrokes, msg);
    } catch (e) {
      debugPrint('PDF 図形書き込み (isolate) 失敗: $e');
      // isolate が使えない環境では同じ処理をその場で走らせる。
      try {
        ok = await burnPdfStrokes(msg);
      } catch (_) {
        ok = false;
      }
    }
    if (ok) {
      // 焼き込み完了を知らせる (= ホストがサムネイルを作り直す)。
      // widget の onSaved と違い、 閉じた後の自動保存でも必ず届く。
      pdfDrawBurnedNotifier.value =
          '$path ${DateTime.now().microsecondsSinceEpoch}';
    }
    return ok;
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
            onPointerHover: (e) => _trackCursor(e.position),
            child: MouseRegion(
              // 消しゴム中は自前の丸だけを出す (= 大きさがそのまま見える)。
              cursor: _tool == PdfDrawTool.eraser
                  ? SystemMouseCursors.none
                  : SystemMouseCursors.precise,
              onExit: (_) => _trackCursor(null),
              child: ClipRect(
                child: CustomPaint(
                  painter: _PdfDrawPainter(
                    strokes: _strokes,
                    current: _current,
                    eraserCursor:
                        _tool == PdfDrawTool.eraser ? _cursorGlobal : null,
                    eraserSize: _eraserSize,
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
    // [ic] が null の時は消しゴムの絵を自前で描く (Material に消しゴムの
    // アイコンが無く、 魔法の杖 (auto_fix) では何のボタンか伝わらないため)。
    Widget toolBtn(PdfDrawTool t, IconData? ic, String tipKey) {
      final on = _tool == t;
      final fg = on ? Colors.white : Colors.white70;
      return Tooltip(
        message: widget.tr(tipKey),
        child: InkWell(
          onTap: () => setState(() => _tool = t),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? const Color(0xFF6C63FF) : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: ic == null
                ? _EraserGlyph(size: 19, color: fg)
                : Icon(ic, size: 18, color: fg),
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

    /// 太さ / 消しゴムの大きさ を「見て分かる」 形で操作する
    /// (= ユーザー要望: 消しゴムの太さの所が分かりにくい。 オレンジの
    ///  アイコンでは何の設定か分からないし、 太さも分からない)。
    ///
    ///   [見本] ──スライダー── [数字 pt]
    ///
    /// 見本はペンなら「その太さの線」、 消しゴムなら「その大きさの丸」 を
    /// そのまま出す。 数字も並べるので、 今いくつなのかが一目で分かる。
    /// ページの上にも同じ大きさの丸が出る (= _PdfDrawPainter)。
    Widget sizeControl() {
      final eraser = _tool == PdfDrawTool.eraser;
      final double cur = eraser ? _eraserSize : _width;
      final double minV = eraser ? 4.0 : 0.5;
      final double maxV = eraser ? 40.0 : 16.0;
      final double v = cur.clamp(minV, maxV).toDouble();
      final Color accent =
          eraser ? const Color(0xFF9FE7FF) : const Color(0xFFB9B4FF);
      // 見本 (入りきらない大きさは枠いっぱいで頭打ち)。
      final double dia = (v * 0.75).clamp(4.0, 24.0).toDouble();
      final double lineH = (v * 1.2).clamp(1.5, 16.0).toDouble();
      return Container(
        height: 30,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          // 何の設定かを示す見出し (消しゴム / ペン)。
          Tooltip(
            message: widget.tr(
                eraser ? 'pdfdraw.eraserSize' : 'pdfdraw.penWidth'),
            child: eraser
                ? const _EraserGlyph(size: 16, color: Color(0xFF9FE7FF))
                : Icon(Icons.brush_rounded, size: 15, color: accent),
          ),
          const SizedBox(width: 6),
          // 見本 (実際の形と大きさ)。
          SizedBox(
            width: 26,
            height: 26,
            child: Center(
              child: eraser
                  ? Container(
                      width: dia,
                      height: dia,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.22),
                        border: Border.all(color: Colors.white, width: 1.2),
                      ),
                    )
                  : Container(
                      width: 22,
                      height: lineH,
                      decoration: BoxDecoration(
                        color: _color,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white24, width: 0.5),
                      ),
                    ),
            ),
          ),
          SizedBox(
            width: 104,
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                activeTrackColor: accent,
                inactiveTrackColor: Colors.white24,
                thumbColor: accent,
                overlayColor: accent.withValues(alpha: 0.18),
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: v,
                min: minV,
                max: maxV,
                // 0.5 刻み (= 細かく選べるように)。
                divisions: ((maxV - minV) * 2).round(),
                onChanged: (nv) => setState(() {
                  if (eraser) {
                    _eraserSize = nv;
                  } else {
                    _width = nv;
                  }
                }),
              ),
            ),
          ),
          const SizedBox(width: 2),
          SizedBox(
            width: 32,
            child: Text(
              v < 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(0),
              textAlign: TextAlign.right,
              style: TextStyle(
                  color: accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ]),
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
            // 消しゴム / チェック (= ユーザー要望)。
            toolBtn(PdfDrawTool.eraser, null, 'pdfdraw.eraser'),
            toolBtn(PdfDrawTool.check, Icons.check_rounded, 'pdfdraw.check'),
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
            sizeControl(),
            actBtn(Icons.undo_rounded, 'pdfdraw.undo',
                _strokes.isEmpty || _saving
                    ? null
                    : () => setState(() => _strokes.removeLast())),
            actBtn(Icons.delete_outline_rounded, 'pdfdraw.clear',
                _strokes.isEmpty || _saving
                    ? null
                    : () => setState(_strokes.clear)),
            // ── 上書き保存 (= ユーザー要望)。 描いたものを PDF に
            //    焼き込むが、 描き込みモードは続けたまま。 ──
            actBtn(
                Icons.save_rounded,
                'pdfdraw.save',
                _strokes.isEmpty || _saving
                    ? null
                    : () => unawaited(_commit(exitAfter: false)),
                color: const Color(0xFF5FD3B2)),
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

  /// 消しゴムの丸を出す位置 (グローバル座標)。 null なら出さない。
  final Offset? eraserCursor;

  /// 消しゴムの大きさ (pt)。
  final double eraserSize;
  final List<_PageGeom> Function() geomsGetter;
  final RenderBox? Function() overlayBoxGetter;

  _PdfDrawPainter({
    required this.strokes,
    required this.current,
    required this.eraserCursor,
    required this.eraserSize,
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
        case PdfDrawTool.eraser:
        case PdfDrawTool.check:

          break;
      }
    }

    for (final s in strokes) {
      draw(s);
    }
    final cur = current;
    if (cur != null) draw(cur);

    // ── 消しゴムの「消える範囲」 をそのままの大きさで出す ──
    //    (= ユーザー要望: 太さが分からない)。 ページの拡大率に合わせるので、
    //    ズームしても実際に消える大きさと一致する。
    final ec = eraserCursor;
    if (ec != null) {
      double px = 1.0;
      for (final g in geoms) {
        try {
          final local = g.box.globalToLocal(ec);
          if (local.dx >= 0 &&
              local.dy >= 0 &&
              local.dx <= g.contentSize.width &&
              local.dy <= g.contentSize.height) {
            final a = g.box.localToGlobal(Offset.zero);
            final b = g.box.localToGlobal(const Offset(0, 10));
            px = ((b - a).distance / 10.0) / g.heightPercentage;
            break;
          }
        } catch (_) {}
      }
      final c = overlay.globalToLocal(ec);
      final r = (eraserSize / 2 * px).clamp(4.0, 600.0).toDouble();
      canvas.drawCircle(
          c, r, Paint()..color = const Color(0x26000000));
      // 白地でも黒地でも見えるよう二重の輪にする。
      canvas.drawCircle(
          c,
          r,
          Paint()
            ..color = const Color(0xCC000000)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0);
      canvas.drawCircle(
          c,
          r > 1.5 ? r - 1.5 : r,
          Paint()
            ..color = const Color(0xEEFFFFFF)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4);
      // 中心の点 (どこが基準か分かるように)。
      canvas.drawCircle(c, 1.6, Paint()..color = const Color(0xCC000000));
    }
  }

  @override
  bool shouldRepaint(covariant _PdfDrawPainter old) => true;
}


/// 消しゴムの絵 (Material に消しゴムのアイコンが無いので自前で描く)。
/// 斜めに倒した本体 + 下側の濃い帯 で「消しゴム」 と分かる形にする。
class _EraserGlyph extends StatelessWidget {
  final double size;
  final Color color;

  const _EraserGlyph({required this.size, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _EraserGlyphPainter(color)),
      );
}

class _EraserGlyphPainter extends CustomPainter {
  final Color color;

  _EraserGlyphPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-math.pi / 4);
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: s * 0.56, height: s * 0.95),
      Radius.circular(s * 0.12),
    );
    canvas.drawRRect(
        body,
        Paint()
          ..color = color.withValues(alpha: 0.28)
          ..style = PaintingStyle.fill);
    canvas.drawRRect(
        body,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.09);
    // 下半分 (実際に紙を擦る側) を濃くする。
    canvas.drawRect(
        Rect.fromLTRB(-s * 0.28, s * 0.1, s * 0.28, s * 0.47),
        Paint()..color = color.withValues(alpha: 0.75));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EraserGlyphPainter old) => old.color != color;
}
