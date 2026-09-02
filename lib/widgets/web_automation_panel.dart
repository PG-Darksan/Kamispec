// Web ページの自動操作パネル (= ユーザー要望: 「指定した箇所を何回タップ
// やスワイプするか、 ホールドしておく時間などを設定できるように」 +
// 「スクショと自動化を組み合わせて右スワイプして、 ここからここまでスクショ
// 撮るみたいな自動化」)。
//
// 仕組み: WebView へ JS を流し込んで PointerEvent / MouseEvent / TouchEvent
//   を合成する。 スクショはホスト側 (google_search_dialog) が画面キャプチャ
//   して保存する。 手順は SharedPreferences に保存され、 次回も同じ設定で
//   走らせられる。
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform, Process, ProcessResult;
import 'dart:math' as math;
// パソコンの画面を撮った PNG を持っておくのに使う。
import 'dart:typed_data' show Uint8List;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart'
    show
        Clipboard,
        ClipboardData,
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        LogicalKeyboardKey;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// アシスタントからの依頼を受ける合図。
import '../main.dart' show automationRequestFromAssistant;
import '../providers/mind_map_provider.dart';
// パソコンそのものを操作する (= ユーザー要望: PC 内のアプリを操作)。
import '../services/cdp_browser.dart';
import '../services/desktop_input.dart';
import '../services/page_extract_js.dart';
import '../services/page_scroll_js.dart';
import '../services/screen_capture.dart' as scap;
import '../utils/build_flags.dart';
import 'shot_manager_dialog.dart';

/// 1 ステップの種類。
/// 1 ステップの種類。 open = リンクを開く (= ユーザー要望)。
/// 自動操作の手順の種類。
///
/// `click` と `scrollTo` は後から足した (= ユーザー報告: AI に「フッターの
/// スクショを撮って」「Windows 版のタブに切り替えて」 と頼んでも、 途中で
/// 止まったり切り替えられなかったりする)。 原因は AI が座標しか指定できず、
/// 画面に何があるかを知らないまま組み立てていたこと。
///   ・click     … 文字 / セレクタで要素を探して押す (座標が要らない)
///   ・scrollTo  … 一番下 / 一番上まで一気に送る (フッターの撮影が確実になる)
enum WebAutoKind {
  tap,
  hold,
  swipe,
  scroll,
  wait,
  shot,
  type,
  open,
  loop,
  click,
  scrollTo,
  // ── ここから外向けの操作 (= ユーザー要望: アプリの外のブラウザ操作や
  //    ターミナル操作)。 どちらもパソコン版だけ。 ──
  /// 既定のブラウザ (アプリの外) でページを開く。
  openExternal,

  /// パソコンのコマンドを実行する。 実行の可否は設定 (使わない / 毎回
  /// 確認 / 全部任せる) に従う。
  command,

  /// ページの上から下までを 1 枚の縦長画像にする (= ユーザー要望)。
  /// WebView には全面を撮る口が無いので、 1 画面ぶんずつ撮って縦に繋げる。
  fullShot,

  /// フォルダーの中のファイルをページの「ファイル選択」 に渡す
  /// (= ユーザー要望: 自動化でファイルをアップロードしたい /
  /// 繰り返しごとにここからここの範囲を順番に)。
  /// text = フォルダー、 selector = 入れ先の要素、
  /// x = 何番目から (1 始まり)、 y = 何番目まで (0 = 最後まで)。
  upload,

  /// ファイルを 1 つ作る (= ユーザー要望: ファイルを作成して
  /// アップロードしたりできるように)。
  /// selector = ファイル名、 text = 中身。 保存先は automation_files/。
  /// 直後の upload (フォルダー未指定) にそのまま渡せる。
  makeFile,

  // ── ここからは「パソコンそのもの」 を操作する
  //    (= ユーザー要望: アプリ内だけでなく PC 内のアプリを操作したい)。
  //    アプリの中のブラウザではなく、 Windows に直接マウス / キーボードの
  //    信号を送る。 危ないので、 利用者が許した時だけ動く。 Windows 限定。 ──

  /// 窓を前に出す。 text = 題名の一部 (例: 'Chrome')。
  osActivate,

  /// 画面のその場所を押す。 x / y = 画面の座標、 count = 押す回数、
  /// selector = 'right' / 'middle' でボタンを変える。
  osClick,

  /// 画面のその場所へマウスを動かす (押さない)。
  osMove,

  /// 今選ばれている欄に文字を打つ。 text = 打つ内容。
  osType,

  /// キーを同時押しする。 text = 'ctrl+l' のように + でつなぐ。
  osKey,

  /// 画面を縦に転がす。 count = 回す量 (正で上、 負で下)。
  osScroll,

  /// パソコンの画面を撮る (アプリの中ではなく画面全体)。
  osShot,

  /// 利用者に聞いて、 選んでもらうまで待つ
  /// (= ユーザー要望: Chrome のアカウント選択のような、 本人にしか
  ///  決められない所で止まらず、 選んでもらってから先へ進む)。
  ///   text     = 聞く内容 (例: 「どのアカウントでログインしますか?」)
  ///   selector = 選択肢を「|」 で区切って並べる。 空なら「続ける」 だけ。
  ask,

  /// 外のブラウザ (Chrome / Edge / Brave …) を、 操作できる状態で
  /// 開いてつなぐ (= ユーザー要望: PC 内のブラウザを操作)。
  ///
  /// これ以降の手順 (要素を押す / 文字を打つ / 端まで送る…) は、
  /// アプリ内のブラウザではなく **外のブラウザ** に効く。
  ///   text     = どのブラウザか ('chrome' / 'edge' / 'brave' …。 空なら先頭)
  ///   selector = 最初に開く URL (空でもよい)
  ///   submit   = true にすると、 アカウント専用のブラウザで開く
  ///              (初回だけ人がログインすれば、 次からはログイン済み)
  ///   account  = どのアカウントか (呼び名。 空なら既定の 1 つ)
  openBrowser,

  /// ページのダウンロードボタン / リンクを押して、 ファイルを保存する
  /// (= ユーザー要望: スクショ以外のデータも取ってこられるように)。
  ///   text     = 押す物の文字 (例「ダウンロード」)。 空なら selector を使う
  ///   selector = 押す物の CSS。 http で始まる時はその URL を直に落とす
  ///   durationMs = 待つ上限 (既定 60 秒)
  download,

  /// そのページのログとエラー (デバッグログ) を取る
  /// (= ユーザー要望: エラーが起こっている画面のログを取りたい)。
  ///   count = 0 で「集め始める」 だけ。 1 以上で「今まで集めた分を保存」
  consoleLog,

  /// ページの中身 (文字 / 表 / リンク / HTML) を取り出して保存する。
  ///   text     = 何を取るか: 'text' / 'html' / 'table' / 'links'
  ///   selector = 取り出す範囲の CSS (空ならページ全体)
  extract,
}

/// この手順の中に、 インターネットが要る物があるか
/// (= ユーザー要望: つながっていない時に案内を出すため)。
/// 繰り返しの中身も見る。
bool autoStepsNeedNetwork(List<WebAutoStep> steps) {
  const net = {
    WebAutoKind.open,
    WebAutoKind.openExternal,
    WebAutoKind.openBrowser,
    WebAutoKind.download,
  };
  for (final st in steps) {
    if (net.contains(st.kind)) return true;
    if (st.children.isNotEmpty && autoStepsNeedNetwork(st.children)) {
      return true;
    }
  }
  return false;
}

/// 依頼文が「ログインして」 と頼んでいるか。
///
/// = ユーザー要望「プロンプトの中に『〜にログインして』 と含まれていたら
///   最初にログインさせる。 明示しない場合はシークレットモードがいい」。
///   ログインと明示していない時は、 まっさらなシークレット窓で開く
///   (アカウントも使わず、 ログイン画面にも飛ばない)。
bool requestWantsLogin(String request) {
  final r = request.toLowerCase();
  return request.contains('ログイン') ||
      request.contains('サインイン') ||
      request.contains('ログオン') ||
      request.contains('サインオン') ||
      r.contains('log in') ||
      r.contains('login') ||
      r.contains('logon') ||
      r.contains('sign in') ||
      r.contains('signin');
}

/// 依頼文の中のアカウントを見つける。
///
/// = ユーザー報告「chrome を ○○@gmail.com の垢で立ち上げて、 と頼んで
///   いるのに『既定の 1 つ』 で開かれる」。 AI への指示文には書いてあるが、
///   軽いモデルは埋め忘れるので、 こちらでも見つけて必ず入れる。
///
/// [knownNames] はブラウザに入っている呼び名 (「浩靖」 など)。 メールが
/// 書いてあればそちらを優先し、 無ければ呼び名が文の中にあるかを見る。
String accountFromRequest(String request, List<String> knownNames) {
  // ★ 末尾は必ず英字 (= 本物のドメイン)。 これが無いと
  //   `chart.js@4.4.0` のような版の指定まで拾ってしまう。
  //   URL や git の宛先 (`…/x@y.com/…` `git@github.com:…`) も外す。
  final mailRe = RegExp(r'[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}');
  for (final m in mailRe.allMatches(request)) {
    final after = request.substring(m.end);
    if (after.startsWith(':') || after.startsWith('/')) continue;
    final before = request.substring(0, m.start);
    final cut = before.lastIndexOf(RegExp(r'[\s　]'));
    final token = before.substring(cut + 1);
    if (token.contains('://') || token.contains('/')) continue;
    return m.group(0)!;
  }
  for (final n in knownNames) {
    final t = n.trim();
    // 1 文字の呼び名は、 たまたま文に混ざるので使わない。
    if (t.length >= 2 && request.contains(t)) return t;
  }
  return '';
}

/// エージェントが前に進めているかの見張り。
///
/// = ユーザー報告「止まらずに同じフローをひたすら作り続ける」。
///   画面が変わっていないのに次の一手も前と同じなら、 何度やっても
///   結果は同じなので、 そこで打ち切る。 手数の上限 (12 回) だけだと、
///   同じ手順が 12 回ぶん積み上がってしまう。
class AgentProgressGuard {
  String? _prevPlan;
  String? _prevSnap;

  /// 次の一手を受け取る。 進んでいれば true、 足踏みしていれば false。
  bool advance(List<WebAutoStep> steps, String snapshot) {
    final plan = planSignature(steps);
    // 画面は長いので頭だけ見る (末尾は時計などで毎回変わることがある)。
    final snap =
        snapshot.length > 400 ? snapshot.substring(0, 400) : snapshot;
    final same = plan == _prevPlan && snap == _prevSnap;
    _prevPlan = plan;
    _prevSnap = snap;
    return !same;
  }

  /// 手順の中身を 1 本の文字列にする (同じ手かどうかの見分け用)。
  ///
  /// ★ URL は末尾の / や大文字小文字だけの違いを無視する
  ///   (= ユーザー報告: 同じ処理を二回行うフローが作られる。
  ///   1 周目が "https://例.com"、 2 周目が "https://例.com/" だったため
  ///   別物と見なされ、 そのまま積み増されていた)。
  /// ★ 待ち時間・回数・アカウント・入れ子の中身も入れる。 入れないと
  ///   「1 秒待つ」 と「30 秒待つ」、 中身の違う繰り返しが同じ物と見なされ、
  ///   別の手順なのに足踏みと誤判定していた (= 点検で判明)。
  static String planSignature(List<WebAutoStep> steps) =>
      steps.map(_stepSignature).join(';');

  /// 手順 1 つぶんの見分け用の文字。
  ///
  /// ★ 「開く」 系 (open / openExternal / openBrowser) は、 同じ URL なら
  ///   同じ手として扱う。 途中でつなぎ方が変わると、 AI が出す物が
  ///   open ↔ openBrowser で入れ替わり (_coercePcIntent)、 URL の入る場所も
  ///   text ↔ selector で入れ替わるため、 そのままでは同じ手だと気付けない
  ///   (= ユーザー報告: 同じ処理を二回行うフローが生成される)。
  static String _stepSignature(WebAutoStep st) {
    const navKinds = {
      WebAutoKind.open,
      WebAutoKind.openExternal,
      WebAutoKind.openBrowser,
    };
    if (navKinds.contains(st.kind)) {
      final url = st.selector.trim().isEmpty ? st.text : st.selector;
      return 'nav|${normUrlish(url)}|${st.account}';
    }
    return '${st.kind.name}|${normUrlish(st.text)}|'
        '${normUrlish(st.selector)}|${st.scrollDir}|${st.x}|${st.y}|'
        '${st.durationMs}|${st.count}|${st.account}'
        '${st.children.isEmpty ? '' : '[${planSignature(st.children)}]'}';
  }

  /// URL らしき文字を見比べやすい形にそろえる。 URL でなければそのまま。
  static String normUrlish(String v) {
    final t = v.trim();
    if (!t.toLowerCase().startsWith('http')) return t;
    var u = t.toLowerCase();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}

/// コマンド実行の許可の仕方 (= ユーザー要望: 許可を求める・全部任せる)。
///
/// 既定は [off] (使わない)。 危ない操作なので、 ユーザーが自分で
/// 「毎回確認」 か「全部任せる」 に切り替えるまでは一切動かさない。
enum AutoCommandPolicy { off, ask, always }

/// 明らかに壊しにいくコマンドは、 設定に関わらず断る。
///
/// AI にフローを組ませることもできる以上、 「全部任せる」 にしていても
/// 取り返しの付かない操作だけは通さない (= 安全側の線引き)。
/// Microsoft Store 提出用ビルドか (= 画面側と同じ dart-define)。
///
/// ★ 任意のコマンドを実行できる仕組みは、 ストアでは「コード実行」 と
///   みなされる。 ストア版では実行も設定 UI も落とす。

bool isDangerousCommand(String raw) {
  final c = raw.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  const patterns = [
    'format ',
    'del /s',
    'del /f /s',
    'rd /s',
    'rmdir /s',
    'rm -rf /',
    'rm -fr /',
    'mkfs',
    'diskpart',
    'vssadmin delete',
    'wmic shadowcopy delete',
    'reg delete',
    'shutdown',
    'bcdedit',
    'cipher /w',
    ':(){:|:&};:',
  ];
  for (final p in patterns) {
    if (c.contains(p)) return true;
  }
  return false;
}

class WebAutoStep {
  WebAutoKind kind;
  double x;
  double y;
  double x2;
  double y2;

  /// タップ回数 / スクショ枚数。
  int count;

  /// ホールド時間 / スワイプ所要時間 / 待機時間 (ms)。
  int durationMs;

  /// 連続実行の間隔 (ms)。 下限。
  int intervalMs;

  /// 間隔のばらつき幅 (ms)。 1 以上なら 間隔 〜 間隔+この値 の乱数になる
  /// (= ユーザー要望: 間隔は乱数秒を入れられるように)。 0 なら固定。
  int intervalMaxMs;

  /// スクロール方向 (= ユーザー要望: 方向を設定できるように)。
  /// 'down' | 'up' | 'right' | 'left'
  String scrollDir;

  /// どのアカウント (ブラウザのプロファイル) で開くか。 openBrowser 用。
  ///
  /// ★ 以前は scrollDir を借りていたが、 手順を足した時の既定が 'down' な
  ///   ので、 触っていないのに「down というアカウント」 になっていた
  ///   (= ユーザー報告: アカウント名を指定しても、そのアカウントで
  ///   開いてくれない)。 専用の入れ物にする。
  String account;

  /// 入力する文字列 (kind == type)。
  String text;

  /// 入力先の CSS セレクタ (kind == type)。 空なら座標 (x, y) の位置に
  /// ある要素へ入力する。 GUI の「要素を選ぶ」 で自動設定される
  /// (= ユーザー要望: テキストブロックの HTML 要素を GUI で設定したい)。
  String selector;

  /// 入力後に Enter を送るか (検索ボックス等の送信用)。
  bool submit;

  /// 繰り返しブロックの中身 (= ユーザー要望: 繰り返しの中に処理ブロックを
  /// 入れて、 そこから出ると繰り返し終了になるように)。 kind == loop の
  /// 時だけ使う。
  final List<WebAutoStep> children;

  WebAutoStep({
    required this.kind,
    this.x = 0,
    this.y = 0,
    this.x2 = 0,
    this.y2 = 0,
    this.count = 1,
    this.durationMs = 300,
    this.intervalMs = 200,
    this.intervalMaxMs = 0,
    this.scrollDir = 'down',
    this.account = '',
    this.text = '',
    this.selector = '',
    this.submit = false,
    List<WebAutoStep>? children,
  }) : children = children ?? <WebAutoStep>[];

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'x': x,
        'y': y,
        'x2': x2,
        'y2': y2,
        'count': count,
        'durationMs': durationMs,
        'intervalMs': intervalMs,
        'intervalMaxMs': intervalMaxMs,
        'scrollDir': scrollDir,
        'account': account,
        'text': text,
        'selector': selector,
        'submit': submit,
        if (kind == WebAutoKind.loop)
          'children': children.map((e) => e.toJson()).toList(),
      };

  static WebAutoStep fromJson(Map<String, dynamic> j) => WebAutoStep(
        kind: WebAutoKind.values.firstWhere(
          (e) => e.name == (j['kind'] as String? ?? 'tap'),
          // ★ 知らない種類は「待つ」 に倒す (= 以前は tap に化けていた。
          //   tap は座標 (0,0) を押すので、 新しい種類を含むフローを
          //   古い版で開くと画面の左上を連打する手順に変わり、 しかも
          //   保存し直されて元に戻らなかった)。 待機なら害が無い。
          orElse: () => WebAutoKind.wait,
        ),
        x: (j['x'] as num?)?.toDouble() ?? 0,
        y: (j['y'] as num?)?.toDouble() ?? 0,
        x2: (j['x2'] as num?)?.toDouble() ?? 0,
        y2: (j['y2'] as num?)?.toDouble() ?? 0,
        count: (j['count'] as num?)?.toInt() ?? 1,
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 300,
        intervalMs: (j['intervalMs'] as num?)?.toInt() ?? 200,
        intervalMaxMs: (j['intervalMaxMs'] as num?)?.toInt() ?? 0,
        scrollDir: (j['scrollDir'] as String?) ?? 'down',
        account: (j['account'] as String?) ?? '',
        text: (j['text'] as String?) ?? '',
        selector: (j['selector'] as String?) ?? '',
        submit: (j['submit'] as bool?) ?? false,
        children: ((j['children'] as List?) ?? const [])
            .map((e) => WebAutoStep.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

/// 自動操作パネル。 ホスト (検索ダイアログ) から WebView 操作関数を受け取る。
class WebAutomationPanel extends StatefulWidget {
  /// WebView に JS を流す。
  final Future<void> Function(String js) exec;

  /// WebView で JS を評価して結果を文字列で受け取る (= ユーザー要望:
  /// テキストの入力先要素を GUI で選べるように)。 未指定なら要素選択は
  /// 使わず、 座標だけで入力する。
  final Future<String?> Function(String js)? evalJs;

  /// 画面キャプチャして保存し、 保存先パスを返す。 [region] が null なら
  /// WebView 全体。 座標は WebView 内のローカル論理座標。
  final Future<String?> Function(Rect? region) capture;

  /// ページ全体 (上から下まで) を 1 枚の縦長画像として保存し、 パスを返す
  /// (= ユーザー要望)。 渡されていなければ「全体を 1 枚」 の手順は何もしない。
  final Future<String?> Function()? captureFull;

  /// 出来上がった PNG をスクショ置き場に保存し、 保存先パスを返す。
  ///
  /// 外のブラウザ (CDP) で撮った絵はアプリの画面には映らないので、
  /// [capture] の経路を通れない。 保存先の採番はホスト側が持っているため、
  /// バイト列だけ渡して保存してもらう。
  final Future<String?> Function(Uint8List png)? saveShotBytes;

  /// ユーザーにページ上の 1 点をクリックしてもらい、 その座標を返す。
  final Future<Offset?> Function() pickPoint;

  /// 2 点 (矩形) をクリックしてもらう (= 「ここからここまで」)。
  final Future<Rect?> Function() pickRect;

  final VoidCallback onClose;

  /// 実行状態が変わった時に呼ばれる (running, 停止関数)。 親 (フローティング
  /// 窓) が実行中はヘッダーに停止ボタンだけを出すために使う (= ユーザー要望)。
  final void Function(bool running, VoidCallback stop)? onRunningChanged;

  /// 1 回の実行が始まった合図 (保存先フォルダを分けるのに使う)。
  ///
  /// ★ [onRunningChanged] とは別にする。 あちらは「ブラウザを前に出すか」
  ///   も兼ねていて、 見せない実行では呼ばれないため、 保存先を分ける処理も
  ///   一緒に飛んでいた (= スクショが前回の実行のフォルダに混ざる)。
  final Future<void> Function()? onRunStarted;

  /// 操作の記録モードの ON/OFF をホストへ伝える (= ユーザー要望: フローを
  /// 組まなくても操作を覚えて再現できるように)。 ON の間、 ホストは
  /// WebView 上のタップを [WebAutomationPanelController.recordTap] へ流す。
  final void Function(bool recording)? onRecordingChanged;

  /// 見出しの端に「閉じる」 を出すか (= ユーザー要望: 窓いっぱいに
  /// 広げた時は、 外側の帯を出さずこの見出しだけにする)。
  final bool showCloseButton;
  const WebAutomationPanel({
    super.key,
    required this.exec,
    required this.capture,
    required this.pickPoint,
    required this.pickRect,
    required this.onClose,
    this.captureFull,
    this.saveShotBytes,
    this.onRunStarted,
    this.evalJs,
    this.onRunningChanged,
    this.onRecordingChanged,
    this.showCloseButton = false,
  });

  @override
  State<WebAutomationPanel> createState() => WebAutomationPanelState();
}

class WebAutomationPanelState extends State<WebAutomationPanel> {
  static const _prefsKey = 'webAutomationSteps_v1';
  final List<WebAutoStep> _steps = [];

  // ─── 操作の記録 (= ユーザー要望: フローを組まなくても自動で操作を記憶して
  //     再現してくれるように) ───────────────────────────────────────────
  /// 記録中か。
  bool _recording = false;
  bool get isRecording => _recording;

  /// 直前に記録した時刻 (操作の間隔を待機ステップとして残すため)。
  DateTime? _lastRecordAt;

  /// 記録開始時にステップを消したか (= 追記か上書きか)。
  void toggleRecording() {
    setState(() {
      _recording = !_recording;
      _lastRecordAt = _recording ? DateTime.now() : null;
      if (_recording) _status = '';
    });
    widget.onRecordingChanged?.call(_recording);
  }

  void stopRecording() {
    if (!_recording) return;
    setState(() {
      _recording = false;
      _lastRecordAt = null;
    });
    widget.onRecordingChanged?.call(false);
  }

  /// ホストから呼ばれる: WebView 上のタップを 1 件記録して、 そのまま
  /// ページにも流す (= 記録中も普通に操作できるように)。
  Future<void> recordTap(Offset local) async {
    if (!_recording) return;
    setState(() {
      _steps.add(WebAutoStep(
        kind: WebAutoKind.tap,
        x: local.dx,
        y: local.dy,
        // 記録した操作は間を詰めて再生する (= ユーザー要望: 待機時間は
        // 覚えなくてよい / 動作と動作の間はなるべく短く)。
        intervalMs: _kRecordIntervalMs,
      ));
    });
    _save();
    await _tapAt(local.dx, local.dy);
  }

  /// ホストから呼ばれる: スクロール操作を 1 件記録する。
  void recordScroll(double dy) {
    if (!_recording) return;
    setState(() {
      _steps.add(WebAutoStep(
        kind: WebAutoKind.scroll,
        durationMs: dy.abs().round().clamp(60, 2000),
        scrollDir: dy >= 0 ? 'down' : 'up',
        intervalMs: _kRecordIntervalMs,
      ));
    });
    _save();
  }

  /// 記録中にスクショボタンが押された時 (= ユーザー要望: 記録する時は
  /// スクショボタン等が表示されるように)。 実際に 1 枚撮って記録も残す。
  Future<void> recordShot() async {
    setState(() {
      _steps.add(WebAutoStep(
          kind: WebAutoKind.shot, intervalMs: _kRecordIntervalMs));
    });
    _save();
    try {
      await widget.capture(null);
    } catch (_) {}
  }

  /// 記録した操作を再生する時の間隔 (ms)。 = ユーザー要望: 待機時間は
  /// 記録せず、 動作と動作の間はなるべく短く。
  static const int _kRecordIntervalMs = 120;

  /// 全体の繰り返し回数。 = ユーザー要望で設定欄は廃止し、 常に 1 周。
  /// (繰り返したい時は「繰り返し」 ブロックの中に手順を入れる)。
  /// 旧データを読んでも 1 に丸める。
  static const int _loop = 1;
  bool _running = false;
  String _status = '';
  bool _cancel = false;

  // ── これ以上送れない (= 一番下に着いた) 時に、 残りの繰り返しを切り上げる
  //    ための印 (= ユーザー報告: 最後に同じスクショが何枚も並ぶ) ──
  //    _cancel と違い、 その繰り返しを抜けた所で消費して先へ進む。
  bool _loopBreak = false;

  /// 繰り返しの入れ子の深さ (0 = 繰り返しの外)。 0 の時は打ち切らない
  /// (= 単発のスクショ / スクロールは今までどおり必ず動く)。
  int _loopDepth = 0;

  /// 直前のスクロールで読み取った送り位置 (px)。 読めない時は null。
  int? _lastScrollPos;

  /// 最後に撮った時の送り位置。 同じ所を続けて撮らないために使う。
  int? _lastShotPos;

  @override
  void initState() {
    super.initState();
    _load();
    _loadFlows();
    // 前に使った指示 (= ユーザー要望: 呼び出せるように)。
    // ignore: discarded_futures
    _loadAiPrompts();
    // 入力欄の下書きを戻す (= ユーザー要望: 戻ってきた時に空にしない)。
    // ignore: discarded_futures
    _restoreAiDraft();
    // 外向けの設定 (時刻で実行 / コマンドの許可) を読む (= ユーザー要望)。
    // ignore: discarded_futures
    _loadCmdPolicy();
    // ignore: discarded_futures
    _loadSchedule();
    // 2 択 (見方 / フロー) の覚え書き (= ボタンを 1 つにまとめたので、
    //   この 2 択が唯一の設定になった)。
    // ignore: discarded_futures
    _loadAgentOpts();
    // ネットの様子を見張る (= ユーザー要望: つながっていない時だけ、
    //   一番上に分かり易く出す)。 判定そのものは短い間だけ使い回される。
    unawaited(_checkNet());
    _netTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => unawaited(_checkNet()));
    // Esc / Ctrl+C を横取りして「止める」 に使う (= ユーザー要望:
    // Esc で欄が閉じるのをやめ、 実行を止める側に割り当てる)。
    HardwareKeyboard.instance.addHandler(_handleStopKey);
    // AI アシスタントからの依頼を受ける (= ユーザー要望: アシスタントに
    //   chrome を起動させて何かやってと言ったら自律的に動くように)。
    automationRequestFromAssistant.addListener(_onAssistantAutomation);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleStopKey);
    automationRequestFromAssistant.removeListener(_onAssistantAutomation);
    // 外のブラウザとのつながり (WebSocket) を残さない。
    unawaited(_releaseCdp());
    _schedTimer?.cancel();
    _netTimer?.cancel();
    _aiCtrl.dispose();
    super.dispose();
  }

  /// AI アシスタントから「この指示で動かして」 と渡された。
  ///
  /// 入力欄に入れて「画面を見ながら実行」 を走らせる。 許可の判断は今まで
  /// どおり自動操作側 (使わない / 毎回確認 / 全部任せる) が行う。
  void _onAssistantAutomation() {
    final v = automationRequestFromAssistant.value;
    if (v == null || v.trim().isEmpty || !mounted) return;
    // 同じ値で 2 回走らないよう、 受け取ったら消しておく。
    automationRequestFromAssistant.value = null;
    if (_running || _agentBusy || _aiBusy) {
      _log('AI', 'アシスタントからの依頼は、 今の実行が終わるまで受けません');
      return;
    }
    final provider = context.read<MindMapProvider>();
    setState(() {
      _aiCtrl.text = v.trim();
      _aiFormOpen = true;
    });
    _saveAiDraft(_aiCtrl.text);
    _log('AI', 'アシスタントからの依頼: ${v.trim()}');
    // ignore: discarded_futures
    _runAgent(provider, v.trim(), keepSteps: _agentKeepSteps);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_prefsKey);
      if (s == null || s.isEmpty) return;
      final m = jsonDecode(s) as Map<String, dynamic>;
      final list = (m['steps'] as List?) ?? const [];
      _steps
        ..clear()
        ..addAll(list
            .map((e) => WebAutoStep.fromJson(Map<String, dynamic>.from(e))));
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // ── 名前を付けたフローの保存 / 呼び出し (= ユーザー要望) ──
  // prefs `webAutomationFlows_v1` に {名前: 手順} で保存する。
  static const _flowsKey = 'webAutomationFlows_v1';
  Map<String, dynamic> _flows = {};

  Future<void> _loadFlows() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_flowsKey);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is Map) {
        _flows = Map<String, dynamic>.from(m);
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _persistFlows() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_flowsKey, jsonEncode(_flows));
    } catch (_) {}
  }

  // ── 設定の窓は「押した所の近く」 に出す (= ユーザー要望: 画面の真ん中だと
  //    ボタンから遠い)。 ヘッダーを押した位置を控えておく。 ──
  Offset? _lastPointerPos;

  /// 窓を二重に開かないための鍵。
  ///
  /// ★ = ユーザー報告: 「保存したフローを開く」 を連打すると、
  ///   押した分だけポップアップが積み上がる。 このファイルの窓は
  ///   全部この鍵を共有する。
  bool _modalOpen = false;

  /// 押した所の近くに出すダイアログ。 位置が分からない時は今までどおり中央。
  Future<T?> _showNearDialog<T>(
      {required WidgetBuilder builder, double maxWidth = 420.0}) async {
    if (_modalOpen) return null;
    _modalOpen = true;
    final at = _lastPointerPos;
    try {
      return await showDialog<T>(
      // ★ 一番近い Navigator に出す (= ユーザー報告: 浮かせた窓から
      //   開くと、 窓の裏のアプリ本体に出てしまう)。 浮遊窓は根っこの
      //   Overlay に挿されているので、 既定の useRootNavigator: true だと
      //   窓の下に隠れる。 他の開き方では一番近い = 根っこなので
      //   今までどおり。
      useRootNavigator: false,
      context: context,
      builder: (dctx) {
        if (at == null) return builder(dctx);
        final screen = MediaQuery.of(dctx).size;
        // 画面からはみ出さないように寄せる。
        final w = math.min(maxWidth, screen.width - 24.0);
        const h = 360.0;
        final left = (at.dx - w / 2)
            .clamp(12.0, math.max(12.0, screen.width - w - 12))
            .toDouble();
        // 押した所のすぐ下に出す。 下が足りなければ上へ。
        var top = at.dy + 14;
        if (top + h > screen.height - 12) {
          top = math.max(12.0, at.dy - h - 14);
        }
        return Stack(children: [
          Positioned(
            left: left,
            top: top,
            width: w,
            child: Material(
              type: MaterialType.transparency,
              child: MediaQuery.removeViewInsets(
                context: dctx,
                removeTop: true,
                removeBottom: true,
                child: Builder(builder: builder),
              ),
            ),
          ),
        ]);
      },
    );
    } finally {
      _modalOpen = false;
    }
  }

  /// 白紙から作り直す (= ユーザー要望: 新しいフローを作るボタンが無いので、
  /// 作りたい時に既存の手順を書き換えることになってしまう)。
  ///
  /// 手順が残っている時は一度確かめる。 保存済みのフロー (📂) は消えない。
  Future<void> _newFlow(MindMapProvider provider) async {
    if (_steps.isNotEmpty) {
      final ok = await _showNearDialog<bool>(
        builder: (dctx) => AlertDialog(
          backgroundColor: const Color(0xFF2A2A3E),
          title: Text(provider.t('auto.flowNew'),
              style: const TextStyle(color: Colors.white, fontSize: 15)),
          content: Text(provider.t('auto.flowNewConfirm'),
              style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(provider.t('common.cancel'),
                  style: const TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8D86FF),
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(dctx, true),
              child: Text(provider.t('auto.flowNew')),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (!mounted) return;
    setState(() {
      _steps.clear();
      _stepSel.clear();
      _selAnchorList = null;
      _selAnchorIndex = -1;
      _status = provider.t('auto.flowNewDone');
    });
    await _save();
  }

  /// 今の手順に名前を付けて保存する。
  Future<void> _saveFlowAs(MindMapProvider provider) async {
    // ── 既定の名前を入れておく (= ユーザー要望: 毎回名前を考えるのが手間) ──
    //    「フロー 1」 のように順に付け、 既にある名前は飛ばす。 全部を選んだ
    //    状態で出すので、 別の名前にしたい人はそのまま打てば置き換わる。
    final prefix = provider.t('auto.flowNamePrefix');
    var n = _flows.length + 1;
    var auto = '$prefix $n';
    while (_flows.containsKey(auto)) {
      n++;
      auto = '$prefix $n';
    }
    final ctrl = TextEditingController(text: auto)
      ..selection = TextSelection(baseOffset: 0, extentOffset: auto.length);
    final name = await _showNearDialog<String>(
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: Text(provider.t('auto.flowSaveTitle'),
            style: const TextStyle(color: Colors.white, fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: provider.t('auto.flowNameHint'),
            hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.06),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none),
          ),
          onSubmitted: (v) => Navigator.pop(dctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(provider.t('common.cancel'),
                style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(dctx, ctrl.text.trim()),
            child: Text(provider.t('auto.flowSave')),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    _flows[name] = {
      'steps': _steps.map((e) => e.toJson()).toList(),
    };
    await _persistFlows();
    if (!mounted) return;
    setState(() => _status =
        provider.t('auto.flowSaved').replaceFirst('{name}', name));
  }

  /// 保存済みフローを読み込む / 削除するメニュー。
  Future<void> _showFlowMenu(MindMapProvider provider) async {
    if (_flows.isEmpty) {
      setState(() => _status = provider.t('auto.flowNone'));
      return;
    }
    final names = _flows.keys.toList()..sort();
    final sel = await _showNearDialog<String>(
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A3E),
        title: Text(provider.t('auto.flowLoadTitle'),
            style: const TextStyle(color: Colors.white, fontSize: 15)),
        content: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final n in names)
              ListTile(
                dense: true,
                title: Text(n,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 13)),
                onTap: () => Navigator.pop(dctx, n),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline_rounded,
                      size: 17, color: Colors.redAccent),
                  onPressed: () async {
                    _flows.remove(n);
                    await _persistFlows();
                    if (dctx.mounted) Navigator.pop(dctx);
                    if (mounted) setState(() {});
                  },
                ),
              ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(provider.t('common.cancel'),
                style: const TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
    if (sel == null) return;
    final data = _flows[sel];
    if (data is! Map) return;
    setState(() {
      _steps
        ..clear()
        ..addAll(((data['steps'] as List?) ?? const [])
            .map((e) => WebAutoStep.fromJson(Map<String, dynamic>.from(e))));
      _status = provider.t('auto.flowLoaded').replaceFirst('{name}', sel);
    });
    _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey,
          jsonEncode({
            'steps': _steps.map((e) => e.toJson()).toList(),
          }));
    } catch (_) {}
  }

  // ── AI でフローを作る (= ユーザー要望: Google 検索の自動化のフロー作成で
  //    AI に指示を出して手順を組み立てられるように) ──
  bool _aiBusy = false;

  /// AI 入力欄を開いているか。
  ///
  /// = ユーザー要望「AI でフロー作成のボタンを押さなくても、 指示を書く欄が
  ///   出ているように」。 既定で開いておき、 ヘッダーのボタンと「キャンセル」
  ///   が畳む役になる。
  bool _aiFormOpen = true;

  /// コマンド実行の欄を開いているか (= ユーザー要望: 肝心のフローの
  /// 表示領域が小さいので、 上の欄をたためるように)。
  bool _cmdOpen = true;

  /// 手順を足すボタンの一覧を開いているか (= ユーザー要望)。
  bool _chipsOpen = true;

  /// 時刻で実行の欄を開いているか (= ユーザー要望: ここもたためるように)。
  /// たたんでいる間も、 入 / 切と要約の 1 行は見えたままにする。
  bool _schedOpen = true;

  /// 手順一覧の高さを人が決めた時の値 (= ユーザー要望: 境界をドラッグして
  /// フローの表示領域を広げられるように)。 null = 自動 (畳み具合から計算)。
  double? _stepsH;

  final TextEditingController _aiCtrl = TextEditingController();

  /// 入力欄の下書きを覚えておく鍵 (= ユーザー要望: 戻ってきた時に
  /// プロンプト欄が空にならないように)。 画面の作り替えで State が
  /// 作り直されても、 ここから戻せば消えない。
  static const String _kAiDraftKey = 'webauto_ai_draft_v1';

  /// 下書きを保存する (打つたびに呼ぶので、 失敗は握り潰す)。
  void _saveAiDraft(String v) {
    // ignore: discarded_futures
    SharedPreferences.getInstance()
        .then((sp) => sp.setString(_kAiDraftKey, v))
        .catchError((_) => false);
  }

  Future<void> _restoreAiDraft() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getString(_kAiDraftKey) ?? '';
      if (v.isNotEmpty && mounted && _aiCtrl.text.isEmpty) {
        _aiCtrl.text = v;
      }
    } catch (_) {}
  }

  /// 前に使った指示 (= ユーザー要望: フロー作成に使ったプロンプトを覚えて
  /// おいて呼び出せるように)。 prefs `autoAiPrompts` に古い順で持つ。
  List<String> _aiPrompts = [];
  static const String _kAiPromptsKey = 'autoAiPrompts';

  Future<void> _loadAiPrompts() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final list = sp.getStringList(_kAiPromptsKey) ?? const [];
      if (mounted) setState(() => _aiPrompts = List<String>.from(list));
    } catch (_) {}
  }

  /// 使った指示を覚える (同じ物は 1 つに。 20 件まで)。
  void _rememberAiPrompt(String v) {
    final t = v.trim();
    if (t.isEmpty) return;
    final list = List<String>.from(_aiPrompts)
      ..remove(t)
      ..add(t);
    while (list.length > 20) {
      list.removeAt(0);
    }
    setState(() => _aiPrompts = list);
    // ignore: discarded_futures
    SharedPreferences.getInstance()
        .then((sp) => sp.setStringList(_kAiPromptsKey, list))
        .catchError((_) => false);
  }

  /// フロー作成で使うモデルを選ぶ (= ユーザー要望: ここでも設定したい)。
  /// AI アシスタント等と同じ設定 (relayModel) を共有する。
  Widget _buildAiModelPicker(MindMapProvider provider) {
    String label(String id) => id.replaceAll(RegExp(r'-\d{8}$'), '');
    final models = [
      for (final m in provider.relayModels)
        if (m is Map && m['available'] == true) m
    ];
    return PopupMenuButton<String>(
      tooltip: provider.t('mcp.model'),
      color: const Color(0xFF1E1E32),
      onSelected: (id) async {
        await provider.setRelayModel(id);
        if (mounted) setState(() {});
      },
      itemBuilder: (_) => [
        for (final m in models)
          PopupMenuItem<String>(
            value: '${m['id']}',
            child: Row(children: [
              Icon(
                  '${m['id']}' == provider.relayModel
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 13,
                  color: '${m['id']}' == provider.relayModel
                      ? const Color(0xFFBA68C8)
                      : Colors.white38),
              const SizedBox(width: 8),
              Text(label('${m['id']}'),
                  style:
                      const TextStyle(color: Colors.white, fontSize: 12)),
            ]),
          ),
        if (models.isEmpty)
          PopupMenuItem<String>(
            enabled: false,
            child: Text(label(provider.relayModel),
                style:
                    const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.memory_rounded, size: 13, color: Colors.white54),
          const SizedBox(width: 5),
          Text(label(provider.relayModel),
              style: const TextStyle(color: Colors.white70, fontSize: 10.5)),
          const Icon(Icons.expand_more_rounded,
              size: 13, color: Colors.white38),
        ]),
      ),
    );
  }

  /// 今開いているページの中身を短くまとめて返す (AI に見せる用)。
  ///
  /// = ユーザー報告「フッターのスクショを頼むと途中で止まる」「タブに
  ///   切り替えてと頼んでも切り替えてくれない」。 原因は AI が画面に何が
  ///   あるかを知らないまま、 座標 0 のタップを並べていたこと。 押せる物の
  ///   文字を渡せば、 click で名指しできる。
  Future<String> _pageSnapshot() async {
    // ★ _eval を通す (= 以前は widget.evalJs 直呼びで、 外のブラウザに
    //   つないでいても **アプリの中のブラウザ**の中身を AI に見せていた。
    //   AI から見ると外の Chrome は真っ白なので、 ページを読む手順を選べず、
    //   画面を撮る類の手順へ逃げていた = ユーザー報告)。
    try {
      final js = '(function(){'
          'var out={url:location.href,title:document.title,'
          ' scrollY:Math.round(window.scrollY),'
          ' viewH:Math.round(window.innerHeight),'
          ' pageH:Math.round(document.body?document.body.scrollHeight:0),'
          ' items:[]};'
          'var seen={};'
          'var cand=document.querySelectorAll('
          ' "a,button,[role=button],[role=tab],input,summary");'
          'for(var i=0;i<cand.length&&out.items.length<60;i++){'
          ' var c=cand[i];'
          ' var r=c.getBoundingClientRect();'
          ' if(!r||(r.width<=1&&r.height<=1)) continue;'
          ' var t=(c.innerText||c.textContent||c.getAttribute("aria-label")'
          '  ||c.getAttribute("placeholder")||c.value||"").'
          '  replace(/\\s+/g," ").trim();'
          ' if(!t||t.length>60) continue;'
          ' if(seen[t]) continue; seen[t]=1;'
          ' out.items.push({t:t,tag:c.tagName.toLowerCase()});'
          '}'
          'var hs=document.querySelectorAll("h1,h2");'
          'out.heads=[];'
          'for(var k=0;k<hs.length&&out.heads.length<12;k++){'
          ' var ht=(hs[k].innerText||"").replace(/\\s+/g," ").trim();'
          ' if(ht) out.heads.push(ht);'
          '}'
          'return JSON.stringify(out);'
          '})();';
      final r = await _eval(js);
      if (r == null) return '';
      // WebView によっては引用符で包まれて返る。
      var s = r.trim();
      if (s.startsWith('"') && s.endsWith('"') && s.length > 1) {
        try {
          s = jsonDecode(s) as String;
        } catch (_) {}
      }
      return s.length > 4000 ? s.substring(0, 4000) : s;
    } catch (_) {
      return '';
    }
  }

  /// AI に渡す手順の書き方 (フロー作成とエージェントで共通)。
  static const String _kFlowFormatRules = '''
{"steps":[
 {"kind":"open","text":"https://example.com/","durationMs":2500},
 {"kind":"click","text":"Windows 版","durationMs":1200},
 {"kind":"scrollTo","scrollDir":"bottom","durationMs":1200},
 {"kind":"scroll","scrollDir":"down","durationMs":0,"count":1,"intervalMs":600},
 {"kind":"wait","durationMs":1000},
 {"kind":"type","text":"入力する文字","selector":"","submit":true},
 {"kind":"shot","count":1},
 {"kind":"tap","x":0,"y":0,"count":1,"intervalMs":200},
 {"kind":"makeFile","selector":"memo.txt","text":"ファイルの中身"},
 {"kind":"upload","text":"","selector":"input[type=file]"},
 {"kind":"loop","count":8,"children":[{"kind":"scroll","scrollDir":"down","durationMs":0},{"kind":"wait","durationMs":400},{"kind":"shot","count":1}]}
]}

ルール:
- kind は openBrowser / open / click / scrollTo / scroll / wait / shot /
  fullShot / download / consoleLog / extract / type / tap / hold / swipe /
  loop / makeFile / upload / openExternal / command / osActivate /
  osClick / osMove / osType / osKey / osScroll / osShot / ask のみ。
- **スクショ以外のデータも取れる**:
    {"kind":"download","text":"ダウンロード"}     押して保存する
    {"kind":"download","selector":"https://…/a.pdf"}  URL を直に保存
    {"kind":"consoleLog","count":0}              ログを集め始める
    {"kind":"consoleLog","count":1}              集めた分を保存する
    {"kind":"extract","text":"text"}             本文を取り出して保存
    {"kind":"extract","text":"table","selector":"table"}  表を CSV で保存
    {"kind":"extract","text":"links"}            リンクの一覧を保存
    {"kind":"extract","text":"html","selector":"#main"}   HTML を保存
  「エラーが出ていないか見て」 と頼まれたら、 ページを開く**前**に
  {"kind":"consoleLog","count":0} を置き、 操作の後に
  {"kind":"consoleLog","count":1} を置いてください。
- **shot は「今つないでいるページ」 のスクショ**。 openBrowser でつないで
  いる間は**外のブラウザのそのページ**が撮れる。 「スクショを撮って」
  「画面を撮って」 と言われたら、 原則これを使う。
- **頼まれていない手順を足さないこと**。 依頼に書かれた事だけを並べる。
  「念のため画面を撮る」「とりあえずキーを押す」 は不要。
- **中身が決まらない手順は出さないこと**。 osActivate は窓の題名、
  osKey はキー、 osClick は座標が必ず要る。 空のまま置かない
  (空の手順は捨てられる)。
- 本人にしか決められない所 (ログインするアカウントの選択、 二段階認証、
  同意画面など) に来たら、 そこで止めずに
  {"kind":"ask","text":"どのアカウントでログインしますか?"} を置く。
  画面で選んでもらってから、 その次の手順へ進む。
  選択肢を出せる時は selector に「A|B|C」 のように並べる。
- **「パソコンの」「PC の」「Chrome で」「外のブラウザで」 と言われたら、
  open を使ってはいけない**。 open は**アプリの中のブラウザ**で開くだけ。
  その時は **openBrowser** を使う:
    {"kind":"openBrowser","text":"chrome","selector":"https://example.com/"}
  これで外のブラウザが「操作できる状態」 で開き、 **以降の
  click / type / scrollTo / shot / 端まで送る はすべてその外のブラウザに
  効く**。 座標は要らない。 いつもどおり文字で要素を指せばよい。
    ・text  … chrome / edge / brave / vivaldi / opera (空なら入っている先頭)
    ・selector … 開く URL
    ・**既定はシークレット (まっさらな窓)**。 ふつうは account も submit も
      付けないでください。 その場合はシークレットで開き、 ログイン画面には
      飛びません。
    ・依頼に**はっきり「ログインして」「サインインして」**と書かれている
      時だけ、 account にアカウントの呼び名 (画面に出ている名前。 例「浩靖」)
      を入れ、 submit を true にしてください。 「○○の垢で」 とだけ書いて
      あってもログインとは限らないので、 「ログイン」 の言葉が無ければ
      シークレットのままにします。
  ★ Chrome の決まりで、 **普段使っているブラウザのログインは
    持ってこられない**。 アカウント専用のブラウザは初回だけ人が
    ログインする必要がある (次からはログイン済みで開く)。 ログイン画面に
    来たら {"kind":"ask","text":"ログインしてから続けてください"} を置く。
  ページを見せるだけで操作が要らないなら openExternal でよい。
- **「chrome を立ち上げて ○○ のスクショを撮って」 は、 これで足りる**:
    {"kind":"openBrowser","text":"chrome","selector":"https://…",
     "durationMs":2500}
    {"kind":"shot","count":1}
  os で始まる手順も command も要らない。 窓を前に出す必要も無い。
- **os で始まる手順は最後の手段**。 ブラウザの中で済むこと
  (ページを開く / 押す / 文字を打つ / スクショ) は、 外のブラウザでも
  **openBrowser + click / type / scrollTo / shot** でできる。 os 系は
  ブラウザでは届かない物 (エクスプローラー、 OS のダイアログ、
  ブラウザ以外のアプリ) にだけ使う。
- **ページの見た目が欲しいだけの時に osShot / osActivate を使わないこと**。
  アプリの窓まで写り込むうえ、 座標を測る必要も無い。
- os で**押す・打つ手順 (osClick / osType / osKey)** を出す時だけ、
  その直前に {"kind":"osShot"} を置いて座標を確かめること。
    {"kind":"osActivate","text":"メモ帳"}          窓を前に出す
    {"kind":"osShot"}                              画面を撮る (座標を測る用)
    {"kind":"osClick","x":100,"y":200,"count":1}   画面のその点を押す
    {"kind":"osType","text":"打つ文字"}             今の入力欄に打つ
    {"kind":"osKey","text":"ctrl+l"}               同時押し (+ でつなぐ)
    {"kind":"osScroll","count":-3}                 負で下、 正で上
  x / y は**画面全体の座標**(左上が 0,0)。 ページの中の座標ではない。
  座標が分からないまま osClick を書かないこと (関係ない所を押してしまう)。
- **アップロードを試す時は、 投稿欄が実際にあるサイトを選ぶこと**。
  example.com のような説明用のページには入力欄が無く、 何も起きない。
- **ファイルを作って渡す時は makeFile → upload の 2 手順**。
  makeFile は selector にファイル名、 text に中身 (文字だけ)。
  upload は text を空にしておけば、 直前に作ったファイルをそのまま
  ページの「ファイル選択」 に入れる (selector は入れ先の要素。
  分からなければ空でよい = 最初の input[type=file])。
  フォルダーの中身を順に渡したい時だけ upload の text にフォルダーを書く。
- openExternal は「アプリの外の既定ブラウザで開く」。 アプリの中で見れば
  済む時は open を使い、 外で開いてと明示された時だけ openExternal。
- command は「パソコンのコマンドを実行」。 **ユーザーがコマンドの実行を
  はっきり頼んだ時だけ** 使う。 消す・初期化する・電源を切るなどの
  取り返しの付かない操作は書かないこと。
- **押す操作は必ず click を使い、 text に画面に見えている文字をそのまま
  書く** (例: {"kind":"click","text":"Windows 版"})。 tap は座標が要るので
  基本的に使わない。 下の「今の画面」 に出ている文字から選ぶこと。
- ページの一番下 (フッター) へ行くには {"kind":"scrollTo","scrollDir":"bottom"}
  を使う。 一番上へ戻るのは "top"。 少しずつ送るのが scroll。
- 「フッターを撮って」 の類は scrollTo(bottom) → wait → shot の 3 手順で足りる。
  スクロールの回数を当てにいかないこと。
- **1 枚の縦長画像で欲しい**と言われたら {"kind":"fullShot"} を 1 つ置く
  (ページの上から下まで自分で送りながら撮り、 1 枚に繋げる)。 open の
  直後に置けば足りる。 scroll や loop と組み合わせない。
- 「上から下まで全部撮って」 で**複数枚**が良い時は
  loop(children: scroll(down, durationMs:0) → wait(400) → shot) を使い、
  count は 【今の画面】 の pageH ÷ viewH を切り上げた数 + 1 にする
  (分からなければ 10)。
- **scroll の durationMs は「送る量(px)」。 0 = 1 画面ぶん** (少しだけ重ねて
  送る)。 スクショと組み合わせる時は必ず 0 にすること。 px を決め打ちすると
  同じ所ばかり写る。
- open は「そのページを開く」。 text に URL、 durationMs に読み込み待ち (ms)。
- scrollDir は down / up / right / left (scrollTo では bottom / top)。
- steps は 30 個以内。''';

  /// 今どちらで開くか (シークレット / ○○でログイン) の目印。
  ///
  /// = ユーザー要望「ログインと明示しない時はシークレット」。 アカウントも
  ///   印も無ければシークレット、 あればそのアカウントでログインして開く。
  Widget _openModeBadge(MindMapProvider provider, WebAutoStep s) {
    final login = s.submit || s.account.trim().isNotEmpty;
    final acct = s.account.trim();
    final text = login
        ? (acct.isEmpty
            ? provider.t('auto.openLogin')
            : '${provider.t('auto.openLogin')}: $acct')
        : provider.t('auto.openIncognito');
    final color =
        login ? const Color(0xFF43B97F) : const Color(0xFF9FA8DA);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(login ? Icons.login_rounded : Icons.visibility_off_rounded,
            size: 12, color: color),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(color: color, fontSize: 10, height: 1.1)),
      ]),
    );
  }

  /// どのアカウントで開くかの選択 (= ユーザー要望:
  /// アカウントを指定してログイン)。
  ///
  /// 普段の Chrome に入っている呼び名をそのまま並べる。 選んだ
  /// アカウントごとに自動操作専用のブラウザを持つ。
  Widget _acctPicker(MindMapProvider provider, WebAutoStep s) {
    final kind = CdpBrowserKindName.fromText(s.text) ??
        (CdpBrowser.installed().isNotEmpty
            ? CdpBrowser.installed().first
            : CdpBrowserKind.chrome);
    final names = CdpBrowser.listProfiles(kind)
        .map((p) => p.name)
        .where((n) => n.trim().isNotEmpty)
        .toList();
    final cur = s.account.trim();
    // ★ 一覧はブラウザに入っている呼び名だけなので、 AI が書いたメール
    //   などは選べず「既定の 1 つ」 に見えていた (= ユーザー報告)。
    //   一覧に無い時は、 その値そのものを 1 行足して見せる。
    if (cur.isNotEmpty && !names.contains(cur)) names.insert(0, cur);
    return SizedBox(
      width: 170,
      child: DropdownButtonFormField<String>(
        initialValue: names.contains(cur) ? cur : '',
        dropdownColor: const Color(0xFF23233A),
        style: const TextStyle(color: Colors.white, fontSize: 12),
        decoration: _fieldDeco(provider.t('auto.acctLabel')),
        items: [
          DropdownMenuItem(
              value: '',
              child: Text(provider.t('auto.acctDefault'),
                  style: const TextStyle(fontSize: 12))),
          for (final n in names)
            DropdownMenuItem(
                value: n,
                child: Text(n, style: const TextStyle(fontSize: 12))),
        ],
        onChanged: (v) {
          setState(() => s.account = v ?? '');
          _save();
        },
      ),
    );
  }

  /// 手順の小さな入力欄の見た目 (このファイルで何度も同じ形を書くため)。
  InputDecoration _fieldDeco(String label) => InputDecoration(
        isDense: true,
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54, fontSize: 10),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.06),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide.none),
      );

  /// 手順を全部消す (= ユーザー要望: 一括削除してクリアにするボタン)。
  /// 押し間違いが痛いので一度だけ確かめる。
  Future<void> _clearAllSteps(MindMapProvider provider) async {
    if (_steps.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      // ★ 浮かぶ窓の中から出す時は、 根っこの Navigator を使わない
      //   (= ユーザー報告: 確認が自動化の枠の下に出てしまう)。 根っこに
      //   出すと、 Overlay に載っているこの窓の方が上に来て隠れる。
      useRootNavigator: false,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E32),
        title: Text(provider.t('auto.clearAll'),
            style: const TextStyle(color: Colors.white, fontSize: 15)),
        content: Text(
            provider
                .t('auto.clearAllBody')
                .replaceFirst('{n}', '${_steps.length}'),
            style: const TextStyle(
                color: Colors.white70, fontSize: 13, height: 1.6)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(provider.t('common.cancel'),
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(provider.t('auto.clearAllDo'),
                style: const TextStyle(color: Color(0xFFE57373))),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _steps.clear();
      _status = provider.t('auto.clearedAll');
    });
    await _save();
  }

  /// 依頼が「パソコンのアプリを操作したい」 内容かどうか。
  ///
  /// 「PC 内の chrome を起動させて」 と頼んでいるのに、 AI が
  /// アプリの中のブラウザで開く手順 (open) を出してくることがある
  /// (= ユーザー報告)。 説明文で止めても軽いモデルは従わないので、
  /// 依頼の言葉から機械的に判断して手順を直す。
  static bool _wantsPcApp(String request) {
    final r = request.toLowerCase();
    const words = [
      'pc内', 'pcの', 'pc の', 'パソコン', 'デスクトップ', '外のブラウザ',
      '外部ブラウザ', '別のブラウザ', 'chrome', 'クローム', 'edge', 'エッジ',
      'firefox', 'ファイアフォックス', 'ブラウザアプリ', 'アプリを起動',
      '起動させて', '立ち上げて',
    ];
    return words.any(r.contains);
  }

  /// 依頼文に出てくるブラウザの名前 (無ければ null)。
  ///
  /// = ユーザー報告「CDP が実装できているのに、 スクショを指示していない
  ///   のに『パソコンの画面を撮る』 が作られる」。 ブラウザの話なら
  ///   OS 操作ではなく CDP (openBrowser) へ寄せるための判定。
  static String? _browserNameIn(String request) {
    final r = request.toLowerCase();
    // ★ 名前だけで決めない (= 「オペラを見に行く予定」「エッジの効いた
    //   デザイン」 のような、 ブラウザと関係ない文でブラウザを起動して
    //   しまうため)。 ブラウザの話らしさが無ければ拾わない。
    const context = [
      'ブラウザ', 'browser', '立ち上げ', '起動', '開い', '開く',
      'url', 'http', 'タブ', 'サイト', 'ページ', 'ログイン', '検索',
    ];
    final looksBrowser = context.any(r.contains);
    // 英字の名前は前後が区切れている時だけ (= 語の一部に埋もれた
    //   「edge」「opera」 を拾わない)。
    bool word(String w) =>
        RegExp(r'(^|[^a-z0-9])' + w + r'([^a-z0-9]|$)').hasMatch(r);
    const latin = ['chrome', 'edge', 'brave', 'vivaldi', 'opera'];
    for (final n in latin) {
      if (word(n) && looksBrowser) return n;
    }
    // 片仮名は取り違えの少ない物だけ。
    if (r.contains('クローム') || r.contains('グーグルクローム')) return 'chrome';
    if (r.contains('エッジ') && looksBrowser) return 'edge';
    // 名前は無いが「外のブラウザ」 とは言っている。
    const generic = [
      '外のブラウザ', '外部ブラウザ', '別のブラウザ', 'ブラウザアプリ',
      'パソコンのブラウザ', 'pcのブラウザ', 'pc のブラウザ',
    ];
    if (generic.any(r.contains)) return '';
    return null;
  }

  /// この依頼は「ブラウザの話」 か (= OS 操作ではなく CDP で足りるか)。
  static bool _wantsPcBrowser(String request) =>
      _browserNameIn(request) != null;

  /// パソコンの画面そのものを撮ってほしいと言われているか。
  /// (ページではなく、 デスクトップ全体の話をしている時だけ true)
  static bool _wantsOsScreenshot(String request) {
    final r = request.toLowerCase();
    const words = [
      'パソコンの画面', 'pcの画面', 'pc の画面', 'デスクトップの画面',
      '画面全体', 'デスクトップ全体', '画面ごと',
    ];
    return words.any(r.contains);
  }

  /// パソコンのアプリを操作する依頼の時だけ、 今どんな窓が開いているかと、
  /// 画面の大きさを AI に渡す (= ユーザー要望: 外部アプリを立ち上げて
  /// 操作しながら見せる)。 これが無いと、 AI は座標も窓の名前も分からず
  /// 入っているアカウントの呼び名を AI に見せる (= 呼び名が分からないと、
  /// メールをそのまま書いてしまい、 一覧から選べない形になる)。
  String _profileHint(String request) {
    if (!_isDesktopHost) return '';
    // ★ ログインの指定も垢の名指しも無い時は、 シークレットで開く。
    //   アカウントの呼び名は勧めない (= ユーザー要望: 明示しなければ
    //   シークレット)。 ここだけ古い判定のままだと、 後ろで account を
    //   入れる依頼にも「シークレットで開け」 と指示してしまう。
    if (!_wantsLogin(request)) {
      return 'ログインの指定が無いので、 account も submit も付けず、'
          ' シークレットで開いてください。\n';
    }
    final out = <String>[];
    for (final kind in CdpBrowser.installed()) {
      for (final p in CdpBrowser.listProfiles(kind)) {
        final n = p.name.trim();
        if (n.isEmpty) continue;
        out.add(p.account.trim().isEmpty ? n : '$n (${p.account.trim()})');
      }
      if (out.isNotEmpty) break;
    }
    if (out.isEmpty) return '';
    return 'このパソコンに入っているアカウントの呼び名: ${out.join(' / ')}\n'
        '依頼にアカウントが書いてあれば account にこの呼び名を入れ、'
        ' submit も true にしてください。\n';
  }

  /// アプリの中のブラウザで済ませようとしてしまう。
  String _pcContext(String request) {
    if (!_wantsPcApp(request) || !_isDesktopHost) return '';
    // ★ ブラウザの話なら OS 操作の案内を出さない (= ユーザー報告:
    //   スクショを指示していないのに「パソコンの画面を撮る」 が作られる)。
    //   外のブラウザは CDP でページの中身がそのまま触れるので、
    //   座標も画面キャプチャも要らない。
    final browserPart = !_wantsPcBrowser(request)
        ? ''
        : (() {
            final name = _browserNameIn(request);
            return '''

【外のブラウザ】 この依頼は**パソコンのブラウザ**の話です。
${_profileHint(request)}
アプリの中のブラウザで開く open は使わないでください。 かわりに
{"kind":"openBrowser","text":"${name == null || name.isEmpty ? 'chrome' : name}","selector":"https://…"}
で開けば、 そこから先の click / type / scrollTo / shot は**すべてその
外のブラウザに効きます**。 座標も画面キャプチャも要りません。
**ブラウザの中で済むこと**に os で始まる手順や command を使わないでください。
''';
          })();
    // ★ ブラウザの話だからといって、 ここで打ち切らない
    //   (= 「chrome で調べてメモ帳に貼って」 のような混ざった依頼で、
    //   画面の大きさも窓の一覧も渡らなくなる)。
    if (!DesktopInput.isSupported) return browserPart;
    try {
      final b = DesktopInput.screenBounds();
      final wins = DesktopInput.listWindows()
          .map((w) => w.title)
          .where((t) => t.trim().isNotEmpty)
          .take(20)
          .toList();
      return '''$browserPart

【パソコンの画面】 これは**アプリの外**の話です。
- 画面の大きさ: ${b.width} x ${b.height} (左上が 0,0)
- いま開いている窓: ${wins.isEmpty ? '(取れませんでした)' : wins.join(' / ')}
ブラウザ以外のアプリを動かす時は、 アプリの中のブラウザで開く
open は使わないでください。 起動は {"kind":"command","text":"start notepad"}
のように書き、 窓を前に出すのは {"kind":"osActivate","text":"メモ帳"}、
押す・打つ前に {"kind":"osShot"} を置いて座標を確かめてください。
''';
    } catch (_) {
      return browserPart;
    }
  }

  /// パソコンのアプリを操作する依頼なのに、 アプリの中で開く手順に
  /// なっている時は、 外のブラウザで開く手順に直す。
  ///
  /// ★ 説明文への追記だけでは軽いモデルが従わなかったため、 出てきた
  ///   手順そのものを直す (= ユーザー報告: PC 内の chrome を起動させてと
  ///   言っているのにアプリ内でブラウザを立ち上げてしまう)。
  /// 中身が空で意味を成さない手順を落とす。
  ///
  /// ★ AI が「窓を前に出す (題名なし)」「キーを押す (キーなし)」 のような
  ///   空の手順を並べてくることがある (= ユーザー報告: 指示していない事が
  ///   フローに入る)。 実行しても何も起きないか、 関係ない所を触るので、
  ///   ここで捨てる。 何を捨てたかは画面に出す。
  List<WebAutoStep> _dropEmptySteps(List<WebAutoStep> steps) {
    final dropped = <String>[];
    bool keep(WebAutoStep s) {
      switch (s.kind) {
        case WebAutoKind.osActivate:
          // 題名が無いとどの窓か決まらない。
          if (s.text.trim().isEmpty) return false;
          return true;
        case WebAutoKind.osKey:
          if (s.text.trim().isEmpty) return false;
          return true;
        case WebAutoKind.osType:
        case WebAutoKind.type:
          if (s.text.trim().isEmpty) return false;
          return true;
        case WebAutoKind.osClick:
        case WebAutoKind.osMove:
          // 座標が両方 0 = どこを押すか決まっていない。
          if (s.x.abs() < 0.5 && s.y.abs() < 0.5) return false;
          return true;
        case WebAutoKind.open:
        case WebAutoKind.openExternal:
        case WebAutoKind.command:
          if (s.text.trim().isEmpty) return false;
          return true;
        case WebAutoKind.openBrowser:
          // どのブラウザも URL も無いと、 空のタブが開くだけになる。
          if (s.text.trim().isEmpty && s.selector.trim().isEmpty) return false;
          return true;
        case WebAutoKind.download:
          // 押す物も URL も無いと、 何を落とすか決まらない。
          if (s.text.trim().isEmpty && s.selector.trim().isEmpty) return false;
          return true;
        case WebAutoKind.makeFile:
          if (s.selector.trim().isEmpty) return false;
          return true;
        case WebAutoKind.click:
          if (s.text.trim().isEmpty && s.selector.trim().isEmpty) return false;
          return true;
        default:
          return true;
      }
    }

    final out = <WebAutoStep>[];
    for (final s in steps) {
      if (s.kind == WebAutoKind.loop) {
        s.children
          ..clear()
          ..addAll(_dropEmptySteps(List<WebAutoStep>.from(s.children)));
      }
      if (keep(s)) {
        out.add(s);
      } else {
        dropped.add(_kindLabel(context.read<MindMapProvider>(), s.kind));
      }
    }
    if (dropped.isNotEmpty && mounted) {
      Future.microtask(() {
        if (!mounted) return;
        setState(() => _status = context
            .read<MindMapProvider>()
            .t('auto.droppedEmpty')
            .replaceFirst('{list}', dropped.toSet().join(' / ')));
      });
    }
    return out;
  }

  /// 依頼文の中のアカウント (メール、 またはブラウザに入っている呼び名)。
  ///
  /// = ユーザー報告「chrome を ○○@gmail.com の垢で立ち上げて、 と頼んで
  ///   いるのに『既定の 1 つ』 で開かれる」。 AI への指示文には書いてある
  ///   が、 軽いモデルは埋め忘れる。 こちらでも見つけて必ず入れる。
  static String accountIn(String request) {
    final names = <String>[];
    if (_isDesktopHost) {
      for (final kind in CdpBrowser.installed()) {
        for (final p in CdpBrowser.listProfiles(kind)) {
          if (p.name.trim().isNotEmpty) names.add(p.name.trim());
          if (p.account.trim().isNotEmpty) names.add(p.account.trim());
        }
      }
    }
    return accountFromRequest(request, names);
  }

  /// 「その垢で」 と言っている言い回し。
  static final RegExp _acctWordRe = RegExp(
      r'垢|アカウント|プロファイル|プロフィール|account|profile',
      caseSensitive: false);

  /// この依頼はログインした状態で動かす物か。
  ///
  /// 「ログイン」 と書いてある時だけでなく、 **アカウントを名指しして
  /// いる時**もそう扱う (= ユーザー報告: 「chrome を ○○@gmail.com の垢で
  /// 立ち上げて」 と頼んでいるのに、 シークレット窓で開いてログイン画面が
  /// 出てこない)。 垢を指定するのは、 その人として使いたいという事。
  ///
  /// ★ 「@ が入っている」 だけでは名指しにしない。 `chart.js@4.4.0` や
  ///   `git@github.com` のような物、 ページの入力欄へ打ち込みたい宛先まで
  ///   拾ってしまい、 関係の無い依頼をログイン画面で止めていた
  ///   (= 点検で判明)。 次のどちらかの時だけ名指しと見る:
  ///   ・「垢 / アカウント / プロファイル」 と一緒に書かれている
  ///   ・このパソコンのブラウザに実際に入っているアカウントと一致する
  bool _wantsLogin(String request) {
    if (requestWantsLogin(request)) return true;
    final acct = accountIn(request);
    if (acct.isEmpty) return false;
    if (_acctWordRe.hasMatch(request)) return true;
    return _isKnownBrowserAccount(acct);
  }

  /// このパソコンのブラウザに入っているアカウント (呼び名 / メール) か。
  static bool _isKnownBrowserAccount(String acct) {
    if (!_isDesktopHost) return false;
    final a = acct.trim().toLowerCase();
    if (a.isEmpty) return false;
    try {
      for (final kind in CdpBrowser.installed()) {
        for (final p in CdpBrowser.listProfiles(kind)) {
          if (p.account.trim().toLowerCase() == a) return true;
          if (p.name.trim().toLowerCase() == a) return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// 見つけたアカウントを、 外のブラウザを開く手順へ入れる。
  /// 既に入っている物は触らない (AI が正しく埋めた時はそのまま)。
  List<WebAutoStep> _applyAccountIntent(
      String request, List<WebAutoStep> steps) {
    // ★ ログインも垢の指定も無い時は、 シークレットで開く。 AI が勝手に
    //   account / submit を付けていたら**外す** (= ユーザー要望: 明示
    //   しなければシークレット。 軽いモデルが付けてしまう事があるため)。
    if (!_wantsLogin(request)) {
      void strip(List<WebAutoStep> list) {
        for (final st in list) {
          if (st.kind == WebAutoKind.openBrowser) {
            st.account = '';
            st.submit = false;
          }
          if (st.children.isNotEmpty) strip(st.children);
        }
      }

      strip(steps);
      return steps;
    }
    final acct = accountIn(request);
    if (acct.isEmpty) return steps;
    void walk(List<WebAutoStep> list) {
      for (final s in list) {
        if (s.kind == WebAutoKind.openBrowser && s.account.trim().isEmpty) {
          s.account = acct;
          // そのアカウント専用のブラウザで開く (= ログインを保てる)。
          s.submit = true;
        }
        if (s.children.isNotEmpty) walk(s.children);
      }
    }

    walk(steps);
    return steps;
  }

  List<WebAutoStep> _coercePcIntent(String request, List<WebAutoStep> steps) {
    steps = _dropEmptySteps(steps);
    // ★ アカウントの指定は、 パソコン操作の依頼かどうかに関わらず入れる
    //   (= 下の早い戻りより前に置く)。
    steps = _applyAccountIntent(request, steps);
    if (!_wantsPcApp(request)) return steps;
    if (!_isDesktopHost) return steps;
    var changed = false;
    // ブラウザの話なら、 操作できる形 (openBrowser) で開く。
    //   openExternal は「開くだけ」 で中身に触れないので、 続く
    //   click / shot がアプリの中のブラウザへ飛んでしまっていた。
    final browser = _browserNameIn(request);
    final viaCdp = browser != null;
    // ★ すでに外のブラウザへつないでいるなら、 open を
    //   openBrowser には直さない。 直すとブラウザを立ち上げ直して
    //   しまい、 1 手ずつ進める途中で毎回新しい窓が開く。
    //   つながっている間の open は、 そのまま外のブラウザの
    //   ページ移動になる (_exec が CDP へ送る)。
    final cdpLive = _cdp != null && !_cdp!.isClosed;
    // 「開いて見せるだけ」 なら openExternal のまま (= 普段のブラウザで
    //   開いた方が、 ログインもお気に入りもそのままで都合がよい)。
    //   後にページを触る手順が続く時だけ、 操作できる形で開き直す。
    const needsControl = {
      WebAutoKind.click,
      WebAutoKind.type,
      WebAutoKind.scroll,
      WebAutoKind.scrollTo,
      WebAutoKind.shot,
      WebAutoKind.fullShot,
      WebAutoKind.upload,
      WebAutoKind.tap,
      WebAutoKind.swipe,
      WebAutoKind.hold,
    };
    bool anyControl(List<WebAutoStep> list) => list.any((s) =>
        needsControl.contains(s.kind) ||
        (s.kind == WebAutoKind.loop && anyControl(s.children)));
    final willControl = anyControl(steps);
    final out = <WebAutoStep>[];
    for (final s in steps) {
      if (s.kind == WebAutoKind.open || s.kind == WebAutoKind.openExternal) {
        if (viaCdp &&
            !cdpLive &&
            (s.kind == WebAutoKind.open || willControl)) {
          if (s.kind == WebAutoKind.open || s.selector.trim().isEmpty) {
            s.selector = s.text.trim();
          }
          s.text = browser.isEmpty ? 'chrome' : browser;
          // submit は種類ごとに意味が違う (type=Enter で送信 /
          //   openBrowser=そのアカウント専用で開く)。 持ち越さない。
          s.submit = false;
          s.kind = WebAutoKind.openBrowser;
          // ★ ログインを頼まれた時 / 垢を名指しされた時だけ、 アカウントを
          //   入れる (= それ以外はシークレットで開く)。
          if (_wantsLogin(request)) {
            final acct = accountIn(request);
            if (acct.isNotEmpty && s.account.trim().isEmpty) {
              s.account = acct;
              s.submit = true;
            }
          }
        } else if (s.kind == WebAutoKind.open && !cdpLive) {
          // つないでいる間の open は、 そのまま外のブラウザのページ移動に
          //   なる (_exec が CDP へ送る)。 ここで openExternal に直すと、
          //   別の窓が開いて操作先とページがずれる。
          s.kind = WebAutoKind.openExternal;
        }
        changed = true;
      }
      out.add(s);
    }
    // ★ ブラウザで済む依頼なのに OS の画面を撮る / 窓を前に出す手順が
    //   混ざっていたら落とす (= ユーザー報告: スクショと指示していない
    //   のに「パソコンの画面を撮る」 が入る)。 本当に画面全体が欲しい
    //   と言われている時だけ残す。
    if (viaCdp && !_wantsOsScreenshot(request)) {
      // この回の手順に openBrowser が無くても、 すでにつながって
      //   いるなら同じ (= 1 手ずつ進める時は、 開くのは最初の回だけ)。
      final hasBrowser =
          cdpLive || out.any((s) => s.kind == WebAutoKind.openBrowser);
      // ★ 押す・打つ手順が 1 つでも残るなら、 窓を前に出す手順
      //   (osActivate) と座標を測る手順 (osShot) を落としてはいけない。
      //   落とすと「どの窓に打つか」 が決まらないまま入力だけが走り、
      //   前面のブラウザなど関係ない所へ文字が飛ぶ (= 点検で判明)。
      const osPressKinds = {
        WebAutoKind.osClick,
        WebAutoKind.osMove,
        WebAutoKind.osType,
        WebAutoKind.osKey,
        WebAutoKind.osScroll,
      };
      final hasOsPress = out.any((s) => osPressKinds.contains(s.kind));
      if (hasBrowser && !hasOsPress) {
        final kept = <WebAutoStep>[];
        var dropped = false;
        for (final s in out) {
          if (s.kind == WebAutoKind.osShot ||
              s.kind == WebAutoKind.osActivate) {
            dropped = true;
            continue;
          }
          kept.add(s);
        }
        if (dropped) {
          changed = true;
          out
            ..clear()
            ..addAll(kept);
        }
      }
    }
    if (changed && mounted) {
      // 直したことを黙って済ませない (何が起きたか分かるように)。
      Future.microtask(() {
        if (mounted) {
          setState(() => _status = context.read<MindMapProvider>()
              .t('auto.coercedToExternal'));
        }
      });
    }
    return out;
  }

  /// 欄を確定する (= ユーザー要望: Enter で AI のフロー作成が走る)。
  void _submitAiPrompt(MindMapProvider provider) {
    if (_aiBusy || _agentBusy || _running) return;
    final v = _aiCtrl.text;
    if (v.trim().isEmpty) return;
    _rememberAiPrompt(v);
    // ボタンと同じ経路にする (= 以前は Enter だけ「組み立てるだけ」 の
    //   古い経路へ行っていた)。
    unawaited(_runAgent(provider, v, keepSteps: _agentKeepSteps));
  }

  /// 入力欄の中身で組み立てる。 呼ぶ前に欄は閉じる。
  ///
  /// ★ 今は画面から呼んでいない (= ユーザー要望でボタンを実行 1 つに
  ///   まとめ、 実行しながら手順も残る _runAgent に一本化した)。
  ///   組み立てだけの動きが要る時にすぐ戻せるよう、 残してある。
  // ignore: unused_element
  Future<void> _aiBuildFlowFrom(MindMapProvider provider, String request) async {
    final req = request.trim();
    if (req.isEmpty || !mounted) return;
    setState(() {
      _aiBusy = true;
      _status = '…';
    });
    try {
      // 今の画面を見せてから組み立ててもらう (= ユーザー報告への対処)。
      final snap = await _pageSnapshot();
      final prompt = '''
あなたは Web ページの自動操作フローを作る道具です。
次の依頼を、 下の形式の JSON だけで出力してください
(説明文・コードフェンス・前置きは一切不要)。

$_kFlowFormatRules
${snap.isEmpty ? '' : '''

【今の画面】 (url / title / 押せる物の文字 items / 見出し heads)
$snap'''}

依頼: $req''';
      final out = (await provider.askAi(prompt)).trim();
      // AI の返事を残す (= ユーザー要望: 自動化の所でも AI からの
      //   メッセージを見たい)。 何を考えたのかが後から追える。
      _noteAiMessage(out);
      var body = out;
      final fence = RegExp(r'```[a-zA-Z]*\s*\n([\s\S]*?)\n?```');
      final fm = fence.firstMatch(body);
      if (fm != null) body = fm.group(1) ?? body;
      final s = body.indexOf('{');
      final e = body.lastIndexOf('}');
      if (s < 0 || e <= s) throw Exception(provider.t('aiflow.failed'));
      final m = jsonDecode(body.substring(s, e + 1));
      final list = (m is Map ? m['steps'] : null);
      if (list is! List || list.isEmpty) {
        throw Exception(provider.t('aiflow.failed'));
      }
      final steps = _coercePcIntent(req, [
        for (final j in list)
          if (j is Map) WebAutoStep.fromJson(Map<String, dynamic>.from(j)),
      ]);
      if (steps.isEmpty) throw Exception(provider.t('aiflow.failed'));
      if (!mounted) return;
      setState(() {
        _steps
          ..clear()
          ..addAll(steps);
        _status = provider
            .t('auto.aiDone')
            .replaceFirst('{n}', '${steps.length}');
      });
      await _save();
    } catch (e) {
      if (mounted) {
        setState(
            () => _status = '$e'.replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _aiBusy = false);
    }
  }

  /// セレクタ、 無ければ見えている文字で要素を探して押す JS。
  ///
  /// ページ内リンク / ボタン / タブの切り替えは、 座標より文字で探す方が
  /// 確実 (= ユーザー報告: 「Windows 版のタブに切り替えて」 が効かない)。
  String _clickByJs(String selector, String text) {
    final sel = jsonEncode(selector.trim());
    final want = jsonEncode(text.trim());
    return '(function(){'
        'var sel=$sel, want=$want, el=null;'
        'if(sel){try{el=document.querySelector(sel);}catch(e){}}'
        'if(!el&&want){'
        // 押せそうな物から、 表示されていて文字が一致する要素を探す。
        ' var cand=document.querySelectorAll('
        '  "a,button,[role=button],[role=tab],input[type=submit],'
        '[onclick],summary,li,label");'
        ' var norm=function(s){return String(s||"").replace(/\\s+/g," ").trim()'
        '  .toLowerCase();};'
        ' var w=norm(want), exact=null, partial=null;'
        ' for(var i=0;i<cand.length;i++){'
        '  var c=cand[i];'
        '  var r=c.getBoundingClientRect();'
        '  if(!r||(r.width<=0&&r.height<=0)) continue;'
        '  var t=norm(c.innerText||c.textContent||c.getAttribute("aria-label")'
        '   ||c.getAttribute("title")||c.value);'
        '  if(!t) continue;'
        '  if(t===w){exact=c;break;}'
        '  if(!partial&&t.indexOf(w)>=0&&t.length<w.length+40){partial=c;}'
        ' }'
        ' el=exact||partial;'
        '}'
        'if(!el) return "notfound";'
        'try{el.scrollIntoView({block:"center",behavior:"instant"});}catch(e){'
        ' try{el.scrollIntoView();}catch(e2){}}'
        'try{el.focus();}catch(e){}'
        'try{el.click();return "ok";}catch(e){}'
        // click() が効かない作りの物 (JS で拾っている等) には合成イベントを送る。
        'try{var r=el.getBoundingClientRect();'
        ' var x=r.left+r.width/2, y=r.top+r.height/2;'
        ' var o={clientX:x,clientY:y,bubbles:true,cancelable:true,'
        '  composed:true,view:window};'
        ' el.dispatchEvent(new MouseEvent("mousedown",o));'
        ' el.dispatchEvent(new MouseEvent("mouseup",o));'
        ' el.dispatchEvent(new MouseEvent("click",o));'
        '}catch(e){}'
        'return "ok";'
        '})();';
  }

  // ── AI エージェント (= ユーザー要望: 開いている画面をリアルタイムに見な
  //    がら自動化を進められないか) ────────────────────────────────────
  /// エージェントで動かしているか。
  bool _agentBusy = false;

  /// 途中で止めるための合図。
  bool _agentStop = false;

  /// エージェントがやった事を手順として残すか (= ユーザー要望: 後でも使える
  /// フローにするか、 その場かぎりで実行させるかを選べるように)。
  /// 切っている時は、 走らせる前の手順を終わったら元に戻す。
  bool _agentKeepSteps = true;

  /// 2 択 (見方 / フロー) の覚え書き。
  ///
  /// = ボタンを 1 つにまとめたことで、 この 2 択が唯一の設定になった。
  ///   毎回既定に戻ると押し直す手間が増えるので、 覚えておく。
  static const String _kAgentPrefsKey = 'webauto_agent_opts_v1';

  /// もう人が触ったか (= 読み込みが遅れて選んだ側を上書き
  /// しないように)。
  bool _agentOptsTouched = false;

  Future<void> _loadAgentOpts() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kAgentPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      final headless = m['headless'];
      final keep = m['keep'];
      // 欄の開き具合も覚えておく (= ユーザー要望: たためるように)。
      final aiOpen = m['aiOpen'];
      final cmdOpen = m['cmdOpen'];
      final chipsOpen = m['chipsOpen'];
      final schedOpen = m['schedOpen'];
      final stepsH = m['stepsH'];
      // 待っている間に選ばれていたら、 そちらを優先する。
      if (!mounted || _agentOptsTouched) return;
      setState(() {
        if (headless is bool) _agentHeadless = headless;
        if (keep is bool) _agentKeepSteps = keep;
        if (aiOpen is bool) _aiFormOpen = aiOpen;
        if (cmdOpen is bool) _cmdOpen = cmdOpen;
        if (chipsOpen is bool) _chipsOpen = chipsOpen;
        if (schedOpen is bool) _schedOpen = schedOpen;
        if (stepsH is num && stepsH > 0) _stepsH = stepsH.toDouble();
      });
    } catch (_) {}
  }

  Future<void> _saveAgentOpts() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
          _kAgentPrefsKey,
          jsonEncode({
            'headless': _agentHeadless,
            'keep': _agentKeepSteps,
            'aiOpen': _aiFormOpen,
            'cmdOpen': _cmdOpen,
            'chipsOpen': _chipsOpen,
            'schedOpen': _schedOpen,
            if (_stepsH != null) 'stepsH': _stepsH,
          }));
    } catch (_) {}
  }

  /// うまく進めなかった理由を画面に出す (= ユーザー報告: 何も作られない
  /// まま戻ってきた)。 黙って抜けると、 何が起きたのか分からない。
  void _agentFail(MindMapProvider provider, String key, String detail) {
    if (!mounted) return;
    final d = detail.trim();
    final tail = d.isEmpty
        ? ''
        : ' / ${d.length > 160 ? '${d.substring(0, 160)}…' : d}';
    // 失敗は記録にも残す (= ユーザー要望: 開発のテストに使いたい)。
    //   画面の 1 行と違い、 こちらは返事の全文を残す。
    _log('失敗', provider.t(key) + (d.isEmpty ? '' : '\n    $d'));
    setState(() => _status = provider.t(key) + tail);
  }

  /// 画面を見ながら、 1 手ずつ考えて実行する。
  ///
  /// 先に全部組み立てる「フロー作成」 と違い、 毎回いまの画面を見てから
  /// 次の 1 手を決めるので、 「フッターまで行けたか」「タブが切り替わったか」
  /// を確かめながら進められる。 やった手順はフローとして残るので、 後から
  /// 手直しして繰り返し実行できる。
  /// 「ページを開いて見る」 だけの手順で出来ているか。
  ///
  /// = ユーザー報告「同じ処理を二回行うフローが生成されてしまう」。
  ///   開く・端まで送るは何度やっても結果が同じなので、 直前の回と
  ///   そっくり同じ物が出てきたら「やる事はもう無い」 と見てよい。
  ///   待つ (wait) は入れない — 待ち直しには意味がある。
  ///   繰り返し (loop) も入れない — 中で何をするか分からない。
  static bool _navigationOnly(List<WebAutoStep> steps) {
    const kinds = {
      WebAutoKind.open,
      WebAutoKind.openExternal,
      WebAutoKind.openBrowser,
      WebAutoKind.scrollTo,
    };
    return steps.isNotEmpty && steps.every((s) => kinds.contains(s.kind));
  }

  Future<void> _runAgent(MindMapProvider provider, String request,
      {bool keepSteps = true}) async {
    final req = request.trim();
    if (req.isEmpty || !mounted || _agentBusy) return;
    // ★ AI に聞くので、 まずネットを確かめる (= ユーザー要望: つながって
    //   いない時は、 その旨を出してほしい)。
    if (!await provider.hasInternet()) {
      if (!mounted) return;
      _agentFail(provider, 'net.offline', '');
      return;
    }
    // その場かぎり (= 残さない) の時のために、 今の手順を控えておく。
    final before = List<WebAutoStep>.from(_steps);
    setState(() {
      _agentBusy = true;
      _agentStop = false;
      // ★ 前に止めた印を持ち越さない (= 一度止めると、 次からは 12 回
      //   AI に聞くだけで何も実行されなくなっていた)。
      _cancel = false;
      _cdpLost = false;
      _steps.clear();
      // 前回作ったファイルは引き継がない (= 古い物を渡さない)。
      _madeFiles.clear();
      _status = provider.t('agent.thinking');
    });
    // ★ 実行中だと伝える (= ユーザー要望: 画面を見ながら実行している
    //   間はブラウザも見えるように)。 これを呼ばないと、 手順を並べて実行した
    //   時だけブラウザが出て、 AI に任せて動かしている間は隠れたままだった。
    //
    // ★ ただし「パソコンのアプリを操作して」 という依頼の時は出さない
    //   (= ユーザー報告: 画面を見ながら実行を押すとアプリ内部のブラウザを
    //    立ち上げようとする)。 見せたいのは PC の本物のアプリの方なので、
    //    アプリ内ブラウザを前に出すとかえって隠してしまう。
    final pcMode = _wantsPcApp(req);
    // 見せない選択 (= ユーザー要望: ヘッドレスか見ながらか) の時も出さない。
    final showBrowser = !pcMode && !_agentHeadless;
    // ★ 保存先を分けるのは、 見せるかどうかとは別の話
    //   (= 見せない実行だとフォルダが分かれず、 前回の実行の
    //   スクショに混ざっていた)。
    await widget.onRunStarted?.call();
    if (showBrowser) widget.onRunningChanged?.call(true, _requestStop);
    final done = <String>[];
    try {
      // ★ 「同じ画面で、 同じ手順」 を出し続けていないかを見張る
      //   (= ユーザー報告: 止まらずに同じフローをひたすら作り続ける)。
      //   手数の上限だけだと、 12 回ぶんの同じ手順が積み上がってしまう。
      final guard = AgentProgressGuard();
      // 直前の回に実行した手順 (同じ物を積み増さないため)。
      String? lastRanSig;
      String? prevPlan;
      // 手数の上限。 止まらなくなるのを防ぐ。
      for (var turn = 0; turn < 12; turn++) {
        if (_agentStop || !mounted) break;
        // ★ ブラウザが閉じられていたら、 そこで終わり (= ユーザー要望)。
        if (_cdpGone) {
          _agentFail(provider, 'agent.errBrowserGone', '');
          break;
        }
        final snap = await _pageSnapshot();
        final prompt = '''
あなたは Web ページを操作する担当です。 依頼を達成するために、
**次にやる 1〜3 手**だけを JSON で出してください
(説明文・コードフェンス・前置きは一切不要)。

出力の形:
{"done":false,"steps":[ …手順… ]}
- 依頼が済んだと判断したら {"done":true,"steps":[]} を返してください。
- steps の書き方は下と同じです。

$_kFlowFormatRules

【今の画面】 (url / title / 押せる物の文字 items / 見出し heads /
 scrollY と pageH で今どのあたりかが分かります)
${snap.isEmpty ? (_wantsPcBrowser(req) ? '\n※ まだ何も開いていません。 最初の 1 手は必ず'
    ' {"kind":"openBrowser","text":"ブラウザ名","selector":"https://…"}'
    ' にしてください (外のブラウザの話なので open ではいけません)。\n' : '\n※ まだページを開いていません。 最初の 1 手は必ず'
    ' {"kind":"open","text":"https://…"} にしてください。\n') : ''}
${snap.isEmpty ? '(画面の中身を読めませんでした)' : snap}

【ここまでにやったこと】
${done.isEmpty ? '(まだ何もしていません)' : done.join('\n')}
${prevPlan == null ? '' : '''
【直前に出した手順】 これと同じ物をもう一度出さないでください。
$prevPlan
同じ手を繰り返しても画面は変わりません。 効かなかったのなら、
別のやり方 (別の文字で探す / 先に待つ / 端まで送る) に変えるか、
これ以上やる事が無ければ {"done":true,"steps":[]} を返してください。
'''}
${_pcContext(req)}
依頼: $req''';
        String out;
        try {
          out = (await provider.askAi(prompt)).trim();
          _noteAiMessage(out);
        } catch (err) {
          // ★ 黙って止まらない (= ユーザー報告: 真っ白な画面になった後、
          //   何も作られないまま戻ってきた)。 何が起きたのかを出す。
          _agentFail(provider, 'agent.errAi', '$err');
          break;
        }
        if (_agentStop || !mounted) break;
        // AI に聞いている間に閉じられた時も止める。
        if (_cdpGone) {
          _agentFail(provider, 'agent.errBrowserGone', '');
          break;
        }
        if (out.isEmpty) {
          // AI が空を返した。 推論に余裕が無いモデルで起きやすい。
          _agentFail(provider, 'agent.errEmpty', '');
          break;
        }
        var body = out;
        final fence = RegExp(r'```[a-zA-Z]*\s*\n([\s\S]*?)\n?```');
        final fm = fence.firstMatch(body);
        if (fm != null) body = fm.group(1) ?? body;
        final s = body.indexOf('{');
        final e = body.lastIndexOf('}');
        if (s < 0 || e <= s) {
          _agentFail(provider, 'agent.errFormat', out);
          break;
        }
        Object? m;
        try {
          m = jsonDecode(body.substring(s, e + 1));
        } catch (_) {
          _agentFail(provider, 'agent.errFormat', out);
          break;
        }
        if (m is! Map) {
          _agentFail(provider, 'agent.errFormat', out);
          break;
        }
        if (m['done'] == true) {
          if (mounted) setState(() => _status = provider.t('agent.done'));
          break;
        }
        final list = m['steps'];
        if (list is! List || list.isEmpty) {
          // 手順が空で done でも無い = 何もしないまま終わるところ。
          _agentFail(provider, 'agent.errNoSteps', out);
          break;
        }
        final steps = _coercePcIntent(req, <WebAutoStep>[
          for (final j in list)
            if (j is Map) WebAutoStep.fromJson(Map<String, dynamic>.from(j)),
        ]);
        if (steps.isEmpty) {
          _agentFail(provider, 'agent.errNoSteps', out);
          break;
        }
        // ★ 画面が変わっていないのに、 次の一手も同じ = 進んでいない。
        //   ここで止めないと、 同じ手順が何度も積まれ続ける
        //   (= ユーザー報告: 止まらずに同じフローを作り続ける)。
        //   積む前に抜けるので、 フローには 1 回ぶんだけ残る。
        if (!guard.advance(steps, snap)) {
          _agentFail(provider, 'agent.errStuck', '');
          break;
        }
        // ★ 直前の回とそっくり同じ「開くだけ」 の手順を出してきたら、
        //   もう積まない (= ユーザー報告: 同じ処理を二回行うフローが
        //   生成される。 ページを開いて端まで送る、 をもう一度出していた)。
        //
        //   ・**直前の回**とだけ比べる。 一覧ページへ戻りながら 1 件ずつ
        //     見て回るような使い方では、 間に押す・読むの回が挟まるので
        //     切ってしまわない。
        //   ・「開く / 端まで送る」 だけの回に限る。 待つ・押す・打つの
        //     繰り返しには意味があるので通す。
        final sig = AgentProgressGuard.planSignature(steps);
        if (sig == lastRanSig && _navigationOnly(steps)) {
          if (mounted) setState(() => _status = provider.t('agent.done'));
          break;
        }
        lastRanSig = sig;
        // 次の回で AI に見せる (= 同じ手を出さないように頼むため)。
        prevPlan = AgentProgressGuard.planSignature(steps);
        // 手順が増えすぎた時も止める (どこかで空回りしている)。
        if (_steps.length >= 80) {
          _agentFail(provider, 'agent.errStuck', '');
          break;
        }
        if (!mounted) return;
        // 実行した手順はフローに積んでいく (後で使い回せるように)。
        setState(() {
          _steps.addAll(steps);
          _status = provider
              .t('agent.step')
              .replaceFirst('{n}', '${turn + 1}');
        });
        // ★ 実行する前に控える。 後回しにすると、 スクショ等で画面が
        //   作り直された時にここまでの手順が消えてしまう。
        await _save();
        for (final st in steps) {
          if (_agentStop) break;
          done.add('- ${st.kind.name}'
              '${st.text.isEmpty ? '' : ' "${st.text}"'}'
              '${st.scrollDir.isEmpty ? '' : ' ${st.scrollDir}'}');
        }
        await _runSteps(steps, provider.t('agent.label'));
        await _save();
        // ★ 手順の中で止まった時は、 次の回へ進まない (= これが無いと、
        //   ブラウザを開けなかった後も 12 回ぶん AI に聞き続けていた)。
        if (_cancel || _cdpGone) {
          if (_cdpGone) _agentFail(provider, 'agent.errBrowserGone', '');
          break;
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e'.replaceFirst('Exception: ', ''));
      }
    } finally {
      // ★ 外のブラウザを使ったなら、 終わったらつながりを手放す。
      //   つないだままだと、 次にアプリの中のページを操作するふつうの
      //   フローを流しても目の前のページは動かず、 放置した外のブラウザ
      //   の方が動いてしまう (= 点検で判明)。 窓自体は閉じない。
      await _releaseCdp();
      // その場かぎりで頼まれた時は、 走らせる前の手順に戻す
      // (= ユーザー要望: 手元のフローを勝手に置き換えない)。
      if (!keepSteps) {
        _steps
          ..clear()
          ..addAll(before);
        await _save();
      }
      // ★ 終わったので元に戻す (ブラウザを隠す判断は受け側が持つ)。
      //   出していない時は戻す必要も無い。
      if (showBrowser) widget.onRunningChanged?.call(false, _requestStop);
      if (mounted) {
        setState(() {
          _agentBusy = false;
          _agentStop = false;
          // 残した時は、 そのまま保存できる事を伝える。
          if (keepSteps && _steps.isNotEmpty) {
            _status = provider
                .t('agent.kept')
                .replaceFirst('{n}', '${_steps.length}');
          }
        });
      }
    }
  }

  // ─── JS 合成イベント ──────────────────────────────────────────────────
  String _pointerJs(String type, double x, double y, {int buttons = 1}) {
    final xi = x.round();
    final yi = y.round();
    return '(function(){var x=$xi,y=$yi;'
        'var el=document.elementFromPoint(x,y)||document.body;'
        'var o={clientX:x,clientY:y,screenX:x,screenY:y,bubbles:true,'
        'cancelable:true,composed:true,pointerId:1,pointerType:"touch",'
        'isPrimary:true,buttons:$buttons,button:0,view:window};'
        'try{el.dispatchEvent(new PointerEvent("$type",o));}catch(e){}'
        'try{var t=new Touch({identifier:1,target:el,clientX:x,clientY:y});'
        'var tt="$type"==="pointerdown"?"touchstart":'
        '("$type"==="pointerup"?"touchend":"touchmove");'
        'el.dispatchEvent(new TouchEvent(tt,{touches:tt==="touchend"?[]:[t],'
        'targetTouches:tt==="touchend"?[]:[t],changedTouches:[t],'
        'bubbles:true,cancelable:true,composed:true}));}catch(e){}'
        '})();';
  }

  String _mouseJs(String type, double x, double y, {int buttons = 1}) {
    final xi = x.round();
    final yi = y.round();
    return '(function(){var x=$xi,y=$yi;'
        'var el=document.elementFromPoint(x,y)||document.body;'
        'el.dispatchEvent(new MouseEvent("$type",{clientX:x,clientY:y,'
        'bubbles:true,cancelable:true,composed:true,buttons:$buttons,'
        'button:0,view:window}));'
        '})();';
  }

  Future<void> _tapAt(double x, double y) async {
    await _exec(_pointerJs('pointerdown', x, y));
    await _exec(_mouseJs('mousedown', x, y));
    await Future.delayed(const Duration(milliseconds: 40));
    await _exec(_pointerJs('pointerup', x, y, buttons: 0));
    await _exec(_mouseJs('mouseup', x, y, buttons: 0));
    await _exec(_mouseJs('click', x, y, buttons: 0));
    // 注: 以前はここで el.click() も呼んでいたが、 合成 click と二重に
    //     発火してリンクが 2 回開く等の症状が出ていた (= ユーザー報告:
    //     何故か 2 回繰り返される)。 実際のタップと同じく合成イベントの
    //     系列だけを送る。
  }

  Future<void> _holdAt(double x, double y, int ms) async {
    await _exec(_pointerJs('pointerdown', x, y));
    await _exec(_mouseJs('mousedown', x, y));
    await Future.delayed(Duration(milliseconds: ms));
    await _exec(_pointerJs('pointerup', x, y, buttons: 0));
    await _exec(_mouseJs('mouseup', x, y, buttons: 0));
  }

  Future<void> _swipe(
      double x1, double y1, double x2, double y2, int ms) async {
    const frames = 12;
    await _exec(_pointerJs('pointerdown', x1, y1));
    await _exec(_mouseJs('mousedown', x1, y1));
    for (var i = 1; i <= frames; i++) {
      if (_cancel) break;
      final t = i / frames;
      final x = x1 + (x2 - x1) * t;
      final y = y1 + (y2 - y1) * t;
      await _exec(_pointerJs('pointermove', x, y));
      await _exec(_mouseJs('mousemove', x, y));
      await Future.delayed(Duration(milliseconds: (ms / frames).round()));
    }
    await _exec(_pointerJs('pointerup', x2, y2, buttons: 0));
    await _exec(_mouseJs('mouseup', x2, y2, buttons: 0));
  }

  int _shots = 0;
  final math.Random _rng = math.Random();

  /// ステップの待機間隔。 上限が設定されていれば毎回その範囲の乱数
  /// (= ユーザー要望: 間隔は乱数秒を入れられるように)。
  Duration _intervalOf(WebAutoStep s) {
    final lo = s.intervalMs;
    // ばらつき: 0 なら固定。 1 以上ならこの幅ぶんだけランダムに上乗せする
    // (= 実際の待ち時間は 間隔 〜 間隔+ばらつき)。
    final spread = s.intervalMaxMs;
    if (spread > 0) {
      return Duration(milliseconds: lo + _rng.nextInt(spread + 1));
    }
    return Duration(milliseconds: lo);
  }

  /// ステップ列を順に実行する (繰り返しブロックは中身を再帰実行)。
  /// 「何番目まで渡したか」 を手順ごとに覚えておく。
  /// 繰り返しの中に置くと、 1 周ごとに次のファイルに進む。
  final Map<WebAutoStep, int> _uploadCursor = {};

  /// この実行で作ったファイル (= 「ファイルを渡す」 でフォルダーを
  /// 指定していない時はこちらを順に渡す)。
  final List<File> _madeFiles = [];

  /// ファイルを 1 つ作る (= ユーザー要望: ファイルを作成して
  /// アップロードしたりできるように)。
  Future<void> _runMakeFileStep(WebAutoStep s) async {
    if (!mounted) return;
    final provider = context.read<MindMapProvider>();
    var name = s.selector.trim();
    if (name.isEmpty) name = 'auto_file.txt';
    name = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (!name.contains('.')) name = '$name.txt';
    try {
      final dir = await automationFilesDir();
      final f = File('${dir.path}/$name');
      await f.writeAsString(s.text, flush: true);
      _madeFiles.removeWhere((e) => e.path == f.path);
      _madeFiles.add(f);
      if (!mounted) return;
      setState(() => _status =
          provider.t('auto.madeFile').replaceFirst('{name}', name));
    } catch (e) {
      if (!mounted) return;
      setState(() =>
          _status = provider.t('auto.madeFileFailed').replaceFirst('{e}', '$e'));
    }
  }

  /// 指定されたフォルダーのファイルを名前順に並べ、 範囲で切る。
  /// フォルダー未指定なら、 この実行で作ったファイルを使う。
  List<File> _uploadFilesOf(WebAutoStep s) {
    final dirPath = s.text.trim();
    if (dirPath.isEmpty) {
      final made = _madeFiles.where((f) => f.existsSync()).toList();
      if (made.isEmpty) return const [];
      final f0 = s.x.round() <= 0 ? 1 : s.x.round();
      final t0 = s.y.round() <= 0 ? made.length : s.y.round();
      if (f0 > made.length) return const [];
      return made.sublist(
          f0 - 1, t0 > made.length ? made.length : (t0 < f0 ? f0 : t0));
    }
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return const [];
      final all = dir
          .listSync()
          .whereType<File>()
          .toList()
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      final from = s.x.round() <= 0 ? 1 : s.x.round();
      final to = s.y.round() <= 0 ? all.length : s.y.round();
      if (from > all.length) return const [];
      return all.sublist(
          from - 1, to > all.length ? all.length : (to < from ? from : to));
    } catch (_) {
      return const [];
    }
  }

  /// ページの <input type=file> にファイルを入れる。
  ///
  /// JS から input.files は普通代入できないが、 DataTransfer を経由すれば
  /// 入れられる (Chromium 系の WebView なら Windows / Android とも動く)。
  Future<void> _runUploadStep(WebAutoStep s) async {
    final files = _uploadFilesOf(s);
    if (files.isEmpty) {
      if (mounted) {
        setState(() => _status =
            context.read<MindMapProvider>().t('auto.uploadNoFile'));
      }
      return;
    }
    // 繰り返しの中なら 1 周ごとに次へ。 範囲を使い切ったら繰り返しを抜ける。
    final at = _uploadCursor[s] ?? 0;
    if (at >= files.length) {
      _loopBreak = true;
      return;
    }
    _uploadCursor[s] = at + 1;
    final f = files[at];
    final name = f.path.split(RegExp(r'[\\/]')).last;
    late final String b64;
    try {
      b64 = base64Encode(await f.readAsBytes());
    } catch (_) {
      return;
    }
    final sel = s.selector.trim();
    final js = '(function(){'
        'var el=${sel.isEmpty ? "document.querySelector('input[type=file]')" : 'document.querySelector(${jsonEncode(sel)})'};'
        'if(!el)return;'
        'var b=atob(${jsonEncode(b64)});'
        'var a=new Uint8Array(b.length);'
        'for(var i=0;i<b.length;i++)a[i]=b.charCodeAt(i);'
        'var dt=new DataTransfer();'
        'dt.items.add(new File([a],${jsonEncode(name)}));'
        'el.files=dt.files;'
        "el.dispatchEvent(new Event('change',{bubbles:true}));"
        '})()';
    await _exec(js);
    if (mounted) {
      setState(() => _status = context
          .read<MindMapProvider>()
          .t('auto.uploadSent')
          .replaceFirst('{name}', name)
          .replaceFirst('{n}', '${at + 1}')
          .replaceFirst('{total}', '${files.length}'));
    }
  }

  Future<void> _runSteps(List<WebAutoStep> steps, String path) async {
    for (var i = 0; i < steps.length; i++) {
      if (_cancel) return;
      // ★ 外のブラウザが閉じられていたら、 そこで止める (= ユーザー要望)。
      if (_cdpGone) {
        _cancel = true;
        _log('失敗', '外のブラウザが閉じられたので止めました');
        if (mounted) {
          setState(() => _status =
              context.read<MindMapProvider>().t('agent.errBrowserGone'));
        }
        return;
      }
      // 一番下に着いた: この繰り返しの残り (待機やスクショ) は飛ばす
      // (= ユーザー報告: 同じ場所のスクショが何枚も並ぶ)。
      if (_loopBreak) return;
      final s = steps[i];
      final label = path.isEmpty ? '${i + 1}' : '$path-${i + 1}';
      if (mounted) {
        setState(() => _status = '$_lapLabel · $label');
      }
      // ── 何をやったかを記録に残す (= ユーザー要望: 開発のテストに使う) ──
      //    中身も一緒に残す (どの URL を開いたか等が後から分かるように)。
      {
        final p = context.read<MindMapProvider>();
        final detail = [
          if (s.text.trim().isNotEmpty)
            's.text=${s.text.trim().length > 80 ? '${s.text.trim().substring(0, 80)}…' : s.text.trim()}',
          if (s.selector.trim().isNotEmpty) 'sel=${s.selector.trim()}',
          if (s.x != 0 || s.y != 0) 'xy=(${s.x.round()},${s.y.round()})',
          if (s.count != 0) 'count=${s.count}',
          if (s.durationMs != 0) 'ms=${s.durationMs}',
        ].join(' ');
        _log('実行', '$label ${_kindLabel(p, s.kind)}'
            '${detail.isEmpty ? '' : '  $detail'}');
      }
      switch (s.kind) {
        case WebAutoKind.loop:
          // 回数 0 = 停止するまで無限に回す (= while)。
          //
          // ★ 中で「これ以上送れない」 と分かったら、 残りの回数は回さない
          //   (= ユーザー報告: 一番下に着いた後も撮り続けて同じ絵が並ぶ)。
          //   印はこの繰り返しの中だけで使い、 抜ける時に消す。
          _loopDepth++;
          _loopBreak = false;
          _lastShotPos = null;
          try {
            if (s.count <= 0) {
              while (!_cancel && !_loopBreak) {
                await _runSteps(s.children, label);
              }
            } else {
              for (var c = 0; c < s.count; c++) {
                if (_cancel) return;
                await _runSteps(s.children, label);
                if (_loopBreak) break;
              }
            }
          } finally {
            _loopDepth--;
            _loopBreak = false;
          }
          break;
        case WebAutoKind.tap:
          for (var c = 0; c < s.count; c++) {
            if (_cancel) return;
            await _tapAt(s.x, s.y);
            await Future.delayed(_intervalOf(s));
          }
          break;
        case WebAutoKind.hold:
          await _holdAt(s.x, s.y, s.durationMs);
          break;
        case WebAutoKind.swipe:
          for (var c = 0; c < s.count; c++) {
            if (_cancel) return;
            await _swipe(s.x, s.y, s.x2, s.y2, s.durationMs);
            await Future.delayed(_intervalOf(s));
          }
          break;
        case WebAutoKind.scroll:
          // 送る量 (px)。 **0 以下 = 「1 画面ぶん」**。
          //   = ユーザー報告「上から下まで撮ったら、 送り幅と撮る間隔が
          //     合わずに同じ所ばかり写る」。 決め打ちの px だと 1 画面より
          //     ずっと短く、 大半が重なっていた。 実行時に window.innerHeight
          //     を見て 1 割だけ重ねて送る (つなぎ目が切れないように)。
          //   なめらか送り (smooth) は次の手順が始まっても動き続けて写真が
          //     ぶれるので、 一気に送る (instant) に変える。
          final amount = s.durationMs;
          final horiz = s.scrollDir == 'right' || s.scrollDir == 'left';
          final neg = s.scrollDir == 'up' || s.scrollDir == 'left';
          final expr = amount > 0
              ? '${neg ? -amount : amount}'
              : '${neg ? '-' : ''}Math.round(window.'
                  '${horiz ? 'innerWidth' : 'innerHeight'}*0.9)';
          final top = horiz ? '0' : expr;
          final left = horiz ? expr : '0';
          // ★ 送る前と後の位置を同じ 1 回の JS で読む。 動かなかったら
          //   「もう端」 なので、 繰り返しの中なら残りを切り上げる
          //   (= ユーザー報告: 最後に同じスクショが何枚も入る)。
          // ★ _eval を使う (= 以前は widget.evalJs を直に掴んでいたため、
          //   外のブラウザにつないでいてもスクロールの JS が
          //   **アプリの中のブラウザ**へ飛んでいた
          //   = ユーザー報告「一番下までスクロールしてと言っても動かない」)。
          final axis = horiz ? 'scrollX' : 'scrollY';
          final axisFallback = horiz ? 'scrollLeft' : 'scrollTop';
          final scrollJs = '(function(){var d=document.documentElement;'
              'var b=Math.round(window.$axis||d.$axisFallback||0);'
              'window.scrollBy({top:$top,left:$left,behavior:"instant"});'
              'var a=Math.round(window.$axis||d.$axisFallback||0);'
              'return String(b)+","+String(a);})();';
          for (var c = 0; c < (s.count <= 0 ? 1 : s.count); c++) {
            if (_cancel) return;
            final raw = await _eval(scrollJs);
            // ★ 答えが返らないのは「送る口が無い」 時だけとは限らない
            //   (ページ移動中の例外など)。 口がある時に撃ち直すと、
            //   2 画面ぶん進んでしまい 1 画面撮り漏れる。
            if (raw == null && !_hasJsChannel) {
              await _exec(scrollJs);
            } else if (raw != null) {
              final t = raw.replaceAll('"', '').trim();
              final p = t.split(',');
              final before = p.length == 2 ? int.tryParse(p[0]) : null;
              final after = p.length == 2 ? int.tryParse(p[1]) : null;
              if (before != null && after != null) {
                _lastScrollPos = after;
                if (after == before && _loopDepth > 0) _loopBreak = true;
              }
            }
            await Future.delayed(_intervalOf(s));
            if (_loopBreak) return;
          }
          break;
        case WebAutoKind.type:
          for (var c = 0; c < (s.count <= 0 ? 1 : s.count); c++) {
            if (_cancel) return;
            await _exec(_typeJs(s));
            await Future.delayed(_intervalOf(s));
          }
          break;
        case WebAutoKind.upload:
          await _runUploadStep(s);
          await Future.delayed(_intervalOf(s));
          break;
        case WebAutoKind.makeFile:
          await _runMakeFileStep(s);
          await Future.delayed(_intervalOf(s));
          break;
        case WebAutoKind.open:
          // ── リンクを開く (= ユーザー要望: 「このページを開いて上から下まで
          //    スクショ」 のような手順を組めるように) ──
          //    WebView の中で移動するだけなので、 外のブラウザは開かない。
          {
            var u = s.text.trim();
            if (u.isEmpty) break;
            if (!u.startsWith('http://') && !u.startsWith('https://')) {
              u = 'https://$u';
            }
            await _exec('location.href = ${jsonEncode(u)};');
            // 読み込みを待つ。 durationMs を待ち時間として使う (既定 2 秒)。
            final waitMs = s.durationMs <= 0 ? 2000 : s.durationMs;
            await Future.delayed(Duration(milliseconds: waitMs));
          }
          break;
        case WebAutoKind.click:
          // ── 文字 / セレクタで要素を探して押す (= 座標に頼らない) ──
          for (var c = 0; c < (s.count <= 0 ? 1 : s.count); c++) {
            if (_cancel) return;
            await _exec(_clickByJs(s.selector, s.text));
            // 押した先が別ページなら読み込みを待つ。
            await Future.delayed(Duration(
                milliseconds: s.durationMs <= 0 ? 800 : s.durationMs));
          }
          break;
        case WebAutoKind.scrollTo:
          // ── 一番下 / 一番上まで送る (= フッターの撮影を確実にする) ──
          //
          // ★ 一発撃って終わりにしない (= ユーザー報告: 一番下まで
          //   スクロールしてと言ってもスクロールされない)。 直した点は 4 つ:
          //   ・なめらか送り (smooth) をやめる。 窓が裏に居るとアニメーションが
          //     進まないまま次の手順へ行ってしまう。
          //   ・document.body ではなく scrollingElement を見る。 作りによっては
          //     body の高さが 0 で、 送り先が 0 になっていた。
          //   ・本体が動かない時は、 中身がはみ出している内側の枠を送る。
          //   ・下へ行くほど中身が増えるページがあるので、 位置が変わらなく
          //     なるまで数回押し込む。
          {
            final toTop = s.scrollDir == 'top' || s.scrollDir == 'up';
            final waitMs = s.durationMs <= 0 ? 700 : s.durationMs;
            final js = scrollEndJs(toTop);
            var lastY = -1;
            var lastH = -1;
            for (var i = 0; i < (toTop ? 2 : 8); i++) {
              if (_cancel) return;
              final raw = await _eval(js);
              await Future.delayed(Duration(milliseconds: waitMs));
              if (raw == null) {
                // 位置を読めない相手でも、 送るだけは送る
                //   (端まで送るのは何度やっても同じなので二度打ちは無害)。
                if (!_hasJsChannel) await _exec(js);
                break;
              }
              final p = raw.replaceAll('"', '').trim().split(',');
              if (p.length != 2) break;
              final y = int.tryParse(p[0]);
              final h = int.tryParse(p[1]);
              if (y == null || h == null) break;
              _lastScrollPos = y;
              // 位置も全体の高さも動かなくなったら、 そこが端。
              if (y == lastY && h == lastH) break;
              lastY = y;
              lastH = h;
            }
          }
          break;
        case WebAutoKind.openExternal:
          // ── アプリの外の既定ブラウザで開く (= ユーザー要望) ──
          {
            var u = s.text.trim();
            if (u.isEmpty) break;
            if (!u.startsWith('http://') &&
                !u.startsWith('https://') &&
                !u.startsWith('file:')) {
              u = 'https://$u';
            }
            await _openInOsBrowser(u);
            await Future.delayed(
                Duration(milliseconds: s.durationMs <= 0 ? 1500 : s.durationMs));
          }
          break;
        case WebAutoKind.command:
          // ── パソコンのコマンドを実行 (= ユーザー要望) ──
          //    許可の設定に従う。 断られたらフローごと止める。
          {
            final ok = await _runCommandStep(s);
            if (!ok) {
              _cancel = true;
              return;
            }
          }
          break;
        case WebAutoKind.wait:
          await Future.delayed(Duration(milliseconds: s.durationMs));
          break;
        case WebAutoKind.shot:
          // 同じ場所を続けて撮らない (= ユーザー報告: 一番下で同じ絵が並ぶ)。
          //   繰り返しの外や、 位置が読めない時は今までどおり必ず撮る。
          if (_loopDepth > 0 &&
              _lastScrollPos != null &&
              _lastScrollPos == _lastShotPos) {
            break;
          }
          _lastShotPos = _lastScrollPos;
          final region = (s.x2 - s.x).abs() > 4 && (s.y2 - s.y).abs() > 4
              ? Rect.fromLTRB(s.x, s.y, s.x2, s.y2)
              : null;
          for (var c = 0; c < (s.count <= 0 ? 1 : s.count); c++) {
            if (_cancel) return;
            // ★ 外のブラウザにつないでいる時は、 そちらのページを撮る
            //   (= ユーザー報告: CDP が実装できているのに、 画面を撮る
            //   手順ばかり作られる)。 以前はここが必ずアプリの中の
            //   ブラウザを撮っていたので、 外の Chrome を開いていても
            //   写るのは空っぽのアプリ内ブラウザだった。
            final saved = await _captureHere(region);
            if (saved) _shots++;
            await Future.delayed(_intervalOf(s));
          }
          break;
        case WebAutoKind.fullShot:
          {
            // ページの上から下までを 1 枚に繋げる (= ユーザー要望)。
            // ★ 外のブラウザは CDP 側で「ページ全体」 を撮れる。
            final cdp = _cdp;
            if (cdp != null && !cdp.isClosed) {
              // 外のブラウザは CDP に「ページ全体」 を撮る口がある。
              if (await _captureHere(null, fullPage: true)) _shots++;
              break;
            }
            final f = widget.captureFull;
            if (f == null) break;
            for (var c = 0; c < (s.count <= 0 ? 1 : s.count); c++) {
              if (_cancel) return;
              final shot = await f();
              if (shot != null) _shots++;
              await Future.delayed(_intervalOf(s));
            }
          }
          break;
        // ── 利用者に聞いて待つ (= ユーザー要望: Chrome のアカウント選択で
        //    止まらず、 選んでもらってから先へ進む) ──
        case WebAutoKind.openBrowser:
          {
            final ok = await _openExternalBrowser(s);
            if (!ok) {
              _cancel = true;
              return;
            }
            await Future.delayed(_intervalOf(s));
          }
          break;
        case WebAutoKind.ask:
          {
            final ok = await _runAskStep(s);
            if (!ok) {
              _cancel = true;
              return;
            }
          }
          break;
        // ── パソコンそのものの操作 (= ユーザー要望: PC 内のアプリを操作) ──
        //    アプリの中のブラウザではなく Windows に直接信号を送るので、
        //    許可されていない時は何もせず、 その旨を出して止める。
        case WebAutoKind.osActivate:
        case WebAutoKind.osClick:
        case WebAutoKind.osMove:
        case WebAutoKind.osType:
        case WebAutoKind.osKey:
        case WebAutoKind.osScroll:
          {
            // ★ ここが下のダウンロードへ落ちていた (= 点検で判明)。
            //   窓を前に出す・打つ・押すの手順が、 全部ダウンロードの
            //   中身を走っていた。
            final ok = await _runOsStep(s);
            if (!ok) {
              _cancel = true;
              return;
            }
            await Future.delayed(_intervalOf(s));
          }
          break;
        // ── ダウンロード (= ユーザー要望) ──
        case WebAutoKind.download:
          {
            final ok = await _runDownloadStep(s);
            if (!ok) {
              _cancel = true;
              return;
            }
            await Future.delayed(_intervalOf(s));
          }
          break;
        // ── ページのログ・エラー (= ユーザー要望) ──
        case WebAutoKind.consoleLog:
          await _runConsoleStep(s);
          await Future.delayed(_intervalOf(s));
          break;
        // ── ページの中身を取り出す (= ユーザー要望) ──
        case WebAutoKind.extract:
          await _runExtractStep(s);
          await Future.delayed(_intervalOf(s));
          break;
        case WebAutoKind.osShot:
          {
            final ok = await _runOsStep(s);
            if (!ok) {
              _cancel = true;
              return;
            }
            await Future.delayed(_intervalOf(s));
          }
          break;
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  アプリの外の操作 (= ユーザー要望: 外のブラウザ操作 / ターミナル操作)
  //
  //  コマンド実行は取り返しが付かないことがあるので、
  //    ・既定は「使わない」 (何も起きない)
  //    ・「毎回確認」 なら実行のたびに中身を見せて許可を取る
  //    ・「全部任せる」 でも、 明らかに壊しにいくコマンドだけは断る
  //  という三段構えにしている。
  // ═══════════════════════════════════════════════════════════════
  static const String _kPolicyPrefsKey = 'automationCommandPolicy';

  AutoCommandPolicy _cmdPolicy = AutoCommandPolicy.off;

  /// パソコン版か (外の操作はパソコンだけ)。
  static bool get _isDesktopHost =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Future<void> _loadCmdPolicy() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getString(_kPolicyPrefsKey) ?? 'off';
      if (!mounted) return;
      setState(() {
        _cmdPolicy = AutoCommandPolicy.values.firstWhere(
          (e) => e.name == v,
          orElse: () => AutoCommandPolicy.off,
        );
      });
    } catch (_) {}
  }

  Future<void> _saveCmdPolicy() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kPolicyPrefsKey, _cmdPolicy.name);
    } catch (_) {}
  }

  /// 既定のブラウザでページを開く。
  Future<void> _openInOsBrowser(String url) async {
    if (!_isDesktopHost) return;
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'ブラウザを開けませんでした: $e');
    }
  }

  /// 利用者に聞いて、 答えるまで待つ。
  ///
  /// ★ Chrome のアカウント選択のように、 本人にしか決められない所がある
  ///   (= ユーザー要望: そこで終わらずに、 選んでもらってから先へ進む)。
  ///   選択肢が無い時は「続ける」 だけを出し、 画面で操作し終えたら
  ///   押してもらう形にする。
  ///
  /// 進めてよければ true、 やめるなら false。
  /// 人の作業が終わるまで待つ (押されるまで戻らない)。
  ///
  /// = ユーザー報告「chrome のプロファイルにログインするのが失敗する」。
  ///   Google は自動操作の口を開けたブラウザではログインさせてくれない
  ///   ので、 口を開けない窓で人にログインしてもらい、 終わったと
  ///   押されてから開き直す。
  Future<bool> _waitForHuman(String question) async {
    if (!mounted) return false;
    final provider = context.read<MindMapProvider>();
    if (mounted) setState(() => _status = question);
    final ok = await showDialog<bool>(
      context: context,
      // 浮かぶ窓の中から出しても下に潜らないように。
      useRootNavigator: false,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E32),
        title: Row(children: [
          const Icon(Icons.login_rounded, color: Color(0xFF80CBC4), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(provider.t('auto.kindAsk'),
                style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
        ]),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            child: Text(question,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13, height: 1.6)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(provider.t('auto.askStop'),
                style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF43B97F),
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(provider.t('auto.askContinue')),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<bool> _runAskStep(WebAutoStep s) async {
    if (!mounted) return false;
    final provider = context.read<MindMapProvider>();
    final question = s.text.trim().isEmpty
        ? provider.t('auto.askDefault')
        : s.text.trim();
    final choices = s.selector
        .split('|')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (mounted) setState(() => _status = question);
    final picked = await showDialog<String>(
      context: context,
      // 浮かぶ窓の中から出しても下に潜らないように。
      useRootNavigator: false,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E32),
        title: Row(children: [
          const Icon(Icons.help_outline_rounded,
              color: Color(0xFF80CBC4), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(provider.t('auto.kindAsk'),
                style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(question,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13, height: 1.6)),
            if (choices.isEmpty) ...[
              const SizedBox(height: 10),
              Text(provider.t('auto.askManualHint'),
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 11, height: 1.5)),
            ],
            if (choices.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final c in choices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF80CBC4),
                          side: const BorderSide(color: Color(0xFF80CBC4))),
                      onPressed: () => Navigator.pop(dctx, c),
                      child: Text(c,
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                  ),
                ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, null),
            child: Text(provider.t('auto.askStop'),
                style: const TextStyle(color: Color(0xFFE57373))),
          ),
          if (choices.isEmpty)
            TextButton(
              onPressed: () => Navigator.pop(dctx, ''),
              child: Text(provider.t('auto.askContinue'),
                  style: const TextStyle(color: Color(0xFF4FC3F7))),
            ),
        ],
      ),
    );
    if (!mounted) return false;
    if (picked == null) {
      setState(() => _status = context
          .read<MindMapProvider>()
          .t('auto.askStopped'));
      return false;
    }
    // 選ばれた答えは、 次に AI へ渡す時の手がかりとして覚えておく。
    if (picked.isNotEmpty) _lastAskAnswer = picked;
    return true;
  }

  /// 直近で利用者が選んだ答え (AI に「こう選ばれた」 と伝えるため)。
  String? _lastAskAnswer;

  /// パソコンそのものへの操作を 1 つ行う (= ユーザー要望: アプリ内だけで
  /// なく PC 内のアプリを操作)。
  ///
  /// ★ 画面に見えている物を無差別に押せてしまうので、 コマンド実行と同じ
  ///   設定 (使わない / 毎回確認 / 全部任せる) を流用して守る。 「使わない」
  ///   の間は一切動かない。
  Future<bool> _runOsStep(WebAutoStep s) async {
    if (!_isDesktopHost || !DesktopInput.isSupported) {
      if (mounted) {
        setState(() => _status = context.read<MindMapProvider>().t('auto.osWindowsOnly'));
      }
      return false;
    }
    if (kStoreBuild) {
      if (mounted) setState(() => _status = context.read<MindMapProvider>().t('auto.osStoreBuild'));
      return false;
    }
    if (_cmdPolicy == AutoCommandPolicy.off) {
      if (mounted) setState(() => _status = context.read<MindMapProvider>().t('auto.osDisabled'));
      return false;
    }
    // 何をするのかを 1 行で説明して、 毎回確認の時はこれを見せる。
    final what = switch (s.kind) {
      WebAutoKind.osActivate => '${context.read<MindMapProvider>().t('auto.kindOsActivate')}: ${s.text}',
      WebAutoKind.osClick => '${context.read<MindMapProvider>().t('auto.kindOsClick')}: '
          '(${s.x.round()}, ${s.y.round()})',
      WebAutoKind.osMove => '${context.read<MindMapProvider>().t('auto.kindOsMove')}: '
          '(${s.x.round()}, ${s.y.round()})',
      WebAutoKind.osType => '${context.read<MindMapProvider>().t('auto.kindOsType')}: ${s.text}',
      WebAutoKind.osKey => '${context.read<MindMapProvider>().t('auto.kindOsKey')}: ${s.text}',
      WebAutoKind.osScroll => '${context.read<MindMapProvider>().t('auto.kindOsScroll')}: ${s.count}',
      _ => context.read<MindMapProvider>().t('auto.kindOsShot'),
    };
    if (_cmdPolicy == AutoCommandPolicy.ask) {
      final ok = await _confirmCommand(what);
      if (ok != true) {
        if (mounted) setState(() => _status = context.read<MindMapProvider>().t('auto.osCancelled'));
        return false;
      }
    }
    // 許しが出ている間だけ動かす。 終わったらすぐ閉じる。
    DesktopInput.enabled = true;
    try {
      switch (s.kind) {
        case WebAutoKind.osActivate:
          if (!DesktopInput.activateWindow(s.text)) {
            if (mounted) {
              setState(() => _status = context
                  .read<MindMapProvider>()
                  .t('auto.osNoWindow')
                  .replaceFirst('{name}', s.text));
            }
            return false;
          }
          // 前に出てから落ち着くまで少し待つ。
          await Future.delayed(const Duration(milliseconds: 400));
          break;
        case WebAutoKind.osClick:
          DesktopInput.click(s.x.round(), s.y.round(),
              button: switch (s.selector.trim().toLowerCase()) {
                'right' => MouseButton.right,
                'middle' => MouseButton.middle,
                _ => MouseButton.left,
              },
              count: s.count <= 0 ? 1 : s.count);
          break;
        case WebAutoKind.osMove:
          DesktopInput.moveTo(s.x.round(), s.y.round());
          break;
        case WebAutoKind.osType:
          DesktopInput.typeText(s.text);
          break;
        case WebAutoKind.osKey:
          DesktopInput.pressKeys(
              s.text.split('+').map((e) => e.trim()).toList());
          break;
        case WebAutoKind.osScroll:
          DesktopInput.scroll(s.count == 0 ? -3 : s.count);
          break;
        case WebAutoKind.osShot:
          {
            final b = DesktopInput.screenBounds();
            final png =
                scap.captureScreenRectPng(b.x, b.y, b.width, b.height);
            if (png != null) {
              _osShots.add(png);
              // 溜め込まない (1 枚が数 MB になる)。
              while (_osShots.length > 4) {
                _osShots.removeAt(0);
              }
              _shots++;
            }
          }
          break;
        default:
          break;
      }
      return true;
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
      return false;
    } finally {
      DesktopInput.enabled = false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  スクショ以外のデータ (= ユーザー要望: ページからダウンロードしたり、
  //  エラーが起こっている画面のデバッグログを取ったりできるように)
  // ═══════════════════════════════════════════════════════════════

  /// 取ってきた物の置き場 (ダウンロード / 取り出した中身 / ログ)。
  Future<Directory> _dataDir() async {
    final root = await automationFilesDir();
    final d = Directory('${root.path}/data');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 同じ名前を上書きしない置き場所を作る。
  Future<File> _newDataFile(String baseName) async {
    final d = await _dataDir();
    final dot = baseName.lastIndexOf('.');
    final stem = dot > 0 ? baseName.substring(0, dot) : baseName;
    final ext = dot > 0 ? baseName.substring(dot) : '';
    var f = File('${d.path}/$baseName');
    var n = 2;
    while (await f.exists()) {
      f = File('${d.path}/${stem}_$n$ext');
      n++;
    }
    return f;
  }

  /// 取れた物を記録に残して、 画面にも出す。
  void _noteData(MindMapProvider provider, String what, String path) {
    _log('取得', '$what → $path');
    if (!mounted) return;
    setState(() => _status =
        provider.t('auto.dataSaved').replaceFirst('{what}', what));
  }

  /// ── ダウンロード ──────────────────────────────────────────────
  ///
  /// 外のブラウザにつないでいる時は、 ブラウザに保存させて終わりを待つ。
  /// つないでいない時は、 押す物の href を読み取って自分で取りに行く
  /// (アプリ内ブラウザにはダウンロードの受け口が無いため)。
  Future<bool> _runDownloadStep(WebAutoStep s) async {
    final provider = context.read<MindMapProvider>();
    final dir = await _dataDir();
    final sel = s.selector.trim();
    final label = s.text.trim();
    final waitMs = s.durationMs <= 0 ? 60000 : s.durationMs;

    // URL を直に指定された時は、 押さずにそのまま取りに行く。
    final direct = sel.startsWith('http://') || sel.startsWith('https://')
        ? sel
        : (label.startsWith('http://') || label.startsWith('https://')
            ? label
            : '');

    final c = _cdp;
    final viaCdp = c != null && !c.isClosed;

    if (viaCdp && direct.isEmpty) {
      // ブラウザに保存させる。
      final ok = await c.enableDownloads(dir.path);
      if (!ok) {
        _log('失敗', 'ダウンロードの受け入れを設定できませんでした');
      }
      final clicked = await _eval(_clickByJs(sel, label));
      _log('実行', 'ダウンロード: 押しました ${label.isEmpty ? sel : label}'
          '${clicked == null ? '' : ' ($clicked)'}');
      final name = await c.waitForDownload(
          timeout: Duration(milliseconds: waitMs));
      if (name == null) {
        _log('失敗', 'ダウンロードが終わりませんでした');
        if (mounted) {
          setState(() => _status = provider.t('auto.downloadFailed'));
        }
        return true; // 止めはしない (次の手順へ進む)
      }
      _madeFiles.add(File('${dir.path}/$name'));
      _noteData(provider, name, '${dir.path}/$name');
      return true;
    }

    // つないでいない時 / URL 直指定の時は、 自分で取りに行く。
    var url = direct;
    if (url.isEmpty) {
      // 押す物の href を読み取る。
      final raw = await _eval(hrefOfJs(sel, label));
      url = (raw ?? '').replaceAll('"', '').trim();
    }
    if (url.isEmpty || url == 'null') {
      _log('失敗', 'ダウンロード先が分かりませんでした');
      if (mounted) {
        setState(() => _status = provider.t('auto.downloadNoTarget'));
      }
      return true;
    }
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(Duration(milliseconds: waitMs));
      if (res.statusCode >= 400) {
        _log('失敗', 'ダウンロード: $url が ${res.statusCode} を返しました');
        return true;
      }
      var name = Uri.parse(url).pathSegments.isEmpty
          ? ''
          : Uri.parse(url).pathSegments.last;
      if (name.isEmpty || !name.contains('.')) name = 'download.bin';
      final f = await _newDataFile(name);
      await f.writeAsBytes(res.bodyBytes, flush: true);
      _madeFiles.add(f);
      _noteData(provider, name, f.path);
    } catch (e) {
      _log('失敗', 'ダウンロード: $e');
    }
    return true;
  }

  /// ── ページのログ・エラー ──────────────────────────────────────
  ///
  /// count が 0 なら「集め始める」 だけ。 1 以上なら「今までの分を保存」。
  /// 外のブラウザは CDP のイベントで拾い、 アプリ内ブラウザは
  /// console を横取りする仕掛けを入れて拾う。
  Future<void> _runConsoleStep(WebAutoStep s) async {
    final provider = context.read<MindMapProvider>();
    final c = _cdp;
    final viaCdp = c != null && !c.isClosed;
    final start = s.count <= 0;

    if (start) {
      if (viaCdp) {
        await c.startConsoleCapture();
        c.clearConsole();
      } else {
        await _exec(consoleHookJs);
      }
      _log('実行', 'ログを集め始めました');
      if (mounted) {
        setState(() => _status = provider.t('auto.logStarted'));
      }
      return;
    }

    final lines = <String>[];
    if (viaCdp) {
      lines.addAll(c.consoleLines);
    } else {
      final raw = await _eval(
          'JSON.stringify((window.__hnLogs||[]).slice(-400))');
      try {
        final j = jsonDecode(raw ?? '[]');
        if (j is List) {
          for (final e in j) {
            lines.add('$e');
          }
        }
      } catch (_) {}
    }
    if (lines.isEmpty) {
      _log('取得', 'ログはありませんでした');
      if (mounted) {
        setState(() => _status = provider.t('auto.logEmpty'));
      }
      return;
    }
    final f = await _newDataFile('log.txt');
    await f.writeAsString(lines.join('\n'), flush: true);
    _madeFiles.add(f);
    // 記録の窓でもそのまま読めるようにする。
    for (final l in lines.take(60)) {
      _log('ページ', l);
    }
    _noteData(provider, 'log.txt (${lines.length} 行)', f.path);
  }

  /// ── ページの中身を取り出す ────────────────────────────────────
  Future<void> _runExtractStep(WebAutoStep s) async {
    final provider = context.read<MindMapProvider>();
    final what = s.text.trim().toLowerCase();
    final sel = s.selector.trim();
    final mode = ['text', 'html', 'table', 'links'].contains(what)
        ? what
        : 'text';
    final raw = await _eval(extractJs(mode, sel));
    var body = raw ?? '';
    // WebView は JSON の文字列として返すことがある。
    if (body.length >= 2 && body.startsWith('"') && body.endsWith('"')) {
      try {
        body = jsonDecode(body) as String;
      } catch (_) {}
    }
    if (body.trim().isEmpty) {
      _log('失敗', '取り出せる中身がありませんでした ($mode)');
      if (mounted) {
        setState(() => _status = provider.t('auto.extractEmpty'));
      }
      return;
    }
    final name = switch (mode) {
      'html' => 'page.html',
      'table' => 'table.csv',
      'links' => 'links.txt',
      _ => 'page.txt',
    };
    final f = await _newDataFile(name);
    await f.writeAsString(body, flush: true);
    _madeFiles.add(f);
    _noteData(provider, name, f.path);
  }

  /// パソコンの画面を撮った分 (AI に見せるために持っておく)。
  final List<Uint8List> _osShots = [];

  /// 今操作している所を 1 枚撮って保存する。 撮れたら true。
  ///
  /// 外のブラウザにつないでいる時はそのページを、 つないでいない時は
  /// 今までどおりアプリの中のブラウザを撮る。
  Future<bool> _captureHere(Rect? region, {bool fullPage = false}) async {
    final c = _cdp;
    if (c != null && !c.isClosed) {
      try {
        final b64 = await c.screenshotBase64(
          clip: region == null
              ? null
              : (
                  x: region.left,
                  y: region.top,
                  w: region.width,
                  h: region.height
                ),
          fullPage: fullPage,
        );
        if (b64 == null || b64.isEmpty) return false;
        final png = base64Decode(b64);
        final save = widget.saveShotBytes;
        if (save != null) {
          final path = await save(png);
          if (path != null) return true;
          // ★ 保存できなかったのに「撮れた」 と数えない (= 終わりに
          //   「N 枚撮りました」 と出るのに 1 枚も残っていない、 という
          //   食い違いを防ぐ)。
          _log('失敗', 'CDP: スクショを保存できませんでした');
          return false;
        }
        // 保存の口が無い時でも、 AI に見せる分だけは持っておく
        //   (増えすぎないよう新しい方から数枚だけ)。
        _osShots.add(png);
        while (_osShots.length > 4) {
          _osShots.removeAt(0);
        }
        return true;
      } catch (e) {
        _log('失敗', 'CDP: スクショが撮れませんでした ($e)');
        return false;
      }
    }
    final shot = await widget.capture(region);
    return shot != null;
  }

  /// コマンドを 1 つ実行する。 実行した (もしくは黙って飛ばした) なら true、
  /// ユーザーが断った / 危ないので止めた なら false。
  Future<bool> _runCommandStep(WebAutoStep s) async {
    final cmd = s.text.trim();
    if (cmd.isEmpty) return true;
    if (!_isDesktopHost) {
      if (mounted) setState(() => _status = 'コマンド実行はパソコン版だけです');
      return false;
    }
    // ★ ストア提出版ではコマンド実行の仕組みごと使わない。
    if (kStoreBuild) {
      if (mounted) {
        setState(() => _status = 'この版ではコマンド実行は使えません');
      }
      return false;
    }
    if (_cmdPolicy == AutoCommandPolicy.off) {
      // ★ 設定の説明どおり「飛ばす」。 これまでは false を返していて、
      //   呼び出し側が実行そのものを打ち切っていたので、 コマンドが 1 つ
      //   混ざっているだけでフロー全体が動かなかった (= ユーザー報告:
      //   作ったフローを実行しても何も起きない)。
      final provider = context.read<MindMapProvider>();
      _log('注意', provider.t('auto.cmdSkipped'));
      if (mounted) {
        setState(() => _status = provider.t('auto.cmdSkipped'));
      }
      return true;
    }
    if (isDangerousCommand(cmd)) {
      if (mounted) {
        setState(() => _status = '危ないコマンドなので実行しませんでした: $cmd');
      }
      return false;
    }
    if (_cmdPolicy == AutoCommandPolicy.ask) {
      final ok = await _confirmCommand(cmd);
      if (ok != true) {
        if (mounted) setState(() => _status = 'コマンドの実行を取りやめました');
        return false;
      }
    }
    try {
      if (mounted) setState(() => _status = '実行中: $cmd');
      final ProcessResult r = await (Platform.isWindows
              ? Process.run('cmd', ['/c', cmd], runInShell: false)
              : Process.run('/bin/sh', ['-c', cmd]))
          .timeout(Duration(
              milliseconds: s.durationMs <= 0 ? 60000 : s.durationMs));
      final out = '${r.stdout}'.trim();
      final err = '${r.stderr}'.trim();
      _cmdLog.add('\$ $cmd');
      if (out.isNotEmpty) _cmdLog.add(out.length > 2000 ? out.substring(0, 2000) : out);
      if (err.isNotEmpty) _cmdLog.add(err.length > 1000 ? err.substring(0, 1000) : err);
      while (_cmdLog.length > 60) {
        _cmdLog.removeAt(0);
      }
      if (mounted) {
        setState(() => _status = r.exitCode == 0
            ? '実行しました (終了コード 0)'
            : '終了コード ${r.exitCode}: ${err.isEmpty ? out : err}');
      }
      return true;
    } catch (e) {
      if (mounted) setState(() => _status = 'コマンドに失敗: $e');
      return false;
    }
  }

  /// 実行したコマンドと結果の控え (= 何をしたか後から見えるように)。
  final List<String> _cmdLog = [];

  /// 動いた記録 (= ユーザー要望: 開発のテストに使いたいので、 デバッグ用の
  /// 記録を取れるように)。 手順の実行、 AI とのやり取り、 失敗の理由を
  /// 時刻つきで並べる。 上限を決めて古い物から捨てる。
  final List<String> _runLog = [];

  /// AI が返してきた文章 (= ユーザー要望: 自動化の所でも AI からの
  /// メッセージを見たい)。 手順だけでなく、 何を考えたのかを出す。
  final List<String> _aiMessages = [];

  static String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  }

  /// 記録を 1 行足す。 [tag] は '実行' / 'AI' / '失敗' など。
  void _log(String tag, String text) {
    final line = '[${_stamp()}] $tag  $text';
    _runLog.add(line);
    while (_runLog.length > 400) {
      _runLog.removeAt(0);
    }
    // 画面に出ている時だけ描き直す (実行中に毎回 setState すると重い)。
    if (mounted && _logPanelOpen) setState(() {});
  }

  /// 記録の欄を開いているか。
  bool _logPanelOpen = false;

  // ── 外のブラウザ (Chrome / Edge / Brave …) につないでいる時の相手 ──
  //    = ユーザー要望「PC 内のブラウザを操作したい」。
  //
  //    ★ ここが繋がっている間、 手順の JS はアプリ内ブラウザではなく
  //      **外のブラウザ**へ送られる。 文字で要素を探して押す仕掛けは
  //      そのまま効くので、 座標も画像も要らない。
  CdpBrowser? _cdp;

  /// JS を送る (つないでいる時は外のブラウザへ)。
  Future<void> _exec(String js) async {
    final c = _cdp;
    if (c != null) {
      // ★ 外のブラウザにつないでいたのなら、 切れた時にアプリの中の
      //   ブラウザへ黙って乗り換えない (= ユーザー報告: 閉じても動き
      //   続ける)。 何もせずに戻り、 呼び出し側が止める。
      if (c.isClosed) return;
      await c.evaluate(js);
      return;
    }
    await widget.exec(js);
  }

  /// 外のブラウザとのつながりを手放す。
  ///
  /// ★ つないだままにしてはいけない。 つないでいる間は JS もスクショも
  ///   すべて外のブラウザへ行くので、 次にアプリの中のページを操作する
  ///   ふつうのフローを流しても、 目の前のページは一切動かず、 放置した
  ///   Chrome の方が動く (= 点検で判明)。 フローが終わったら切る。
  Future<void> _releaseCdp() async {
    final c = _cdp;
    _cdp = null;
    // こちらから切る時は「居なくなった」 扱いにしない。
    _cdpLost = false;
    if (c == null) return;
    try {
      await c.dispose();
    } catch (_) {}
  }

  // ★ 「この項目だけ試す」 (_testStep) では切らない。 外のブラウザを開く
  //   手順を試してから、 次の手順を 1 つずつ試せるようにするため。
  //   まとめて実行した時とパネルを閉じた時には切る。

  /// 外のブラウザが (こちらが頼んでいないのに) 居なくなったか。
  ///
  /// = ユーザー要望「立ち上がったブラウザを閉じても エージェントが
  ///   止まってくれない。 指定していないのにブラウザが閉じるなどの
  ///   動作が起こったらエージェントが停止するようにして欲しい」。
  bool _cdpLost = false;

  bool get _cdpGone {
    final c = _cdp;
    return _cdpLost || (c != null && c.isClosed);
  }

  /// JS を送れる口があるか (外のブラウザ、 またはアプリ内ブラウザ)。
  bool get _hasJsChannel =>
      (_cdp != null && !_cdp!.isClosed) || widget.evalJs != null;

  /// JS の答えを受け取る (つないでいる時は外のブラウザから)。
  Future<String?> _eval(String js) async {
    final c = _cdp;
    if (c != null) {
      // ★ つないでいた相手が居なくなったら、 アプリの中のブラウザの
      //   中身を返さない (= それが「別の画面で動き続ける」 の正体)。
      if (c.isClosed) return null;
      return c.evaluate(js);
    }
    final ev = widget.evalJs;
    if (ev == null) return null;
    return ev(js);
  }

  /// つないだ相手が居なくなったら止める、 の見張りを付ける。
  ///
  /// = ユーザー要望「ブラウザを閉じたらエージェントも止まってほしい」。
  ///   別の相手に張り替えた後の知らせで止めないよう、 同じ物かを見る。
  void _watchCdpClosed(MindMapProvider provider) {
    final made = _cdp;
    if (made == null) return;
    _cdpLost = false;
    unawaited(made.closed.then((why) {
      if (!identical(_cdp, made)) return; // 張り替え / 意図した切断
      _cdpLost = true;
      _agentStop = true;
      _cancel = true;
      _log('失敗', 'CDP: $why');
      if (mounted) {
        setState(() => _status = provider.t('agent.errBrowserGone'));
      }
    }));
  }

  /// 初回だけ、 人にログインしてもらう。
  ///
  /// = ユーザー要望「ログインが要るなら、 最初からログイン画面へ」。
  ///   Google は自動操作の口を開けたブラウザではログインさせてくれないので、
  ///   口を開けない窓でログインしてもらい、 終わったら閉じて開き直す。
  ///   戻り値 true = ログイン済みになった (呼び出し側は続けてよい)。
  Future<bool> _firstLoginFlow(
      CdpBrowserKind kind, String acct, MindMapProvider provider) async {
    final mail = acct.isEmpty ? '' : CdpBrowser.accountEmailFor(kind, acct);
    // 選んだアカウントをあらかじめ選んだ状態の画面へ (continue は付けない
    //   = Google の continue は Google のドメインしか受け付けず 400)。
    final loginUrl = mail.isEmpty
        ? 'https://accounts.google.com/'
        : 'https://accounts.google.com/AccountChooser'
            '?Email=${Uri.encodeComponent(mail)}';
    final dataDir =
        CdpBrowser.accountDataDir(kind, acct.isEmpty ? 'default' : acct);
    _log('注意',
        'CDP: 「${acct.isEmpty ? '既定' : acct}」'
        '${mail.isEmpty ? '' : ' ($mail)'} 専用のブラウザは初めてです。'
        ' 自動操作の口を開けない窓でログインしてもらいます');
    // 開いている口があれば閉じる (同じ置き場は 1 つしか開けない)。
    await _releaseCdp();
    await CdpBrowser.closeProcessesUsingDataDir(dataDir);
    // 口を開けずに、 いきなりログイン画面で開く。
    final opened = await CdpBrowser.launchForLogin(
        kind: kind, dataDir: dataDir, url: loginUrl);
    if (!opened) {
      if (mounted) {
        setState(() => _status = provider.t('auto.acctFirstLogin'));
      }
      return false;
    }
    // 人が終わるまで待つ。
    final done = await _waitForHuman(provider
        .t('auto.acctLoginWait')
        .replaceFirst('{name}', mail.isEmpty ? acct : mail));
    if (!done) {
      if (mounted) setState(() => _status = provider.t('auto.stopped'));
      return false;
    }
    // ログイン用の窓を閉じてから、 口を開けて開き直せるようにする。
    final closed = await CdpBrowser.closeProcessesUsingDataDir(dataDir);
    if (!closed) {
      _log('失敗', provider.t('auto.acctLoginRetry'));
      if (mounted) setState(() => _status = provider.t('auto.acctLoginRetry'));
      return false;
    }
    // 済んだ印を置く (次からはこの流れを通らない)。
    CdpBrowser.markLoginDone(dataDir);
    _log('実行', 'CDP: ログインが済みました');
    return true;
  }

  /// 外のブラウザを開いてつなぐ。
  Future<bool> _openExternalBrowser(WebAutoStep s) async {
    final provider = context.read<MindMapProvider>();
    if (!_isDesktopHost) {
      setState(() => _status = provider.t('auto.osWindowsOnly'));
      return false;
    }
    // どのブラウザか (text で指定。 空なら入っている物の先頭)。
    final kind = CdpBrowserKindName.fromText(s.text) ??
        (CdpBrowser.installed().isNotEmpty
            ? CdpBrowser.installed().first
            : null);
    if (kind == null) {
      setState(() => _status = provider.t('auto.cdpNoBrowser'));
      return false;
    }
    // selector に URL を書ける (無ければ空のタブで開く)。
    var url = s.selector.trim();
    if (url.isNotEmpty &&
        !url.startsWith('http://') &&
        !url.startsWith('https://')) {
      url = 'https://$url';
    }
    // ★ submit で選ぶ (= 以前は count==1 を目印にしていたが、 count の
    //   既定が 1 なので**必ず**普段のプロファイル側に落ちていた。 その結果
    //   Chrome が本物の置き場で起動し、 プロファイルが複数あると
    //   「Chrome はどなたが使用しますか？」 で止まっていた
    //   = ユーザー報告)。 submit の既定は false なので、 既定は使い捨ての
    //   プロファイル = 選択画面が出ない。
    // ★ アカウントが入っているなら、 印が付いていなくてもそれで開く
    //   (= ユーザー報告: アカウントを指定しているのに使われない)。
    //   印 (submit) は「そのアカウント専用のブラウザで開く」 の意味で、
    //   普段のプロファイルを使う訳ではない。
    final acct = s.account.trim();
    final ownProfile = s.submit || acct.isNotEmpty;
    // ★ アカウントもログインの指定も無い時は、 シークレットで開く
    //   (= ユーザー要望: 明示しなければシークレット。 ログイン画面に
    //   飛ばず、 まっさらな状態で開く)。
    final incognito = !ownProfile;

    // ★ ログインが要るのにまだ済んでいないなら、 **最初に**ログインする
    //   (= ユーザー要望: ホームページに寄り道せず、 いきなりログイン画面へ)。
    //   これまでは目的のページを開いてから「初回ログイン」 と気付いて
    //   いたので、 一度ホームに飛んでからログイン窓に切り替わっていた。
    if (ownProfile) {
      final dataDir =
          CdpBrowser.accountDataDir(kind, acct.isEmpty ? 'default' : acct);
      if (!CdpBrowser.loginDoneFor(dataDir)) {
        final ok = await _firstLoginFlow(kind, acct, provider);
        if (!ok) return false;
        // ここまで来たらログイン済み。 下のふつうの起動へ進み、
        //   目的の URL でつなぐ。
      }
    }

    // ★ もう同じ相手につないでいるなら、 開き直さずページを移すだけ。
    //
    //   = ユーザー報告「実行が終わっても Chrome のタブが複数回開く」。
    //   1 手ずつ進めるやり方だと openBrowser が何度も出てくることがあり、
    //   その度に起動し直していたので窓とタブが増え続けていた。
    final live = _cdp;
    // ★ 使い回してよいのは「同じブラウザ・同じアカウント」 の時だけ。
    //   以前は acct が空だと必ず一致と見なしていたので、 別のアカウントの
    //   窓をそのまま使っていた (= ユーザー報告: 指定した垢で開かない)。
    if (live != null &&
        !live.isClosed &&
        live.kind == kind &&
        (acct.isEmpty
            ? !live.attachedToExisting
            : live.profileDir.toLowerCase() == acct.toLowerCase())) {
      if (url.isNotEmpty) {
        await live.navigate(url);
      }
      _log('実行', 'CDP: 開いている ${kind.label} をそのまま使います'
          '${url.isEmpty ? '' : ' → $url'}');
      if (mounted) {
        setState(() => _status = provider
            .t('auto.cdpConnected')
            .replaceFirst('{name}', kind.label));
      }
      return true;
    }
    try {
      await _cdp?.dispose();
      _log('実行', 'CDP: ${kind.label} を開いてつなぐ'
          '${url.isEmpty ? '' : ' → $url'}'
          '${ownProfile ? ' (普段のプロファイル)' : ''}');
      _cdp = await CdpBrowser.launchAndConnect(
        kind: kind,
        url: url.isEmpty ? null : url,
        useOwnProfile: ownProfile,
        incognito: incognito,
        profileHint: acct,
      );
      _watchCdpClosed(provider);
      if (incognito) {
        _log('実行', 'CDP: シークレットで開きました'
            ' (ログインの指定が無いため)');
      }
      final cur = await _cdp!.current();
      _log('実行', 'CDP: つながりました  ${cur?.url ?? ''}');
      // ★ 新しい窓を開かずに、 前から開いていた窓へつないだ時は、
      //   その旨を出す (= ユーザー報告: 実行しても chrome が
      //   立ち上がらない。 実際は裏の窓につないでいた)。
      if (_cdp!.attachedToExisting) {
        _log('注意',
            'CDP: 開いていた ${kind.label} につなぎました (新しい窓は'
            '開いていません)');
        if (mounted) {
          setState(() => _status = provider
              .t('auto.cdpReused')
              .replaceFirst('{name}', kind.label));
        }
      }
      // 裏に回っている窓は見えないので、 前に出す。
      unawaited(_cdp!.bringToFront());
      // ★ 念のため: 起動後にまだ未ログインと分かった時は、 ここでも
      //   ログインの流れに入る (ふつうは上で先に済ませてある)。
      if (_cdp!.needsFirstLogin) {
        await _releaseCdp();
        final ok = await _firstLoginFlow(kind, acct, provider);
        if (!ok) return false;
        _cdp = await CdpBrowser.launchAndConnect(
          kind: kind,
          url: url.isEmpty ? null : url,
          useOwnProfile: true,
          profileHint: acct,
        );
        _watchCdpClosed(provider);
        unawaited(_cdp!.bringToFront());
        if (mounted) {
          setState(() => _status = provider
              .t('auto.cdpConnected')
              .replaceFirst('{name}', kind.label));
        }
        return true;
      } else if (_cdp!.downgradedFromOwnProfile) {      } else if (_cdp!.downgradedFromOwnProfile) {
        _log('注意',
            'CDP: 普段のプロファイルでは操作口が開かなかったため、'
            ' 使い捨てのプロファイルで開きました'
            ' (ログインは引き継がれていません)');
      } else if (_cdp!.openedAsGuest) {
        _log('注意',
            'CDP: ゲストモードで開きました'
            ' (ログインは引き継がれていません)');
      }
      if (mounted) {
        setState(() => _status = provider
            .t('auto.cdpConnected')
            .replaceFirst('{name}', kind.label));
      }
      return true;
    } catch (e) {
      _log('失敗', 'CDP: $e');
      if (mounted) setState(() => _status = '$e');
      return false;
    }
  }

  /// 画面を見せずに動かすか (= ユーザー要望: 「ヘッドレスか見ながらか」)。
  /// true なら実行中もブラウザを前に出さない。
  bool _agentHeadless = false;

  /// 2 択のちいさな切り替え (見出し + 左右のどちらか)。
  Widget _twoWay(
    String title, {
    required String left,
    required String right,
    required bool leftPicked,
    required VoidCallback onLeft,
    required VoidCallback onRight,
  }) {
    Widget side(String label, bool picked, VoidCallback onTap) => InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: picked
                  ? const Color(0xFF80CBC4).withValues(alpha: 0.22)
                  : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                  color:
                      picked ? const Color(0xFF80CBC4) : Colors.white24),
            ),
            child: Text(label,
                style: TextStyle(
                    color: picked
                        ? const Color(0xFF80CBC4)
                        : Colors.white60,
                    fontSize: 10.5,
                    fontWeight:
                        picked ? FontWeight.w700 : FontWeight.w400)),
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$title  ',
          style: const TextStyle(color: Colors.white38, fontSize: 10.5)),
      side(left, leftPicked, onLeft),
      const SizedBox(width: 4),
      side(right, !leftPicked, onRight),
    ]);
  }

  /// AI の返事を控える (= ユーザー要望: 自動化の所でも AI からの
  /// メッセージを表示できるように)。
  ///
  /// JSON だけを返す作りなので、 そのままだと読みにくい。 手順以外に
  /// 何か書いてあれば、 その部分を「ひとこと」 として拾う。
  void _noteAiMessage(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return;
    // JSON の外側にある文章 (説明・言い訳・確認) だけを取り出す。
    var note = t;
    final s = t.indexOf('{');
    final e = t.lastIndexOf('}');
    if (s >= 0 && e > s) {
      note = (t.substring(0, s) + t.substring(e + 1))
          .replaceAll(RegExp(r'```[a-zA-Z]*'), '')
          .trim();
    }
    // 手順だけの返事なら、 何手作ったかを短く残す。
    if (note.isEmpty) {
      note = _briefOfStepsJson(t);
    }
    if (note.isEmpty) return;
    _aiMessages.add('[${_stamp()}] $note');
    while (_aiMessages.length > 60) {
      _aiMessages.removeAt(0);
    }
    _log('AI', note.length > 300 ? '${note.substring(0, 300)}…' : note);
  }

  /// 手順だけの返事を「〜を N 手」 の形に要約する。
  String _briefOfStepsJson(String raw) {
    try {
      final s = raw.indexOf('{');
      final e = raw.lastIndexOf('}');
      if (s < 0 || e <= s) return '';
      final m = jsonDecode(raw.substring(s, e + 1));
      if (m is! Map) return '';
      if (m['done'] == true) return '(完了と判断しました)';
      final list = m['steps'];
      if (list is! List) return '';
      final kinds = <String>[];
      for (final j in list) {
        if (j is Map && j['kind'] != null) kinds.add('${j['kind']}');
      }
      if (kinds.isEmpty) return '';
      return '${kinds.join(' → ')} (${kinds.length} 手)';
    } catch (_) {
      return '';
    }
  }

  Future<bool?> _confirmCommand(String cmd) {
    return showDialog<bool>(
      // 浮かせた窓の中でも見えるように一番近い Navigator へ。
      useRootNavigator: false,
      context: context,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E32),
        title: Row(children: const [
          Icon(Icons.terminal_rounded, color: Color(0xFFFFB347), size: 20),
          SizedBox(width: 8),
          Text('このコマンドを実行しますか？',
              style: TextStyle(color: Colors.white, fontSize: 15)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(cmd,
                style: const TextStyle(
                    color: Color(0xFF9CDCFE),
                    fontSize: 12.5,
                    fontFamily: 'monospace')),
          ),
          const SizedBox(height: 10),
          const Text('パソコンの中で実行されます。 心当たりのない内容なら実行しないでください。',
              style: TextStyle(color: Colors.white54, fontSize: 11.5)),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('実行しない',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFB347),
                foregroundColor: Colors.black),
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('実行する'),
          ),
        ],
      ),
    );
  }

  // ─── 時刻で実行 (= ユーザー要望: 何時何分になったらこの動作) ─────────
  //
  //   ★ 1 つの時刻しか選べなかったのを、 **複数の時刻**・**曜日**・
  //     **日付**で指定できるようにした (= ユーザー要望)。
  static const String _kSchedPrefsKey = 'automationSchedule_v1';
  bool _schedOn = false;

  /// 動かす時刻 (0 時からの分。 例 540 = 9:00)。 小さい順に持つ。
  final List<int> _schedTimes = [];

  /// 動かす曜日 (1=月 … 7=日)。 **空なら毎日**。
  final Set<int> _schedDays = {};

  /// 動かす日付 ('MM-DD' = 毎年その日 / 'YYYY-MM-DD' = その日だけ)。
  /// **空なら日付では絞らない**。
  final Set<String> _schedDates = {};

  /// 繰り返すか。 切っていると、 1 回動いたら自動で止まる。
  bool _schedRepeat = true;
  Timer? _schedTimer;

  /// ネットにつながっているか (= ユーザー要望: 下の方の地味な 1 行ではなく、
  /// つながっていない時だけ一番上に分かり易く出す)。
  bool _online = true;
  Timer? _netTimer;

  /// 今の様子を見る。 変わった時だけ描き直す。
  Future<void> _checkNet() async {
    if (!mounted) return;
    final provider = context.read<MindMapProvider>();
    final ok = await provider.hasInternet();
    if (!mounted || ok == _online) return;
    setState(() => _online = ok);
  }

  /// 同じ時刻で二重に走らせないための控え ('2026-08-31 09:00')。
  final Set<String> _firedKeys = {};

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 分を "09:00" の形に。
  static String _hhmm(int minOfDay) =>
      '${_two(minOfDay ~/ 60)}:${_two(minOfDay % 60)}';

  Future<void> _loadSchedule() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kSchedPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map || !mounted) return;
      setState(() {
        _schedOn = m['on'] == true;
        _schedTimes.clear();
        final t = m['times'];
        if (t is List) {
          for (final e in t) {
            final v = (e as num?)?.toInt();
            if (v != null && v >= 0 && v < 1440) _schedTimes.add(v);
          }
        } else {
          // ★ 古い形 ({h, m}) からの読み替え。 1 つだけ入れる。
          final h = (m['h'] as num?)?.toInt() ?? 9;
          final mi = (m['m'] as num?)?.toInt() ?? 0;
          _schedTimes.add((h.clamp(0, 23) * 60 + mi.clamp(0, 59)).toInt());
        }
        _schedTimes.sort();
        _schedDays.clear();
        final d = m['days'];
        if (d is List) {
          for (final e in d) {
            final v = (e as num?)?.toInt();
            if (v != null && v >= 1 && v <= 7) _schedDays.add(v);
          }
        }
        _schedDates.clear();
        final dd = m['dates'];
        if (dd is List) {
          for (final e in dd) {
            final v = '$e'.trim();
            if (v.isNotEmpty) _schedDates.add(v);
          }
        }
        // 古い形の 'daily' も引き継ぐ。
        _schedRepeat = m['repeat'] is bool
            ? m['repeat'] as bool
            : (m['daily'] != false);
      });
      _restartScheduleTimer();
    } catch (_) {}
  }

  Future<void> _saveSchedule() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
          _kSchedPrefsKey,
          jsonEncode({
            'on': _schedOn,
            'times': _schedTimes,
            'days': _schedDays.toList()..sort(),
            'dates': _schedDates.toList()..sort(),
            'repeat': _schedRepeat,
          }));
    } catch (_) {}
  }

  /// その日に動かす日か (曜日と日付のしぼり込み)。
  bool _schedMatchesDay(DateTime now) {
    if (_schedDays.isNotEmpty && !_schedDays.contains(now.weekday)) {
      return false;
    }
    if (_schedDates.isEmpty) return true;
    final md = '${_two(now.month)}-${_two(now.day)}';
    final ymd = '${now.year}-$md';
    return _schedDates.contains(md) || _schedDates.contains(ymd);
  }

  void _restartScheduleTimer() {
    _schedTimer?.cancel();
    if (!_schedOn || _schedTimes.isEmpty) return;
    // 20 秒ごとに時計を見て、 指定の分に入ったら 1 回だけ走らせる。
    _schedTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted || _running || _agentBusy) return;
      final now = DateTime.now();
      final nowMin = now.hour * 60 + now.minute;
      if (!_schedTimes.contains(nowMin)) return;
      if (!_schedMatchesDay(now)) return;
      // ★ 時刻ごとに控える (= 1 日に何回も動かせるように)。
      final key = '${now.year}-${_two(now.month)}-${_two(now.day)} '
          '${_hhmm(nowMin)}';
      if (_firedKeys.contains(key)) return;
      _firedKeys.add(key);
      // 溜め込まない (前日以前の分は捨てる)。
      final today = '${now.year}-${_two(now.month)}-${_two(now.day)}';
      _firedKeys.removeWhere((k) => !k.startsWith(today));
      final provider = context.read<MindMapProvider>();
      unawaited(_run(provider).then((_) {
        if (!_schedRepeat && mounted) {
          setState(() => _schedOn = false);
          _schedTimer?.cancel();
          unawaited(_saveSchedule());
        }
      }));
    });
  }

  /// ブラウザ側が生きているか (= 手順を投げても意味がある状態か)。
  ///
  /// JS の答えを受け取れる口 (evalJs) があればそれで確かめる。 無ければ
  /// 「分からない」 = true にして、 従来どおり動かしてみる。
  Future<bool> _hasLivePage() async {
    // 外のブラウザにつないでいるなら、 そちらが生きているページ。
    final c = _cdp;
    if (c != null) return !c.isClosed;
    final eval = widget.evalJs;
    if (eval == null) return true;
    try {
      final r = await eval('location.href')
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
      final href = (r ?? '').replaceAll('"', '').trim();
      if (href.isEmpty) return false;
      if (href == 'about:blank' || href.startsWith('about:')) return false;
      return true;
    } catch (_) {
      // 確かめられなかった時は止めない (誤検知で動かせなくなる方が困る)。
      return true;
    }
  }

  /// この 1 ステップだけを試しに動かす (= ユーザー要望: スワイプ等が
  /// ちゃんと効くか項目単体で試したい)。 繰り返しブロックなら中身を 1 周。
  Future<void> _testStep(MindMapProvider provider, WebAutoStep step) async {
    if (_running) {
      setState(() => _status = provider.t('auto.alreadyRunning'));
      return;
    }
    setState(() {
      _running = true;
      _cancel = false;
      // 打ち切りの印も毎回まっさらにする。
      _loopBreak = false;
      _loopDepth = 0;
      _lastScrollPos = null;
      _lastShotPos = null;
      _shots = 0;
      _lapLabel = provider.t('auto.testRunning');
      _status = provider.t('auto.testRunning');
    });
    widget.onRunningChanged?.call(true, _requestStop);
    try {
      await _runSteps([step], '');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _status = _cancel
              ? provider.t('auto.stopped')
              : provider.t('auto.testDone').replaceFirst('{n}', '$_shots');
        });
      }
      widget.onRunningChanged?.call(false, _requestStop);
    }
  }

  String _lapLabel = '';

  /// 外 (フローティング窓のヘッダー) からも止められるようにした停止処理。
  void _requestStop() {
    if (!mounted) return;
    setState(() => _cancel = true);
  }

  /// AI に任せている途中の動きを止める。
  void _stopAgent() {
    if (!_agentBusy) return;
    _agentStop = true;
  }

  // ── Esc / Ctrl+C で「止める」 (= ユーザー要望) ──────────────────────
  //
  // 以前は Esc がダイアログ枠に届いて**欄ごと閉じて**いた。 手順を組んで
  // いる最中に閉じられると厄介なので、 この欄が出ている間は Esc を横取り
  // して、 動いていれば止める・動いていなければ何もしない (閉じない)。
  // Ctrl+C も同じ (実行中だけ横取りし、 止まっている時は普通の複写)。
  bool _handleStopKey(KeyEvent e) {
    if (!mounted) return false;
    if (e is! KeyDownEvent) return false;
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrl = keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      if (_running || _agentBusy) {
        _requestStop();
        _stopAgent();
      }
      return true; // 閉じさせない
    }
    if (ctrl && e.logicalKey == LogicalKeyboardKey.keyC) {
      if (_running || _agentBusy) {
        _requestStop();
        _stopAgent();
        return true;
      }
    }
    return false;
  }

  /// この手順を動かすのに、 先にページを開く必要があるか。
  ///
  /// = ユーザー報告「実行ボタンなど押しても効かない時がある」。
  ///   タップ / スワイプ / スクロール等はブラウザに向けて送るので、
  ///   ページを開いていないと**何も起きないまま終わる**。 黙って終わると
  ///   壊れているように見えるので、 事前に知らせる。
  bool _needsPageFirst() {
    const needsPage = {
      WebAutoKind.tap,
      WebAutoKind.hold,
      WebAutoKind.swipe,
      WebAutoKind.scroll,
      WebAutoKind.type,
      WebAutoKind.shot,
      WebAutoKind.fullShot,
      WebAutoKind.upload,
      WebAutoKind.click,
      WebAutoKind.scrollTo,
      WebAutoKind.download,
      WebAutoKind.consoleLog,
      WebAutoKind.extract,
    };
    // 手順のどこかで「リンクを開く」 があるなら、 その後は開いている。
    // ★ 外のブラウザで開く手順も同じ扱いにする (= これが抜けていたので、
    //   「外のブラウザで開く → 一番下まで送る」 というフローが 1 手も
    //   動かないまま「先にページを開いてください」 で終わっていた)。
    for (final s in _steps) {
      // openExternal は**外の既定ブラウザで開くだけ**で、 こちらから
      //   触れるページにはならない。 数に入れると、 本当に何も開いて
      //   いない時の案内が出なくなる。
      if (s.kind == WebAutoKind.open ||
          s.kind == WebAutoKind.openBrowser) {
        return false;
      }
      if (s.kind == WebAutoKind.loop) {
        for (final c in s.children) {
          if (c.kind == WebAutoKind.open ||
              c.kind == WebAutoKind.openBrowser) {
            return false;
          }
        }
      }
      if (needsPage.contains(s.kind)) return true;
      if (s.kind == WebAutoKind.loop &&
          s.children.any((c) => needsPage.contains(c.kind))) {
        return true;
      }
    }
    return false;
  }

  Future<void> _run(MindMapProvider provider) async {
    // ── 押しても何も起きない時に、 理由を出す (= ユーザー報告) ──
    if (_running) {
      setState(() => _status = provider.t('auto.alreadyRunning'));
      return;
    }
    if (_steps.isEmpty) {
      setState(() => _status = provider.t('auto.noSteps'));
      return;
    }
    if (_needsPageFirst() && !await _hasLivePage()) {
      setState(() => _status = provider.t('auto.openPageFirst'));
      return;
    }
    // ★ ネットが要る手順が入っているなら、 先に確かめる (= ユーザー要望:
    //   Wi-Fi につながっていない時は、 その旨を出してほしい)。
    if (autoStepsNeedNetwork(_steps) && !await provider.hasInternet()) {
      if (!mounted) return;
      _log('失敗', provider.t('net.offline'));
      setState(() => _status = provider.t('net.offline'));
      return;
    }
    if (_running || _steps.isEmpty) return;
    setState(() {
      _running = true;
      _cancel = false;
      // 打ち切りの印も毎回まっさらにする。
      _loopBreak = false;
      _loopDepth = 0;
      _lastScrollPos = null;
      _lastShotPos = null;
      _shots = 0;
      _status = '';
      // 前回の実行で作ったファイルは引き継がない。
      _madeFiles.clear();
    });
    widget.onRunningChanged?.call(true, _requestStop);
    try {
      for (var lap = 0; lap < _loop; lap++) {
        if (_cancel) break;
        _lapLabel = '${lap + 1}/$_loop';
        _uploadCursor.clear();
        await _runSteps(_steps, '');
      }
    } finally {
      // 外のブラウザを使ったフローなら、 終わったらつながりを切る。
      await _releaseCdp();
      if (mounted) {
        setState(() {
          _running = false;
          _status = _cancel
              ? provider.t('auto.stopped')
              : provider.t('auto.finished').replaceFirst('{n}', '$_shots');
        });
      }
      widget.onRunningChanged?.call(false, _requestStop);
    }
  }

  /// 文字列を JS のリテラルとして安全に埋め込む。
  static String _jsStr(String v) =>
      jsonEncode(v); // jsonEncode は JS リテラルとしてそのまま使える

  /// テキスト入力の JS。 セレクタがあればそれ、 無ければ座標の要素へ入れる。
  ///
  /// React などのフレームワークは value を直接書き換えても気付かないので、
  /// ネイティブの value setter を使ってから input / change を発火させる
  /// (= 一般的な「プログラムからの入力」 対策)。
  String _typeJs(WebAutoStep s) {
    final sel = _jsStr(s.selector);
    final txt = _jsStr(s.text);
    return '(function(){'
        'try{'
        'var sel=$sel;'
        'var el=sel?document.querySelector(sel):'
        'document.elementFromPoint(${s.x.round()},${s.y.round()});'
        'if(!el) return;'
        'if(el.isContentEditable){'
        'el.focus();el.textContent=$txt;'
        'el.dispatchEvent(new InputEvent("input",{bubbles:true}));'
        '}else{'
        'el.focus();'
        'var proto=el instanceof HTMLTextAreaElement?HTMLTextAreaElement.prototype'
        ':HTMLInputElement.prototype;'
        'var setter=Object.getOwnPropertyDescriptor(proto,"value");'
        'if(setter&&setter.set){setter.set.call(el,$txt);}else{el.value=$txt;}'
        'el.dispatchEvent(new Event("input",{bubbles:true}));'
        'el.dispatchEvent(new Event("change",{bubbles:true}));'
        '}'
        '${s.submit ? _submitJsFragment() : ''}'
        '}catch(e){}'
        '})();';
  }

  static String _submitJsFragment() =>
      'var ev={key:"Enter",code:"Enter",keyCode:13,which:13,bubbles:true};'
      'el.dispatchEvent(new KeyboardEvent("keydown",ev));'
      'el.dispatchEvent(new KeyboardEvent("keypress",ev));'
      'el.dispatchEvent(new KeyboardEvent("keyup",ev));'
      'if(el.form&&el.form.requestSubmit){try{el.form.requestSubmit();}catch(e){}}';

  /// 座標の要素から一意な CSS セレクタを組み立てて返す JS。
  static String _selectorAtJs(int x, int y) => '(function(){'
      'try{'
      'var el=document.elementFromPoint($x,$y);'
      'if(!el) return "";'
      // 入力欄そのものでなければ、 中の input / textarea を探す
      'if(!(el.tagName==="INPUT"||el.tagName==="TEXTAREA"||el.isContentEditable)){'
      'var inner=el.querySelector("input,textarea,[contenteditable=true]");'
      'if(inner) el=inner;'
      '}'
      'function esc(v){return (window.CSS&&CSS.escape)?CSS.escape(v):v;}'
      'if(el.id) return "#"+esc(el.id);'
      'var name=el.getAttribute("name");'
      'if(name) return el.tagName.toLowerCase()+"[name=\\""+name+"\\"]";'
      'var al=el.getAttribute("aria-label");'
      'if(al) return el.tagName.toLowerCase()+"[aria-label=\\""+al+"\\"]";'
      // 親からの path を作る (nth-of-type で一意化)
      'var parts=[];var cur=el;'
      'while(cur&&cur.nodeType===1&&parts.length<6){'
      'var sel=cur.tagName.toLowerCase();'
      'if(cur.id){parts.unshift("#"+esc(cur.id));break;}'
      'var p=cur.parentElement;'
      'if(p){var same=Array.prototype.filter.call(p.children,function(c){'
      'return c.tagName===cur.tagName;});'
      'if(same.length>1){sel+=":nth-of-type("+(same.indexOf(cur)+1)+")";}}'
      'parts.unshift(sel);cur=p;'
      '}'
      'return parts.join(" > ");'
      '}catch(e){return "";}'
      '})();';

  /// GUI で入力先の要素を選ぶ (= ユーザー要望)。
  Future<void> _pickElementFor(WebAutoStep s) async {
    final p = await widget.pickPoint();
    if (p == null) return;
    setState(() {
      s.x = p.dx;
      s.y = p.dy;
    });
    final ev = widget.evalJs;
    if (ev != null) {
      try {
        final raw = await ev(_selectorAtJs(p.dx.round(), p.dy.round()));
        var sel = (raw ?? '').trim();
        // webview によっては JSON 文字列 ("\"#id\"") で返ってくる。
        if (sel.length >= 2 && sel.startsWith('"') && sel.endsWith('"')) {
          try {
            sel = jsonDecode(sel) as String;
          } catch (_) {}
        }
        if (sel.isNotEmpty && sel != 'null') {
          setState(() => s.selector = sel);
        }
      } catch (_) {}
    }
    _save();
  }

  String _kindLabel(MindMapProvider p, WebAutoKind k) {
    switch (k) {
      case WebAutoKind.tap:
        return p.t('auto.kindTap');
      case WebAutoKind.hold:
        return p.t('auto.kindHold');
      case WebAutoKind.swipe:
        return p.t('auto.kindSwipe');
      case WebAutoKind.scroll:
        return p.t('auto.kindScroll');
      case WebAutoKind.wait:
        return p.t('auto.kindWait');
      case WebAutoKind.shot:
        return p.t('auto.kindShot');
      case WebAutoKind.fullShot:
        return p.t('auto.kindFullShot');
      case WebAutoKind.download:
        return p.t('auto.kindDownload');
      case WebAutoKind.consoleLog:
        return p.t('auto.kindConsoleLog');
      case WebAutoKind.extract:
        return p.t('auto.kindExtract');
      case WebAutoKind.upload:
        return p.t('auto.kindUpload');
      case WebAutoKind.makeFile:
        return p.t('auto.kindMakeFile');
      case WebAutoKind.type:
        return p.t('auto.kindType');
      case WebAutoKind.open:
        return p.t('auto.kindOpen');
      case WebAutoKind.loop:
        return p.t('auto.kindLoop');
      case WebAutoKind.click:
        return p.t('auto.kindClick');
      case WebAutoKind.scrollTo:
        return p.t('auto.kindScrollTo');
      case WebAutoKind.openExternal:
        return '外のブラウザで開く';
      case WebAutoKind.command:
        return 'コマンド実行';
      // ── パソコンそのものの操作 ──
      case WebAutoKind.osActivate:
        return p.t('auto.kindOsActivate');
      case WebAutoKind.osClick:
        return p.t('auto.kindOsClick');
      case WebAutoKind.osMove:
        return p.t('auto.kindOsMove');
      case WebAutoKind.osType:
        return p.t('auto.kindOsType');
      case WebAutoKind.osKey:
        return p.t('auto.kindOsKey');
      case WebAutoKind.osScroll:
        return p.t('auto.kindOsScroll');
      case WebAutoKind.osShot:
        return p.t('auto.kindOsShot');
      case WebAutoKind.ask:
        return p.t('auto.kindAsk');
      case WebAutoKind.openBrowser:
        return p.t('auto.kindOpenBrowser');
    }
  }

  IconData _kindIcon(WebAutoKind k) {
    switch (k) {
      case WebAutoKind.tap:
        return Icons.touch_app_rounded;
      case WebAutoKind.hold:
        return Icons.timer_rounded;
      case WebAutoKind.swipe:
        return Icons.swipe_rounded;
      case WebAutoKind.scroll:
        return Icons.swap_vert_rounded;
      case WebAutoKind.wait:
        return Icons.hourglass_bottom_rounded;
      case WebAutoKind.shot:
        return Icons.photo_camera_rounded;
      case WebAutoKind.fullShot:
        return Icons.photo_size_select_actual_rounded;
      case WebAutoKind.download:
        return Icons.download_rounded;
      case WebAutoKind.consoleLog:
        return Icons.terminal_rounded;
      case WebAutoKind.extract:
        return Icons.text_snippet_rounded;
      case WebAutoKind.upload:
        return Icons.upload_file_rounded;
      case WebAutoKind.makeFile:
        return Icons.note_add_rounded;
      case WebAutoKind.type:
        return Icons.keyboard_rounded;
      case WebAutoKind.open:
        return Icons.link_rounded;
      case WebAutoKind.openExternal:
        return Icons.open_in_new_rounded;
      case WebAutoKind.command:
        return Icons.terminal_rounded;
      case WebAutoKind.loop:
        return Icons.repeat_rounded;
      case WebAutoKind.click:
        return Icons.ads_click_rounded;
      case WebAutoKind.scrollTo:
        return Icons.vertical_align_bottom_rounded;
      // ── パソコンそのものの操作 ──
      case WebAutoKind.osActivate:
        return Icons.desktop_windows_rounded;
      case WebAutoKind.osClick:
        return Icons.mouse_rounded;
      case WebAutoKind.osMove:
        return Icons.open_with_rounded;
      case WebAutoKind.osType:
        return Icons.keyboard_alt_rounded;
      case WebAutoKind.osKey:
        return Icons.keyboard_command_key_rounded;
      case WebAutoKind.osScroll:
        return Icons.unfold_more_rounded;
      case WebAutoKind.osShot:
        return Icons.screenshot_monitor_rounded;
      case WebAutoKind.ask:
        return Icons.help_outline_rounded;
      case WebAutoKind.openBrowser:
        return Icons.travel_explore_rounded;
    }
  }

  Widget _numField(String label, int value, ValueChanged<int> onChanged,
      {double width = 74}) {
    return SizedBox(
      width: width,
      child: TextFormField(
        initialValue: '$value',
        keyboardType: TextInputType.number,
        style: const TextStyle(color: Colors.white, fontSize: 12),
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54, fontSize: 10),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.06),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide.none),
        ),
        onChanged: (v) {
          final n = int.tryParse(v.trim());
          if (n != null) {
            onChanged(n);
            _save();
          }
        },
      ),
    );
  }

  /// 「時刻で実行」 の行 (= ユーザー要望: 一番下に置く)。 パソコン版だけ。
  ///
  /// ★ 1 つの時刻しか選べなかったのを、 複数の時刻・曜日・日付で
  ///   指定できるようにした (= ユーザー要望)。
  Widget _buildScheduleRow(MindMapProvider provider) {
    if (!_isDesktopHost) return const SizedBox.shrink();

    Widget chip(String label, {VoidCallback? onDelete, VoidCallback? onTap}) =>
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A44),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(label,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 11.5)),
                if (onDelete != null) ...[
                  const SizedBox(width: 4),
                  InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: onDelete,
                    child: const Icon(Icons.close_rounded,
                        size: 13, color: Colors.white54),
                  ),
                ],
              ]),
            ),
          ),
        );

    Widget addBtn(String label, IconData icon, VoidCallback onTap) =>
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF80CBC4),
            side: const BorderSide(color: Color(0xFF80CBC4)),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 26),
            visualDensity: VisualDensity.compact,
          ),
          icon: Icon(icon, size: 13),
          label: Text(label, style: const TextStyle(fontSize: 11)),
          onPressed: onTap,
        );

    // 曜日の並び (月曜はじまり)。
    const dayKeys = [
      (1, 'week.mon'),
      (2, 'week.tue'),
      (3, 'week.wed'),
      (4, 'week.thu'),
      (5, 'week.fri'),
      (6, 'week.sat'),
      (7, 'week.sun'),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 入り口のスイッチ (見出しを押すとたためる = ユーザー要望) ──
              // ★ 切っているのに時刻が出ていると、 その時刻で動くように
              //   見える (= ユーザー指摘)。 中身は入れている間だけ出す。
              //   たたんでいても、 入 / 切と下の要約 1 行は見えたまま。
              _sectionHead(
                provider,
                provider.t('auto.schedTitle'),
                open: _schedOpen,
                icon: Icons.schedule_rounded,
                color: const Color(0xFF80CBC4),
                onTap: () {
                  setState(() => _schedOpen = !_schedOpen);
                  unawaited(_saveAgentOpts());
                },
                trailing: [
                Switch(
                  value: _schedOn,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) async {
                    setState(() {
                      _schedOn = v;
                      // 初めて入れた時は 9:00 を 1 つ用意しておく。
                      if (v && _schedTimes.isEmpty) _schedTimes.add(9 * 60);
                    });
                    await _saveSchedule();
                    _restartScheduleTimer();
                  },
                ),
                ],
              ),
              if (_schedOpen && _schedOn) ...[
                Row(children: [
                  const SizedBox(width: 21),
                  InkWell(
                    onTap: () async {
                      setState(() => _schedRepeat = !_schedRepeat);
                      await _saveSchedule();
                    },
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(
                          _schedRepeat
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 15,
                          color: _schedRepeat
                              ? const Color(0xFF80CBC4)
                              : Colors.white38),
                      const SizedBox(width: 3),
                      Text(provider.t('auto.schedRepeat'),
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 11)),
                    ]),
                  ),
                ]),
              ],
              if (_schedOpen && _schedOn) ...[
                const SizedBox(height: 6),
                // ── 時刻 (いくつでも) ──
                Text(provider.t('auto.schedTimes'),
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 10)),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final t in _schedTimes)
                    chip(_hhmm(t), onDelete: () async {
                      setState(() => _schedTimes.remove(t));
                      await _saveSchedule();
                      _restartScheduleTimer();
                    }, onTap: () async {
                      final picked = await showTimePicker(
                        context: context,
                        // ★ 根っこの Navigator を使わない。 この画面は
                        //   Overlay に載っているので、 既定のままだと
                        //   時刻の選択が自動化の枠の**下**に出る
                        //   (= ユーザー報告)。
                        useRootNavigator: false,
                        initialTime:
                            TimeOfDay(hour: t ~/ 60, minute: t % 60),
                      );
                      if (picked == null || !mounted) return;
                      final v = picked.hour * 60 + picked.minute;
                      setState(() {
                        _schedTimes.remove(t);
                        if (!_schedTimes.contains(v)) _schedTimes.add(v);
                        _schedTimes.sort();
                      });
                      await _saveSchedule();
                      _restartScheduleTimer();
                    }),
                  addBtn(provider.t('auto.schedAddTime'),
                      Icons.add_alarm_rounded, () async {
                    final picked = await showTimePicker(
                      context: context,
                      useRootNavigator: false,
                      initialTime: const TimeOfDay(hour: 9, minute: 0),
                    );
                    if (picked == null || !mounted) return;
                    final v = picked.hour * 60 + picked.minute;
                    setState(() {
                      if (!_schedTimes.contains(v)) _schedTimes.add(v);
                      _schedTimes.sort();
                    });
                    await _saveSchedule();
                    _restartScheduleTimer();
                  }),
                ]),
                const SizedBox(height: 8),
                // ── 曜日 (選ばなければ毎日) ──
                Text(provider.t('auto.schedDays'),
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 10)),
                const SizedBox(height: 4),
                Wrap(spacing: 4, runSpacing: 4, children: [
                  for (final d in dayKeys)
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () async {
                          setState(() {
                            if (!_schedDays.add(d.$1)) {
                              _schedDays.remove(d.$1);
                            }
                          });
                          await _saveSchedule();
                        },
                        child: Container(
                          width: 30,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _schedDays.contains(d.$1)
                                ? const Color(0xFF80CBC4)
                                    .withValues(alpha: 0.26)
                                : const Color(0xFF2A2A44),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                                color: _schedDays.contains(d.$1)
                                    ? const Color(0xFF80CBC4)
                                    : Colors.white24),
                          ),
                          child: Text(provider.t(d.$2),
                              style: TextStyle(
                                  color: _schedDays.contains(d.$1)
                                      ? Colors.white
                                      : Colors.white54,
                                  fontSize: 11)),
                        ),
                      ),
                    ),
                  if (_schedDays.isNotEmpty)
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: Colors.white38,
                        minimumSize: const Size(0, 26),
                      ),
                      onPressed: () async {
                        setState(_schedDays.clear);
                        await _saveSchedule();
                      },
                      child: Text(provider.t('auto.schedEveryDay'),
                          style: const TextStyle(fontSize: 10.5)),
                    ),
                ]),
                const SizedBox(height: 8),
                // ── 日付 (選ばなければ絞らない) ──
                Text(provider.t('auto.schedDates'),
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 10)),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final d in _schedDates.toList()..sort())
                    chip(d, onDelete: () async {
                      setState(() => _schedDates.remove(d));
                      await _saveSchedule();
                    }),
                  addBtn(provider.t('auto.schedAddDate'),
                      Icons.event_rounded, () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: context,
                      useRootNavigator: false,
                      initialDate: now,
                      firstDate: DateTime(now.year - 1),
                      lastDate: DateTime(now.year + 5),
                    );
                    if (picked == null || !mounted) return;
                    setState(() => _schedDates.add(
                        '${picked.year}-${_two(picked.month)}'
                        '-${_two(picked.day)}'));
                    await _saveSchedule();
                  }),
                  if (_schedDates.isNotEmpty)
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: Colors.white38,
                        minimumSize: const Size(0, 26),
                      ),
                      onPressed: () async {
                        setState(_schedDates.clear);
                        await _saveSchedule();
                      },
                      child: Text(provider.t('auto.schedAnyDate'),
                          style: const TextStyle(fontSize: 10.5)),
                    ),
                ]),
              ],
              const SizedBox(height: 4),
              // ★ オフの時に「動かします」 とだけ書いてあると、 切っていても
              //   時刻で動くように読める (= ユーザー指摘)。 今どちらなのかを
              //   最初に書く。
              Padding(
                padding: const EdgeInsets.only(left: 21, bottom: 2),
                child: Text(_schedSummary(provider),
                    style: TextStyle(
                        color: _schedOn
                            ? const Color(0xFF80CBC4)
                            : Colors.white38,
                        fontSize: 10)),
              ),
            ]),
      ),
    );
  }

  /// 今の設定を 1 行で言い直す (何が起きるのかを読めるように)。
  String _schedSummary(MindMapProvider provider) {
    if (!_schedOn) return provider.t('auto.schedOffNote');
    if (_schedTimes.isEmpty) return provider.t('auto.schedNoTime');
    const names = [
      'week.mon',
      'week.tue',
      'week.wed',
      'week.thu',
      'week.fri',
      'week.sat',
      'week.sun',
    ];
    final when = _schedDays.isEmpty
        ? provider.t('auto.schedEveryDay')
        : (_schedDays.toList()..sort())
            .map((d) => provider.t(names[d - 1]))
            .join('・');
    final dates = _schedDates.isEmpty
        ? ''
        : ' / ${(_schedDates.toList()..sort()).join('・')}';
    return provider
        .t('auto.schedOnNote')
        .replaceFirst('{when}', when)
        .replaceFirst('{times}', _schedTimes.map(_hhmm).join('・'))
        .replaceFirst('{dates}', dates)
        .replaceFirst('{repeat}',
            provider.t(_schedRepeat ? 'auto.schedRepeatOn' : 'auto.schedOnce'));
  }

  /// 「コマンドの許可」 の行 (= ユーザー要望: AI の欄のすぐ下に置く)。
  ///
  /// パソコン版だけ。 既定は「使わない」 で、 自分で切り替えるまで動かない。
  Widget _buildCommandRow(MindMapProvider provider) {
    if (!_isDesktopHost) return const SizedBox.shrink();
    // ★ ストア提出版ではコマンド実行の設定ごと出さない (= 任意コマンドを
    //   実行できる仕組みは「コード実行」 とみなされるため)。
    if (kStoreBuild) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── コマンドの許可 (見出しを押すとたためる = ユーザー要望) ──
              // ★ この設定は OS の操作 (os… の手順) にも効くので、 名前は
              //   「コマンド実行 / パソコンの操作」 とまとめて書く。
              _sectionHead(
                provider,
                DesktopInput.isSupported
                    ? provider.t('auto.cmdSection')
                    : 'コマンド実行',
                open: _cmdOpen,
                icon: Icons.terminal_rounded,
                color: const Color(0xFFFFB347),
                onTap: () {
                  setState(() => _cmdOpen = !_cmdOpen);
                  unawaited(_saveAgentOpts());
                },
                trailing: [
                  // たたんでいる間も、 今どの設定かは分かるようにする。
                  if (!_cmdOpen)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                          _cmdPolicy == AutoCommandPolicy.off
                              ? '使わない'
                              : (_cmdPolicy == AutoCommandPolicy.ask
                                  ? '毎回確認'
                                  : '全部任せる'),
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 10.5)),
                    ),
                ],
              ),
              if (_cmdOpen)
              Row(children: [
                const SizedBox(width: 21),
                Expanded(
                  child: Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final (v, label) in const [
                      (AutoCommandPolicy.off, '使わない'),
                      (AutoCommandPolicy.ask, '毎回確認'),
                      (AutoCommandPolicy.always, '全部任せる'),
                    ])
                      ChoiceChip(
                        label: Text(label,
                            style: const TextStyle(fontSize: 11)),
                        selected: _cmdPolicy == v,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) async {
                          setState(() => _cmdPolicy = v);
                          await _saveCmdPolicy();
                        },
                      ),
                  ]),
                ),
                if (_cmdLog.isNotEmpty)
                  IconButton(
                    tooltip: '実行したコマンドの記録',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.receipt_long_rounded,
                        size: 16, color: Colors.white54),
                    onPressed: _showCmdLog,
                  ),
              ]),
              if (_cmdOpen)
              Padding(
                padding: const EdgeInsets.only(left: 21, top: 2),
                child: Text(
                    _cmdPolicy == AutoCommandPolicy.off
                        ? '今は実行しません。 手順に入っていても飛ばします。'
                        : (_cmdPolicy == AutoCommandPolicy.ask
                            ? '実行のたびに中身を見せて確認します。'
                            : '確認なしで実行します。 壊す恐れのある操作だけは断ります。') +
                        // ★ 何が動くのかをはっきり書く (= マウスとキーボードを
                        //   乗っ取る操作なので、 知らずに「全部任せる」 に
                        //   しないように)。
                        (DesktopInput.isSupported
                            ? '\nパソコンの操作 (マウス・キーボード・窓) も'
                                'この設定に従います。'
                            : ''),
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 10)),
              ),
            ]),
      ),
    );
  }

  /// 実行したコマンドの記録を見せる。
  void _showCmdLog() {
    _showNearDialog<void>(
      maxWidth: 470,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E32),
        title: const Text('実行したコマンド',
            style: TextStyle(color: Colors.white, fontSize: 15)),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: SelectableText(_cmdLog.join('\n'),
                style: const TextStyle(
                    color: Color(0xFFB3E5FC),
                    fontSize: 11.5,
                    fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(_cmdLog.clear);
              Navigator.pop(dctx);
            },
            child: const Text('記録を消す',
                style: TextStyle(color: Color(0xFFE57373))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('閉じる',
                style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  /// 動いた記録 (= ユーザー要望: 開発のテストに使いたいので、 デバッグ用の
  /// 記録と AI からのメッセージを見られるように)。
  void _showRunLog() {
    final provider = context.read<MindMapProvider>();
    _showNearDialog<void>(
      maxWidth: 620,
      builder: (dctx) => StatefulBuilder(builder: (dctx2, setL) {
        var tab = 0; // 0 = 動いた記録、 1 = AI のメッセージ
        return StatefulBuilder(builder: (_, setInner) {
          Widget chip(int i, String label, int n) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => setInner(() => tab = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 11, vertical: 5),
                    decoration: BoxDecoration(
                      color: tab == i
                          ? const Color(0xFF80CBC4).withValues(alpha: 0.22)
                          : Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: tab == i
                              ? const Color(0xFF80CBC4)
                              : Colors.white24),
                    ),
                    child: Text('$label ($n)',
                        style: TextStyle(
                            color: tab == i
                                ? const Color(0xFF80CBC4)
                                : Colors.white70,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              );
          final body = tab == 0 ? _runLog : _aiMessages;
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E32),
            title: Row(children: [
              const Icon(Icons.bug_report_rounded,
                  color: Color(0xFF80CBC4), size: 19),
              const SizedBox(width: 8),
              Expanded(
                child: Text(provider.t('auto.runLog'),
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
              ),
            ]),
            content: SizedBox(
              width: 600,
              height: 380,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    chip(0, provider.t('auto.runLogSteps'), _runLog.length),
                    chip(1, provider.t('auto.runLogAi'), _aiMessages.length),
                  ]),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.30),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: SingleChildScrollView(
                        reverse: true,
                        child: SelectableText(
                            body.isEmpty
                                ? provider.t('auto.runLogEmpty')
                                : body.join('\n'),
                            style: TextStyle(
                                color: body.isEmpty
                                    ? Colors.white38
                                    : const Color(0xFFB3E5FC),
                                fontSize: 11.5,
                                height: 1.5,
                                fontFamily: 'monospace')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: body.join('\n')));
                  if (dctx2.mounted) Navigator.pop(dctx2);
                },
                child: Text(provider.t('auto.runLogCopy'),
                    style: const TextStyle(color: Color(0xFF4FC3F7))),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    _runLog.clear();
                    _aiMessages.clear();
                  });
                  Navigator.pop(dctx2);
                },
                child: Text(provider.t('auto.runLogClear'),
                    style: const TextStyle(color: Color(0xFFE57373))),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dctx2),
                child: Text(provider.t('btn.close'),
                    style: const TextStyle(color: Colors.white54)),
              ),
            ],
          );
        });
      }),
    );
  }

  /// 追加できる種類のチップ列。 [into] に追加する。
  /// たためる欄の見出し (= ユーザー要望: プロンプト欄・コマンド実行欄・
  /// ボタンの一覧をたたんで、 フローの表示領域を広く使えるように)。
  ///
  /// 見出しのどこを押しても開閉する。 右端の▼が今の状態を表す。
  Widget _sectionHead(
    MindMapProvider provider,
    String label, {
    required bool open,
    required VoidCallback onTap,
    IconData? icon,
    Color color = Colors.white70,
    double fontSize = 11.5,
    List<Widget> trailing = const [],
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(label,
                maxLines: open ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: fontSize)),
          ),
          ...trailing,
          Tooltip(
            message: provider.t(open ? 'auto.collapse' : 'auto.expand'),
            child: Icon(
                open
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 18,
                color: Colors.white54),
          ),
        ]),
      ),
    );
  }

  Widget _addChips(MindMapProvider provider, List<WebAutoStep> into) {
    return Wrap(spacing: 6, runSpacing: 6, children: [
      // ★ 「全体を 1 枚」 は別項目にせず、 スクショの中の
      //   「ページ全体」 切替えにまとめた (= ユーザー要望: 分かりにくい)。
      for (final k in WebAutoKind.values.where((k) => k != WebAutoKind.fullShot))
        ActionChip(
          avatar: Icon(_kindIcon(k), size: 14, color: Colors.white70),
          label: Text(_kindLabel(provider, k),
              style: const TextStyle(color: Colors.white, fontSize: 10.5)),
          backgroundColor: const Color(0xFF2A2A44),
          side: BorderSide.none,
          visualDensity: VisualDensity.compact,
          onPressed: () {
            setState(() => into.add(WebAutoStep(
                  kind: k,
                  count: k == WebAutoKind.loop ? 2 : 1,
                  durationMs: k == WebAutoKind.scroll
                      ? 600
                      : (k == WebAutoKind.wait
                          ? 1000
                          : (k == WebAutoKind.open
                              ? 2000
                              // ダウンロードは終わるまで待つので長め。
                              : (k == WebAutoKind.download
                                  ? 60000
                                  : (k == WebAutoKind.scrollTo ||
                                          k == WebAutoKind.click
                                      ? 1200
                                      : 400)))),
                  // 取り出す物の既定は本文。
                  text: k == WebAutoKind.extract ? 'text' : '',
                  // 端まで送るのは既定で「一番下」 (フッター狙い)。
                  scrollDir:
                      k == WebAutoKind.scrollTo ? 'bottom' : 'down',
                )));
            _save();
          },
        ),
    ]);
  }

  // ─── フローの複数選択 (= ユーザー要望: Ctrl / Shift でまとめて消す) ───
  /// 選んでいる手順 (同一性で持つので、 入れ子の中身も同じ仕組みで扱える)。
  final Set<WebAutoStep> _stepSel = <WebAutoStep>{};

  /// Shift の範囲選択の起点 (同じ list の中だけで有効)。
  List<WebAutoStep>? _selAnchorList;
  int _selAnchorIndex = -1;

  void _toggleStepSel(List<WebAutoStep> list, int index) {
    final keys = HardwareKeyboard.instance;
    setState(() {
      if (keys.isShiftPressed &&
          identical(_selAnchorList, list) &&
          _selAnchorIndex >= 0) {
        final lo = _selAnchorIndex < index ? _selAnchorIndex : index;
        final hi = _selAnchorIndex < index ? index : _selAnchorIndex;
        for (var k = lo; k <= hi && k < list.length; k++) {
          _stepSel.add(list[k]);
        }
        return;
      }
      final s = list[index];
      if (_stepSel.contains(s)) {
        _stepSel.remove(s);
      } else {
        _stepSel.add(s);
      }
      _selAnchorList = list;
      _selAnchorIndex = index;
    });
  }

  /// 選んだ手順をまとめて消す (入れ子の中も辿る)。
  void _deleteSelectedSteps() {
    void prune(List<WebAutoStep> list) {
      list.removeWhere(_stepSel.contains);
      for (final s in list) {
        if (s.kind == WebAutoKind.loop) prune(s.children);
      }
    }

    setState(() {
      prune(_steps);
      _stepSel.clear();
      _selAnchorList = null;
      _selAnchorIndex = -1;
    });
    _save();
  }

  /// 1 ステップのタイル。 繰り返しブロックは中に子ステップを並べる
  /// (= ユーザー要望: 繰り返しの中に処理ブロックを置き、 そこから出ると
  /// 繰り返し終了になるように = 開始 / 終了ボタンを 1 つに統合)。
  Widget _stepTile(MindMapProvider provider, List<WebAutoStep> list, int index,
      {String path = ''}) {
    final s = list[index];
    final isLoop = s.kind == WebAutoKind.loop;
    final label = path.isEmpty ? '${index + 1}' : '$path-${index + 1}';
    // ── Ctrl / Shift でまとめて選ぶ (= ユーザー要望: フローもまとめて消したい)。
    //    見出しの行をクリックで選択。 選択中は上のバーからまとめて消せる。
    final picked = _stepSel.contains(s);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: picked
            ? const Color(0xFF6C63FF).withValues(alpha: 0.20)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: picked ? const Color(0xFF8D86FF) : Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            // 見出しをクリック = 選択の足し引き (Shift で範囲)。
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _toggleStepSel(list, index),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 2, vertical: 2),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(picked ? Icons.check_circle_rounded : _kindIcon(s.kind),
                      size: 15,
                      color: picked
                          ? const Color(0xFF8D86FF)
                          : const Color(0xFF80CBC4)),
                  const SizedBox(width: 6),
                  Text('$label. ${_kindLabel(provider, s.kind)}',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight:
                              isLoop ? FontWeight.w700 : FontWeight.w400)),
                ]),
              ),
            ),
            const Spacer(),
            // ── 畳む / 開く (= ユーザー要望: 手順が多くなってきたので) ──
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              tooltip: provider.t(_collapsedSteps.contains(s)
                  ? 'auto.stepExpand'
                  : 'auto.stepCollapse'),
              icon: Icon(
                  _collapsedSteps.contains(s)
                      ? Icons.unfold_more_rounded
                      : Icons.unfold_less_rounded,
                  size: 15,
                  color: Colors.white38),
              onPressed: () => setState(() {
                if (!_collapsedSteps.remove(s)) _collapsedSteps.add(s);
              }),
            ),
            // この項目だけ試す (= ユーザー要望)
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              tooltip: provider.t('auto.testStep'),
              icon: Icon(Icons.play_circle_fill_rounded,
                  size: 17,
                  color: _running
                      ? Colors.white24
                      : const Color(0xFF43B97F)),
              onPressed: _running ? null : () => _testStep(provider, s),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              icon: const Icon(Icons.arrow_upward_rounded,
                  size: 15, color: Colors.white38),
              onPressed: index == 0
                  ? null
                  : () {
                      setState(() {
                        final t = list.removeAt(index);
                        list.insert(index - 1, t);
                      });
                      _save();
                    },
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              icon: const Icon(Icons.arrow_downward_rounded,
                  size: 15, color: Colors.white38),
              onPressed: index >= list.length - 1
                  ? null
                  : () {
                      setState(() {
                        final t = list.removeAt(index);
                        list.insert(index + 1, t);
                      });
                      _save();
                    },
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              icon: const Icon(Icons.close_rounded,
                  size: 15, color: Colors.redAccent),
              onPressed: () {
                setState(() => list.removeAt(index));
                _save();
              },
            ),
          ]),
          // ── 中身の畳み方 (= ユーザー要望: 手順が多くなってきたので
          //    折り畳めるように) ──
          //    畳んでいる時は、 何が入っているかを 1 行で見せる。
          if (_collapsedSteps.contains(s))
            Padding(
              padding: const EdgeInsets.only(left: 21, top: 2, bottom: 2),
              child: Text(_stepSummary(s),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white38, fontSize: 10.5)),
            ),
          if (!_collapsedSteps.contains(s)) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (s.kind == WebAutoKind.tap ||
                s.kind == WebAutoKind.hold ||
                s.kind == WebAutoKind.swipe)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF4FC3F7),
                  side: const BorderSide(color: Color(0xFF4FC3F7)),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                icon: const Icon(Icons.my_location_rounded, size: 14),
                label: Text(
                    '${provider.t('auto.pickPoint')} '
                    '(${s.x.round()},${s.y.round()})',
                    style: const TextStyle(fontSize: 10.5)),
                onPressed: () async {
                  final p = await widget.pickPoint();
                  if (p == null) return;
                  setState(() {
                    s.x = p.dx;
                    s.y = p.dy;
                  });
                  // スワイプは始点を決めたらそのまま終点の指定へ移る
                  // (= ユーザー要望: まとめて設定できるように)。
                  if (s.kind == WebAutoKind.swipe) {
                    final e = await widget.pickPoint();
                    if (e != null) {
                      setState(() {
                        s.x2 = e.dx;
                        s.y2 = e.dy;
                      });
                    }
                  }
                  _save();
                },
              ),
            if (s.kind == WebAutoKind.swipe)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFFB74D),
                  side: const BorderSide(color: Color(0xFFFFB74D)),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                icon: const Icon(Icons.flag_rounded, size: 14),
                label: Text(
                    '${provider.t('auto.pickEnd')} '
                    '(${s.x2.round()},${s.y2.round()})',
                    style: const TextStyle(fontSize: 10.5)),
                onPressed: () async {
                  final p = await widget.pickPoint();
                  if (p == null) return;
                  setState(() {
                    s.x2 = p.dx;
                    s.y2 = p.dy;
                  });
                  _save();
                },
              ),
            // ── リンクを開く (= ユーザー要望: 「このページを開いて上から下まで
            //    スクショ」 のような手順を組めるように) ──
            if (s.kind == WebAutoKind.open) ...[
              SizedBox(
                width: 300,
                child: TextFormField(
                  initialValue: s.text,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: provider.t('auto.openUrl'),
                    labelStyle:
                        const TextStyle(color: Colors.white54, fontSize: 10),
                    hintText: 'https://example.com/',
                    hintStyle:
                        const TextStyle(color: Colors.white24, fontSize: 10),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none),
                  ),
                  onChanged: (v) {
                    s.text = v.trim();
                    _save();
                  },
                ),
              ),
              _numField(provider.t('auto.openWait'), s.durationMs, (v) {
                s.durationMs = v.clamp(0, 60000);
              }, width: 96),
            ],
            // ── 外のブラウザで開く (= ユーザー要望) ──
            if (s.kind == WebAutoKind.openExternal) ...[
              SizedBox(
                width: 300,
                child: TextFormField(
                  initialValue: s.text,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: '開くページ',
                    labelStyle:
                        const TextStyle(color: Colors.white54, fontSize: 10),
                    hintText: 'https://example.com/',
                    hintStyle:
                        const TextStyle(color: Colors.white24, fontSize: 10),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none),
                  ),
                  onChanged: (v) {
                    s.text = v.trim();
                    _save();
                  },
                ),
              ),
              _numField('待ち(ms)', s.durationMs, (v) {
                s.durationMs = v.clamp(0, 60000);
              }, width: 92),
            ],
            // ── コマンド実行 (= ユーザー要望: ターミナル操作) ──
            if (s.kind == WebAutoKind.command) ...[
              SizedBox(
                width: 320,
                child: TextFormField(
                  initialValue: s.text,
                  style: const TextStyle(
                      color: Color(0xFF9CDCFE),
                      fontSize: 12,
                      fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'コマンド',
                    labelStyle:
                        const TextStyle(color: Colors.white54, fontSize: 10),
                    hintText: Platform.isWindows
                        ? 'echo hello   (cmd で実行)'
                        : 'echo hello   (sh で実行)',
                    hintStyle:
                        const TextStyle(color: Colors.white24, fontSize: 10),
                    filled: true,
                    fillColor: Colors.black.withValues(alpha: 0.30),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none),
                  ),
                  onChanged: (v) {
                    s.text = v;
                    _save();
                  },
                ),
              ),
              _numField('打ち切り(ms)', s.durationMs, (v) {
                s.durationMs = v.clamp(1000, 600000);
              }, width: 108),
            ],
            // ── 要素を押す (= ユーザー報告: 座標だと切り替えられない) ──
            if (s.kind == WebAutoKind.click) ...[
              SizedBox(
                width: 240,
                child: TextFormField(
                  initialValue: s.text,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: provider.t('auto.clickText'),
                    labelStyle:
                        const TextStyle(color: Colors.white54, fontSize: 10),
                    hintText: provider.t('auto.clickTextHint'),
                    hintStyle:
                        const TextStyle(color: Colors.white24, fontSize: 10),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none),
                  ),
                  onChanged: (v) {
                    s.text = v.trim();
                    _save();
                  },
                ),
              ),
              _numField(provider.t('auto.openWait'), s.durationMs, (v) {
                s.durationMs = v.clamp(0, 60000);
              }, width: 96),
            ],
            // ── 端まで送る (= フッターの撮影を確実にする) ──
            if (s.kind == WebAutoKind.scrollTo) ...[
              for (final d in const ['bottom', 'top'])
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ChoiceChip(
                    label: Text(
                        provider.t(d == 'bottom'
                            ? 'auto.scrollBottom'
                            : 'auto.scrollTop'),
                        style: const TextStyle(fontSize: 10.5)),
                    selected: s.scrollDir == d,
                    visualDensity: VisualDensity.compact,
                    backgroundColor: const Color(0xFF2A2A44),
                    selectedColor: const Color(0xFFBA68C8),
                    labelStyle: TextStyle(
                        color: s.scrollDir == d
                            ? Colors.black
                            : Colors.white70),
                    onSelected: (_) {
                      setState(() => s.scrollDir = d);
                      _save();
                    },
                  ),
                ),
              _numField(provider.t('auto.openWait'), s.durationMs, (v) {
                s.durationMs = v.clamp(0, 60000);
              }, width: 96),
            ],
            // ── ダウンロード (= ユーザー要望) ──
            if (s.kind == WebAutoKind.download) ...[
              SizedBox(
                width: 170,
                child: TextFormField(
                  initialValue: s.text,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: _fieldDeco(provider.t('auto.dlLabel')),
                  onChanged: (v) {
                    s.text = v;
                    _save();
                  },
                ),
              ),
              SizedBox(
                width: 230,
                child: TextFormField(
                  initialValue: s.selector,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: _fieldDeco(provider.t('auto.dlTarget')),
                  onChanged: (v) {
                    s.selector = v.trim();
                    _save();
                  },
                ),
              ),
            ],
            // ── ページのログ (= ユーザー要望) ──
            if (s.kind == WebAutoKind.consoleLog)
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<int>(
                  initialValue: s.count <= 0 ? 0 : 1,
                  dropdownColor: const Color(0xFF23233A),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: _fieldDeco(provider.t('auto.logMode')),
                  items: [
                    DropdownMenuItem(
                        value: 0,
                        child: Text(provider.t('auto.logModeStart'),
                            style: const TextStyle(fontSize: 12))),
                    DropdownMenuItem(
                        value: 1,
                        child: Text(provider.t('auto.logModeSave'),
                            style: const TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) {
                    setState(() => s.count = v ?? 0);
                    _save();
                  },
                ),
              ),
            // ── 中身を取り出す (= ユーザー要望) ──
            if (s.kind == WebAutoKind.extract) ...[
              SizedBox(
                width: 150,
                child: DropdownButtonFormField<String>(
                  initialValue: const ['text', 'html', 'table', 'links']
                          .contains(s.text.trim().toLowerCase())
                      ? s.text.trim().toLowerCase()
                      : 'text',
                  dropdownColor: const Color(0xFF23233A),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: _fieldDeco(provider.t('auto.extractWhat')),
                  items: [
                    for (final e in const [
                      ('text', 'auto.extractText'),
                      ('table', 'auto.extractTable'),
                      ('links', 'auto.extractLinks'),
                      ('html', 'auto.extractHtml'),
                    ])
                      DropdownMenuItem(
                          value: e.$1,
                          child: Text(provider.t(e.$2),
                              style: const TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) {
                    setState(() => s.text = v ?? 'text');
                    _save();
                  },
                ),
              ),
              SizedBox(
                width: 200,
                child: TextFormField(
                  initialValue: s.selector,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: _fieldDeco(provider.t('auto.extractWhere')),
                  onChanged: (v) {
                    s.selector = v.trim();
                    _save();
                  },
                ),
              ),
            ],
            // ── 外のブラウザを操作 ──
            //    どのブラウザで / どの URL を / どのプロファイルで、 の
            //    3 つを手で直せるようにする (= 以前は 1 つも直せず、
            //    チップから足すと空のタブが開くだけの手順になっていた)。
            if (s.kind == WebAutoKind.openBrowser) ...[
              SizedBox(
                width: 120,
                child: DropdownButtonFormField<String>(
                  initialValue: const [
                    '',
                    'chrome',
                    'edge',
                    'brave',
                    'vivaldi',
                    'opera'
                  ].contains(s.text.trim().toLowerCase())
                      ? s.text.trim().toLowerCase()
                      : '',
                  dropdownColor: const Color(0xFF23233A),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: provider.t('auto.browserName'),
                    labelStyle:
                        const TextStyle(color: Colors.white54, fontSize: 10),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none),
                  ),
                  items: [
                    DropdownMenuItem(
                        value: '',
                        child: Text(provider.t('auto.browserAuto'),
                            style: const TextStyle(fontSize: 12))),
                    for (final k in const [
                      'chrome',
                      'edge',
                      'brave',
                      'vivaldi',
                      'opera'
                    ])
                      DropdownMenuItem(
                          value: k,
                          child: Text(k, style: const TextStyle(fontSize: 12))),
                  ],
                  onChanged: (v) {
                    setState(() => s.text = v ?? '');
                    _save();
                  },
                ),
              ),
              SizedBox(
                width: 240,
                child: TextFormField(
                  initialValue: s.selector,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: provider.t('auto.openUrl'),
                    labelStyle:
                        const TextStyle(color: Colors.white54, fontSize: 10),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none),
                  ),
                  onChanged: (v) {
                    s.selector = v.trim();
                    _save();
                  },
                ),
              ),
              // ── どのアカウントで開くか (= ユーザー要望) ──
              //    普段の Chrome に入っている呼び名から選べる。
              // ★ 印 (submit) が付いていなくても出す。 隠していたせいで、
              //   AI が入れたアカウントが画面から消えていた
              //   (= ユーザー報告: 指定しているのに「既定の 1 つ」)。
              _acctPicker(provider, s),
            ],
            // ── 普段のプロファイルで開くかどうか ──
            //    以前は count==1 という隠れた目印で決めていて、 count の
            //    既定が 1 なので**必ず**普段のプロファイル側に落ちていた
            //    (= プロファイル選択画面で止まる原因)。 目に見える形にする。
            if (s.kind == WebAutoKind.openBrowser) ...[
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () {
                    setState(() => s.submit = !s.submit);
                    _save();
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: s.submit
                          ? const Color(0xFF43B97F).withValues(alpha: 0.26)
                          : const Color(0xFF2A2A44),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: s.submit
                              ? const Color(0xFF43B97F)
                              : Colors.white24),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(
                          s.submit
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 13,
                          color: s.submit
                              ? const Color(0xFF8FE3BC)
                              : Colors.white54),
                      const SizedBox(width: 5),
                      Text(provider.t('auto.ownProfile'),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 10.5)),
                    ]),
                  ),
                ),
              ),
              // ── 今どちらで開くか、 ひと目で分かるように
              //    (= ユーザー要望: 明示しなければシークレット) ──
              _openModeBadge(provider, s),
            ],
            // ── テキスト入力 (= ユーザー要望) ──
            if (s.kind == WebAutoKind.type) ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF43B97F),
                  side: const BorderSide(color: Color(0xFF43B97F)),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                icon: const Icon(Icons.ads_click_rounded, size: 14),
                label: Text(
                    s.selector.isEmpty
                        ? provider.t('auto.pickElement')
                        : (s.selector.length > 28
                            ? '${s.selector.substring(0, 28)}…'
                            : s.selector),
                    style: const TextStyle(fontSize: 10.5)),
                onPressed: () => _pickElementFor(s),
              ),
              SizedBox(
                width: 220,
                child: TextFormField(
                  initialValue: s.text,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: provider.t('auto.typeText'),
                    labelStyle:
                        const TextStyle(color: Colors.white54, fontSize: 10),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none),
                  ),
                  onChanged: (v) {
                    s.text = v;
                    _save();
                  },
                ),
              ),
              // セレクタの手入力 (= GUI で拾えない時の逃げ道)。
              SizedBox(
                width: 220,
                child: TextFormField(
                  key: ValueKey('sel_${identityHashCode(s)}_${s.selector}'),
                  initialValue: s.selector,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: provider.t('auto.selector'),
                    labelStyle:
                        const TextStyle(color: Colors.white54, fontSize: 10),
                    hintText: '#search / input[name="q"]',
                    hintStyle:
                        const TextStyle(color: Colors.white24, fontSize: 10),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none),
                  ),
                  onChanged: (v) {
                    s.selector = v.trim();
                    _save();
                  },
                ),
              ),
              // テーマの色を拾って白飛びしないよう自前描画にする。
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () {
                    setState(() => s.submit = !s.submit);
                    _save();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: s.submit
                          ? const Color(0xFF43B97F).withValues(alpha: 0.26)
                          : const Color(0xFF2A2A44),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: s.submit
                              ? const Color(0xFF43B97F)
                              : Colors.white24),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(
                          s.submit
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 13,
                          color: s.submit
                              ? const Color(0xFF8FE3BC)
                              : Colors.white54),
                      const SizedBox(width: 5),
                      Text(provider.t('auto.typeSubmit'),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 10.5)),
                    ]),
                  ),
                ),
              ),
            ],
            // スクロール方向 (= ユーザー要望)
            if (s.kind == WebAutoKind.scroll)
              Wrap(spacing: 4, children: [
                for (final d in const [
                  ('down', Icons.arrow_downward_rounded),
                  ('up', Icons.arrow_upward_rounded),
                  ('right', Icons.arrow_forward_rounded),
                  ('left', Icons.arrow_back_rounded),
                ])
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      setState(() => s.scrollDir = d.$1);
                      _save();
                    },
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: s.scrollDir == d.$1
                            ? const Color(0xFF4DB6AC).withValues(alpha: 0.3)
                            : Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: s.scrollDir == d.$1
                                ? const Color(0xFF4DB6AC)
                                : Colors.white24),
                      ),
                      child: Icon(d.$2,
                          size: 15,
                          color: s.scrollDir == d.$1
                              ? const Color(0xFF80CBC4)
                              : Colors.white54),
                    ),
                  ),
              ]),
            // ── ファイルを渡す (= ユーザー要望) ──
            //    フォルダーを選んで、 何番目から何番目までを順番に渡す。
            //    繰り返しの中に置くと 1 周ごとに次のファイルに進む。
            if (s.kind == WebAutoKind.upload) ...[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF4FC3F7),
                  side: const BorderSide(color: Color(0xFF4FC3F7)),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                icon: const Icon(Icons.folder_open_rounded, size: 14),
                label: Text(
                    s.text.trim().isEmpty
                        ? provider.t('auto.uploadMadeFiles')
                        : s.text.split(RegExp(r'[\\/]')).last,
                    style: const TextStyle(fontSize: 10.5)),
                onPressed: () async {
                  final dir =
                      await FilePicker.platform.getDirectoryPath();
                  if (dir == null) return;
                  setState(() => s.text = dir);
                  _save();
                },
              ),
              // 選んだフォルダーを外して、 「作ったファイル」 に戻す。
              if (s.text.trim().isNotEmpty)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: provider.t('auto.uploadClearFolder'),
                  icon: const Icon(Icons.backspace_outlined,
                      size: 14, color: Colors.white54),
                  onPressed: () {
                    setState(() => s.text = '');
                    _save();
                  },
                ),
              _numField(provider.t('auto.uploadFrom'), s.x.round(),
                  (v) => s.x = v.clamp(1, 99999).toDouble(),
                  width: 92),
              _numField(provider.t('auto.uploadTo'), s.y.round(),
                  (v) => s.y = v.clamp(0, 99999).toDouble(),
                  width: 92),
            ],
            // ── ファイルを作る (= ユーザー要望: 作ってそのまま渡せるように) ──
            if (s.kind == WebAutoKind.makeFile) ...[
              SizedBox(
                width: 170,
                child: TextFormField(
                  initialValue: s.selector,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: provider.t('auto.fileName'),
                    labelStyle:
                        const TextStyle(color: Colors.white54, fontSize: 10),
                    hintText: 'memo.txt',
                    hintStyle:
                        const TextStyle(color: Colors.white24, fontSize: 10),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none),
                  ),
                  onChanged: (v) {
                    s.selector = v.trim();
                    _save();
                  },
                ),
              ),
              SizedBox(
                width: 320,
                child: TextFormField(
                  initialValue: s.text,
                  minLines: 1,
                  maxLines: 4,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: provider.t('auto.fileBody'),
                    labelStyle:
                        const TextStyle(color: Colors.white54, fontSize: 10),
                    hintText: provider.t('auto.fileBodyHint'),
                    hintStyle:
                        const TextStyle(color: Colors.white24, fontSize: 10),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide.none),
                  ),
                  onChanged: (v) {
                    s.text = v;
                    _save();
                  },
                ),
              ),
            ],
            // ページ全体を 1 枚にするかの切替え (旧「全体を 1 枚」)。
            if (s.kind == WebAutoKind.shot ||
                s.kind == WebAutoKind.fullShot)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: s.kind == WebAutoKind.fullShot
                      ? const Color(0xFF80CBC4)
                      : Colors.white54,
                  side: BorderSide(
                      color: s.kind == WebAutoKind.fullShot
                          ? const Color(0xFF80CBC4)
                          : Colors.white24),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                icon: Icon(
                    s.kind == WebAutoKind.fullShot
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    size: 14),
                label: Text(provider.t('auto.kindFullShot'),
                    style: const TextStyle(fontSize: 10.5)),
                onPressed: () {
                  setState(() => s.kind = s.kind == WebAutoKind.fullShot
                      ? WebAutoKind.shot
                      : WebAutoKind.fullShot);
                  _save();
                },
              ),
            if (s.kind == WebAutoKind.shot)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFBA68C8),
                  side: const BorderSide(color: Color(0xFFBA68C8)),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                ),
                icon: const Icon(Icons.crop_rounded, size: 14),
                label: Text(
                    (s.x2 - s.x).abs() > 4
                        ? '${provider.t('auto.pickRegion')} '
                            '(${s.x.round()},${s.y.round()})-'
                            '(${s.x2.round()},${s.y2.round()})'
                        : provider.t('auto.pickRegion'),
                    style: const TextStyle(fontSize: 10.5)),
                onPressed: () async {
                  final r = await widget.pickRect();
                  if (r == null) return;
                  setState(() {
                    s.x = r.left;
                    s.y = r.top;
                    s.x2 = r.right;
                    s.y2 = r.bottom;
                  });
                  _save();
                },
              ),
            if (s.kind == WebAutoKind.tap ||
                s.kind == WebAutoKind.swipe ||
                s.kind == WebAutoKind.shot)
              _numField(provider.t('auto.count'), s.count,
                  (v) => s.count = v.clamp(1, 999)),
            if (isLoop)
              _numField(provider.t('auto.loopCount'), s.count,
                  (v) => s.count = v.clamp(0, 9999), width: 104),
            if (s.kind == WebAutoKind.hold ||
                s.kind == WebAutoKind.swipe ||
                s.kind == WebAutoKind.wait)
              _numField(provider.t('auto.durationMs'), s.durationMs,
                  (v) => s.durationMs = v.clamp(10, 600000), width: 92),
            if (s.kind == WebAutoKind.scroll)
              _numField(provider.t('auto.scrollPx'), s.durationMs,
                  (v) => s.durationMs = v, width: 92),
            if (s.kind != WebAutoKind.wait && !isLoop) ...[
              _numField(provider.t('auto.intervalMs'), s.intervalMs,
                  (v) => s.intervalMs = v.clamp(0, 600000), width: 92),
              // ばらつき (0 = 間隔どおり固定) = ユーザー要望
              _numField(provider.t('auto.intervalRandomMs'), s.intervalMaxMs,
                  (v) => s.intervalMaxMs = v.clamp(0, 600000), width: 116),
            ],
          ]),
          // 間隔のばらつきが有効なら実際の範囲を書いておく (= 分かりやすく)
          if (s.kind != WebAutoKind.wait && !isLoop && s.intervalMaxMs > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  provider
                      .t('auto.intervalRandomHint')
                      .replaceFirst('{a}', '${s.intervalMs}')
                      .replaceFirst(
                          '{b}', '${s.intervalMs + s.intervalMaxMs}'),
                  style: const TextStyle(
                      color: Color(0xFF80CBC4), fontSize: 10)),
            ),
          if (isLoop && s.count == 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(provider.t('auto.loopInfinite'),
                  style:
                      const TextStyle(color: Color(0xFFFFB74D), fontSize: 10)),
            ),
          if (isLoop) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(6),
                border: const Border(
                  left: BorderSide(color: Color(0xFF4DB6AC), width: 3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s.children.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(provider.t('auto.loopEmpty'),
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 10.5)),
                    ),
                  for (var ci = 0; ci < s.children.length; ci++)
                    _stepTile(provider, s.children, ci, path: label),
                  _addChips(provider, s.children),
                ],
              ),
            ),
          ],
          ], // ← 畳んでいない時だけ中身を出す
        ],
      ),
    );
  }

  /// 畳んでいる手順の集まり (= ユーザー要望: 手順が多くなってきたので
  /// 折り畳めるように)。
  final Set<WebAutoStep> _collapsedSteps = <WebAutoStep>{};

  /// 畳んだ時に 1 行で見せる中身。
  String _stepSummary(WebAutoStep s) {
    final bits = <String>[
      if (s.text.trim().isNotEmpty)
        s.text.trim().length > 48
            ? '${s.text.trim().substring(0, 48)}…'
            : s.text.trim(),
      if (s.selector.trim().isNotEmpty) s.selector.trim(),
      if (s.x != 0 || s.y != 0) '(${s.x.round()},${s.y.round()})',
      if (s.count != 0) '×${s.count}',
      if (s.durationMs != 0) '${s.durationMs}ms',
      if (s.kind == WebAutoKind.loop) '中に ${s.children.length} 手',
    ];
    return bits.isEmpty ? '—' : bits.join('  ');
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<MindMapProvider>();
    return Container(
      color: const Color(0xFF1B1B2A),
      // ★ 浮かせた窓は高さが決め打ち (既定 560x760) なので、 AI の欄や
      //   コマンド実行・時刻で実行を出すと固定の行が縦を食い尽くし、
      //   一番下の「時刻で実行」 まで届かなくなる (= ユーザー報告:
      //   下までスクロールできない)。 伸び縮みするのは手順一覧だけなので、
      //   そこが 0 になっても上下の行は入りきらない。
      //   縦が足りない時は全体を巻物にして、 手順一覧には決まった
      //   高さを渡す。 広い時 (全画面) は今までどおり。
      child: LayoutBuilder(builder: (lctx, cons) {
        final tight = cons.maxHeight.isFinite && cons.maxHeight < 760;
        // ★ 上の欄をたたんだぶんだけ、 手順の一覧を広くする
        //   (= ユーザー要望: 肝心のフローの表示領域が小さくて操作しづらい)。
        final openCount = (_aiFormOpen ? 1 : 0) +
            (_cmdOpen && _isDesktopHost && !kStoreBuild ? 1 : 0) +
            (_chipsOpen ? 1 : 0);
        final autoHeight = (cons.maxHeight * (0.62 - 0.09 * openCount))
            .clamp(180.0, 560.0)
            .toDouble();
        // ★ 人が境界をドラッグして決めた高さがあれば、 そちらを使う
        //   (= ユーザー要望: 表示領域がまだ小さいので自分で広げたい)。
        //   窓より高くしてよい (足りない分は全体が巻物になる)。
        final maxSteps =
            cons.maxHeight.isFinite ? cons.maxHeight * 2.5 : 1600.0;
        final stepsHeight = _stepsH == null
            ? autoHeight
            : _stepsH!.clamp(120.0, maxSteps).toDouble();
        // 人が高さを決めた時は、 広い画面でも決めた高さで出す
        //   (Expanded だと決めた高さが無視されるため)。
        final fixedSteps = tight || _stepsH != null;
        final steps = _steps.isEmpty
            ? Center(
                child: Text(provider.t('auto.empty'),
                    style: const TextStyle(
                        color: Colors.white24, fontSize: 11)),
              )
            : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: _steps.length,
                itemBuilder: (_, i) => _stepTile(provider, _steps, i),
              );
        final body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: fixedSteps ? MainAxisSize.min : MainAxisSize.max,
        children: [
          // ── ネットにつながっていない時だけ、 一番上に出す
          //    (= ユーザー要望: 下の方の 1 行では地味で気付けない) ──
          if (!_online)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              color: const Color(0xFFB71C1C),
              child: Row(children: [
                const Icon(Icons.wifi_off_rounded, size: 16,
                    color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(provider.t('net.offline'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          height: 1.35)),
                ),
                // 待たずに調べ直せるように (= つなぎ直した直後)。
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: provider.t('net.recheck'),
                  icon: const Icon(Icons.refresh_rounded,
                      size: 16, color: Colors.white),
                  onPressed: () => unawaited(_checkNet()),
                ),
              ]),
            ),
          if (_recording)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: const Color(0xFFE57373).withValues(alpha: 0.18),
              child: Text(provider.t('auto.recordHint'),
                  style: const TextStyle(
                      color: Color(0xFFFFCDD2), fontSize: 10.5, height: 1.35)),
            ),
          // 設定の窓を「押した所の近く」 に出すため、 位置を控える
          // (= ユーザー要望: 保存の窓が画面中央に出る)。
          Listener(
            onPointerDown: (e) => _lastPointerPos = e.position,
            child: Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            color: const Color(0xFF23233A),
            // ── 幅が狭い端末 (= モバイル) ではヘッダーのボタンが溢れるので、
            //    横スクロールできるようにする (= ユーザー要望: オーバーフロー
            //    してしまうので使いやすいサイズに)。 ──
            child: Row(children: [
              Expanded(
                child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.play_circle_outline_rounded,
                  size: 17, color: Color(0xFF80CBC4)),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(provider.t('auto.title'),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ),
              // ── 操作の記録 (= ユーザー要望: フローを組まなくても自動で
              //    操作を記憶して再現できるように) ──
              if (!_running && !_recording)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE57373),
                      side: const BorderSide(color: Color(0xFFE57373)),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 28),
                    ),
                    icon: const Icon(Icons.fiber_manual_record_rounded,
                        size: 14),
                    label: Text(provider.t('auto.record'),
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w700)),
                    onPressed: toggleRecording,
                  ),
                ),
              if (_recording) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF4FC3F7),
                      side: const BorderSide(color: Color(0xFF4FC3F7)),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 28),
                    ),
                    icon: const Icon(Icons.photo_camera_rounded, size: 14),
                    label: Text(provider.t('auto.recordShot'),
                        style: const TextStyle(fontSize: 11)),
                    // ignore: discarded_futures
                    onPressed: recordShot,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE57373),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 28),
                    ),
                    icon: const Icon(Icons.stop_rounded, size: 16),
                    label: Text(provider.t('auto.recordStop'),
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w700)),
                    onPressed: stopRecording,
                  ),
                ),
              ],
              // 実行ボタンをヘッダーに置く (= ユーザー要望: 押しやすい位置に)。
              if (!_running && !_recording && _steps.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF43B97F),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 28),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 17),
                    label: Text(provider.t('auto.run'),
                        style: const TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.w700)),
                    onPressed: () => _run(provider),
                  ),
                ),
              // 実行中はヘッダーを停止ボタンだけにする (= ユーザー要望)。
              if (_running)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 28),
                  ),
                  icon: const Icon(Icons.stop_rounded, size: 16),
                  label: Text(provider.t('auto.stop'),
                      style: const TextStyle(fontSize: 11)),
                  onPressed: _requestStop,
                ),
              // ── エージェントを止める (= 動いている間だけ出す) ──
              if (_agentBusy)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE57373),
                      side: const BorderSide(color: Color(0xFFE57373)),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 28),
                    ),
                    icon: const Icon(Icons.stop_rounded, size: 14),
                    label: Text(provider.t('auto.agentStop'),
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w700)),
                    onPressed: () => setState(() {
                      _agentStop = true;
                      _cancel = true;
                    }),
                  ),
                ),
              // ★ ヘッダーの AI ボタンは置かない (= ユーザー要望: 欄の
              //   右上の▼で閉じたり開いたり出来るので、 ヘッダーには要らない)。
              // 撮ったスクショの管理 (= ユーザー要望: どこにあるか分かり
              // にくい / PDF 前に編集・並べ替えしたい)
              // ★ 浮かせた窓だと横に溢れて見えなくなっていた
              //   (= ユーザー報告: スクショを管理するボタンがない)。
              //   ファイル操作より先に置いて、 狭い幅でも残るようにした。
              if (!_running)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: provider.t('shots.title'),
                  icon: const Icon(Icons.photo_library_rounded,
                      size: 17, color: Color(0xFF80CBC4)),
                  onPressed: () async {
                    if (_modalOpen) return;
                    _modalOpen = true;
                    try {
                      // ★ 全画面で開く (= ユーザー要望: 浮かせた窓だと
                      //   潰れて使えない)。
                      await ShotManagerDialog.show(context,
                          useRootNavigator: false, fullscreen: true);
                    } finally {
                      _modalOpen = false;
                    }
                  },
                ),
              // 新しいフローを作る (= ユーザー要望: 作り直したい時に、 今の
              // 手順を消して白紙から始められるように)。 手順が残っている時は
              // 確かめてから消す。
              if (!_running)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: provider.t('auto.flowNew'),
                  icon: const Icon(Icons.note_add_outlined,
                      size: 16, color: Colors.white70),
                  onPressed: () => _newFlow(provider),
                ),
              // フローの保存 / 呼び出し (= ユーザー要望: フロー名を保存して
              // 呼び出せるように)
              if (!_running)
                IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: provider.t('auto.flowSaveTitle'),
                icon: const Icon(Icons.save_rounded,
                    size: 16, color: Colors.white70),
                onPressed: () => _saveFlowAs(provider),
              ),
              if (!_running)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: provider.t('auto.flowLoadTitle'),
                  icon: const Icon(Icons.folder_open_rounded,
                      size: 16, color: Colors.white70),
                  onPressed: () => _showFlowMenu(provider),
                ),
              // ★ 閉じるはこの列には置かない (= ユーザー報告: スクショ管理の
              //   隣の × を押すと進行不能になる / 閉じるボタンが 2 つある)。
              //   外側の帯がある間はそちらの × だけ、 帯を出さない時だけ
              //   下の showCloseButton で 1 つだけ出す。
            ]),
              ),
              ),
              // ★ 「手順を全部消す」 はここには置かない。 1 番目の手順の
              //   すぐ上へ移した (= ユーザー要望)。
              // ── 動いた記録 / AI のメッセージ (= ユーザー要望: 開発の
              //    テストに使いたいのでデバッグの記録を見られるように) ──
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: provider.t('auto.runLog'),
                icon: Icon(Icons.bug_report_rounded,
                    size: 17,
                    color: (_runLog.isEmpty && _aiMessages.isEmpty)
                        ? Colors.white38
                        : const Color(0xFF80CBC4)),
                onPressed: _showRunLog,
              ),
              // ── 閉じる (= 窓いっぱいに広げている時だけ。 外側の帯が
              //    無いのでここが唯一の閉じ口になる) ──
              //    狭い画面でも必ず見えるよう、 横スクロールの外に置く。
              if (widget.showCloseButton)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: provider.t('btn.close'),
                  icon: const Icon(Icons.close_rounded,
                      size: 17, color: Colors.white70),
                  onPressed: widget.onClose,
                ),
            ]),
          ),
          ),
          // ── AI でフローを作る入力欄 (= ユーザー要望: 一番上に置く。
          //    コマンド実行はこのすぐ下、 時刻で実行は一番下) ──
          // ── AI の欄。 見出しは常に出し、 中身だけたたむ
          //    (= ユーザー要望: ヘッダーのボタンを外したので、 ここが
          //    唯一の開け閉め口になる) ──
          Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Container(
                padding: EdgeInsets.all(_aiFormOpen ? 8 : 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFBA68C8).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: const Color(0xFFBA68C8).withValues(alpha: 0.5)),
                ),
                child: Column(children: [
                  // ── 見出し。 押すとプロンプト欄ごとたためる
                  //    (= ユーザー要望: フローの表示領域を広く使いたい) ──
                  _sectionHead(
                    provider,
                    provider.t('auto.aiSection'),
                    open: _aiFormOpen,
                    icon: Icons.auto_awesome_rounded,
                    color: const Color(0xFFBA68C8),
                    onTap: () {
                      setState(() => _aiFormOpen = !_aiFormOpen);
                      unawaited(_saveAgentOpts());
                    },
                    trailing: [
                      // 考えている間の目印 (ヘッダーから移した)。
                      if (_aiBusy || _agentBusy)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(
                                    Color(0xFFBA68C8))),
                          ),
                        ),
                    ],
                  ),
                  if (_aiFormOpen) ...[
                  const SizedBox(height: 4),
                  // ── Enter で確定 = AI でフロー作成 (= ユーザー要望) ──
                  //    改行を入れたい時は Shift+Enter。 複数行の欄はそのままだと
                  //    Enter が改行になるので、 手前で捕まえる。
                  Focus(
                    onKeyEvent: (node, ev) {
                      if (ev is! KeyDownEvent) return KeyEventResult.ignored;
                      final k = ev.logicalKey;
                      if (k != LogicalKeyboardKey.enter &&
                          k != LogicalKeyboardKey.numpadEnter) {
                        return KeyEventResult.ignored;
                      }
                      if (HardwareKeyboard.instance.isShiftPressed) {
                        return KeyEventResult.ignored;
                      }
                      _submitAiPrompt(provider);
                      return KeyEventResult.handled;
                    },
                    child: TextField(
                      controller: _aiCtrl,
                      // 打つたびに下書きを残す (= ユーザー要望: 実行から
                      // 戻ってきた時にプロンプト欄が空にならないように)。
                      onChanged: _saveAiDraft,
                      // 常に出ているので、 勝手に文字入力へ移らない
                      // (モバイルでキーボードが出っぱなしになるのを防ぐ)。
                      autofocus: false,
                      maxLines: 3,
                      minLines: 1,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 12.5),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: provider.t('auto.aiHint'),
                        hintStyle: const TextStyle(
                            color: Colors.white38, fontSize: 11),
                        filled: true,
                        fillColor: Colors.black.withValues(alpha: 0.25),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide.none),
                      ),
                      onSubmitted: (_) => _submitAiPrompt(provider),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // ── 使うモデル + 前に使った指示 (= ユーザー要望) ──
                  Row(children: [
                    _buildAiModelPicker(provider),
                    const SizedBox(width: 6),
                    if (_aiPrompts.isNotEmpty)
                      PopupMenuButton<String>(
                        tooltip: provider.t('auto.aiHistory'),
                        color: const Color(0xFF1E1E32),
                        onSelected: (v) => setState(() {
                          _aiCtrl.text = v;
                          _aiCtrl.selection = TextSelection.collapsed(
                              offset: v.length);
                        }),
                        itemBuilder: (_) => [
                          for (final p in _aiPrompts.reversed)
                            PopupMenuItem<String>(
                              value: p,
                              child: SizedBox(
                                width: 260,
                                child: Text(p,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 12)),
                              ),
                            ),
                        ],
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.history_rounded,
                                size: 13, color: Colors.white54),
                            const SizedBox(width: 4),
                            Text(provider.t('auto.aiHistory'),
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 10.5)),
                          ]),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 8),
                  // ── 2 つの選び方を並べる (= ユーザー要望: 説明が諄いので、
                  //    「見ながら / 見せない」 と「フローを残す / 残さない」
                  //    の 2 択に置き換える) ──
                  // ── 2 択は左揃え、 実行は同じ段の右端 (= ユーザー要望) ──
                  //    幅が狭い時は 2 択の方だけが折り返る (Wrap を包む)。
                  Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Expanded(
                        child:
                            Wrap(spacing: 14, runSpacing: 6, children: [
                      _twoWay(
                      provider.t('auto.optWatch'),
                      left: provider.t('auto.optWatchOn'),
                      right: provider.t('auto.optWatchOff'),
                      leftPicked: !_agentHeadless,
                      onLeft: () {
                        _agentOptsTouched = true;
                        setState(() => _agentHeadless = false);
                        unawaited(_saveAgentOpts());
                      },
                      onRight: () {
                        _agentOptsTouched = true;
                        setState(() => _agentHeadless = true);
                        unawaited(_saveAgentOpts());
                      },
                    ),
                    _twoWay(
                      provider.t('auto.optKeep'),
                      left: provider.t('auto.optKeepOn'),
                      right: provider.t('auto.optKeepOff'),
                      leftPicked: _agentKeepSteps,
                      onLeft: () {
                        _agentOptsTouched = true;
                        setState(() => _agentKeepSteps = true);
                        unawaited(_saveAgentOpts());
                      },
                      onRight: () {
                        _agentOptsTouched = true;
                        setState(() => _agentKeepSteps = false);
                        unawaited(_saveAgentOpts());
                      },
                      ),
                    ])),
                    const SizedBox(width: 8),
                    // ── 投げるボタンは 1 つだけ (= ユーザー要望: 見方と
                    //    フローの 2 択があるのだから、 ボタンで同じことを
                    //    選ばせる必要は無い。 キャンセルも使い道が無い) ──
                    //    畳みたい時は見出しの▼で畳める。
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFBA68C8),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 4),
                          visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.send_rounded, size: 14),
                      label: Text(provider.t('auto.aiSend'),
                          style: const TextStyle(fontSize: 12)),
                      onPressed: (_aiBusy || _agentBusy || _running)
                          ? null
                          : () {
                              final v = _aiCtrl.text;
                              if (v.trim().isEmpty) return;
                              _rememberAiPrompt(v);
                              _runAgent(provider, v,
                                  keepSteps: _agentKeepSteps);
                            },
                    ),
                  ]),
                  ],
                ]),
              ),
            ),
          // ── 説明の行が、 そのままボタン一覧の見出し (= ユーザー要望:
          //    「手順を並べて実行します」 の所をたためるように) ──
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 8, 2),
            child: _sectionHead(
              provider,
              provider.t('auto.hint'),
              open: _chipsOpen,
              color: Colors.white38,
              fontSize: 10.5,
              onTap: () {
                setState(() => _chipsOpen = !_chipsOpen);
                unawaited(_saveAgentOpts());
              },
            ),
          ),
          // ステップ追加ボタン
          if (_chipsOpen)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _addChips(provider, _steps),
            ),
          // ── まとめて消すバー (= ユーザー要望: Ctrl / Shift で複数選択) ──
          if (_stepSel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Row(children: [
                Text(
                    provider
                        .t('auto.selected')
                        .replaceFirst('{n}', '${_stepSel.length}'),
                    style: const TextStyle(
                        color: Color(0xFF8D86FF), fontSize: 11.5)),
                const Spacer(),
                TextButton(
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: Colors.white38),
                  onPressed: () => setState(() {
                    _stepSel.clear();
                    _selAnchorList = null;
                    _selAnchorIndex = -1;
                  }),
                  child: Text(provider.t('mcp.clearSelection'),
                      style: const TextStyle(fontSize: 11)),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: const Color(0xFFFF8A80)),
                  icon: const Icon(Icons.delete_sweep_rounded, size: 15),
                  label: Text(provider.t('mcp.deleteSelected'),
                      style: const TextStyle(fontSize: 11)),
                  onPressed: _deleteSelectedSteps,
                ),
              ]),
            ),
          // ── 手順を全部消す (= ユーザー要望: 1 番目の手順のすぐ上に) ──
          //    間違って押しても困らないよう、 一度だけ確かめる。
          if (!_running && _steps.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: const Color(0xFFE57373),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 26),
                  ),
                  icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                  label: Text(provider.t('auto.clearAll'),
                      style: const TextStyle(fontSize: 11)),
                  onPressed: () => _clearAllSteps(provider),
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (fixedSteps)
            SizedBox(height: stepsHeight, child: steps)
          else
            Expanded(child: steps),
          // ── 境界をドラッグして、 手順一覧の高さを変える
          //    (= ユーザー要望)。 二度押しで自動の高さに戻る。 ──
          //    ★ 巻物の中でも掴めるよう、 Listener で直に受け取る
          //      (中の GestureDetector と取り合いにならない)。
          MouseRegion(
            cursor: SystemMouseCursors.resizeUpDown,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerMove: (e) {
                final base = _stepsH ?? stepsHeight;
                final next = (base + e.delta.dy).clamp(120.0, maxSteps);
                if ((next - base).abs() < 0.5) return;
                setState(() => _stepsH = next.toDouble());
              },
              onPointerUp: (_) => unawaited(_saveAgentOpts()),
              child: GestureDetector(
                onDoubleTap: () {
                  setState(() => _stepsH = null);
                  unawaited(_saveAgentOpts());
                },
                child: Container(
                  height: 12,
                  width: double.infinity,
                  color: Colors.white.withValues(alpha: 0.04),
                  alignment: Alignment.center,
                  child: Container(
                    width: 46,
                    height: 3,
                    decoration: BoxDecoration(
                      color: _stepsH == null
                          ? Colors.white24
                          : const Color(0xFF80CBC4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Padding(
            padding: const EdgeInsets.all(8),
            // 全体の繰り返し回数の欄は廃止 (= ユーザー要望: 繰り返しは
            //   繰り返しブロックの中で指定すればいいだけ)。 保存済みの値は
            //   読み込むが、 常に 1 周として走る。
            child: Row(children: [
              Expanded(
                child: Text(_status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 10.5)),
              ),
              const SizedBox(width: 6),
              // 実行 / 停止はヘッダーに集約した (= ユーザー要望: 押しやすい
              // 位置へ)。 ここには残さない。
            ]),
          ),
          // ★ コマンド実行 / パソコンの操作 = 時刻で実行と並べて一番下
          //   (= ユーザー要望)。 以前は AI の欄のすぐ下にあり、 肝心の
          //   手順一覧が下に押し出されていた。
          _buildCommandRow(provider),
          // 時刻で実行 = 一番下 (= ユーザー要望)。
          _buildScheduleRow(provider),
        ],
        );
        // ★ 高さを決めた時も巻物にする (= 決めた高さが窓より高い時に
        //   はみ出さないように)。
        return fixedSteps ? SingleChildScrollView(child: body) : body;
      }),
    );
  }
}
