// 画面の「明るさ」 と「ブルーライトカット」 (Windows 専用)。
//
// ★ = ユーザー要望「ディスプレイの明るさを変えられるようにして欲しいのと、
//   ブルーライトカットモードを付けて欲しい」。
//
// ── 明るさ: 3 つの道を、 効く順に試す ─────────────────────────────
//
//  1. **DDC/CI** (`dxva2.dll`)。 外付けモニターの本当の明るさ (背面光) を
//     動かす。 win32 5.15.0 に束縛が入っているのでそのまま呼べる。
//     この開発機の内蔵パネルでは `GetMonitorBrightness` が 0 を返した
//     (= 対応していない) ので、 失敗を見て次へ落ちる作りにしてある。
//  2. **WMI** (`root\WMI` の WmiMonitorBrightnessMethods)。 ノートの内蔵
//     パネルの背面光。 実測で**管理者権限なしで動く** (0〜100 の 101 段階)。
//     Dart から COM で WMI を叩くのは大掛かりなので、 窓を出さずに
//     PowerShell を 1 回走らせる。 つまみを離した時しか呼ばないので、
//     0.3 秒ほど掛かっても操作の邪魔にはならない。
//  3. **ガンマ表** (`gdi32` の SetDeviceGammaRamp)。 背面光は動かないが、
//     どの画面でも効く最後の手段。 ブルーライトカットもこれで行う。
//
// ── ガンマ表の「壁」 (実測) ───────────────────────────────────────
// Windows は極端なガンマ表を黙って弾く。 実測した判定式は
//     |ramp[c][i] - (i << 8)| > 32768 なら拒否
// で、 一次で縮める場合の下限は **約 0.496 倍** (i=255 で効いてくる)。
// 二分探索で 0.496 と出た (tool/gamma_clamp_probe.dart)。
// そこで少し余裕を見て **0.52 倍**を下限にし、 それより暗い / 濃い指定は
// こちらで丸める。 こうすれば SetDeviceGammaRamp が失敗しない。
// (HKLM の GdiIcmGammaRange を書けば外せるが、 管理者権限が要るうえ
//  他のアプリにも影響するので触らない。)
//
// ── 事故を防ぐ ───────────────────────────────────────────────────
//  ・ガンマは**アプリを閉じる時に必ず元へ戻す** (main.dart)。 背面光と違い
//    OS の設定画面に出てこないので、 暗いまま残ると戻し方が分からない。
//  ・落ちた時のために、 最初に触る前の表を控えへ書き出しておく。 次に
//    立ち上がった時、 戻し忘れの印が残っていればそれを書き戻す。
//  ・下限は 50% 止まり。 真っ暗にはできない。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// 明るさをどうやって変えるか。
enum BrightnessRoute {
  /// 外付けモニターの本当の明るさ (DDC/CI)。
  ddc,

  /// ノートの内蔵パネルの本当の明るさ (WMI)。
  wmi,

  /// 見かけだけ暗くする (ガンマ表)。
  gamma,
}

/// 1 台ぶんの画面。
class LightMonitor {
  /// GDI の名前 (`\\.\DISPLAY1` など)。 ガンマを当てる時の宛先。
  final String gdiName;

  /// モニターの説明 (`Generic PnP Monitor` など)。
  final String label;
  final bool primary;
  final int left;
  final int top;
  final int width;
  final int height;

  /// 明るさをどう変えるか。
  final BrightnessRoute route;

  /// 今の明るさ (%)。 分からなければ null。
  final int? percent;

  const LightMonitor({
    required this.gdiName,
    required this.label,
    required this.primary,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.route,
    this.percent,
  });

  /// 本当の背面光を動かせるか (= 見かけだけではないか)。
  bool get isRealBacklight => route != BrightnessRoute.gamma;
}

// ── Win32 の入口 ───────────────────────────────────────────────────
final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _gdi32 = DynamicLibrary.open('gdi32.dll');

final _enumDisplayDevices = _user32.lookupFunction<
    Int32 Function(Pointer<Utf16>, Uint32, Pointer<Uint8>, Uint32),
    int Function(
        Pointer<Utf16>, int, Pointer<Uint8>, int)>('EnumDisplayDevicesW');
final _enumDisplaySettings = _user32.lookupFunction<
    Int32 Function(Pointer<Utf16>, Uint32, Pointer<Uint8>),
    int Function(Pointer<Utf16>, int, Pointer<Uint8>)>('EnumDisplaySettingsW');
final _monitorFromPoint = _user32.lookupFunction<IntPtr Function(Int64, Uint32),
    int Function(int, int)>('MonitorFromPoint');

final _createDC = _gdi32.lookupFunction<
    IntPtr Function(
        Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
    int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        Pointer<Void>)>('CreateDCW');
final _deleteDC =
    _gdi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'DeleteDC');
// ★ SetDeviceGammaRamp / GetDeviceGammaRamp は package:win32 5.15.0 に
//   入っていない (パッケージ全体で 0 件)。 自前で束縛する。
final _getGamma = _gdi32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint16>),
    int Function(int, Pointer<Uint16>)>('GetDeviceGammaRamp');
final _setGamma = _gdi32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint16>),
    int Function(int, Pointer<Uint16>)>('SetDeviceGammaRamp');

/// DISPLAY_DEVICEW の大きさ (x64)。
/// cb 4 + DeviceName[32] 64 + DeviceString[128] 256 + StateFlags 4 +
/// DeviceID[128] 256 + DeviceKey[128] 256 = 840。
const int _kDisplayDeviceSize = 840;
const int _kAttachedToDesktop = 0x00000001;
const int _kPrimaryDevice = 0x00000004;

/// DEVMODEW の中身の置き場所 (x64)。 実測で合わせてある。
///
///   0   dmDeviceName WCHAR[32]      (64)
///   64  dmSpecVersion / dmDriverVersion / dmSize(68) / dmDriverExtra
///   72  dmFields
///   76  ★ dmPosition.x / 80 dmPosition.y   (印刷用と共用の 16 バイト)
///   92  dmColor 〜 100 dmCollate
///   102 dmFormName WCHAR[32]        (64)
///   166 dmLogPixels
///   168 dmBitsPerPel
///   172 ★ dmPelsWidth / 176 dmPelsHeight
///   180 dmDisplayFlags / 184 dmDisplayFrequency … 220 まで
///
/// ★ はじめ位置を 172 から読んでいて、 **画面の大きさを位置と取り違えて**
///   いた (実測で @(1920,1200) と出て気付いた)。 位置は 76。
const int _kDevModeSize = 220;
const int _kDevModeSizeOffset = 68;
const int _kDevModePositionOffset = 76;
const int _kDevModePelsOffset = 172;
const int _kEnumCurrentSettings = 0xFFFFFFFF;

/// PHYSICAL_MONITOR = HANDLE 8 + WCHAR[128] 256。
const int _kPhysicalMonitorSize = 264;
const int _kMonitorDefaultToNull = 0;

/// ガンマ表で縮められる下限。 実測の壁は 0.496 なので少し余裕を見る。
const double kGammaFloor = 0.52;

String _readWide(Pointer<Uint8> base, int offset, int maxChars) {
  final p = Pointer<Uint16>.fromAddress(base.address + offset);
  final b = StringBuffer();
  for (var i = 0; i < maxChars; i++) {
    final c = p[i];
    if (c == 0) break;
    b.writeCharCode(c);
  }
  return b.toString();
}

class DisplayLight {
  DisplayLight._();

  static bool get isSupported => !kIsWeb && Platform.isWindows;

  /// 触った画面の「元のガンマ表」。 鍵は GDI の名前。
  static final Map<String, Uint16List> _originals = <String, Uint16List>{};

  /// 今ガンマを当てているか。
  static bool get isGammaApplied => _originals.isNotEmpty;

  /// WMI が使えるか (1 回だけ調べて覚える)。
  static bool? _wmiOk;

  /// 画面ごとの「どの道で明るさを変えるか」。 鍵は `名前@位置`。
  /// DDC/CI の問い合わせが重いので、 1 回調べたら覚えておく。
  static final Map<String, BrightnessRoute> _routeCache =
      <String, BrightnessRoute>{};

  /// 覚えている道を捨てる (画面を繋ぎ直した時などに呼ぶ)。
  static void invalidateRoutes() => _routeCache.clear();

  // ── 画面の一覧 ─────────────────────────────────────────────────
  /// 今つながっている画面を、 左上から順に返す。
  static List<LightMonitor> list() {
    if (!isSupported) return const [];
    try {
      return _list();
    } catch (e) {
      debugPrint('画面の一覧を作れませんでした: $e');
      return const [];
    }
  }

  static List<LightMonitor> _list() {
    final out = <LightMonitor>[];
    final dd = calloc<Uint8>(_kDisplayDeviceSize);
    final dm = calloc<Uint8>(_kDevModeSize);
    try {
      for (var i = 0; i < 16; i++) {
        for (var k = 0; k < _kDisplayDeviceSize; k++) {
          dd[k] = 0;
        }
        dd.cast<Uint32>().value = _kDisplayDeviceSize;
        if (_enumDisplayDevices(nullptr, i, dd, 0) == 0) break;
        final flags = Pointer<Uint32>.fromAddress(dd.address + 324).value;
        if (flags & _kAttachedToDesktop == 0) continue;
        final name = _readWide(dd, 4, 32);
        final label = _readWide(dd, 68, 128);
        final primary = flags & _kPrimaryDevice != 0;

        var left = 0, top = 0, w = 0, h = 0;
        for (var k = 0; k < _kDevModeSize; k++) {
          dm[k] = 0;
        }
        Pointer<Uint16>.fromAddress(dm.address + _kDevModeSizeOffset).value =
            _kDevModeSize;
        final np = name.toNativeUtf16();
        try {
          if (_enumDisplaySettings(np, _kEnumCurrentSettings, dm) != 0) {
            left = Pointer<Int32>.fromAddress(
                    dm.address + _kDevModePositionOffset)
                .value;
            top = Pointer<Int32>.fromAddress(
                    dm.address + _kDevModePositionOffset + 4)
                .value;
            w = Pointer<Uint32>.fromAddress(dm.address + _kDevModePelsOffset)
                .value;
            h = Pointer<Uint32>.fromAddress(
                    dm.address + _kDevModePelsOffset + 4)
                .value;
          }
        } finally {
          calloc.free(np);
        }

        // どの道で明るさを変えるか。
        //
        // ★ DDC/CI の問い合わせはモニターとの I2C 往復で、 対応している
        //   機種でも数十〜数百 ms 掛かる。 `list()` は設定を開くたび・
        //   当てるたびに呼ばれるので、 **画面ごとに 1 回だけ**調べて覚える。
        final key = '$name@$left,$top';
        BrightnessRoute route;
        int? percent;
        final cached = _routeCache[key];
        if (cached != null) {
          route = cached;
          percent = route == BrightnessRoute.wmi
              ? _wmiCached
              : route == BrightnessRoute.ddc
                  ? _ddcRead(left, top)
                  : null;
        } else {
          final ddc = _ddcRead(left, top);
          if (ddc != null) {
            route = BrightnessRoute.ddc;
            percent = ddc;
          } else if (primary && _wmiAvailable()) {
            route = BrightnessRoute.wmi;
            percent = _wmiCached;
          } else {
            route = BrightnessRoute.gamma;
          }
          // WMI を調べ終える前は gamma と出るので、 その答えは覚えない
          // (調べ終わってから呼び直した時に wmi へ変わるようにする)。
          if (!(route == BrightnessRoute.gamma && primary && _wmiOk == null)) {
            _routeCache[key] = route;
          }
        }

        out.add(LightMonitor(
          gdiName: name,
          label: label,
          primary: primary,
          left: left,
          top: top,
          width: w,
          height: h,
          route: route,
          percent: percent,
        ));
      }
    } finally {
      calloc.free(dd);
      calloc.free(dm);
    }
    out.sort((a, b) =>
        a.left != b.left ? a.left.compareTo(b.left) : a.top.compareTo(b.top));
    return out;
  }

  // ── DDC/CI (外付けモニターの本当の明るさ) ────────────────────────
  static DynamicLibrary? _dxva2;
  static DynamicLibrary? get _dxva {
    if (_dxva2 != null) return _dxva2;
    try {
      return _dxva2 = DynamicLibrary.open('dxva2.dll');
    } catch (_) {
      return null;
    }
  }

  /// [left],[top] にある画面の物理モニターの握りを 1 本だけ取る。
  /// 使い終わったら [_ddcRelease] を必ず呼ぶ。
  static ({int handle, Pointer<Uint8> arr, int count})? _ddcOpen(
      int left, int top) {
    final lib = _dxva;
    if (lib == null) return null;
    try {
      final getNum = lib.lookupFunction<
          Int32 Function(IntPtr, Pointer<Uint32>),
          int Function(int,
              Pointer<Uint32>)>('GetNumberOfPhysicalMonitorsFromHMONITOR');
      final getPhys = lib.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Uint8>),
          int Function(
              int, int, Pointer<Uint8>)>('GetPhysicalMonitorsFromHMONITOR');
      // POINT は 32bit の x と y をつなげた 64bit。
      final pt = ((top + 1) << 32) | ((left + 1) & 0xFFFFFFFF);
      final hmon = _monitorFromPoint(pt, _kMonitorDefaultToNull);
      if (hmon == 0) return null;
      final n = calloc<Uint32>();
      try {
        if (getNum(hmon, n) == 0 || n.value == 0) return null;
        final arr = calloc<Uint8>(_kPhysicalMonitorSize * n.value);
        if (getPhys(hmon, n.value, arr) == 0) {
          calloc.free(arr);
          return null;
        }
        final handle = Pointer<IntPtr>.fromAddress(arr.address).value;
        return (handle: handle, arr: arr, count: n.value);
      } finally {
        calloc.free(n);
      }
    } catch (e) {
      debugPrint('DDC/CI を開けません: $e');
      return null;
    }
  }

  static void _ddcRelease(({int handle, Pointer<Uint8> arr, int count}) h) {
    try {
      _dxva?.lookupFunction<Int32 Function(Uint32, Pointer<Uint8>),
              int Function(int, Pointer<Uint8>)>('DestroyPhysicalMonitors')(
          h.count, h.arr);
    } catch (_) {}
    calloc.free(h.arr);
  }

  /// DDC/CI で今の明るさ (%) を読む。 使えなければ null。
  static int? _ddcRead(int left, int top) {
    final h = _ddcOpen(left, top);
    if (h == null) return null;
    final mn = calloc<Uint32>(), cur = calloc<Uint32>(), mx = calloc<Uint32>();
    try {
      final get = _dxva!.lookupFunction<
          Int32 Function(
              IntPtr, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>, Pointer<Uint32>,
              Pointer<Uint32>)>('GetMonitorBrightness');
      if (get(h.handle, mn, cur, mx) == 0) return null;
      final lo = mn.value, hi = mx.value;
      if (hi <= lo) return null;
      return ((cur.value - lo) * 100 / (hi - lo)).round().clamp(0, 100);
    } catch (_) {
      return null;
    } finally {
      calloc.free(mn);
      calloc.free(cur);
      calloc.free(mx);
      _ddcRelease(h);
    }
  }

  /// DDC/CI で明るさ (%) を当てる。
  static bool _ddcWrite(int left, int top, int percent) {
    final h = _ddcOpen(left, top);
    if (h == null) return false;
    final mn = calloc<Uint32>(), cur = calloc<Uint32>(), mx = calloc<Uint32>();
    try {
      final get = _dxva!.lookupFunction<
          Int32 Function(
              IntPtr, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>, Pointer<Uint32>,
              Pointer<Uint32>)>('GetMonitorBrightness');
      final set = _dxva!.lookupFunction<Int32 Function(IntPtr, Uint32),
          int Function(int, int)>('SetMonitorBrightness');
      if (get(h.handle, mn, cur, mx) == 0) return false;
      final lo = mn.value, hi = mx.value;
      if (hi <= lo) return false;
      final v = (lo + (hi - lo) * percent.clamp(0, 100) / 100).round();
      return set(h.handle, v) != 0;
    } catch (e) {
      debugPrint('DDC/CI で明るさを変えられません: $e');
      return false;
    } finally {
      calloc.free(mn);
      calloc.free(cur);
      calloc.free(mx);
      _ddcRelease(h);
    }
  }

  // ── WMI (ノートの内蔵パネルの本当の明るさ) ──────────────────────
  //
  // Dart から COM で WMI を叩くのは大掛かりなので、 窓を出さずに
  // PowerShell を 1 回走らせる。 つまみを離した時しか呼ばない。
  static int? _wmiCached;

  /// 分かっている範囲での答え。 **調べには行かない** (画面を作る所から
  /// 呼ばれるので、 ここで PowerShell を待つと数百 ms 固まってしまう)。
  static bool _wmiAvailable() => _wmiOk ?? false;

  static Future<bool>? _wmiProbe;

  /// WMI で明るさを触れるかを 1 回だけ調べる。 **画面を出す前に呼ぶ**。
  ///
  /// ★ はじめ `Process.runSync` で調べていたが、 これは列挙のたびに
  ///   UI を 0.3 秒ほど止める。 立ち上がりにも走るので、 待たない形にした。
  static Future<bool> ensureWmiProbed() {
    if (_wmiOk != null) return Future<bool>.value(_wmiOk);
    return _wmiProbe ??= () async {
      try {
        final r = await Process.run(
          'powershell',
          const [
            '-NoProfile',
            '-NonInteractive',
            '-WindowStyle',
            'Hidden',
            '-Command',
            r'(Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness -ErrorAction Stop).CurrentBrightness',
          ],
          runInShell: false,
        );
        final txt = '${r.stdout}'.trim().split(RegExp(r'\s+')).firstWhere(
              (e) => e.isNotEmpty,
              orElse: () => '',
            );
        final v = int.tryParse(txt);
        _wmiCached = v;
        return _wmiOk = (r.exitCode == 0 && v != null);
      } catch (e) {
        debugPrint('WMI の明るさを読めません: $e');
        return _wmiOk = false;
      }
    }();
  }

  static Future<bool> _wmiWrite(int percent) async {
    try {
      final v = percent.clamp(0, 100);
      final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-Command',
          'Get-CimInstance -Namespace root/WMI -ClassName '
              'WmiMonitorBrightnessMethods | Invoke-CimMethod '
              '-MethodName WmiSetBrightness '
              '-Arguments @{Timeout=1;Brightness=$v} | Out-Null',
        ],
        runInShell: false,
      );
      if (r.exitCode == 0) _wmiCached = v;
      return r.exitCode == 0;
    } catch (e) {
      debugPrint('WMI で明るさを変えられません: $e');
      return false;
    }
  }

  // ── 明るさを当てる (道は画面ごと) ───────────────────────────────
  /// [m] の明るさを [percent] (%) にする。
  ///
  /// 背面光を動かせる画面 (DDC/CI・WMI) はそのまま当てる。
  /// できない画面は、 ガンマ表で見かけを暗くする (下限 [kGammaFloor])。
  static Future<bool> setBrightness(LightMonitor m, int percent,
      {double warm = 0}) async {
    if (!isSupported) return false;
    switch (m.route) {
      case BrightnessRoute.ddc:
        return _ddcWrite(m.left, m.top, percent);
      case BrightnessRoute.wmi:
        return _wmiWrite(percent);
      case BrightnessRoute.gamma:
        return applyGamma(m.gdiName, dim: percent / 100, warm: warm);
    }
  }

  // ── ガンマ表 (見かけの明るさ + ブルーライトカット) ────────────────
  /// [dim] 0.5〜1.0 (小さいほど暗い) と [warm] 0〜1 (大きいほど暖色) を当てる。
  ///
  /// どちらも 1.0 / 0 なら元へ戻す。
  static bool applyGamma(String gdiName, {double dim = 1, double warm = 0}) {
    if (!isSupported) return false;
    if (dim >= 0.999 && warm <= 0.001) {
      restoreGamma(gdiName);
      return true;
    }
    final hdc = _openDC(gdiName);
    if (hdc == 0) return false;
    try {
      _rememberOriginal(gdiName, hdc);
      final ramp = _buildRamp(dim, warm);
      try {
        return _setGamma(hdc, ramp) != 0;
      } finally {
        calloc.free(ramp);
      }
    } finally {
      _deleteDC(hdc);
    }
  }

  /// 明るさ [dim] と暖かさ [warm] からガンマ表を作る。
  ///
  /// 暖色は「緑をすこし、 青をおおきく落とす」。 いちばん濃くして
  /// R:1 / G:0.75 / B:0.5 (おおよそ 6500K → 3400K)。
  /// どの色も [kGammaFloor] より下へは行かせない (Windows が弾くため)。
  static Pointer<Uint16> _buildRamp(double dim, double warm) {
    final d = dim.clamp(kGammaFloor, 1.0);
    final w = warm.clamp(0.0, 1.0);
    final mr = d.clamp(kGammaFloor, 1.0);
    final mg = (d * (1 - 0.25 * w)).clamp(kGammaFloor, 1.0);
    final mb = (d * (1 - 0.50 * w)).clamp(kGammaFloor, 1.0);
    final p = calloc<Uint16>(768);
    for (var i = 0; i < 256; i++) {
      final v = i * 257.0;
      p[i] = (v * mr).clamp(0, 65535).round();
      p[256 + i] = (v * mg).clamp(0, 65535).round();
      p[512 + i] = (v * mb).clamp(0, 65535).round();
    }
    return p;
  }

  static int _openDC(String gdiName) {
    final drv = 'DISPLAY'.toNativeUtf16();
    final dev = gdiName.toNativeUtf16();
    try {
      return _createDC(drv, dev, nullptr, nullptr);
    } catch (e) {
      debugPrint('画面の入口を開けません ($gdiName): $e');
      return 0;
    } finally {
      calloc.free(drv);
      calloc.free(dev);
    }
  }

  /// 初めて触る前の表を覚えておく (戻すため)。
  static void _rememberOriginal(String gdiName, int hdc) {
    if (_originals.containsKey(gdiName)) return;
    final buf = calloc<Uint16>(768);
    try {
      if (_getGamma(hdc, buf) == 0) return;
      final copy = Uint16List(768);
      for (var i = 0; i < 768; i++) {
        copy[i] = buf[i];
      }
      _originals[gdiName] = copy;
    } finally {
      calloc.free(buf);
    }
  }

  /// 1 台ぶん元へ戻す。
  static void restoreGamma(String gdiName) {
    final orig = _originals.remove(gdiName);
    if (orig == null) return;
    final hdc = _openDC(gdiName);
    if (hdc == 0) return;
    final buf = calloc<Uint16>(768);
    try {
      for (var i = 0; i < 768; i++) {
        buf[i] = orig[i];
      }
      _setGamma(hdc, buf);
    } finally {
      calloc.free(buf);
      _deleteDC(hdc);
    }
  }

  /// 触った画面すべてを元へ戻す (アプリを閉じる時に呼ぶ)。
  static void restoreAllGamma() {
    for (final name in _originals.keys.toList()) {
      restoreGamma(name);
    }
  }

  // ── 落ちた時の戻し ─────────────────────────────────────────────
  /// 元の表を控えへ書き出しておく形。 `{gdiName: base64}`。
  static String encodeOriginals() {
    if (_originals.isEmpty) return '';
    final m = <String, String>{};
    _originals.forEach((k, v) {
      m[k] = base64Encode(v.buffer.asUint8List());
    });
    return jsonEncode(m);
  }

  /// [raw] は [encodeOriginals] が作った文字列。 中身を書き戻して消す。
  ///
  /// アプリが落ちてガンマを戻せなかった時、 次の立ち上がりに呼ぶ。
  static void restoreFromEncoded(String raw) {
    if (!isSupported || raw.isEmpty) return;
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return;
      m.forEach((k, v) {
        if (v is! String) return;
        final bytes = base64Decode(v);
        if (bytes.length != 768 * 2) return;
        final ramp = bytes.buffer.asUint16List();
        final hdc = _openDC('$k');
        if (hdc == 0) return;
        final buf = calloc<Uint16>(768);
        try {
          for (var i = 0; i < 768; i++) {
            buf[i] = ramp[i];
          }
          _setGamma(hdc, buf);
        } finally {
          calloc.free(buf);
          _deleteDC(hdc);
        }
      });
    } catch (e) {
      debugPrint('前回のガンマを戻せませんでした: $e');
    }
  }
}
