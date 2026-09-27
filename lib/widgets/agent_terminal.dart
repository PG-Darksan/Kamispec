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
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart'
    show
        PointerDeviceKind,
        PointerHoverEvent,
        PointerScrollEvent,
        kPrimaryMouseButton,
        kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
// クリップボードの画像を読む (Ctrl+V で道筋を差し込む用)。
import 'package:super_clipboard/super_clipboard.dart';
// 出力の中の URL を押した時に、 外のブラウザーへ渡す。
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm/xterm.dart';

import '../providers/mind_map_provider.dart';
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

/// 出力の中の「押せる所」 (URL かコマンド)。
///
/// ★ = ユーザー要望「codexCLI から出された powershell コマンド等をクリック
///   したらターミナルが開いて shell で実行されるようにして欲しい」。
///   URL を押したら開く仕組み (b438) と**同じ当たり判定**を通すので、
///   1 つの型で運ぶ。 レコードは項目が増えると別の型になり、 同じ関数で
///   受け取れないため小さなクラスにしてある。
class _TermHit {
  const _TermHit({
    required this.text,
    required this.row,
    required this.from,
    required this.to,
    required this.cmd,
  });

  /// URL そのもの、 またはコマンドの 1 行。
  final String text;

  /// 押された行 (巻物の中での番号)。
  final int row;

  /// その行の中で何枡目から何枡目か (前後の行にはみ出す時は負や cols 超え)。
  final int from;
  final int to;

  /// true = コマンド (走らせる)、 false = URL (開く)。
  final bool cmd;
}

class AgentTerminal extends StatefulWidget {
  const AgentTerminal({
    super.key,
    required this.session,
    this.showHeader = true,
    this.onRunAgain,
    this.onPickLanguage,
    this.onContextMenu,
    this.onRunCommand,
  });

  /// 走らせている物。 この widget は覗くだけで、 止めたりはしない。
  final AgentCliSession session;

  /// 見出しの帯を自分で出すか。
  final bool showHeader;

  /// 「もう一度」 を押した時 (同じ物をもう 1 回走らせる)。
  final VoidCallback? onRunAgain;

  /// 「言語」 を押した時 (= CLI が返事をする言葉を選び直す)。
  final VoidCallback? onPickLanguage;

  /// 本文の上で右クリックされた時 (= ユーザー要望:「codexCLI の本文中で
  /// 右クリックすることは無いから、 画面分割や新規タブ作成などの項目を
  /// 出すように割り当てられないか」)。 渡されなければ今までどおり何もしない。
  final void Function(Offset globalPosition)? onContextMenu;

  /// 出力の中の「コマンドらしい 1 行」 を押して、 **確認まで済んだ**時
  /// (= ユーザー要望: codexCLI が出した powershell のコマンド等を押したら
  ///  ターミナルが開いて走るように)。
  ///
  /// ★ 渡すのは**必ず 1 行**。 [run] が true なら Enter まで送る、 false なら
  ///   **打ち込むだけ** (走らせるかは利用者が端末で決める)。
  /// ★ 渡されない時は、 この端末自身が殻 (`AgentCliSession.isShell`) なら
  ///   そこへ打ち込み、 そうでなければ**押せるようにしない**
  ///   (押しても何も起きない下線を出さない)。 AI の CLI へ打ち込むと
  ///   「指示」 として読まれてしまい、 コマンドとしては走らない。
  final void Function(String command, bool run)? onRunCommand;

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

  /// 下の帯の横巻き (= ユーザー要望: 下の項目が入らない場合は
  /// 左右スクロール方式に)。
  ///
  /// ★ 横に流れる仕掛けは前からあったが、 マウスだと手が無かった
  ///   (ホイールは縦にしか効かず、 掘ることもできない、 見た目の印も無い)。
  ///   巻物役を持って、 ホイールを横へ振り向け、 細い帯を出す。
  final _bottomBarScroll = ScrollController();

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

  /// いま中身を直している順番待ちの通し番号 ([QueuedPrompt.id]、
  /// null = 新しく足す)。
  ///
  /// ★ = ユーザー要望「キューの内容を編集できるようにして欲しい」。
  ///   別の窓は出さず、 下の入力欄をそのまま「直す欄」 として使い回す。
  /// ★ **並びの位置ではなく通し番号で持つ**。 直している間に先頭の 1 件が
  ///   渡って番号がずれても、 同じ文言が 2 つ並んでいても、 狙った行だけを
  ///   書き直せる (位置や文言で指すと別の行を書き潰す)。
  int? _queueEditId;

  /// 「全部消す」 を一度押した状態 (もう一度押すと本当に消す)。
  bool _queueClearArmed = false;

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

  /// 欄を通らずに直接差し込んだ文字 (ファイルの道筋など)。
  ///
  /// ★ [_liveSent] は隠し入力欄との差分用なのでこれらを入れられないが、
  ///   「キュー」へ溜める時に落とすと画像の道筋が消えるので、 別に覚えておく。
  String _injectedText = '';

  /// 送り出しの最中か (入力欄を空に戻す時の呼び戻しを止める)。
  bool _flushing = false;

  /// 一番下に貼り付いているか。
  bool _atBottom = true;

  // ── 「最新へ」 の札 (= ユーザー報告: 欄が点滅する) ──
  //
  //    以前は「下端から 4px 以内か」 だけで出し入れしていた。 出力が
  //    続いている間は**下端が中身より 1 フレーム早く伸びる**ので、
  //    貼り付いているのに一瞬だけ 4px を超え、 札が出ては消えるを
  //    出力の速さで繰り返していた。 これが点滅の一番目立つ正体。
  //      ・余裕を 1 行より広く取る
  //      ・**自分で上へ遡った時だけ**出す (自動で送られた分では出さない)
  bool _userScrolledUp = false;
  bool _showJumpLatest = false;
  double _lastPixels = 0;

  /// 端末のカーソルの位置 (この widget の中での座標)。
  ///
  /// ★ ここだけを見ている小さな欄 (隠し入力) に配り、 端末そのものを
  ///   組み直さない (= 点滅対策)。
  final ValueNotifier<Offset?> _cursorPosVn = ValueNotifier<Offset?>(null);

  /// 指している URL の下線の場所 (この widget の中での座標)。
  ///
  /// ★ = ユーザー要望「codexCLI 等で出力されてハイパーリンクをクリックしたら
  ///   そのURL先に飛べるようにして欲しい」。 ここも端末そのものを組み直さず、
  ///   小さな札だけに配る (= 点滅対策)。
  final ValueNotifier<Rect?> _linkRectVn = ValueNotifier<Rect?>(null);

  /// いま指しているのが URL かコマンドか (下線の色と太さを分けるだけ)。
  ///
  /// ★ 札の組み直しは [_linkRectVn] が起こすので、 **場所を配る直前に**
  ///   ここへ入れておけば、 その組み直しで新しい値が読まれる。
  bool _linkIsCmd = false;

  /// コマンドの確認窓を出している間の掛け金。
  ///
  /// ★ このコードベースのダイアログには再入防止が無い物が多く、 連打すると
  ///   同じ窓が積み上がる。 端末は色と枠だらけで押し間違いが起きやすいので、
  ///   ここは 1 枚だけに限る。
  bool _cmdConfirmOpen = false;

  /// 左ボタンが押された場所と時刻。
  ///
  /// ★ 「押して離すまで動いていない」 時だけ URL を探す。 文字選び (掘って
  ///   選ぶ) を壊さないため、 ジェスチャーの取り合いには入らず [Listener] で
  ///   生の押下だけを見て自分で見極める。
  Offset? _linkDownAt;
  int _linkDownMs = 0;

  /// 直前に見極めた枡 (同じ枡の上で動いている間は読み直さない)。
  int _hoverCellX = -1;
  int _hoverCellY = -1;

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
    // ★ 上限が解けた後に送る言葉は、 表示言語に合わせる (CLI はその言葉で
    //   返事をしている)。 置き場が無い / 言葉が見つからない時は既定の
    //   「続けて」 のまま (鍵の名前をそのまま打ち込ませない)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        const k = 'cli.limitResumeWord';
        final w = context.read<MindMapProvider>().t(k).trim();
        if (w.isNotEmpty && w != k) _s.resumeWord = w;
      } catch (_) {}
    });
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
      if (_inputFocus.hasPrimaryFocus) {
        _focusMissed = 0;
        return;
      }
      // ★ = ユーザー報告「欄が点滅する」。 相手 (地図の押鍵の受け口など)
      //   も焦点を取り返しに来ると、 700 ms ごとに行ったり来たりして
      //   分割画面の枠の色まで点滅していた。 何度やっても取れない時は
      //   諦める。 利用者がこの端末を押せば [_grabInput] が数え直す。
      if (_focusMissed >= 3) return;
      // 他所の入力欄 (要素の名前など) が使われている間も横取りしない。
      // ★ ここで掛け金 (_userLeft) は掛けない。 掛けると、 その欄が
      //   閉じた後も見回りが止まったままになり、 二度と打てなくなる
      //   (= ユーザー報告: 他の要素を編集すると入れられなくなる)。
      //   次の見回りで判断し直せばよい。
      // ★ 空振りに数えるのは**取りに行った時だけ**。 他所の欄を使って
      //   いる間も数えると、 要素の名前を 2 秒ほど書いただけで見回りが
      //   止まってしまう (= 点検で判明)。
      if (_otherEditorHasFocus()) return;
      _focusMissed++;
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
      // ★ 別のセッションになったら、 巻物まわりの掛け金と印も下ろす
      //   (前のタブで遡っていた事を持ち越さない)。
      _userScrolledUp = false;
      _showJumpLatest = false;
      _lastPixels = 0;
      _lastSig = '';
      _focusMissed = 0;
      // ★ タブを切り替えた時 (= ユーザー要望: 新規タブ) に、 前のタブへ
      //   「先出し」 していた文字を持ち越さない。 持ち越すと、 次に打った
      //   文字の「消す分」 が前のタブの長さだけずれて、 新しいタブの行が
      //   壊れる。 開いていた欄 (履歴 / 順番待ち) も畳む。
      //   ★ ここでは setState を呼ばない (この後どのみち組み直される)。
      _flushing = true;
      _inputCtrl.clear();
      _flushing = false;
      _liveSent = '';
      _composing = '';
      // ★ 待たせてある打鍵も捨てる。 `_flushPendingKeys` は `_s`
      //   (= いま差し替わった**新しい**セッション) へ送るので、 前のタブ
      //   へ打った文字が新しいタブに紛れ込む (最大 400 ミリ秒分)。
      _pendingTimer?.cancel();
      _pendingTimer = null;
      _pendingKeys.clear();
      _openPanelCmd = null;
      _histOpen = false;
      _queueOpen = false;
      _queueCtrl.clear();
      _queueEditId = null;
      _queueClearArmed = false;
      _focusTried = false;
      // ★ 前のタブで外へ出ていた掛け金は下ろす。 下ろさないと
      //   `_grabFocusSoon` が素通りして、 選んだタブに打ち込めない。
      _userLeft = false;
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
    _bottomBarScroll.dispose();
    _pendingTimer?.cancel();
    _focusWatch?.cancel();
    _inputCtrl.removeListener(_onInputChanged);
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _queueCtrl.dispose();
    _queueFocus.dispose();
    _termController.dispose();
    _termFocus.dispose();
    _cursorPosVn.dispose();
    _linkRectVn.dispose();
    super.dispose();
  }

  bool _focusTried = false;

  /// 焦点を取りに行って空振りした回数 (点滅止め。 [_grabInput] で 0 に戻る)。
  int _focusMissed = 0;

  /// 画面に出している値をひとまとめにした印。
  ///
  /// ★ = ユーザー報告「AI やターミナルの欄が点滅する」。 セッションは
  ///   400 ms ごとの見張りや順番待ちの汲み出しでも知らせを出すので、
  ///   そのたびに端末ごと組み直していた (TerminalView・スクロール棒・
  ///   隠し入力まで作り直す)。 出している値が動いた時だけ組み直す。
  String _viewSig() {
    final lim = _s.limitUntil?.millisecondsSinceEpoch ?? 0;
    final sent = _s.sentLines;
    // ★ 件数だけだと控えの上限 (100 件) に達した後で「履歴」 欄が
    //   止まるので、 最後の 1 行も見る。
    final lastSent = sent.isEmpty ? '' : sent.last;
    // ★ 溜めた分は 100 件まで入るので、 全部つないで比べると 500 ミリ秒
    //   ごとに数十 KB の文字列を作る事になる。 件数と、 順番待ちが動いた
    //   回数 ([AgentCliSession.queueRev]) だけ見る (入れ替えや書き直しでも
    //   必ず増える)。
    return '${_s.running}|${_s.busyForUi}|${_s.starting}|${_s.launchFailed}'
        '|${_s.launchError}|${_s.launchDiedEarly}|${_s.stoppedByUser}'
        '|${_s.exitCode}|${_s.queueMode}|${_s.queuedCount}|${_s.queueRev}'
        '|${_s.limitWaiting}|$lim|${_s.limitZoneNote}|${_s.needsResumeWord}'
        '|${sent.length}|$lastSent|${_s.shownDirectory}|${_s.resumeWord}';
  }

  String _lastSig = '';

  void _onChanged() {
    if (!mounted) return;
    final sig = _viewSig();
    if (sig != _lastSig) {
      _lastSig = sig;
      setState(() {});
    }
    _syncCursorSoon();
    if (!_focusTried && _s.running) {
      _focusTried = true;
      _grabFocusSoon();
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final bottom = pos.pixels >= pos.maxScrollExtent - 24;
    // 自動で送られる時は必ず下へ動く。 **上へ動いた時だけ**「自分で遡った」。
    if (pos.pixels < _lastPixels - 1) _userScrolledUp = true;
    if (bottom) _userScrolledUp = false;
    _lastPixels = pos.pixels;
    _atBottom = bottom;
    final show = _userScrolledUp && !bottom;
    if (show != _showJumpLatest) setState(() => _showJumpLatest = show);
    // ★ 巻き上げると下線の場所が狂うので消す (次に指した時に出し直す)。
    if (_linkRectVn.value != null) _linkRectVn.value = null;
    _hoverCellY = -1;
  }

  /// 打てる状態にする。
  void _grabInput() {
    if (!mounted) return;
    if (_queueFocus.hasFocus) return;
    // 呼ばれるのは「利用者がこの端末で何かした」 時だけなので、
    // 掛け金はここで必ず下ろす。
    _userLeft = false;
    _focusMissed = 0;
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
    // ★ 4 回 (0/120/400/900) 撃っていたのを 2 回に (= 点滅対策)。 1 回の
    //   タブ切り替えで焦点が 4 度動き、 そのたびに枠の色が変わっていた。
    for (final ms in const [0, 300]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (!mounted || !_s.running) return;
        // 既に打てるなら何もしない。
        if (_inputFocus.hasPrimaryFocus) return;
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
      final cur = _cursorPosVn.value;
      if (cur == null || (p - cur).distance > 1.0) {
        _lastCursorSync = now;
        // ★ setState ではなく配るだけ (= 点滅対策)。 隠し入力の場所しか
        //   変わらないのに、 端末ごと組み直す必要は無い。
        _cursorPosVn.value = p;
      }
    } catch (_) {
      // まだ組み上がっていない時は何もしない。
    }
  }

  // ── 出力の中の URL ──────────────────────────────────────────────────────
  //
  //   ★ = ユーザー要望「codexCLI 等で出力されてハイパーリンクをクリックしたら
  //     そのURL先に飛べるようにして欲しい」。
  //   ★ xterm 4.0.0 には OSC 8 (端末が自分でリンクを覚える決まり) が無く、
  //     `TerminalView.onTapUp` も向こう側の配線違いで呼ばれない (向こうの
  //     `gesture_detector.dart` は `onTapUp` を宣言するだけで一度も呼ばず、
  //     実際の叩きは `onSingleTapUp` へ流れて端末自身が使っている)。 そこで
  //     「押された場所 → 枡 → その行の字」 を自分で辿って URL を割り出す。
  //     使っているのは向こうに実際にある口だけ:
  //       ・`TerminalViewState.renderTerminal`
  //       ・`RenderTerminal.getCellOffset` / `getOffset` / `cellSize`
  //       ・`BufferLine.getCodePoint` / `length` / `isWrapped`

  /// URL に見える所を拾う決まり。 後ろの句読点は下で削る。
  static final RegExp _kUrlRe = RegExp(
      r'''(?:https?://|www\.)[-\w.~:/?#\[\]@!$&'*+,;=%()]+''',
      caseSensitive: false);

  /// 行の字を**枡と同じ並びで**取り出す (1 枡 = きっかり 1 単位)。
  ///
  /// ★ `BufferLine.getText()` は空の枡 (codePoint 0) を**飛ばす**ので、
  ///   字の位置と枡の位置がずれてしまい、 押された所を数えるのに使えない。
  /// ★ 16bit に収まらない字 (絵文字など) も**空白 1 つ**に置き換える。
  ///   `writeCharCode` はそういう字を 2 単位で書くので、 そのまま入れると
  ///   以降の位置が 1 つずつずれる。 URL は ASCII なので置き換えて困らない。
  // ── 出力の中の「コマンドらしい 1 行」 を見分ける決まり ──────────────────
  //
  //  ★ = ユーザー要望「codexCLI から出された powershell コマンド等をクリック
  //    したらターミナルが開いて shell で実行されるようにして欲しい」。
  //  ★ URL と違ってコマンドは形が決まっていない。 **誤検知が害になる**ので
  //    (押し間違いで消す系が走る)、 取りこぼす方へ倒す。 拾うのは
  //    「下の白名簿の言葉で始まる 1 行」 だけ。
  //  ★ `^` は付けない。 頭に釘付けするのは `matchAsPrefix` の役目で、 `^` を
  //    書くと入力の 0 文字目しか見なくなる (枠線を落とした後では使えない)。

  /// 頭に付いた飾り (枠線を落とした後の、 箇条書きの印や見せかけの
  /// プロンプト)。 後ろに空白を要るので `>out.txt` は飾りと見なさない。
  ///
  /// ★ 生文字列にバックスラッシュを入れない形にしてある
  ///   (`C:\dir>` は `[A-Za-z]:[^>]{0,200}>` で足りる)。
  static final RegExp _kCmdLeadRe = RegExp(
      r'(?:PS\s+[^>]{0,200}>|[A-Za-z]:[^>]{0,200}>|[-*>$]|\d{1,2}\s*[.)])\s+');

  /// コマンドの先頭に来る言葉 (白名簿)。
  ///
  /// ★ 文章にも出る短い語 (make / set / type / copy / echo / cat / ls /
  ///   dir / code / where) は**入れない**。 `go` は後ろに副命令を要求する形
  ///   だけ入れる (「go to the folder」 を拾わないため)。
  static final RegExp _kCmdHeadRe = RegExp(
      r'(?:powershell|pwsh|cmd|git|gh|npm|npx|pnpm|yarn|flutter|dart'
      r'|python3?|py|pip3?|node|deno|bun|adb|gradlew|dotnet|msbuild|cmake'
      r'|cargo|rustup|rustc|winget|choco|scoop|curl|wget|tar|ssh|scp'
      r'|robocopy|xcopy|findstr|rg|ffmpeg|sqlite3|explorer|taskkill|schtasks'
      r'|reg|ipconfig|netstat|docker|kubectl|mvn|gradle|pytest|poetry|ruff'
      r'|go\s+(?:build|run|test|mod|get|install)'
      r'|Get-\w+|Set-\w+|New-\w+|Remove-\w+|Copy-Item|Move-Item|Test-Path'
      r'|Start-Process|Invoke-\w+|Select-String)(?:\.exe)?(?=\s|$)',
      caseSensitive: false);

  /// 文章の句読点。 1 つでも入っていたら説明文と見なして押せるようにしない。
  static final RegExp _kCmdProseRe = RegExp(r'[、。「」『』・？！，；]');

  /// 消す / 元に戻せない操作の言葉。 入っていたら「打ち込むだけ」 しか
  /// 出さない (= 押し間違い・AI の暴走で消えるのを防ぐ最後の歯止め)。
  ///
  /// ★ `format` は**ドライブ指定が付いた時だけ**危ないと見る。 `\bformat\b`
  ///   にすると `dart format` と `git log --pretty=format:` まで巻き込む
  ///   (このリポジトリは analyzer が壊れていて `dart format` を常用する)。
  static final RegExp _kCmdRiskyRe = RegExp(
      r'(?:\bRemove-Item\b|\bri\s+-|\brm\s|\bdel\s|\berase\s|\brmdir\b|\brd\s'
      r'|\bformat\s+[A-Za-z]:|\bdiskpart\b|\bmkfs|\bdd\s+if=|\bcipher\s+/w'
      r'|\bgit\s+(?:reset\s+--hard|clean\s+-|push\s+(?:-f\b|--force))'
      r'|\bshutdown\b|\brestart-computer\b|\bstop-computer\b|\btaskkill\b'
      r'|\bstop-process\b|\breg\s+delete\b|\bset-executionpolicy\b'
      r'|\bicacls\b|\btakeown\b|\bInvoke-Expression\b|\biex\b|\bsudo\b'
      r'|\bchmod\s+-R|\bchown\s+-R|\bnpm\s+publish\b|(?:^|\s)>(?!>)\s*\S)',
      caseSensitive: false);

  String _cellsOf(BufferLine line, int cols) {
    final sb = StringBuffer();
    final n = line.length < cols ? line.length : cols;
    for (var i = 0; i < n; i++) {
      final cp = line.getCodePoint(i);
      sb.writeCharCode(cp == 0 || cp > 0xFFFF ? 0x20 : cp);
    }
    for (var i = n; i < cols; i++) {
      sb.writeCharCode(0x20);
    }
    return sb.toString();
  }

  /// 画面の座標 → 枡。
  ///
  /// ★ `getCellOffset` は行も列も**端へ丸めて**返すので、 余白や巻物の棒を
  ///   押した時も一番近い枡が返ってくる。 [exact] の時は、 その枡の実際の
  ///   場所を測り直して「本当にその枡の中を押したか」を確かめ、 丸められて
  ///   いたら捨てる (余白の値を決め打ちしないので padding を変えても効く)。
  /// ★ `renderTerminal` は向こうで `currentContext!` + `as` を通るため
  ///   投げ得る。 まとめて包んでおく。
  CellOffset? _cellAtGlobal(Offset globalPos, {bool exact = false}) {
    final st = _viewKey.currentState;
    if (st == null) return null;
    try {
      final rt = st.renderTerminal;
      if (!rt.hasSize) return null;
      final local = rt.globalToLocal(globalPos);
      final cell = rt.getCellOffset(local);
      if (exact) {
        final cs = rt.cellSize;
        final tl = rt.getOffset(cell);
        if (local.dx < tl.dx ||
            local.dx > tl.dx + cs.width ||
            local.dy < tl.dy ||
            local.dy > tl.dy + cs.height) {
          return null;
        }
      }
      return cell;
    } catch (_) {
      return null;
    }
  }

  /// [globalPos] にある URL を割り出す。
  ///
  /// 返す物は URL と、 **押された行の中で**何枡目から何枡目か (下線用。 前後の
  /// 行にはみ出す時は負の値や `cols` 超えになるので、 使う側で丸める)。
  /// 折り返してちぎれた URL も `isWrapped` を辿ってつなぎ直す。
  _TermHit? _urlAtGlobal(Offset globalPos) {
    final term = _s.terminal;
    final cols = term.viewWidth;
    final lines = term.buffer.lines;
    if (cols <= 0 || lines.length <= 0) return null;
    final cell = _cellAtGlobal(globalPos, exact: true);
    if (cell == null) return null;
    final row = cell.y;
    if (row < 0 || row >= lines.length) return null;
    // 折り返しの元と続きは [_joinedLineAt] が辿る (コマンド判定と共通)。
    final j = _joinedLineAt(row, cols);
    final text = j.text;
    final rowHead = j.rowHead;
    final at = rowHead + cell.x;
    for (final m in _kUrlRe.allMatches(text)) {
      final s = m.start;
      var e = m.end;
      // 後ろの句読点・閉じ括弧は URL に入れない (「〜。」「(https://…)」)。
      while (e > s) {
        final ch = text[e - 1];
        if ('.,;:!?'.contains(ch) || ch == "'" || ch == '"') {
          e--;
          continue;
        }
        if (ch == ')' && !text.substring(s, e).contains('(')) {
          e--;
          continue;
        }
        if (ch == ']' && !text.substring(s, e).contains('[')) {
          e--;
          continue;
        }
        break;
      }
      if (at < s || at >= e) continue;
      var url = text.substring(s, e);
      if (url.toLowerCase().startsWith('www.')) url = 'https://$url';
      return _TermHit(
          text: url,
          row: row,
          from: s - rowHead,
          to: e - rowHead,
          cmd: false);
    }
    return null;
  }

  /// [row] を含む「折り返しでつながった 1 行」 を、 枡と同じ並びで返す。
  ///
  /// ★ URL とコマンドの**両方がこれを使う** (= 同じ仕組みに相乗り)。
  ({String text, int rowHead}) _joinedLineAt(int row, int cols) {
    final lines = _s.terminal.buffer.lines;
    var head = row;
    while (head > 0 && lines[head].isWrapped) {
      head--;
    }
    var tail = row;
    while (tail + 1 < lines.length && lines[tail + 1].isWrapped) {
      tail++;
    }
    final sb = StringBuffer();
    for (var i = head; i <= tail; i++) {
      sb.write(_cellsOf(lines[i], cols));
    }
    return (text: sb.toString(), rowHead: (row - head) * cols);
  }

  /// [globalPos] にある「コマンドらしい 1 行」 を割り出す。
  ///
  /// ★ 渡す先が無い時は**押せるようにしない** (押しても何も起きない下線を
  ///   出さない)。 渡す先 = [AgentTerminal.onRunCommand]、 または この端末
  ///   自身が殻であること。
  /// ★ 返すのは**必ず 1 行**。 制御文字が混じった行は捨てるので、 束が
  ///   一度に流れることは起こらない。
  /// ★ 枠線 (TUI の `│ …… │`)・箇条書きの印・見せかけのプロンプトを落として
  ///   から、 白名簿の言葉で始まるかだけを見る。
  _TermHit? _cmdAtGlobal(Offset globalPos) {
    if (widget.onRunCommand == null && !_s.isShell) return null;
    final term = _s.terminal;
    final cols = term.viewWidth;
    final lines = term.buffer.lines;
    if (cols <= 0 || lines.length <= 0) return null;
    final cell = _cellAtGlobal(globalPos, exact: true);
    if (cell == null) return null;
    final row = cell.y;
    if (row < 0 || row >= lines.length) return null;
    final j = _joinedLineAt(row, cols);
    final text = j.text;
    final at = j.rowHead + cell.x;
    // 枠線と余白を落とす。
    bool deco(int c) =>
        c == 0x20 || c == 0x09 || c == 0xA0 || (c >= 0x2500 && c <= 0x259F);
    var s = 0;
    var e = text.length;
    while (s < e && deco(text.codeUnitAt(s))) {
      s++;
    }
    while (e > s && deco(text.codeUnitAt(e - 1))) {
      e--;
    }
    // 箇条書きの印や見せかけのプロンプトも落とす (2 段まで)。
    for (var i = 0; i < 2; i++) {
      final m = _kCmdLeadRe.matchAsPrefix(text, s);
      if (m == null || m.end > e) break;
      s = m.end;
      while (s < e && deco(text.codeUnitAt(s))) {
        s++;
      }
    }
    if (e - s < 2 || e - s > 500) return null;
    final body = text.substring(s, e);
    if (_kCmdHeadRe.matchAsPrefix(body) == null) return null;
    if (_kCmdProseRe.hasMatch(body)) return null;
    for (final c in body.codeUnits) {
      if (c < 0x20 || c == 0x7f) return null;
    }
    if (at < s || at >= e) return null;
    return _TermHit(
        text: body,
        row: row,
        from: s - j.rowHead,
        to: e - j.rowHead,
        cmd: true);
  }

  /// 下線を出す場所を配る (この widget の中での座標)。
  void _updateLinkRect(_TermHit? hit) {
    final st = _viewKey.currentState;
    final box = _stackKey.currentContext?.findRenderObject();
    if (hit == null || st == null || box is! RenderBox || !box.hasSize) {
      _linkRectVn.value = null;
      return;
    }
    final cols = _s.terminal.viewWidth;
    final c0 = hit.from < 0 ? 0 : (hit.from > cols ? cols : hit.from);
    final c1 = hit.to < 0 ? 0 : (hit.to > cols ? cols : hit.to);
    if (c1 <= c0) {
      _linkRectVn.value = null;
      return;
    }
    try {
      final rt = st.renderTerminal;
      final cs = rt.cellSize;
      final tl = box.globalToLocal(
          rt.localToGlobal(rt.getOffset(CellOffset(c0, hit.row))));
      _linkIsCmd = hit.cmd;
      _linkRectVn.value =
          Rect.fromLTWH(tl.dx, tl.dy, (c1 - c0) * cs.width, cs.height);
    } catch (_) {
      _linkRectVn.value = null;
    }
  }

  /// マウスが動いた時。 URL の上に来たら下線と指の形を出す。
  ///
  /// ★ 枡が変わった時だけ読み直す (1px ごとに行を組み立て直すのは無駄)。
  void _onTermHover(PointerHoverEvent e) {
    final cell = _cellAtGlobal(e.position);
    final cx = cell?.x ?? -1;
    final cy = cell?.y ?? -1;
    if (cx == _hoverCellX && cy == _hoverCellY) return;
    _hoverCellX = cx;
    _hoverCellY = cy;
    // URL が先 (開くだけで害が小さい)。 無ければコマンドを見る。
    _updateLinkRect(_urlAtGlobal(e.position) ?? _cmdAtGlobal(e.position));
  }

  /// 叩かれた所に URL があれば開く。
  ///
  /// ★ 出先はこのアプリの他の所と同じ**外のブラウザー**。
  Future<void> _openLinkAt(Offset globalPos) async {
    final hit = _urlAtGlobal(globalPos) ?? _cmdAtGlobal(globalPos);
    if (hit == null) return;
    _linkRectVn.value = null;
    // ★ コマンドは**ここでは走らせない**。 中身を見せて確かめてから。
    if (hit.cmd) {
      await _confirmAndRunCommand(hit.text);
      return;
    }
    final uri = Uri.tryParse(hit.text);
    if (uri == null || !uri.hasScheme) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 開けなかった時は黙って諦める (端末の表示は壊さない)。
    }
  }

  /// 押されたコマンドを、 **中身を見せて確かめてから**端末へ渡す。
  ///
  /// ★ ここが安全の要。 押しただけでは走らない。
  ///   ・全文と「どこで走らせるか」 を出す
  ///   ・1 回に渡すのは**1 行だけ** (束では流さない)
  ///   ・消す / 元に戻せない語が入っていた時は「打ち込むだけ」 しか出さない
  ///     (走らせるには、 端末に乗った行を自分で読んで Enter を押す)
  /// ★ 窓は**一番近い Navigator** に出す (`useRootNavigator: false`)。 浮遊窓
  ///   (`_FloatingPanelWindow`) は自前の Navigator を持っているので、 根っこへ
  ///   出すと窓の裏に積まれて押せなくなる。 サブ窓の中でも、 この端末の
  ///   context は窓の MaterialApp の**内側**なので同じ形で届く。
  Future<void> _confirmAndRunCommand(String cmd) async {
    if (!mounted || _cmdConfirmOpen) return;
    final provider = context.read<MindMapProvider>();
    final dir = _s.shownDirectory;
    final risky = _kCmdRiskyRe.hasMatch(cmd);
    _cmdConfirmOpen = true;
    bool? run;
    try {
      run = await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (dctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E32),
          title: Row(children: [
            Icon(risky ? Icons.warning_amber_rounded : Icons.terminal_rounded,
                size: 18,
                color:
                    risky ? const Color(0xFFE53935) : const Color(0xFF9CCC65)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(provider.t('cli.runCmdTitle'),
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
            ),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF12121F),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white12),
                ),
                child: SelectableText(cmd,
                    style: const TextStyle(
                        color: Color(0xFFD7E3F4),
                        fontSize: 12,
                        height: 1.5,
                        fontFamily: 'Consolas')),
              ),
              const SizedBox(height: 10),
              Text('${provider.t('cli.runCmdDir')}  $dir',
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 11, height: 1.5)),
              const SizedBox(height: 8),
              Text(
                  risky
                      ? provider.t('cli.runCmdRisky')
                      : provider.t('cli.runCmdHint'),
                  style: TextStyle(
                      color: risky ? const Color(0xFFFFB347) : Colors.white54,
                      fontSize: 11,
                      height: 1.6)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(null),
              child: Text(provider.t('common.cancel'),
                  style: const TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: Text(provider.t('cli.runCmdTypeOnly'),
                  style: const TextStyle(color: Color(0xFF8AB4F8))),
            ),
            // ★ 消す系が入っていたら「実行する」 は**出さない**。
            if (!risky)
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF43B97F),
                    foregroundColor: Colors.white),
                onPressed: () => Navigator.of(dctx).pop(true),
                child: Text(provider.t('cli.runCmdRun')),
              ),
          ],
        ),
      );
    } finally {
      _cmdConfirmOpen = false;
    }
    if (run == null || !mounted) return;
    final cb = widget.onRunCommand;
    if (cb != null) {
      // 殻を用意して渡すのは画面側の仕事 (AI の CLI へは打ち込まない)。
      cb(cmd, run);
      return;
    }
    // この端末自身が殻なら、 その場へ打ち込む (ヘッダーのターミナル / 編集
    // 画面の下の帯)。
    if (!_s.isShell || !_s.running) return;
    if (run) {
      _s.send(cmd);
    } else {
      _s.sendRaw(cmd);
    }
    _returnToTerminal();
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
    _injectedText = '';
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
      // ★ 「キュー」 に切り替えている間の Enter は、 CLI へ渡さず順番待ちへ
      //   溜める (= ユーザー要望: プロバイダー側にその機能が無いのであれば
      //   アプリ側で実装する)。 打った分は CLI の行に映っているので、
      //   ^U で消してから溜める。
      if (tk == TerminalKey.enter && !ctrl && !alt && !shift && _s.queueMode) {
        if (_enqueueTypedLine()) return KeyEventResult.handled;
      }
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

  /// Ctrl+V。 ★ = ユーザー要望「ctrl+v でチャット欄に画像の道筋を貼り付け
  ///   られるようにして欲しい」。 クリップボードに画像があれば、 一度
  ///   ファイルへ書き出して**その道筋**を打ちかけの文へ差し込む
  ///   (CLI はどれも画像を「道筋」 で受け取るため)。 画像が無ければ、
  ///   今までどおり文字を貼る。
  Future<void> _pasteClipboard() async {
    // ★ = 点検で判明: Excel や Web から写すと**画像と文字の両方**が
    //   クリップボードに載る。 以前は画像だけを見て文字を捨てていたので、
    //   写したはずの表や文章が消えていた。 両方あれば両方渡す
    //   (道筋 → 文字の順。 CLI の行に見える並びもこの順になる)。
    final path = await _writeClipboardImage();
    if (path != null) {
      // 空白や日本語を含む道筋があるので、 必ず引用符で包む。
      // ★ [_liveSent] には足さない。 これは「隠し入力欄と CLI の行の
      //   差分」を取るための控えなので、 欄に無い物を足すと、 次に打った
      //   瞬間に道筋を退避で消しに行ってしまう (ファイル選択も同じ扱い)。
      _s.sendRaw('"$path" ');
      _injectedText = '$_injectedText"$path" ';
      _grabInput();
      _stickToBottom();
      // 文字も載っていれば、 続けて貼る (どちらも捨てない)。
      final withText = await Clipboard.getData(Clipboard.kTextPlain);
      final tt = withText?.text ?? '';
      if (tt.isNotEmpty) {
        _s.terminal.paste(tt);
        _injectedText = '$_injectedText$tt';
        _stickToBottom();
      }
      return;
    }
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text ?? '';
    if (t.isEmpty) return;
    // ★ 貼った分も控えへ足す (= 点検で判明: 足さないと「キュー」 で Enter を
    //   押した時に [_enqueueTypedLine] が拾えず、 そのうえ ^U で行ごと消える
    //   ので、 貼り付けた中身が跡形もなく消える)。 [_liveSent] ではなく
    //   [_injectedText] に入れるのは、 隠し入力欄に無い文字だから (画像の
    //   道筋と同じ扱い)。
    _s.terminal.paste(t);
    _injectedText = '$_injectedText$t';
    _stickToBottom();
  }

  /// クリップボードの画像をファイルへ書き出して、 その道筋を返す。
  /// 画像が無ければ null (= 文字の貼り付けへ回す)。
  ///
  /// ★ 置き場はアプリの支え置き場の下。 1 日より古い物は開くたびに片付ける
  ///   (= 溜め込まない。 provider の `_writeImagesForCli` と同じ決まり)。
  Future<String?> _writeClipboardImage() async {
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
        final done = Completer<Uint8List?>();
        reader.getFile(fmt, (file) async {
          try {
            final chunks = <int>[];
            await for (final c in file.getStream()) {
              chunks.addAll(c);
            }
            if (!done.isCompleted) {
              done.complete(Uint8List.fromList(chunks));
            }
          } catch (_) {
            if (!done.isCompleted) done.complete(null);
          }
        }, onError: (_) {
          if (!done.isCompleted) done.complete(null);
        });
        final bytes = await done.future
            .timeout(const Duration(seconds: 10), onTimeout: () => null);
        if (bytes == null || bytes.isEmpty) continue;
        final base = await getApplicationSupportDirectory();
        final sep = Platform.pathSeparator;
        final dir = Directory('${base.path}${sep}cli_paste');
        if (!await dir.exists()) await dir.create(recursive: true);
        try {
          final now = DateTime.now();
          for (final f in dir.listSync()) {
            if (f is! File) continue;
            if (now.difference(f.statSync().modified).inHours >= 24) {
              try {
                f.deleteSync();
              } catch (_) {}
            }
          }
        } catch (_) {}
        final ext = fmt == Formats.jpeg
            ? 'jpg'
            : fmt == Formats.gif
                ? 'gif'
                : fmt == Formats.webp
                    ? 'webp'
                    : fmt == Formats.bmp
                        ? 'bmp'
                        : 'png';
        final file = File('${dir.path}${sep}paste_'
            '${DateTime.now().millisecondsSinceEpoch}.$ext');
        await file.writeAsBytes(bytes, flush: true);
        return file.path;
      }
    } catch (e) {
      debugPrint('クリップボードの画像の取り込みに失敗: $e');
    }
    return null;
  }

  /// 打ちかけの行を丸ごと消す。
  ///
  /// ★ = ユーザー要望「チャット欄を ctrl+a などで全消しすることって
  ///   できないよね? できるようにするかクリアボタンで全消しできるように」。
  ///   端末では Ctrl+A は「行頭へ移動」 なので取り上げない。 代わりに
  ///   ^U (行を消す) を送るボタンを下の帯に置いた。 ^U を知らない相手でも
  ///   消えるよう、 こちらが映している分だけ退避も送る。
  void _clearInputLine() {
    final n = _liveSent.runes.length;
    _s.sendRaw('\x15');
    if (n > 0) _s.sendRaw('\x7f' * n);
    _resetMirror();
    _grabInput();
    _stickToBottom();
  }

  /// 打ちかけの行を順番待ちへ溜める。 溜められたら true。
  bool _enqueueTypedLine() {
    final t = '$_injectedText$_liveSent'.trim();
    if (t.isEmpty) return false;
    if (!_s.enqueue(t)) {
      // 上限に当たった時は、 いつもどおり今すぐ渡す (消えてしまわないように)。
      return false;
    }
    _clearInputLine();
    if (mounted) setState(() {});
    return true;
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
      final pos = _scroll.position;
      _userScrolledUp = false;
      // 既に下端なら触らない (毎回飛ばすと上の判定と押し合って点滅する)。
      if ((pos.maxScrollExtent - pos.pixels).abs() < 1) return;
      pos.jumpTo(pos.maxScrollExtent);
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

  /// 帯を開け閉めするボタン (キュー / 予約)。
  /// 送るのではなく自分の帯を出すので、 _cmdButton とは別。
  /// 画像や文書を選んで、 その道筋を端末へ差し込む。
  ///
  /// ★ = ユーザー要望「CLI に画像や文書ファイルを渡せるようにして欲しい」。
  ///   Claude Code も codex も、 受け取り方は**道筋を文中に書く**形なので、
  ///   選んだ物の道筋を打ちかけの文へ入れるだけでよい。 送信はしない
  ///   (「これを要約して」 などと書き足してから送れるように)。
  Future<void> _pickFilesForCli() async {
    try {
      final res = await FilePicker.platform.pickFiles(allowMultiple: true);
      final files = res?.files ?? const <PlatformFile>[];
      if (files.isEmpty) return;
      final parts = <String>[];
      for (final f in files) {
        final path = (f.path ?? '').trim();
        if (path.isEmpty) continue;
        // 空白や日本語を含む道筋があるので、 必ず引用符で包む。
        parts.add('"$path"');
      }
      if (parts.isEmpty) return;
      _s.sendRaw('${parts.join(' ')} ');
      _injectedText = '$_injectedText${parts.join(' ')} ';
      _grabInput();
    } catch (_) {
      // 選ばれなかった / 開けなかった時は何もしない。
    }
  }

  Widget _panelButton({
    required String label,
    required IconData icon,
    required String tip,
    required bool open,
    required Color color,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: open ? '$tip / もう一度押すと閉じます' : tip,
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: open ? color : Colors.white70,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          icon: Icon(open ? Icons.close_rounded : icon, size: 14),
          label: Text(label, style: const TextStyle(fontSize: 11)),
          onPressed: enabled ? onTap : null,
        ),
      ),
    );
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

  /// いま直している行が、 並びの何番目に居るか (居なければ -1)。
  int get _queueEditAt {
    final id = _queueEditId;
    if (id == null) return -1;
    return _s.queuedItems.indexWhere((e) => e.id == id);
  }

  /// 順番待ちに 1 件足す (直している最中はその 1 件を書き換える)。
  ///
  /// ★ = ユーザー要望「100 件まで貯めておけるように」。 満杯の時は
  ///   黙って捨てず、 入れられなかったと分かるように残す。
  void _addQueued() {
    final t = _queueCtrl.text.trim();
    if (t.isEmpty) return;
    final editing = _queueEditId;
    if (editing != null) {
      if (_s.updateQueuedId(editing, t)) {
        _queueCtrl.clear();
        setState(() => _queueEditId = null);
        return;
      }
      // ★ 直している間に渡ってしまった = もう直せない。 黙って捨てず、
      //   新しく足す方へ落とす。
      _queueEditId = null;
    }
    if (!_s.enqueue(t)) {
      setState(() {});
      return;
    }
    _queueCtrl.clear();
    setState(() {});
  }

  /// 溜めた 1 件を下の入力欄へ移して直せるようにする。
  void _editQueued(QueuedPrompt item) {
    _queueCtrl.text = item.text;
    _queueCtrl.selection =
        TextSelection.collapsed(offset: _queueCtrl.text.length);
    setState(() {
      _queueEditId = item.id;
      _queueClearArmed = false;
    });
    _queueFocus.requestFocus();
  }

  /// 溜めた 1 件を取り消す (通し番号で指すので取り違えない)。
  void _removeQueued(QueuedPrompt item) {
    setState(() {
      _s.cancelQueuedId(item.id);
      // 直していた行が消えたら、 直すのもやめる。
      if (_queueEditId == item.id) {
        _queueEditId = null;
        _queueCtrl.clear();
      }
    });
  }

  /// 直すのをやめる (入力欄を空に戻す)。
  void _cancelQueueEdit() {
    if (_queueEditId == null && _queueCtrl.text.isEmpty) return;
    _queueCtrl.clear();
    setState(() => _queueEditId = null);
    _queueFocus.requestFocus();
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _clock(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

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
    // Esc を押した時 (= 直すのをやめる)。 null なら Esc は横取りしない。
    VoidCallback? onEscape,
    // 帯全体の背の上限。 [extra] に `Flexible` を置く時は必ず渡す事
    //   (Column の高さが決まっていないと `Flexible` は組めない)。
    double? maxHeight,
    List<Widget> extra = const [],
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: const BoxDecoration(
        color: Color(0xFF141426),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: maxHeight ?? double.infinity),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
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
                  // ★ **Enter で確定、 Shift+Enter で改行** (= ユーザー要望)。
                  //   以前は逆 (Enter が改行 / Ctrl+Enter で確定) だったが、 チャット
                  //   欄と同じ手触りにした。 Ctrl+Enter も今までどおり確定として受ける。
                  //   TextField の Enter を横取りするには Focus(onKeyEvent) で
                  //   handled を返すしかない。 かな漢字変換の最中は渡す (変換を決める
                  //   Enter で送ってしまわないように)。
                  child: Focus(
                    onKeyEvent: (node, event) {
                      if (event is! KeyDownEvent) return KeyEventResult.ignored;
                      final k = event.logicalKey;
                      // Esc = 直すのをやめる (かな漢字変換中は変換の取り消しへ渡す)。
                      if (k == LogicalKeyboardKey.escape && onEscape != null) {
                        final c0 = ctrl.value.composing;
                        if (c0.isValid && !c0.isCollapsed) {
                          return KeyEventResult.ignored;
                        }
                        onEscape();
                        return KeyEventResult.handled;
                      }
                      if (k != LogicalKeyboardKey.enter &&
                          k != LogicalKeyboardKey.numpadEnter) {
                        return KeyEventResult.ignored;
                      }
                      // Shift+Enter は改行 = 入力側へそのまま渡す。
                      if (HardwareKeyboard.instance.isShiftPressed) {
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
      ),
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

  /// [paneH] … この端末に与えられている高さ (0 = 分からない)。 溜めた分を
  /// 出す一覧の背を、 端末が潰れない範囲に収めるのに使う。
  Widget _buildQueueBar(double paneH) {
    final q = _s.queuedItems;
    final editingAt = _queueEditAt;
    final editingNow = editingAt >= 0;
    // ★ 帯は下の Column の**伸び縮みしない子**なので、 背が高いままだと
    //   狭いペイン (CLI を 2 段に割った時など) で端末を 0 まで押し潰して
    //   はみ出す。 与えられた高さの 8 割までに抑え、 入り切らない分は
    //   一覧を縮めて巻物にする。
    final double barCap =
        paneH > 0 ? (paneH * 0.8).clamp(110.0, 340.0).toDouble() : 340.0;
    final double listCap = math.min(196.0, math.max(44.0, barCap - 116.0));
    return _buildBar(
      icon: Icons.playlist_add_rounded,
      color: _s.queueFull
          ? const Color(0xFFE57373)
          : const Color(0xFFFFB347),
      maxHeight: barCap,
      // ★ 何件まで入れられるかを常に出す (= ユーザー要望: 100 件まで)。
      //   満杯の時は「入らない」 と分かる色と文言にする。
      note: editingNow
          ? '${editingAt + 1} 件目を直しています (Enter で確定 / Esc でやめる)'
          : _s.queueFull
              ? 'これ以上は溜められません '
                  '(${AgentCliSession.kMaxQueued} 件まで)。 渡し終えるか、 下の × で減らしてください'
              : '処理が終わって落ち着いたら、 ここに入れた指示を順番に渡します '
                  '(${q.length} / ${AgentCliSession.kMaxQueued} 件)',
      ctrl: _queueCtrl,
      focus: _queueFocus,
      hint: editingNow
          ? '直した内容 (Enter で確定 / Shift+Enter で改行)'
          : '次に渡す指示 (Enter で確定 / Shift+Enter で改行)',
      buttonLabel: editingNow ? '直す' : '追加',
      onSubmit: _addQueued,
      onEscape: editingNow ? _cancelQueueEdit : null,
      onClose: () {
        setState(() {
          _queueOpen = false;
          _queueEditId = null;
          _queueClearArmed = false;
        });
        _grabInput();
      },
      extra: [
        if (q.isNotEmpty) ...[
          const SizedBox(height: 5),
          // ── 溜めた分の並び (掴んで入れ替え / 押して中身を直す) ──
          //    ★ = ユーザー要望「キューの順番を入れ替えたり、 内容を編集
          //      できるようにして欲しい」。 100 件まで入るので、 背が高く
          //      なり過ぎないように巻物にする (帯ごと画面を押し出さない)。
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: listCap),
              child: ReorderableListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                // 既定の掴み手は右端に出て × と重なるので、 自分で左に置く。
                buildDefaultDragHandles: false,
                itemCount: q.length,
                // 位置の直し (抜く前 / 後) は session が持つ。
                // ★ 直している行は通し番号で持っているので、 並べ替えても
                //   追い掛ける必要が無い。
                onReorder: (from, to) =>
                    setState(() => _s.reorderQueued(from, to)),
                proxyDecorator: (child, index, anim) => Material(
                  color: const Color(0xFF23233A),
                  borderRadius: BorderRadius.circular(6),
                  child: child,
                ),
                itemBuilder: (_, i) {
                  final item = q[i];
                  final mine = i == editingAt;
                  return Padding(
                    // ★ 通し番号を鍵にする (位置を鍵にすると、 先頭が渡った
                    //   時に別の行の見た目を引き継いでしまう)。
                    key: ValueKey('cliQueue${item.id}'),
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Row(children: [
                      ReorderableDragStartListener(
                        index: i,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 2),
                          child: Icon(Icons.drag_indicator_rounded,
                              size: 13, color: Colors.white30),
                        ),
                      ),
                      Text('${i + 1}.',
                          style: const TextStyle(
                              color: Color(0xFFFFB347), fontSize: 10.5)),
                      const SizedBox(width: 5),
                      // 押すと下の入力欄へ移して直せる (= ユーザー要望)。
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => _editQueued(item),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                                // 改行は 1 行に見せる (溜めた物は複数行もある)。
                                item.text.replaceAll('\n', ' ⏎ '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: mine
                                        ? const Color(0xFFFFD79A)
                                        : Colors.white60,
                                    fontSize: 10.5)),
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () => _editQueued(item),
                        child: const Padding(
                          padding: EdgeInsets.all(3),
                          child: Icon(Icons.edit_outlined,
                              size: 12, color: Colors.white38),
                        ),
                      ),
                      InkWell(
                        onTap: () => _removeQueued(item),
                        child: const Padding(
                          padding: EdgeInsets.all(3),
                          child: Icon(Icons.close_rounded,
                              size: 12, color: Colors.white38),
                        ),
                      ),
                    ]),
                  );
                },
              ),
            ),
          ),
          // ── 全部消す (100 件を 1 つずつ消すのは大変なので) ──
          //    ★ 押し間違いが痛いので、 一度目は「本当に消す?」 に変わる。
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 26),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: _queueClearArmed
                    ? const Color(0xFFE57373)
                    : Colors.white38,
              ),
              onPressed: () {
                if (!_queueClearArmed) {
                  setState(() => _queueClearArmed = true);
                  return;
                }
                _s.clearQueued();
                _queueCtrl.clear();
                setState(() {
                  _queueClearArmed = false;
                  _queueEditId = null;
                });
              },
              child: Text(
                  _queueClearArmed ? 'もう一度押すと全部消えます' : '全部消す',
                  style: const TextStyle(fontSize: 10.5)),
            ),
          ),
        ],
      ],
    );
  }

  /// 表示の言葉。
  ///
  /// ★ この widget は置き場 (provider) 無しでも使えるようにしてあるので、
  ///   見つからない時は素の英語に落として落ちないようにする。
  String _tr(String key, String fallback) {
    try {
      return context.read<MindMapProvider>().t(key);
    } catch (_) {
      return fallback;
    }
  }

  /// 上限が解けるのを待っている時の帯 (= ユーザー要望: 予約の代わりに、
  /// 上限に当たったら解除まで待ってから送る)。
  ///
  /// ★ 「いつ動き出すのか」 と「今すぐ試す / やめる」 が一目で要る。 下の帯は
  ///   横に流れて隠れてしまうので、 全幅の帯として下の帯の上に出す。
  Widget _buildLimitWaitBar() {
    final at = _s.limitUntil;
    final zone = _s.limitZoneNote;
    final note = at == null
        ? _tr('cli.limitWaitingRetry',
                'Waiting for the limit to lift (retrying about every {min} min)')
            .replaceFirst('{min}', '${AgentCliSession.kLimitRetryMinutes}')
        : _tr('cli.limitWaitingAt',
                'Waiting for the limit to lift (resumes at {time})')
            .replaceFirst(
                '{time}', zone == null ? _clock(at) : '${_clock(at)} ($zone)');
    final q = _s.queuedCount;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: const BoxDecoration(
        color: Color(0xFF3B3320),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(
                strokeWidth: 1.6, color: Color(0xFFFFB347)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                q == 0
                    ? note
                    : '$note  '
                        '(${_tr('cli.limitQueued', '{n} waiting')
                            .replaceFirst('{n}', '$q')})',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Color(0xFFFFD79A), fontSize: 11, height: 1.4)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFFFB347),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 26),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              _s.resumeFromLimit();
              _grabInput();
            },
            child: Text(_tr('cli.limitTryNow', 'Try now'),
                style: const TextStyle(fontSize: 11)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white54,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 26),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () {
              _s.cancelLimitWait();
              _grabInput();
            },
            child: Text(_tr('cli.limitStopWait', 'Stop waiting'),
                style: const TextStyle(fontSize: 11)),
          ),
        ]),
        // ── 返事の途中で切れた時 (= ユーザー要望: 「続けて」 と再開を促す) ──
        //    時刻が来たら自分で送るが、 送る事と取り消し方をここに出しておく。
        if (_s.needsResumeWord)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              const Icon(Icons.subdirectory_arrow_right_rounded,
                  size: 13, color: Color(0xFF80CBC4)),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                    _tr('cli.limitResumePending',
                            'The reply was cut off. "{word}" will be sent once the limit lifts.')
                        .replaceFirst('{word}', _s.resumeWord),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Color(0xFF9FD8D0),
                        fontSize: 10.5,
                        height: 1.4)),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(_s.dropResumeWord),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text(_tr('cli.limitResumeCancel', 'Do not send it'),
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 10.5)),
                ),
              ),
            ]),
          ),
      ]),
    );
  }

  // ── 起こせなかった時の帯 (= ユーザー報告: 「ターミナルボタンを押すと
  //    セキュリティソフトにブロックされてアプリが落ちてしまう」) ──
  //
  //   落とさずに、 枠の中に赤い字で理由を出す。 「もう一度」 で同じ物を
  //   組み直せる。
  Widget _buildLaunchErrorBar(BuildContext context) {
    // ★ この帯だけが唯一の provider 頼み。 失敗を伝える為の帯が、
    //   置き場所の都合で自分から落ちては本末転倒なので、 見つからない時は
    //   英語の素文に落とす (= この widget は元々 provider 無しで使えた)。
    MindMapProvider? provider;
    try {
      provider = context.read<MindMapProvider>();
    } catch (_) {
      provider = null;
    }
    String tr(String key, String fallback) => provider?.t(key) ?? fallback;
    // ★ 「何も出さないまま、 起動直後に終わった」 だけは言い切らない。
    //   出力と終了は別の口から届くので取りこぼしの目もあるし、 引数の誤りや
    //   ログイン切れでも同じ形になる (= セキュリティソフトのせいだと
    //   決めつけると、 直し先を間違わせる)。
    final early = _s.launchDiedEarly;
    final title = early
        ? tr('cli.launchDiedEarly', 'It exited right after starting')
        : tr('cli.launchFailed', 'Could not start the terminal');
    final hint = early
        ? tr('cli.launchDiedEarlyHint',
            'It ended without printing anything. Security software may have '
                'blocked it, but a wrong argument or an expired login can do '
                'the same.')
        : tr('cli.launchBlockedHint',
            'Security software may have blocked it. Check your exclusion '
                'settings.');
    return Container(
      width: double.infinity,
      color: const Color(0xFF3B1F1F),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.report_gmailerrorred_rounded,
            size: 16, color: Color(0xFFFF8A80)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    color: Color(0xFFFF8A80),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    height: 1.5)),
            const SizedBox(height: 2),
            SelectableText(_s.launchError ?? '',
                style: const TextStyle(
                    color: Color(0xFFFFC1BC), fontSize: 11, height: 1.5)),
            const SizedBox(height: 2),
            Text(hint,
                style: const TextStyle(
                    color: Color(0xFFE0A0A0), fontSize: 10.5, height: 1.5)),
          ]),
        ),
        const SizedBox(width: 6),
        TextButton.icon(
          onPressed: () {
            // ★ 外が「もう一度」 を持っている時はそちらへ (新しい 1 回分を
            //   組み直してくれる)。 無い時はこの実行をそのまま起こし直す。
            final again = widget.onRunAgain;
            if (again != null) {
              again();
              return;
            }
            _s.retry();
            if (mounted) setState(() {});
          },
          icon: const Icon(Icons.refresh_rounded,
              size: 15, color: Color(0xFFFFC1BC)),
          label: Text(tr('cli.launchRetry', 'Try again'),
              style: const TextStyle(color: Color(0xFFFFC1BC), fontSize: 11)),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = _s.running;
    final slash = _s.supportsSlashCommands;
    // ★ 順番待ちは Claude Code と Gemini CLI に出す
    //   (= ユーザー要望「ClaudeCode や GeminiCLI においてはキューで処理後に
    //   投げる処理を貯めておくことができない」)。
    //   Codex は Tab で自前の順番待ちを持っているので出さない。
    //   Claude Code も溜めてはくれるが、 溜めた物を**道具の切れ目で今の
    //   返事に割り込ませる**ので、 「処理が終わった後に渡す」 にはならない。
    // ★ = ユーザー要望「アプリ側で実装するように」。 キューへ切り替えられる
    //   ようになったので、 溜めた物を見る帯はどの CLI でも出す。
    final wantQueue = slash;
    // ★ この端末のどこかが押されたら、 また打てるように戻す
    //   (= ユーザー報告: 画面を動かしたり他の要素を編集すると
    //   プロンプト欄に入れられなくなる)。
    //   隠し入力欄の onTapOutside は「焦点がある間」しか登録されず、
    //   xterm の onTapUp は向こう側の配線違いで呼ばれないので、
    //   「戻ってきた」 を拾える口がどこにも無かった。
    //   Listener は押下の取り合いに参加しないので、 ボタンや
    //   帯を掴む操作を邪魔しない。
    // ★ 与えられた高さを測る (= 順番待ちの帯が、 狭いペインで端末を
    //   0 まで押し潰さないようにするため)。 決まっていない時は 0。
    return LayoutBuilder(builder: (lctx, lc) {
      final double paneH = lc.maxHeight.isFinite ? lc.maxHeight : 0.0;
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
      // ★ 起こせなかった時は、 終了の帯ではなく赤い理由と「もう一度」 を出す。
      if (!running && _s.launchFailed) _buildLaunchErrorBar(context),
      if (!running && !_s.launchFailed)
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
              // ★ 右クリックは端末自身が使っていないので、 ここで受ける
              //   (= ユーザー要望「codexCLI の本文中で右クリックすることは
              //   無いから、 画面分割や新規タブ作成などの項目を出すように
              //   割り当てられないか」)。 包む形にすると、 中の端末が先に
              //   当たり判定を取り、 左クリックや文字選びは今までどおり
              //   端末が受ける。 右ボタンは誰も名乗り出ないのでここへ来る。
              final body = Stack(key: _stackKey, children: [
                Positioned.fill(
                  // ★ 掴んで動かせる棒を出す (= ユーザー要望: 画面の外へ
                  //   流れた会話を遡りたい)。 ホイールでも遡れる。
                  child: Scrollbar(
                    controller: _scroll,
                    // ★ 棒は**動かしている時だけ**出す (= ユーザー要望: 常に
                    //   出ていると邪魔)。 false にすると、 巻き上げている間
                    //   だけ浮かび上がり、 手を止めて少し経つと消える
                    //   (Flutter が ScrollUpdateNotification で浮かせ、
                    //   ScrollEndNotification から timeToFade 後に消す)。
                    // ★ アプリ全体の既定 (main.dart の
                    //   `_autoHideScrollbarTheme`) も「動かす時とホバー中
                    //   だけ」 なので、 この上書きを外すと揃う。
                    // ★ 出力が流れている間は光らない。 下端への追従は xterm が
                    //   `_offset.correctBy` で行い、 これは通知を出さない。
                    // ★ 透明な間でも、 棒が有るはずの帯にマウスを乗せれば
                    //   浮かび上がる (RawScrollbar.handleHover)。 だから
                    //   掴んで動かす道 (interactive) は残る。
                    thumbVisibility: false,
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
                //    ★ 場所だけをここで受け取る。 端末の側は組み直さない
                //      (= ユーザー報告: 欄が点滅する)。
                ValueListenableBuilder<Offset?>(
                  valueListenable: _cursorPosVn,
                  builder: (_, cpos, child) => Positioned(
                    left: (cpos?.dx ?? 10.0).clamp(
                        0.0, (cons.maxWidth - inputW).clamp(0.0, 4000.0)),
                    top: (cpos?.dy ?? (cons.maxHeight - 24))
                        .clamp(0.0, (cons.maxHeight - 18).clamp(0.0, 4000.0)),
                    child: child!,
                  ),
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
                // ── 最新へ戻る (自分で遡っている間だけ出す) ──
                if (_showJumpLatest)
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
                // ── 押せる URL の下線 (指している間だけ) ──
                //    ★ = ユーザー要望「codexCLI 等で出力されてハイパーリンクを
                //      クリックしたらそのURL先に飛べるようにして欲しい」。
                //    ★ 端末そのものは組み直さない (= 点滅対策)。 場所を見て
                //      出し入れするのはこの札だけ。
                //    ★ `opaque: false` にすると、 この札は「指の形」 を決める
                //      列には並ぶが**当たり判定は素通り**するので、 下の端末が
                //      今までどおり押下・文字選び (掘って選ぶ) を受け取る。
                //      (Flutter 本体 `RenderMouseRegion.hitTest` が
                //       `super.hitTest(...) && _opaque` = 列には足すが false を
                //       返す作りになっているため。)
                //    ★ 何も指していない時も **Positioned のまま** 0 の大きさで
                //      置く。 Positioned でない子を Stack に混ぜると、 Stack の
                //      大きさがその子に引っぱられてしまう。
                ValueListenableBuilder<Rect?>(
                  valueListenable: _linkRectVn,
                  builder: (_, r, __) => Positioned(
                    left: r?.left ?? 0.0,
                    top: r?.top ?? 0.0,
                    width: r?.width ?? 0.0,
                    height: r?.height ?? 0.0,
                    child: r == null
                        ? const SizedBox.shrink()
                        : MouseRegion(
                            opaque: false,
                            cursor: SystemMouseCursors.click,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                // ★ コマンドは URL と見分けが付くように、
                                //   緑の太い下線 + 薄い敷きにする
                                //   (押すと「走らせる」 = 重い方だから)。
                                color: _linkIsCmd
                                    ? const Color(0x269CCC65)
                                    : null,
                                border: Border(
                                  bottom: BorderSide(
                                      color: _linkIsCmd
                                          ? const Color(0xFF9CCC65)
                                          : const Color(0xFF8AB4F8),
                                      width: _linkIsCmd ? 2 : 1),
                                ),
                              ),
                              child: const SizedBox.expand(),
                            ),
                          ),
                  ),
                ),
              ]);
              final cb = widget.onContextMenu;
              // ★ 実機で確かめたら **GestureDetector では出なかった**。
              //   端末 (xterm) が自前の判定を持っていて、 押した瞬間に
              //   ジェスチャーの取り合いへ入るため、 こちらの「右で叩いた」
              //   は勝てずに捨てられていた。 [Listener] は取り合いに参加
              //   しないので、 押した事だけは必ず届く。 右ボタンの時だけ
              //   拾い、 左は今までどおり端末が使う。
              // ★ 左ボタンは URL を開くためだけに見る (= ユーザー要望:
              //   出力の中のハイパーリンクを押したら飛べるように)。 ここも
              //   取り合いには入らないので、 掘って文字を選ぶ・二度叩きで
              //   単語を選ぶ・長押しといった端末側の操作は今までどおり動く。
              //   「押して離すまで動いていない」 時だけ URL を探し、 文字を
              //   選んだままの 1 回目は「選びを消す」 だけにする
              //   (端末側が押下で選びを外すため)。
              // ★ 右クリック一覧が無い呼び出し側 (帯なしの埋め込み) でも
              //   URL は押せるようにしたいので、 `cb == null` でも敷く。
              return MouseRegion(
                onExit: (_) => _linkRectVn.value = null,
                child: Listener(
                  behavior: HitTestBehavior.deferToChild,
                  onPointerHover: _onTermHover,
                  onPointerDown: (e) {
                    _linkDownAt = null;
                    if (e.kind == PointerDeviceKind.mouse) {
                      if (e.buttons == kSecondaryMouseButton) {
                        cb?.call(e.position);
                        return;
                      }
                      if (e.buttons != kPrimaryMouseButton) return;
                    }
                    if (_termController.selection != null) return;
                    _linkDownAt = e.position;
                    _linkDownMs = DateTime.now().millisecondsSinceEpoch;
                  },
                  onPointerUp: (e) {
                    final down = _linkDownAt;
                    _linkDownAt = null;
                    if (down == null) return;
                    if ((e.position - down).distance > 6) return;
                    if (DateTime.now().millisecondsSinceEpoch - _linkDownMs >
                        700) {
                      return;
                    }
                    unawaited(_openLinkAt(e.position));
                  },
                  onPointerCancel: (_) => _linkDownAt = null,
                  child: body,
                ),
              );
            }),
          ),
        ),
      ),
      // ── いまの会話で投げた指示 (= ユーザー要望: 現在の会話履歴) ──
      if (_histOpen && running) _buildHistoryPanel(),
      // ── 順番待ちの欄 (= ユーザー要望: キュー) ──
      if (_queueOpen && running) _buildQueueBar(paneH),
      // ── 上限が解けるのを待っている時の帯 (= ユーザー要望: 予約の代わり) ──
      if (running && _s.limitWaiting) _buildLimitWaitBar(),
      // ── 下の帯 ──
      Container(
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 6),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Colors.white12)),
        ),
        child: Row(children: [
          // ★ 幅が足りない時は横に流す (ボタンが増えてもはみ出さない)。
          //   ★ = ユーザー要望「下の項目が入らない場合は左右スクロール
          //   方式に」。 流れることは流れていたが、 マウスで動かす手が
          //   無かったので、 ホイールを横へ振り向け、 掘んでも動かせるようにし、
          //   細い帯を出して「まだ先がある」と分かるようにした。
          Expanded(
            child: Listener(
              onPointerSignal: (e) {
                if (e is! PointerScrollEvent) return;
                if (!_bottomBarScroll.hasClients) return;
                final d = e.scrollDelta.dy.abs() > e.scrollDelta.dx.abs()
                    ? e.scrollDelta.dy
                    : e.scrollDelta.dx;
                final pos = _bottomBarScroll.position;
                _bottomBarScroll.jumpTo(
                    (pos.pixels + d).clamp(0.0, pos.maxScrollExtent));
              },
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                  },
                  scrollbars: false,
                ),
                child: Scrollbar(
                  controller: _bottomBarScroll,
                  thickness: 3,
                  child: SingleChildScrollView(
                    controller: _bottomBarScroll,
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                if (slash) ...[
                  _cmdButton(
                      label: 'モデル',
                      icon: Icons.memory_rounded,
                      tip: 'モデルを選び直す (/model)',
                      command: '/model',
                      enabled: running),
                  // ★ = ユーザー要望「codexCLI ではモデル選択後に推論レベルの
                  //   設定項目が出てくるから推論って項目は要らない」。
                  if (_s.cliKey != 'codex')
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
                  // ── 画像や文書を渡す (= ユーザー要望「CLI に画像や
                  //    文書ファイルを渡せるようにして欲しい」) ──
                  //    ★ CLI は**道筋で**ファイルを受け取る (画像も同じ)。
                  //      選んだ物の道筋を、 打ちかけの文の所へ差し込むだけに
                  //      する (送らない)。 続けて「これを要約して」 などと
                  //      書き足してから Enter を押せる。
                  //    ★ 空白を含む道筋があるので必ず引用符で包む。
                  if (_s.supportsSlashCommands)
                    _panelButton(
                      label: 'ファイル',
                      icon: Icons.attach_file_rounded,
                      tip: '画像や文書を選んで、 その道筋を打ちかけの文へ'
                          '差し込みます (送信はしません)',
                      open: false,
                      color: const Color(0xFF4FC3F7),
                      enabled: running,
                      onTap: _pickFilesForCli,
                    ),
                  // ── 打ちかけの行を全消し (= ユーザー要望) ──
                  _panelButton(
                    label: 'クリア',
                    icon: Icons.backspace_outlined,
                    tip: '打ちかけの行を全部消します (^U と同じ)。 '
                        '端末では Ctrl+A は「行頭へ移動」 なので、 '
                        '全消しはこちらから',
                    open: false,
                    color: const Color(0xFFB0BEC5),
                    enabled: running,
                    onTap: _clearInputLine,
                  ),
                  // ── キュー / ステアの切り替え ──
                  //    ★ = ユーザー要望「キュー/ステアのボタンを押しても何も
                  //      起こらないからちゃんと切り替わるように。 claudecode
                  //      などプロバイダー側にその機能がないのであれば
                  //      アプリ側で実装するように」。 codex へ Tab を送る
                  //      だけだったのをやめ、 **アプリ側の状態**にした
                  //      ([AgentCliSession.queueMode])。 どの CLI でも効く。
                  if (slash)
                    _panelButton(
                      label: _s.queueMode ? 'キュー' : 'ステア',
                      icon: _s.queueMode
                          ? Icons.playlist_add_check_rounded
                          : Icons.bolt_rounded,
                      tip: _s.queueMode
                          ? '今は「キュー」。 Enter で送った文は順番待ちへ溜まり、 '
                              '考え終わってから渡します。 押すと「ステア」 に戻ります'
                          : '今は「ステア」。 Enter でその場で割り込みます。 '
                              '押すと「キュー」 (考え終わってから渡す) に変わります',
                      open: _s.queueMode,
                      color: const Color(0xFFFFB347),
                      enabled: running,
                      onTap: () {
                        _s.queueMode = !_s.queueMode;
                        setState(() {});
                        _grabInput();
                      },
                    ),
                  // ── 順番待ち (= ユーザー要望: 100 件まで貯めておける) ──
                  //    ★ 上限に当たったら、 ここに溜めた分は消さずに
                  //      解けるまで待ってから渡る (上の帯に様子が出る)。
                  if (wantQueue)
                    _panelButton(
                      label: _s.queuedCount == 0
                          ? 'キュー'
                          : 'キュー ${_s.queuedCount}',
                      icon: Icons.playlist_add_rounded,
                      tip: '処理が終わってから渡す指示を溜めておく '
                          '(${AgentCliSession.kMaxQueued} 件まで)。 '
                          'プランの上限に当たった時は、 解けるまで待ってから渡します',
                      open: _queueOpen,
                      color: const Color(0xFFFFB347),
                      enabled: running,
                      onTap: () {
                        setState(() => _queueOpen = !_queueOpen);
                        if (!_queueOpen) _grabInput();
                      },
                    ),
                ],
              ]),
                  ),
                ),
              ),
            ),
          ),
          // ── 立ち上がっている最中は「起動中」 とだけ出す
          //    (= ユーザー要望: CodexCLI が立ち上がるタイミングでも
          //    「停止」 が出るのはおかしい)。 まだ止める処理が無いため。 ──
          if (running && _s.starting)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: Color(0xFF8AA0C0))),
                SizedBox(width: 6),
                Text('起動中',
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
              ]),
            ),
          // ── 処理を止める (= ユーザー要望: 処理が始まったら出す) ──
          //    CLI そのものは閉じない。 どの CLI も走っている処理を
          //    打ち切るのは Esc なので、 それを送るだけ。
          //    「終了」 (右) は CLI ごと閉じるボタンで、 別物。
          if (running && _s.busyForUi)
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
    });
  }
}
