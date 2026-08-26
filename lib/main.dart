import 'dart:async';
import 'dart:math' as math;
import 'dart:io'
    show
        Platform,
        File,
        // メモに貼る画像の置き場所を作るのに要る (= ユーザー要望)。
        Directory,
        // サブ窓で WebView を作れない時に外の窓を起動するのに要る。
        ProcessStartMode,
        FileMode,
        Process,
        exit,
        pid,
        HttpServer,
        HttpClient,
        InternetAddress,
        ContentType;
import 'dart:convert';
// 録画の範囲選び窓の「選んだ所以外を暗くする」 描画に要る。
import 'dart:ui' as ui;
// 録画の操作窓を画面キャプチャから外すため (Win32 を直に呼ぶ)。
import 'dart:ffi' as ffi;
// オーバーレイの AI モードから直接問い合わせるため (= ユーザー要望)。
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// 高リフレッシュレート (120Hz / 144Hz) 対応 (= ユーザー要望)。Android 専用。
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
// flutter_quill (リッチテキスト) のUIローカライズ delegate を MaterialApp に追加する。
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'widgets/calc_body.dart';
// アプリ外に出す AI 窓 (= ユーザー要望) の中身。 Windows 専用プラグイン。
import 'package:webview_windows/webview_windows.dart' as wv_win;
import 'package:win32_registry/win32_registry.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
// メモに画像を貼り付けるため (= ユーザー要望)。
import 'package:super_clipboard/super_clipboard.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:fvp/fvp.dart' as fvp;
// フローティングメモ (他のアプリの上に小さくメモ表示 = ユーザー要望)。
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'providers/mind_map_provider.dart';
import 'screens/mind_map_screen.dart';
// 自動操作のフロー画面を外の窓 (別プロセス) で出すため (= ユーザー要望)。
import 'widgets/google_search_dialog.dart' show GoogleSearchAutomationHost;
import 'services/home_shortcut_service.dart';
// 録画窓の中の範囲選び (デスクトップの写しを撮る) に使う。
import 'services/screen_capture.dart' as scap;
// 録画窓の中のプレビュー再生 (デスクトップは fvp バックエンド)。
import 'package:video_player/video_player.dart';
// 録画窓が自分の窓の大きさを変える (GetWindowRect) のに使う。
import 'package:ffi/ffi.dart' as pkgffi;
// Linux 専用 WebView (CEF) の初期化。 中身は flutter_linux_webview を import
//   するが Linux 専用プラグインなので Windows/Android のネイティブには影響しない。
import 'services/linux_webview.dart' as linux_wv;

/// アプリ全体で使うローカル通知プラグインのインスタンス。
/// `mind_map_screen.dart` から参照できるよう、 トップレベル変数として公開。
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

/// フローティングメモの本文を保存する SharedPreferences キー。
/// オーバーレイ側 (別 isolate) と本体側の両方から読み書きする。
const String kFloatingMemoPrefsKey = 'floating_memo_text_v1';

/// ── デスクトップのフローティングメモ本文は専用ファイルに保存する ──
/// SharedPreferences は本体とサブウィンドウ (別エンジン) がそれぞれ
/// メモリ上のキャッシュを持ち、 set のたびに JSON を丸ごと書き戻すため、
/// 本体側の保存でメモの内容が消されてしまう (= ユーザー報告: 閉じると
/// 消える)。 メモ専用ファイルなら互いに上書きし合わない。
Future<File> floatingMemoTextFile() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}${Platform.pathSeparator}floating_memo.txt');
}

Future<String> loadFloatingMemoText() async {
  try {
    final f = await floatingMemoTextFile();
    if (await f.exists()) return await f.readAsString();
  } catch (_) {}
  // 旧バージョンが prefs に保存した内容の移行。
  try {
    final sp = await SharedPreferences.getInstance();
    await sp.reload();
    return sp.getString(kFloatingMemoPrefsKey) ?? '';
  } catch (_) {}
  return '';
}

Future<void> saveFloatingMemoText(String text) async {
  try {
    final f = await floatingMemoTextFile();
    await f.writeAsString(text, flush: true);
  } catch (_) {}
}

/// ── フローティングメモの 1 項目 ──
/// YouTube の動画メモ (`_VideoMemoEntry`) と同じ作りにして、 1 件ごとに
/// 作成時刻・マップ追加済みの印を持たせる (= ユーザー要望: 箇条書きの欄を
/// 動画メモと同じ感じに)。
class FloatMemoItem {
  final String id;
  String text;

  /// 貼り付けた画像の場所 (= ユーザー要望: フローティングメモに画像を
  /// 貼れるように)。 空なら文字だけの項目。
  String image;

  /// 作成時刻 (UNIX ms)。 動画メモの再生位置バッジと同じ位置に時刻を出す。
  final int savedAt;

  /// マップに追加済みなら true (重複追加防止 + 緑の印)。
  bool addedToMap;

  FloatMemoItem({
    required this.id,
    required this.text,
    int? savedAt,
    this.addedToMap = false,
    this.image = '',
  }) : savedAt = savedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory FloatMemoItem.create(String text, {String image = ''}) =>
      FloatMemoItem(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        text: text,
        image: image,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'savedAt': savedAt,
        'addedToMap': addedToMap,
        if (image.isNotEmpty) 'image': image,
      };

  static FloatMemoItem? fromJson(Map j) {
    final t = '${j['text'] ?? ''}';
    final img = '${j['image'] ?? ''}';
    // 画像だけの項目もある (= 文字が空でも捨てない)。
    if (t.trim().isEmpty && img.trim().isEmpty) return null;
    return FloatMemoItem(
      id: '${j['id'] ?? DateTime.now().microsecondsSinceEpoch}',
      text: t,
      savedAt: j['savedAt'] is num ? (j['savedAt'] as num).toInt() : null,
      addedToMap: j['addedToMap'] == true,
      image: img,
    );
  }
}

/// ── メモ 1 冊分 (= ユーザー要望: フローティングメモを複数保存できるように) ──
/// 箇条書きの項目・フリーメモの本文・表示モードを冊子ごとに持つ。
class FloatMemoBook {
  final String id;
  String name;
  List<FloatMemoItem> items;
  String free;

  /// 'list' = 箇条書き / 'free' = 自由記入
  String mode;

  FloatMemoBook({
    required this.id,
    required this.name,
    List<FloatMemoItem>? items,
    this.free = '',
    this.mode = 'list',
  }) : items = items ?? [];

  /// [mode] を渡すと、 そのモード ('list' / 'free') で作る。
  /// = ユーザー要望: 新しいメモを追加した時、 追加を押す前のメモと同じ
  ///   モードで始まってほしい (毎回箇条書きに戻るのが気になる)。
  factory FloatMemoBook.create(String name, {String mode = 'list'}) =>
      FloatMemoBook(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        mode: mode == 'free' ? 'free' : 'list',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'free': free,
        'mode': mode,
        'items': items.map((e) => e.toJson()).toList(),
      };

  static FloatMemoBook? fromJson(Map j) {
    final items = <FloatMemoItem>[];
    final raw = j['items'];
    if (raw is List) {
      for (final e in raw) {
        // v3 = 項目オブジェクト / それ以前 = ただの文字列。
        if (e is Map) {
          final it = FloatMemoItem.fromJson(e);
          if (it != null) items.add(it);
        } else if ('$e'.trim().isNotEmpty) {
          items.add(FloatMemoItem.create('$e'));
        }
      }
    }
    return FloatMemoBook(
      id: '${j['id'] ?? DateTime.now().microsecondsSinceEpoch}',
      name: '${j['name'] ?? ''}'.trim().isEmpty ? 'メモ 1' : '${j['name']}',
      items: items,
      free: '${j['free'] ?? ''}',
      mode: j['mode'] == 'free' ? 'free' : 'list',
    );
  }
}

/// 保存文字列 (v3 = 複数メモ / v2 = 1 冊 / それ以前 = プレーンテキスト) を
/// メモ帳の一覧に読み直す。 どの形式でも最低 1 冊は返す。
({List<FloatMemoBook> books, int active}) parseFloatingMemoBooks(String raw) {
  List<FloatMemoBook> books = [];
  int active = 0;
  if (raw.trim().isNotEmpty) {
    try {
      final j = jsonDecode(raw);
      if (j is Map && j['books'] is List) {
        // ── v3: 複数メモ ──
        for (final e in (j['books'] as List)) {
          if (e is Map) {
            final b = FloatMemoBook.fromJson(e);
            if (b != null) books.add(b);
          }
        }
        final activeId = '${j['active'] ?? ''}';
        final idx = books.indexWhere((b) => b.id == activeId);
        active = idx >= 0 ? idx : 0;
      } else if (j is Map) {
        // ── v2: 1 冊だけ。 v2 は新しい順で保存、 それ以前は古い順。 ──
        final list = (j['items'] is List ? j['items'] as List : const [])
            .map((e) => '$e')
            .where((e) => e.trim().isNotEmpty)
            .toList();
        final ordered = j['v'] == 2 ? list : list.reversed.toList();
        books.add(FloatMemoBook(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: FloatL10n.t('memo.book1'),
          items: ordered.map(FloatMemoItem.create).toList(),
          free: '${j['free'] ?? ''}',
          mode: j['mode'] == 'free' ? 'free' : 'list',
        ));
      }
    } catch (_) {}
    if (books.isEmpty) {
      // 旧形式 (プレーンテキスト) は行ごとに項目へ。
      final lines = raw
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList()
          .reversed
          .toList();
      books.add(FloatMemoBook(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: FloatL10n.t('memo.book1'),
        items: lines.map(FloatMemoItem.create).toList(),
      ));
    }
  }
  if (books.isEmpty) {
    books.add(FloatMemoBook.create(FloatL10n.t('memo.book1')));
  }
  if (active < 0 || active >= books.length) active = 0;
  return (books: books, active: active);
}

String encodeFloatingMemoBooks(List<FloatMemoBook> books, int active) {
  final safe = active >= 0 && active < books.length ? active : 0;
  return jsonEncode({
    'v': 3,
    'active': books.isEmpty ? '' : books[safe].id,
    'books': books.map((b) => b.toJson()).toList(),
  });
}

/// 外 (本体アプリ) からメモ窓へ文章を渡す時に使う。 保存済みの内容を
/// 消さずに、 開いているメモの先頭へ 1 項目として積む。
Future<void> appendFloatingMemoItem(String text) async {
  final t = text.trim();
  if (t.isEmpty) return;
  final raw = await loadFloatingMemoText();
  final parsed = parseFloatingMemoBooks(raw);
  final books = parsed.books;
  books[parsed.active].items.insert(0, FloatMemoItem.create(t));
  await saveFloatingMemoText(encodeFloatingMemoBooks(books, parsed.active));
}

/// フローティングメモの下 3 つのボタンを隠しているか (同じ理由でファイル)。
/// SharedPreferences は本体とサブウィンドウで潰し合うので使えない。
Future<File> _floatingMemoFooterFile() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}${Platform.pathSeparator}floating_memo_footer.txt');
}

Future<bool> loadFloatingMemoFooterHidden() async {
  try {
    final f = await _floatingMemoFooterFile();
    if (await f.exists()) return (await f.readAsString()).trim() == '1';
  } catch (_) {}
  return false;
}

Future<void> saveFloatingMemoFooterHidden(bool hidden) async {
  try {
    final f = await _floatingMemoFooterFile();
    await f.writeAsString(hidden ? '1' : '0', flush: true);
  } catch (_) {}
}

/// フローティング AI の「最後に開いたサイト」 の記録 (同じ理由でファイル)。
Future<File> _floatingAiLastFile() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}${Platform.pathSeparator}floating_ai_last.txt');
}

/// ── フローティングメモのオーバーレイ用エントリポイント ──
/// flutter_overlay_window が OverlayService 内の別 Flutter エンジンで
/// この関数を起動する (= ユーザー要望: 他のアプリの上に小さくメモを表示)。
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  // ── 表示言語を読んでから出す (= ユーザー報告: フローティング AI が
  //    英語表記になる)。 オーバーレイは本体と別のエンジンで動くので、
  //    ここで読み直さないと FloatL10n が既定の英語のままになる。 ──
  unawaited(FloatL10n.load().then((_) {
    runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FloatingMemoOverlay(),
    ));
  }).catchError((_) {
    runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: FloatingMemoOverlay(),
    ));
  }));
}

/// 他のアプリの上に出る小さなメモカード。 入力は自動保存され、 本体アプリの
/// フローティングメモボタンで取り込める。 ドラッグ移動は
/// flutter_overlay_window の enableDrag が担当する。
class FloatingMemoOverlay extends StatefulWidget {
  const FloatingMemoOverlay({super.key});
  @override
  State<FloatingMemoOverlay> createState() => _FloatingMemoOverlayState();
}

class _FloatingMemoOverlayState extends State<FloatingMemoOverlay> {
  final TextEditingController _ctrl = TextEditingController();
  Timer? _saveDebounce;
  bool _loaded = false;

  // ── 折り畳み + サイズ変更 (= ユーザー要望: フローティングメモは小さく
  //    畳んだり、 大きさを変えられるように) ──
  /// true = 小さなアイコンだけの丸ボタン状態。
  bool _collapsed = false;

  /// 展開時の論理サイズ (dp)。 リサイズグリップで変更し、 prefs に保存して
  /// 次回も同じ大きさで開く。 上限は控えめにして、 画面全体を覆って
  /// 閉じるボタンが押せなくなる事故を防ぐ (= ユーザー要望: L で画面全体を
  /// 覆ってしまって消せなくなる → サイズ分けをやめて 1 つに + 上限を制限)。
  // 既定を一回り大きくする (= ユーザー要望: 欄の大きさが微妙で使いにくい)。
  double _memoW = 340;
  double _memoH = 460;
  static const double _kMaxW = 460;
  static const double _kMaxH = 620;
  static const String _kSizeKey = 'floating_memo_size_v1';

  /// キーボード入力を受け取るか (= ユーザー要望: 入力モードを切れないと
  /// 後ろで動いている本体アプリが操作しづらい)。
  /// true  = focusPointer (この窓に文字を打てる)
  /// false = defaultFlag  (この窓はキー入力を取らない → 後ろが操作しやすい)
  bool _inputEnabled = true;

  /// リサイズの取っ手を掴んでいる最中か (= 今の大きさを出すため)。
  bool _resizing = false;

  Future<void> _toggleInputMode() async {
    final next = !_inputEnabled;
    setState(() => _inputEnabled = next);
    try {
      await FlutterOverlayWindow.updateFlag(
          next ? OverlayFlag.focusPointer : OverlayFlag.defaultFlag);
    } catch (e) {
      debugPrint('overlay flag update failed: $e');
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(kInputKey, next);
    } catch (_) {}
  }

  static const String kInputKey = 'floating_overlay_input_v1';

  /// オーバーレイの表示モード。 'memo' = メモ、 'ai' = AI に質問
  /// (= ユーザー要望: フローティング AI もアプリの外に出せるように)。
  /// 本体アプリが起動時に prefs へ書き、 ここで読む。
  static const String kModeKey = 'floating_overlay_mode_v1';
  String _mode = 'memo';

  /// ── 画面録画の受け渡し (= ユーザー要望: モバイルでも録画ボタンを
  ///    アプリの外に出せるように) ──
  ///    本体が 1 秒ごとに「録画中か / 何秒たったか」 を prefs に書き、
  ///    ここで読む。 停止は逆に prefs へ合図を置いて本体に止めてもらう
  ///    (オーバーレイは別エンジンなので直接は触れない)。
  static const String kRecStateKey = 'floating_rec_state_v1';
  static const String kRecStopKey = 'floating_rec_stop_v1';
  bool _recRecording = false;
  int _recSeconds = 0;
  Timer? _recPoll;

  String get _recLabel {
    final m = (_recSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_recSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _stopRecPoll() {
    _recPoll?.cancel();
    _recPoll = null;
  }

  void _startRecPoll() {
    _recPoll?.cancel();
    _recPoll = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted || _mode != 'rec') return;
      try {
        final sp = await SharedPreferences.getInstance();
        await sp.reload();
        final raw = sp.getString(kRecStateKey) ?? '';
        final parts = raw.split('|');
        final rec = parts.isNotEmpty && parts[0] == '1';
        final sec = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
        if (mounted && (rec != _recRecording || sec != _recSeconds)) {
          setState(() {
            _recRecording = rec;
            _recSeconds = sec;
          });
        }
      } catch (_) {}
    });
  }

  /// 本体に「止めて」 と伝える。
  Future<void> _askStopRecording() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(kRecStopKey, true);
    } catch (_) {}
    if (mounted) setState(() => _recRecording = false);
  }

  /// 録画モードの中身 (= 経過時間と停止だけの小さな画面)。
  Widget _buildRecBody() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.fiber_manual_record_rounded,
                  size: 14,
                  color: _recRecording
                      ? const Color(0xFFE53935)
                      : Colors.white24),
              const SizedBox(width: 8),
              Text(_recRecording ? _recLabel : '--:--',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ]),
            const SizedBox(height: 10),
            if (_recRecording)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935)),
                icon: const Icon(Icons.stop_rounded, size: 18),
                label: Text(FloatL10n.t('rec.stop')),
                onPressed: () => unawaited(_askStopRecording()),
              )
            else
              Text(FloatL10n.t('rec.notRecording'),
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
      );

  // ── AI モードの状態 ──
  final TextEditingController _aiCtrl = TextEditingController();
  String _aiAnswer = '';
  bool _aiBusy = false;
  String _aiError = '';

  /// 本体アプリが書き残した「実際の画面サイズ (dp)」。
  /// オーバーレイ内の MediaQuery は自分自身の大きさを返すので、 それを
  /// 上限計算に使うと自己参照になって暴走する (= ユーザー報告: 画面全体を
  /// 覆って操作不能になる)。 必ず本体が測った値を使う。
  static const String kScreenKey = 'floating_memo_screen_v1';
  double _screenW = 0;
  double _screenH = 0;

  /// 既定サイズ (「大きさを戻す」 用)。
  static const double _kDefaultW = 340;
  static const double _kDefaultH = 460;

  Future<void> _applyOverlaySize({required bool collapsed}) async {
    try {
      // ★ resizeOverlay に渡すのは「dp」。 プラグインが内部で dpToPx() して
      //   から WindowManager に渡すため、 こちらで画素に直して渡すと
      //   端末倍率のぶんだけ巨大化する (= ユーザー報告: POCO F6 Pro (倍率
      //   約 3.5) で画面全体を覆う)。 以前は px を渡していたのが原因。
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final dpr = view.devicePixelRatio <= 0 ? 1.0 : view.devicePixelRatio;

      // 論理サイズ (dp) の上限。
      var w = collapsed ? 64.0 : _memoW.clamp(180.0, _kMaxW).toDouble();
      var h = collapsed ? 64.0 : _memoH.clamp(160.0, _kMaxH).toDouble();

      // 実画面に対する割合でも頭打ちにする。 基準は本体アプリが測った dp。
      //   取れていない時は物理解像度から逆算する (どちらもオーバーレイ自身の
      //   大きさには依存しないので自己参照にならない)。
      var sw = _screenW;
      var sh = _screenH;
      if (sw <= 0 || sh <= 0) {
        sw = view.physicalSize.width / dpr;
        sh = view.physicalSize.height / dpr;
      }
      if (!collapsed && sw > 0 && sh > 0) {
        // 幅は 80%、 高さは 55% まで。 これで下のアプリも操作でき、
        //   閉じる / 畳むボタンが画面外へ出ることもない。
        w = math.min(w, sw * 0.80);
        h = math.min(h, sh * 0.55);
      }
      // dp のまま渡す (px に変換しない)。
      final dpW = w.round().clamp(64, 2000);
      final dpH = h.round().clamp(64, 2000);
      await FlutterOverlayWindow.resizeOverlay(dpW, dpH, true);
    } catch (e) {
      debugPrint('overlay resize failed: $e');
    }
  }

  Widget _buildMemoBody() => TextField(
        controller: _ctrl,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        cursorColor: const Color(0xFF6C63FF),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: FloatL10n.t('memo.hintOverlay'),
          hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
        ),
        onChanged: (_) => _scheduleSave(),
      );

  /// メモ / AI の切り替えボタン 1 個 (= ユーザー要望: 位置を固定)。
  /// 選んでいる方だけ色が付く。 押しても並び順は変わらない。
  Widget _modeButton({
    required bool isAi,
    required IconData icon,
    required Color onColor,
    required String tip,
  }) {
    final on = (_mode == 'ai') == isAi;
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      tooltip: tip,
      icon: Icon(icon, size: 16, color: on ? onColor : Colors.white30),
      onPressed: on
          ? null
          : () {
              setState(() => _mode = isAi ? 'ai' : 'memo');
              // ignore: discarded_futures
              _persistMode();
            },
    );
  }

  /// AI モードの中身 (= ユーザー要望: フローティング AI をアプリの外に)。
  ///
  /// アプリの外に出せる窓は 1 つだけで、 そこにブラウザを載せると別エンジン
  /// になって重く不安定なため、 ここは「質問して答えを受け取る」 だけの
  /// 軽い画面にしている。 通信先は本体と同じ代行サーバー / 自分のキー。
  Widget _buildAiBody() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: _aiCtrl,
                maxLines: 2,
                minLines: 1,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                cursorColor: const Color(0xFFBA68C8),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _askAiFromOverlay(),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: FloatL10n.t('ai.askHint'),
                  hintStyle:
                      const TextStyle(color: Colors.white30, fontSize: 12),
                ),
              ),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: _aiBusy
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Color(0xFFBA68C8)))
                  : const Icon(Icons.send_rounded,
                      size: 18, color: Color(0xFFBA68C8)),
              onPressed: _aiBusy ? null : _askAiFromOverlay,
            ),
          ]),
          const Divider(color: Colors.white12, height: 10),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
                _aiError.isNotEmpty
                    ? _aiError
                    : (_aiAnswer.isEmpty
                        ? FloatL10n.t('ai.askEmpty')
                        : _aiAnswer),
                style: TextStyle(
                  color: _aiError.isNotEmpty
                      ? const Color(0xFFEF9A9A)
                      : (_aiAnswer.isEmpty
                          ? Colors.white30
                          : Colors.white),
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ),
          ),
          Row(children: [
            // ここの AI は鍵 (代行 / 自分のキー) を叩く形なので、 いつもの
            //   ブラウザ版をそのまま使いたい人向けの逃げ道を置く
            //   (= ユーザー要望: ブラウザ版で開けるようにして)。
            TextButton.icon(
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 30)),
              icon: const Icon(Icons.open_in_browser_rounded,
                  size: 15, color: Color(0xFF4FC3F7)),
              label: Text(FloatL10n.t('memo.aiBrowser'),
                  style:
                      const TextStyle(color: Color(0xFF4FC3F7), fontSize: 11.5)),
              // ignore: discarded_futures
              onPressed: () => _openBrowserAi(_aiCtrl.text),
            ),
            const Spacer(),
            if (_aiAnswer.isNotEmpty)
              TextButton.icon(
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 30)),
                icon: const Icon(Icons.note_add_rounded,
                    size: 15, color: Color(0xFFFFB347)),
                label: Text(FloatL10n.t('ai.toMemo'),
                    style: const TextStyle(
                        color: Color(0xFFFFB347), fontSize: 11.5)),
                onPressed: () {
                  // 答えをメモへ移してメモモードに戻る (取っておける)。
                  final add = _aiAnswer.trim();
                  if (add.isEmpty) return;
                  _ctrl.text = _ctrl.text.trim().isEmpty
                      ? add
                      : '${_ctrl.text.trimRight()}\n\n$add';
                  _scheduleSave();
                  setState(() => _mode = 'memo');
                  // ignore: discarded_futures
                  _persistMode();
                },
              ),
          ]),
        ],
      );

  /// ブラウザ版の AI を既定のブラウザで開く。
  /// オーバーレイからは provider を触れないので、 選んでいる AI は
  /// prefs (`browser_ai_target`) から読む。
  Future<void> _openBrowserAi(String text) async {
    const targets = <String, String>{
      'chatgpt': 'https://chatgpt.com/?q={q}',
      'gemini': 'https://gemini.google.com/app?q={q}',
      'perplexity': 'https://www.perplexity.ai/search?q={q}',
      'claude': 'https://claude.ai/new?q={q}',
      'grok': 'https://grok.com/?q={q}',
      'deepseek': 'https://chat.deepseek.com/?q={q}',
    };
    var tmpl = targets['chatgpt']!;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      final id = (sp.getString('browser_ai_target') ?? '').trim();
      if (targets.containsKey(id)) tmpl = targets[id]!;
    } catch (_) {}
    final url = tmpl.replaceAll('{q}', Uri.encodeComponent(text.trim()));
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('ブラウザ版 AI を開けませんでした: $e');
    }
  }

  /// 本体アプリへ「このメモをページに追加して」 と伝える。
  /// オーバーレイからは provider を触れないので、 prefs に置いて渡す。
  static const String kPendingAddKey = 'floating_memo_pending_add_v1';

  Future<void> _addMemoToPage() async {
    final text = (_mode == 'ai' ? _aiAnswer : _ctrl.text).trim();
    if (text.isEmpty) return;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      // 複数回押された分もためられるように、 区切って積む。
      final prev = sp.getString(kPendingAddKey) ?? '';
      final next = prev.isEmpty ? text : '$prev\n---\n$text';
      await sp.setString(kPendingAddKey, next);
      if (mounted) {
        setState(() => _addedNotice = true);
        Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _addedNotice = false);
        });
      }
    } catch (e) {
      debugPrint('ページ追加の予約に失敗: $e');
    }
  }

  /// 「追加しました」 の一時表示。
  bool _addedNotice = false;

  Future<void> _persistMode() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(kModeKey, _mode);
    } catch (_) {}
  }

  /// オーバーレイから AI に質問する。
  /// 代行サーバー (前払いクレジット) → 自分の Gemini キー、 の順で試す。
  Future<void> _askAiFromOverlay() async {
    final q = _aiCtrl.text.trim();
    if (q.isEmpty || _aiBusy) return;
    setState(() {
      _aiBusy = true;
      _aiError = '';
    });
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      final base = (sp.getString('relayApiBase') ?? '').trim();
      final uid = (sp.getString('firebase_uid') ?? '').trim();
      final ownKey = (sp.getString('gemini_api_key') ?? '').trim();
      final model =
          sp.getString('relayModel') ?? 'gemini-flash-latest';

      String? text;
      // 1) 代行サーバー (残高があれば)
      if (base.isNotEmpty && uid.isNotEmpty && ownKey.isEmpty) {
        final r = await http
            .post(Uri.parse('$base/ai/generate'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode(
                    {'uid': uid, 'prompt': q, 'model': model}))
            .timeout(const Duration(seconds: 90));
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        if (r.statusCode == 200) {
          text = (j['text'] as String?) ?? '';
        } else if (r.statusCode == 402) {
          throw Exception(FloatL10n.t('ai.noCredit'));
        } else {
          throw Exception('${j['error'] ?? 'HTTP ${r.statusCode}'}');
        }
      }
      // 2) 自分の Gemini キー
      if (text == null && ownKey.isNotEmpty) {
        final r = await http
            .post(
                Uri.parse(
                    'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$ownKey'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({
                  'contents': [
                    {
                      'parts': [
                        {'text': q}
                      ]
                    }
                  ]
                }))
            .timeout(const Duration(seconds: 90));
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        if (r.statusCode != 200) {
          throw Exception(
              '${(j['error'] as Map?)?['message'] ?? 'HTTP ${r.statusCode}'}');
        }
        final cands = j['candidates'] as List?;
        final parts = ((cands?.first as Map?)?['content'] as Map?)?['parts']
            as List?;
        text = (parts ?? [])
            .map((p) => (p as Map)['text']?.toString() ?? '')
            .join();
      }
      if (text == null) throw Exception(FloatL10n.t('ai.needSetup'));
      if (!mounted) return;
      setState(() {
        _aiAnswer = text!.trim();
        _aiBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiError = '$e'.replaceFirst('Exception: ', '');
        _aiBusy = false;
      });
    }
  }

  /// 大きさを既定へ戻す (= ユーザー要望: 大きくなり過ぎて操作できなくなった
  /// 時の逃げ道)。 ヘッダーのダブルタップで呼ぶ。
  Future<void> _resetOverlaySize() async {
    setState(() {
      _memoW = _kDefaultW;
      _memoH = _kDefaultH;
      _collapsed = false;
    });
    await _applyOverlaySize(collapsed: false);
    await _persistSize();
  }

  Future<void> _persistSize() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
          _kSizeKey, '${_memoW.round()}x${_memoH.round()}');
    } catch (_) {}
  }

  void _toggleCollapsed() {
    setState(() => _collapsed = !_collapsed);
    _applyOverlaySize(collapsed: _collapsed);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      _ctrl.text = sp.getString(kFloatingMemoPrefsKey) ?? '';
      // 保存済みのウィンドウサイズを復元 (= ユーザー要望: 大きさ変更)。
      _mode = sp.getString(kModeKey) ?? 'memo';
      if (_mode == 'rec') _startRecPoll();
      _inputEnabled = sp.getBool(kInputKey) ?? true;
      // 本体アプリが書き残した実画面サイズ (dp)。
      final sc = sp.getString(kScreenKey) ?? '';
      final scm = RegExp(r'^(\d+)x(\d+)$').firstMatch(sc);
      if (scm != null) {
        _screenW = double.parse(scm.group(1)!);
        _screenH = double.parse(scm.group(2)!);
      }
      final size = sp.getString(_kSizeKey) ?? '';
      final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(size);
      if (m != null) {
        // 旧バージョンで保存された大き過ぎるサイズも上限に丸める。
        _memoW = double.parse(m.group(1)!).clamp(180.0, _kMaxW);
        _memoH = double.parse(m.group(2)!).clamp(160.0, _kMaxH);
      }
      // 保存の有無にかかわらず必ず当て直す。 これで、 以前の版で大きく
      //   なり過ぎた状態のまま起動しても、 開いた瞬間に上限へ丸められる。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyOverlaySize(collapsed: false);
      });
    } catch (_) {}
    if (mounted) setState(() => _loaded = true);
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final sp = await SharedPreferences.getInstance();
        await sp.setString(kFloatingMemoPrefsKey, _ctrl.text);
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _stopRecPoll();
    _saveDebounce?.cancel();
    // 閉じる直前の内容も確実に保存する。
    SharedPreferences.getInstance()
        .then((sp) => sp.setString(kFloatingMemoPrefsKey, _ctrl.text));
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ── 折り畳み時: 小さな丸アイコンだけ (= ユーザー要望: 小さく畳む)。
    //    タップで展開する。 ドラッグ移動は overlay の enableDrag が担当。 ──
    if (_collapsed) {
      return Material(
        color: Colors.transparent,
        child: Center(
          child: GestureDetector(
            onTap: _toggleCollapsed,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xF01A1A2E),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF6C63FF), width: 1.4),
                boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 10),
                ],
              ),
              child: const Icon(Icons.sticky_note_2_rounded,
                  color: Color(0xFFFFB347), size: 24),
            ),
          ),
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xF01A1A2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF6C63FF), width: 1.2),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 12),
          ],
        ),
        child: Stack(children: [
          Column(children: [
          // ヘッダー (タイトル + サイズ変更 + 畳む + 閉じる)。
          //   ダブルタップで大きさを既定へ戻せる (= ユーザー要望: 大きく
          //   なり過ぎて操作できなくなった時の逃げ道)。
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: () {
              // ignore: discarded_futures
              _resetOverlaySize();
            },
            child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 2, 0),
            child: Row(children: [
              // ── メモ / AI は場所の変わらない 2 つのボタンにする
              //    (= ユーザー要望: 切り替えるたびにボタンの位置が
              //    入れ替わると使いにくい)。 今どちらかは色で示す。 ──
              _modeButton(
                  isAi: false,
                  icon: Icons.sticky_note_2_rounded,
                  onColor: const Color(0xFFFFB347),
                  tip: FloatL10n.t('memo.title')),
              _modeButton(
                  isAi: true,
                  icon: Icons.auto_awesome_rounded,
                  onColor: const Color(0xFFBA68C8),
                  tip: FloatL10n.t('memo.openAi')),
              // タイトル文字は出さない (= ユーザー要望: 幅が足りず潰れる)。
              //   何のモードかは左のアイコンの色と形で分かる。
              //   空いた分はボタンの間隔として使う。
              const Spacer(),
              // ── ページに追加 (= ユーザー要望: フローティングメモを
              //    ページに追加できるように) ──
              //    アプリに戻った時に取り込まれる。
              IconButton(
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 32),
                tooltip: FloatL10n.t('memo.addToPage'),
                icon: Icon(
                    _addedNotice
                        ? Icons.check_circle_rounded
                        : Icons.playlist_add_rounded,
                    size: 18,
                    color: _addedNotice
                        ? const Color(0xFF43B97F)
                        : const Color(0xFFFFB347)),
                onPressed: () {
                  // ignore: discarded_futures
                  _addMemoToPage();
                },
              ),
              // ── 入力モードの ON/OFF (= ユーザー要望: 入力を切れないと
              //    後ろのアプリが操作しづらい) ──
              //    OFF にすると、 この窓はキーボード入力を受け取らなくなり、
              //    後ろのアプリのタップ / 入力がしやすくなる。
              IconButton(
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 32),
                tooltip: _inputEnabled
                    ? FloatL10n.t('memo.inputOff')
                    : FloatL10n.t('memo.inputOn'),
                icon: Icon(
                    _inputEnabled
                        ? Icons.keyboard_rounded
                        : Icons.keyboard_hide_rounded,
                    size: 17,
                    color: _inputEnabled
                        ? const Color(0xFF7FD8A0)
                        : Colors.white38),
                onPressed: () {
                  // ignore: discarded_futures
                  _toggleInputMode();
                },
              ),
              // ── 畳む (= ユーザー要望: 小さく畳む)。 サイズ変更は右下の
              //    グリップのドラッグ 1 本に統一 (プリセットは廃止)。 ──
              IconButton(
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 32),
                icon: const Icon(Icons.close_fullscreen_rounded,
                    color: Colors.white54, size: 15),
                onPressed: _toggleCollapsed,
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 32),
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white54, size: 18),
                onPressed: () async {
                  try {
                    final sp = await SharedPreferences.getInstance();
                    await sp.setString(kFloatingMemoPrefsKey, _ctrl.text);
                  } catch (_) {}
                  await FlutterOverlayWindow.closeOverlay();
                },
              ),
            ]),
          ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: !_loaded
                  ? const Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : (_mode == 'rec'
                      ? _buildRecBody()
                      : (_mode == 'ai' ? _buildAiBody() : _buildMemoBody())),
            ),
          ),
          ]),
          // ── 右下のリサイズグリップ (= ユーザー要望: 大きさ調節が難しい
          //    のでもっと調整しやすく)。 掴める所を大きく (36×36) して、
          //    掴んでいる間は今の大きさを数字で出す。 ──
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => setState(() => _resizing = true),
              onPanUpdate: (d) {
                _memoW = (_memoW + d.delta.dx).clamp(180.0, _kMaxW);
                _memoH = (_memoH + d.delta.dy).clamp(160.0, _kMaxH);
                _applyOverlaySize(collapsed: false);
                setState(() {});
              },
              onPanEnd: (_) {
                setState(() => _resizing = false);
                _persistSize();
              },
              onPanCancel: () => setState(() => _resizing = false),
              child: Container(
                width: 36,
                height: 36,
                alignment: Alignment.bottomRight,
                padding: const EdgeInsets.all(3),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: _resizing
                        ? const Color(0xFF6C63FF)
                        : Colors.white.withValues(alpha: 0.14),
                    borderRadius: const BorderRadius.only(
                        bottomRight: Radius.circular(10),
                        topLeft: Radius.circular(10)),
                  ),
                  child: Icon(Icons.open_in_full_rounded,
                      size: 13,
                      color: _resizing ? Colors.white : Colors.white60),
                ),
              ),
            ),
          ),
          // 掴んでいる間だけ、 今の大きさを見せる (= 目安が無いと合わせ
          // にくいため)。
          if (_resizing)
            Positioned(
              right: 40,
              bottom: 8,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('${_memoW.round()} × ${_memoH.round()}',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 10.5)),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// 「後で通知」 で使う Android の通知チャンネル ID。
const String kNodeReminderChannelId = 'mokumoku_node_reminders';

/// 未保存の編集がある画面 (テキスト / Word / PowerPoint エディタ等) の
/// 「閉じて良いか」 確認。 各エディタが開いている間だけ登録する。
///
/// アプリ本体の × ボタンで閉じる前に順に呼び、 1 つでも false (= ユーザーが
/// キャンセル) を返したら終了を中止する (= ユーザー要望: アプリ自体の
/// 閉じるボタンを押しても変更内容を保存しますかのダイアログが出るように)。
/// 各ガードは未保存変更が無ければ黙って true を返す。
final Map<int, Future<bool> Function()> kUnsavedCloseGuards = {};

/// 本体ウィンドウを閉じる時の後始末。
///
/// 浮遊窓 (メモ / AI) は本体と同じプロセスの別ウィンドウなので、 本体だけを
/// 閉じると「窓は残っているのにプロセスは終わりかけ」 という状態になり、
/// 次にフローティングを開こうとしても開けなくなる (= ユーザー報告)。
/// ここで全ての子ウィンドウを閉じてから、 確実にプロセスを終了させる。
class _MainWindowCloser extends WindowListener {
  bool _closing = false;

  /// 閉じる工程の進み具合を TEMP に刻む (デバッグ用。 数十バイトなので常設)。
  static void _stampClose(String tag) {
    try {
      final dir = Platform.environment['TEMP'] ?? '.';
      File('$dir\\hn_close_log.txt').writeAsStringSync(
          '${DateTime.now().toIso8601String()} $tag\n',
          mode: FileMode.append,
          flush: true);
    } catch (_) {}
  }

  /// プロセスを「即座に」 終わらせる。
  ///
  /// dart:io の exit() は C ランタイムの exit → 各プラグイン DLL の後始末
  /// (スレッド join 等) を待つため、 fvp(libmdk) や WebView2 が居ると
  /// 数秒〜十数秒かかることがある (= ユーザー報告: × を押しても固まる)。
  /// Windows では Process.killPid が TerminateProcess に相当し、 後始末を
  /// 一切待たずに終わる。 設定は全て逐次保存済みなので失うものはない。
  static Never _forceKillSelf() {
    try {
      Process.killPid(pid);
    } catch (_) {}
    exit(0);
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    _stampClose('enter');
    // ── 未保存の編集があるエディタの確認 (= ユーザー要望: アプリ自体の
    //    × でも「変更内容を保存しますか」 を出す)。 ダイアログ表示中に
    //    watchdog で殺さないよう、 確認が済んでから終了シーケンスに入る。
    try {
      for (final guard in List.of(kUnsavedCloseGuards.values)) {
        bool ok = true;
        try {
          ok = await guard();
        } catch (_) {}
        if (!ok) {
          // ユーザーがキャンセル → 閉じるのを中止。
          _stampClose('cancelled-by-guard');
          _closing = false;
          return;
        }
      }
    } catch (_) {}
    // ── 何があっても 1.5 秒後には必ずプロセスを終わらせる保険 ──
    //   (= ユーザー報告: × ボタンを押しても固まって閉じない)。
    //   下の子ウィンドウ close や destroy は、 WebView2 や応答しない
    //   サブ窓が相手だと await が返らないことがある。 TerminateProcess
    //   相当で終えるのでサブ窓も一緒に消え、 ゾンビが残らない。
    Timer(const Duration(milliseconds: 1500), () {
      _stampClose('watchdog-kill');
      _forceKillSelf();
    });
    // 見た目は先に消す (= 押した瞬間に閉じたように見せる)。
    try {
      await windowManager.hide().timeout(const Duration(milliseconds: 300));
    } catch (_) {}
    try {
      final ids = await DesktopMultiWindow.getAllSubWindowIds()
          .timeout(const Duration(milliseconds: 500));
      for (final id in ids) {
        try {
          await WindowController.fromWindowId(id)
              .close()
              .timeout(const Duration(milliseconds: 300));
        } catch (_) {}
      }
    } catch (_) {}
    _stampClose('children-done');
    // destroy (通常終了) は待たない。 プラグイン DLL の後始末で数秒〜
    // 十数秒かかることがあるため、 そのまま即終了する。
    _forceKillSelf();
  }
}

/// 浮遊窓 (メモ / AI) を「モーダル移動ループを使わずに」 動かすための
/// ドラッグ状態。 window_manager の startDragging() は Windows の
/// SC_MOVE モーダルループを回すため、 その間メインスレッドが止まり、
/// アプリ本体が固まる (= ユーザー報告: フローティング窓を動かすと本体が
/// 動作しなくなる)。 代わりに setPosition() で自前に動かす。
class _WinDragger {
  Offset? _winStart;
  Offset _accum = Offset.zero;
  bool _busy = false;

  Future<void> start() async {
    _accum = Offset.zero;
    try {
      _winStart = await windowManager.getPosition();
    } catch (_) {
      _winStart = null;
    }
  }

  void update(DragUpdateDetails d, double dpr) {
    final base = _winStart;
    if (base == null) return;
    _accum += d.delta * dpr;
    if (_busy) return; // 未処理の setPosition が溜まらないよう間引く
    _busy = true;
    // ignore: discarded_futures
    windowManager
        .setPosition(base + _accum)
        .whenComplete(() => _busy = false)
        .catchError((_) => _busy = false);
  }
}

/// フローティング窓 (メモ / AI) 用の軽い翻訳表。
///
/// これらの窓は `MindMapProvider` を持たない別ウィンドウ (DesktopMultiWindow)
/// や Android のオーバーレイで動くため、 本体の i18n を使えない。
/// prefs の `appLanguage` を直接読んで、 ここの表から引く
/// (= ユーザー要望: フローティングメモも多言語対応に)。
class FloatL10n {
  static String _lang = 'en';

  /// 起動時に 1 回呼ぶ。 失敗しても英語で動く。
  static Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final v = (sp.getString('appLanguage') ?? '').trim();
      if (v.isNotEmpty) _lang = v;
    } catch (_) {}
  }

  static String t(String key) {
    final m = _table[key];
    if (m == null) return key;
    return m[_lang] ?? m['en'] ?? m['ja'] ?? key;
  }

  static const Map<String, Map<String, String>> _table = {
    // ── 外に出した AI アシスタントの窓 (= ユーザー要望) ──
    // ── 画面録画をアプリの外に出した時の文言 (= ユーザー要望)。
    //    'rec.stop' は既にあるのでそちらを使う。 ──
    'rec.notRecording': {
      'ja': '録画していません',
      'en': 'Not recording',
      'zh': '未在录制',
      'ko': '녹화 중이 아닙니다',
      'es': 'No se esta grabando',
      'fr': 'Pas d enregistrement',
      'de': 'Keine Aufnahme',
      'pt': 'Nao esta gravando',
      'ru': 'Запись не идёт',
    },
    'assist.title': {
      'ja': 'AI アシスタント',
      'en': 'AI assistant',
      'zh': 'AI 助手',
      'ko': 'AI 어시스턴트',
      'es': 'Asistente de IA',
      'fr': 'Assistant IA',
      'de': 'KI-Assistent',
      'pt': 'Assistente de IA',
      'ru': 'ИИ-ассистент',
    },
    'assist.hint': {
      'ja': 'AIへの指示を入力… (Enterで送信)',
      'en': 'Tell the AI what to do (Enter to send)',
      'zh': '输入对 AI 的指示（回车发送）',
      'ko': 'AI에게 지시를 입력 (Enter로 전송)',
      'es': 'Indica a la IA qué hacer (Enter para enviar)',
      'fr': 'Dites a l IA quoi faire (Entree pour envoyer)',
      'de': 'Anweisung an die KI (Enter zum Senden)',
      'pt': 'Diga a IA o que fazer (Enter para enviar)',
      'ru': 'Укажите задачу для ИИ (Enter — отправить)',
    },
    'assist.empty': {
      'ja': 'このまま指示を書くと、本体のアプリが動きます。\n'
          '（考える所はアプリ本体に残っています）',
      'en': 'Type here and the main app will do the work.\n'
          '(The thinking stays in the main app.)',
      'zh': '在此输入指示，主程序会执行。',
      'ko': '여기에 지시를 쓰면 본체 앱이 작업합니다.',
      'es': 'Escribe aqui y la aplicacion principal hara el trabajo.',
      'fr': 'Ecrivez ici et l application principale agit.',
      'de': 'Hier schreiben - die Haupt-App fuehrt es aus.',
      'pt': 'Escreva aqui e o aplicativo principal executa.',
      'ru': 'Пишите здесь — работу выполнит основное приложение.',
    },
    'assist.thinking': {
      'ja': '考えています',
      'en': 'Thinking',
      'zh': '思考中',
      'ko': '생각 중',
      'es': 'Pensando',
      'fr': 'Reflexion',
      'de': 'Denkt nach',
      'pt': 'Pensando',
      'ru': 'Думает',
    },
    'assist.stopping': {
      'ja': '止めています…',
      'en': 'Stopping...',
      'zh': '正在停止…',
      'ko': '중지하는 중…',
      'es': 'Deteniendo...',
      'fr': 'Arret...',
      'de': 'Wird gestoppt...',
      'pt': 'Parando...',
      'ru': 'Останавливаем…',
    },
    'assist.stop': {
      'ja': '停止',
      'en': 'Stop',
      'zh': '停止',
      'ko': '중지',
      'es': 'Detener',
      'fr': 'Arreter',
      'de': 'Stopp',
      'pt': 'Parar',
      'ru': 'Стоп',
    },
    'assist.pin': {
      'ja': '常に手前に出す',
      'en': 'Keep on top',
      'zh': '始终置顶',
      'ko': '항상 위에 표시',
      'es': 'Mantener al frente',
      'fr': 'Toujours au premier plan',
      'de': 'Immer im Vordergrund',
      'pt': 'Manter na frente',
      'ru': 'Поверх всех окон',
    },
    'assist.close': {
      'ja': '閉じる',
      'en': 'Close',
      'zh': '关闭',
      'ko': '닫기',
      'es': 'Cerrar',
      'fr': 'Fermer',
      'de': 'Schliessen',
      'pt': 'Fechar',
      'ru': 'Закрыть',
    },
    // ── 画面録画の操作窓 (= ユーザー要望) ──
    'rec.start': {
      'ja': '録画開始',
      'en': 'Record',
      'zh': '开始录制',
      'ko': '녹화 시작',
      'es': 'Grabar',
      'fr': 'Enregistrer',
      'de': 'Aufnehmen',
      'pt': 'Gravar',
      'ru': 'Запись',
    },
    'rec.stop': {
      'ja': '停止',
      'en': 'Stop',
      'zh': '停止',
      'ko': '중지',
      'es': 'Parar',
      'fr': 'Arreter',
      'de': 'Stopp',
      'pt': 'Parar',
      'ru': 'Стоп',
    },
    'rec.whole': {
      'ja': '画面全体',
      'en': 'Whole screen',
      'zh': '整个屏幕',
      'ko': '전체 화면',
      'es': 'Pantalla completa',
      'fr': 'Tout l ecran',
      'de': 'Ganzer Bildschirm',
      'pt': 'Tela inteira',
      'ru': 'Весь экран',
    },
    'rec.area': {
      'ja': '範囲',
      'en': 'Area',
      'zh': '范围',
      'ko': '범위',
      'es': 'Area',
      'fr': 'Zone',
      'de': 'Bereich',
      'pt': 'Area',
      'ru': 'Область',
    },
    'rec.saveDir': {
      'ja': '保存先を選ぶ',
      'en': 'Choose save folder',
      'zh': '选择保存位置',
      'ko': '저장 위치 선택',
      'es': 'Elegir carpeta',
      'fr': 'Choisir le dossier',
      'de': 'Speicherort waehlen',
      'pt': 'Escolher pasta',
      'ru': 'Выбрать папку',
    },
    'rec.openFolder': {
      'ja': '場所を開く',
      'en': 'Show in folder',
      'zh': '打开位置',
      'ko': '위치 열기',
      'es': 'Abrir carpeta',
      'fr': 'Ouvrir le dossier',
      'de': 'Ordner oeffnen',
      'pt': 'Abrir pasta',
      'ru': 'Открыть папку',
    },
    'rec.notCaptured': {
      'ja': 'この窓は録画に写りません',
      'en': 'This window is not captured in the recording',
      'zh': '此窗口不会被录进去',
      'ko': '이 창은 녹화에 찍히지 않습니다',
      'es': 'Esta ventana no se graba',
      'fr': 'Cette fenetre n est pas enregistree',
      'de': 'Dieses Fenster wird nicht aufgenommen',
      'pt': 'Esta janela nao e gravada',
      'ru': 'Это окно не попадает в запись',
    },
    'rec.preview': {
      'ja': '撮影後にプレビュー',
      'en': 'Preview when done',
      'zh': '录完后预览',
      'ko': '촬영 후 미리보기',
      'es': 'Vista previa al terminar',
      'fr': 'Apercu a la fin',
      'de': 'Vorschau danach',
      'pt': 'Previa ao terminar',
      'ru': 'Предпросмотр после',
    },
    'rec.regionTitle': {
      'ja': '録る範囲を選ぶ',
      'en': 'Choose the area to record',
      'zh': '选择录制范围',
      'ko': '녹화할 범위 선택',
      'es': 'Elige el área a grabar',
      'fr': 'Choisir la zone à enregistrer',
      'de': 'Aufnahmebereich wählen',
      'pt': 'Escolha a área a gravar',
      'ru': 'Выберите область записи',
    },
    'rec.regionHint': {
      'ja': '画面の上をなぞると、その範囲だけを録ります。なぞらずに「録画開始」を押すと画面全体です。',
      'en': 'Drag over the picture to record just that area. Press Start without dragging to record the whole screen.',
      'zh': '在画面上拖动即可只录制该范围。不拖动直接点“开始录制”则录制整个屏幕。',
      'ko': '화면 위를 드래그하면 그 범위만 녹화합니다. 드래그하지 않고 시작을 누르면 전체 화면입니다.',
      'es': 'Arrastra sobre la imagen para grabar solo esa zona. Pulsa Iniciar sin arrastrar para toda la pantalla.',
      'fr': 'Faites glisser sur l\'image pour n\'enregistrer que cette zone. Sans glisser, tout l\'écran est enregistré.',
      'de': 'Ziehe über das Bild, um nur diesen Bereich aufzunehmen. Ohne Ziehen wird der ganze Bildschirm aufgenommen.',
      'pt': 'Arraste sobre a imagem para gravar só essa área. Sem arrastar, grava a tela inteira.',
      'ru': 'Проведите по изображению, чтобы записать только эту область. Без выделения записывается весь экран.',
    },
    'rec.regionWhole': {
      'ja': '画面全体を録ります',
      'en': 'Recording the whole screen',
      'zh': '录制整个屏幕',
      'ko': '전체 화면을 녹화합니다',
      'es': 'Se grabará toda la pantalla',
      'fr': 'Tout l\'écran sera enregistré',
      'de': 'Der ganze Bildschirm wird aufgenommen',
      'pt': 'A tela inteira será gravada',
      'ru': 'Будет записан весь экран',
    },
    'rec.regionReset': {
      'ja': '選び直す',
      'en': 'Clear',
      'zh': '重选',
      'ko': '다시 선택',
      'es': 'Borrar',
      'fr': 'Effacer',
      'de': 'Zurücksetzen',
      'pt': 'Limpar',
      'ru': 'Сбросить',
    },
    'rec.previewTitle': {
      'ja': '録画のプレビュー',
      'en': 'Recording preview',
      'zh': '录制预览',
      'ko': '녹화 미리보기',
      'es': 'Vista previa de la grabación',
      'fr': 'Aperçu de l\'enregistrement',
      'de': 'Aufnahmevorschau',
      'pt': 'Prévia da gravação',
      'ru': 'Предпросмотр записи',
    },
    'rec.close': {
      'ja': '閉じる',
      'en': 'Close',
      'zh': '关闭',
      'ko': '닫기',
      'es': 'Cerrar',
      'fr': 'Fermer',
      'de': 'Schließen',
      'pt': 'Fechar',
      'ru': 'Закрыть',
    },
    'rec.stopKey': {
      'ja': '停止キー',
      'en': 'Stop key',
      'zh': '停止键',
      'ko': '중지 키',
      'es': 'Tecla de parada',
      'fr': 'Touche d\'arret',
      'de': 'Stopp-Taste',
      'pt': 'Tecla de parada',
      'ru': 'Клавиша остановки',
    },
    'float.pin': {
      'ja': '常に手前に表示', 'en': 'Always on top', 'zh': '始终置顶',
      'ko': '항상 위에 표시', 'es': 'Siempre visible',
      'fr': 'Toujours au premier plan', 'de': 'Immer im Vordergrund',
      'pt': 'Sempre visível', 'ru': 'Поверх всех окон',
    },
    'calc.title': {
      'ja': '関数電卓', 'en': 'Calculator', 'zh': '科学计算器', 'ko': '공학용 계산기',
      'es': 'Calculadora', 'fr': 'Calculatrice', 'de': 'Rechner',
      'pt': 'Calculadora', 'ru': 'Калькулятор',
    },
    'float.openMemo': {
      'ja': 'フローティングメモを開く', 'en': 'Open the floating memo',
      'zh': '打开浮动便签', 'ko': '플로팅 메모 열기',
      'es': 'Abrir la nota flotante', 'fr': 'Ouvrir le mémo flottant',
      'de': 'Schwebende Notiz öffnen', 'pt': 'Abrir a nota flutuante',
      'ru': 'Открыть плавающую заметку',
    },
    'float.backHome': {
      'ja': '元の画面に戻る', 'en': 'Back to the original page',
      'zh': '返回原来的页面', 'ko': '원래 화면으로 돌아가기',
      'es': 'Volver a la página original', 'fr': 'Revenir à la page d’origine',
      'de': 'Zur ursprünglichen Seite zurück', 'pt': 'Voltar à página original',
      'ru': 'Вернуться к исходной странице',
    },
    // 外の窓で動画を見る時の再生速度 (= ユーザー要望: 要素から開いた
    //   YouTube は外の窓で立ち上がるので、 速度もそこで変えられるように)。
    'float.playbackRate': {
      'ja': '再生速度', 'en': 'Playback speed', 'zh': '播放速度',
      'ko': '재생 속도', 'es': 'Velocidad de reproducción',
      'fr': 'Vitesse de lecture', 'de': 'Wiedergabegeschwindigkeit',
      'pt': 'Velocidade de reprodução', 'ru': 'Скорость воспроизведения',
    },
    'memo.openAiApi': {
      'ja': 'アプリの AI で聞く (API)', 'en': 'Ask the built-in AI (API)',
      'zh': '用应用内 AI 提问（API）', 'ko': '앱의 AI로 묻기 (API)',
      'es': 'Preguntar a la IA integrada (API)',
      'fr': "Demander à l'IA intégrée (API)",
      'de': 'Die eingebaute KI fragen (API)',
      'pt': 'Perguntar à IA integrada (API)',
      'ru': 'Спросить встроенный ИИ (API)',
    },
    'float.browserAi': {
      'ja': 'ブラウザAI (この窓で開く)', 'en': 'Browser AI (opens in this window)',
      'zh': '浏览器 AI（在此窗口打开）', 'ko': '브라우저 AI (이 창에서 열기)',
      'es': 'IA del navegador (en esta ventana)',
      'fr': 'IA navigateur (dans cette fenêtre)',
      'de': 'Browser-KI (in diesem Fenster)',
      'pt': 'IA do navegador (nesta janela)',
      'ru': 'Браузерный ИИ (в этом окне)',
    },
    // ── ストップウォッチ / タイマーの外部窓 (= ユーザー要望) ──
    'timer.title': {
      'ja': 'ストップウォッチ / タイマー', 'en': 'Stopwatch / Timer',
      'zh': '秒表 / 计时器', 'ko': '스톱워치 / 타이머',
      'es': 'Cronómetro / Temporizador', 'fr': 'Chrono / Minuteur',
      'de': 'Stoppuhr / Timer', 'pt': 'Cronômetro / Timer',
      'ru': 'Секундомер / Таймер',
    },
    'timer.stopwatch': {
      'ja': 'ストップウォッチ', 'en': 'Stopwatch', 'zh': '秒表', 'ko': '스톱워치',
      'es': 'Cronómetro', 'fr': 'Chrono', 'de': 'Stoppuhr',
      'pt': 'Cronômetro', 'ru': 'Секундомер',
    },
    'timer.countdown': {
      'ja': 'タイマー', 'en': 'Timer', 'zh': '计时器', 'ko': '타이머',
      'es': 'Temporizador', 'fr': 'Minuteur', 'de': 'Timer',
      'pt': 'Timer', 'ru': 'Таймер',
    },
    'timer.pomodoro': {
      'ja': 'ポモドーロ', 'en': 'Pomodoro', 'zh': '番茄钟', 'ko': '뽀모도로',
      'es': 'Pomodoro', 'fr': 'Pomodoro', 'de': 'Pomodoro',
      'pt': 'Pomodoro', 'ru': 'Помодоро',
    },
    'timer.work': {
      'ja': '作業', 'en': 'Work', 'zh': '工作', 'ko': '작업',
      'es': 'Trabajo', 'fr': 'Travail', 'de': 'Arbeit',
      'pt': 'Trabalho', 'ru': 'Работа',
    },
    'timer.break': {
      'ja': '休憩', 'en': 'Break', 'zh': '休息', 'ko': '휴식',
      'es': 'Descanso', 'fr': 'Pause', 'de': 'Pause',
      'pt': 'Pausa', 'ru': 'Перерыв',
    },
    'timer.start': {
      'ja': 'スタート', 'en': 'Start', 'zh': '开始', 'ko': '시작',
      'es': 'Iniciar', 'fr': 'Démarrer', 'de': 'Start',
      'pt': 'Iniciar', 'ru': 'Старт',
    },
    'timer.stop': {
      'ja': 'ストップ', 'en': 'Stop', 'zh': '停止', 'ko': '정지',
      'es': 'Parar', 'fr': 'Arrêter', 'de': 'Stopp',
      'pt': 'Parar', 'ru': 'Стоп',
    },
    'timer.reset': {
      'ja': 'リセット', 'en': 'Reset', 'zh': '重置', 'ko': '리셋',
      'es': 'Reiniciar', 'fr': 'Réinitialiser', 'de': 'Zurücksetzen',
      'pt': 'Zerar', 'ru': 'Сброс',
    },
    'timer.done': {
      'ja': '時間になりました', 'en': "Time's up", 'zh': '时间到了', 'ko': '시간이 됐습니다',
      'es': 'Tiempo cumplido', 'fr': 'Temps écoulé', 'de': 'Zeit ist um',
      'pt': 'Tempo esgotado', 'ru': 'Время вышло',
    },
    'memo.title': {
      'ja': 'メモ', 'en': 'Memo', 'zh': '备忘录', 'ko': '메모',
      'es': 'Nota', 'fr': 'Note', 'de': 'Notiz', 'pt': 'Nota',
      'ru': 'Заметка',
    },
    // ── AI モデルの切り替え (= ユーザー要望: AI ボタンを長押し / 右クリック
    //    でモデルを変更できるように) ──
    'memo.aiModel': {
      'ja': 'AI モデルを変更', 'en': 'Change AI model', 'zh': '更改 AI 模型',
      'ko': 'AI 모델 변경', 'es': 'Cambiar modelo de IA',
      'fr': 'Changer de modèle d\'IA', 'de': 'KI-Modell wechseln',
      'pt': 'Mudar modelo de IA', 'ru': 'Сменить модель ИИ',
    },
    'memo.aiModelSet': {
      'ja': 'モデルを変更しました', 'en': 'Model changed', 'zh': '已更改模型',
      'ko': '모델을 변경했습니다', 'es': 'Modelo cambiado',
      'fr': 'Modèle changé', 'de': 'Modell gewechselt',
      'pt': 'Modelo alterado', 'ru': 'Модель изменена',
    },
    'memo.aiModelNone': {
      'ja': 'モデル一覧を取得できませんでした', 'en': 'Could not load the model list',
      'zh': '无法获取模型列表', 'ko': '모델 목록을 가져오지 못했습니다',
      'es': 'No se pudo cargar la lista de modelos',
      'fr': 'Impossible de charger la liste des modèles',
      'de': 'Modellliste konnte nicht geladen werden',
      'pt': 'Não foi possível carregar a lista de modelos',
      'ru': 'Не удалось получить список моделей',
    },
    'memo.aiModelHint': {
      'ja': '長押し / 右クリックでモデルを変更', 'en': 'Long-press / right-click to change model',
      'zh': '长按 / 右键更改模型', 'ko': '길게 누르기 / 우클릭으로 모델 변경',
      'es': 'Mantén pulsado / clic derecho para cambiar de modelo',
      'fr': 'Appui long / clic droit pour changer de modèle',
      'de': 'Lang drücken / Rechtsklick zum Modellwechsel',
      'pt': 'Pressione e segure / clique direito para mudar o modelo',
      'ru': 'Долгое нажатие / правый клик — смена модели',
    },
    // ── フローティング AI 窓の追加ボタン (= ユーザー要望) ──
    'memo.openAssistant': {
      'ja': 'AI アシスタントを開く', 'en': 'Open the AI assistant',
      'zh': '打开 AI 助手', 'ko': 'AI 어시스턴트 열기',
      'es': 'Abrir el asistente de IA', 'fr': "Ouvrir l'assistant IA",
      'de': 'KI-Assistenten öffnen', 'pt': 'Abrir o assistente de IA',
      'ru': 'Открыть ИИ-ассистента',
    },
    'memo.assistantFailed': {
      'ja': '本体のアプリが見つかりませんでした', 'en': 'Could not reach the main app',
      'zh': '未找到主应用', 'ko': '본체 앱을 찾지 못했습니다',
      'es': 'No se pudo contactar con la aplicación principal',
      'fr': "Impossible de joindre l'application principale",
      'de': 'Haupt-App nicht erreichbar',
      'pt': 'Não foi possível acessar o aplicativo principal',
      'ru': 'Не удалось связаться с основным приложением',
    },
    'memo.aiPrefixTip': {
      'ja': '前提条件を入力欄に入れる (長押し / 右クリックで編集)',
      'en': 'Insert your standing instructions (long-press / right-click to edit)',
      'zh': '将前提条件插入输入框（长按 / 右键编辑）',
      'ko': '전제 조건을 입력란에 넣기 (길게 누르기 / 우클릭으로 편집)',
      'es': 'Insertar tus instrucciones fijas (mantén pulsado / clic derecho para editar)',
      'fr': 'Insérer vos consignes permanentes (appui long / clic droit pour modifier)',
      'de': 'Standardvorgaben einfügen (lang drücken / Rechtsklick zum Bearbeiten)',
      'pt': 'Inserir suas instruções fixas (pressione e segure / clique direito para editar)',
      'ru': 'Вставить постоянные указания (долгое нажатие / правый клик — изменить)',
    },
    'memo.aiPrefixTitle': {
      'ja': '前提条件', 'en': 'Standing instructions', 'zh': '前提条件',
      'ko': '전제 조건', 'es': 'Instrucciones fijas',
      'fr': 'Consignes permanentes', 'de': 'Standardvorgaben',
      'pt': 'Instruções fixas', 'ru': 'Постоянные указания',
    },
    'memo.aiPrefixDesc': {
      'ja': 'AI に渡す文の先頭に、いつも付けたい指示を書いておけます。',
      'en': 'Text you always want prepended to what you send the AI.',
      'zh': '可以写下每次都要加在发送给 AI 的内容前面的指示。',
      'ko': 'AI에 보내는 문장 앞에 항상 붙일 지시를 적어 둘 수 있습니다.',
      'es': 'Texto que quieres anteponer siempre a lo que envías a la IA.',
      'fr': "Texte à ajouter systématiquement avant ce que vous envoyez à l'IA.",
      'de': 'Text, der immer vor Ihre KI-Eingabe gesetzt wird.',
      'pt': 'Texto que você quer sempre antes do que envia para a IA.',
      'ru': 'Текст, который всегда добавляется перед вашим запросом к ИИ.',
    },
    'memo.aiPrefixHint': {
      'ja': '例: 日本語で、結論から答えて',
      'en': 'e.g. Answer in English, conclusion first',
      'zh': '例：用中文回答，先说结论',
      'ko': '예: 한국어로, 결론부터 답해줘',
      'es': 'ej.: Responde en español, primero la conclusión',
      'fr': "ex. : Réponds en français, conclusion d'abord",
      'de': 'z. B. Antworte auf Deutsch, Fazit zuerst',
      'pt': 'ex.: Responda em português, conclusão primeiro',
      'ru': 'напр.: Отвечай по-русски, сначала вывод',
    },
    'memo.hideHeader': {
      'ja': 'ヘッダーを隠す', 'en': 'Hide the header', 'zh': '隐藏标题栏',
      'ko': '헤더 숨기기', 'es': 'Ocultar el encabezado',
      'fr': "Masquer l'en-tête", 'de': 'Kopfzeile ausblenden',
      'pt': 'Ocultar o cabeçalho', 'ru': 'Скрыть заголовок',
    },
    'memo.showHeader': {
      'ja': 'ヘッダーを表示', 'en': 'Show the header', 'zh': '显示标题栏',
      'ko': '헤더 표시', 'es': 'Mostrar el encabezado',
      'fr': "Afficher l'en-tête", 'de': 'Kopfzeile einblenden',
      'pt': 'Mostrar o cabeçalho', 'ru': 'Показать заголовок',
    },
    'btn.cancel': {
      'ja': 'キャンセル', 'en': 'Cancel', 'zh': '取消', 'ko': '취소',
      'es': 'Cancelar', 'fr': 'Annuler', 'de': 'Abbrechen',
      'pt': 'Cancelar', 'ru': 'Отмена',
    },
    'btn.clear': {
      'ja': 'クリア', 'en': 'Clear', 'zh': '清除', 'ko': '지우기',
      'es': 'Borrar', 'fr': 'Effacer', 'de': 'Löschen',
      'pt': 'Limpar', 'ru': 'Очистить',
    },
    'btn.save': {
      'ja': '保存', 'en': 'Save', 'zh': '保存', 'ko': '저장',
      'es': 'Guardar', 'fr': 'Enregistrer', 'de': 'Speichern',
      'pt': 'Salvar', 'ru': 'Сохранить',
    },
    // ── 複数メモ (= ユーザー要望: フローティングメモを複数保存) ──
    'memo.book1': {
      'ja': 'メモ 1', 'en': 'Memo 1', 'zh': '备忘录 1', 'ko': '메모 1',
      'es': 'Nota 1', 'fr': 'Note 1', 'de': 'Notiz 1', 'pt': 'Nota 1',
      'ru': 'Заметка 1',
    },
    'memo.bookPrefix': {
      'ja': 'メモ', 'en': 'Memo', 'zh': '备忘录', 'ko': '메모',
      'es': 'Nota', 'fr': 'Note', 'de': 'Notiz', 'pt': 'Nota',
      'ru': 'Заметка',
    },
    'memo.newBook': {
      'ja': '新しいメモ', 'en': 'New memo', 'zh': '新建备忘录',
      'ko': '새 메모', 'es': 'Nueva nota', 'fr': 'Nouvelle note',
      'de': 'Neue Notiz', 'pt': 'Nova nota', 'ru': 'Новая заметка',
    },
    'memo.renameBook': {
      'ja': 'メモの名前を変える', 'en': 'Rename this memo',
      'zh': '重命名备忘录', 'ko': '메모 이름 변경',
      'es': 'Renombrar esta nota', 'fr': 'Renommer cette note',
      'de': 'Notiz umbenennen', 'pt': 'Renomear esta nota',
      'ru': 'Переименовать заметку',
    },
    'memo.deleteBook': {
      'ja': 'このメモを削除', 'en': 'Delete this memo',
      'zh': '删除此备忘录', 'ko': '이 메모 삭제',
      'es': 'Eliminar esta nota', 'fr': 'Supprimer cette note',
      'de': 'Diese Notiz löschen', 'pt': 'Excluir esta nota',
      'ru': 'Удалить эту заметку',
    },
    'memo.editItem': {
      'ja': '項目を書き直す', 'en': 'Edit this item', 'zh': '编辑此条目',
      'ko': '항목 수정', 'es': 'Editar este elemento',
      'fr': 'Modifier cet élément', 'de': 'Eintrag bearbeiten',
      'pt': 'Editar este item', 'ru': 'Изменить запись',
    },
    'memo.itemCount': {
      'ja': '{n} 件', 'en': '{n} items', 'zh': '{n} 条', 'ko': '{n} 개',
      'es': '{n} elementos', 'fr': '{n} éléments', 'de': '{n} Einträge',
      'pt': '{n} itens', 'ru': '{n} записей',
    },
    'memo.allToAi': {
      'ja': 'まとめてAI', 'en': 'All to AI', 'zh': '全部发给 AI',
      'ko': '전체 AI로', 'es': 'Todo a la IA', 'fr': 'Tout à l IA',
      'de': 'Alles an die KI', 'pt': 'Tudo para a IA',
      'ru': 'Всё в ИИ',
    },
    'memo.allToMap': {
      'ja': 'まとめてマップ', 'en': 'All to map', 'zh': '全部加入导图',
      'ko': '전체 맵에', 'es': 'Todo al mapa', 'fr': 'Tout vers la carte',
      'de': 'Alles zur Map', 'pt': 'Tudo para o mapa',
      'ru': 'Всё на карту',
    },
    'memo.clearAll': {
      'ja': 'すべて削除', 'en': 'Delete all', 'zh': '全部删除',
      'ko': '모두 삭제', 'es': 'Eliminar todo', 'fr': 'Tout supprimer',
      'de': 'Alle löschen', 'pt': 'Excluir tudo', 'ru': 'Удалить всё',
    },
    'memo.clearAllConfirm': {
      'ja': '{n} 件のメモをすべて削除しますか？',
      'en': 'Delete all {n} items?',
      'zh': '要删除全部 {n} 条备忘吗？',
      'ko': '{n} 개의 메모를 모두 삭제할까요?',
      'es': '¿Eliminar los {n} elementos?',
      'fr': 'Supprimer les {n} éléments ?',
      'de': 'Alle {n} Einträge löschen?',
      'pt': 'Excluir todos os {n} itens?',
      'ru': 'Удалить все {n} записей?',
    },
    'memo.cancel': {
      'ja': 'キャンセル', 'en': 'Cancel', 'zh': '取消', 'ko': '취소',
      'es': 'Cancelar', 'fr': 'Annuler', 'de': 'Abbrechen',
      'pt': 'Cancelar', 'ru': 'Отмена',
    },
    'memo.ok': {
      'ja': 'OK', 'en': 'OK', 'zh': '确定', 'ko': '확인', 'es': 'Aceptar',
      'fr': 'OK', 'de': 'OK', 'pt': 'OK', 'ru': 'OK',
    },
    'memo.hintList': {
      'ja': 'ここにメモ (Enter=追加 / Shift+Enter=改行)',
      'en': 'Type a memo (Enter = add, Shift+Enter = new line)',
      'zh': '在此输入备忘（Enter=添加 / Shift+Enter=换行）',
      'ko': '여기에 메모 (Enter=추가 / Shift+Enter=줄바꿈)',
      'es': 'Escribe una nota (Enter = añadir, Shift+Enter = salto de línea)',
      'fr': 'Saisir une note (Entrée = ajouter, Maj+Entrée = nouvelle ligne)',
      'de': 'Notiz eingeben (Enter = hinzufügen, Umschalt+Enter = neue Zeile)',
      'pt': 'Digite uma nota (Enter = adicionar, Shift+Enter = nova linha)',
      'ru': 'Введите заметку (Enter — добавить, Shift+Enter — новая строка)',
    },
    'memo.hintFree': {
      'ja': 'ここに自由にメモ (自動保存)',
      'en': 'Write freely here (saved automatically)',
      'zh': '在此自由记录（自动保存）',
      'ko': '자유롭게 메모 (자동 저장)',
      'es': 'Escribe libremente (guardado automático)',
      'fr': 'Écrivez librement (sauvegarde automatique)',
      'de': 'Frei schreiben (automatisch gespeichert)',
      'pt': 'Escreva livremente (salvo automaticamente)',
      'ru': 'Пишите свободно (сохраняется автоматически)',
    },
    'memo.hintOverlay': {
      'ja': 'ここにメモ… (自動保存)',
      'en': 'Type a memo… (saved automatically)',
      'zh': '在此输入备忘…（自动保存）',
      'ko': '여기에 메모… (자동 저장)',
      'es': 'Escribe una nota… (guardado automático)',
      'fr': 'Saisir une note… (sauvegarde auto)',
      'de': 'Notiz eingeben… (auto-gespeichert)',
      'pt': 'Digite uma nota… (salvo automaticamente)',
      'ru': 'Введите заметку… (сохраняется автоматически)',
    },
    'memo.emptyHint': {
      'ja': '上の欄に書いて Enter で追加',
      'en': 'Type above and press Enter to add',
      'zh': '在上方输入并按 Enter 添加',
      'ko': '위 칸에 입력하고 Enter로 추가',
      'es': 'Escribe arriba y pulsa Enter para añadir',
      'fr': 'Saisissez ci-dessus puis Entrée pour ajouter',
      'de': 'Oben eingeben und mit Enter hinzufügen',
      'pt': 'Digite acima e pressione Enter para adicionar',
      'ru': 'Введите выше и нажмите Enter, чтобы добавить',
    },
    'memo.saveAsText': {
      'ja': 'テキストで保存', 'en': 'Save as text', 'zh': '保存为文本',
      'ko': '텍스트로 저장', 'es': 'Guardar como texto',
      'fr': 'Enregistrer en texte', 'de': 'Als Text speichern',
      'pt': 'Salvar como texto', 'ru': 'Сохранить как текст',
    },
    'memo.saveDir': {
      'ja': '保存場所の設定', 'en': 'Save location', 'zh': '保存位置',
      'ko': '저장 위치', 'es': 'Ubicacion de guardado',
      'fr': 'Dossier d\'enregistrement', 'de': 'Speicherort',
      'pt': 'Local de salvamento', 'ru': 'Папка сохранения',
    },
    'memo.saveDirPick': {
      'ja': '保存場所を選ぶ...', 'en': 'Choose folder...',
      'zh': '选择文件夹...', 'ko': '폴더 선택...',
      'es': 'Elegir carpeta...', 'fr': 'Choisir un dossier...',
      'de': 'Ordner wahlen...', 'pt': 'Escolher pasta...',
      'ru': 'Выбрать папку...',
    },
    'memo.saveDirDefault': {
      'ja': '既定の場所に戻す', 'en': 'Use the default folder',
      'zh': '恢复默认位置', 'ko': '기본 위치로',
      'es': 'Usar la carpeta predeterminada',
      'fr': 'Revenir au dossier par defaut',
      'de': 'Standardordner verwenden', 'pt': 'Usar a pasta padrao',
      'ru': 'Папка по умолчанию',
    },
    'memo.saveDirHint': {
      'ja': '右クリックで保存場所', 'en': 'Right-click for the save location',
      'zh': '右键设置保存位置', 'ko': '오른쪽 클릭으로 저장 위치',
      'es': 'Clic derecho: ubicacion de guardado',
      'fr': 'Clic droit : dossier d\'enregistrement',
      'de': 'Rechtsklick: Speicherort',
      'pt': 'Clique direito: local de salvamento',
      'ru': 'Правый клик — папка сохранения',
    },
    'memo.saved': {
      'ja': '保存しました: {path}', 'en': 'Saved: {path}', 'zh': '已保存：{path}',
      'ko': '저장했습니다: {path}', 'es': 'Guardado: {path}',
      'fr': 'Enregistré : {path}', 'de': 'Gespeichert: {path}',
      'pt': 'Salvo: {path}', 'ru': 'Сохранено: {path}',
    },
    'memo.pasteImage': {
      'ja': '画像を貼り付け', 'en': 'Paste an image', 'zh': '粘贴图片',
      'ko': '이미지 붙여넣기', 'es': 'Pegar una imagen', 'fr': 'Coller une image',
      'de': 'Bild einfügen', 'pt': 'Colar uma imagem', 'ru': 'Вставить изображение',
    },
    'memo.noImage': {
      'ja': 'クリップボードに画像がありません', 'en': 'No image on the clipboard',
      'zh': '剪贴板中没有图片', 'ko': '클립보드에 이미지가 없습니다',
      'es': 'No hay imagen en el portapapeles',
      'fr': "Pas d'image dans le presse-papiers",
      'de': 'Kein Bild in der Zwischenablage',
      'pt': 'Nenhuma imagem na área de transferência',
      'ru': 'В буфере обмена нет изображения',
    },
    'memo.add': {
      'ja': '追加', 'en': 'Add', 'zh': '添加', 'ko': '추가',
      'es': 'Añadir', 'fr': 'Ajouter', 'de': 'Hinzufügen',
      'pt': 'Adicionar', 'ru': 'Добавить',
    },
    'memo.delete': {
      'ja': '削除', 'en': 'Delete', 'zh': '删除', 'ko': '삭제',
      'es': 'Eliminar', 'fr': 'Supprimer', 'de': 'Löschen',
      'pt': 'Excluir', 'ru': 'Удалить',
    },
    'memo.toAi': {
      'ja': 'AIに渡す', 'en': 'Send to AI', 'zh': '发送给 AI',
      'ko': 'AI에 보내기', 'es': 'Enviar a la IA', 'fr': 'Envoyer à l IA',
      'de': 'An die KI senden', 'pt': 'Enviar para a IA',
      'ru': 'Отправить ИИ',
    },
    'memo.googleSearch': {
      'ja': 'Google検索', 'en': 'Google search', 'zh': 'Google 搜索',
      'ko': 'Google 검색', 'es': 'Buscar en Google',
      'fr': 'Recherche Google', 'de': 'Google-Suche',
      'pt': 'Pesquisar no Google', 'ru': 'Поиск в Google',
    },
    'memo.addToMap': {
      'ja': 'マップに追加', 'en': 'Add to map', 'zh': '添加到导图',
      'ko': '맵에 추가', 'es': 'Añadir al mapa', 'fr': 'Ajouter à la carte',
      'de': 'Zur Map hinzufügen', 'pt': 'Adicionar ao mapa',
      'ru': 'Добавить на карту',
    },
    'memo.pickPageAddToMap': {
      'ja': 'ページを選んでマップに追加',
      'en': 'Pick a page and add to the map',
      'zh': '选择页面并添加到导图',
      'ko': '페이지를 선택해 맵에 추가',
      'es': 'Elegir una página y añadir al mapa',
      'fr': 'Choisir une page et ajouter à la carte',
      'de': 'Seite wählen und zur Map hinzufügen',
      'pt': 'Escolher uma página e adicionar ao mapa',
      'ru': 'Выбрать страницу и добавить на карту',
    },
    'memo.addedToMap': {
      'ja': 'マップに追加しました', 'en': 'Added to the map',
      'zh': '已添加到导图', 'ko': '맵에 추가했습니다',
      'es': 'Añadido al mapa', 'fr': 'Ajouté à la carte',
      'de': 'Zur Map hinzugefügt', 'pt': 'Adicionado ao mapa',
      'ru': 'Добавлено на карту',
    },
    'memo.mainNotRunning': {
      'ja': '本体のアプリが起動していません', 'en': 'The main app is not running',
      'zh': '主应用未启动', 'ko': '본체 앱이 실행되어 있지 않습니다',
      'es': 'La aplicacion principal no esta abierta',
      'fr': "L'application principale n'est pas lancee",
      'de': 'Die Haupt-App lauft nicht',
      'pt': 'O aplicativo principal nao esta aberto',
      'ru': 'Основное приложение не запущено',
    },
    // 本体が起動していなくても追加できる (= ユーザー要望): 控えておいて
    // 本体の次回起動時にマップへ追加する。
    'memo.queuedForNextLaunch': {
      'ja': '控えました。本体の次回起動時にマップへ追加されます',
      'en': 'Saved. It will be added to the map next time the app starts',
      'zh': '已保存。主应用下次启动时会添加到地图',
      'ko': '보관했습니다. 본체 다음 실행 시 맵에 추가됩니다',
      'es': 'Guardado. Se añadirá al mapa la próxima vez que abras la app',
      'fr': "Enregistré. Ce sera ajouté à la carte au prochain démarrage",
      'de': 'Gespeichert. Wird beim nächsten Start zur Map hinzugefügt',
      'pt': 'Salvo. Será adicionado ao mapa na próxima abertura do app',
      'ru': 'Сохранено. Будет добавлено на карту при следующем запуске',
    },
    'memo.noPages': {
      'ja': '追加できるページがありません',
      'en': 'There are no pages to add to',
      'zh': '没有可添加的页面',
      'ko': '추가할 수 있는 페이지가 없습니다',
      'es': 'No hay páginas a las que añadir',
      'fr': 'Aucune page disponible',
      'de': 'Keine Seiten zum Hinzufügen vorhanden',
      'pt': 'Não há páginas para adicionar',
      'ru': 'Нет страниц для добавления',
    },
    'memo.backToMemo': {
      'ja': 'メモに戻る', 'en': 'Back to the memo', 'zh': '返回备忘录',
      'ko': '메모로 돌아가기', 'es': 'Volver a la nota',
      'fr': 'Retour à la note', 'de': 'Zurück zur Notiz',
      'pt': 'Voltar à nota', 'ru': 'Назад к заметке',
    },
    'memo.switchToFree': {
      'ja': 'フリーメモに切替', 'en': 'Switch to free-form',
      'zh': '切换到自由记录', 'ko': '자유 메모로 전환',
      'es': 'Cambiar a texto libre', 'fr': 'Passer en texte libre',
      'de': 'Zu Freitext wechseln', 'pt': 'Mudar para texto livre',
      'ru': 'Переключить на свободный текст',
    },
    'memo.switchToList': {
      'ja': '箇条書きに切替', 'en': 'Switch to a list',
      'zh': '切换到列表', 'ko': '목록으로 전환',
      'es': 'Cambiar a lista', 'fr': 'Passer en liste',
      'de': 'Zur Liste wechseln', 'pt': 'Mudar para lista',
      'ru': 'Переключить на список',
    },
    'memo.openAi': {
      'ja': 'AIを開く', 'en': 'Open AI', 'zh': '打开 AI',
      'ko': 'AI 열기', 'es': 'Abrir la IA', 'fr': 'Ouvrir l IA',
      'de': 'KI öffnen', 'pt': 'Abrir a IA', 'ru': 'Открыть ИИ',
    },
    // 上下のボタン類 (アイコン・題・AI・下の 3 つ) をまとめて隠す切替。
    'memo.hideFooter': {
      'ja': 'ボタン類を隠す', 'en': 'Hide the buttons',
      'zh': '隐藏按钮', 'ko': '버튼 숨기기',
      'es': 'Ocultar los botones',
      'fr': 'Masquer les boutons',
      'de': 'Schaltflächen ausblenden',
      'pt': 'Ocultar os botões', 'ru': 'Скрыть кнопки',
    },
    'memo.showFooter': {
      'ja': 'ボタン類を出す', 'en': 'Show the buttons',
      'zh': '显示按钮', 'ko': '버튼 표시',
      'es': 'Mostrar los botones',
      'fr': 'Afficher les boutons',
      'de': 'Schaltflächen einblenden',
      'pt': 'Mostrar os botões', 'ru': 'Показать кнопки',
    },
    // メモ窓の中の AI 画面。
    'memo.aiTitle': {
      'ja': 'AI', 'en': 'AI', 'zh': 'AI', 'ko': 'AI',
      'es': 'IA', 'fr': 'IA', 'de': 'KI', 'pt': 'IA', 'ru': 'ИИ',
    },
    'memo.aiHint': {
      'ja': 'AIに聞く… (送信ボタンで実行)',
      'en': 'Ask the AI… (press send)',
      'zh': '向 AI 提问…(点击发送)',
      'ko': 'AI에게 질문… (보내기)',
      'es': 'Pregunta a la IA… (pulsa enviar)',
      'fr': "Demandez à l'IA… (envoyer)",
      'de': 'Die KI fragen… (senden)',
      'pt': 'Pergunte à IA… (enviar)',
      'ru': 'Спросить ИИ… (отправить)',
    },
    'memo.aiEmptyHint': {
      'ja': 'ここに答えが出ます',
      'en': 'The answer will appear here',
      'zh': '答案会显示在这里',
      'ko': '여기에 답이 표시됩니다',
      'es': 'La respuesta aparecerá aquí',
      'fr': 'La réponse apparaîtra ici',
      'de': 'Die Antwort erscheint hier',
      'pt': 'A resposta aparecerá aqui',
      'ru': 'Ответ появится здесь',
    },
    'memo.aiEmpty': {
      'ja': '答えが返ってきませんでした',
      'en': 'No answer came back',
      'zh': '没有返回答案',
      'ko': '답이 오지 않았습니다',
      'es': 'No llegó ninguna respuesta',
      'fr': "Aucune réponse n'est revenue",
      'de': 'Es kam keine Antwort zurück',
      'pt': 'Nenhuma resposta voltou',
      'ru': 'Ответ не пришёл',
    },
    'memo.aiKeep': {
      'ja': 'メモに残す', 'en': 'Keep as a memo', 'zh': '保存为备忘',
      'ko': '메모로 남기기', 'es': 'Guardar como nota',
      'fr': 'Garder en note', 'de': 'Als Notiz behalten',
      'pt': 'Guardar como nota', 'ru': 'Сохранить в заметку',
    },
    'memo.aiBrowser': {
      'ja': 'ブラウザ版で開く', 'en': 'Open the browser version',
      'zh': '用网页版打开', 'ko': '브라우저 버전으로 열기',
      'es': 'Abrir la versión web', 'fr': 'Ouvrir la version web',
      'de': 'Browser-Version öffnen', 'pt': 'Abrir a versão web',
      'ru': 'Открыть веб-версию',
    },
    'memo.openMemo': {
      'ja': 'メモを開く', 'en': 'Open the memo', 'zh': '打开备忘录',
      'ko': '메모 열기', 'es': 'Abrir la nota', 'fr': 'Ouvrir la note',
      'de': 'Notiz öffnen', 'pt': 'Abrir a nota', 'ru': 'Открыть заметку',
    },
    'memo.pin': {
      'ja': '常に手前に表示', 'en': 'Always on top', 'zh': '始终置顶',
      'ko': '항상 위에 표시', 'es': 'Siempre visible',
      'fr': 'Toujours au premier plan', 'de': 'Immer im Vordergrund',
      'pt': 'Sempre visível', 'ru': 'Поверх всех окон',
    },
    'memo.unpin': {
      'ja': '手前固定を解除', 'en': 'Stop staying on top',
      'zh': '取消置顶', 'ko': '항상 위 표시 해제',
      'es': 'Dejar de estar siempre visible',
      'fr': 'Ne plus rester au premier plan',
      'de': 'Nicht mehr im Vordergrund', 'pt': 'Parar de ficar visível',
      'ru': 'Не поверх всех окон',
    },
    'memo.openFailed': {
      'ja': '開けませんでした', 'en': 'Could not open it',
      'zh': '无法打开', 'ko': '열 수 없습니다', 'es': 'No se pudo abrir',
      'fr': 'Impossible d ouvrir', 'de': 'Konnte nicht geöffnet werden',
      'pt': 'Não foi possível abrir', 'ru': 'Не удалось открыть',
    },
    'memo.addToPage': {
      'ja': '今のページに追加（アプリに戻ると反映）',
      'en': 'Add to the current page (applied when you return to the app)',
      'zh': '添加到当前页面（返回应用后生效）',
      'ko': '현재 페이지에 추가 (앱으로 돌아오면 반영)',
      'es': 'Anadir a la pagina actual (se aplica al volver a la app)',
      'fr': 'Ajouter a la page actuelle (applique au retour dans l app)',
      'de': 'Zur aktuellen Seite hinzufuegen (wird beim Zurueckkehren uebernommen)',
      'pt': 'Adicionar a pagina atual (aplicado ao voltar ao app)',
      'ru': 'Добавить на текущую страницу (применится при возврате в приложение)',
    },
    'memo.inputOn': {
      'ja': '入力をオンにする', 'en': 'Turn input on', 'zh': '开启输入',
      'ko': '입력 켜기', 'es': 'Activar la entrada', 'fr': 'Activer la saisie',
      'de': 'Eingabe einschalten', 'pt': 'Ativar a entrada',
      'ru': 'Включить ввод',
    },
    'memo.inputOff': {
      'ja': '入力をオフにする（後ろのアプリを操作しやすくする）',
      'en': 'Turn input off (makes the app behind easier to use)',
      'zh': '关闭输入（便于操作后方应用）',
      'ko': '입력 끄기 (뒤쪽 앱을 조작하기 쉬워집니다)',
      'es': 'Desactivar la entrada (facilita usar la app de detras)',
      'fr': 'Desactiver la saisie (facilite l usage de l app derriere)',
      'de': 'Eingabe ausschalten (erleichtert die App dahinter)',
      'pt': 'Desativar a entrada (facilita usar o app atras)',
      'ru': 'Выключить ввод (проще управлять приложением позади)',
    },
    'ai.askHint': {
      'ja': 'AI に質問…', 'en': 'Ask the AI…', 'zh': '向 AI 提问…',
      'ko': 'AI에게 질문…', 'es': 'Pregunta a la IA…',
      'fr': 'Demander a l IA…', 'de': 'Die KI fragen…',
      'pt': 'Pergunte a IA…', 'ru': 'Спросить ИИ…',
    },
    'ai.askEmpty': {
      'ja': '上の欄に質問を書いて送信すると、ここに答えが出ます。',
      'en': 'Type a question above and send it; the answer appears here.',
      'zh': '在上方输入问题并发送，答案将显示在此处。',
      'ko': '위에 질문을 입력해 보내면 여기에 답이 표시됩니다.',
      'es': 'Escribe una pregunta arriba y enviala; la respuesta aparece aqui.',
      'fr': 'Saisissez une question ci-dessus et envoyez-la ; la reponse apparait ici.',
      'de': 'Oben eine Frage eingeben und senden; die Antwort erscheint hier.',
      'pt': 'Digite uma pergunta acima e envie; a resposta aparece aqui.',
      'ru': 'Введите вопрос выше и отправьте — ответ появится здесь.',
    },
    'ai.toMemo': {
      'ja': 'メモに残す', 'en': 'Save to memo', 'zh': '保存到备忘录',
      'ko': '메모에 저장', 'es': 'Guardar en la nota',
      'fr': 'Enregistrer dans la note', 'de': 'In Notiz speichern',
      'pt': 'Salvar na nota', 'ru': 'Сохранить в заметку',
    },
    'ai.noCredit': {
      'ja': 'AI クレジットの残高が足りません。アプリでチャージしてください。',
      'en': 'Not enough AI credit. Please add more in the app.',
      'zh': 'AI 额度不足，请在应用中充值。',
      'ko': 'AI 크레딧이 부족합니다. 앱에서 충전해 주세요.',
      'es': 'Credito de IA insuficiente. Recarga en la app.',
      'fr': 'Credit IA insuffisant. Rechargez dans l application.',
      'de': 'Nicht genug KI-Guthaben. Bitte in der App aufladen.',
      'pt': 'Credito de IA insuficiente. Recarregue no app.',
      'ru': 'Недостаточно кредита ИИ. Пополните в приложении.',
    },
    'ai.needSetup': {
      'ja': 'AI を使う準備ができていません。アプリで API キーを登録するか、クレジットをチャージしてください。',
      'en': 'The AI is not set up yet. Register an API key or add credit in the app.',
      'zh': 'AI 尚未配置。请在应用中注册 API 密钥或充值。',
      'ko': 'AI 준비가 되지 않았습니다. 앱에서 API 키를 등록하거나 크레딧을 충전해 주세요.',
      'es': 'La IA no esta configurada. Registra una clave de API o recarga credito en la app.',
      'fr': 'L IA n est pas configuree. Enregistrez une cle API ou rechargez du credit dans l application.',
      'de': 'Die KI ist nicht eingerichtet. Registrieren Sie einen API-Schluessel oder laden Sie Guthaben in der App auf.',
      'pt': 'A IA nao esta configurada. Registre uma chave de API ou recarregue credito no app.',
      'ru': 'ИИ не настроен. Зарегистрируйте ключ API или пополните кредит в приложении.',
    },
    'ai.switchAi': {
      'ja': 'AI を切り替え', 'en': 'Switch AI', 'zh': '切换 AI',
      'ko': 'AI 전환', 'es': 'Cambiar de IA', 'fr': 'Changer d IA',
      'de': 'KI wechseln', 'pt': 'Trocar de IA', 'ru': 'Сменить ИИ',
    },
    'ai.cannotOpen': {
      'ja': 'AI ウィンドウを開けませんでした',
      'en': 'Could not open the AI window',
      'zh': '无法打开 AI 窗口', 'ko': 'AI 창을 열 수 없습니다',
      'es': 'No se pudo abrir la ventana de IA',
      'fr': 'Impossible d ouvrir la fenêtre IA',
      'de': 'KI-Fenster konnte nicht geöffnet werden',
      'pt': 'Não foi possível abrir a janela da IA',
      'ru': 'Не удалось открыть окно ИИ',
    },
    'ai.loadFailed': {
      'ja': '読み込みに失敗しました', 'en': 'Loading failed',
      'zh': '加载失败', 'ko': '불러오지 못했습니다',
      'es': 'Error al cargar', 'fr': 'Échec du chargement',
      'de': 'Laden fehlgeschlagen', 'pt': 'Falha ao carregar',
      'ru': 'Не удалось загрузить',
    },
    'ai.openFailedNamed': {
      'ja': '{name} を開けませんでした', 'en': 'Could not open {name}',
      'zh': '无法打开 {name}', 'ko': '{name}을(를) 열 수 없습니다',
      'es': 'No se pudo abrir {name}', 'fr': 'Impossible d ouvrir {name}',
      'de': '{name} konnte nicht geöffnet werden',
      'pt': 'Não foi possível abrir {name}',
      'ru': 'Не удалось открыть {name}',
    },
    'ai.stalled': {
      'ja': '{name} の読み込みが終わりません。ネットワークやセキュリティ設定で遮断されている可能性があります。上の「{name} ▾」から別の AI を選べます。',
      'en': '{name} is still loading. It may be blocked by your network or security settings. You can pick a different AI from the "{name} ▾" menu above.',
      'zh': '{name} 一直在加载中。可能被网络或安全设置拦截。可从上方的「{name} ▾」菜单选择其他 AI。',
      'ko': '{name} 로딩이 끝나지 않습니다. 네트워크나 보안 설정에 의해 차단되었을 수 있습니다. 위의 「{name} ▾」에서 다른 AI를 선택할 수 있습니다.',
      'es': '{name} sigue cargando. Puede estar bloqueado por tu red o tus ajustes de seguridad. Elige otra IA en el menú «{name} ▾» de arriba.',
      'fr': '{name} continue de charger. Il est peut-être bloqué par votre réseau ou vos réglages de sécurité. Choisissez une autre IA dans le menu « {name} ▾ » ci-dessus.',
      'de': '{name} lädt weiterhin. Möglicherweise blockiert Ihr Netzwerk oder Ihre Sicherheitseinstellungen die Seite. Wählen Sie oben unter „{name} ▾“ eine andere KI.',
      'pt': '{name} continua carregando. Pode estar bloqueado pela sua rede ou pelas configurações de segurança. Escolha outra IA no menu "{name} ▾" acima.',
      'ru': '{name} всё ещё загружается. Возможно, доступ заблокирован сетью или настройками безопасности. Выберите другой ИИ в меню «{name} ▾» выше.',
    },
  };
}

const String kNodeReminderChannelName = 'ノード通知';
const String kNodeReminderChannelDescription = '「後で通知」 で予約したノードの通知';

/// 端末が対応していれば最も滑らかな表示モード (120Hz / 144Hz 等) にする
/// (= ユーザー要望: リフレッシュレートは 120Hz や 144Hz 等にも対応させて)。
///
/// ・Android 専用。 他 OS では `flutter_displaymode` が例外を投げるので
///   呼び出さない (Windows は OS がモニターのレートで描画するため不要)。
/// ・同じ解像度のまま一番リフレッシュレートが高いモードを選ぶ。 解像度が
///   変わるモードを避けることで、 レイアウト崩れを避ける。
/// ・失敗しても致命的ではないので握りつぶす (60Hz のまま動く)。
Future<void> applyPreferredDisplayMode({required bool high}) async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    if (!high) {
      await FlutterDisplayMode.setLowRefreshRate();
      return;
    }
    final modes = await FlutterDisplayMode.supported;
    if (modes.isEmpty) return;
    final active = await FlutterDisplayMode.active;
    // 現在と同じ解像度で最もレートが高いモード。
    DisplayMode? best;
    for (final m in modes) {
      if (m.width != active.width || m.height != active.height) continue;
      if (best == null || m.refreshRate > best.refreshRate) best = m;
    }
    if (best != null && best.refreshRate > active.refreshRate + 0.5) {
      await FlutterDisplayMode.setPreferredMode(best);
    } else {
      await FlutterDisplayMode.setHighRefreshRate();
    }
  } catch (e) {
    debugPrint('DisplayMode: 切り替えに失敗 (無視して続行): $e');
  }
}

/// 「プログラムから開く」 でこのアプリを指定して開かれたファイル
/// (= ユーザー要望: テキストや PDF をアプリから開けるように)。
/// Windows は起動引数でパスが渡ってくるので、 ここに貯めて画面側で処理する。
final List<String> pendingOpenFilePaths = <String>[];

/// アラームに起こされて立ち上がった時の、 そのアラームの id
/// (= ユーザー要望: アプリを閉じていても鳴るように)。 画面側が拾って鳴らす。
String? pendingAlarmId;

/// 起動引数から「開くファイル」 を拾う。 オプション (先頭が -) と
/// 実在しないパスは無視する。
List<String> _openFilePathsFromArgs(List<String> args) {
  final out = <String>[];
  for (final a in args) {
    final v = a.trim();
    if (v.isEmpty || v.startsWith('-')) continue;
    if (v == 'multi_window') continue;
    try {
      if (File(v).existsSync()) out.add(v);
    } catch (_) {}
  }
  return out;
}

// ── 「アプリで開く」 の 1 窓運用 (= ユーザー要望: 既にアプリが起動している
//    なら、 新しく立ち上げずにその画面の上でファイルを表示する) ──
//
// 本体は 127.0.0.1 のこのポートでファイルの引き渡しを待ち受ける。
// 2 個目の起動はまずここへ渡してみて、 渡せたら自分は即終了する。
// 動作設定「別ウィンドウで開く」 (prefs `openWithNewInstance`) を ON に
// すると従来どおり毎回新しく立ち上がる。
const int _kOpenWithPort = 38641;
const String _kOpenWithToken = 'HisatorNotebook-openwith-v1';

/// 「アプリで開く」 で渡されたファイルが後から (= 起動済みの本体に) 届いた
/// 合図。 画面側 (mind_map_screen) が listen して開く。
final ValueNotifier<int> openWithFilesTick = ValueNotifier<int>(0);

/// フローティング AI 窓 (別プロセス) から「AI アシスタントを開いて」 と
/// 頼まれた合図 (= ユーザー要望)。 画面側が listen して MCP チャットを開く。
/// 値は「一緒に渡したい文」 (空なら何も入れずに開く)。
final ValueNotifier<String?> assistantRequestFromFloating =
    ValueNotifier<String?>(null);

/// ショートカット起動でボタンの開き方が「フローティング」 の時に開く URL。
/// 本体を立ち上げないために main 側で解決する (screen 側の対応表の写し)。
String? _shortcutFloatingUrl(SharedPreferences prefs, String id) {
  const urls = <String, String>{
    'openChatGPT': 'https://chatgpt.com/',
    'openGemini': 'https://gemini.google.com/app',
    'openClaude': 'https://claude.ai/',
    'openDeepSeek': 'https://chat.deepseek.com/',
    'openGrok': 'https://grok.com/',
    'openGmail': 'https://mail.google.com/',
    'openReddit': 'https://www.reddit.com/',
    'openYoutube': 'https://m.youtube.com/',
    'openYoutubeMusic': 'https://music.youtube.com/',
    'openDeepL': 'https://www.deepl.com/translator',
    'openGoogleCalendar': 'https://calendar.google.com/',
    'openGoogleDrive': 'https://drive.google.com/',
    'openGoogleMaps': 'https://www.google.com/maps',
    'openGoogleEarth': 'https://earth.google.com/web/',
    'openKindle': 'https://read.amazon.co.jp/',
    'openSlack': 'https://app.slack.com/',
    'openDiscord': 'https://discord.com/channels/@me',
    'openSpotify': 'https://open.spotify.com/',
    'openSoundCloud': 'https://soundcloud.com/',
    'openAmazon': 'https://www.amazon.co.jp/',
    'openQiita': 'https://qiita.com/',
    'openLINE': 'https://line.me/ja/',
  };
  if (id == 'openAi') {
    final t = prefs.getString('browser_ai_target') ?? 'chatgpt';
    final def = MindMapProvider.browserAiTargets.firstWhere(
      (e) => e['id'] == t,
      orElse: () => MindMapProvider.browserAiTargets.first,
    );
    return (def['url'] ?? '').replaceAll('{q}', '');
  }
  if (id == 'openInstagram') {
    final landing = prefs.getString('instagramLanding') ?? 'home';
    final user = (prefs.getString('instagramUsername') ?? '').trim();
    if (landing == 'dm') return 'https://www.instagram.com/direct/inbox/';
    if (landing == 'profile' && user.isNotEmpty) {
      return 'https://www.instagram.com/$user/';
    }
    return 'https://www.instagram.com/';
  }
  return urls[id];
}

/// メモに貼る画像をアプリの中へコピーして、 その場所を返す。
/// = ユーザー要望: フローティングメモに画像を貼り付けられるように。
Future<String?> importFloatMemoImage({Uint8List? bytes, String? srcPath}) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory('${dir.path}/memo_images');
    if (!await d.exists()) await d.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    if (bytes != null && bytes.isNotEmpty) {
      final dest = '${d.path}/memo_$stamp.png';
      await File(dest).writeAsBytes(bytes, flush: true);
      return dest;
    }
    if (srcPath != null && srcPath.trim().isNotEmpty) {
      final src = File(srcPath);
      if (!await src.exists()) return null;
      final dot = srcPath.lastIndexOf('.');
      final ext = dot >= 0 ? srcPath.substring(dot) : '.png';
      final dest = '${d.path}/memo_$stamp$ext';
      await src.copy(dest);
      return dest;
    }
  } catch (e) {
    debugPrint('メモ画像の取り込みに失敗: $e');
  }
  return null;
}

/// クリップボードの画像を取り込む。 画像が無ければ null。
Future<String?> importFloatMemoImageFromClipboard() async {
  try {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;
    final reader = await clipboard.read();
    for (final fmt in const [
      Formats.png,
      Formats.jpeg,
      Formats.gif,
      Formats.webp,
      Formats.bmp,
    ]) {
      if (!reader.canProvide(fmt)) continue;
      final completer = Completer<Uint8List?>();
      reader.getFile(fmt, (file) async {
        try {
          final chunks = <int>[];
          await for (final c in file.getStream()) {
            chunks.addAll(c);
          }
          if (!completer.isCompleted) {
            completer.complete(Uint8List.fromList(chunks));
          }
        } catch (_) {
          if (!completer.isCompleted) completer.complete(null);
        }
      }, onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      });
      final bytes = await completer.future
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      if (bytes != null && bytes.isNotEmpty) {
        return importFloatMemoImage(bytes: bytes);
      }
    }
  } catch (e) {
    debugPrint('クリップボードからの画像取り込みに失敗: $e');
  }
  return null;
}

/// サービスごとの DM 未読数 (ホスト名 → 件数)。 外部フローティング窓が
/// ページ題の「(3)」 などから拾って /badge で知らせてくる
/// (= ユーザー要望: Instagram / Slack / Discord などの DM 通知を表示)。
final Map<String, int> serviceUnreadCounts = {};
final ValueNotifier<int> serviceBadgeTick = ValueNotifier<int>(0);

/// デスクトップのショートカットから「このボタンを実行して」 と届いた合図
/// (= ユーザー要望: カスタムボタンを一発で呼び出すショートカット)。
/// 値はボタン (コマンド) の ID。 画面側が listen して実行する。
final ValueNotifier<String?> commandRequestFromShortcut =
    ValueNotifier<String?>(null);

/// 起動済みの本体へ「このボタンを実行して」 と頼む。 成功したら true
/// (= 呼び出し側の 2 個目のプロセスはそのまま終了してよい)。
Future<bool> _forwardCommandToRunningInstance(String commandId) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(milliseconds: 600);
  try {
    final req = await client
        .post('127.0.0.1', _kOpenWithPort, '/command')
        .timeout(const Duration(milliseconds: 900));
    req.headers.set('x-hisator-token', _kOpenWithToken);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'id': commandId}));
    final res = await req.close().timeout(const Duration(seconds: 2));
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 1));
    return res.statusCode == 200 && body.contains(_kOpenWithToken);
  } catch (_) {
    return false;
  } finally {
    try {
      client.close(force: true);
    } catch (_) {}
  }
}

/// 外の窓 (= 別プロセスのフローティング Web 窓) を本体の分割ペインの上に
/// 置いて放した時、 本体側で「そのペインへ埋め込めるか」 を判定する差し込み口。
///
/// = ユーザー要望「要素から YouTube を立ち上げる時はいきなり外部に出す
///   モードで開き、 それを画面分割の他のペインの上に置いたら埋め込まれる
///   ようにして」。
///
/// 画面 (mind_map_screen) が起動時に登録する。 [frameOnScreen] は外の窓の
/// 画面座標での枠。 戻り値 true = 埋め込んだ (外の窓は閉じてよい)。
Future<bool> Function(Rect frameOnScreen, String url)? floatingWindowDropProbe;

/// 単体で開いたメモ窓 (ショートカット起動 = 別プロセス) からの頼みごとを
/// 本体が受ける口 (= ユーザー報告: マップに追加しようとすると「追加できる
/// ページがありません」 と出る)。 サブウィンドウと同じ method/args を渡す。
/// 画面 (mind_map_screen) が起動時に登録する。
Future<String> Function(String method, dynamic args)? floatingMemoBridge;

/// メモ窓側: 本体へ頼む (別プロセス版)。 本体が起動していなければ空。
Future<String> requestFromMainApp(String method, [dynamic args]) async {
  final client = HttpClient();
  try {
    final req = await client
        .post(InternetAddress.loopbackIPv4.address, _kOpenWithPort, '/memo')
        .timeout(const Duration(seconds: 2));
    req.headers.set('x-hisator-token', _kOpenWithToken);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'method': method, 'args': args}));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await utf8.decoder.bind(res).join();
    final m = jsonDecode(body);
    if (m is Map && m['token'] == _kOpenWithToken) return '${m['result'] ?? ''}';
  } catch (_) {
    // 本体が起動していない / 応答しない。
  } finally {
    try {
      client.close(force: true);
    } catch (_) {}
  }
  return '';
}

/// 外の窓 → 本体へ「この枠の位置で放したので、 ペインに入るなら入れて」 と頼む。
/// 埋め込まれたら true (= 呼び出した外の窓は自分を閉じる)。
Future<bool> requestEmbedIntoRunningInstance(String url, Rect frame) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(milliseconds: 600);
  try {
    final req = await client
        .post('127.0.0.1', _kOpenWithPort, '/embed')
        .timeout(const Duration(milliseconds: 900));
    req.headers.set('x-hisator-token', _kOpenWithToken);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'url': url,
      'x': frame.left,
      'y': frame.top,
      'w': frame.width,
      'h': frame.height,
    }));
    final res = await req.close().timeout(const Duration(seconds: 3));
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 1));
    return res.statusCode == 200 &&
        body.contains(_kOpenWithToken) &&
        body.contains('embedded');
  } catch (_) {
    return false;
  } finally {
    try {
      client.close(force: true);
    } catch (_) {}
  }
}

/// 別プロセスの窓から本体へ「AI アシスタントを開いて」 と頼む。
/// 本体アプリを起こして AI アシスタントを開く (= ユーザー報告: ショートカット
/// から開いた窓でアシスタントを押すと「本体のアプリが見つかりませんでした」)。
/// 起動済みなら転送、 居なければ本体を立ち上げてアシスタントを開かせる。
Future<bool> openAssistantAnyway(String text) async {
  if (await requestAssistantFromRunningInstance(text)) return true;
  try {
    await Process.start(
      Platform.resolvedExecutable,
      ['--command=aiAssistant', '--new-window'],
      mode: ProcessStartMode.detached,
    );
    return true;
  } catch (e) {
    debugPrint('本体アプリを起動できませんでした: $e');
    return false;
  }
}

Future<bool> requestAssistantFromRunningInstance(String text) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(milliseconds: 600);
  try {
    final req = await client
        .post('127.0.0.1', _kOpenWithPort, '/assistant')
        .timeout(const Duration(milliseconds: 900));
    req.headers.set('x-hisator-token', _kOpenWithToken);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'text': text}));
    final res = await req.close().timeout(const Duration(seconds: 2));
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 1));
    return res.statusCode == 200 && body.contains(_kOpenWithToken);
  } catch (_) {
    return false;
  } finally {
    try {
      client.close(force: true);
    } catch (_) {}
  }
}

/// 起動済みの本体へファイルを引き渡す。 成功したら true (呼び出し側は終了)。
Future<bool> _forwardOpenFilesToRunningInstance(List<String> paths) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(milliseconds: 600);
  try {
    final req = await client
        .post('127.0.0.1', _kOpenWithPort, '/open')
        .timeout(const Duration(milliseconds: 900));
    req.headers.set('x-hisator-token', _kOpenWithToken);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'paths': paths}));
    final res = await req.close().timeout(const Duration(seconds: 2));
    final body = await res
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 1));
    // トークンを確認して、 たまたま同じポートを使う別アプリへ渡して
    // しまっていないかを見分ける。
    return res.statusCode == 200 && body.contains(_kOpenWithToken);
  } catch (_) {
    return false;
  } finally {
    try {
      client.close(force: true);
    } catch (_) {}
  }
}

/// 本体側: ファイルの引き渡しを待ち受ける。 bind できなければ黙って諦める
/// (= ポートが他で使われていても本体の機能には影響しない)。
Future<void> _startOpenWithReceiver() async {
  try {
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, _kOpenWithPort);
    server.listen((req) async {
      try {
        if (req.method == 'POST' &&
            req.uri.path == '/open' &&
            req.headers.value('x-hisator-token') == _kOpenWithToken) {
          final body = await utf8.decoder.bind(req).join();
          final data = jsonDecode(body) as Map<String, dynamic>;
          final paths = (data['paths'] as List?)
                  ?.whereType<String>()
                  .where((p) {
                try {
                  return File(p).existsSync();
                } catch (_) {
                  return false;
                }
              }).toList() ??
              const <String>[];
          if (paths.isNotEmpty) {
            pendingOpenFilePaths.addAll(paths);
            openWithFilesTick.value++;
            // 最小化していても前面へ出す。
            try {
              await windowManager.restore();
            } catch (_) {}
            try {
              await windowManager.show();
              await windowManager.focus();
            } catch (_) {}
          }
          req.response.statusCode = 200;
          req.response.write(_kOpenWithToken);
        } else if (req.method == 'POST' &&
            req.uri.path == '/command' &&
            req.headers.value('x-hisator-token') == _kOpenWithToken) {
          // ── デスクトップのショートカットからの「このボタンを実行して」 ──
          //    (= ユーザー要望: ボタンを一発で呼び出すショートカット)
          try {
            final body = await utf8.decoder.bind(req).join();
            final data = jsonDecode(body);
            final id = (data is Map ? '${data['id'] ?? ''}' : '').trim();
            if (id.isNotEmpty) commandRequestFromShortcut.value = id;
          } catch (_) {}
          try {
            await windowManager.restore();
          } catch (_) {}
          try {
            await windowManager.show();
            await windowManager.focus();
          } catch (_) {}
          req.response.statusCode = 200;
          req.response.write(_kOpenWithToken);
        } else if (req.method == 'POST' &&
            req.uri.path == '/badge' &&
            req.headers.value('x-hisator-token') == _kOpenWithToken) {
          // ── 外部フローティング窓からの DM 未読数の知らせ ──
          //    (= ユーザー要望: DM 通知の表示)。 窓は前に出さない。
          try {
            final body = await utf8.decoder.bind(req).join();
            final data = jsonDecode(body);
            if (data is Map) {
              final host = '${data['host'] ?? ''}'.trim();
              final count = int.tryParse('${data['count'] ?? ''}') ?? 0;
              if (host.isNotEmpty) {
                serviceUnreadCounts[host] = count;
                serviceBadgeTick.value++;
              }
            }
          } catch (_) {}
          req.response.statusCode = 200;
          req.response.write(_kOpenWithToken);
        } else if (req.method == 'POST' &&
            req.uri.path == '/embed' &&
            req.headers.value('x-hisator-token') == _kOpenWithToken) {
          // ── 外の窓を分割ペインの上に置いて放した ──
          //    (= ユーザー要望: 外に出した YouTube を分割ペインの上に
          //     置いたら、 そのペインに埋め込まれるように)。
          //    判定は画面側 (分割セルの位置を知っている) に任せる。
          //    窓は前に出さない (= 埋め込みは本体の中で起きるだけ)。
          bool embedded = false;
          try {
            final body = await utf8.decoder.bind(req).join();
            final data = jsonDecode(body);
            final probe = floatingWindowDropProbe;
            if (data is Map && probe != null) {
              final url = '${data['url'] ?? ''}'.trim();
              final x = (data['x'] as num?)?.toDouble();
              final y = (data['y'] as num?)?.toDouble();
              final w = (data['w'] as num?)?.toDouble();
              final h = (data['h'] as num?)?.toDouble();
              if (url.isNotEmpty &&
                  x != null &&
                  y != null &&
                  w != null &&
                  h != null) {
                embedded = await probe(Rect.fromLTWH(x, y, w, h), url)
                    .timeout(const Duration(seconds: 2), onTimeout: () => false);
              }
            }
          } catch (_) {}
          req.response.statusCode = 200;
          req.response.write('$_kOpenWithToken${embedded ? ' embedded' : ''}');
        } else if (req.method == 'POST' &&
            req.uri.path == '/memo' &&
            req.headers.value('x-hisator-token') == _kOpenWithToken) {
          // ── 単体で開いたメモ窓からの頼みごと (ページ一覧 / マップに追加 /
          //    AI) ──  (= ユーザー報告: 追加できるページがありませんと出る)。
          //    窓は前に出さない (メモ窓で作業中なので邪魔しない)。
          var out = '';
          try {
            final body = await utf8.decoder.bind(req).join();
            final data = jsonDecode(body);
            final bridge = floatingMemoBridge;
            if (data is Map && bridge != null) {
              out = await bridge('${data['method'] ?? ''}', data['args'])
                  .timeout(const Duration(seconds: 18), onTimeout: () => '');
            }
          } catch (_) {}
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response
              .write(jsonEncode({'token': _kOpenWithToken, 'result': out}));
        } else if (req.method == 'POST' &&
            req.uri.path == '/assistant' &&
            req.headers.value('x-hisator-token') == _kOpenWithToken) {
          // ── フローティング AI 窓からの「AI アシスタントを開いて」 ──
          //    (= ユーザー要望: 別プロセスの窓からアシスタントを呼べるように)
          try {
            final body = await utf8.decoder.bind(req).join();
            final data = jsonDecode(body);
            final text = (data is Map ? '${data['text'] ?? ''}' : '').trim();
            assistantRequestFromFloating.value = text;
          } catch (_) {
            assistantRequestFromFloating.value = '';
          }
          try {
            await windowManager.restore();
          } catch (_) {}
          try {
            await windowManager.show();
            await windowManager.focus();
          } catch (_) {}
          req.response.statusCode = 200;
          req.response.write(_kOpenWithToken);
        } else {
          req.response.statusCode = 404;
        }
      } catch (_) {
        try {
          req.response.statusCode = 500;
        } catch (_) {}
      } finally {
        try {
          await req.response.close();
        } catch (_) {}
      }
    });
  } catch (_) {
    // 既に別の本体が待ち受けている / ポートが使えない → 何もしない。
  }
}

/// このアプリを「プログラムから開く」 の一覧に載せる (Windows / HKCU のみ)。
/// 管理者権限は不要で、 既定のアプリを勝手に奪うこともしない。
/// 一覧に出ることで、 ユーザーが .txt / .pdf をこのアプリで開けるようになる。
Future<void> _registerWindowsOpenWith() async {
  if (kIsWeb || !Platform.isWindows) return;
  try {
    final exe = Platform.resolvedExecutable;
    final appKey = r'Software\Classes\Applications\HisatorNotebook.exe';
    void setValue(String path, String name, String value) {
      final key = Registry.currentUser.createKey(path);
      key.createValue(RegistryValue.string(name, value));
      key.close();
    }

    setValue('$appKey\\shell\\open\\command', '', '"$exe" "%1"');
    setValue(appKey, 'FriendlyAppName', 'HisatorNotebook');

    // ── 「既定のアプリ」 に選べるようにする (= ユーザー要望: 動画ビューワー /
    //    エディター、 ペイントアプリとして既定のアプリに設定したい) ──
    // Windows は拡張子ごとの OpenWithProgids に載っている ProgID しか
    // 既定候補に出さないので、 専用の ProgID を作って各拡張子へ結び付ける。
    const progId = 'HisatorNotebook.File';
    setValue('Software\\Classes\\$progId', '', 'HisatorNotebook ファイル');
    setValue('Software\\Classes\\$progId\\DefaultIcon', '', '"$exe",0');
    setValue(
        'Software\\Classes\\$progId\\shell\\open\\command', '', '"$exe" "%1"');

    // 対応拡張子 (= この一覧に出したい種類)。
    const exts = <String>[
      // 文書・PDF
      '.pdf', '.txt', '.md', '.csv', '.docx', '.xlsx', '.pptx',
      '.json', '.html',
      // 動画 (ビューワー / エディターとして)
      '.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v',
      // 画像 (ペイント / 画像編集として)
      '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp',
    ];
    for (final ext in exts) {
      // 「プログラムから開く」 の一覧に出す。
      final st = Registry.currentUser.createKey('$appKey\\SupportedTypes');
      st.createValue(RegistryValue.string(ext, ''));
      st.close();
      // 既定のアプリ候補に出す。
      final ow = Registry.currentUser
          .createKey('Software\\Classes\\$ext\\OpenWithProgids');
      ow.createValue(RegistryValue.string(progId, ''));
      ow.close();
    }
  } catch (e) {
    debugPrint('「プログラムから開く」 の登録に失敗 (続行): $e');
  }
}

/// スタートメニューに残った「古い場所を指すショートカット」 を消す。
///
/// Windows はアプリの見た目 (スタート / タスクバー / 通知のアイコン) を
/// AppUserModelID の付いた .lnk 経由で解決する。 local_notifier が使う
/// WinToast は、 既存の .lnk を **AppUserModelID しか見ない** ので、
/// リンク先の exe が消えていても「そのままで良い」 と判断してしまう。
/// その結果、 アプリのフォルダーを消して別の場所へ入れ直すと、
/// リンクは壊れたまま残り、 アイコンが既定の白い物になる。
///
/// ここで消しておけば、 直後の `localNotifier.setup` が今の場所で作り直す。
///
/// リンク先の判定は .lnk の中身から今の exe のフォルダー名を探す方式。
/// 見つけられなかった時は「古い」 と見なして消すが、 消しても作り直されるので
/// 実害は無い (作り直しの方が確実に正しい)。
void _cleanStaleStartMenuShortcuts() {
  if (!Platform.isWindows) return;
  try {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return;
    final dir = Directory(
        '$appData\\Microsoft\\Windows\\Start Menu\\Programs');
    if (!dir.existsSync()) return;
    final exe = Platform.resolvedExecutable;
    final exeBytesAscii = exe.toLowerCase().codeUnits;
    // 昔の名前で作られた物も片付ける (改名の度に残っていた)。
    const names = <String>[
      'HisatorNotebook',
      'HistorNotebook',
      'HistorNote',
      'Kamispec',
      'Kamispe',
      'mindmap_app',
    ];
    for (final n in names) {
      final f = File('${dir.path}\\$n.lnk');
      if (!f.existsSync()) continue;
      var keep = false;
      try {
        final raw = f.readAsBytesSync();
        // .lnk は同じ文字列を ANSI と UTF-16LE の両方で持つことがあるので
        // 両方で探す。
        final ascii = String.fromCharCodes(raw).toLowerCase();
        if (ascii.contains(exe.toLowerCase())) keep = true;
        if (!keep) {
          final sb = StringBuffer();
          for (var i = 0; i + 1 < raw.length; i += 2) {
            sb.writeCharCode(raw[i] | (raw[i + 1] << 8));
          }
          if (sb.toString().toLowerCase().contains(exe.toLowerCase())) {
            keep = true;
          }
        }
      } catch (_) {}
      if (keep) continue;
      try {
        f.deleteSync();
        debugPrint('古いショートカットを片付けた: ${f.path}');
      } catch (_) {}
    }
    // ignore: unused_local_variable
    final _ = exeBytesAscii;
  } catch (e) {
    debugPrint('ショートカットの片付けに失敗 (起動は続行): $e');
  }
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // ── アプリの外に出す Web 窓として起動された場合 (= ユーザー要望:
  //    Google マップなどをフローティングメモのようにアプリの外へ出したい) ──
  //
  //    desktop_multi_window の「サブ窓」 ではなく、 わざわざ別プロセスとして
  //    起動する。 サブ窓は本体と同じプロセスなので、 そこで WebView を作ると
  //    窓を閉じた時にプロセス全体で WebView が作れなくなる不具合があった
  //    (b88 で修正済み)。 別プロセスなら WebView の後始末も独立するので、
  //    本体側に一切影響しない。
  if (!kIsWeb && args.isNotEmpty && args.first.startsWith('--floating-web=')) {
    final url = Uri.decodeComponent(
        args.first.substring('--floating-web='.length));
    // --floating-pin … 開いた瞬間から「常に手前」 (= ユーザー要望:
    //   ディアクティブでも前面に出るピン機能)。
    final pinned = args.contains('--floating-pin');
    // --floating-embed … 本体の分割ペインの上に置いて放したら、 そのペインへ
    //   埋め込んで自分は閉じる (= ユーザー要望: 要素から開いた YouTube は
    //   外の窓で立ち上がり、 分割ペインの上に置くと埋め込まれる)。
    //   要素から開いた窓だけに付ける (= ふつうのフローティング AI 等が
    //   本体の上を通っただけで吸い込まれないように)。
    final embeddable = args.contains('--floating-embed');
    // --floating-title=… … 窓のタイトル (URL の代わりに出す)。
    String? title;
    // --floating-x/y/w/h … 掴んで外へ出した時の位置と大きさ
    //   (= ユーザー要望: そのままの姿で外へ出したい)。
    double? fx, fy, fw, fh;
    for (final a in args) {
      if (a.startsWith('--floating-title=')) {
        title = Uri.decodeComponent(a.substring('--floating-title='.length));
      } else if (a.startsWith('--floating-x=')) {
        fx = double.tryParse(a.substring('--floating-x='.length));
      } else if (a.startsWith('--floating-y=')) {
        fy = double.tryParse(a.substring('--floating-y='.length));
      } else if (a.startsWith('--floating-w=')) {
        fw = double.tryParse(a.substring('--floating-w='.length));
      } else if (a.startsWith('--floating-h=')) {
        fh = double.tryParse(a.substring('--floating-h='.length));
      }
    }
    await FloatL10n.load();
    runApp(_FloatingWebWindowApp(
      url: url,
      startPinned: pinned,
      embeddable: embeddable,
      title: title,
      initialFrame: (fw != null && fh != null)
          ? Rect.fromLTWH(fx ?? 100, fy ?? 100, fw, fh)
          : null,
      initialPosition: (fw == null || fh == null) && fx != null && fy != null
          ? Offset(fx, fy)
          : null,
    ));
    return;
  }
  // ── 自動操作のフロー画面だけを出す「外の窓」 として起動された場合
  //    (= ユーザー要望: フローティングモードで自動操作のフローを外に
  //    出せるように) ──
  //    WebView を使うので multi_window のサブ窓ではなく別プロセスにする
  //    (--floating-web と同じ理由)。 フローは prefs 経由で本体と共有される。
  if (!kIsWeb && args.isNotEmpty && args.first == '--floating-auto') {
    final pinned = args.contains('--floating-pin');
    double? fx, fy, fw, fh;
    for (final a in args) {
      if (a.startsWith('--floating-x=')) {
        fx = double.tryParse(a.substring('--floating-x='.length));
      } else if (a.startsWith('--floating-y=')) {
        fy = double.tryParse(a.substring('--floating-y='.length));
      } else if (a.startsWith('--floating-w=')) {
        fw = double.tryParse(a.substring('--floating-w='.length));
      } else if (a.startsWith('--floating-h=')) {
        fh = double.tryParse(a.substring('--floating-h='.length));
      }
    }
    // 本体専用の常駐処理 (MCP の待ち受け再開など) はこの窓では立てない。
    MindMapProvider.externalToolWindow = true;
    final px = fx, py = fy;
    try {
      await windowManager.ensureInitialized();
      final opts = WindowOptions(
        size: Size(fw ?? 900, fh ?? 720),
        center: px == null || py == null,
        title: '自動操作',
      );
      unawaited(windowManager.waitUntilReadyToShow(opts, () async {
        if (px != null && py != null) {
          try {
            await windowManager.setPosition(Offset(px, py));
          } catch (_) {}
        }
        if (pinned) {
          try {
            await windowManager.setAlwaysOnTop(true);
          } catch (_) {}
        }
        await windowManager.show();
        await windowManager.focus();
      }));
    } catch (_) {}
    runApp(const _AutomationWindowApp());
    return;
  }
  // ── メモだけを単独で立ち上げる (= ユーザー要望: フローティングメモの
  //    ショートカットから、 裏で本体アプリまで開いてしまうのをやめる) ──
  //    本体とは別プロセスなので、 マップの画面は一切立ち上がらない。
  //    メモの中身は同じ保存先を読み書きするので、 本体で見ても同じもの。
  if (!kIsWeb && args.isNotEmpty && args.first == '--floating-memo') {
    await FloatL10n.load();
    runApp(const _MemoWindowApp(windowId: -1, args: {}));
    return;
  }
  // ── サブウィンドウ (発表者モードの「聴衆ウィンドウ」) として起動された場合 ──
  // desktop_multi_window はサブウィンドウを同じ実行ファイルで
  //   ['multi_window', '<windowId>', '<arguments>'] という引数で起動する。
  // その場合は通常のアプリ初期化をスキップし、 スライド画像だけを全画面表示
  //   する軽量アプリを起動する (= メモは出さない＝共有してよいクリーン画面)。
  if (!kIsWeb && args.isNotEmpty && args.first == 'multi_window') {
    final windowId = int.tryParse(args.length > 1 ? args[1] : '') ?? 0;
    Map<String, dynamic> argMap = const {};
    try {
      if (args.length > 2 && args[2].isNotEmpty) {
        argMap = jsonDecode(args[2]) as Map<String, dynamic>;
      }
    } catch (_) {/* 引数解析失敗時は空 */}
    // ── サブウィンドウの種類 (= ユーザー要望: メモ / AI をアプリの外に
    //    浮かせたい)。 'memo' / 'ai' が来たら専用の軽量アプリを起動する。 ──
    final kind = (argMap['kind'] as String?) ?? 'audience';
    // フローティング窓の表示言語を読む (= ユーザー要望: 多言語対応)。
    //   ここは runApp の前なので、 最初の描画から翻訳が効く。
    await FloatL10n.load();
    if (kind == 'memo') {
      runApp(_MemoWindowApp(windowId: windowId, args: argMap));
      return;
    }
    if (kind == 'ai') {
      runApp(_AiWindowApp(windowId: windowId, args: argMap));
      return;
    }
    if (kind == 'calc') {
      runApp(_CalcWindowApp(windowId: windowId));
      return;
    }
    // AI アシスタントの窓 (= ユーザー要望: アプリの外に出せるように)。
    //   考える所は本体に残し、 この窓は表示と入力だけを受け持つ。
    if (kind == 'assistant') {
      runApp(_AssistantWindowApp(
          windowId: windowId, pinned: argMap['pinned'] != false));
      return;
    }
    // 画面録画の操作窓 (= ユーザー要望: 録画ボタンをアプリの外へ / 録画に
    //   写り込まないように)。
    if (kind == 'screenrec') {
      // 撮り終えたプレビューをこの窓の中で再生するため、 この窓でも
      // fvp を video_player の実装として登録する (= ユーザー要望:
      // 範囲選びもプレビューも全部 1 つの窓の中で)。
      try {
        fvp.registerWith(options: {
          'platforms': ['windows', 'linux', 'macos'],
        });
      } catch (_) {}
      runApp(_ScreenRecWindowApp(windowId: windowId));
      return;
    }
    // ストップウォッチ / タイマーの外部窓 (= ユーザー要望: タイマーも外に)。
    if (kind == 'timer') {
      runApp(_TimerWindowApp(
          windowId: windowId,
          initialTab: (argMap['tab'] == 'pomodoro') ? 2 : 0));
      return;
    }
    runApp(_AudienceWindowApp(windowId: windowId, args: argMap));
    return;
  }
  // ── デスクトップの動画再生バックエンドを登録 (= ビデオエディターの
  //   プレビューが Windows/Linux で真っ黒になる問題の対策) ──
  // fvp(libmdk) を video_player の Platform 実装としてデスクトップに供給。
  // Android/iOS は公式バックエンド (ExoPlayer/AVPlayer) のままにしたいので
  // platforms を windows/linux/macos に限定する。
  try {
    fvp.registerWith(options: {
      'platforms': ['windows', 'linux', 'macos'],
    });
  } catch (_) {/* 登録失敗時は従来通り (モバイルは公式実装で動く) */}
  // ── Linux のみ: CEF WebView を初期化 ──
  // Windows は webview_windows、 モバイルは flutter_inappwebview のままなので
  //   ここは触らない。 Linux だけ flutter_linux_webview を初期化する。
  if (!kIsWeb && Platform.isLinux) {
    linux_wv.initLinuxWebView();
  }
  // ホーム画面/デスクトップのショートカット (--page=<id>) から起動された場合の
  //   ページ ID を記録 (Windows)。 Android は MethodChannel 経由で別途取得する。
  HomeShortcutService.windowsLaunchPageId =
      HomeShortcutService.pageIdFromArgs(args);
  // ボタンを一発で呼び出すショートカット (--command=<id>) から起動された場合。
  HomeShortcutService.windowsLaunchCommandId =
      HomeShortcutService.commandIdFromArgs(args);
  final shortcutCmd = HomeShortcutService.windowsLaunchCommandId ?? '';
  if (!kIsWeb && Platform.isWindows && shortcutCmd.isNotEmpty) {
    // ── 開き方が「フローティング」 のボタンは、 本体を立ち上げずに
    //    このプロセス自身が外部フローティング窓になる (= ユーザー要望:
    //    後ろの大元のアプリを起動させずにフローティングだけ表示)。 ──
    // ── フローティングメモのショートカット ──
    //    = ユーザー報告「立ち上げると裏で大元のアプリがページを開いた状態で
    //    立ち上がってしまう。 メモの機能だけが立ち上がってほしい」。
    //    本体を起動せず、 このプロセス自身がメモ窓になる。
    if (shortcutCmd == 'floatingMemo' ||
        shortcutCmd == 'popOutMemo' ||
        // 統合後の「メモ」 ボタン (= ユーザー要望)。
        shortcutCmd == 'mapMemo') {
      await FloatL10n.load();
      runApp(const _MemoWindowApp(windowId: -1, args: {}));
      return;
    }
    // ── ショートカットは「それ単体」 で開く (= ユーザー要望: 全ての
    //    ショートカットはフローティングモード単体で動作するように) ──
    //    本体アプリ (マップの画面) は立ち上げない。
    try {
      final prefs = await SharedPreferences.getInstance();
      // Web ページで完結するボタン (AI / Gmail / YouTube 等) は、
      //   このプロセス自身が浮かぶ Web 窓になる。
      final url = _shortcutFloatingUrl(prefs, shortcutCmd);
      if (url != null && url.isNotEmpty) {
        await FloatL10n.load();
        runApp(_FloatingWebWindowApp(url: url));
        return;
      }
      // 電卓 / タイマーも単体で開ける (窓 1 つで完結するため)。
      if (shortcutCmd == 'calculator' || shortcutCmd == 'stopwatch' ||
          shortcutCmd == 'pomodoro') {
        await FloatL10n.load();
        if (shortcutCmd == 'calculator') {
          runApp(const _CalcWindowApp(windowId: -1));
        } else {
          runApp(_TimerWindowApp(
              windowId: -1,
              initialTab: shortcutCmd == 'pomodoro' ? 2 : 0));
        }
        return;
      }
    } catch (_) {}
    // 既に本体が起動しているなら、 そちらに実行させて自分は終了する
    // (= 二重起動しない。 ファイルの引き渡しと同じ考え方)。
    if (!args.contains('--new-window') &&
        await _forwardCommandToRunningInstance(shortcutCmd)) {
      exit(0);
    }
  }
  // ── アラームに起こされた起動か (= ユーザー要望: アプリがオフの状態でも
  //    設定されていたら起動するように)。 Windows のタスク スケジューラが
  //    `--alarm=<id>` を付けてこのアプリを立ち上げる。 ──
  for (final a in args) {
    if (a.startsWith('--alarm=')) {
      pendingAlarmId = a.substring('--alarm='.length).trim();
      break;
    }
  }
  // ── 「プログラムから開く」 で渡されたファイル (= ユーザー要望) ──
  pendingOpenFilePaths.addAll(_openFilePathsFromArgs(args));
  // ── 既に本体が起動しているなら、 そちらへ渡して自分は終了する ──
  // (= ユーザー要望: 新規でアプリを立ち上げずにその上で表示)。
  // 動作設定「別ウィンドウで開く」 が ON なら従来どおり立ち上げる。
  // --new-window 付き (= 本体の「新しいウィンドウで開く」 の選択から
  // 起動された) 時も引き渡さず、 このプロセスがそのまま窓になる。
  if (!kIsWeb &&
      Platform.isWindows &&
      pendingOpenFilePaths.isNotEmpty &&
      !args.contains('--new-window')) {
    bool newInstance = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      newInstance = prefs.getBool('openWithNewInstance') ?? false;
    } catch (_) {}
    if (!newInstance &&
        await _forwardOpenFilesToRunningInstance(
            List<String>.from(pendingOpenFilePaths))) {
      exit(0);
    }
  }
  // 本体としてファイルの引き渡しを待ち受ける (Windows のみ)。
  if (!kIsWeb && Platform.isWindows) {
    // ignore: discarded_futures
    _startOpenWithReceiver();
  }
  // ignore: discarded_futures
  _registerWindowsOpenWith();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // ── ローカル通知プラグインの初期化 ──
  // タイムゾーン DB を読み込んで、 端末のローカル TZ を設定。
  // zonedSchedule は TZDateTime で時刻を指定するので必須。
  tz_data.initializeTimeZones();
  try {
    tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));
  } catch (_) {/* TZ 取得失敗時は UTC のままで問題なし */}

  // ── 通知の初期化 + Android 権限リクエストはバックグラウンドで ──
  // ★ 起動ハング対策: これらを runApp の前で await すると、 特に Android で
  //   起動画面が「読み込み中」 のまま固まることがある。 権限ダイアログは
  //   Activity が用意できてからでないと表示できず、 runApp 前に
  //   requestNotificationsPermission() 等を await すると、 ダイアログが出せず
  //   await が返らないまま runApp に到達できない (= 画面が出ない) ため。
  //   そこで await せず fire-and-forget で実行し、 runApp を即座に呼ぶ。
  // ignore: discarded_futures
  _initNotificationsAndPermissions();

  // デスクトップ版のみ window_manager を初期化
  if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'HisatorNotebook',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );

    // ── 本体を閉じる時は、 先に浮遊窓 (メモ / AI) を閉じてから終わる ──
    //   浮遊窓は本体と同じプロセスの別ウィンドウ。 本体だけ閉じると、
    //   窓は残っているのにプロセスが終了しかけた中途半端な状態になり、
    //   以後フローティングを開けなくなる (= ユーザー報告)。
    //   閉じる操作を横取りして、 順番に片付けてから終了する。
    try {
      await windowManager.setPreventClose(true);
      windowManager.addListener(_MainWindowCloser());
    } catch (e) {
      debugPrint('main window close handler の設定に失敗: $e');
    }

    // ── デスクトップの OS 通知 (local_notifier) を初期化 ──
    // ユーザー要望「windows 版の通知方法をアプリ内通知ではなく OS 通知に」
    //   への対応。 Windows では shortcutPolicy.requireCreate でスタートメニュー
    //   ショートカット (AUMID 紐付け) を作成し、 MSIX 化していなくても
    //   トーストが表示できるようにする。 macOS / Linux では shortcutPolicy は
    //   無視される。
    // ★ 起動高速化: ショートカット作成はディスク I/O を伴い遅いことがある
    //   ので await せず裏で走らせる (= ユーザー要望: 立ち上がりを軽く)。
    //   通知は起動直後に出ることはまず無いので、 準備が数百 ms 遅れても
    //   実害はない。
    unawaited(() async {
      try {
        // ★ 先に、 古い場所を指したままのショートカットを片付ける
        //   (= ユーザー報告: フォルダーを消して入れ直すとアイコンが壊れる)。
        _cleanStaleStartMenuShortcuts();
        await localNotifier.setup(
          appName: 'HisatorNotebook',
          shortcutPolicy: ShortcutPolicy.requireCreate,
        );
      } catch (e) {
        debugPrint('local_notifier 初期化失敗: $e');
      }
    }());
  }

  // ── 高リフレッシュレート (120Hz / 144Hz) を適用 (= ユーザー要望) ──
  // 保存された設定を読んで反映する。 プロバイダの初期化を待たずに済むよう
  // ここでは prefs を直接読む (既定は ON)。 Android 以外では何もしない。
  // ★ 起動高速化: 効果があるのは Android だけなので、 それ以外の OS では
  //   prefs 読み込みごと省く。 Android でも runApp を待たせず裏で適用する。
  if (!kIsWeb && Platform.isAndroid) {
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await applyPreferredDisplayMode(
            high: prefs.getBool('highRefreshRate') ?? true);
      } catch (e) {
        debugPrint('DisplayMode: 初期適用に失敗 (無視): $e');
      }
    }());
  }

  runApp(const MyApp());
}

/// 通知プラグインの初期化と Android 権限リクエストをバックグラウンドで実行する。
/// (= 起動時に「読み込み中」 画面で固まる不具合の対策。 runApp をブロックしない)
/// 失敗しても通知が出ないだけでアプリ本体は動くので、 すべて try/catch で握る。
Future<void> _initNotificationsAndPermissions() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  try {
    await flutterLocalNotificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse resp) {
        debugPrint('通知タップ: ${resp.payload}');
      },
    );
  } catch (e) {
    debugPrint('flutter_local_notifications 初期化失敗: $e');
  }

  // Android 13+ の通知 permission をリクエスト (起動時に 1 回だけ)。
  if (!kIsWeb && Platform.isAndroid) {
    try {
      final androidImpl =
          flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestNotificationsPermission();
      await androidImpl?.requestExactAlarmsPermission();
    } catch (e) {
      debugPrint('Android 通知 permission リクエスト失敗: $e');
    }
  }
}

/// 明るいテーマでも、 時刻の選択 (時計ダイヤル) をアプリの暗いダイアログに
/// 揃えるための配色。 暗いテーマ側は元から暗いので触らない。
TimePickerThemeData _darkTimePickerTheme(Color accent) {
  const surface = Color(0xFF1E1E32);
  const field = Color(0xFF2A2A45);
  return TimePickerThemeData(
    backgroundColor: surface,
    dialBackgroundColor: field,
    dialHandColor: accent,
    dialTextColor: WidgetStateColor.resolveWith((s) =>
        s.contains(WidgetState.selected) ? Colors.white : Colors.white70),
    hourMinuteColor: WidgetStateColor.resolveWith((s) =>
        s.contains(WidgetState.selected) ? accent.withValues(alpha: 0.35) : field),
    hourMinuteTextColor: Colors.white,
    dayPeriodColor: WidgetStateColor.resolveWith((s) =>
        s.contains(WidgetState.selected) ? accent.withValues(alpha: 0.35) : field),
    dayPeriodTextColor: Colors.white,
    dayPeriodBorderSide: const BorderSide(color: Colors.white24),
    entryModeIconColor: Colors.white70,
    helpTextStyle: const TextStyle(color: Colors.white70),
    hourMinuteTextStyle: const TextStyle(fontSize: 44, color: Colors.white),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: field,
      hintStyle: TextStyle(color: Colors.white38),
    ),
  );
}

/// 同じく日付の選択 (カレンダー表) 用。
DatePickerThemeData _darkDatePickerTheme(Color accent) {
  const surface = Color(0xFF1E1E32);
  return DatePickerThemeData(
    backgroundColor: surface,
    surfaceTintColor: Colors.transparent,
    headerBackgroundColor: accent,
    headerForegroundColor: Colors.white,
    weekdayStyle: const TextStyle(color: Colors.white60),
    dividerColor: Colors.white24,
    yearForegroundColor: WidgetStateColor.resolveWith((s) =>
        s.contains(WidgetState.selected) ? Colors.white : Colors.white70),
    yearBackgroundColor: WidgetStateColor.resolveWith((s) =>
        s.contains(WidgetState.selected) ? accent : Colors.transparent),
    dayForegroundColor: WidgetStateColor.resolveWith((s) {
      if (s.contains(WidgetState.disabled)) return Colors.white24;
      return Colors.white;
    }),
    dayBackgroundColor: WidgetStateColor.resolveWith((s) =>
        s.contains(WidgetState.selected) ? accent : Colors.transparent),
    todayForegroundColor: const WidgetStatePropertyAll(Colors.white),
    todayBorder: BorderSide(color: accent),
    cancelButtonStyle: TextButton.styleFrom(foregroundColor: Colors.white70),
    confirmButtonStyle: TextButton.styleFrom(foregroundColor: Colors.white),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => MindMapProvider(),
      child: Consumer<MindMapProvider>(
        builder: (context, provider, _) {
          if (!kIsWeb &&
              (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
            windowManager.setTitle(provider.t('app.title'));
          }
          final baseColor = provider.headerColor;
          // flutter_quill と Flutter 標準UIのロケールもアプリ内言語へ追従させる。
          // Quill側で確実に提供される主要9言語以外は英語へフォールバックし、
          // OS言語や日本語が意図せず混ざらないようにする。
          const localizedFrameworkLanguages = {
            'en',
            'ja',
            'zh',
            'ko',
            'es',
            'fr',
            'de',
            'pt',
            'ru',
          };
          final frameworkLanguage =
              localizedFrameworkLanguages.contains(provider.appLanguage)
                  ? provider.appLanguage
                  : 'en';
          return MaterialApp(
            title: provider.t('app.title'),
            debugShowCheckedModeBanner: false,
            // flutter_quill (リッチテキスト) のUIローカライズ + Material/Cupertino の
            //   各言語化に必要な delegate。 これが無いと QuillEditor/QuillSimpleToolbar
            //   が実行時に例外を出す。
            localizationsDelegates: const [
              FlutterQuillLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            locale: Locale(frameworkLanguage),
            supportedLocales: const [
              Locale('en'),
              Locale('ja'),
              Locale('zh'),
              Locale('ko'),
              Locale('es'),
              Locale('fr'),
              Locale('de'),
              Locale('pt'),
              Locale('ru'),
            ],
            themeMode: provider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: baseColor,
                brightness: Brightness.light,
              ),
              appBarTheme: AppBarTheme(
                backgroundColor: baseColor,
                foregroundColor: Colors.white,
              ),
              scaffoldBackgroundColor: const Color(0xFFD8D8D4),
              useMaterial3: true,
              fontFamily: 'sans-serif',
              snackBarTheme: const SnackBarThemeData(
                backgroundColor: Color(0xFF2A2A3E),
                contentTextStyle: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
                actionTextColor: Color(0xFFFFD54F),
                disabledActionTextColor: Colors.white38,
              ),
              // ── スクロールバー (スライドバー) を常時表示 + 白系で見やすく ──
              // ダイアログ / シートは暗色背景なので、 白系のサムにすると
              // 「スライドバーが見えない」 問題が解消する。 ユーザー要望対応。
              scrollbarTheme: ScrollbarThemeData(
                thumbVisibility: const WidgetStatePropertyAll(true),
                thickness: const WidgetStatePropertyAll(6),
                radius: const Radius.circular(8),
                thumbColor:
                    WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.7)),
              ),
              // ── 時刻 / 日付の選択画面も暗色に揃える ──
              // アプリのダイアログ・引き出しは明るいテーマでも暗色で作って
              // あるため、 標準の時計ダイヤルと日付表だけが真っ白に浮いて
              // いた (アラーム追加などで実際に見えた)。
              // 目印の色はヘッダー色ではなく決め打ちにする。 ヘッダーを黒に
              //   近い色にしている人だと、 選択中の数字が黒地に黒で読めなく
              //   なるため。
              timePickerTheme: _darkTimePickerTheme(const Color(0xFF6C63FF)),
              datePickerTheme: _darkDatePickerTheme(const Color(0xFF6C63FF)),
            ),
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: baseColor,
                brightness: Brightness.dark,
              ),
              appBarTheme: AppBarTheme(
                backgroundColor: baseColor,
                foregroundColor: Colors.white,
              ),
              useMaterial3: true,
              fontFamily: 'sans-serif',
              snackBarTheme: const SnackBarThemeData(
                backgroundColor: Color(0xFF2A2A3E),
                contentTextStyle: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
                actionTextColor: Color(0xFFFFD54F),
                disabledActionTextColor: Colors.white38,
              ),
              // ── スクロールバー (スライドバー) を常時表示 + 白系で見やすく ──
              scrollbarTheme: ScrollbarThemeData(
                thumbVisibility: const WidgetStatePropertyAll(true),
                thickness: const WidgetStatePropertyAll(6),
                radius: const Radius.circular(8),
                thumbColor:
                    WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.7)),
              ),
            ),
            home: const MindMapScreen(),
          );
        },
      ),
    );
  }
}

/// 発表者モードの「聴衆ウィンドウ」 (= 別ウィンドウ) のアプリ。
///
/// メインウィンドウ (発表者ビュー) が現在のスライドを PNG にレンダリングして
/// 渡してくるので、 それを黒背景に全画面で表示するだけの軽量アプリ。 メモや
/// 次スライドは含まれないため、 この窓を Meet 等で共有すればメモは相手に
/// 見えない。 更新は `DesktopMultiWindow.invokeMethod(id, 'update', {imagePath})`
/// で受け取る。
/// アプリの外に出すフローティングメモ (= ユーザー要望: PC でもアプリの外に
/// 表示したい)。 本体と同じ SharedPreferences を読み書きするので、 どちらで
/// 編集しても内容は共有される。 常に手前に出したいので枠なしの小窓にする。
/// ブラウザ版 AI に毎回添える「前提条件」 の保存先 (窓をまたいで共通)。
const String kBrowserAiPrefixKey = 'browser_ai_prefix';

Future<String> loadBrowserAiPrefix() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(kBrowserAiPrefixKey) ?? '';
  } catch (_) {
    return '';
  }
}

/// 「前提条件」 を書き換えるダイアログ (= ユーザー要望: ブラウザ版 AI に
/// 切り替える時もモデルの選択や前提条件の設定ができるように)。
/// 保存したら新しい文、 取り消しなら null を返す。
Future<String?> editBrowserAiPrefix(BuildContext ctx) async {
  final ctrl = TextEditingController(text: await loadBrowserAiPrefix());
  if (!ctx.mounted) {
    ctrl.dispose();
    return null;
  }
  final saved = await showDialog<String>(
    context: ctx,
    builder: (dctx) => AlertDialog(
      backgroundColor: const Color(0xFF1E1E32),
      title: Text(FloatL10n.t('memo.aiPrefixTitle'),
          style: const TextStyle(color: Colors.white, fontSize: 15)),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(FloatL10n.t('memo.aiPrefixDesc'),
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: ctrl,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: FloatL10n.t('memo.aiPrefixHint'),
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.06),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dctx, '__cancel__'),
          child: Text(FloatL10n.t('btn.cancel'),
              style: const TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dctx, ''),
          child: Text(FloatL10n.t('btn.clear'),
              style: const TextStyle(color: Color(0xFFFF8A80))),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFBA68C8),
              foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(dctx, ctrl.text.trim()),
          child: Text(FloatL10n.t('btn.save')),
        ),
      ],
    ),
  );
  ctrl.dispose();
  if (saved == null || saved == '__cancel__') return null;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kBrowserAiPrefixKey, saved);
  } catch (_) {}
  return saved;
}

/// 他の浮遊窓の中に「フローティングメモと同じ画面」 を出すための入口
/// (= ユーザー要望: AI エージェントからメモを開いた時に、 簡易メモではなく
/// いつものメモが出るように)。 保存先も同じなので、 どこで書いても同じ
/// メモ帳に積まれる。
class FloatingMemoView extends StatelessWidget {
  const FloatingMemoView({super.key});
  @override
  Widget build(BuildContext context) =>
      const _MemoWindowApp(windowId: -1, args: {}, embedded: true);
}

class _MemoWindowApp extends StatefulWidget {
  /// desktop_multi_window のサブ窓 id。
  /// **-1 = 単独プロセスとして開いている** (= ユーザー要望: フローティング
  /// メモのショートカットから、 本体アプリを立ち上げずにメモだけ出す)。
  final int windowId;
  final Map<String, dynamic> args;

  /// 他の窓の中に**そのまま埋め込んで**使うか (= ユーザー要望: フローティング
  /// AI からメモを開いた時、 フローティングメモと同じ画面が出るように)。
  /// true の時は窓の大きさ・常に手前・閉じるといった「窓の操作」 をしない。
  final bool embedded;
  const _MemoWindowApp(
      {required this.windowId, required this.args, this.embedded = false});

  /// 本体アプリの中のサブ窓ではなく、 自分だけで動いているか。
  /// 埋め込みの時は窓を持たないので false 扱い (窓の操作をしない)。
  bool get standalone => windowId < 0 && !embedded;

  @override
  State<_MemoWindowApp> createState() => _MemoWindowAppState();
}

class _MemoWindowAppState extends State<_MemoWindowApp> with WindowListener {
  /// ダイアログ / SnackBar 用の context。
  ///
  /// ★ この State の `context` は自分が組み立てる MaterialApp より **上** に
  ///   いるので、 Navigator も ScaffoldMessenger も見つからない。 そのまま
  ///   showDialog すると例外で何も出ない (= 新しいメモの名前入力が出なかった
  ///   不具合)。 MaterialApp に鍵を付けて、 その中の context を使う。
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  BuildContext? get _dlgCtx => _navKey.currentContext;

  final _WinDragger _dragger = _WinDragger();
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _listCtrl = ScrollController();
  Timer? _topTimer;
  bool _pinned = true;

  /// メモ帳の一覧 (= ユーザー要望: フローティングメモを複数保存できるように)。
  /// 冊子ごとに箇条書きの項目・フリーメモ・表示モードを持つ。
  List<FloatMemoBook> _books = [FloatMemoBook.create('メモ 1')];
  int _bookIndex = 0;

  FloatMemoBook get _book =>
      _books[_bookIndex.clamp(0, _books.length - 1).toInt()];

  /// 開いているメモの項目。 Enter を押すたびに 1 項目ずつ増える
  /// (= ユーザー要望: 別々に項目分けされるように)。 JSON でファイルに保存する。
  List<FloatMemoItem> get _items => _book.items;

  /// 'list' = 箇条書き / 'free' = 1 つの欄に自由に書くモード
  /// (= ユーザー要望: 2 つのモードが欲しい)。 冊子ごとに覚える。
  String get _memoMode => _book.mode;
  final TextEditingController _free = TextEditingController();
  Timer? _freeSaveTimer;
  int _lastInputLines = 1;

  /// 飾り (上のアイコン・題・ボタン類 + 下の 3 つのボタン) を隠すか
  /// (= ユーザー要望: 使わないので消したい)。 目のボタンだけは残るので
  /// いつでも戻せる。 次に開いた時もこの状態で開く。
  bool _chromeHidden = false;

  /// メモの所を AI の画面に切り替えているか (= ユーザー要望: 新しい窓を
  /// 出さずにこの窓の中で AI を使いたい)。
  ///
  /// ★ このメモ窓は本体とは別のエンジンなので WebView2 を持てない。
  ///   そこで、 質問文を本体へ渡して本体の AI (代行サーバー) に投げ、
  ///   返ってきた文だけをここに表示する形にしている。
  bool _aiMode = false;
  final TextEditingController _aiInput = TextEditingController();
  String _aiAnswer = '';
  String _aiError = '';
  bool _aiBusy = false;

  // ── メモ窓自体を AI / Google 検索の画面に切り替える (= ユーザー要望:
  //    ボタンを押したらフローティングメモがそのままポップアップに変わる) ──
  bool _webMode = false;
  bool _webReady = false;
  String _webTitle = '';
  wv_win.WebviewController? _webCtrl;

  @override
  void initState() {
    super.initState();
    _load();
    // ── 単独プロセスで開いた時の窓の大きさ (= ユーザー要望: ショートカット
    //    から開くと横長になる。 アプリの中で開くのと同じ縦長にして、
    //    最後に閉じた大きさを覚えておいてほしい) ──
    //    サブ窓の時は親が大きさを決めるので触らない。
    if (widget.standalone) {
      windowManager.addListener(this);
      // ignore: discarded_futures
      _restoreStandaloneSize();
    }
    // ── Enter で確定 / Shift+Enter で改行 (= ユーザー要望) ──
    // IME 変換中の Enter (変換確定) は奪わない。
    _inputFocus.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter;
      if (!isEnter) return KeyEventResult.ignored;
      if (HardwareKeyboard.instance.isShiftPressed) {
        return KeyEventResult.ignored; // 改行は TextField に任せる
      }
      if (_input.value.composing.isValid) {
        return KeyEventResult.ignored; // IME 確定
      }
      _commitInput();
      return KeyEventResult.handled;
    };
    // Shift+Enter で入力欄が伸びたら窓の高さも追従させる。
    _input.addListener(() {
      final lines = _inputLineCount();
      if (lines != _lastInputLines) {
        _lastInputLines = lines;
        // ignore: discarded_futures
        _fitWindowToContent();
      }
    });
    _free.addListener(() {
      _freeSaveTimer?.cancel();
      _freeSaveTimer = Timer(const Duration(milliseconds: 500), () {
        // ignore: discarded_futures
        _persist();
      });
    });
    // ── 他のアプリ (Chrome / Edge 等) の上に出し続ける ──
    //    埋め込みの時は入れ物の窓に任せる (= 自分では触らない)。
    if (!widget.embedded) _applyAlwaysOnTop(true);
    // 間隔を広げる (4 秒 → 10 秒)。 実際に外れた時だけ張り直すので、
    //   入力の邪魔になりにくい (= ユーザー報告: 入力状態が安定しない)。
    _topTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      // 破棄後に走らせない (= 閉じた窓へ操作を投げるとプロセスが落ちる)。
      if (!mounted) {
        _topTimer?.cancel();
        _topTimer = null;
        return;
      }
      // ignore: discarded_futures
      if (_pinned) _applyAlwaysOnTop(true);
    });
  }

  /// 単独プロセスで開いた時の窓の大きさの記憶先。
  static const String _kMemoWinSizeKey = 'floatingMemoWindowSize';

  /// 既定の大きさ。 アプリの中で開くメモと同じく縦長にする。
  static const Size _kMemoWinDefault = Size(460, 560);

  Timer? _sizeSaveTimer;

  /// 前回閉じた大きさで開く (無ければ縦長の既定値)。
  Future<void> _restoreStandaloneSize() async {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setTitle(FloatL10n.t('memo.title'));
      var size = _kMemoWinDefault;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kMemoWinSizeKey) ?? '';
      final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(raw);
      if (m != null) {
        size = Size(
          double.parse(m.group(1)!).clamp(320.0, 3000.0),
          double.parse(m.group(2)!).clamp(240.0, 3000.0),
        );
      }
      await windowManager.setSize(size);
      await windowManager.center();
    } catch (_) {}
  }

  /// 今の大きさを控える (続けて動く間は最後の 1 回だけ書く)。
  void _scheduleSaveWinSize() {
    if (!widget.standalone) return;
    _sizeSaveTimer?.cancel();
    _sizeSaveTimer = Timer(const Duration(milliseconds: 500), () {
      // ignore: discarded_futures
      _saveWinSize();
    });
  }

  Future<void> _saveWinSize() async {
    if (!widget.standalone) return;
    try {
      final s = await windowManager.getSize();
      if (s.width < 100 || s.height < 100) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kMemoWinSizeKey, '${s.width.round()}x${s.height.round()}');
    } catch (_) {}
  }

  @override
  void onWindowResize() => _scheduleSaveWinSize();

  @override
  void onWindowResized() => _scheduleSaveWinSize();

  int _inputLineCount() {
    final t = _input.text;
    if (t.isEmpty) return 1;
    return ('\n'.allMatches(t).length + 1).clamp(1, 4);
  }

  Future<void> _applyAlwaysOnTop(bool on) async {
    if (widget.embedded) return;
    try {
      await windowManager.ensureInitialized();
      // 既にその状態なら呼ばない (= ユーザー報告: 入力状態が安定しない)。
      //   setAlwaysOnTop は内部で SetWindowPos(HWND_TOPMOST) を呼ぶため、
      //   入力中に定期実行すると日本語入力の変換が中断される。
      try {
        if (await windowManager.isAlwaysOnTop() == on) return;
      } catch (_) {}
      await windowManager.setAlwaysOnTop(on);
    } catch (_) {}
  }

  Future<void> _load() async {
    final raw = await loadFloatingMemoText();
    if (!mounted) return;
    final parsed = parseFloatingMemoBooks(raw);
    // 下のボタンを隠していたかを取り出す。
    final footerHidden = await loadFloatingMemoFooterHidden();
    if (!mounted) return;
    setState(() {
      _books = parsed.books;
      _bookIndex = parsed.active;
      _free.text = _book.free;
      _chromeHidden = footerHidden;
      _loaded = true;
    });
    _fitWindowToContent();
  }

  /// 別のメモ帳へ切り替える。 書きかけのフリーメモは先に今の冊子へ移す。
  void _switchBook(int i) {
    if (i < 0 || i >= _books.length || i == _bookIndex) return;
    _book.free = _free.text;
    setState(() {
      _bookIndex = i;
      _free.text = _books[i].free;
      _input.clear();
    });
    // ignore: discarded_futures
    _persist();
    // ignore: discarded_futures
    _fitWindowToContent();
  }

  /// メモ帳を新規作成 / 名前変更 / 削除するメニュー (= ユーザー要望: 複数保存)。
  Future<void> _showBookMenu(BuildContext btnCtx) async {
    final box = btnCtx.findRenderObject() as RenderBox?;
    final pos =
        box == null ? const Offset(40, 40) : box.localToGlobal(Offset.zero);
    final chosen = await showMenu<String>(
      context: btnCtx,
      color: const Color(0xFF23233A),
      position:
          RelativeRect.fromLTRB(pos.dx, pos.dy + 26, pos.dx + 1, pos.dy + 27),
      items: [
        for (var i = 0; i < _books.length; i++)
          PopupMenuItem<String>(
            value: 'open:$i',
            height: 34,
            child: Row(children: [
              Icon(
                  i == _bookIndex
                      ? Icons.radio_button_checked_rounded
                      : Icons.sticky_note_2_outlined,
                  size: 14,
                  color: i == _bookIndex
                      ? const Color(0xFF43B97F)
                      : Colors.white38),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                    // 件数の (0) は箇条書きの数で、 自由記入では増えないため
                    //   意味が伝わらない (= ユーザー要望で削除)。
                    _books[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ]),
          ),
        const PopupMenuDivider(height: 6),
        PopupMenuItem<String>(
          value: 'new',
          height: 34,
          child: Row(children: [
            const Icon(Icons.note_add_rounded,
                size: 14, color: Color(0xFF43B97F)),
            const SizedBox(width: 8),
            Text(FloatL10n.t('memo.newBook'),
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ]),
        ),
        PopupMenuItem<String>(
          value: 'rename',
          height: 34,
          child: Row(children: [
            const Icon(Icons.drive_file_rename_outline_rounded,
                size: 14, color: Color(0xFF4FC3F7)),
            const SizedBox(width: 8),
            Text(FloatL10n.t('memo.renameBook'),
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ]),
        ),
        if (_books.length > 1)
          PopupMenuItem<String>(
            value: 'delete',
            height: 34,
            child: Row(children: [
              const Icon(Icons.delete_outline_rounded,
                  size: 14, color: Color(0xFFE57373)),
              const SizedBox(width: 8),
              Text(FloatL10n.t('memo.deleteBook'),
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ]),
          ),
      ],
    );
    if (chosen == null || !mounted) return;
    if (chosen.startsWith('open:')) {
      _switchBook(int.tryParse(chosen.substring(5)) ?? 0);
      return;
    }
    if (chosen == 'new') {
      // ── 名前は聞かない (= ユーザー要望: 追加のたびに入力を求めない) ──
      //    「メモ 4」 のように順に付け、 変えたい人は後から
      //    「名前の変更」 で直す。 既にある番号は飛ばす。
      var n = _books.length + 1;
      final used = _books.map((b) => b.name).toSet();
      var auto = '${FloatL10n.t('memo.bookPrefix')} $n';
      while (used.contains(auto)) {
        n++;
        auto = '${FloatL10n.t('memo.bookPrefix')} $n';
      }
      _book.free = _free.text;
      setState(() {
        _books.add(FloatMemoBook.create(
            auto,
            // 今開いているメモと同じモードで始める (= ユーザー要望)。
            mode: _book.mode));
        _bookIndex = _books.length - 1;
        _free.text = '';
        _input.clear();
      });
      // ignore: discarded_futures
      _persist();
      // ignore: discarded_futures
      _fitWindowToContent();
      return;
    }
    if (chosen == 'rename') {
      final name = await _askText(FloatL10n.t('memo.renameBook'),
          initial: _book.name);
      if (name == null || name.trim().isEmpty || !mounted) return;
      setState(() => _book.name = name.trim());
      // ignore: discarded_futures
      _persist();
      return;
    }
    if (chosen == 'delete' && _books.length > 1) {
      setState(() {
        _books.removeAt(_bookIndex);
        if (_bookIndex >= _books.length) _bookIndex = _books.length - 1;
        _free.text = _book.free;
      });
      // ignore: discarded_futures
      _persist();
      // ignore: discarded_futures
      _fitWindowToContent();
    }
  }

  /// 1 行入力のダイアログ (メモ帳の名前・項目の編集で使う)。
  Future<String?> _askText(String title,
      {String initial = '', bool multiline = false}) async {
    final ctx = _dlgCtx;
    if (ctx == null) return null;
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E32),
        title: Text(title,
            style: const TextStyle(color: Colors.white, fontSize: 14)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: multiline ? 3 : 1,
          maxLines: multiline ? 8 : 1,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: const InputDecoration(
            enabledBorder:
                UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
          ),
          onSubmitted:
              multiline ? null : (v) => Navigator.pop(dctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(FloatL10n.t('memo.cancel'),
                style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(dctx, ctrl.text),
            child: Text(FloatL10n.t('memo.ok')),
          ),
        ],
      ),
    );
  }

  /// 履歴が無いなら余計なスペースを確保しない (= ユーザー要望)。
  /// 項目数に合わせて窓の高さを合わせる (上限あり、 Web モード中は触らない)。
  Future<void> _fitWindowToContent() async {
    if (widget.embedded) return;
    // 単独プロセスの時は利用者が決めた大きさを尊重する
    //   (= ユーザー要望: 最後に閉じた縦横で開いてほしい)。
    if (_webMode || widget.standalone) return;
    const header = 34.0;
    // setSize は OS のタイトルバーと枠を含む外寸なので、 その分を足す。
    const chrome = 44.0;
    double contentH;
    if (_memoMode == 'free') {
      // フリーメモは書くスペースをまとまって確保する。
      contentH = 360.0;
    } else {
      final inputRow = 46.0 + (_inputLineCount() - 1) * 19.0;
      // 一括操作の帯 (項目があるときだけ出る) ぶんも見込む。
      final itemsH = _items.isEmpty
          ? 0.0
          : math.min(_items.length * 46.0 + 42.0, 430.0);
      // 下限を設けて、 空でも細長い帯にならないようにする (= ユーザー要望:
      // もう少し縦幅を付けて欲しい)。
      contentH = math.max(inputRow + itemsH + 8, 210.0);
    }
    try {
      final cur = await windowManager.getSize();
      await windowManager.setSize(Size(cur.width, header + contentH + chrome));
    } catch (_) {}
  }

  /// 読み込みが終わるまでは保存しない。 起動直後の既定値 ('list') で
  /// 保存済みのモードを潰さないため (= ユーザー要望: 最後に閉じた方の
  /// モードで次回立ち上がるように)。
  bool _loaded = false;

  /// 保存形式は v3 (= 複数メモ)。 読み込みは v2 / プレーンテキストにも対応
  /// する ([parseFloatingMemoBooks])。
  Future<void> _persist() async {
    if (!_loaded) return;
    _book.free = _free.text;
    await saveFloatingMemoText(encodeFloatingMemoBooks(_books, _bookIndex));
  }

  /// 飾りを隠す / 出す (= ユーザー要望)。
  Future<void> _toggleChrome() async {
    setState(() => _chromeHidden = !_chromeHidden);
    await saveFloatingMemoFooterHidden(_chromeHidden);
  }

  /// ブラウザ版 AI (ChatGPT 等) を **この窓の中で** 開く。
  ///
  /// = ユーザー要望「フローティングメモからフローティング AI を開く時は
  ///   既定でブラウザ版にして、 新しいウィンドウではなくメモの画面自体が
  ///   AI に変わるように」。 本体と同じ prefs (`browser_ai_target`) を読み、
  ///   選んでいる AI のページを _openWeb でこの窓に表示する。
  /// [id] を渡すとその AI を開き、 次回の既定にもする。
  /// 今のメモを AI に渡す (= ユーザー要望: 下の「AIに渡す」 と
  /// ヘッダーの AI を統合。 既定はブラウザ版 AI)。
  Future<void> _sendToAi(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _openBrowserAi(query: t);
  }

  /// 今 AI に渡したい文。 自由記入なら選んだ所 (無ければ全文)、
  /// 箇条書きなら全項目。
  String _aiTargetText() =>
      _memoMode == 'free' ? _freeTargetText() : _allItemsText();

  Future<void> _openBrowserAi({String? id, String query = ''}) async {
    var target = (id ?? '').trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (target.isEmpty) {
        target = (prefs.getString('browser_ai_target') ?? '').trim();
      } else {
        await prefs.setString('browser_ai_target', target);
      }
    } catch (_) {}
    final def = MindMapProvider.browserAiTargets.firstWhere(
      (e) => e['id'] == target,
      orElse: () => MindMapProvider.browserAiTargets.first,
    );
    var q = query.trim();
    // 前提条件があれば頭に添える (= ユーザー要望: ブラウザ版でも前提条件)。
    final prefix = await loadBrowserAiPrefix();
    if (q.isNotEmpty && prefix.trim().isNotEmpty) {
      q = '${prefix.trim()}\n\n$q';
    }
    // 渡したい文があれば質問欄に載せた形で開く (= ユーザー要望: AI に渡す)。
    final url = (def['url'] ?? '')
        .replaceAll('{q}', q.isEmpty ? '' : Uri.encodeComponent(q));
    if (url.isEmpty) return;
    await _openWeb(url, def['label'] ?? 'AI');
  }

  /// どのブラウザ AI を開くか選ぶ (= 長押し / 右クリック)。
  /// アプリの API チャットを使いたい時のための項目も置く。
  Future<void> _showBrowserAiMenu(BuildContext btnCtx) async {
    final box = btnCtx.findRenderObject() as RenderBox?;
    final pos =
        box == null ? const Offset(60, 60) : box.localToGlobal(Offset.zero);
    final chosen = await showMenu<String>(
      context: btnCtx,
      position:
          RelativeRect.fromLTRB(pos.dx, pos.dy + 24, pos.dx + 1, pos.dy + 25),
      color: const Color(0xFF23233A),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 28,
          child: Text(FloatL10n.t('float.browserAi'),
              style: const TextStyle(
                  color: Color(0xFF8890A6),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700)),
        ),
        for (final t in MindMapProvider.browserAiTargets)
          PopupMenuItem<String>(
            value: 'web:${t['id']}',
            height: 32,
            child: Text(t['label'] ?? '${t['id']}',
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
        const PopupMenuDivider(height: 6),
        // アプリの AI アシスタント (API) に切り替える (= ユーザー要望)。
        PopupMenuItem<String>(
          value: 'api',
          height: 32,
          child: Text(FloatL10n.t('memo.openAiApi'),
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
        // そのアシスタントが使うモデルを選ぶ (= ユーザー要望)。
        PopupMenuItem<String>(
          value: 'model',
          height: 32,
          child: Text(FloatL10n.t('memo.aiModel'),
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
        // 毎回 AI に添える前提条件 (= ユーザー要望: ブラウザ版に切り替える
        //   時も前提条件の設定ができるように)。 外の窓と同じ設定を使う。
        PopupMenuItem<String>(
          value: 'prefix',
          height: 32,
          child: Text(FloatL10n.t('memo.aiPrefixTitle'),
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
      ],
    );
    if (chosen == null || !mounted) return;
    if (chosen == 'api') {
      // アプリの AI にも「今のメモ」 をそのまま渡す。
      _enterAiMode(_aiTargetText());
      return;
    }
    if (chosen == 'model') {
      await _showAiModelMenu(btnCtx);
      return;
    }
    if (chosen == 'prefix') {
      await editBrowserAiPrefix(_dlgCtx ?? btnCtx);
      return;
    }
    await _openBrowserAi(id: chosen.substring(4), query: _aiTargetText());
  }

  /// メモの所を AI の画面に切り替える (= ユーザー要望: 別窓を出さない)。
  /// [text] があれば質問欄に入れておく (項目の「AIに渡す」 から)。
  void _enterAiMode(String text) {
    setState(() {
      _aiMode = true;
      _aiError = '';
      if (text.trim().isNotEmpty) _aiInput.text = text.trim();
    });
    // 読む場所が要るので少し広げる。
    // ignore: discarded_futures
    _growWindowForAi();
    if (_aiInput.text.trim().isNotEmpty) {
      // ignore: discarded_futures
      _askAi();
    }
  }

  Future<void> _growWindowForAi() async {
    if (widget.embedded) return;
    try {
      final cur = await windowManager.getSize();
      if (cur.height < 480) {
        await windowManager.setSize(Size(cur.width, 520));
      }
    } catch (_) {}
  }

  /// 質問を本体へ渡して答えを受け取る。
  /// 本体側 (`_onSubWindowCall` の 'floatingMemoAskAi') が代行サーバーへ
  /// 投げてくれる。 この窓は鍵もトークンも持たないので自前では投げない。
  Future<void> _askAi() async {
    final q = _aiInput.text.trim();
    if (q.isEmpty || _aiBusy) return;
    setState(() {
      _aiBusy = true;
      _aiError = '';
      _aiAnswer = '';
    });
    try {
      final res = await _askMain('floatingMemoAskAi', q);
      if (!mounted) return;
      final text = '${res ?? ''}'.trim();
      setState(() {
        _aiBusy = false;
        if (text.startsWith('⚠')) {
          _aiError = text.substring(1).trim();
        } else if (text.isEmpty) {
          _aiError = FloatL10n.t('memo.aiEmpty');
        } else {
          _aiAnswer = text;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiBusy = false;
        _aiError = '$e';
      });
    }
  }

  /// AI の答えをメモへ書き写す (= 使った後にそのまま残せるように)。
  void _keepAiAnswerAsMemo() {
    final a = _aiAnswer.trim();
    if (a.isEmpty) return;
    setState(() {
      if (_memoMode == 'free') {
        final cur = _free.text.trimRight();
        _free.text = cur.isEmpty ? a : '$cur\n\n$a';
      } else {
        _items.insert(0, FloatMemoItem.create(a));
      }
      _aiMode = false;
    });
    // ignore: discarded_futures
    _persist();
    // ignore: discarded_futures
    _fitWindowToContent();
  }

  /// AI 画面の中身。
  Widget _buildAiBody() => Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: TextField(
                controller: _aiInput,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: FloatL10n.t('memo.aiHint'),
                  hintStyle:
                      const TextStyle(color: Colors.white24, fontSize: 12),
                ),
              ),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              icon: _aiBusy
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Color(0xFFBA68C8)))
                  : const Icon(Icons.send_rounded,
                      size: 18, color: Color(0xFFBA68C8)),
              onPressed: _aiBusy ? null : _askAi,
            ),
          ]),
          const Divider(color: Colors.white12, height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
                _aiError.isNotEmpty
                    ? _aiError
                    : (_aiAnswer.isEmpty
                        ? FloatL10n.t('memo.aiEmptyHint')
                        : _aiAnswer),
                style: TextStyle(
                  color: _aiError.isNotEmpty
                      ? const Color(0xFFEF9A9A)
                      : (_aiAnswer.isEmpty ? Colors.white30 : Colors.white),
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ),
          ),
          Row(children: [
            // ── ブラウザ版の AI で開く ──
            //   この窓の AI は鍵 (= API/代行) を叩く形。 いつも使っている
            //   ChatGPT 等をそのまま使いたい場合はこちら
            //   (= ユーザー要望: ブラウザ版で開けるようにして)。
            TextButton.icon(
              icon: const Icon(Icons.open_in_browser_rounded,
                  size: 15, color: Color(0xFF4FC3F7)),
              label: Text(FloatL10n.t('memo.aiBrowser'),
                  style:
                      const TextStyle(color: Color(0xFF4FC3F7), fontSize: 11)),
              onPressed: () => _openAiFor(_aiInput.text),
            ),
            const Spacer(),
            if (_aiAnswer.isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.note_add_outlined,
                    size: 15, color: Color(0xFF43B97F)),
                label: Text(FloatL10n.t('memo.aiKeep'),
                    style: const TextStyle(
                        color: Color(0xFF43B97F), fontSize: 11)),
                onPressed: _keepAiAnswerAsMemo,
              ),
          ]),
        ]),
      );

  void _snack(String msg, {Color color = const Color(0xFF43B97F)}) {
    if (!mounted) return;
    // ★ この State の context は MaterialApp の外なので、
    //   ScaffoldMessenger は中の context から取る。
    final ctx = _dlgCtx;
    if (ctx == null) return;
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12)),
      backgroundColor: color,
      duration: const Duration(seconds: 2),
    ));
  }

  /// 入力欄の内容を 1 項目として確定する (Enter / 追加ボタン)。
  /// 新しい項目は入力欄のすぐ下 (リスト先頭) に追加していく
  /// (= ユーザー要望: 書いた所の下に追加していく形に)。
  void _commitInput() {
    final t = _input.text.trim();
    if (t.isEmpty) return;
    setState(() {
      _items.insert(0, FloatMemoItem.create(t));
      _input.clear();
    });
    // ignore: discarded_futures
    _persist();
    // ignore: discarded_futures
    _fitWindowToContent();
    _inputFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_listCtrl.hasClients) _listCtrl.jumpTo(0);
    });
  }

  /// クリップボードの画像をメモに足す (= ユーザー要望)。
  /// 入力欄に文字があれば、 その文字を説明として一緒に持たせる。
  Future<void> _addImageItem() async {
    final path = await importFloatMemoImageFromClipboard();
    if (path == null) {
      _snack(FloatL10n.t('memo.noImage'), color: const Color(0xFFE57373));
      return;
    }
    final caption = _input.text.trim();
    setState(() {
      _items.insert(0, FloatMemoItem.create(caption, image: path));
      _input.clear();
    });
    // ignore: discarded_futures
    _persist();
    // ignore: discarded_futures
    _fitWindowToContent();
  }

  /// 今のメモをテキストファイルに書き出す (= ユーザー要望)。
  /// 箇条書きなら 1 行ずつ、 自由記入なら本文をそのまま書く。
  /// メモをテキストで保存する時の置き場所 (= ユーザー要望: 指定できるように)。
  /// 空なら 書類/memo_export。
  static const String kMemoSaveDirKey = 'memoSaveDir';

  /// フォルダ選択に渡せる形に直す (= ユーザー報告: 保存場所を選ぼうとすると
  /// 「パラメーターの値が違う」 と出る)。 実在しない / 区切りが `/` のままの
  /// パスは Windows のダイアログが受け付けないので、 その時は渡さない。
  String? _safeInitialDir(String path) {
    var p = path.trim();
    if (p.isEmpty) return null;
    if (Platform.isWindows) p = p.replaceAll('/', Platform.pathSeparator);
    try {
      if (!Directory(p).existsSync()) return null;
    } catch (_) {
      return null;
    }
    return p;
  }

  Future<String> _memoSaveDir() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.reload();
      final v = (sp.getString(kMemoSaveDirKey) ?? '').trim();
      if (v.isNotEmpty && await Directory(v).exists()) return v;
    } catch (_) {}
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/memo_export';
  }

  /// 保存アイコンを右クリックした時に出す「保存場所の設定」 (= ユーザー要望)。
  Future<void> _showSaveDirMenu(BuildContext btnCtx) async {
    final box = btnCtx.findRenderObject() as RenderBox?;
    final pos =
        box == null ? const Offset(60, 60) : box.localToGlobal(Offset.zero);
    final now = await _memoSaveDir();
    if (!mounted) return;
    final chosen = await showMenu<String>(
      context: btnCtx,
      position:
          RelativeRect.fromLTRB(pos.dx, pos.dy + 24, pos.dx + 1, pos.dy + 25),
      color: const Color(0xFF23233A),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 30,
          child: SizedBox(
            width: 240,
            child: Text('${FloatL10n.t('memo.saveDir')}\n$now',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(0xFF8890A6), fontSize: 10.5)),
          ),
        ),
        PopupMenuItem<String>(
          value: 'pick',
          height: 32,
          child: Text(FloatL10n.t('memo.saveDirPick'),
              style: const TextStyle(color: Colors.white, fontSize: 12)),
        ),
        PopupMenuItem<String>(
          value: 'reset',
          height: 32,
          child: Text(FloatL10n.t('memo.saveDirDefault'),
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
      ],
    );
    if (chosen == null || !mounted) return;
    try {
      final sp = await SharedPreferences.getInstance();
      if (chosen == 'reset') {
        await sp.remove(kMemoSaveDirKey);
        if (mounted) _snack(FloatL10n.t('memo.saveDirDefault'));
        return;
      }
      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: FloatL10n.t('memo.saveDir'),
        initialDirectory: _safeInitialDir(now),
      );
      if (dir == null || dir.trim().isEmpty) return;
      await sp.setString(kMemoSaveDirKey, dir.trim());
      if (mounted) _snack('${FloatL10n.t('memo.saveDir')}: ${dir.trim()}');
    } catch (e) {
      if (mounted) _snack('$e', color: const Color(0xFFE57373));
    }
  }

  Future<void> _saveAsText() async {
    try {
      final buf = StringBuffer()
        ..writeln(_book.name)
        ..writeln('');
      if (_memoMode == 'free') {
        buf.writeln(_free.text);
      } else {
        for (final it in _items.reversed) {
          final t = DateTime.fromMillisecondsSinceEpoch(it.savedAt);
          final stamp = '${t.year}/${t.month.toString().padLeft(2, '0')}/'
              '${t.day.toString().padLeft(2, '0')} '
              '${t.hour.toString().padLeft(2, '0')}:'
              '${t.minute.toString().padLeft(2, '0')}';
          buf.writeln('[$stamp] ${it.text}');
          if (it.image.isNotEmpty) buf.writeln('  (画像) ${it.image}');
        }
      }
      // 置き場所は設定があればそちら (= ユーザー要望)。
      final d = Directory(await _memoSaveDir());
      if (!await d.exists()) await d.create(recursive: true);
      final now = DateTime.now();
      final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}';
      var base = _book.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      if (base.isEmpty) base = 'memo';
      final dest = '${d.path}/${base}_$stamp.txt';
      await File(dest).writeAsString(buf.toString(), flush: true);
      _snack(FloatL10n.t('memo.saved').replaceFirst('{path}', dest));
    } catch (e) {
      _snack('$e', color: const Color(0xFFE57373));
    }
  }

  void _removeItem(int i) {
    setState(() => _items.removeAt(i));
    // ignore: discarded_futures
    _persist();
    // ignore: discarded_futures
    _fitWindowToContent();
  }

  // ── メモ窓の中身を WebView に切り替える ──
  // 先に画面をスピナー付きで切り替えてから WebView を初期化する
  // (= ユーザー報告: AI ボタンを押しても切り替わらない。 WebView2 の
  //  初期化に数秒かかる間なにも起きず、 押せていないように見えた)。
  Future<void> _openWeb(String url, String title) async {
    setState(() {
      _webMode = true;
      _webReady = false;
      _webTitle = title;
    });
    // Web は読む領域が要るので広げる (埋め込みの時は入れ物に任せる)。
    if (!widget.embedded) {
      try {
        final cur = await windowManager.getSize();
        if (cur.height < 520) {
          await windowManager.setSize(Size(cur.width, 560));
        }
      } catch (_) {}
    }
    try {
      final c = wv_win.WebviewController();
      await c.initialize();
      await c.loadUrl(url);
      if (!mounted || !_webMode) {
        // 初期化中に「メモに戻る」 された場合は破棄するだけ。
        await c.dispose();
        return;
      }
      setState(() {
        _webCtrl = c;
        _webReady = true;
      });
    } catch (e) {
      // ── アプリの中のサブ窓では WebView を作れない ──
      //    (= ユーザー報告: MissingPluginException が出て開けない)。
      //    サブ窓のエンジンには webview_windows を登録していないため。
      //    その時は「アプリの外の窓」 として開き直す (別プロセスなので確実)。
      debugPrint('メモ窓での WebView 作成に失敗、 外の窓で開きます: $e');
      await _closeWeb();
      try {
        await Process.start(
          Platform.resolvedExecutable,
          ['--floating-web=${Uri.encodeComponent(url)}'],
          mode: ProcessStartMode.detached,
        );
      } catch (e2) {
        _snack('${FloatL10n.t('memo.openFailed')}: $e2',
            color: const Color(0xFFE57373));
      }
    }
  }

  /// メモ画面に戻る (WebView は破棄してメモリを返す)。
  Future<void> _closeWeb() async {
    final c = _webCtrl;
    setState(() {
      _webMode = false;
      _webReady = false;
      _webCtrl = null;
      _webTitle = '';
    });
    try {
      await c?.dispose();
    } catch (_) {}
    await _fitWindowToContent();
  }

  /// ブラウザ版の AI (ChatGPT 等) を本体に頼んで開く。
  /// この窓の中の AI は鍵を叩く形なので、 いつものブラウザ版を使いたい
  /// 時はこちら (= ユーザー要望)。 本体が「アプリの外の窓」 で開く。
  Future<void> _openAiFor(String text) async {
    // 単体で開いた窓は本体に頼れないので、 この窓の中で開く (= ユーザー報告
    //   対策: 本体が起動していないと何も起きなかった)。
    if (widget.standalone) {
      await _openBrowserAi(query: text);
      return;
    }
    try {
      await DesktopMultiWindow.invokeMethod(0, 'openFloatingAi', text.trim());
    } catch (_) {
      _snack(FloatL10n.t('memo.openFailed'), color: const Color(0xFFE57373));
    }
  }

  /// Google 検索はメモ欄そのものを検索画面に切り替える (= ユーザー要望:
  /// 別の窓ではなく、 この窓が Google 検索になるように)。
  /// サブ窓で WebView を作れない環境では、 _openWeb の中の保険が
  /// 「アプリの外の窓」 へ自動で逃がすので何も起きないままにはならない。
  Future<void> _openGoogleFor(String text) async {
    final searchUrl =
        'https://www.google.com/search?q=${Uri.encodeComponent(text)}';
    await _openWeb(searchUrl, 'Google');
  }

  /// フリーメモの AI / Google 検索に渡す文。
  /// 範囲選択があればその部分だけ、 無ければ全文
  /// (= ユーザー要望: 範囲選択した所を AI や Google 検索に渡す)。
  String _freeTargetText() {
    final sel = _free.selection;
    if (sel.isValid && !sel.isCollapsed) {
      final t = sel.textInside(_free.text).trim();
      if (t.isNotEmpty) return t;
    }
    return _free.text.trim();
  }

  /// AI モデルの切り替えメニュー (= ユーザー要望: AI ボタンを長押し /
  /// 右クリックでモデルを変更)。 一覧と現在値は本体から受け取り、 選んだら
  /// 本体の設定 (relayModel) を書き換える。 この窓は鍵を持たない。
  Future<void> _showAiModelMenu(BuildContext btnCtx) async {
    List<Map<String, dynamic>> models = [];
    String current = '';
    try {
      final raw = await _askMain('floatingMemoAiModels');
      final m = jsonDecode(raw) as Map<String, dynamic>;
      current = '${m['current'] ?? ''}';
      models = (m['models'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } catch (_) {}
    if (!mounted || !btnCtx.mounted) return;
    if (models.isEmpty) {
      _snack(FloatL10n.t('memo.aiModelNone'), color: const Color(0xFFE57373));
      return;
    }
    final box = btnCtx.findRenderObject() as RenderBox?;
    final pos =
        box == null ? const Offset(60, 60) : box.localToGlobal(Offset.zero);
    final chosen = await showMenu<String>(
      context: btnCtx,
      position:
          RelativeRect.fromLTRB(pos.dx, pos.dy + 24, pos.dx + 1, pos.dy + 25),
      color: const Color(0xFF23233A),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 28,
          child: Text(FloatL10n.t('memo.aiModel'),
              style: const TextStyle(
                  color: Color(0xFF8890A6),
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700)),
        ),
        for (final m in models)
          PopupMenuItem<String>(
            value: '${m['id']}',
            height: 32,
            child: Row(children: [
              Icon(
                  '${m['id']}' == current
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 14,
                  color: '${m['id']}' == current
                      ? const Color(0xFFBA68C8)
                      : Colors.white38),
              const SizedBox(width: 8),
              Flexible(
                child: Text('${m['label'] ?? m['id']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ]),
          ),
      ],
    );
    if (chosen == null || chosen.isEmpty) return;
    try {
      await _askMain('floatingMemoSetAiModel', chosen);
      _snack(FloatL10n.t('memo.aiModelSet'));
    } catch (_) {}
  }

  /// 本体へ頼む。 アプリの中から開いたサブウィンドウなら
  /// desktop_multi_window、 ショートカットなどで**単体で開いた窓**なら別
  /// プロセスなので 127.0.0.1 越しに頼む (= ユーザー報告: 単体で開いたメモ
  /// から「マップに追加」 すると「追加できるページがありません」 と出る)。
  Future<String> _askMain(String method, [dynamic args]) async {
    if (!widget.standalone) {
      try {
        final r = await DesktopMultiWindow.invokeMethod(0, method, args);
        return '${r ?? ''}';
      } catch (_) {
        return '';
      }
    }
    return requestFromMainApp(method, args);
  }

  /// 追加先のページを選んでマップへ (= ユーザー要望: ページを指定できるように)。
  /// [texts] は 1 件ずつ別々のメモノードになる (= 動画メモの「まとめてマップに
  /// 追加」 と同じ)。 追加できたら true。
  Future<bool> _addToMapWithPicker(
      BuildContext btnCtx, List<String> texts) async {
    final list = texts.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (list.isEmpty) return false;
    List<Map<String, dynamic>> pages = [];
    try {
      final raw = await _askMain('floatingMemoPages');
      pages = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } catch (_) {}
    if (!mounted || !btnCtx.mounted) return false;
    if (pages.isEmpty) {
      // ── 本体が起きていない時は控えておき、 次回起動時に追加する
      //    (= ユーザー要望: 本体が起動していなくても追加できるように)。
      //    prefs は本体と同じ保存先なので、 本体が次に起きた時に読める。 ──
      if (widget.standalone) {
        try {
          final sp = await SharedPreferences.getInstance();
          final raw = sp.getString('pending_memo_to_map_v1');
          final queue = <dynamic>[];
          if (raw != null && raw.isNotEmpty) {
            final d = jsonDecode(raw);
            if (d is List) queue.addAll(d);
          }
          for (final t in list) {
            queue.add({'text': t, 'at': DateTime.now().toIso8601String()});
          }
          await sp.setString('pending_memo_to_map_v1', jsonEncode(queue));
          _snack(FloatL10n.t('memo.queuedForNextLaunch'),
              color: const Color(0xFF43B97F));
          return true;
        } catch (_) {
          _snack(FloatL10n.t('memo.mainNotRunning'),
              color: const Color(0xFFE57373));
          return false;
        }
      }
      _snack(FloatL10n.t('memo.noPages'), color: const Color(0xFFE57373));
      return false;
    }
    final box = btnCtx.findRenderObject() as RenderBox?;
    final pos =
        box == null ? const Offset(80, 80) : box.localToGlobal(Offset.zero);
    final chosen = await showMenu<String>(
      context: btnCtx,
      position:
          RelativeRect.fromLTRB(pos.dx, pos.dy + 22, pos.dx + 1, pos.dy + 23),
      color: const Color(0xFF23233A),
      items: [
        for (final p in pages)
          PopupMenuItem<String>(
            value: '${p['id']}',
            height: 34,
            child: Row(children: [
              Icon(
                  p['current'] == true
                      ? Icons.radio_button_checked_rounded
                      : Icons.account_tree_rounded,
                  size: 14,
                  color: p['current'] == true
                      ? const Color(0xFF43B97F)
                      : Colors.white38),
              const SizedBox(width: 8),
              Flexible(
                child: Text('${p['name']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ]),
          ),
      ],
    );
    if (chosen == null) return false;
    var ok = false;
    for (final t in list) {
      try {
        final r = await _askMain('floatingMemoToNodePage',
            jsonEncode({'text': t, 'pageId': chosen}));
        if (r == 'ok') ok = true;
      } catch (_) {}
    }
    if (ok) _snack(FloatL10n.t('memo.addedToMap'));
    return ok;
  }

  /// 閉じる前の後始末: 保存 + WebView 破棄 + 本体へフォーカス返却
  /// (= ユーザー報告: 閉じると本体の動作がおかしくなる、 の対策)。
  Future<void> _closeWindow() async {
    await _persist();
    if (_webCtrl != null) {
      try {
        await _webCtrl?.dispose();
      } catch (_) {}
      _webCtrl = null;
    }
    // ── 単独プロセスの時は自分を終わらせる (= ユーザー要望: ショートカット
    //    から出したメモ窓は、 本体とは無関係に開いて閉じる) ──
    //    WebView2 の後始末を待つと数秒固まるので、 見た目を消してから
    //    即終了する (× を押した時と同じ考え方)。
    if (widget.standalone) {
      _sizeSaveTimer?.cancel();
      await _saveWinSize();
      try {
        await windowManager.hide().timeout(const Duration(milliseconds: 300));
      } catch (_) {}
      try {
        Process.killPid(pid);
      } catch (_) {}
      exit(0);
    }
    try {
      await DesktopMultiWindow.invokeMethod(0, 'focusMain');
    } catch (_) {}
    try {
      await WindowController.fromWindowId(widget.windowId).close();
    } catch (_) {}
  }

  @override
  void dispose() {
    if (widget.standalone) {
      _sizeSaveTimer?.cancel();
      try {
        windowManager.removeListener(this);
      } catch (_) {}
    }
    _topTimer?.cancel();
    _freeSaveTimer?.cancel();
    // ignore: discarded_futures
    _persist();
    try {
      _webCtrl?.dispose();
    } catch (_) {}
    _input.dispose();
    _free.dispose();
    _inputFocus.dispose();
    _listCtrl.dispose();
    super.dispose();
  }

  /// 項目の作成時刻 (動画メモの再生位置バッジと同じ位置に出す)。
  static String _clock(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }

  /// 項目の文章を書き直す (= 押し間違いや書き足しのため)。
  Future<void> _editItem(int i) async {
    if (i < 0 || i >= _items.length) return;
    final v = await _askText(FloatL10n.t('memo.editItem'),
        initial: _items[i].text, multiline: true);
    if (v == null || !mounted) return;
    final t = v.trim();
    if (t.isEmpty) {
      _removeItem(i);
      return;
    }
    setState(() => _items[i].text = t);
    // ignore: discarded_futures
    _persist();
  }

  /// この冊子の全項目をまとめて扱う (= 動画メモの一括操作と同じ)。
  String _allItemsText() => _items.map((e) => e.text).join('\n');

  Future<void> _addAllItemsToMap(BuildContext btnCtx) async {
    if (_items.isEmpty) return;
    final ok =
        await _addToMapWithPicker(btnCtx, _items.map((e) => e.text).toList());
    if (!ok || !mounted) return;
    setState(() {
      for (final e in _items) {
        e.addedToMap = true;
      }
    });
    // ignore: discarded_futures
    _persist();
  }

  Future<void> _clearAllItems() async {
    if (_items.isEmpty) return;
    final ctx = _dlgCtx;
    if (ctx == null) return;
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E32),
        title: Text(FloatL10n.t('memo.clearAll'),
            style: const TextStyle(color: Colors.white, fontSize: 14)),
        content: Text(
            FloatL10n.t('memo.clearAllConfirm')
                .replaceFirst('{n}', '${_items.length}'),
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(FloatL10n.t('memo.cancel'),
                style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE57373),
                foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(FloatL10n.t('memo.delete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _items.clear());
    // ignore: discarded_futures
    _persist();
    // ignore: discarded_futures
    _fitWindowToContent();
  }

  /// 一覧の上に出す「件数 + まとめて〜」 の帯 (= 動画メモの履歴ヘッダーと同じ)。
  Widget _itemsHeaderBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 6, 2),
      child: Wrap(
        spacing: 4,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.checklist_rounded,
                size: 13, color: Colors.white38),
            const SizedBox(width: 3),
            Text(
                FloatL10n.t('memo.itemCount')
                    .replaceFirst('{n}', '${_items.length}'),
                style: const TextStyle(color: Colors.white38, fontSize: 10.5)),
          ]),
          // ── まとめて AI / マップ / 検索 / 保存 / 全消し は
          //    ヘッダーへ移した (= ユーザー要望: 全ての下のボタンを
          //    ヘッダーに配置して欲しい)。 ここは件数だけ出す。 ──
        ],
      ),
    );
  }

  /// 一覧の 1 行 (= YouTube の動画メモの履歴項目と同じ作り)。
  /// 時刻バッジ + 本文 + 活用ボタン。 行をクリックすると書き直せる。
  Widget _itemTile(int i) {
    final item = _items[i];
    final text = item.text;
    // 画像付きの項目は、 上に絵を出してから下に文字を並べる (= ユーザー要望)。
    if (item.image.isNotEmpty) {
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            // ignore: discarded_futures
            _editItem(i);
          },
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 3),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(_clock(item.savedAt),
                      style: const TextStyle(
                          color: Color(0xFF4FC3F7),
                          fontSize: 10,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  InkWell(
                    onTap: () => _removeItem(i),
                    child: const Icon(Icons.close_rounded,
                        size: 14, color: Colors.white38),
                  ),
                ]),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.file(
                    File(item.image),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Container(
                      height: 60,
                      alignment: Alignment.center,
                      color: Colors.white10,
                      child: const Icon(Icons.broken_image_outlined,
                          color: Colors.white24, size: 18),
                    ),
                  ),
                ),
                if (text.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(text,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12, height: 1.35)),
                ],
              ],
            ),
          ),
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          // ignore: discarded_futures
          _editItem(i);
        },
        child: Container(
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 3),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: item.addedToMap
                  ? const Color(0xFF43B97F).withValues(alpha: 0.5)
                  : Colors.white12,
            ),
          ),
          child: Row(children: [
            // 時刻バッジ (動画メモのタイムスタンプと同じ見た目)。
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF4FC3F7).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _clock(item.savedAt),
                style: const TextStyle(
                    color: Color(0xFF4FC3F7),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 12, height: 1.35)),
            ),
            const SizedBox(width: 4),
            // 項目ごとの活用ボタン (= ユーザー要望: 動画メモのように)。
            if (item.addedToMap)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.check_circle_rounded,
                    color: Color(0xFF43B97F), size: 15),
              )
            else
              Builder(builder: (btnCtx) {
                return IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                  tooltip: FloatL10n.t('memo.pickPageAddToMap'),
                  icon: const Icon(Icons.add_to_photos_rounded,
                      size: 15, color: Color(0xFF43B97F)),
                  onPressed: () async {
                    final ok = await _addToMapWithPicker(btnCtx, [text]);
                    if (!ok || !mounted) return;
                    setState(() => item.addedToMap = true);
                    // ignore: discarded_futures
                    _persist();
                  },
                );
              }),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              tooltip: FloatL10n.t('memo.toAi'),
              icon: const Icon(Icons.auto_awesome_rounded,
                  size: 15, color: Color(0xFFBA68C8)),
              onPressed: () => _enterAiMode(text),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              tooltip: FloatL10n.t('memo.googleSearch'),
              icon: const Icon(Icons.search_rounded,
                  size: 15, color: Color(0xFF4FC3F7)),
              onPressed: () {
                // ignore: discarded_futures
                _openGoogleFor(text);
              },
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
              tooltip: FloatL10n.t('memo.delete'),
              icon: const Icon(Icons.close_rounded,
                  size: 14, color: Colors.white54),
              onPressed: () => _removeItem(i),
            ),
          ]),
        ),
      ),
    );
  }

  /// ヘッダーにカーソルが乗っているか (= ユーザー要望: 非表示ボタンは
  /// ホバー中だけ出す)。
  bool _headerHover = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF1B1B2A),
        body: Column(children: [
          // ドラッグで動かせるタイトル帯。
          MouseRegion(
            onEnter: (_) => setState(() => _headerHover = true),
            onExit: (_) => setState(() => _headerHover = false),
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _dragger.start(),
            onPanUpdate: (d) =>
                _dragger.update(d, View.of(context).devicePixelRatio),
            child: Container(
              height: 34,
              color: const Color(0xFF23233A),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(children: [
                // AI 表示中 / Web モード中はメモへ戻る矢印を出す。
                if (_webMode || _aiMode)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 26, minHeight: 26),
                    tooltip: FloatL10n.t('memo.backToMemo'),
                    icon: const Icon(Icons.arrow_back_rounded,
                        size: 16, color: Colors.white70),
                    onPressed: () {
                      if (_aiMode) {
                        setState(() => _aiMode = false);
                        // ignore: discarded_futures
                        _fitWindowToContent();
                        return;
                      }
                      // ignore: discarded_futures
                      _closeWeb();
                    },
                  )
                else if (!_chromeHidden)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.sticky_note_2_outlined,
                        size: 15, color: Color(0xFFFFC107)),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: (_chromeHidden && !_webMode && !_aiMode)
                      // 隠している時は題も出さない (= ユーザー要望)。
                      //   帯そのものは窓を掴んで動かすために残す。
                      ? const SizedBox.shrink()
                      : (_webMode || _aiMode)
                          ? Text(
                              _webMode
                                  ? _webTitle
                                  : FloatL10n.t('memo.aiTitle'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700))
                          // ── メモ帳の切替 (= ユーザー要望: 複数のメモを
                          //    保存して切り替えられるように) ──
                          : Builder(builder: (btnCtx) {
                              return InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: () {
                                  // ignore: discarded_futures
                                  _showBookMenu(btnCtx);
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 3),
                                  child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(_book.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                  fontWeight:
                                                      FontWeight.w700)),
                                        ),
                                        if (_books.length > 1)
                                          Text('  ${_bookIndex + 1}/'
                                              '${_books.length}',
                                              style: const TextStyle(
                                                  color: Colors.white38,
                                                  fontSize: 10)),
                                        const Icon(
                                            Icons.arrow_drop_down_rounded,
                                            size: 16,
                                            color: Colors.white54),
                                      ]),
                                ),
                              );
                            }),
                ),
                // 箇条書き ⇔ フリーメモの切替 (= ユーザー要望)。
                if (!_webMode && !_aiMode && !_chromeHidden)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 26, minHeight: 26),
                    tooltip:
                        _memoMode == 'list'
                            ? FloatL10n.t('memo.switchToFree')
                            : FloatL10n.t('memo.switchToList'),
                    icon: Icon(
                        _memoMode == 'list'
                            ? Icons.subject_rounded
                            : Icons.checklist_rounded,
                        size: 15,
                        color: const Color(0xFF80CBC4)),
                    onPressed: () {
                      setState(() =>
                          _book.mode = _memoMode == 'list' ? 'free' : 'list');
                      // ignore: discarded_futures
                      _persist();
                      // ignore: discarded_futures
                      _fitWindowToContent();
                    },
                  ),
                // AI を開く (= ユーザー要望: 新しい窓を出さず、 メモの所が
                //   そのまま AI の画面に切り替わる)。
                if (!_webMode && !_aiMode && !_chromeHidden)
                  Builder(builder: (btnCtx) {
                    // 長押し / 右クリックでモデルを変更 (= ユーザー要望)。
                    return GestureDetector(
                      onLongPress: () {
                        // ignore: discarded_futures
                        _showBrowserAiMenu(btnCtx);
                      },
                      onSecondaryTap: () {
                        // ignore: discarded_futures
                        _showBrowserAiMenu(btnCtx);
                      },
                      // IconButton の tooltip は長押しでも開いてしまい、
                      // モデル変更の長押しを食うので手動トリガーで包む。
                      child: Tooltip(
                        message:
                            '${FloatL10n.t('memo.openAi')}\n${FloatL10n.t('memo.aiModelHint')}',
                        triggerMode: TooltipTriggerMode.manual,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 26, minHeight: 26),
                          icon: const Icon(Icons.auto_awesome_rounded,
                              size: 15, color: Color(0xFFBA68C8)),
                          // ── 下の「AIに渡す」 と統合 (= ユーザー要望) ──
                          //   既定は**ブラウザ版 AI** に今のメモを渡して
                          //   この窓の中で開く。 長押し / 右クリックで
                          //   渡し先 (AI サイト / アプリのアシスタント /
                          //   モデル) を選べる。
                          onPressed: () {
                            // ignore: discarded_futures
                            _sendToAi(_aiTargetText());
                          },
                        ),
                      ),
                    );
                  }),
                // ── ここから下の「下のバーから移してきた」 ボタン ──
                //    (= ユーザー要望: 全ての下のボタンをヘッダーに配置)。
                //    自由記入なら選んだ所、 箇条書きなら全項目が対象。
                if (!_webMode && !_aiMode && !_chromeHidden)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 26, minHeight: 26),
                    tooltip: FloatL10n.t('memo.googleSearch'),
                    icon: const Icon(Icons.search_rounded,
                        size: 15, color: Color(0xFF4FC3F7)),
                    onPressed: () {
                      final t = _aiTargetText().trim();
                      if (t.isEmpty) return;
                      // ignore: discarded_futures
                      _openGoogleFor(t);
                    },
                  ),
                if (!_webMode && !_aiMode && !_chromeHidden)
                  Builder(builder: (btnCtx) {
                    return IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 26, minHeight: 26),
                      tooltip: FloatL10n.t('memo.addToMap'),
                      icon: const Icon(Icons.add_to_photos_rounded,
                          size: 15, color: Color(0xFF43B97F)),
                      onPressed: () {
                        if (_memoMode == 'free') {
                          final t = _free.text.trim();
                          if (t.isEmpty) return;
                          // ignore: discarded_futures
                          _addToMapWithPicker(btnCtx, [t]);
                        } else {
                          // ignore: discarded_futures
                          _addAllItemsToMap(btnCtx);
                        }
                      },
                    );
                  }),
                // テキストで保存。 右クリックで保存場所の設定 (= ユーザー要望)。
                if (!_webMode && !_aiMode && !_chromeHidden)
                  Builder(builder: (btnCtx) {
                    return GestureDetector(
                      onSecondaryTap: () {
                        // ignore: discarded_futures
                        _showSaveDirMenu(btnCtx);
                      },
                      onLongPress: () {
                        // ignore: discarded_futures
                        _showSaveDirMenu(btnCtx);
                      },
                      child: Tooltip(
                        message: '${FloatL10n.t('memo.saveAsText')}\n'
                            '${FloatL10n.t('memo.saveDirHint')}',
                        triggerMode: TooltipTriggerMode.manual,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 26, minHeight: 26),
                          icon: const Icon(Icons.save_alt_rounded,
                              size: 15, color: Colors.white54),
                          onPressed: () {
                            // ignore: discarded_futures
                            _saveAsText();
                          },
                        ),
                      ),
                    );
                  }),
                // 全部消す (箇条書きの時だけ)。
                if (!_webMode && !_aiMode && !_chromeHidden &&
                    _memoMode == 'list' && _items.isNotEmpty)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 26, minHeight: 26),
                    tooltip: FloatL10n.t('memo.clearAll'),
                    icon: const Icon(Icons.delete_sweep_rounded,
                        size: 15, color: Color(0xFFE57373)),
                    onPressed: () {
                      // ignore: discarded_futures
                      _clearAllItems();
                    },
                  ),
                // ── 目のボタン: 上のボタン類と下の 3 つをまとめて隠す ──
                //    (= ユーザー要望: メモのアイコンや文字、 AI などの
                //     ボタンも一緒に消えるように)。
                //    ★ 出し方の決まり (= ユーザー要望):
                //      ・「非表示にする」 ボタンは**いつでも**出しておく。
                //      ・「表示に戻す」 ボタンはヘッダーにカーソルが乗った
                //        時だけ出す (隠した意味が薄れないように)。
                //    ★ Web / AI に切り替えている間も出す (= ユーザー要望:
                //      切り替えたら表示/非表示ボタンが無くなるのが気になる)。
                if (!_chromeHidden || _headerHover)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 26, minHeight: 26),
                    tooltip: _chromeHidden
                        ? FloatL10n.t('memo.showFooter')
                        : FloatL10n.t('memo.hideFooter'),
                    icon: Icon(
                        _chromeHidden
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 15,
                        color: _chromeHidden
                            ? Colors.white38
                            : const Color(0xFF80CBC4)),
                    onPressed: _toggleChrome,
                  ),
                // ── ブラウザ AI 表示中: どの AI にするか切り替える ──
                //    (= ユーザー要望: 切り替えた後にモデルの切り替えが
                //     行えないのが気になる)。 押すと一覧が出て、 選ぶと
                //     この窓の中で開き直す。
                if (_webMode)
                  Builder(builder: (btnCtx) {
                    return IconButton(
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 26, minHeight: 26),
                      tooltip: FloatL10n.t('float.browserAi'),
                      icon: const Icon(Icons.smart_toy_rounded,
                          size: 15, color: Color(0xFFBA68C8)),
                      onPressed: () {
                        // ignore: discarded_futures
                        _showBrowserAiMenu(btnCtx);
                      },
                    );
                  }),
                // ── アプリの AI (API) 表示中: 使うモデルを切り替える ──
                if (_aiMode)
                  Builder(builder: (btnCtx) {
                    return IconButton(
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 26, minHeight: 26),
                      tooltip: FloatL10n.t('memo.aiModel'),
                      icon: const Icon(Icons.memory_rounded,
                          size: 15, color: Color(0xFFBA68C8)),
                      onPressed: () {
                        // ignore: discarded_futures
                        _showAiModelMenu(btnCtx);
                      },
                    );
                  }),
                // 手前固定の切り替え。
                if (!_chromeHidden || _webMode || _aiMode)
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 26, minHeight: 26),
                    tooltip: _pinned
                        ? FloatL10n.t('memo.unpin')
                        : FloatL10n.t('memo.pin'),
                    icon: Icon(
                        _pinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        size: 15,
                        color: _pinned
                            ? const Color(0xFF4FC3F7)
                            : Colors.white54),
                    onPressed: () {
                      setState(() => _pinned = !_pinned);
                      _applyAlwaysOnTop(_pinned);
                    },
                  ),
                // ── 閉じる (✕) は窓の枠にもあるので、 こちらには置かない ──
                //    (= ユーザー要望: ✕ が 2 つあるので下の方は要らない)。
              ]),
            ),
          ),
          ),
          // ── 入力欄 (上に配置。 Enter で書いた所の下に項目が増えていく
          //    = ユーザー要望)。 Shift+Enter で改行できる。 ──
          if (!_webMode && !_aiMode && _memoMode == 'list')
            Container(
              padding: const EdgeInsets.fromLTRB(10, 4, 4, 6),
              decoration: const BoxDecoration(
                color: Color(0xFF23233A),
                border: Border(
                    bottom: BorderSide(color: Color(0xFF32324A), width: 1)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    minLines: 1,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      hintText: FloatL10n.t('memo.hintList'),
                      hintStyle: const TextStyle(
                          color: Colors.white24, fontSize: 12),
                    ),
                  ),
                ),
                // 画像を貼り付ける (= ユーザー要望)。 クリップボードに
                //   画像があればそれを 1 項目として足す。
                IconButton(
                  tooltip: FloatL10n.t('memo.pasteImage'),
                  icon: const Icon(Icons.image_outlined,
                      size: 17, color: Color(0xFFFFB347)),
                  onPressed: () {
                    // ignore: discarded_futures
                    _addImageItem();
                  },
                ),
                IconButton(
                  tooltip: FloatL10n.t('memo.add'),
                  icon: const Icon(Icons.add_circle_outline_rounded,
                      size: 18, color: Color(0xFF43B97F)),
                  onPressed: _commitInput,
                ),
              ]),
            ),
          // ── 本体: メモ項目一覧 / フリーメモ / AI / WebView ──
          Expanded(
            child: _webMode
                ? (_webReady && _webCtrl != null
                    ? wv_win.Webview(_webCtrl!)
                    : const Center(
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : _aiMode
                    ? _buildAiBody()
                    : (_memoMode == 'free'
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                        child: TextField(
                          controller: _free,
                          maxLines: null,
                          expands: true,
                          keyboardType: TextInputType.multiline,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13, height: 1.5),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: FloatL10n.t('memo.hintFree'),
                            hintStyle: const TextStyle(
                                color: Colors.white24, fontSize: 12),
                          ),
                        ),
                      )
                    : (_items.isEmpty
                        ? Center(
                            child: Text(FloatL10n.t('memo.emptyHint'),
                                style: const TextStyle(
                                    color: Colors.white24, fontSize: 12)))
                        // ── 件数 + まとめて〜 の帯 + 一覧 (= ユーザー要望:
                        //    YouTube の動画メモと同じ感じに) ──
                        : Column(children: [
                            _itemsHeaderBar(),
                            const Divider(
                                height: 1, color: Color(0x22FFFFFF)),
                            Expanded(
                              child: ListView.builder(
                                controller: _listCtrl,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 5),
                                itemCount: _items.length,
                                itemBuilder: (_, i) => _itemTile(i),
                              ),
                            ),
                          ]))),
          ),
          // ── フリーメモの活用ボタン (全文を対象にする) ──
          //    ヘッダーの目のボタンで隠せる (= ユーザー要望)。
          // ── 自由記入の下のバー (AIに渡す / 検索 / マップに追加 /
          //    保存) は無くした (= ユーザー要望: 全ての下のボタンを
          //    ヘッダーに配置)。 同じものがヘッダーに並んでいる。 ──
        ]),
      ),
    );
  }
}

/// アプリの外に出す AI チャット窓 (= ユーザー要望)。 中身は WebView なので、
/// いつも使っている AI サイトをそのまま小窓で開ける。
class _AiWindowApp extends StatefulWidget {
  final int windowId;
  final Map<String, dynamic> args;
  const _AiWindowApp({required this.windowId, required this.args});

  @override
  State<_AiWindowApp> createState() => _AiWindowAppState();
}

class _AiWindowAppState extends State<_AiWindowApp> {
  final _WinDragger _dragger = _WinDragger();
  final wv_win.WebviewController _ctrl = wv_win.WebviewController();
  Timer? _topTimer;
  bool _ready = false;
  String _error = '';

  /// 切り替えられる AI サイト (= ユーザー要望: フローティング AI で
  /// AI モデルを切り替えられるように)。 並びは ChatGPT の次に Claude
  /// (= ユーザー要望)。 urlQ はメモから渡された質問を事前入力する URL。
  static const List<({String label, String url, String urlQ})> _aiSites = [
    (
      label: 'ChatGPT',
      url: 'https://chatgpt.com/',
      urlQ: 'https://chatgpt.com/?q={q}'
    ),
    (
      label: 'Claude',
      url: 'https://claude.ai/new',
      urlQ: 'https://claude.ai/new?q={q}'
    ),
    (
      label: 'Gemini',
      url: 'https://gemini.google.com/app',
      urlQ: 'https://gemini.google.com/app?q={q}'
    ),
    (
      label: 'Perplexity',
      url: 'https://www.perplexity.ai/',
      urlQ: 'https://www.perplexity.ai/search?q={q}'
    ),
    (
      label: 'Grok',
      url: 'https://grok.com/',
      urlQ: 'https://grok.com/?q={q}'
    ),
    (
      label: 'DeepSeek',
      url: 'https://chat.deepseek.com/',
      urlQ: 'https://chat.deepseek.com/?q={q}'
    ),
  ];
  String _currentAiLabel = 'AI';
  bool _disposed = false;

  /// 読み込みが終わらない時の案内 (= ユーザー報告: ChatGPT が既定で開いて
  /// 永遠に読み込み中になる)。 会社の管理ツール等でそのサイトが遮断されて
  /// いると起きるので、 上の切替メニューから別の AI を選べる旨を出す。
  bool _loading = false;
  bool _stalled = false;
  String _loadNote = '';
  Timer? _stallTimer;
  StreamSubscription<wv_win.LoadingState>? _loadSub;
  StreamSubscription<dynamic>? _errSub;

  @override
  void initState() {
    super.initState();
    _init();
    // z オーダーが戻された時のために定期的に最前面を張り直す。
    // 既に最前面なら呼び直さない + 間隔を広げる (= ユーザー報告: 入力状態が
    //   安定しない)。 setAlwaysOnTop を入力中に定期実行すると変換が切れる。
    _topTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      // 破棄後に走らせない (= 閉じた窓へ操作を投げるとプロセスが落ちる)。
      if (_disposed || !mounted) {
        _topTimer?.cancel();
        _topTimer = null;
        return;
      }
      try {
        if (await windowManager.isAlwaysOnTop()) return;
        if (_disposed || !mounted) return;
        await windowManager.setAlwaysOnTop(true);
      } catch (_) {}
    });
  }

  Future<void> _init() async {
    try {
      // 他アプリの上に出しておく (= ユーザー要望)。
      try {
        await windowManager.ensureInitialized();
        await windowManager.setAlwaysOnTop(true);
      } catch (_) {}
      await _ctrl.initialize();
      // WebView 自体は初期化できた時点で表示する (= ユーザー報告: 読み込みが
      //   終わらないと画面が spinner のままで、 AI を切り替えても何も出ない)。
      //   読み込みの完了は待たない。
      if (mounted) setState(() => _ready = true);
      // 読み込み状態を監視して、 止まったら案内を出す。
      _loadSub = _ctrl.loadingState.listen((st) {
        if (!mounted) return;
        final done = st == wv_win.LoadingState.navigationCompleted;
        setState(() {
          _loading = !done;
          if (done) {
            _stalled = false;
            _loadNote = '';
          }
        });
        if (done) _stallTimer?.cancel();
      });
      _errSub = _ctrl.onLoadError.listen((e) {
        if (!mounted) return;
        _stallTimer?.cancel();
        setState(() {
          _loading = false;
          _stalled = true;
          _loadNote =
              '${FloatL10n.t('ai.openFailedNamed').replaceAll('{name}', _currentAiLabel)} ($e)';
        });
      });
      // ── 開くサイトの決定 ──
      // 1) 最後に開いたサイトの記録があればそれ (= ユーザー要望)。
      // 2) 無ければ呼び出し元の URL、 それも無ければ ChatGPT。
      ({String label, String url, String urlQ})? site;
      try {
        final f = await _floatingAiLastFile();
        if (await f.exists()) {
          final label = (await f.readAsString()).trim();
          for (final s in _aiSites) {
            if (s.label == label) {
              site = s;
              break;
            }
          }
        }
      } catch (_) {}
      final initial =
          (widget.args['url'] as String?) ?? 'https://chatgpt.com/';
      if (site == null) {
        for (final s in _aiSites) {
          if (initial.startsWith(s.url) ||
              Uri.parse(initial).host == Uri.parse(s.url).host) {
            site = s;
            break;
          }
        }
      }
      // メモから渡された質問があれば事前入力付き URL で開く。
      final q = ((widget.args['q'] as String?) ?? '').trim();
      String url;
      if (site != null) {
        _currentAiLabel = site.label;
        url = q.isEmpty
            ? site.url
            : site.urlQ.replaceAll('{q}', Uri.encodeComponent(q));
      } else {
        url = initial;
      }
      await _loadSite(url);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// URL を読み込み、 一定時間で終わらなければ「別の AI に切り替えられる」
  /// 案内を出す (= ユーザー報告: 永遠に読み込み中になる)。
  Future<void> _loadSite(String url) async {
    _stallTimer?.cancel();
    if (mounted) {
      setState(() {
        _loading = true;
        _stalled = false;
        _loadNote = '';
      });
    }
    _stallTimer = Timer(const Duration(seconds: 12), () {
      if (!mounted || !_loading) return;
      setState(() {
        _stalled = true;
        _loadNote = FloatL10n.t('ai.stalled')
            .replaceAll('{name}', _currentAiLabel);
      });
    });
    try {
      await _ctrl.loadUrl(url);
    } catch (e) {
      if (!mounted) return;
      _stallTimer?.cancel();
      setState(() {
        _loading = false;
        _stalled = true;
        _loadNote = '${FloatL10n.t('ai.loadFailed')}: $e';
      });
    }
  }

  /// WebView を確実に破棄してから閉じる (= ユーザー報告: 閉じると本体の
  /// 動作がおかしくなる)。 破棄せずにウィンドウを壊すと WebView2 の
  /// プロセスやフックが残り、 本体側の入力が乱れることがある。
  Future<void> _closeWindow() async {
    // ★ 閉じる前に、 動き続けるものを全部止める ★
    //   タイマーや購読が生きたまま窓を閉じると、 破棄済みのエンジンに対して
    //   最前面設定や WebView の操作を投げ続けることになり、 プロセスごと
    //   落ちる。 その結果、 本体アプリまで巻き添えで終了し、 残った
    //   プロセスのせいで起動し直せなくなる
    //   (= ユーザー報告: AI ウィンドウを閉じると本体も起動できなくなる)。
    _topTimer?.cancel();
    _topTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    try {
      await _loadSub?.cancel();
    } catch (_) {}
    _loadSub = null;
    try {
      await _errSub?.cancel();
    } catch (_) {}
    _errSub = null;

    if (!_disposed) {
      _disposed = true;
      try {
        await _ctrl.dispose();
      } catch (_) {}
    }
    try {
      await DesktopMultiWindow.invokeMethod(0, 'focusMain');
    } catch (_) {}
    try {
      await WindowController.fromWindowId(widget.windowId).close();
    } catch (_) {}
  }

  @override
  void dispose() {
    // OS の × で閉じられた時もここを通る。 タイマー / 購読を必ず切ってから
    //   WebView を破棄する (残っていると破棄済みエンジンを叩いて落ちる)。
    _disposed = true;
    _topTimer?.cancel();
    _topTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    // ignore: discarded_futures
    _loadSub?.cancel();
    _loadSub = null;
    // ignore: discarded_futures
    _errSub?.cancel();
    _errSub = null;
    try {
      _ctrl.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF10101A),
        body: Column(children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _dragger.start(),
            onPanUpdate: (d) =>
                _dragger.update(d, View.of(context).devicePixelRatio),
            child: Container(
              height: 34,
              color: const Color(0xFF23233A),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(children: [
                const Icon(Icons.auto_awesome_rounded,
                    size: 15, color: Color(0xFFBA68C8)),
                const SizedBox(width: 6),
                // メモ窓を開く (= ユーザー要望: AI チャット欄からメモ欄を
                //   開けるように)。 本体経由でフローティングメモを立ち上げる。
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 26, minHeight: 26),
                  tooltip: FloatL10n.t('memo.openMemo'),
                  icon: const Icon(Icons.sticky_note_2_outlined,
                      size: 15, color: Color(0xFFFFC107)),
                  onPressed: () {
                    // ignore: discarded_futures
                    DesktopMultiWindow.invokeMethod(0, 'openFloatingMemo');
                  },
                ),
                const SizedBox(width: 2),
                // ── AI サイト切替 (= ユーザー要望) ──
                PopupMenuButton<({String label, String url, String urlQ})>(
                  tooltip: FloatL10n.t('ai.switchAi'),
                  color: const Color(0xFF23233A),
                  // 読み込み中でも切り替えられる (= ユーザー要望: 読み込み中も
                  //   AI モデルの変更ができるように)。 ヘッダーは webview の
                  //   状態に関係なく常に操作できる。
                  onSelected: (site) async {
                    setState(() => _currentAiLabel = site.label);
                    // 最後に開いたサイトとして記録 (= ユーザー要望)。
                    try {
                      final f = await _floatingAiLastFile();
                      await f.writeAsString(site.label, flush: true);
                    } catch (_) {}
                    // WebView がまだ初期化前でも落ちないようにガード。
                    if (!_ready) return;
                    await _loadSite(site.url);
                  },
                  itemBuilder: (_) => [
                    for (final site in _aiSites)
                      PopupMenuItem(
                        value: site,
                        height: 36,
                        child: Text(site.label,
                            style: TextStyle(
                                color: site.label == _currentAiLabel
                                    ? const Color(0xFFBA68C8)
                                    : Colors.white,
                                fontSize: 12.5,
                                fontWeight: site.label == _currentAiLabel
                                    ? FontWeight.w700
                                    : FontWeight.w400)),
                      ),
                  ],
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_currentAiLabel,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                    const Icon(Icons.arrow_drop_down_rounded,
                        size: 18, color: Colors.white54),
                  ]),
                ),
                const Spacer(),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 26, minHeight: 26),
                  icon: const Icon(Icons.close_rounded,
                      size: 16, color: Colors.white54),
                  onPressed: () {
                    // ignore: discarded_futures
                    _closeWindow();
                  },
                ),
              ]),
            ),
          ),
          Expanded(
            child: _error.isNotEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('${FloatL10n.t('ai.cannotOpen')}\n$_error',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    ),
                  )
                : (_ready
                    ? Stack(children: [
                        Positioned.fill(child: wv_win.Webview(_ctrl)),
                        // 読み込み中は細い進捗バーだけ (画面は隠さない)。
                        if (_loading)
                          const Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: LinearProgressIndicator(
                                minHeight: 2, color: Color(0xFFBA68C8)),
                          ),
                        // 開けない / 終わらない時の案内 (= ユーザー報告)。
                        if (_stalled && _loadNote.isNotEmpty)
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: 12,
                            child: Material(
                              color: const Color(0xFF2A2A40),
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    12, 10, 8, 10),
                                child: Row(children: [
                                  const Icon(Icons.info_outline_rounded,
                                      size: 16, color: Color(0xFFFFC107)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(_loadNote,
                                        style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 11.5,
                                            height: 1.35)),
                                  ),
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                        minWidth: 26, minHeight: 26),
                                    icon: const Icon(Icons.close_rounded,
                                        size: 14, color: Colors.white38),
                                    onPressed: () =>
                                        setState(() => _stalled = false),
                                  ),
                                ]),
                              ),
                            ),
                          ),
                      ])
                    : const Center(
                        child: CircularProgressIndicator(strokeWidth: 2))),
          ),
        ]),
      ),
    );
  }
}

class _AudienceWindowApp extends StatefulWidget {
  final int windowId;
  final Map<String, dynamic> args;
  const _AudienceWindowApp({required this.windowId, required this.args});

  @override
  State<_AudienceWindowApp> createState() => _AudienceWindowAppState();
}

class _AudienceWindowAppState extends State<_AudienceWindowApp> {
  String? _imagePath;

  @override
  void initState() {
    super.initState();
    _imagePath = widget.args['imagePath'] as String?;
    // メインウィンドウからの更新 (スライド画像差し替え) を受け取る。
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == 'update') {
        final m = call.arguments;
        final path = (m is Map) ? m['imagePath'] as String? : null;
        if (path != null && mounted) {
          setState(() => _imagePath = path);
        }
      }
      return null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final path = _imagePath;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: path == null
              ? const Text('スライド待機中…',
                  style: TextStyle(color: Colors.white38, fontSize: 16))
              : Image.file(
                  File(path),
                  key: ValueKey(path),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
        ),
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════════════
// 関数電卓ウィンドウ (= ユーザー要望: 関数電卓をアプリの外に出す)。
// メモ窓と同じ DesktopMultiWindow のサブウィンドウ。 WebView を使わない
// 純 Flutter UI なのでサブウィンドウでも問題なく動く。
// 電卓の中身はアプリ内オーバーレイと共通の CalcBody (= ユーザー要望:
// フローティングモードと普通に開く時とで UI が異なって困惑する → 統一)。
// ═══════════════════════════════════════════════════════════════════════════
/// アプリの外に出した Web 窓 (= ユーザー要望: Google マップなどを
/// フローティングメモのようにアプリの外へ出したい)。
///
/// 本体とは別プロセスで動く。 そのため、 この窓を閉じても本体側の
/// WebView には何の影響も無い (b88 で直した不具合の再発を避けるため)。
/// フローティング AI 窓のダイアログ用 navigator (= サブ窓と同じ理由:
/// State.context は自作 MaterialApp の外なので、 showDialog はこれを使う)。
final GlobalKey<NavigatorState> _navKeyFloating = GlobalKey<NavigatorState>();

/// 自動操作のフロー画面だけを出す「外の窓」 (= ユーザー要望)。
/// 別プロセスなので WebView の後始末も本体に一切影響しない。
class _AutomationWindowApp extends StatefulWidget {
  const _AutomationWindowApp();

  @override
  State<_AutomationWindowApp> createState() => _AutomationWindowAppState();
}

class _AutomationWindowAppState extends State<_AutomationWindowApp>
    with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  /// 即座に終わらせる。 exit() は WebView2 等の DLL の後始末を待って
  /// 固まることがあるため、 本体の × と同じ TerminateProcess 方式
  /// (設定は逐次保存済みなので失うものはない)。
  static Never _forceKillSelf() {
    try {
      Process.killPid(pid);
    } catch (_) {}
    exit(0);
  }

  @override
  void onWindowClose() {
    _forceKillSelf();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => MindMapProvider(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF12121C),
        ),
        home: Scaffold(
          backgroundColor: const Color(0xFF12121C),
          body: GoogleSearchAutomationHost(
            onRequestClose: _forceKillSelf,
          ),
        ),
      ),
    );
  }
}

class _FloatingWebWindowApp extends StatefulWidget {
  final String url;

  /// 開いた瞬間から「常に手前」 にするか (= ユーザー要望: フローティング AI は
  /// ディアクティブでも前面に出てほしい)。
  final bool startPinned;

  /// 窓のタイトル (省略時は URL)。
  final String? title;

  /// 掴んで外へ出された時の位置と大きさ (= ユーザー要望: そのままの姿で外へ)。
  /// null なら前回の大きさ、 それも無ければ縦長の既定値で開く。
  final Rect? initialFrame;

  /// 場所だけの指定 (= ユーザー要望: 押したボタンの近くに出す)。
  /// 大きさは前回のまま、 位置だけこの点に合わせる。
  final Offset? initialPosition;

  /// 本体の分割ペインの上に置いて放したら、 そのペインへ埋め込んで自分は
  /// 閉じるか (= ユーザー要望)。 要素から開いた窓だけ true。
  final bool embeddable;
  const _FloatingWebWindowApp(
      {required this.url,
      this.startPinned = false,
      this.embeddable = false,
      this.title,
      this.initialFrame,
      this.initialPosition});
  @override
  State<_FloatingWebWindowApp> createState() => _FloatingWebWindowAppState();
}

class _FloatingWebWindowAppState extends State<_FloatingWebWindowApp>
    with WindowListener {
  final wv_win.WebviewController _ctrl = wv_win.WebviewController();
  bool _ready = false;
  String? _error;
  late bool _pinned = widget.startPinned;

  // ─── AI の切り替え / 前提条件 / ヘッダー表示 (= ユーザー要望) ───────────
  /// 今開いている AI の id (browserAiTargets の id)。 URL から推定する。
  late String _aiId = _guessAiId(widget.url);

  /// 窓に出す題 (AI を切り替えたら差し替える)。
  late String _title = (widget.title != null && widget.title!.isNotEmpty)
      ? widget.title!
      : widget.url;

  /// 毎回 AI に渡す前提条件 (本体と同じ prefs キーを共有)。
  String _prefix = '';

  /// ヘッダーを出すか (= ユーザー要望: 表示/非表示の切り替え)。
  bool _headerVisible = true;

  /// 動画サイトらしい URL か (= 速度バーを自動で出す判定)。
  static bool _looksVideoUrl(String u) {
    final l = u.toLowerCase();
    return l.contains('youtube.com') ||
        l.contains('youtu.be') ||
        l.contains('youtube-nocookie.com') ||
        l.contains('vimeo.com') ||
        l.contains('nicovideo.jp') ||
        l.contains('twitch.tv') ||
        l.contains('dailymotion.com') ||
        l.contains('bilibili.com') ||
        l.endsWith('.mp4') ||
        l.contains('.mp4?');
  }

  /// ヘッダーの表示 / 非表示。 OS のタイトルバーも一緒に隠す
  /// (= ユーザー報告: ボタンを押してもいちばん上の帯 (OS のタイトルバー) が
  /// 残って、 隠れたように見えなかった)。
  Future<void> _setHeaderVisible(bool v) async {
    setState(() => _headerVisible = v);
    try {
      await windowManager.setTitleBarStyle(
        v ? TitleBarStyle.normal : TitleBarStyle.hidden,
        windowButtonVisibility: v,
      );
    } catch (_) {}
  }

  /// ヘッダーが隠れている時、 上端にカーソルが乗っているか
  /// (= ユーザー要望: 乗せるまで表示ボタンを出さない)。
  bool _hoverTop = false;

  static const String _kPrefixKey = kBrowserAiPrefixKey;
  static const String _kTargetKey = 'browser_ai_target';

  /// URL からどの AI かを推定する。
  static String _guessAiId(String url) {
    final u = url.toLowerCase();
    for (final t in MindMapProvider.browserAiTargets) {
      final id = t['id'] ?? '';
      if (id.isNotEmpty && u.contains(id)) return id;
    }
    if (u.contains('openai')) return 'chatgpt';
    if (u.contains('x.ai')) return 'grok';
    return MindMapProvider.browserAiTargets.first['id'] ?? 'chatgpt';
  }

  Map<String, String> get _aiDef =>
      MindMapProvider.browserAiTargets.firstWhere(
        (e) => e['id'] == _aiId,
        orElse: () => MindMapProvider.browserAiTargets.first,
      );

  /// タイトルの監視 (= DM 未読数を拾うため)。
  StreamSubscription<String>? _titleSub;

  /// 現在 URL の監視 (= 分割ペインへ埋め込む時に今見ているページを渡すため)。
  StreamSubscription<String>? _urlSub;
  int _lastReportedUnread = -1;

  /// ページ題の「(3) …」 から未読数を拾って本体へ知らせる
  /// (= ユーザー要望: Instagram / Slack / Discord などの DM 通知)。
  void _reportUnreadFromTitle(String t) {
    final m = RegExp(r'^\s*\((\d+)\+?\)').firstMatch(t);
    final count = m == null ? 0 : (int.tryParse(m.group(1) ?? '') ?? 0);
    if (count == _lastReportedUnread) return;
    _lastReportedUnread = count;
    String host = '';
    try {
      host = Uri.parse(_lastLoadedUrl).host;
    } catch (_) {}
    if (host.isEmpty) return;
    unawaited(() async {
      final client = HttpClient();
      client.connectionTimeout = const Duration(milliseconds: 600);
      try {
        final req = await client.post('127.0.0.1', _kOpenWithPort, '/badge');
        req.headers.set('x-hisator-token', _kOpenWithToken);
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({'host': host, 'count': count}));
        await req.close().timeout(const Duration(seconds: 2));
      } catch (_) {} finally {
        try {
          client.close(force: true);
        } catch (_) {}
      }
    }());
  }

  /// AI に切り替える前に開いていた「元のページ」 (= ユーザー要望: 戻れるように)。
  String? _homeUrl;
  String? _homeTitle;

  /// 最後に明示的に読み込んだ URL (元のページを覚えるために使う)。
  late String _lastLoadedUrl = widget.url;

  /// この URL がブラウザ AI のものか (元のページとして覚えるかの判定)。
  static bool _isAiHost(String url) {
    try {
      final h = Uri.parse(url).host.toLowerCase();
      if (h.isEmpty) return false;
      for (final t in MindMapProvider.browserAiTargets) {
        final th =
            Uri.parse((t['url'] ?? '').replaceAll('{q}', '')).host.toLowerCase();
        if (th.isNotEmpty && th == h) return true;
      }
    } catch (_) {}
    return false;
  }

  /// AI に切り替える前のページへ戻る (= ユーザー要望: 元のフローティング
  /// 画面に戻れる戻るボタン)。
  Future<void> _goHome() async {
    final u = _homeUrl;
    if (u == null || u.isEmpty) return;
    final t = _homeTitle;
    setState(() {
      _homeUrl = null;
      _homeTitle = null;
      if (t != null && t.isNotEmpty) _title = t;
    });
    try {
      await windowManager.setTitle(_title);
    } catch (_) {}
    try {
      await _ctrl.loadUrl(u);
    } catch (_) {}
    _lastLoadedUrl = u;
  }

  /// 別の AI に切り替える (窓はそのまま、 中身だけ差し替える)。
  Future<void> _switchAi(String id) async {
    final def = MindMapProvider.browserAiTargets.firstWhere(
      (e) => e['id'] == id,
      orElse: () => MindMapProvider.browserAiTargets.first,
    );
    final tmpl = def['url'] ?? '';
    // クエリ無しで開く (= 既に開いている会話を潰さないよう、 素の URL へ)。
    final url = tmpl.replaceAll('{q}', '');
    // AI ではないページから切り替える時は、 戻り先として覚えておく
    // (= ユーザー要望)。 AI → AI の切り替えでは上書きしない。
    if (_homeUrl == null && !_isAiHost(_lastLoadedUrl)) {
      _homeUrl = _lastLoadedUrl;
      _homeTitle = _title;
    }
    _lastLoadedUrl = url;
    setState(() {
      _aiId = id;
      _title = def['label'] ?? id;
    });
    try {
      await windowManager.setTitle(_title);
    } catch (_) {}
    try {
      await _ctrl.loadUrl(url);
    } catch (_) {}
    // 次に開く時もこの AI にする (本体と同じ prefs キー)。
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kTargetKey, id);
    } catch (_) {}
  }

  Future<void> _loadPrefix() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() => _prefix = prefs.getString(_kPrefixKey) ?? '');
    } catch (_) {}
  }

  /// 前提条件を編集する (本体の設定と同じものを書き換える)。
  Future<void> _editPrefix() async {
    final ctrl = TextEditingController(text: _prefix);
    final saved = await showDialog<String>(
      context: _navKeyFloating.currentContext ?? context,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E32),
        title: Text(FloatL10n.t('memo.aiPrefixTitle'),
            style: const TextStyle(color: Colors.white, fontSize: 15)),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(FloatL10n.t('memo.aiPrefixDesc'),
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: FloatL10n.t('memo.aiPrefixHint'),
                hintStyle:
                    const TextStyle(color: Colors.white24, fontSize: 12),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.06),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, '__cancel__'),
            child: Text(FloatL10n.t('btn.cancel'),
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, ''),
            child: Text(FloatL10n.t('btn.clear'),
                style: const TextStyle(color: Color(0xFFFF8A80))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFBA68C8),
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(dctx, ctrl.text.trim()),
            child: Text(FloatL10n.t('btn.save')),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (saved == null || saved == '__cancel__') return;
    setState(() => _prefix = saved);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefixKey, saved);
    } catch (_) {}
  }

  /// 前提条件を AI の入力欄へ差し込む (空なら編集ダイアログを出す)。
  Future<void> _insertPrefix() async {
    if (_prefix.trim().isEmpty) {
      await _editPrefix();
      if (_prefix.trim().isEmpty) return;
    }
    final esc = jsonEncode(_prefix);
    // 本体の AI 欄と同じ挿入 JS (contenteditable → textarea の順に探す)。
    final js = '''
(function(){
  try{
    var text = $esc;
    function area(el){var r=el.getBoundingClientRect();
      if(r.width<80||r.height<16)return 0;
      if(r.bottom<0||r.top>window.innerHeight)return 0;return r.width*r.height;}
    var sels=['div.ProseMirror[contenteditable="true"]','#prompt-textarea',
      'div[contenteditable="true"].ql-editor','div[contenteditable="true"]'];
    var best=null,ba=0;
    for(var i=0;i<sels.length;i++){var ns=document.querySelectorAll(sels[i]);
      for(var j=0;j<ns.length;j++){var a=area(ns[j]);if(a>ba){ba=a;best=ns[j];}}
      if(best)break;}
    if(best){best.focus();
      try{var rg=document.createRange();rg.selectNodeContents(best);
        rg.collapse(false);var s=window.getSelection();s.removeAllRanges();
        s.addRange(rg);}catch(e){}
      var ex=(best.innerText||best.textContent||'').trim();
      try{document.execCommand('insertText',false,(ex?'\\n':'')+text);}
      catch(e){best.innerText=ex+(ex?'\\n':'')+text;
        best.dispatchEvent(new InputEvent('input',{bubbles:true}));}
      return 'ok';}
    var tas=document.querySelectorAll('textarea, input[type="text"]');
    var bt=null,bta=0;
    for(var k=0;k<tas.length;k++){var t=area(tas[k]);if(t>bta){bta=t;bt=tas[k];}}
    if(bt){bt.focus();var ev=bt.value||'';
      var nv=ev+(ev?'\\n':'')+text;
      var proto=bt.tagName==='TEXTAREA'?window.HTMLTextAreaElement.prototype
        :window.HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto,'value').set.call(bt,nv);
      bt.dispatchEvent(new Event('input',{bubbles:true}));return 'ok-ta';}
    return 'not-found';
  }catch(e){return 'err';}
})();
''';
    try {
      await _ctrl.executeScript(js);
    } catch (_) {}
  }

  /// 本体の AI アシスタント (MCP チャット) を開いてもらう。
  /// メモ表示に切り替えているか。
  ///
  /// = ユーザー要望「フローティング AI からフローティングメモを呼び出すと
  ///   別枠が開いてしまう。 そうじゃなくてフローティング AI の画面がメモに
  ///   切り替わるようにして欲しい」。 別プロセス / 別窓は作らず、 この窓の
  ///   中身だけ差し替える。 メモの中身は本体・メモ窓と同じ保存先を読み書き
  ///   するので、 どこで書いても同じメモ帳になる。
  bool _memoMode = false;

  Future<void> _callAssistant() async {
    final ok = await openAssistantAnyway('');
    if (!ok && mounted) {
      final ctx = _navKeyFloating.currentContext;
      if (ctx != null) {
        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
          content: Text(FloatL10n.t('memo.assistantFailed')),
          duration: const Duration(seconds: 3),
        ));
      }
    }
  }

  /// 常に手前を維持し直すタイマー。
  ///
  /// ★ Windows は他アプリをクリックした時などに TOPMOST が外れることが
  ///   あるので、 ピン中は定期的に付け直す (= ユーザー要望: ディアクティブ
  ///   でも前面に出たまま)。
  Timer? _topTimer;

  @override
  void initState() {
    super.initState();
    // 窓の大きさが変わったら控える (= ユーザー要望: 次回その大きさで開く)。
    windowManager.addListener(this);
    // ignore: discarded_futures
    _init();
    // ignore: discarded_futures
    _loadPrefix();
    // ignore: discarded_futures
    _loadMaxRate();
  }

  @override
  void onWindowResized() => _scheduleSaveSize();

  @override
  void onWindowResize() => _scheduleSaveSize();

  // ─── 動画の再生速度 (= ユーザー要望: 要素から開いた YouTube は外の窓で
  //     立ち上がるので、 速度もこの窓で変えられるように) ───────────────
  /// 今の再生速度 (1.0 = 等速)。
  double _rate = 1.0;

  /// ページが変わると JS が消えるので、 少し待って掛け直すタイマー。
  Timer? _rateReapplyTimer;

  Future<void> _applyRate() async {
    try {
      await _ctrl.executeScript(webVideoRateJs(_rate));
    } catch (_) {}
  }

  void _scheduleRateReapply() {
    if ((_rate - 1.0).abs() < 0.01) return;
    _rateReapplyTimer?.cancel();
    _rateReapplyTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      // ignore: discarded_futures
      _applyRate();
    });
  }

  /// 速度の候補 (本体の速度バーと同じ考え方で、 2 倍より上も出す)。
  static const List<double> _kRateChoices = [
    0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0
  ];

  /// 速度バー (スライダーの行) を開いているか (= ユーザー要望: どのモードで
  /// 開いても再生速度バーが出るように)。 ヘッダーの「1.00x」 で開閉する。
  bool _rateBarOpen = false;

  /// 速度の上限 (本体の動作設定と同じ prefs を読む)。
  double _maxRate = 4.0;

  Future<void> _loadMaxRate() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getDouble('videoMaxRate') ?? 4.0;
      if (mounted) setState(() => _maxRate = v.clamp(1.5, 16.0).toDouble());
    } catch (_) {}
  }

  /// 埋め込みを頼んでいる最中か (連打・多重送信を防ぐ)。
  bool _embedAsking = false;

  /// 窓を動かし終えた (= マウスを放した) 合図。
  ///
  /// ここで本体に「今この枠の位置に置いたよ」 と伝え、 分割ペインの上なら
  /// 埋め込んでもらう (= ユーザー要望: 外に出した YouTube を分割ペインの
  /// 上に置いたら埋め込まれるように)。 ペインの上でなければ本体は何もせず、
  /// この窓もそのまま残る。
  @override
  void onWindowMoved() {
    if (!widget.embeddable) return;
    // ignore: discarded_futures
    _tryEmbedIntoMainWindow();
  }

  Future<void> _tryEmbedIntoMainWindow() async {
    if (_embedAsking || !mounted) return;
    _embedAsking = true;
    try {
      final bounds = await windowManager.getBounds();
      // 最小化中などは座標があり得ない値になるので投げない。
      if (bounds.left < -8000 || bounds.top < -8000) return;
      final ok = await requestEmbedIntoRunningInstance(_lastLoadedUrl, bounds);
      if (!ok) return;
      // 埋め込まれたのでこの窓は役目を終える。 見た目は先に消して、
      // WebView2 の後始末を待たずに終わらせる (= ×押下と同じ考え方)。
      try {
        await windowManager.hide().timeout(const Duration(milliseconds: 300));
      } catch (_) {}
      try {
        Process.killPid(pid);
      } catch (_) {}
      exit(0);
    } catch (_) {
      // 本体が居ない / 応答しない時は何もしない (窓はそのまま)。
    } finally {
      _embedAsking = false;
    }
  }

  /// 最後に閉じた時の窓の大きさを覚えておくキー (= ユーザー要望:
  /// フローティング AI は最後に閉じた大きさで開く)。
  static const String _kSizeKey = 'floatingAiWindowSize';
  Timer? _sizeSaveTimer;

  /// 今の窓の大きさを控える (連続で動く間は最後の 1 回だけ書く)。
  void _scheduleSaveSize() {
    _sizeSaveTimer?.cancel();
    _sizeSaveTimer = Timer(const Duration(milliseconds: 600), () async {
      try {
        final s = await windowManager.getSize();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            _kSizeKey, '${s.width.round()}x${s.height.round()}');
      } catch (_) {}
    });
  }

  /// 開く時の位置と大きさを決める。
  ///
  /// 1. 掴んで外へ出された時は、 その場所・その大きさのまま (= ユーザー要望)。
  /// 2. そうでなければ前回閉じた大きさ。
  /// 3. どちらも無ければ**縦長**の既定値 (= ユーザー要望: 既定の横幅が
  ///    大きすぎるので、 高さはそのままに横を絞って縦長に)。
  Future<void> _restoreSize() async {
    // ① 掴んで出された時の枠をそのまま使う。
    final f = widget.initialFrame;
    if (f != null && f.width >= 200 && f.height >= 160) {
      try {
        await windowManager.setBounds(f);
        return;
      } catch (_) {}
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      // サイトごとに前回の大きさを覚える (= 縦長が合うサイトと、 横幅が
      // 要るサイトが混ざっているため)。 無ければ今までの共通の控え。
      final raw = (prefs.getString('${_kSizeKey}_$_sizeHost') ??
              prefs.getString(_kSizeKey)) ??
          '';
      final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(raw);
      if (m != null) {
        // ② 前回の大きさ。
        final w = double.parse(m.group(1)!).clamp(320.0, 4000.0);
        final h = double.parse(m.group(2)!).clamp(240.0, 3000.0);
        await windowManager.setSize(Size(w, h));
        return;
      }
      // ③ 既定は縦長 (高さは今までどおり、 横幅だけ絞る)。 ただし、 横に
      //    広げないと中身が切れるサイト (通販など) は広めに開く
      //    (= ユーザー報告: Amazon が縦長で入り切らない)。
      final cur = await windowManager.getSize();
      final h = cur.height < 240 ? 720.0 : cur.height;
      await windowManager.setSize(
          Size(_wantsWideWindow(widget.url) ? _kWideFloatWebWidth : _kDefaultFloatWebWidth, h));
    } catch (_) {}
  }

  /// 大きさを覚える時の相手 (サイト) の名前。
  String get _sizeHost {
    try {
      final h = Uri.parse(widget.url).host.toLowerCase();
      return h.isEmpty ? 'other' : h;
    } catch (_) {
      return 'other';
    }
  }

  /// 横幅が要るサイトか (= ユーザー報告: Amazon を浮かせると縦長で画面が
  /// 入り切れていない)。 通販や地図のように、 横に広げないと項目が折り重なる
  /// サイトは最初から広めに開く。
  static bool _wantsWideWindow(String url) {
    final l = url.toLowerCase();
    const wide = [
      'amazon.',
      'rakuten.',
      'yahoo.co.jp',
      'mercari.',
      'ebay.',
      'aliexpress.',
      'google.com/maps',
      'docs.google.com',
      'drive.google.com',
      'calendar.google.com',
      'notion.so',
      'github.com',
    ];
    for (final w in wide) {
      if (l.contains(w)) return true;
    }
    return false;
  }

  /// 外に出した窓の既定の横幅 (= ユーザー要望: 既定が横に大きすぎる)。
  static const double _kDefaultFloatWebWidth = 480;

  /// 横幅が要るサイトの既定の横幅 (= ユーザー報告: Amazon が入り切らない)。
  static const double _kWideFloatWebWidth = 1000;

  Future<void> _init() async {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setTitle(_title);
      // 最後に閉じた大きさで開く (= ユーザー要望)。
      await _restoreSize();
      // 場所だけの指定 (= ボタンの近くに出す) が来ていたら移す。
      final p0 = widget.initialPosition;
      if (p0 != null && widget.initialFrame == null) {
        try {
          await windowManager.setPosition(p0);
        } catch (_) {}
      }
      if (_pinned) {
        try {
          await windowManager.setAlwaysOnTop(true);
        } catch (_) {}
        _startTopTimer();
      }
      await _ctrl.initialize();
      // DM 未読数をページ題から拾う (= ユーザー要望: DM 通知)。
      _titleSub = _ctrl.title.listen(_reportUnreadFromTitle);
      // 今見ているページを追いかける。 分割ペインへ埋め込む時は、 開いた
      // 時の URL ではなく「今見ている動画」 を渡したい (= ユーザー要望)。
      _urlSub = _ctrl.url.listen((u) {
        if (u.isEmpty) return;
        if (u != _lastLoadedUrl) _scheduleRateReapply();
        _lastLoadedUrl = u;
        // 動画サイトへ移動したら速度バーを自動で出す (= ユーザー要望:
        // YouTube を開く時は必ず出るように)。
        if (!_rateBarOpen && _looksVideoUrl(u) && mounted) {
          setState(() => _rateBarOpen = true);
        }
      });
      // 動画サイトなら速度バーを最初から出す (= ユーザー要望)。
      if (_looksVideoUrl(widget.url)) _rateBarOpen = true;
      await _ctrl.loadUrl(widget.url);
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _startTopTimer() {
    _topTimer?.cancel();
    _topTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!_pinned) return;
      try {
        // ★ 既に最前面フラグが立っているなら何もしない (= ユーザー報告:
        //   3 秒ごとに窓を持ち上げ直していたせいで、 本体アプリを触るたびに
        //   消えたり出たりを繰り返して邪魔)。 最前面は一度立てれば OS が
        //   維持するので、 フラグが外れてしまった時だけ掛け直す。
        if (await windowManager.isAlwaysOnTop()) return;
        await windowManager.setAlwaysOnTop(true);
      } catch (_) {}
    });
  }

  Future<void> _togglePin() async {
    final next = !_pinned;
    setState(() => _pinned = next);
    try {
      await windowManager.setAlwaysOnTop(next);
    } catch (_) {}
    if (next) {
      _startTopTimer();
    } else {
      _topTimer?.cancel();
      _topTimer = null;
    }
  }

  @override
  void dispose() {
    _titleSub?.cancel();
    _urlSub?.cancel();
    _rateReapplyTimer?.cancel();
    _topTimer?.cancel();
    _sizeSaveTimer?.cancel();
    windowManager.removeListener(this);
    try {
      _ctrl.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKeyFloating,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF12121C),
        body: Column(children: [
          // ── 上のバー (AI 切替 / アシスタント / 前提条件 / 常に前面 /
          //    再読み込み / ヘッダーを隠す / 閉じる) ──
          //    ★ 隠している時は 6px の帯だけ残し、 そこにカーソルを乗せた時
          //      だけ「表示」 ボタンが出る (= ユーザー要望)。
          if (_headerVisible)
            Container(
              height: 34,
              color: const Color(0xFF1A1A2E),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(children: [
                // ── 左端は窓の題だけ (= ユーザー要望: AI の窓でもないのに
                //    左端にモデル名が出ているのは変。 ブラウザ AI は右側の
                //    ✨ ボタンに移動した) ──
                const Icon(Icons.public_rounded,
                    size: 14, color: Colors.white38),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
                // ── 元のページへ戻る (= ユーザー要望: AI に切り替えた後で
                //    元のフローティング画面に戻れるように) ──
                if (_homeUrl != null)
                  IconButton(
                    tooltip: FloatL10n.t('float.backHome'),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: const Icon(Icons.arrow_back_rounded,
                        size: 16, color: Color(0xFF4FC3F7)),
                    onPressed: () {
                      // ignore: discarded_futures
                      _goHome();
                    },
                  ),
                // ── ブラウザ AI (= ユーザー要望: 右側に並べて、 押すとモデルを
                //    選べる。 選ぶと**この窓がそのまま**フローティング AI に
                //    切り替わる)。 キラキラ (✨) は AI アシスタントに譲って、
                //    こちらはロボットのアイコン (= ユーザー要望)。 ──
                PopupMenuButton<String>(
                  tooltip: FloatL10n.t('float.browserAi'),
                  color: const Color(0xFF1E1E32),
                  onSelected: (id) {
                    // ignore: discarded_futures
                    _switchAi(id);
                  },
                  itemBuilder: (_) {
                    // ★ 今この窓で AI を開いている時だけ丸印を付ける
                    //   (= ユーザー要望: AI 画面でもないのに ChatGPT に
                    //   チェックが入っているのは変)。
                    final checked =
                        _isAiHost(_lastLoadedUrl) ? _aiId : null;
                    return [
                      for (final t in MindMapProvider.browserAiTargets)
                        PopupMenuItem<String>(
                          value: t['id'],
                          height: 34,
                          child: Row(children: [
                            Icon(
                                t['id'] == checked
                                    ? Icons.radio_button_checked_rounded
                                    : Icons.radio_button_off_rounded,
                                size: 14,
                                color: t['id'] == checked
                                    ? const Color(0xFF4FC3F7)
                                    : Colors.white38),
                            const SizedBox(width: 8),
                            Text(t['label'] ?? '',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12.5)),
                          ]),
                        ),
                    ];
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(Icons.smart_toy_rounded,
                        size: 16, color: Color(0xFFBA68C8)),
                  ),
                ),
                // ── 再生速度 (= ユーザー要望: どのモードで開いても
                //    再生速度バーが出るように)。 押すと下にスライダーの
                //    バーが開く (本体の浮遊窓と同じ形)。 ──
                Tooltip(
                  message: FloatL10n.t('float.playbackRate'),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () =>
                        setState(() => _rateBarOpen = !_rateBarOpen),
                    child: Text(
                      '${_rate.toStringAsFixed(2)}x',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: _rateBarOpen || (_rate - 1.0).abs() > 0.01
                            ? const Color(0xFF4FC3F7)
                            : Colors.white38,
                      ),
                    ),
                  ),
                ),
                // ── メモに切り替える / Web に戻る ──
                // = ユーザー要望「フローティング AI からメモを呼ぶと別枠が
                //   開いてしまう。 この画面がメモに切り替わるように」。
                //   別窓は作らず、 この窓の中身だけ差し替える。
                IconButton(
                  tooltip: FloatL10n.t(
                      _memoMode ? 'memo.backToMemo' : 'float.openMemo'),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(
                      _memoMode
                          ? Icons.arrow_back_rounded
                          : Icons.sticky_note_2_rounded,
                      size: 16,
                      color: _memoMode
                          ? const Color(0xFF4FC3F7)
                          : const Color(0xFFFFB347)),
                  onPressed: () => setState(() => _memoMode = !_memoMode),
                ),
                // ── AI アシスタント (本体の MCP チャット) を呼ぶ。
                //    アプリ内と同じキラキラ (✨) にする (= ユーザー要望)。 ──
                IconButton(
                  tooltip: FloatL10n.t('memo.openAssistant'),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.auto_awesome_rounded,
                      size: 16, color: Color(0xFF43B97F)),
                  onPressed: () {
                    // ignore: discarded_futures
                    _callAssistant();
                  },
                ),
                // ── 前提条件 (押すと入力欄へ挿入、 長押し/右クリックで編集) ──
                GestureDetector(
                  onLongPress: () {
                    // ignore: discarded_futures
                    _editPrefix();
                  },
                  onSecondaryTap: () {
                    // ignore: discarded_futures
                    _editPrefix();
                  },
                  child: IconButton(
                    tooltip: FloatL10n.t('memo.aiPrefixTip'),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    icon: Icon(Icons.tips_and_updates_outlined,
                        size: 16,
                        color: _prefix.trim().isEmpty
                            ? Colors.white38
                            : const Color(0xFFBA68C8)),
                    onPressed: () {
                      // ignore: discarded_futures
                      _insertPrefix();
                    },
                  ),
                ),
                IconButton(
                  tooltip: FloatL10n.t(_pinned ? 'memo.unpin' : 'memo.pin'),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(
                      _pinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      size: 16,
                      color:
                          _pinned ? const Color(0xFF4FC3F7) : Colors.white38),
                  onPressed: _togglePin,
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.refresh_rounded,
                      size: 16, color: Colors.white38),
                  onPressed: () {
                    // ignore: discarded_futures
                    _ctrl.reload();
                  },
                ),
                // ── ヘッダーを隠す (= ユーザー要望) ──
                IconButton(
                  tooltip: FloatL10n.t('memo.hideHeader'),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.keyboard_double_arrow_up_rounded,
                      size: 16, color: Colors.white38),
                  onPressed: () => _setHeaderVisible(false),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.close_rounded,
                      size: 16, color: Colors.white54),
                  onPressed: () async {
                    // 閉じる直前の大きさを覚えておく (= ユーザー要望:
                    // 次回はこの大きさで開く)。
                    _sizeSaveTimer?.cancel();
                    try {
                      final s = await windowManager.getSize();
                      final prefs = await SharedPreferences.getInstance();
                      final v = '${s.width.round()}x${s.height.round()}';
                      // サイトごとに覚える (= 通販は横長、 AI は縦長、 と
                      // サイトによって合う形が違うため)。 共通の控えも残す。
                      await prefs.setString('${_kSizeKey}_$_sizeHost', v);
                      await prefs.setString(_kSizeKey, v);
                    } catch (_) {}
                    // 別プロセスなので、 自分だけ終わればよい。
                    exit(0);
                  },
                ),
              ]),
            )
          else
            // 隠している時: 上端の細い帯。 カーソルを乗せた時だけボタンが出る。
            MouseRegion(
              onEnter: (_) => setState(() => _hoverTop = true),
              onExit: (_) => setState(() => _hoverTop = false),
              child: Container(
                height: _hoverTop ? 26 : 6,
                width: double.infinity,
                color: const Color(0xFF1A1A2E),
                alignment: Alignment.centerRight,
                child: _hoverTop
                    ? IconButton(
                        tooltip: FloatL10n.t('memo.showHeader'),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 26, minHeight: 26),
                        icon: const Icon(
                            Icons.keyboard_double_arrow_down_rounded,
                            size: 15,
                            color: Colors.white54),
                        onPressed: () => _setHeaderVisible(true),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          // ── 再生速度バー (= ユーザー要望: 必ず再生速度バーの付いたモードで
          //    開くように)。 ヘッダーの「1.00x」 で開閉する。 ──
          if (_rateBarOpen && _headerVisible)
            Container(
              height: 30,
              color: const Color(0xFF15152A),
              padding: const EdgeInsets.only(left: 8, right: 4),
              child: Row(children: [
                const Icon(Icons.speed_rounded,
                    size: 14, color: Color(0xFF4FC3F7)),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 5),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 10),
                      activeTrackColor: const Color(0xFF4FC3F7),
                      inactiveTrackColor: Colors.white24,
                      thumbColor: const Color(0xFF4FC3F7),
                    ),
                    child: Slider(
                      value: _rate.clamp(0.25, _maxRate),
                      min: 0.25,
                      max: _maxRate,
                      divisions: ((_maxRate - 0.25) * 4).round().clamp(4, 64),
                      onChanged: (v) {
                        setState(() => _rate = v);
                        // ignore: discarded_futures
                        _applyRate();
                      },
                    ),
                  ),
                ),
                // よく使う速度をすぐ選べるように (= 押すだけで切り替え)。
                for (final r in const [1.0, 1.5, 2.0])
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(0, 26),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () {
                      setState(() => _rate = r);
                      // ignore: discarded_futures
                      _applyRate();
                    },
                    child: Text('${r}x',
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: (r - _rate).abs() < 0.01
                                ? const Color(0xFF4FC3F7)
                                : Colors.white38)),
                  ),
              ]),
            ),
          // ── 中身: Web ⇄ メモ ──
          // = ユーザー要望「フローティング AI からフローティングメモを呼ぶと
          //   別枠が開いてしまう。 そうじゃなくてこの画面がメモに切り替わる
          //   ように」。 WebView は Offstage で生かしたままにして、 メモから
          //   戻った時に会話が消えないようにする。
          Expanded(
            child: Stack(children: [
              Offstage(
                offstage: _memoMode,
                child: _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Color(0xFFEF9A9A), fontSize: 12)),
                        ),
                      )
                    : _ready
                        ? wv_win.Webview(_ctrl)
                        : const Center(
                            child: CircularProgressIndicator(
                                color: Color(0xFF4FC3F7), strokeWidth: 2)),
              ),
              // = ユーザー要望: メモを開いた時はフローティングメモと同じ
              //   画面が出るように (簡易メモから差し替え)。
              if (_memoMode) const Positioned.fill(child: FloatingMemoView()),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// 外のフローティング窓の中に出す簡易メモ。
///
/// = ユーザー要望「フローティング AI からメモを呼ぶと別枠が開いてしまう。
///   この画面がメモに切り替わるように」。 別窓 (`_MemoWindowApp`) と同じ
///   保存先 (`loadFloatingMemoText` / `saveFloatingMemoText`) を読み書きする
///   ので、 どちらで書いても同じメモ帳に積まれる。
///
/// この窓には Provider がいないので、 文言は `FloatL10n` から取る。
class _FloatMemoPane extends StatefulWidget {
  const _FloatMemoPane();
  @override
  State<_FloatMemoPane> createState() => _FloatMemoPaneState();
}

class _FloatMemoPaneState extends State<_FloatMemoPane> {
  List<FloatMemoBook> _books = [];
  int _active = 0;
  bool _loading = true;
  final TextEditingController _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _reload();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final parsed = parseFloatingMemoBooks(await loadFloatingMemoText());
      if (!mounted) return;
      setState(() {
        _books = parsed.books;
        _active = parsed.active;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final t = _input.text.trim();
    if (t.isEmpty) return;
    _input.clear();
    await appendFloatingMemoItem(t);
    await _reload();
  }

  Future<void> _delete(FloatMemoItem item) async {
    try {
      if (_active < 0 || _active >= _books.length) return;
      _books[_active].items.removeWhere((e) => e.id == item.id);
      await saveFloatingMemoText(encodeFloatingMemoBooks(_books, _active));
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ColoredBox(
        color: Color(0xFF1B1B2A),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: Color(0xFFFFB347)),
          ),
        ),
      );
    }
    final items = (_active >= 0 && _active < _books.length)
        ? _books[_active].items
        : const <FloatMemoItem>[];
    return ColoredBox(
      color: const Color(0xFF1B1B2A),
      child: Column(children: [
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(FloatL10n.t('memo.emptyHint'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12, height: 1.5)),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: items.length,
                  separatorBuilder: (_, __) =>
                      const Divider(color: Colors.white10, height: 1),
                  itemBuilder: (_, i) {
                    final it = items[i];
                    final t = DateTime.fromMillisecondsSinceEpoch(it.savedAt);
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2, right: 8),
                            child: Text(
                              '${t.hour.toString().padLeft(2, '0')}:'
                              '${t.minute.toString().padLeft(2, '0')}',
                              style: const TextStyle(
                                  color: Colors.white24, fontSize: 10),
                            ),
                          ),
                          Expanded(
                            child: SelectableText(it.text,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12.5,
                                    height: 1.4)),
                          ),
                          IconButton(
                            tooltip: FloatL10n.t('memo.delete'),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 26, minHeight: 26),
                            icon: const Icon(Icons.close_rounded,
                                size: 14, color: Colors.white38),
                            onPressed: () {
                              // ignore: discarded_futures
                              _delete(it);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        const Divider(color: Colors.white12, height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 6, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: FloatL10n.t('memo.hintList'),
                  hintStyle:
                      const TextStyle(color: Colors.white24, fontSize: 11.5),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.06),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none),
                ),
                onSubmitted: (_) {
                  // ignore: discarded_futures
                  _add();
                },
              ),
            ),
            IconButton(
              tooltip: FloatL10n.t('memo.add'),
              icon: const Icon(Icons.add_circle_rounded,
                  size: 20, color: Color(0xFFFFB347)),
              onPressed: () {
                // ignore: discarded_futures
                _add();
              },
            ),
          ]),
        ),
      ]),
    );
  }
}


/// AI アシスタントをアプリの外に出した窓 (= ユーザー要望)。
///
/// ★ この窓は「表示と入力だけ」 を持つ。 考える所 (会話の続行、 ページの
///   書き換え) は本体 (windowId 0) に残したまま動く。 サブ窓のエンジンには
///   本体と同じ状態が無く、 ここで AI を動かしてもページを触れないため。
///   やり取りは 'assistCmd' (窓 → 本体) と 'assistState' (本体 → 窓) だけ。
class _AssistantWindowApp extends StatefulWidget {
  final int windowId;
  final bool pinned;
  const _AssistantWindowApp({required this.windowId, this.pinned = true});
  @override
  State<_AssistantWindowApp> createState() => _AssistantWindowAppState();
}

class _AssistantWindowAppState extends State<_AssistantWindowApp> {
  final List<({String role, String text})> _msgs = [];
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _busy = false;
  bool _canceling = false;
  int _step = 0;
  int _maxRounds = 24;
  String _model = '';
  String _balance = '';
  Timer? _poll;
  int _hwnd = 0;
  late bool _pinned = widget.pinned;

  @override
  void initState() {
    super.initState();
    // 本体からの押し出しを受ける。
    DesktopMultiWindow.setMethodHandler((call, from) async {
      if (call.method == 'assistState') _apply(call.arguments);
      return null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _grabHwnd();
      // ignore: discarded_futures
      _refresh();
    });
    // 押し出しが届かない時の保険 (負荷を掛けないよう間隔は広め)。
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      // ignore: discarded_futures
      _refresh();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 自分の窓のハンドルを控える (常に手前の切り替えに使う)。
  void _grabHwnd() {
    if (!Platform.isWindows) return;
    try {
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      final getActive = user32
          .lookupFunction<ffi.IntPtr Function(), int Function()>(
              'GetActiveWindow');
      final getForeground = user32
          .lookupFunction<ffi.IntPtr Function(), int Function()>(
              'GetForegroundWindow');
      var hwnd = getActive();
      if (hwnd == 0) hwnd = getForeground();
      if (hwnd == 0) return;
      _hwnd = hwnd;
      if (_pinned) _applyTopmost(true);
    } catch (_) {}
  }

  void _applyTopmost(bool on) {
    if (_hwnd == 0) return;
    try {
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      final setWindowPos = user32.lookupFunction<
          ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr, ffi.Int32, ffi.Int32,
              ffi.Int32, ffi.Int32, ffi.Uint32),
          int Function(int, int, int, int, int, int, int)>('SetWindowPos');
      const hwndTopmost = -1;
      const hwndNoTopmost = -2;
      const swpNoMove = 0x0002, swpNoSize = 0x0001, swpNoActivate = 0x0010;
      setWindowPos(_hwnd, on ? hwndTopmost : hwndNoTopmost, 0, 0, 0, 0,
          swpNoMove | swpNoSize | swpNoActivate);
    } catch (_) {}
  }

  void _apply(dynamic raw) {
    try {
      final m = (raw is Map) ? raw : null;
      final js = '${m?['json'] ?? ''}';
      if (js.isEmpty) return;
      final d = jsonDecode(js);
      if (d is! Map) return;
      final list = <({String role, String text})>[];
      for (final e in (d['msgs'] as List? ?? const [])) {
        if (e is Map) {
          list.add((role: '${e['role'] ?? 'ai'}', text: '${e['text'] ?? ''}'));
        }
      }
      final grew = list.length != _msgs.length;
      if (!mounted) return;
      setState(() {
        _msgs
          ..clear()
          ..addAll(list);
        _busy = d['busy'] == true;
        _canceling = d['canceling'] == true;
        _step = (d['step'] as num?)?.toInt() ?? 0;
        _maxRounds = (d['maxRounds'] as num?)?.toInt() ?? 24;
        _model = '${d['model'] ?? ''}';
        _balance = '${d['balance'] ?? ''}';
      });
      if (grew) _scrollToEnd();
    } catch (_) {}
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    });
  }

  Future<void> _refresh() async {
    try {
      _apply(await DesktopMultiWindow.invokeMethod(0, 'assistState'));
    } catch (_) {}
  }

  /// 本体へ注文を出す。 ★ 返事は待たない (AI の応答は分単位で掛かるため、
  /// 待つと窓と本体の両方が固まる)。
  void _cmd(String cmd, {String? value}) {
    unawaited(() async {
      try {
        _apply(await DesktopMultiWindow.invokeMethod(
            0, 'assistCmd', {'cmd': cmd, if (value != null) 'value': value}));
      } catch (_) {}
    }());
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    // 送った文はすぐ画面に出す (本体からの押し出しを待たない)。
    setState(() {
      _msgs.add((role: 'user', text: text));
      _busy = true;
    });
    _scrollToEnd();
    _cmd('send', value: text);
  }

  Future<void> _closeSelf() async {
    // ★ 閉じる前にタイマーを必ず止める。 走らせたまま窓を閉じると
    //   プロセスが巻き添えで固まることがある。
    _poll?.cancel();
    _poll = null;
    try {
      await DesktopMultiWindow.invokeMethod(0, 'assistClosed');
    } catch (_) {}
    try {
      await WindowController.fromWindowId(widget.windowId).close();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFFBA68C8);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: const Color(0xFF15152A),
        body: SafeArea(
          child: Column(children: [
            // ── ヘッダー ──
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              color: const Color(0xFF1E1E32),
              child: Row(children: [
                const Icon(Icons.auto_awesome_rounded,
                    color: accent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(FloatL10n.t('assist.title'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  tooltip: FloatL10n.t('assist.pin'),
                  icon: Icon(Icons.push_pin_rounded,
                      size: 16, color: _pinned ? accent : Colors.white38),
                  onPressed: () {
                    setState(() => _pinned = !_pinned);
                    _applyTopmost(_pinned);
                  },
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  tooltip: FloatL10n.t('assist.close'),
                  icon: const Icon(Icons.close_rounded,
                      size: 16, color: Colors.white54),
                  onPressed: () {
                    // ignore: discarded_futures
                    _closeSelf();
                  },
                ),
              ]),
            ),
            // ── 会話 ──
            Expanded(
              child: _msgs.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(FloatL10n.t('assist.empty'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                                height: 1.6)),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: _msgs.length,
                      itemBuilder: (c, i) {
                        final m = _msgs[i];
                        final isUser = m.role == 'user';
                        return Align(
                          alignment: isUser
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            constraints: const BoxConstraints(maxWidth: 420),
                            decoration: BoxDecoration(
                              color: isUser
                                  ? accent.withValues(alpha: 0.85)
                                  : const Color(0xFF23233C),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: SelectableText(m.text,
                                style: TextStyle(
                                    color: isUser
                                        ? Colors.white
                                        : Colors.white70,
                                    fontSize: 12.5,
                                    height: 1.5)),
                          ),
                        );
                      },
                    ),
            ),
            // ── 進み具合と停止 ──
            if (_busy)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Row(children: [
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: accent)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        _canceling
                            ? FloatL10n.t('assist.stopping')
                            : '${FloatL10n.t('assist.thinking')} '
                                '($_step / $_maxRounds)',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28)),
                    onPressed: _canceling ? null : () => _cmd('stop'),
                    child: Text(FloatL10n.t('assist.stop'),
                        style: const TextStyle(
                            color: Color(0xFFE57373), fontSize: 11.5)),
                  ),
                ]),
              ),
            // ── 使っているモデルと残り ──
            if (_model.isNotEmpty || _balance.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                child: Row(children: [
                  Text(_model,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 10.5)),
                  const Spacer(),
                  Flexible(
                    child: Text(_balance,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 10.5)),
                  ),
                ]),
              ),
            // ── 入力 ──
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Row(children: [
                Expanded(
                  child: Focus(
                    onKeyEvent: (n, e) {
                      if (e is! KeyDownEvent) return KeyEventResult.ignored;
                      if (e.logicalKey != LogicalKeyboardKey.enter &&
                          e.logicalKey != LogicalKeyboardKey.numpadEnter) {
                        return KeyEventResult.ignored;
                      }
                      if (HardwareKeyboard.instance.isShiftPressed) {
                        return KeyEventResult.ignored;
                      }
                      _send();
                      return KeyEventResult.handled;
                    },
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12.5),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFF1E1E32),
                        hintText: FloatL10n.t('assist.hint'),
                        hintStyle: const TextStyle(
                            color: Colors.white24, fontSize: 12),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Material(
                  color: _busy ? Colors.white12 : accent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _busy ? null : _send,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.arrow_upward_rounded,
                          size: 16,
                          color: _busy ? Colors.white38 : Colors.black),
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 画面録画の操作だけを持つ小さな窓 (= ユーザー要望)。
///
/// ★ この窓は「録画に写らない」。 Windows の
///   SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE) を掛けると、
///   画面を取り込む側 (ffmpeg の gdigrab を含む) からは無いものとして
///   扱われるため、 停止ボタンごと録画に入り込まない。
/// 録画そのものは本体 (windowId 0) が持っているので、 操作は IPC で頼む。
class _ScreenRecWindowApp extends StatefulWidget {
  final int windowId;
  const _ScreenRecWindowApp({required this.windowId});
  @override
  State<_ScreenRecWindowApp> createState() => _ScreenRecWindowAppState();
}

class _ScreenRecWindowAppState extends State<_ScreenRecWindowApp> {
  bool _recording = false;
  String _label = '00:00';
  String _target = 'screen';
  String _saveDir = '';
  String _lastSaved = '';
  bool _preview = true;
  Timer? _poll;

  /// 今の表示。 bar = 操作の帯 / region = 範囲選び / preview = 撮れた動画。
  /// (= ユーザー要望: 範囲選びもプレビューも全部この 1 つの窓の中で)
  String _view = 'bar';

  /// この窓のハンドル (自分の大きさを変えるのに使う)。
  int _hwnd = 0;

  /// 帯の時の窓の位置と大きさ (範囲選び/プレビューから戻る時に使う)。
  (int, int, int, int)? _savedRect;

  // ── 範囲選び ──
  Uint8List? _shot;
  int _vx = 0, _vy = 0, _vw = 1, _vh = 1;
  Offset? _dragFrom;
  Offset? _dragTo;
  Size _shotViewSize = Size.zero;

  // ── プレビュー ──
  String _previewPath = '';
  VideoPlayerController? _pv;
  bool _pvFailed = false;

  @override
  void initState() {
    super.initState();
    // ★ ここで windowManager を触らない。 サブ窓から呼ぶと本体側の窓を
    //   掴もうとして固まることがある (= ユーザー報告: 外に出すとフリーズ)。
    //   位置と大きさは本体が createWindow の後に決めている。
    // 本体からの押し出しを受ける。
    DesktopMultiWindow.setMethodHandler((call, from) async {
      if (call.method == 'recState') _apply(call.arguments);
      // 撮り終えた動画をこの窓の中で見せる (= ユーザー要望)。
      if (call.method == 'recPreview') {
        final m = call.arguments;
        final path = (m is Map) ? '${m['path'] ?? ''}' : '';
        unawaited(_enterPreview(path));
      }
      return null;
    });
    // 描画が出てから除外を掛ける (それまで窓の実体が無い)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _excludeFromCapture();
      // ignore: discarded_futures
      _refresh();
    });
    // 押し出しが届かない時の保険。 間隔は広めにして負荷を掛けない。
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      // ignore: discarded_futures
      _refresh();
    });
  }

  /// この窓を画面キャプチャから外す (Windows 10 2004 以降)。
  void _excludeFromCapture() {
    if (!Platform.isWindows) return;
    try {
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      final getForeground = user32.lookupFunction<ffi.IntPtr Function(),
          int Function()>('GetForegroundWindow');
      final getActive = user32.lookupFunction<ffi.IntPtr Function(),
          int Function()>('GetActiveWindow');
      final setAffinity = user32.lookupFunction<
          ffi.Int32 Function(ffi.IntPtr, ffi.Uint32),
          int Function(int, int)>('SetWindowDisplayAffinity');
      var hwnd = getActive();
      if (hwnd == 0) hwnd = getForeground();
      if (hwnd == 0) return;
      _hwnd = hwnd; // 自分の大きさを変える時に使う
      const wdaExcludeFromCapture = 0x00000011;
      setAffinity(hwnd, wdaExcludeFromCapture);
      // 他のフローティング機能と同じく、 既定で前面に出す (= ユーザー要望)。
      if (_pinned) _applyTopmost(true);
    } catch (_) {
      // 古い Windows では効かない。 その時は普通の窓として動く。
    }
  }

  /// 常に手前に表示 (= ユーザー要望: 他のフローティング機能と同様に)。
  bool _pinned = true;

  void _applyTopmost(bool on) {
    if (_hwnd == 0) return;
    try {
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      final setWindowPos = user32.lookupFunction<
          ffi.Int32 Function(ffi.IntPtr, ffi.IntPtr, ffi.Int32, ffi.Int32,
              ffi.Int32, ffi.Int32, ffi.Uint32),
          int Function(int, int, int, int, int, int, int)>('SetWindowPos');
      // HWND_TOPMOST = -1 / HWND_NOTOPMOST = -2。
      // SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE = 0x13。
      setWindowPos(_hwnd, on ? -1 : -2, 0, 0, 0, 0, 0x13);
    } catch (_) {}
  }

  /// 今の窓の位置と大きさ (物理ピクセル)。 取れなければ null。
  (int, int, int, int)? _winRect() {
    if (_hwnd == 0) return null;
    try {
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      final getWindowRect = user32.lookupFunction<
          ffi.Int32 Function(ffi.IntPtr, ffi.Pointer<ffi.Int32>),
          int Function(int, ffi.Pointer<ffi.Int32>)>('GetWindowRect');
      final p = pkgffi.calloc<ffi.Int32>(4);
      try {
        if (getWindowRect(_hwnd, p) == 0) return null;
        return (p[0], p[1], p[2] - p[0], p[3] - p[1]);
      } finally {
        pkgffi.calloc.free(p);
      }
    } catch (_) {
      return null;
    }
  }

  /// 窓を動かす / 大きさを変える (物理ピクセル)。
  void _moveWin(int x, int y, int w, int h) {
    if (_hwnd == 0) return;
    try {
      final user32 = ffi.DynamicLibrary.open('user32.dll');
      final moveWindow = user32.lookupFunction<
          ffi.Int32 Function(ffi.IntPtr, ffi.Int32, ffi.Int32, ffi.Int32,
              ffi.Int32, ffi.Int32),
          int Function(int, int, int, int, int, int)>('MoveWindow');
      moveWindow(_hwnd, x, y, w, h, 1);
    } catch (_) {}
  }

  /// 帯の時の窓の位置へ戻す。
  void _restoreBarRect() {
    final r = _savedRect;
    _savedRect = null;
    if (r != null) _moveWin(r.$1, r.$2, r.$3, r.$4);
  }

  // ── 範囲選び (この窓が大きくなって、 なぞってもらう) ──
  Future<void> _enterRegionSelect() async {
    final v = scap.virtualScreenRect();
    // 写しが撮れない環境では画面全体で始める。
    final shot = v == null
        ? null
        : scap.captureScreenRectPng(v.x, v.y, v.width, v.height);
    if (v == null || shot == null) {
      _cmd('start', value: '{}');
      return;
    }
    _savedRect ??= _winRect();
    setState(() {
      _view = 'region';
      _shot = shot;
      _vx = v.x;
      _vy = v.y;
      _vw = v.width;
      _vh = v.height;
      _dragFrom = null;
      _dragTo = null;
    });
    final w = (v.width * 0.86).round();
    final h = (v.height * 0.86).round();
    _moveWin(v.x + (v.width - w) ~/ 2, v.y + (v.height - h) ~/ 2, w, h);
  }

  /// 表示上の矩形 → 画面の物理ピクセルの矩形 (本体と同じ換算)。
  Map<String, int>? _regionMap() {
    final a = _dragFrom, b = _dragTo;
    if (a == null || b == null || _shotViewSize.width <= 0) return null;
    final sx = _vw / _shotViewSize.width;
    final sy = _vh / _shotViewSize.height;
    final l = math.min(a.dx, b.dx) * sx;
    final t = math.min(a.dy, b.dy) * sy;
    final r = math.max(a.dx, b.dx) * sx;
    final bo = math.max(a.dy, b.dy) * sy;
    final w = (r - l).round();
    final h = (bo - t).round();
    if (w < 16 || h < 16) return null;
    // 偶数に丸める (libx264 の都合。 本体の evened() と同じ)。
    return {
      'x': _vx + l.round(),
      'y': _vy + t.round(),
      'w': w - (w % 2),
      'h': h - (h % 2),
    };
  }

  void _cancelRegion() {
    setState(() {
      _view = 'bar';
      _shot = null;
    });
    _restoreBarRect();
  }

  void _startFromRegion() {
    final region = _regionMap();
    setState(() {
      _view = 'bar';
      _shot = null;
    });
    _restoreBarRect();
    // 選んでいなければ画面全体 (本体側と同じ扱い)。
    _cmd('start',
        value: jsonEncode({if (region != null) 'region': region}));
  }

  // ── 撮れた動画のプレビュー (この窓の中で再生する) ──
  Future<void> _enterPreview(String path) async {
    if (path.isEmpty || !mounted) return;
    final old = _pv;
    _pv = null;
    try {
      await old?.dispose();
    } catch (_) {}
    _savedRect ??= _winRect();
    setState(() {
      _view = 'preview';
      _previewPath = path;
      _pvFailed = false;
    });
    final v = scap.virtualScreenRect();
    if (v != null) {
      final w = (v.width * 0.5)
          .clamp(560.0, math.max(560.0, v.width.toDouble()))
          .round();
      final h = (w * 9 / 16).round() + 150;
      _moveWin(v.x + (v.width - w) ~/ 2, v.y + (v.height - h) ~/ 2, w, h);
    }
    try {
      final vc = VideoPlayerController.file(File(path));
      await vc.initialize();
      if (!mounted || _view != 'preview') {
        await vc.dispose();
        return;
      }
      vc.addListener(_pvTick);
      setState(() => _pv = vc);
      await vc.play();
    } catch (_) {
      if (mounted) setState(() => _pvFailed = true);
    }
  }

  void _pvTick() {
    if (mounted) setState(() {});
  }

  Future<void> _closePreview() async {
    final vc = _pv;
    _pv = null;
    vc?.removeListener(_pvTick);
    try {
      await vc?.dispose();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _view = 'bar';
        _previewPath = '';
      });
    }
    _restoreBarRect();
    // 本体へ知らせる (自動で出した窓なら本体が片付ける)。
    _cmd('previewClosed');
  }

  Future<void> _refresh() async {
    try {
      final r = await DesktopMultiWindow.invokeMethod(0, 'screenRecState');
      _apply(r);
    } catch (_) {}
  }

  /// 本体へ注文を出す。 ★ 返事は待たない。
  /// 待つと、 本体が範囲選びのモーダルを開いている間ずっと止まってしまう。
  void _cmd(String cmd, {String? value}) {
    unawaited(() async {
      try {
        final r = await DesktopMultiWindow.invokeMethod(
            0, 'screenRecCmd', {'cmd': cmd, if (value != null) 'value': value});
        _apply(r);
      } catch (_) {}
    }());
  }

  void _apply(dynamic r) {
    if (r is! Map || !mounted) return;
    setState(() {
      _recording = r['recording'] == true;
      _label = '${r['label'] ?? '00:00'}';
      _target = '${r['target'] ?? 'screen'}';
      _saveDir = '${r['saveDir'] ?? ''}';
      _lastSaved = '${r['lastSaved'] ?? ''}';
      if (r.containsKey('preview')) _preview = r['preview'] == true;
      if (r.containsKey('stopKey')) _stopKey = '${r['stopKey'] ?? ''}';
    });
  }

  /// 録画停止のショートカット (表示用。 本体から受け取る)。
  String _stopKey = '';

  @override
  void dispose() {
    _poll?.cancel();
    // プレビュー再生が残っていれば必ず止める (= サブ窓の後始末教訓:
    // 止め漏れが本体巻き添えの原因になる)。
    final vc = _pv;
    _pv = null;
    vc?.removeListener(_pvTick);
    try {
      // ignore: discarded_futures
      vc?.dispose();
    } catch (_) {}
    try {
      unawaited(DesktopMultiWindow.invokeMethod(0, 'screenRecClosed'));
    } catch (_) {}
    super.dispose();
  }

  Widget _chip(String id, IconData icon, String label) {
    final on = _target == id;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _recording ? null : () => _cmd('target', value: id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: on ? const Color(0xFF39395C) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border:
                Border.all(color: on ? const Color(0xFF9575CD) : Colors.white24),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: on ? Colors.white : Colors.white54),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: on ? Colors.white : Colors.white54, fontSize: 11.5)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF1B1B2C),
        // 範囲選びもプレビューもこの 1 つの窓の中で切り替える
        // (= ユーザー要望: 別の画面が立ち上がるのは使いにくい)。
        body: _view == 'region'
            ? _buildRegionSelect()
            : _view == 'preview'
                ? _buildPreview()
                : _buildBar(),
      ),
    );
  }

  Widget _buildBar() {
    return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Icon(Icons.screenshot_monitor_rounded,
                    size: 17,
                    color: _recording
                        ? const Color(0xFFE53935)
                        : const Color(0xFF9575CD)),
                const SizedBox(width: 8),
                if (_recording) ...[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                        color: Color(0xFFE53935), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 7),
                  Text(_label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE53935),
                        foregroundColor: Colors.white,
                        visualDensity: VisualDensity.compact),
                    icon: const Icon(Icons.stop_rounded, size: 16),
                    label: Text(FloatL10n.t('rec.stop')),
                    onPressed: () => _cmd('stop'),
                  ),
                ] else ...[
                  _chip('screen', Icons.desktop_windows_rounded,
                      FloatL10n.t('rec.whole')),
                  _chip('region', Icons.crop_rounded, FloatL10n.t('rec.area')),
                  const Spacer(),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF9575CD),
                        foregroundColor: Colors.white,
                        visualDensity: VisualDensity.compact),
                    icon: const Icon(Icons.fiber_manual_record_rounded,
                        size: 16),
                    label: Text(FloatL10n.t('rec.start')),
                    // 範囲なら、 この窓が大きくなってその場で選ぶ
                    // (= ユーザー要望: 別の画面を立ち上げない)。
                    onPressed: () {
                      if (_target == 'region') {
                        unawaited(_enterRegionSelect());
                      } else {
                        _cmd('start', value: '{}');
                      }
                    },
                  ),
                ],
                IconButton(
                  tooltip: FloatL10n.t('rec.saveDir'),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  icon: Icon(Icons.drive_file_move_outline,
                      size: 17,
                      color: _saveDir.isEmpty
                          ? Colors.white38
                          : const Color(0xFF9CCC65)),
                  onPressed: _recording ? null : () => _cmd('pickDir'),
                ),
                if (_lastSaved.isNotEmpty)
                  IconButton(
                    tooltip: FloatL10n.t('rec.openFolder'),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 30, minHeight: 30),
                    icon: const Icon(Icons.folder_open_rounded,
                        size: 17, color: Color(0xFF9CCC65)),
                    onPressed: () => _cmd('openFolder'),
                  ),
                // ── 常に手前に表示 (= ユーザー要望: 他のフローティングと
                //    同じように前面へ出せるように) ──
                IconButton(
                  tooltip: FloatL10n.t('float.pin'),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(
                      _pinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      size: 15,
                      color: _pinned
                          ? const Color(0xFF9575CD)
                          : Colors.white38),
                  onPressed: () {
                    setState(() => _pinned = !_pinned);
                    _applyTopmost(_pinned);
                  },
                ),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                // ── 撮影後にプレビューを出すか (= ユーザー要望) ──
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _cmd('preview', value: _preview ? '0' : '1'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 2, vertical: 2),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(
                          _preview
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 14,
                          color: _preview
                              ? const Color(0xFF9CCC65)
                              : Colors.white38),
                      const SizedBox(width: 4),
                      Text(FloatL10n.t('rec.preview'),
                          style: TextStyle(
                              color: _preview
                                  ? Colors.white70
                                  : Colors.white38,
                              fontSize: 10.5)),
                    ]),
                  ),
                ),
                const SizedBox(width: 8),
                // 録画中は停止ショートカットも見せる (= ユーザー要望)。
                if (_recording && _stopKey.isNotEmpty) ...[
                  Text(
                      '${FloatL10n.t('rec.stopKey')}: '
                      '${_stopKey.toUpperCase()}',
                      style: const TextStyle(
                          color: Color(0xFF9575CD), fontSize: 10.5)),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(FloatL10n.t('rec.notCaptured'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 10.5)),
                ),
              ]),
              if (_saveDir.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(_saveDir,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white24, fontSize: 10)),
                ),
            ],
          ),
        );
  }

  /// 範囲選び (この窓の中でなぞって選ぶ)。
  Widget _buildRegionSelect() {
    final region = _regionMap();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Row(children: [
          const Icon(Icons.crop_rounded, color: Color(0xFF9575CD), size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Text(FloatL10n.t('rec.regionTitle'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                color: Colors.white54, size: 20),
            onPressed: _cancelRegion,
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(FloatL10n.t('rec.regionHint'),
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ),
      const SizedBox(height: 10),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _shot == null
              ? const Center(
                  child:
                      CircularProgressIndicator(color: Color(0xFF9575CD)))
              : Center(
                  child: AspectRatio(
                    aspectRatio: _vw / _vh,
                    child: LayoutBuilder(builder: (ctx, c) {
                      _shotViewSize = Size(c.maxWidth, c.maxHeight);
                      return GestureDetector(
                        onPanStart: (d) => setState(() {
                          _dragFrom = d.localPosition;
                          _dragTo = d.localPosition;
                        }),
                        onPanUpdate: (d) =>
                            setState(() => _dragTo = d.localPosition),
                        child: Stack(children: [
                          Positioned.fill(
                            child: Image.memory(_shot!,
                                fit: BoxFit.fill, gaplessPlayback: true),
                          ),
                          if (_dragFrom != null && _dragTo != null)
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _RecRegionWinPainter(
                                    _dragFrom!, _dragTo!),
                              ),
                            ),
                        ]),
                      );
                    }),
                  ),
                ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Row(children: [
          Expanded(
            child: Text(
                region == null
                    ? FloatL10n.t('rec.regionWhole')
                    : '${region['w']} x ${region['h']}  '
                        '(+${region['x']}, +${region['y']})',
                style: const TextStyle(
                    color: Color(0xFF9CCC65), fontSize: 12.5)),
          ),
          TextButton(
            onPressed: () => setState(() {
              _dragFrom = null;
              _dragTo = null;
            }),
            child: Text(FloatL10n.t('rec.regionReset'),
                style: const TextStyle(color: Colors.white54)),
          ),
          const SizedBox(width: 4),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF9575CD),
                foregroundColor: Colors.white),
            icon: const Icon(Icons.fiber_manual_record_rounded, size: 16),
            label: Text(FloatL10n.t('rec.start')),
            onPressed: _startFromRegion,
          ),
        ]),
      ),
    ]);
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// 撮れた動画のプレビュー (この窓の中で再生)。
  Widget _buildPreview() {
    final vc = _pv;
    final ready = vc != null && vc.value.isInitialized;
    final dur = ready ? vc.value.duration : Duration.zero;
    final pos = ready ? vc.value.position : Duration.zero;
    final ratio =
        ready && vc.value.aspectRatio.isFinite && vc.value.aspectRatio > 0.1
            ? vc.value.aspectRatio
            : 16 / 9;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Row(children: [
          const Icon(Icons.movie_rounded, color: Color(0xFF9575CD), size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Text(FloatL10n.t('rec.previewTitle'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded,
                color: Colors.white54, size: 20),
            onPressed: () => unawaited(_closePreview()),
          ),
        ]),
      ),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _pvFailed
              ? Center(
                  child: Text(_previewPath,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12)),
                )
              : !ready
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: Color(0xFF9575CD)))
                  : Center(
                      child: AspectRatio(
                        aspectRatio: ratio,
                        child: ColoredBox(
                          color: Colors.black,
                          child: VideoPlayer(vc),
                        ),
                      ),
                    ),
        ),
      ),
      if (ready)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
          child: Row(children: [
            IconButton(
              icon: Icon(
                  vc.value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 24),
              onPressed: () {
                if (vc.value.isPlaying) {
                  // ignore: discarded_futures
                  vc.pause();
                } else {
                  // ignore: discarded_futures
                  vc.play();
                }
              },
            ),
            Text(_fmtDur(pos),
                style:
                    const TextStyle(color: Colors.white70, fontSize: 11.5)),
            Expanded(
              child: Slider(
                value: dur.inMilliseconds <= 0
                    ? 0
                    : pos.inMilliseconds
                        .clamp(0, dur.inMilliseconds)
                        .toDouble(),
                max: math.max(1, dur.inMilliseconds).toDouble(),
                activeColor: const Color(0xFF9575CD),
                inactiveColor: Colors.white24,
                onChanged: (v) {
                  // ignore: discarded_futures
                  vc.seekTo(Duration(milliseconds: v.round()));
                },
              ),
            ),
            Text(_fmtDur(dur),
                style:
                    const TextStyle(color: Colors.white70, fontSize: 11.5)),
          ]),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
        child: Row(children: [
          Expanded(
            child: Text(_previewPath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: Colors.white38, fontSize: 10.5)),
          ),
          TextButton.icon(
            icon: const Icon(Icons.folder_open_rounded,
                size: 16, color: Color(0xFF9CCC65)),
            label: Text(FloatL10n.t('rec.openFolder'),
                style:
                    const TextStyle(color: Color(0xFF9CCC65), fontSize: 12)),
            onPressed: () {
              try {
                Process.run('explorer',
                    ['/select,', _previewPath.replaceAll('/', '\\')]);
              } catch (_) {}
            },
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: () => unawaited(_closePreview()),
            child: Text(FloatL10n.t('rec.close'),
                style: const TextStyle(color: Colors.white54)),
          ),
        ]),
      ),
    ]);
  }
}

/// 選んだ所以外を暗くする (範囲選び窓用。 本体の _RecRegionPainter と同じ)。
class _RecRegionWinPainter extends CustomPainter {
  final Offset a;
  final Offset b;
  _RecRegionWinPainter(this.a, this.b);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromPoints(a, b);
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    canvas.save();
    canvas.clipRect(r, clipOp: ui.ClipOp.difference);
    canvas.drawRect(Offset.zero & size, dim);
    canvas.restore();
    canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF9575CD));
  }

  @override
  bool shouldRepaint(_RecRegionWinPainter old) => old.a != a || old.b != b;
}

class _CalcWindowApp extends StatefulWidget {
  /// -1 = 単独プロセス (= ショートカットから直接開いた時)。
  final int windowId;
  const _CalcWindowApp({required this.windowId});

  bool get standalone => windowId < 0;
  @override
  State<_CalcWindowApp> createState() => _CalcWindowAppState();
}

class _CalcWindowAppState extends State<_CalcWindowApp> {
  final _WinDragger _dragger = _WinDragger();
  bool _pinned = true;
  Timer? _topTimer;

  /// 電卓の中身の実寸を測るための鍵 (= 窓の高さを中身に合わせる)。
  final GlobalKey _calcBodyKey = GlobalKey();

  /// 窓の高さを中身にぴったり合わせる (= ユーザー報告: 外部モードで
  /// 下に謎のスペースが空く)。 決め打ちの高さをやめて、 描画後に実寸で直す。
  Future<void> _fitToContent() async {
    try {
      final h = _calcBodyKey.currentContext?.size?.height;
      if (h == null || h <= 0) return;
      await windowManager.ensureInitialized();
      final cur = await windowManager.getSize();
      // 34 = 自前ヘッダー、 44 = OS のタイトルバーと枠 (メモ窓と同じ見積もり)。
      await windowManager.setSize(Size(cur.width, h + 34.0 + 44.0));
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitToContent());
    // 他のアプリの上に出し続ける (メモ窓と同じ方式)。
    // ignore: discarded_futures
    _applyTop(true);
    _topTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) {
        _topTimer?.cancel();
        _topTimer = null;
        return;
      }
      // ignore: discarded_futures
      if (_pinned) _applyTop(true);
    });
  }

  Future<void> _applyTop(bool on) async {
    try {
      await windowManager.ensureInitialized();
      try {
        if (await windowManager.isAlwaysOnTop() == on) return;
      } catch (_) {}
      await windowManager.setAlwaysOnTop(on);
    } catch (_) {}
  }

  @override
  void dispose() {
    _topTimer?.cancel();
    _topTimer = null;
    super.dispose();
  }

  /// 閉じる: タイマーを止めてから本体へフォーカスを返して閉じる
  /// (= サブ窓の後始末教訓: タイマー停止漏れが本体巻き添えの原因になる)。
  Future<void> _close() async {
    _topTimer?.cancel();
    _topTimer = null;
    // 単独プロセスなら自分を終わらせる (= ショートカットから開いた時)。
    if (widget.standalone) {
      try {
        Process.killPid(pid);
      } catch (_) {}
      exit(0);
    }
    try {
      await DesktopMultiWindow.invokeMethod(0, 'focusMain');
    } catch (_) {}
    try {
      await WindowController.fromWindowId(widget.windowId).close();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    const acc = Color(0xFF80CBC4);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1B1B2A),
      ),
      home: Scaffold(
        backgroundColor: const Color(0xFF1B1B2A),
        body: Column(children: [
          // ── ドラッグで動かせるタイトル帯 (モーダル移動ループは使わない) ──
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _dragger.start(),
            onPanUpdate: (d) =>
                _dragger.update(d, View.of(context).devicePixelRatio),
            child: Container(
              height: 34,
              color: const Color(0xFF23233A),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                const Icon(Icons.calculate_rounded, color: acc, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(FloatL10n.t('calc.title'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis),
                ),
                // 最前面固定の切替
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(
                      _pinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      color: _pinned ? acc : Colors.white38,
                      size: 15),
                  onPressed: () {
                    setState(() => _pinned = !_pinned);
                    // ignore: discarded_futures
                    _applyTop(_pinned);
                  },
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.close,
                      color: Colors.white54, size: 16),
                  onPressed: () {
                    // ignore: discarded_futures
                    _close();
                  },
                ),
              ]),
            ),
          ),
          // ── 本体 (アプリ内オーバーレイと共通の CalcBody) ──
          Expanded(
            child: SingleChildScrollView(
              child: KeyedSubtree(
                  key: _calcBodyKey, child: const CalcBody()),
            ),
          ),
        ]),
      ),
    );
  }
}

// ─── ストップウォッチ / タイマーの外部窓 (= ユーザー要望: タイマーも外に) ───
//
// 電卓窓と同じ作法: 常に手前 (ピンで切替)、 自前ヘッダーでドラッグ移動、
// 閉じる時はタイマーを全部止めてから本体へフォーカスを返す。
class _TimerWindowApp extends StatefulWidget {
  /// -1 = 単独プロセス (= ショートカットから直接開いた時)。
  final int windowId;

  bool get standalone => windowId < 0;

  /// 0=ストップウォッチ / 1=タイマー / 2=ポモドーロ。
  final int initialTab;
  const _TimerWindowApp({required this.windowId, this.initialTab = 0});
  @override
  State<_TimerWindowApp> createState() => _TimerWindowAppState();
}

class _TimerWindowAppState extends State<_TimerWindowApp> {
  final _WinDragger _dragger = _WinDragger();
  bool _pinned = true;
  Timer? _topTimer;

  /// 0 = ストップウォッチ、 1 = タイマー、 2 = ポモドーロ。
  late int _tab = widget.initialTab.clamp(0, 2);

  // ── ポモドーロ (= ユーザー要望: ポモドーロもフローティングで) ──
  int _pomoWorkMin = 25;
  int _pomoBreakMin = 5;
  bool _pomoOnBreak = false;
  bool _pomoRunning = false;
  int _pomoLeftSec = 25 * 60;
  int _pomoCycles = 0;
  DateTime? _pomoEndsAt;

  // ── ストップウォッチ ──
  final Stopwatch _sw = Stopwatch();

  // ── タイマー (カウントダウン) ──
  int _totalSec = 300;
  int _leftSec = 300;
  bool _running = false;

  /// 時間切れの点滅表示中か。
  bool _done = false;

  /// 表示の更新と残り時間の減算 (0.1 秒刻み)。
  Timer? _tick;
  DateTime? _timerEndsAt;

  void _ensureTick() {
    _tick ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      if (_running && _timerEndsAt != null) {
        final left = _timerEndsAt!.difference(DateTime.now()).inMilliseconds;
        if (left <= 0) {
          _running = false;
          _leftSec = 0;
          _done = true;
          _timerEndsAt = null;
          // 気付けるように音を 1 回鳴らして前面に出す (音は OS 依存)。
          try {
            SystemSound.play(SystemSoundType.alert);
          } catch (_) {}
          // ignore: discarded_futures
          _applyTop(true);
        } else {
          _leftSec = (left / 1000).ceil();
        }
      }
      // ── ポモドーロ: 時間が来たら作業⇄休憩を自動で切り替える ──
      if (_pomoRunning && _pomoEndsAt != null) {
        final left = _pomoEndsAt!.difference(DateTime.now()).inMilliseconds;
        if (left <= 0) {
          if (!_pomoOnBreak) _pomoCycles++;
          _pomoOnBreak = !_pomoOnBreak;
          final nextMin = _pomoOnBreak ? _pomoBreakMin : _pomoWorkMin;
          _pomoLeftSec = nextMin * 60;
          _pomoEndsAt = DateTime.now().add(Duration(minutes: nextMin));
          try {
            SystemSound.play(SystemSoundType.alert);
          } catch (_) {}
          // ignore: discarded_futures
          _applyTop(true);
        } else {
          _pomoLeftSec = (left / 1000).ceil();
        }
      }
      setState(() {});
    });
  }

  Future<void> _applyTop(bool on) async {
    try {
      await windowManager.ensureInitialized();
      try {
        if (await windowManager.isAlwaysOnTop() == on) return;
      } catch (_) {}
      await windowManager.setAlwaysOnTop(on);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _applyTop(true);
    _ensureTick();
    _topTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) {
        _topTimer?.cancel();
        _topTimer = null;
        return;
      }
      // ignore: discarded_futures
      if (_pinned) _applyTop(true);
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _tick = null;
    _topTimer?.cancel();
    _topTimer = null;
    super.dispose();
  }

  /// 閉じる: タイマーを全部止めてから本体へフォーカスを返して閉じる
  /// (= サブ窓の後始末教訓: タイマー停止漏れが本体巻き添えの原因になる)。
  Future<void> _close() async {
    _tick?.cancel();
    _tick = null;
    _topTimer?.cancel();
    _topTimer = null;
    _sw.stop();
    try {
      await DesktopMultiWindow.invokeMethod(0, 'focusMain');
    } catch (_) {}
    try {
      await WindowController.fromWindowId(widget.windowId).close();
    } catch (_) {}
  }

  String _fmtSw(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    final t = (d.inMilliseconds % 1000) ~/ 100;
    return '$m:$s.$t';
  }

  String _fmtSec(int sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _bigBtn(String label, Color color, VoidCallback onTap) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.22),
        foregroundColor: Colors.white,
        minimumSize: const Size(96, 40),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      onPressed: onTap,
      child: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }

  Widget _chip(String label, VoidCallback onTap) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white70,
        side: const BorderSide(color: Colors.white24),
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      onPressed: onTap,
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  @override
  Widget build(BuildContext context) {
    const acc = Color(0xFF4FC3F7);
    final sw = _sw.elapsed;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1B1B2A),
      ),
      home: Scaffold(
        backgroundColor:
            _done ? const Color(0xFF4A1B22) : const Color(0xFF1B1B2A),
        body: Column(children: [
          // ── ドラッグで動かせるタイトル帯 (電卓窓と同じ作法) ──
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _dragger.start(),
            onPanUpdate: (d) =>
                _dragger.update(d, View.of(context).devicePixelRatio),
            child: Container(
              height: 34,
              color: const Color(0xFF23233A),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                const Icon(Icons.timer_rounded, color: acc, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(FloatL10n.t('timer.title'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700),
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  tooltip: FloatL10n.t('float.pin'),
                  icon: Icon(
                      _pinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      color: _pinned ? acc : Colors.white38,
                      size: 15),
                  onPressed: () {
                    setState(() => _pinned = !_pinned);
                    // ignore: discarded_futures
                    _applyTop(_pinned);
                  },
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.close,
                      color: Colors.white54, size: 16),
                  onPressed: () {
                    // ignore: discarded_futures
                    _close();
                  },
                ),
              ]),
            ),
          ),
          // ── ストップウォッチ / タイマーの切替タブ ──
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            child: Row(children: [
              for (final e in [
                (0, FloatL10n.t('timer.stopwatch')),
                (1, FloatL10n.t('timer.countdown')),
                (2, FloatL10n.t('timer.pomodoro')),
              ])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(9),
                      onTap: () => setState(() => _tab = e.$1),
                      child: Container(
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _tab == e.$1
                              ? acc.withValues(alpha: 0.22)
                              : Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                              color:
                                  _tab == e.$1 ? acc : Colors.white12),
                        ),
                        child: Text(e.$2,
                            style: TextStyle(
                                color: _tab == e.$1
                                    ? Colors.white
                                    : Colors.white60,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          Expanded(
            child: _tab == 2
                // ── ポモドーロ (作業⇄休憩を自動でくり返す) ──
                ? Column(mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                          (_pomoOnBreak
                                  ? FloatL10n.t('timer.break')
                                  : FloatL10n.t('timer.work')) +
                              (_pomoCycles > 0 ? '  ×$_pomoCycles' : ''),
                          style: TextStyle(
                              color: _pomoOnBreak
                                  ? const Color(0xFF43B97F)
                                  : const Color(0xFFFF8A80),
                              fontSize: 13,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(_fmtSec(_pomoLeftSec),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 44,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [FontFeature.tabularFigures()])),
                      const SizedBox(height: 8),
                      // 作業・休憩の長さ (分)。 止まっている時に変えられる。
                      Row(mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(FloatL10n.t('timer.work'),
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 11)),
                            const SizedBox(width: 4),
                            _chip('-', () => setState(() {
                                  _pomoWorkMin =
                                      (_pomoWorkMin - 5).clamp(5, 90);
                                  if (!_pomoRunning && !_pomoOnBreak) {
                                    _pomoLeftSec = _pomoWorkMin * 60;
                                  }
                                })),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: Text('$_pomoWorkMin',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12)),
                            ),
                            _chip('+', () => setState(() {
                                  _pomoWorkMin =
                                      (_pomoWorkMin + 5).clamp(5, 90);
                                  if (!_pomoRunning && !_pomoOnBreak) {
                                    _pomoLeftSec = _pomoWorkMin * 60;
                                  }
                                })),
                            const SizedBox(width: 14),
                            Text(FloatL10n.t('timer.break'),
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 11)),
                            const SizedBox(width: 4),
                            _chip('-', () => setState(() {
                                  _pomoBreakMin =
                                      (_pomoBreakMin - 1).clamp(1, 30);
                                })),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: Text('$_pomoBreakMin',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12)),
                            ),
                            _chip('+', () => setState(() {
                                  _pomoBreakMin =
                                      (_pomoBreakMin + 1).clamp(1, 30);
                                })),
                          ]),
                      const SizedBox(height: 12),
                      Row(mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _bigBtn(
                                _pomoRunning
                                    ? FloatL10n.t('timer.stop')
                                    : FloatL10n.t('timer.start'),
                                _pomoRunning
                                    ? const Color(0xFFFF8A80)
                                    : const Color(0xFF43B97F), () {
                              setState(() {
                                if (_pomoRunning) {
                                  _pomoRunning = false;
                                  _pomoEndsAt = null;
                                } else {
                                  _pomoRunning = true;
                                  if (_pomoLeftSec <= 0) {
                                    _pomoLeftSec = _pomoWorkMin * 60;
                                  }
                                  _pomoEndsAt = DateTime.now()
                                      .add(Duration(seconds: _pomoLeftSec));
                                }
                              });
                            }),
                            const SizedBox(width: 10),
                            _bigBtn(FloatL10n.t('timer.reset'),
                                const Color(0xFF7986CB), () {
                              setState(() {
                                _pomoRunning = false;
                                _pomoEndsAt = null;
                                _pomoOnBreak = false;
                                _pomoCycles = 0;
                                _pomoLeftSec = _pomoWorkMin * 60;
                              });
                            }),
                          ]),
                    ])
                : _tab == 0
                // ── ストップウォッチ ──
                ? Column(mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(_fmtSw(sw),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 44,
                              fontWeight: FontWeight.w700,
                              fontFeatures: [
                                FontFeature.tabularFigures()
                              ])),
                      const SizedBox(height: 14),
                      Row(mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _bigBtn(
                                _sw.isRunning
                                    ? FloatL10n.t('timer.stop')
                                    : FloatL10n.t('timer.start'),
                                _sw.isRunning
                                    ? const Color(0xFFFF8A80)
                                    : const Color(0xFF43B97F), () {
                              setState(() =>
                                  _sw.isRunning ? _sw.stop() : _sw.start());
                            }),
                            const SizedBox(width: 10),
                            _bigBtn(FloatL10n.t('timer.reset'),
                                const Color(0xFF7986CB), () {
                              setState(() => _sw.reset());
                            }),
                          ]),
                    ])
                // ── タイマー (カウントダウン) ──
                : Column(mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                          _done
                              ? FloatL10n.t('timer.done')
                              : _fmtSec(_leftSec),
                          style: TextStyle(
                              color: _done
                                  ? const Color(0xFFFF8A80)
                                  : Colors.white,
                              fontSize: _done ? 30 : 44,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ])),
                      const SizedBox(height: 10),
                      // 時間を足すボタン (押すだけで設定できる)。
                      Row(mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _chip('+1', () => setState(() {
                                  _totalSec += 60;
                                  _leftSec += 60;
                                  _done = false;
                                })),
                            const SizedBox(width: 6),
                            _chip('+5', () => setState(() {
                                  _totalSec += 300;
                                  _leftSec += 300;
                                  _done = false;
                                })),
                            const SizedBox(width: 6),
                            _chip('+10', () => setState(() {
                                  _totalSec += 600;
                                  _leftSec += 600;
                                  _done = false;
                                })),
                          ]),
                      const SizedBox(height: 12),
                      Row(mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _bigBtn(
                                _running
                                    ? FloatL10n.t('timer.stop')
                                    : FloatL10n.t('timer.start'),
                                _running
                                    ? const Color(0xFFFF8A80)
                                    : const Color(0xFF43B97F), () {
                              setState(() {
                                if (_running) {
                                  _running = false;
                                  _timerEndsAt = null;
                                } else if (_leftSec > 0) {
                                  _running = true;
                                  _done = false;
                                  _timerEndsAt = DateTime.now()
                                      .add(Duration(seconds: _leftSec));
                                }
                              });
                            }),
                            const SizedBox(width: 10),
                            _bigBtn(FloatL10n.t('timer.reset'),
                                const Color(0xFF7986CB), () {
                              setState(() {
                                _running = false;
                                _timerEndsAt = null;
                                _leftSec = _totalSec;
                                _done = false;
                              });
                            }),
                          ]),
                    ]),
          ),
        ]),
      ),
    );
  }
}
