// パソコン側の設定 (マウスの感度 / スクリーンセーバー / スリープ・電源) を
// アプリから触るための道具 (= ユーザー要望「PC設定」)。
//
// Windows 専用。 他の OS では [isSupported] が false を返し、 読み書きは
// 黙って諦める (画面側は項目そのものを出さない)。
//
// ★ 外の道具は一切呼ばない。
//   以前ディスプレイ設定が PowerShell を起動していて、 利用者の
//   セキュリティソフトに「悪意ある行動」 として止められた
//   ([[win32-com-and-os-settings]])。 ここは全部その場で Win32 を呼ぶ。
//
// ── 何を触っているか ────────────────────────────────────────────────
//  マウス感度        SystemParametersInfo(SPI_GET/SETMOUSESPEED)  1〜20
//  ポインター精度    SystemParametersInfo(SPI_GET/SETMOUSE)       加速の有無
//  ホイールの行数    SystemParametersInfo(SPI_GET/SETWHEELSCROLLLINES)
//  ダブルクリック    Get/SetDoubleClickTime()                     ミリ秒
//  スクリーンセーバー SPI_GET/SET SCREENSAVEACTIVE / TIMEOUT / SECURE
//                    + HKCU\Control Panel\Desktop\SCRNSAVE.EXE
//  スリープ/電源     powrprof.dll の Power*ValueIndex (電源プラン)
//
// 電源だけは「今の電源プラン」 を書き換える形になる。 Windows の設定
// アプリと同じやり方なので、 あちらを開けば同じ値が見える。
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:win32_registry/win32_registry.dart';

// ── SystemParametersInfo の種別 ──────────────────────────────────────
const int _spiGetMouse = 0x0003;
const int _spiSetMouse = 0x0004;
const int _spiGetScreenSaveTimeout = 0x000E;
const int _spiSetScreenSaveTimeout = 0x000F;
const int _spiGetScreenSaveActive = 0x0010;
const int _spiSetScreenSaveActive = 0x0011;
const int _spiGetWheelScrollLines = 0x0068;
const int _spiSetWheelScrollLines = 0x0069;
const int _spiGetMouseSpeed = 0x0070;
const int _spiSetMouseSpeed = 0x0071;
const int _spiGetScreenSaveSecure = 0x0076;
const int _spiSetScreenSaveSecure = 0x0077;

/// 変えた事を控えに残す + 他のアプリにも知らせる。
const int _spifUpdateAndSend = 0x01 | 0x02;

typedef _SpiNative = ffi.Int32 Function(
    ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Void>, ffi.Uint32);
typedef _SpiDart = int Function(int, int, ffi.Pointer<ffi.Void>, int);

typedef _GetDoubleClickTimeNative = ffi.Uint32 Function();
typedef _SetDoubleClickTimeNative = ffi.Int32 Function(ffi.Uint32);
typedef _SetDoubleClickTimeDart = int Function(int);

typedef _GetSystemPowerStatusNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Uint8>);
typedef _GetSystemPowerStatusDart = int Function(ffi.Pointer<ffi.Uint8>);

typedef _LocalFreeNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>);
typedef _LocalFreeDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>);

typedef _PowerGetActiveSchemeNative = ffi.Uint32 Function(
    ffi.IntPtr, ffi.Pointer<ffi.Pointer<ffi.Uint8>>);
typedef _PowerGetActiveSchemeDart = int Function(
    int, ffi.Pointer<ffi.Pointer<ffi.Uint8>>);

typedef _PowerReadValueNative = ffi.Uint32 Function(
    ffi.IntPtr,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint32>);
typedef _PowerReadValueDart = int Function(
    int,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint32>);

typedef _PowerWriteValueNative = ffi.Uint32 Function(
    ffi.IntPtr,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Uint32);
typedef _PowerWriteValueDart = int Function(int, ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Uint8>, int);

typedef _PowerSetActiveSchemeNative = ffi.Uint32 Function(
    ffi.IntPtr, ffi.Pointer<ffi.Uint8>);
typedef _PowerSetActiveSchemeDart = int Function(int, ffi.Pointer<ffi.Uint8>);

/// 電源プランの中の場所を表す 16 バイトの札 (GUID)。
///
/// 文字の並びから作れるようにしておく (Windows の資料に載っている形の
/// まま書けるので、 打ち間違いを見つけやすい)。
Uint8List _guid(String s) {
  final hex = s.replaceAll('-', '').replaceAll('{', '').replaceAll('}', '');
  if (hex.length != 32) {
    throw ArgumentError('GUID の長さがおかしい: $s');
  }
  int b(int i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  final out = Uint8List(16);
  // Data1 (4 バイト) と Data2/Data3 (2 バイトずつ) は逆順に入る。
  out[0] = b(3);
  out[1] = b(2);
  out[2] = b(1);
  out[3] = b(0);
  out[4] = b(5);
  out[5] = b(4);
  out[6] = b(7);
  out[7] = b(6);
  for (var i = 8; i < 16; i++) {
    out[i] = b(i);
  }
  return out;
}

/// 画面まわりの入れ物 / 画面を消すまでの時間。
final Uint8List _kVideoSubgroup = _guid('7516b95f-f776-4464-8c53-06167f40cc99');
final Uint8List _kVideoPowerdownTimeout =
    _guid('3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e');

/// スリープの入れ物 / スリープに入るまでの時間。
final Uint8List _kSleepSubgroup = _guid('238C9FA8-0AAD-41ED-83F4-97BE242C8F20');
final Uint8List _kStandbyTimeout = _guid('29f6c1db-86da-48c5-9fdb-f2b67b1f44da');

/// スクリーンセーバーの控えがある場所。
const String _kDesktopKey = r'Control Panel\Desktop';
const String _kScrnSaveValue = 'SCRNSAVE.EXE';

/// マウスの今の状態。
class PcMouseState {
  /// 感度 1〜20 (既定 10)。
  final int speed;

  /// ポインターの精度を高める (= 加速) が入っているか。
  final bool acceleration;

  /// ホイールを 1 段回した時に流れる行数。 -1 = 1 画面ぶん。
  final int wheelLines;

  /// ダブルクリックと見なす間隔 (ミリ秒)。
  final int doubleClickMs;

  const PcMouseState({
    required this.speed,
    required this.acceleration,
    required this.wheelLines,
    required this.doubleClickMs,
  });
}

/// スクリーンセーバーの今の状態。
class PcScreenSaverState {
  /// 動く事になっているか。
  final bool active;

  /// 何も触らずに何秒で始まるか。
  final int timeoutSec;

  /// 戻る時にサインインを求めるか。
  final bool secure;

  /// 今選ばれている .scr の場所 (空 = なし)。
  final String path;

  /// 選べる .scr の一覧 (場所, 表に出す名前)。
  final List<({String path, String name})> choices;

  const PcScreenSaverState({
    required this.active,
    required this.timeoutSec,
    required this.secure,
    required this.path,
    required this.choices,
  });
}

/// スリープ / 画面を消すまでの時間 (秒)。 0 = しない。
class PcPowerState {
  /// この機械に電池があるか (無ければ「バッテリー駆動」 の行は出さない)。
  final bool hasBattery;

  /// 充電中 (AC)。
  final int acDisplayOffSec;
  final int acSleepSec;

  /// バッテリー駆動 (DC)。
  final int dcDisplayOffSec;
  final int dcSleepSec;

  const PcPowerState({
    required this.hasBattery,
    required this.acDisplayOffSec,
    required this.acSleepSec,
    required this.dcDisplayOffSec,
    required this.dcSleepSec,
  });
}

/// パソコン側の設定の読み書き。 全部 static。
class PcSettings {
  PcSettings._();

  static bool get isSupported => Platform.isWindows;

  static ffi.DynamicLibrary? _user32lib;
  static ffi.DynamicLibrary get _user32 =>
      _user32lib ??= ffi.DynamicLibrary.open('user32.dll');
  static ffi.DynamicLibrary? _kernel32lib;
  static ffi.DynamicLibrary get _kernel32 =>
      _kernel32lib ??= ffi.DynamicLibrary.open('kernel32.dll');
  static ffi.DynamicLibrary? _powrproflib;
  static ffi.DynamicLibrary get _powrprof =>
      _powrproflib ??= ffi.DynamicLibrary.open('powrprof.dll');

  static _SpiDart? _spiFn;
  static _SpiDart get _spi => _spiFn ??=
      _user32.lookupFunction<_SpiNative, _SpiDart>('SystemParametersInfoW');

  // ── マウス ────────────────────────────────────────────────────────

  /// 今のマウスの状態を読む。 読めなかった所は Windows の既定で埋める。
  static PcMouseState readMouse() {
    if (!isSupported) {
      return const PcMouseState(
          speed: 10, acceleration: true, wheelLines: 3, doubleClickMs: 500);
    }
    var speed = 10;
    var accel = true;
    var wheel = 3;
    var dbl = 500;
    final buf = pkgffi.calloc<ffi.Int32>(3);
    try {
      if (_spi(_spiGetMouseSpeed, 0, buf.cast(), 0) != 0) {
        speed = buf[0].clamp(1, 20);
      }
      buf[0] = 0;
      buf[1] = 0;
      buf[2] = 0;
      if (_spi(_spiGetMouse, 0, buf.cast(), 0) != 0) {
        // 3 つめが 0 以外なら加速が入っている。
        accel = buf[2] != 0;
      }
      buf[0] = 0;
      if (_spi(_spiGetWheelScrollLines, 0, buf.cast(), 0) != 0) {
        wheel = buf[0];
      }
    } catch (_) {
    } finally {
      pkgffi.calloc.free(buf);
    }
    try {
      final f = _user32.lookupFunction<_GetDoubleClickTimeNative, int Function()>(
          'GetDoubleClickTime');
      final v = f();
      if (v > 0) dbl = v;
    } catch (_) {}
    return PcMouseState(
      speed: speed,
      acceleration: accel,
      wheelLines: wheel,
      doubleClickMs: dbl,
    );
  }

  /// 感度 (1〜20)。 大きいほど速い。
  static bool setMouseSpeed(int speed) {
    if (!isSupported) return false;
    final v = speed.clamp(1, 20);
    try {
      // ★ この種別だけは「値そのもの」 を pvParam の場所に渡す決まり。
      return _spi(_spiSetMouseSpeed, 0, ffi.Pointer<ffi.Void>.fromAddress(v),
              _spifUpdateAndSend) !=
          0;
    } catch (_) {
      return false;
    }
  }

  /// ポインターの精度を高める (= 加速)。
  static bool setMouseAcceleration(bool on) {
    if (!isSupported) return false;
    final buf = pkgffi.calloc<ffi.Int32>(3);
    try {
      // 今の値を読んでから 3 つめ (加速の段) だけ入れ替える。
      if (_spi(_spiGetMouse, 0, buf.cast(), 0) == 0) return false;
      if (on) {
        // Windows の既定の組み合わせ。
        buf[0] = 6;
        buf[1] = 10;
        buf[2] = 1;
      } else {
        buf[0] = 0;
        buf[1] = 0;
        buf[2] = 0;
      }
      return _spi(_spiSetMouse, 0, buf.cast(), _spifUpdateAndSend) != 0;
    } catch (_) {
      return false;
    } finally {
      pkgffi.calloc.free(buf);
    }
  }

  /// ホイール 1 段で流れる行数 (1〜30)。
  static bool setWheelScrollLines(int lines) {
    if (!isSupported) return false;
    final v = lines.clamp(1, 30);
    try {
      return _spi(_spiSetWheelScrollLines, v, ffi.Pointer<ffi.Void>.fromAddress(0),
              _spifUpdateAndSend) !=
          0;
    } catch (_) {
      return false;
    }
  }

  /// ダブルクリックと見なす間隔 (ミリ秒。 100〜900)。
  static bool setDoubleClickTime(int ms) {
    if (!isSupported) return false;
    final v = ms.clamp(100, 900);
    try {
      final f = _user32.lookupFunction<_SetDoubleClickTimeNative,
          _SetDoubleClickTimeDart>('SetDoubleClickTime');
      return f(v) != 0;
    } catch (_) {
      return false;
    }
  }

  // ── スクリーンセーバー ────────────────────────────────────────────

  /// Windows に付いてくる物の、 分かりやすい名前。
  /// 一覧に無い物は、 ファイル名をそのまま出す。
  static const Map<String, String> _kKnownSavers = {
    'bubbles': 'バブル',
    'mystify': 'ブランク線',
    'ribbons': 'リボン',
    'photoscreensaver': '写真',
    'ssText3d': '3D テキスト',
    'sstext3d': '3D テキスト',
    'scrnsave': 'ブランク (真っ暗)',
  };

  static PcScreenSaverState readScreenSaver() {
    if (!isSupported) {
      return const PcScreenSaverState(
          active: false,
          timeoutSec: 600,
          secure: false,
          path: '',
          choices: []);
    }
    var active = false;
    var timeout = 600;
    var secure = false;
    final buf = pkgffi.calloc<ffi.Int32>(1);
    try {
      if (_spi(_spiGetScreenSaveActive, 0, buf.cast(), 0) != 0) {
        active = buf[0] != 0;
      }
      buf[0] = 0;
      if (_spi(_spiGetScreenSaveTimeout, 0, buf.cast(), 0) != 0) {
        timeout = buf[0];
      }
      buf[0] = 0;
      if (_spi(_spiGetScreenSaveSecure, 0, buf.cast(), 0) != 0) {
        secure = buf[0] != 0;
      }
    } catch (_) {
    } finally {
      pkgffi.calloc.free(buf);
    }
    var path = '';
    try {
      final key = Registry.openPath(RegistryHive.currentUser,
          path: _kDesktopKey, desiredAccessRights: AccessRights.readOnly);
      path = key.getValueAsString(_kScrnSaveValue)?.trim() ?? '';
      key.close();
    } catch (_) {}
    return PcScreenSaverState(
      active: active,
      timeoutSec: timeout,
      secure: secure,
      path: path,
      choices: listScreenSavers(),
    );
  }

  /// この機械に入っている .scr を探す。
  static List<({String path, String name})> listScreenSavers() {
    if (!isSupported) return const [];
    final seen = <String, ({String path, String name})>{};
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    for (final dir in [
      Directory('$root\\System32'),
      Directory('$root\\SysWOW64'),
    ]) {
      try {
        if (!dir.existsSync()) continue;
        for (final f in dir.listSync(followLinks: false)) {
          if (f is! File) continue;
          final p = f.path;
          if (!p.toLowerCase().endsWith('.scr')) continue;
          final base = p.split(RegExp(r'[\\/]')).last;
          final stem = base.substring(0, base.length - 4);
          final keyName = stem.toLowerCase();
          if (seen.containsKey(keyName)) continue;
          seen[keyName] = (path: p, name: _kKnownSavers[keyName] ?? stem);
        }
      } catch (_) {}
    }
    final out = seen.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// 動かすかどうか。
  static bool setScreenSaverActive(bool on) {
    if (!isSupported) return false;
    try {
      return _spi(_spiSetScreenSaveActive, on ? 1 : 0,
              ffi.Pointer<ffi.Void>.fromAddress(0), _spifUpdateAndSend) !=
          0;
    } catch (_) {
      return false;
    }
  }

  /// 何秒で始まるか (60〜7200)。
  static bool setScreenSaverTimeout(int sec) {
    if (!isSupported) return false;
    final v = sec.clamp(60, 7200);
    try {
      return _spi(_spiSetScreenSaveTimeout, v,
              ffi.Pointer<ffi.Void>.fromAddress(0), _spifUpdateAndSend) !=
          0;
    } catch (_) {
      return false;
    }
  }

  /// 戻る時にサインインを求めるか。
  static bool setScreenSaverSecure(bool on) {
    if (!isSupported) return false;
    try {
      return _spi(_spiSetScreenSaveSecure, on ? 1 : 0,
              ffi.Pointer<ffi.Void>.fromAddress(0), _spifUpdateAndSend) !=
          0;
    } catch (_) {
      return false;
    }
  }

  /// どの .scr を使うか ([path] が空なら「なし」)。
  ///
  /// 控え (レジストリ) に書いてから、 動かす / 止めるを Win32 で伝える。
  /// 設定アプリと同じ手順なので、 あちらを開いても同じ物が選ばれている。
  static bool setScreenSaverPath(String path) {
    if (!isSupported) return false;
    try {
      final key = Registry.openPath(RegistryHive.currentUser,
          path: _kDesktopKey, desiredAccessRights: AccessRights.allAccess);
      key.createValue(RegistryValue.string(_kScrnSaveValue, path));
      key.close();
    } catch (_) {
      return false;
    }
    // 「なし」 にした時は動かす札も下ろす (そうしないと真っ暗な既定が動く)。
    setScreenSaverActive(path.isNotEmpty);
    return true;
  }

  // ── スリープ / 電源 ──────────────────────────────────────────────

  /// 電池を積んでいるか。
  static bool hasBattery() {
    if (!isSupported) return false;
    final buf = pkgffi.calloc<ffi.Uint8>(12);
    try {
      final f = _kernel32.lookupFunction<_GetSystemPowerStatusNative,
          _GetSystemPowerStatusDart>('GetSystemPowerStatus');
      if (f(buf) == 0) return false;
      // BatteryFlag == 128 は「電池が無い」。
      return buf[1] != 128;
    } catch (_) {
      return false;
    } finally {
      pkgffi.calloc.free(buf);
    }
  }

  /// 今の電源プランの札を借りる。 使い終わったら [_freeScheme] で返す。
  static ffi.Pointer<ffi.Uint8> _activeScheme() {
    final pp = pkgffi.calloc<ffi.Pointer<ffi.Uint8>>();
    try {
      final f = _powrprof.lookupFunction<_PowerGetActiveSchemeNative,
          _PowerGetActiveSchemeDart>('PowerGetActiveScheme');
      if (f(0, pp) != 0) return ffi.nullptr;
      return pp.value;
    } catch (_) {
      return ffi.nullptr;
    } finally {
      pkgffi.calloc.free(pp);
    }
  }

  static void _freeScheme(ffi.Pointer<ffi.Uint8> p) {
    if (p == ffi.nullptr) return;
    try {
      final f = _kernel32
          .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
      f(p.cast());
    } catch (_) {}
  }

  /// 16 バイトの札を、 呼び出しに渡せる形で借りる。
  static ffi.Pointer<ffi.Uint8> _toNative(Uint8List g) {
    final p = pkgffi.calloc<ffi.Uint8>(16);
    for (var i = 0; i < 16; i++) {
      p[i] = g[i];
    }
    return p;
  }

  static PcPowerState readPower() {
    final battery = hasBattery();
    if (!isSupported) {
      return PcPowerState(
        hasBattery: battery,
        acDisplayOffSec: 0,
        acSleepSec: 0,
        dcDisplayOffSec: 0,
        dcSleepSec: 0,
      );
    }
    final scheme = _activeScheme();
    if (scheme == ffi.nullptr) {
      return PcPowerState(
        hasBattery: battery,
        acDisplayOffSec: 0,
        acSleepSec: 0,
        dcDisplayOffSec: 0,
        dcSleepSec: 0,
      );
    }
    final video = _toNative(_kVideoSubgroup);
    final videoTo = _toNative(_kVideoPowerdownTimeout);
    final sleep = _toNative(_kSleepSubgroup);
    final sleepTo = _toNative(_kStandbyTimeout);
    final out = pkgffi.calloc<ffi.Uint32>();
    int read(String fn, ffi.Pointer<ffi.Uint8> sub, ffi.Pointer<ffi.Uint8> st) {
      try {
        final f = _powrprof
            .lookupFunction<_PowerReadValueNative, _PowerReadValueDart>(fn);
        out.value = 0;
        if (f(0, scheme, sub, st, out) != 0) return 0;
        return out.value;
      } catch (_) {
        return 0;
      }
    }

    try {
      return PcPowerState(
        hasBattery: battery,
        acDisplayOffSec: read('PowerReadACValueIndex', video, videoTo),
        acSleepSec: read('PowerReadACValueIndex', sleep, sleepTo),
        dcDisplayOffSec: read('PowerReadDCValueIndex', video, videoTo),
        dcSleepSec: read('PowerReadDCValueIndex', sleep, sleepTo),
      );
    } finally {
      pkgffi.calloc.free(out);
      pkgffi.calloc.free(video);
      pkgffi.calloc.free(videoTo);
      pkgffi.calloc.free(sleep);
      pkgffi.calloc.free(sleepTo);
      _freeScheme(scheme);
    }
  }

  /// 時間を書き込む。
  /// [onBattery] = バッテリー駆動の側、 [display] = 画面を消すまで
  /// (false ならスリープに入るまで)。 [sec] は 0 で「しない」。
  static bool setPowerTimeout({
    required bool onBattery,
    required bool display,
    required int sec,
  }) {
    if (!isSupported) return false;
    final scheme = _activeScheme();
    if (scheme == ffi.nullptr) return false;
    final sub = _toNative(display ? _kVideoSubgroup : _kSleepSubgroup);
    final st = _toNative(display ? _kVideoPowerdownTimeout : _kStandbyTimeout);
    try {
      final fn =
          onBattery ? 'PowerWriteDCValueIndex' : 'PowerWriteACValueIndex';
      final f = _powrprof
          .lookupFunction<_PowerWriteValueNative, _PowerWriteValueDart>(fn);
      if (f(0, scheme, sub, st, sec < 0 ? 0 : sec) != 0) return false;
      // ★ 書いただけでは効かない。 同じプランを入れ直して初めて反映される。
      final act = _powrprof.lookupFunction<_PowerSetActiveSchemeNative,
          _PowerSetActiveSchemeDart>('PowerSetActiveScheme');
      return act(0, scheme) == 0;
    } catch (_) {
      return false;
    } finally {
      pkgffi.calloc.free(sub);
      pkgffi.calloc.free(st);
      _freeScheme(scheme);
    }
  }
}
