// READ-ONLY research probe. Two questions, both NON-DESTRUCTIVE:
//  (A) Does IVirtualDesktopManager::MoveWindowToDesktop really return
//      E_ACCESSDENIED for a foreign window?  We move the window to the
//      desktop it is ALREADY on -> even S_OK is a visible no-op.
//  (B) Does any KNOWN IVirtualDesktopManagerInternal IID resolve on this
//      build?  QueryService only; we never call an unknown vtable slot.
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart' as pkgffi;
import 'package:win32/win32.dart' as w32;

const kGwlExStyle = -20;
const kWsExToolWindow = 0x00000080;
const kWsExAppWindow = 0x00040000;
const kProcQueryLimited = 0x1000;

final _ole = ffi.DynamicLibrary.open('ole32.dll');
final _coCreate = _ole.lookupFunction<
    ffi.Int32 Function(ffi.Pointer, ffi.Pointer, ffi.Uint32, ffi.Pointer,
        ffi.Pointer<ffi.Pointer<ffi.Void>>),
    int Function(ffi.Pointer, ffi.Pointer, int, ffi.Pointer,
        ffi.Pointer<ffi.Pointer<ffi.Void>>)>('CoCreateInstance');

String hx(int hr) =>
    '0x${(hr & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';

String nm(int hr) {
  switch (hr & 0xFFFFFFFF) {
    case 0:
      return 'S_OK';
    case 0x80070005:
      return 'E_ACCESSDENIED';
    case 0x80004002:
      return 'E_NOINTERFACE';
    case 0x80004005:
      return 'E_FAIL';
    case 0x80070057:
      return 'E_INVALIDARG';
    case 0x80040154:
      return 'REGDB_E_CLASSNOTREG';
    case 0x80040155:
      return 'REGDB_E_IIDNOTREG';
    case 0x8007000E:
      return 'E_OUTOFMEMORY';
    case 0x800706BA:
      return 'RPC_S_SERVER_UNAVAILABLE';
    case 0x80070490:
      return 'ELEMENT_NOT_FOUND';
    default:
      return '?';
  }
}

void main() {
  w32.CoInitializeEx(ffi.nullptr, w32.COINIT_APARTMENTTHREADED);
  partA();
  print('');
  partB();
  w32.CoUninitialize();
}

// ------------------------- A: public API on a foreign window
void partA() {
  print('=== A. IVirtualDesktopManager::MoveWindowToDesktop ===');
  final mgr = w32.COMObject.createFromID(
      w32.CLSID_VirtualDesktopManager, w32.IID_IVirtualDesktopManager);
  final vdm = w32.IVirtualDesktopManager(mgr);
  final buf = pkgffi.calloc<ffi.Uint16>(512).cast<pkgffi.Utf16>();
  final exe = pkgffi.calloc<ffi.Uint16>(512).cast<pkgffi.Utf16>();
  final exeLen = pkgffi.calloc<ffi.Uint32>();
  final pid = pkgffi.calloc<ffi.Uint32>();
  final guid = pkgffi.calloc<w32.GUID>();
  final selfPid = w32.GetCurrentProcessId();
  var h = 0;
  var tested = 0;
  while (tested < 8) {
    h = w32.FindWindowEx(0, h, ffi.nullptr, ffi.nullptr);
    if (h == 0) break;
    if (w32.IsWindowVisible(h) == 0) continue;
    if (w32.GetWindow(h, w32.GW_OWNER) != 0) continue;
    final ex = w32.GetWindowLongPtr(h, kGwlExStyle);
    if ((ex & kWsExToolWindow) != 0 && (ex & kWsExAppWindow) == 0) continue;
    if (w32.GetWindowTextLength(h) <= 0) continue;
    w32.GetWindowText(h, buf, 511);
    final title = buf.toDartString().trim();
    if (title.isEmpty) continue;
    pid.value = 0;
    w32.GetWindowThreadProcessId(h, pid);
    if (pid.value == selfPid) continue; // foreign only
    var proc = '?';
    final hp = w32.OpenProcess(kProcQueryLimited, 0, pid.value);
    if (hp != 0) {
      exeLen.value = 511;
      if (w32.QueryFullProcessImageName(hp, 0, exe, exeLen) != 0) {
        proc = exe.toDartString().split(r'\').last;
      }
      w32.CloseHandle(hp);
    }
    // its CURRENT desktop id -> moving there is a no-op even on success
    if (vdm.getWindowDesktopId(h, guid) != w32.S_OK) continue;
    final did = guid.toDartGuid().toString();
    final hr = vdm.moveWindowToDesktop(h, guid);
    tested++;
    final t = title.length > 34 ? title.substring(0, 34) : title;
    print('  [$proc] "$t"');
    print('      desktop=$did  ->  hr=${hx(hr)} ${nm(hr)}');
  }
  if (tested == 0) print('  (no foreign top-level window found)');
  pkgffi.calloc.free(buf.cast<ffi.Uint16>());
  pkgffi.calloc.free(exe.cast<ffi.Uint16>());
  pkgffi.calloc.free(exeLen);
  pkgffi.calloc.free(pid);
  pkgffi.calloc.free(guid);
  vdm.detach();
  pkgffi.calloc.free(mgr);
}

// ------------------------- B: undocumented interface availability
const clsidImmersiveShell = '{C2F03A33-21F5-47FA-B4BB-156362A2F239}';
const iidServiceProvider = '{6D5140C1-7436-11CE-8034-00AA006009FA}';
const clsidVdmInternal = '{C5E0CDCA-7B6E-41B2-9FC4-D93975CC467B}';

// Community-maintained IIDs, one per Windows generation.
const vdmInternalIids = <String, String>{
  'Win10 1607-1803': '{F31574D6-B682-4CDC-BD56-1827860ABEC6}',
  'Win10 1809-21H2': '{094AFE11-44F2-4BA0-976F-29A97E263EE0}',
  'Win11 21H2 22000': '{B2F925B9-5A0F-4D2E-9F4D-2B1507593C10}',
  'Win11 22H2 22621': '{A3175F2D-239C-4BD2-8AA0-EEBA8B0B138E}',
  'Win11 22H2/23H2 late': '{53F5CA0B-158F-4124-900C-057158060B27}',
  'Win11 24H2 26100': '{4970BA3D-FD4E-4647-BEA3-D89076EF4B9C}',
};
const appViewCollIids = <String, String>{
  'IApplicationViewCollection Win10': '{1841C6D7-4F9D-42C0-AF41-8747538F10E5}',
  'IApplicationViewCollection 1803+': '{9AC0B5C8-1484-4C5B-9533-4134A0F97CEA}',
};

void partB() {
  print('=== B. undocumented IVirtualDesktopManagerInternal probe ===');
  print('  (QueryService only - no unknown vtable slot is ever called)');
  final clsid = w32.GUIDFromString(clsidImmersiveShell);
  final iid = w32.GUIDFromString(iidServiceProvider);
  final pp = pkgffi.calloc<ffi.Pointer<ffi.Void>>();
  final hr = _coCreate(clsid, ffi.nullptr, 0x1 | 0x4, iid, pp);
  print('  CoCreateInstance(ImmersiveShell, IServiceProvider) = '
      '${hx(hr)} ${nm(hr)}');
  if (hr != 0 || pp.value == ffi.nullptr) {
    pkgffi.calloc.free(pp);
    return;
  }
  final psp = pp.value;
  // IServiceProvider::QueryService is documented vtable slot 3.
  final vtbl = psp.cast<ffi.Pointer<ffi.Pointer<ffi.Void>>>().value;
  final qs = (vtbl + 3)
      .cast<
          ffi.Pointer<
              ffi.NativeFunction<
                  ffi.Int32 Function(ffi.Pointer, ffi.Pointer, ffi.Pointer,
                      ffi.Pointer<ffi.Pointer<ffi.Void>>)>>>()
      .value
      .asFunction<
          int Function(ffi.Pointer, ffi.Pointer, ffi.Pointer,
              ffi.Pointer<ffi.Pointer<ffi.Void>>)>();

  void probe(String svc, Map<String, String> iids) {
    final sg = w32.GUIDFromString(svc);
    for (final e in iids.entries) {
      final ig = w32.GUIDFromString(e.value);
      final out = pkgffi.calloc<ffi.Pointer<ffi.Void>>();
      var r = -1;
      try {
        r = qs(psp, sg, ig, out);
      } catch (ex) {
        print('    ${e.key}: THREW $ex');
      }
      print('    ${e.key.padRight(26)} ${e.value} -> ${hx(r)} ${nm(r)}');
      if (r == 0 && out.value != ffi.nullptr) {
        // release immediately; never call an unknown slot
        final vt = out.value.cast<ffi.Pointer<ffi.Pointer<ffi.Void>>>().value;
        (vt + 2)
            .cast<
                ffi.Pointer<
                    ffi.NativeFunction<ffi.Uint32 Function(ffi.Pointer)>>>()
            .value
            .asFunction<int Function(ffi.Pointer)>()(out.value);
      }
      pkgffi.calloc.free(out);
      pkgffi.calloc.free(ig);
    }
    pkgffi.calloc.free(sg);
  }

  print('  service CLSID_VirtualDesktopManagerInternal $clsidVdmInternal:');
  probe(clsidVdmInternal, vdmInternalIids);
  print('  service = IID (IApplicationViewCollection):');
  for (final e in appViewCollIids.entries) {
    probe(e.value, <String, String>{e.key: e.value});
  }
  pkgffi.calloc.free(pp);
  pkgffi.calloc.free(clsid);
  pkgffi.calloc.free(iid);
}
