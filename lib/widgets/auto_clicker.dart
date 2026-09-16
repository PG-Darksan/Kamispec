// オートクリッカー (= ユーザー要望:「画面タップなどの操作はオートクリッカー
// って名前でボタン項目として別で作って欲しい」)。
//
// 自動操作 (web_automation_panel) は「手順を組み立てて流す」 道具で、 その中に
// 画面を押す手順 (osClick) も入っている。 そちらは今までどおり使えるが、
// 「同じ所をひたすら押し続けたいだけ」 の時に手順を組むのは大げさなので、
// それだけを切り出した小さな道具をここに置く。
//
// 仕組みは自動操作と同じ [DesktopInput] (SendInput)。 押す先は
//   ・覚えた 1 点 (「位置を覚える」 で今のカーソルの所を控える)
//   ・今のカーソルの所 (動かさずにその場を押す)
// のどちらか。 止め方は画面のボタンと、 アプリの外にいても効く停止キー。
//
// ★ 走っている間だけ [DesktopInput.enabled] を立てる。 閉じた時・止めた時は
//   必ず false に戻す (= 押しっぱなしで放置しない)。
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../providers/mind_map_provider.dart';
import '../services/desktop_input.dart';
import '../services/rec_hotkey.dart';
import '../utils/build_flags.dart';

/// この道具を出してよい環境か。
///
/// ・Windows だけ (SendInput を使う)
/// ・ストア提出版では出さない (自動操作のコマンド実行と同じ理由)
bool get autoClickerSupported =>
    !kStoreBuild && DesktopInput.isSupported && Platform.isWindows;

/// 押す先の決め方。
enum AutoClickTarget {
  /// 覚えた 1 点を押す。
  fixedPoint,

  /// 今カーソルがある所を押す (マウスを動かさない)。
  cursor,
}

class AutoClickerView extends StatefulWidget {
  const AutoClickerView({
    super.key,
    required this.provider,
    this.onRequestClose,
  });

  final MindMapProvider provider;

  /// 閉じる時の処理 (道具窓・分割ペイン・ダイアログのどれでも使えるように、
  /// 閉じ方は呼んだ側に任せる)。 null なら閉じるボタンを出さない。
  final VoidCallback? onRequestClose;

  @override
  State<AutoClickerView> createState() => _AutoClickerViewState();
}

class _AutoClickerViewState extends State<AutoClickerView> {
  // ── 押し方 ──
  AutoClickTarget _target = AutoClickTarget.fixedPoint;
  int _x = 0;
  int _y = 0;
  MouseButton _button = MouseButton.left;

  /// 1 回の合図で何度押すか (2 = ダブルクリック)。
  int _clicksPerShot = 1;

  /// 間隔 (ミリ秒)。
  int _intervalMs = 1000;

  /// 何回で終わるか (0 = 止めるまでずっと)。
  int _repeat = 0;

  /// 始めるまでの待ち (秒)。 押したい窓を前に出す時間。
  int _startDelaySec = 3;

  // ── 走っている間の状態 ──
  Timer? _timer;
  Timer? _countdown;
  int _done = 0;
  int _waitLeft = 0;
  String _status = '';

  /// アプリの外にいても効く停止キー (F9 固定)。
  final RecStopHotkey _stopKey = RecStopHotkey.separate();
  static const int _kVkF9 = 0x78;

  bool get _running => _timer != null || _countdown != null;

  late final TextEditingController _xCtrl =
      TextEditingController(text: '$_x');
  late final TextEditingController _yCtrl =
      TextEditingController(text: '$_y');

  // ★ 数を入れる欄の controller は状態として持つ。 build の中で作ると
  //   打つたびに作り直され、 文字を 1 つ入れるたびに入力位置が先頭へ飛ぶ。
  late final TextEditingController _intervalCtrl =
      TextEditingController(text: '$_intervalMs');
  late final TextEditingController _repeatCtrl =
      TextEditingController(text: '$_repeat');
  late final TextEditingController _delayCtrl =
      TextEditingController(text: '$_startDelaySec');

  @override
  void initState() {
    super.initState();
    // 開いた時点のカーソル位置を初期値にしておく (= 何も決まっていない
    // 状態で 0,0 を押しに行かないように)。
    final p = DesktopInput.cursorPos();
    if (p != null) {
      _x = p.x;
      _y = p.y;
      _xCtrl.text = '$_x';
      _yCtrl.text = '$_y';
    }
    _stopKey.onPressed = () {
      if (_running) _stop(byHotkey: true);
    };
  }

  @override
  void dispose() {
    // ★ 閉じても押し続ける、 が一番危ない。 必ず全部畳む。
    _timer?.cancel();
    _countdown?.cancel();
    DesktopInput.enabled = false;
    unawaited(_stopKey.stop());
    _xCtrl.dispose();
    _yCtrl.dispose();
    _intervalCtrl.dispose();
    _repeatCtrl.dispose();
    _delayCtrl.dispose();
    super.dispose();
  }

  String _t(String key) => widget.provider.t(key);

  // ─── 位置を覚える ─────────────────────────────────────────────────────
  //
  // 画面全体を覆う板を出して 1 点を選ばせる事は出来ない (アプリの窓の外は
  // 触れない) ので、 「数えている間に置きたい所へカーソルを動かしてもらう」
  // 形にする。 自動操作の「位置を決める」 と同じ考え方。
  Timer? _pickTimer;
  int _pickLeft = 0;

  void _pickPoint() {
    if (_running) return;
    _pickTimer?.cancel();
    setState(() {
      _pickLeft = 3;
      _status = _t('autoClicker.pickHint').replaceFirst('{n}', '$_pickLeft');
    });
    _pickTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _pickLeft--;
        if (_pickLeft > 0) {
          _status =
              _t('autoClicker.pickHint').replaceFirst('{n}', '$_pickLeft');
          return;
        }
        t.cancel();
        _pickTimer = null;
        final p = DesktopInput.cursorPos();
        if (p != null) {
          _x = p.x;
          _y = p.y;
          _xCtrl.text = '$_x';
          _yCtrl.text = '$_y';
          _target = AutoClickTarget.fixedPoint;
          _status = _t('autoClicker.picked')
              .replaceFirst('{x}', '$_x')
              .replaceFirst('{y}', '$_y');
        } else {
          _status = _t('autoClicker.pickFailed');
        }
      });
    });
  }

  // ─── 開始 / 停止 ─────────────────────────────────────────────────────

  void _start() {
    if (_running) return;
    if (!autoClickerSupported) {
      setState(() => _status = _t('autoClicker.windowsOnly'));
      return;
    }
    _syncCoordsFromFields();
    _done = 0;
    _waitLeft = _startDelaySec;
    setState(() {
      _status = _waitLeft > 0
          ? _t('autoClicker.startingIn').replaceFirst('{n}', '$_waitLeft')
          : '';
    });
    // 止め方をアプリの外にも用意してから始める (= 押している間はアプリに
    // 戻れない事があるため)。
    unawaited(_stopKey.start(0, _kVkF9));
    if (_waitLeft <= 0) {
      _beginClicking();
      return;
    }
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      _waitLeft--;
      if (_waitLeft > 0) {
        setState(() => _status =
            _t('autoClicker.startingIn').replaceFirst('{n}', '$_waitLeft'));
        return;
      }
      t.cancel();
      _countdown = null;
      _beginClicking();
    });
  }

  void _beginClicking() {
    // 許しが出ている間だけ動かす (止めたら必ず閉じる)。
    DesktopInput.enabled = true;
    setState(() => _status = _t('autoClicker.running'));
    final period = Duration(milliseconds: _intervalMs.clamp(10, 600000));
    _timer = Timer.periodic(period, (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final ok = _clickOnce();
      _done++;
      if (!ok) {
        _stop();
        setState(() => _status = _t('autoClicker.failed'));
        return;
      }
      if (_repeat > 0 && _done >= _repeat) {
        _stop();
        setState(() => _status =
            _t('autoClicker.done').replaceFirst('{n}', '$_done'));
        return;
      }
      setState(() {});
    });
  }

  bool _clickOnce() {
    if (_target == AutoClickTarget.cursor) {
      final p = DesktopInput.cursorPos();
      if (p == null) return false;
      return DesktopInput.click(p.x, p.y,
          button: _button, count: _clicksPerShot);
    }
    return DesktopInput.click(_x, _y, button: _button, count: _clicksPerShot);
  }

  void _stop({bool byHotkey = false}) {
    _timer?.cancel();
    _timer = null;
    _countdown?.cancel();
    _countdown = null;
    DesktopInput.enabled = false;
    unawaited(_stopKey.stop());
    if (!mounted) return;
    setState(() {
      _status = byHotkey
          ? _t('autoClicker.stoppedByKey')
          : _t('autoClicker.stopped').replaceFirst('{n}', '$_done');
    });
  }

  void _syncCoordsFromFields() {
    _x = int.tryParse(_xCtrl.text.trim()) ?? _x;
    _y = int.tryParse(_yCtrl.text.trim()) ?? _y;
  }

  // ─── 見た目 ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    return Container(
      color: const Color(0xFF12121C),
      child: Column(children: [
        // 見出し
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.white12)),
          ),
          child: Row(children: [
            const Icon(Icons.ads_click_rounded,
                size: 18, color: Color(0xFF4DD0E1)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(p.t('hdr.autoClicker'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ),
            if (widget.onRequestClose != null)
              IconButton(
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 30),
                icon: const Icon(Icons.close_rounded,
                    size: 18, color: Colors.white54),
                onPressed: widget.onRequestClose,
              ),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: !autoClickerSupported
                ? Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: Text(p.t('autoClicker.windowsOnly'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _sectionTitle(p.t('autoClicker.whereTitle')),
                      _targetRow(p),
                      const SizedBox(height: 8),
                      _pointRow(p),
                      const SizedBox(height: 16),
                      _sectionTitle(p.t('autoClicker.howTitle')),
                      _buttonRow(p),
                      const SizedBox(height: 8),
                      _numberRow(
                        label: p.t('autoClicker.interval'),
                        controller: _intervalCtrl,
                        suffix: 'ms',
                        min: 10,
                        max: 600000,
                        onChanged: (v) => _intervalMs = v,
                      ),
                      _numberRow(
                        label: p.t('autoClicker.repeat'),
                        controller: _repeatCtrl,
                        suffix: p.t('autoClicker.timesUnit'),
                        min: 0,
                        max: 1000000,
                        hint: p.t('autoClicker.repeatZero'),
                        onChanged: (v) => _repeat = v,
                      ),
                      _numberRow(
                        label: p.t('autoClicker.startDelay'),
                        controller: _delayCtrl,
                        suffix: p.t('autoClicker.secUnit'),
                        min: 0,
                        max: 60,
                        onChanged: (v) => _startDelaySec = v,
                      ),
                      const SizedBox(height: 16),
                      _runRow(p),
                      if (_status.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(_status,
                            style: const TextStyle(
                                color: Color(0xFF9CCC65),
                                fontSize: 12,
                                height: 1.5)),
                      ],
                      if (_running) ...[
                        const SizedBox(height: 6),
                        Text(
                            p
                                .t('autoClicker.counter')
                                .replaceFirst('{n}', '$_done'),
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                      ],
                      const SizedBox(height: 14),
                      Text(p.t('autoClicker.note'),
                          style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                              height: 1.6)),
                    ],
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s,
            style: const TextStyle(
                color: Color(0xFF4DD0E1),
                fontSize: 11.5,
                fontWeight: FontWeight.w700)),
      );

  Widget _targetRow(MindMapProvider p) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _chip(
            label: p.t('autoClicker.targetPoint'),
            selected: _target == AutoClickTarget.fixedPoint,
            onTap: () => setState(() => _target = AutoClickTarget.fixedPoint),
          ),
          _chip(
            label: p.t('autoClicker.targetCursor'),
            selected: _target == AutoClickTarget.cursor,
            onTap: () => setState(() => _target = AutoClickTarget.cursor),
          ),
        ],
      );

  Widget _pointRow(MindMapProvider p) {
    final disabled = _target == AutoClickTarget.cursor;
    return Opacity(
      opacity: disabled ? 0.45 : 1,
      child: Row(children: [
        SizedBox(width: 70, child: _coordField('X', _xCtrl, !disabled)),
        const SizedBox(width: 8),
        SizedBox(width: 70, child: _coordField('Y', _yCtrl, !disabled)),
        const SizedBox(width: 10),
        TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF4DD0E1),
            visualDensity: VisualDensity.compact,
          ),
          icon: const Icon(Icons.my_location_rounded, size: 16),
          label: Text(p.t('autoClicker.pick'),
              style: const TextStyle(fontSize: 11.5)),
          onPressed: disabled || _running ? null : _pickPoint,
        ),
      ]),
    );
  }

  Widget _coordField(String label, TextEditingController c, bool enabled) =>
      TextField(
        controller: c,
        enabled: enabled && !_running,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(color: Colors.white, fontSize: 12.5),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white38, fontSize: 11),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          enabledBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Colors.white24)),
          focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF4DD0E1))),
        ),
      );

  Widget _buttonRow(MindMapProvider p) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final e in [
            (MouseButton.left, 'autoClicker.btnLeft'),
            (MouseButton.right, 'autoClicker.btnRight'),
            (MouseButton.middle, 'autoClicker.btnMiddle'),
          ])
            _chip(
              label: p.t(e.$2),
              selected: _button == e.$1,
              onTap: () => setState(() => _button = e.$1),
            ),
          const SizedBox(width: 10),
          _chip(
            label: p.t('autoClicker.doubleClick'),
            selected: _clicksPerShot == 2,
            onTap: () =>
                setState(() => _clicksPerShot = _clicksPerShot == 2 ? 1 : 2),
          ),
        ],
      );

  Widget _numberRow({
    required String label,
    required TextEditingController controller,
    required String suffix,
    required int min,
    required int max,
    required ValueChanged<int> onChanged,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(
          width: 118,
          child: Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
        SizedBox(
          width: 96,
          child: TextField(
            controller: controller,
            enabled: !_running,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(color: Colors.white, fontSize: 12.5),
            onChanged: (s) {
              // ★ 打っている途中の空欄や 0 で書き換えない (= 打ち直す時に
              //   最小値へ跳ね上がって数が打てなくなる)。 丸めるのは
              //   「開始」 の時。
              final v = int.tryParse(s.trim());
              if (v == null) return;
              onChanged(v.clamp(min, max));
            },
            decoration: const InputDecoration(
              isDense: true,
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF4DD0E1))),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(suffix,
            style: const TextStyle(color: Colors.white38, fontSize: 11.5)),
        if (hint != null) ...[
          const SizedBox(width: 10),
          Expanded(
            child: Text(hint,
                style: const TextStyle(color: Colors.white30, fontSize: 11)),
          ),
        ],
      ]),
    );
  }

  Widget _runRow(MindMapProvider p) => Row(children: [
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor:
                _running ? const Color(0xFFE53935) : const Color(0xFF4DD0E1),
            foregroundColor: _running ? Colors.white : Colors.black87,
          ),
          icon: Icon(
              _running ? Icons.stop_rounded : Icons.play_arrow_rounded,
              size: 18),
          label: Text(
              _running ? p.t('autoClicker.stop') : p.t('autoClicker.start')),
          onPressed: _running ? () => _stop() : _start,
        ),
      ]);

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: _running ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFF4DD0E1).withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
                color: selected ? const Color(0xFF4DD0E1) : Colors.white24),
          ),
          child: Text(label,
              style: TextStyle(
                  color: selected ? const Color(0xFF4DD0E1) : Colors.white60,
                  fontSize: 11.5)),
        ),
      );
}
