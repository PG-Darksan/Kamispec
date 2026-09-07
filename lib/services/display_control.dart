// ディスプレイの「拡大率」 と「壁紙」 を、 アプリから触るための道具
// (= ユーザー要望: ディスプレイ設定でメインモニター / サブモニターの画面
//  拡大率を操作したい。 壁紙も設定できるように)。
//
// Windows 専用。 他の OS では何も持っていない事にして黙って諦める。
//
// ── 拡大率 ─────────────────────────────────────────────────────────
// Windows の「拡大縮小 (100% / 125% …)」 は、 表向きの API が無い。
// 設定アプリ自身が使っている `DisplayConfigGetDeviceInfo` /
// `DisplayConfigSetDeviceInfo` の**文書化されていない**種別
// (-3 = 取得 / -4 = 設定) を叩く。 昔から変わっておらず、 界隈の道具は
// どれもこれを使っている。 それでも表に出ていない物なので、
//   ・取れた最小〜最大の範囲の中だけを選ばせる (勝手な値は入れない)
//   ・失敗しても黙って false を返し、 画面には「変えられなかった」 と出す
// という守りを付けてある。
//
// ── 壁紙 ───────────────────────────────────────────────────────────
// こちらは表向きの COM (IDesktopWallpaper、 Windows 8 以降)。
// モニターごとに別の絵を貼れる。
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter/foundation.dart';

/// 1 台ぶんの拡大率の情報。
class MonitorScale {
  /// 画面の左上の位置と大きさ (アプリ側の並びと突き合わせるのに使う)。
  final int left;
  final int top;
  final int width;
  final int height;

  /// 今の拡大率 (%)。
  final int current;

  /// 選べる拡大率 (%) の一覧。 少ない順。
  final List<int> choices;

  /// Windows のおすすめ (= 「推奨」 と出る値)。
  final int recommended;

  /// 設定に使う覚え書き (アダプター LUID と source id)。
  final int adapterLow;
  final int adapterHigh;
  final int sourceId;

  const MonitorScale({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.current,
    required this.choices,
    required this.recommended,
    required this.adapterLow,
    required this.adapterHigh,
    required this.sourceId,
  });
}

/// 1 台ぶんの壁紙の宛先 (IDesktopWallpaper の monitor id)。
class WallpaperMonitor {
  final String id;
  final int left;
  final int top;
  final int width;
  final int height;
  final String? currentPath;
  const WallpaperMonitor({
    required this.id,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.currentPath,
  });
}

/// 壁紙の並べ方。 IDesktopWallpaper の DESKTOP_WALLPAPER_POSITION と同じ番号。
enum WallpaperFit {
  center(0),
  tile(1),
  stretch(2),
  fit(3),
  fill(4),
  span(5);

  const WallpaperFit(this.value);
  final int value;
}

class DisplayControl {
  DisplayControl._();

  static bool get isSupported => !kIsWeb && Platform.isWindows;

  /// Windows が使う拡大率の並び。 設定に渡すのは「おすすめからの差」 なので、
  /// この並びの番号で数える。
  static const List<int> _dpiSteps = [
    100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500
  ];

  /// まだ繋いでいない画面ぶんに出す、 よく使う拡大率
  /// (= ユーザー要望: 繋いでいない時でも予め決めておけるように)。
  /// 本物が繋がれば、 その画面が返す本当の選択肢に差し替わる。
  ///
  /// ★ 225% / 250% までは出さない (= ユーザー要望: サブモニターだけ 250% まで
  ///   選べるのはおかしい)。 今ある画面が返す選択肢が使えない時の予備なので、
  ///   ふつうの画面が出す範囲に揃えておく。
  static const List<int> commonScales = [100, 125, 150, 175, 200];

  // ── user32 の入口 ──────────────────────────────────────────────
  static ffi.DynamicLibrary get _user32 =>
      ffi.DynamicLibrary.open('user32.dll');

  /// 今つながっている画面の拡大率を調べる。 取れない時は空。
  static List<MonitorScale> listScales() {
    if (!isSupported) return const [];
    try {
      return _listScales();
    } catch (e) {
      debugPrint('拡大率の取得に失敗: $e');
      return const [];
    }
  }

  static List<MonitorScale> _listScales() {
    final u = _user32;
    final getSizes = u.lookupFunction<
        ffi.Int32 Function(ffi.Uint32, ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>),
        int Function(int, ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint32>)>('GetDisplayConfigBufferSizes');
    final query = u.lookupFunction<
        ffi.Int32 Function(
            ffi.Uint32,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Void>),
        int Function(
            int,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Uint32>,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Void>)>('QueryDisplayConfig');
    final getInfo = u.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Uint8>),
        int Function(ffi.Pointer<ffi.Uint8>)>('DisplayConfigGetDeviceInfo');

    const qdcOnlyActivePaths = 0x00000002;
    const pathSize = 72; // DISPLAYCONFIG_PATH_INFO (x64)
    const modeSize = 64; // DISPLAYCONFIG_MODE_INFO (x64)

    final nPath = pkgffi.calloc<ffi.Uint32>();
    final nMode = pkgffi.calloc<ffi.Uint32>();
    ffi.Pointer<ffi.Uint8>? paths;
    ffi.Pointer<ffi.Uint8>? modes;
    final req = pkgffi.calloc<ffi.Uint8>(32); // GET は 32 バイト
    try {
      if (getSizes(qdcOnlyActivePaths, nPath, nMode) != 0) return const [];
      final pc = nPath.value, mc = nMode.value;
      if (pc == 0) return const [];
      paths = pkgffi.calloc<ffi.Uint8>(pathSize * pc);
      modes = pkgffi.calloc<ffi.Uint8>(modeSize * mc);
      if (query(qdcOnlyActivePaths, nPath, paths, nMode, modes, ffi.nullptr) !=
          0) {
        return const [];
      }
      final out = <MonitorScale>[];
      final seen = <String>{};
      final pathBytes = paths.asTypedList(pathSize * pc).buffer.asByteData();
      final modeBytes = modes.asTypedList(modeSize * mc).buffer.asByteData();
      for (var i = 0; i < nPath.value; i++) {
        final base = i * pathSize;
        // sourceInfo: LUID adapterId(0,8) / UINT32 id(8) / UINT32 modeIdx(12)
        final adapterLow = pathBytes.getUint32(base + 0, Endian.little);
        final adapterHigh = pathBytes.getInt32(base + 4, Endian.little);
        final sourceId = pathBytes.getUint32(base + 8, Endian.little);
        final modeIdx = pathBytes.getUint32(base + 12, Endian.little);
        final key = '$adapterLow:$adapterHigh:$sourceId';
        if (!seen.add(key)) continue; // 同じ画面が複製で 2 本来る事がある
        // 位置と大きさ (source mode)。 取れない時は 0 のまま。
        var left = 0, top = 0, w = 0, h = 0;
        if (modeIdx != 0xFFFFFFFF && modeIdx < nMode.value) {
          final mb = modeIdx * modeSize;
          final infoType = modeBytes.getUint32(mb + 0, Endian.little);
          if (infoType == 1) {
            // DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE
            w = modeBytes.getUint32(mb + 16, Endian.little);
            h = modeBytes.getUint32(mb + 20, Endian.little);
            left = modeBytes.getInt32(mb + 28, Endian.little);
            top = modeBytes.getInt32(mb + 32, Endian.little);
          }
        }
        // ── 拡大率の取得 (種別 -3) ──
        //   header: type(0,4) size(4,4) adapterId(8,8) id(16,4)
        //   本体  : min(20,4) cur(24,4) max(28,4)
        final rb = req.asTypedList(32).buffer.asByteData();
        for (var k = 0; k < 32; k++) {
          req[k] = 0;
        }
        rb.setInt32(0, -3, Endian.little);
        rb.setUint32(4, 32, Endian.little);
        rb.setUint32(8, adapterLow, Endian.little);
        rb.setInt32(12, adapterHigh, Endian.little);
        rb.setUint32(16, sourceId, Endian.little);
        if (getInfo(req) != 0) continue;
        final minRel = rb.getInt32(20, Endian.little);
        final curRel = rb.getInt32(24, Endian.little);
        final maxRel = rb.getInt32(28, Endian.little);
        // おすすめの番号 = -min (min は必ず 0 以下)。
        final recIdx = -minRel;
        if (recIdx < 0 || recIdx >= _dpiSteps.length) continue;
        final curIdx = recIdx + curRel;
        var maxIdx = recIdx + maxRel;
        if (maxIdx >= _dpiSteps.length) maxIdx = _dpiSteps.length - 1;
        if (curIdx < 0 || curIdx >= _dpiSteps.length) continue;
        final choices = <int>[];
        for (var k = 0; k <= maxIdx; k++) {
          choices.add(_dpiSteps[k]);
        }
        out.add(MonitorScale(
          left: left,
          top: top,
          width: w,
          height: h,
          current: _dpiSteps[curIdx],
          choices: choices,
          recommended: _dpiSteps[recIdx],
          adapterLow: adapterLow,
          adapterHigh: adapterHigh,
          sourceId: sourceId,
        ));
      }
      // 左上から順に並べる (アプリの画面の並びと同じ)。
      out.sort((a, b) =>
          a.left != b.left ? a.left.compareTo(b.left) : a.top.compareTo(b.top));
      return out;
    } finally {
      pkgffi.calloc.free(nPath);
      pkgffi.calloc.free(nMode);
      pkgffi.calloc.free(req);
      if (paths != null) pkgffi.calloc.free(paths);
      if (modes != null) pkgffi.calloc.free(modes);
    }
  }

  /// 拡大率を変える。 [percent] は [MonitorScale.choices] の中の値。
  static bool setScale(MonitorScale mon, int percent) {
    if (!isSupported) return false;
    final target = _dpiSteps.indexOf(percent);
    final recIdx = _dpiSteps.indexOf(mon.recommended);
    if (target < 0 || recIdx < 0) return false;
    final req = pkgffi.calloc<ffi.Uint8>(24); // SET は 24 バイト
    try {
      final setInfo = _user32.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Uint8>),
          int Function(ffi.Pointer<ffi.Uint8>)>('DisplayConfigSetDeviceInfo');
      final rb = req.asTypedList(24).buffer.asByteData();
      rb.setInt32(0, -4, Endian.little); // SET_SOURCE_DPI_SCALE
      rb.setUint32(4, 24, Endian.little);
      rb.setUint32(8, mon.adapterLow, Endian.little);
      rb.setInt32(12, mon.adapterHigh, Endian.little);
      rb.setUint32(16, mon.sourceId, Endian.little);
      rb.setInt32(20, target - recIdx, Endian.little);
      return setInfo(req) == 0;
    } catch (e) {
      debugPrint('拡大率の変更に失敗: $e');
      return false;
    } finally {
      pkgffi.calloc.free(req);
    }
  }

  // ══ 壁紙 (IDesktopWallpaper) ══════════════════════════════════════
  static ffi.Pointer<ffi.Uint8> _guid(
      int d1, int d2, int d3, List<int> d4) {
    final g = pkgffi.calloc<ffi.Uint8>(16);
    for (var i = 0; i < 4; i++) {
      g[i] = (d1 >> (8 * i)) & 0xFF;
    }
    for (var i = 0; i < 2; i++) {
      g[4 + i] = (d2 >> (8 * i)) & 0xFF;
    }
    for (var i = 0; i < 2; i++) {
      g[6 + i] = (d3 >> (8 * i)) & 0xFF;
    }
    for (var i = 0; i < 8; i++) {
      g[8 + i] = d4[i];
    }
    return g;
  }

  /// IDesktopWallpaper を作る。 使い終わったら [_release] で放す。
  static ffi.Pointer<ffi.Void> _createWallpaper() {
    final ole32 = ffi.DynamicLibrary.open('ole32.dll');
    final coInit = ole32.lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32),
        int Function(ffi.Pointer<ffi.Void>, int)>('CoInitializeEx');
    final coCreate = ole32.lookupFunction<
        ffi.Int32 Function(
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Void>,
            ffi.Uint32,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Pointer<ffi.Void>>),
        int Function(
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Void>,
            int,
            ffi.Pointer<ffi.Uint8>,
            ffi.Pointer<ffi.Pointer<ffi.Void>>)>('CoCreateInstance');
    // CLSID_DesktopWallpaper / IID_IDesktopWallpaper
    final clsid = _guid(0xC2CF3110, 0x460E, 0x4FC1,
        const [0xB9, 0xD0, 0x8A, 0x1C, 0x0C, 0x9C, 0xC4, 0xBD]);
    final iid = _guid(0xB92B56A9, 0x8B55, 0x4E14,
        const [0x9A, 0x89, 0x01, 0x99, 0xBB, 0xB6, 0xF9, 0x3B]);
    final out = pkgffi.calloc<ffi.Pointer<ffi.Void>>();
    try {
      coInit(ffi.nullptr, 0x2); // APARTMENTTHREADED
      // ★ CLSCTX_ALL (0x17) を使う。 CLSCTX_INPROC_SERVER (0x1) だけだと
      //   REGDB_E_CLASSNOTREG (0x80040154) で作れない (実測)。
      final hr = coCreate(clsid, ffi.nullptr, 0x17, iid, out);
      if (hr != 0) {
        debugPrint('IDesktopWallpaper を作れませんでした: '
            '0x${(hr & 0xFFFFFFFF).toRadixString(16)}');
        return ffi.nullptr;
      }
      return out.value;
    } finally {
      pkgffi.calloc.free(clsid);
      pkgffi.calloc.free(iid);
      pkgffi.calloc.free(out);
    }
  }

  static ffi.Pointer<ffi.Pointer<ffi.Void>> _vtable(
          ffi.Pointer<ffi.Void> obj) =>
      obj.cast<ffi.Pointer<ffi.Pointer<ffi.Void>>>().value;

  static void _release(ffi.Pointer<ffi.Void> obj) {
    if (obj == ffi.nullptr) return;
    try {
      final fn = _vtable(obj)[2]
          .cast<ffi.NativeFunction<ffi.Uint32 Function(ffi.Pointer<ffi.Void>)>>()
          .asFunction<int Function(ffi.Pointer<ffi.Void>)>();
      fn(obj);
    } catch (_) {}
  }

  /// 壁紙を貼れる画面の一覧。 左上から順。
  static List<WallpaperMonitor> listWallpaperMonitors() {
    if (!isSupported) return const [];
    final obj = _createWallpaper();
    if (obj == ffi.nullptr) return const [];
    final countOut = pkgffi.calloc<ffi.Uint32>();
    try {
      final vt = _vtable(obj);
      // 6: GetMonitorDevicePathCount(UINT*)
      final getCount = vt[6]
          .cast<
              ffi.NativeFunction<
                  ffi.Int32 Function(
                      ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>)>>()
          .asFunction<
              int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>)>();
      // 5: GetMonitorDevicePathAt(UINT, LPWSTR*)
      final getAt = vt[5]
          .cast<
              ffi.NativeFunction<
                  ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32,
                      ffi.Pointer<ffi.Pointer<pkgffi.Utf16>>)>>()
          .asFunction<
              int Function(ffi.Pointer<ffi.Void>, int,
                  ffi.Pointer<ffi.Pointer<pkgffi.Utf16>>)>();
      // 7: GetMonitorRECT(LPCWSTR, RECT*)
      final getRect = vt[7]
          .cast<
              ffi.NativeFunction<
                  ffi.Int32 Function(ffi.Pointer<ffi.Void>,
                      ffi.Pointer<pkgffi.Utf16>, ffi.Pointer<ffi.Int32>)>>()
          .asFunction<
              int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<pkgffi.Utf16>,
                  ffi.Pointer<ffi.Int32>)>();
      // 4: GetWallpaper(LPCWSTR, LPWSTR*)
      final getWall = vt[4]
          .cast<
              ffi.NativeFunction<
                  ffi.Int32 Function(
                      ffi.Pointer<ffi.Void>,
                      ffi.Pointer<pkgffi.Utf16>,
                      ffi.Pointer<ffi.Pointer<pkgffi.Utf16>>)>>()
          .asFunction<
              int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<pkgffi.Utf16>,
                  ffi.Pointer<ffi.Pointer<pkgffi.Utf16>>)>();

      if (getCount(obj, countOut) != 0) return const [];
      final n = countOut.value;
      final out = <WallpaperMonitor>[];
      for (var i = 0; i < n; i++) {
        final idOut = pkgffi.calloc<ffi.Pointer<pkgffi.Utf16>>();
        final rect = pkgffi.calloc<ffi.Int32>(4);
        final wallOut = pkgffi.calloc<ffi.Pointer<pkgffi.Utf16>>();
        try {
          if (getAt(obj, i, idOut) != 0) continue;
          final id = idOut.value.toDartString();
          var l = 0, t = 0, r = 0, b = 0;
          if (getRect(obj, idOut.value, rect) == 0) {
            l = rect[0];
            t = rect[1];
            r = rect[2];
            b = rect[3];
          }
          String? cur;
          if (getWall(obj, idOut.value, wallOut) == 0 &&
              wallOut.value != ffi.nullptr) {
            final s = wallOut.value.toDartString();
            if (s.isNotEmpty) cur = s;
            _coFree(wallOut.value.cast());
          }
          // ★ 外した画面の名残 (大きさが 0 / 名前が空) は出さない。
          //   実測で、 今つながっていない画面の分も混ざって返ってくる。
          if (id.isNotEmpty && (r - l) > 0 && (b - t) > 0) {
            out.add(WallpaperMonitor(
              id: id,
              left: l,
              top: t,
              width: r - l,
              height: b - t,
              currentPath: cur,
            ));
          }
          _coFree(idOut.value.cast());
        } catch (_) {
        } finally {
          pkgffi.calloc.free(idOut);
          pkgffi.calloc.free(rect);
          pkgffi.calloc.free(wallOut);
        }
      }
      out.sort((a, b) =>
          a.left != b.left ? a.left.compareTo(b.left) : a.top.compareTo(b.top));
      return out;
    } catch (e) {
      debugPrint('壁紙の一覧の取得に失敗: $e');
      return const [];
    } finally {
      pkgffi.calloc.free(countOut);
      _release(obj);
    }
  }

  static void _coFree(ffi.Pointer<ffi.Void> p) {
    if (p == ffi.nullptr) return;
    try {
      final ole32 = ffi.DynamicLibrary.open('ole32.dll');
      final free = ole32.lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)>('CoTaskMemFree');
      free(p);
    } catch (_) {}
  }

  /// 壁紙を貼る。 [monitorId] が null なら全部の画面へ。
  static bool setWallpaper(String? monitorId, String imagePath,
      {WallpaperFit? fit}) {
    if (!isSupported) return false;
    final obj = _createWallpaper();
    if (obj == ffi.nullptr) return false;
    final path = imagePath.toNativeUtf16(allocator: pkgffi.malloc);
    final mon =
        monitorId == null ? null : monitorId.toNativeUtf16(allocator: pkgffi.malloc);
    try {
      final vt = _vtable(obj);
      // 3: SetWallpaper(LPCWSTR monitorID, LPCWSTR wallpaper)
      final setWall = vt[3]
          .cast<
              ffi.NativeFunction<
                  ffi.Int32 Function(
                      ffi.Pointer<ffi.Void>,
                      ffi.Pointer<pkgffi.Utf16>,
                      ffi.Pointer<pkgffi.Utf16>)>>()
          .asFunction<
              int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<pkgffi.Utf16>,
                  ffi.Pointer<pkgffi.Utf16>)>();
      if (fit != null) {
        // 10: SetPosition(DESKTOP_WALLPAPER_POSITION)
        final setPos = vt[10]
            .cast<
                ffi.NativeFunction<
                    ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32)>>()
            .asFunction<int Function(ffi.Pointer<ffi.Void>, int)>();
        setPos(obj, fit.value);
      }
      final hr = setWall(obj, mon ?? ffi.nullptr, path);
      return hr == 0;
    } catch (e) {
      debugPrint('壁紙の設定に失敗: $e');
      return false;
    } finally {
      pkgffi.malloc.free(path);
      if (mon != null) pkgffi.malloc.free(mon);
      _release(obj);
    }
  }

  /// 今の並べ方を読む。 読めなければ null。
  /// (= ユーザー要望: 壁紙の見本を「実際にどう貼られるか」 に合わせる。
  ///  そのために、 今 Windows が使っている並べ方を知る必要がある)。
  static WallpaperFit? getWallpaperFit() {
    if (!isSupported) return null;
    final obj = _createWallpaper();
    if (obj == ffi.nullptr) return null;
    final out = pkgffi.calloc<ffi.Int32>();
    try {
      // 11: GetPosition(DESKTOP_WALLPAPER_POSITION*)
      final getPos = _vtable(obj)[11]
          .cast<
              ffi.NativeFunction<
                  ffi.Int32 Function(
                      ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int32>)>>()
          .asFunction<
              int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Int32>)>();
      if (getPos(obj, out) != 0) return null;
      final v = out.value;
      for (final f in WallpaperFit.values) {
        if (f.value == v) return f;
      }
      return null;
    } catch (e) {
      debugPrint('壁紙の並べ方の取得に失敗: $e');
      return null;
    } finally {
      pkgffi.calloc.free(out);
      _release(obj);
    }
  }

  /// 並べ方だけを変える。
  static bool setWallpaperFit(WallpaperFit fit) {
    if (!isSupported) return false;
    final obj = _createWallpaper();
    if (obj == ffi.nullptr) return false;
    try {
      final setPos = _vtable(obj)[10]
          .cast<
              ffi.NativeFunction<
                  ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32)>>()
          .asFunction<int Function(ffi.Pointer<ffi.Void>, int)>();
      // ★ SetPosition は「もうその並べ方です」 の時に S_FALSE (=1) を返す。
      //   0 だけを成功と見なすと、 今選ばれている物を押しただけで
      //   「変えられませんでした」 と赤字が出る (= 実害のある誤報)。
      final hr = setPos(obj, fit.value);
      return hr >= 0;
    } catch (e) {
      debugPrint('壁紙の並べ方の設定に失敗: $e');
      return false;
    } finally {
      _release(obj);
    }
  }
}
