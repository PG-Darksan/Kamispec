// AI の返事から「アプリが読むための JSON」 を取り除けているかを、
// アプリを起動せずに確かめる。
//
//   flutter test test/ai_json_strip_test.dart --no-pub
//
// = ユーザー報告「LLM からの回答に Json 出力がそのまま入ってしまっている
//   からチャット欄の回答には含めないようにして欲しい」。
import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/screens/mind_map_screen.dart';

void main() {
  String strip(String s) => stripAiJsonBlocksForTest(s);

  bool looksLikeJson(String s) =>
      s.contains('"deck"') ||
      s.contains('"slides"') ||
      s.contains('"design"') ||
      s.contains('```');

  test('```json フェンス付き', () {
    const raw = '''
カフェらしい配色にしました。

```json
{"deck": {"theme": {"bg": "2B1B12"}, "slides": [{"layout": "title", "title": "Cafe"}]}}
```
''';
    final out = strip(raw);
    expect(looksLikeJson(out), isFalse, reason: out);
    expect(out.contains('カフェらしい配色'), isTrue);
  });

  test('フェンス無しで末尾にぶら下がる', () {
    const raw = '''
落ち着いた色にしました。
{"deck": {"slides": [{"layout": "bullets", "title": "A"}]}}
''';
    final out = strip(raw);
    expect(looksLikeJson(out), isFalse, reason: out);
  });

  test('フェンスの中が配列', () {
    const raw = '''
こうしました。

```json
[{"layout": "title", "title": "Cafe"}]
```
''';
    final out = strip(raw);
    expect(looksLikeJson(out), isFalse, reason: out);
  });

  test('JSON の後ろにも文章がある', () {
    const raw = '''
まず配色です。

```json
{"deck": {"slides": [{"layout": "title", "title": "Cafe"}]}}
```

写真は表紙だけに入れています。
''';
    final out = strip(raw);
    expect(looksLikeJson(out), isFalse, reason: out);
    expect(out.contains('まず配色です'), isTrue);
    expect(out.contains('写真は表紙だけ'), isTrue,
        reason: 'JSON の後ろの説明まで消してはいけない: $out');
  });

  test('閉じフェンスが欠けている (途中で切れた返事)', () {
    const raw = '''
こうします。

```json
{"deck": {"slides": [{"layout": "title", "title": "Cafe"}]}}
''';
    final out = strip(raw);
    expect(looksLikeJson(out), isFalse, reason: out);
  });

  test('deck / design 以外の鍵で始まる', () {
    const raw = '''
表にしました。
{"slides": [{"title": "A", "bullets": ["x"]}]}
''';
    final out = strip(raw);
    expect(looksLikeJson(out), isFalse, reason: out);
  });

  // ★ ここが元の不具合。 全部 JSON だった時に生の JSON へ戻していたので、
  //   pptx のように「返事が JSON だけ」 の場合は結局そのまま出ていた。
  test('JSON しか返ってこなかったら空を返す (生の JSON へ戻さない)', () {
    const raw = '{"deck": {"slides": []}}';
    expect(strip(raw), isEmpty, reason: '生の JSON が会話欄に出てしまう');
  });

  test('フェンス付きで JSON だけでも空', () {
    const raw = '''
```json
{"deck": {"slides": []}}
```''';
    expect(strip(raw), isEmpty);
  });

  test('ふつうの文章は変えない', () {
    const raw = 'グラフの作り方ですが、まず数値を選んでください。\n次に挿入します。';
    expect(strip(raw), raw.trim());
  });

  test('JSON でないコードフェンス (説明のコード) は残す', () {
    const raw = '''
こう書きます。

```dart
final x = 1;
```
''';
    final out = strip(raw);
    expect(out.contains('final x = 1;'), isTrue,
        reason: 'JSON でないコードまで消してはいけない: $out');
  });
}
