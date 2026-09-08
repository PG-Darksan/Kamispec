import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _dlg() => AlertDialog(
      backgroundColor: const Color(0xFF1E1E32),
      title: Row(children: [
        const Icon(Icons.crop_rounded, color: Color(0xFFFFB347), size: 20),
        const SizedBox(width: 8),
        const Expanded(
            child: Text('壁紙の位置を調整',
                style: TextStyle(color: Colors.white, fontSize: 15))),
      ]),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 460,
            height: 300,
            child: Center(
              child: CustomPaint(size: const Size(430, 268)),
            ),
          ),
          const SizedBox(height: 8),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
                '枠をつまんで動かすと、 画面に映る所を決められます。 大きさはホイールか下の目盛りで変えられます。',
                style: TextStyle(
                    color: Colors.white54, fontSize: 11, height: 1.4)),
          ),
          const SizedBox(height: 6),
          Row(children: [
            const Text('大きさ',
                style: TextStyle(color: Colors.white54, fontSize: 11)),
            Expanded(
              child: Slider(value: 1, min: 1, max: 4, onChanged: (_) {}),
            ),
            TextButton(
              onPressed: () {},
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8)),
              child: const Text('元に戻す',
                  style: TextStyle(color: Color(0xFF4FC3F7), fontSize: 11.5)),
            ),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () {}, child: const Text('閉じる')),
        FilledButton(
            onPressed: () {},
            child: const Text('この位置で貼る',
                style: TextStyle(fontSize: 12.5))),
      ],
    );

Future<void> _probe(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final errs = <String>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (d) => errs.add(d.exceptionAsString());
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: Builder(builder: (c) => _dlg())));
  await tester.pump();
  FlutterError.onError = prev;
  // measure natural height
  final dialogH = tester.getSize(find.byType(AlertDialog)).height;
  // ignore: avoid_print
  print('SIZE ${size.width}x${size.height}  dialogH=$dialogH  errors=${errs.length}');
  for (final e in errs) {
    // ignore: avoid_print
    print('  ERR: ${e.split('\n').first}');
  }
}

void main() {
  for (final s in const [
    Size(1280, 900),
    Size(1280, 720),
    Size(1280, 660),
    Size(1280, 640),
    Size(1280, 620),
    Size(1280, 600),
    Size(1280, 560),
    Size(960, 540),
    Size(768, 432),
  ]) {
    testWidgets('measure ${s.width}x${s.height}', (t) async {
      await _probe(t, s);
    });
  }
}
