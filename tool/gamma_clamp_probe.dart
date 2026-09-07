// 使い捨て: Windows がどこまでのガンマ表を受け付けるかを二分探索で測る。
//   dart run tool/gamma_clamp_probe.dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final _user32 = DynamicLibrary.open('user32.dll');
final _gdi32 = DynamicLibrary.open('gdi32.dll');

final _enumDisplayDevices = _user32.lookupFunction<
    Int32 Function(Pointer<Utf16>, Uint32, Pointer<Uint8>, Uint32),
    int Function(Pointer<Utf16>, int, Pointer<Uint8>,
        int)>('EnumDisplayDevicesW');
final _createDC = _gdi32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        Pointer<Void>),
    int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        Pointer<Void>)>('CreateDCW');
final _deleteDC = _gdi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');
final _getGamma = _gdi32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint16>),
    int Function(int, Pointer<Uint16>)>('GetDeviceGammaRamp');
final _setGamma = _gdi32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint16>),
    int Function(int, Pointer<Uint16>)>('SetDeviceGammaRamp');

String _first() {
  final dd = calloc<Uint8>(840);
  try {
    for (var i = 0; i < 16; i++) {
      for (var k = 0; k < 840; k++) {
        dd[k] = 0;
      }
      dd.cast<Uint32>().value = 840;
      if (_enumDisplayDevices(nullptr, i, dd, 0) == 0) break;
      final flags = Pointer<Uint32>.fromAddress(dd.address + 324).value;
      if (flags & 1 == 0) continue;
      final p = Pointer<Uint16>.fromAddress(dd.address + 4);
      final b = StringBuffer();
      for (var k = 0; k < 32; k++) {
        if (p[k] == 0) break;
        b.writeCharCode(p[k]);
      }
      return b.toString();
    }
  } finally {
    calloc.free(dd);
  }
  return '';
}

Pointer<Uint16> ramp(double br, double wr) {
  final p = calloc<Uint16>(768);
  final gg = 1.0 - 0.28 * wr;
  final gb = 1.0 - 0.62 * wr;
  for (var i = 0; i < 256; i++) {
    final v = i * 257.0;
    p[i] = (v * br).clamp(0, 65535).round();
    p[256 + i] = (v * br * gg).clamp(0, 65535).round();
    p[512 + i] = (v * br * gb).clamp(0, 65535).round();
  }
  return p;
}

void main() {
  final name = _first();
  final drv = 'DISPLAY'.toNativeUtf16();
  final dev = name.toNativeUtf16();
  final hdc = _createDC(drv, dev, nullptr, nullptr);
  calloc.free(drv);
  calloc.free(dev);
  stdout.writeln('display=$name hdc=$hdc');
  if (hdc == 0) return;
  final orig = calloc<Uint16>(768);
  _getGamma(hdc, orig);
  try {
    bool tryIt(double br, double wr) {
      final r = ramp(br, wr);
      final ok = _setGamma(hdc, r) != 0;
      calloc.free(r);
      _setGamma(hdc, orig);
      return ok;
    }

    // 1) 暗さだけ
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 14; i++) {
      final mid = (lo + hi) / 2;
      if (tryIt(mid, 0)) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    stdout.writeln('暗さだけ: 受け付ける下限 = ${(hi * 100).toStringAsFixed(1)}%');

    // 2) 暖色だけ
    lo = 1.0;
    hi = 0.0;
    var a = 0.0, b = 1.0;
    for (var i = 0; i < 14; i++) {
      final mid = (a + b) / 2;
      if (tryIt(1.0, mid)) {
        a = mid;
      } else {
        b = mid;
      }
    }
    stdout.writeln('暖色だけ: 受け付ける上限 = ${(a * 100).toStringAsFixed(1)}% '
        '(青の倍率 ${(1 - 0.62 * a).toStringAsFixed(3)})');

    // 3) 青だけを落とす場合の限界 (赤緑はそのまま)
    double blueOnly(double mul) {
      final r = calloc<Uint16>(768);
      for (var i = 0; i < 256; i++) {
        final v = i * 257.0;
        r[i] = v.round();
        r[256 + i] = v.round();
        r[512 + i] = (v * mul).clamp(0, 65535).round();
      }
      final ok = _setGamma(hdc, r) != 0;
      calloc.free(r);
      _setGamma(hdc, orig);
      return ok ? 1 : 0;
    }

    var bl = 0.0, bh = 1.0;
    for (var i = 0; i < 14; i++) {
      final mid = (bl + bh) / 2;
      if (blueOnly(mid) == 1) {
        bh = mid;
      } else {
        bl = mid;
      }
    }
    stdout.writeln('青だけ: 受け付ける下限倍率 = ${bh.toStringAsFixed(3)}');

    // 4) 一次関数ではなく「持ち上げ (黒を浮かせない) 」 型も試す。
    //    ramp[i] = i*257 * br だと下限が厳しいので、
    //    ガンマ曲線 (i/255)^(1/g) を使うとどうか。
    bool tryGamma(double g) {
      final r = calloc<Uint16>(768);
      for (var i = 0; i < 256; i++) {
        final v = 65535.0 * _pow(i / 255.0, 1.0 / g);
        r[i] = v.clamp(0, 65535).round();
        r[256 + i] = v.clamp(0, 65535).round();
        r[512 + i] = v.clamp(0, 65535).round();
      }
      final ok = _setGamma(hdc, r) != 0;
      calloc.free(r);
      _setGamma(hdc, orig);
      return ok;
    }

    var gl = 0.05, gh = 1.0;
    for (var i = 0; i < 12; i++) {
      final mid = (gl + gh) / 2;
      if (tryGamma(mid)) {
        gh = mid;
      } else {
        gl = mid;
      }
    }
    stdout.writeln('ガンマ曲線: 受け付ける下限 g = ${gh.toStringAsFixed(3)}');
  } finally {
    _setGamma(hdc, orig);
    calloc.free(orig);
    _deleteDC(hdc);
    stdout.writeln('元に戻しました');
  }
}

double _pow(double x, double e) {
  if (x <= 0) return 0;
  var r = 1.0;
  // dart:math を使わずに済ませる必要は無いが、 依存を増やさないため簡易に。
  return _expApprox(e * _lnApprox(x)) * r;
}

double _lnApprox(double x) {
  var n = 0;
  while (x > 2) {
    x /= 2;
    n++;
  }
  while (x < 0.5) {
    x *= 2;
    n--;
  }
  final y = (x - 1) / (x + 1);
  var s = 0.0, t = y;
  for (var k = 1; k <= 21; k += 2) {
    s += t / k;
    t *= y * y;
  }
  return 2 * s + n * 0.6931471805599453;
}

double _expApprox(double x) {
  var s = 1.0, t = 1.0;
  for (var k = 1; k <= 20; k++) {
    t *= x / k;
    s += t;
  }
  return s;
}
