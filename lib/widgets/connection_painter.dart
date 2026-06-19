import 'package:flutter/material.dart';
import '../models/mind_map_node.dart';

class ConnectionPainter extends CustomPainter {
  final Map<String, MindMapNode> nodes;
  final List<NodeConnection> connections;

  /// 選択中の接続（複数選択対応）
  final Set<NodeConnection> selectedConnections;

  /// ダークモード設定。ライトモードでは pale な黄色の接続線が白背景に
  /// 溶けて見えなくなるため、ノード背景と同様に濃いアンバーへ補正する。
  final bool isDarkMode;

  ConnectionPainter({
    required this.nodes,
    required this.connections,
    Set<NodeConnection>? selectedConnections,
    this.isDarkMode = true,
  }) : selectedConnections = selectedConnections ?? {};

  /// 接続線の表示色を計算。黄色系の色は視認性が低いためユーザー要望により
  /// 全廃。pale な黄色を ブラック(Blue Gray 900) に置き換える。
  /// ダーク/ライトモード両方で適用。
  Color _effectiveLineColor(Color base) {
    final hsl = HSLColor.fromColor(base);
    if (hsl.hue >= 40 && hsl.hue <= 70 && hsl.lightness > 0.55) {
      return const Color(0xFF263238);
    }
    return base;
  }

  // ─── ヒットテスト用：接続をクリックしたか判定 ───────────────────────────────

  /// [point] がいずれかの接続線の近傍にあるか判定し、
  /// 最も近い接続を返す。なければ null。
  NodeConnection? findConnection(Offset point) {
    NodeConnection? result;
    double best = 14.0;

    for (final conn in connections) {
      final from = nodes[conn.fromId];
      final to = nodes[conn.toId];
      if (from == null || to == null) continue;

      final p1 = from.anchorPoint(conn.fromAnchor);
      final p2 = to.anchorPoint(conn.toAnchor);
      final dist0 = (p1 - p2).distance;
      final strength = (dist0 * 0.4).clamp(30.0, 150.0);
      final cp1 = p1 + _controlOffset(conn.fromAnchor, strength);
      final cp2 = p2 + _controlOffset(conn.toAnchor, strength);

      final dist = _distToCubic(point, p1, cp1, cp2, p2);
      if (dist < best) {
        best = dist;
        result = conn;
      }
    }
    return result;
  }

  /// アンカー方向に応じたコントロールポイントのオフセット
  static Offset _controlOffset(AnchorDirection dir, double s) {
    switch (dir) {
      case AnchorDirection.north:     return Offset(0, -s);
      case AnchorDirection.south:     return Offset(0, s);
      case AnchorDirection.east:      return Offset(s, 0);
      case AnchorDirection.west:      return Offset(-s, 0);
      case AnchorDirection.northEast: return Offset(s * 0.7, -s * 0.7);
      case AnchorDirection.northWest: return Offset(-s * 0.7, -s * 0.7);
      case AnchorDirection.southEast: return Offset(s * 0.7, s * 0.7);
      case AnchorDirection.southWest: return Offset(-s * 0.7, s * 0.7);
    }
  }

  /// 三次ベジェ曲線上の最近傍距離を近似計算（20分割）
  double _distToCubic(
      Offset p, Offset p0, Offset c1, Offset c2, Offset p1) {
    double minDist = double.infinity;
    const steps = 20;
    Offset prev = p0;
    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      final mt = 1 - t;
      final next = Offset(
        mt * mt * mt * p0.dx +
            3 * mt * mt * t * c1.dx +
            3 * mt * t * t * c2.dx +
            t * t * t * p1.dx,
        mt * mt * mt * p0.dy +
            3 * mt * mt * t * c1.dy +
            3 * mt * t * t * c2.dy +
            t * t * t * p1.dy,
      );
      final d = _distToSegment(p, prev, next);
      if (d < minDist) minDist = d;
      prev = next;
    }
    return minDist;
  }

  double _distToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final ap = p - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / len2).clamp(0.0, 1.0);
    final proj = a + ab * t;
    return (p - proj).distance;
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final conn in connections) {
      final from = nodes[conn.fromId];
      final to = nodes[conn.toId];
      if (from == null || to == null) continue;

      final isSelected = selectedConnections.contains(conn);

      final p1 = from.anchorPoint(conn.fromAnchor);
      final p2 = to.anchorPoint(conn.toAnchor);

      final dist = (p1 - p2).distance;
      final strength = (dist * 0.4).clamp(30.0, 150.0);
      final cp1 = p1 + _controlOffset(conn.fromAnchor, strength);
      final cp2 = p2 + _controlOffset(conn.toAnchor, strength);

      final paint = Paint()
        ..color = isSelected
            ? Colors.redAccent.withValues(alpha: 0.95)
            : _effectiveLineColor(to.color).withValues(alpha: 0.6)
        ..strokeWidth = isSelected ? (conn.strokeWidth + 1.0) : conn.strokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      if (isSelected) {
        final glowPaint = Paint()
          ..color = Colors.redAccent.withValues(alpha: 0.25)
          ..strokeWidth = conn.strokeWidth + 8.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
        final glowPath = Path()
          ..moveTo(p1.dx, p1.dy)
          ..cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
        canvas.drawPath(glowPath, glowPaint);
      }

      // ── 線の終端を矢印の根元まで短縮して描画 ──
      if (conn.showArrow) {
        final arrowLen =
            (10.0 + conn.strokeWidth * 2.0) * conn.arrowHeadScale;
        final dir2 = p2 - cp2;
        final d2 = dir2.distance;
        final tip = p2;
        final base = d2 > 0.001
            ? p2 - (dir2 / d2) * arrowLen
            : p2;
        // ── 始点側の矢印 (両方向の場合) ──
        // bidirectional == true なら from 側にも矢印を描画する。
        // 線の始点も矢印の根元までずらす必要がある。
        Offset lineStart = p1;
        if (conn.bidirectional) {
          final dir1 = p1 - cp1;
          final d1 = dir1.distance;
          final base1 = d1 > 0.001 ? p1 - (dir1 / d1) * arrowLen : p1;
          lineStart = base1;
          _drawFilledArrow(canvas, cp1, p1, paint.color,
              conn.strokeWidth, conn.arrowHeadScale);
        }
        // 線は矢印の根元まで
        final linePath = Path()
          ..moveTo(lineStart.dx, lineStart.dy)
          ..cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, base.dx, base.dy);
        canvas.drawPath(linePath, paint);
        _drawFilledArrow(canvas, cp2, tip, paint.color, conn.strokeWidth,
            conn.arrowHeadScale);
      } else {
        final linePath = Path()
          ..moveTo(p1.dx, p1.dy)
          ..cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
        canvas.drawPath(linePath, paint);
      }

      // ── 始点に丸印を描画 ──
      // 両方向矢印の場合は丸印を描画しない (= 矢印で十分視覚的に区別できる)
      if (!conn.bidirectional) {
        final dotRadius = (conn.strokeWidth * 1.2).clamp(3.0, 8.0);
        final dotPaint = Paint()
          ..color = isSelected
              ? Colors.redAccent.withValues(alpha: 0.9)
              : _effectiveLineColor(
                      nodes[conn.fromId]?.color ?? paint.color)
                  .withValues(alpha: 0.8)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(p1, dotRadius, dotPaint);
        final dotBorder = Paint()
          ..color = Colors.white.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;
        canvas.drawCircle(p1, dotRadius, dotBorder);
      }

      // ── ラベルを線の中央に描画 ──
      // 線のラベル (= 関係の名称等) を中央の制御点周辺に表示。
      if (conn.label != null && conn.label!.isNotEmpty) {
        // 線の中央点 (= ベジェ曲線の t=0.5 の位置を近似)
        final midPoint = Offset(
          (p1.dx + 3 * cp1.dx + 3 * cp2.dx + p2.dx) / 8,
          (p1.dy + 3 * cp1.dy + 3 * cp2.dy + p2.dy) / 8,
        );
        final textPainter = TextPainter(
          text: TextSpan(
            text: conn.label,
            style: TextStyle(
              color: Colors.white,
              fontSize: 12 + conn.strokeWidth * 0.5,
              fontWeight: FontWeight.w700,
              shadows: const [
                Shadow(
                    color: Colors.black54, blurRadius: 2, offset: Offset(0, 1)),
              ],
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 2,
        )..layout(maxWidth: 200);
        // ── ラベル背景 ──
        // ノードと同じ色感を持たせるため、 接続先ノードの色をベースに描画。
        // 選択中なら赤系、 それ以外なら to.color (= 接続線と同じ色) を使い、
        // 黄色系は視認性のため _effectiveLineColor で補正された色を使う。
        final labelRect = Rect.fromCenter(
          center: midPoint,
          width: textPainter.width + 14,
          height: textPainter.height + 8,
        );
        final bgColor = isSelected
            ? Colors.redAccent.withValues(alpha: 0.95)
            : _effectiveLineColor(to.color).withValues(alpha: 0.95);
        final bgPaint = Paint()..color = bgColor;
        canvas.drawRRect(
            RRect.fromRectAndRadius(labelRect, const Radius.circular(8)),
            bgPaint);
        // ── 縁取り (= ノード境界感を出す) ──
        final borderPaint = Paint()
          ..color = Colors.white.withValues(alpha: 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;
        canvas.drawRRect(
            RRect.fromRectAndRadius(labelRect, const Radius.circular(8)),
            borderPaint);
        textPainter.paint(
            canvas,
            Offset(midPoint.dx - textPainter.width / 2,
                midPoint.dy - textPainter.height / 2));
      }
    }
  }

  /// 塗りつぶし矢印ヘッドを描画（→型の大きな三角形）
  void _drawFilledArrow(Canvas canvas, Offset from, Offset tip,
      Color color, double strokeWidth, double scale) {
    // 矢印サイズ: 線の太さに応じてスケール、さらにユーザー設定倍率を乗算
    final arrowLength = (12.0 + strokeWidth * 2.5) * scale; // 矢印の長さ
    final arrowWidth = (8.0 + strokeWidth * 2.0) * scale;   // 矢印の幅（片側）
    final dist = (from - tip).distance;
    if (dist < 0.001) return;

    // 方向ベクトル（from→tip）
    final dx = (tip.dx - from.dx) / dist;
    final dy = (tip.dy - from.dy) / dist;
    // 垂直ベクトル
    final nx = -dy;
    final ny = dx;

    // 矢印の根元
    final baseX = tip.dx - dx * arrowLength;
    final baseY = tip.dy - dy * arrowLength;
    // 矢印の内側のくぼみ（→型にするため）
    final indentX = tip.dx - dx * arrowLength * 0.6;
    final indentY = tip.dy - dy * arrowLength * 0.6;

    // 三角形の左右の点
    final leftX = baseX + nx * arrowWidth;
    final leftY = baseY + ny * arrowWidth;
    final rightX = baseX - nx * arrowWidth;
    final rightY = baseY - ny * arrowWidth;

    final arrowPath = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(leftX, leftY)
      ..lineTo(indentX, indentY)
      ..lineTo(rightX, rightY)
      ..close();

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawPath(arrowPath, fillPaint);

    // 矢印の輪郭
    final outlinePaint = Paint()
      ..color = color.withValues(alpha: 1.0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(arrowPath, outlinePaint);
  }

  @override
  bool shouldRepaint(ConnectionPainter oldDelegate) =>
      oldDelegate.nodes != nodes ||
      oldDelegate.connections != connections ||
      oldDelegate.selectedConnections != selectedConnections ||
      oldDelegate.isDarkMode != isDarkMode;
}
