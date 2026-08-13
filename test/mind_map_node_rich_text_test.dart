import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/models/mind_map_node.dart';

void main() {
  const baseStyle = TextStyle(
    color: Color(0xFF111111),
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );

  TextSpan render(List<Map<String, dynamic>> delta) =>
      MindMapNode.buildRichSpan(jsonEncode(delta), baseStyle) as TextSpan;

  test('applies line attributes to the text before the newline', () {
    final span = render([
      {'insert': 'Heading'},
      {
        'insert': '\n',
        'attributes': {'header': 1}
      },
      {'insert': 'Item'},
      {
        'insert': '\n',
        'attributes': {'list': 'bullet'}
      },
    ]);

    final heading = span.children!
        .whereType<TextSpan>()
        .firstWhere((child) => child.text == 'Heading');
    expect(heading.style!.fontSize, 18);
    expect(heading.style!.fontWeight, FontWeight.w800);
    expect(span.toPlainText(), 'Heading\n• Item\n');
  });

  test('renders inline code, scripts, and distinguishable bold', () {
    final span = render([
      {
        'insert': 'code',
        'attributes': {'code': true}
      },
      {
        'insert': '2',
        'attributes': {'script': 'super'}
      },
      {
        'insert': 'bold',
        'attributes': {'bold': true}
      },
      {'insert': '\n'},
    ]);
    final runs = span.children!.whereType<TextSpan>().toList();

    expect(runs.firstWhere((run) => run.text == 'code').style!.fontFamily,
        'monospace');
    expect(runs.firstWhere((run) => run.text == '2').style!.fontFeatures,
        isNotEmpty);
    expect(runs.firstWhere((run) => run.text == 'bold').style!.fontWeight,
        FontWeight.w800);
  });

  test('keeps malformed Delta as plain text', () {
    final span =
        MindMapNode.buildRichSpan('{not-json', baseStyle) as TextSpan;
    expect(span.text, '{not-json');
    expect(span.style, baseStyle);
  });
}
