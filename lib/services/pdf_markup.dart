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
// そちらを見せる。 焼き込みには元の PDF が持っている見た目 (/AP の外観
// ストリーム) をそのまま使うので、 他のアプリで見た時と同じ絵になる。
//
//   ・**元のファイルは一切書き換えない**。 控えはアプリの作業場所に作る。
//   ・メモやマーカー、 描き込みの控えは今までどおり**元の道**を鍵にする
//     (ここが変わると、 今までの書き込みが行方不明になる)。
//   ・文字のマーカーと付箋は焼き込まない (ビューアが自分で描くので、
//     焼き込むと二重に濃くなってしまう)。
//   ・リンクと入力欄 (Widget) も焼き込まない (押せなくなるため)。
//
// ── 限界 ─────────────────────────────────────────────────────────
// syncfusion_flutter_pdf が読み込んだ PDF から組み立て直せる注釈は
// Link / Line / Circle / Square / Polygon / Widget / 文字マーカー / 付箋 だけ。
// 手書き (Ink) や吹き出し (FreeText)、 スタンプ (Stamp) はそもそも物として
// 出てこないので、 ここでも焼き込めない。 囲みの印はほぼ Square / Circle
// なので、 今回の用途はこれで足りる。
import 'dart:async';
import 'dart:io';

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
      final anns = page.annotations;
      for (var j = 0; j < anns.count; j++) {
        final sfpdf.PdfAnnotation a;
        try {
          a = anns[j];
        } catch (_) {
          continue;
        }
        // ★ 焼き込むのは「ビューアが自分では描かない印」 だけ。
        //   文字マーカー / 付箋 (二重に濃くなる)、 リンク / 入力欄
        //   (押せなくなる) は触らない。
        if (a is sfpdf.PdfRectangleAnnotation ||
            a is sfpdf.PdfEllipseAnnotation ||
            a is sfpdf.PdfLineAnnotation ||
            a is sfpdf.PdfPolygonAnnotation) {
          try {
            a.flatten();
            count++;
          } catch (_) {}
        }
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
