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

  final List<String> _queued = [];
  List<String> get queued => List<String>.unmodifiable(_queued);
  Timer? _queueTimer;

  /// 順番待ちに足す。
  void enqueue(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _queued.add(t);
    _startQueueTimer();
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
    if (DateTime.now().difference(_lastOutputAt) < _kIdle) return;
    final next = _queued.removeAt(0);
    // 送った時点で出力が動くので、 次の 1 件はまた落ち着くまで待つ。
    _lastOutputAt = DateTime.now();
    send(next);
    notifyListeners();
  }

  final Completer<int> _finished = Completer<int>();

  /// 終わるまで待つ (画面を閉じていても必ず 1 回返る)。
  Future<int> get finished => _finished.future;

  void start() {
    if (_running || exitCode != null) return;
    // 日本語を含む道筋のために、 一時的に現在地を移した時の戻し先。
    String? savedCwd;
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
        exePath,
        arguments: arguments,
        workingDirectory: cwdArg,
        // 端末の大きさはそのまま伝える (CLI はこれを見て表示を組む)。
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
        // ★ 日本語を含む値は壊れて渡るので、 英数字だけに整えてから
        //   渡す (= 実測: Path と PSModulePath が壊れていた)。
        environment: AgentCli.asciiEnvironment(),
      );
      _pty = pty;
      _running = true;
      // ★ 文字の切れ目を跨いでも壊れないように、 流れたまま解く
      //   (1 回分ずつ utf8.decode すると、 途中で切れた文字が □ になる)。
      _sub = pty.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((chunk) {
        // 順番待ちの判断に使う「最後に何か出た時刻」。
        _lastOutputAt = DateTime.now();
        terminal.write(chunk);
      }, onError: (Object e) {
        terminal.write('\r\n[エラー] $e\r\n');
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
      unawaited(pty.exitCode.then(_onExit).catchError((Object e) {
        terminal.write('\r\n[エラー] $e\r\n');
        _onExit(-1);
        return -1;
      }));
      notifyListeners();
    } catch (e) {
      terminal.write('端末を開けませんでした: $e\r\n');
      _onExit(-1);
    } finally {
      if (savedCwd != null) {
        try {
          Directory.current = savedCwd;
        } catch (_) {}
      }
    }
  }

  void _onExit(int code) {
    if (exitCode != null) return;
    exitCode = code;
    _running = false;
    _queueTimer?.cancel();
    _queueTimer = null;
    _queued.clear();
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
    } catch (e) {
      terminal.write('\r\n[送れませんでした] $e\r\n');
    }
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
  static AgentCliSession begin(AgentCliSession session) {
    active.add(session);
    session.start();
    unawaited(session.finished.whenComplete(() {
      active.remove(session);
    }));
    return session;
  }

  /// まだ走っている物があるか (アプリを閉じる時の確認などに使える)。
  static bool get anyRunning => active.any((s) => s.running);
}
