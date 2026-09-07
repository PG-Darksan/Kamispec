// 使い捨て: WMI (root\WMI) を COM で叩く手順を 1 段ずつ確かめる。
//   dart run tool/wmi_brightness_probe.dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

void say(Object? o) {
  stdout.writeln(o);
}

void rel(IUnknown? o) {
  if (o == null) return;
  try {
    o.release();
  } catch (_) {}
  try {
    calloc.free(o.ptr);
  } catch (_) {}
}

void main() {
  say('1. CoInitializeEx');
  final hr0 = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  say('   hr=0x${hr0.toRadixString(16)}');

  say('2. WbemLocator.createInstance');
  IWbemLocator locator;
  try {
    locator = WbemLocator.createInstance();
  } catch (e) {
    say('   失敗: $e');
    return;
  }
  say('   ok');

  say('3. connectServer(root\\WMI)');
  final svcPtr = calloc<COMObject>();
  final nsRaw = r'root\WMI'.toNativeUtf16();
  final ns = SysAllocString(nsRaw);
  final hr = locator.connectServer(
      ns, nullptr, nullptr, nullptr, 0, nullptr, nullptr, svcPtr.cast());
  say('   hr=0x${hr.toRadixString(16)}');
  SysFreeString(ns);
  calloc.free(nsRaw);
  if (FAILED(hr)) {
    calloc.free(svcPtr);
    rel(locator);
    return;
  }
  final svc = IWbemServices(svcPtr);
  rel(locator);

  say('4. CoSetProxyBlanket');
  try {
    // ★ 渡すのは「相手そのもの」。 受け皿の場所ではない
    //   (受け皿を渡すと即座に落ちる)。
    final b = CoSetProxyBlanket(
        svcPtr.ref.lpVtbl.cast(), 10, 0, nullptr, 3, 3, nullptr, 0);
    say('   hr=0x${b.toRadixString(16)}');
  } catch (e) {
    say('   失敗: $e');
  }

  say('5. execQuery(WmiMonitorBrightness)');
  final langRaw = 'WQL'.toNativeUtf16();
  final qRaw = 'SELECT * FROM WmiMonitorBrightness'.toNativeUtf16();
  final lang = SysAllocString(langRaw);
  final q = SysAllocString(qRaw);
  final enumPtr = calloc<COMObject>();
  final hr2 = svc.execQuery(lang, q, 0x30, nullptr, enumPtr.cast());
  say('   hr=0x${hr2.toRadixString(16)}');
  SysFreeString(lang);
  SysFreeString(q);
  calloc.free(langRaw);
  calloc.free(qRaw);
  if (FAILED(hr2)) {
    calloc.free(enumPtr);
    rel(svc);
    return;
  }
  final en = IEnumWbemClassObject(enumPtr);

  say('6. next');
  final objPtr = calloc<COMObject>();
  final got = calloc<Uint32>();
  final hr3 = en.next(5000, 1, objPtr.cast(), got);
  say('   hr=0x${hr3.toRadixString(16)} got=${got.value}');
  if (FAILED(hr3) || got.value == 0) {
    calloc.free(objPtr);
    calloc.free(got);
    rel(en);
    rel(svc);
    return;
  }
  final obj = IWbemClassObject(objPtr);

  say('7. get(CurrentBrightness)');
  final v = calloc<VARIANT>();
  final name = 'CurrentBrightness'.toNativeUtf16();
  final hr4 = obj.get(name, 0, v, nullptr, nullptr);
  say('   hr=0x${hr4.toRadixString(16)} vt=${v.ref.vt} '
      'bVal=${v.ref.bVal} lVal=${v.ref.lVal}');
  final v0 = v.ref.vt == VT_UI1 ? v.ref.bVal : v.ref.lVal;
  calloc.free(name);
  calloc.free(v);

  final before = v0;
  calloc.free(got);
  rel(obj);
  rel(en);

  // ── 書き込み ──
  say('8. WmiMonitorBrightnessMethods を取る');
  final mRaw = 'SELECT * FROM WmiMonitorBrightnessMethods'.toNativeUtf16();
  final mB = SysAllocString(mRaw);
  final langB = SysAllocString('WQL'.toNativeUtf16());
  final en2Ptr = calloc<COMObject>();
  final hr5 = svc.execQuery(langB, mB, 0x30, nullptr, en2Ptr.cast());
  say('   hr=0x${hr5.toRadixString(16)}');
  final en2 = IEnumWbemClassObject(en2Ptr);
  final o2Ptr = calloc<COMObject>();
  final got2 = calloc<Uint32>();
  final hr6 = en2.next(5000, 1, o2Ptr.cast(), got2);
  say('   next hr=0x${hr6.toRadixString(16)} got=${got2.value}');
  final inst = IWbemClassObject(o2Ptr);

  say('9. __PATH');
  final pv = calloc<VARIANT>();
  final pn = '__PATH'.toNativeUtf16();
  final hr7 = inst.get(pn, 0, pv, nullptr, nullptr);
  final objPath = pv.ref.bstrVal == nullptr ? '' : pv.ref.bstrVal.toDartString();
  say('   hr=0x${hr7.toRadixString(16)} path=$objPath');
  calloc.free(pn);
  calloc.free(pv);

  say('10. getObject + getMethod + spawnInstance');
  final clsPtr = calloc<COMObject>();
  final clsB = SysAllocString('WmiMonitorBrightnessMethods'.toNativeUtf16());
  final hr8 = svc.getObject(clsB, 0, nullptr, clsPtr.cast(), nullptr);
  say('   getObject hr=0x${hr8.toRadixString(16)}');
  final cls = IWbemClassObject(clsPtr);
  final inPtr = calloc<COMObject>();
  final mth = 'WmiSetBrightness'.toNativeUtf16();
  final hr9 = cls.getMethod(mth, 0, inPtr.cast(), nullptr);
  say('   getMethod hr=0x${hr9.toRadixString(16)}');
  final inParams = IWbemClassObject(inPtr);
  final instPtr = calloc<COMObject>();
  final hr10 = inParams.spawnInstance(0, instPtr.cast());
  say('   spawnInstance hr=0x${hr10.toRadixString(16)}');
  final inInst = IWbemClassObject(instPtr);

  say('11. put + execMethod');
  bool put(String name, int value) {
    final vv = calloc<VARIANT>();
    final nn = name.toNativeUtf16();
    try {
      vv.ref.vt = VT_I4;
      vv.ref.lVal = value;
      final h = inInst.put(nn, 0, vv, 0);
      say('   put $name=$value hr=0x${h.toRadixString(16)}');
      return !FAILED(h);
    } finally {
      calloc.free(nn);
      calloc.free(vv);
    }
  }

  final target = before >= 99 ? before - 1 : before + 1;
  put('Timeout', 0);
  put('Brightness', target);
  final pathB = SysAllocString(objPath.toNativeUtf16());
  final methodB = SysAllocString('WmiSetBrightness'.toNativeUtf16());
  final hr11 = svc.execMethod(pathB, methodB, 0, nullptr,
      inInst.ptr.ref.lpVtbl.cast(), nullptr, nullptr);
  say('   execMethod($target%) hr=0x${hr11.toRadixString(16)}');

  say('12. 戻す');
  put('Brightness', before);
  final hr12 = svc.execMethod(pathB, methodB, 0, nullptr,
      inInst.ptr.ref.lpVtbl.cast(), nullptr, nullptr);
  say('   execMethod($before%) hr=0x${hr12.toRadixString(16)}');

  say('13. 後始末');
  SysFreeString(pathB);
  SysFreeString(methodB);
  SysFreeString(mB);
  SysFreeString(langB);
  SysFreeString(clsB);
  calloc.free(got2);
  rel(inInst);
  rel(inParams);
  rel(cls);
  rel(inst);
  rel(en2);
  rel(svc);
  say('   done');
}
