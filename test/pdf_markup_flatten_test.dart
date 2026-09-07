// 「PDF に元から入っている囲みの印が、 アプリで開いても出ない」 の直しと、
// b323 で直した「出るけれど場所がずれる」 の見張り (= ユーザー報告)。
//
// 場所の検算は、 圧縮を切って保存した中身の `re` / `cm` を読んで、
// 元の /Rect と一致するかを見る。 描画は 1 本の座標系に乗っているので、
// これが合っていれば画面でもそのまま合う。
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/services/pdf_markup.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sfpdf;

/// 実物の PDF (手元にある時だけ確かめる)。
const String kRealPdf =
    r'C:\Users\Study\OneDrive\ドキュメント\attachments\64c251b5-d701-48de-aece-7fc730a4070c_daaf22f8-5e7c-4fa3-a243-c49f781f6310_64c251b5-d701-48de-aece-7fc730a4070c_crown_acc.pdf';

void main() {
  test('元から入っている囲みの印がページへ焼き込まれる', () async {
    final dir = await Directory.systemTemp.createTemp('pdfmarkup');
    final src = File('${dir.path}${Platform.pathSeparator}src.pdf');
    final out = File('${dir.path}${Platform.pathSeparator}out.pdf');

    // ── 印の入った PDF を作る ──
    final doc = sfpdf.PdfDocument();
    final page = doc.pages.add();
    page.graphics.drawString(
      'image here',
      sfpdf.PdfStandardFont(sfpdf.PdfFontFamily.helvetica, 18),
      bounds: const Rect.fromLTWH(60, 90, 300, 30),
    );
    page.annotations.add(sfpdf.PdfRectangleAnnotation(
      const Rect.fromLTWH(50, 80, 220, 60),
      '画像の位置',
      color: sfpdf.PdfColor(0, 180, 90),
      innerColor: sfpdf.PdfColor(0, 180, 90),
    ));
    page.annotations.add(sfpdf.PdfEllipseAnnotation(
      const Rect.fromLTWH(300, 200, 120, 120),
      '丸の印',
      color: sfpdf.PdfColor(220, 40, 40),
    ));
    await src.writeAsBytes(await doc.save(), flush: true);
    doc.dispose();

    final before = sfpdf.PdfDocument(inputBytes: src.readAsBytesSync());
    expect(before.pages[0].annotations.count, 2);
    before.dispose();

    // ── 焼き込む ──
    final res = await flattenPdfMarkupWorker(
        <String, Object?>{'src': src.path, 'out': out.path});
    expect(res['error'], isNull);
    expect((res['count'] as num).toInt(), 2);
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync(), greaterThan(0));

    // ── 控えのページからは印が消え、 中身へ溶け込んでいる ──
    final after = sfpdf.PdfDocument(inputBytes: out.readAsBytesSync());
    expect(after.pages[0].annotations.count, 0);
    after.dispose();

    // 元のファイルは触っていない。
    final origin = sfpdf.PdfDocument(inputBytes: src.readAsBytesSync());
    expect(origin.pages[0].annotations.count, 2);
    origin.dispose();

    await dir.delete(recursive: true);
  });

  test('印が無い PDF では控えを作らない', () async {
    final dir = await Directory.systemTemp.createTemp('pdfmarkup2');
    final src = File('${dir.path}${Platform.pathSeparator}plain.pdf');
    final out = File('${dir.path}${Platform.pathSeparator}plain_out.pdf');
    final doc = sfpdf.PdfDocument();
    doc.pages.add().graphics.drawString(
          'no markup',
          sfpdf.PdfStandardFont(sfpdf.PdfFontFamily.helvetica, 14),
          bounds: const Rect.fromLTWH(40, 40, 200, 20),
        );
    await src.writeAsBytes(await doc.save(), flush: true);
    doc.dispose();

    final res = await flattenPdfMarkupWorker(
        <String, Object?>{'src': src.path, 'out': out.path});
    expect((res['count'] as num).toInt(), 0);
    expect(out.existsSync(), isFalse);

    await dir.delete(recursive: true);
  });

  // ★ b323: 場所がずれないことの見張り (= ユーザー報告)。
  //
  //   実物と同じ /Rect の印を置き、 焼き込んだ後の中身を読んで
  //   元の /Rect と一致するかを見る。 昔の作り (外観ストリームを
  //   syncfusion に置かせる) では、 ここが 33.69 pt ぶん右へずれていた。
  test('焼き込んだ印が元の /Rect と同じ場所に来る', () async {
    const w = 822.047, h = 566.929;
    // 実物の 1 件目と同じ枠。
    const rx0 = 33.6875, ry0 = 442.304, rx1 = 371.02085, ry1 = 501.63734;

    final doc = sfpdf.PdfDocument();
    doc.pageSettings.size = const Size(w, h);
    doc.pageSettings.margins.all = 0;
    doc.pages.add();
    final made = await doc.save();
    doc.dispose();

    // 読み込んだページとして扱い、 圧縮を切って焼き込む。
    final doc2 = sfpdf.PdfDocument(inputBytes: made);
    doc2.compressionLevel = sfpdf.PdfCompressionLevel.none;
    final page = doc2.pages[0];
    final ph = page.size.height;
    // /Rect (左下原点) → bounds (左上原点)。
    final bounds =
        Rect.fromLTWH(rx0, ph - ry1, rx1 - rx0, ry1 - ry0);
    page.graphics.drawRectangle(
      pen: sfpdf.PdfPen(sfpdf.PdfColor(255, 0, 0), width: 1),
      bounds: bounds,
    );
    final outBytes = await doc2.save();
    doc2.dispose();

    final text = String.fromCharCodes(outBytes.map((b) => b < 128 ? b : 46));
    final re = RegExp(r'([-0-9.]+) ([-0-9.]+) ([-0-9.]+) ([-0-9.]+) re')
        .firstMatch(text);
    final cm = RegExp(
            r'1 0 0 1 ([-0-9.]+) ([-0-9.]+) cm')
        .firstMatch(text);
    expect(re, isNotNull, reason: '長方形が中身に書かれていない');
    expect(cm, isNotNull, reason: '座標系の移動が見つからない');

    final dy = double.parse(cm!.group(2)!);
    final x = double.parse(re!.group(1)!);
    final y = double.parse(re.group(2)!);
    final rw = double.parse(re.group(3)!);
    final rh = double.parse(re.group(4)!);

    // 紙の座標へ戻す。 高さは負で書かれる (上から下へ) ので足し直す。
    final pdfLeft = x;
    final pdfTop = dy + y;
    final pdfBottom = pdfTop + rh;
    expect(pdfLeft, closeTo(rx0, 0.05));
    expect(pdfTop, closeTo(ry1, 0.05));
    expect(pdfBottom, closeTo(ry0, 0.05));
    expect(rw, closeTo(rx1 - rx0, 0.05));
  });

  test('実物の PDF: すべての Square が焼き込まれる (手元にある時だけ)', () async {
    final f = File(kRealPdf);
    if (!f.existsSync()) {
      // ignore: avoid_print
      print('実物が無いので飛ばす: $kRealPdf');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('pdfmarkup3');
    final out = File('${dir.path}${Platform.pathSeparator}real_out.pdf');
    final res = await flattenPdfMarkupWorker(
        <String, Object?>{'src': f.path, 'out': out.path});
    expect(res['error'], isNull);
    final n = (res['count'] as num).toInt();
    // ignore: avoid_print
    print('焼き込んだ印 = $n');
    expect(n, greaterThan(0));
    expect(out.existsSync(), isTrue);

    // 出来た控えが読めて、 リンクは残っていること。
    final after = sfpdf.PdfDocument(inputBytes: out.readAsBytesSync());
    var squares = 0, links = 0;
    for (var i = 0; i < after.pages.count; i++) {
      final anns = after.pages[i].annotations;
      for (var j = 0; j < anns.count; j++) {
        final a = anns[j];
        if (a is sfpdf.PdfRectangleAnnotation) squares++;
        if (a is sfpdf.PdfDocumentLinkAnnotation) links++;
      }
    }
    after.dispose();
    // ignore: avoid_print
    print('控えに残った Square=$squares / リンク=$links');
    expect(squares, 0, reason: '焼き込んだ印が注釈として残っている');
    expect(links, greaterThan(0), reason: 'リンクまで消してはいけない');

    await dir.delete(recursive: true);
  });
}
