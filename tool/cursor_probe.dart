// マウスカーソルの大きさ / 色を「今すぐ」 変えられるかを確かめる道具。
//
//   dart run tool/cursor_probe.dart
//
// ★ レジストリには一切書かない。 SetSystemCursor だけを使う (= その場限り。
//   サインインし直さなくても効く代わりに、 再起動で元へ戻る)。 最後に
//   SystemParametersInfo(SPI_SETCURSORS) で必ず戻す。
//
// b287 で「レジストリは書けても 32px のままだった」 と判断して機能ごと
// 消した経緯があるが、 その時は SetSystemCursor を試していない。 ここで
// 実測してから作り直す。
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as w32;

const int ocrNormal = 32512; // OCR_NORMAL (通常の矢印)
const int imageCursor = 2; // IMAGE_CURSOR
const int lrLoadFromFile = 0x00000010;
const int lrDefaultSize = 0x00000040;
const int spiSetCursors = 0x0057;

/// 今の「通常の矢印」 の実寸 (幅 x 高さ) を測る。
/// 取れなければ null。
({int w, int h})? measureArrow() {
  final hcur = w32.LoadCursor(0, w32.IDC_ARROW);
  if (hcur == 0) return null;
  final info = calloc<w32.ICONINFO>();
  try {
    if (w32.GetIconInfo(hcur, info) == 0) return null;
    final bmp = calloc<w32.BITMAP>();
    try {
      // 色ビットマップが無い (白黒カーソル) 時はマスクを見る。
      // マスクは高さが 2 倍になるので半分にする。
      final hbm = info.ref.hbmColor != 0 ? info.ref.hbmColor : info.ref.hbmMask;
      final mono = info.ref.hbmColor == 0;
      if (w32.GetObject(hbm, sizeOf<w32.BITMAP>(), bmp) == 0) return null;
      final h = mono ? bmp.ref.bmHeight ~/ 2 : bmp.ref.bmHeight;
      return (w: bmp.ref.bmWidth, h: h);
    } finally {
      calloc.free(bmp);
      if (info.ref.hbmColor != 0) w32.DeleteObject(info.ref.hbmColor);
      if (info.ref.hbmMask != 0) w32.DeleteObject(info.ref.hbmMask);
    }
  } finally {
    calloc.free(info);
  }
}

void restore() {
  w32.SystemParametersInfo(spiSetCursors, 0, nullptr, 0);
}

void main() {
  if (!Platform.isWindows) {
    print('Windows 専用');
    return;
  }
  final cx = w32.GetSystemMetrics(w32.SM_CXCURSOR);
  final cy = w32.GetSystemMetrics(w32.SM_CYCURSOR);
  print('SM_CXCURSOR/SM_CYCURSOR = $cx x $cy');
  print('今の矢印の実寸        = ${measureArrow()}');

  // ── 試験 B: ファイルから大きさ指定で読み込んで差し替える ──
  const src = r'C:\Windows\Cursors\aero_arrow.cur';
  if (!File(src).existsSync()) {
    print('見本のカーソルが無い: $src');
    return;
  }
  for (final size in [48, 64, 96, 128]) {
    final p = src.toNativeUtf16();
    try {
      final h = w32.LoadImage(0, p, imageCursor, size, size, lrLoadFromFile);
      if (h == 0) {
        print('[$size] LoadImage 失敗 err=${w32.GetLastError()}');
        continue;
      }
      // SetSystemCursor は渡した物を持って行く (= あとで壊さない)。
      final ok = w32.SetSystemCursor(h, ocrNormal);
      final got = measureArrow();
      print('[$size] LoadImage ok / SetSystemCursor=$ok -> 実寸 $got');
    } finally {
      calloc.free(p);
    }
  }

  print('\n-- 戻す --');
  restore();
  print('戻したあとの実寸      = ${measureArrow()}');

  // ── 試験 D: 別の絵柄 (黒) に差し替えられるか (色の代わり) ──
  const black = r'C:\Windows\Cursors\arrow_r.cur';
  print('\n黒い矢印のファイルはあるか: ${File(black).existsSync()}');
  if (File(black).existsSync()) {
    final p = black.toNativeUtf16();
    try {
      final h = w32.LoadImage(0, p, imageCursor, 64, 64, lrLoadFromFile);
      if (h != 0) {
        final ok = w32.SetSystemCursor(h, ocrNormal);
        print('黒に差し替え: SetSystemCursor=$ok 実寸 ${measureArrow()}');
      } else {
        print('黒の LoadImage 失敗 err=${w32.GetLastError()}');
      }
    } finally {
      calloc.free(p);
    }
    restore();
    print('戻したあとの実寸      = ${measureArrow()}');
  }

  // ── 試験 B2: 大きさ 0 (= 元の大きさ) で読んだ時 ──
  final p2 = src.toNativeUtf16();
  try {
    final h = w32.LoadImage(0, p2, imageCursor, 0, 0, lrLoadFromFile);
    print('\n大きさ 0 で読んだ時の handle=$h');
    if (h != 0) {
      w32.SetSystemCursor(h, ocrNormal);
      print('その実寸              = ${measureArrow()}');
    }
  } finally {
    calloc.free(p2);
  }
  restore();
  print('最終確認 (戻した)      = ${measureArrow()}');
}
