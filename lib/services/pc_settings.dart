// パソコン側の設定 (マウスの感度 / スクリーンセーバー / スリープ・電源) を
// アプリから触るための道具 (= ユーザー要望「PC設定」)。
//
// Windows 専用。 他の OS では [isSupported] が false を返し、 読み書きは
// 黙って諦める (画面側は項目そのものを出さない)。
//
// ★ 外の道具は原則呼ばない。
//   以前ディスプレイ設定が PowerShell を起動していて、 利用者の
//   セキュリティソフトに「悪意ある行動」 として止められた
//   ([[win32-com-and-os-settings]])。 ここは全部その場で Win32 を呼ぶ。
//
//   **唯一の例外がスクリーンセーバーのプレビュー / 設定**
//   ([previewScreenSaver] / [configureScreenSaver])。 .scr は「絵を出す
//   プログラム」 そのもので、 中から真似る事ができない。 Windows の
//   「設定」 のプレビューと全く同じ事 (`その .scr /s`) をする。 上の件と
//   違うのは次の 4 点で、 これは必ず守る:
//     ・ボタンを押した時だけ。 設定を開いただけでは決して動かさない
//     ・cmd.exe / powershell.exe を通さない (引数は配列でそのまま渡す)
//     ・実在する .scr だけ。 %SystemRoot% の外は一度確かめてから
//     ・隠して動かさない (全画面に出る)
//
// ── 何を触っているか ────────────────────────────────────────────────
//  マウス感度        SystemParametersInfo(SPI_GET/SETMOUSESPEED)  1〜20
//  ポインター精度    SystemParametersInfo(SPI_GET/SETMOUSE)       加速の有無
//  ポインターの伸び  HKCU\Control Panel\Mouse\SmoothMouseYCurve   加速の曲線
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

// ── Windows の見た目 (明るい / 暗い) ─────────────────────────────────
//   HKCU\...\Themes\Personalize の 2 つの値で決まる。
//   1 = 明るい / 0 = 暗い。 書いた後は「設定が変わった」 と放送して、
//   起動中のアプリにも反映させる。
const String _kPersonalizeKey =
    r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';
const String _kAppsUseLightTheme = 'AppsUseLightTheme';
const String _kSystemUsesLightTheme = 'SystemUsesLightTheme';
const int _hwndBroadcast = 0xFFFF;
const int _wmSettingChange = 0x001A;
const int _smtoAbortIfHung = 0x0002;

typedef _SendMsgTimeoutNative = ffi.IntPtr Function(
    ffi.IntPtr hWnd,
    ffi.Uint32 msg,
    ffi.IntPtr wParam,
    ffi.Pointer<pkgffi.Utf16> lParam,
    ffi.Uint32 flags,
    ffi.Uint32 timeout,
    ffi.Pointer<ffi.IntPtr> result);
typedef _SendMsgTimeoutDart = int Function(
    int hWnd,
    int msg,
    int wParam,
    ffi.Pointer<pkgffi.Utf16> lParam,
    int flags,
    int timeout,
    ffi.Pointer<ffi.IntPtr> result);

/// Windows の見た目 (明るい / 暗い) の今の状態。
class PcThemeState {
  /// アプリの見た目が暗いか。
  final bool appsDark;

  /// タスクバー / スタートの見た目が暗いか。
  final bool systemDark;
  const PcThemeState({required this.appsDark, required this.systemDark});
}

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

// ── .scr が自分で名乗っている名前 (version.dll) ─────────────────────
typedef _VerInfoSizeNative = ffi.Uint32 Function(
    ffi.Pointer<pkgffi.Utf16>, ffi.Pointer<ffi.Uint32>);
typedef _VerInfoSizeDart = int Function(
    ffi.Pointer<pkgffi.Utf16>, ffi.Pointer<ffi.Uint32>);

typedef _VerInfoNative = ffi.Int32 Function(ffi.Pointer<pkgffi.Utf16>,
    ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Void>);
typedef _VerInfoDart = int Function(
    ffi.Pointer<pkgffi.Utf16>, int, int, ffi.Pointer<ffi.Void>);

typedef _VerQueryNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<pkgffi.Utf16>,
    ffi.Pointer<ffi.Pointer<ffi.Void>>,
    ffi.Pointer<ffi.Uint32>);
typedef _VerQueryDart = int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<pkgffi.Utf16>,
    ffi.Pointer<ffi.Pointer<ffi.Void>>,
    ffi.Pointer<ffi.Uint32>);

/// 設定ダイアログ (/c) の親にする窓。
typedef _GetForegroundWindowNative = ffi.IntPtr Function();
typedef _GetForegroundWindowDart = int Function();

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

/// 同じ場所にある、 開始までの時間 / 動かすか / サインインを求めるか。
/// どれも**文字**で入っている (実測: ScreenSaveTimeOut は REG_SZ の "60")。
/// SCRNSAVE.EXE とは別々に持たれているので、 「なし」 のままでも書ける。
const String _kTimeoutValue = 'ScreenSaveTimeOut';
const String _kActiveValue = 'ScreenSaveActive';
const String _kSecureValue = 'ScreenSaverIsSecure';

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

/// 書き込みの結果。
///
/// Windows は画面まわりの都合で断る事がある (実測: 画面が省電力に入った
/// 後などは SystemParametersInfo が ERROR_OPERATION_IN_PROGRESS = 329 を
/// 返す)。 断られても控え (レジストリ) には書けるので、 「今は効かないが
/// 覚えた」 を [pending] として区別し、 画面側で一言添える。
enum PcWriteResult {
  /// その場で効いた。
  ok,

  /// 控えには書けた。 サインインし直すと効く。
  pending,

  /// どちらも書けなかった。
  failed,
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
  static ffi.DynamicLibrary? _versionlib;
  static ffi.DynamicLibrary get _version =>
      _versionlib ??= ffi.DynamicLibrary.open('version.dll');

  static _SpiDart? _spiFn;
  static _SpiDart get _spi => _spiFn ??=
      _user32.lookupFunction<_SpiNative, _SpiDart>('SystemParametersInfoW');

  // ── Windows の見た目 (明るい / 暗い) ───────────────────────────────
  //
  // ★ = ユーザー要望「PC 自体のダークモードとの切り替えもアプリの
  //   ディスプレイ設定でできるように」。 Windows の「設定 > 個人用設定 >
  //   色」 と同じ所 (レジストリ) を書く。 外の道具は使わない。

  static _SendMsgTimeoutDart? _sendMsgFn;
  static _SendMsgTimeoutDart get _sendMsg =>
      _sendMsgFn ??= _user32.lookupFunction<_SendMsgTimeoutNative,
          _SendMsgTimeoutDart>('SendMessageTimeoutW');

  /// 今の見た目を読む。 値が無い時は Windows の既定 = 明るい。
  static PcThemeState readTheme() {
    if (!isSupported) {
      return const PcThemeState(appsDark: false, systemDark: false);
    }
    var apps = false;
    var sys = false;
    try {
      final key = Registry.openPath(RegistryHive.currentUser,
          path: _kPersonalizeKey,
          desiredAccessRights: AccessRights.readOnly);
      apps = (key.getValueAsInt(_kAppsUseLightTheme) ?? 1) == 0;
      sys = (key.getValueAsInt(_kSystemUsesLightTheme) ?? 1) == 0;
      key.close();
    } catch (_) {}
    return PcThemeState(appsDark: apps, systemDark: sys);
  }

  /// 見た目を変える。 [appsDark] = アプリ、 [systemDark] = タスクバー /
  /// スタート。 null の所は今のまま。 戻り値 true = 書けた。
  static bool setTheme({bool? appsDark, bool? systemDark}) {
    if (!isSupported) return false;
    if (appsDark == null && systemDark == null) return false;
    try {
      final key = Registry.openPath(RegistryHive.currentUser,
          path: _kPersonalizeKey,
          desiredAccessRights: AccessRights.allAccess);
      if (appsDark != null) {
        key.createValue(
            RegistryValue.int32(_kAppsUseLightTheme, appsDark ? 0 : 1));
      }
      if (systemDark != null) {
        key.createValue(
            RegistryValue.int32(_kSystemUsesLightTheme, systemDark ? 0 : 1));
      }
      key.close();
    } catch (_) {
      return false;
    }
    // 起動中のアプリにも今すぐ効かせる (無いと次に開いた窓からになる)。
    _broadcastImmersiveColorSet();
    return true;
  }

  /// 「色の設定が変わった」 と全部の窓へ知らせる。
  static void _broadcastImmersiveColorSet() {
    final lp = 'ImmersiveColorSet'.toNativeUtf16(allocator: pkgffi.calloc);
    final res = pkgffi.calloc<ffi.IntPtr>();
    try {
      _sendMsg(_hwndBroadcast, _wmSettingChange, 0, lp, _smtoAbortIfHung,
          200, res);
    } catch (_) {
      // 知らせられなくても、 レジストリには書けているので次回から効く。
    } finally {
      pkgffi.calloc.free(lp);
      pkgffi.calloc.free(res);
    }
  }

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

  // ── ポインターの伸び (加速の曲線) ────────────────────────────────
  //
  // 「20 でも遅い」 と言われた時の話 (= ユーザー要望「ポインターの速さって
  // もっと早くできない?」)。 SPI_SETMOUSESPEED は 1〜20 が Windows の上限で、
  // 20 は既に **標準 (10) の 3.5 倍**。 21 は無い。
  //
  // その先へ行く手は 1 つだけ ── **加速の曲線を書き換える**。
  //
  //   HKCU\Control Panel\Mouse\SmoothMouseYCurve  (REG_BINARY / 40 バイト)
  //     折れ点 5 個 × 8 バイト。 各 8 バイトのうち **先頭 4 バイトだけ**が
  //     意味を持ち、 リトルエンディアンの 16.16 固定小数 (= 実数 ×65536)。
  //     残り 4 バイトは Windows が常に 0 を入れている。
  //     X 側が「手を動かした速さ」、 Y 側が「その時ポインターが進む量」。
  //     Y を丸ごと k 倍すれば、 どの速さでも k 倍進むようになる。
  //
  // ★ 必ず伝えないといけない事が 3 つある。
  //   1. この曲線は 「ポインターの精度を高める」 が入っている時だけ使われる。
  //   2. 書いても **サインインし直すまで効かない**。 Windows に読み直させる
  //      口が公開されていない (SPI_SETMOUSE でも駄目)。
  //   3. 逆に言うと、 速すぎた時は 「精度を高める」 を切れば **その場で**
  //      元の動きに戻る (そちらは即座に効く)。 これが逃げ道になる。
  //
  // 元の 40 バイトは HKCU\Software\HisatorNotebook\Mouse に控えておき、
  // 「元に戻す」 でそのまま書き戻す。 Windows の既定値は **画面の拡大率で
  // 変わる**ので、 決め打ちの既定を書き戻してはいけない。

  static const String _kMouseKey = r'Control Panel\Mouse';
  static const String _kYCurveValue = 'SmoothMouseYCurve';
  static const String _kOurKey = r'Software\HisatorNotebook\Mouse';
  static const String _kYCurveOrig = 'SmoothMouseYCurveOrig';
  static const String _kYCurveHad = 'SmoothMouseYCurveHad';
  static const String _kBoostPercent = 'PointerBoostPercent';

  /// 引き伸ばしを入れる前の「ポインターの精度を高める」 の入り切り。
  /// 曲線はその札が入っていないと使われないのでこちらで入れる事になる。
  /// 「戻す」 で元へ返せるように控えておく。
  static const String _kAccelOrig = 'AccelWasOn';

  /// 感度 1〜20 が「標準 (10) の何倍」 に当たるか。
  ///
  /// Windows の中の表。 設定アプリのつまみが触れるのは 1/2/4/6/8/10/12/
  /// 14/16/18/20 の 11 段で、 そこの値ははっきりしている。 間の奇数は
  /// 見出し用に前後の真ん中を置いてあるだけ (表示にしか使わない)。
  static const List<double> _kSpeedFactor = <double>[
    0.03125, 0.0625, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1.0, //
    1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 3.25, 3.5,
  ];

  /// 感度 [speed] が標準の何倍か。 20 で 3.5 倍 (= Windows の上限)。
  static double mouseSpeedFactor(int speed) =>
      _kSpeedFactor[speed.clamp(1, 20) - 1];

  /// 上を人に見せる形にした物 (「3.50」 のような)。
  static String mouseSpeedFactorLabel(int speed) {
    final f = mouseSpeedFactor(speed);
    return f >= 1 ? f.toStringAsFixed(2) : f.toStringAsFixed(5);
  }

  // ★ 「既定の曲線」 を決め打ちで持つのはやめた。
  //   Windows が書く既定は**画面の拡大率で変わる**ので、 96 DPI の値を
  //   書き戻すと「戻した筈なのに前と違う」 になる。 出回っている「既定」 の
  //   バイト列も 1 種類ではない。 今の曲線が読めない時は、 土台が無いという
  //   事なので**引き伸ばしを行わない** (戻せない物は作らない)。

  /// 40 バイトの曲線を [percent] % にする。
  /// 8 バイトごとの先頭 4 バイトだけを掛ける (残りは触らない)。
  static Uint8List _scaleCurve(Uint8List src, int percent) {
    final out = Uint8List.fromList(src);
    for (var i = 0; i + 8 <= out.length; i += 8) {
      final v = out[i] |
          (out[i + 1] << 8) |
          (out[i + 2] << 16) |
          (out[i + 3] << 24);
      var n = (v * percent) ~/ 100;
      if (n > 0xFFFFFFFF) n = 0xFFFFFFFF;
      out[i] = n & 0xFF;
      out[i + 1] = (n >> 8) & 0xFF;
      out[i + 2] = (n >> 16) & 0xFF;
      out[i + 3] = (n >> 24) & 0xFF;
    }
    return out;
  }

  /// 引き伸ばしの計算だけを取り出した口 (テスト用)。
  /// レジストリには触らないので、 `flutter test` から安全に確かめられる。
  static Uint8List debugScaleCurve(Uint8List src, int percent) =>
      _scaleCurve(src, percent);

  /// 今かけている伸び (100 = 何もしていない)。
  static int readPointerBoost() {
    if (!isSupported) return 100;
    try {
      final k = Registry.openPath(RegistryHive.currentUser,
          path: _kOurKey, desiredAccessRights: AccessRights.readOnly);
      final v = k.getIntValue(_kBoostPercent) ?? 100;
      k.close();
      return v.clamp(100, 300);
    } catch (_) {
      // 控えの入れ物がまだ無い = 何もしていない。
      return 100;
    }
  }

  /// 加速の曲線を [percent] % に引き伸ばす (100 = 元のまま、 300 が上限)。
  ///
  /// 何度動かしても **必ず控えを土台に**掛け直すので、 積み重なって
  /// どんどん速くなる事は無い。
  ///
  /// ★ 効き始めるのは **サインインし直してから**。
  static bool setPointerBoost(int percent) {
    if (!isSupported) return false;
    final pct = percent.clamp(100, 300);
    if (pct == 100) return resetPointerBoost();
    final root = _openCurrentUser();
    if (root == null) return false;
    try {
      final ours = root.createKey(_kOurKey);
      final mouse = Registry.openPath(RegistryHive.currentUser,
          path: _kMouseKey, desiredAccessRights: AccessRights.allAccess);
      try {
        // 1) 初回だけ、 今の 40 バイトと「精度を高める」 の入り切りを控える。
        var orig = ours.getBinaryValue(_kYCurveOrig);
        if (orig == null || orig.length != 40) {
          final cur = mouse.getBinaryValue(_kYCurveValue);
          // ★ 今の曲線が読めない時は何もしない。 決め打ちの既定を書くと
          //   元に戻せなくなる (既定は拡大率で違う)。
          if (cur == null || cur.length != 40) return false;
          orig = cur;
          ours.createValue(RegistryValue.binary(_kYCurveOrig, orig));
          ours.createValue(RegistryValue.int32(_kYCurveHad, 1));
          // 曲線は「精度を高める」 が入っていないと使われない。 こちらで
          //   入れる事になるので、 元の状態も控えて 戻せるようにする。
          ours.createValue(RegistryValue.int32(
              _kAccelOrig, readMouse().acceleration ? 1 : 0));
        }
        // 2) 控えを土台に掛け直す (何度動かしても積み重ならない)。
        mouse.createValue(
            RegistryValue.binary(_kYCurveValue, _scaleCurve(orig, pct)));
        ours.createValue(RegistryValue.int32(_kBoostPercent, pct));
        // 3) Windows に「設定を読み直せ」 と伝えておく。 曲線が読み直される
        //   保証は無い (資料に無い) が、 ただで済むので押しておく。
        _nudgeUserParams();
        return true;
      } finally {
        mouse.close();
        ours.close();
      }
    } catch (_) {
      return false;
    } finally {
      root.close();
    }
  }

  /// Windows の元の曲線に戻す。
  ///
  /// 控えがあればそれを書き戻し、 元々 値が無かったなら消して
  /// Windows に任せる。 どちらもサインインし直した時から効く。
  static bool resetPointerBoost() {
    if (!isSupported) return false;
    final root = _openCurrentUser();
    if (root == null) return false;
    try {
      final ours = root.createKey(_kOurKey);
      final mouse = Registry.openPath(RegistryHive.currentUser,
          path: _kMouseKey, desiredAccessRights: AccessRights.allAccess);
      try {
        final orig = ours.getBinaryValue(_kYCurveOrig);
        final had = (ours.getIntValue(_kYCurveHad) ?? 1) != 0;
        if (orig != null && orig.length == 40) {
          // 控えた物をそのまま書き戻す。
          mouse.createValue(RegistryValue.binary(_kYCurveValue, orig));
        } else if (orig == null && !had) {
          // 元々 値が無かったと分かっている時だけ消す。
          try {
            mouse.deleteValue(_kYCurveValue);
          } catch (_) {}
        }
        // ★ 控えが壊れている時 (40 バイトでない) は**何もしない**。
        //   決め打ちの既定を書くのも消すのも、 利用者の設定を壊す側に倒れる。
        // 一緒に入れた「精度を高める」 も元へ戻す。 曲線はサインインし直す
        //   まで効かないので、 **その場で効く唯一の戻し**がこれ。
        final accel = ours.getIntValue(_kAccelOrig);
        if (accel != null) setMouseAcceleration(accel != 0);
        for (final n in const [
          _kYCurveOrig,
          _kYCurveHad,
          _kBoostPercent,
          _kAccelOrig,
        ]) {
          try {
            ours.deleteValue(n);
          } catch (_) {}
        }
        _nudgeUserParams();
        return true;
      } finally {
        mouse.close();
        ours.close();
      }
    } catch (_) {
      return false;
    } finally {
      root.close();
    }
  }

  /// HKCU を開く (使い終わったら閉じる事。 毎回新しい鍵が返る)。
  static RegistryKey? _openCurrentUser() {
    try {
      return Registry.currentUser;
    } catch (_) {
      return null;
    }
  }

  /// 「利用者ごとの設定を読み直せ」 と Windows に伝える。
  /// 曲線が読み直される保証は無いが、 害は無いので押しておく。
  static void _nudgeUserParams() {
    try {
      _spi(0x002F /* SPI_UPDATEPERUSERSYSTEMPARAMETERS */, 0,
          ffi.Pointer<ffi.Void>.fromAddress(0), _spifUpdateAndSend);
    } catch (_) {}
  }

  /// ホイール 1 段で流れる行数だけを、 軽く読む。
  /// -1 = 1 画面ぶん (WHEEL_PAGESCROLL)、 0 = 読めなかった。
  ///
  /// [readMouse] は感度・加速・ダブルクリックまで一度に読むので、 ホイールを
  /// 回している最中に呼ぶには重い。 ここは SystemParametersInfo を 1 回だけ叩く。
  static int readWheelScrollLines() {
    if (!isSupported) return 0;
    final buf = pkgffi.calloc<ffi.Int32>(1);
    try {
      if (_spi(_spiGetWheelScrollLines, 0, buf.cast(), 0) != 0) {
        return buf[0];
      }
    } catch (_) {
    } finally {
      pkgffi.calloc.free(buf);
    }
    return 0;
  }

  /// ホイール 1 段で流れる行数 (1〜30)。
  static bool setWheelScrollLines(int lines) {
    if (!isSupported) return false;
    final v = lines.clamp(1, 30);
    try {
      return _spi(_spiSetWheelScrollLines, v,
              ffi.Pointer<ffi.Void>.fromAddress(0), _spifUpdateAndSend) !=
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

  /// Windows に付いてくる物の、 分かりやすい名前 (**控えの手立て**)。
  ///
  /// ふだんは .scr 自身が名乗っている名前 ([_fileDescription]) を使う。
  /// ここはバージョン情報が壊れている / 入っていない時だけ使う。
  ///
  /// ★ 'mystify' はもともと「ブランク線」 と書いてあったが、 Windows が
  ///   名乗っているのは「ライン アート」 だった (実測)。 直してある。
  static const Map<String, String> _kKnownSavers = {
    'bubbles': 'バブル',
    'mystify': 'ライン アート',
    'ribbons': 'リボン',
    'photoscreensaver': '写真',
    'sstext3d': '3D テキスト',
    'scrnsave': 'ブランク (真っ暗)',
  };

  /// 自分の設定 (/c) を持っていない、 Windows 内蔵の物。
  ///
  /// ★ 「設定を持っているか」 を確かめる決まった手立ては無い。 資源
  ///   (RT_DIALOG 2003 = DLG_SCRNSAVECONFIGURE) を見る手を実機で試したが、
  ///   持っていたのは写真だけ。 設定がある 3D テキストは持っておらず、
  ///   設定の無いバブルと全く同じ並び (105/200/201) だった。 当てにならない。
  ///   Windows 自身もこの 4 つを決め打ちで灰色にしているので、 同じにする。
  ///   知らない物には設定ボタンを出して、 相手に任せる。
  static const Set<String> _kSaversWithoutConfig = {
    'bubbles',
    'mystify',
    'ribbons',
    'scrnsave',
  };

  /// 一度読んだ .scr の一覧を覚えておく (バージョン情報を読むぶん少し重く、
  /// アプリが動いている間に増減する物でもないため)。
  static List<({String path, String name})>? _saverCache;

  /// HKCU\Control Panel\Desktop の 1 つを読む。
  static String? _readDesktopValue(String name) {
    try {
      final key = Registry.openPath(RegistryHive.currentUser,
          path: _kDesktopKey, desiredAccessRights: AccessRights.readOnly);
      final v = key.getValueAsString(name);
      key.close();
      return v?.trim();
    } catch (_) {
      return null;
    }
  }

  /// HKCU\Control Panel\Desktop の 1 つに文字で書く (Windows が使う形)。
  static bool _writeDesktopValue(String name, String value) {
    try {
      final key = Registry.openPath(RegistryHive.currentUser,
          path: _kDesktopKey, desiredAccessRights: AccessRights.allAccess);
      key.createValue(RegistryValue.string(name, value));
      key.close();
      return true;
    } catch (_) {
      return false;
    }
  }

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
    // ★ 控え (レジストリ) の方を後から重ねる。
    //   SystemParametersInfo は断る事がある (画面が省電力に入った後などは
    //   ERROR_OPERATION_IN_PROGRESS = 329。 実機で再現した)。 その時は
    //   控えにだけ書いてあるので、 ここで控えを見ないと
    //   **動かしたつまみが元に戻る** = 「設定できない」 に逆戻りする。
    //   うまく書けた時は SPIF_UPDATEINIFILE で両方同じ値になっているので、
    //   どちらを見ても違いは出ない。
    final regTimeout = int.tryParse(_readDesktopValue(_kTimeoutValue) ?? '');
    if (regTimeout != null && regTimeout > 0) timeout = regTimeout;
    final regActive = _readDesktopValue(_kActiveValue);
    if (regActive != null && regActive.isNotEmpty) active = regActive != '0';
    final regSecure = _readDesktopValue(_kSecureValue);
    if (regSecure != null && regSecure.isNotEmpty) secure = regSecure != '0';
    final path = _readDesktopValue(_kScrnSaveValue) ?? '';
    return PcScreenSaverState(
      active: active,
      timeoutSec: timeout,
      secure: secure,
      path: path,
      choices: listScreenSavers(),
    );
  }

  /// .scr が自分で名乗っている名前 (バージョン情報の FileDescription)。
  ///
  /// Windows の「設定」 が出しているのと同じ文字で、 **OS の言葉で**
  /// 入っている (実測: 日本語環境で「3D テキスト スクリーン セーバー」
  /// 「ライン アート スクリーン セーバー」)。 手書きの対応表より正確。
  static String? _fileDescription(String path) {
    if (!isSupported) return null;
    final pathP = path.toNativeUtf16(allocator: pkgffi.calloc);
    final sizeHandle = pkgffi.calloc<ffi.Uint32>();
    final outP = pkgffi.calloc<ffi.Pointer<ffi.Void>>();
    final lenP = pkgffi.calloc<ffi.Uint32>();
    ffi.Pointer<ffi.Uint8> block = ffi.nullptr;
    ffi.Pointer<pkgffi.Utf16> transP = ffi.nullptr;
    ffi.Pointer<pkgffi.Utf16> descP = ffi.nullptr;
    try {
      final sizeFn = _version
          .lookupFunction<_VerInfoSizeNative, _VerInfoSizeDart>(
              'GetFileVersionInfoSizeW');
      final size = sizeFn(pathP, sizeHandle);
      if (size == 0) return null;
      block = pkgffi.calloc<ffi.Uint8>(size);
      final getFn = _version
          .lookupFunction<_VerInfoNative, _VerInfoDart>('GetFileVersionInfoW');
      if (getFn(pathP, 0, size, block.cast()) == 0) return null;
      final queryFn = _version
          .lookupFunction<_VerQueryNative, _VerQueryDart>('VerQueryValueW');
      // どの言葉で入っているかは、 ファイルが自分で名乗っている。
      var lang = 0x0409; // 既定: 英語 (米国)
      var page = 0x04B0; // 既定: Unicode
      transP = r'\VarFileInfo\Translation'
          .toNativeUtf16(allocator: pkgffi.calloc);
      if (queryFn(block.cast(), transP, outP, lenP) != 0 &&
          lenP.value >= 4 &&
          outP.value != ffi.nullptr) {
        final w = outP.value.cast<ffi.Uint16>();
        lang = w[0];
        page = w[1];
      }
      String hex4(int v) => v.toRadixString(16).padLeft(4, '0');
      descP = '\\StringFileInfo\\${hex4(lang)}${hex4(page)}\\FileDescription'
          .toNativeUtf16(allocator: pkgffi.calloc);
      outP.value = ffi.nullptr;
      lenP.value = 0;
      if (queryFn(block.cast(), descP, outP, lenP) == 0 ||
          lenP.value == 0 ||
          outP.value == ffi.nullptr) {
        return null;
      }
      final s = outP.value.cast<pkgffi.Utf16>().toDartString().trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    } finally {
      pkgffi.calloc.free(pathP);
      pkgffi.calloc.free(sizeHandle);
      pkgffi.calloc.free(outP);
      pkgffi.calloc.free(lenP);
      if (block != ffi.nullptr) pkgffi.calloc.free(block);
      if (transP != ffi.nullptr) pkgffi.calloc.free(transP);
      if (descP != ffi.nullptr) pkgffi.calloc.free(descP);
    }
  }

  /// 「バブル スクリーン セーバー」 → 「バブル」。
  /// 知らない書き方はそのまま出す。
  static String _trimSaverSuffix(String s) {
    for (final suffix in const [
      ' スクリーン セーバー',
      ' スクリーンセーバー',
      'スクリーン セーバー',
      'スクリーンセーバー',
      ' Screen Saver',
      ' screen saver',
      ' 屏幕保护程序',
      '屏幕保护程序',
      ' 화면 보호기',
    ]) {
      if (s.length > suffix.length && s.endsWith(suffix)) {
        final t = s.substring(0, s.length - suffix.length).trim();
        if (t.isNotEmpty) return t;
      }
    }
    return s;
  }

  /// 表に出す名前。 ファイル自身が名乗っている名前 → 手書きの対応表 →
  /// ファイル名、 の順。
  static String screenSaverDisplayName(String path, {String? stem}) {
    final base = path.split(RegExp(r'[\\/]')).last;
    final s = stem ??
        (base.toLowerCase().endsWith('.scr')
            ? base.substring(0, base.length - 4)
            : base);
    // ★ 「ブランク」 だけは、 名乗っている名前より手書きの方が親切。
    //   真っ暗な画面が出るので、 止まったと勘違いされやすい。
    final known = _kKnownSavers[s.toLowerCase()];
    if (s.toLowerCase() == 'scrnsave' && known != null) return known;
    final desc = _fileDescription(path);
    if (desc != null && desc.isNotEmpty) return _trimSaverSuffix(desc);
    return known ?? s;
  }

  /// この機械に入っている .scr を探す。
  static List<({String path, String name})> listScreenSavers(
      {bool refresh = false}) {
    if (!isSupported) return const [];
    if (!refresh && _saverCache != null) return _saverCache!;
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
          seen[keyName] =
              (path: p, name: screenSaverDisplayName(p, stem: stem));
        }
      } catch (_) {}
    }
    final out = seen.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    _saverCache = out;
    return out;
  }

  /// Windows に付いてくる物か (= %SystemRoot% の下にあるか)。
  static bool isBuiltInScreenSaver(String path) {
    if (!isSupported || path.trim().isEmpty) return false;
    final root = (Platform.environment['SystemRoot'] ?? r'C:\Windows')
        .toLowerCase()
        .replaceAll('/', '\\');
    return path.toLowerCase().replaceAll('/', '\\').startsWith('$root\\');
  }

  /// そのスクリーンセーバーが自分の設定 (/c) を持っているか。
  static bool screenSaverHasConfig(String path) {
    if (path.trim().isEmpty) return false;
    final base = path.split(RegExp(r'[\\/]')).last.toLowerCase();
    final stem =
        base.endsWith('.scr') ? base.substring(0, base.length - 4) : base;
    return !_kSaversWithoutConfig.contains(stem);
  }

  /// 動かすかどうか。
  static PcWriteResult setScreenSaverActive(bool on) {
    if (!isSupported) return PcWriteResult.failed;
    var live = false;
    try {
      live = _spi(_spiSetScreenSaveActive, on ? 1 : 0,
              ffi.Pointer<ffi.Void>.fromAddress(0), _spifUpdateAndSend) !=
          0;
    } catch (_) {}
    if (live) return PcWriteResult.ok;
    return _writeDesktopValue(_kActiveValue, on ? '1' : '0')
        ? PcWriteResult.pending
        : PcWriteResult.failed;
  }

  /// 何秒で始まるか (60〜7200)。
  ///
  /// ★ 「なし」 を選んでいても書ける。 Windows は開始までの時間を
  ///   SCRNSAVE.EXE とは**別に**持っているため (実測: SCRNSAVE.EXE が
  ///   1 つも無いまま ScreenSaveTimeOut="60" が入っていた)。 ここを
  ///   「セーバーを選んだ時だけ」 にしてはいけない
  ///   (= ユーザー要望「起動する時間設定ができるようにして欲しい」)。
  ///
  /// ★ SystemParametersInfo は断る事がある。 画面が省電力に入った後などは
  ///   ERROR_OPERATION_IN_PROGRESS (329) を返す (実機で再現)。 その時は
  ///   控えにだけ書いて [PcWriteResult.pending] を返す。
  static PcWriteResult setScreenSaverTimeout(int sec) {
    if (!isSupported) return PcWriteResult.failed;
    final v = sec.clamp(60, 7200);
    var live = false;
    try {
      live = _spi(_spiSetScreenSaveTimeout, v,
              ffi.Pointer<ffi.Void>.fromAddress(0), _spifUpdateAndSend) !=
          0;
    } catch (_) {}
    if (live) return PcWriteResult.ok;
    return _writeDesktopValue(_kTimeoutValue, '$v')
        ? PcWriteResult.pending
        : PcWriteResult.failed;
  }

  /// 戻る時にサインインを求めるか。
  static PcWriteResult setScreenSaverSecure(bool on) {
    if (!isSupported) return PcWriteResult.failed;
    var live = false;
    try {
      live = _spi(_spiSetScreenSaveSecure, on ? 1 : 0,
              ffi.Pointer<ffi.Void>.fromAddress(0), _spifUpdateAndSend) !=
          0;
    } catch (_) {}
    if (live) return PcWriteResult.ok;
    return _writeDesktopValue(_kSecureValue, on ? '1' : '0')
        ? PcWriteResult.pending
        : PcWriteResult.failed;
  }

  // ── プレビュー / そのセーバー自身の設定 ──────────────────────────

  /// .scr を引数付きで起こす。
  ///
  /// ★ このファイルの決まり (外の道具を呼ばない) の**唯一の例外**。
  ///   経緯と守るべき 4 点はファイル冒頭に書いてある。 ここでは
  ///   ・cmd.exe / powershell.exe を通さない (引数は配列でそのまま渡す)
  ///   ・.scr で、 実在する物だけ
  ///   ・作業場所はその .scr のある所
  ///   を守る。 呼び出し側が「ボタンを押した時だけ」 を守る事。
  static Future<bool> _runScreenSaver(String path, List<String> args) async {
    if (!isSupported) return false;
    final p = path.trim();
    if (p.isEmpty || !p.toLowerCase().endsWith('.scr')) return false;
    final file = File(p);
    if (!file.existsSync()) return false;
    try {
      await Process.start(
        p,
        args,
        workingDirectory: file.parent.path,
        runInShell: false,
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// プレビュー (= Windows の「設定」 にあるプレビューと同じ `/s`)。
  ///
  /// マウスを動かすかキーを押すと自分で終わる (DefScreenSaverProc が
  /// WM_MOUSEMOVE / WM_KEYDOWN / クリックで畳む)。 後始末は要らない。
  /// `/s` で出したプレビューは、 「復帰時にパスワードを求める」 が入って
  /// いても**鍵は掛からない** (鍵を掛けるのは、 放置で始まった時の
  /// winlogon 側の仕事)。
  static Future<bool> previewScreenSaver(String path) =>
      _runScreenSaver(path, const ['/s']);

  /// そのスクリーンセーバー自身の設定を開く (`/c`)。
  ///
  /// Microsoft の資料 (KB 182383) は `/c` だけを載せていて、 その時は
  /// 手前の窓が親になる。 Windows 自身は `/c:<窓の番号>` の形で呼ぶので、
  /// 番号が取れる時はそちらを使う (どちらも受けるのが .scr の作法)。
  static Future<bool> configureScreenSaver(String path) {
    var arg = '/c';
    try {
      final f = _user32.lookupFunction<_GetForegroundWindowNative,
          _GetForegroundWindowDart>('GetForegroundWindow');
      final h = f();
      if (h > 0) arg = '/c:$h';
    } catch (_) {}
    return _runScreenSaver(path, [arg]);
  }

  /// どの .scr を使うか ([path] が空なら「なし」)。
  ///
  /// 控え (レジストリ) に書いてから、 動かす / 止めるを Win32 で伝える。
  /// 設定アプリと同じ手順なので、 あちらを開いても同じ物が選ばれている。
  static PcWriteResult setScreenSaverPath(String path) {
    if (!isSupported) return PcWriteResult.failed;
    try {
      final key = Registry.openPath(RegistryHive.currentUser,
          path: _kDesktopKey, desiredAccessRights: AccessRights.allAccess);
      key.createValue(RegistryValue.string(_kScrnSaveValue, path));
      key.close();
    } catch (_) {
      return PcWriteResult.failed;
    }
    // 「なし」 にした時は動かす札も下ろす (そうしないと真っ暗な既定が動く)。
    //
    // ★ ここの結果を捨ててはいけない。 Windows は画面まわりの都合で断る事が
    //   ある (ERROR_OPERATION_IN_PROGRESS = 329)。 捨てると「選んだのに
    //   始まらない、 理由も出ない」 になる。
    return setScreenSaverActive(path.isNotEmpty);
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
