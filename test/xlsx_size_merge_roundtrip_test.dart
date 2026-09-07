// 表計算エディタで変えた「列の幅 / 行の高さ / セルの結合」 が、
// xlsx に入って読み直せるかの見張り (= ユーザー要望)。
//
// エディタ本体の換算式と同じ物をここにも置き、 往復して値が戻るかを見る。
// (本体の換算は private なので、 式が変わったらここも直すこと。)
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as xls;
import 'package:flutter_test/flutter_test.dart';

// ── mind_map_screen.dart の _pxToXlsxWidth などと同じ式 ──
double pxToWidth(double px) => (px - 5) / 7;
double widthToPx(double w) => w * 7 + 5;
double pxToHeight(double px) => px * 3 / 4;
double heightToPx(double pt) => pt * 4 / 3;

void main() {
  test('列の幅 / 行の高さ / 結合が xlsx を往復する', () {
    final excel = xls.Excel.createExcel();
    final name = excel.getDefaultSheet()!;
    final sheet = excel[name];

    // 中身を少し入れておく (空だと <row> が出ない事があるため)。
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        sheet
            .cell(xls.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r))
            .value = xls.TextCellValue('r${r}c$c');
      }
    }

    // 画面で決めた px を xlsx の単位へ。
    const colPx = 220.0; // 幅を広げた列
    const rowPx = 60.0; // 高さを広げた行
    sheet.setColumnWidth(1, pxToWidth(colPx));
    sheet.setRowHeight(2, pxToHeight(rowPx));
    sheet.merge(
      xls.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
      xls.CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: 1),
    );

    final bytes = excel.encode();
    expect(bytes, isNotNull);

    // ── 読み直す ──
    final back = xls.Excel.decodeBytes(bytes!);
    final s2 = back[name];

    final cw = s2.getColumnWidths;
    // ignore: avoid_print
    print('読み直した列の幅 = $cw');
    expect(cw.containsKey(1), isTrue, reason: '広げた列の幅が残っていない');
    expect(widthToPx(cw[1]!), closeTo(colPx, 0.5));
    // ★ 触っていない列にも既定の幅で <col> が付く (excel パッケージは
    //   いちばん大きい番号までまとめて書き出すため)。 実害は無いので許す。

    final rh = s2.getRowHeights;
    // ignore: avoid_print
    print('読み直した行の高さ = $rh');
    expect(rh.containsKey(2), isTrue, reason: '広げた行の高さが残っていない');
    expect(heightToPx(rh[2]!), closeTo(rowPx, 0.5));

    // ignore: avoid_print
    print('読み直した結合 = ${s2.spannedItems}');
    expect(s2.spannedItems, contains('A1:C2'));
  });

  test('結合を外した状態も往復する', () {
    final excel = xls.Excel.createExcel();
    final name = excel.getDefaultSheet()!;
    final sheet = excel[name];
    sheet
        .cell(xls.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
        .value = xls.TextCellValue('x');
    sheet.merge(
      xls.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
      xls.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 0),
    );
    final once = xls.Excel.decodeBytes(excel.encode()!);
    expect(once[name].spannedItems, isNotEmpty);

    // エディタの「結合を外す」 と同じ手順 (spannedItems を回して unMerge)。
    final s2 = once[name];
    for (final span in List<String>.from(s2.spannedItems)) {
      s2.unMerge(span);
    }
    final twice = xls.Excel.decodeBytes(once.encode()!);
    // ignore: avoid_print
    print('外した後 = ${twice[name].spannedItems}');
    // ★ ここが excel パッケージの穴。 そのシートの結合を**全部**外すと
    //   save_file.dart の `_setMerge` が `_spanList.isNotEmpty` で弾かれ、
    //   <mergeCells> が書き直されない = ファイルに残ったままになる。
    //   これが「結合解除ができない」 の正体。 アプリ側は
    //   `_writeCellFormatsIntoZip` で自分で <mergeCells> を書き直して直した。
    //   この見張りは「パッケージ任せでは駄目」 を固定するためのもの。
    expect(twice[name].spannedItems, isNotEmpty,
        reason: 'パッケージが直ったら、 アプリ側の自前書き直しを見直せる');
  });

  // ★ アプリ本体の直し (= 自分で <mergeCells> を書き直す) を、
  //   同じ手順で確かめる。 パッケージ任せでは消えなかった結合が、
  //   これなら本当にファイルから消えることを見る。
  test('自分で <mergeCells> を書き直せば、 結合は本当に外れる', () {
    final excel = xls.Excel.createExcel();
    final name = excel.getDefaultSheet()!;
    final sheet = excel[name];
    sheet
        .cell(xls.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
        .value = xls.TextCellValue('x');
    sheet.merge(
      xls.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
      xls.CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 0),
    );
    final bytes = Uint8List.fromList(excel.encode()!);
    expect(xls.Excel.decodeBytes(bytes)[name].spannedItems, isNotEmpty);

    // ── mind_map_screen.dart の _writeCellFormatsIntoZip と同じ手順 ──
    final arc = ZipDecoder().decodeBytes(bytes);
    final files = <String, List<int>>{};
    for (final f in arc.files) {
      files[f.name] = List<int>.from(f.content as List<int>);
    }
    var hit = 0;
    for (final key in files.keys.toList()) {
      if (!key.startsWith('xl/worksheets/') || !key.endsWith('.xml')) continue;
      var xml = utf8.decode(files[key]!, allowMalformed: true);
      if (!xml.contains('<mergeCells')) continue;
      xml = xml
          .replaceAll(RegExp(r'<mergeCells[^>]*>[\s\S]*?</mergeCells>'), '')
          .replaceAll(RegExp(r'<mergeCells[^>]*/>'), '');
      files[key] = utf8.encode(xml);
      hit++;
    }
    expect(hit, greaterThan(0), reason: '<mergeCells> が見つからない');

    final out = Archive();
    for (final f in arc.files) {
      final data = files[f.name] ?? (f.content as List<int>);
      out.addFile(ArchiveFile(f.name, data.length, data));
    }
    final rebuilt = Uint8List.fromList(ZipEncoder().encode(out)!);
    final after = xls.Excel.decodeBytes(rebuilt);
    // ignore: avoid_print
    print('自前で書き直した後 = ${after[name].spannedItems}');
    expect(after[name].spannedItems, isEmpty);
  });
}
