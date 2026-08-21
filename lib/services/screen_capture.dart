// Windows のデスクトップ画面から矩形をキャプチャして PNG バイト列を返す。
//
// なぜ FFI で Win32 を直接叩くのか:
//   `webview_windows` (WebView2) にはスクリーンショット API が無く、
//   WebView2 の描画は Flutter のテクスチャ合成で画面に出るため
//   `RenderRepaintBoundary.toImage()` でも中身が取れない。
//   そこで「画面に出ているものをそのまま撮る」 = デスクトップ DC からの
//   BitBlt を使う (= ユーザー要望: 自動操作とスクショの組み合わせ)。
//
// 制限: 対象ウィンドウが他のウィンドウに隠れていると隠れたまま写る
//   (画面に見えているものを撮る方式のため)。 最小化中は撮れない。
import 'dart:ffi';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

// ── Win32 バインディング ────────────────────────────────────────────────
typedef _GetDCNative = IntPtr Function(IntPtr hWnd);
typedef _GetDCDart = int Function(int hWnd);

typedef _ReleaseDCNative = Int32 Function(IntPtr hWnd, IntPtr hDC);
typedef _ReleaseDCDart = int Function(int hWnd, int hDC);

typedef _CreateCompatibleDCNative = IntPtr Function(IntPtr hdc);
typedef _CreateCompatibleDCDart = int Function(int hdc);

typedef _CreateCompatibleBitmapNative = IntPtr Function(
    IntPtr hdc, Int32 cx, Int32 cy);
typedef _CreateCompatibleBitmapDart = int Function(int hdc, int cx, int cy);

typedef _SelectObjectNative = IntPtr Function(IntPtr hdc, IntPtr h);
typedef _SelectObjectDart = int Function(int hdc, int h);

typedef _BitBltNative = Int32 Function(IntPtr hdc, Int32 x, Int32 y, Int32 cx,
    Int32 cy, IntPtr hdcSrc, Int32 x1, Int32 y1, Uint32 rop);
typedef _BitBltDart = int Function(int hdc, int x, int y, int cx, int cy,
    int hdcSrc, int x1, int y1, int rop);

typedef _DeleteObjectNative = Int32 Function(IntPtr ho);
typedef _DeleteObjectDart = int Function(int ho);

typedef _DeleteDCNative = Int32 Function(IntPtr hdc);
typedef _DeleteDCDart = int Function(int hdc);

typedef _GetDIBitsNative = Int32 Function(IntPtr hdc, IntPtr hbm, Uint32 start,
    Uint32 cLines, Pointer<Uint8> lpvBits, Pointer<Uint8> lpbmi, Uint32 usage);
typedef _GetDIBitsDart = int Function(int hdc, int hbm, int start, int cLines,
    Pointer<Uint8> lpvBits, Pointer<Uint8> lpbmi, int usage);

const int _srcCopy = 0x00CC0020;
const int _captureBlt = 0x40000000;
const int _diRgbColors = 0;

/// 仮想デスクトップ全体 (複数のモニターを含む) の位置と大きさ。
/// 物理ピクセル。 Windows 以外では null。
///
/// = ユーザー要望「録画する範囲を指定できるように」。 範囲を選ぶ画面で
///   デスクトップ全体を写して、 その上をなぞってもらうために使う。
({int x, int y, int width, int height})? virtualScreenRect() {
  if (!_isWindows) return null;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final getMetrics = user32.lookupFunction<Int32 Function(Int32),
        int Function(int)>('GetSystemMetrics');
    // SM_XVIRTUALSCREEN=76 / SM_YVIRTUALSCREEN=77
    // SM_CXVIRTUALSCREEN=78 / SM_CYVIRTUALSCREEN=79
    final x = getMetrics(76);
    final y = getMetrics(77);
    var w = getMetrics(78);
    var h = getMetrics(79);
    if (w <= 0 || h <= 0) {
      // 取れない環境では主モニターだけ (SM_CXSCREEN=0 / SM_CYSCREEN=1)。
      w = getMetrics(0);
      h = getMetrics(1);
    }
    if (w <= 0 || h <= 0) return null;
    return (x: x, y: y, width: w, height: h);
  } catch (_) {
    return null;
  }
}

/// つながっているモニターの数。 取れない環境では 1。
///
/// = 画面録画のカーソル点滅対策で「1 枚だけなら ddagrab を使える」 の判定に
///   使う (ddagrab は 1 つの出力しか撮れないため)。
int monitorCount() {
  if (!_isWindows) return 1;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final getMetrics = user32.lookupFunction<Int32 Function(Int32),
        int Function(int)>('GetSystemMetrics');
    final n = getMetrics(80); // SM_CMONITORS
    return n > 0 ? n : 1;
  } catch (_) {
    return 1;
  }
}

/// 画面座標 (物理ピクセル) の矩形をキャプチャして PNG で返す。
Uint8List? captureScreenRectPng(int x, int y, int width, int height) =>
    _captureScreenRect(x, y, width, height, jpeg: false);

/// 同上を JPEG で返す (= ユーザー要望: データ容量が小さく済む)。
/// [quality] は 1〜100。
Uint8List? captureScreenRectJpg(int x, int y, int width, int height,
        {int quality = 85}) =>
    _captureScreenRect(x, y, width, height, jpeg: true, quality: quality);

/// 画面座標 (論理ピクセル ではなく 物理ピクセル) の矩形をキャプチャする。
/// 失敗したら null。 Windows 以外では常に null。
Uint8List? _captureScreenRect(int x, int y, int width, int height,
    {bool jpeg = false, int quality = 85}) {
  if (!_isWindows) return null;
  if (width <= 0 || height <= 0) return null;
  final gdi = DynamicLibrary.open('gdi32.dll');
  final user32 = DynamicLibrary.open('user32.dll');

  final getDC = user32.lookupFunction<_GetDCNative, _GetDCDart>('GetDC');
  final releaseDC =
      user32.lookupFunction<_ReleaseDCNative, _ReleaseDCDart>('ReleaseDC');
  final createCompatibleDC =
      gdi.lookupFunction<_CreateCompatibleDCNative, _CreateCompatibleDCDart>(
          'CreateCompatibleDC');
  final createCompatibleBitmap = gdi.lookupFunction<
      _CreateCompatibleBitmapNative,
      _CreateCompatibleBitmapDart>('CreateCompatibleBitmap');
  final selectObject =
      gdi.lookupFunction<_SelectObjectNative, _SelectObjectDart>(
          'SelectObject');
  final bitBlt = gdi.lookupFunction<_BitBltNative, _BitBltDart>('BitBlt');
  final deleteObject =
      gdi.lookupFunction<_DeleteObjectNative, _DeleteObjectDart>(
          'DeleteObject');
  final deleteDC =
      gdi.lookupFunction<_DeleteDCNative, _DeleteDCDart>('DeleteDC');
  final getDIBits =
      gdi.lookupFunction<_GetDIBitsNative, _GetDIBitsDart>('GetDIBits');

  final screenDC = getDC(0);
  if (screenDC == 0) return null;
  final memDC = createCompatibleDC(screenDC);
  final bmp = createCompatibleBitmap(screenDC, width, height);
  Pointer<Uint8>? bits;
  Pointer<Uint8>? bmi;
  try {
    if (memDC == 0 || bmp == 0) return null;
    final old = selectObject(memDC, bmp);
    final ok = bitBlt(memDC, 0, 0, width, height, screenDC, x, y,
        _srcCopy | _captureBlt);
    if (ok == 0) return null;

    // BITMAPINFOHEADER (40 byte) をゼロ埋めで組む
    bmi = calloc<Uint8>(40 + 12);
    final h = bmi.cast<Int32>();
    h[0] = 40; // biSize
    h[1] = width; // biWidth
    h[2] = -height; // biHeight (負 = トップダウン)
    // biPlanes(2byte) + biBitCount(2byte) をまとめて書く
    bmi.cast<Uint16>()[6] = 1; // biPlanes
    bmi.cast<Uint16>()[7] = 32; // biBitCount
    h[4] = 0; // biCompression = BI_RGB

    final byteCount = width * height * 4;
    bits = calloc<Uint8>(byteCount);
    final lines =
        getDIBits(memDC, bmp, 0, height, bits, bmi, _diRgbColors);
    selectObject(memDC, old);
    if (lines == 0) return null;

    // BGRA → RGBA に並べ替えて PNG エンコード
    final src = bits.asTypedList(byteCount);
    final rgba = Uint8List(byteCount);
    for (var i = 0; i < byteCount; i += 4) {
      rgba[i] = src[i + 2];
      rgba[i + 1] = src[i + 1];
      rgba[i + 2] = src[i];
      rgba[i + 3] = 255;
    }
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      numChannels: 4,
    );
    return Uint8List.fromList(
        jpeg ? img.encodeJpg(image, quality: quality) : img.encodePng(image));
  } catch (e) {
    debugPrint('captureScreenRectPng: $e');
    return null;
  } finally {
    if (bits != null) calloc.free(bits);
    if (bmi != null) calloc.free(bmi);
    if (bmp != 0) deleteObject(bmp);
    if (memDC != 0) deleteDC(memDC);
    releaseDC(0, screenDC);
  }
}

bool get _isWindows {
  try {
    return defaultTargetPlatform == TargetPlatform.windows && !kIsWeb;
  } catch (_) {
    return false;
  }
}

/// Flutter の論理座標の矩形を、 その View の devicePixelRatio で物理座標に
/// 直してキャプチャするヘルパー。 [origin] はウィンドウ内の論理座標、
/// [windowOriginPhysical] は画面上のウィンドウ左上 (物理座標)。
Uint8List? captureLogicalRectPng({
  required ui.Rect logicalRect,
  required double devicePixelRatio,
  required ui.Offset windowOriginPhysical,
}) {
  final x = (windowOriginPhysical.dx + logicalRect.left * devicePixelRatio)
      .round();
  final y =
      (windowOriginPhysical.dy + logicalRect.top * devicePixelRatio).round();
  final w = (logicalRect.width * devicePixelRatio).round();
  final h = (logicalRect.height * devicePixelRatio).round();
  return captureScreenRectPng(x, y, w, h);
}
