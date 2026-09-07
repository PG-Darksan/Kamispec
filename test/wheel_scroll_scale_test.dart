// ホイールの行数の掛け直しが、 本当に届く量に効いているかを確かめる。
// アプリを起動しなくても `flutter test test/wheel_scroll_scale_test.dart` で
// 検分できる。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/services/wheel_scroll_scale.dart';

/// 本物と同じ [WheelScrollScaling] を試験用 binding に混ぜる。
/// AutomatedTestWidgetsFlutterBinding は handlePointerEvent を上書きして
/// いないので、 super は素の GestureBinding のそれに落ちる。
class _ScalingTestBinding extends AutomatedTestWidgetsFlutterBinding
    with WheelScrollScaling {
  static bool _made = false;

  static void ensureInitialized() {
    if (_made) return;
    _made = true;
    _ScalingTestBinding();
  }
}

void main() {
  // ★ testWidgets より先に作る。 TestWidgetsFlutterBinding.ensureInitialized は
  //   既にある物を返すので、 以後この binding が使われる。
  _ScalingTestBinding.ensureInitialized();
  WheelScrollScale.debugDisableReread = true;

  setUp(() => WheelScrollScale.debugSetLines(baked: 3, os: 3));

  test('倍率 1 の時は同じ物をそのまま返す', () {
    const e = PointerScrollEvent(scrollDelta: Offset(0, 100));
    expect(identical(WheelScrollScale.scaleEvent(e), e), isTrue);
  });

  test('行数を増やすと量も増え、 他の値はそのまま運ばれる', () {
    WheelScrollScale.debugSetLines(baked: 3, os: 10);
    const e = PointerScrollEvent(
      viewId: 7,
      timeStamp: Duration(milliseconds: 42),
      device: 5,
      position: Offset(11, 22),
      scrollDelta: Offset(0, 100),
      embedderId: 99,
    );
    final s = WheelScrollScale.scaleEvent(e) as PointerScrollEvent;
    expect(s.scrollDelta.dy, closeTo(100 * 10 / 3, 1e-9));
    expect(s.scrollDelta.dx, 0);
    expect(s.viewId, 7);
    expect(s.timeStamp, const Duration(milliseconds: 42));
    expect(s.kind, PointerDeviceKind.mouse);
    expect(s.device, 5);
    expect(s.position, const Offset(11, 22));
    expect(s.embedderId, 99);
    expect(s.transform, isNull);
    expect(s.original, isNull);
  });

  test('マウス以外 (タッチパッド) は触らない', () {
    WheelScrollScale.debugSetLines(baked: 3, os: 10);
    const e = PointerScrollEvent(
      kind: PointerDeviceKind.trackpad,
      scrollDelta: Offset(0, 100),
    );
    expect(identical(WheelScrollScale.scaleEvent(e), e), isTrue);
  });

  test('スクロール以外の出来事は触らない', () {
    WheelScrollScale.debugSetLines(baked: 3, os: 10);
    const e = PointerDownEvent(position: Offset(1, 2));
    expect(identical(WheelScrollScale.scaleEvent(e), e), isTrue);
  });

  test('1 画面ぶん (-1) や 0 では比が作れないので何もしない', () {
    const e = PointerScrollEvent(scrollDelta: Offset(0, 100));
    WheelScrollScale.debugSetLines(baked: -1, os: 10);
    expect(identical(WheelScrollScale.scaleEvent(e), e), isTrue);
    WheelScrollScale.debugSetLines(baked: 3, os: 0);
    expect(identical(WheelScrollScale.scaleEvent(e), e), isTrue);
  });

  test('respond は元の出来事へ通る', () {
    WheelScrollScale.debugSetLines(baked: 3, os: 6);
    bool? got;
    final e = PointerScrollEvent(
      scrollDelta: const Offset(0, 100),
      onRespond: ({required bool allowPlatformDefault}) {
        got = allowPlatformDefault;
      },
    );
    (WheelScrollScale.scaleEvent(e) as PointerScrollEvent)
        .respond(allowPlatformDefault: true);
    expect(got, isTrue);
  });

  testWidgets('binding の入口で掛け直され、 Listener には増えた量が届く',
      (tester) async {
    WheelScrollScale.debugSetLines(baked: 3, os: 12); // 4 倍
    Offset? seen;
    await tester.pumpWidget(MaterialApp(
      home: Listener(
        // 中身が当たり判定を持たないので、 ここで受ける事をはっきりさせる。
        behavior: HitTestBehavior.opaque,
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) seen = e.scrollDelta;
        },
        child: const SizedBox.expand(),
      ),
    ));
    final Offset where = tester.getCenter(find.byType(SizedBox).first);
    await tester.sendEventToBinding(
      PointerScrollEvent(position: where, scrollDelta: const Offset(0, 100)),
    );
    expect(seen, isNotNull);
    expect(seen!.dy, closeTo(400, 1e-9));
  });

  testWidgets('巻物 (Scrollable) も増えた量ぶん動く', (tester) async {
    WheelScrollScale.debugSetLines(baked: 3, os: 9); // 3 倍
    final ctrl = ScrollController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(MaterialApp(
      home: ListView.builder(
        controller: ctrl,
        itemExtent: 20,
        itemCount: 500,
        itemBuilder: (_, i) => Text('$i'),
      ),
    ));
    final Offset where = tester.getCenter(find.byType(ListView));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: where, scrollDelta: const Offset(0, 20)),
    );
    await tester.pump();
    expect(ctrl.offset, closeTo(60, 0.01));
  });
}
