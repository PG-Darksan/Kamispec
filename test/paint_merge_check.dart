// フリーノートの共同編集で使う 3-way マージの検算 (使い捨て)。
//   flutter test test/paint_merge_check.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/providers/mind_map_provider.dart';

String note(List<Map<String, dynamic>> strokes, {String noteId = 'n1'}) =>
    jsonEncode({
      'v': 3,
      'noteSel': 0,
      'notes': [
        {
          'id': noteId,
          'n': 'ノート1',
          'sel': 0,
          'pages': [
            {
              'id': 's1',
              'n': 'ページ1',
              'sz': 'a4p',
              'cw': 1000,
              'ch': 1000,
              'rule': 0,
              's': strokes,
              't': [],
              'sh': [],
              'im': [],
            }
          ],
        }
      ],
    });

Map<String, dynamic> stroke(String id, double x) => {
      'id': id,
      'c': 0xFF000000,
      'w': 4.0,
      'p': [
        [x, 0.0],
        [x + 10, 10.0]
      ],
    };

List<String> strokeIds(String body) {
  final d = jsonDecode(body) as Map<String, dynamic>;
  final page = (d['notes'] as List).first as Map<String, dynamic>;
  final sheet = (page['pages'] as List).first as Map<String, dynamic>;
  return (sheet['s'] as List)
      .map((e) => '${(e as Map)['id']}')
      .toList(growable: false);
}

void main() {
  test('両方が足したら、 どちらも残る', () {
    final base = note([stroke('a', 0)]);
    final local = note([stroke('a', 0), stroke('mine', 100)]);
    final remote = note([stroke('a', 0), stroke('theirs', 200)]);
    final ids = strokeIds(MindMapProvider.mergePaintBodies(base, local, remote));
    expect(ids.toSet(), {'a', 'mine', 'theirs'});
  });

  test('相手が消した物は消える (相手がこちらの版を見ていた時)', () {
    final base = note([stroke('a', 0), stroke('b', 50)]);
    final local = note([stroke('a', 0), stroke('b', 50)]);
    final remote = note([stroke('a', 0)]);
    final ids = strokeIds(MindMapProvider.mergePaintBodies(base, local, remote));
    expect(ids, ['a']);
  });

  test('すれ違った時は、 自分の線を消さない', () {
    // 自分が先に送った線 (mine) が基準に入っているが、 相手はそれを見ずに
    // 書いた。 「相手に無い = 消された」 と判断してはいけない。
    final base = note([stroke('a', 0), stroke('mine', 100)]);
    final local = note([stroke('a', 0), stroke('mine', 100)]);
    final remote = note([stroke('a', 0), stroke('theirs', 200)]);
    final ids = strokeIds(MindMapProvider.mergePaintBodies(base, local, remote,
        remoteSawBase: false));
    expect(ids.toSet(), {'a', 'mine', 'theirs'});
  });

  test('自分が消した物は、 相手が触っていなければ消えたまま', () {
    final base = note([stroke('a', 0), stroke('b', 50)]);
    final local = note([stroke('a', 0)]);
    final remote = note([stroke('a', 0), stroke('b', 50)]);
    final ids = strokeIds(MindMapProvider.mergePaintBodies(base, local, remote));
    expect(ids, ['a']);
  });

  test('基準が無い初回は合算する (中身の無い自分のノートは足さない)', () {
    final localEmpty = note([]);
    final remote = note([stroke('theirs', 0)]);
    final ids =
        strokeIds(MindMapProvider.mergePaintBodies('', localEmpty, remote));
    expect(ids, ['theirs']);
  });

  test('画像の置き場が端末ごとに違っても「同じ」 と見なす (往復しない)', () {
    Map<String, dynamic> img(String path) => {
          'id': 'i1',
          'p': path,
          'l': 0.0,
          't': 0.0,
          'w': 100.0,
          'h': 100.0,
          'lu': 'https://example.com/x?alt=media',
        };
    String withImage(String path) => jsonEncode({
          'v': 3,
          'noteSel': 0,
          'notes': [
            {
              'id': 'n1',
              'n': 'ノート1',
              'sel': 0,
              'pages': [
                {
                  'id': 's1',
                  'n': 'ページ1',
                  'sz': 'a4p',
                  'cw': 1000,
                  'ch': 1000,
                  'rule': 0,
                  's': [],
                  't': [],
                  'sh': [],
                  'im': [img(path)],
                }
              ],
            }
          ],
        });
    expect(
        MindMapProvider.paintBodiesEqual(
            withImage(r'C:\Users\a\img.png'),
            withImage('/data/user/0/app/live_attachments/9f3a.png')),
        isTrue);
  });

  test('紙の背景 (bgi) の道が違っても、 同じ URL なら「同じ」', () {
    String sheetWithBg(String path) => jsonEncode({
          'v': 3,
          'noteSel': 0,
          'notes': [
            {
              'id': 'n1',
              'n': 'ノート1',
              'sel': 0,
              'pages': [
                {
                  'id': 's1',
                  'n': 'ページ1',
                  'sz': 'a4p',
                  'cw': 1000,
                  'ch': 1000,
                  'rule': 0,
                  's': [],
                  't': [],
                  'sh': [],
                  'im': [],
                  'bgi': path,
                  'bgiLu': 'https://example.com/bg?alt=media',
                }
              ],
            }
          ],
        });
    expect(
        MindMapProvider.paintBodiesEqual(
            sheetWithBg(r'C:\host\page1.png'), sheetWithBg('/guest/9f3a.png')),
        isTrue);
  });

  test('ID の無い古い要素は、 中身から同じ ID になる', () {
    final a = {'c': 0xFF000000, 'w': 4.0, 'p': [[0, 0], [10, 10]]};
    final b = {'w': 4, 'p': [[0.0, 0.0], [10.0, 10.0]], 'c': 0xFF000000};
    expect(MindMapProvider.paintItemFallbackId(a),
        MindMapProvider.paintItemFallbackId(b));
    final c = {'c': 0xFFFF0000, 'w': 4.0, 'p': [[0, 0], [10, 10]]};
    expect(MindMapProvider.paintItemFallbackId(a) !=
        MindMapProvider.paintItemFallbackId(c), isTrue);
  });

  test('相手が動かした要素は、 自分が触っていなければ相手の位置になる', () {
    final base = note([stroke('a', 0)]);
    final local = note([stroke('a', 0)]);
    final remote = note([stroke('a', 500)]);
    final merged = MindMapProvider.mergePaintBodies(base, local, remote);
    final d = jsonDecode(merged) as Map<String, dynamic>;
    final sheet = ((d['notes'] as List).first as Map)['pages'] as List;
    final s = ((sheet.first as Map)['s'] as List).first as Map;
    expect((s['p'] as List).first, [500, 0]);
  });

  test('両方が同じ要素を動かしたら、 自分の位置が残る (次の送信で相手へ)', () {
    final base = note([stroke('a', 0)]);
    final local = note([stroke('a', 100)]);
    final remote = note([stroke('a', 500)]);
    final merged = MindMapProvider.mergePaintBodies(base, local, remote);
    final d = jsonDecode(merged) as Map<String, dynamic>;
    final sheet = ((d['notes'] as List).first as Map)['pages'] as List;
    final s = ((sheet.first as Map)['s'] as List).first as Map;
    expect((s['p'] as List).first, [100, 0]);
  });

  test('ノートを 2 冊持っていても、 相手のノートと混ざらない', () {
    String twoNotes(List<String> ids) => jsonEncode({
          'v': 3,
          'noteSel': 0,
          'notes': [
            for (final id in ids)
              {
                'id': id,
                'n': id,
                'sel': 0,
                'pages': [
                  {
                    'id': '$id-s',
                    'n': 'p',
                    'sz': 'a4p',
                    'cw': 1000,
                    'ch': 1000,
                    'rule': 0,
                    's': [stroke('$id-a', 0)],
                    't': [],
                    'sh': [],
                    'im': [],
                  }
                ],
              }
          ],
        });
    final merged = MindMapProvider.mergePaintBodies(
        twoNotes(['n1']), twoNotes(['n1', 'n2']), twoNotes(['n1', 'n3']));
    final d = jsonDecode(merged) as Map<String, dynamic>;
    final ids = (d['notes'] as List).map((e) => '${(e as Map)['id']}').toSet();
    expect(ids, {'n1', 'n2', 'n3'});
  });
}
