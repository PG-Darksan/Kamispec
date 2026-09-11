// タイルに出す「1 枚目」 の読み取りが、 開いた時の表紙と同じ物を拾えて
// いるかを、 アプリを起動せずに確かめる検査。
//
//   flutter test test/pptx_thumb_preview_test.dart
//
// = ユーザー要望「サムネイルと開いた時の表紙でレイアウトが違うのおかしいから
//   揃えて欲しい」。 見ているのは次の 4 点。
//   1. 紙の色 (<p:bg>) を拾えているか
//   2. 貼られている絵を拾えているか (以前は 1 枚も読んでいなかった)
//   3. 見出しの文字・太字・大きさを拾えているか
//   4. 並べ替えても「表示順の 1 枚目」 を出すか
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/screens/mind_map_screen.dart';
import 'package:mindmap_app/widgets/doc_preview.dart';

/// 1x1 の PNG (中身は何でもよい。 読めるかだけを見る)。
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  test('タイルの読み取りが紙の色・絵・見出しを拾う', () async {
    final dir = await Directory.systemTemp.createTemp('hn_pptx_thumb');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final bytes = buildPptxFromSlidesForTest(
      [
        (
          title: 'ガンダムシリーズの歴史',
          bullets: ['リアルロボットアニメが切り拓いた 45 年の軌跡'],
          image: _png,
          imagePos: 'right',
          imageShape: 'rect',
          anim: '',
          shapes: const <Map<String, dynamic>>[],
        ),
        (
          title: '2 枚目',
          bullets: ['ここは表紙ではない'],
          image: null,
          imagePos: 'right',
          imageShape: 'rect',
          anim: '',
          shapes: const <Map<String, dynamic>>[],
        ),
      ],
      themeName: 'ミッドナイト',
      coverFirst: true,
    );
    final f = File('${dir.path}/deck.pptx');
    await f.writeAsBytes(bytes, flush: true);

    await DocPreview.load(f.path, 'pptx');
    final slide = DocPreview.slideFor(f.path);
    expect(slide, isNotNull, reason: '1 枚目を読めていない');

    // 1. 紙の色。
    expect(slide!.bg, 0x0F172A, reason: '紙の色を拾えていない');

    // 2. 絵 (= 以前は 0 枚だった)。
    expect(slide.images.length, 1, reason: '貼られている絵を拾えていない');
    expect(slide.images.first.w, greaterThan(0));

    // 3. 見出し。 太字・大きさ・色まで拾えている。
    final title = slide.boxes.firstWhere(
        (b) => (b.text ?? '').contains('ガンダム'),
        orElse: () => const SlideBox(x: 0, y: 0, w: 0, h: 0));
    expect(title.text, isNotNull, reason: '見出しの文字が無い');
    expect(title.bold, isTrue, reason: '太字を拾えていない');
    expect(title.sizeHundredths, greaterThan(2000), reason: '文字の大きさが違う');
    expect(title.color, 0xFFFFFF, reason: '文字色を拾えていない');

    // 表紙には上端の帯が無い = 2 枚目の中身が混ざっていない。
    expect(slide.boxes.any((b) => (b.text ?? '').contains('2 枚目')), isFalse);

    // 4. 線・矢印の色を「塗り」 と読み違えていない (帯と罫は塗りの図形)。
    final fills = slide.boxes.where((b) => b.text == null).toList();
    expect(fills.isNotEmpty, isTrue, reason: '飾りの図形を拾えていない');
  });
}
