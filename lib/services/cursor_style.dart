// マウスカーソルの大きさ / 色を変える (Windows 専用)。
//
// ★ = ユーザー要望「マウスカーソルの大きさを調節したり、 色を付けられる
//   機能をディスプレイ設定に追加して欲しい」。
//
// **レジストリには書かない**。 これが以前 (b271〜b287) の作りとの決定的な
// 違い。 当時は HKCU の CursorSize / CursorBaseSize を書いて
// SystemParametersInfo(SPI_SETCURSORS) を呼んでいたが、 Windows 11 は
// サインインし直すまで読み直さないので**見た目が全く変わらず**、
// 「変えられないなら項目ごと消して」 と言われて削除した経緯がある。
//
// ここでは `SetSystemCursor` で**今動いているカーソルそのものを差し替える**。
// 実測 (tool/cursor_probe.dart) で 48/64/96/128px いずれも即座に反映され、
// `SystemParametersInfo(SPI_SETCURSORS, 0, null, 0)` で元へ戻ることを確認済み。
//
// 副作用: 差し替えはサインインしている間ずっと・**全アプリに効く**。
// アプリを閉じる時と、 設定を切った時に必ず戻すこと。
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart' as w32;

/// 差し替えるカーソルの種類 (OCR_*) と、 その絵を持つレジストリの名前。
/// 名前が空 (= Windows 内蔵) の物は触らない。
const Map<int, String> _kCursorSlots = {
  32512: 'Arrow', // OCR_NORMAL
  32513: 'IBeam', // OCR_IBEAM
  32514: 'Wait', // OCR_WAIT
  32515: 'Crosshair', // OCR_CROSS
  32516: 'UpArrow', // OCR_UP
  32631: 'NWPen', // OCR_NWPEN
  32642: 'SizeNWSE',
  32643: 'SizeNESW',
  32644: 'SizeWE',
  32645: 'SizeNS',
  32646: 'SizeAll',
  32648: 'No',
  32649: 'Hand',
  32650: 'AppStarting',
  32651: 'Help',
};

const int _imageCursor = 2;
const int _lrLoadFromFile = 0x00000010;
const int _spiSetCursors = 0x0057;
const int _biRgb = 0;
const int _dibRgbColors = 0;

class CursorStyleControl {
  CursorStyleControl._();

  static bool get isSupported => !kIsWeb && Platform.isWindows;

  /// 今このアプリがカーソルを差し替えているか。
  static bool _applied = false;
  static bool get isApplied => _applied;

  /// 大きさの選べる幅 (px)。 32 = Windows の既定。
  static const List<int> sizeChoices = [32, 40, 48, 64, 80, 96, 128];

  /// 今の「通常の矢印」 の実寸 (px)。 測れなければ null。
  static int? currentArrowPixels() {
    if (!isSupported) return null;
    final hcur = w32.LoadCursor(0, w32.IDC_ARROW);
    if (hcur == 0) return null;
    final info = calloc<w32.ICONINFO>();
    try {
      if (w32.GetIconInfo(hcur, info) == 0) return null;
      final bmp = calloc<w32.BITMAP>();
      try {
        final mono = info.ref.hbmColor == 0;
        final hbm = mono ? info.ref.hbmMask : info.ref.hbmColor;
        if (w32.GetObject(hbm, sizeOf<w32.BITMAP>(), bmp) == 0) return null;
        return bmp.ref.bmWidth;
      } finally {
        calloc.free(bmp);
        if (info.ref.hbmColor != 0) w32.DeleteObject(info.ref.hbmColor);
        if (info.ref.hbmMask != 0) w32.DeleteObject(info.ref.hbmMask);
      }
    } finally {
      calloc.free(info);
    }
  }

  /// HKCU\Control Panel\Cursors から絵のファイルの場所を読む (読み取りのみ)。
  static String _readCursorPath(String name) {
    final sub = 'Control Panel\\Cursors'.toNativeUtf16();
    final val = name.toNativeUtf16();
    final buf = calloc<Uint16>(520);
    final len = calloc<Uint32>()..value = 520 * 2;
    try {
      // RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ (= 0x2 | 0x4) + 展開する。
      final r = w32.RegGetValue(w32.HKEY_CURRENT_USER, sub, val, 0x00000002,
          nullptr, buf.cast(), len);
      if (r != w32.ERROR_SUCCESS) return '';
      final s = buf.cast<Utf16>().toDartString();
      if (s.isEmpty) return '';
      // %SystemRoot% 等を展開する。
      return s.replaceAll(RegExp('%SystemRoot%', caseSensitive: false),
          Platform.environment['SystemRoot'] ?? r'C:\Windows');
    } catch (_) {
      return '';
    } finally {
      calloc.free(sub);
      calloc.free(val);
      calloc.free(buf);
      calloc.free(len);
    }
  }

  /// [path] のカーソルを [size] px で読み込む。 [argb] があれば
  /// 「明るい所ほどその色」 に塗り替える (黒い縁取りは残る)。
  /// 作れなければ 0。
  static int _buildCursor(String path, int size, int? argb) {
    final p = path.toNativeUtf16();
    int src;
    try {
      src = w32.LoadImage(0, p, _imageCursor, size, size, _lrLoadFromFile);
    } finally {
      calloc.free(p);
    }
    if (src == 0) return 0;
    if (argb == null) return src; // 大きさだけ変える
    final info = calloc<w32.ICONINFO>();
    if (w32.GetIconInfo(src, info) == 0) {
      calloc.free(info);
      return src;
    }
    final hbmColor = info.ref.hbmColor;
    final hbmMask = info.ref.hbmMask;
    // 色のビットマップが無い物 (白黒 / アニメーション) は塗れないのでそのまま。
    if (hbmColor == 0) {
      if (hbmMask != 0) w32.DeleteObject(hbmMask);
      calloc.free(info);
      return src;
    }
    final bmp = calloc<w32.BITMAP>();
    w32.GetObject(hbmColor, sizeOf<w32.BITMAP>(), bmp);
    final w = bmp.ref.bmWidth, h = bmp.ref.bmHeight;
    calloc.free(bmp);
    if (w <= 0 || h <= 0) {
      w32.DeleteObject(hbmColor);
      if (hbmMask != 0) w32.DeleteObject(hbmMask);
      calloc.free(info);
      return src;
    }

    final hdc = w32.GetDC(0);
    final bi = calloc<w32.BITMAPINFO>();
    bi.ref.bmiHeader.biSize = sizeOf<w32.BITMAPINFOHEADER>();
    bi.ref.bmiHeader.biWidth = w;
    bi.ref.bmiHeader.biHeight = -h; // 上から下へ並べる
    bi.ref.bmiHeader.biPlanes = 1;
    bi.ref.bmiHeader.biBitCount = 32;
    bi.ref.bmiHeader.biCompression = _biRgb;
    final bytes = w * h * 4;
    final buf = calloc<Uint8>(bytes);
    var out = src;
    try {
      if (w32.GetDIBits(hdc, hbmColor, 0, h, buf.cast(), bi, _dibRgbColors) !=
          0) {
        final tr = (argb >> 16) & 0xFF,
            tg = (argb >> 8) & 0xFF,
            tb = argb & 0xFF;
        for (var i = 0; i < bytes; i += 4) {
          if (buf[i + 3] == 0) continue; // 透けている所は触らない
          final b = buf[i], g = buf[i + 1], r = buf[i + 2];
          // 明るさ (0..255) を保ったまま色を乗せる。 白 → 指定色、
          // 黒 (縁取り) → 黒のまま。
          final lum = (r * 30 + g * 59 + b * 11) ~/ 100;
          buf[i] = (tb * lum) ~/ 255;
          buf[i + 1] = (tg * lum) ~/ 255;
          buf[i + 2] = (tr * lum) ~/ 255;
        }
        final ppv = calloc<Pointer<Void>>();
        final newBmp = w32.CreateDIBSection(hdc, bi, _dibRgbColors, ppv, 0, 0);
        if (newBmp != 0 && ppv.value != nullptr) {
          final dst = ppv.value.cast<Uint8>();
          for (var i = 0; i < bytes; i++) {
            dst[i] = buf[i];
          }
          final ni = calloc<w32.ICONINFO>();
          ni.ref.fIcon = 0; // アイコンではなくカーソル
          ni.ref.xHotspot = info.ref.xHotspot;
          ni.ref.yHotspot = info.ref.yHotspot;
          ni.ref.hbmMask = hbmMask;
          ni.ref.hbmColor = newBmp;
          final tinted = w32.CreateIconIndirect(ni);
          calloc.free(ni);
          w32.DeleteObject(newBmp);
          if (tinted != 0) {
            w32.DestroyCursor(src); // 元は捨てて塗った方を使う
            out = tinted;
          }
        }
        calloc.free(ppv);
      }
    } catch (e) {
      debugPrint('カーソルの塗り替えに失敗: $e');
    } finally {
      calloc.free(buf);
      calloc.free(bi);
      w32.ReleaseDC(0, hdc);
      w32.DeleteObject(hbmColor);
      if (hbmMask != 0) w32.DeleteObject(hbmMask);
      calloc.free(info);
    }
    return out;
  }

  /// 大きさ [sizePx] (32 = 既定) と色 [argb] (null = 元の色) を当てる。
  /// 戻り値は実際に差し替えられた本数。
  static int apply({required int sizePx, int? argb}) {
    if (!isSupported) return 0;
    // 既定の大きさで色も指定が無ければ、 元へ戻すだけ。
    if (sizePx <= 32 && argb == null) {
      restore();
      return 0;
    }
    var done = 0;
    _kCursorSlots.forEach((ocr, regName) {
      final path = _readCursorPath(regName);
      if (path.isEmpty || !File(path).existsSync()) return;
      final h = _buildCursor(path, sizePx, argb);
      if (h == 0) return;
      // SetSystemCursor は渡した物を持って行くので、 こちらでは壊さない。
      if (w32.SetSystemCursor(h, ocr) != 0) done++;
    });
    if (done > 0) _applied = true;
    return done;
  }

  /// Windows の元のカーソルへ戻す。
  static void restore() {
    if (!isSupported) return;
    try {
      w32.SystemParametersInfo(_spiSetCursors, 0, nullptr, 0);
    } catch (_) {}
    _applied = false;
  }

  /// アプリを閉じる時に必ず呼ぶ (差し替えはサインイン中ずっと残るため)。
  static void restoreIfApplied() {
    if (_applied) restore();
  }
}
