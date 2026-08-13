import 'dart:async';
import 'dart:math' as math;
import 'dart:io'
    show
        Platform,
        File,
        FileMode,
        Process,
        exit,
        pid,
        HttpServer,
        HttpClient,
        InternetAddress,
        ContentType;
import 'dart:convert';
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
import 'services/home_shortcut_service.dart';
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

  /// 作成時刻 (UNIX ms)。 動画メモの再生位置バッジと同じ位置に時刻を出す。
  final int savedAt;

  /// マップに追加済みなら true (重複追加防止 + 緑の印)。
  bool addedToMap;

  FloatMemoItem({
    required this.id,
    required this.text,
    int? savedAt,
    this.addedToMap = false,
  }) : savedAt = savedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory FloatMemoItem.create(String text) => FloatMemoItem(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        text: text,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'text': text, 'savedAt': savedAt, 'addedToMap': addedToMap};

  static FloatMemoItem? fromJson(Map j) {
    final t = '${j['text'] ?? ''}';
    if (t.trim().isEmpty) return null;
    return FloatMemoItem(
      id: '${j['id'] ?? DateTime.now().microsecondsSinceEpoch}',
      text: t,
      savedAt: j['savedAt'] is num ? (j['savedAt'] as num).toInt() : null,
      addedToMap: j['addedToMap'] == true,
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

  factory FloatMemoBook.create(String name) => FloatMemoBook(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
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
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: FloatingMemoOverlay(),
  ));
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
          if (_aiAnswer.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
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
            ),
        ],
      );

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
              Icon(
                  _mode == 'ai'
                      ? Icons.auto_awesome_rounded
                      : Icons.sticky_note_2_rounded,
                  color: _mode == 'ai'
                      ? const Color(0xFFBA68C8)
                      : const Color(0xFFFFB347),
                  size: 16),
              const SizedBox(width: 6),
              // メモ / AI の切り替え (= ユーザー要望: AI もアプリの外に)。
              IconButton(
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                tooltip: _mode == 'ai'
                    ? FloatL10n.t('memo.title')
                    : FloatL10n.t('memo.openAi'),
                icon: Icon(
                    _mode == 'ai'
                        ? Icons.sticky_note_2_outlined
                        : Icons.auto_awesome_outlined,
                    size: 15,
                    color: Colors.white54),
                onPressed: () {
                  setState(() => _mode = _mode == 'ai' ? 'memo' : 'ai');
                  // ignore: discarded_futures
                  _persistMode();
                },
              ),
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
                  : (_mode == 'ai' ? _buildAiBody() : _buildMemoBody()),
            ),
          ),
          ]),
          // ── 右下のリサイズグリップ (= ユーザー要望: ドラッグで大きさ調整) ──
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) {
                _memoW = (_memoW + d.delta.dx).clamp(180.0, _kMaxW);
                _memoH = (_memoH + d.delta.dy).clamp(160.0, _kMaxH);
                _applyOverlaySize(collapsed: false);
              },
              onPanEnd: (_) {
                setState(() {});
                _persistSize();
              },
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.south_east_rounded,
                    size: 14, color: Colors.white38),
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
    await FloatL10n.load();
    runApp(_FloatingWebWindowApp(url: url));
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
class _MemoWindowApp extends StatefulWidget {
  final int windowId;
  final Map<String, dynamic> args;
  const _MemoWindowApp({required this.windowId, required this.args});

  @override
  State<_MemoWindowApp> createState() => _MemoWindowAppState();
}

class _MemoWindowAppState extends State<_MemoWindowApp> {
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
    _applyAlwaysOnTop(true);
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

  int _inputLineCount() {
    final t = _input.text;
    if (t.isEmpty) return 1;
    return ('\n'.allMatches(t).length + 1).clamp(1, 4);
  }

  Future<void> _applyAlwaysOnTop(bool on) async {
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
                    '${_books[i].name} (${_books[i].items.length})',
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
      final name = await _askText(FloatL10n.t('memo.newBook'),
          initial: '${FloatL10n.t('memo.bookPrefix')} ${_books.length + 1}');
      if (name == null || !mounted) return;
      _book.free = _free.text;
      setState(() {
        _books.add(FloatMemoBook.create(
            name.trim().isEmpty ? '${_books.length + 1}' : name.trim()));
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
    if (_webMode) return;
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
      final res =
          await DesktopMultiWindow.invokeMethod(0, 'floatingMemoAskAi', q);
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
          if (_aiAnswer.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.note_add_outlined,
                    size: 15, color: Color(0xFF43B97F)),
                label: Text(FloatL10n.t('memo.aiKeep'),
                    style: const TextStyle(
                        color: Color(0xFF43B97F), fontSize: 11)),
                onPressed: _keepAiAnswerAsMemo,
              ),
            ),
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
    // Web は読む領域が要るので広げる。
    try {
      final cur = await windowManager.getSize();
      if (cur.height < 520) {
        await windowManager.setSize(Size(cur.width, 560));
      }
    } catch (_) {}
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
      _snack('${FloatL10n.t('memo.openFailed')}: $e',
          color: const Color(0xFFE57373));
      await _closeWeb();
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

  /// 本体側の浮遊 AI パネル (ブラウザ版 AI) を開く。
  /// ふだんは `_enterAiMode` でこの窓の中に AI を出すので使わないが、
  /// 「ブラウザの AI で開きたい」 場合の逃げ道として残してある。
  // ignore: unused_element
  Future<void> _openAiFor(String text) async {
    try {
      await DesktopMultiWindow.invokeMethod(0, 'openFloatingAi', text.trim());
    } catch (_) {
      _snack(FloatL10n.t('memo.openFailed'), color: const Color(0xFFE57373));
    }
  }

  /// Google 検索も同じ理由で本体側の浮遊パネルに委譲する。
  Future<void> _openGoogleFor(String text) async {
    try {
      await DesktopMultiWindow.invokeMethod(0, 'openFloatingWeb',
          'https://www.google.com/search?q=${Uri.encodeComponent(text)}');
    } catch (_) {
      _snack(FloatL10n.t('memo.openFailed'), color: const Color(0xFFE57373));
    }
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
      final raw =
          await DesktopMultiWindow.invokeMethod(0, 'floatingMemoAiModels');
      final m = jsonDecode('$raw') as Map<String, dynamic>;
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
      await DesktopMultiWindow.invokeMethod(
          0, 'floatingMemoSetAiModel', chosen);
      _snack(FloatL10n.t('memo.aiModelSet'));
    } catch (_) {}
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
      final raw = await DesktopMultiWindow.invokeMethod(0, 'floatingMemoPages');
      pages = (jsonDecode('$raw') as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    } catch (_) {}
    if (!mounted || !btnCtx.mounted) return false;
    if (pages.isEmpty) {
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
        await DesktopMultiWindow.invokeMethod(0, 'floatingMemoToNodePage',
            jsonEncode({'text': t, 'pageId': chosen}));
        ok = true;
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
    try {
      await DesktopMultiWindow.invokeMethod(0, 'focusMain');
    } catch (_) {}
    try {
      await WindowController.fromWindowId(widget.windowId).close();
    } catch (_) {}
  }

  @override
  void dispose() {
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
    Widget act(IconData icon, Color color, String label, VoidCallback onTap) =>
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 13, color: color),
              if (label.isNotEmpty) ...[
                const SizedBox(width: 3),
                Text(label,
                    style: TextStyle(
                        color: color,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ],
            ]),
          ),
        );
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
          act(Icons.auto_awesome_rounded, const Color(0xFFBA68C8),
              FloatL10n.t('memo.allToAi'), () {
            final t = _allItemsText().trim();
            if (t.isNotEmpty) _enterAiMode(t);
          }),
          Builder(
            builder: (btnCtx) => act(Icons.library_add_rounded,
                const Color(0xFF43B97F), FloatL10n.t('memo.allToMap'), () {
              // ignore: discarded_futures
              _addAllItemsToMap(btnCtx);
            }),
          ),
          act(Icons.search_rounded, const Color(0xFF4FC3F7),
              FloatL10n.t('memo.googleSearch'), () {
            final t = _allItemsText().trim();
            // ignore: discarded_futures
            if (t.isNotEmpty) _openGoogleFor(t);
          }),
          act(Icons.delete_sweep_rounded, const Color(0xFFE57373), '', () {
            // ignore: discarded_futures
            _clearAllItems();
          }),
        ],
      ),
    );
  }

  /// 一覧の 1 行 (= YouTube の動画メモの履歴項目と同じ作り)。
  /// 時刻バッジ + 本文 + 活用ボタン。 行をクリックすると書き直せる。
  Widget _itemTile(int i) {
    final item = _items[i];
    final text = item.text;
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
          GestureDetector(
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
                        _showAiModelMenu(btnCtx);
                      },
                      onSecondaryTap: () {
                        // ignore: discarded_futures
                        _showAiModelMenu(btnCtx);
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
                          onPressed: () => _enterAiMode(''),
                        ),
                      ),
                    );
                  }),
                // ── 目のボタン: 上のボタン類と下の 3 つをまとめて隠す ──
                //    (= ユーザー要望: メモのアイコンや文字、 AI などの
                //     ボタンも一緒に消えるように)。 これだけは残しておかないと
                //     戻せなくなるので常に出す。
                if (!_webMode && !_aiMode)
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
          if (!_webMode && !_aiMode && _memoMode == 'free' && !_chromeHidden)
            Container(
              height: 36,
              decoration: const BoxDecoration(
                color: Color(0xFF23233A),
                border: Border(
                    top: BorderSide(color: Color(0xFF32324A), width: 1)),
              ),
              child: Row(children: [
                Expanded(
                  // 範囲選択があればその部分だけを AI へ (= ユーザー要望)。
                  // 長押し / 右クリックでモデルを変更 (= ユーザー要望)。
                  child: Builder(builder: (btnCtx) {
                    return GestureDetector(
                      onLongPress: () {
                        // ignore: discarded_futures
                        _showAiModelMenu(btnCtx);
                      },
                      onSecondaryTap: () {
                        // ignore: discarded_futures
                        _showAiModelMenu(btnCtx);
                      },
                      child: Tooltip(
                        message: FloatL10n.t('memo.aiModelHint'),
                        // 長押しをツールチップに食われないようにする
                        // (トリガーは hover のみ)。
                        triggerMode: TooltipTriggerMode.manual,
                        child: TextButton.icon(
                          icon: const Icon(Icons.auto_awesome_rounded,
                              size: 14, color: Color(0xFFBA68C8)),
                          label: Text(FloatL10n.t('memo.toAi'),
                              style: TextStyle(
                                  color: Color(0xFFBA68C8), fontSize: 11)),
                          onPressed: () {
                            final t = _freeTargetText();
                            if (t.isEmpty) return;
                            _enterAiMode(t);
                          },
                        ),
                      ),
                    );
                  }),
                ),
                Expanded(
                  // 範囲選択があればその部分だけを検索 (= ユーザー要望)。
                  child: TextButton.icon(
                    icon: const Icon(Icons.search_rounded,
                        size: 15, color: Color(0xFF4FC3F7)),
                    label: Text(FloatL10n.t('memo.googleSearch'),
                        style: TextStyle(
                            color: Color(0xFF4FC3F7), fontSize: 11)),
                    onPressed: () {
                      final t = _freeTargetText();
                      if (t.isEmpty) return;
                      // ignore: discarded_futures
                      _openGoogleFor(t);
                    },
                  ),
                ),
                Expanded(
                  child: Builder(builder: (btnCtx) {
                    return TextButton.icon(
                      icon: const Icon(Icons.add_to_photos_rounded,
                          size: 14, color: Color(0xFF43B97F)),
                      label: Text(FloatL10n.t('memo.addToMap'),
                          style: TextStyle(
                              color: Color(0xFF43B97F), fontSize: 11)),
                      onPressed: () {
                        final t = _free.text.trim();
                        if (t.isEmpty) return;
                        // ignore: discarded_futures
                        _addToMapWithPicker(btnCtx, [t]);
                      },
                    );
                  }),
                ),
              ]),
            ),
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
class _FloatingWebWindowApp extends StatefulWidget {
  final String url;
  const _FloatingWebWindowApp({required this.url});
  @override
  State<_FloatingWebWindowApp> createState() => _FloatingWebWindowAppState();
}

class _FloatingWebWindowAppState extends State<_FloatingWebWindowApp> {
  final wv_win.WebviewController _ctrl = wv_win.WebviewController();
  bool _ready = false;
  String? _error;
  bool _pinned = false;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _init();
  }

  Future<void> _init() async {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setTitle(widget.url);
      await _ctrl.initialize();
      await _ctrl.loadUrl(widget.url);
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _togglePin() async {
    final next = !_pinned;
    setState(() => _pinned = next);
    try {
      await windowManager.setAlwaysOnTop(next);
    } catch (_) {}
  }

  @override
  void dispose() {
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
        backgroundColor: const Color(0xFF12121C),
        body: Column(children: [
          // ── 上のバー (常に前面 / 再読み込み / 閉じる) ──
          Container(
            height: 34,
            color: const Color(0xFF1A1A2E),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(children: [
              const Icon(Icons.public_rounded,
                  size: 15, color: Color(0xFF4FC3F7)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11)),
              ),
              IconButton(
                tooltip: FloatL10n.t('float.pin'),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: Icon(
                    _pinned
                        ? Icons.push_pin_rounded
                        : Icons.push_pin_outlined,
                    size: 16,
                    color: _pinned ? const Color(0xFF4FC3F7) : Colors.white38),
                onPressed: _togglePin,
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.refresh_rounded,
                    size: 16, color: Colors.white38),
                onPressed: () {
                  // ignore: discarded_futures
                  _ctrl.reload();
                },
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.close_rounded,
                    size: 16, color: Colors.white54),
                onPressed: () {
                  // 別プロセスなので、 自分だけ終わればよい。
                  exit(0);
                },
              ),
            ]),
          ),
          Expanded(
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
        ]),
      ),
    );
  }
}

class _CalcWindowApp extends StatefulWidget {
  final int windowId;
  const _CalcWindowApp({required this.windowId});
  @override
  State<_CalcWindowApp> createState() => _CalcWindowAppState();
}

class _CalcWindowAppState extends State<_CalcWindowApp> {
  final _WinDragger _dragger = _WinDragger();
  bool _pinned = true;
  Timer? _topTimer;

  @override
  void initState() {
    super.initState();
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
          const Expanded(
            child: SingleChildScrollView(
              child: CalcBody(),
            ),
          ),
        ]),
      ),
    );
  }
}
