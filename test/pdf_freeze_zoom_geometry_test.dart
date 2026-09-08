import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// PDF の固定の帯が「拡大しても本物と揃う」 ことの土台を確かめる。
///
/// = ユーザー要望「PDF の拡大率を上げた後に固定できるように」。
///   b336 の実装は `PdfPageView` が組み立て時に持つ大きさ (contentSize) を
///   そのまま画面の大きさとして使っていた。 拡大は先祖の Transform が絵を
///   伸ばしているだけなので、 その値は**拡大しても変わらない** = 帯だけ
///   等倍で描かれ、 横へ送ると貼り先が画面の外へ出ていた。
///
/// ここで確かめるのは、 直した後に使っている測り方
/// (`overlay.globalToLocal(page.localToGlobal(...))`) が、 拡大と移動の
/// **両方**を拾うかどうか。
void main() {
  /// 拡大率 [scale]、 ずらし [pan] の下で、 ページの画面上の四角を測る。
  Future<Rect> measure(WidgetTester tester,
      {required double scale,
      required Offset pan,
      Size page = const Size(400, 600)}) async {
    final overlayKey = GlobalKey();
    final pageKey = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 800,
            height: 600,
            child: Stack(children: [
              // 本物のビューア相当: Transform で拡大 + 移動する。
              Positioned.fill(
                child: ClipRect(
                  child: Transform(
                    transform: Matrix4.identity()
                      ..translate(pan.dx, pan.dy)
                      ..scale(scale, scale),
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      maxWidth: double.infinity,
                      maxHeight: double.infinity,
                      child: SizedBox(
                          key: pageKey, width: page.width, height: page.height),
                    ),
                  ),
                ),
              ),
              // 重ね面 (帯を描く所)。
              Positioned.fill(child: SizedBox(key: overlayKey)),
            ]),
          ),
        ),
      ),
    );
    final overlay =
        overlayKey.currentContext!.findRenderObject()! as RenderBox;
    final box = pageKey.currentContext!.findRenderObject()! as RenderBox;
    final a = overlay.globalToLocal(box.localToGlobal(Offset.zero));
    final b = overlay.globalToLocal(
        box.localToGlobal(Offset(page.width, page.height)));
    return Rect.fromPoints(a, b);
  }

  testWidgets('等倍では、 組み立て時の大きさがそのまま画面の大きさ',
      (tester) async {
    final r = await measure(tester, scale: 1.0, pan: Offset.zero);
    expect(r.left, 0);
    expect(r.top, 0);
    expect(r.width, 400);
    expect(r.height, 600);
  });

  testWidgets('3 倍に拡大すると、 画面の大きさも 3 倍になる', (tester) async {
    final r = await measure(tester, scale: 3.0, pan: Offset.zero);
    expect(r.width, 1200);
    expect(r.height, 1800);
    // ★ ここが b336 の不具合。 組み立て時の大きさ (400x600) を使っていたので
    //   帯だけ 1/3 で描かれていた。
    expect(r.width, isNot(400));
  });

  testWidgets('拡大して右下へ送ると、 ページの左上は画面の外 (負) へ動く',
      (tester) async {
    final r = await measure(tester, scale: 3.0, pan: const Offset(-900, -1200));
    expect(r.left, -900);
    expect(r.top, -1200);
    // 大きさは拡大率のまま。
    expect(r.width, 1200);
    expect(r.height, 1800);
  });

  testWidgets('帯の厚みは「紙の位置 / hp × 拡大率」 で出せる', (tester) async {
    const page = Size(400, 600);
    const hp = 842.0 / 600.0; // 元ページ pt / 表示 px (A4 相当)
    const yPt = 200.0; // ここより上を固定する
    final r = await measure(tester, scale: 3.0, pan: Offset.zero, page: page);
    final zy = r.height / page.height;
    final bandHpx = (yPt / hp) * zy;
    // 画面に出ているページの高さに対する割合は、 拡大しても変わらない。
    expect(bandHpx / r.height, closeTo(yPt / (page.height * hp), 1e-9));
    // 等倍の時の厚み × 3 になっている。
    expect(bandHpx, closeTo((yPt / hp) * 3.0, 1e-9));
  });
}
