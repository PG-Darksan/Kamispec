// 「貼り替えたのに前の物が同期される」 を二度と起こさないための見張り。
//
// ★ 経緯: copyWith は `?? this.x` で値を持ち越すので、 画像や動画を貼り替えて
//   も「雲へ上げた時の URL」 が残っていた。 残っていると
//     ・上げ直しが行われない (「もう上げてある」 と判断する)
//     ・受け取った側は**前の画像**を落としてくる
//     ・動画は再生時に URL を先に見るので、 **貼り替えた本人の端末でも
//       前の動画が再生される**
//   という形で出ていた。 ここでは「持ち越す」 という copyWith の性質そのものを
//   固定し、 呼ぶ側が消し忘れたら気付けるようにしておく。
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/models/mind_map_node.dart';
import 'package:mindmap_app/providers/mind_map_provider.dart';

void main() {
  group('copyWith は雲の控えを持ち越す (だから呼ぶ側が消す)', () {
    test('添付を貼り替えても attachmentStorageUrl は残る', () {
      final n = MindMapNode(
        id: 'a',
        title: 'x',
        position: Offset.zero,
        attachmentPath: r'C:\old.png',
        attachmentStorageUrl: 'https://example.com/old.png',
      );
      final replaced = n.copyWith(attachmentPath: r'C:\new.png');
      // 持ち越す = これが仕様。 だから貼り替えた側で消す必要がある。
      expect(replaced.attachmentStorageUrl, 'https://example.com/old.png',
          reason: 'copyWith の持ち越しが変わったら、 消し忘れの罠も変わる');
      // 消せる事 (書き換え可能な欄である事) も固定しておく。
      replaced.attachmentStorageUrl = null;
      expect(replaced.attachmentStorageUrl, isNull);
    });

    test('表紙を作り直しても attachmentThumbStorageUrl は残る', () {
      final n = MindMapNode(
        id: 'c',
        title: 'x',
        position: Offset.zero,
        attachmentThumbPath: r'C:	humb_old.png',
        attachmentThumbStorageUrl: 'https://example.com/thumb_old.png',
      );
      final replaced = n.copyWith(attachmentThumbPath: r'C:	humb_new.png');
      expect(replaced.attachmentThumbStorageUrl,
          'https://example.com/thumb_old.png');
      replaced.attachmentThumbStorageUrl = null;
      expect(replaced.attachmentThumbStorageUrl, isNull);
    });

    test('表紙の置き場 URL は書き出して読み直しても残る', () {
      final n = MindMapNode(
        id: 'd',
        title: 'x',
        position: Offset.zero,
        attachmentThumbPath: r'C:	.png',
        attachmentThumbStorageUrl: 'https://example.com/t.png',
      );
      final back = MindMapNode.fromJson(n.toJson());
      expect(back.attachmentThumbStorageUrl, 'https://example.com/t.png',
          reason: '運ばないと、 受け取った側の表紙が空欄のままになる');
    });

    test('古い版が書いた要素 (表紙 URL 無し) も読める', () {
      // 実物の書き出しから、 新しい欄だけを抜いて「古い版」 を作る。
      final j = MindMapNode(
        id: 'e',
        title: 'x',
        position: Offset.zero,
        attachmentThumbPath: r'C:\old.png',
      ).toJson();
      j.remove('attachmentThumbStorageUrl');
      final back = MindMapNode.fromJson(j);
      expect(back.attachmentThumbPath, r'C:\old.png');
      expect(back.attachmentThumbStorageUrl, isNull);
    });

    test('動画を貼り替えても videoStorageUrl は残る', () {
      final n = MindMapNode(
        id: 'b',
        title: 'x',
        position: Offset.zero,
        youtubeUrl: r'C:\old.mp4',
        videoStorageUrl: 'https://example.com/old.mp4',
      );
      final replaced = n.copyWith(youtubeUrl: r'C:\new.mp4');
      expect(replaced.videoStorageUrl, 'https://example.com/old.mp4');
      replaced.videoStorageUrl = null;
      expect(replaced.videoStorageUrl, isNull);
    });
  });

  group('ページの背景画像の置き場 URL', () {
    test('書き出して読み直しても残る', () {
      final p = MindMapPage(id: 'p1', name: 'ページ');
      p.backgroundImagePath = r'C:\attachments\bg.png';
      p.backgroundStorageUrl = 'https://example.com/bg.png';
      final back = MindMapPage.fromJson(p.toJson());
      expect(back.backgroundImagePath, r'C:\attachments\bg.png');
      expect(back.backgroundStorageUrl, 'https://example.com/bg.png',
          reason: '運ばないと、 受け取った側で背景が黙って消える');
    });

    test('背景が無いページには書き出さない (古い版と行き来できるように)', () {
      final p = MindMapPage(id: 'p2', name: 'ページ');
      final j = p.toJson();
      expect(j.containsKey('backgroundImagePath'), isFalse);
      expect(j.containsKey('backgroundStorageUrl'), isFalse);
      // 知らない欄が無くても読める。
      final back = MindMapPage.fromJson(j);
      expect(back.backgroundStorageUrl, isNull);
    });

    test('古い版が書いた JSON (置き場 URL 無し) も読める', () {
      final old = {
        'id': 'p3',
        'name': '古いページ',
        'nodes': <dynamic>[],
        'backgroundImagePath': r'C:\old\bg.png',
      };
      final back = MindMapPage.fromJson(old);
      expect(back.backgroundImagePath, r'C:\old\bg.png');
      expect(back.backgroundStorageUrl, isNull);
    });
  });
}
