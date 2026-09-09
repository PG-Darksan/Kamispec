// AI が作る .pptx が「開ける形」 になっているかを、 アプリを起動せずに
// 確かめる使い捨ての検査 (= 動作確認の代わり)。
//
//   flutter test test/pptx_writer_test.dart
//
// 見ているのは次の 3 点。
//   1. zip として開けて、 pptx に要る部品が全部入っているか
//   2. 飾りの図形 (<p:sp> + prstGeom) がスライドに書かれているか
//   3. 絵 (<p:pic> + ppt/media) が置き場所どおりに書かれているか
//
// = ユーザー要望「おしゃれなカフェのパワポにしてとお願いしても珈琲の画像や
//   図形が挿入されず味気ない」 の裏取り。
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/screens/mind_map_screen.dart';

void main() {
  test('AI が頼んだ図形と絵が pptx に書き出される', () {
    // 1x1 の PNG (中身は何でもよい。 media に入るかだけを見る)。
    final png = Uint8List.fromList(const [
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

    final bytes = buildPptxFromSlidesForTest([
      (
        title: 'おしゃれなカフェ',
        bullets: const ['珈琲', '焼き菓子'],
        image: png,
        imagePos: 'right',
        shapes: <Map<String, dynamic>>[
          {'kind': 'ellipse', 'x': 72, 'y': 8, 'w': 22, 'h': 30, 'fill': 'D4AF37'},
          {'kind': 'rect', 'x': 0, 'y': 92, 'w': 100, 'h': 8, 'fill': '1E293B'},
        ],
      ),
      (
        title: '全面の絵',
        bullets: const ['文字が上に乗る'],
        image: png,
        imagePos: 'full',
        shapes: const <Map<String, dynamic>>[],
      ),
    ]);

    final arch = ZipDecoder().decodeBytes(bytes);
    final names = arch.files.map((f) => f.name).toSet();

    // 1. pptx に要る部品
    for (final need in [
      '[Content_Types].xml',
      '_rels/.rels',
      'ppt/presentation.xml',
      'ppt/_rels/presentation.xml.rels',
      'ppt/slides/slide1.xml',
      'ppt/slides/_rels/slide1.xml.rels',
      'ppt/slideMasters/slideMaster1.xml',
      'ppt/slideLayouts/slideLayout1.xml',
      'ppt/theme/theme1.xml',
    ]) {
      expect(names, contains(need), reason: '$need が入っていない');
    }

    String part(String n) => String.fromCharCodes(
        arch.files.firstWhere((f) => f.name == n).content as List<int>);

    final s1 = part('ppt/slides/slide1.xml');
    // 2. 飾りの図形が 2 個
    expect(RegExp('prst="ellipse"').hasMatch(s1), isTrue, reason: '丸が無い');
    expect('Deco'.allMatches(s1).length, greaterThanOrEqualTo(2),
        reason: '飾りの図形が足りない');
    // 3. 絵が右側 (x=5180000) に置かれている
    expect(s1.contains('<p:pic>'), isTrue, reason: '絵が無い');
    expect(s1.contains('x="5180000"'), isTrue, reason: '絵が右に無い');
    expect(names, contains('ppt/media/image1.png'));
    expect(part('ppt/slides/_rels/slide1.xml.rels').contains('media/image1.png'),
        isTrue,
        reason: '絵の関連付けが無い');

    // 全面の絵は左上から画面いっぱい
    final s2 = part('ppt/slides/slide2.xml');
    expect(s2.contains('<a:off x="0" y="0"/>'), isTrue, reason: '全面になっていない');
    expect(s2.contains('cx="9144000" cy="6858000"'), isTrue,
        reason: '全面の大きさが違う');

    // XML として開始/終了タグの数が釣り合っている (= 壊れた XML を弾く)
    for (final n in ['ppt/slides/slide1.xml', 'ppt/slides/slide2.xml']) {
      final x = part(n);
      expect('<p:sp>'.allMatches(x).length, '</p:sp>'.allMatches(x).length,
          reason: '$n の <p:sp> が釣り合っていない');
      expect('<p:pic>'.allMatches(x).length, '</p:pic>'.allMatches(x).length,
          reason: '$n の <p:pic> が釣り合っていない');
    }
  });

  // = 点検で見つかった不具合。 絵が無いのに imagePos だけ 'left' だと、
  //   本文の枠が右へ寄ったまま幅は元のままで、 紙からはみ出していた。
  //   絵が無くなる道は普通にある (指示を書かなかった / 生成に失敗した /
  //   1 回の上限を超えた)。
  test('絵が無い時は imagePos を無視して、 本文が紙からはみ出さない', () {
    const slideW = 9144000;
    final bytes = buildPptxFromSlidesForTest([
      (
        title: '絵は無い',
        bullets: const ['はみ出さない事'],
        image: null,
        imagePos: 'left',
        shapes: const <Map<String, dynamic>>[],
      ),
    ]);
    final arch = ZipDecoder().decodeBytes(bytes);
    final xml = String.fromCharCodes(arch.files
        .firstWhere((f) => f.name == 'ppt/slides/slide1.xml')
        .content as List<int>);
    // 本文の枠 (Body) の位置と幅を取り出して、 右端が紙の中に収まるか見る。
    final m = RegExp(r'name="Body".*?<a:off x="(\d+)" y="\d+"/>'
            r'<a:ext cx="(\d+)"')
        .firstMatch(xml);
    expect(m, isNotNull, reason: '本文の枠が見つからない');
    final x = int.parse(m!.group(1)!);
    final cx = int.parse(m.group(2)!);
    expect(x + cx, lessThanOrEqualTo(slideW),
        reason: '本文が紙の右端からはみ出している (x=$x cx=$cx)');
  });

  // 線は塗る面が無いので、 fill しか書かれていなくても <a:ln> を出す。
  test('線の図形は色が付いた <a:ln> で書き出される', () {
    final bytes = buildPptxFromSlidesForTest([
      (
        title: '線',
        bullets: const <String>[],
        image: null,
        imagePos: 'right',
        shapes: <Map<String, dynamic>>[
          {'kind': 'line', 'x': 10, 'y': 50, 'w': 80, 'h': 0.5, 'fill': 'D4AF37'},
        ],
      ),
    ]);
    final arch = ZipDecoder().decodeBytes(bytes);
    final xml = String.fromCharCodes(arch.files
        .firstWhere((f) => f.name == 'ppt/slides/slide1.xml')
        .content as List<int>);
    expect(xml.contains('prst="line"'), isTrue);
    expect(RegExp(r'<a:ln w="\d+"><a:solidFill><a:srgbClr val="D4AF37"')
        .hasMatch(xml), isTrue,
        reason: '線に色が付いていない (何も描かれない図形になる)');
  });
}
