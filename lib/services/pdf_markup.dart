// PDF の中に元から入っている「書き込み (注釈)」 を、 アプリのビューアでも
// 見えるようにする道具。
//
// ★ = ユーザー報告「PDF 内の画像位置のマークアップが、 アプリ内で開くと
//   反映されていない」。
//
// ── なぜ見えないのか ─────────────────────────────────────────────
// ページの絵を作っているのは syncfusion_pdfviewer_windows (中身は pdfium)。
// そこは `FPDF_RenderPageBitmap(..., flags)` に **FPDF_ANNOT を渡していない**
// ので、 ページの中身だけが描かれ、 注釈は一切描かれない。
// その上で syncfusion の Dart 側が自前で描き足しているのは
//   ・文字のマーカー (Highlight / Underline / StrikeOut / Squiggly)
//   ・付箋 (Text = Popup)
// の 5 種類だけ。 つまり**四角・丸・線・多角形で囲った印は、 元の PDF に
// 入っていても画面には出てこない**。 これが今回の「反映されない」 の正体。
//
// ── どう直したか ─────────────────────────────────────────────────
// 開く時に、 その印をページの中身へ**焼き込んだ控えを作り**、 ビューアには
// そちらを見せる。
//
//   ・**元のファイルは一切書き換えない**。 控えはアプリの作業場所に作る。
//   ・メモやマーカー、 描き込みの控えは今までどおり**元の道**を鍵にする
//     (ここが変わると、 今までの書き込みが行方不明になる)。
//   ・文字のマーカーと付箋は焼き込まない (ビューアが自分で描くので、
//     焼き込むと二重に濃くなってしまう)。
//   ・リンクと入力欄 (Widget) も焼き込まない (押せなくなるため)。
//
// ── 位置がずれた話 (b322 → b323) ─────────────────────────────────
// はじめは syncfusion の `PdfAnnotation.flatten()` に任せていたが、
// **場所がずれて描かれた** (= ユーザー報告)。 原因は外観ストリームの置き方。
//
//   実物の PDF (fitz/PyMuPDF が付けた印) の外観は
//     /BBox[33.6875 442.304 371.02085 501.63734]  /Matrix[1 0 0 1 0 0]
//   のように **BBox が紙の絶対座標**で、 中身もその絶対座標で描いている。
//   PDF の決まりでは 「BBox を Matrix で変換した枠を /Rect へ合わせる行列」
//   を掛けてから描く (= この場合は何も動かさないのが正解)。 ところが
//   syncfusion の `drawPdfTemplate` は **BBox が原点から始まる前提**で
//   `translate(左, -(上 + 高さ))` を足すため、 絶対座標の中身が**二重に
//   ずれる** (左端の箱なら右へ約 34pt)。
//
// そこで**外観ストリームは使わず、 注釈の持っている値から自分で描く**。
//   `annotation.bounds` は「左上原点の紙座標」 で返り、
//   `page.graphics.drawRectangle(bounds: ...)` はそこへ正確に描かれる
//   (実測: /Rect[33.6875 442.304 371.02085 501.63734] の注釈が、
//    焼き込み後の中身で `33.69 -320.41 337.33 -59.33 re` +
//    `1 0 0 1 0 822.05 cm` = 元の /Rect と完全に一致)。
// 線の色 (/C)、 中の色 (/IC)、 透け具合 (/CA)、 枠の太さ (/BS /W) を
// そのまま使うので、 見た目もほぼ同じになる。
//
// ── 限界 ─────────────────────────────────────────────────────────
// syncfusion_flutter_pdf が読み込んだ PDF から組み立て直せる注釈は
// Link / Line / Circle / Square / Polygon / Widget / 文字マーカー / 付箋 だけ。
// 手書き (Ink) や吹き出し (FreeText)、 スタンプ (Stamp) はそもそも物として
// 出てこないので、 ここでも描けない。 囲みの印はほぼ Square / Circle
// なので、 今回の用途はこれで足りる。
// 回転しているページ (/Rotate ≠ 0) は座標の当てが外れるので触らない。
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sfpdf;

/// 焼き込みの控えを置く場所の名前。
const String _kCacheDirName = 'pdf_markup_cache';

/// これより大きいファイルは触らない (開くのが遅くなるため)。
const int _kMaxBytes = 120 * 1024 * 1024;

/// 1 本ぶんの覚え書き。 [out] が null = 「調べたが焼き込む物は無かった」。
class _Entry {
  final String? out;
  final int mtimeMs;
  final int size;
  final int count;
  const _Entry(this.out, this.mtimeMs, this.size, this.count);
}

/// 焼き込む対象か (= ビューアが自分では描かない印だけ)。
///
/// 文字マーカー / 付箋はビューアが描くので触らない (二重に濃くなる)。
/// リンクと入力欄も触らない (押せなくなる)。
bool _isMarkup(sfpdf.PdfAnnotation a) =>
    a is sfpdf.PdfRectangleAnnotation ||
    a is sfpdf.PdfEllipseAnnotation ||
    a is sfpdf.PdfLineAnnotation ||
    a is sfpdf.PdfPolygonAnnotation;

/// PDF の座標 (左下原点) の点の並びを、 紙の左上原点へ直す。
List<Offset> _toTopLeft(List<int> flat, double pageHeight) {
  final out = <Offset>[];
  for (var i = 0; i + 1 < flat.length; i += 2) {
    out.add(Offset(flat[i].toDouble(), pageHeight - flat[i + 1].toDouble()));
  }
  return out;
}

/// 印を 1 つ、 ページの中身へ描く。 描けたら true。
///
/// ★ 外観ストリームは使わない (絶対座標の BBox を syncfusion が二重に
///   ずらしてしまうため。 ファイル頭のコメント参照)。 注釈の持っている
///   値から自分で描くので、 場所は `bounds` のとおり正確になる。
bool _paintMarkup(sfpdf.PdfPage page, sfpdf.PdfAnnotation a) {
  final g = page.graphics;
  final h = page.size.height;
  final state = g.save();
  try {
    final op = a.opacity;
    if (op > 0 && op < 1) g.setTransparency(op);

    if (a is sfpdf.PdfRectangleAnnotation) {
      final bw = a.border.width;
      final pen = a.color.isEmpty
          ? null
          : sfpdf.PdfPen(a.color, width: bw <= 0 ? 1.0 : bw);
      final brush =
          a.innerColor.isEmpty ? null : sfpdf.PdfSolidBrush(a.innerColor);
      if (pen == null && brush == null) return false;
      // 枠線は縁の真ん中に引かれるので、 太さの半分だけ内へ寄せる
      // (= 元の見た目と同じ位置に来るように)。
      final inset = bw <= 0 ? 0.0 : bw / 2;
      var r = a.bounds;
      if (r.width > inset * 2 && r.height > inset * 2) r = r.deflate(inset);
      if (r.width <= 0 || r.height <= 0) return false;
      g.drawRectangle(pen: pen, brush: brush, bounds: r);
      return true;
    }
    if (a is sfpdf.PdfEllipseAnnotation) {
      final bw = a.border.width;
      final pen = a.color.isEmpty
          ? null
          : sfpdf.PdfPen(a.color, width: bw <= 0 ? 1.0 : bw);
      final brush =
          a.innerColor.isEmpty ? null : sfpdf.PdfSolidBrush(a.innerColor);
      if (pen == null && brush == null) return false;
      final inset = bw <= 0 ? 0.0 : bw / 2;
      var r = a.bounds;
      if (r.width > inset * 2 && r.height > inset * 2) r = r.deflate(inset);
      if (r.width <= 0 || r.height <= 0) return false;
      g.drawEllipse(r, pen: pen, brush: brush);
      return true;
    }
    if (a is sfpdf.PdfLineAnnotation) {
      if (a.color.isEmpty) return false;
      final pts = _toTopLeft(a.linePoints, h);
      if (pts.length < 2) return false;
      final bw = a.border.width;
      final pen = sfpdf.PdfPen(a.color, width: bw <= 0 ? 1.0 : bw);
      for (var i = 0; i + 1 < pts.length; i++) {
        g.drawLine(pen, pts[i], pts[i + 1]);
      }
      return true;
    }
    if (a is sfpdf.PdfPolygonAnnotation) {
      final pts = _toTopLeft(a.polygonPoints, h);
      if (pts.length < 3) return false;
      final bw = a.border.width;
      final pen = a.color.isEmpty
          ? null
          : sfpdf.PdfPen(a.color, width: bw <= 0 ? 1.0 : bw);
      final brush =
          a.innerColor.isEmpty ? null : sfpdf.PdfSolidBrush(a.innerColor);
      if (pen == null && brush == null) return false;
      g.drawPolygon(pts, pen: pen, brush: brush);
      return true;
    }
    return false;
  } catch (e) {
    debugPrint('印を描けませんでした: $e');
    return false;
  } finally {
    g.restore(state);
  }
}

/// 別 isolate で走る本体。 [msg] は `{src, out}`。
/// 戻りは `{count, error?}`。 count == 0 なら控えは作っていない。
Future<Map<String, Object?>> flattenPdfMarkupWorker(
    Map<String, Object?> msg) async {
  final src = msg['src'] as String;
  final out = msg['out'] as String;
  sfpdf.PdfDocument? doc;
  try {
    final bytes = await File(src).readAsBytes();
    doc = sfpdf.PdfDocument(inputBytes: bytes);
    var count = 0;
    for (var i = 0; i < doc.pages.count; i++) {
      final page = doc.pages[i];
      // ★ 回っているページは座標の当てが外れるので触らない
      //   (ずれた所に描くくらいなら、 描かない方がまし)。
      if (page.rotation != sfpdf.PdfPageRotateAngle.rotateAngle0) continue;
      final anns = page.annotations;
      // 描いてから消すので、 先に対象を集めてしまう
      // (途中で消すと並びがずれる)。
      final targets = <sfpdf.PdfAnnotation>[];
      for (var j = 0; j < anns.count; j++) {
        try {
          final a = anns[j];
          if (_isMarkup(a)) targets.add(a);
        } catch (_) {}
      }
      for (final a in targets) {
        if (!_paintMarkup(page, a)) continue;
        count++;
        // 中身へ描いたので、 注釈そのものは外す (他のアプリで開いた時に
        // 二重に見えないように)。 外せなくても実害は無い。
        try {
          anns.remove(a);
        } catch (_) {}
      }
    }
    if (count == 0) {
      doc.dispose();
      return <String, Object?>{'count': 0};
    }
    final saved = await doc.save();
    doc.dispose();
    doc = null;
    if (saved.isEmpty) return <String, Object?>{'count': 0};
    final f = File(out);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(saved, flush: true);
    return <String, Object?>{'count': count};
  } catch (e) {
    try {
      doc?.dispose();
    } catch (_) {}
    return <String, Object?>{'count': 0, 'error': '$e'};
  }
}

/// 元の PDF に入っている囲みの印を、 見える形にして返す入口。
class PdfMarkupFlatten {
  PdfMarkupFlatten._();

  static final Map<String, _Entry> _cache = <String, _Entry>{};
  static final Map<String, Future<void>> _inflight = <String, Future<void>>{};

  /// 機能そのものの入り / 切り (= 設定から止められるように)。
  static bool enabled = true;

  /// ビューアへ渡す道。 まだ調べていない / 印が無い時は元の道のまま。
  static String resolve(String? path) {
    if (path == null || path.isEmpty) return path ?? '';
    if (!enabled) return path;
    return _cache[path]?.out ?? path;
  }

  /// 焼き込んだ印の数 (0 = 無し / まだ調べていない。 -1 = 控えの使い回し)。
  static int markupCount(String? path) =>
      path == null ? 0 : (_cache[path]?.count ?? 0);

  /// ファイルを書き換えた後に呼ぶ (描き込みの焼き込み等)。
  static void invalidate(String? path) {
    if (path == null) return;
    final out = _cache.remove(path)?.out;
    if (out == null) return;
    try {
      final f = File(out);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 調べて、 必要なら控えを作る。
  /// 戻り値 true = [resolve] の答えがこの呼び出しで変わった
  /// (= 呼んだ側はビューアを読み直す)。
  static Future<bool> ensure(String? path) async {
    if (path == null || path.isEmpty || !enabled) return false;
    final before = resolve(path);
    final pending = _inflight[path];
    if (pending != null) {
      await pending;
      return resolve(path) != before;
    }
    final work = _run(path);
    _inflight[path] = work;
    try {
      await work;
    } finally {
      _inflight.remove(path);
    }
    return resolve(path) != before;
  }

  static Future<void> _run(String path) async {
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      final st = f.statSync();
      if (st.size <= 0 || st.size > _kMaxBytes) return;
      final mtimeMs = st.modified.millisecondsSinceEpoch;
      final hit = _cache[path];
      if (hit != null && hit.mtimeMs == mtimeMs && hit.size == st.size) {
        final out = hit.out;
        // 控えが消えていた時だけ作り直す。
        if (out == null || File(out).existsSync()) return;
        _cache.remove(path);
      }
      final sep = Platform.pathSeparator;
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}$sep$_kCacheDirName');
      final outPath = '${dir.path}$sep${_key(path, mtimeMs, st.size)}.pdf';
      // すでに同じ中身の控えがあれば作り直さない。
      final done = File(outPath);
      if (done.existsSync() && done.lengthSync() > 0) {
        _cache[path] = _Entry(outPath, mtimeMs, st.size, -1);
        return;
      }
      final res = await compute(flattenPdfMarkupWorker,
          <String, Object?>{'src': path, 'out': outPath});
      final count = (res['count'] as num?)?.toInt() ?? 0;
      final err = res['error'];
      if (err != null) debugPrint('PDF の印の焼き込みに失敗: $err');
      if (count > 0 && done.existsSync() && done.lengthSync() > 0) {
        _cache[path] = _Entry(outPath, mtimeMs, st.size, count);
        unawaited(_prune(dir, outPath));
      } else {
        _cache[path] = _Entry(null, mtimeMs, st.size, 0);
      }
    } catch (e) {
      debugPrint('PDF の印を調べられませんでした: $e');
    }
  }

  /// 道 + 更新時刻 + 大きさ から、 控えの名前を作る (FNV-1a)。
  static String _key(String path, int mtimeMs, int size) {
    var h = 0x811c9dc5;
    for (final c in path.toLowerCase().codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return '${h.toRadixString(16)}_${mtimeMs.toRadixString(16)}_$size';
  }

  /// 控えを溜め込みすぎないよう、 古い物から消す (最大 24 本 / 30 日)。
  static Future<void> _prune(Directory dir, String keep) async {
    try {
      if (!dir.existsSync()) return;
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.pdf'))
          .toList();
      final now = DateTime.now();
      final live = _cache.values.map((e) => e.out).whereType<String>().toSet();
      files.sort(
          (a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        if (f.path == keep || live.contains(f.path)) continue;
        final old = now.difference(f.statSync().modified).inDays > 30;
        if (i >= 24 || old) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
