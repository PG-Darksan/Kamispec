// ギャラリーの格子が 1000 個ぶんのマス目を**描ける範囲に**持てるかを見る。
//
// ★ = 動作検証の不具合「多数のギャラリー要素を一括追加すると同じ座標へ大量に
//   重なる」。 994 件足したら 502 件が (120,120) に、 さらに y=20000 の各列に
//   11 件ずつ重なった、 という報告。 原因は 2 つあり、
//   (1) 列が 5 列で打ち止めだった → 件数に応じて広げる (b442 で直した)
//   (2) 列を増やす計算が「100 段ある」 前提だったが、 段の y は
//       120 + r*225 なので 88 段より下はキャンバスの端 (20000) で丸められ、
//       全部同じ y に潰れていた → 描ける段数で割る (この回で直した)
//   算数を間違えるとまた静かに重なるので、 ここで数式を固定する。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/providers/mind_map_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('描ける段数は端を越えない', () {
    const rowH = MindMapProvider.kShelfTileW * 1.1;
    const pitch = rowH + MindMapProvider.kShelfGap;
    final rows = MindMapProvider.kShelfUsableRows;

    // 最後の段の**下端**がキャンバスの端の内側にある。
    final lastBottom =
        MindMapProvider.kShelfOuterControlPad + (rows - 1) * pitch + rowH;
    expect(lastBottom, lessThanOrEqualTo(MindMapProvider.kShelfCanvasLimit));

    // 1 段でも足したら越える (= 段数を取りこぼしていない)。
    final oneMore =
        MindMapProvider.kShelfOuterControlPad + rows * pitch + rowH;
    expect(oneMore, greaterThan(MindMapProvider.kShelfCanvasLimit));
  });

  test('上限の 1000 個が描ける範囲のマス目に収まる', () {
    final rows = MindMapProvider.kShelfUsableRows;
    final needCols = (MindMapProvider.kShelfMaxVisibleItems / rows).ceil();
    // 列の上限の中で足りている。
    expect(needCols, lessThanOrEqualTo(MindMapProvider.kShelfMaxGridCols));
    expect(rows * needCols,
        greaterThanOrEqualTo(MindMapProvider.kShelfMaxVisibleItems));
    // 横幅もキャンバスに収まる (右へはみ出して切れない)。
    final width = MindMapProvider.kShelfOuterControlPad +
        needCols *
            (MindMapProvider.kShelfTileW + MindMapProvider.kShelfGap);
    expect(width, lessThan(MindMapProvider.kShelfCanvasLimit));
  });

  test('ギャラリーへ 1000 個足しても座標が重ならない', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final provider = MindMapProvider();
    for (var i = 0; i < 300 && !provider.pageLoadSettled; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    provider.addBookshelfPage(name: 'shelf-capacity');
    final page = provider.pages.firstWhere((p) => p.name == 'shelf-capacity');

    const want = MindMapProvider.kShelfMaxVisibleItems;
    var made = 0;
    for (var i = 0; i < want; i++) {
      if (provider.mcpAddGalleryItem(page.id, text: 'tile $i') != null) made++;
    }
    expect(made, want, reason: '上限ちょうどまでは入るはず');

    // 1001 個目は理由を付けて断られる (= 上限を守る)。
    expect(provider.mcpAddGalleryItem(page.id, text: 'over'), isNull);

    final seen = <String>{};
    final dupes = <String>[];
    for (final n in page.nodes.values) {
      final key = '${n.position.dx.toStringAsFixed(1)},'
          '${n.position.dy.toStringAsFixed(1)}';
      if (!seen.add(key)) dupes.add(key);
      expect(n.position.dy,
          lessThanOrEqualTo(MindMapProvider.kShelfCanvasLimit),
          reason: '端で丸められた座標が残っている');
    }
    expect(dupes, isEmpty,
        reason: '同じ座標に重なったタイルがある: ${dupes.take(5).toList()}');
    expect(seen.length, page.nodes.length);
    provider.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
