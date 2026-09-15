// MCP の道具の「宣言」 と「実装」 と「説明書」 がずれていないか調べる。
//
// ★ = 調査報告 BUG-27「公開仕様書と現行ツール契約で、 ページ種別・動画更新・
//   tidy_page の対象・同期の可否などが食い違う」。 食い違いは、 片方を直して
//   もう片方を直し忘れた時にしか起きない。 人が見比べるのは続かないので、
//   機械で突き合わせられるようにしておく。
//
// 使い方:
//   dart run tool/check_mcp_contract.dart
//   ずれがあれば中身を並べて、 終了コード 1 で終わる (CI に置ける)。
//
// 見ているのは 3 つ:
//   1. toolDefs に宣言してあるのに callTool で受けていない道具 (呼ぶと必ず失敗)
//   2. callTool で受けているのに toolDefs に無い道具 (AI からは存在しない)
//   3. 道具の名前が assets/ai/ のどこにも出て来ない (説明書に載っていない)
import 'dart:io';

void main() {
  final root = Directory.current.path;
  final serverFile = File('$root/lib/services/mcp_server.dart');
  if (!serverFile.existsSync()) {
    stderr.writeln('lib/services/mcp_server.dart が見つかりません。'
        'リポジトリの根っこで実行してください。');
    exit(2);
  }
  final src = serverFile.readAsStringSync();

  // ── 1. 宣言 (_tool('name', …) の並び) ──
  final declared = <String>{};
  for (final m in RegExp(r"_tool\(\s*'([a-z0-9_]+)'").allMatches(src)) {
    declared.add(m.group(1)!);
  }

  // ── 2. 実装 (callTool の switch の case) ──
  //    _dispatch 側の case (initialize / tools/list など) は道具ではないので、
  //    小文字と下線だけの名前に限る。
  final handled = <String>{};
  for (final m in RegExp(r"case\s+'([a-z0-9_]+)':").allMatches(src)) {
    handled.add(m.group(1)!);
  }
  // 道具ではない case を除く。
  handled.removeAll({
    'initialize',
    'ping',
    'notifications',
    'number',
    'circle',
    'cross',
    'triangle',
    'square',
    'check',
    'rect',
    'ellipse',
    'arrow',
    'line',
    'pen',
    'text',
    'select',
  });

  final declaredNotHandled = declared.difference(handled).toList()..sort();
  final handledNotDeclared =
      handled.difference(declared).where((n) => n.contains('_')).toList()
        ..sort();

  // ── 3. 説明書に名前が出ているか ──
  final docs = StringBuffer();
  final aiDir = Directory('$root/assets/ai');
  if (aiDir.existsSync()) {
    for (final f in aiDir.listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.md')) {
        docs.write(f.readAsStringSync());
      }
    }
  }
  final docText = docs.toString();
  final undocumented = declared.where((n) => !docText.contains(n)).toList()
    ..sort();

  var bad = false;
  void report(String title, List<String> names, String why) {
    if (names.isEmpty) return;
    bad = true;
    stdout.writeln('');
    stdout.writeln('[NG] $title (${names.length} 件)');
    stdout.writeln('     $why');
    for (final n in names) {
      stdout.writeln('       - $n');
    }
  }

  stdout.writeln('宣言: ${declared.length} 件 / 実装: ${handled.length} 件');

  report('宣言しているのに受けていない', declaredNotHandled,
      'AI から呼べるのに callTool に case が無く、 必ず失敗します。');
  report('受けているのに宣言していない', handledNotDeclared,
      'toolDefs に無いので AI からは存在しない事になります。');
  report('説明書に載っていない', undocumented,
      'assets/ai/ のどこにも名前が出て来ません。 AI は使い所を知れません。');

  if (bad) {
    stdout.writeln('');
    stdout.writeln('道具の宣言・実装・説明書がずれています。');
    exit(1);
  }
  stdout.writeln('ずれはありません。');
}
