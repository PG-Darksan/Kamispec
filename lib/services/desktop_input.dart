// パソコンそのものを操作する (マウス / キーボード / ウィンドウ)。
//
// なぜ要るのか:
//   自動操作がこれまで動かせたのは「アプリの中のブラウザ」 だけだった。
//   PC の Chrome を起動しても、 それは別のプロセスの別の窓なので、
//   中を押すことも文字を入れることもできなかった
//   (= ユーザー要望「PC 内のアプリを操作できるようにして欲しい」)。
//   ここでは Windows に直接マウス / キーボードの信号を送る。
//
// ★ 危ない機能なので、 既定では動かない。 呼ぶ側が `enabled` を立てた時
//   だけ効く。 画面に見えている物を無差別に押せてしまうため、 利用者が
//   はっきり許した時以外は動かさないこと。
//
// 対応は Windows だけ。 他のプラットフォームでは何もしない
//   (isSupported が false を返し、 各操作は黙って何もしない)。
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// ここは Flutter に依存させない (= dart run だけで確かめられる
/// ように。 FFI の並びを間違えると「動くけれど違う所を押す」 という
/// 一番たちの悪い壊れ方をするので、 実測できる形にしておく)。
void _warn(String m) {
  // ignore: avoid_print
  print(m);
}

// ── Win32 の定数 ────────────────────────────────────────────────────────
const int _kInputMouse = 0;
const int _kInputKeyboard = 1;

const int _kMouseMove = 0x0001;
const int _kMouseLeftDown = 0x0002;
const int _kMouseLeftUp = 0x0004;
const int _kMouseRightDown = 0x0008;
const int _kMouseRightUp = 0x0010;
const int _kMouseMiddleDown = 0x0020;
const int _kMouseMiddleUp = 0x0040;
const int _kMouseWheel = 0x0800;
const int _kMouseAbsolute = 0x8000;
const int _kMouseVirtualDesk = 0x4000;

const int _kKeyExtended = 0x0001;
const int _kKeyUp = 0x0002;
const int _kKeyUnicode = 0x0004;

const int _kSmXVirtual = 76;
const int _kSmYVirtual = 77;
const int _kSmCxVirtual = 78;
const int _kSmCyVirtual = 79;

const int _kSwRestore = 9;

/// INPUT 構造体の大きさ (64bit Windows)。
///   type(4) + 詰め物(4) + 共用体(32) = 40
const int _kInputSize = 40;

// ── 関数の型 ────────────────────────────────────────────────────────────
typedef _SendInputNative = ffi.Uint32 Function(
    ffi.Uint32 cInputs, ffi.Pointer<ffi.Uint8> pInputs, ffi.Int32 cbSize);
typedef _SendInputDart = int Function(
    int cInputs, ffi.Pointer<ffi.Uint8> pInputs, int cbSize);

typedef _GetSystemMetricsNative = ffi.Int32 Function(ffi.Int32 nIndex);
typedef _GetSystemMetricsDart = int Function(int nIndex);

typedef _SetCursorPosNative = ffi.Int32 Function(ffi.Int32 x, ffi.Int32 y);
typedef _SetCursorPosDart = int Function(int x, int y);

typedef _GetCursorPosNative = ffi.Int32 Function(ffi.Pointer<ffi.Int32> pt);
typedef _GetCursorPosDart = int Function(ffi.Pointer<ffi.Int32> pt);

typedef _EnumWindowsNative = ffi.Int32 Function(
    ffi.Pointer<ffi.NativeFunction<ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr)>>
        cb,
    ffi.IntPtr lParam);
typedef _EnumWindowsDart = int Function(
    ffi.Pointer<ffi.NativeFunction<ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr)>>
        cb,
    int lParam);

typedef _GetWindowTextWNative = ffi.Int32 Function(
    ffi.IntPtr hWnd, ffi.Pointer<Utf16> buf, ffi.Int32 maxCount);
typedef _GetWindowTextWDart = int Function(
    int hWnd, ffi.Pointer<Utf16> buf, int maxCount);

typedef _IsWindowVisibleNative = ffi.Int32 Function(ffi.IntPtr hWnd);
typedef _IsWindowVisibleDart = int Function(int hWnd);

typedef _SetForegroundWindowNative = ffi.Int32 Function(ffi.IntPtr hWnd);
typedef _SetForegroundWindowDart = int Function(int hWnd);

typedef _ShowWindowNative = ffi.Int32 Function(
    ffi.IntPtr hWnd, ffi.Int32 nCmdShow);
typedef _ShowWindowDart = int Function(int hWnd, int nCmdShow);

/// 見えている窓ひとつ。
class DesktopWindow {
  final int handle;
  final String title;
  const DesktopWindow(this.handle, this.title);
  @override
  String toString() => title;
}

/// 押せるボタン。
enum MouseButton { left, right, middle }

// ── 窓の一覧を集める (EnumWindows の受け口は静的関数でないといけない) ──
final List<DesktopWindow> _collected = [];
// ★ late final にしない。 listWindows() は何度でも呼ばれるので、
//   late final だと 2 回目の代入で例外になる
//   (LateInitializationError: Field has already been initialized)。
_GetWindowTextWDart? _getWindowTextForEnum;
_IsWindowVisibleDart? _isVisibleForEnum;

int _enumProc(int hWnd, int lParam) {
  try {
    if (_isVisibleForEnum?.call(hWnd) == 0) return 1;
    final buf = calloc<ffi.Uint16>(512).cast<Utf16>();
    try {
      final n = _getWindowTextForEnum?.call(hWnd, buf, 512) ?? 0;
      if (n > 0) {
        final t = buf.toDartString();
        if (t.trim().isNotEmpty) _collected.add(DesktopWindow(hWnd, t));
      }
    } finally {
      calloc.free(buf);
    }
  } catch (_) {}
  return 1; // 1 = 続ける
}

/// パソコンを直に操作する口。
class DesktopInput {
  DesktopInput._();

  /// ★ 既定では動かない。 利用者がはっきり許した時だけ true にすること。
  static bool enabled = false;

  static bool get isSupported {
    try {
      return Platform.isWindows;
    } catch (_) {
      return false;
    }
  }

  static bool get _ready => isSupported && enabled;

  static ffi.DynamicLibrary? _user32lib;
  static ffi.DynamicLibrary get _user32 =>
      _user32lib ??= ffi.DynamicLibrary.open('user32.dll');

  static _SendInputDart? _sendInput;
  static _SendInputDart get _send => _sendInput ??=
      _user32.lookupFunction<_SendInputNative, _SendInputDart>('SendInput');

  static _GetSystemMetricsDart? _metrics;
  static _GetSystemMetricsDart get _sysMetrics =>
      _metrics ??= _user32.lookupFunction<_GetSystemMetricsNative,
          _GetSystemMetricsDart>('GetSystemMetrics');

  /// 画面全体 (複数のモニタを含む) の大きさ。
  static ({int x, int y, int width, int height}) screenBounds() {
    if (!isSupported) return (x: 0, y: 0, width: 0, height: 0);
    try {
      return (
        x: _sysMetrics(_kSmXVirtual),
        y: _sysMetrics(_kSmYVirtual),
        width: _sysMetrics(_kSmCxVirtual),
        height: _sysMetrics(_kSmCyVirtual),
      );
    } catch (_) {
      return (x: 0, y: 0, width: 0, height: 0);
    }
  }

  /// 今のマウスの位置。
  static ({int x, int y})? cursorPos() {
    if (!isSupported) return null;
    final p = calloc<ffi.Int32>(2);
    try {
      final f = _user32
          .lookupFunction<_GetCursorPosNative, _GetCursorPosDart>('GetCursorPos');
      if (f(p) == 0) return null;
      return (x: p[0], y: p[1]);
    } catch (_) {
      return null;
    } finally {
      calloc.free(p);
    }
  }

  /// INPUT の並びを組み立てて送る。
  static bool _sendRaw(List<void Function(ByteData d, int base)> writers) {
    if (!_ready || writers.isEmpty) return false;
    final n = writers.length;
    final mem = calloc<ffi.Uint8>(_kInputSize * n);
    try {
      final bytes = mem.asTypedList(_kInputSize * n);
      final view = ByteData.sublistView(bytes);
      for (var i = 0; i < n; i++) {
        writers[i](view, i * _kInputSize);
      }
      final sent = _send(n, mem, _kInputSize);
      return sent == n;
    } catch (e) {
      _warn('DesktopInput.send 失敗: $e');
      return false;
    } finally {
      calloc.free(mem);
    }
  }

  /// マウスの INPUT を 1 つ書く。
  ///   並び: type@0 / dx@8 / dy@12 / mouseData@16 / dwFlags@20 /
  ///        time@24 / dwExtraInfo@32
  static void Function(ByteData, int) _mouse(
      {int dx = 0, int dy = 0, int data = 0, required int flags}) {
    return (d, b) {
      d.setUint32(b + 0, _kInputMouse, Endian.little);
      d.setInt32(b + 8, dx, Endian.little);
      d.setInt32(b + 12, dy, Endian.little);
      d.setUint32(b + 16, data, Endian.little);
      d.setUint32(b + 20, flags, Endian.little);
      d.setUint32(b + 24, 0, Endian.little);
      d.setUint64(b + 32, 0, Endian.little);
    };
  }

  /// キーボードの INPUT を 1 つ書く。
  ///   並び: type@0 / wVk@8 / wScan@10 / dwFlags@12 / time@16 /
  ///        dwExtraInfo@24
  static void Function(ByteData, int) _key(
      {int vk = 0, int scan = 0, required int flags}) {
    return (d, b) {
      d.setUint32(b + 0, _kInputKeyboard, Endian.little);
      d.setUint16(b + 8, vk, Endian.little);
      d.setUint16(b + 10, scan, Endian.little);
      d.setUint32(b + 12, flags, Endian.little);
      d.setUint32(b + 16, 0, Endian.little);
      d.setUint64(b + 24, 0, Endian.little);
    };
  }

  /// 画面上の座標を、 SendInput が使う 0〜65535 の目盛りに直す。
  static (int, int) _normalize(int x, int y) {
    final b = screenBounds();
    if (b.width <= 0 || b.height <= 0) return (0, 0);
    final nx = ((x - b.x) * 65535 / (b.width - 1)).round().clamp(0, 65535);
    final ny = ((y - b.y) * 65535 / (b.height - 1)).round().clamp(0, 65535);
    return (nx, ny);
  }

  /// マウスをその場所へ動かす (押さない)。
  static bool moveTo(int x, int y) {
    if (!_ready) return false;
    final (nx, ny) = _normalize(x, y);
    return _sendRaw([
      _mouse(
          dx: nx,
          dy: ny,
          flags: _kMouseMove | _kMouseAbsolute | _kMouseVirtualDesk),
    ]);
  }

  /// その場所を押す。 [count] 2 で二度押し。
  static bool click(int x, int y,
      {MouseButton button = MouseButton.left, int count = 1}) {
    if (!_ready) return false;
    if (!moveTo(x, y)) return false;
    final (down, up) = switch (button) {
      MouseButton.right => (_kMouseRightDown, _kMouseRightUp),
      MouseButton.middle => (_kMouseMiddleDown, _kMouseMiddleUp),
      MouseButton.left => (_kMouseLeftDown, _kMouseLeftUp),
    };
    final w = <void Function(ByteData, int)>[];
    for (var i = 0; i < count.clamp(1, 3); i++) {
      w.add(_mouse(flags: down));
      w.add(_mouse(flags: up));
    }
    return _sendRaw(w);
  }

  /// 縦に転がす。 [notches] 正で上、 負で下。
  static bool scroll(int notches) {
    if (!_ready) return false;
    return _sendRaw([
      _mouse(data: notches * 120, flags: _kMouseWheel),
    ]);
  }

  /// 文字をそのまま打ち込む (キーボードの配列に左右されない)。
  static bool typeText(String text) {
    if (!_ready || text.isEmpty) return false;
    final w = <void Function(ByteData, int)>[];
    for (final unit in text.codeUnits) {
      w.add(_key(scan: unit, flags: _kKeyUnicode));
      w.add(_key(scan: unit, flags: _kKeyUnicode | _kKeyUp));
      // 一度に送り過ぎると取りこぼすので、 適当な所で区切る。
      if (w.length >= 200) {
        if (!_sendRaw(w)) return false;
        w.clear();
      }
    }
    return w.isEmpty || _sendRaw(w);
  }

  /// 名前で引ける主なキー。
  static const Map<String, int> _vkNames = {
    'enter': 0x0D, 'return': 0x0D, 'tab': 0x09, 'esc': 0x1B, 'escape': 0x1B,
    'space': 0x20, 'backspace': 0x08, 'delete': 0x2E, 'del': 0x2E,
    'home': 0x24, 'end': 0x23, 'pageup': 0x21, 'pagedown': 0x22,
    'left': 0x25, 'up': 0x26, 'right': 0x27, 'down': 0x28,
    'ctrl': 0x11, 'control': 0x11, 'shift': 0x10, 'alt': 0x12,
    'win': 0x5B, 'meta': 0x5B,
    'f1': 0x70, 'f2': 0x71, 'f3': 0x72, 'f4': 0x73, 'f5': 0x74, 'f6': 0x75,
    'f11': 0x7A, 'f12': 0x7B,
  };

  static int _vkFor(String name) {
    final k = name.trim().toLowerCase();
    if (_vkNames.containsKey(k)) return _vkNames[k]!;
    if (k.length == 1) {
      final c = k.toUpperCase().codeUnitAt(0);
      // A-Z / 0-9 はそのまま仮想キーコードになる。
      if ((c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)) return c;
    }
    return 0;
  }

  /// 同時押し。 例: ['ctrl','l'] / ['alt','f4'] / ['enter']
  static bool pressKeys(List<String> keys) {
    if (!_ready || keys.isEmpty) return false;
    final vks = keys.map(_vkFor).where((v) => v != 0).toList();
    if (vks.isEmpty) return false;
    final w = <void Function(ByteData, int)>[];
    for (final v in vks) {
      w.add(_key(vk: v, flags: v == 0x5B ? _kKeyExtended : 0));
    }
    for (final v in vks.reversed) {
      w.add(_key(vk: v, flags: (v == 0x5B ? _kKeyExtended : 0) | _kKeyUp));
    }
    return _sendRaw(w);
  }

  /// 見えている窓の一覧 (題名つき)。 許可が無くても読める。
  static List<DesktopWindow> listWindows() {
    if (!isSupported) return const [];
    try {
      _getWindowTextForEnum = _user32.lookupFunction<_GetWindowTextWNative,
          _GetWindowTextWDart>('GetWindowTextW');
      _isVisibleForEnum = _user32.lookupFunction<_IsWindowVisibleNative,
          _IsWindowVisibleDart>('IsWindowVisible');
      _collected.clear();
      final enumWindows = _user32
          .lookupFunction<_EnumWindowsNative, _EnumWindowsDart>('EnumWindows');
      final cb = ffi.Pointer.fromFunction<
          ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr)>(_enumProc, 0);
      enumWindows(cb, 0);
      return List<DesktopWindow>.from(_collected);
    } catch (e) {
      _warn('DesktopInput.listWindows 失敗: $e');
      return const [];
    }
  }

  /// 題名の一部が合う窓を前に出す。 出せたら true。
  static bool activateWindow(String titleContains) {
    if (!_ready) return false;
    final want = titleContains.trim().toLowerCase();
    if (want.isEmpty) return false;
    try {
      final hit = listWindows().where(
          (w) => w.title.toLowerCase().contains(want));
      if (hit.isEmpty) return false;
      final show = _user32
          .lookupFunction<_ShowWindowNative, _ShowWindowDart>('ShowWindow');
      final fore = _user32.lookupFunction<_SetForegroundWindowNative,
          _SetForegroundWindowDart>('SetForegroundWindow');
      show(hit.first.handle, _kSwRestore);
      return fore(hit.first.handle) != 0;
    } catch (e) {
      _warn('DesktopInput.activateWindow 失敗: $e');
      return false;
    }
  }
}
