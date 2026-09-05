// lib/widgets/calc_body.dart
//
// 関数電卓の共通本体 (= ユーザー要望: フローティングモード (別ウィンドウ) と
// 普通に開く時 (アプリ内オーバーレイ) とで UI が異なって困惑する → 揃える)。
// ディスプレイ + DEG/RAD 切替 + キーパッド + キーボード入力を 1 つの
// ウィジェットに纏め、 本体オーバーレイ (mind_map_screen) と
// 別ウィンドウ (main.dart の _CalcWindowApp) の両方から使う。
// 式の評価器 CalcEval も本体の _SciCalcEval と同じもの (移設コピー)。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 関数電卓の共通本体 (ディスプレイ + キーパッド)。
class CalcBody extends StatefulWidget {
  /// 物理キーボードからの入力を受け付けるか (既定 true)。
  final bool enableKeyboard;
  const CalcBody({super.key, this.enableKeyboard = true});

  @override
  State<CalcBody> createState() => _CalcBodyState();
}

class _CalcBodyState extends State<CalcBody> {
  String _expr = '';
  String _result = '';
  bool _degreeMode = true;

  @override
  void initState() {
    super.initState();
    if (widget.enableKeyboard) {
      HardwareKeyboard.instance.addHandler(_handleKey);
    }
  }

  @override
  void dispose() {
    if (widget.enableKeyboard) {
      HardwareKeyboard.instance.removeHandler(_handleKey);
    }
    super.dispose();
  }

  /// 物理キーボード入力 (数字/演算子/Enter/Backspace)。
  /// テキスト入力欄にフォーカスがある時と Ctrl 併用時は素通しする。
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final isCtrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final focused = FocusManager.instance.primaryFocus;
    if (focused != null && focused.context?.widget is EditableText) {
      return false;
    }
    if (isCtrl) return false;
    final k = event.logicalKey;
    final map = {
      LogicalKeyboardKey.digit0: '0',
      LogicalKeyboardKey.digit1: '1',
      LogicalKeyboardKey.digit2: '2',
      LogicalKeyboardKey.digit3: '3',
      LogicalKeyboardKey.digit4: '4',
      LogicalKeyboardKey.digit5: '5',
      LogicalKeyboardKey.digit6: '6',
      LogicalKeyboardKey.digit7: '7',
      LogicalKeyboardKey.digit8: '8',
      LogicalKeyboardKey.digit9: '9',
      LogicalKeyboardKey.numpad0: '0',
      LogicalKeyboardKey.numpad1: '1',
      LogicalKeyboardKey.numpad2: '2',
      LogicalKeyboardKey.numpad3: '3',
      LogicalKeyboardKey.numpad4: '4',
      LogicalKeyboardKey.numpad5: '5',
      LogicalKeyboardKey.numpad6: '6',
      LogicalKeyboardKey.numpad7: '7',
      LogicalKeyboardKey.numpad8: '8',
      LogicalKeyboardKey.numpad9: '9',
      LogicalKeyboardKey.period: '.',
      LogicalKeyboardKey.numpadDecimal: '.',
      LogicalKeyboardKey.add: '+',
      LogicalKeyboardKey.numpadAdd: '+',
      LogicalKeyboardKey.minus: '-',
      LogicalKeyboardKey.numpadSubtract: '-',
      LogicalKeyboardKey.asterisk: '*',
      LogicalKeyboardKey.numpadMultiply: '*',
      LogicalKeyboardKey.slash: '/',
      LogicalKeyboardKey.numpadDivide: '/',
      LogicalKeyboardKey.parenthesisLeft: '(',
      LogicalKeyboardKey.parenthesisRight: ')',
      LogicalKeyboardKey.caret: '^',
    };
    if (map.containsKey(k)) {
      _push(map[k]!);
      return true;
    }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.equal) {
      _evaluate();
      return true;
    }
    if (k == LogicalKeyboardKey.backspace) {
      _backspace();
      return true;
    }
    return false;
  }

  void _push(String s) {
    setState(() {
      _expr += s;
      _result = '';
    });
  }

  void _backspace() {
    if (_expr.isEmpty) return;
    setState(() {
      _expr = _expr.substring(0, _expr.length - 1);
      _result = '';
    });
  }

  void _clear() {
    setState(() {
      _expr = '';
      _result = '';
    });
  }

  void _evaluate() {
    if (_expr.trim().isEmpty) return;
    try {
      final v = CalcEval(_expr, degreeMode: _degreeMode).parse();
      setState(() => _result = _fmt(v));
    } catch (_) {
      setState(() => _result = 'Error');
    }
  }

  String _fmt(double v) {
    if (v.isNaN || v.isInfinite) return 'Error';
    if (v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    var t = v.toStringAsPrecision(12);
    if (t.contains('.')) {
      t = t.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return t;
  }

  /// 結果を式に引き継いで続けて計算 (= Ans 的な使い方)。
  void _useResult() {
    if (_result.isEmpty || _result == 'Error') return;
    setState(() {
      _expr = _result;
      _result = '';
    });
  }

  static const double _keyH = 46;

  Widget _btn(String label,
      {String? ins, VoidCallback? onTap, Color? bg, Color? fg}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: SizedBox(
          height: _keyH - 4,
          child: Material(
            color: bg ?? const Color(0xFF2A2A3E),
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap ?? () => _push(ins ?? label),
              child: Center(
                child: Text(label,
                    style: TextStyle(
                        color: fg ?? Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const fnBg = Color(0xFF232338);
    const opBg = Color(0xFF33334E);
    const acc = Color(0xFF80CBC4);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // ── ディスプレイ ──
      Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(6, 6, 6, 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF0B0B1E),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(children: [
          Row(children: [
            // DEG/RAD 切替
            InkWell(
              onTap: () => setState(() => _degreeMode = !_degreeMode),
              borderRadius: BorderRadius.circular(4),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(_degreeMode ? 'DEG' : 'RAD',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Text(_expr.isEmpty ? '0' : _expr,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 20, height: 1.2)),
              ),
            ),
          ]),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: _useResult,
              child: Text(_result.isEmpty ? ' ' : '= $_result',
                  style: TextStyle(
                      color: _result == 'Error' ? Colors.redAccent : acc,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ),
      // ── キーパッド ──
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            _btn('sin', ins: 'sin('),
            _btn('cos', ins: 'cos('),
            _btn('tan', ins: 'tan('),
            _btn('π'),
            _btn('e', ins: 'math.e'),
          ]),
          Row(children: [
            _btn('asin', ins: 'asin(', bg: fnBg),
            _btn('acos', ins: 'acos(', bg: fnBg),
            _btn('atan', ins: 'atan(', bg: fnBg),
            _btn('ln', ins: 'ln('),
            _btn('log', ins: 'log('),
          ]),
          Row(children: [
            _btn('√', ins: '√('),
            _btn('x²', ins: '^2'),
            _btn('^'),
            _btn('(', bg: opBg),
            _btn(')', bg: opBg),
          ]),
          Row(children: [
            _btn('7'),
            _btn('8'),
            _btn('9'),
            _btn('÷', bg: opBg),
            _btn('⌫', onTap: _backspace, bg: opBg),
          ]),
          Row(children: [
            _btn('4'),
            _btn('5'),
            _btn('6'),
            _btn('×', bg: opBg),
            _btn('C', onTap: _clear, bg: const Color(0xFF4A2A35)),
          ]),
          Row(children: [
            _btn('1'),
            _btn('2'),
            _btn('3'),
            _btn('-', bg: opBg),
            _btn('abs', ins: 'abs(', bg: fnBg),
          ]),
          Row(children: [
            _btn('0'),
            _btn('.'),
            _btn('exp', ins: 'exp(', bg: fnBg),
            _btn('+', bg: opBg),
            _btn('=', onTap: _evaluate, bg: acc, fg: const Color(0xFF10241F)),
          ]),
        ]),
      ),
    ]);
  }
}

class CalcEval {
  final String input;
  int _pos = 0;
  final bool degreeMode;
  CalcEval(this.input, {this.degreeMode = true});

  double parse() {
    final v = _parseExpr();
    _skipWs();
    if (_pos < input.length) {
      throw FormatException('未使用の文字: ${input.substring(_pos)}');
    }
    return v;
  }

  void _skipWs() {
    while (_pos < input.length && input[_pos] == ' ') {
      _pos++;
    }
  }

  bool _match(String s) {
    _skipWs();
    if (_pos + s.length <= input.length &&
        input.substring(_pos, _pos + s.length) == s) {
      _pos += s.length;
      return true;
    }
    return false;
  }

  double _parseExpr() {
    var left = _parseTerm();
    while (true) {
      _skipWs();
      if (_match('+')) {
        left += _parseTerm();
      } else if (_match('-')) {
        left -= _parseTerm();
      } else {
        break;
      }
    }
    return left;
  }

  double _parseTerm() {
    var left = _parsePower();
    while (true) {
      _skipWs();
      if (_match('*') || _match('×')) {
        left *= _parsePower();
      } else if (_match('/') || _match('÷')) {
        final r = _parsePower();
        if (r == 0) return double.nan;
        left /= r;
      } else {
        break;
      }
    }
    return left;
  }

  double _parsePower() {
    final left = _parseUnary();
    _skipWs();
    if (_match('^')) {
      final right = _parsePower(); // right-associative
      return math.pow(left, right).toDouble();
    }
    return left;
  }

  double _parseUnary() {
    _skipWs();
    if (_match('-')) return -_parseUnary();
    if (_match('+')) return _parseUnary();
    return _parsePostfix();
  }

  double _parsePostfix() {
    var v = _parseAtom();
    _skipWs();
    // 後置: 度数記号、平方、階乗など
    if (_match('°')) {
      v = v * math.pi / 180;
    } else if (_match('²')) {
      v = v * v;
    } else if (_match('!')) {
      v = _factorial(v);
    }
    return v;
  }

  double _factorial(double n) {
    if (n < 0 || n != n.truncateToDouble() || n > 170) return double.nan;
    var r = 1.0;
    for (var i = 2; i <= n.toInt(); i++) {
      r *= i;
    }
    return r;
  }

  double _parseAtom() {
    _skipWs();
    if (_pos >= input.length) throw const FormatException('予期せぬ式の終端');
    if (_match('(')) {
      final v = _parseExpr();
      _skipWs();
      if (!_match(')')) throw const FormatException('括弧の閉じ忘れ');
      return v;
    }
    // 関数・定数（最長一致で順に判定）
    for (final entry in const [
      ['asin', 1],
      ['acos', 1],
      ['atan', 1],
      ['sin', 1],
      ['cos', 1],
      ['tan', 1],
      ['sqrt', 1],
      ['√', 1],
      ['log', 1],
      ['ln', 1],
      ['exp', 1],
      ['abs', 1],
    ]) {
      final name = entry[0] as String;
      if (_match(name)) {
        _skipWs();
        final needParen = _match('(');
        final arg = _parseUnary();
        if (needParen) {
          _skipWs();
          _match(')');
        }
        return _applyFunc(name, arg);
      }
    }
    if (_match('π') || _match('math.pi')) return math.pi;
    if (_match('math.e')) return math.e;
    // 数値
    final start = _pos;
    while (_pos < input.length && (RegExp(r'[0-9.]').hasMatch(input[_pos]))) {
      _pos++;
    }
    // 指数表記 (1e5)
    if (_pos < input.length &&
        (input[_pos] == 'E' || input[_pos] == 'math.e')) {
      // 'math.e' は定数でもあるので、前が数字で後ろが数字/+/- の時だけ
      if (start < _pos &&
          _pos + 1 < input.length &&
          RegExp(r'[0-9+-]').hasMatch(input[_pos + 1])) {
        _pos++;
        if (input[_pos] == '+' || input[_pos] == '-') _pos++;
        while (_pos < input.length && RegExp(r'[0-9]').hasMatch(input[_pos])) {
          _pos++;
        }
      }
    }
    if (start == _pos) {
      throw FormatException('数値が期待されました位置 $_pos');
    }
    return double.parse(input.substring(start, _pos));
  }

  double _applyFunc(String name, double x) {
    final ang = degreeMode ? x * math.pi / 180 : x;
    switch (name) {
      case 'sin':
        return math.sin(ang);
      case 'cos':
        return math.cos(ang);
      case 'tan':
        return math.tan(ang);
      case 'asin':
        final r = math.asin(x);
        return degreeMode ? r * 180 / math.pi : r;
      case 'acos':
        final r = math.acos(x);
        return degreeMode ? r * 180 / math.pi : r;
      case 'atan':
        final r = math.atan(x);
        return degreeMode ? r * 180 / math.pi : r;
      case 'sqrt':
      case '√':
        return math.sqrt(x);
      case 'log':
        return math.log(x) / math.ln10;
      case 'ln':
        return math.log(x);
      case 'exp':
        return math.exp(x);
      case 'abs':
        return x.abs();
    }
    return double.nan;
  }
}

/// 関数電卓フローティングパネル


/// 普通の電卓の本体 (= ユーザー要望: 普通の電卓と関数電卓をヘッダーから
/// 切り替えられるように)。
///
/// もともと画面ファイルの中に直書きされていた四則の電卓を、 関数電卓
/// ([CalcBody]) と同じように部品として切り出した物。 これで、 アプリの中の
/// 浮かぶ窓・左右分割のペイン・アプリの外の窓のどれでも同じ電卓が出せる。
///
/// 見た目と計算の仕方は元のままにしてある (足し算の途中式を上に小さく出し、
/// C / ⌫ / ± と四則、 = で確定)。
class BasicCalcBody extends StatefulWidget {
  /// 物理キーボードからの入力を受け付けるか (既定 true)。
  /// 左右分割に埋め込む時など、 開きっぱなしになる場所では false にする
  /// (= 別のペインでの文字入力を奪わないため)。
  final bool enableKeyboard;

  /// 狭い所 (スマホ・小さな窓) 向けに詰めて出すか。
  final bool compact;

  const BasicCalcBody(
      {super.key, this.enableKeyboard = true, this.compact = false});

  @override
  State<BasicCalcBody> createState() => _BasicCalcBodyState();
}

class _BasicCalcBodyState extends State<BasicCalcBody> {
  String _display = '0';
  double? _pendingValue;
  String? _pendingOp;
  bool _justComputed = false;

  @override
  void initState() {
    super.initState();
    if (widget.enableKeyboard) {
      HardwareKeyboard.instance.addHandler(_handleKey);
    }
  }

  @override
  void dispose() {
    if (widget.enableKeyboard) {
      HardwareKeyboard.instance.removeHandler(_handleKey);
    }
    super.dispose();
  }

  /// 物理キーボード入力 (数字/演算子/Enter/Backspace)。
  /// 文字入力欄にフォーカスがある時と Ctrl 併用時は素通しする。
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return false;
    }
    final focused = FocusManager.instance.primaryFocus;
    if (focused != null && focused.context?.widget is EditableText) {
      return false;
    }
    final k = event.logicalKey;
    // const にはできない (LogicalKeyboardKey は == を自前で持つため)。
    final digits = {
      LogicalKeyboardKey.digit0: '0',
      LogicalKeyboardKey.digit1: '1',
      LogicalKeyboardKey.digit2: '2',
      LogicalKeyboardKey.digit3: '3',
      LogicalKeyboardKey.digit4: '4',
      LogicalKeyboardKey.digit5: '5',
      LogicalKeyboardKey.digit6: '6',
      LogicalKeyboardKey.digit7: '7',
      LogicalKeyboardKey.digit8: '8',
      LogicalKeyboardKey.digit9: '9',
      LogicalKeyboardKey.numpad0: '0',
      LogicalKeyboardKey.numpad1: '1',
      LogicalKeyboardKey.numpad2: '2',
      LogicalKeyboardKey.numpad3: '3',
      LogicalKeyboardKey.numpad4: '4',
      LogicalKeyboardKey.numpad5: '5',
      LogicalKeyboardKey.numpad6: '6',
      LogicalKeyboardKey.numpad7: '7',
      LogicalKeyboardKey.numpad8: '8',
      LogicalKeyboardKey.numpad9: '9',
    };
    final d = digits[k];
    if (d != null) {
      _pressDigit(d);
      return true;
    }
    if (k == LogicalKeyboardKey.period ||
        k == LogicalKeyboardKey.numpadDecimal) {
      _pressDot();
      return true;
    }
    if (k == LogicalKeyboardKey.add || k == LogicalKeyboardKey.numpadAdd) {
      _pressOp('+');
      return true;
    }
    if (k == LogicalKeyboardKey.minus ||
        k == LogicalKeyboardKey.numpadSubtract) {
      _pressOp('-');
      return true;
    }
    if (k == LogicalKeyboardKey.asterisk ||
        k == LogicalKeyboardKey.numpadMultiply) {
      _pressOp('*');
      return true;
    }
    if (k == LogicalKeyboardKey.slash || k == LogicalKeyboardKey.numpadDivide) {
      _pressOp('/');
      return true;
    }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.equal) {
      _pressEquals();
      return true;
    }
    if (k == LogicalKeyboardKey.backspace) {
      _pressBackspace();
      return true;
    }
    return false;
  }

  String _formatNum(double v) {
    if (v.isNaN || v.isInfinite) return 'Error';
    if (v == v.truncate() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    var s = v.toStringAsFixed(10);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      s = s.replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  double? _compute(double a, String op, double b) {
    switch (op) {
      case '+':
        return a + b;
      case '-':
        return a - b;
      case '*':
        return a * b;
      case '/':
        return b == 0 ? double.nan : a / b;
    }
    return null;
  }

  void _pressDigit(String d) {
    setState(() {
      if (_justComputed) {
        _display = d;
        _justComputed = false;
      } else if (_display == '0') {
        _display = d;
      } else {
        _display = _display + d;
      }
    });
  }

  void _pressDot() {
    setState(() {
      if (_justComputed) {
        _display = '0.';
        _justComputed = false;
      } else if (!_display.contains('.')) {
        _display = '$_display.';
      }
    });
  }

  void _pressOp(String op) {
    setState(() {
      final current = double.tryParse(_display) ?? 0;
      if (_pendingValue != null && _pendingOp != null && !_justComputed) {
        final result = _compute(_pendingValue!, _pendingOp!, current);
        if (result != null) {
          _display = _formatNum(result);
          _pendingValue = result;
        }
      } else {
        _pendingValue = current;
      }
      _pendingOp = op;
      _justComputed = true;
    });
  }

  void _pressEquals() {
    setState(() {
      if (_pendingValue != null && _pendingOp != null) {
        final current = double.tryParse(_display) ?? 0;
        final result = _compute(_pendingValue!, _pendingOp!, current);
        if (result != null) {
          _display = _formatNum(result);
          _pendingValue = null;
          _pendingOp = null;
          _justComputed = true;
        }
      }
    });
  }

  void _pressClear() {
    setState(() {
      _display = '0';
      _pendingValue = null;
      _pendingOp = null;
      _justComputed = false;
    });
  }

  void _pressBackspace() {
    setState(() {
      if (_justComputed || _display.length <= 1) {
        _display = '0';
        _justComputed = false;
      } else {
        _display = _display.substring(0, _display.length - 1);
        if (_display == '-') _display = '0';
      }
    });
  }

  void _pressNegate() {
    setState(() {
      if (_display == '0') return;
      if (_display.startsWith('-')) {
        _display = _display.substring(1);
      } else {
        _display = '-$_display';
      }
    });
  }

  Widget _btn(String label,
      {Color? bg, Color? fg, VoidCallback? onPressed, int flex = 1}) {
    final compact = widget.compact;
    return Expanded(
      flex: flex,
      child: Padding(
        padding: EdgeInsets.all(compact ? 2 : 3),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: bg ?? const Color(0xFF2A2A3E),
            foregroundColor: fg ?? Colors.white,
            padding: EdgeInsets.symmetric(vertical: compact ? 9 : 14),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(compact ? 6 : 8)),
          ),
          onPressed: onPressed,
          child: Text(label,
              style: TextStyle(
                  fontSize: compact ? 14 : 18, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    return Padding(
      padding: EdgeInsets.all(compact ? 6 : 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(compact ? 10 : 16),
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0B0B1E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (_pendingValue != null && _pendingOp != null)
                  Text(
                    '${_formatNum(_pendingValue!)} '
                    '${_pendingOp!.replaceAll('*', '×').replaceAll('/', '÷')}',
                    style: TextStyle(
                        color: Colors.white38,
                        fontSize: compact ? 10 : 12,
                        fontFamily: 'monospace'),
                  ),
                Text(_display,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 20 : 26,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          Row(children: [
            _btn('C',
                bg: const Color(0xFFFF6B6B).withValues(alpha: 0.8),
                onPressed: _pressClear),
            _btn('⌫',
                bg: const Color(0xFF555577), onPressed: _pressBackspace),
            _btn('±', bg: const Color(0xFF555577), onPressed: _pressNegate),
            _btn('÷',
                bg: const Color(0xFFBA68C8), onPressed: () => _pressOp('/')),
          ]),
          Row(children: [
            _btn('7', onPressed: () => _pressDigit('7')),
            _btn('8', onPressed: () => _pressDigit('8')),
            _btn('9', onPressed: () => _pressDigit('9')),
            _btn('×',
                bg: const Color(0xFFBA68C8), onPressed: () => _pressOp('*')),
          ]),
          Row(children: [
            _btn('4', onPressed: () => _pressDigit('4')),
            _btn('5', onPressed: () => _pressDigit('5')),
            _btn('6', onPressed: () => _pressDigit('6')),
            _btn('-',
                bg: const Color(0xFFBA68C8), onPressed: () => _pressOp('-')),
          ]),
          Row(children: [
            _btn('1', onPressed: () => _pressDigit('1')),
            _btn('2', onPressed: () => _pressDigit('2')),
            _btn('3', onPressed: () => _pressDigit('3')),
            _btn('+',
                bg: const Color(0xFFBA68C8), onPressed: () => _pressOp('+')),
          ]),
          Row(children: [
            _btn('0', flex: 2, onPressed: () => _pressDigit('0')),
            _btn('.', onPressed: _pressDot),
            _btn('=',
                bg: const Color(0xFF43B97F), onPressed: _pressEquals),
          ]),
        ],
      ),
    );
  }
}
