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

  /// いま変換中の文字 (カーソルの所に出す)。
  String _composing = '';

  /// 送り出しの最中か (入力欄を空に戻す時の呼び戻しを止める)。
  bool _flushing = false;

  /// 一番下に貼り付いているか (= false の間は「最新へ」 を出す)。
  bool _atBottom = true;

  /// 端末のカーソルの位置 (この widget の中での座標)。
  Offset? _cursorPos;

  /// いま開いていると思われる CLI の画面 (/usage など)。
  /// 同じボタンをもう一度押したら Esc を送って閉じる (= ユーザー要望)。
  String? _openPanelCmd;

  AgentCliSession get _s => widget.session;

  @override
  void initState() {
    super.initState();
    _s.addListener(_onChanged);
    _inputCtrl.addListener(_onInputChanged);
    _scroll.addListener(_onScroll);
    _grabFocusSoon();
  }

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
    // ★ ここで止めない (= ユーザー要望: 欄を閉じても裏で動き続ける)。
    _s.removeListener(_onChanged);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
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
    if (_queueFocus.hasFocus) return; // 順番待ちを書いている最中は邪魔しない
    if (!_inputFocus.hasFocus) _inputFocus.requestFocus();
  }

  /// 組み上がってから打てるようにする (1 回だと空振りする事がある)。
  void _grabFocusSoon() {
    for (final ms in const [0, 120, 400, 900]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (!mounted || !_s.running) return;
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

  void _syncCursorPos() {
    if (!mounted) return;
    final st = _viewKey.currentState;
    final box = _stackKey.currentContext?.findRenderObject();
    if (st == null || box is! RenderBox || !box.hasSize) return;
    try {
      final p = box.globalToLocal(st.globalCursorRect.topLeft);
      if (_cursorPos == null || (p - _cursorPos!).distance > 0.5) {
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
    final v = _inputCtrl.value;
    final comp = v.composing.isValid && !v.composing.isCollapsed
        ? v.composing.textInside(v.text)
        : '';
    if (comp != _composing) {
      setState(() => _composing = comp);
      if (comp.isNotEmpty) _syncCursorPos();
    }
    // 変換中は確定を待つ。
    if (comp.isNotEmpty) return;
    final text = v.text;
    if (text.isEmpty) return;
    _flushing = true;
    _inputCtrl.value = TextEditingValue.empty;
    _flushing = false;
    _s.sendRaw(text);
    _stickToBottom();
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
          _stickToBottom();
          return KeyEventResult.handled;
        }
      }
    }

    // ── ただの文字 (受け口の状態に関係なく必ず打てる) ──
    if (!ctrl && !alt && !meta) {
      final ch = event.character;
      if (ch != null && ch.isNotEmpty) {
        final code = ch.codeUnitAt(0);
        if (code >= 0x20 && code != 0x7f) {
          _s.sendRaw(ch);
          _stickToBottom();
          return KeyEventResult.handled;
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
      // 端末が要らないと言った物も、 アプリ側に横取りさせない。
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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

  Widget _buildQueueBar() {
    final q = _s.queued;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: const BoxDecoration(
        color: Color(0xFF141426),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.playlist_add_rounded,
              size: 14, color: Color(0xFFFFB347)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                '処理が終わって落ち着いたら、 ここに入れた指示を順番に渡します',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 10.5)),
          ),
          IconButton(
            tooltip: '閉じる',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            icon: const Icon(Icons.close_rounded,
                size: 15, color: Colors.white38),
            onPressed: () {
              setState(() => _queueOpen = false);
              _grabInput();
            },
          ),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _queueCtrl,
              focusNode: _queueFocus,
              autofocus: true,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: InputDecoration(
                hintText: '次に渡す指示 (日本語もそのまま打てます)',
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
              onSubmitted: (_) => _addQueued(),
            ),
          ),
          const SizedBox(width: 6),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF37474F),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: _addQueued,
            child: const Text('追加',
                style: TextStyle(fontSize: 11, color: Colors.white)),
          ),
        ]),
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
      ]),
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
    return Column(children: [
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
                    child: TerminalView(
                      _s.terminal,
                      key: _viewKey,
                      controller: _termController,
                      focusNode: _termFocus,
                      scrollController: _scroll,
                      autofocus: false,
                      onTapUp: (_, __) => _grabInput(),
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
                // ── 打ち込み口 (カーソルに重ねる。 空の間は見えない) ──
                Positioned(
                  left: cx,
                  top: cy,
                  child: IgnorePointer(
                    child: Container(
                      decoration: _composing.isEmpty
                          ? null
                          : BoxDecoration(
                              color: const Color(0xEE10202C),
                              border: const Border(
                                  bottom: BorderSide(
                                      color: Color(0xFF4FC3F7), width: 1.5)),
                            ),
                      child: SizedBox(
                        width: inputW,
                        child: EditableText(
                          controller: _inputCtrl,
                          focusNode: _inputFocus,
                          maxLines: 1,
                          autofocus: true,
                          style: TextStyle(
                            color: _composing.isEmpty
                                ? Colors.transparent
                                : const Color(0xFFB3E5FC),
                            fontSize: 12,
                            fontFamily: 'Consolas',
                          ),
                          cursorColor: Colors.transparent,
                          backgroundCursorColor: Colors.transparent,
                          selectionColor: const Color(0x554FC3F7),
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                          keyboardType: TextInputType.text,
                          textInputAction: TextInputAction.none,
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
                  _cmdButton(
                      label: '使用量',
                      icon: Icons.donut_small_rounded,
                      tip: 'プランの使用量と残りを出す (/usage)',
                      command: '/usage',
                      enabled: running),
                  // ★ セッションの切り替え (= ユーザー要望)。
                  _cmdButton(
                      label: 'セッション',
                      icon: Icons.history_rounded,
                      tip: '前の会話に切り替える (/resume)',
                      command: '/resume',
                      enabled: running),
                ],
                // ★ 順番待ち (= ユーザー要望)。
                if (wantQueue)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Tooltip(
                      message: '処理が終わった後に渡す指示を用意しておく',
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: _s.queued.isEmpty
                              ? Colors.white70
                              : const Color(0xFFFFB347),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.playlist_add_rounded, size: 14),
                        label: Text(
                            _s.queued.isEmpty
                                ? 'キュー'
                                : 'キュー ${_s.queued.length}',
                            style: const TextStyle(fontSize: 11)),
                        onPressed: running
                            ? () {
                                setState(() => _queueOpen = !_queueOpen);
                                if (!_queueOpen) _grabInput();
                              }
                            : null,
                      ),
                    ),
                  ),
              ]),
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
          //   閉じるボタン。 処理を止めたい時は端末の中で Esc。
          if (running)
            Tooltip(
              message: 'CLI を閉じて一覧へ戻る (処理を止めたい時は Esc)',
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
    ]);
  }
}
