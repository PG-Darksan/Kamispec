// パソコン側をその場で切り替える小物 (電源モード / 仮想デスクトップ)。
//
// = ユーザー要望「バッテリーのモードを省電力モードに切り替えたりできる
//   ボタンを作って欲しい」「デスクトップの切り替えボタンも欲しい」。
//
// Windows 専用。 他の OS では [isSupported] が false を返し、 何もしない
// (画面側はボタンそのものを出さない)。
//
// ★ 外のプログラムは呼ばない。 以前ディスプレイの設定が PowerShell を
//   起動していて、 利用者のセキュリティソフトに「悪意ある行動」 として
//   止められた。 ここは全部その場で Win32 を呼ぶ ([[no-hidden-powershell-from-app]])。
//
// ── 何を触っているか ────────────────────────────────────────────────
//  電源モード      powrprof.dll の PowerSetActiveOverlayScheme /
//                  PowerGetEffectiveOverlayScheme。 Windows 10/11 の
//                  タスクバーの電源スライダーと**同じ物**。 電源プラン
//                  (PcSettings が触っている方) とは別の層で、 プランを
//                  壊さずに「省電力 / バランス / 最高性能」 だけを変える。
//  デスクトップ    SendInput で Ctrl+Win+←/→/D/F4。 仮想デスクトップを
//                  切り替える公開 API は無い (IVirtualDesktopManager は
//                  「その窓がどのデスクトップに居るか」 しか扱えない)。
//                  内部 COM は Windows のビルドごとに形が変わって壊れる
//                  ので、 利用者が普段使うのと同じショートカットを送る。
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart' as w32;

/// 電源モード (タスクバーのスライダーと同じ 3 段)。
enum PowerMode {
  /// 省電力 (バッテリーを長持ちさせる)。
  saver,

  /// バランス (Windows の既定)。
  balanced,

  /// 最高性能。
  performance,
}

typedef _SetOverlayNative = ffi.Uint32 Function(ffi.Pointer<_Guid>);
typedef _SetOverlayDart = int Function(ffi.Pointer<_Guid>);
typedef _GetOverlayNative = ffi.Uint32 Function(ffi.Pointer<_Guid>);
typedef _GetOverlayDart = int Function(ffi.Pointer<_Guid>);
typedef _SendInputNative = ffi.Uint32 Function(
    ffi.Uint32, ffi.Pointer<ffi.Uint8>, ffi.Int32);
typedef _SendInputDart = int Function(int, ffi.Pointer<ffi.Uint8>, int);
typedef _MapVkNative = ffi.Uint32 Function(ffi.Uint32, ffi.Uint32);
typedef _MapVkDart = int Function(int, int);
typedef _HwndNative = ffi.IntPtr Function();
typedef _HwndDart = int Function();

/// GUID (16 バイト)。
final class _Guid extends ffi.Struct {
  @ffi.Uint32()
  external int d1;
  @ffi.Uint16()
  external int d2;
  @ffi.Uint16()
  external int d3;
  @ffi.Array<ffi.Uint8>(8)
  external ffi.Array<ffi.Uint8> d4;
}

/// 起動中のアプリの窓 1 つぶん (= 仮想デスクトップへ移す相手)。
class DesktopWindowInfo {
  /// 窓のハンドル。
  final int hwnd;

  /// 題名バーの文字 (一覧に出す名前)。
  final String title;

  /// 今見えているデスクトップに居るか。
  final bool onCurrentDesktop;

  /// このアプリ自身の窓か。
  final bool isSelf;

  const DesktopWindowInfo({
    required this.hwnd,
    required this.title,
    required this.onCurrentDesktop,
    required this.isSelf,
  });
}

/// 窓を移した結果。
enum MoveWindowResult {
  /// 移せた。
  ok,

  /// Windows に断られた (= 他のアプリの窓は移せない事がある)。
  denied,

  /// 仕組みが使えない / 窓が見つからない。
  failed,
}

/// デスクトップの切り替えを頼んだ結果。
enum DesktopSwitchResult {
  /// 切り替わった。
  ok,

  /// 隣にデスクトップが無かった (= 何も起きない)。
  noNeighbor,

  /// キーを送れなかった。
  failed,

  /// Windows 以外。
  unsupported,
}

class OsQuickToggles {
  OsQuickToggles._();

  static bool get isSupported => !kIsWeb && Platform.isWindows;

  // ── 電源モード ─────────────────────────────────────────────────────
  //
  //   Windows が決めている「重ねる設定 (overlay)」 の GUID。
  //   バランスだけは**すべて 0** で、「重ねない = 既定に戻す」 を意味する。
  static const List<int> _kSaverGuid = [
    0x961CC777, 0x2547, 0x4F9D, //
    0x81, 0x74, 0x7D, 0x86, 0x18, 0x1B, 0x8A, 0x7A,
  ];
  static const List<int> _kPerfGuid = [
    0xDED574B5, 0x45A0, 0x4F42, //
    0x87, 0x37, 0x46, 0x34, 0x5C, 0x09, 0xC2, 0x38,
  ];

  static ffi.DynamicLibrary? _powrprofLib;
  static ffi.DynamicLibrary get _powrprof =>
      _powrprofLib ??= ffi.DynamicLibrary.open('powrprof.dll');

  static ffi.DynamicLibrary? _user32Lib;
  static ffi.DynamicLibrary get _user32 =>
      _user32Lib ??= ffi.DynamicLibrary.open('user32.dll');

  static void _fillGuid(ffi.Pointer<_Guid> p, List<int> g) {
    p.ref.d1 = g[0];
    p.ref.d2 = g[1];
    p.ref.d3 = g[2];
    for (var i = 0; i < 8; i++) {
      p.ref.d4[i] = g[3 + i];
    }
  }

  static bool _guidIs(ffi.Pointer<_Guid> p, List<int> g) {
    if (p.ref.d1 != g[0] || p.ref.d2 != g[1] || p.ref.d3 != g[2]) return false;
    for (var i = 0; i < 8; i++) {
      if (p.ref.d4[i] != g[3 + i]) return false;
    }
    return true;
  }

  /// 今の電源モード。 読めなければ null。
  ///
  /// ★ この 2 つの関数は Windows の輸出表には在るが説明書には載っていない
  ///   (タスクバーのスライダーが使っている物)。 古い Windows では見つから
  ///   ないので、 lookup の失敗は握り潰して null を返す。
  static PowerMode? currentPowerMode() {
    if (!isSupported) return null;
    ffi.Pointer<_Guid>? buf;
    try {
      final fn = _powrprof
          .lookupFunction<_GetOverlayNative, _GetOverlayDart>(
              'PowerGetEffectiveOverlayScheme');
      buf = pkgffi.calloc<_Guid>();
      if (fn(buf) != 0) return null;
      if (_guidIs(buf, _kSaverGuid)) return PowerMode.saver;
      if (_guidIs(buf, _kPerfGuid)) return PowerMode.performance;
      // 0 埋め (= 重ねていない) も、 知らない GUID もバランス扱いにする。
      return PowerMode.balanced;
    } catch (_) {
      return null;
    } finally {
      if (buf != null) pkgffi.calloc.free(buf);
    }
  }

  /// 電源モードを変える。 出来たら true。
  ///
  /// ★ 電源**プラン**は書き換えない。 プランを変えると利用者が自分で
  ///   組んだ設定を壊すので、 上に重ねるだけのこちらを使う。
  static bool setPowerMode(PowerMode mode) {
    if (!isSupported) return false;
    ffi.Pointer<_Guid>? buf;
    try {
      final fn = _powrprof
          .lookupFunction<_SetOverlayNative, _SetOverlayDart>(
              'PowerSetActiveOverlayScheme');
      buf = pkgffi.calloc<_Guid>();
      switch (mode) {
        case PowerMode.saver:
          _fillGuid(buf, _kSaverGuid);
          break;
        case PowerMode.performance:
          _fillGuid(buf, _kPerfGuid);
          break;
        case PowerMode.balanced:
          // すべて 0 のまま = 重ねない (既定へ戻す)。
          break;
      }
      return fn(buf) == 0;
    } catch (_) {
      return false;
    } finally {
      if (buf != null) pkgffi.calloc.free(buf);
    }
  }

  /// 押すたびに 省電力 → バランス → 最高性能 → 省電力 … と回す。
  /// 返すのは切り替えた**後**のモード (失敗したら null)。
  static PowerMode? cyclePowerMode() {
    final now = currentPowerMode();
    if (now == null) return null;
    final next = switch (now) {
      PowerMode.saver => PowerMode.balanced,
      PowerMode.balanced => PowerMode.performance,
      PowerMode.performance => PowerMode.saver,
    };
    return setPowerMode(next) ? next : null;
  }

  // ── 仮想デスクトップ ───────────────────────────────────────────────
  static const int _kInputKeyboard = 1;
  static const int _kKeyUp = 0x0002;
  static const int _kVkControl = 0x11;
  static const int _kVkLWin = 0x5B;
  static const int _kVkLeft = 0x25;
  static const int _kVkRight = 0x27;
  static const int _kVkD = 0x44;
  static const int _kVkF4 = 0x73;

  /// INPUT 構造体は 64bit で 40 バイト。
  static const int _kInputSize = 40;

  static _SendInputDart? _sendInputFn;
  static _SendInputDart get _sendInput => _sendInputFn ??= _user32
      .lookupFunction<_SendInputNative, _SendInputDart>('SendInput');

  /// この仮想キーは「拡張キー (E0 付き)」 か。
  ///
  /// ★ ここが b407 まで抜けていて、 デスクトップの切り替えが効かない
  ///   原因だった。 矢印キーの走査コード (MapVirtualKey) は **テンキーの
  ///   4 / 6 と同じ 0x4B / 0x4D** で、 本物の矢印キーはそこに E0 が付く。
  ///   拡張の印を立てずに送ると Windows 側は「テンキーの 4」 として扱うので、
  ///   シェルの Ctrl+Win+←/→ の組み合わせに当たらず、 SendInput は
  ///   成功を返すのに何も起きない。 Win キー自体も拡張キー。
  static bool _isExtended(int vk) =>
      vk == _kVkLeft ||
      vk == _kVkRight ||
      vk == _kVkLWin ||
      vk == 0x26 || // ↑
      vk == 0x28; // ↓

  static _MapVkDart? _mapVkFn;
  static _MapVkDart get _mapVk => _mapVkFn ??=
      _user32.lookupFunction<_MapVkNative, _MapVkDart>('MapVirtualKeyW');

  /// 走査コード (MAPVK_VK_TO_VSC = 0)。 取れなければ 0 のまま
  /// (Windows が仮想キーから補う)。
  static int _scanOf(int vk) {
    try {
      return _mapVk(vk, 0);
    } catch (_) {
      return 0;
    }
  }

  static void _writeKey(ByteData d, int base, int vk, {required bool up}) {
    const kExtended = 0x0001;
    final ext = _isExtended(vk);
    var flags = up ? _kKeyUp : 0;
    if (ext) flags |= kExtended;
    d.setUint32(base + 0, _kInputKeyboard, Endian.little);
    d.setUint16(base + 8, vk, Endian.little);
    d.setUint16(base + 10, _scanOf(vk), Endian.little);
    d.setUint32(base + 12, flags, Endian.little);
    d.setUint32(base + 16, 0, Endian.little);
    d.setUint64(base + 24, 0, Endian.little);
  }

  static _HwndDart? _foregroundFn;
  static _HwndDart get _foreground => _foregroundFn ??=
      _user32.lookupFunction<_HwndNative, _HwndDart>('GetForegroundWindow');

  /// 今いちばん手前の窓。 取れなければ 0。
  static int _foregroundWindow() {
    try {
      return _foreground();
    } catch (_) {
      return 0;
    }
  }

  /// Ctrl+Win+[key] を送る。
  ///
  /// ★ 仮想デスクトップを切り替える公開 API は無い。 内部 COM
  ///   (IVirtualDesktopManagerInternal) は Windows のビルドが上がるたびに
  ///   形が変わって動かなくなるので、 利用者が普段押すのと**同じ**
  ///   ショートカットを送る形にしてある。 押した本人の操作として届くので、
  ///   他のアプリを勝手に触る事にはならない。
  static bool _ctrlWin(int vk) {
    if (!isSupported) return false;
    ffi.Pointer<ffi.Uint8>? buf;
    try {
      const n = 6; // Ctrl↓ Win↓ key↓ key↑ Win↑ Ctrl↑
      buf = pkgffi.calloc<ffi.Uint8>(_kInputSize * n);
      final d = buf.asTypedList(_kInputSize * n).buffer.asByteData();
      _writeKey(d, _kInputSize * 0, _kVkControl, up: false);
      _writeKey(d, _kInputSize * 1, _kVkLWin, up: false);
      _writeKey(d, _kInputSize * 2, vk, up: false);
      _writeKey(d, _kInputSize * 3, vk, up: true);
      _writeKey(d, _kInputSize * 4, _kVkLWin, up: true);
      _writeKey(d, _kInputSize * 5, _kVkControl, up: true);
      return _sendInput(n, buf, _kInputSize) == n;
    } catch (_) {
      return false;
    } finally {
      if (buf != null) pkgffi.calloc.free(buf);
    }
  }

  /// 仮想デスクトップを切り替えて、 **本当に動いたか**まで確かめる。
  ///
  /// ★ = ユーザー報告「デスクトップの切り替えが動作していない」。
  ///   SendInput は「送れたか」 しか返さないので、 **隣にデスクトップが
  ///   無い**時も成功を返す (何も起きないのに知らせようが無かった)。
  ///   切り替わると自分の窓は別のデスクトップに取り残されるので、
  ///   「いちばん手前の窓が自分でなくなったか」 で動いたかどうかが分かる。
  static Future<DesktopSwitchResult> switchDesktop(
      {required bool forward}) async {
    if (!isSupported) return DesktopSwitchResult.unsupported;
    final before = _foregroundWindow();
    final sent = forward ? nextDesktop() : prevDesktop();
    if (!sent) return DesktopSwitchResult.failed;
    // 切り替えの見た目が終わるまで少し待つ (だいたい 300ms ほど)。
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 160));
      final now = _foregroundWindow();
      if (now != before) return DesktopSwitchResult.ok;
    }
    // 手前の窓が変わらない = 隣にデスクトップが無かった。
    return DesktopSwitchResult.noNeighbor;
  }

  /// 右のデスクトップへ (Ctrl+Win+→)。
  static bool nextDesktop() => _ctrlWin(_kVkRight);

  /// 左のデスクトップへ (Ctrl+Win+←)。
  static bool prevDesktop() => _ctrlWin(_kVkLeft);

  /// 新しいデスクトップを作る (Ctrl+Win+D)。
  static bool newDesktop() => _ctrlWin(_kVkD);

  /// 今のデスクトップを閉じる (Ctrl+Win+F4)。
  ///
  /// ★ Windows の仕様で、 閉じてもそのデスクトップにあった窓は消えず、
  ///   隣のデスクトップへ移る (仕事を失わない)。
  static bool closeDesktop() => _ctrlWin(_kVkF4);

  // ── 他のアプリの窓を移す ────────────────────────────
  //
  // ★ = ユーザー要望「切り替えに加えて、 作成 / 削除に他の起動中の
  //   アプリ window の転送なども行えるように」。
  //
  //   使うのは公開されている IVirtualDesktopManager だけ
  //   (内部 COM は Windows の版が上がるたびに壊れるので使わない)。
  //   ただし MoveWindowToDesktop は、 相手のアプリによっては Windows 側が
  //   断る (E_ACCESSDENIED)。 断られた時はその事をそのまま伝える。

  static const int _kGwlExStyle = -20;
  static const int _kWsExToolWindow = 0x00000080;
  static const int _kWsExAppWindow = 0x00040000;

  /// 今開いているアプリの窓を並べる (題名の無い物・道具窓は除く)。
  ///
  /// 他のデスクトップにある窓も含む (そちらから呼び寄せるため)。
  ///
  /// ★ = ユーザー報告「仮想デスクトップのボタンを押して立ち上げようとすると
  ///   アプリが落ちてしまう」。 COM を**画面のスレッドで直に呼んでいた**のが
  ///   原因。 Flutter の本スレッドは既に別の都合で COM を抱えていて、
  ///   そこへ割り込むとプロセスごと落ちる。 別の isolate で回し、
  ///   時間切れも付ける (このリポジトリの他の COM も同じ作法)。
  static Future<List<DesktopWindowInfo>> listAppWindows({int max = 60}) async {
    if (!isSupported) return const [];
    try {
      final rows = await Isolate.run(() => _listWindowsInIsolate(max))
          .timeout(const Duration(seconds: 6));
      return [
        for (final r in rows)
          DesktopWindowInfo(
            hwnd: (r['hwnd'] as int?) ?? 0,
            title: (r['title'] as String?) ?? '',
            onCurrentDesktop: r['cur'] == true,
            isSelf: r['self'] == true,
          ),
      ];
    } catch (_) {
      // 取れなければ空。 画面側が「窓はありません」 と出す。
      return const [];
    }
  }

  /// 別の isolate で回る本体。 戻りは送れる型だけにする。
  static List<Map<String, Object?>> _listWindowsInIsolate(int max) {
    final out = <Map<String, Object?>>[];
    final init = w32.CoInitializeEx(ffi.nullptr, w32.COINIT_APARTMENTTHREADED);
    final needUninit = init == w32.S_OK || init == w32.S_FALSE;
    ffi.Pointer<w32.COMObject>? mgr;
    final buf = pkgffi.calloc<ffi.Uint16>(512).cast<pkgffi.Utf16>();
    final cls = pkgffi.calloc<ffi.Uint16>(256).cast<pkgffi.Utf16>();
    final onCur = pkgffi.calloc<ffi.Int32>();
    final pidBuf = pkgffi.calloc<ffi.Uint32>();
    try {
      try {
        mgr = w32.COMObject.createFromID(
            w32.CLSID_VirtualDesktopManager, w32.IID_IVirtualDesktopManager);
      } catch (_) {
        mgr = null;
      }
      final vdm = mgr == null ? null : w32.IVirtualDesktopManager(mgr);
      final selfPid = w32.GetCurrentProcessId();
      // 同じアプリの同じ題名が何十も並ぶ事がある (ブラウザの裏の窓など)。
      final seen = <String>{};
      var h = 0;
      while (out.length < max) {
        h = w32.FindWindowEx(0, h, ffi.nullptr, ffi.nullptr);
        if (h == 0) break;
        if (w32.IsWindowVisible(h) == 0) continue;
        // 別の窓に飼われている物 (ダイアログなど) は主の窓ではない。
        if (w32.GetWindow(h, w32.GW_OWNER) != 0) continue;
        final ex = w32.GetWindowLongPtr(h, _kGwlExStyle);
        if ((ex & _kWsExToolWindow) != 0 && (ex & _kWsExAppWindow) == 0) {
          continue;
        }
        final len = w32.GetWindowTextLength(h);
        if (len <= 0) continue;
        w32.GetWindowText(h, buf, 511);
        final title = buf.toDartString().trim();
        if (title.isEmpty) continue;
        // Windows の中身 (入力エクスペリエンス / ロック画面など) は出さない。
        w32.GetClassName(h, cls, 255);
        final klass = cls.toDartString();
        if (klass == 'Windows.UI.Core.CoreWindow') continue;
        pidBuf.value = 0;
        w32.GetWindowThreadProcessId(h, pidBuf);
        final key = '${pidBuf.value}\u0000$title';
        if (!seen.add(key)) continue;
        var cur = true;
        if (vdm != null) {
          onCur.value = 0;
          final hr = vdm.isWindowOnCurrentVirtualDesktop(h, onCur);
          if (hr == w32.S_OK) cur = onCur.value != 0;
        }
        out.add({
          'hwnd': h,
          'title': title,
          'cur': cur,
          'self': pidBuf.value == selfPid,
        });
      }
    } catch (_) {
      // 途中まで集めた分だけ返す。
    } finally {
      try {
        if (mgr != null) {
          w32.IUnknown(mgr).release();
          pkgffi.calloc.free(mgr);
        }
      } catch (_) {}
      pkgffi.calloc.free(buf.cast<ffi.Uint16>());
      pkgffi.calloc.free(cls.cast<ffi.Uint16>());
      pkgffi.calloc.free(onCur);
      pkgffi.calloc.free(pidBuf);
      if (needUninit) w32.CoUninitialize();
    }
    return out;
  }

  /// [hwnd] の窓を、 今見ているデスクトップへ呼び寄せる。
  ///
  /// 今のデスクトップの id は、 自分の窓が居るデスクトップから取る
  /// (自分の窓は必ず見えている = 今のデスクトップに居る)。
  /// 自分の窓の探し方だけは画面のスレッドで行い (窓はそちらの物)、
  /// COM は別の isolate へ回す。
  static Future<MoveWindowResult> moveWindowToThisDesktop(int hwnd) async {
    if (!isSupported || hwnd == 0) return MoveWindowResult.failed;
    var me = 0;
    try {
      me = w32.GetActiveWindow();
      if (me == 0) me = w32.GetForegroundWindow();
    } catch (_) {
      me = 0;
    }
    if (me == 0) return MoveWindowResult.failed;
    try {
      final code = await Isolate.run(() => _moveWindowInIsolate(hwnd, me))
          .timeout(const Duration(seconds: 6));
      return MoveWindowResult.values[code];
    } catch (_) {
      return MoveWindowResult.failed;
    }
  }

  /// 別の isolate で回る本体。 戻りは [MoveWindowResult] の番号。
  static int _moveWindowInIsolate(int hwnd, int selfHwnd) {
    final init = w32.CoInitializeEx(ffi.nullptr, w32.COINIT_APARTMENTTHREADED);
    final needUninit = init == w32.S_OK || init == w32.S_FALSE;
    ffi.Pointer<w32.COMObject>? mgr;
    final guid = pkgffi.calloc<w32.GUID>();
    try {
      mgr = w32.COMObject.createFromID(
          w32.CLSID_VirtualDesktopManager, w32.IID_IVirtualDesktopManager);
      final vdm = w32.IVirtualDesktopManager(mgr);
      if (vdm.getWindowDesktopId(selfHwnd, guid) != w32.S_OK) {
        return MoveWindowResult.failed.index;
      }
      final hr = vdm.moveWindowToDesktop(hwnd, guid);
      if (hr == w32.S_OK) return MoveWindowResult.ok.index;
      // E_ACCESSDENIED (0x80070005) = 他のアプリの窓を拒まれた。
      return hr == -2147024891
          ? MoveWindowResult.denied.index
          : MoveWindowResult.failed.index;
    } catch (_) {
      return MoveWindowResult.failed.index;
    } finally {
      try {
        if (mgr != null) {
          w32.IUnknown(mgr).release();
          pkgffi.calloc.free(mgr);
        }
      } catch (_) {}
      pkgffi.calloc.free(guid);
      if (needUninit) w32.CoUninitialize();
    }
  }

  /// [hwnd] を手前へ出す (呼び寄せた後に使う)。
  static void focusWindow(int hwnd) {
    if (!isSupported || hwnd == 0) return;
    try {
      const swRestore = 9;
      if (w32.IsIconic(hwnd) != 0) w32.ShowWindow(hwnd, swRestore);
      w32.SetForegroundWindow(hwnd);
    } catch (_) {}
  }
}
