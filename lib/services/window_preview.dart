// Windows の窓の「中身の小さな絵」 と「アプリのアイコン」 を作る。
//
// ★ = ユーザー要望「他のアプリ窓の項目アイコンがチェックボックスと
//   勘違いしてしまうから別のにして欲しいのと、 何の画面か分かりにくいから
//   窓のプレビュー画面を表示して欲しい」。
//
// ── なぜ DWM のサムネイルを使わないか ──────────────────────────
//   `DwmRegisterThumbnail` / `DwmUpdateThumbnailProperties` は「行き先の窓
//   (HWND) のこの矩形に、 元の窓の生映像を出す」 という頼み方で、 実際に
//   描くのは DWM (Flutter ではない)。 Flutter が描いた絵の**上に必ず重なる**
//   ので、 巻物に入れても一緒に動かず、 ダイアログや献立で隠す事もできず、
//   角を丸める事もできない。 一覧の中に埋める用途では使えない。
//
// ── 代わりに使う物 ──────────────────────────────────────────
//   `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)`。 画面に映っている物を
//   写すのではなく**その窓自身に描き直させる**ので、 手前に他の窓が
//   重なっていても、 こちらのダイアログが乗っていても中身が撮れる
//   (`screen_capture.dart` の BitBlt との違い。 あちらを使うと、 どの行の
//   絵にもこちらの設定画面が写り込む)。
//   PW_RENDERFULLCONTENT (Windows 8.1〜) が無いと Chrome / Electron /
//   WebView2 のように GPU で描く窓が真っ白になる。
//
// ── 撮れない事がある ────────────────────────────────────────
//   ・最小化中 (`IsIconic`) は DWM が絵を捨てているので真っ白。
//   ・管理者権限で動いている窓は Windows が断る (UIPI)。
//   ・他のデスクトップに居る窓は絵が残っていれば撮れるが、 残っていない
//     事もある (本家のタスクビューと同じ仕組みに乗っている)。
//   撮れなかった時は thumbPng を null で返し、 画面側はアイコンに
//   切り替える。 「真っ白」 は成功と見分けが付かないので、 全部同じ色なら
//   撮れていないと見なす (_looksBlank)。
//
// ★ 重さ: PrintWindow は相手のアプリを巻き込む呼び出しで、 4K の窓なら
//   33MB のビットマップになる。 画面のスレッドでは回さず (Isolate.run +
//   時間切れ = このリポジトリの他の Win32 と同じ作法)、 縮めるのは GDI の
//   StretchBlt でやって、 Dart へ読むのは縮めた後だけにする。 一覧を
//   開いた時と「更新」 の時だけ撮り、 組み立てのたびには撮らない。
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:win32/win32.dart' as w32;

/// 窓 1 つぶんの見た目。
class WindowShot {
  /// 窓の中身を縮めた絵 (PNG)。 撮れなければ null。
  final Uint8List? thumbPng;

  /// アプリのアイコン (PNG)。 取れなければ null。
  final Uint8List? iconPng;

  /// 最小化中か (= 中身は撮れない)。
  final bool minimized;

  const WindowShot({this.thumbPng, this.iconPng, this.minimized = false});
}

// ── Win32 の数 ──────────────────────────────────────────────
// ★ win32 パッケージの版で名前が変わっても困らないよう、 このファイルの
//   中で持つ (os_quick_toggles.dart と同じ作法)。
const int _kPwRenderFullContent = 0x00000002;
const int _kDwmwaExtendedFrameBounds = 9;
const int _kSrcCopy = 0x00CC0020;
const int _kBiRgb = 0;
const int _kDibRgbColors = 0;
const int _kHalftone = 4;
const int _kWmGetIcon = 0x007F;
const int _kIconBig = 1;
const int _kIconSmall2 = 2;
const int _kGclpHicon = -14;
const int _kGclpHiconSm = -34;
const int _kSmtoAbortIfHung = 0x0002;
const int _kShgfiIcon = 0x00000100;
const int _kShgfiLargeIcon = 0x00000000;
const int _kCoinitApartmentThreaded = 0x2;
const int _kSOk = 0;
const int _kSFalse = 1;

/// Windows でだけ働く。
bool get isWindowPreviewSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// [targets] の窓をまとめて 1 往復で撮る (hwnd → 見た目)。
///
/// 絵は [maxThumbs] 枚まで。 それを超えた窓はアイコンだけ返す
/// (アイコンは安いので全部に付ける)。
Future<Map<int, WindowShot>> captureWindowPreviews(
  List<({int hwnd, String exePath})> targets, {
  int thumbWidth = 192,
  int thumbHeight = 108,
  int maxThumbs = 48,
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (!isWindowPreviewSupported || targets.isEmpty) return const {};
  // ★ Isolate へ渡すのは送れる型だけにする (os_quick_toggles.dart と同じ)。
  final jobs = <List<Object>>[
    for (final t in targets) <Object>[t.hwnd, t.exePath],
  ];
  try {
    final rows =
        await Isolate.run(() => _shootAll(jobs, thumbWidth, thumbHeight, maxThumbs))
            .timeout(timeout);
    return <int, WindowShot>{
      for (final r in rows)
        (r['hwnd'] as int? ?? 0): WindowShot(
          thumbPng: r['thumb'] as Uint8List?,
          iconPng: r['icon'] as Uint8List?,
          minimized: r['min'] == true,
        ),
    };
  } catch (_) {
    // 撮れなくても一覧そのものは出す。
    return const {};
  }
}

/// 別の isolate で回る本体。 戻りは送れる型だけにする。
List<Map<String, Object?>> _shootAll(
    List<List<Object>> jobs, int tw, int th, int maxThumbs) {
  final out = <Map<String, Object?>>[];
  // SHGetFileInfo はシェルの COM を使う。
  final init = w32.CoInitializeEx(ffi.nullptr, _kCoinitApartmentThreaded);
  final needUninit = init == _kSOk || init == _kSFalse;
  final screenDc = w32.GetDC(0);
  try {
    var shot = 0;
    for (final j in jobs) {
      final hwnd = j[0] as int;
      final exe = j.length > 1 ? j[1] as String : '';
      Uint8List? thumb;
      var minimized = false;
      try {
        minimized = w32.IsIconic(hwnd) != 0;
        if (!minimized && shot < maxThumbs) {
          thumb = _shootWindow(screenDc, hwnd, tw, th);
          shot++;
        }
      } catch (_) {}
      Uint8List? icon;
      try {
        icon = _appIconPng(screenDc, hwnd, exe);
      } catch (_) {}
      out.add(<String, Object?>{
        'hwnd': hwnd,
        'thumb': thumb,
        'icon': icon,
        'min': minimized,
      });
    }
  } catch (_) {
    // 途中まで撮れた分だけ返す。
  } finally {
    if (screenDc != 0) w32.ReleaseDC(0, screenDc);
    if (needUninit) w32.CoUninitialize();
  }
  return out;
}

/// 窓 [hwnd] の中身を [tw]x[th] に収まる大きさで撮って PNG で返す。
Uint8List? _shootWindow(int screenDc, int hwnd, int tw, int th) {
  if (screenDc == 0) return null;
  final rc = pkgffi.calloc<w32.RECT>();
  final fb = pkgffi.calloc<w32.RECT>();
  var bigDc = 0, bigBmp = 0, oldBig = 0;
  var smallDc = 0, smallBmp = 0, oldSmall = 0;
  ffi.Pointer<w32.BITMAPINFO>? bi;
  ffi.Pointer<ffi.Uint8>? bits;
  try {
    if (w32.GetWindowRect(hwnd, rc) == 0) return null;
    final ww = rc.ref.right - rc.ref.left;
    final wh = rc.ref.bottom - rc.ref.top;
    if (ww <= 16 || wh <= 16 || ww > 16384 || wh > 16384) return null;
    // ★ GetWindowRect は影のぶん外へ広い。 見えている枠 (DWM) で切り抜く。
    //   PrintWindow が描くのは GetWindowRect の原点からなので、 差を
    //   そのまま切り抜きの位置に使える。
    var cx = 0, cy = 0, cw = ww, ch = wh;
    if (w32.DwmGetWindowAttribute(hwnd, _kDwmwaExtendedFrameBounds,
            fb.cast<ffi.Void>(), ffi.sizeOf<w32.RECT>()) ==
        _kSOk) {
      final l = fb.ref.left - rc.ref.left;
      final t = fb.ref.top - rc.ref.top;
      final r = fb.ref.right - rc.ref.left;
      final b = fb.ref.bottom - rc.ref.top;
      if (l >= 0 && t >= 0 && r <= ww && b <= wh && r - l > 16 && b - t > 16) {
        cx = l;
        cy = t;
        cw = r - l;
        ch = b - t;
      }
    }
    bigDc = w32.CreateCompatibleDC(screenDc);
    bigBmp = w32.CreateCompatibleBitmap(screenDc, ww, wh);
    if (bigDc == 0 || bigBmp == 0) return null;
    oldBig = w32.SelectObject(bigDc, bigBmp);
    // ★ PW_RENDERFULLCONTENT が無いと GPU で描く窓 (Chrome / Electron /
    //   WebView2) が真っ白になる。 断られた時だけ古い呼び方も試す。
    var ok = w32.PrintWindow(hwnd, bigDc, _kPwRenderFullContent) != 0;
    if (!ok) ok = w32.PrintWindow(hwnd, bigDc, 0) != 0;
    if (!ok) return null;

    // ★ 縮めるのは GDI でやる。 4K の窓をそのまま Dart へ読むと 33MB。
    final box = _fitBox(cw, ch, tw, th);
    smallDc = w32.CreateCompatibleDC(screenDc);
    smallBmp = w32.CreateCompatibleBitmap(screenDc, box.w, box.h);
    if (smallDc == 0 || smallBmp == 0) return null;
    oldSmall = w32.SelectObject(smallDc, smallBmp);
    // HALFTONE = きれいに縮む。 この DC では後で筆を使わないので
    // SetBrushOrgEx は要らない。
    w32.SetStretchBltMode(smallDc, _kHalftone);
    if (w32.StretchBlt(smallDc, 0, 0, box.w, box.h, bigDc, cx, cy, cw, ch,
            _kSrcCopy) ==
        0) {
      return null;
    }

    bi = pkgffi.calloc<w32.BITMAPINFO>();
    bi.ref.bmiHeader.biSize = ffi.sizeOf<w32.BITMAPINFOHEADER>();
    bi.ref.bmiHeader.biWidth = box.w;
    bi.ref.bmiHeader.biHeight = -box.h; // 負 = 上から下へ並べる
    bi.ref.bmiHeader.biPlanes = 1;
    bi.ref.bmiHeader.biBitCount = 32;
    bi.ref.bmiHeader.biCompression = _kBiRgb;
    final n = box.w * box.h * 4;
    bits = pkgffi.calloc<ffi.Uint8>(n);
    if (w32.GetDIBits(
            smallDc, smallBmp, 0, box.h, bits.cast(), bi, _kDibRgbColors) ==
        0) {
      return null;
    }
    final src = bits.asTypedList(n);
    // ★ 撮れていない窓は真っ白 / 真っ黒で返る。 成功と見分けが付かないので
    //   「全部同じ色」 は失敗と見なして、 画面側でアイコンに切り替えさせる。
    if (_looksBlank(src)) return null;
    return _pngFromBgra(src, box.w, box.h, opaque: true);
  } catch (_) {
    return null;
  } finally {
    if (bits != null) pkgffi.calloc.free(bits);
    if (bi != null) pkgffi.calloc.free(bi);
    if (smallDc != 0 && oldSmall != 0) w32.SelectObject(smallDc, oldSmall);
    if (smallBmp != 0) w32.DeleteObject(smallBmp);
    if (smallDc != 0) w32.DeleteDC(smallDc);
    if (bigDc != 0 && oldBig != 0) w32.SelectObject(bigDc, oldBig);
    if (bigBmp != 0) w32.DeleteObject(bigBmp);
    if (bigDc != 0) w32.DeleteDC(bigDc);
    pkgffi.calloc.free(rc);
    pkgffi.calloc.free(fb);
  }
}

/// 窓 [hwnd] のアプリのアイコンを PNG で返す。
Uint8List? _appIconPng(int screenDc, int hwnd, String exePath) {
  var hIcon = 0;
  // ★ 自分で作らせた物だけ捨てる。 窓 / クラスのアイコンは持ち主の物で、
  //   こちらが DestroyIcon すると相手のアプリの絵が消える。
  var owned = false;
  // ★ まずクラスのアイコン。 他のアプリへ聞きに行かないので固まらない。
  try {
    hIcon = w32.GetClassLongPtr(hwnd, _kGclpHiconSm);
    if (hIcon == 0) hIcon = w32.GetClassLongPtr(hwnd, _kGclpHicon);
  } catch (_) {}
  if (hIcon == 0) {
    // ★ WM_GETICON は相手が返事をするまで待つ。 固まっている窓で止まらない
    //   よう、 必ず時間切れ付き (SMTO_ABORTIFHUNG) で聞く。
    final res = pkgffi.calloc<ffi.IntPtr>();
    try {
      for (final kind in const <int>[_kIconSmall2, _kIconBig]) {
        res.value = 0;
        final r = w32.SendMessageTimeout(
            hwnd, _kWmGetIcon, kind, 0, _kSmtoAbortIfHung, 80, res);
        if (r != 0 && res.value != 0) {
          hIcon = res.value;
          break;
        }
      }
    } catch (_) {
    } finally {
      pkgffi.calloc.free(res);
    }
  }
  if (hIcon == 0 && exePath.isNotEmpty) {
    // ★ 窓がアイコンを持っていない時は実行ファイルから取る。
    //   SHGFI_USEFILEATTRIBUTES は付けない (付けると exe に埋まっている
    //   本物ではなく、 種類ごとの当たり障りのない絵が返る)。
    final p = exePath.toNativeUtf16(allocator: pkgffi.calloc);
    final sfi = pkgffi.calloc<w32.SHFILEINFO>();
    try {
      if (w32.SHGetFileInfo(p, 0, sfi, ffi.sizeOf<w32.SHFILEINFO>(),
              _kShgfiIcon | _kShgfiLargeIcon) !=
          0) {
        hIcon = sfi.ref.hIcon;
        owned = hIcon != 0;
      }
    } catch (_) {
    } finally {
      pkgffi.calloc.free(sfi);
      pkgffi.calloc.free(p);
    }
  }
  if (hIcon == 0) return null;
  try {
    return _iconToPng(screenDc, hIcon);
  } finally {
    if (owned) {
      try {
        w32.DestroyIcon(hIcon);
      } catch (_) {}
    }
  }
}

/// HICON → PNG。 cursor_style.dart と同じ道筋 (GetIconInfo → GetDIBits)。
Uint8List? _iconToPng(int screenDc, int hIcon) {
  if (screenDc == 0) return null;
  final info = pkgffi.calloc<w32.ICONINFO>();
  if (w32.GetIconInfo(hIcon, info) == 0) {
    pkgffi.calloc.free(info);
    return null;
  }
  // ★ GetIconInfo はビットマップを**作って**返す。 必ずこちらで捨てる。
  final hbmColor = info.ref.hbmColor;
  final hbmMask = info.ref.hbmMask;
  ffi.Pointer<w32.BITMAP>? bm;
  ffi.Pointer<w32.BITMAPINFO>? bi;
  ffi.Pointer<ffi.Uint8>? buf;
  ffi.Pointer<ffi.Uint8>? mbuf;
  try {
    // 色の板が無い物 (白黒アイコン) は諦める。
    if (hbmColor == 0) return null;
    bm = pkgffi.calloc<w32.BITMAP>();
    w32.GetObject(hbmColor, ffi.sizeOf<w32.BITMAP>(), bm);
    final w = bm.ref.bmWidth;
    final h = bm.ref.bmHeight;
    if (w <= 0 || h <= 0 || w > 512 || h > 512) return null;
    bi = pkgffi.calloc<w32.BITMAPINFO>();
    bi.ref.bmiHeader.biSize = ffi.sizeOf<w32.BITMAPINFOHEADER>();
    bi.ref.bmiHeader.biWidth = w;
    bi.ref.bmiHeader.biHeight = -h;
    bi.ref.bmiHeader.biPlanes = 1;
    bi.ref.bmiHeader.biBitCount = 32;
    bi.ref.bmiHeader.biCompression = _kBiRgb;
    final n = w * h * 4;
    buf = pkgffi.calloc<ffi.Uint8>(n);
    if (w32.GetDIBits(screenDc, hbmColor, 0, h, buf.cast(), bi,
            _kDibRgbColors) ==
        0) {
      return null;
    }
    final src = buf.asTypedList(n);
    // ★ 古い (32bit でない) アイコンは α が全部 0。 その時はマスク
    //   (白 = 透ける) から α を作らないと、 全部透明になって消える。
    var anyAlpha = false;
    for (var i = 3; i < n; i += 4) {
      if (src[i] != 0) {
        anyAlpha = true;
        break;
      }
    }
    final rgba = Uint8List(n);
    if (!anyAlpha && hbmMask != 0) {
      mbuf = pkgffi.calloc<ffi.Uint8>(n);
      final okMask = w32.GetDIBits(screenDc, hbmMask, 0, h, mbuf.cast(), bi,
              _kDibRgbColors) !=
          0;
      final m = mbuf.asTypedList(n);
      for (var i = 0; i + 3 < n; i += 4) {
        rgba[i] = src[i + 2];
        rgba[i + 1] = src[i + 1];
        rgba[i + 2] = src[i];
        rgba[i + 3] = okMask ? (m[i] != 0 ? 0 : 255) : 255;
      }
    } else {
      for (var i = 0; i + 3 < n; i += 4) {
        rgba[i] = src[i + 2];
        rgba[i + 1] = src[i + 1];
        rgba[i + 2] = src[i];
        rgba[i + 3] = anyAlpha ? src[i + 3] : 255;
      }
    }
    final im = img.Image.fromBytes(
        width: w, height: h, bytes: rgba.buffer, numChannels: 4);
    return Uint8List.fromList(img.encodePng(im));
  } catch (_) {
    return null;
  } finally {
    if (mbuf != null) pkgffi.calloc.free(mbuf);
    if (buf != null) pkgffi.calloc.free(buf);
    if (bi != null) pkgffi.calloc.free(bi);
    if (bm != null) pkgffi.calloc.free(bm);
    if (hbmColor != 0) w32.DeleteObject(hbmColor);
    if (hbmMask != 0) w32.DeleteObject(hbmMask);
    pkgffi.calloc.free(info);
  }
}

/// [sw]x[sh] を [tw]x[th] に収まる大きさへ (元より大きくはしない)。
({int w, int h}) _fitBox(int sw, int sh, int tw, int th) {
  final kx = tw / sw;
  final ky = th / sh;
  var k = kx < ky ? kx : ky;
  if (k > 1) k = 1;
  var w = (sw * k).round();
  var h = (sh * k).round();
  if (w < 2) w = 2;
  if (h < 2) h = 2;
  return (w: w, h: h);
}

/// 全部同じ色か (= 撮れていない)。 間引いて見るので安い。
bool _looksBlank(Uint8List bgra) {
  if (bgra.length < 64) return true;
  final b0 = bgra[0], g0 = bgra[1], r0 = bgra[2];
  var step = (bgra.length ~/ 4 ~/ 96) * 4;
  if (step < 4) step = 4;
  for (var i = 0; i + 3 < bgra.length; i += step) {
    if ((bgra[i] - b0).abs() > 3 ||
        (bgra[i + 1] - g0).abs() > 3 ||
        (bgra[i + 2] - r0).abs() > 3) {
      return false;
    }
  }
  return true;
}

/// BGRA (上から下) → PNG。
Uint8List _pngFromBgra(Uint8List bgra, int w, int h, {required bool opaque}) {
  final n = bgra.length;
  final rgba = Uint8List(n);
  for (var i = 0; i + 3 < n; i += 4) {
    rgba[i] = bgra[i + 2];
    rgba[i + 1] = bgra[i + 1];
    rgba[i + 2] = bgra[i];
    // ★ PrintWindow は α を埋めない事がある (全部 0 = 何も見えない)。
    //   窓の絵は必ず不透明にする。
    rgba[i + 3] = opaque ? 255 : bgra[i + 3];
  }
  final im = img.Image.fromBytes(
      width: w, height: h, bytes: rgba.buffer, numChannels: 4);
  return Uint8List.fromList(img.encodePng(im));
}
