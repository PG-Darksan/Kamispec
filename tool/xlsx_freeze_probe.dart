// xlsx の「ウィンドウ枠の固定」 を書き込む正規表現が、 excel パッケージの
// 出す worksheet XML に本当に当たるかを確かめる使い捨ての道具。
// 使い方: dart run tool/xlsx_freeze_probe.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as xls;

String _colLabel(int c) {
  if (c < 0) return '';
  var n = c;
  final sb = StringBuffer();
  while (true) {
    sb.write(String.fromCharCode(65 + (n % 26)));
    n = n ~/ 26 - 1;
    if (n < 0) break;
  }
  return sb.toString().split('').reversed.join();
}

void main() {
  final excel = xls.Excel.createExcel();
  final name = excel.tables.keys.first;
  final sheet = excel[name];
  for (var r = 0; r < 5; r++) {
    for (var c = 0; c < 4; c++) {
      sheet
          .cell(xls.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r))
          .value = xls.TextCellValue('r${r}c$c');
    }
  }
  final bytes = Uint8List.fromList(excel.encode()!);
  final arc = ZipDecoder().decodeBytes(bytes);
  final files = <String, List<int>>{};
  for (final f in arc.files) {
    files[f.name] = List<int>.from(f.content as List<int>);
  }
  String? read(String n) => files[n] == null
      ? null
      : utf8.decode(files[n]!, allowMalformed: true);

  // ── シート名 → worksheet の道 ──
  final wb = read('xl/workbook.xml');
  final rels = read('xl/_rels/workbook.xml.rels');
  print('workbook.xml あり: ${wb != null} / rels あり: ${rels != null}');
  final relTarget = <String, String>{};
  for (final m in RegExp(r'<Relationship\b[^>]*>').allMatches(rels!)) {
    final t = m.group(0)!;
    final id = RegExp(r'Id="([^"]+)"').firstMatch(t)?.group(1);
    var tg = RegExp(r'Target="([^"]+)"').firstMatch(t)?.group(1);
    if (id == null || tg == null) continue;
    if (tg.startsWith('/')) tg = tg.substring(1);
    if (tg.startsWith('xl/')) tg = tg.substring(3);
    relTarget[id] = 'xl/$tg';
  }
  final paths = <String, String>{};
  for (final m in RegExp(r'<sheet\b[^>]*?/?>').allMatches(wb!)) {
    final t = m.group(0)!;
    final nm = RegExp(r'name="([^"]*)"').firstMatch(t)?.group(1);
    final rid = RegExp(r'r:id="([^"]+)"').firstMatch(t)?.group(1);
    if (nm == null || rid == null) continue;
    final p = relTarget[rid];
    if (p != null) paths[nm] = p;
  }
  print('見つかったシート: $paths');

  final path = paths[name];
  if (path == null) {
    print('FAIL: シートの道が引けない');
    return;
  }
  var xml = read(path)!;
  print('sheetViews あり: ${xml.contains('<sheetViews>')}');
  final sv = RegExp(r'<sheetView\b[^>]*>').firstMatch(xml);
  final svSelf = RegExp(r'<sheetView\b[^>]*/>').firstMatch(xml);
  print('sheetView 開き札: ${sv?.group(0)}');
  print('sheetView 自己終端: ${svSelf?.group(0)}');

  // ── 実装と同じ手順で <pane> を入れる ──
  const rows = 1, cols = 1;
  final topLeft = '${_colLabel(cols)}${rows + 1}';
  final tag = '<pane xSplit="$cols" ySplit="$rows" topLeftCell="$topLeft"'
      ' activePane="bottomRight" state="frozen"/>';
  if (svSelf != null && (sv == null || svSelf.start <= sv.start)) {
    final g = svSelf.group(0)!;
    final open = '${g.substring(0, g.length - 2)}>';
    xml = xml.replaceRange(svSelf.start, svSelf.end, '$open$tag</sheetView>');
    print('=> 自己終端の道を使った');
  } else if (sv != null) {
    xml = xml.substring(0, sv.end) + tag + xml.substring(sv.end);
    print('=> 開き札の道を使った');
  } else {
    final i = xml.indexOf('<sheetViews>');
    if (i < 0) {
      print('FAIL: 入れる所が無い');
      return;
    }
    final at = i + '<sheetViews>'.length;
    xml = xml.substring(0, at) +
        '<sheetView workbookViewId="0">$tag</sheetView>' +
        xml.substring(at);
    print('=> sheetViews を作る道を使った');
  }

  // ── 読み戻す ──
  final m = RegExp(r'<pane\b[^>]*/?>').firstMatch(xml);
  print('書けた pane: ${m?.group(0)}');
  final st = RegExp(r'state="([^"]*)"').firstMatch(m?.group(0) ?? '')?.group(1);
  final xs = RegExp(r'xSplit="([0-9.]+)"').firstMatch(m?.group(0) ?? '')?.group(1);
  final ys = RegExp(r'ySplit="([0-9.]+)"').firstMatch(m?.group(0) ?? '')?.group(1);
  print('読み戻し: state=$st xSplit=$xs ySplit=$ys  '
      '(期待 frozen / 1 / 1)');

  // ── 消せるか ──
  final removed = xml.replaceAll(RegExp(r'<pane\b[^>]*/>'), '');
  print('解除できた: ${!RegExp(r'<pane\b').hasMatch(removed)}');

  // ── zip に戻せるか ──
  files[path] = utf8.encode(xml);
  final outArc = Archive();
  for (final e in files.entries) {
    outArc.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  final enc = ZipEncoder().encode(outArc);
  print('zip 再構成: ${enc != null && enc.isNotEmpty} (${enc?.length} bytes)');
  try {
    final re = xls.Excel.decodeBytes(Uint8List.fromList(enc!));
    print('excel で読み直せた: シート ${re.tables.keys.toList()} '
        '/ A1=${re.tables[name]?.rows[0][0]?.value}');
  } catch (e) {
    print('FAIL: 読み直せない: $e');
  }
}
