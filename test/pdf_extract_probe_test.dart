// テスト用 PDF を、 アプリ本体と同じ Syncfusion のライブラリで読めるか
// 確かめる (= 画面の _extractAttachmentTextForAi と同じ経路)。
// Syncfusion の PDF は dart:ui を要するので flutter test で動かす。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sfpdf;

String _extract(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: 'テスト用 PDF が見つからない: $path');
  final doc = sfpdf.PdfDocument(inputBytes: f.readAsBytesSync());
  try {
    return sfpdf.PdfTextExtractor(doc).extractText();
  } finally {
    doc.dispose();
  }
}

void main() {
  test('markdown_source_sample.pdf から日本語の本文を取り出せる', () {
    final text = _extract(r'docs\test_assets\markdown_source_sample.pdf');
    // ignore: avoid_print
    print('PDF_PROBE ${jsonEncode({
          'chars': text.runes.length,
          'tofu': text.contains('�'),
        })}');
    expect(text.runes.length, greaterThan(1800));
    expect(text.contains('�'), isFalse, reason: '文字化けしている');
    expect(text.contains('あおぞら'), isTrue);
    expect(text.contains('次回報告は'), isTrue, reason: '最終ページまで読めていない');
  });

  test('c_exam_sample.pdf からコード・表・図を取り出せる', () {
    final text = _extract(r'docs\test_assets\c_exam_sample.pdf');
    // ignore: avoid_print
    print('C_EXAM_PROBE ${jsonEncode({
          'chars': text.runes.length,
          'tofu': text.contains('�'),
        })}');
    expect(text.contains('�'), isFalse, reason: '文字化けしている');
    // コード (関数名と制御構文)
    expect(text.contains('alleven'), isTrue);
    expect(text.contains('sortnma'), isTrue);
    expect(text.contains('sum_to'), isTrue);
    // 表 (計算量・用語)
    expect(text.contains('マージソート'), isTrue);
    expect(text.contains('O(N log N)') || text.contains('O(N log N)'), isTrue);
    expect(text.contains('ヒープ領域'), isTrue);
    // 図 (フローチャートの中の文字)
    expect(text.contains('sum = 0') || text.contains('sum'), isTrue);
    // 最終章まで届いている
    expect(text.contains('NULL'), isTrue);
  });
}
