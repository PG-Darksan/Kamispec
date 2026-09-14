// ── アプリの中のターミナル (AI の CLI 用) ──
//
// (= ユーザー要望: codex CLI / Gemini CLI / Claude Code をアプリ内にログインして
//  指示出して使えるように)
//
// 本物の擬似端末 (Windows は ConPTY) で CLI を動かす。CLI が「端末がある」と
// 判断できるので、ログインの案内がそのまま出て、CLI 自身が既定のブラウザを
// 開き、認証後のコールバックも CLI 自身が受け取る。アプリは端末を用意する
// だけで、資格情報には一切触らない。
//
// ★ ここは「見るだけ」。 走らせている物は AgentCliSession が持っているので、
//   この欄を閉じても止まらない (= ユーザー要望: 閉じて止まると面倒)。
//   止まるのは「終了」 を押した時だけ。
//
// ── 打ち込みの仕組み (ここが一番の勘所) ──
//   端末の部品 (xterm) に任せると、 **普通の文字と日本語だけ**が OS の
//   「文字の受け口」 (TextInput) を通る作りになっている。 この受け口が
//   このアプリでは開かず、 矢印は効くのに文字が打てない状態だった。
//
//   そこで打ち込み口は**自前で持つ**。 1 行の入力欄を**カーソルの所**に
//   重ねて焦点を預け、
//     ・ただの文字 … 押されたキーからそのまま端末へ流す (受け口を待たない)
//     ・かな漢字変換 … 入力欄が受け取り、 確定した所で端末へ流す
//     ・矢印 / Enter / Ctrl+◯ … 端末の決まりに直して流す
//   という振り分けにしてある。 変換中の文字はカーソルの位置にそのまま出る
//   ので、 本物の端末と同じ見え方になる (= ユーザー報告: 日本語が打てない)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../services/agent_cli_session.dart';

/// 押されたキー → 端末の決まり。
///
/// ★ xterm の変換表は公開されていないので、 CLI で要る物だけここに持つ。
///   ここに載せた物は `Terminal.keyInput` が正しい脱出文字へ直してくれる
///   (矢印の `\E[A` や Shift+Tab の `\E[Z` など)。
/// ★ `LogicalKeyboardKey` は `==` を持つので **const Map にはできない**。
final Map<LogicalKeyboardKey, TerminalKey> _kTermKeys = {
  LogicalKeyboardKey.enter: TerminalKey.enter,
  LogicalKeyboardKey.numpadEnter: TerminalKey.enter,
  LogicalKeyboardKey.escape: TerminalKey.escape,
  LogicalKeyboardKey.tab: TerminalKey.tab,
  LogicalKeyboardKey.backspace: TerminalKey.backspace,
  LogicalKeyboardKey.delete: TerminalKey.delete,
  LogicalKeyboardKey.insert: TerminalKey.insert,
  LogicalKeyboardKey.home: TerminalKey.home,
  LogicalKeyboardKey.end: TerminalKey.end,
  LogicalKeyboardKey.pageUp: TerminalKey.pageUp,
  LogicalKeyboardKey.pageDown: TerminalKey.pageDown,
  LogicalKeyboardKey.arrowUp: TerminalKey.arrowUp,
  LogicalKeyboardKey.arrowDown: TerminalKey.arrowDown,
  LogicalKeyboardKey.arrowLeft: TerminalKey.arrowLeft,
  LogicalKeyboardKey.arrowRight: TerminalKey.arrowRight,
  LogicalKeyboardKey.f1: TerminalKey.f1,
  LogicalKeyboardKey.f2: TerminalKey.f2,
  LogicalKeyboardKey.f3: TerminalKey.f3,
  LogicalKeyboardKey.f4: TerminalKey.f4,
  LogicalKeyboardKey.f5: TerminalKey.f5,
  LogicalKeyboardKey.f6: TerminalKey.f6,
  LogicalKeyboardKey.f7: TerminalKey.f7,
  LogicalKeyboardKey.f8: TerminalKey.f8,
  LogicalKeyboardKey.f9: TerminalKey.f9,
  LogicalKeyboardKey.f10: TerminalKey.f10,
  LogicalKeyboardKey.f11: TerminalKey.f11,
  LogicalKeyboardKey.f12: TerminalKey.f12,
};

class AgentTerminal extends StatefulWidget {
  const AgentTerminal({
    super.key,
    required this.session,
    this.showHeader = true,
    this.onRunAgain,
    this.onPickLanguage,
  });

  /// 走らせている物。 この widget は覗くだけで、 止めたりはしない。
  final AgentCliSession session;

  /// 見出しの帯を自分で出すか。
  final bool showHeader;

  /// 「もう一度」 を押した時 (同じ物をもう 1 回走らせる)。
  final VoidCallback? onRunAgain;

  /// 「言語」 を押した時 (= CLI が返事をする言葉を選び直す)。
  final VoidCallback? onPickLanguage;

  @override
  State<AgentTerminal> createState() => AgentTerminalState();
}

class AgentTerminalState extends State<AgentTerminal> {
  final _termController = TerminalController();

  /// 端末の画面そのもの。
  final _viewKey = GlobalKey<TerminalViewState>();

  /// カーソルの位置を測るための入れ物。
  final _stackKey = GlobalKey();

  /// 画面の巻き上げ (= ユーザー要望: 上へ流れた会話を遡りたい)。
  final _scroll = ScrollController();

  /// 端末側の焦点。
  ///
  /// ★ **わざと焦点を取らせない**。 端末に焦点が行くと、 打ち込みが端末の
  ///   「文字の受け口」 側に戻ってしまい、 日本語が打てなくなる。
  final _termFocus = FocusNode(
      debugLabel: 'agent_cli_term', canRequestFocus: false, skipTraversal: true);

  /// 打ち込み口。 かな漢字変換もここを通る。
  final _inputFocus = FocusNode(debugLabel: 'agent_cli_input');
  final _inputCtrl = TextEditingController();

  /// 順番待ちに足す時の入力欄。
  final _queueCtrl = TextEditingController();
  final _queueFocus = FocusNode(debugLabel: 'agent_cli_queue');
  bool _queueOpen = false;

  /// いまの会話で投げた指示の一覧を出しているか (= ユーザー要望)。
  bool _histOpen = false;

  /// いま変換中の文字。
  String _composing = '';

  /// いま CLI 側へ「先出し」 している文字。
  ///
  /// ★ = ユーザー要望「Enter を押さないとチャット欄に出てこないのが使い
  ///   にくい。 直接打ち込めるように」。 変換中の文字も、 打つそばから
  ///   CLI の入力欄へ送る。 変換が進んで中身が変わったら、 先に送った分を
  ///   後退で消してから送り直す。 確定した時には既に出ているので、
  ///   改めて送らない。
  String _liveSent = '';

  /// 送り出しの最中か (入力欄を空に戻す時の呼び戻しを止める)。
  bool _flushing = false;

  /// 一番下に貼り付いているか (= false の間は「最新へ」 を出す)。
  bool _atBottom = true;

  /// 端末のカーソルの位置 (この widget の中での座標)。
  Offset? _cursorPos;

  /// いま開いていると思われる CLI の画面 (/usage など)。
  /// 同じボタンをもう一度押したら Esc を送って閉じる (= ユーザー要望)。
  String? _openPanelCmd;

  // ── 「文字の受け口」 が生きているかの見極め ─────────────────────────────
  //
  //   ★ ここが全角入力の肝 (= ユーザー報告: 半角英数しか打てない)。
  //     押鍵をこちらで **handled** にすると、 Windows はその打鍵を OS へ
  //     投げ返さないので **IME が変換を始められない**。 それで半角だけが
  //     通り、 かな漢字変換は永久に始まらなかった。
  //
  //     そこで打鍵は必ず OS へ通す (ignored) ことにして、 受け口が死んで
  //     いた時だけ自前で送る。 死活は「受け口から何か届いたか」 で判る
  //     ので、 最初の数打鍵だけ様子を見て、 届かなければ以後は自前で送る。
  //   null = まだ判らない / true = 生きている / false = 死んでいる
  bool? _textPathAlive;

  /// 受け口の返事を待っている間の控え。
  final StringBuffer _pendingKeys = StringBuffer();
  Timer? _pendingTimer;

  AgentCliSession get _s => widget.session;

  // ── 打ち込み先を CLI から返す (= ユーザー報告: 「codexCLI などが開いて
  //    いる時にページ要素を編集しようとすると codex 側に吸われてしまって
  //    要素を上手く編集することができない」) ──
  //
  //   この端末は、 かな漢字変換のために **見えない入力欄**を端末の上に
  //   重ねている (xterm 自身の受け口は使っていない)。 その入力欄が
  //   ・`autofocus: true`
  //   ・`onTapOutside: (_) {}` (= 外を押しても焦点を離さない)
  //   ・700ms ごとに焦点を取り戻す見張り
  //   の 3 段構えで焦点を抱え込んでいたため、 要素の名前を書き換えようと
  //   すると 0.7 秒以内に焦点を奪われ、 打った文字がそのまま CLI へ
  //   流れ込んでいた (しかも要素の編集欄は焦点を失うと自分で閉じる)。
  //
  //   そこで「利用者が自分で外へ出た」 という掛け金を持つ。 掛かっている
  //   間は焦点を取り戻さない。 端末をもう一度押せば外れる。
  bool _userLeft = false;

  /// いま画面に出ている端末たち (= 画面側から焦点を返させるため)。
  static final Set<AgentTerminalState> live = <AgentTerminalState>{};

  /// キーボードを手放す (画面側がキャンバスを押した時などに呼ぶ)。
  void releaseKeyboard() {
    _userLeft = true;
    if (_inputFocus.hasFocus) _inputFocus.unfocus();
  }

  /// 端末に戻ってきた (押された) ので、 また打てるようにする。
  ///
  /// ★ = ユーザー報告「CLI の画面を動かしたり、 他の画面外の要素を編集すると
  ///   CLI のプロンプト欄に入れられなくなる」。
  ///   `releaseKeyboard()` が立てる `_userLeft` は一度立つと下りない掛け金に
  ///   なっていた。 下ろす道は 2 つあったが、 どちらも死んでいた:
  ///     ・隠し入力欄の `onTapOutside` は**焦点がある間しか登録されない**
  ///       ので、 手放した後は押されても届かない。
  ///     ・`TerminalView.onTapUp` は xterm 4.0.0 側の配線違いで呼ばれない。
  ///   そこで build の一番外側に `Listener` を敷いて、 焦点に関係なく
  ///   「この端末が押された」 を拾う (下の build を参照)。
  void _returnToTerminal() {
    _userLeft = false;
    _grabInput();
  }

  /// 画面側から「また打てるようにして」 と頼む口 (窓を動かし終わった時など)。
  void returnKeyboard() => _returnToTerminal();

  @override
  void initState() {
    super.initState();
    live.add(this);
    _s.addListener(_onChanged);
    _inputCtrl.addListener(_onInputChanged);
    _scroll.addListener(_onScroll);
    _grabFocusSoon();
    // ★ 焦点が何かの拍子に他所へ移ると、 そこから先ずっと打てなくなる。
    //   下の欄を書いている時以外は、 打ち込み口に焦点を戻し続ける。
    //   ただし**利用者が自分で外へ出た時は戻さない** (上の経緯)。
    _focusWatch = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted || !_s.running) return;
      if (_userLeft) return;
      if (_queueFocus.hasFocus) return;
      if (_inputFocus.hasPrimaryFocus) return;
      // 他所の入力欄 (要素の名前など) が使われている間も横取りしない。
      // ★ ここで掛け金 (_userLeft) は掛けない。 掛けると、 その欄が
      //   閉じた後も見回りが止まったままになり、 二度と打てなくなる
      //   (= ユーザー報告: 他の要素を編集すると入れられなくなる)。
      //   次の見回りで判断し直せばよい。
      if (_otherEditorHasFocus()) return;
      _inputFocus.requestFocus();
    });
  }

  /// この端末の外にある入力欄が、 いま打ち込みを受けているか。
  bool _otherEditorHasFocus() {
    final p = FocusManager.instance.primaryFocus;
    if (p == null) return false;
    if (p == _inputFocus || p == _queueFocus || p == _termFocus) return false;
    final ctx = p.context;
    // ★ 既に消えた欄は「他所が使っている」 ではない。 FocusNode は外れた後も
    //   context を持ち続けるので、 これを見ないと閉じた欄に居座られたまま
    //   になり、 端末が二度と焦点を取れなくなる (= ユーザー報告)。
    if (ctx == null || !ctx.mounted) return false;
    // この端末の中の欄なら横取りではない。
    if (ctx.findAncestorStateOfType<AgentTerminalState>() == this) {
      return false;
    }
    // 文字を打てる所が持っているかどうかだけ見る (ボタン等は無視)。
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  Timer? _focusWatch;

  @override
  void didUpdateWidget(covariant AgentTerminal old) {
    super.didUpdateWidget(old);
    if (!identical(old.session, widget.session)) {
      old.session.removeListener(_onChanged);
      widget.session.addListener(_onChanged);
      _grabFocusSoon();
    }
  }

  @override
  void dispose() {
    live.remove(this);
    // ★ ここで止めない (= ユーザー要望: 欄を閉じても裏で動き続ける)。
    _s.removeListener(_onChanged);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _pendingTimer?.cancel();
    _focusWatch?.cancel();
    _inputCtrl.removeListener(_onInputChanged);
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _queueCtrl.dispose();
    _queueFocus.dispose();
    _termController.dispose();
    _termFocus.dispose();
    super.dispose();
  }

  bool _focusTried = false;

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    _syncCursorSoon();
    if (!_focusTried && _s.running) {
      _focusTried = true;
      _grabFocusSoon();
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final bottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 4;
    if (bottom != _atBottom) setState(() => _atBottom = bottom);
  }

  /// 打てる状態にする。
  void _grabInput() {
    if (!mounted) return;
    if (_queueFocus.hasFocus) return;
    // 呼ばれるのは「利用者がこの端末で何かした」 時だけなので、
    // 掛け金はここで必ず下ろす。
    _userLeft = false;
    if (!_inputFocus.hasFocus) {
      _inputFocus.requestFocus();
      // ★ 同じセッションを 2 つの画面が抱えている時は、 いま押された方に
      //   譲る (立ち上がった時ではなく、 実際に焦点を取った時に行う。
      //   作った時にやると、 裏の窓が手前の端末を黙らせてしまう)。
      for (final t in live.toList()) {
        if (!identical(t, this) && identical(t._s, _s)) t.releaseKeyboard();
      }
    }
  }

  /// 組み上がってから打てるようにする (1 回だと空振りする事がある)。
  void _grabFocusSoon() {
    for (final ms in const [0, 120, 400, 900]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (!mounted || !_s.running) return;
        // 利用者が既に他所を触っている時は横取りしない (= 上の経緯)。
        if (_userLeft || _otherEditorHasFocus()) return;
        _grabInput();
        _syncCursorPos();
      });
    }
  }

  // ── 打ち込み口の場所 (カーソルの所へ重ねる) ──────────────────────────
  //
  //   ★ ここが肝心 (= ユーザー報告: 日本語が打てない)。 変換中の文字は
  //     この入力欄に出るので、 画面の隅に置くと「打ったのに何も出ない」
  //     ように見える。 OS が出す変換候補の窓も、 この欄の場所に付く。
  //     端末のカーソルに重ねておけば、 本物の端末と同じ見え方になる。

  void _syncCursorSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCursorPos());
  }

  DateTime _lastCursorSync = DateTime.fromMillisecondsSinceEpoch(0);

  void _syncCursorPos() {
    if (!mounted) return;
    // ★ 変換中は**絶対に動かさない**。 入力欄が動くと、 OS へ知らせる
    //   位置が毎回変わり、 変換が途中で流れることがある。
    if (_composing.isNotEmpty) return;
    // 出力のたびに動かすと落ち着かないので、 間を空ける。
    final now = DateTime.now();
    if (now.difference(_lastCursorSync).inMilliseconds < 300) return;
    final st = _viewKey.currentState;
    final box = _stackKey.currentContext?.findRenderObject();
    if (st == null || box is! RenderBox || !box.hasSize) return;
    try {
      final p = box.globalToLocal(st.globalCursorRect.topLeft);
      if (_cursorPos == null || (p - _cursorPos!).distance > 1.0) {
        _lastCursorSync = now;
        setState(() => _cursorPos = p);
      }
    } catch (_) {
      // まだ組み上がっていない時は何もしない。
    }
  }

  // ── 打ち込み ────────────────────────────────────────────────────────────

  /// 入力欄が動いた時。 変換が終わった分だけ端末へ流す。
  void _onInputChanged() {
    if (_flushing || !mounted) return;
    // 受け口から何か届いた = 生きている。 控えていた打鍵は捨てる
    // (こちらからも送ると二重になる)。
    if (_textPathAlive != true) _textPathAlive = true;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingKeys.clear();
    final v = _inputCtrl.value;
    final comp = v.composing.isValid && !v.composing.isCollapsed
        ? v.composing.textInside(v.text)
        : '';
    if (comp != _composing) {
      setState(() => _composing = comp);
      if (comp.isNotEmpty) _syncCursorPos();
    }
    // ★ 打つそばから CLI の入力欄へ流す (= ユーザー要望: 確定を待たずに
    //   直接打ち込めるように)。 前に送った分との差だけを直す。
    final target = v.text;
    // ★ 「前に送った分」 と「今の中身」 の**違う所だけ**を直す
    //   (= ユーザー報告: 書いた文字が二重に入る)。
    //   以前は「全部消して全部送り直す」 うえに、 確定のたびに欄を空へ戻して
    //   `_liveSent` も空にしていた。 OS から同じ中身がもう一度届くと
    //   (日本語の確定では実際に届く)、 消す分が 0 のまま丸ごともう一度
    //   送られて、 CLI の行に同じ文字が 2 回並んでいた。
    //   頭からの共通部分を数えて、 余った分を消し、 足りない分だけ足す。
    //   同じ中身が二度届いても、 共通部分が全部なので何も送らない。
    if (target != _liveSent) {
      final a = _liveSent.runes.toList();
      final b = target.runes.toList();
      var common = 0;
      while (common < a.length && common < b.length && a[common] == b[common]) {
        common++;
      }
      if (a.length > common) _s.sendRaw('\x7f' * (a.length - common));
      if (b.length > common) {
        _s.sendRaw(String.fromCharCodes(b.sublist(common)));
      }
      _liveSent = target;
      _stickToBottom();
    }
    // ★ 確定しても欄は空にしない。 空にすると `_liveSent` が嘘になり、
    //   次に届いた分を消せずに二重になる。 欄の文字は透明なので見えないし、
    //   CLI が自分の行を消す時 (Enter / ^C / ^U など) に
    //   `_resetMirror()` でこちらも合わせる。
  }

  /// CLI が自分の入力行を消した時に、 こちらの控えも合わせる。
  void _resetMirror() {
    _flushing = true;
    // TextEditingValue.empty はカーソルの位置が -1 (= カーソル無し) なので
    // 使わない。 clear() は 0 に置く。
    _inputCtrl.clear();
    _flushing = false;
    _liveSent = '';
    if (_composing.isNotEmpty && mounted) setState(() => _composing = '');
  }

  /// 押されたキーを端末へ。
  ///
  /// 戻り値が handled の物は、 アプリの他の仕掛けにも OS にも渡らない。
  /// 変換中の打鍵はここへ来ない (OS が IME へ回すため) ので、 日本語は
  /// 入力欄側 (_onInputChanged) が受け取る。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_s.running) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // 変換中は一切手を出さない。
    if (_composing.isNotEmpty) return KeyEventResult.ignored;
    final hk = HardwareKeyboard.instance;
    final ctrl = hk.isControlPressed;
    final alt = hk.isAltPressed;
    final shift = hk.isShiftPressed;
    final meta = hk.isMetaPressed;
    final key = event.logicalKey;
    // 自分で打ったなら、 ボタンで開いた画面はもう当てにしない。
    _openPanelCmd = null;

    // ── 写す / 貼る ──
    if (ctrl && shift && key == LogicalKeyboardKey.keyC) {
      _copySelection();
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyV) {
      unawaited(_pasteClipboard());
      return KeyEventResult.handled;
    }
    if (ctrl &&
        key == LogicalKeyboardKey.keyC &&
        _termController.selection != null) {
      // 選んでいる時の Ctrl+C は「写す」 (選んでいなければ中断の ^C)。
      _copySelection();
      _termController.clearSelection();
      return KeyEventResult.handled;
    }

    // ── 画面の巻き上げ (Shift+PageUp / PageDown) ──
    if (shift && key == LogicalKeyboardKey.pageUp) {
      _scrollByPage(-1);
      return KeyEventResult.handled;
    }
    if (shift && key == LogicalKeyboardKey.pageDown) {
      _scrollByPage(1);
      return KeyEventResult.handled;
    }

    // ── Ctrl + 英字 → 制御文字 (^C ^D ^U など) ──
    if (ctrl && !alt) {
      final label = key.keyLabel;
      if (label.length == 1) {
        final c = label.toUpperCase().codeUnitAt(0);
        if (c >= 0x41 && c <= 0x5F) {
          _s.sendRaw(String.fromCharCode(c - 0x40));
          // ^C / ^U / ^W / ^D は CLI 側の行が消えるので、 控えも合わせる。
          if (c == 0x43 || c == 0x44 || c == 0x55 || c == 0x57) {
            _resetMirror();
          }
          _stickToBottom();
          return KeyEventResult.handled;
        }
      }
    }

    // ── ただの文字 ──
    //
    //   ★ ここでは **絶対に handled を返さない**。 返すと Windows は
    //     その打鍵を OS へ投げ返さず、 IME が変換を始められない
    //     (= ユーザー報告: 半角英数しか打てない)。
    //     受け口 (入力欄) に任せ、 それが死んでいた時だけ自前で送る。
    if (!ctrl && !alt && !meta) {
      final ch = event.character;
      if (ch != null && ch.isNotEmpty) {
        final code = ch.codeUnitAt(0);
        if (code >= 0x20 && code != 0x7f) {
          if (_textPathAlive == true) return KeyEventResult.ignored;
          _pendingKeys.write(ch);
          _pendingTimer?.cancel();
          // 判るまでは長めに、 死んでいると判った後は取りこぼさない程度に。
          // 遅れて送っても二重にならなくなったので、 待ちは長めでよい
          //   (= 画面の書き換えで詰まっている時に、 受け口より先に
          //    こちらが送ってしまうのを防ぐ)。
          _pendingTimer = Timer(
              Duration(milliseconds: _textPathAlive == null ? 400 : 120),
              _flushPendingKeys);
          return KeyEventResult.ignored;
        }
      }
    }

    // ── Alt + 英字 → ESC + 文字 ──
    if (alt && !ctrl) {
      final label = key.keyLabel;
      if (label.length == 1) {
        _s.sendRaw('\x1b${label.toLowerCase()}');
        _stickToBottom();
        return KeyEventResult.handled;
      }
    }

    // ── 矢印 / Enter / Tab などの決まった打鍵 ──
    final tk = _kTermKeys[key];
    if (tk != null) {
      if (_s.terminal.keyInput(tk, ctrl: ctrl, alt: alt, shift: shift)) {
        _stickToBottom();
      }
      // ★ Enter / Esc で CLI は自分の入力行を片付けるので、 こちらの控えも
      //   空に戻す (= 残しておくと、 次に打った時に消す分がずれて
      //   さっきの行がもう一度出る)。
      if (tk == TerminalKey.enter || tk == TerminalKey.escape) {
        _resetMirror();
      }
      // 端末が要らないと言った物も、 アプリ側に横取りさせない。
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 受け口から返事が来なかった打鍵を、 自前で端末へ送る。
  void _flushPendingKeys() {
    _pendingTimer = null;
    final text = _pendingKeys.toString();
    _pendingKeys.clear();
    if (text.isEmpty || !mounted) return;
    // 待っても届かなかった = 受け口は使えない。 以後は自前で送る。
    _textPathAlive = false;
    _s.sendRaw(text);
    // ★ 送った分は控えにも足す (= 足さないと、 後から受け口が動いた時に
    //   同じ文字をもう一度送ってしまう)。
    _liveSent = '$_liveSent$text';
    _stickToBottom();
  }

  void _copySelection() {
    final sel = _termController.selection;
    if (sel == null) return;
    final text = _s.terminal.buffer.getText(sel);
    unawaited(Clipboard.setData(ClipboardData(text: text)));
  }

  Future<void> _pasteClipboard() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text ?? '';
    if (t.isEmpty) return;
    _s.terminal.paste(t);
    _stickToBottom();
  }

  // ── 画面の巻き上げ ──────────────────────────────────────────────────────

  void _scrollByPage(int dir) {
    if (!_scroll.hasClients) return;
    final page = _scroll.position.viewportDimension * 0.9;
    final to = (_scroll.position.pixels + page * dir)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(to);
  }

  void _stickToBottom() {
    if (!_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// 外から指示を流し込む (チャット欄から渡す用)。
  void sendLine(String text) => _s.send(text);

  // ── 下の帯のボタン ──────────────────────────────────────────────────────

  /// CLI のコマンドを 1 つ送る。
  ///
  /// ★ 同じボタンをもう一度押したら Esc を送って閉じる (= ユーザー要望:
  ///   使用量を再度押しても閉まらない)。 CLI 側の画面はどれも Esc で閉じる。
  void _sendPanelCommand(String command) {
    if (_openPanelCmd == command) {
      _s.sendRaw('\x1b');
      setState(() => _openPanelCmd = null);
    } else {
      _s.sendCommand(command);
      setState(() => _openPanelCmd = command);
    }
    _grabInput();
  }

  Widget _cmdButton({
    required String label,
    required IconData icon,
    required String tip,
    required String command,
    required bool enabled,
  }) {
    final open = _openPanelCmd == command;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: open ? '$tip / もう一度押すと閉じます' : tip,
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: open ? const Color(0xFF4FC3F7) : Colors.white70,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: Icon(open ? Icons.close_rounded : icon, size: 14),
          label: Text(label, style: const TextStyle(fontSize: 11)),
          onPressed: enabled ? () => _sendPanelCommand(command) : null,
        ),
      ),
    );
  }

  /// 順番待ちに 1 件足す。
  void _addQueued() {
    final t = _queueCtrl.text.trim();
    if (t.isEmpty) return;
    _s.enqueue(t);
    _queueCtrl.clear();
    setState(() {});
  }

  /// 入力欄 (日本語も必ず打てる) と、 送った指示の一覧。
  Widget _buildBar({
    required IconData icon,
    required Color color,
    required String note,
    required TextEditingController ctrl,
    required FocusNode focus,
    required String hint,
    required String buttonLabel,
    required VoidCallback onSubmit,
    required VoidCallback onClose,
    List<Widget> extra = const [],
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: const BoxDecoration(
        color: Color(0xFF141426),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(note,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 10.5)),
          ),
          IconButton(
            tooltip: '閉じる',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            icon:
                const Icon(Icons.close_rounded, size: 15, color: Colors.white38),
            onPressed: onClose,
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            // ★ Enter は改行、 Ctrl+Enter で確定 (= ユーザー要望)。
            //   TextField の Enter を横取りするには Focus(onKeyEvent) で
            //   handled を返すしかない。 かな漢字変換の最中は渡す。
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                final k = event.logicalKey;
                if (k != LogicalKeyboardKey.enter &&
                    k != LogicalKeyboardKey.numpadEnter) {
                  return KeyEventResult.ignored;
                }
                if (!HardwareKeyboard.instance.isControlPressed) {
                  return KeyEventResult.ignored;
                }
                final c = ctrl.value.composing;
                if (c.isValid && !c.isCollapsed) return KeyEventResult.ignored;
                onSubmit();
                return KeyEventResult.handled;
              },
              child: TextField(
                controller: ctrl,
                focusNode: focus,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle:
                      const TextStyle(color: Colors.white24, fontSize: 11.5),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.06),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF37474F),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: onSubmit,
            child: Text(buttonLabel,
                style: const TextStyle(fontSize: 11, color: Colors.white)),
          ),
        ]),
        ...extra,
      ]),
    );
  }

  /// いまの会話で投げた指示の一覧 (= ユーザー要望: 現在の会話履歴)。
  Widget _buildHistoryPanel() {
    final lines = _s.sentLines.reversed.toList();
    return Container(
      constraints: const BoxConstraints(maxHeight: 170),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: const BoxDecoration(
        color: Color(0xFF141426),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              const Icon(Icons.history_rounded,
                  size: 14, color: Color(0xFF80CBC4)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    lines.isEmpty
                        ? 'この会話でまだ何も投げていません'
                        : 'この会話で投げた指示 (押すと入力欄に入ります)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 10.5)),
              ),
              IconButton(
                tooltip: '閉じる',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                icon: const Icon(Icons.close_rounded,
                    size: 15, color: Colors.white38),
                onPressed: () => setState(() => _histOpen = false),
              ),
            ]),
            if (lines.isNotEmpty)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(top: 4),
                  itemCount: lines.length,
                  itemBuilder: (_, i) => InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      // ★ CLI の入力欄へそのまま打ち込む (Enter は押さない
                      //   ので、 直してから送れる)。
                      _s.sendRaw(lines[i]);
                      setState(() => _histOpen = false);
                      _stickToBottom();
                      _grabInput();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 4),
                      child: Text(lines[i],
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              height: 1.4)),
                    ),
                  ),
                ),
              ),
          ]),
    );
  }

  Widget _buildQueueBar() {
    final q = _s.queued;
    return _buildBar(
      icon: Icons.playlist_add_rounded,
      color: const Color(0xFFFFB347),
      note: '処理が終わって落ち着いたら、 ここに入れた指示を順番に渡します',
      ctrl: _queueCtrl,
      focus: _queueFocus,
      hint: '次に渡す指示 (Ctrl+Enter で確定 / Enter は改行)',
      buttonLabel: '追加',
      onSubmit: _addQueued,
      onClose: () {
        setState(() => _queueOpen = false);
        _grabInput();
      },
      extra: [
        if (q.isNotEmpty) ...[
          const SizedBox(height: 5),
          for (var i = 0; i < q.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(children: [
                Text('${i + 1}.',
                    style: const TextStyle(
                        color: Color(0xFFFFB347), fontSize: 10.5)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(q[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 10.5)),
                ),
                InkWell(
                  onTap: () => setState(() => _s.cancelQueued(i)),
                  child: const Padding(
                    padding: EdgeInsets.all(3),
                    child: Icon(Icons.close_rounded,
                        size: 12, color: Colors.white38),
                  ),
                ),
              ]),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = _s.running;
    final slash = _s.supportsSlashCommands;
    // ★ 順番待ちは Claude Code にだけ出す。
    //   Codex は Tab、 Gemini CLI は Enter / Tab で自前の順番待ちを持って
    //   いる (調べた結果)。 Claude Code も溜めてはくれるが、 溜めた物を
    //   **道具の切れ目で今の返事に割り込ませる**ので、 「処理が終わった後に
    //   渡す」 にはならない (= ユーザー要望はこちら)。
    final wantQueue = slash && _s.cliKey == 'claude';
    // ★ この端末のどこかが押されたら、 また打てるように戻す
    //   (= ユーザー報告: 画面を動かしたり他の要素を編集すると
    //   プロンプト欄に入れられなくなる)。
    //   隠し入力欄の onTapOutside は「焦点がある間」しか登録されず、
    //   xterm の onTapUp は向こう側の配線違いで呼ばれないので、
    //   「戻ってきた」 を拾える口がどこにも無かった。
    //   Listener は押下の取り合いに参加しないので、 ボタンや
    //   帯を掴む操作を邪魔しない。
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _returnToTerminal(),
      child: Column(children: [
      // ── 見出し (外側が出している時は出さない) ──
      if (widget.showHeader)
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.white12)),
          ),
          child: Row(children: [
            Icon(Icons.terminal_rounded,
                size: 16,
                color: running ? const Color(0xFF9CCC65) : Colors.white38),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700)),
            ),
            if (!running && widget.onRunAgain != null)
              IconButton(
                tooltip: 'もう一度',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: const Icon(Icons.refresh_rounded,
                    size: 17, color: Colors.white54),
                onPressed: widget.onRunAgain,
              ),
            IconButton(
              tooltip: 'コピー (選んだ所)',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              icon: const Icon(Icons.copy_rounded,
                  size: 16, color: Colors.white54),
              onPressed: _copySelection,
            ),
          ]),
        ),
      // ── 上の一言 (動いている間 / 終わった後で出し分ける) ──
      if (running && (_s.hint ?? '').isNotEmpty)
        Container(
          width: double.infinity,
          color: const Color(0xFF1B3A4B),
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          child: Text(
              '${_s.hint!}\nこの欄を閉じても裏で動き続けます。 閉じる時は右下の「終了」 を押してください。',
              style: const TextStyle(
                  color: Color(0xFF9BD7F0), fontSize: 11, height: 1.5)),
        ),
      if (!running)
        Container(
          width: double.infinity,
          color: _s.exitCode == 0
              ? const Color(0xFF1E3B2A)
              : const Color(0xFF3B2A2A),
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          child: Row(children: [
            Icon(
                _s.exitCode == 0
                    ? Icons.check_circle_rounded
                    : Icons.error_outline_rounded,
                size: 15,
                color: _s.exitCode == 0
                    ? const Color(0xFF8BD9A8)
                    : const Color(0xFFFF8A80)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _s.stoppedByUser
                    ? '終了しました。'
                    : (_s.exitCode == 0
                        ? (_s.isInstall
                            ? '入れ終わりました。 一覧に戻ると、 そのまま使えます。'
                            : '終わりました。')
                        : '終わりませんでした (コード ${_s.exitCode})。 上の記録を見て、 もう一度お試しください。'),
                style: TextStyle(
                    color: _s.exitCode == 0
                        ? const Color(0xFFBFE9CE)
                        : const Color(0xFFFFC1BC),
                    fontSize: 11,
                    height: 1.5),
              ),
            ),
          ]),
        ),
      // ── 画面 (本物の端末表示) ──
      Expanded(
        child: Focus(
          // ★ 打鍵はまずここで受ける。 焦点は中の入力欄が持っているので、
          //   この Focus はその親として全ての打鍵を先に見られる。
          // ★ **この Focus 自身は焦点を取らない**。 取れてしまうと、 入力欄が
          //   焦点を失った時に焦点がここへ落ち着いてしまい、 打鍵は届くのに
          //   文字の受け口だけ閉じた状態 (= 半角は打てるが日本語が打てない)
          //   になる。
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: Container(
            width: double.infinity,
            color: const Color(0xFF0D0D14),
            child: LayoutBuilder(builder: (ctx, cons) {
              const inputW = 260.0;
              final cx = ((_cursorPos?.dx ?? 10.0))
                  .clamp(0.0, (cons.maxWidth - inputW).clamp(0.0, 4000.0));
              final cy = ((_cursorPos?.dy ?? (cons.maxHeight - 24)))
                  .clamp(0.0, (cons.maxHeight - 18).clamp(0.0, 4000.0));
              return Stack(key: _stackKey, children: [
                Positioned.fill(
                  // ★ 掴んで動かせる棒を出す (= ユーザー要望: 画面の外へ
                  //   流れた会話を遡りたい)。 ホイールでも遡れる。
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    interactive: true,
                    // ★ 棒が 2 本出ていたのを 1 本に (= ユーザー報告)。
                    //   端末の中身は素の `Scrollable` で、 パソコン版の
                    //   既定の作法 (MaterialScrollBehavior) が**そこにも
                    //   勝手に棒を付ける**。 上の掴める棒と二重になるので、
                    //   中の自動の棒だけ止める。
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context)
                          .copyWith(scrollbars: false),
                      child: TerminalView(
                      _s.terminal,
                      key: _viewKey,
                      controller: _termController,
                      focusNode: _termFocus,
                      scrollController: _scroll,
                      autofocus: false,
                      onTapUp: (_, __) => _returnToTerminal(),
                      padding: const EdgeInsets.fromLTRB(10, 8, 16, 8),
                      textStyle: const TerminalStyle(
                        fontSize: 12,
                        fontFamily: 'Consolas',
                      ),
                      theme: TerminalThemes.defaultTheme,
                      backgroundOpacity: 0,
                    ),
                    ),
                  ),
                ),
                // ── 打ち込み口 (カーソルに重ねる。 空の間は見えない) ──
                Positioned(
                  left: cx,
                  top: cy,
                  child: IgnorePointer(
                    child: Container(
                      // ★★ ここが日本語が打てなかった正体 (実機で特定)。
                      //   枠 (Border) は箱の**寸法そのもの**を変えるので、
                      //   変換が始まった瞬間に入力欄が 1.5px ずれて組み直され、
                      //   Windows はそこで変換を打ち切っていた。 実測では
                      //   「ｎ」 まで出て、 その先が一切来なくなる。
                      //   太さは常に同じにして、 色だけ変える。
                      decoration: BoxDecoration(
                        // ★ 文字は CLI の入力欄に直接出るので、 ここには
                        //   出さない (二重に見えてしまうため)。
                        color: Colors.transparent,
                        border: Border(
                          bottom: BorderSide(
                              color: Colors.transparent, width: 1.5),
                        ),
                      ),
                      child: SizedBox(
                        width: inputW,
                        // ★ 下の「日本語」 の欄と**まったく同じ作り**にする
                        //   (= そちらは変換が確実に効いているため)。 違いを
                        //   残さないよう、 生の EditableText ではなく
                        //   TextField を、 同じ種類・同じ確定動作で置く。
                        child: TextField(
                          controller: _inputCtrl,
                          focusNode: _inputFocus,
                          autofocus: true,
                          // ★ ここが日本語が打てなかった正体。 Windows では
                          //   入力欄の**外**を押すと焦点が外れる決まりに
                          //   なっていて、 端末を押すたびにこの欄が焦点を
                          //   失っていた。 焦点が無ければ文字の受け口も閉じ、
                          //   かな漢字変換は始まりようがない。 半角だけ打てて
                          //   いたのは、 押鍵から直に送る保険が働いていたため。
                          // ★ とはいえ「何があっても離さない」 は行き過ぎで、
                          //   ページの要素を書き換えようとしても打った字が
                          //   CLI へ吸われてしまっていた (= ユーザー報告)。
                          //   押された所がこの端末の中かどうかで分ける。
                          //   中なら抱えたまま (変換を切らさない)、 外なら返す。
                          onTapOutside: (e) {
                            final box =
                                context.findRenderObject() as RenderBox?;
                            if (box != null && box.hasSize) {
                              final p = box.globalToLocal(e.position);
                              if (p.dx >= 0 &&
                                  p.dy >= 0 &&
                                  p.dx <= box.size.width &&
                                  p.dy <= box.size.height) {
                                _returnToTerminal();
                                return;
                              }
                            }
                            releaseKeyboard();
                          },
                          enableInteractiveSelection: false,
                          minLines: 1,
                          maxLines: 4,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                          cursorColor: Colors.transparent,
                          style: const TextStyle(
                            color: Colors.transparent,
                            fontSize: 12,
                            fontFamily: 'Consolas',
                          ),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // ── 最新へ戻る (遡っている間だけ出す) ──
                if (!_atBottom)
                  Positioned(
                    right: 18,
                    bottom: 8,
                    child: Material(
                      color: const Color(0xEE23233C),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          if (!_scroll.hasClients) return;
                          _scroll.jumpTo(_scroll.position.maxScrollExtent);
                        },
                        child: const Padding(
                          padding: EdgeInsets.fromLTRB(9, 4, 9, 4),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.arrow_downward_rounded,
                                size: 13, color: Color(0xFF9CCC65)),
                            SizedBox(width: 4),
                            Text('最新へ',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 10.5)),
                          ]),
                        ),
                      ),
                    ),
                  ),
              ]);
            }),
          ),
        ),
      ),
      // ── いまの会話で投げた指示 (= ユーザー要望: 現在の会話履歴) ──
      if (_histOpen && running) _buildHistoryPanel(),
      // ── 順番待ちの欄 (= ユーザー要望: キュー) ──
      if (_queueOpen && running) _buildQueueBar(),
      // ── 下の帯 ──
      Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 6),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Colors.white12)),
        ),
        child: Row(children: [
          // ★ 幅が足りない時は横に流す (ボタンが増えてもはみ出さない)。
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                if (slash) ...[
                  _cmdButton(
                      label: 'モデル',
                      icon: Icons.memory_rounded,
                      tip: 'モデルを選び直す (/model)',
                      command: '/model',
                      enabled: running),
                  _cmdButton(
                      label: '推論',
                      icon: Icons.psychology_alt_rounded,
                      tip: '考える深さを変える (/effort)。 走っている最中でも'
                          ' すぐ受け付けて、 次のひと押しから効きます',
                      command: '/effort',
                      enabled: running),
                  // ★ 並びは 左から モデル → 推論 → 履歴 → 使用量
                  //   (= ユーザー要望)。 よく使う物を左に寄せる。
                  //   いまの会話で投げた指示の一覧 (別のセッションではなく、
                  //   いまの会話履歴)。
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Tooltip(
                      message: 'この会話で投げた指示を並べる',
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: _histOpen
                              ? const Color(0xFF80CBC4)
                              : Colors.white70,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.history_rounded, size: 14),
                        label:
                            const Text('履歴', style: TextStyle(fontSize: 11)),
                        onPressed: running
                            ? () {
                                setState(() => _histOpen = !_histOpen);
                                if (!_histOpen) _grabInput();
                              }
                            : null,
                      ),
                    ),
                  ),
                  _cmdButton(
                      label: '使用量',
                      icon: Icons.donut_small_rounded,
                      tip: 'プランの使用量と残りを出す (/usage)',
                      command: '/usage',
                      enabled: running),
                ],
              ]),
            ),
          ),
          // ── 処理を止める (= ユーザー要望: 処理が始まったら出す) ──
          //    CLI そのものは閉じない。 どの CLI も走っている処理を
          //    打ち切るのは Esc なので、 それを送るだけ。
          //    「終了」 (右) は CLI ごと閉じるボタンで、 別物。
          if (running && _s.busy)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tooltip(
                message: 'いま走っている処理を止める (Esc)',
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFE57373),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.stop_circle_outlined, size: 14),
                  label: const Text('停止', style: TextStyle(fontSize: 11)),
                  onPressed: () {
                    _s.sendRaw('\x1b');
                    _returnToTerminal();
                  },
                ),
              ),
            ),
          // ★ 言語はあまり使わないので終了の左へ (= ユーザー要望)。
          if (slash && widget.onPickLanguage != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tooltip(
                message: 'CLI が返事をする言語を選ぶ',
                child: IconButton(
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  icon: const Icon(Icons.translate_rounded,
                      size: 16, color: Colors.white54),
                  onPressed: running ? widget.onPickLanguage : null,
                ),
              ),
            ),
          // ★ 動いている間は「終了」、 終わったら「もう一度」 に変わる。
          //   これは走っている処理を打ち切るボタンではなく、 CLI そのものを
          //   閉じるボタン。 処理を止めたい時は左に出る「停止」。
          if (running)
            Tooltip(
              message: 'CLI を閉じて一覧へ戻る (処理だけ止めるなら「停止」)',
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFFF8A80),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.power_settings_new_rounded, size: 14),
                label: const Text('終了', style: TextStyle(fontSize: 11)),
                onPressed: _s.kill,
              ),
            )
          else
            IconButton(
              tooltip: 'もう一度',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              icon: Icon(Icons.refresh_rounded,
                  size: 19,
                  color: widget.onRunAgain == null
                      ? Colors.white24
                      : const Color(0xFF9CCC65)),
              onPressed: widget.onRunAgain,
            ),
        ]),
      ),
    ]),
    );
  }
}
