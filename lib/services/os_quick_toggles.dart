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
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter/foundation.dart';

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
  static bool closeDesktop() => _ctrlWin(_kVkF4);
}
