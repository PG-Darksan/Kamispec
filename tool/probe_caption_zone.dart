// 窓の右上ボタンの判定を実機で確かめる使い捨ての道具。
// 使い方: dart run tool/probe_caption_zone.dart
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as w32;

(int, int, int, int)? windowRect(int hwnd) {
  final r = calloc<w32.RECT>();
  try {
    if (w32.GetWindowRect(hwnd, r) == 0) return null;
    return (r.ref.left, r.ref.top, r.ref.right, r.ref.bottom);
  } finally {
    calloc.free(r);
  }
}

bool nearCaptionButtons(int x, int y) {
  final pt = calloc<w32.POINT>();
  try {
    pt.ref.x = x;
    pt.ref.y = y;
    var hwnd = 0;
    final under = w32.WindowFromPoint(pt.ref);
    if (under != 0) hwnd = w32.GetAncestor(under, w32.GA_ROOT);
    if (hwnd == 0) hwnd = w32.GetForegroundWindow();
    if (hwnd == 0) return false;
    if (hwnd == w32.GetShellWindow() || hwnd == w32.GetDesktopWindow()) {
      return false;
    }
    final style = w32.GetWindowLongPtr(hwnd, w32.GWL_STYLE);
    const wantCaption = w32.WS_CAPTION;
    if ((style & wantCaption) != wantCaption) return false;
    final r = windowRect(hwnd);
    if (r == null) return false;
    if (x < r.$1 || x > r.$3 || y < r.$2 || y > r.$4) return false;
    var dpi = 96;
    final d = w32.GetDpiForWindow(hwnd);
    if (d > 0) dpi = d;
    final zoneW = (170 * dpi / 96).round();
    final zoneH = (48 * dpi / 96).round();
    return x >= r.$3 - zoneW && y <= r.$2 + zoneH;
  } finally {
    calloc.free(pt);
  }
}

void main() {
  final fg = w32.GetForegroundWindow();
  print('foreground hwnd=$fg');
  final r = windowRect(fg);
  print('rect=$r  dpi=${w32.GetDpiForWindow(fg)}');
  print('style=0x${w32.GetWindowLongPtr(fg, w32.GWL_STYLE).toRadixString(16)}');
  print('shell=${w32.GetShellWindow()} desktop=${w32.GetDesktopWindow()}');
  if (r != null) {
    final topRight = nearCaptionButtons(r.$3 - 20, r.$2 + 10);
    final centre =
        nearCaptionButtons((r.$1 + r.$3) ~/ 2, (r.$2 + r.$4) ~/ 2);
    final topLeft = nearCaptionButtons(r.$1 + 20, r.$2 + 10);
    print('topRight=$topRight (期待 true)');
    print('centre=$centre (期待 false)');
    print('topLeft=$topLeft (期待 false)');
  }
}
