// xlsx の <xf> へ 「折り返して全体を表示する」 (wrapText) を書き足す所だけを
// 取り出して確かめる道具。
//   dart run tool/xlsx_wrap_probe.dart
//
// アプリ側 (_applyXlsxCellStyles) と同じ書き換えをして、
//   1. XML として壊れていないか
//   2. 読み側の正規表現で wrap が意図どおり取れるか
//   3. 元からあった寄せ方 (horizontal など) が消えていないか
// を見る。
import 'package:xml/xml.dart' as xml;

/// アプリと同じ書き換え (= _applyXlsxCellStyles の中の折り返しの所)。
String applyWrap(String baseXf, bool wrapOn,
    {int fontId = 0, int fillId = 0, int borderId = 0}) {
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

  final alRe = RegExp(r'<alignment\b[^>]*?/>'
      r'|<alignment\b[^>]*?>[\s\S]*?</alignment>'
      r'|<alignment\b[^>]*?>');
  final alOld = alRe.firstMatch(xf)?.group(0);
  final alOpen = alOld == null
      ? null
      : RegExp(r'^<alignment\b[^>]*?/?>').firstMatch(alOld)?.group(0);
  final alAttrs = alOpen == null
      ? ''
      : alOpen
          .replaceFirst('<alignment', '')
          .replaceAll(RegExp(r'/?>$'), '')
          .replaceAll(RegExp(r'\swrapText="[^"]*"'), '')
          .trimRight();
  final alNew = '<alignment$alAttrs wrapText="${wrapOn ? '1' : '0'}"/>';
  xf = xf
      .replaceAll(alRe, '')
      .replaceAll(RegExp(r'\sapplyAlignment="[^"]*"'), '')
      .replaceFirst('<xf', '<xf applyAlignment="1"');
  if (xf.endsWith('/>')) {
    xf = '${xf.substring(0, xf.length - 2)}>$alNew</xf>';
  } else {
    final open = RegExp(r'^<xf\b[^>]*>').firstMatch(xf)?.group(0);
    xf = open == null
        ? xf.replaceFirst('</xf>', '$alNew</xf>')
        : xf.replaceFirst(open, '$open$alNew');
  }
  return xf;
}

/// アプリの読み側と同じ判定 (= _readXlsxStyles の xfWrap)。
bool readWrap(String x) {
  final al = RegExp(r'<alignment\b[^>]*/?>').firstMatch(x)?.group(0);
  final w = al == null
      ? null
      : RegExp(r'wrapText="([^"]+)"').firstMatch(al)?.group(1);
  return w == '1' || w?.toLowerCase() == 'true';
}

int fails = 0;

void check(String label, bool ok, [String? detail]) {
  print('${ok ? '  OK  ' : ' FAIL '} $label${detail == null ? '' : '  → $detail'}');
  if (!ok) fails++;
}

void run(String label, String base, bool wrapOn,
    {String? mustKeep, required bool expectWrap}) {
  print('\n■ $label  (wrapOn=$wrapOn)');
  print('  in : $base');
  final out = applyWrap(base, wrapOn);
  print('  out: $out');

  // 1. XML として読めるか
  var parsed = true;
  try {
    xml.XmlDocument.parse('<cellXfs>$out</cellXfs>');
  } catch (e) {
    parsed = false;
    print('      parse error: $e');
  }
  check('XML として壊れていない', parsed);

  // 2. 読み側で wrap が取れるか
  check('読み直すと wrap=$expectWrap', readWrap(out) == expectWrap,
      'readWrap=${readWrap(out)}');

  // 3. 元の寄せ方が残っているか
  if (mustKeep != null) {
    check('元の指定 "$mustKeep" が残っている', out.contains(mustKeep));
  }

  // 4. <alignment> は 1 個だけ (重ねて足していない)
  final n = RegExp(r'<alignment\b').allMatches(out).length;
  check('<alignment> は 1 個だけ', n == 1, '$n 個');

  // 4b. 閉じ札が取り残されていない
  check('</alignment> が残っていない', !out.contains('</alignment>'));

  // 5. applyAlignment が付いている (Excel はこれが無いと寄せを見ない)
  check('applyAlignment="1" が付いている', out.contains('applyAlignment="1"'));

  // 5b. 決まり (CT_Xf) の順番: alignment → protection
  final ai = out.indexOf('<alignment');
  final pi = out.indexOf('<protection');
  check('<alignment> は <protection> より前', pi < 0 || ai < pi,
      'alignment=$ai protection=$pi');

  // 6. font/fill/border の指定が 1 組だけ
  for (final k in ['fontId', 'fillId', 'borderId']) {
    final c = RegExp('$k="').allMatches(out).length;
    check('$k は 1 個だけ', c == 1, '$c 個');
  }
}

void main() {
  // ふつうの自己完結タグ (いちばん多い形)
  run('素の <xf .../>', '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" '
      'xfId="0"/>', true, expectWrap: true);

  // 既に寄せ方を持っている (中身つき)
  run(
      '寄せ方つき <xf ...>…</xf>',
      '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" '
          'applyFont="1" applyAlignment="1">'
          '<alignment horizontal="center" vertical="center"/></xf>',
      true,
      mustKeep: 'horizontal="center"',
      expectWrap: true);

  // 既に折り返しが入っている物を、 外す
  run(
      '折り返しを外す',
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" '
          'applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf>',
      false,
      mustKeep: 'vertical="top"',
      expectWrap: false);

  // 既に折り返しが入っている物を、 入れ直す (二重にならないこと)
  run(
      '折り返しを入れ直す',
      '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" '
          'applyAlignment="1"><alignment wrapText="true"/></xf>',
      true,
      expectWrap: true);

  // <protection> のような別の子を持っている物
  run(
      '別の子つき',
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" '
          'applyProtection="1"><protection locked="0"/></xf>',
      true,
      mustKeep: '<protection locked="0"/>',
      expectWrap: true);

  // 閉じ札を持つ形 (一部の生成系がこう書く)。 開き札だけに当てると
  // </alignment> が取り残されて styles.xml が壊れる (= 点検で判明)。
  run(
      '閉じ札つき <alignment ...></alignment>',
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" '
          'applyAlignment="1">'
          '<alignment horizontal="center"></alignment></xf>',
      true,
      mustKeep: 'horizontal="center"',
      expectWrap: true);

  // 閉じ札つき + 折り返しが既に入っている物を外す
  run(
      '閉じ札つきの折り返しを外す',
      '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" '
          'applyAlignment="1">'
          '<alignment vertical="top" wrapText="1"></alignment></xf>',
      false,
      mustKeep: 'vertical="top"',
      expectWrap: false);

  print('\n${fails == 0 ? 'すべて通った' : "$fails 件こけた"}');
}
