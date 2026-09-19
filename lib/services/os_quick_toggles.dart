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
// ★ デスクトップの並び順と名前はレジストリにしか無い (公開 API が無い)。
import 'package:win32_registry/win32_registry.dart';

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

  /// 実行ファイルの名前 (例 'chrome.exe')。 取れなければ空。
  ///
  /// ★ = ユーザー要望「windows本家の様に仮想デスクトップに window を
  ///   送ったりできるようにして欲しい」。 題名だけでは同じ名前の窓が
  ///   並んで見分けられないので、 アプリ名も添える。
  final String processName;

  /// 今居るデスクトップの GUID ('{...}')。 取れなければ空。
  final String desktopId;

  /// 今居るデスクトップの並び順 (0 始まり)。 分からなければ -1。
  final int desktopIndex;

  const DesktopWindowInfo({
    required this.hwnd,
    required this.title,
    required this.onCurrentDesktop,
    required this.isSelf,
    this.processName = '',
    this.desktopId = '',
    this.desktopIndex = -1,
  });

  /// この窓を [OsQuickToggles.moveWindowToDesktop] で別のデスクトップへ
  /// 送れるか。
  ///
  /// ★ = ユーザー要望「windows本家の様に仮想デスクトップに window を
  ///   送ったりできるようにして欲しい」 の**届かない所**。
  ///   公開 API の `IVirtualDesktopManager::MoveWindowToDesktop` は
  ///   **呼び出した側のプロセスが持っている窓しか動かせない**決まりで、
  ///   他のアプリの窓を渡すと必ず E_ACCESSDENIED が返る (権限を上げても、
  ///   Windows の版が変わっても同じ)。 本家の Win+Tab が他のアプリの窓を
  ///   引っ張れるのは、 公開されていない内部 COM
  ///   (IVirtualDesktopManagerInternal) をシェル自身が使っているから。
  ///   内部 COM は Windows のビルドが上がるたびに形 (IID / 関数の並び) が
  ///   変わり、 当てが外れるとその場でプロセスが落ちるので、 ここでは
  ///   使わない。 代わりに画面側で、 送れない窓には「送る」 を出さず
  ///   「そこへ移る」 とタスクビュー ([OsQuickToggles.openTaskView]) への
  ///   案内を出す。
  bool get canSend => isSelf;
}

/// 仮想デスクトップ 1 つぶん (並びはタスクビューの左から)。
///
/// ★ = ユーザー要望「windows本家の様に仮想デスクトップに window を
///   送ったりできるようにして欲しい」。 Win+Tab の画面と同じように
///   「どのデスクトップへ送るか」 を選べるようにするための一覧。
class VirtualDesktopInfo {
  /// 並び順 (0 始まり。 画面には +1 して出す)。
  final int index;

  /// GUID ('{...}' の形。 小文字)。
  final String id;

  /// 利用者が付けた名前。 付けていなければ空。
  final String name;

  /// 今見ているデスクトップか。
  final bool isCurrent;

  const VirtualDesktopInfo({
    required this.index,
    required this.id,
    required this.name,
    required this.isCurrent,
  });
}

/// デスクトップの一覧と窓の一覧を 1 往復で受け取る入れ物。
class VirtualDesktopSnapshot {
  final List<VirtualDesktopInfo> desktops;
  final List<DesktopWindowInfo> windows;
  const VirtualDesktopSnapshot({
    required this.desktops,
    required this.windows,
  });

  /// 今見ているデスクトップの並び順 (分からなければ -1)。
  int get currentIndex => desktops.indexWhere((d) => d.isCurrent);
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
  static const int _kVkTab = 0x09;

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

  /// Win+[key] を送る (Ctrl は押さない)。
  static bool _winOnly(int vk) {
    if (!isSupported) return false;
    ffi.Pointer<ffi.Uint8>? buf;
    try {
      const n = 4; // Win↓ key↓ key↑ Win↑
      buf = pkgffi.calloc<ffi.Uint8>(_kInputSize * n);
      final d = buf.asTypedList(_kInputSize * n).buffer.asByteData();
      _writeKey(d, _kInputSize * 0, _kVkLWin, up: false);
      _writeKey(d, _kInputSize * 1, vk, up: false);
      _writeKey(d, _kInputSize * 2, vk, up: true);
      _writeKey(d, _kInputSize * 3, _kVkLWin, up: true);
      return _sendInput(n, buf, _kInputSize) == n;
    } catch (_) {
      return false;
    } finally {
      if (buf != null) pkgffi.calloc.free(buf);
    }
  }

  /// タスクビュー (Win+Tab) を開く。
  ///
  /// ★ = ユーザー要望「windows本家の様に仮想デスクトップに window を
  ///   送ったりできるようにして欲しい」。 **他のアプリの窓**は Windows の
  ///   決まりで外からは動かせない ([moveWindowToDesktop] の説明)。
  ///   そこだけは本家の画面へ橋渡しして、 引っ張って移してもらう。
  static bool openTaskView() => _winOnly(_kVkTab);

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

  /// デスクトップの並び順と名前が入っている鍵。
  ///
  /// ★ 並び順・名前を教えてくれる公開 API は無いので、 Windows 自身が
  ///   書いているここを**読むだけ**にする (書き換えはしない)。
  static const String _kVdRegPath =
      r'Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops';

  /// DWMWA_CLOAKED (窓が隠されているか)。
  static const int _kDwmCloaked = 14;

  /// PROCESS_QUERY_LIMITED_INFORMATION。
  static const int _kProcQueryLimited = 0x1000;

  /// レジストリからデスクトップの一覧 (並び順どおり) を読む。
  ///
  /// 戻りは `[{'id': '{guid}', 'name': '...'}, ...]`。 読めなければ空。
  ///
  /// ★ 「今どれか」 はここでは決めない ([_readCurrentDesktopFromRegistry])。
  static List<Map<String, String>> _readDesktopsFromRegistry() {
    final out = <Map<String, String>>[];
    RegistryKey? key;
    try {
      key = Registry.openPath(RegistryHive.currentUser,
          path: _kVdRegPath, desiredAccessRights: AccessRights.readOnly);
      final ids = key.getBinaryValue('VirtualDesktopIDs');
      if (ids == null || ids.length < 16) return out;
      for (var off = 0; off + 16 <= ids.length; off += 16) {
        // REG_BINARY の並びはメモリ上の GUID と同じ (Data1/2/3 は LE)。
        // 手で 16 進を繋ぐと順番を間違えるので Guid に直させる。
        final id =
            w32.Guid(Uint8List.fromList(ids.sublist(off, off + 16))).toString();
        var name = '';
        RegistryKey? dk;
        try {
          dk = Registry.openPath(RegistryHive.currentUser,
              path: '$_kVdRegPath\\Desktops\\$id',
              desiredAccessRights: AccessRights.readOnly);
          name = dk.getStringValue('Name') ?? '';
        } catch (_) {
          // 名前を付けていないデスクトップには鍵そのものが無い。
        } finally {
          try {
            dk?.close();
          } catch (_) {}
        }
        out.add({'id': id, 'name': name});
      }
    } catch (_) {
      // 読めなければ空のまま (画面側が「一覧を読めませんでした」 と出す)。
    } finally {
      try {
        key?.close();
      } catch (_) {}
    }
    return out;
  }

  /// 16 バイトの REG_BINARY を GUID の文字にして読む。 無ければ空。
  static String _readGuidValue(String path, String name) {
    RegistryKey? k;
    try {
      k = Registry.openPath(RegistryHive.currentUser,
          path: path, desiredAccessRights: AccessRights.readOnly);
      final b = k.getBinaryValue(name);
      if (b == null || b.length < 16) return '';
      return w32.Guid(Uint8List.fromList(b.sublist(0, 16))).toString();
    } catch (_) {
      return '';
    } finally {
      try {
        k?.close();
      } catch (_) {}
    }
  }

  /// 今見ているデスクトップの GUID をレジストリから読む。 読めなければ空。
  ///
  /// ★ 置き場所が Windows 10 と 11 で違う。 11 は VirtualDesktops の直下、
  ///   10 は SessionInfo\<番号>\VirtualDesktops の下なので、 両方を見る。
  ///   自分の窓が別のデスクトップに居る時 (= 切り替えた後) は COM では
  ///   今のデスクトップが分からないので、 この読み取りが要る。
  static String _readCurrentDesktopFromRegistry() {
    final direct = _readGuidValue(_kVdRegPath, 'CurrentVirtualDesktop');
    if (direct.isNotEmpty) return direct;
    const sessionRoot =
        r'Software\Microsoft\Windows\CurrentVersion\Explorer\SessionInfo';
    RegistryKey? k;
    try {
      k = Registry.openPath(RegistryHive.currentUser,
          path: sessionRoot, desiredAccessRights: AccessRights.readOnly);
      for (final s in k.subkeyNames) {
        final v = _readGuidValue(
            '$sessionRoot\\$s\\VirtualDesktops', 'CurrentVirtualDesktop');
        if (v.isNotEmpty) return v;
      }
    } catch (_) {
    } finally {
      try {
        k?.close();
      } catch (_) {}
    }
    return '';
  }

  /// 今の並び順を**その場で**読み直して、 「今ここ」 と [id] の位置を返す。
  ///
  /// 戻りはどちらも 0 始まり。 分からなければ -1。
  ///
  /// ★ = 一覧 ([snapshot]) は開いた時の控えなので、 その後に利用者が
  ///   Ctrl+Win+←/→ や Win+Tab で自分でデスクトップを変えていると
  ///   「今どこか」 がずれる。 ずれたまま段数を数えると別のデスクトップに
  ///   着いてしまうので、 押す直前にここで読み直す。 レジストリを読むだけで
  ///   COM は使わないから、 画面のスレッドから呼んでよい (安い)。
  static ({int current, int target}) desktopIndexNow([String id = '']) {
    if (!isSupported) return (current: -1, target: -1);
    try {
      final ds = _readDesktopsFromRegistry();
      if (ds.isEmpty) return (current: -1, target: -1);
      final cur = _readCurrentDesktopFromRegistry();
      return (
        current: cur.isEmpty ? -1 : ds.indexWhere((d) => d['id'] == cur),
        target: id.isEmpty ? -1 : ds.indexWhere((d) => d['id'] == id),
      );
    } catch (_) {
      return (current: -1, target: -1);
    }
  }

  /// 自分の窓 (= 今のデスクトップに居る窓) を探す。
  static int _selfHwnd() {
    try {
      final a = w32.GetActiveWindow();
      if (a != 0) return a;
      return w32.GetForegroundWindow();
    } catch (_) {
      return 0;
    }
  }

  /// 今開いているアプリの窓を並べる (題名の無い物・道具窓は除く)。
  ///
  /// 他のデスクトップにある窓も含む (そちらから呼び寄せるため)。
  ///
  /// ★ = ユーザー報告「仮想デスクトップのボタンを押して立ち上げようとすると
  ///   アプリが落ちてしまう」。 COM を**画面のスレッドで直に呼んでいた**のが
  ///   原因。 Flutter の本スレッドは既に別の都合で COM を抱えていて、
  ///   そこへ割り込むとプロセスごと落ちる。 別の isolate で回し、
  ///   時間切れも付ける (このリポジトリの他の COM も同じ作法)。
  static Future<List<DesktopWindowInfo>> listAppWindows({int max = 60}) async =>
      (await snapshot(max: max)).windows;

  /// デスクトップの一覧 + 窓の一覧を 1 往復で取る。
  ///
  /// ★ = ユーザー要望「windows本家の様に仮想デスクトップに window を
  ///   送ったりできるようにして欲しい」。 送り先を選ばせるには
  ///   「デスクトップが何枚あって、 どういう名前で、 どの窓がどこに居るか」
  ///   が要るので、 窓の一覧と一緒にまとめて取る (COM を何度も起こさない)。
  ///
  /// 自分の窓も含めて返す (画面側が「このアプリ」 の段に出す)。
  static Future<VirtualDesktopSnapshot> snapshot({int max = 80}) async {
    if (!isSupported) {
      return const VirtualDesktopSnapshot(desktops: [], windows: []);
    }
    // 自分の窓を探すのだけは画面のスレッドで (窓はこちらの物)。
    final me = _selfHwnd();
    try {
      final m = await Isolate.run(() => _snapshotInIsolate(max, me))
          .timeout(const Duration(seconds: 8));
      final cur = (m['currentId'] as String?) ?? '';
      final ds = ((m['desktops'] as List?) ?? const []).cast<Map>();
      final desktops = <VirtualDesktopInfo>[
        for (var i = 0; i < ds.length; i++)
          VirtualDesktopInfo(
            index: i,
            id: (ds[i]['id'] as String?) ?? '',
            name: (ds[i]['name'] as String?) ?? '',
            isCurrent: cur.isNotEmpty && ds[i]['id'] == cur,
          ),
      ];
      final ws = ((m['windows'] as List?) ?? const []).cast<Map>();
      return VirtualDesktopSnapshot(
        desktops: desktops,
        windows: [
          for (final r in ws)
            DesktopWindowInfo(
              hwnd: (r['hwnd'] as int?) ?? 0,
              title: (r['title'] as String?) ?? '',
              onCurrentDesktop: r['cur'] == true,
              isSelf: r['self'] == true,
              processName: (r['proc'] as String?) ?? '',
              desktopId: (r['did'] as String?) ?? '',
              desktopIndex: (r['didx'] as int?) ?? -1,
            ),
        ],
      );
    } catch (_) {
      // 取れなければ空。 画面側が「窓はありません」 と出す。
      return const VirtualDesktopSnapshot(desktops: [], windows: []);
    }
  }

  /// COM の包みと元の領域を後始末する。
  ///
  /// ★ win32 5.x の `IUnknown` は**コンストラクタで Finalizer を張る**
  ///   (`if (isComInitialized) _release(ptr); free(ptr);`)。 そのまま手で
  ///   `release()` + `free()` すると、 後で Finalizer がもう一度 release /
  ///   free して解放済みの領域を触る (二重解放 / use-after-free で
  ///   プロセスごと落ちる)。 `release()` の説明にもそう書いてある。
  ///   なので**先に detach して Finalizer を外し**、 始末はここだけで行う。
  static void _disposeCom(
      w32.IUnknown? obj, ffi.Pointer<w32.COMObject>? ptr) {
    try {
      if (obj != null) {
        obj.detach();
        obj.release();
      }
    } catch (_) {}
    try {
      if (ptr != null) pkgffi.calloc.free(ptr);
    } catch (_) {}
  }

  /// 別の isolate で回る本体。 戻りは送れる型だけにする。
  static Map<String, Object?> _snapshotInIsolate(int max, int selfHwnd) {
    final out = <Map<String, Object?>>[];
    final desktops = _readDesktopsFromRegistry();
    final order = <String, int>{
      for (var i = 0; i < desktops.length; i++) desktops[i]['id']!: i,
    };
    var currentId = '';
    final init = w32.CoInitializeEx(ffi.nullptr, w32.COINIT_APARTMENTTHREADED);
    final needUninit = init == w32.S_OK || init == w32.S_FALSE;
    ffi.Pointer<w32.COMObject>? mgr;
    w32.IVirtualDesktopManager? vdm;
    final buf = pkgffi.calloc<ffi.Uint16>(512).cast<pkgffi.Utf16>();
    final cls = pkgffi.calloc<ffi.Uint16>(256).cast<pkgffi.Utf16>();
    final exePath = pkgffi.calloc<ffi.Uint16>(512).cast<pkgffi.Utf16>();
    final exeLen = pkgffi.calloc<ffi.Uint32>();
    final onCur = pkgffi.calloc<ffi.Int32>();
    final pidBuf = pkgffi.calloc<ffi.Uint32>();
    final guid = pkgffi.calloc<w32.GUID>();
    final cloaked = pkgffi.calloc<ffi.Uint32>();
    try {
      try {
        mgr = w32.COMObject.createFromID(
            w32.CLSID_VirtualDesktopManager, w32.IID_IVirtualDesktopManager);
      } catch (_) {
        mgr = null;
      }
      if (mgr != null) vdm = w32.IVirtualDesktopManager(mgr);
      // 今のデスクトップを決める。
      // ★ まず自分の窓から取る (自分の窓が今のデスクトップに居る時だけ
      //   正しいので、 居るかどうかを先に確かめる)。 切り替えた後など
      //   自分の窓が別のデスクトップに居る時はレジストリから読む。
      if (vdm != null && selfHwnd != 0) {
        try {
          onCur.value = 0;
          final okHere =
              vdm.isWindowOnCurrentVirtualDesktop(selfHwnd, onCur) == w32.S_OK &&
                  onCur.value != 0;
          if (okHere && vdm.getWindowDesktopId(selfHwnd, guid) == w32.S_OK) {
            currentId = guid.toDartGuid().toString();
          }
        } catch (_) {}
      }
      if (currentId.isEmpty) currentId = _readCurrentDesktopFromRegistry();
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
        // 居るデスクトップ (GUID)。
        var did = '';
        if (vdm != null) {
          try {
            if (vdm.getWindowDesktopId(h, guid) == w32.S_OK) {
              did = guid.toDartGuid().toString();
            }
          } catch (_) {}
        }
        var cur = true;
        if (did.isNotEmpty && currentId.isNotEmpty) {
          cur = did == currentId;
        } else if (vdm != null) {
          onCur.value = 0;
          final hr = vdm.isWindowOnCurrentVirtualDesktop(h, onCur);
          if (hr == w32.S_OK) cur = onCur.value != 0;
        }
        // ★ 隠れている窓 (中断中のストアアプリなど) は出さない。 ただし
        //   **今のデスクトップに居る物だけ**に掛ける。 他のデスクトップの
        //   窓は Windows が必ず隠す印 (DWM_CLOAKED_SHELL) を立てるので、
        //   一律に除くと送りたい相手が全部消えてしまう。
        if (cur) {
          try {
            cloaked.value = 0;
            final hr = w32.DwmGetWindowAttribute(
                h, _kDwmCloaked, cloaked.cast<ffi.Void>(), 4);
            if (hr == w32.S_OK && cloaked.value != 0) continue;
          } catch (_) {}
        }
        // アプリ名 (守られているプロセスは取れない = 空のまま)。
        var proc = '';
        try {
          final hp = w32.OpenProcess(_kProcQueryLimited, 0, pidBuf.value);
          if (hp != 0) {
            // 入りは容量、 出は長さ。 毎回入れ直す。
            exeLen.value = 511;
            if (w32.QueryFullProcessImageName(hp, 0, exePath, exeLen) != 0) {
              proc = exePath.toDartString().split('\\').last;
            }
            w32.CloseHandle(hp);
          }
        } catch (_) {}
        out.add({
          'hwnd': h,
          'title': title,
          'cur': cur,
          'self': pidBuf.value == selfPid,
          'proc': proc,
          'did': did,
          'didx': order[did] ?? -1,
        });
      }
    } catch (_) {
      // 途中まで集めた分だけ返す。
    } finally {
      _disposeCom(vdm, mgr);
      pkgffi.calloc.free(buf.cast<ffi.Uint16>());
      pkgffi.calloc.free(cls.cast<ffi.Uint16>());
      pkgffi.calloc.free(exePath.cast<ffi.Uint16>());
      pkgffi.calloc.free(exeLen);
      pkgffi.calloc.free(onCur);
      pkgffi.calloc.free(pidBuf);
      pkgffi.calloc.free(guid);
      pkgffi.calloc.free(cloaked);
      if (needUninit) w32.CoUninitialize();
    }
    return <String, Object?>{
      'desktops': desktops,
      'currentId': currentId,
      'windows': out,
    };
  }

  /// [hwnd] の窓を、 今見ているデスクトップへ呼び寄せる。
  ///
  /// 行き先はレジストリの「今見ているデスクトップ」。 読めなかった時だけ
  /// 自分の窓が居るデスクトップで代用する (昔の作り)。
  /// 自分の窓の探し方だけは画面のスレッドで行い (窓はそちらの物)、
  /// COM は別の isolate へ回す。
  ///
  /// ★ 他のアプリの窓は Windows が断る ([DesktopWindowInfo.canSend])。
  static Future<MoveWindowResult> moveWindowToThisDesktop(int hwnd) async {
    if (!isSupported || hwnd == 0) return MoveWindowResult.failed;
    final me = _selfHwnd();
    try {
      final code = await Isolate.run(() => _moveWindowInIsolate(hwnd, me, ''))
          .timeout(const Duration(seconds: 6));
      return MoveWindowResult.values[code];
    } catch (_) {
      return MoveWindowResult.failed;
    }
  }

  /// [hwnd] の窓を、 [desktopId] ('{guid}') のデスクトップへ**送る**。
  ///
  /// ★ = ユーザー要望「windows本家の様に仮想デスクトップに window を
  ///   送ったりできるようにして欲しい」。 Win+Tab の画面で窓を別の
  ///   デスクトップへ引っ張るのと同じ事を、 一覧から選んで行う。
  ///   使うのは公開されている IVirtualDesktopManager だけ。
  ///
  /// ★ **動かせるのはこのアプリ自身の窓だけ** ([DesktopWindowInfo.canSend])。
  ///   他のアプリの窓を渡すと Windows が必ず断る ([MoveWindowResult.denied])。
  static Future<MoveWindowResult> moveWindowToDesktop(
      int hwnd, String desktopId) async {
    if (!isSupported || hwnd == 0 || desktopId.isEmpty) {
      return MoveWindowResult.failed;
    }
    try {
      final code =
          await Isolate.run(() => _moveWindowInIsolate(hwnd, 0, desktopId))
              .timeout(const Duration(seconds: 6));
      return MoveWindowResult.values[code];
    } catch (_) {
      return MoveWindowResult.failed;
    }
  }

  /// 別の isolate で回る本体。 戻りは [MoveWindowResult] の番号。
  ///
  /// [targetId] が空の時だけ [selfHwnd] の居るデスクトップ (= 今ここ) へ、
  /// 中身があればその GUID のデスクトップへ送る。
  static int _moveWindowInIsolate(int hwnd, int selfHwnd, String targetId) {
    // ★ 行き先が空 = 「ここへ」。 本当の行き先は**今見ているデスクトップ**で、
    //   自分の窓が居るデスクトップとは限らない (自分の窓を他所へ送って
    //   付いて行かなかった時など)。 まずレジストリの「今どれか」 を使い、
    //   読めなかった時だけ昔どおり自分の窓から取る。
    var wanted = targetId;
    if (wanted.isEmpty) wanted = _readCurrentDesktopFromRegistry();
    final init = w32.CoInitializeEx(ffi.nullptr, w32.COINIT_APARTMENTTHREADED);
    final needUninit = init == w32.S_OK || init == w32.S_FALSE;
    ffi.Pointer<w32.COMObject>? mgr;
    w32.IVirtualDesktopManager? vdm;
    ffi.Pointer<w32.GUID>? guidRef;
    try {
      // '{...}' の形でなければ例外 → failed。
      final guid = wanted.isEmpty
          ? pkgffi.calloc<w32.GUID>()
          : w32.GUIDFromString(wanted);
      guidRef = guid;
      mgr = w32.COMObject.createFromID(
          w32.CLSID_VirtualDesktopManager, w32.IID_IVirtualDesktopManager);
      vdm = w32.IVirtualDesktopManager(mgr);
      if (wanted.isEmpty) {
        if (selfHwnd == 0 ||
            vdm.getWindowDesktopId(selfHwnd, guid) != w32.S_OK) {
          return MoveWindowResult.failed.index;
        }
      }
      final hr = vdm.moveWindowToDesktop(hwnd, guid);
      if (hr == w32.S_OK) return MoveWindowResult.ok.index;
      // E_ACCESSDENIED (0x80070005) = 自分のプロセスの窓ではないので拒まれた。
      return hr == -2147024891
          ? MoveWindowResult.denied.index
          : MoveWindowResult.failed.index;
    } catch (_) {
      return MoveWindowResult.failed.index;
    } finally {
      _disposeCom(vdm, mgr);
      if (guidRef != null) pkgffi.calloc.free(guidRef);
      if (needUninit) w32.CoUninitialize();
    }
  }

  /// [hwnd] が今見ているデスクトップに居るか。 分からなければ null。
  ///
  /// 送った後に「本当に移れたか」 を確かめるのに使う。
  static Future<bool?> isWindowOnCurrentDesktop(int hwnd) async {
    if (!isSupported || hwnd == 0) return null;
    try {
      final v = await Isolate.run(() => _isOnCurrentInIsolate(hwnd))
          .timeout(const Duration(seconds: 5));
      return v == 0 ? null : v > 0;
    } catch (_) {
      return null;
    }
  }

  /// 別の isolate で回る本体。 1 = 居る / -1 = 居ない / 0 = 分からない。
  static int _isOnCurrentInIsolate(int hwnd) {
    final init = w32.CoInitializeEx(ffi.nullptr, w32.COINIT_APARTMENTTHREADED);
    final needUninit = init == w32.S_OK || init == w32.S_FALSE;
    ffi.Pointer<w32.COMObject>? mgr;
    w32.IVirtualDesktopManager? vdm;
    final onCur = pkgffi.calloc<ffi.Int32>();
    try {
      mgr = w32.COMObject.createFromID(
          w32.CLSID_VirtualDesktopManager, w32.IID_IVirtualDesktopManager);
      vdm = w32.IVirtualDesktopManager(mgr);
      onCur.value = 0;
      if (vdm.isWindowOnCurrentVirtualDesktop(hwnd, onCur) != w32.S_OK) {
        return 0;
      }
      return onCur.value != 0 ? 1 : -1;
    } catch (_) {
      return 0;
    } finally {
      _disposeCom(vdm, mgr);
      pkgffi.calloc.free(onCur);
      if (needUninit) w32.CoUninitialize();
    }
  }

  /// [from] 番目のデスクトップから [to] 番目へ移る。
  ///
  /// ★ 「デスクトップ N へ飛ぶ」 公開 API は無いので、 Ctrl+Win+←/→ を
  ///   差のぶん送る (利用者が普段押すのと同じ手順)。 [verifyHwnd] を渡すと、
  ///   その窓が今のデスクトップに居るかどうかで着いたかを確かめる。
  static Future<DesktopSwitchResult> switchToDesktopIndex({
    required int from,
    required int to,
    int? verifyHwnd,
    String targetId = '',
  }) async {
    if (!isSupported) return DesktopSwitchResult.unsupported;
    if (from < 0 || to < 0) return DesktopSwitchResult.failed;
    if (from == to && targetId.isEmpty) return DesktopSwitchResult.ok;
    final forward = to > from;
    final steps = (to - from).abs();
    for (var i = 0; i < steps; i++) {
      if (!(forward ? nextDesktop() : prevDesktop())) {
        return DesktopSwitchResult.failed;
      }
      // 切り替えの見た目が終わるまで少し待つ。
      await Future<void>.delayed(const Duration(milliseconds: 280));
    }
    // ★ [targetId] を渡されたら、 着いたかどうかをレジストリで確かめて
    //   ずれていれば足りない分を送り直す。 段数は押した時の控えから
    //   数えているので、 その後に利用者が自分で Ctrl+Win+←/→ や Win+Tab で
    //   切り替えていると行き先がずれる。 先に数えた分を送ってから直すので、
    //   レジストリの書き込みが遅れても行き過ぎには**ならない**。
    if (targetId.isNotEmpty) {
      for (var round = 0; round < 2; round++) {
        await Future<void>.delayed(const Duration(milliseconds: 220));
        final now = desktopIndexNow(targetId);
        // 読めない = 確かめようが無いので、 動いた事にする。
        if (now.current < 0 || now.target < 0) return DesktopSwitchResult.ok;
        if (now.current == now.target) return DesktopSwitchResult.ok;
        final gap = (now.target - now.current).abs();
        final fw = now.target > now.current;
        for (var i = 0; i < gap; i++) {
          if (!(fw ? nextDesktop() : prevDesktop())) {
            return DesktopSwitchResult.failed;
          }
          await Future<void>.delayed(const Duration(milliseconds: 280));
        }
      }
      final fin = desktopIndexNow(targetId);
      return (fin.current >= 0 && fin.target >= 0 && fin.current != fin.target)
          ? DesktopSwitchResult.noNeighbor
          : DesktopSwitchResult.ok;
    }
    if (verifyHwnd == null || verifyHwnd == 0) return DesktopSwitchResult.ok;
    final on = await isWindowOnCurrentDesktop(verifyHwnd);
    // 分からない時 (null) は動いた事にする (確かめようが無い)。
    return on == false ? DesktopSwitchResult.noNeighbor : DesktopSwitchResult.ok;
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
