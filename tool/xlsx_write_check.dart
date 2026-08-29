// アプリの「書式を zip に書き込む」 所だけを取り出して試す道具。
//   dart run tool/xlsx_write_check.dart <元の xlsx> <書き出す xlsx>
//
// mind_map_screen.dart の _writeCellFormatsIntoZip をそのまま写している。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as xls;

class SsBorderSide {
  final String style;
  final int? color;
  const SsBorderSide(this.style, [this.color]);
}

class SsCellFmt {
  int? bg;
  int? fg;
  double? size;
  bool bold;
  bool italic;
  bool underline;
  SsBorderSide? bLeft;
  SsBorderSide? bRight;
  SsBorderSide? bTop;
  SsBorderSide? bBottom;
  SsCellFmt({
    this.bg,
    this.fg,
    this.size,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.bLeft,
    this.bRight,
    this.bTop,
    this.bBottom,
  });
  bool get hasBorder =>
      bLeft != null || bRight != null || bTop != null || bBottom != null;
  bool get isEmpty =>
      bg == null && fg == null && size == null && !bold && !italic &&
      !underline && !hasBorder;
}

String xmlUnescape(String v) => v
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String rgbToArgbHex(int rgb) =>
    'FF${(rgb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

void debugPrint(Object? o) => stdout.writeln('  [debug] $o');

Uint8List normalizeXlsxRels(List<int> bytes) {
  try {
    final arc = ZipDecoder().decodeBytes(bytes);
    var changed = false;
    final out = Archive();
    for (final f in arc.files) {
      var data = List<int>.from(f.content as List<int>);
      if (f.name == 'xl/_rels/workbook.xml.rels') {
        final t = utf8.decode(data, allowMalformed: true);
        final fixed = t.replaceAllMapped(RegExp(r'Target="([^"]*)"'), (m) {
          var v = m.group(1)!;
          if (v.startsWith('/')) v = v.substring(1);
          if (v.startsWith('xl/')) v = v.substring(3);
          return 'Target="$v"';
        });
        if (fixed != t) {
          changed = true;
          data = utf8.encode(fixed);
        }
      }
      out.addFile(ArchiveFile(f.name, data.length, data));
    }
    if (!changed) return Uint8List.fromList(bytes);
    final enc = ZipEncoder().encode(out);
    if (enc == null) return Uint8List.fromList(bytes);
    return Uint8List.fromList(enc);
  } catch (_) {
    return Uint8List.fromList(bytes);
  }
}

/// 直した書式だけを、 出来上がった xlsx の zip に自分で書き込む。
///
/// = excel パッケージの cellStyle 経由は、 ファイルから読んだブックだと
///   番号がずれてセルの見た目が入れ替わる (= 実測)。 触らずに書き出した
///   物へ、 ここで styles.xml とシートの s= を足す。
///
/// 触っていないセルには一切手を入れないので、 元の飾りはそのまま残る。
Uint8List writeCellFormatsIntoZip(Uint8List bytes,
  Map<String, Map<String, SsCellFmt>> sheetFmts,
  Map<String, Set<String>> fmtDirty) {
  // 直した所が無ければ何もしない。
  if (fmtDirty.values.every((v) => v.isEmpty)) return bytes;
  try {
    final arc = ZipDecoder().decodeBytes(bytes);
    final files = <String, List<int>>{};
    for (final f in arc.files) {
      files[f.name] = List<int>.from(f.content as List<int>);
    }
    String? text(String name) => files[name] == null
        ? null
        : utf8.decode(files[name]!, allowMalformed: true);

    var styles = text('xl/styles.xml');
    final wb = text('xl/workbook.xml');
    final rels = text('xl/_rels/workbook.xml.rels');
    if (styles == null || wb == null || rels == null) return bytes;

    // ── シート名 → xml の場所 ──
    final relTarget = <String, String>{};
    for (final m in RegExp(r'<Relationship\b[^>]*>').allMatches(rels)) {
      final t = m.group(0)!;
      final id = RegExp(r'Id="([^"]+)"').firstMatch(t)?.group(1);
      var tg = RegExp(r'Target="([^"]+)"').firstMatch(t)?.group(1);
      if (id == null || tg == null) continue;
      if (tg.startsWith('/')) tg = tg.substring(1);
      if (tg.startsWith('xl/')) tg = tg.substring(3);
      relTarget[id] = 'xl/$tg';
    }
    final sheetPath = <String, String>{};
    for (final m in RegExp(r'<sheet\b[^>]*?/?>').allMatches(wb)) {
      final t = m.group(0)!;
      final name = RegExp(r'name="([^"]*)"').firstMatch(t)?.group(1);
      final rid = RegExp(r'r:id="([^"]+)"').firstMatch(t)?.group(1);
      if (name == null || rid == null) continue;
      final p = relTarget[rid];
      if (p != null) sheetPath[xmlUnescape(name)] = p;
    }

    // ── styles.xml をばらす ──
    List<String> block(String tag) {
      final m = RegExp('<$tag[^>]*>([\\s\\S]*?)</$tag>').firstMatch(styles!);
      if (m == null) return <String>[];
      final inner = m.group(1)!;
      final items = <String>[];
      // <x .../> か <x ...>…</x> の並び
      for (final e in RegExp(
              '<${tag.substring(0, tag.length - 1)}\\b[^>]*?/>|'
              '<${tag.substring(0, tag.length - 1)}\\b[^>]*?>[\\s\\S]*?'
              '</${tag.substring(0, tag.length - 1)}>')
          .allMatches(inner)) {
        items.add(e.group(0)!);
      }
      return items;
    }

    final fonts = block('fonts');
    final fills = block('fills');
    final bordersList = block('borders');
    final xfsM = RegExp(r'<cellXfs[^>]*>([\s\S]*?)</cellXfs>')
        .firstMatch(styles);
    if (fonts.isEmpty || xfsM == null) return bytes;
    final xfs = <String>[];
    for (final e in RegExp(r'<xf\b[^>]*?/>|<xf\b[^>]*?>[\s\S]*?</xf>')
        .allMatches(xfsM.group(1)!)) {
      xfs.add(e.group(0)!);
    }
    if (xfs.isEmpty) return bytes;

    // ── 新しく足す分 ──
    final newFonts = <String>[];
    final newFills = <String>[];
    final newBorders = <String>[];
    final newXfs = <String>[];
    final xfCache = <String, int>{};

    int addFont(String xml) {
      final at = fonts.indexOf(xml);
      if (at >= 0) return at;
      final at2 = newFonts.indexOf(xml);
      if (at2 >= 0) return fonts.length + at2;
      newFonts.add(xml);
      return fonts.length + newFonts.length - 1;
    }

    int addFill(String xml) {
      final at = fills.indexOf(xml);
      if (at >= 0) return at;
      final at2 = newFills.indexOf(xml);
      if (at2 >= 0) return fills.length + at2;
      newFills.add(xml);
      return fills.length + newFills.length - 1;
    }

    int addBorder(String xml) {
      final at = bordersList.indexOf(xml);
      if (at >= 0) return at;
      final at2 = newBorders.indexOf(xml);
      if (at2 >= 0) return bordersList.length + at2;
      newBorders.add(xml);
      return bordersList.length + newBorders.length - 1;
    }

    int addXf(String xml) {
      final at = xfCache[xml];
      if (at != null) return at;
      final at2 = newXfs.indexOf(xml);
      if (at2 >= 0) return xfs.length + at2;
      newXfs.add(xml);
      final idx = xfs.length + newXfs.length - 1;
      xfCache[xml] = idx;
      return idx;
    }

    var touched = false;
    for (final entry in fmtDirty.entries) {
      final name = entry.key;
      if (entry.value.isEmpty) continue;
      final path = sheetPath[name];
      if (path == null) continue;
      var xml = text(path);
      if (xml == null) continue;
      final fmts = sheetFmts[name] ?? const <String, SsCellFmt>{};

      for (final key in entry.value) {
        final parts = key.split(',');
        if (parts.length != 2) continue;
        final r = int.tryParse(parts[0]);
        final c = int.tryParse(parts[1]);
        if (r == null || c == null) continue;
        final ref = '${colLetters(c)}${r + 1}';
        // そのセルの今の書き方を探す
        final cellRe =
            RegExp('<c\\b[^>]*\\br="$ref"[^>]*?(/>|>)');
        final cm = cellRe.firstMatch(xml!);
        if (cm == null) continue;
        final cellTag = cm.group(0)!;
        final baseS =
            int.tryParse(RegExp(r'\ss="(\d+)"').firstMatch(cellTag)?.group(1) ??
                    '0') ??
                0;
        final baseXf = baseS < xfs.length ? xfs[baseS] : xfs[0];
        final baseFontId = int.tryParse(
                RegExp(r'fontId="(\d+)"').firstMatch(baseXf)?.group(1) ??
                    '0') ??
            0;
        final baseFont =
            baseFontId < fonts.length ? fonts[baseFontId] : fonts[0];

        final f = fmts[key];
        final int fontId;
        final int fillId;
        final int borderId;
        if (f == null || f.isEmpty) {
          // 飾りを消した → 素の書式に戻す
          fontId = 0;
          fillId = 0;
          borderId = 0;
        } else {
          fontId = addFont(buildFontXml(baseFont, f));
          fillId = f.bg == null ? 0 : addFill(buildFillXml(f.bg!));
          borderId = f.hasBorder ? addBorder(buildBorderXml(f)) : 0;
        }
        // 元の xf を土台に、 フォント / 塗り / 罫線だけ差し替える
        var xf = baseXf
            .replaceAll(RegExp(r'\sfontId="\d+"'), '')
            .replaceAll(RegExp(r'\sfillId="\d+"'), '')
            .replaceAll(RegExp(r'\sborderId="\d+"'), '')
            .replaceAll(RegExp(r'\sapplyFont="[^"]*"'), '')
            .replaceAll(RegExp(r'\sapplyBorder="[^"]*"'), '')
            .replaceAll(RegExp(r'\sapplyFill="[^"]*"'), '');
        xf = xf.replaceFirst(
            '<xf',
            '<xf fontId="$fontId" fillId="$fillId" borderId="$borderId" '
                'applyFont="1" applyFill="1" applyBorder="1"');
        final newS = addXf(xf);

        // セルの s= を書き換える
        final replaced = cellTag.contains(RegExp(r'\ss="\d+"'))
            ? cellTag.replaceFirst(RegExp(r'\ss="\d+"'), ' s="$newS"')
            : cellTag.replaceFirst('<c', '<c s="$newS"');
        xml = xml.replaceRange(cm.start, cm.end, replaced);
        touched = true;
      }
      files[path] = utf8.encode(xml!);
    }

    if (!touched) return bytes;

    // ── styles.xml を組み直す ──
    if (newFonts.isNotEmpty) {
      styles = styles!.replaceFirst(
          RegExp(r'<fonts[^>]*>'), '<fonts count="${fonts.length + newFonts.length}">');
      styles = styles.replaceFirst('</fonts>', '${newFonts.join()}</fonts>');
    }
    if (newFills.isNotEmpty) {
      styles = styles!.replaceFirst(
          RegExp(r'<fills[^>]*>'), '<fills count="${fills.length + newFills.length}">');
      styles = styles.replaceFirst('</fills>', '${newFills.join()}</fills>');
    }
    if (newBorders.isNotEmpty) {
      styles = styles!.replaceFirst(RegExp(r'<borders[^>]*>'),
          '<borders count="${bordersList.length + newBorders.length}">');
      styles = styles.replaceFirst(
          '</borders>', '${newBorders.join()}</borders>');
    }
    if (newXfs.isNotEmpty) {
      styles = styles!.replaceFirst(RegExp(r'<cellXfs[^>]*>'),
          '<cellXfs count="${xfs.length + newXfs.length}">');
      styles = styles.replaceFirst('</cellXfs>', '${newXfs.join()}</cellXfs>');
    }
    files['xl/styles.xml'] = utf8.encode(styles!);

    // ── 結び直す ──
    final out = Archive();
    for (final f in arc.files) {
      final data = files[f.name] ?? (f.content as List<int>);
      out.addFile(ArchiveFile(f.name, data.length, data));
    }
    final enc = ZipEncoder().encode(out);
    if (enc == null) return bytes;
    return Uint8List.fromList(enc);
  } catch (e, st) {
    debugPrint('書式の書き込みに失敗 (書式なしで保存します): $e\n$st');
    return bytes;
  }
}

/// 列番号 (0 始まり) → "A" / "AB"。
String colLetters(int c) {
  var n = c + 1;
  var out = '';
  while (n > 0) {
    final rem = (n - 1) % 26;
    out = String.fromCharCode(65 + rem) + out;
    n = (n - 1) ~/ 26;
  }
  return out;
}

/// 元のフォントを土台に、 指定された飾りだけを差し替えた <font> を作る。
String buildFontXml(String baseFont, SsCellFmt f) {
  // 中身を取り出す (<font ...>中身</font> か <font .../>)
  final m = RegExp(r'^<font\b[^>]*>([\s\S]*)</font>$').firstMatch(baseFont);
  var inner = m?.group(1) ?? '';
  // 差し替える物は落とす
  inner = inner
      .replaceAll(RegExp(r'<sz\b[^>]*/>'), '')
      .replaceAll(RegExp(r'<color\b[^>]*/>'), '')
      .replaceAll(RegExp(r'<b\b[^>]*/>'), '')
      .replaceAll(RegExp(r'<i\b[^>]*/>'), '')
      .replaceAll(RegExp(r'<u\b[^>]*/>'), '');
  final sb = StringBuffer('<font>');
  sb.write(inner);
  if (f.bold) sb.write('<b/>');
  if (f.italic) sb.write('<i/>');
  if (f.underline) sb.write('<u/>');
  if (f.size != null) sb.write('<sz val="${f.size!.round()}"/>');
  if (f.fg != null) sb.write('<color rgb="${rgbToArgbHex(f.fg!)}"/>');
  sb.write('</font>');
  return sb.toString();
}

/// 罫線を <border> の形にする。
String buildBorderXml(SsCellFmt f) {
  String side(String name, SsBorderSide? b) {
    if (b == null) return '<$name/>';
    final col = b.color == null
        ? ''
        : '<color rgb="${rgbToArgbHex(b.color!)}"/>';
    return '<$name style="${b.style}">$col</$name>';
  }

  return '<border>${side('left', f.bLeft)}${side('right', f.bRight)}'
      '${side('top', f.bTop)}${side('bottom', f.bBottom)}<diagonal/></border>';
}

String buildFillXml(int bg) =>
    '<fill><patternFill patternType="solid">'
    '<fgColor rgb="${rgbToArgbHex(bg)}"/><bgColor indexed="64"/>'
    '</patternFill></fill>';


int fails = 0;
void check(String what, bool ok, [String extra = '']) {
  stdout.writeln('  ${ok ? "ok  " : "FAIL"} $what${extra.isEmpty ? '' : '  ($extra)'}');
  if (!ok) fails++;
}

void main(List<String> args) {
  final src = args[0];
  final dst = args[1];

  // ── 読む (アプリと同じく rels を直してから) ──
  final bytes = normalizeXlsxRels(File(src).readAsBytesSync());
  final excel = xls.Excel.decodeBytes(bytes);

  // ── 利用者が D3 と B9 を直したことにする ──
  final sheet = excel.tables.keys.first;
  final fmts = <String, Map<String, SsCellFmt>>{
    sheet: {
      // D3: 背景を水色・文字を白・18pt・太字 + 下線
      '2,3': SsCellFmt(
          bg: 0x2E75B6, fg: 0xFFFFFF, size: 18, bold: true, underline: true,
          bLeft: const SsBorderSide('thin'),
          bRight: const SsBorderSide('thin'),
          bTop: const SsBorderSide('thin'),
          bBottom: const SsBorderSide('thin')),
      // B9: 太い赤枠だけ
      '8,1': SsCellFmt(italic: true, size: 14,
          bTop: const SsBorderSide('medium', 0xFF0000),
          bBottom: const SsBorderSide('medium', 0xFF0000)),
    }
  };
  final dirty = <String, Set<String>>{
    sheet: {'2,3', '8,1'}
  };

  // ── アプリと同じ順で: encode → 書式を zip に書く ──
  final enc = excel.encode();
  final withFmt =
      writeCellFormatsIntoZip(Uint8List.fromList(enc!), fmts, dirty);
  File(dst).writeAsBytesSync(withFmt);
  stdout.writeln('書き出し: $dst (${withFmt.length} bytes)');

  // ── 読み直して確かめる ──
  final e2 = xls.Excel.decodeBytes(normalizeXlsxRels(File(dst).readAsBytesSync()));
  final t2 = e2.tables[sheet]!;
  xls.CellStyle? styleAt(int r, int c) =>
      (t2.rows.length > r && t2.rows[r].length > c) ? t2.rows[r][c]?.cellStyle : null;

  stdout.writeln('\n== 直したセル ==');
  final d3 = styleAt(2, 3);
  check('D3 の背景が水色', d3?.backgroundColor.colorHex == 'FF2E75B6',
      '${d3?.backgroundColor.colorHex}');
  check('D3 の文字が白', d3?.fontColor.colorHex == 'FFFFFFFF',
      '${d3?.fontColor.colorHex}');
  check('D3 が 18pt', d3?.fontSize == 18, '${d3?.fontSize}');
  check('D3 が太字', d3?.isBold == true);

  final b9 = styleAt(8, 1);
  check('B9 が斜体', b9?.isItalic == true);
  check('B9 が 14pt', b9?.fontSize == 14, '${b9?.fontSize}');

  stdout.writeln('\n== 触っていないセル (壊れていないか) ==');
  final a1 = styleAt(0, 0);
  check('A1 の背景が青のまま', a1?.backgroundColor.colorHex == 'FF2E75B6',
      '${a1?.backgroundColor.colorHex}');
  check('A1 の文字が白のまま', a1?.fontColor.colorHex == 'FFFFFFFF',
      '${a1?.fontColor.colorHex}');
  check('A1 が 16pt のまま', a1?.fontSize == 16, '${a1?.fontSize}');
  final c5 = styleAt(4, 2);
  check('C5 が赤 + 斜体のまま',
      c5?.fontColor.colorHex == 'FFFF0000' && c5?.isItalic == true,
      '${c5?.fontColor.colorHex} italic=${c5?.isItalic}');
  final a2 = styleAt(1, 0);
  check('A2 の見出しの塗りが残る', a2?.backgroundColor.colorHex == 'FFD9E1F2',
      '${a2?.backgroundColor.colorHex}');

  stdout.writeln('\n== 結合 ==');
  final spans = t2.spannedItems.toSet();
  check('A1:D1 が残る', spans.contains('A1:D1'));
  check('A6:A7 が残る', spans.contains('A6:A7'));
  check('B9:C10 が残る', spans.contains('B9:C10'));

  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
