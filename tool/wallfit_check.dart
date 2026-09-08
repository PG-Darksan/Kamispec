// 使い捨ての確認用: IDesktopWallpaper::GetPosition (vtable 11) が本当に
// 読めるかを確かめる。 dart run tool/wallfit_probe.dart
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart' as pkgffi;

ffi.Pointer<ffi.Uint8> guid(int d1, int d2, int d3, List<int> d4) {
  final p = pkgffi.calloc<ffi.Uint8>(16);
  p[0] = d1 & 0xFF;
  p[1] = (d1 >> 8) & 0xFF;
  p[2] = (d1 >> 16) & 0xFF;
  p[3] = (d1 >> 24) & 0xFF;
  p[4] = d2 & 0xFF;
  p[5] = (d2 >> 8) & 0xFF;
  p[6] = d3 & 0xFF;
  p[7] = (d3 >> 8) & 0xFF;
  for (var i = 0; i < 8; i++) {
    p[8 + i] = d4[i];
  }
  return p;
}

void main() {
  final ole32 = ffi.DynamicLibrary.open('ole32.dll');
  final coInit = ole32.lookupFunction<
      ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32),
      int Function(ffi.Pointer<ffi.Void>, int)>('CoInitializeEx');
  final coCreate = ole32.lookupFunction<
      ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Void>,
          ffi.Uint32, ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Pointer<ffi.Void>>),
      int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Void>, int,
          ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Pointer<ffi.Void>>)>(
      'CoCreateInstance');
  final clsid = guid(0xC2CF3110, 0x460E, 0x4FC1,
      const [0xB9, 0xD0, 0x8A, 0x1C, 0x0C, 0x9C, 0xC4, 0xBD]);
  final iid = guid(0xB92B56A9, 0x8B55, 0x4E14,
      const [0x9A, 0x89, 0x01, 0x99, 0xBB, 0xB6, 0xF9, 0x3B]);
  final out = pkgffi.calloc<ffi.Pointer<ffi.Void>>();
  coInit(ffi.nullptr, 0x2);
  final hr = coCreate(clsid, ffi.nullptr, 0x17, iid, out);
  print('CoCreateInstance hr=0x${(hr & 0xFFFFFFFF).toRadixString(16)}');
  if (hr != 0) return;
  final obj = out.value;
  final vt = obj.cast<ffi.Pointer<ffi.Pointer<ffi.Void>>>().value;
  final pos = pkgffi.calloc<ffi.Int32>();
  final getPos = vt[11]
      .cast<
          ffi.NativeFunction<
              ffi.Int32 Function(
                  ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int32>)>>()
      .asFunction<int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int32>)>();
  final hr2 = getPos(obj, pos);
  const names = ['center', 'tile', 'stretch', 'fit', 'fill', 'span'];
  print('GetPosition hr=0x${(hr2 & 0xFFFFFFFF).toRadixString(16)} '
      'value=${pos.value} '
      '(${pos.value >= 0 && pos.value < names.length ? names[pos.value] : "?"})');
}
