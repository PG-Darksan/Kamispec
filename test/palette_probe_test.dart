// 使い捨ての検分用テスト (= 実機を触らずに、 部品を実際に描いて確かめる)。
//
// ★ 利用者の実データを触らずに済ませるための道具。 はみ出し (RenderFlex
//   overflow) は Flutter が例外として投げるので、 pumpWidget するだけで
//   「狭い所で入り切らない」 類の不具合が捕まる。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mindmap_app/providers/mind_map_provider.dart';
import 'package:mindmap_app/widgets/auto_click_palette.dart';


// 本物の日本語を引く (= 鍵そのままだと字数が実物とかけ離れる)。
String t(String k) => MindMapProvider.translateFor(k, 'ja');

Widget wrap(Widget child, Size size) => MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: Scaffold(
          backgroundColor: const Color(0xFF1B1B2A),
          body: SizedBox(
            width: size.width,
            height: size.height,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
              child: child,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('動作パレット: 札が無い時 (別窓の幅 420)', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(420, 460);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(wrap(
        AutoClickPalette(t: t, compact: true), const Size(420, 460)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('動作パレット: 札を 8 種そろえても収まる (別窓の幅 420)',
      (tester) async {
    final slots = <Map<String, dynamic>>[
      {'kind': 'click', 'x1': 974, 'y1': 312},
      {'kind': 'doubleClick', 'x1': 100, 'y1': 200},
      {'kind': 'rightClick', 'x1': 300, 'y1': 400},
      {'kind': 'swipe', 'x1': 10, 'y1': 20, 'x2': 800, 'y2': 900},
      {'kind': 'scroll', 'notches': -3},
      {'kind': 'repeatClick', 'x1': 55, 'y1': 66, 'interval': 250},
      {'kind': 'typeText', 'text': 'こんにちは世界'},
      {'kind': 'keys', 'text': 'ctrl+shift+alt+f12'},
      {'kind': 'screenshot'},
      {'kind': 'screenshotRect', 'x1': 0, 'y1': 0, 'x2': 1920, 'y2': 1080},
    ];
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.autoClickPalette_v1': _json(slots),
    });
    tester.view.physicalSize = const Size(420, 460);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(wrap(
        AutoClickPalette(t: t, compact: true), const Size(420, 460)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 10 枚ぜんぶ札になっているか (名前は鍵そのままが出る)。
    expect(find.text(t('palette.kindSwipe')), findsOneWidget);
    expect(find.text(t('palette.kindShotRect')), findsOneWidget);
  });

  testWidgets('動作パレット: 帯の形 (別窓 640x132)', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.autoClickPalette_v1': _json(<Map<String, dynamic>>[
        {'kind': 'click', 'x1': 974, 'y1': 312},
        {'kind': 'swipe', 'x1': 10, 'y1': 20, 'x2': 800, 'y2': 900},
        {'kind': 'repeatClick', 'x1': 55, 'y1': 66, 'interval': 250},
        {'kind': 'screenshotRect', 'x1': 0, 'y1': 0, 'x2': 1920, 'y2': 1080},
      ]),
    });
    tester.view.physicalSize = const Size(640, 132);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(wrap(
        AutoClickPalette(t: t, compact: true, bar: true),
        const Size(640, 132)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('動作パレット: 中身を決め直す窓 (狭い画面 360)', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.autoClickPalette_v1':
          _json(<Map<String, dynamic>>[
        {'kind': 'swipe', 'x1': 10, 'y1': 20, 'x2': 800, 'y2': 900},
      ]),
    });
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(wrap(
        AutoClickPalette(t: t, compact: true), const Size(360, 640)));
    await tester.pumpAndSettle();
    // ⚙ (tune) を押して編集の窓を出す。
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 始点 / 終点の欄が数で書けるようになっているか。
    expect(find.text(t('palette.startPoint')), findsOneWidget);
    expect(find.text(t('palette.endPoint')), findsOneWidget);
    expect(find.widgetWithText(TextField, '10'), findsOneWidget);
    expect(find.widgetWithText(TextField, '900'), findsOneWidget);
  });
}

String _json(List<Map<String, dynamic>> v) {
  final buf = StringBuffer('[');
  for (var i = 0; i < v.length; i++) {
    if (i > 0) buf.write(',');
    buf.write('{');
    var first = true;
    v[i].forEach((k, val) {
      if (!first) buf.write(',');
      first = false;
      buf.write('"$k":');
      buf.write(val is String ? '"$val"' : '$val');
    });
    buf.write('}');
  }
  buf.write(']');
  return buf.toString();
}
