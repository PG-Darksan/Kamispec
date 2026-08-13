import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mindmap_app/models/mind_map_node.dart';

void main() {
  test('YouTube node data survives a JSON round trip', () {
    final original = MindMapNode(
      id: 'video-node',
      title: 'Video note',
      position: const Offset(12.5, 34.5),
      contentType: NodeContentType.youtube,
      youtubeUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      memoText: 'Remember this scene',
    );

    final restored = MindMapNode.fromJson(original.toJson());

    expect(restored.id, original.id);
    expect(restored.position, original.position);
    expect(restored.contentType, NodeContentType.youtube);
    expect(restored.youtubeUrl, original.youtubeUrl);
    expect(restored.memoText, original.memoText);
  });
}
