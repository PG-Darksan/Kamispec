// ── 走らせている CLI の 1 回分 ──
//
// (= ユーザー要望: 「閉じて止まると面倒だから、 明示的に停止ボタンを押さない
//  限りバックグラウンドで動き続けて、 完了したらアプリにメッセージが出る
//  ようにして欲しい」「選択肢を Enter で確定させたり、 プロンプト投げられる
//  ように」)
//
// 以前は画面 (AgentTerminal) が擬似端末そのものを持っていたので、 欄を閉じた
// 瞬間に dispose が走って npm ごと止まっていた。 走らせている物はここが持ち、
// 画面はそれを覗くだけにする。 止まるのは「止める」 を押した時だけ。
//
// **なぜ本物の端末表示 (xterm) を挟むのか**
//   Windows の擬似端末 (ConPTY) は、 CLI が描いた画面を「文字の並び」 では
//   なく「カーソルをここへ動かして、 ここを消して、 ここに書く」 という形で
//   送ってくる。 以前はその制御をまとめて捨てて素の文字だけ出していたので、
//   文字が詰まって並び (Welcome→WelcometoClaude…)、 選択肢のどれを選んで
//   いるのかも分からなかった。 端末の画面を持てば、 そのまま正しく出る。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import 'agent_cli.dart';

/// 1 回分の実行。 画面を閉じても、 これが生きている限り走り続ける。
class AgentCliSession extends ChangeNotifier {
  AgentCliSession({
    required this.title,
    required this.exePath,
    required this.arguments,
    required this.workingDirectory,
    this.hint,
    this.isInstall = false,
    this.isShell = false,
    this.cliKey = '',
    this.extraEnvironment = const <String, String>{},
  });

  /// 見出し (「Claude Code — インストール」 など)。
  final String title;
  final String exePath;
  final List<String> arguments;
  final String workingDirectory;

  /// 上に出す一言。
  final String? hint;

  /// npm での導入か (終わったら CLI の一覧を作り直す)。
  final bool isInstall;

  /// ただのターミナル (シェル) か (= ユーザー要望: ターミナルを開くボタン)。
  /// AI の CLI ではないので、 モデルや推論の切り替えは出さない。
  final bool isShell;

  /// どの CLI か ('claude' / 'codex' / 'gemini'、 シェルなら空)。
  /// 出すボタンを決めるのに使う (Codex は自前で順番待ちを持っている)。
  final String cliKey;

  /// この実行にだけ足す環境変数。
  ///
  /// ★ = ユーザー報告「gemini CLI にログインしようとするとセキュリティソフト
  ///   にブロックされてしまう」。 API キーをここで渡せば、 CLI は
  ///   ブラウザも 127.0.0.1 の待ち受けも使わずに済む (= 止められる手順を
  ///   そもそも通らない)。
  /// ★ 合言葉の類は**引数ではなくここへ**。 引数は起動時に端末の画面へ
  ///   そのまま書き出すので、 覗かれる。
  final Map<String, String> extraEnvironment;

  /// `/model` のようなコマンドを受け付ける相手か (= CLI 本体を動かしている
  /// 時だけ true。 npm の導入中に送っても意味が無い)。
  bool get supportsSlashCommands => !isInstall && !isShell;

  /// コマンドを 1 行送る (「/usage」 など)。
  void sendCommand(String command) => send(command);

  /// 端末の画面。 画面側はこれを `TerminalView` に渡すだけ。
  final Terminal terminal = Terminal(maxLines: 10000);

  bool get running => _running;
  bool _running = false;

  /// 終わった時の返り値 (まだなら null)。
  int? exitCode;

  /// 「止める」 を押して終わらせたか。
  bool stoppedByUser = false;

  // ── 起こせなかった時の控え (= ユーザー報告: 「ターミナルボタンを押すと
  //    セキュリティソフトにブロックされてアプリが落ちてしまう」) ──
  //
  //   ★ 落ちていた元は **隠し PowerShell に base64 の一行を渡す**形で、
  //     それは [AgentCli.shellLaunch] から取り除いてある。 撃たれていたのは
  //     アプリのプロセスそのもの (= Dart の例外では拾えない) なので、
  //     ここの受け止めは**その先の保険**であって、 落ちていた原因への
  //     手当てではない。
  //
  //   擬似端末を作る所は、 ネイティブの DLL を読み込む所から
  //   `CreateProcessW` まで、 いくつも転ぶ口がある。 どこで転んでも
  //   **全部ここで受け止めて**画面に理由を出し、 「もう一度」 を出せる
  //   ようにする。
  //
  //   ★ 起動直後に死ぬ形 (セキュリティソフトが子だけ撃った時など) は
  //     例外にならないので、 [_kLaunchWindow] の間に何も喋らないまま
  //     終わった物も「起こせなかった」 として扱う。 ただし**言い切らない**
  //     ([launchDiedEarly] を立てて、 画面は柔らかい言い方に変える) —
  //     引数の誤りやログイン切れでも同じ形になるため。
  String? launchError;
  bool get launchFailed => launchError != null;

  /// 「何も喋らないまま、 すぐ死んだ」 で失敗と見なしたか。
  ///
  /// ★ セキュリティソフトのせいだと決めつけない為の目印
  ///   (画面はこれを見て言い方を変える)。
  bool launchDiedEarly = false;

  /// 起動の失敗と見なす時間 (これより早く、 何も出さずに死んだら失敗)。
  static const Duration _kLaunchWindow = Duration(seconds: 3);

  /// 終わった後、 出力を汲み切るのに待つ時間。
  ///
  /// ★ flutter_pty は出力と終了を**別の口**で届ける (実測: ネイティブ側で
  ///   読み取りと終了待ちが別々の糸になっていて、 それぞれ別の Port へ
  ///   投げている)。 `exitCode` の説明にも「終了が返った時点で出力を
  ///   配り終えている保証は無い」 と明記されている。 そのまま判定すると、
  ///   CLI がエラー文を出してすぐ死んだ時にその文を取りこぼしたまま
  ///   「起こせなかった (= セキュリティソフト?)」 と誤って出してしまう。
  static const Duration _kDrainWindow = Duration(milliseconds: 800);

  /// 一度でも出力があったか (= 本当に動き出したか)。
  bool _sawOutput = false;

  /// 出力の流れが終わったか (擬似端末が口を閉じた時に立つ)。
  Completer<void>? _outputDone;

  /// 実際に終わった時刻 (汲み切るのに待った分を勘定に入れない為)。
  DateTime? _exitedAt;

  Pty? _pty;
  StreamSubscription<String>? _sub;

  // ── 順番待ち (= ユーザー要望: 処理が終わった後に、 用意しておいた指示を
  //    渡せるように) ──
  //
  //    CLI が「いま考え中か」 を外から知る手立ては無いので、 **画面が
  //    静かになったか**で見る。 考えている間はどの CLI も待ち表示を書き
  //    換え続けるので出力が途切れず、 返事が済むとぱたりと止まる。
  //    落ち着いて [_kIdle] 経つまで待ってから 1 件送る。
  static const Duration _kIdle = Duration(milliseconds: 2200);

  /// 最後に何か出力された時刻。
  DateTime _lastOutputAt = DateTime.now();

  // ── 「いま考えている最中か」 (= ユーザー要望: 処理を止めるボタンを、
  //    処理が始まったら出す) ──
  //
  //    CLI に「考え中です」 と教えてもらう手立ては無い。 ただ、 考えて
  //    いる間はどの CLI も待ち表示 (くるくる回る印や経過秒) を書き換え
  //    続けるので**出力が途切れない**。 順番待ちの判定に既に使っている
  //    この性質を、 そのまま外へ出す。
  //
  //    ★ 出力の受け取りは `notifyListeners()` を呼ばない (毎文字ごとに
  //      画面を組み直すと重いため) ので、 これだけでは画面が変わらない。
  //      走っている間だけ小さな見張りを回して、 値が変わった時にだけ
  //      知らせる。
  // ★ 判定は [starting] に任せる。 _readyAfterStart を直に見ると、 ずっと
  //   喋り続ける相手で _kStartupCap を過ぎた後も false のままになり、
  //   「停止」 が永久に出せなくなる (= 逃げ道を塞いでしまう)。
  bool get busy =>
      _running &&
      !starting &&
      DateTime.now().difference(_lastOutputAt) < _kIdle;

  // ── 立ち上がっている最中か (= ユーザー要望: CodexCLI が立ち上がる
  //    タイミングでも「停止」 が出るのはおかしい) ──
  //
  //    [busy] は「出力が途切れないか」 で考え中かを見ている。 ところが
  //    CLI は**起動中にも**名乗りや設定の読み込みを書き続けるので、 その
  //    間ずっと busy になり、 まだ何も走っていないのに「停止」 が出ていた。
  //    押しても、 起動しかけの CLI に Esc を送るだけで意味が無い。
  //
  //    ★ 起動の終わりは「一度でも出力が途切れた時」 で見る。 待ち時間を
  //      決め打ちにしないので、 速い機械でも遅い機械でも合う。
  //    ★ 万一ずっと喋り続ける相手でも [_kStartupCap] で必ず抜ける
  //      (抜けないと「停止」 が永久に出せなくなる)。
  static const Duration _kStartupCap = Duration(seconds: 60);
  DateTime? _startedAt;
  bool _readyAfterStart = false;

  bool get starting {
    if (!_running || _readyAfterStart) return false;
    final t = _startedAt;
    if (t != null && DateTime.now().difference(t) > _kStartupCap) return false;
    return true;
  }

  Timer? _busyTimer;
  bool _busyShown = false;

  void _startBusyTimer() {
    _busyTimer ??= Timer.periodic(const Duration(milliseconds: 400), (_) {
      // ★ 起動の終わり = 出力が一度途切れた時。 ここで捕まえる。
      if (_running &&
          !_readyAfterStart &&
          DateTime.now().difference(_lastOutputAt) >= _kIdle) {
        _readyAfterStart = true;
        _busyShown = false;
        notifyListeners();
        return;
      }
      final now = busy;
      if (now == _busyShown) return;
      // ★ 考え終わった = 渡した 1 件は無事に済んだ (控えを外す)。
      // ★ 考え終わった = 渡した 1 件は無事に済んだ (控えを外す)。
      //   ただし承認待ちなどの短い間は「終わった」 と見ない。
      if (!now && DateTime.now().difference(_lastOutputAt) >= _kIdle * 2) {
        _inFlight = null;
      }
      _busyShown = now;
      notifyListeners();
    });
  }

  final List<String> _queued = [];
  List<String> get queued => List<String>.unmodifiable(_queued);
  Timer? _queueTimer;

  /// 溜めておける件数の上限 (= ユーザー要望: 5 件まで)。
  ///
  /// ★ いくらでも溜められると、 渡す頃には前提が変わっていて
  ///   無駄に走らせるだけになるので、 意図的に少なくしてある。
  static const int kMaxQueued = 5;

  /// 溜めておける枠がもう無いか。
  bool get queueFull => _queued.length >= kMaxQueued;

  /// 順番待ちに足す。 入れられたら true。
  bool enqueue(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (queueFull) return false;
    _queued.add(t);
    _startQueueTimer();
    notifyListeners();
    return true;
  }

  // ── プランの上限で待つ (= ユーザー要望: 予約はやめて、 上限に当たったら
  //    解除まで待ってから送る) ─────────────────────────────
  //
  // ★ CLI は上限を「画面の文字」 でしか教えてくれない。 擬似端末の出力を
  //   見て、 上限らしい文言が出たら順番待ちを止め、 書いてあった再開時刻
  //   (読めなければ [_kLimitRetry] ごと) にひとりでに送り直す。
  //
  // ★ 出力は色と枠と折り返しだらけで、 「usage limit reached」 が
  //   「usage limit │\n│ reached」 のように割れて届く。 色と枠を落として
  //   1 行に均し、 直近の分をつないだ物 ([_outTail]) に当てる。
  //
  // ★ アプリが起きていて、 この CLI が走っている間だけ待てる
  //   (端末を閉じたら畳む)。 その事は画面側が伝える。

  /// 均した出力の直近分 (文言が chunk をまたいでも拾えるように)。
  final StringBuffer _outTail = StringBuffer();
  static const int _kTailMax = 4000;

  /// 上限が解けるのを待っている最中か。
  bool get limitWaiting => _limitWaiting;
  bool _limitWaiting = false;

  /// 再開する時刻 (読み取れなかった時は null = [_kLimitRetry] ごとに試す)。
  DateTime? get limitUntil => _limitUntil;
  DateTime? _limitUntil;

  /// 出力に添えてあった地域名 (例 'Asia/Tokyo')。 表示にだけ使う。
  String? get limitZoneNote => _limitZoneNote;
  String? _limitZoneNote;

  /// 上限が解けたら「続けて」 を送るか (= 返事の途中で切れた時)。
  bool get needsResumeWord => _needsResumeWord;
  bool _needsResumeWord = false;

  /// 上限が解けた後に送る言葉 (画面が表示言語に合わせて入れ替える)。
  String resumeWord = '続けて';

  /// 渡したが、 まだ返事が終わっていない 1 件。
  /// 上限で弾かれたらここから順番待ちへ戻す (= 消してしまわない)。
  String? _inFlight;

  Timer? _limitTimer;
  DateTime _limitSince = DateTime.now();
  int _shownLeftMin = -1;

  /// 時刻が読めなかった時に試し直す間隔。
  ///
  /// ★ 短くしても上限は早く解けない。 弾かれた分だけ無駄に出力が流れるので、
  ///   10 分に 1 度だけ様子を見る。
  static const Duration _kLimitRetry = Duration(minutes: 10);

  /// 上の待ち直しの間隔 (分)。 画面の文言に出すため公開している。
  static int get kLimitRetryMinutes => _kLimitRetry.inMinutes;

  /// 読み取った時刻に足す余裕 (きっかりだとまだ解けていない事がある)。
  static const Duration _kLimitMargin = Duration(seconds: 45);

  /// 一度見つけたら、 しばらくは二度目を見ない (同じ画面を描き直す度に
  /// 反応しない為)。
  static const Duration _kLimitDebounce = Duration(seconds: 90);
  DateTime _lastLimitHit = DateTime.fromMillisecondsSinceEpoch(0);

  /// 「待機をやめる」 の後、 見張りを止めておく時間。
  ///
  /// ★ 止めないと、 溜めた分を渡した先から同じ文言が出てまた待ちに入り、
  ///   利用者が抜け出せなくなる。
  static const Duration _kLimitMute = Duration(minutes: 30);
  DateTime _limitMuteUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // 色・枠・折り返しを落として 1 行に均す為の型。
  static final RegExp _kAnsi = RegExp(
      r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\)|[@-Z_\\])');
  static final RegExp _kBoxy = RegExp(r'[─-▟\r\n\t]');
  static final RegExp _kSpaces = RegExp(r'\s{2,}');

  static String _flatten(String s) => s
      .replaceAll(_kAnsi, ' ')
      .replaceAll(_kBoxy, ' ')
      .replaceAll(_kSpaces, ' ');

  /// 「上限に当たった」 と言い切れる文言だけ。
  ///
  /// ★ ここは**狭く**取る。 `/usage` の画面にも「resets 3:10pm」 は出るし、
  ///   「approaching your usage limit」 は当たる前の注意書きなので、 これらで
  ///   待ちに入ると動かなくなる。 当たった事を言う語 (reached / exceeded /
  ///   hit / out of) を必ず伴う物だけを拾う。
  static final List<RegExp> _kLimitHits = [
    RegExp(r'usage limit reached'),
    RegExp(r"hit (?:your|the) [a-z0-9 \-']{0,28}limit"),
    RegExp(r'reached (?:your|the) [a-z0-9 \-]{0,28}(?:limit|quota)'),
    RegExp(r'(?:hour|daily|weekly|monthly|session|spend|rate) limit reached'),
    RegExp(r'quota exceeded'),
    RegExp(r'exceeded your current quota'),
    RegExp(r'resource[_ ]exhausted'),
    RegExp(r'rate limit exceeded'),
    RegExp(r'\b429\b[^.]{0,40}(?:quota|limit|rate)'),
    RegExp(r'(?:quota|limit|rate)[^.]{0,40}\b429\b'),
    RegExp(r'out of (?:credits|usage)'),
    RegExp(r'credit balance is too low'),
    RegExp(r'insufficient (?:credits|quota)'),
    RegExp(r'上限に達し'),
    RegExp(r'上限を超え'),
    RegExp(r'利用上限'),
  ];

  /// 待っても直らない物 / まだ当たっていない物は除く。
  static final RegExp _kNotPlanLimit = RegExp(
      r'context (?:window|limit)|token limit|too many tokens|'
      r'prompt is too long|approaching|almost|nearly|will reach|まもなく');

  static bool _looksLikeLimit(String tail) {
    for (final r in _kLimitHits) {
      final m = r.firstMatch(tail);
      if (m == null) continue;
      final from = m.start - 80 < 0 ? 0 : m.start - 80;
      final to = m.end + 80 > tail.length ? tail.length : m.end + 80;
      if (_kNotPlanLimit.hasMatch(tail.substring(from, to))) continue;
      return true;
    }
    return false;
  }

  /// 端末へ書いた出力を見て、 上限に当たっていないか調べる。
  void _scanForLimit(String chunk) {
    if (!_running || isInstall || isShell) return;
    final now = DateTime.now();
    if (now.isBefore(_limitMuteUntil)) return;
    final flat = _flatten(chunk);
    if (flat.trim().isEmpty) return;
    _outTail.write(flat);
    if (_outTail.length > _kTailMax) {
      final s = _outTail.toString();
      _outTail
        ..clear()
        ..write(s.substring(s.length - _kTailMax));
    }
    if (_limitWaiting) return;
    if (now.difference(_lastLimitHit) < _kLimitDebounce) return;
    final raw = _outTail.toString();
    final tail = raw.toLowerCase();
    if (!_looksLikeLimit(tail)) return;
    _lastLimitHit = now;
    final at = _parseResetAt(tail, raw, now);
    // 同じ文言にもう一度当たらないよう、 見た分は捨てる。
    _outTail.clear();
    _enterLimitWait(at);
  }

  /// 文言から再開時刻を読み取る。 読めなければ null。
  ///
  /// ★ 読めた時刻は**この端末の地元時間**として扱う (CLI は利用者の時計で
  ///   書き出す)。 括弧の中の地域名は表示にだけ使い、 計算には使わない —
  ///   取り違えると丸一日待たせてしまう。 読めなかった時と同じ
  ///   [_kLimitRetry] の試し直しが、 どちらにせよ保険として動く。
  DateTime? _parseResetAt(String tail, String raw, DateTime now) {
    _limitZoneNote = null;
    // 「try again in 12 minutes」
    final rel = RegExp(r'(?:try again|retry|available again) in '
            r'(\d{1,3}) ?(second|minute|hour)')
        .firstMatch(tail);
    if (rel != null) {
      final n = int.tryParse(rel.group(1) ?? '') ?? 0;
      if (n > 0) {
        switch (rel.group(2)) {
          case 'second':
            return now.add(Duration(seconds: n));
          case 'minute':
            return now.add(Duration(minutes: n));
          case 'hour':
            return now.add(Duration(hours: n));
        }
      }
    }
    // 「limit resets 3:10pm」「will reset at 3pm (Asia/Tokyo)」「resets at 15:10」
    final m = RegExp(r'reset(?:s|ting)?(?: at| on)? '
            r'(\d{1,2})(?::(\d{2}))? ?(am|pm)?')
        .firstMatch(tail);
    if (m == null) return null;
    var h = int.tryParse(m.group(1) ?? '');
    if (h == null || h < 0 || h > 23) return null;
    final min = int.tryParse(m.group(2) ?? '0') ?? 0;
    if (min < 0 || min > 59) return null;
    final ap = m.group(3);
    if (ap == 'pm' && h < 12) h += 12;
    if (ap == 'am' && h == 12) h = 0;
    if (h > 23) return null;
    // 地域名は元の大小文字のまま拾う (表示用)。
    final zm = RegExp(r'reset[a-z]*(?: at| on)? [^()]{0,24}\(([^)]{1,40})\)',
            caseSensitive: false)
        .firstMatch(raw);
    final z = zm?.group(1)?.trim();
    if (z != null && z.isNotEmpty) _limitZoneNote = z;
    var at = DateTime(now.year, now.month, now.day, h, min);
    // ★ 過ぎていたら明日。 ただし数分の遅れ (文言が出てから読むまでのずれ)
    //   で丸一日待たされないよう、 少しの過去は今日のままにする。
    if (at.isBefore(now.subtract(const Duration(minutes: 5)))) {
      at = at.add(const Duration(days: 1));
    }
    if (!at.isAfter(now)) at = now.add(const Duration(seconds: 30));
    // ★ 読み違いの保険。 12 時間より先は信じない (= 時刻無しとして扱う)。
    if (at.difference(now) > const Duration(hours: 12)) return null;
    return at;
  }

  /// 上限と見て、 順番待ちを止める。
  void _enterLimitWait(DateTime? at) {
    _limitWaiting = true;
    _limitUntil = at;
    _limitSince = DateTime.now();
    _shownLeftMin = -1;
    // ★ 渡した先から弾かれた分は捨てない (= ユーザー要望: 上限で消えない)。
    final back = _inFlight;
    _inFlight = null;
    if (back != null) {
      _queued.insert(0, back);
      _needsResumeWord = false;
    } else {
      // こちらが渡した物ではない = 返事の途中で切れた。 続きを頼む。
      _needsResumeWord = !starting;
    }
    _limitTimer ??=
        Timer.periodic(const Duration(seconds: 20), (_) => _tickLimit());
    terminal.write(at == null
        ? '\r\n[上限に達したようです — 解けるのを待って送り直します]\r\n'
        : '\r\n[上限に達したようです — ${_hhmm(at)} に送り直します]\r\n');
    notifyListeners();
  }

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  void _tickLimit() {
    if (!_running) {
      _limitTimer?.cancel();
      _limitTimer = null;
      return;
    }
    if (!_limitWaiting) return;
    final now = DateTime.now();
    final at = _limitUntil;
    if (at != null) {
      if (now.isAfter(at.add(_kLimitMargin))) {
        resumeFromLimit();
        return;
      }
    } else if (now.difference(_limitSince) >= _kLimitRetry) {
      resumeFromLimit();
      return;
    }
    // 残りの表示を進める (分が変わった時だけ知らせる)。
    final left = at == null
        ? _kLimitRetry - now.difference(_limitSince)
        : at.difference(now);
    if (left.inMinutes != _shownLeftMin) {
      _shownLeftMin = left.inMinutes;
      notifyListeners();
    }
  }

  /// 待つのをやめて送り直す (時刻が来た時 / 「今すぐ試す」)。
  void resumeFromLimit() {
    if (!_limitWaiting) return;
    _limitWaiting = false;
    _limitUntil = null;
    _limitZoneNote = null;
    _shownLeftMin = -1;
    _limitTimer?.cancel();
    _limitTimer = null;
    // ★ 返事の途中で切れていた時は、 まず「続けて」 で続きから始めさせる
    //   (= ユーザー要望)。
    if (_needsResumeWord) {
      _needsResumeWord = false;
      final w = resumeWord.trim();
      if (w.isNotEmpty) _queued.insert(0, w);
    }
    // 次の見回りですぐ 1 件出せるように、 落ち着いた事にする。
    _lastOutputAt =
        DateTime.now().subtract(_kIdle + const Duration(seconds: 1));
    // ★ 見張りはすぐには解かない。 解くと、 画面に残ったままの同じ文言を
    //   もう一度拾って待ちへ戻り、 「続けて」 を繰り返し送ってしまう。
    //   [_kLimitDebounce] の間を置いてから、 新しく出た文言だけを見る。
    _lastLimitHit = DateTime.now();
    _outTail.clear();
    if (_queued.isNotEmpty) _startQueueTimer();
    notifyListeners();
  }

  /// 待つのをやめる (溜めた分はそのまま渡す)。
  ///
  /// ★ ここで見張りを [_kLimitMute] だけ止める。 止めないと、 渡した先から
  ///   同じ文言が出てまた待ちに入り、 利用者が抜け出せなくなる。
  void cancelLimitWait() {
    if (!_limitWaiting) return;
    _limitMuteUntil = DateTime.now().add(_kLimitMute);
    _needsResumeWord = false;
    resumeFromLimit();
  }

  /// 「続けて」 を送らないようにする (= 自分で打ち直す時)。
  void dropResumeWord() {
    if (!_needsResumeWord) return;
    _needsResumeWord = false;
    notifyListeners();
  }

  void cancelQueued(int index) {
    if (index < 0 || index >= _queued.length) return;
    _queued.removeAt(index);
    notifyListeners();
  }

  void clearQueued() {
    if (_queued.isEmpty) return;
    _queued.clear();
    notifyListeners();
  }

  void _startQueueTimer() {
    _queueTimer ??=
        Timer.periodic(const Duration(milliseconds: 500), (_) => _pumpQueue());
  }

  void _pumpQueue() {
    if (_queued.isEmpty || !_running) {
      _queueTimer?.cancel();
      _queueTimer = null;
      return;
    }
    // ★ 上限で待っている間は渡さない。 消さずにそのまま持っておく
    //   (= ユーザー要望: 上限が解けるまで送信を待つ)。
    if (_limitWaiting) return;
    if (DateTime.now().difference(_lastOutputAt) < _kIdle) return;
    final next = _queued.removeAt(0);
    // ★ 渡した 1 件は、 返事が終わるまで控えておく。 上限で弾かれたら
    //   ここから順番待ちの先頭へ戻す (消えてしまわないように)。
    _inFlight = next;
    // 送った時点で出力が動くので、 次の 1 件はまた落ち着くまで待つ。
    _lastOutputAt = DateTime.now();
    send(next);
    notifyListeners();
  }

  Completer<int> _finished = Completer<int>();

  /// 終わるまで待つ (画面を閉じていても必ず 1 回返る)。
  Future<int> get finished => _finished.future;

  /// もう一度起こす (= 画面の「もう一度」)。
  ///
  /// ★ 起こせなかった時に、 同じ物をそのまま組み直せるようにする。
  ///   一度終わった実行は置き場から外れているので、 入れ直してから走らせる。
  void retry() {
    if (_running) return;
    exitCode = null;
    stoppedByUser = false;
    launchError = null;
    launchDiedEarly = false;
    _sawOutput = false;
    _outputDone = null;
    _exitedAt = null;
    if (_finished.isCompleted) _finished = Completer<int>();
    if (!AgentCliRunner.active.contains(this)) AgentCliRunner.active.add(this);
    final f = _finished.future;
    unawaited(f.whenComplete(() => AgentCliRunner.active.remove(this)));
    terminal.write('\r\n');
    start();
    notifyListeners();
  }

  void start() {
    if (_running || exitCode != null) return;
    // 日本語を含む道筋のために、 一時的に現在地を移した時の戻し先。
    String? savedCwd;
    // ★ 起こす前に、 その実行ファイルが本当にあるか見る。 擬似端末は
    //   ネイティブ側で転ぶと Dart では拾えないので、 転ぶ前に止める。
    final pre = AgentCli.launchPreflightError(exePath);
    if (pre != null) {
      launchError = pre;
      terminal.write('\r\n[起動できませんでした] $pre\r\n');
      _onExit(-1);
      return;
    }
    try {
      // ★ 何を走らせているかを先に出す (= ユーザー要望: 裏で何が
      //   走っているのか分からない)。
      terminal.write('> $exePath ${arguments.join(' ')}\r\n');
      terminal.write('  ($workingDirectory)\r\n\r\n');
      // ★ 日本語を含む道筋は擬似端末にそのまま渡せない (= ユーザー報告:
      //   デスクトップの下でターミナルが開けない)。 flutter_pty の Windows
      //   実装が道筋を 1 バイトずつ WCHAR へ広げるだけなので、 文字化けした
      //   場所を渡して「プロセスを作れない」 で落ちていた。
      //   8.3 形式の短い名前 (英数字だけ) に直し、 それも使えない時は
      //   このプロセスの現在地を一瞬だけ移して引き継がせる。
      String? cwdArg = workingDirectory;
      if (Platform.isWindows && !AgentCli.isAscii(workingDirectory)) {
        final safe = AgentCli.ptySafeDirectory(workingDirectory);
        if (safe != null) {
          cwdArg = safe;
        } else {
          try {
            savedCwd = Directory.current.path;
            Directory.current = workingDirectory;
            cwdArg = null; // 親 (= このアプリ) の現在地を引き継ぐ
          } catch (_) {
            savedCwd = null;
          }
        }
      }
      final pty = Pty.start(
        // ★ 空白を含む道筋 (`C:\Program Files\…`) は、 引用符を付けずに
        //   つなぐ flutter_pty ではそのまま渡せない。 短い名前に直す。
        AgentCli.ptySafePath(exePath),
        arguments: arguments,
        workingDirectory: cwdArg,
        // 端末の大きさはそのまま伝える (CLI はこれを見て表示を組む)。
        // ★ ただし 0 は渡さない。 まだ一度も組まれていない端末は 0 を返し、
        //   Windows の擬似端末 (CreatePseudoConsole) は 0 を渡されると
        //   作れずに失敗する (= 起動できない口の 1 つ)。
        columns: terminal.viewWidth > 0 ? terminal.viewWidth : 80,
        rows: terminal.viewHeight > 0 ? terminal.viewHeight : 25,
        // ★ 日本語を含む値は壊れて渡るので、 英数字だけに整えてから
        //   渡す (= 実測: Path と PSModulePath が壊れていた)。
        //   この実行にだけ足す物 (API キーなど) は後ろに重ねる。
        environment: {
          ...AgentCli.asciiEnvironment(),
          ...extraEnvironment,
        },
      );
      _pty = pty;
      _running = true;
      // 立ち上がり直し。 「起動中」 からやり直す (= 停止を出さない)。
      _startedAt = DateTime.now();
      _readyAfterStart = false;
      _busyShown = false;
      _startBusyTimer();
      // ★ 文字の切れ目を跨いでも壊れないように、 流れたまま解く
      //   (1 回分ずつ utf8.decode すると、 途中で切れた文字が □ になる)。
      final drained = Completer<void>();
      _outputDone = drained;
      _sub = pty.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((chunk) {
        // 順番待ちの判断に使う「最後に何か出た時刻」。
        _lastOutputAt = DateTime.now();
        // ★ 一度でも喋れば「本当に動き出した」 (= 起動の失敗ではない)。
        if (chunk.isNotEmpty) _sawOutput = true;
        terminal.write(chunk);
        // ★ プランの上限に当たっていないか見る (当たっていたら順番待ちを
        //   止めて、 解けるのを待つ = ユーザー要望)。
        _scanForLimit(chunk);
      }, onError: (Object e) {
        terminal.write('\r\n[エラー] $e\r\n');
      }, onDone: () {
        // ★ 擬似端末が口を閉じた = これ以上は出て来ない。 終わりの判定は
        //   これを待ってから行う ([_kDrainWindow])。
        if (!drained.isCompleted) drained.complete();
      });
      // 打った物・矢印キーなどは、 端末がまとめて教えてくれる。
      terminal.onOutput = (data) {
        try {
          pty.write(const Utf8Encoder().convert(data));
        } catch (_) {}
      };
      terminal.onResize = (w, h, pw, ph) {
        try {
          pty.resize(h, w);
        } catch (_) {}
      };
      unawaited(_watchExit(pty));
      notifyListeners();
    } catch (e, st) {
      // ★ 擬似端末は DLL の読み込みから `CreateProcessW` まで転ぶ口が多い。
      //   どこで転んでもアプリは落とさず、 理由だけ画面に出す
      //   (= ユーザー報告: ターミナルを押すとアプリが落ちる)。
      debugPrint('AgentCliSession.start failed: $e\n$st');
      launchError = '$e';
      terminal.write('\r\n[起動できませんでした] $e\r\n');
      _onExit(-1);
    } finally {
      if (savedCwd != null) {
        try {
          Directory.current = savedCwd;
        } catch (_) {}
      }
    }
  }

  /// 終わりを待って片付ける。
  ///
  /// ★ ここで `await` を 1 つ挟むのが肝。 出力と終了は別の口から届くので、
  ///   速く死んだ相手では**終了の方が先に着く**。 そのまま判定すると、
  ///   CLI が出したエラー文 (引数違い・ログイン切れなど) を画面に出す前に
  ///   購読を切ってしまい、 端末には最初の 1 行と `[終了しました]` しか
  ///   残らないまま「セキュリティソフトに止められたかも」 と誤った案内を
  ///   出してしまう。
  Future<void> _watchExit(Pty pty) async {
    int code;
    try {
      code = await pty.exitCode;
    } catch (e) {
      // ★ ネイティブ側から返ってきた失敗も、 ここで受け止めて終わらせる
      //   (投げっぱなしにすると拾い手の無い例外になる)。
      launchError ??= '$e';
      terminal.write('\r\n[エラー] $e\r\n');
      _onExit(-1);
      return;
    }
    // ★ 「すぐ死んだか」 は**終わった時刻**で見る (汲み切るのに待った分を
    //   足してしまうと、 待った所為で判定が変わる)。
    _exitedAt = DateTime.now();
    await _drainOutput();
    _onExit(code);
  }

  /// まだ配られていない出力を汲み切る (長くても [_kDrainWindow])。
  Future<void> _drainOutput() async {
    final d = _outputDone;
    if (d != null && !d.isCompleted) {
      try {
        await d.future.timeout(_kDrainWindow);
      } catch (_) {
        // 来なくても先へ進む (待ち続けて終われない方が困る)。
      }
    }
    // 受け取った分が端末に描かれるまで、 もう 1 拍だけ譲る。
    await Future<void>.delayed(Duration.zero);
  }

  void _onExit(int code) {
    if (exitCode != null) return;
    // ★ 起こした直後に、 何も喋らないまま死んだ物は「起こせなかった」 と
    //   見なす (= セキュリティソフトに子だけ撃たれた時など。 例外は
    //   飛んでこないので、 時間と出力の有無でしか見分けられない)。
    //   ★ 出力は [_drainOutput] で汲み切った後に見る。 先に見ると、
    //     エラー文を出してすぐ死んだ相手を取りこぼす。
    //   ★ 決めつけない。 [launchDiedEarly] を立てて、 画面には
    //     「起動直後に終了した」 という事実の方を出す。
    final began = _startedAt;
    if (launchError == null &&
        !stoppedByUser &&
        code != 0 &&
        !_sawOutput &&
        began != null &&
        (_exitedAt ?? DateTime.now()).difference(began) < _kLaunchWindow) {
      launchError = 'exited immediately (code $code)';
      launchDiedEarly = true;
    }
    exitCode = code;
    _running = false;
    _readyAfterStart = false;
    _startedAt = null;
    _queueTimer?.cancel();
    _queueTimer = null;
    _busyTimer?.cancel();
    _busyTimer = null;
    _queued.clear();
    // ★ 端末が閉じたら上限待ちも畳む (送る先が無いため)。
    _limitWaiting = false;
    _limitUntil = null;
    _limitZoneNote = null;
    _needsResumeWord = false;
    _inFlight = null;
    _outTail.clear();
    _limitTimer?.cancel();
    _limitTimer = null;
    unawaited(_sub?.cancel());
    _sub = null;
    terminal.onOutput = null;
    terminal.onResize = null;
    terminal.write('\r\n[終了しました (コード $code)]\r\n');
    notifyListeners();
    if (!_finished.isCompleted) _finished.complete(code);
  }

  /// 打った文字を送る。
  ///
  /// ★ 端末の Enter は `\r` (改行 `\n` ではない)。 `\n` だと選択肢の画面で
  ///   確定できない (= ユーザー報告: 選択肢を Enter で確定させたい)。
  void send(String text) => sendRaw('$text\r');

  /// 矢印キーなどをそのまま送る。
  void sendRaw(String seq) {
    final pty = _pty;
    if (pty == null || !_running) return;
    try {
      pty.write(const Utf8Encoder().convert(seq));
      _recordTyped(seq);
    } catch (e) {
      terminal.write('\r\n[送れませんでした] $e\r\n');
    }
  }

  // ── いまの会話で投げた指示の控え (= ユーザー要望: 現在の会話履歴) ──
  //
  //   打った物は 1 文字ずつ流れていくので、 改行が来た所で 1 行と数える。
  //   矢印などの制御が挟まった行は当てにならないので捨てる。
  final List<String> _sentLines = [];
  List<String> get sentLines => List<String>.unmodifiable(_sentLines);
  final StringBuffer _lineBuf = StringBuffer();

  void _recordTyped(String seq) {
    var changed = false;
    for (final r in seq.runes) {
      if (r == 0x0d || r == 0x0a) {
        final t = _lineBuf.toString().trim();
        _lineBuf.clear();
        if (t.isNotEmpty && !t.startsWith('/')) {
          if (_sentLines.isEmpty || _sentLines.last != t) {
            _sentLines.add(t);
            if (_sentLines.length > 100) _sentLines.removeAt(0);
            changed = true;
          }
        }
      } else if (r >= 0x20 && r != 0x7f) {
        _lineBuf.write(String.fromCharCode(r));
      } else {
        // 制御文字 (矢印の始まりなど) が来たら、 その行は数えない。
        _lineBuf.clear();
      }
    }
    if (changed) notifyListeners();
  }

  /// 「止める」 を押した時だけ呼ぶ。
  void kill() {
    stoppedByUser = true;
    try {
      _pty?.kill();
    } catch (_) {}
  }

  @override
  void dispose() {
    // 画面が消えても止めない。 後始末は終わった時に済ませてある。
    super.dispose();
  }
}

/// 走らせている物の置き場。 画面はここを見るだけ。
class AgentCliRunner {
  AgentCliRunner._();

  /// まだ終わっていない実行。
  static final List<AgentCliSession> active = <AgentCliSession>[];

  /// 走らせ始める。 終わったら置き場から外す。
  ///
  /// ★ ここで転んでも画面は開いたままにする (理由を出して「もう一度」)。
  ///   = ユーザー報告「ターミナルボタンを押すとセキュリティソフトに
  ///   ブロックされてアプリが落ちてしまう」 の**手当てそのものではない**
  ///   (撃たれていたのはアプリのプロセスで、 Dart の例外ではない)。
  ///   効いているのは [AgentCli.shellLaunch] から隠し PowerShell +
  ///   base64 を外した所。 ここはその先の保険。
  static AgentCliSession begin(AgentCliSession session) {
    active.add(session);
    try {
      session.start();
    } catch (e, st) {
      debugPrint('AgentCliRunner.begin failed: $e\n$st');
      session.launchError ??= '$e';
      session._onExit(-1);
    }
    unawaited(session.finished.whenComplete(() {
      active.remove(session);
    }));
    return session;
  }

  /// まだ走っている物があるか (アプリを閉じる時の確認などに使える)。
  static bool get anyRunning => active.any((s) => s.running);
}
