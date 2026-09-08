import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/widgets/anchor_below_layout.dart';

/// パレットが「押した所の下、 入らなければ上」 に出る事を確かめる
/// (= ユーザー要望: 図形の挿入のパレットを端子と同じ出し方にする)。
void main() {
  const view = Size(800, 600);

  /// 実際に並べてみて、 子の左上がどこに来たかを返す。
  Future<Offset> place(
      WidgetTester tester, Offset anchor, Size childSize) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: view.width,
            height: view.height,
            child: Stack(children: [
              Positioned.fill(
                child: CustomSingleChildLayout(
                  delegate: AnchorBelowLayout(anchor),
                  child: SizedBox(
                      key: key,
                      width: childSize.width,
                      height: childSize.height),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    final stackBox =
        tester.renderObject<RenderBox>(find.byType(Stack).first);
    final childBox = key.currentContext!.findRenderObject()! as RenderBox;
    return stackBox.globalToLocal(childBox.localToGlobal(Offset.zero));
  }

  testWidgets('カーソルの下に、 横は中央を合わせて出る', (tester) async {
    final at = await place(tester, const Offset(400, 100), const Size(300, 120));
    expect(at.dy, 100 + 14); // gap の分だけ下
    expect(at.dx, 400 - 150); // 中央合わせ
  });

  testWidgets('下に入らない時は上へ回る', (tester) async {
    final at = await place(tester, const Offset(400, 560), const Size(300, 120));
    expect(at.dy, 560 - 14 - 120);
  });

  testWidgets('上にも下にも入らない時は画面の中へ収める', (tester) async {
    final at = await place(tester, const Offset(400, 40), const Size(300, 580));
    expect(at.dy, 600 - 580 - 8);
    expect(at.dy, greaterThanOrEqualTo(8.0));
  });

  testWidgets('横は画面の縁からはみ出さない', (tester) async {
    final left = await place(tester, const Offset(5, 100), const Size(300, 80));
    expect(left.dx, 8);
    final right =
        await place(tester, const Offset(795, 100), const Size(300, 80));
    expect(right.dx, 800 - 300 - 8);
  });

  testWidgets('子は画面より大きくならない', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: view.width,
            height: view.height,
            child: Stack(children: [
              Positioned.fill(
                child: CustomSingleChildLayout(
                  delegate: const AnchorBelowLayout(Offset(400, 100)),
                  // 無制限に広がろうとする子。
                  child: SizedBox.expand(key: key),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    final box = key.currentContext!.findRenderObject()! as RenderBox;
    expect(box.size.width, view.width - 16);
    expect(box.size.height, view.height - 16);
  });
}
