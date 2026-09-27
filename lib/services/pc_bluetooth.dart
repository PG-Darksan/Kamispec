// Bluetooth の様子を読む所 (Windows 専用)。
//
// = ユーザー要望「PC 設定の中に bluetooth やオーディオ設定などの選択肢を
//   増やして分けて、 その選択肢を押すと項目が出てくる仕様にして欲しい」。
//
// ★ 何ができて、 何ができないか:
//   ・アダプター (無線機) の有無と名前は `BluetoothGetRadioInfo` で読める。
//   ・登録済み / 接続中の機器一覧は `BluetoothFindFirstDevice` で読める。
//     `fIssueInquiry: false` なので**電波を出して探しに行かない** (周りの
//     知らない機器は出ない)。 探しに行くと数秒止まるため。
//   ・**入 / 切の切り替えは、 この API には無い** (WinRT の
//     `Windows.Devices.Radios` が要る。 win32 5.15.0 には入っていない)。
//     なので切り替えは Windows の設定を開いて任せる
//     ([openWindowsBluetoothSettings])。
//   ・隠した powershell は撃たない ([[no-hidden-powershell-from-app]] の
//     覚書。 `ShellExecute` で `ms-settings:` を開くだけ)。
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart' as w32;

/// Bluetooth のアダプター (無線機) 1 台。
class PcBluetoothRadio {
  final String name;

  const PcBluetoothRadio({required this.name});
}

/// 登録済みの機器 1 台。
class PcBluetoothDevice {
  final String name;

  /// 今つながっているか。
  final bool connected;

  /// この PC に登録 (ペアリング) 済みか。
  final bool paired;

  const PcBluetoothDevice({
    required this.name,
    required this.connected,
    required this.paired,
  });
}

/// 読み取った Bluetooth の様子。
class PcBluetoothState {
  /// アダプターがあるか (無ければ項目そのものを出さない)。
  final bool hasRadio;

  final List<PcBluetoothRadio> radios;
  final List<PcBluetoothDevice> devices;

  const PcBluetoothState({
    required this.hasRadio,
    required this.radios,
    required this.devices,
  });

  static const PcBluetoothState none =
      PcBluetoothState(hasRadio: false, radios: [], devices: []);
}

class PcBluetooth {
  PcBluetooth._();

  static bool get isSupported => !kIsWeb && Platform.isWindows;

  /// アダプターと登録済み機器をまとめて読む。
  ///
  /// ★ 電波は出さない (周りを探しに行かない) ので、 待たされない。
  static PcBluetoothState read() {
    if (!isSupported) return PcBluetoothState.none;
    final radios = <PcBluetoothRadio>[];
    final devices = <PcBluetoothDevice>[];
    final findParams = calloc<w32.BLUETOOTH_FIND_RADIO_PARAMS>();
    final radioHandle = calloc<ffi.IntPtr>();
    final radioInfo = calloc<w32.BLUETOOTH_RADIO_INFO>();
    var find = 0;
    try {
      findParams.ref.dwSize = ffi.sizeOf<w32.BLUETOOTH_FIND_RADIO_PARAMS>();
      find = w32.BluetoothFindFirstRadio(findParams, radioHandle);
      while (find != 0) {
        final h = radioHandle.value;
        radioInfo.ref.dwSize = ffi.sizeOf<w32.BLUETOOTH_RADIO_INFO>();
        if (w32.BluetoothGetRadioInfo(h, radioInfo) == 0) {
          final n = radioInfo.ref.szName.trim();
          radios.add(PcBluetoothRadio(name: n.isEmpty ? 'Bluetooth' : n));
        } else {
          radios.add(const PcBluetoothRadio(name: 'Bluetooth'));
        }
        w32.CloseHandle(h);
        if (w32.BluetoothFindNextRadio(find, radioHandle) == 0) break;
      }
    } catch (_) {
      // 見付からない / 呼べない機械では「無い」 扱い。
    } finally {
      if (find != 0) {
        try {
          w32.BluetoothFindRadioClose(find);
        } catch (_) {}
      }
      calloc.free(radioInfo);
      calloc.free(radioHandle);
      calloc.free(findParams);
    }
    if (radios.isEmpty) return PcBluetoothState.none;

    final search = calloc<w32.BLUETOOTH_DEVICE_SEARCH_PARAMS>();
    final info = calloc<w32.BLUETOOTH_DEVICE_INFO>();
    var dfind = 0;
    try {
      search.ref
        ..dwSize = ffi.sizeOf<w32.BLUETOOTH_DEVICE_SEARCH_PARAMS>()
        ..fReturnAuthenticated = 1
        ..fReturnRemembered = 1
        ..fReturnUnknown = 0
        ..fReturnConnected = 1
        // ★ 0 = 電波を出して探しに行かない。 1 にすると
        //   cTimeoutMultiplier × 1.28 秒ぶん画面が止まる。
        ..fIssueInquiry = 0
        ..cTimeoutMultiplier = 0
        ..hRadio = 0;
      info.ref.dwSize = ffi.sizeOf<w32.BLUETOOTH_DEVICE_INFO>();
      dfind = w32.BluetoothFindFirstDevice(search, info);
      while (dfind != 0) {
        final n = info.ref.szName.trim();
        devices.add(PcBluetoothDevice(
          name: n.isEmpty ? '(名前なし)' : n,
          connected: info.ref.fConnected != 0,
          paired: info.ref.fAuthenticated != 0 || info.ref.fRemembered != 0,
        ));
        if (devices.length >= 64) break; // 出し過ぎない
        info.ref.dwSize = ffi.sizeOf<w32.BLUETOOTH_DEVICE_INFO>();
        if (w32.BluetoothFindNextDevice(dfind, info) == 0) break;
      }
    } catch (_) {
      // 機器一覧だけ取れない事はある。 アダプターの行は出す。
    } finally {
      if (dfind != 0) {
        try {
          w32.BluetoothFindDeviceClose(dfind);
        } catch (_) {}
      }
      calloc.free(info);
      calloc.free(search);
    }
    // つながっている物を上に、 その中は名前順。
    devices.sort((a, b) {
      if (a.connected != b.connected) return a.connected ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return PcBluetoothState(
        hasRadio: true, radios: radios, devices: devices);
  }

  /// Windows の Bluetooth 設定を開く (入 / 切と登録はここに任せる)。
  static bool openWindowsBluetoothSettings() {
    if (!isSupported) return false;
    final verb = 'open'.toNativeUtf16();
    final target = 'ms-settings:bluetooth'.toNativeUtf16();
    try {
      // 戻り値は 32 より大きければ成功 (ShellExecute の決まり)。
      final r = w32.ShellExecute(
          0, verb, target, ffi.nullptr, ffi.nullptr, 1 /* SW_SHOWNORMAL */);
      return r > 32;
    } catch (_) {
      return false;
    } finally {
      calloc.free(verb);
      calloc.free(target);
    }
  }
}
