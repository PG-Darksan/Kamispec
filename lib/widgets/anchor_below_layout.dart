import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// カーソルの下 (入り切らなければ上) に子を置く配置係。
///
/// ★ = ユーザー要望「右クリックから図形の挿入を押した際のパレットは端子と
///   同じ様にカーソルの下 (画面に入らなければ上) に出る様に」。
///   中身の大きさを測ってから位置を決めるので、 段数の変わる札でも画面から
///   はみ出さない。 [CustomSingleChildLayout] に渡して使う。
class AnchorBelowLayout extends SingleChildLayoutDelegate {
  const AnchorBelowLayout(this.anchor, {this.gap = 14, this.margin = 8});

  /// 基準にする位置 (親の中での座標)。
  final Offset anchor;

  /// 基準から縦に離す量。
  final double gap;

  /// 画面の縁から空ける量。
  final double margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) => BoxConstraints(
        maxWidth: (c.maxWidth - margin * 2).clamp(0.0, double.infinity),
        maxHeight: (c.maxHeight - margin * 2).clamp(0.0, double.infinity),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var top = anchor.dy + gap;
    if (top + childSize.height > size.height - margin) {
      // 下に入らない → 上へ。 上にも入らなければ画面の中へ寄せる。
      final above = anchor.dy - gap - childSize.height;
      top = above >= margin
          ? above
          : (size.height - childSize.height - margin)
              .clamp(margin, math.max(margin, size.height));
    }
    final maxLeft = math.max(margin, size.width - childSize.width - margin);
    final left = (anchor.dx - childSize.width / 2).clamp(margin, maxLeft);
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(AnchorBelowLayout old) =>
      old.anchor != anchor || old.gap != gap || old.margin != margin;
}
