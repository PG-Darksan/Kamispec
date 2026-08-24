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
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// 置いた図形を選んで、 動かす / 消す (= ユーザー要望: PDF の置いた図形を
  /// 選択して操作できるモード)。 まだ保存していない図形が対象
  /// (保存済みは PDF に焼き付いているので触れない)。
  select,

  /// 文字を置く (= ユーザー要望: テキスト入力を行う機能)。 押した所に
  /// 打ち込んだ文字を置く。 保存すると PDF の本文として焼き込まれる。
  text,
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
    // 焼き込みの土台。 指定があればそこを読んで [path] へ書き出す
    // (= 保存済みの線をもう一度動かせるようにするため、 毎回同じ土台から
    //  やり直す)。 無ければ従来どおり書き込み先そのものを読む。
    final base = msg['base'] as String?;
    final raw = (msg['strokes'] as List).cast<Map<String, Object?>>();
    // 日本語を書ける書体 (assets/fonts の NotoSansJP)。 呼ぶ側が読んで渡す
    // (= 別 isolate では rootBundle を使えないため)。 無ければ英数字だけの
    // 標準書体で書く。
    final fontBytes = msg['font'] as List<int>?;
    final f = File(path);
    var src = f;
    if (base != null) {
      final b = File(base);
      if (b.existsSync()) src = b;
    }
    final bytes = await src.readAsBytes();
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
      // ── 文字 (= ユーザー要望: テキスト入力) ──
      if (tool == PdfDrawTool.text) {
        final body = '${m['text'] ?? ''}';
        if (body.isEmpty) continue;
        final fs = (m['fontSize'] as num?)?.toDouble() ?? 25.0;
        sfpdf.PdfFont font;
        if (fontBytes != null && fontBytes.isNotEmpty) {
          font = sfpdf.PdfTrueTypeFont(fontBytes, fs);
        } else {
          font = sfpdf.PdfStandardFont(sfpdf.PdfFontFamily.helvetica, fs);
        }
        g.drawString(
          body,
          font,
          brush: sfpdf.PdfSolidBrush(sfpdf.PdfColor(
              (argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF)),
          bounds: Rect.fromLTWH(points.first.dx, points.first.dy, 0, 0),
        );
        continue;
      }
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
        case PdfDrawTool.select:
        case PdfDrawTool.text:
          // 消しゴムと選択は線を残さない。 チェックはペンの線として積み、
          // 文字は上で書き終えているので、 ここへは来ない。
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

  /// 置いた文字 (tool == text の時だけ)。
  final String? text;

  /// 文字の大きさ (pt)。
  final double fontSize;

  PdfDrawStroke({
    required this.pageNumber,
    required this.tool,
    required this.points,
    required this.color,
    required this.width,
    this.text,
    this.fontSize = 25,
  });

  /// 一部だけ差し替えた複製。
  ///
  /// ★ 作り直す時に項目を手で並べ直すと取りこぼす。 実際、 図形を動かす
  ///   処理が `text` と `fontSize` を書き忘れていたため、 置いた文字を
  ///   ドラッグすると中身が消えて透明になっていた (= ユーザー報告)。
  ///   以後は必ずこれを通す。
  PdfDrawStroke copyWith({
    int? pageNumber,
    PdfDrawTool? tool,
    List<Offset>? points,
    Color? color,
    double? width,
    String? text,
    double? fontSize,
  }) =>
      PdfDrawStroke(
        pageNumber: pageNumber ?? this.pageNumber,
        tool: tool ?? this.tool,
        points: points ?? this.points,
        color: color ?? this.color,
        width: width ?? this.width,
        text: text ?? this.text,
        fontSize: fontSize ?? this.fontSize,
      );
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

  /// 道具箱 (ツールバー) をホスト側 (= ヘッダーの下) に出すための受け口。
  ///
  /// 渡すと、 ここへ道具箱の Widget を流し込み、 PDF の上には重ねない
  /// (= ユーザー要望: PDF の上部が道具箱と被って描けない)。 描き込みモードを
  /// 抜けた時と片付けの時は null を流す。 渡さなければ従来どおり PDF の上端に
  /// 重ねて出す (= 分割ペインのように置き場所が無い所)。
  final ValueNotifier<Widget?>? toolbarSink;

  const PdfDrawLayer({
    super.key,
    required this.child,
    required this.active,
    required this.filePath,
    required this.tr,
    required this.onExit,
    required this.onSaved,
    this.controller,
    this.toolbarSink,
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
  /// このセッションを始めた時点の PDF の控え (= 焼き込みの土台)。
  ///
  /// 保存した後も線を動かせるようにするため、 保存のたびに
  /// 「土台 + 今の線」 を書き出す。 これが無いと、 保存済みの線を動かして
  /// もう一度保存した時に、 前に焼き込んだ線がそのまま残って二重になる。
  ///
  /// セッション単位で取るので、 描き込みを始める前に他の機能 (蛍光ペンや
  /// 分割ペインの文字・チェック) が書き込んだ内容は土台に入っており、
  /// 焼き直しても消えない。
  String? _sessionBasePath;

  /// 前回の保存から線が変わったか (dispose 時の無駄な焼き込みを避ける)。
  bool _dirtySinceCommit = false;

  /// 土台をまだ取っていなければ取る。 取れなければ null (= 従来動作)。
  Future<String?> _ensureSessionBase(String path) async {
    final cur = _sessionBasePath;
    if (cur != null) {
      try {
        if (File(cur).existsSync()) return cur;
      } catch (_) {}
    }
    try {
      final dir = await getApplicationSupportDirectory();
      final sep = Platform.pathSeparator;
      final bdir = Directory('${dir.path}${sep}pdf_draw_session');
      if (!bdir.existsSync()) bdir.createSync(recursive: true);
      final p =
          '${bdir.path}$sep${path.hashCode.toRadixString(16)}_base.pdf';
      await File(path).copy(p);
      _sessionBasePath = p;
      return p;
    } catch (_) {
      return null;
    }
  }

  /// 土台を片付ける (別の PDF に移った時 / 画面を閉じた時)。
  void _dropSessionBase() {
    final p = _sessionBasePath;
    _sessionBasePath = null;
    if (p == null) return;
    try {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  bool _committed = false;

  /// ハンドツールやホイールでスクロールした時にも描画位置を追従させる
  /// ための軽い再描画タイマー (モード ON の間だけ)。
  Timer? _repaintTimer;

  /// 色 (= ユーザー要望: カラーバリエーションをもっと増やして)。
  /// 上段 = よく使う濃い色 / 下段 = 明るい色・中間色・無彩色。
  static const List<Color> _palette = [
    Color(0xFFE53935), // 赤
    Color(0xFFD81B60), // 紅
    Color(0xFFFB8C00), // 橙
    Color(0xFFFDD835), // 黄
    Color(0xFF43A047), // 緑
    Color(0xFF00897B), // 青緑
    Color(0xFF1E88E5), // 青
    Color(0xFF3949AB), // 藍
    Color(0xFF8E24AA), // 紫
    Color(0xFF6D4C41), // 茶
    Color(0xFFFF80AB), // 桃
    Color(0xFFFFAB40), // 山吹
    Color(0xFF9CCC65), // 黄緑
    Color(0xFF4DD0E1), // 水
    Color(0xFF757575), // 灰
    Color(0xFF000000), // 黒
  ];

  /// 消しゴムの大きさ (pt)。 ペンとは別に持つ (= ユーザー要望)。
  double _eraserSize = 40.0;

  /// 消しゴムの「今の大きさの丸」 をページの上に出すための位置 (グローバル
  /// 座標)。 = ユーザー要望: 消しゴムの太さが見て分からない。 実際に消える
  /// 範囲をそのままの大きさで見せる。
  Offset? _cursorGlobal;

  /// 選んでいる図形 (_strokes の位置)。 null なら未選択。
  int? _selected;

  /// 色の一覧を広げているか (= ユーザー要望: 色が並び過ぎて気になるので、
  /// 普段は「今の色 + 展開ボタン」 だけにする)。
  bool _colorsOpen = false;

  /// 選んだ図形をドラッグしている間の、 直前のページ座標。
  Offset? _dragPrev;

  /// 掴んでいる四隅の番号 (0=左上 1=右上 2=左下 3=右下)。 null なら
  /// 「動かす」。 = ユーザー要望: 選択モードで大きさや縦横比も変えられるように。
  int? _resizeCorner;

  /// 拡大縮小の支点 (掴んだ角の対角) と、 掴んだ時の図形 / 枠。
  Offset? _resizeAnchor;
  PdfDrawStroke? _resizeOrig;
  Rect? _resizeOrigBox;

  /// 図形の大きさを固定して置くか (= ユーザー要望: 楕円や四角は毎回同じ
  /// 大きさで出てきた方が嬉しい時がある)。 ON の間は、 押した所に
  /// [_lastShapeSize] の大きさで置く (ドラッグ不要)。
  bool _fixedSize = false;

  /// 最後に自由に描いた図形の大きさ (ページ pt)。 固定モードはこれを使う
  /// ので、 好きな大きさで 1 つ描いてから ON にすれば、 その大きさで揃う。
  Size _lastShapeSize = const Size(120, 80);

  /// 大きさを固定して置ける (= 始点と終点で決まる) 図形か。
  static bool _isSpanTool(PdfDrawTool t) =>
      t == PdfDrawTool.rect ||
      t == PdfDrawTool.ellipse ||
      t == PdfDrawTool.line ||
      t == PdfDrawTool.arrow;

  /// 取り消し (Ctrl+Z) 用の控え。 図形を足す / 消す / 動かす の前に積む
  /// (= ユーザー要望: ctrl+z で挿入した図形を取り消せるように)。
  final List<List<PdfDrawStroke>> _undo = [];
  static const int _kUndoMax = 60;

  /// やり直す (Ctrl+Y / Ctrl+Shift+Z) 用の控え (= ユーザー要望: 戻すはあるのに
  /// やり直すが無かった)。 新しく描いた時点で捨てる (= 分岐した歴史は残さない)。
  final List<List<PdfDrawStroke>> _redo = [];

  void _pushUndo() {
    _dirtySinceCommit = true;
    _undo.add(List<PdfDrawStroke>.from(_strokes));
    if (_undo.length > _kUndoMax) _undo.removeAt(0);
    // 新しい操作をしたら「やり直す」 先は無くなる。
    _redo.clear();
  }

  void _undoOnce() {
    if (_undo.isEmpty) return;
    _dirtySinceCommit = true;
    final prev = _undo.removeLast();
    setState(() {
      // 戻す前の状態を「やり直す」 側へ積む。
      _redo.add(List<PdfDrawStroke>.from(_strokes));
      if (_redo.length > _kUndoMax) _redo.removeAt(0);
      _strokes
        ..clear()
        ..addAll(prev);
      _selected = null;
      _current = null;
    });
  }

  /// やり直す (= 戻したものをもう一度当てる)。
  void _redoOnce() {
    if (_redo.isEmpty) return;
    _dirtySinceCommit = true;
    final next = _redo.removeLast();
    setState(() {
      // やり直す前の状態は「戻す」 側へ積み直す (_pushUndo は _redo を
      // 消してしまうので使わない)。
      _undo.add(List<PdfDrawStroke>.from(_strokes));
      if (_undo.length > _kUndoMax) _undo.removeAt(0);
      _strokes
        ..clear()
        ..addAll(next);
      _selected = null;
      _current = null;
    });
  }

  /// [pt] (ページ座標 pt) にある図形を探す。 後から描いた物を優先する。
  int? _hitStrokeAt(int pageNumber, Offset pt) {
    for (var i = _strokes.length - 1; i >= 0; i--) {
      final st = _strokes[i];
      if (st.pageNumber != pageNumber) continue;
      final tol = (st.width * 1.5).clamp(6.0, 24.0).toDouble();
      if (st.tool == PdfDrawTool.rect ||
          st.tool == PdfDrawTool.ellipse ||
          st.tool == PdfDrawTool.text) {
        // 四角 / 楕円は枠の中も掴めるようにする (= 選びやすさ優先)。
        final r = Rect.fromPoints(st.points.first, st.points.last)
            .inflate(tol);
        if (r.contains(pt)) return i;
        continue;
      }
      for (var k = 0; k + 1 < st.points.length; k++) {
        if (_distToSegment(pt, st.points[k], st.points[k + 1]) <= tol) {
          return i;
        }
      }
    }
    return null;
  }

  static double _distToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 <= 0) return (p - a).distance;
    final t =
        (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    return (a + Offset(ab.dx * t, ab.dy * t) - p).distance;
  }

  /// 図形を囲む枠 (ページ座標 pt)。 画面の見た目 (= 8px ぶん広げた枠) と
  /// 合わせるため、 [padPx] を掛けた分だけ広げる。
  static Rect _strokeBox(PdfDrawStroke st, {double pad = 0}) {
    var r = Rect.fromPoints(st.points.first, st.points.first);
    for (final q in st.points) {
      r = r.expandToInclude(Rect.fromPoints(q, q));
    }
    return pad == 0 ? r : r.inflate(pad);
  }

  /// 枠の四隅 (0=左上 1=右上 2=左下 3=右下)。
  static List<Offset> _boxCorners(Rect r) =>
      [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight];

  /// 選んでいる図形を [d] だけずらす。
  ///
  /// ★ copyWith を使う。 以前はここで PdfDrawStroke を作り直しており、
  ///   `text` / `fontSize` を渡し忘れていたため、 置いた文字をドラッグすると
  ///   中身が消えて何も描かれなくなっていた (= ユーザー報告: 文字が透明に
  ///   なって消える)。 大きさを変える方 (_resizeSelectedTo) は渡していたので
  ///   ドラッグの時だけ起きていた。
  void _moveSelected(Offset d) {
    final i = _selected;
    if (i == null || i < 0 || i >= _strokes.length) return;
    final st = _strokes[i];
    _strokes[i] =
        st.copyWith(points: [for (final q in st.points) q + d]);
  }

  /// 掴んだ角を [pt] まで動かして、 選んでいる図形を伸び縮みさせる。
  /// Shift を押している間は縦横比を保つ (= 形を崩さずに大きさだけ変える)。
  void _resizeSelectedTo(Offset pt) {
    final i = _selected;
    final orig = _resizeOrig;
    final anchor = _resizeAnchor;
    final box = _resizeOrigBox;
    if (i == null || orig == null || anchor == null || box == null) return;
    if (i < 0 || i >= _strokes.length) return;
    final w0 = box.width;
    final h0 = box.height;
    // 支点から掴んだ角までの元の長さ (0 だと割れないので下限を置く)。
    final dx0 = (w0.abs() < 1e-3 ? 1e-3 : w0) * (anchor.dx <= box.left ? 1 : -1);
    final dy0 = (h0.abs() < 1e-3 ? 1e-3 : h0) * (anchor.dy <= box.top ? 1 : -1);
    var sx = (pt.dx - anchor.dx) / dx0;
    var sy = (pt.dy - anchor.dy) / dy0;
    // 潰れ切らないように下限を置く (反転はできる)。
    double clampScale(double v) {
      if (v.isNaN || v.isInfinite) return 1.0;
      if (v.abs() < 0.05) return v < 0 ? -0.05 : 0.05;
      return v.clamp(-20.0, 20.0).toDouble();
    }

    sx = clampScale(sx);
    sy = clampScale(sy);
    if (HardwareKeyboard.instance.isShiftPressed) {
      final k = math.max(sx.abs(), sy.abs());
      sx = k * (sx < 0 ? -1 : 1);
      sy = k * (sy < 0 ? -1 : 1);
    }
    _strokes[i] = PdfDrawStroke(
      pageNumber: orig.pageNumber,
      tool: orig.tool,
      points: [
        for (final q in orig.points)
          Offset(anchor.dx + (q.dx - anchor.dx) * sx,
              anchor.dy + (q.dy - anchor.dy) * sy),
      ],
      color: orig.color,
      width: orig.width,
      text: orig.text,
      // 文字は枠と一緒に大きさも変える (= 引っ張った分だけ大きくなる)。
      fontSize: orig.tool == PdfDrawTool.text
          ? (orig.fontSize * ((sx.abs() + sy.abs()) / 2)).clamp(4.0, 400.0)
          : orig.fontSize,
    );
  }

  /// 選んでいる図形を消す。
  void _deleteSelected() {
    final i = _selected;
    if (i == null || i < 0 || i >= _strokes.length) return;
    _pushUndo();
    setState(() {
      _strokes.removeAt(i);
      _selected = null;
    });
  }

  /// 描き込み中のキー操作 (= ユーザー要望: Ctrl+Z で取り消し)。
  bool _onKey(KeyEvent e) {
    if (!widget.active || widget.filePath == null) return false;
    if (e is! KeyDownEvent) return false;
    // 大きさの数値を打ち込んでいる間は、 Delete / Backspace を図形の削除に
    // 使わない (= 数字を消せなくなるため)。
    if (_sizeFocus.hasFocus) return false;
    // ── 文字を打ち込んでいる間は、 箱の方にキーを渡す ──
    //    (Esc だけはここで受けて打ち込みをやめる)
    if (_textPage != null) {
      if (e.logicalKey == LogicalKeyboardKey.escape) {
        _cancelText();
        return true;
      }
      return false;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyZ) {
      // Ctrl+Shift+Z は「やり直す」 (= 一般的な割り当てに合わせる)。
      if (HardwareKeyboard.instance.isShiftPressed) {
        _redoOnce();
      } else {
        _undoOnce();
      }
      return true;
    }
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyY) {
      _redoOnce();
      return true;
    }
    if (_selected != null &&
        (e.logicalKey == LogicalKeyboardKey.delete ||
            e.logicalKey == LogicalKeyboardKey.backspace)) {
      _deleteSelected();
      return true;
    }
    // ── Esc: ファイルは閉じない。 選んでいれば解除、 道具を使って
    //    いれば「選ぶ」 に戻す (= ユーザー要望) ──
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        if (_selected != null) {
          _selected = null;
        } else if (_tool != PdfDrawTool.select) {
          _tool = PdfDrawTool.select;
        }
      });
      return true;
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant PdfDrawLayer old) {
    super.didUpdateWidget(old);
    // ★ モードを閉じただけでは焼き込まない (= ユーザー要望: パレットを
    //   閉じる度に保存されると、 消したい線や図形を消せなくなる)。
    //   描いたものは「まだ保存していない線」 のまま持ち続け、 PDF へ
    //   焼き込むのは ✓ / 保存ボタンを押した時と、 ビューアを閉じた時 (dispose)
    //   だけにする。 閉じている間も線は薄く見えたままにする (build 参照)。
    // ── 別の PDF に切り替わった時だけは、 元のファイルへ書き戻す ──
    //    (そのまま持ち越すと、 関係の無い PDF に焼き込まれてしまう)
    if (old.filePath != widget.filePath && _strokes.isNotEmpty) {
      final oldPath = old.filePath;
      final pending = List<PdfDrawStroke>.from(_strokes);
      final base = _sessionBasePath;
      _strokes.clear();
      _selected = null;
      _undo.clear();
      _redo.clear();
      if (oldPath != null && _dirtySinceCommit) {
        unawaited(writeStrokesToPdf(oldPath, pending, basePath: base));
      }
      _dirtySinceCommit = false;
      // 土台は PDF ごとなので、 移ったら捨てる。
      _dropSessionBase();
    }
    _syncTimer();
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    // 大きさの数値欄を今の道具の値で埋めておく。
    _seedSizeField();
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
    HardwareKeyboard.instance.removeHandler(_onKey);
    _sizeCtrl.dispose();
    _sizeFocus.dispose();
    _textCtrl.dispose();
    _textFocus.dispose();
    // ヘッダーに出していた道具箱を片付ける。
    final sink = widget.toolbarSink;
    if (sink != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => sink.value = null);
    }
    _repaintTimer?.cancel();
    // 閉じられた時も未保存分を書き込む (リロード通知は出来ないが、 次に
    // 開いた時には反映されている)。
    if (_strokes.isNotEmpty && !_saving && _dirtySinceCommit) {
      final path = widget.filePath;
      final pending = List<PdfDrawStroke>.from(_strokes);
      final base = _sessionBasePath;
      if (path != null) {
        unawaited(writeStrokesToPdf(path, pending, basePath: base)
            .whenComplete(_dropSessionBase));
      } else {
        _dropSessionBase();
      }
    } else {
      _dropSessionBase();
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
    // ── 選ぶ: 押した所の図形を掴む (= ユーザー要望: 置いた図形を選択して
    //    操作できるモード)。 そのままドラッグで動かせる。 ──
    if (_tool == PdfDrawTool.select) {
      // ── まず「選んでいる図形の四隅」 を掴んでいないか見る ──
      //    (= ユーザー要望: 動かすだけでなく大きさや縦横比も変えられるように)
      final sel = _selected;
      if (sel != null && sel >= 0 && sel < _strokes.length) {
        final st = _strokes[sel];
        if (st.pageNumber == geom.pageNumber) {
          final box = _strokeBox(st, pad: 8 * geom.heightPercentage);
          final tol = 12 * geom.heightPercentage;
          final corners = _boxCorners(box);
          for (var i = 0; i < corners.length; i++) {
            if ((corners[i] - pt).distance <= tol) {
              _pushUndo();
              setState(() {
                _resizeCorner = i;
                // 掴んだ角の対角を支点にする。
                _resizeAnchor = corners[3 - i];
                _resizeOrig = st;
                _resizeOrigBox = box;
              });
              return;
            }
          }
        }
      }
      final hit = _hitStrokeAt(geom.pageNumber, pt);
      setState(() {
        _selected = hit;
        _dragPrev = hit == null ? null : pt;
        _resizeCorner = null;
      });
      if (hit != null) _pushUndo(); // 動かす前の位置を控える
      return;
    }
    // ── 大きさを固定して置く (= ユーザー要望) ──
    //    押した所を左上にして、 覚えている大きさでそのまま置く。
    if (_fixedSize && _isSpanTool(_tool)) {
      _pushUndo();
      // ★ 押した所が真ん中に来るように置く (= ユーザー要望: カーソルが
      //   中心となるように)。
      final half =
          Offset(_lastShapeSize.width / 2, _lastShapeSize.height / 2);
      setState(() {
        _strokes.add(PdfDrawStroke(
          pageNumber: geom.pageNumber,
          tool: _tool,
          points: [pt - half, pt + half],
          color: _color,
          width: _width,
        ));
      });
      _activePointer = null;
      _currentGeom = null;
      return;
    }
    // ── 文字を置く (= ユーザー要望: 押した所にそのまま書き込める箱) ──
    if (_tool == PdfDrawTool.text) {
      _activePointer = null;
      _currentGeom = null;
      _beginTextAt(geom.pageNumber, pt);
      return;
    }
    // ── 消しゴム: なぞった所の線を消す (= ユーザー要望) ──
    if (_tool == PdfDrawTool.eraser) {
      _pushUndo();
      _eraseAt(geom.pageNumber, pt);
      return;
    }
    // ── チェック: 押した所に ✓ を置く (= ユーザー要望) ──
    if (_tool == PdfDrawTool.check) {
      _pushUndo();
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
    // 選んだ図形をドラッグで動かす。
    if (_tool == PdfDrawTool.select) {
      if (_selected == null) return;
      if (_resizeCorner == null && _dragPrev == null) return;
      try {
        final local = geom.box.globalToLocal(e.position);
        final pt = Offset(
              local.dx.clamp(0.0, geom.contentSize.width),
              local.dy.clamp(0.0, geom.contentSize.height),
            ) *
            geom.heightPercentage;
        if (_resizeCorner != null) {
          setState(() => _resizeSelectedTo(pt));
        } else {
          setState(() {
            _moveSelected(pt - _dragPrev!);
            _dragPrev = pt;
          });
        }
      } catch (_) {}
      return;
    }
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
        // ── Shift を押している間はまっすぐ引く (= ユーザー要望: 直線は
        //    0 / 90 / 180 / 270 度だけ)。 四角と楕円は正方形 / 真円にする。 ──
        var end = pt;
        if (HardwareKeyboard.instance.isShiftPressed) {
          final a = cur.points.first;
          final d = end - a;
          if (cur.tool == PdfDrawTool.line || cur.tool == PdfDrawTool.arrow) {
            end = d.dx.abs() >= d.dy.abs()
                ? Offset(end.dx, a.dy)
                : Offset(a.dx, end.dy);
          } else if (cur.tool == PdfDrawTool.rect ||
              cur.tool == PdfDrawTool.ellipse) {
            final side = math.max(d.dx.abs(), d.dy.abs());
            end = a +
                Offset(side * (d.dx < 0 ? -1 : 1), side * (d.dy < 0 ? -1 : 1));
          }
        }
        cur.points[cur.points.length - 1] = end;
      }
    });
  }

  void _onPointerUp(PointerEvent e) {
    // 指を離したら丸も消す (マウスは hover で出続ける)。
    if (e.kind != PointerDeviceKind.mouse) _trackCursor(null);
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    _currentGeom = null;
    _dragPrev = null;
    if (_resizeCorner != null) {
      setState(() {
        _resizeCorner = null;
        _resizeAnchor = null;
        _resizeOrig = null;
        _resizeOrigBox = null;
      });
      return;
    }
    final cur = _current;
    if (cur == null) return;
    setState(() {
      _current = null;
      // 動きがほぼ無い図形はゴミになるので捨てる (ペンの点は残す)。
      final span = (cur.points.last - cur.points.first).distance;
      if (cur.tool == PdfDrawTool.pen || span >= 1.0) {
        _pushUndo();
        _strokes.add(cur);
        // 次に「大きさを固定」 で置く時のために、 今の大きさを覚える
        // (= ユーザー要望: 好きな大きさで 1 つ描いてから固定すれば揃う)。
        if (_isSpanTool(cur.tool)) {
          final d = cur.points.last - cur.points.first;
          if (d.dx.abs() >= 2 || d.dy.abs() >= 2) {
            _lastShapeSize = Size(d.dx, d.dy);
          }
        }
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

  /// 文字の大きさ (pt)。 置いた文字に使う (= ユーザー要望: テキスト入力)。
  /// 既定は 25pt (= ユーザー要望)。 道具箱のスライダー、 または隣の欄に
  /// 数値を打ち込んでも変えられる。
  double _fontSize = 25;

  /// チェック (✓) の大きさ。 既定 10 (= ユーザー要望)。 ペンの太さとは
  /// 別に持つ (太さを 10 にするとペンの線まで極太になってしまうため)。
  double _checkSize = 10;

  /// チェックの線の太さ (pt)。 大きさとは別で、 常にこの太さで描く
  /// (= ユーザー要望: チェックの太さも 2.5)。 大きさを変えても線の太さは
  /// 変わらないので、 大きい ✓ でも細い線のままになる。
  static const double _kCheckStrokeWidth = 2.5;

  /// 打ち込み中の文字の場所 (ページ番号 / ページ座標 pt)。
  /// null なら打ち込んでいない。 = ユーザー要望: 窓を出すのではなく、
  /// 押した所にそのまま文字を書き込める箱を出す (PowerPoint と同じ感覚)。
  int? _textPage;
  Offset? _textAt;
  final TextEditingController _textCtrl = TextEditingController();
  final FocusNode _textFocus = FocusNode();

  /// 道具箱の「大きさ」 欄。 スライダーだけでなく数値でも指定できる
  /// (= ユーザー要望: 数値で指定することもできるように)。
  final TextEditingController _sizeCtrl = TextEditingController();
  final FocusNode _sizeFocus = FocusNode();

  /// 今選んでいる道具の大きさ。
  double get _activeToolSize {
    switch (_tool) {
      case PdfDrawTool.text:
        return _fontSize;
      case PdfDrawTool.check:
        return _checkSize;
      case PdfDrawTool.eraser:
        return _eraserSize;
      default:
        return _width;
    }
  }

  /// 今選んでいる道具の大きさの下限 / 上限。
  (double, double) get _activeToolSizeRange {
    switch (_tool) {
      case PdfDrawTool.text:
        return (6.0, 96.0);
      case PdfDrawTool.check:
        return (1.0, 20.0);
      case PdfDrawTool.eraser:
        return (4.0, 120.0);
      default:
        return (0.5, 16.0);
    }
  }

  /// 数値欄の表示を今の値に合わせる。 build の中では呼ばない
  /// (build 中に controller を書き換えると setState 中の setState になる)。
  void _seedSizeField() {
    final v = _activeToolSize;
    final t = v < 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(0);
    if (_sizeCtrl.text != t) _sizeCtrl.text = t;
  }

  /// 数値欄に打ち込まれた値を今の道具へ入れる。
  void _applySizeField(String raw) {
    final parsed = double.tryParse(raw.trim());
    if (parsed == null) return;
    final (lo, hi) = _activeToolSizeRange;
    final v = parsed.clamp(lo, hi).toDouble();
    setState(() {
      switch (_tool) {
        case PdfDrawTool.text:
          _fontSize = v;
          break;
        case PdfDrawTool.check:
          _checkSize = v;
          break;
        case PdfDrawTool.eraser:
          _eraserSize = v;
          break;
        default:
          _width = v;
      }
    });
  }

  /// 押した所に文字の箱を出す。 既に打ち込み中なら先に確定する。
  void _beginTextAt(int pageNumber, Offset at) {
    if (_textPage != null) _commitText();
    setState(() {
      _textPage = pageNumber;
      _textAt = at;
      _textCtrl.text = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
  }

  /// 打ち込んだ文字を確定して線として積む。 空なら捨てる。
  void _commitText() {
    final page = _textPage;
    final at = _textAt;
    final body = _textCtrl.text;
    if (page == null || at == null) return;
    setState(() {
      _textPage = null;
      _textAt = null;
      _textCtrl.text = '';
    });
    if (body.trim().isEmpty) return;
    // 置いた文字の大きさを測って、 選ぶ / 消す / 大きさを変える の対象にする。
    final tp = TextPainter(
      text: TextSpan(
          text: body, style: TextStyle(fontSize: _fontSize, height: 1.2)),
      textDirection: TextDirection.ltr,
    )..layout();
    _pushUndo();
    setState(() {
      _strokes.add(PdfDrawStroke(
        pageNumber: page,
        tool: PdfDrawTool.text,
        points: [at, at + Offset(tp.width, tp.height)],
        color: _color,
        width: _width,
        text: body,
        fontSize: _fontSize,
      ));
    });
  }

  /// 打ち込みをやめる (= 何も置かない)。
  void _cancelText() {
    if (_textPage == null) return;
    setState(() {
      _textPage = null;
      _textAt = null;
      _textCtrl.text = '';
    });
  }

  /// ページ座標 (pt) → オーバーレイ上の位置 (px)。 見つからなければ null。
  (Offset, double)? _pageToOverlay(int pageNumber, Offset pagePt) {
    final overlay =
        _overlayKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlay == null || !overlay.attached) return null;
    for (final g in _collectPageGeoms()) {
      if (g.pageNumber != pageNumber) continue;
      try {
        final local = pagePt / g.heightPercentage;
        final o = overlay.globalToLocal(g.box.localToGlobal(local));
        final a = g.box.localToGlobal(Offset.zero);
        final b = g.box.localToGlobal(const Offset(0, 10));
        final px = ((b - a).distance / 10.0) / g.heightPercentage;
        return (o, px);
      } catch (_) {}
    }
    return null;
  }

  /// 打ち込み中の文字の箱 (= 押した所にそのまま出る)。
  Widget _buildTextBox() {
    final page = _textPage;
    final at = _textAt;
    if (page == null || at == null) return const SizedBox.shrink();
    final hit = _pageToOverlay(page, at);
    if (hit == null) return const SizedBox.shrink();
    final (pos, px) = hit;
    final fs = (_fontSize * px).clamp(6.0, 200.0).toDouble();
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minWidth: 120, maxWidth: math.max(160.0, 520.0 * px)),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.86),
              border: Border.all(color: const Color(0xFF6C63FF), width: 1.4),
              borderRadius: BorderRadius.circular(3),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: IntrinsicWidth(
              child: TextField(
                controller: _textCtrl,
                focusNode: _textFocus,
                autofocus: true,
                maxLines: null,
                style: TextStyle(
                    color: _color, fontSize: fs, height: 1.2),
                cursorColor: const Color(0xFF6C63FF),
                cursorHeight: fs,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                // 打ち終わりは外を押すか ✓。 Enter は改行として使う。
                onTapOutside: (_) => _commitText(),
                onEditingComplete: _commitText,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// チェック (✓) 1 個ぶんの線  /// チェック (✓) 1 個ぶんの線 (= ユーザー要望: 簡単に出せるように)。
  /// 太さに合わせて大きさも変える。
  PdfDrawStroke _checkStroke(int pageNumber, Offset at) {
    // 大きさはチェック専用の設定から出す (= ユーザー要望: 既定 10)。
    final k = (_checkSize / 2.5).clamp(0.2, 8.0);
    return PdfDrawStroke(
      pageNumber: pageNumber,
      tool: PdfDrawTool.pen,
      points: [
        at + Offset(-7 * k, 0),
        at + Offset(-2 * k, 6 * k),
        at + Offset(9 * k, -8 * k),
      ],
      color: _color,
      width: _kCheckStrokeWidth,
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
    // 線が 0 本でも、 このセッションで一度でも焼き込んでいるなら書き直す。
    //   そうしないと「保存済みの線を全部消して保存」 が効かず、 消したはず
    //   の線が PDF に残ってしまう (= ユーザー要望: 保存した後も消せるように)。
    final canRestoreBase = _sessionBasePath != null && _dirtySinceCommit;
    if (path == null || (_strokes.isEmpty && !canRestoreBase)) {
      if (exitAfter) widget.onExit();
      return;
    }
    setState(() => _saving = true);
    final pending = List<PdfDrawStroke>.from(_strokes);
    // 毎回「セッションを始めた時点の PDF + 今の線」 を書き出す。 これで
    // 何度保存しても線が二重にならないので、 保存した後も動かせる
    // (= ユーザー要望: 保存した後も消したり動かしたりできるように)。
    final base = await _ensureSessionBase(path);
    final ok = await writeStrokesToPdf(path, pending, basePath: base);
    if (!mounted) {
      _saving = false;
      _committed = ok;
      return;
    }
    setState(() {
      _saving = false;
      if (ok) {
        _committed = true;
        // ★ 線は消さない。 保存した後もそのまま選んで動かせるようにする。
        //   もう一度保存すれば土台から焼き直されるので二重にならない。
        _dirtySinceCommit = false;
      }
    });
    if (ok) {
      widget.onSaved();
      if (exitAfter) widget.onExit();
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
      String path, List<PdfDrawStroke> strokes,
      {String? basePath}) async {
    if (strokes.isEmpty) {
      // 全部消された時は土台に戻す (= 焼き込み済みの線を取り除く)。
      if (basePath == null) return true;
      try {
        final b = File(basePath);
        if (!b.existsSync()) return true;
        await b.copy(path);
        pdfDrawBurnedNotifier.value =
            '$path ${DateTime.now().microsecondsSinceEpoch}';
        return true;
      } catch (e) {
        debugPrint('PDF 土台への戻し失敗: $e');
        return false;
      }
    }
    // バックアップ先はプラグイン (path_provider) 経由なので UI isolate 側で
    // 先に解決してから渡す (別 isolate ではプラグインを呼べない)。
    // ── 文字を置いている時は日本語の書体を読んでおく ──
    //    (別 isolate では rootBundle を使えないので、 ここで読んで渡す)
    List<int>? fontBytes;
    if (strokes.any((e) => e.tool == PdfDrawTool.text)) {
      try {
        final data =
            await rootBundle.load('assets/fonts/NotoSansJP-Regular.ttf');
        fontBytes = data.buffer.asUint8List();
      } catch (_) {
        fontBytes = null; // 無ければ英数字だけの標準書体になる
      }
    }
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
      'base': basePath,
      'strokes': [
        for (final st in strokes)
          <String, Object?>{
            'page': st.pageNumber,
            'tool': st.tool.index,
            'color': st.color.toARGB32(),
            'width': st.width,
            'text': st.text,
            'fontSize': st.fontSize,
            'pts': <double>[
              for (final pt in st.points) ...[pt.dx, pt.dy]
            ],
          },
      ],
      'font': fontBytes,
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
    if (!widget.active || widget.filePath == null) {
      _publishToolbar(null);
      // ── 描き込みモードを閉じている間も、 まだ焼き込んでいない線は
      //    そのまま見せる (= ユーザー要望: 閉じても保存しない代わりに、
      //    描いたものが消えたように見えないようにする)。 触れはしない。 ──
      if (_strokes.isEmpty) return child;
      return Stack(children: [
        Positioned.fill(child: child),
        Positioned.fill(
          child: IgnorePointer(
            child: ClipRect(
              child: CustomPaint(
                key: _overlayKey,
                painter: _PdfDrawPainter(
                  strokes: _strokes,
                  current: null,
                  eraserCursor: null,
                  eraserSize: _eraserSize,
                  selected: null,
                  geomsGetter: _collectPageGeoms,
                  overlayBoxGetter: () => _overlayKey.currentContext
                      ?.findRenderObject() as RenderBox?,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ]);
    }
    final passThrough = _tool == PdfDrawTool.hand;
    final toolbar = _buildToolbar(context);
    if (widget.toolbarSink != null) _publishToolbar(toolbar);
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
                  : _tool == PdfDrawTool.select
                      ? SystemMouseCursors.click
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
                    selected: _tool == PdfDrawTool.select ? _selected : null,
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
      // ── 打ち込み中の文字の箱 (= ユーザー要望: 押した所にそのまま書ける) ──
      if (_textPage != null) _buildTextBox(),
      // ── 道具箱 ──
      //    ホスト側に置き場所 (toolbarSink) があればそちらに出すので、
      //    ここでは重ねない (= ユーザー要望: PDF の上部と被って描けない)。
      if (widget.toolbarSink == null)
        Positioned(
          top: 6,
          left: 6,
          right: 6,
          child: Align(
            alignment: Alignment.topCenter,
            child: toolbar,
          ),
        ),
    ]);
  }

  /// 道具箱をホスト側の受け口へ流す。 build 中に他の Widget を書き換える
  /// ことになるので、 フレームが終わってから渡す。
  void _publishToolbar(Widget? w) {
    final sink = widget.toolbarSink;
    if (sink == null) return;
    if (identical(sink.value, w)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted && w != null) return;
      sink.value = w;
    });
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
          // 選んでいる道具をもう一度押すと解除する (= ユーザー要望)。
          // 解除すると素通し (hand) になり、 PDF の操作に戻る。
          onTap: () {
            setState(() => _tool = _tool == t ? PdfDrawTool.hand : t);
            // 道具ごとに大きさが違うので、 数値欄も入れ替える。
            _seedSizeField();
          },
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
        onTap: () => setState(() {
          _color = c;
          // 選んだら畳む (= 広がったままだと道具箱が長くなる)。
          _colorsOpen = false;
        }),
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
      // ── 道具ごとに「その道具の大きさ」 を出す (= ユーザー要望: 文字が
      //    小さいのに変えられなかった。 チェックもペンの太さに引きずられて
      //    いた)。 文字 = pt、 チェック = 大きさ、 ペン = 太さ。 ──
      final textTool = _tool == PdfDrawTool.text;
      final checkTool = _tool == PdfDrawTool.check;
      final double cur = textTool
          ? _fontSize
          : checkTool
              ? _checkSize
              : eraser
                  ? _eraserSize
                  : _width;
      final double minV = textTool
          ? 6.0
          : checkTool
              ? 1.0
              : eraser
                  ? 4.0
                  : 0.5;
      // 消しゴムは大きく取れるようにする (= ユーザー要望: 最大値をもう少し
      // 大きく)。 ページの上に出る丸で実際の大きさが分かる。
      final double maxV = textTool
          ? 96.0
          : checkTool
              ? 20.0
              : eraser
                  ? 120.0
                  : 16.0;
      final double v = cur.clamp(minV, maxV).toDouble();
      final Color accent = eraser
          ? const Color(0xFF9FE7FF)
          : textTool
              ? const Color(0xFFFFD8A8)
              : const Color(0xFFB9B4FF);
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
            message: widget.tr(textTool
                ? 'pdfdraw.textSize'
                : checkTool
                    ? 'pdfdraw.checkSize'
                    : eraser
                        ? 'pdfdraw.eraserSize'
                        : 'pdfdraw.penWidth'),
            child: eraser
                ? const _EraserGlyph(size: 16, color: Color(0xFF9FE7FF))
                : Icon(
                    textTool
                        ? Icons.format_size_rounded
                        : checkTool
                            ? Icons.check_rounded
                            : Icons.brush_rounded,
                    size: 15,
                    color: accent),
          ),
          const SizedBox(width: 6),
          // 見本 (実際の形と大きさ)。
          //   チェックは見出しと同じ ✓ になって同じ絵が 2 つ並ぶので出さない
          //   (= ユーザー要望: 左 1 つだけでいい)。
          if (!checkTool)
            SizedBox(
              width: 26,
              height: 26,
            child: Center(
              child: textTool
                  // 文字の見本 (枠に収まる範囲で実際の大きさに近づける)。
                  ? Text('あ',
                      style: TextStyle(
                          color: _color,
                          height: 1.0,
                          fontSize: (v * 0.7).clamp(8.0, 24.0).toDouble()))
                  : eraser
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
                // ペンは 0.5 刻み / 消しゴムは 1 刻み (= 幅が広いので)。
                divisions: (eraser || textTool)
                    ? (maxV - minV).round()
                    : ((maxV - minV) * 2).round(),
                onChanged: (nv) {
                  setState(() {
                    if (textTool) {
                      _fontSize = nv;
                    } else if (checkTool) {
                      _checkSize = nv;
                    } else if (eraser) {
                      _eraserSize = nv;
                    } else {
                      _width = nv;
                    }
                  });
                  _seedSizeField();
                },
              ),
            ),
          ),
          const SizedBox(width: 2),
          // 数値でも指定できる (= ユーザー要望)。 打ち込んだらその場で効く。
          SizedBox(
            width: 40,
            height: 26,
            child: TextField(
              controller: _sizeCtrl,
              focusNode: _sizeFocus,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true),
              style: TextStyle(
                  color: accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()]),
              cursorColor: accent,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 4),
              ),
              onChanged: _applySizeField,
              onSubmitted: (t) {
                _applySizeField(t);
                _seedSizeField();
              },
              onTapOutside: (_) {
                _sizeFocus.unfocus();
                _seedSizeField();
              },
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
            // ── 置いた図形を選んで動かす / 消す (= ユーザー要望) ──
            toolBtn(PdfDrawTool.select, Icons.near_me_outlined,
                'pdfdraw.select'),
            // 文字を置く (= ユーザー要望: 図形を選択と手書きペンの間に)。
            toolBtn(PdfDrawTool.text, Icons.title_rounded, 'pdfdraw.text'),
            toolBtn(PdfDrawTool.pen, Icons.gesture_rounded, 'pdfdraw.pen'),
            // 消しゴム / チェック (= ユーザー要望)。
            toolBtn(PdfDrawTool.eraser, null, 'pdfdraw.eraser'),
            toolBtn(PdfDrawTool.check, Icons.check_rounded, 'pdfdraw.check'),
            toolBtn(PdfDrawTool.line, Icons.horizontal_rule_rounded, 'pdfdraw.line'),
            toolBtn(PdfDrawTool.arrow, Icons.north_east_rounded, 'pdfdraw.arrow'),
            toolBtn(PdfDrawTool.rect, Icons.crop_square_rounded, 'pdfdraw.rect'),
            toolBtn(PdfDrawTool.ellipse, Icons.circle_outlined, 'pdfdraw.ellipse'),
            // ── 大きさを固定して置く (= ユーザー要望: 四角や楕円は毎回同じ
            //    大きさで出てきた方が嬉しい時がある)。 ON の間は押した所へ
            //    「最後に描いた大きさ」 でそのまま置く。 ──
            if (_isSpanTool(_tool))
              Tooltip(
                message: '${widget.tr('pdfdraw.fixedSize')}'
                    ' (${_lastShapeSize.width.abs().round()}'
                    '×${_lastShapeSize.height.abs().round()})',
                child: InkWell(
                  onTap: () => setState(() => _fixedSize = !_fixedSize),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _fixedSize
                          ? const Color(0xFF6C63FF)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                        _fixedSize
                            ? Icons.photo_size_select_small_rounded
                            : Icons.photo_size_select_large_rounded,
                        size: 17,
                        color: _fixedSize ? Colors.white : Colors.white70),
                  ),
                ),
              ),
            Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: Colors.white24),
            // ── 色: 普段は「今の色」 と展開ボタンだけ (= ユーザー要望) ──
            colorBtn(_color),
            InkWell(
              onTap: () => setState(() => _colorsOpen = !_colorsOpen),
              borderRadius: BorderRadius.circular(6),
              child: Tooltip(
                message: widget.tr('pdfdraw.moreColors'),
                child: SizedBox(
                  width: 22,
                  height: 26,
                  child: Icon(
                      _colorsOpen
                          ? Icons.chevron_left_rounded
                          : Icons.chevron_right_rounded,
                      size: 18,
                      color: Colors.white70),
                ),
              ),
            ),
            if (_colorsOpen)
              for (final c in _palette)
                if (c.toARGB32() != _color.toARGB32()) colorBtn(c),
            Container(
                width: 1,
                height: 20,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: Colors.white24),
            if (_tool != PdfDrawTool.select) sizeControl(),
            // 選んでいる図形を消す (= 選択モードの時だけ出す)。
            if (_tool == PdfDrawTool.select)
              actBtn(
                  Icons.delete_forever_rounded,
                  'pdfdraw.deleteSelected',
                  _selected == null || _saving ? null : _deleteSelected,
                  color: const Color(0xFFFF8A80)),
            // 一つ戻す (Ctrl+Z も同じ働き = ユーザー要望)。
            actBtn(Icons.undo_rounded, 'pdfdraw.undo',
                _undo.isEmpty || _saving ? null : _undoOnce),
            // やり直す (Ctrl+Y / Ctrl+Shift+Z = ユーザー要望: 戻すはあるのに
            // やり直すが無かった)。
            actBtn(Icons.redo_rounded, 'pdfdraw.redo',
                _redo.isEmpty || _saving ? null : _redoOnce),
            actBtn(
                Icons.delete_outline_rounded,
                'pdfdraw.clear',
                _strokes.isEmpty || _saving
                    ? null
                    : () {
                        _pushUndo();
                        setState(() {
                          _strokes.clear();
                          _selected = null;
                        });
                      }),
            // ── 保存は「保存して終了」 の 1 つに纏めた (= ユーザー要望:
            //    上書き保存と保存して終了は分けなくていい)。 焼き込んで
            //    から描き込みモードを閉じる。 ──
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

  /// 選んでいる図形 (strokes の位置)。 null なら囲みを出さない。
  final int? selected;
  final List<_PageGeom> Function() geomsGetter;
  final RenderBox? Function() overlayBoxGetter;

  _PdfDrawPainter({
    required this.strokes,
    required this.current,
    required this.eraserCursor,
    required this.eraserSize,
    required this.selected,
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
      // ── 置いた文字 (= ユーザー要望: テキスト入力) ──
      if (s.tool == PdfDrawTool.text) {
        final body = s.text ?? '';
        if (body.isEmpty) return;
        final tp = TextPainter(
          text: TextSpan(
            text: body,
            style: TextStyle(
                color: s.color,
                fontSize: (s.fontSize * pxScale).clamp(2.0, 800.0),
                height: 1.2),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, p1);
        return;
      }
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
        case PdfDrawTool.select:
        case PdfDrawTool.text:
          break;
      }
    }

    for (final s in strokes) {
      draw(s);
    }
    final cur = current;
    if (cur != null) draw(cur);

    // ── 選んでいる図形を囲う (= ユーザー要望: 選択して操作できるモード) ──
    final sel = selected;
    if (sel != null && sel >= 0 && sel < strokes.length) {
      final st = strokes[sel];
      final g = byPage[st.pageNumber];
      if (g != null && st.points.isNotEmpty) {
        Offset toOverlay(Offset pagePt) => overlay
            .globalToLocal(g.box.localToGlobal(pagePt / g.heightPercentage));
        var r = Rect.fromPoints(toOverlay(st.points.first),
            toOverlay(st.points.first));
        for (final q in st.points) {
          final o = toOverlay(q);
          r = r.expandToInclude(Rect.fromPoints(o, o));
        }
        r = r.inflate(8);
        canvas.drawRRect(
            RRect.fromRectAndRadius(r, const Radius.circular(6)),
            Paint()
              ..color = const Color(0x224FC3F7)
              ..style = PaintingStyle.fill);
        canvas.drawRRect(
            RRect.fromRectAndRadius(r, const Radius.circular(6)),
            Paint()
              ..color = const Color(0xFF4FC3F7)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.6);
        // 四隅の掴み (= ここを引っ張ると大きさ / 縦横比を変えられる)。
        for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
          canvas.drawCircle(c, 5.5, Paint()..color = Colors.white);
          canvas.drawCircle(
              c,
              5.5,
              Paint()
                ..color = const Color(0xFF1565C0)
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.6);
          canvas.drawCircle(c, 2.4, Paint()..color = const Color(0xFF4FC3F7));
        }
      }
    }

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
