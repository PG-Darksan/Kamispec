// マウスカーソルの大きさ / 色 / 絵 を変える (Windows 専用)。
//
// ★ = ユーザー要望「マウスカーソルの大きさを調節したり、 色を付けられる
//   機能をディスプレイ設定に追加して欲しい」。
// ★ = ユーザー要望「外枠の色も指定したい」「自分で用意した画像をカーソルに
//   したい」「既定が何 px なのか数値で出して欲しい」「もっと小さい選択肢を」。
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
// 既定ではアプリを閉じる時に必ず戻す。 閉じた後も残すかは設定で選べる
// (= ユーザー要望。 Pro 以上限定)。
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
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

/// 自分で用意した絵を当てるのは「ふつうの矢印」 だけ
/// (= 待ち時間や文字入力のカーソルまで絵にすると、 何をしている所か
///  分からなくなるため)。
const int _kOcrNormal = 32512;

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

  /// アプリを閉じた後も差し替えを残すか (= ユーザー要望。 Pro 以上限定)。
  /// provider が今のプランを見て立てる。
  static bool keepOnExit = false;

  /// 大きさを選べる幅 (px)。 0 は別枠で「Windows の既定」 を指す。
  ///
  /// ★ 札を並べるのをやめてスライドバーにした (= ユーザー要望)。
  ///   下は 12px まで下げられる (= ユーザー要望: 小さい方が欲しい)。
  static const int sizeMin = 12;
  static const int sizeMax = 128;

  /// 差し替える前の「通常の矢印」 の実寸 (px)。 一度測ったら覚えておく
  /// (差し替えた後に測ると、 差し替え後の大きさが返ってしまうため)。
  static int? _baseArrowPixels;

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
        // 幅で測る (白黒のカーソルはマスクが縦に 2 枚ぶん入るため、
        // 高さでは測れない)。
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

  /// Windows の既定の大きさ (px)。 差し替える前に一度だけ測って覚える。
  /// = ユーザー要望「既定が何 px を指すのか分かりにくいので数値で示して」。
  static int? get defaultPixels {
    if (!isSupported) return null;
    if (_applied) return _baseArrowPixels;
    return _baseArrowPixels ??= currentArrowPixels();
  }

  /// 前に測った既定の大きさを教える (= 控えから読み直す時に使う)。
  ///
  /// ★ 「閉じた後もそのまま」 を選んでいると、 次に立ち上げた時にはもう
  ///   差し替わった後なので測り直せない。 前に測った値を渡してもらう。
  static void seedDefaultPixels(int? px) {
    if (px != null && px > 0) _baseArrowPixels = px;
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

  /// [path] のカーソルを [size] px で読み込み、 色を塗り替える。
  ///
  /// [fill] = 明るい所 (カーソルの本体) の色。 null なら元の白のまま。
  /// [outline] = 暗い所 (縁取り) の色。 null なら元の黒のまま。
  /// どちらも null なら大きさだけ変える。 作れなければ 0。
  ///
  /// ★ 明るさ (0〜255) を保ったまま、 暗 → [outline] / 明 → [fill] へ
  ///   混ぜる。 前の作りは縁取りを必ず黒にしていたので、 外枠の色を
  ///   選べなかった (= ユーザー要望)。
  static int _buildCursor(String path, int size, int? fill, int? outline) {
    final p = path.toNativeUtf16();
    int src;
    try {
      src = w32.LoadImage(0, p, _imageCursor, size, size, _lrLoadFromFile);
    } finally {
      calloc.free(p);
    }
    if (src == 0) return 0;
    if (fill == null && outline == null) return src; // 大きさだけ変える
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
        // 指定が無い側は元の色 (白 / 黒) を使う。
        final fr = fill == null ? 255 : (fill >> 16) & 0xFF;
        final fg = fill == null ? 255 : (fill >> 8) & 0xFF;
        final fb = fill == null ? 255 : fill & 0xFF;
        final or_ = outline == null ? 0 : (outline >> 16) & 0xFF;
        final og = outline == null ? 0 : (outline >> 8) & 0xFF;
        final ob = outline == null ? 0 : outline & 0xFF;
        for (var i = 0; i < bytes; i += 4) {
          if (buf[i + 3] == 0) continue; // 透けている所は触らない
          final b = buf[i], g = buf[i + 1], r = buf[i + 2];
          // 明るさ (0..255)。 白 (= 本体) → fill、 黒 (= 縁取り) → outline。
          final lum = (r * 30 + g * 59 + b * 11) ~/ 100;
          final inv = 255 - lum;
          buf[i] = (ob * inv + fb * lum) ~/ 255;
          buf[i + 1] = (og * inv + fg * lum) ~/ 255;
          buf[i + 2] = (or_ * inv + fr * lum) ~/ 255;
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

  /// 自分で用意した絵からカーソルを作る (= ユーザー要望)。
  ///
  /// .cur / .ani はそのまま Windows に読ませる (当たり所も絵に入っている)。
  /// png / jpg / bmp / gif は自前で読み、 [size] px の四角の中へ収める。
  /// 当たり所は左上 (= ふつうの矢印と同じ感覚)。 作れなければ 0。
  static int buildCursorFromImage(String path, int size) {
    if (!isSupported) return 0;
    final lower = path.toLowerCase();
    if (lower.endsWith('.cur') || lower.endsWith('.ani')) {
      final p = path.toNativeUtf16();
      try {
        return w32.LoadImage(0, p, _imageCursor, size, size, _lrLoadFromFile);
      } finally {
        calloc.free(p);
      }
    }
    img.Image? src;
    try {
      final bytes = File(path).readAsBytesSync();
      src = img.decodeImage(bytes);
    } catch (e) {
      debugPrint('カーソルの絵を読めませんでした: $e');
      return 0;
    }
    if (src == null || src.width <= 0 || src.height <= 0) return 0;
    final side = size.clamp(8, 256);
    // 縦横の比を保ったまま、 四角の中へ収める。
    final scale = side / (src.width > src.height ? src.width : src.height);
    final rw = (src.width * scale).round().clamp(1, side);
    final rh = (src.height * scale).round().clamp(1, side);
    final small = img.copyResize(src,
        width: rw, height: rh, interpolation: img.Interpolation.cubic);
    // 左上へ寄せる (当たり所を左上にするため。 中央寄せだと押した所と
    // 絵の先端がずれる)。
    final rgba = Uint8List(side * side * 4); // すべて透明で初期化される
    for (var y = 0; y < rh; y++) {
      for (var x = 0; x < rw; x++) {
        final px = small.getPixel(x, y);
        final o = (y * side + x) * 4;
        rgba[o] = px.b.toInt(); // BGRA で並べる
        rgba[o + 1] = px.g.toInt();
        rgba[o + 2] = px.r.toInt();
        rgba[o + 3] = px.a.toInt();
      }
    }
    return _cursorFromBgra(rgba, side, side);
  }

  /// BGRA の並びからカーソルを 1 本作る。 当たり所は左上。
  static int _cursorFromBgra(Uint8List bgra, int w, int h) {
    final hdc = w32.GetDC(0);
    final bi = calloc<w32.BITMAPINFO>();
    // マスクは 1bpp。 1 行あたり 4 バイト単位に切り上げる。
    final maskStride = ((w + 31) ~/ 32) * 4;
    final maskBuf = calloc<Uint8>(maskStride * h); // 0 = 「色をそのまま出す」
    final ppv = calloc<Pointer<Void>>();
    var hbmColor = 0, hbmMask = 0, cur = 0;
    try {
      bi.ref.bmiHeader.biSize = sizeOf<w32.BITMAPINFOHEADER>();
      bi.ref.bmiHeader.biWidth = w;
      bi.ref.bmiHeader.biHeight = -h; // 上から下へ
      bi.ref.bmiHeader.biPlanes = 1;
      bi.ref.bmiHeader.biBitCount = 32;
      bi.ref.bmiHeader.biCompression = _biRgb;
      hbmColor = w32.CreateDIBSection(hdc, bi, _dibRgbColors, ppv, 0, 0);
      if (hbmColor == 0 || ppv.value == nullptr) return 0;
      final dst = ppv.value.cast<Uint8>();
      for (var i = 0; i < bgra.length; i++) {
        dst[i] = bgra[i];
      }
      hbmMask = w32.CreateBitmap(w, h, 1, 1, maskBuf.cast());
      if (hbmMask == 0) return 0;
      final ni = calloc<w32.ICONINFO>();
      try {
        ni.ref.fIcon = 0; // カーソル
        ni.ref.xHotspot = 0;
        ni.ref.yHotspot = 0;
        ni.ref.hbmMask = hbmMask;
        ni.ref.hbmColor = hbmColor;
        cur = w32.CreateIconIndirect(ni);
      } finally {
        calloc.free(ni);
      }
      return cur;
    } catch (e) {
      debugPrint('絵からカーソルを作れませんでした: $e');
      return 0;
    } finally {
      if (hbmColor != 0) w32.DeleteObject(hbmColor);
      if (hbmMask != 0) w32.DeleteObject(hbmMask);
      calloc.free(ppv);
      calloc.free(maskBuf);
      calloc.free(bi);
      w32.ReleaseDC(0, hdc);
    }
  }

  /// 試しに作っただけのカーソルを捨てる (SetSystemCursor へ渡していない
  /// 物は、 こちらで始末しないと残ってしまう)。
  static void destroyProbeCursor(int handle) {
    if (!isSupported || handle == 0) return;
    try {
      w32.DestroyCursor(handle);
    } catch (_) {}
  }

  /// 今の見た目が「何も変えていない」 状態かどうか。
  static bool isDefaultLook({
    required int sizePx,
    int? fillArgb,
    int? outlineArgb,
    String? imagePath,
  }) =>
      sizePx <= 0 &&
      fillArgb == null &&
      outlineArgb == null &&
      (imagePath == null || imagePath.isEmpty);

  /// 大きさ [sizePx] (0 = Windows の既定)、 本体の色 [fillArgb]、
  /// 外枠の色 [outlineArgb]、 自前の絵 [imagePath] を当てる。
  /// 戻り値は実際に差し替えられた本数。
  static int apply({
    required int sizePx,
    int? fillArgb,
    int? outlineArgb,
    String? imagePath,
  }) {
    if (!isSupported) return 0;
    if (isDefaultLook(
        sizePx: sizePx,
        fillArgb: fillArgb,
        outlineArgb: outlineArgb,
        imagePath: imagePath)) {
      restore();
      return 0;
    }
    // 差し替える前に既定の大きさを測っておく (画面に出すため)。
    _baseArrowPixels ??= currentArrowPixels();
    // 0 (= 既定) のまま色だけ変える時は、 実測した既定の大きさで作る。
    final px = sizePx > 0 ? sizePx : (_baseArrowPixels ?? 32);
    final useImage = imagePath != null &&
        imagePath.isNotEmpty &&
        File(imagePath).existsSync();
    var done = 0;
    _kCursorSlots.forEach((ocr, regName) {
      int h = 0;
      if (useImage && ocr == _kOcrNormal) {
        h = buildCursorFromImage(imagePath, px);
      }
      if (h == 0) {
        // 絵を当てない所 (と、 絵を作れなかった時) は今までどおり
        // 大きさと色だけ変える。
        final path = _readCursorPath(regName);
        if (path.isEmpty || !File(path).existsSync()) return;
        h = _buildCursor(path, px, fillArgb, outlineArgb);
      }
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

  /// 差し替えていれば戻す (設定を切った時など、 必ず戻す場面で使う)。
  static void restoreIfApplied() {
    if (_applied) restore();
  }

  /// アプリを閉じる時に呼ぶ。
  ///
  /// ★ 既定では戻す (差し替えはサインイン中ずっと・全アプリに効くため)。
  ///   [keepOnExit] が立っている時だけ、 そのまま残す
  ///   (= ユーザー要望「アプリが閉じた後もカーソル設定そのままになる設定」。
  ///    Pro 以上限定なので、 印を立てるのは provider 側の役目)。
  static void restoreOnExit() {
    if (keepOnExit) return;
    restoreIfApplied();
  }
}
