import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart' as w32;

/// 音声の出力先 (Windows の既定の再生デバイス) をアプリから切り替える。
///
/// = ユーザー要望「音声を接続したサブモニターから出すのか、 メインモニター
///   から出すのかなどの設定もアプリからできると便利」。
///
/// 一覧は MMDevice API (公開 API)、 切り替えは IPolicyConfig (Windows の
/// サウンド設定が内部で使っている COM。 公開されていないが Windows 7 から
/// 変わっておらず、 切り替えソフトは皆これを使う)。
///
/// ★ COM は画面のスレッドで呼ばない (= 固まる原因。 home_shortcut_service
///   と同じ作法で Isolate.run + 時間切れ)。
class AudioOutput {
  AudioOutput._();

  static bool get isSupported {
    try {
      return !kIsWeb && Platform.isWindows;
    } catch (_) {
      return false;
    }
  }

  /// 再生デバイスの一覧 (今の既定に印つき)。 失敗したら空。
  static Future<List<({String id, String name, bool isDefault})>>
      listDevices() async {
    if (!isSupported) return const [];
    try {
      return await Isolate.run(_listDevices).timeout(
          const Duration(seconds: 12),
          onTimeout: () => const []);
    } catch (_) {
      return const [];
    }
  }

  /// 既定の再生デバイスを切り替える (通常・メディア・通話の 3 役まとめて)。
  static Future<bool> setDefault(String deviceId) async {
    if (!isSupported) return false;
    try {
      return await Isolate.run(() => _setDefault(deviceId)).timeout(
          const Duration(seconds: 12),
          onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  /// 今の音量 (0.0〜1.0)。 読めなければ null
  /// (= ユーザー要望: 音声出力の大きさも設定できるように)。
  static Future<double?> getVolume() async {
    if (!isSupported) return null;
    try {
      return await Isolate.run(_getVolume)
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  /// 音量を変える (0.0〜1.0)。 変えられたら true。
  static Future<bool> setVolume(double v) async {
    if (!isSupported) return false;
    final x = v.clamp(0.0, 1.0).toDouble();
    try {
      return await Isolate.run(() => _setVolume(x))
          .timeout(const Duration(seconds: 8), onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  /// 音を 1 つ鳴らして、 今の出力先と大きさを耳で確かめられるようにする
  /// (= ユーザー要望: 音声出力を変えた時は音が出るようにして欲しい)。
  ///
  /// Windows の「システム通知」 の音を非同期で鳴らすだけ。 出す先は既定の
  /// 再生デバイスなので、 切り替えた直後に鳴らせば、 どこから出るかが
  /// そのまま分かる。
  static void playTestSound() {
    if (!isSupported) return;
    try {
      final winmm = DynamicLibrary.open('winmm.dll');
      final playSound = winmm.lookupFunction<
          Int32 Function(Pointer<Utf16>, IntPtr, Uint32),
          int Function(Pointer<Utf16>, int, int)>('PlaySoundW');
      final name = 'SystemAsterisk'.toNativeUtf16();
      try {
        // SND_ALIAS (0x00010000) | SND_ASYNC (0x1) | SND_NODEFAULT (0x2)
        playSound(name, 0, 0x00010000 | 0x1 | 0x2);
      } finally {
        calloc.free(name);
      }
    } catch (e) {
      debugPrint('確認の音を鳴らせませんでした: $e');
    }
  }

  /// 消音の入り切り。 読めなければ null。
  static Future<bool?> getMuted() async {
    if (!isSupported) return null;
    try {
      return await Isolate.run(_getMuted)
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> setMuted(bool m) async {
    if (!isSupported) return false;
    try {
      return await Isolate.run(() => _setMuted(m))
          .timeout(const Duration(seconds: 8), onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }
}

// ── 既定の再生デバイスの音量 (IAudioEndpointVolume) ────────────────
//
// win32 パッケージにこのインターフェイスの包みは無いので、 表 (vtable) の
// 何番目かを自分で数えて呼ぶ。 並びは Windows SDK の endpointvolume.h の
// 宣言順で、 IUnknown の 3 つ (QueryInterface / AddRef / Release) の後に
//   3 RegisterControlChangeNotify   4 UnregisterControlChangeNotify
//   5 GetChannelCount               6 SetMasterVolumeLevel
//   7 SetMasterVolumeLevelScalar    8 GetMasterVolumeLevel
//   9 GetMasterVolumeLevelScalar   10 SetChannelVolumeLevel
//   ...                            14 SetMute   15 GetMute
// と続く。
//
// ★ 番号を 1 つでも間違えると、 別の機械語を関数として呼んでプロセスごと
//   落ちる。 触る時は必ず実機で読み書きして確かめること。
const String _kIidAudioEndpointVolume =
    '{5CDF2C82-841E-4546-9722-0CF74078229A}';

const int _kSlotSetMasterScalar = 7;
const int _kSlotGetMasterScalar = 9;
const int _kSlotSetMute = 14;
const int _kSlotGetMute = 15;

/// 既定の再生デバイスの IAudioEndpointVolume を開いて [body] に渡す。
/// 開けなければ [body] を呼ばずに null を返す。
T? _withEndpointVolume<T>(T Function(Pointer<w32.COMObject> vol) body) {
  final init = w32.CoInitializeEx(nullptr, w32.COINIT_APARTMENTTHREADED);
  final needUninit = init == w32.S_OK || init == w32.S_FALSE;
  w32.MMDeviceEnumerator? enumr;
  final ppDev = calloc<w32.COMObject>();
  final ppVol = calloc<w32.COMObject>();
  final iid = w32.GUIDFromString(_kIidAudioEndpointVolume);
  try {
    enumr = w32.MMDeviceEnumerator.createInstance();
    if (enumr.getDefaultAudioEndpoint(
            w32.eRender, w32.eMultimedia, ppDev.cast()) !=
        w32.S_OK) {
      return null;
    }
    final dev = w32.IMMDevice(ppDev);
    try {
      if (dev.activate(iid, w32.CLSCTX_ALL, nullptr, ppVol.cast()) !=
          w32.S_OK) {
        return null;
      }
      if (ppVol.ref.isNull) return null;
      return body(ppVol);
    } finally {
      // 中身を離してから入れ物を返す。
      try {
        if (!ppVol.ref.isNull) {
          w32.IUnknown(ppVol).release();
        }
      } catch (_) {}
      dev.release();
    }
  } catch (e) {
    debugPrint('音量の取り出しに失敗: $e');
    return null;
  } finally {
    calloc.free(iid);
    calloc.free(ppVol);
    calloc.free(ppDev);
    try {
      enumr?.release();
    } catch (_) {}
    if (needUninit) w32.CoUninitialize();
  }
}

double? _getVolume() => _withEndpointVolume<double?>((vol) {
      final p = calloc<Float>();
      try {
        final fn = (vol.ref.vtable + _kSlotGetMasterScalar)
            .cast<Pointer<NativeFunction<Int32 Function(Pointer, Pointer<Float>)>>>()
            .value
            .asFunction<int Function(Pointer, Pointer<Float>)>();
        if (fn(vol.ref.lpVtbl, p) != w32.S_OK) return null;
        return p.value.toDouble();
      } finally {
        calloc.free(p);
      }
    });

bool _setVolume(double v) =>
    _withEndpointVolume<bool>((vol) {
      final fn = (vol.ref.vtable + _kSlotSetMasterScalar)
          .cast<Pointer<NativeFunction<Int32 Function(Pointer, Float, Pointer<w32.GUID>)>>>()
          .value
          .asFunction<int Function(Pointer, double, Pointer<w32.GUID>)>();
      return fn(vol.ref.lpVtbl, v, nullptr) == w32.S_OK;
    }) ??
    false;

bool? _getMuted() => _withEndpointVolume<bool?>((vol) {
      final p = calloc<Int32>();
      try {
        final fn = (vol.ref.vtable + _kSlotGetMute)
            .cast<Pointer<NativeFunction<Int32 Function(Pointer, Pointer<Int32>)>>>()
            .value
            .asFunction<int Function(Pointer, Pointer<Int32>)>();
        if (fn(vol.ref.lpVtbl, p) != w32.S_OK) return null;
        return p.value != 0;
      } finally {
        calloc.free(p);
      }
    });

bool _setMuted(bool m) =>
    _withEndpointVolume<bool>((vol) {
      final fn = (vol.ref.vtable + _kSlotSetMute)
          .cast<Pointer<NativeFunction<Int32 Function(Pointer, Int32, Pointer<w32.GUID>)>>>()
          .value
          .asFunction<int Function(Pointer, int, Pointer<w32.GUID>)>();
      return fn(vol.ref.lpVtbl, m ? 1 : 0, nullptr) == w32.S_OK;
    }) ??
    false;

List<({String id, String name, bool isDefault})> _listDevices() {
  final init = w32.CoInitializeEx(nullptr, w32.COINIT_APARTMENTTHREADED);
  final needUninit = init == w32.S_OK || init == w32.S_FALSE;
  final out = <({String id, String name, bool isDefault})>[];
  w32.MMDeviceEnumerator? enumr;
  try {
    enumr = w32.MMDeviceEnumerator.createInstance();

    String readId(w32.IMMDevice dev) {
      final pId = calloc<Pointer<Utf16>>();
      try {
        if (dev.getId(pId) != w32.S_OK) return '';
        final v = pId.value.toDartString();
        w32.CoTaskMemFree(pId.value.cast());
        return v;
      } finally {
        calloc.free(pId);
      }
    }

    // 今の既定 (メディア役) の id。
    // ★ win32 の COM 包みは「インターフェイスポインタを入れた入れ物
    //   (Pointer<COMObject>)」 を受け取る作法 (createFromID と同じ)。
    //   生のポインタを渡すと 1 段ずれて機械語を関数として呼んでしまい、
    //   プロセスごと落ちる (= 点検で判明)。
    var defId = '';
    final ppDef = calloc<w32.COMObject>();
    try {
      if (enumr.getDefaultAudioEndpoint(
              w32.eRender, w32.eMultimedia, ppDef.cast()) ==
          w32.S_OK) {
        final dev = w32.IMMDevice(ppDef);
        defId = readId(dev);
        dev.release();
      }
    } finally {
      calloc.free(ppDef);
    }

    final ppCol = calloc<w32.COMObject>();
    try {
      if (enumr.enumAudioEndpoints(
              w32.eRender, w32.DEVICE_STATE_ACTIVE, ppCol.cast()) !=
          w32.S_OK) {
        return out;
      }
      final col = w32.IMMDeviceCollection(ppCol);
      final pCount = calloc<Uint32>();
      try {
        if (col.getCount(pCount) != w32.S_OK) return out;
        for (var i = 0; i < pCount.value; i++) {
          final ppDev = calloc<w32.COMObject>();
          try {
            if (col.item(i, ppDev.cast()) != w32.S_OK) continue;
            final dev = w32.IMMDevice(ppDev);
            final id = readId(dev);
            var name = id;
            final ppStore = calloc<w32.COMObject>();
            try {
              if (dev.openPropertyStore(w32.STGM_READ, ppStore.cast()) ==
                  w32.S_OK) {
                final store = w32.IPropertyStore(ppStore);
                final key = w32.PROPERTYKEY.Device_FriendlyName();
                final pv = calloc<w32.PROPVARIANT>();
                try {
                  if (store.getValue(key, pv) == w32.S_OK &&
                      pv.ref.vt == w32.VT_LPWSTR) {
                    name = pv.ref.pwszVal.toDartString();
                  }
                } finally {
                  w32.PropVariantClear(pv);
                  calloc.free(pv);
                  calloc.free(key);
                }
                store.release();
              }
            } finally {
              calloc.free(ppStore);
            }
            dev.release();
            if (id.isNotEmpty) {
              out.add((id: id, name: name, isDefault: id == defId));
            }
          } finally {
            calloc.free(ppDev);
          }
        }
      } finally {
        calloc.free(pCount);
      }
      col.release();
    } finally {
      calloc.free(ppCol);
    }
  } catch (_) {
    // 失敗はそのまま空で返す。
  } finally {
    try {
      enumr?.release();
    } catch (_) {}
    if (needUninit) w32.CoUninitialize();
  }
  return out;
}

bool _setDefault(String deviceId) {
  final init = w32.CoInitializeEx(nullptr, w32.COINIT_APARTMENTTHREADED);
  final needUninit = init == w32.S_OK || init == w32.S_FALSE;
  final idP = deviceId.toNativeUtf16();
  Pointer<w32.COMObject>? obj;
  try {
    // IPolicyConfig (公開されていない COM)。
    obj = w32.COMObject.createFromID(
        '{870af99c-171d-4f9e-af0d-e63df40c2bc9}', // CLSID_PolicyConfigClient
        '{f8679f50-850a-41cf-9c72-430f290290c8}'); // IID_IPolicyConfig

    // SetDefaultEndpoint は vtable の 13 番目
    // (IUnknown 0-2, GetMixFormat 3, ... SetPropertyValue 12)。
    int call(int role) => (obj!.ref.vtable + 13)
        .cast<
            Pointer<
                NativeFunction<
                    Int32 Function(Pointer, Pointer<Utf16>, Int32)>>>()
        .value
        .asFunction<int Function(Pointer, Pointer<Utf16>, int)>()(
            obj.ref.lpVtbl, idP, role);

    var ok = true;
    // 0=通常 (eConsole) / 1=メディア (eMultimedia) / 2=通話 (eCommunications)
    for (final role in const [0, 1, 2]) {
      if (call(role) != w32.S_OK) ok = false;
    }
    return ok;
  } catch (_) {
    return false;
  } finally {
    try {
      if (obj != null) {
        w32.IUnknown(obj).release();
        calloc.free(obj);
      }
    } catch (_) {}
    calloc.free(idP);
    if (needUninit) w32.CoUninitialize();
  }
}
