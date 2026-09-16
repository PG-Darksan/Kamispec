// 仮想デスクトップの窓一覧を、アプリの外で試すための使い捨ての検分。
//
//   dart run tool/vdesk_probe.dart
//
// = ユーザー報告「仮想デスクトップのボタンを押して立ち上げようとすると
//   アプリが落ちてしまう」。 落ちる所が COM なのか窓の列挙なのかを
//   切り分ける (本体を起動せずに確かめる)。
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:win32/win32.dart' as w32;

const int kGwlExStyle = -20;
const int kWsExToolWindow = 0x00000080;
const int kWsExAppWindow = 0x00040000;

void main() {
  print('--- CoInitializeEx');
  final init = w32.CoInitializeEx(ffi.nullptr, w32.COINIT_APARTMENTTHREADED);
  print('hr = 0x${init.toRadixString(16)}');

  print('--- createFromID (IVirtualDesktopManager)');
  ffi.Pointer<w32.COMObject>? mgr;
  try {
    mgr = w32.COMObject.createFromID(
        w32.CLSID_VirtualDesktopManager, w32.IID_IVirtualDesktopManager);
    print('ok: ${mgr.address.toRadixString(16)}');
  } catch (e) {
    print('THREW: $e');
    mgr = null;
  }
  final vdm = mgr == null ? null : w32.IVirtualDesktopManager(mgr);

  print('--- enumerate windows');
  final buf = pkgffi.calloc<ffi.Uint16>(512).cast<pkgffi.Utf16>();
  final onCur = pkgffi.calloc<ffi.Int32>();
  final pidBuf = pkgffi.calloc<ffi.Uint32>();
  var n = 0;
  var h = 0;
  while (n < 60) {
    h = w32.FindWindowEx(0, h, ffi.nullptr, ffi.nullptr);
    if (h == 0) break;
    if (w32.IsWindowVisible(h) == 0) continue;
    final ex = w32.GetWindowLongPtr(h, kGwlExStyle);
    if ((ex & kWsExToolWindow) != 0 && (ex & kWsExAppWindow) == 0) continue;
    final len = w32.GetWindowTextLength(h);
    if (len <= 0) continue;
    w32.GetWindowText(h, buf, 511);
    final title = buf.toDartString().trim();
    if (title.isEmpty) continue;
    var cur = true;
    if (vdm != null) {
      onCur.value = 0;
      final hr = vdm.isWindowOnCurrentVirtualDesktop(h, onCur);
      if (hr == w32.S_OK) {
        cur = onCur.value != 0;
      } else {
        print('  isWindowOnCurrentVirtualDesktop hr=0x${hr.toRadixString(16)}');
      }
    }
    pidBuf.value = 0;
    w32.GetWindowThreadProcessId(h, pidBuf);
    n++;
    print('$n. [${cur ? 'this' : 'other'}] pid=${pidBuf.value} $title');
  }
  print('--- total $n');

  try {
    if (mgr != null) {
      w32.IUnknown(mgr).release();
      pkgffi.calloc.free(mgr);
    }
  } catch (e) {
    print('release THREW: $e');
  }
  pkgffi.calloc.free(buf.cast<ffi.Uint16>());
  pkgffi.calloc.free(onCur);
  pkgffi.calloc.free(pidBuf);
  if (init == w32.S_OK || init == w32.S_FALSE) w32.CoUninitialize();
  print('--- done');
}
