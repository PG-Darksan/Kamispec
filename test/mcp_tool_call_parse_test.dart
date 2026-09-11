// AI の返事から道具の呼び出しを読み取れるかの検査。
//
//   flutter test test/mcp_tool_call_parse_test.dart
//
// = ユーザー報告「claude のモデルに切り替えてマインドマップを作らせたら、
//   新規ページは出来たのに中の要素が 1 つも作られないまま完了した」。
//   原因の 1 つは、 道具の一覧と同じ形 ({"name":…, "input":…}) で返された
//   時に「呼び出しではない」 と見なして黙って終わっていたこと。
import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/screens/mind_map_screen.dart';

void main() {
  test('今までの形 ({"tool":…,"args":…}) はそのまま読める', () {
    final c = parseToolCallForTest('{"tool":"create_page","args":{"name":"A"}}');
    expect(c, isNotNull);
    expect(c!['tool'], 'create_page');
    expect((c['args'] as Map)['name'], 'A');
  });

  test('```json で囲まれていても読める', () {
    final c = parseToolCallForTest(
        'これから作ります。\n```json\n{"tool":"add_node","args":{"pageId":"p1"}}\n```');
    expect(c?['tool'], 'add_node');
  });

  test('道具一覧と同じ形 ({"name":…,"input":…}) も読める', () {
    final c = parseToolCallForTest('{"name":"add_node","input":{"pageId":"p1"}}');
    expect(c, isNotNull, reason: 'name/input の形が読めていない');
    expect(c!['tool'], 'add_node');
    expect((c['args'] as Map)['pageId'], 'p1');
  });

  test('{"name":…,"arguments":…} も読める', () {
    final c =
        parseToolCallForTest('{"name":"connect_nodes","arguments":{"a":"1"}}');
    expect(c?['tool'], 'connect_nodes');
    expect((c!['args'] as Map)['a'], '1');
  });

  test('途中で切れた呼び出しも閉じて読む', () {
    final c = parseToolCallForTest(
        '{"tool":"add_node","args":{"pageId":"p1","nodes":[{"title":"あ"},{"title":"い"');
    expect(c?['tool'], 'add_node');
  });

  test('ただの文章は呼び出しとして読まない', () {
    expect(parseToolCallForTest('新しいマップを作りました。'), isNull);
    expect(looksLikeToolCallForTest('新しいマップを作りました。'), isFalse);
  });

  test('壊れた呼び出しは「書き直させる」 と判定する', () {
    // 読み取りは失敗するが、 呼び出しのつもりだと分かる形。
    expect(looksLikeToolCallForTest('{"name":"add_node","input":{'), isTrue);
    expect(looksLikeToolCallForTest('{"tool":"add_node","args":{'), isTrue);
  });
}
