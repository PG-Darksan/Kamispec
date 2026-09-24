/// キャンバス (フリーノートの紙) に置く文字の折り返しと行の高さ。
///
/// 紙の上の文字 (`_PaintText`) は CustomPaint で描く素のラベルなので
/// **自分では折り返さない**。 長い行をそのまま 1 個置くと用紙の右外へ
/// 流れ出て読めなくなる (= ユーザー報告: 説明資料のレイアウトが崩れる)。
/// 置く前にここで改行を入れておく。
///
/// 画面 (`_PaintPageViewState._wrapForCanvas`) と AI / MCP の書き込み
/// (`MindMapProvider.mcpAddPaintTexts`) の**両方**から呼ぶ。 二重に持つと
/// 片方だけ直り「手で置いた時は折れるのに AI に頼むと崩れる」 が起きるので、
/// 実装はここ 1 箇所だけに置く。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 意味の切れ目になりやすい文字 (= ユーザー要望: 端で折る時は、 単語や文の
/// 途中ではなく区切りのいい所で改行する)。 句読点・閉じ括弧の「後ろ」 で折る。
///
/// 画面側の `_PaintPageViewState._kWrapBreakAfter` と同じ並び (画面はあちらを
/// [wrapTextForCanvas] の breakAfter に渡すので、 使われるのは常に 1 本)。
const String kCanvasWrapBreakAfter =
    '。．.！!？?、，,；;：:）)」』】〕》〉…—ー　 \t/';

/// [maxWidth] に収まる所で改行を入れて返す。 元からある改行はそのまま残す。
///
/// 書式 ([bold]/[italic]/[family]) を渡すと実際に描くのと同じ幅で測るので、
/// 太字や別の書体でもはみ出さない。
///
/// ★ 1 行分ずつ**測り直し**ながら進める。 段落全体を 1 回測って
///   その行の切れ目を使い回すと、 意味の切れ目まで戻した後の行が
///   元の切れ目のままになり、 短い端切れの行が残ってしまう。
String wrapTextForCanvas(String text, double maxWidth, double fontSize,
    {bool bold = false,
    bool italic = false,
    String family = '',
    String breakAfter = kCanvasWrapBreakAfter}) {
  final style = TextStyle(
    fontSize: fontSize,
    fontWeight: bold ? FontWeight.bold : FontWeight.w500,
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    fontFamily: family.isEmpty ? null : family,
  );
  // 毎回 段落の残り全部を測ると長文で重いので、 1 行に収まるはずの
  // 文字数より十分大きい窓だけを測る (足りなければ広げる)。
  const int kBaseWindow = 1024;
  final out = StringBuffer();
  var firstPara = true;
  for (final para in text.split('\n')) {
    if (!firstPara) out.write('\n');
    firstPara = false;
    if (para.isEmpty) continue;
    var offset = 0;
    var firstLine = true;
    while (offset < para.length) {
      // ── この位置から始まる 1 行の終わりを測る ──
      var window = kBaseWindow;
      int end;
      String tail;
      while (true) {
        final stop = math.min(offset + window, para.length);
        tail = para.substring(offset, stop);
        final tp = TextPainter(
          text: TextSpan(text: tail, style: style),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: maxWidth);
        end = tp.getLineBoundary(const TextPosition(offset: 0)).end;
        if (end <= 0) end = 1;
        if (end > tail.length) end = tail.length;
        // 窓を使い切った = まだ先まで 1 行に入るかもしれない → 広げる。
        if (end >= tail.length && stop < para.length && window < 1 << 18) {
          window *= 4;
          continue;
        }
        break;
      }
      // ── 意味の切れ目まで戻す (= ユーザー要望) ──
      //   行の終わり側に句読点などがあれば、 そこまでで折る。
      //   戻し過ぎると隙間だらけになるので、 行の 6 割より後ろだけ見る。
      if (offset + end < para.length) {
        final floor = (end * 0.6).floor();
        for (var i = end - 1; i > floor; i--) {
          if (breakAfter.contains(tail[i])) {
            end = i + 1;
            break;
          }
        }
      }
      final line = tail.substring(0, end);
      if (firstLine) {
        out.write(line);
      } else {
        // 行頭に回った空白は落とす (戻した所が空白だった時に効く)。
        out.write('\n');
        out.write(line.trimLeft());
      }
      firstLine = false;
      offset += end;
    }
  }
  return out.toString();
}

/// 紙に置いた文字 1 行の高さ。 罫線を引いた紙では罫線の間隔に合わせる。
///
/// 画面側 `_PaintPageViewState._paintTextHeightFactor` と**同じ規則**
/// (ずれると、 送った行数ぶん下げたつもりでも行が重なる / 隙間が空く)。
double canvasTextLineHeight(double fontSize, double ruleSpacing) {
  if (ruleSpacing > 0 && fontSize > 0) {
    final f = (ruleSpacing / fontSize).clamp(1.0, 6.0).toDouble();
    return f * fontSize;
  }
  return fontSize * 1.2;
}
