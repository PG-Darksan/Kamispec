// 検算: AI が作るノードの幅が、見出しを変な位置で折り返さないか。
//
// 本物の `aiNodeWidthForTitle` (mind_map_provider.dart の末尾) を直接呼ぶ。
// 写しではないので、実装を直したらここも必ず追従する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/providers/mind_map_provider.dart';

/// その幅で描いた時に何行になるか / 最後の行の文字数。
({int lines, int lastLineChars}) layoutInfo(
    String title, double width, double size) {
  final tp = TextPainter(
    text: TextSpan(
      text: title,
      style: TextStyle(fontSize: size, fontWeight: FontWeight.w700),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width - 30.0);
  final metrics = tp.computeLineMetrics();
  if (metrics.isEmpty) return (lines: 0, lastLineChars: 0);
  final lastTop = metrics.last.baseline - metrics.last.ascent;
  final start = tp.getPositionForOffset(Offset(0, lastTop + 1)).offset;
  return (lines: metrics.length, lastLineChars: title.length - start);
}

void main() {
  const cases = <String>[
    'インスタグラムのジャンル',
    'ファッション',
    'グルメ・カフェ',
    '美容・コスメ',
    '旅行・観光',
    'ライフスタイル',
    'とても長い見出しの例で、これは一行にはどう考えても収まらないはずの文章です',
    'Short',
    'A fairly long English heading that will not fit on one line at all',
    '機械学習',
    'データベース設計の基礎',
  ];

  testWidgets('AI ノードの幅は変な折り返しを作らない', (tester) async {
    for (final size in <double>[12, 15, 20]) {
      for (final t in cases) {
        final w = aiNodeWidthForTitle(t, size);
        final info = layoutInfo(t, w, size);
        debugPrint('size=$size w=${w.toStringAsFixed(1)} '
            'lines=${info.lines} last=${info.lastLineChars}  "$t"');
        expect(w, inInclusiveRange(140.0, 320.0),
            reason: '"$t" (size=$size) の幅が範囲外');
        // 2 行以上になる時、最後の行に 1 文字だけ残さない
        // (= 「インスタグラムのジャン / ル」 を防ぐのが目的)。
        if (info.lines > 1) {
          expect(info.lastLineChars, greaterThan(1),
              reason: '"$t" (size=$size, w=$w) の最後の行が '
                  '${info.lastLineChars} 文字しかない');
        }
      }
    }
  });

  testWidgets('短い見出しは折り返さない', (tester) async {
    for (final t in const [
      'ファッション',
      'グルメ・カフェ',
      'インスタグラムのジャンル',
    ]) {
      final w = aiNodeWidthForTitle(t, 15);
      expect(layoutInfo(t, w, 15).lines, 1, reason: '"$t" が折り返した');
    }
  });
}
