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
import 'dart:io' show Platform, Process, ProcessResult;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/mind_map_provider.dart';
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
        'text': text,
        'selector': selector,
        'submit': submit,
        if (kind == WebAutoKind.loop)
          'children': children.map((e) => e.toJson()).toList(),
      };

  static WebAutoStep fromJson(Map<String, dynamic> j) => WebAutoStep(
        kind: WebAutoKind.values.firstWhere(
          (e) => e.name == (j['kind'] as String? ?? 'tap'),
          orElse: () => WebAutoKind.tap,
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

  /// ユーザーにページ上の 1 点をクリックしてもらい、 その座標を返す。
  final Future<Offset?> Function() pickPoint;

  /// 2 点 (矩形) をクリックしてもらう (= 「ここからここまで」)。
  final Future<Rect?> Function() pickRect;

  final VoidCallback onClose;

  /// 実行状態が変わった時に呼ばれる (running, 停止関数)。 親 (フローティング
  /// 窓) が実行中はヘッダーに停止ボタンだけを出すために使う (= ユーザー要望)。
  final void Function(bool running, VoidCallback stop)? onRunningChanged;

  /// 操作の記録モードの ON/OFF をホストへ伝える (= ユーザー要望: フローを
  /// 組まなくても操作を覚えて再現できるように)。 ON の間、 ホストは
  /// WebView 上のタップを [WebAutomationPanelController.recordTap] へ流す。
  final void Function(bool recording)? onRecordingChanged;
  const WebAutomationPanel({
    super.key,
    required this.exec,
    required this.capture,
    required this.pickPoint,
    required this.pickRect,
    required this.onClose,
    this.evalJs,
    this.onRunningChanged,
    this.onRecordingChanged,
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

  @override
  void initState() {
    super.initState();
    _load();
    _loadFlows();
    // 前に使った指示 (= ユーザー要望: 呼び出せるように)。
    // ignore: discarded_futures
    _loadAiPrompts();
    // 外向けの設定 (時刻で実行 / コマンドの許可) を読む (= ユーザー要望)。
    // ignore: discarded_futures
    _loadCmdPolicy();
    // ignore: discarded_futures
    _loadSchedule();
    // Esc / Ctrl+C を横取りして「止める」 に使う (= ユーザー要望:
    // Esc で欄が閉じるのをやめ、 実行を止める側に割り当てる)。
    HardwareKeyboard.instance.addHandler(_handleStopKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleStopKey);
    _schedTimer?.cancel();
    _aiCtrl.dispose();
    super.dispose();
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

  /// 今の手順に名前を付けて保存する。
  Future<void> _saveFlowAs(MindMapProvider provider) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
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
    final sel = await showDialog<String>(
      context: context,
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

  /// AI 入力欄を開いているか (= ユーザー要望: 画面中央のダイアログではなく
  /// 自動操作の設定画面の上に出す)。
  bool _aiFormOpen = false;
  final TextEditingController _aiCtrl = TextEditingController();

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
    final ev = widget.evalJs;
    if (ev == null) return '';
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
      final r = await ev(js);
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
 {"kind":"scroll","scrollDir":"down","count":3,"intervalMs":400},
 {"kind":"wait","durationMs":1000},
 {"kind":"type","text":"入力する文字","selector":"","submit":true},
 {"kind":"shot","count":1},
 {"kind":"tap","x":0,"y":0,"count":1,"intervalMs":200},
 {"kind":"loop","count":5,"children":[{"kind":"scroll","scrollDir":"down","count":1},{"kind":"shot","count":1}]}
]}

ルール:
- kind は open / click / scrollTo / scroll / wait / shot / type / tap /
  hold / swipe / loop / openExternal / command のみ。
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
- 「上から下まで全部撮って」 の類だけ、 loop(children: scroll(down) + shot) を
  count 8〜12 で使う。
- open は「そのページを開く」。 text に URL、 durationMs に読み込み待ち (ms)。
- scrollDir は down / up / right / left (scrollTo では bottom / top)。
- steps は 30 個以内。''';

  /// 入力欄の中身で組み立てる。 呼ぶ前に欄は閉じる。
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
      final steps = [
        for (final j in list)
          if (j is Map) WebAutoStep.fromJson(Map<String, dynamic>.from(j)),
      ];
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

  /// 画面を見ながら、 1 手ずつ考えて実行する。
  ///
  /// 先に全部組み立てる「フロー作成」 と違い、 毎回いまの画面を見てから
  /// 次の 1 手を決めるので、 「フッターまで行けたか」「タブが切り替わったか」
  /// を確かめながら進められる。 やった手順はフローとして残るので、 後から
  /// 手直しして繰り返し実行できる。
  Future<void> _runAgent(MindMapProvider provider, String request) async {
    final req = request.trim();
    if (req.isEmpty || !mounted || _agentBusy) return;
    setState(() {
      _agentBusy = true;
      _agentStop = false;
      _steps.clear();
      _status = provider.t('agent.thinking');
    });
    final done = <String>[];
    try {
      // 手数の上限。 止まらなくなるのを防ぐ。
      for (var turn = 0; turn < 12; turn++) {
        if (_agentStop || !mounted) break;
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
${snap.isEmpty ? '(画面の中身を読めませんでした)' : snap}

【ここまでにやったこと】
${done.isEmpty ? '(まだ何もしていません)' : done.join('\n')}

依頼: $req''';
        final out = (await provider.askAi(prompt)).trim();
        if (_agentStop || !mounted) break;
        var body = out;
        final fence = RegExp(r'```[a-zA-Z]*\s*\n([\s\S]*?)\n?```');
        final fm = fence.firstMatch(body);
        if (fm != null) body = fm.group(1) ?? body;
        final s = body.indexOf('{');
        final e = body.lastIndexOf('}');
        if (s < 0 || e <= s) break;
        final m = jsonDecode(body.substring(s, e + 1));
        if (m is! Map) break;
        if (m['done'] == true) {
          if (mounted) setState(() => _status = provider.t('agent.done'));
          break;
        }
        final list = m['steps'];
        if (list is! List || list.isEmpty) break;
        final steps = <WebAutoStep>[
          for (final j in list)
            if (j is Map) WebAutoStep.fromJson(Map<String, dynamic>.from(j)),
        ];
        if (steps.isEmpty) break;
        if (!mounted) return;
        // 実行した手順はフローに積んでいく (後で使い回せるように)。
        setState(() {
          _steps.addAll(steps);
          _status = provider
              .t('agent.step')
              .replaceFirst('{n}', '${turn + 1}');
        });
        for (final st in steps) {
          if (_agentStop) break;
          done.add('- ${st.kind.name}'
              '${st.text.isEmpty ? '' : ' "${st.text}"'}'
              '${st.scrollDir.isEmpty ? '' : ' ${st.scrollDir}'}');
        }
        await _runSteps(steps, provider.t('agent.label'));
        await _save();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e'.replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) {
        setState(() {
          _agentBusy = false;
          _agentStop = false;
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
    await widget.exec(_pointerJs('pointerdown', x, y));
    await widget.exec(_mouseJs('mousedown', x, y));
    await Future.delayed(const Duration(milliseconds: 40));
    await widget.exec(_pointerJs('pointerup', x, y, buttons: 0));
    await widget.exec(_mouseJs('mouseup', x, y, buttons: 0));
    await widget.exec(_mouseJs('click', x, y, buttons: 0));
    // 注: 以前はここで el.click() も呼んでいたが、 合成 click と二重に
    //     発火してリンクが 2 回開く等の症状が出ていた (= ユーザー報告:
    //     何故か 2 回繰り返される)。 実際のタップと同じく合成イベントの
    //     系列だけを送る。
  }

  Future<void> _holdAt(double x, double y, int ms) async {
    await widget.exec(_pointerJs('pointerdown', x, y));
    await widget.exec(_mouseJs('mousedown', x, y));
    await Future.delayed(Duration(milliseconds: ms));
    await widget.exec(_pointerJs('pointerup', x, y, buttons: 0));
    await widget.exec(_mouseJs('mouseup', x, y, buttons: 0));
  }

  Future<void> _swipe(
      double x1, double y1, double x2, double y2, int ms) async {
    const frames = 12;
    await widget.exec(_pointerJs('pointerdown', x1, y1));
    await widget.exec(_mouseJs('mousedown', x1, y1));
    for (var i = 1; i <= frames; i++) {
      if (_cancel) break;
      final t = i / frames;
      final x = x1 + (x2 - x1) * t;
      final y = y1 + (y2 - y1) * t;
      await widget.exec(_pointerJs('pointermove', x, y));
      await widget.exec(_mouseJs('mousemove', x, y));
      await Future.delayed(Duration(milliseconds: (ms / frames).round()));
    }
    await widget.exec(_pointerJs('pointerup', x2, y2, buttons: 0));
    await widget.exec(_mouseJs('mouseup', x2, y2, buttons: 0));
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
  Future<void> _runSteps(List<WebAutoStep> steps, String path) async {
    for (var i = 0; i < steps.length; i++) {
      if (_cancel) return;
      final s = steps[i];
      final label = path.isEmpty ? '${i + 1}' : '$path-${i + 1}';
      if (mounted) {
        setState(() => _status = '$_lapLabel · $label');
      }
      switch (s.kind) {
        case WebAutoKind.loop:
          // 回数 0 = 停止するまで無限に回す (= while)。
          if (s.count <= 0) {
            while (!_cancel) {
              await _runSteps(s.children, label);
            }
          } else {
            for (var c = 0; c < s.count; c++) {
              if (_cancel) return;
              await _runSteps(s.children, label);
            }
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
          // 方向に応じて縦横 / 正負を決める (= ユーザー要望)。
          final amount = s.durationMs;
          final dx = s.scrollDir == 'right'
              ? amount
              : (s.scrollDir == 'left' ? -amount : 0);
          final dy = s.scrollDir == 'down'
              ? amount
              : (s.scrollDir == 'up' ? -amount : 0);
          for (var c = 0; c < (s.count <= 0 ? 1 : s.count); c++) {
            if (_cancel) return;
            await widget.exec(
                'window.scrollBy({top:$dy,left:$dx,behavior:"smooth"});');
            await Future.delayed(_intervalOf(s));
          }
          break;
        case WebAutoKind.type:
          for (var c = 0; c < (s.count <= 0 ? 1 : s.count); c++) {
            if (_cancel) return;
            await widget.exec(_typeJs(s));
            await Future.delayed(_intervalOf(s));
          }
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
            await widget.exec('location.href = ${jsonEncode(u)};');
            // 読み込みを待つ。 durationMs を待ち時間として使う (既定 2 秒)。
            final waitMs = s.durationMs <= 0 ? 2000 : s.durationMs;
            await Future.delayed(Duration(milliseconds: waitMs));
          }
          break;
        case WebAutoKind.click:
          // ── 文字 / セレクタで要素を探して押す (= 座標に頼らない) ──
          for (var c = 0; c < (s.count <= 0 ? 1 : s.count); c++) {
            if (_cancel) return;
            await widget.exec(_clickByJs(s.selector, s.text));
            // 押した先が別ページなら読み込みを待つ。
            await Future.delayed(Duration(
                milliseconds: s.durationMs <= 0 ? 800 : s.durationMs));
          }
          break;
        case WebAutoKind.scrollTo:
          // ── 一番下 / 一番上まで送る (= フッターの撮影を確実にする) ──
          {
            final toTop = s.scrollDir == 'top' || s.scrollDir == 'up';
            await widget.exec(toTop
                ? 'window.scrollTo({top:0,behavior:"smooth"});'
                : 'window.scrollTo({top:document.body.scrollHeight,'
                    'behavior:"smooth"});');
            // 遅延読み込みの絵が出るまで少し待つ。
            await Future.delayed(Duration(
                milliseconds: s.durationMs <= 0 ? 1200 : s.durationMs));
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
          final region = (s.x2 - s.x).abs() > 4 && (s.y2 - s.y).abs() > 4
              ? Rect.fromLTRB(s.x, s.y, s.x2, s.y2)
              : null;
          for (var c = 0; c < s.count; c++) {
            if (_cancel) return;
            final shot = await widget.capture(region);
            if (shot != null) _shots++;
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

  /// コマンドを 1 つ実行する。 実行した (もしくは黙って飛ばした) なら true、
  /// ユーザーが断った / 危ないので止めた なら false。
  Future<bool> _runCommandStep(WebAutoStep s) async {
    final cmd = s.text.trim();
    if (cmd.isEmpty) return true;
    if (!_isDesktopHost) {
      if (mounted) setState(() => _status = 'コマンド実行はパソコン版だけです');
      return false;
    }
    if (_cmdPolicy == AutoCommandPolicy.off) {
      if (mounted) {
        setState(() => _status = 'コマンド実行は「使わない」 設定です (上の設定で変えられます)');
      }
      return false;
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

  Future<bool?> _confirmCommand(String cmd) {
    return showDialog<bool>(
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
  static const String _kSchedPrefsKey = 'automationSchedule_v1';
  bool _schedOn = false;
  int _schedHour = 9;
  int _schedMin = 0;
  bool _schedDaily = true;
  Timer? _schedTimer;

  /// 同じ分の中で二重に走らせないための控え。
  String _lastFiredKey = '';

  Future<void> _loadSchedule() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kSchedPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map || !mounted) return;
      setState(() {
        _schedOn = m['on'] == true;
        _schedHour = (m['h'] as num?)?.toInt().clamp(0, 23) ?? 9;
        _schedMin = (m['m'] as num?)?.toInt().clamp(0, 59) ?? 0;
        _schedDaily = m['daily'] != false;
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
            'h': _schedHour,
            'm': _schedMin,
            'daily': _schedDaily,
          }));
    } catch (_) {}
  }

  void _restartScheduleTimer() {
    _schedTimer?.cancel();
    if (!_schedOn) return;
    // 20 秒ごとに時刻を見て、 指定の分に入ったら 1 回だけ走らせる。
    _schedTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted || _running) return;
      final now = DateTime.now();
      if (now.hour != _schedHour || now.minute != _schedMin) return;
      final key = '${now.year}-${now.month}-${now.day} $_schedHour:$_schedMin';
      if (_lastFiredKey == key) return;
      _lastFiredKey = key;
      final provider = context.read<MindMapProvider>();
      unawaited(_run(provider).then((_) {
        if (!_schedDaily && mounted) {
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
      WebAutoKind.click,
      WebAutoKind.scrollTo,
    };
    // 手順のどこかで「リンクを開く」 があるなら、 その後は開いている。
    for (final s in _steps) {
      if (s.kind == WebAutoKind.open) return false;
      if (s.kind == WebAutoKind.loop) {
        for (final c in s.children) {
          if (c.kind == WebAutoKind.open) return false;
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
    if (_running || _steps.isEmpty) return;
    setState(() {
      _running = true;
      _cancel = false;
      _shots = 0;
      _status = '';
    });
    widget.onRunningChanged?.call(true, _requestStop);
    try {
      for (var lap = 0; lap < _loop; lap++) {
        if (_cancel) break;
        _lapLabel = '${lap + 1}/$_loop';
        await _runSteps(_steps, '');
      }
    } finally {
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

  /// 「時刻で実行」 と「コマンドの許可」 の行 (= ユーザー要望)。
  ///
  /// どちらもパソコン版だけ。 コマンドは既定で「使わない」 にしてあり、
  /// ユーザーが自分で切り替えるまでは動かない。
  Widget _buildOutsideRow(MindMapProvider provider) {
    if (!_isDesktopHost) return const SizedBox.shrink();
    String two(int v) => v.toString().padLeft(2, '0');
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
              // ── 時刻で実行 ──
              // ★ 切っているのに時刻 (9:00 など) が出ていると、 その時刻で
              //   動くように見える (= ユーザー指摘)。 スイッチを先に置き、
              //   時刻と「毎日」 は入れている間だけ出す。
              Row(children: [
                const Icon(Icons.schedule_rounded,
                    size: 15, color: Color(0xFF80CBC4)),
                const SizedBox(width: 6),
                const Text('時刻で実行',
                    style: TextStyle(color: Colors.white70, fontSize: 11.5)),
                const SizedBox(width: 8),
                Switch(
                  value: _schedOn,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) async {
                    setState(() => _schedOn = v);
                    await _saveSchedule();
                    _restartScheduleTimer();
                  },
                ),
                if (_schedOn) ...[
                  const SizedBox(width: 6),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 26),
                    ),
                    onPressed: () async {
                      final t = await showTimePicker(
                        context: context,
                        initialTime:
                            TimeOfDay(hour: _schedHour, minute: _schedMin),
                      );
                      if (t == null || !mounted) return;
                      setState(() {
                        _schedHour = t.hour;
                        _schedMin = t.minute;
                      });
                      await _saveSchedule();
                      _restartScheduleTimer();
                    },
                    child: Text('${two(_schedHour)}:${two(_schedMin)}',
                        style: const TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 2),
                  InkWell(
                    onTap: () async {
                      setState(() => _schedDaily = !_schedDaily);
                      await _saveSchedule();
                    },
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(
                          _schedDaily
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 15,
                          color: _schedDaily
                              ? const Color(0xFF80CBC4)
                              : Colors.white38),
                      const SizedBox(width: 3),
                      const Text('毎日',
                          style:
                              TextStyle(color: Colors.white60, fontSize: 11)),
                    ]),
                  ),
                ],
              ]),
              // ★ オフの時に「動かします」 とだけ書いてあると、 切っていても
              //   時刻で動くように読める (= ユーザー指摘)。 今どちらなのかを
              //   最初に書く。
              Padding(
                padding: const EdgeInsets.only(left: 21, bottom: 4),
                child: Text(
                    _schedOn
                        ? 'オン: この画面を開いている間、 '
                            '${two(_schedHour)}:${two(_schedMin)} に'
                            '${_schedDaily ? '毎日' : '1 回だけ'}手順を動かします。'
                        : 'オフ: 時刻では動きません。 '
                            'スイッチを入れると時刻を選べて、 '
                            'この画面を開いている間だけその時刻に動きます。',
                    style: TextStyle(
                        color: _schedOn
                            ? const Color(0xFF80CBC4)
                            : Colors.white38,
                        fontSize: 10)),
              ),
              const Divider(height: 8, color: Colors.white12),
              // ── コマンドの許可 ──
              Row(children: [
                const Icon(Icons.terminal_rounded,
                    size: 15, color: Color(0xFFFFB347)),
                const SizedBox(width: 6),
                const Text('コマンド実行',
                    style: TextStyle(color: Colors.white70, fontSize: 11.5)),
                const SizedBox(width: 8),
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
              Padding(
                padding: const EdgeInsets.only(left: 21, top: 2),
                child: Text(
                    _cmdPolicy == AutoCommandPolicy.off
                        ? 'いまは実行しません。 手順に入っていても飛ばします。'
                        : (_cmdPolicy == AutoCommandPolicy.ask
                            ? '実行のたびに中身を見せて確認します。'
                            : '確認なしで実行します。 壊す恐れのある操作だけは断ります。'),
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 10)),
              ),
            ]),
      ),
    );
  }

  /// 実行したコマンドの記録を見せる。
  void _showCmdLog() {
    showDialog<void>(
      context: context,
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

  /// 追加できる種類のチップ列。 [into] に追加する。
  Widget _addChips(MindMapProvider provider, List<WebAutoStep> into) {
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final k in WebAutoKind.values)
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
                              : (k == WebAutoKind.scrollTo ||
                                      k == WebAutoKind.click
                                  ? 1200
                                  : 400))),
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
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<MindMapProvider>();
    return Container(
      color: const Color(0xFF1B1B2A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_recording)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: const Color(0xFFE57373).withValues(alpha: 0.18),
              child: Text(provider.t('auto.recordHint'),
                  style: const TextStyle(
                      color: Color(0xFFFFCDD2), fontSize: 10.5, height: 1.35)),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            color: const Color(0xFF23233A),
            // ── 幅が狭い端末 (= モバイル) ではヘッダーのボタンが溢れるので、
            //    横スクロールできるようにする (= ユーザー要望: オーバーフロー
            //    してしまうので使いやすいサイズに)。 ──
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
              // ── AI でフロー作成 (= ユーザー要望: 指示を出すと AI が手順を
              //    組み立てる) ──
              if (!_running && !_recording && !_agentBusy)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFBA68C8),
                      side: const BorderSide(color: Color(0xFFBA68C8)),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 28),
                    ),
                    icon: _aiBusy
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation(
                                    Color(0xFFBA68C8))),
                          )
                        : const Icon(Icons.auto_awesome_rounded, size: 14),
                    label: Text(provider.t('auto.aiBuild'),
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w700)),
                    onPressed: _aiBusy
                        ? null
                        : () => setState(() => _aiFormOpen = !_aiFormOpen),
                  ),
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
              // 撮ったスクショの管理 (= ユーザー要望: どこにあるか分かり
              // にくい / PDF 前に編集・並べ替えしたい)
              if (!_running)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: provider.t('shots.title'),
                  icon: const Icon(Icons.photo_library_rounded,
                      size: 17, color: Color(0xFF80CBC4)),
                  onPressed: () => ShotManagerDialog.show(context),
                ),
              if (!_running)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded,
                      size: 17, color: Colors.white54),
                  onPressed: widget.onClose,
                ),
            ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Text(provider.t('auto.hint'),
                style: const TextStyle(color: Colors.white38, fontSize: 10.5)),
          ),
          _buildOutsideRow(provider),
          // ── AI でフローを作る入力欄 (= ユーザー要望: 画面中央のダイアログ
          //    ではなく、 自動操作の設定画面の上に出す) ──
          if (_aiFormOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFBA68C8).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: const Color(0xFFBA68C8).withValues(alpha: 0.5)),
                ),
                child: Column(children: [
                  TextField(
                    controller: _aiCtrl,
                    autofocus: true,
                    maxLines: 3,
                    minLines: 2,
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
                    onSubmitted: (v) {
                      _rememberAiPrompt(v);
                      setState(() => _aiFormOpen = false);
                      _aiBuildFlowFrom(provider, v);
                    },
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
                  const SizedBox(height: 6),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                      style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: Colors.white54),
                      onPressed: () => setState(() => _aiFormOpen = false),
                      child: Text(provider.t('common.cancel'),
                          style: const TextStyle(fontSize: 11.5)),
                    ),
                    const SizedBox(width: 6),
                    // ── 画面を見ながら 1 手ずつ進める (= ユーザー要望:
                    //    AI エージェントのように) ──
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF80CBC4),
                          side: const BorderSide(color: Color(0xFF80CBC4)),
                          visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.smart_toy_rounded, size: 14),
                      label: Text(provider.t('auto.agentRun'),
                          style: const TextStyle(fontSize: 11.5)),
                      onPressed: () {
                        final v = _aiCtrl.text;
                        _rememberAiPrompt(v);
                        setState(() => _aiFormOpen = false);
                        _runAgent(provider, v);
                      },
                    ),
                    const SizedBox(width: 6),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFBA68C8),
                          foregroundColor: Colors.white,
                          visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.auto_awesome_rounded, size: 14),
                      label: Text(provider.t('auto.aiBuild'),
                          style: const TextStyle(fontSize: 11.5)),
                      onPressed: () {
                        final v = _aiCtrl.text;
                        _rememberAiPrompt(v);
                        setState(() => _aiFormOpen = false);
                        _aiBuildFlowFrom(provider, v);
                      },
                    ),
                  ]),
                ]),
              ),
            ),
          // ステップ追加ボタン
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
          const SizedBox(height: 8),
          Expanded(
            child: _steps.isEmpty
                ? Center(
                    child: Text(provider.t('auto.empty'),
                        style: const TextStyle(
                            color: Colors.white24, fontSize: 11)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: _steps.length,
                    itemBuilder: (_, i) => _stepTile(provider, _steps, i),
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
        ],
      ),
    );
  }
}
