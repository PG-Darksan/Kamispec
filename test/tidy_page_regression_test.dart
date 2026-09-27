import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/models/mind_map_node.dart';
import 'package:mindmap_app/providers/mind_map_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _waitForPageLoad(MindMapProvider provider) async {
  for (var i = 0; i < 200 && !provider.pageLoadSettled; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(provider.pageLoadSettled, isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('aroundNodes metadata survives JSON round-trip', () {
    final decoration = MapDecoration(
      id: 'frame',
      kind: MapDecorationKind.rectangle,
      start: const Offset(10, 20),
      end: const Offset(30, 40),
      aroundNodeIds: const ['center', 'child-a'],
      aroundNodePadding: 18,
    );

    final restored = MapDecoration.fromJson(decoration.toJson());
    expect(restored.aroundNodeIds, ['center', 'child-a']);
    expect(restored.aroundNodePadding, 18);
  });

  test('markdown read immediately reflects the successful MCP write', () async {
    SharedPreferences.setMockInitialValues({
      'seededDefaultPages': true,
      'mindmap_pages_v3': jsonEncode([
        {
          'id': 'markdown-test',
          'name': 'Markdown regression',
          'pageType': 'markdown',
          'nodes': <Object>[],
          'connections': <Object>[],
          'lastModifiedAt': 1,
        }
      ]),
      'markdown_markdown-test': 'old body',
    });

    final provider = MindMapProvider();
    addTearDown(provider.dispose);
    await _waitForPageLoad(provider);

    // mcpWriteMarkdown は**書けた文字数**を返す (bool ではない)。
    expect(await provider.mcpWriteMarkdown('markdown-test', 'new body'),
        greaterThan(0));

    // SharedPreferences側の値が一時的に古く見える状況でも、成功応答後の
    // readはwrite-throughキャッシュから確定済みの本文を返す。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('markdown_markdown-test', 'old body');
    final read = await provider.mcpReadMarkdown('markdown-test');

    expect(read, isNotNull);
    expect((read!['tabs'] as List).single['text'], 'new body');

    expect(
      await provider.mcpWriteMarkdown('markdown-test', 'continued',
          append: true),
      greaterThan(0),
    );
    final appended = await provider.mcpReadMarkdown('markdown-test');
    expect((appended!['tabs'] as List).single['text'], 'new body\n\ncontinued');
  });

  test('tidy keeps 261 tree nodes distinct and reflows an aroundNodes frame',
      () async {
    SharedPreferences.setMockInitialValues({
      'seededDefaultPages': true,
      'mindmap_pages_v3': jsonEncode([
        {
          'id': 'layout-test',
          'name': 'Layout regression',
          'pageType': 'normal',
          'nodes': <Object>[],
          'connections': <Object>[],
          'lastModifiedAt': 1,
        }
      ]),
    });

    final provider = MindMapProvider();
    addTearDown(provider.dispose);
    await _waitForPageLoad(provider);

    final page = provider.currentPage;
    expect(page.id, 'layout-test');
    page.nodes.clear();
    page.connections.clear();
    page.decorations.clear();

    page.nodes['root'] = MindMapNode(
      id: 'root',
      title: 'ルート',
      position: const Offset(900, 900),
    );
    for (var category = 0; category < 13; category++) {
      final categoryId = 'category-$category';
      page.nodes[categoryId] = MindMapNode(
        id: categoryId,
        title: '分類$category',
        position: Offset(1200, 100.0 * category),
      );
      page.connections.add(NodeConnection(
        fromId: 'root',
        fromAnchor: AnchorDirection.east,
        toId: categoryId,
        toAnchor: AnchorDirection.west,
      ));
      for (var child = 0; child < 19; child++) {
        final childId = '$categoryId-child-$child';
        page.nodes[childId] = MindMapNode(
          id: childId,
          title: '子$category-$child',
          position: Offset(1500, 50.0 * child),
        );
        page.connections.add(NodeConnection(
          fromId: categoryId,
          fromAnchor: AnchorDirection.east,
          toId: childId,
          toAnchor: AnchorDirection.west,
        ));
      }
    }
    page.decorations.add(MapDecoration(
      id: 'around-root-and-first-category',
      kind: MapDecorationKind.rectangle,
      start: const Offset(872, 872),
      end: const Offset(1418, 1068),
      aroundNodeIds: const ['root', 'category-0'],
      aroundNodePadding: 28,
    ));

    expect(page.nodes, hasLength(261));
    expect(page.connections, hasLength(260));

    provider.mcpTidyPage(page.id);

    final positions = <String, String>{};
    for (final node in page.nodes.values) {
      final key = '${node.position.dx.toStringAsFixed(4)},'
          '${node.position.dy.toStringAsFixed(4)}';
      expect(positions[key], isNull,
          reason: '$key is shared by ${positions[key]} and ${node.id}');
      positions[key] = node.id;
    }
    expect(page.nodes.values.map((node) => node.position.dy).reduce(mathMin),
        greaterThanOrEqualTo(0));

    final root = page.nodes['root']!;
    final category0 = page.nodes['category-0']!;
    final frame = page.decorations.single;
    final expectedLeft = mathMin(root.position.dx, category0.position.dx) - 28;
    final expectedTop = mathMin(root.position.dy, category0.position.dy) - 28;
    final expectedRight = mathMax(root.position.dx + root.width,
            category0.position.dx + category0.width) +
        28;
    final expectedBottom = mathMax(root.position.dy + root.visualHeight,
            category0.position.dy + category0.visualHeight) +
        28;
    expect(frame.start.dx, closeTo(expectedLeft, 0.001));
    expect(frame.start.dy, closeTo(expectedTop, 0.001));
    expect(frame.end.dx, closeTo(expectedRight, 0.001));
    expect(frame.end.dy, closeTo(expectedBottom, 0.001));
  });
}

double mathMin(double a, double b) => a < b ? a : b;

double mathMax(double a, double b) => a > b ? a : b;
