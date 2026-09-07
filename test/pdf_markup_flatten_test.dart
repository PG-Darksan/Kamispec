// 「PDF に元から入っている囲みの印が、 アプリで開いても出ない」 の直しを
// 確かめる (= ユーザー報告)。
//
// 印 (Square / Circle) を入れた PDF を作り、 焼き込みの本体を通した後に
//   ・焼き込んだ数が 0 でない
//   ・出来た控えのページから注釈が消えている (= 中身へ溶け込んだ)
// ことを見る。
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/services/pdf_markup.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sfpdf;

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
    final square = sfpdf.PdfRectangleAnnotation(
      const Rect.fromLTWH(50, 80, 220, 60),
      '画像の位置',
      color: sfpdf.PdfColor(0, 180, 90),
      innerColor: sfpdf.PdfColor(0, 180, 90),
    );
    page.annotations.add(square);
    final circle = sfpdf.PdfEllipseAnnotation(
      const Rect.fromLTWH(300, 200, 120, 120),
      '丸の印',
      color: sfpdf.PdfColor(220, 40, 40),
    );
    page.annotations.add(circle);
    await src.writeAsBytes(await doc.save(), flush: true);
    doc.dispose();

    // 作った直後の PDF には印が 2 つ入っている。
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
}
