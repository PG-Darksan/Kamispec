// フリーノートの文書モードの本文が「タブごと」に分かれるかを見る。
//
// ★ = 動作検証の不具合「フリーノートの文書追記がタブごとに分かれない」。
//   1 枚目のタブを選んで書き、 2 枚目を選んで書いたら、 read_document が
//   紙 1 枚だけを返し、 その中に両方の文章が続けて入っていた、 という報告。
//   原因は append_document_text が `document_<pageId>` (ページに 1 本しかない
//   別の入れ物) へ書いていた事。 画面の文書モードは `_PaintSheet` の 'doc'、
//   つまり**紙 (タブ) ごと**を読み書きしている。 書く先を合わせた。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/providers/mind_map_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 紙の中身は画面が開いた時に作られるので、 画面の無い検分では
/// ここで 1 バインダー / 1 タブの空の束を置いておく。
Future<void> _seedPaintBody(String pageId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      'paint_$pageId',
      jsonEncode({
        'notes': [
          {
            'n': 'バインダー1',
            'sel': 0,
            'pages': [
              {'id': 'p1', 'n': 'タブ1', 'sz': 'a4p', 's': [], 't': [], 'sh': [], 'im': []}
            ],
          }
        ],
        'noteSel': 0,
      }));
}

Future<MindMapProvider> _boot() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final provider = MindMapProvider();
  for (var i = 0; i < 300 && !provider.pageLoadSettled; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('タブごとに別の文章が残る', () async {
    final provider = await _boot();
    addTearDown(provider.dispose);
    provider.addPaintPage(name: 'free-note');
    final page = provider.pages.firstWhere((p) => p.name == 'free-note');
    await _seedPaintBody(page.id);

    // 2 枚目のタブを足す。
    final made = await provider.mcpAddPaintTabs(page.id, ['タブ2']);
    expect(made, isNotEmpty, reason: 'タブを足せていない');

    // 1 枚目を選んで書く。
    expect(await provider.mcpSelectPaintTab(page.id, tab: 0), isTrue);
    expect(await provider.mcpAppendDocumentTexts(page.id, ['タブ1だけの文章']),
        1);

    // 2 枚目を選んで書く。
    expect(await provider.mcpSelectPaintTab(page.id, tab: made.first), isTrue);
    expect(await provider.mcpAppendDocumentTexts(page.id, ['タブ2だけの文章']),
        1);

    final doc = await provider.mcpReadDocument(page.id);
    expect(doc, isNotNull);
    expect(doc!['scope'], 'sheet', reason: '紙 (タブ) 単位だと名乗るはず');
    final papers = doc['papers'] as List;
    expect(papers.length, greaterThanOrEqualTo(2),
        reason: 'タブの数だけ紙が返るはず');

    final first = '${(papers[0] as Map)['text']}';
    final second = '${(papers[made.first] as Map)['text']}';
    expect(first, contains('タブ1だけの文章'));
    expect(first, isNot(contains('タブ2だけの文章')),
        reason: '1 枚目に 2 枚目の文章が混ざっている');
    expect(second, contains('タブ2だけの文章'));
    expect(second, isNot(contains('タブ1だけの文章')),
        reason: '2 枚目に 1 枚目の文章が混ざっている');

    // 書いた先は「今開いているタブ」。
    expect(doc['appendsTo'], made.first);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('フリーノートの文書本文はページ内検索で見つかる', () async {
    final provider = await _boot();
    addTearDown(provider.dispose);
    provider.addPaintPage(name: 'free-note-search');
    final page =
        provider.pages.firstWhere((p) => p.name == 'free-note-search');
    await _seedPaintBody(page.id);
    expect(
        await provider.mcpAppendDocumentTexts(page.id, ['固有語メモ_苺大福']),
        1);

    // ★ = 動作検証の不具合「探して見つかったのに見つからない寄りの返事に
    //   なる」 の残り。 本文がページ JSON の外にある種別は、 要素だけを
    //   見ていた頃は必ず absent になっていた。
    final hit = await provider.mcpSearchNodes('固有語メモ_苺大福');
    expect(hit.verdict, 'found');
    expect(hit.hits, isNotEmpty);
    expect(hit.hits.first['pageId'], page.id);

    final miss = await provider.mcpSearchNodes('居ない言葉_zzz');
    expect(miss.hits, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
