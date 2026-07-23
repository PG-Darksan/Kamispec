import 'package:flutter/material.dart';
import '../models/mind_map_node.dart';

class ConnectionPainter extends CustomPainter {
  final Map<String, MindMapNode> nodes;
  final List<NodeConnection> connections;

  /// 選択中の接続（複数選択対応）
  final Set<NodeConnection> selectedConnections;

  /// Ctrl/Meta で個別選択された直角リンクの節点番号。
  /// 選択済み節点だけを強く描画し、一括移動の対象を判別できるようにする。
  final Map<NodeConnection, Set<int>> selectedBendIndices;

  /// ダークモード設定。ライトモードでは pale な黄色の接続線が白背景に
  /// 溶けて見えなくなるため、ノード背景と同様に濃いアンバーへ補正する。
  final bool isDarkMode;

  /// 古い接続データや未設定接続に使うフォールバック線種。
  /// 個々の接続は [NodeConnection.lineStyle] を優先する。
  ///   'curve'    = 従来のベジェ曲線 (既定)
  ///   'straight' = 直線
  ///   'elbow'    = 直角に折れ曲がる線 (フローチャート風)
  final String lineStyle;

  ConnectionPainter({
    required this.nodes,
    required this.connections,
    Set<NodeConnection>? selectedConnections,
    Map<NodeConnection, Set<int>>? selectedBendIndices,
    this.isDarkMode = true,
    this.lineStyle = 'curve',
  })  : selectedConnections = selectedConnections ?? {},
        selectedBendIndices = selectedBendIndices ?? const {};

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

      final p1 = _connectionAnchor(
          from, conn.fromAnchor, conn.fromTableSide, conn.fromTableIndex);
      final p2 = _connectionAnchor(
          to, conn.toAnchor, conn.toTableSide, conn.toTableIndex);
      final style = conn.lineStyle ?? lineStyle;

      // ── 直角折れ線は各セグメントへの距離で判定 ──
      if (style == 'elbow') {
        final pts = elbowPointsFor(conn, from, to);
        double d = double.infinity;
        for (int i = 0; i < pts.length - 1; i++) {
          final sd = _distToSegment(point, pts[i], pts[i + 1]);
          if (sd < d) d = sd;
        }
        if (d < best) {
          best = d;
          result = conn;
        }
        continue;
      }

      final Offset cp1, cp2;
      if (style == 'straight') {
        // 制御点を線分上に置くとベジェは直線に退化する (描画と同一形状)。
        cp1 = Offset.lerp(p1, p2, 1 / 3)!;
        cp2 = Offset.lerp(p1, p2, 2 / 3)!;
      } else {
        final dist0 = (p1 - p2).distance;
        final strength = (dist0 * 0.4).clamp(30.0, 150.0);
        cp1 = p1 + _controlOffset(conn.fromAnchor, strength);
        cp2 = p2 + _controlOffset(conn.toAnchor, strength);
      }

      final dist = _distToCubic(point, p1, cp1, cp2, p2);
      if (dist < best) {
        best = dist;
        result = conn;
      }
    }
    return result;
  }

  static List<Offset> elbowPointsFor(
      NodeConnection conn, MindMapNode from, MindMapNode to) {
    final p1 = _connectionAnchor(
        from, conn.fromAnchor, conn.fromTableSide, conn.fromTableIndex);
    final p2 = _connectionAnchor(
        to, conn.toAnchor, conn.toTableSide, conn.toTableIndex);
    if (conn.elbowBendPoints.isNotEmpty) {
      return [p1, ...conn.elbowBendPoints, p2];
    }
    return _generatedElbowPoints(
      p1,
      p2,
      conn.fromAnchor,
      ratio: conn.elbowSplitRatio,
      count: conn.elbowPointCount,
    );
  }

  /// 接続線上の [position] (0..1) に対応する座標。ラベル描画とドラッグで共有する。
  static Offset pointOnConnection(
    NodeConnection conn,
    MindMapNode from,
    MindMapNode to, {
    String fallbackLineStyle = 'curve',
    double? position,
  }) {
    final t = (position ?? conn.labelPosition).clamp(0.0, 1.0).toDouble();
    final p1 = _connectionAnchor(
        from, conn.fromAnchor, conn.fromTableSide, conn.fromTableIndex);
    final p2 = _connectionAnchor(
        to, conn.toAnchor, conn.toTableSide, conn.toTableIndex);
    final style = conn.lineStyle ?? fallbackLineStyle;
    if (style == 'elbow') {
      final points = elbowPointsFor(conn, from, to);
      final lengths = <double>[];
      var total = 0.0;
      for (int i = 0; i < points.length - 1; i++) {
        final length = (points[i + 1] - points[i]).distance;
        lengths.add(length);
        total += length;
      }
      if (total <= 0.001) return p1;
      var remaining = total * t;
      for (int i = 0; i < lengths.length; i++) {
        if (remaining <= lengths[i] || i == lengths.length - 1) {
          final localT = lengths[i] <= 0.001 ? 0.0 : remaining / lengths[i];
          return Offset.lerp(
              points[i], points[i + 1], localT.clamp(0.0, 1.0).toDouble())!;
        }
        remaining -= lengths[i];
      }
      return p2;
    }
    if (style == 'straight') return Offset.lerp(p1, p2, t)!;
    final dist = (p1 - p2).distance;
    final strength = (dist * 0.4).clamp(30.0, 150.0);
    final cp1 = p1 + _controlOffset(conn.fromAnchor, strength);
    final cp2 = p2 + _controlOffset(conn.toAnchor, strength);
    final mt = 1.0 - t;
    return Offset(
      mt * mt * mt * p1.dx +
          3 * mt * mt * t * cp1.dx +
          3 * mt * t * t * cp2.dx +
          t * t * t * p2.dx,
      mt * mt * mt * p1.dy +
          3 * mt * mt * t * cp1.dy +
          3 * mt * t * t * cp2.dy +
          t * t * t * p2.dy,
    );
  }

  /// ポインタに最も近い線上の位置を返す。直接ラベルをドラッグする際に使う。
  static double closestPositionOnConnection(
    Offset point,
    NodeConnection conn,
    MindMapNode from,
    MindMapNode to, {
    String fallbackLineStyle = 'curve',
  }) {
    const samples = 100;
    var bestT = conn.labelPosition;
    var bestDistance = double.infinity;
    for (int i = 0; i <= samples; i++) {
      final t = i / samples;
      final p = pointOnConnection(conn, from, to,
          fallbackLineStyle: fallbackLineStyle, position: t);
      final d = (p - point).distanceSquared;
      if (d < bestDistance) {
        bestDistance = d;
        bestT = t;
      }
    }
    return bestT.clamp(0.02, 0.98).toDouble();
  }

  static Offset _connectionAnchor(
    MindMapNode node,
    AnchorDirection fallback,
    String? tableSide,
    int? tableIndex,
  ) {
    final table = node.tableData;
    if (table == null || tableSide == null || tableIndex == null) {
      return node.anchorPoint(fallback);
    }
    final rowCount = table.rowCount <= 0 ? 1 : table.rowCount;
    final colCount = table.colCount <= 0 ? 1 : table.colCount;
    final gridLeft = node.position.dx + 14.0;
    final gridRight = node.position.dx + node.width - 14.0;
    final gridTop = node.position.dy + node.estimateTableTitleBarHeight();
    final gridHeight = table.totalHeight;
    final gridBottom = gridTop + gridHeight;
    final gridWidth = (gridRight - gridLeft).clamp(1.0, double.infinity);
    switch (tableSide) {
      case 'left':
        final i = tableIndex.clamp(0, rowCount - 1);
        return Offset(gridLeft, gridTop + gridHeight * (i + 0.5) / rowCount);
      case 'right':
        final i = tableIndex.clamp(0, rowCount - 1);
        return Offset(gridRight, gridTop + gridHeight * (i + 0.5) / rowCount);
      case 'top':
        final i = tableIndex.clamp(0, colCount - 1);
        return Offset(gridLeft + gridWidth * (i + 0.5) / colCount, gridTop);
      case 'bottom':
        final i = tableIndex.clamp(0, colCount - 1);
        return Offset(gridLeft + gridWidth * (i + 0.5) / colCount, gridBottom);
    }
    return node.anchorPoint(fallback);
  }

  /// 直角折れ線の経由点 (p1 → 中間節点 → p2)。
  /// 始点アンカーの向きで「先に水平 / 先に垂直」 を決める。
  static List<Offset> _generatedElbowPoints(
    Offset p1,
    Offset p2,
    AnchorDirection fromDir, {
    double ratio = 0.5,
    int count = 2,
  }) {
    bool horizontalFirst;
    switch (fromDir) {
      case AnchorDirection.east:
      case AnchorDirection.west:
        horizontalFirst = true;
        break;
      case AnchorDirection.north:
      case AnchorDirection.south:
        horizontalFirst = false;
        break;
      default:
        horizontalFirst = (p2.dx - p1.dx).abs() >= (p2.dy - p1.dy).abs();
    }
    final bends = <Offset>[];
    final n = count.clamp(1, 8).toInt();
    final r = ratio.clamp(0.1, 0.9).toDouble();
    var cur = p1;
    var horizontal = horizontalFirst;
    for (int i = 0; i < n; i++) {
      final isLast = i == n - 1;
      final firstT = i == 0 ? r : (i + 1) / (n + 1);
      if (horizontal) {
        final x = isLast ? p2.dx : p1.dx + (p2.dx - p1.dx) * firstT;
        cur = Offset(x, cur.dy);
      } else {
        final y = isLast ? p2.dy : p1.dy + (p2.dy - p1.dy) * firstT;
        cur = Offset(cur.dx, y);
      }
      bends.add(cur);
      horizontal = !horizontal;
    }
    return [p1, ...bends, p2];
  }

  /// アンカー方向に応じたコントロールポイントのオフセット
  static Offset _controlOffset(AnchorDirection dir, double s) {
    switch (dir) {
      case AnchorDirection.north:
        return Offset(0, -s);
      case AnchorDirection.south:
        return Offset(0, s);
      case AnchorDirection.east:
        return Offset(s, 0);
      case AnchorDirection.west:
        return Offset(-s, 0);
      case AnchorDirection.northEast:
        return Offset(s * 0.7, -s * 0.7);
      case AnchorDirection.northWest:
        return Offset(-s * 0.7, -s * 0.7);
      case AnchorDirection.southEast:
        return Offset(s * 0.7, s * 0.7);
      case AnchorDirection.southWest:
        return Offset(-s * 0.7, s * 0.7);
    }
  }

  /// 三次ベジェ曲線上の最近傍距離を近似計算（20分割）
  double _distToCubic(Offset p, Offset p0, Offset c1, Offset c2, Offset p1) {
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

      final p1 = _connectionAnchor(
          from, conn.fromAnchor, conn.fromTableSide, conn.fromTableIndex);
      final p2 = _connectionAnchor(
          to, conn.toAnchor, conn.toTableSide, conn.toTableIndex);
      final style = conn.lineStyle ?? lineStyle;

      // ── 線スタイルごとの形状 (= ユーザー要望: 直線 / 直角折れ限定設定) ──
      // elbow は折れ線 (poly)、 straight は制御点を線分上に置いた退化ベジェ、
      // curve は従来のアンカー方向ベジェ。 cp1/cp2 は矢印の向き・ラベル位置の
      // 計算にも使うため、 elbow では末端セグメントの反対側の点を割り当てる。
      List<Offset>? poly;
      final Offset cp1, cp2;
      if (style == 'elbow') {
        poly = elbowPointsFor(conn, from, to);
        cp1 = poly.length > 2 ? poly[1] : Offset.lerp(p1, p2, 1 / 3)!;
        cp2 = poly.length > 2
            ? poly[poly.length - 2]
            : Offset.lerp(p1, p2, 2 / 3)!;
      } else if (style == 'straight') {
        cp1 = Offset.lerp(p1, p2, 1 / 3)!;
        cp2 = Offset.lerp(p1, p2, 2 / 3)!;
      } else {
        final dist = (p1 - p2).distance;
        final strength = (dist * 0.4).clamp(30.0, 150.0);
        cp1 = p1 + _controlOffset(conn.fromAnchor, strength);
        cp2 = p2 + _controlOffset(conn.toAnchor, strength);
      }

      // 折れ線/ベジェ共通の線パス生成 (始端/終端は矢印ぶん短縮できる)。
      Path buildLine(Offset start, Offset end) {
        final path = Path()..moveTo(start.dx, start.dy);
        if (poly != null) {
          for (int i = 1; i < poly.length - 1; i++) {
            path.lineTo(poly[i].dx, poly[i].dy);
          }
          path.lineTo(end.dx, end.dy);
        } else {
          path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, end.dx, end.dy);
        }
        return path;
      }

      final configuredColor =
          conn.lineColorValue == null ? to.color : Color(conn.lineColorValue!);
      final paint = Paint()
        ..color = isSelected
            ? Colors.redAccent.withValues(alpha: 0.95)
            : _effectiveLineColor(configuredColor).withValues(alpha: 0.82)
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
        canvas.drawPath(buildLine(p1, p2), glowPaint);
      }

      // ── 線の終端を矢印の根元まで短縮して描画 ──
      if (conn.showArrow) {
        final arrowLen = (10.0 + conn.strokeWidth * 2.0) * conn.arrowHeadScale;
        final dir2 = p2 - cp2;
        final d2 = dir2.distance;
        final tip = p2;
        final base = d2 > 0.001 ? p2 - (dir2 / d2) * arrowLen : p2;
        // ── 始点側の矢印 (両方向の場合) ──
        // bidirectional == true なら from 側にも矢印を描画する。
        // 線の始点も矢印の根元までずらす必要がある。
        Offset lineStart = p1;
        if (conn.bidirectional) {
          final dir1 = p1 - cp1;
          final d1 = dir1.distance;
          final base1 = d1 > 0.001 ? p1 - (dir1 / d1) * arrowLen : p1;
          lineStart = base1;
          _drawFilledArrow(canvas, cp1, p1, paint.color, conn.strokeWidth,
              conn.arrowHeadScale);
        }
        // 線は矢印の根元まで
        canvas.drawPath(buildLine(lineStart, base), paint);
        _drawFilledArrow(canvas, cp2, tip, paint.color, conn.strokeWidth,
            conn.arrowHeadScale);
      } else {
        canvas.drawPath(buildLine(p1, p2), paint);
      }

      // ── 始点に丸印を描画 ──
      // 両方向矢印の場合は丸印を描画しない (= 矢印で十分視覚的に区別できる)
      if (!conn.bidirectional) {
        final dotRadius = (conn.strokeWidth * 1.2).clamp(3.0, 8.0);
        final dotPaint = Paint()
          ..color = isSelected
              ? Colors.redAccent.withValues(alpha: 0.9)
              : _effectiveLineColor(conn.lineColorValue == null
                      ? (nodes[conn.fromId]?.color ?? paint.color)
                      : Color(conn.lineColorValue!))
                  .withValues(alpha: 0.8)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(p1, dotRadius, dotPaint);
        final dotBorder = Paint()
          ..color = Colors.white.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0;
        canvas.drawCircle(p1, dotRadius, dotBorder);
      }

      // ── 直角リンクの中間節点ハンドル ──
      // 選択中だけ表示し、画面側のヒットテストでこの点をドラッグできる。
      if (isSelected && style == 'elbow' && poly != null && poly.length > 2) {
        final selectedIndices = selectedBendIndices[conn] ?? const <int>{};
        for (int i = 1; i < poly.length - 1; i++) {
          final isBendSelected = selectedIndices.contains(i - 1);
          final radius = isBendSelected ? 8.0 : 5.5;
          final handleFill = Paint()
            ..color = isBendSelected
                ? const Color(0xFFFFB74D)
                : const Color(0xFF80CBC4).withValues(alpha: 0.82)
            ..style = PaintingStyle.fill;
          final handleBorder = Paint()
            ..color = Colors.white.withValues(alpha: 0.95)
            ..style = PaintingStyle.stroke
            ..strokeWidth = isBendSelected ? 2.2 : 1.4;
          canvas.drawCircle(poly[i], radius, handleFill);
          canvas.drawCircle(poly[i], radius, handleBorder);
        }
      }

      // ── ラベルを線の中央に描画 ──
      // 線のラベル (= 関係の名称等) を中央の制御点周辺に表示。
      if (conn.label != null && conn.label!.isNotEmpty) {
        final midPoint =
            pointOnConnection(conn, from, to, fallbackLineStyle: lineStyle);
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
          maxLines: 8,
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
            : _effectiveLineColor(configuredColor).withValues(alpha: 0.95);
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
        if (isSelected) {
          final handlePaint = Paint()
            ..color = Colors.white
            ..style = PaintingStyle.fill;
          canvas.drawCircle(midPoint, 4.0, handlePaint);
        }
      }
    }
  }

  /// 塗りつぶし矢印ヘッドを描画（→型の大きな三角形）
  void _drawFilledArrow(Canvas canvas, Offset from, Offset tip, Color color,
      double strokeWidth, double scale) {
    // 矢印サイズ: 線の太さに応じてスケール、さらにユーザー設定倍率を乗算
    final arrowLength = (12.0 + strokeWidth * 2.5) * scale; // 矢印の長さ
    final arrowWidth = (8.0 + strokeWidth * 2.0) * scale; // 矢印の幅（片側）
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
      oldDelegate.selectedBendIndices != selectedBendIndices ||
      oldDelegate.isDarkMode != isDarkMode ||
      oldDelegate.lineStyle != lineStyle;
}
