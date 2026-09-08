import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _row(double contentW, List<String> labels, double previewH) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: Material(
          color: Colors.black,
          child: Center(
            child: SizedBox(
              width: contentW,
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: SizedBox(
                          width: 118,
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: const [
                                Text('1  メイン',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11.5)),
                                Text('1920×1080',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 10)),
                              ])),
                    ),
                    SizedBox(width: 132, height: previewH),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('adjusted_1757000000000.jpg',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 10.5)),
                          Wrap(spacing: 2, children: [
                            for (final l in labels)
                              TextButton(
                                onPressed: () {},
                                style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    minimumSize: const Size(0, 28),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6)),
                                child: Text(l,
                                    style: const TextStyle(fontSize: 11.5)),
                              ),
                          ]),
                        ],
                      ),
                    ),
                  ]),
            ),
          ),
        ),
      ),
    );

Future<void> probe(WidgetTester t, double w, List<String> labels, String tag) async {
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final errs = <String>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (d) => errs.add(d.exceptionAsString());
  await t.pumpWidget(_row(w, labels, 87));
  await t.pump();
  FlutterError.onError = prev;
  final wrapW = t.getSize(find.byType(Wrap)).width;
  final wrapH = t.getSize(find.byType(Wrap)).height;
  // ignore: avoid_print
  print('ROW $tag contentW=$w wrap=${wrapW}x$wrapH errors=${errs.length}');
  for (final e in errs) {
    // ignore: avoid_print
    print('  ERR: ${e.split('\n').first}');
  }
}

void main() {
  const ja = ['画像を選ぶ', 'テンプレート', '位置を調整'];
  const en = ['Choose image', 'Template', 'Adjust position'];
  const de = ['Bild auswählen', 'Vorlage', 'Position anpassen'];
  testWidgets('ja 512', (t) => probe(t, 512, ja, 'ja'));
  testWidgets('en 512', (t) => probe(t, 512, en, 'en'));
  testWidgets('de 512', (t) => probe(t, 512, de, 'de'));
  testWidgets('ja 300', (t) => probe(t, 300, ja, 'ja-narrow'));
  testWidgets('ja 258', (t) => probe(t, 258, ja, 'ja-258'));
  testWidgets('ja 250', (t) => probe(t, 250, ja, 'ja-250'));
}
