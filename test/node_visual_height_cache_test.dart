// visualHeight の覚え書き (= 画面が固まる対策) が、
// **古い答えを返さない**ことの見張り。
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/models/mind_map_node.dart';

void main() {
  test('もとの値が変わったら高さも変わる', () {
    final n = MindMapNode(
      id: 'a',
      title: 'タイトル',
      position: Offset.zero,
      width: 200,
      height: 50,
      memoText: '短いメモ',
    );
    final h1 = n.visualHeight;
    // 2 回目は覚え書きから返る (同じ値)。
    expect(n.visualHeight, h1);

    // メモを長くすれば高くなる。
    n.memoText = 'あ' * 400;
    final h2 = n.visualHeight;
    expect(h2, greaterThan(h1), reason: 'メモを増やしたのに高さが変わらない');

    // 幅を広げれば行数が減って低くなる。
    n.width = 600;
    final h3 = n.visualHeight;
    expect(h3, lessThan(h2), reason: '幅を広げたのに高さが変わらない');

    // 文字の大きさを変えても効く。
    n.memoFontSize = 22;
    final h4 = n.visualHeight;
    expect(h4, greaterThan(h3), reason: '文字を大きくしたのに高さが変わらない');

    // アプリの既定を変えても効く (個別指定を外した時)。
    n.memoFontSize = null;
    final h5 = n.visualHeight;
    MindMapNode.defaultMemoFontSizeHint = 22;
    final h6 = n.visualHeight;
    expect(h6, greaterThan(h5), reason: '既定の文字の大きさが効いていない');
    MindMapNode.defaultMemoFontSizeHint = 12;
  });

  test('高さ固定 (ギャラリー) はそのまま返る', () {
    final n = MindMapNode(
      id: 'b',
      title: 'x',
      position: Offset.zero,
      width: 200,
      height: 120,
      memoText: 'あ' * 300,
      clampHeight: true,
    );
    expect(n.visualHeight, 120);
    n.memoText = 'あ' * 900;
    expect(n.visualHeight, 120);
  });
}
