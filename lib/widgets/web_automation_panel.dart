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
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/mind_map_provider.dart';
import 'shot_manager_dialog.dart';

/// 1 ステップの種類。
enum WebAutoKind { tap, hold, swipe, scroll, wait, shot, type, loop }

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

  int _loop = 1;
  bool _running = false;
  String _status = '';
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadFlows();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_prefsKey);
      if (s == null || s.isEmpty) return;
      final m = jsonDecode(s) as Map<String, dynamic>;
      _loop = (m['loop'] as num?)?.toInt() ?? 1;
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
      'loop': _loop,
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
      _loop = (data['loop'] as num?)?.toInt() ?? 1;
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
            'loop': _loop,
            'steps': _steps.map((e) => e.toJson()).toList(),
          }));
    } catch (_) {}
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

  /// この 1 ステップだけを試しに動かす (= ユーザー要望: スワイプ等が
  /// ちゃんと効くか項目単体で試したい)。 繰り返しブロックなら中身を 1 周。
  Future<void> _testStep(MindMapProvider provider, WebAutoStep step) async {
    if (_running) return;
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

  Future<void> _run(MindMapProvider provider) async {
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
      case WebAutoKind.loop:
        return p.t('auto.kindLoop');
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
      case WebAutoKind.loop:
        return Icons.repeat_rounded;
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
                      : (k == WebAutoKind.wait ? 1000 : 400),
                )));
            _save();
          },
        ),
    ]);
  }

  /// 1 ステップのタイル。 繰り返しブロックは中に子ステップを並べる
  /// (= ユーザー要望: 繰り返しの中に処理ブロックを置き、 そこから出ると
  /// 繰り返し終了になるように = 開始 / 終了ボタンを 1 つに統合)。
  Widget _stepTile(MindMapProvider provider, List<WebAutoStep> list, int index,
      {String path = ''}) {
    final s = list[index];
    final isLoop = s.kind == WebAutoKind.loop;
    final label = path.isEmpty ? '${index + 1}' : '$path-${index + 1}';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(_kindIcon(s.kind),
                size: 15, color: const Color(0xFF80CBC4)),
            const SizedBox(width: 6),
            Text('$label. ${_kindLabel(provider, s.kind)}',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: isLoop ? FontWeight.w700 : FontWeight.w400)),
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
          // ステップ追加ボタン
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: _addChips(provider, _steps),
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
            child: Row(children: [
              _numField(provider.t('auto.loop'), _loop, (v) {
                _loop = v.clamp(1, 999);
              }, width: 72),
              const SizedBox(width: 8),
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
