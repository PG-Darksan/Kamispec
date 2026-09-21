// オートクリッカーのパレット。
//
// ★ = ユーザー要望「タップすると画面上にパレットが出てきて、 スワイプや
//   指定したボタン位置をクリックするなどの動作を割り当てられるようにして
//   欲しい」。
//
// これまでのオートクリッカーは「1 か所をひたすら押す」 道具だった。 実際に
// 欲しかったのは**押したい動作を並べておいて、 好きな時に 1 つ押して出す**
// 形なので、 その置き場をここに作る。
//
//   ・札を押す = その動作を 1 回流す (連打の札なら、 押すたび入 / 切)。
//   ・札を長押し (または⚙) = 中身を決め直す。
//   ・位置は「今のカーソルの所を 3 つ数えて控える」 形で決める
//     (アプリの窓の外は触れないので、 覆って選ばせる事は出来ない)。
//
// 中身は [DesktopInput] (SendInput) をそのまま使う。 走っている間だけ
// `DesktopInput.enabled` を立て、 終わったら必ず戻す。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/desktop_input.dart';
import '../services/screen_capture.dart';
import 'shot_manager_dialog.dart';

/// 札に割り当てられる動作。
enum AutoClickKind {
  /// 指定した位置を 1 回押す。
  click,

  /// 指定した位置を 2 回続けて押す。
  doubleClick,

  /// 指定した位置を右で押す。
  rightClick,

  /// 始点から終点まで押したまま引きずる。
  swipe,

  /// ホイールを回す (正で上 / 負で下)。
  scroll,

  /// 指定した位置を決めた間隔で押し続ける (押すたび入 / 切)。
  repeatClick,

  /// 文字をそのまま打ち込む。
  typeText,

  /// キーの組み合わせを送る (例: ctrl+c)。
  keys,

  /// 画面ぜんたいを撮る (= ユーザー要望: スクショも撮れるように)。
  screenshot,

  /// 決めた範囲だけを撮る (始点 → 終点が対角)。
  screenshotRect,
}

String autoClickKindKey(AutoClickKind k) => switch (k) {
      AutoClickKind.click => 'palette.kindClick',
      AutoClickKind.doubleClick => 'palette.kindDouble',
      AutoClickKind.rightClick => 'palette.kindRight',
      AutoClickKind.swipe => 'palette.kindSwipe',
      AutoClickKind.scroll => 'palette.kindScroll',
      AutoClickKind.repeatClick => 'palette.kindRepeat',
      AutoClickKind.typeText => 'palette.kindType',
      AutoClickKind.keys => 'palette.kindKeys',
      AutoClickKind.screenshot => 'palette.kindShot',
      AutoClickKind.screenshotRect => 'palette.kindShotRect',
    };

IconData autoClickKindIcon(AutoClickKind k) => switch (k) {
      AutoClickKind.click => Icons.ads_click_rounded,
      AutoClickKind.doubleClick => Icons.touch_app_rounded,
      AutoClickKind.rightClick => Icons.mouse_rounded,
      AutoClickKind.swipe => Icons.swipe_rounded,
      AutoClickKind.scroll => Icons.swap_vert_rounded,
      AutoClickKind.repeatClick => Icons.repeat_rounded,
      AutoClickKind.typeText => Icons.keyboard_rounded,
      AutoClickKind.keys => Icons.keyboard_command_key_rounded,
      AutoClickKind.screenshot => Icons.photo_camera_rounded,
      AutoClickKind.screenshotRect => Icons.crop_rounded,
    };

/// 位置が要る動作か。
bool autoClickNeedsPoint(AutoClickKind k) =>
    k == AutoClickKind.click ||
    k == AutoClickKind.doubleClick ||
    k == AutoClickKind.rightClick ||
    k == AutoClickKind.swipe ||
    k == AutoClickKind.repeatClick ||
    k == AutoClickKind.screenshotRect;

/// 終点も要る動作か (スワイプ と 範囲のスクショ)。
bool autoClickNeedsEnd(AutoClickKind k) =>
    k == AutoClickKind.swipe || k == AutoClickKind.screenshotRect;

/// 札 1 枚ぶん。
class AutoClickSlot {
  AutoClickSlot({
    required this.kind,
    this.label = '',
    this.x1 = 0,
    this.y1 = 0,
    this.x2 = 0,
    this.y2 = 0,
    this.intervalMs = 300,
    this.notches = -3,
    this.text = '',
  });

  AutoClickKind kind;
  String label;
  int x1;
  int y1;
  int x2;
  int y2;

  /// 連打の間隔 (ミリ秒)。
  int intervalMs;

  /// ホイールの段数 (正で上 / 負で下)。
  int notches;

  /// 打ち込む文字 / 送るキーの組み合わせ。
  String text;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.name,
        'label': label,
        'x1': x1,
        'y1': y1,
        'x2': x2,
        'y2': y2,
        'interval': intervalMs,
        'notches': notches,
        'text': text,
      };

  static AutoClickSlot fromJson(Map<String, dynamic> j) {
    final name = '${j['kind'] ?? ''}';
    var kind = AutoClickKind.click;
    for (final k in AutoClickKind.values) {
      if (k.name == name) kind = k;
    }
    return AutoClickSlot(
      kind: kind,
      label: '${j['label'] ?? ''}',
      x1: (j['x1'] as num?)?.toInt() ?? 0,
      y1: (j['y1'] as num?)?.toInt() ?? 0,
      x2: (j['x2'] as num?)?.toInt() ?? 0,
      y2: (j['y2'] as num?)?.toInt() ?? 0,
      intervalMs: ((j['interval'] as num?)?.toInt() ?? 300).clamp(10, 600000),
      notches: ((j['notches'] as num?)?.toInt() ?? -3).clamp(-30, 30),
      text: '${j['text'] ?? ''}',
    );
  }
}

/// パレット本体。
///
/// ★ = ユーザー要望「パレットが出てきて、 他の箇所がアクティブでも消えずに
///   押せるみたいなものを想定していた」。 その形にするには**アプリとは別の
///   窓**に出す必要がある。 別窓は `MindMapProvider` を持てない (同じ控えを
///   2 つの入れ物から書くと壊れる) ので、 言葉を引く手と控えを書く手を
///   外から受け取る形にした。 本体の中で使う時は provider の物を渡し、
///   別窓では読みだけ自分で行い、 書き込みは本体へ頼む。
class AutoClickPalette extends StatefulWidget {
  const AutoClickPalette({
    super.key,
    required this.t,
    this.onSave,
    this.compact = false,
    this.bar = false,
  });

  /// 言葉を引く手 (本体なら `provider.t`)。
  final String Function(String key) t;

  /// 控えを書く手。 null なら自分で prefs へ書く。
  /// 別窓からは本体へ頼む (別の入れ物から書くと本体の控えを潰すため)。
  final Future<void> Function(String json)? onSave;

  /// 別窓のように狭い所で出す時は、 説明と見出しを畳む。
  final bool compact;

  /// 画面録画の操作窓のような**横一列の帯**で出すか。
  ///
  /// ★ = ユーザー指摘「オートクリッカーが思っているのと違う。 画面録画バー
  ///   みたいなのが画面外にも出る形で出てきて」。 縦長の窓ではなく、 画面の
  ///   どこにでも置ける薄い帯にする。 札は横に流して並べる。
  final bool bar;

  /// 控えの鍵 (別窓から本体へ書き戻してもらう時に使う)。
  static const String prefsKey = 'autoClickPalette_v1';

  @override
  State<AutoClickPalette> createState() => _AutoClickPaletteState();
}

class _AutoClickPaletteState extends State<AutoClickPalette> {
  static const String _kPrefsKey = AutoClickPalette.prefsKey;

  final List<AutoClickSlot> _slots = [];
  bool _loaded = false;

  /// 連打している札の番号 (無ければ -1)。
  int _repeatIndex = -1;
  Timer? _repeatTimer;

  /// 位置を控えている最中の札と残り秒数。
  int _pickIndex = -1;

  /// 控える先 (1 = 始点 / 2 = 終点)。
  int _pickWhich = 1;
  int _pickLeft = 0;
  Timer? _pickTimer;

  /// 始点を控えた後、 続けて終点も控えるか
  /// (= ユーザー要望: スワイプの開始点・終了点は画面に乗せたポインタを基準に)。
  bool _pickChain = false;

  String _status = '';

  String _t(String k) => widget.t(k);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    // ★ 押しっぱなしで放置しないこと。 ここが最後の砦。
    _repeatTimer?.cancel();
    _pickTimer?.cancel();
    DesktopInput.enabled = false;
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefsKey) ?? '';
      if (raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final e in list) {
            if (e is Map) {
              _slots.add(AutoClickSlot.fromJson(
                  e.map((k, v) => MapEntry('$k', v))));
            }
          }
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loaded = true);
  }

  Future<void> _save() async {
    final json = jsonEncode(_slots.map((e) => e.toJson()).toList());
    final out = widget.onSave;
    if (out != null) {
      try {
        await out(json);
      } catch (_) {}
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPrefsKey, json);
    } catch (_) {}
  }


  /// 札の名前 (決めていなければ動作の名前)。
  String _titleOf(AutoClickSlot s) =>
      s.label.trim().isEmpty ? _t(autoClickKindKey(s.kind)) : s.label.trim();

  /// 札の下に出す小さな説明 (どこを押すか等)。
  String _subtitleOf(AutoClickSlot s) {
    switch (s.kind) {
      case AutoClickKind.swipe:
        return '(${s.x1}, ${s.y1}) → (${s.x2}, ${s.y2})';
      case AutoClickKind.scroll:
        return s.notches >= 0
            ? _t('palette.scrollUpN').replaceFirst('{n}', '${s.notches}')
            : _t('palette.scrollDownN').replaceFirst('{n}', '${-s.notches}');
      case AutoClickKind.repeatClick:
        return '(${s.x1}, ${s.y1}) · ${s.intervalMs}ms';
      case AutoClickKind.typeText:
      case AutoClickKind.keys:
        return s.text.isEmpty ? _t('palette.notSet') : s.text;
      case AutoClickKind.screenshot:
        return _t('palette.wholeScreen');
      case AutoClickKind.screenshotRect:
        return '(${s.x1}, ${s.y1}) - (${s.x2}, ${s.y2})';
      default:
        return '(${s.x1}, ${s.y1})';
    }
  }

  // ─── 位置を控える ───────────────────────────────────────────────────
  //
  // アプリの窓の外は覆えないので、 数えている間に置きたい所へカーソルを
  // 動かしてもらう (自動操作・これまでのオートクリッカーと同じ考え方)。
  void _pickPoint(int index, int which, {bool chain = false}) {
    _pickTimer?.cancel();
    setState(() {
      _pickIndex = index;
      _pickWhich = which;
      _pickChain = chain;
      _pickLeft = 3;
      _status = _t('palette.pickHint').replaceFirst('{n}', '$_pickLeft');
    });
    _pickTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _pickLeft--;
        if (_pickLeft > 0) {
          _status = _t('palette.pickHint').replaceFirst('{n}', '$_pickLeft');
          return;
        }
        t.cancel();
        _pickTimer = null;
        final p = DesktopInput.cursorPos();
        final i = _pickIndex;
        _pickIndex = -1;
        if (p == null || i < 0 || i >= _slots.length) {
          _status = _t('palette.pickFailed');
          return;
        }
        if (_pickWhich == 2) {
          _slots[i].x2 = p.x;
          _slots[i].y2 = p.y;
        } else {
          _slots[i].x1 = p.x;
          _slots[i].y1 = p.y;
        }
        _status = _t('palette.picked')
            .replaceFirst('{x}', '${p.x}')
            .replaceFirst('{y}', '${p.y}');
        unawaited(_save());
        // ★ 始点を控えたら、 そのまま終点も控える (= ユーザー要望:
        //   スワイプの 2 点をポインタで決める)。 窓を開き直さずに続ける。
        if (_pickChain && _pickWhich == 1) {
          _pickChain = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _pickPoint(i, 2);
          });
        }
      });
    });
  }

  // ─── 流す ───────────────────────────────────────────────────────────

  Future<void> _fire(int index) async {
    if (index < 0 || index >= _slots.length) return;
    final s = _slots[index];
    if (s.kind == AutoClickKind.repeatClick) {
      _toggleRepeat(index);
      return;
    }
    DesktopInput.enabled = true;
    try {
      switch (s.kind) {
        case AutoClickKind.click:
          DesktopInput.click(s.x1, s.y1);
          break;
        case AutoClickKind.doubleClick:
          DesktopInput.click(s.x1, s.y1, count: 2);
          break;
        case AutoClickKind.rightClick:
          DesktopInput.click(s.x1, s.y1, button: MouseButton.right);
          break;
        case AutoClickKind.swipe:
          await DesktopInput.drag(s.x1, s.y1, s.x2, s.y2);
          break;
        case AutoClickKind.scroll:
          // 転がす前に、 転がしたい所へカーソルを置く (ホイールは
          // カーソルの下の窓へ届くため)。
          if (s.x1 != 0 || s.y1 != 0) DesktopInput.moveTo(s.x1, s.y1);
          DesktopInput.scroll(s.notches);
          break;
        case AutoClickKind.typeText:
          DesktopInput.typeText(s.text);
          break;
        case AutoClickKind.keys:
          DesktopInput.pressKeys(
              s.text.split('+').map((e) => e.trim()).toList());
          break;
        case AutoClickKind.screenshot:
        case AutoClickKind.screenshotRect:
          await _shoot(s);
          break;
        case AutoClickKind.repeatClick:
          break;
      }
    } finally {
      // 連打していない時だけ下ろす (連打中は立てたままにする)。
      if (_repeatIndex < 0) DesktopInput.enabled = false;
    }
    if (!mounted) return;
    setState(() => _status =
        _t('palette.fired').replaceFirst('{n}', _titleOf(s)));
  }

  /// 画面を撮って控えへ落とす (= ユーザー要望: スクショも撮れるように)。
  ///
  /// ★ 撮るのは**画面そのもの**なので、 撮った瞬間にこのパレットも写り込む。
  ///   必要な所だけが欲しい時は、 範囲の札を使う。
  Future<void> _shoot(AutoClickSlot s) async {
    int x, y, w, h;
    if (s.kind == AutoClickKind.screenshotRect) {
      x = s.x1 < s.x2 ? s.x1 : s.x2;
      y = s.y1 < s.y2 ? s.y1 : s.y2;
      w = (s.x2 - s.x1).abs();
      h = (s.y2 - s.y1).abs();
    } else {
      final b = DesktopInput.screenBounds();
      x = b.x;
      y = b.y;
      w = b.width;
      h = b.height;
    }
    if (w <= 0 || h <= 0) {
      if (mounted) setState(() => _status = _t('palette.shotBadRect'));
      return;
    }
    final png = captureScreenRectPng(x, y, w, h);
    if (png == null || png.isEmpty) {
      if (mounted) setState(() => _status = _t('palette.shotFailed'));
      return;
    }
    try {
      final root = await automationShotsDir();
      final dir = Directory('${root.path}/palette');
      if (!await dir.exists()) await dir.create(recursive: true);
      final t = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name = 'shot_${t.year}${two(t.month)}${two(t.day)}_'
          '${two(t.hour)}${two(t.minute)}${two(t.second)}.png';
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(png, flush: true);
      if (!mounted) return;
      setState(
          () => _status = _t('palette.shotSaved').replaceFirst('{p}', f.path));
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '${_t('palette.shotFailed')}: $e');
    }
  }

  void _toggleRepeat(int index) {
    if (_repeatIndex == index) {
      _stopRepeat();
      return;
    }
    _repeatTimer?.cancel();
    final s = _slots[index];
    DesktopInput.enabled = true;
    setState(() {
      _repeatIndex = index;
      _status = _t('palette.repeatOn').replaceFirst('{n}', _titleOf(s));
    });
    _repeatTimer = Timer.periodic(
        Duration(milliseconds: s.intervalMs.clamp(10, 600000)), (_) {
      if (!mounted) {
        _stopRepeat();
        return;
      }
      DesktopInput.click(s.x1, s.y1);
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    DesktopInput.enabled = false;
    if (!mounted) {
      _repeatIndex = -1;
      return;
    }
    setState(() {
      _repeatIndex = -1;
      _status = _t('palette.repeatOff');
    });
  }

  // ─── 札を足す / 決め直す ─────────────────────────────────────────────

  Future<void> _addSlot() async {
    final kind = await _pickKind();
    if (kind == null || !mounted) return;
    setState(() {
      _slots.add(AutoClickSlot(kind: kind));
      _status = _t('palette.added');
    });
    await _save();
    if (!mounted) return;
    // 足したらそのまま中身を決めさせる (位置が 0,0 のままでは使えない)。
    await _editSlot(_slots.length - 1);
  }

  Future<AutoClickKind?> _pickKind() async {
    return showDialog<AutoClickKind>(
      context: context,
      builder: (dctx) => SimpleDialog(
        backgroundColor: const Color(0xFF1E1E32),
        title: Text(_t('palette.pickKind'),
            style: const TextStyle(color: Colors.white, fontSize: 14)),
        children: [
          for (final k in AutoClickKind.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dctx, k),
              child: Row(children: [
                Icon(autoClickKindIcon(k),
                    size: 17, color: const Color(0xFF4DD0E1)),
                const SizedBox(width: 10),
                Text(_t(autoClickKindKey(k)),
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ]),
            ),
        ],
      ),
    );
  }

  Future<void> _editSlot(int index) async {
    if (index < 0 || index >= _slots.length) return;
    final s = _slots[index];
    final nameCtrl = TextEditingController(text: s.label);
    final textCtrl = TextEditingController(text: s.text);
    final intervalCtrl = TextEditingController(text: '${s.intervalMs}');
    final notchCtrl = TextEditingController(text: '${s.notches}');
    final x1Ctrl = TextEditingController(text: '${s.x1}');
    final y1Ctrl = TextEditingController(text: '${s.y1}');
    final x2Ctrl = TextEditingController(text: '${s.x2}');
    final y2Ctrl = TextEditingController(text: '${s.y2}');
    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (sctx, setD) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E32),
          title: Row(children: [
            Icon(autoClickKindIcon(s.kind),
                size: 18, color: const Color(0xFF4DD0E1)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_t(autoClickKindKey(s.kind)),
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
            ),
          ]),
          content: SizedBox(
            // 狭い端末では窓の幅いっぱいに (決め打ちだと外へ出る)。
            width: MediaQuery.sizeOf(sctx).width < 420 ? double.maxFinite : 340,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _field(nameCtrl, _t('palette.name')),
                // ★ = ユーザー指摘「座標指定する形にする」。 位置は数で
                //   書く。 「今そこにある物の座標」 を人が読む術は無いので、
                //   カーソルから取り込む口だけは残してある (欄を埋めるだけ)。
                if (autoClickNeedsPoint(s.kind)) ...[
                  const SizedBox(height: 10),
                  _pointLine(
                    _t(autoClickNeedsEnd(s.kind)
                        ? 'palette.startPoint'
                        : 'palette.point'),
                    x1Ctrl,
                    y1Ctrl,
                    () {
                      _commit(s, nameCtrl, textCtrl, intervalCtrl, notchCtrl,
                          x1Ctrl, y1Ctrl, x2Ctrl, y2Ctrl);
                      Navigator.pop(dctx);
                      _pickPoint(index, 1);
                    },
                  ),
                ],
                if (autoClickNeedsEnd(s.kind)) ...[
                  const SizedBox(height: 6),
                  _pointLine(
                    _t('palette.endPoint'),
                    x2Ctrl,
                    y2Ctrl,
                    () {
                      _commit(s, nameCtrl, textCtrl, intervalCtrl, notchCtrl,
                          x1Ctrl, y1Ctrl, x2Ctrl, y2Ctrl);
                      Navigator.pop(dctx);
                      _pickPoint(index, 2);
                    },
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF4DD0E1),
                        side: const BorderSide(color: Color(0xFF4DD0E1)),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 30),
                      ),
                      icon: const Icon(Icons.timeline_rounded, size: 15),
                      label: Text(_t('palette.pickBoth'),
                          style: const TextStyle(fontSize: 11)),
                      onPressed: () {
                        _commit(s, nameCtrl, textCtrl, intervalCtrl, notchCtrl,
                            x1Ctrl, y1Ctrl, x2Ctrl, y2Ctrl);
                        Navigator.pop(dctx);
                        _pickPoint(index, 1, chain: true);
                      },
                    ),
                  ),
                ],
                if (s.kind == AutoClickKind.scroll) ...[
                  const SizedBox(height: 6),
                  _pointLine(
                    _t('palette.point'),
                    x1Ctrl,
                    y1Ctrl,
                    () {
                      _commit(s, nameCtrl, textCtrl, intervalCtrl, notchCtrl,
                          x1Ctrl, y1Ctrl, x2Ctrl, y2Ctrl);
                      Navigator.pop(dctx);
                      _pickPoint(index, 1);
                    },
                  ),
                  const SizedBox(height: 10),
                  _field(notchCtrl, _t('palette.notches')),
                ],
                if (s.kind == AutoClickKind.repeatClick) ...[
                  const SizedBox(height: 10),
                  _field(intervalCtrl, _t('palette.interval')),
                ],
                if (s.kind == AutoClickKind.typeText ||
                    s.kind == AutoClickKind.keys) ...[
                  const SizedBox(height: 10),
                  _field(
                      textCtrl,
                      s.kind == AutoClickKind.keys
                          ? _t('palette.keysHint')
                          : _t('palette.textHint')),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: Text(_t('btn.cancel'),
                  style: const TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4DD0E1),
                  foregroundColor: Colors.black87),
              onPressed: () {
                _commit(s, nameCtrl, textCtrl, intervalCtrl, notchCtrl, x1Ctrl,
                    y1Ctrl, x2Ctrl, y2Ctrl);
                Navigator.pop(dctx);
              },
              child: Text(_t('btn.save')),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    textCtrl.dispose();
    intervalCtrl.dispose();
    notchCtrl.dispose();
    x1Ctrl.dispose();
    y1Ctrl.dispose();
    x2Ctrl.dispose();
    y2Ctrl.dispose();
    if (!mounted) return;
    setState(() {});
    await _save();
  }

  /// 欄に書かれている値を札へ書き戻す。
  ///
  /// ★ 「カーソルから取り込む」 を押すと窓を一度閉じるので、 その前に
  ///   ここを通さないと、 それまでに書いた名前や間隔が消えてしまう。
  void _commit(
      AutoClickSlot s,
      TextEditingController name,
      TextEditingController text,
      TextEditingController interval,
      TextEditingController notch,
      TextEditingController x1,
      TextEditingController y1,
      TextEditingController x2,
      TextEditingController y2) {
    s.label = name.text.trim();
    s.text = text.text;
    s.intervalMs =
        (int.tryParse(interval.text.trim()) ?? s.intervalMs).clamp(10, 600000);
    s.notches = (int.tryParse(notch.text.trim()) ?? s.notches).clamp(-30, 30);
    s.x1 = int.tryParse(x1.text.trim()) ?? s.x1;
    s.y1 = int.tryParse(y1.text.trim()) ?? s.y1;
    s.x2 = int.tryParse(x2.text.trim()) ?? s.x2;
    s.y2 = int.tryParse(y2.text.trim()) ?? s.y2;
    unawaited(_save());
  }

  Widget _field(TextEditingController c, String hint) => TextField(
        controller: c,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
          filled: true,
          fillColor: Colors.black.withValues(alpha: 0.25),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide.none),
        ),
      );

  Widget _pointLine(String label, TextEditingController xc,
          TextEditingController yc, VoidCallback onPick) =>
      // ★ 点検で判明 (試験環境で描いて発見): 決め打ちの幅を足し合わせると
      //   360dp の端末では 8px 足りずにはみ出していた。 欄は残り幅を
      //   分け合う形にして、 どの幅でも収まるようにする。
      Row(children: [
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
        const SizedBox(width: 6),
        Expanded(flex: 3, child: _numField(xc, 'X')),
        const SizedBox(width: 6),
        Expanded(flex: 3, child: _numField(yc, 'Y')),
        IconButton(
          tooltip: _t('palette.readCursor'),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          icon: const Icon(Icons.my_location_rounded,
              size: 16, color: Color(0xFF4DD0E1)),
          onPressed: onPick,
        ),
      ]);

  Widget _numField(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(signed: true),
        style: const TextStyle(color: Colors.white, fontSize: 12.5),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white38, fontSize: 10.5),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          enabledBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Colors.white24)),
          focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF4DD0E1))),
        ),
      );

  Future<void> _removeSlot(int index) async {
    if (_repeatIndex == index) _stopRepeat();
    setState(() => _slots.removeAt(index));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
            child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (widget.bar) return _buildBar();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.dashboard_customize_rounded,
            size: 15, color: Color(0xFF4DD0E1)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(_t('palette.title'),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF4DD0E1),
            side: const BorderSide(color: Color(0xFF4DD0E1)),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 28),
          ),
          icon: const Icon(Icons.add_rounded, size: 15),
          label:
              Text(_t('palette.add'), style: const TextStyle(fontSize: 11)),
          onPressed: () => unawaited(_addSlot()),
        ),
      ]),
      if (!widget.compact) ...[
        const SizedBox(height: 4),
        Text(_t('palette.hint'),
            style: const TextStyle(
                color: Colors.white38, fontSize: 10.5, height: 1.5)),
      ],
      const SizedBox(height: 8),
      if (_slots.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(_t('palette.empty'),
              style: const TextStyle(color: Colors.white24, fontSize: 11)),
        )
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < _slots.length; i++) _chip(i),
        ]),
      if (_status.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(_status,
            style: const TextStyle(
                color: Color(0xFF9CCC65), fontSize: 11.5, height: 1.5)),
      ],
    ]);
  }

  /// 横一列の帯 (= 画面録画の操作窓と同じ構え)。
  ///
  /// ★ 札は横に流して並べる。 数が増えても帯の高さは変わらない。
  Widget _buildBar() => Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const SizedBox(width: 4),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF4DD0E1),
              side: const BorderSide(color: Color(0xFF4DD0E1)),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 26),
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.add_rounded, size: 14),
            label:
                Text(_t('palette.add'), style: const TextStyle(fontSize: 10.5)),
            onPressed: () => unawaited(_addSlot()),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _slots.isEmpty
                ? Text(_t('palette.empty'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(color: Colors.white24, fontSize: 10.5))
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      for (var i = 0; i < _slots.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        _chip(i),
                      ],
                    ]),
                  ),
          ),
        ]),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Color(0xFF9CCC65), fontSize: 10.5)),
            ),
          ),
      ]);

  Widget _chip(int i) {
    final s = _slots[i];
    final on = _repeatIndex == i;
    final picking = _pickIndex == i;
    return Material(
      color: on
          ? const Color(0xFF9CCC65).withValues(alpha: 0.20)
          : picking
              ? const Color(0xFFE5A23C).withValues(alpha: 0.20)
              : Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => unawaited(_fire(i)),
        onLongPress: () => unawaited(_editSlot(i)),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
                color: on
                    ? const Color(0xFF9CCC65)
                    : Colors.white.withValues(alpha: 0.14)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(on ? Icons.stop_rounded : autoClickKindIcon(s.kind),
                size: 16,
                color: on ? const Color(0xFF9CCC65) : const Color(0xFF4DD0E1)),
            const SizedBox(width: 8),
            // ★ 点検で判明 (試験環境で描いて発見): 名前や説明が長い札
            //   (スワイプの 2 点や、 打ち込む文字が長い物) で横へはみ出して
            //   いた。 札は [Wrap] の中なので、 中身に上限を置いて畳む。
            ConstrainedBox(
              // ★ 札に控える口 (2 点まとめ) を足したぶん、 名前の幅を詰める
              //   (検分で 360dp の端末で 2px はみ出した)。
              constraints: const BoxConstraints(maxWidth: 118),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_titleOf(s),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700)),
                    Text(_subtitleOf(s),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 10)),
                  ]),
            ),
            const SizedBox(width: 4),
            // ★ = ユーザー要望「スワイプの開始点、 終了点は画面の上に乗せた
            //   ポインタを基準にするように」。 札から直に 2 点を続けて
            //   控えられるようにする (窓を開き直さなくてよい)。
            if (autoClickNeedsEnd(s.kind))
              IconButton(
                tooltip: _t('palette.pickBoth'),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                icon: const Icon(Icons.my_location_rounded,
                    size: 14, color: Color(0xFF4DD0E1)),
                onPressed: () => _pickPoint(i, 1, chain: true),
              ),
            IconButton(
              tooltip: _t('palette.edit'),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              icon: const Icon(Icons.tune_rounded,
                  size: 14, color: Colors.white38),
              onPressed: () => unawaited(_editSlot(i)),
            ),
            IconButton(
              tooltip: _t('palette.remove'),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
              icon: const Icon(Icons.close_rounded,
                  size: 14, color: Color(0xFFFF8A80)),
              onPressed: () => unawaited(_removeSlot(i)),
            ),
          ]),
        ),
      ),
    );
  }
}
