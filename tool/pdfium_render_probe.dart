// 使い捨ての検算道具: アプリと同じ pdfium で PDF のページを絵にして、
// 「元の PDF + 注釈あり」 と「焼き込んだ控え + 注釈なし」 を見比べる。
//
// アプリのビューアは FPDF_ANNOT を渡していない (= 注釈を描かない) ので、
// 控えを注釈なしで描いた絵が、 元を注釈ありで描いた絵と重なれば、
// 焼き込みの位置と見た目が正しいことになる。
//
//   dart run tool/pdfium_render_probe.dart <元.pdf> <控え.pdf> <ページ番号> <出力先>
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;

const int kFpdfAnnot = 0x01;
const int kFpdfLcdText = 0x02;
const int kFpdfReverseByteOrder = 0x10;

late final DynamicLibrary _lib;

final _init = _lib.lookupFunction<Void Function(), void Function()>(
    'FPDF_InitLibrary');
final _destroy = _lib.lookupFunction<Void Function(), void Function()>(
    'FPDF_DestroyLibrary');
final _loadDoc = _lib.lookupFunction<
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>),
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>)>('FPDF_LoadDocument');
final _closeDoc = _lib.lookupFunction<Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('FPDF_CloseDocument');
final _loadPage = _lib.lookupFunction<
    Pointer<Void> Function(Pointer<Void>, Int32),
    Pointer<Void> Function(Pointer<Void>, int)>('FPDF_LoadPage');
final _closePage = _lib.lookupFunction<Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('FPDF_ClosePage');
final _pageW = _lib.lookupFunction<Double Function(Pointer<Void>),
    double Function(Pointer<Void>)>('FPDF_GetPageWidth');
final _pageH = _lib.lookupFunction<Double Function(Pointer<Void>),
    double Function(Pointer<Void>)>('FPDF_GetPageHeight');
final _bmpCreate = _lib.lookupFunction<
    Pointer<Void> Function(Int32, Int32, Int32),
    Pointer<Void> Function(int, int, int)>('FPDFBitmap_Create');
final _bmpFill = _lib.lookupFunction<
    Void Function(Pointer<Void>, Int32, Int32, Int32, Int32, Uint32),
    void Function(
        Pointer<Void>, int, int, int, int, int)>('FPDFBitmap_FillRect');
final _bmpBuf = _lib.lookupFunction<Pointer<Uint8> Function(Pointer<Void>),
    Pointer<Uint8> Function(Pointer<Void>)>('FPDFBitmap_GetBuffer');
final _bmpStride = _lib.lookupFunction<Int32 Function(Pointer<Void>),
    int Function(Pointer<Void>)>('FPDFBitmap_GetStride');
final _bmpDestroy = _lib.lookupFunction<Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('FPDFBitmap_Destroy');
final _render = _lib.lookupFunction<
    Void Function(Pointer<Void>, Pointer<Void>, Int32, Int32, Int32, Int32,
        Int32, Int32),
    void Function(Pointer<Void>, Pointer<Void>, int, int, int, int, int,
        int)>('FPDF_RenderPageBitmap');

img.Image renderPage(String path, int pageIndex, int flags, double scale) {
  final p = path.toNativeUtf8();
  final doc = _loadDoc(p, nullptr);
  calloc.free(p);
  if (doc == nullptr) throw StateError('開けません: $path');
  final page = _loadPage(doc, pageIndex);
  if (page == nullptr) throw StateError('ページが読めません');
  final w = (_pageW(page) * scale).round();
  final h = (_pageH(page) * scale).round();
  final bmp = _bmpCreate(w, h, 0);
  _bmpFill(bmp, 0, 0, w, h, 0xFFFFFFFF);
  _render(bmp, page, 0, 0, w, h, 0, flags);
  final stride = _bmpStride(bmp);
  final buf = _bmpBuf(bmp);
  final out = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = y * stride + x * 4;
      // FPDF_REVERSE_BYTE_ORDER を渡していないので BGRA。
      out.setPixelRgb(x, y, buf[o + 2], buf[o + 1], buf[o]);
    }
  }
  _bmpDestroy(bmp);
  _closePage(page);
  _closeDoc(doc);
  return out;
}

void main(List<String> args) {
  final dll = Platform.environment['PDFIUM_DLL'] ??
      r'build\windows\x64\runner\Release\pdfium.dll';
  _lib = DynamicLibrary.open(dll);
  _init();
  try {
    final src = args[0], flat = args[1];
    final pageNo = int.parse(args[2]);
    final outDir = args[3];
    Directory(outDir).createSync(recursive: true);
    const scale = 2.0;

    // 正解: 元の PDF を「注釈あり」 で描く。
    final truth = renderPage(src, pageNo - 1, kFpdfAnnot | kFpdfLcdText, scale);
    // アプリの見え方: 控えを「注釈なし」 で描く。
    final shown = renderPage(flat, pageNo - 1, kFpdfLcdText, scale);
    // 直す前の見え方: 元を「注釈なし」 で描く (= 印がまったく出ない)。
    final bare = renderPage(src, pageNo - 1, kFpdfLcdText, scale);

    File('$outDir/p${pageNo}_truth.png')
        .writeAsBytesSync(img.encodePng(truth));
    File('$outDir/p${pageNo}_shown.png')
        .writeAsBytesSync(img.encodePng(shown));
    File('$outDir/p${pageNo}_bare.png').writeAsBytesSync(img.encodePng(bare));

    int diffCount(img.Image a, img.Image b) {
      var n = 0;
      for (var y = 0; y < a.height; y++) {
        for (var x = 0; x < a.width; x++) {
          final pa = a.getPixel(x, y), pb = b.getPixel(x, y);
          final d = (pa.r - pb.r).abs() +
              (pa.g - pb.g).abs() +
              (pa.b - pb.b).abs();
          if (d > 24) n++;
        }
      }
      return n;
    }

    final total = truth.width * truth.height;
    final dShown = diffCount(truth, shown);
    final dBare = diffCount(truth, bare);
    stdout.writeln('page $pageNo  ${truth.width}x${truth.height}');
    stdout.writeln('  正解 vs 控え(注釈なし) = $dShown 画素 '
        '(${(dShown * 100 / total).toStringAsFixed(3)}%)');
    stdout.writeln('  正解 vs 元(注釈なし)   = $dBare 画素 '
        '(${(dBare * 100 / total).toStringAsFixed(3)}%)');

    // ずれを目で見るための重ね絵 (正解=赤 / 控え=緑)。
    final over = img.Image(width: truth.width, height: truth.height);
    for (var y = 0; y < truth.height; y++) {
      for (var x = 0; x < truth.width; x++) {
        final t = truth.getPixel(x, y), s = shown.getPixel(x, y);
        final tb = t.r < 200 || t.g < 200 || t.b < 200;
        final sb = s.r < 200 || s.g < 200 || s.b < 200;
        over.setPixelRgb(x, y, tb ? 255 : 255, sb ? 255 : 255,
            (tb == sb) ? 255 : 0);
        if (tb != sb) over.setPixelRgb(x, y, tb ? 255 : 0, sb ? 255 : 0, 0);
      }
    }
    File('$outDir/p${pageNo}_overlay.png')
        .writeAsBytesSync(img.encodePng(over));

    final bytes = Uint8List.fromList(img.encodePng(shown));
    stdout.writeln('  書き出し: $outDir (shown=${bytes.length} bytes)');
  } finally {
    _destroy();
  }
}
