// アプリの「xlsx の書式を読む」 所だけを取り出して試す道具。
//   dart run tool/xlsx_style_check.dart <xlsx>
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class SsBorderSide {
  final String style;
  final int? color;
  const SsBorderSide(this.style, [this.color]);
  @override
  String toString() =>
      '$style${color == null ? '' : '#${color!.toRadixString(16).padLeft(6, '0')}'}';
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
  SsCellFmt copy() => this;
  @override
  String toString() {
    final p = <String>[];
    if (bg != null) p.add('bg=#${bg!.toRadixString(16).padLeft(6, '0')}');
    if (fg != null) p.add('fg=#${fg!.toRadixString(16).padLeft(6, '0')}');
    if (size != null) p.add('size=${size!.round()}');
    if (bold) p.add('bold');
    if (italic) p.add('italic');
    if (underline) p.add('underline');
    if (hasBorder) {
      p.add('border[L=$bLeft R=$bRight T=$bTop B=$bBottom]');
    }
    return p.join(' ');
  }
}

String fmtKey(int r, int c) => '$r,$c';

(int, int)? parseA1(String s) {
  final m = RegExp(r'^\s*([A-Za-z]+)\s*(\d+)\s*$').firstMatch(s);
  if (m == null) return null;
  final letters = m.group(1)!.toUpperCase();
  var col = 0;
  for (var i = 0; i < letters.length; i++) {
    col = col * 26 + (letters.codeUnitAt(i) - 64);
  }
  final row = int.tryParse(m.group(2)!);
  if (row == null || row < 1 || col < 1) return null;
  return (row - 1, col - 1);
}

String a1(int r, int c) {
  var n = c + 1;
  var out = '';
  while (n > 0) {
    final rem = (n - 1) % 26;
    out = String.fromCharCode(65 + rem) + out;
    n = (n - 1) ~/ 26;
  }
  return '$out${r + 1}';
}

void debugPrint(Object? o) => stdout.writeln('  [debug] $o');

/// 読み込む前の下ごしらえ。 excel パッケージが落ちる書き方を直す。
///
/// ① rels の Target が絶対パス ("/xl/worksheets/…") だとシートを見失う。
/// ② `<c r="C2" s="1" t="inlineStr"></c>` のように **中身の無い文字セル**
///    (= 色や罫線だけ付けた空セル。 実際の表では珍しくない) があると
///    `findAllElements('t').first` で落ち、 ブック全体が読めなくなる。
Uint8List sanitizeXlsxForParsing(Uint8List bytes) {
  try {
    final arc = ZipDecoder().decodeBytes(bytes);
    var changed = false;
    final out = Archive();
    for (final f in arc.files) {
      var data = List<int>.from(f.content as List<int>);
      final name = f.name;
      if (name == 'xl/_rels/workbook.xml.rels') {
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
      } else if (name.startsWith('xl/worksheets/') && name.endsWith('.xml')) {
        final t = utf8.decode(data, allowMalformed: true);
        // 中身の無い <c … t="…"> から t を外す (= ただの空セル扱いにする)。
        final fixed = t.replaceAllMapped(
            RegExp(r'<c\b[^>]*?/>|<c\b[^>]*?>[\s\S]*?</c>'), (m) {
          final tag = m.group(0)!;
          final ty = RegExp(r'\st="([^"]+)"').firstMatch(tag)?.group(1);
          if (ty == null) return tag;
          final needsIs = ty == 'inlineStr';
          final hasIs = tag.contains('<is');
          final hasV = tag.contains('<v');
          final hasF = tag.contains('<f');
          if (needsIs && !hasIs) {
            return tag.replaceFirst(RegExp(r'\st="[^"]+"'), '');
          }
          if (!needsIs &&
              (ty == 'b' || ty == 'str' || ty == 'e' || ty == 's') &&
              !hasV &&
              !hasF) {
            return tag.replaceFirst(RegExp(r'\st="[^"]+"'), '');
          }
          return tag;
        });
        if (fixed != t) {
          changed = true;
          data = utf8.encode(fixed);
        }
      }
      out.addFile(ArchiveFile(name, data.length, data));
    }
    if (!changed) return bytes;
    final enc = ZipEncoder().encode(out);
    if (enc == null) return bytes;
    return Uint8List.fromList(enc);
  } catch (e) {
    debugPrint('xlsx の下ごしらえに失敗 (そのまま読みます): $e');
    return bytes;
  }
}

String xmlUnescape(String v) => v
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// Excel の昔からの 56 色 (indexed="…" で指されるもの)。
const List<int> kIndexedPalette = <int>[
  0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF,
  0x00FFFF, 0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00,
  0xFF00FF, 0x00FFFF, 0x800000, 0x008000, 0x000080, 0x808000, 0x800080,
  0x008080, 0xC0C0C0, 0x808080, 0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF,
  0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF, 0x000080, 0xFF00FF, 0xFFFF00,
  0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF, 0x00CCFF, 0xCCFFFF,
  0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99, 0x3366FF,
  0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
  0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399,
  0x333333,
];

/// テーマ色 + tint を実際の色にする。
int applyTint(int rgb, double tint) {
  if (tint == 0) return rgb;
  int ch(int v) {
    final d = tint > 0
        ? (v + (255 - v) * tint)
        : (v * (1 + tint));
    return d.round().clamp(0, 255);
  }

  return (ch((rgb >> 16) & 255) << 16) |
      (ch((rgb >> 8) & 255) << 8) |
      ch(rgb & 255);
}

/// `<fgColor …/>` などの色指定を 0xRRGGBB に直す。
int? colorFromXml(String tag, List<int> theme) {
  final rgb = RegExp(r'rgb="([0-9A-Fa-f]{6,8})"').firstMatch(tag)?.group(1);
  if (rgb != null) {
    final h = rgb.length >= 8 ? rgb.substring(rgb.length - 6) : rgb;
    return int.tryParse(h, radix: 16);
  }
  final th = RegExp(r'theme="(\d+)"').firstMatch(tag)?.group(1);
  if (th != null) {
    final i = int.tryParse(th) ?? 0;
    if (i >= 0 && i < theme.length) {
      final tint =
          double.tryParse(RegExp(r'tint="([-\d.eE]+)"').firstMatch(tag)?.group(1) ??
                  '0') ??
              0;
      return applyTint(theme[i], tint);
    }
    return null;
  }
  final ix = RegExp(r'indexed="(\d+)"').firstMatch(tag)?.group(1);
  if (ix != null) {
    final i = int.tryParse(ix) ?? 0;
    if (i >= 0 && i < kIndexedPalette.length) return kIndexedPalette[i];
  }
  return null;
}

/// テーマの色の並び (0=lt1, 1=dk1, 2=lt2, 3=dk2, 4..9=accent, 10,11=link)。
List<int> readThemeColors(String? themeXml) {
  // 読めない時のための既定 (Office の標準テーマ)。
  final def = <int>[
    0xFFFFFF, 0x000000, 0xE7E6E6, 0x44546A, 0x4472C4, 0xED7D31,
    0xA5A5A5, 0xFFC000, 0x5B9BD5, 0x70AD47, 0x0563C1, 0x954F72,
  ];
  if (themeXml == null) return def;
  try {
    final m = RegExp(r'<a:clrScheme[\s\S]*?</a:clrScheme>')
        .firstMatch(themeXml);
    if (m == null) return def;
    final blk = m.group(0)!;
    int? pick(String tag) {
      final e = RegExp('<a:$tag>([\\s\\S]*?)</a:$tag>').firstMatch(blk);
      if (e == null) return null;
      final inner = e.group(1)!;
      final sys = RegExp(r'lastClr="([0-9A-Fa-f]{6})"').firstMatch(inner);
      if (sys != null) return int.tryParse(sys.group(1)!, radix: 16);
      final srgb = RegExp(r'val="([0-9A-Fa-f]{6})"').firstMatch(inner);
      if (srgb != null) return int.tryParse(srgb.group(1)!, radix: 16);
      return null;
    }

    // ★ 並びは lt1, dk1, lt2, dk2 の順 (0 と 1、 2 と 3 が入れ替わる)。
    final order = <String>[
      'lt1', 'dk1', 'lt2', 'dk2', 'accent1', 'accent2', 'accent3',
      'accent4', 'accent5', 'accent6', 'hlink', 'folHlink',
    ];
    final out = <int>[];
    for (var i = 0; i < order.length; i++) {
      out.add(pick(order[i]) ?? def[i]);
    }
    return out;
  } catch (_) {
    return def;
  }
}

/// xlsx の書式を、 styles.xml から**自分で**全部読む。
///
/// excel パッケージの書式読みは、 テーマ色・indexed 色・罫線・下線を
/// 落とすので当てにしない (= ユーザー報告: 背景色や外枠が読み取れない)。
/// 返すのは シート名 → 「行,列」 → 飾り。
Map<String, Map<String, SsCellFmt>> readXlsxStyles(
    Uint8List bytes) {
  final out = <String, Map<String, SsCellFmt>>{};
  try {
    final arc = ZipDecoder().decodeBytes(bytes);
    String? read(String name) {
      for (final f in arc.files) {
        if (f.name == name) {
          return utf8.decode(f.content as List<int>, allowMalformed: true);
        }
      }
      return null;
    }

    final styles = read('xl/styles.xml');
    if (styles == null) return out;
    final theme = readThemeColors(read('xl/theme/theme1.xml'));

    List<String> items(String plural, String single) {
      final m =
          RegExp('<$plural[^>]*>([\\s\\S]*?)</$plural>').firstMatch(styles);
      if (m == null) return <String>[];
      final inner = m.group(1)!;
      return [
        for (final e in RegExp('<$single\\b[^>]*?/>|'
                '<$single\\b[^>]*?>[\\s\\S]*?</$single>')
            .allMatches(inner))
          e.group(0)!,
      ];
    }

    final fonts = items('fonts', 'font');
    final fills = items('fills', 'fill');
    final borders = items('borders', 'border');
    final xfs = items('cellXfs', 'xf');
    if (xfs.isEmpty) return out;

    // ── フォント ──
    final fontFmt = <SsCellFmt>[];
    for (final f in fonts) {
      final szTag = RegExp(r'<sz\b[^>]*/>').firstMatch(f)?.group(0);
      final colTag = RegExp(r'<color\b[^>]*/>').firstMatch(f)?.group(0);
      fontFmt.add(SsCellFmt(
        size: szTag == null
            ? null
            : double.tryParse(
                RegExp(r'val="([\d.]+)"').firstMatch(szTag)?.group(1) ?? ''),
        fg: colTag == null ? null : colorFromXml(colTag, theme),
        bold: RegExp(r'<b\b[^>]*/>').hasMatch(f),
        italic: RegExp(r'<i\b[^>]*/>').hasMatch(f),
        underline: RegExp(r'<u\b[^>]*/?>').hasMatch(f),
      ));
    }

    // ── 塗り ──
    final fillColor = <int?>[];
    for (final f in fills) {
      if (!f.contains('patternType="solid"')) {
        fillColor.add(null);
        continue;
      }
      final fg = RegExp(r'<fgColor\b[^>]*/>').firstMatch(f)?.group(0);
      fillColor.add(fg == null ? null : colorFromXml(fg, theme));
    }

    // ── 罫線 ──
    SsBorderSide? sideOf(String border, String side) {
      final m = RegExp('<$side\\b[^>]*?/>|<$side\\b[^>]*?>[\\s\\S]*?</$side>')
          .firstMatch(border);
      if (m == null) return null;
      final tag = m.group(0)!;
      final st = RegExp(r'style="([^"]+)"').firstMatch(tag)?.group(1);
      if (st == null || st.isEmpty || st == 'none') return null;
      final colTag = RegExp(r'<color\b[^>]*/>').firstMatch(tag)?.group(0);
      return SsBorderSide(
          st, colTag == null ? null : colorFromXml(colTag, theme));
    }

    final borderSides = <List<SsBorderSide?>>[];
    for (final b in borders) {
      borderSides.add([
        sideOf(b, 'left'),
        sideOf(b, 'right'),
        sideOf(b, 'top'),
        sideOf(b, 'bottom'),
      ]);
    }

    // ── xf → (font, fill, border) ──
    final xfFont = <int>[];
    final xfFill = <int>[];
    final xfBorder = <int>[];
    for (final x in xfs) {
      int at(String k) =>
          int.tryParse(RegExp('$k="(\\d+)"').firstMatch(x)?.group(1) ?? '0') ??
          0;
      xfFont.add(at('fontId'));
      xfFill.add(at('fillId'));
      xfBorder.add(at('borderId'));
    }

    // ── シート名 → xml の場所 ──
    final wb = read('xl/workbook.xml') ?? '';
    final rels = read('xl/_rels/workbook.xml.rels') ?? '';
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

    for (final m in RegExp(r'<sheet\b[^>]*?/?>').allMatches(wb)) {
      final t = m.group(0)!;
      final name = RegExp(r'name="([^"]*)"').firstMatch(t)?.group(1);
      final rid = RegExp(r'r:id="([^"]+)"').firstMatch(t)?.group(1);
      if (name == null || rid == null) continue;
      final path = relTarget[rid];
      if (path == null) continue;
      final xml = read(path);
      if (xml == null) continue;
      final map = <String, SsCellFmt>{};
      for (final c in RegExp(r'<c\b[^>]*').allMatches(xml)) {
        final ct = c.group(0)!;
        final ref = RegExp(r'r="([A-Za-z]+\d+)"').firstMatch(ct)?.group(1);
        final si = RegExp(r'\ss="(\d+)"').firstMatch(ct)?.group(1);
        if (ref == null || si == null) continue;
        final xi = int.tryParse(si);
        if (xi == null || xi >= xfs.length) continue;
        final rc = parseA1(ref);
        if (rc == null) continue;

        final fi = xfFont[xi];
        final base = fi < fontFmt.length ? fontFmt[fi] : null;
        final f = SsCellFmt(
          size: base?.size,
          fg: base?.fg,
          bold: base?.bold ?? false,
          italic: base?.italic ?? false,
          underline: base?.underline ?? false,
        );
        // 黒い文字は「指定なし」 と同じ扱い (暗い画面で潰れるため)。
        if (f.fg == 0x000000) f.fg = null;
        final li = xfFill[xi];
        if (li < fillColor.length) f.bg = fillColor[li];
        final bi = xfBorder[xi];
        if (bi < borderSides.length) {
          f.bLeft = borderSides[bi][0];
          f.bRight = borderSides[bi][1];
          f.bTop = borderSides[bi][2];
          f.bBottom = borderSides[bi][3];
        }
        if (!f.isEmpty) map[fmtKey(rc.$1, rc.$2)] = f;
      }
      if (map.isNotEmpty) out[xmlUnescape(name)] = map;
    }
  } catch (e) {
    debugPrint('書式の読み取りに失敗: $e');
  }
  return out;
}



int fails = 0;
void check(String what, bool ok, [String extra = '']) {
  stdout.writeln('  ${ok ? "ok  " : "FAIL"} $what${extra.isEmpty ? '' : '  ($extra)'}');
  if (!ok) fails++;
}

void main(List<String> args) {
  final raw = File(args[0]).readAsBytesSync();
  final bytes = sanitizeXlsxForParsing(Uint8List.fromList(raw));
  final all = readXlsxStyles(bytes);
  for (final e in all.entries) {
    stdout.writeln('-- シート "${e.key}" (${e.value.length} 個) --');
    final keys = e.value.keys.toList()..sort();
    for (final k in keys) {
      final p = k.split(',');
      stdout.writeln('  ${a1(int.parse(p[0]), int.parse(p[1]))}  ${e.value[k]}');
    }
  }
  final m = all['Sheet1'];
  stdout.writeln('\n== 確かめ ==');
  if (m == null) {
    check('Sheet1 が読めた', false);
  } else {
    // テーマ色の塗り
    check('C2 に灰色の塗りがある', m['1,2']?.bg != null,
        '${m['1,2']?.bg?.toRadixString(16)}');
    check('C3 に橙の塗りがある', m['2,2']?.bg != null,
        '${m['2,2']?.bg?.toRadixString(16)}');
    check('C5 に緑の塗りがある', m['4,2']?.bg != null,
        '${m['4,2']?.bg?.toRadixString(16)}');
    // 罫線
    check('C6 に四辺の罫線', m['5,2']?.bLeft != null && m['5,2']?.bRight != null &&
        m['5,2']?.bTop != null && m['5,2']?.bBottom != null);
    check('C8 に四辺の罫線', m['7,2']?.hasBorder == true);
    check('G3 が太い赤枠', m['2,6']?.bTop?.style == 'medium' &&
        m['2,6']?.bTop?.color == 0xFF0000,
        '${m['2,6']?.bTop}');
    // indexed 色
    check('G5 に indexed の塗り', m['4,6']?.bg != null,
        '${m['4,6']?.bg?.toRadixString(16)}');
  }
  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
