// dart:ui を直接 import すると TextStyle 等が flutter/painting.dart と
// 衝突するため、 painting.dart のみインポートする (これだけで Color /
// Offset / Size / TextPainter / TextSpan / TextStyle / FontWeight /
// TextDirection など本ファイルで必要なシンボルが全部入る)。
import 'dart:convert';
import 'package:flutter/painting.dart';

enum NodeContentType { none, memo, youtube, link, attachment, table }

/// PDF / 添付ファイル / リンク先サイトに対するメモ。
///
/// 1 ノードに複数のメモを紐づけられる。 ユーザーは PDF をアプリ内ビューア
/// で開き、 任意のページ + 位置（ページ上の比率座標）でメモを追加できる。
/// URL を開いている時は [url] にその URL を保存することで、 「サイトを
/// 見ながら残したメモ」 も同じノードにぶら下げられる。 メモは:
///   - ビューア内: 該当ページ / 該当 URL に [xRatio]/[yRatio] でマーカー
///     オーバーレイ表示
///   - マップの外: 「PDFメモ一覧」 パネルから全メモを一覧表示
/// の両方で確認できるよう設計されている。
///
/// 座標系:
///   - [pageNumber]: 1-indexed のページ番号 (PDF 用)。 URL メモでは null。
///   - [url]: メモを記したサイトの URL (PDF メモでは null)。 PDF メモと
///     URL メモは [pageNumber] / [url] のどちらが入っているかで識別する。
///   - [xRatio] / [yRatio]: ビューア表示領域に対する 0.0〜1.0 の比率。
///     ピクセル絶対値ではなく比率にすることで、 ビューアの拡大率や
///     ウィンドウサイズが変わっても位置を保てる。
///     null の場合はリスト末尾のフリーメモ扱い。
class PdfMemo {
  final String id;
  String text;
  /// 1-indexed のページ番号。 URL メモでは null。
  int? pageNumber;
  /// URL メモの URL (PDF メモでは null)。
  /// 例: SPA で history が変わる場合があるため、 メモ追加時点でビューア内に
  /// ロードされていた URL をスナップショットして格納する。
  String? url;
  /// URL メモのスクロール位置 (Y方向ピクセル, 文書頂上からの距離)。
  /// メモ追加時のスクロール位置をスナップショットして、 メモジャンプ時に
  /// `window.scrollTo(0, scrollY)` で復元する。 PDF メモ / フリーメモでは null。
  double? scrollY;
  /// ビューア表示領域上の x 比率 (0.0=左端, 1.0=右端)。 null = ページ全体に
  /// 紐づく汎用メモ。
  double? xRatio;
  /// ビューア表示領域上の y 比率 (0.0=上端, 1.0=下端)。 null = 同上。
  double? yRatio;
  /// メモのアクセントカラー (マーカー色)。
  int colorValue;
  /// 作成 / 最終更新時刻 (UTC エポック ms)。
  int updatedAtMs;
  /// メモが属するフォルダ名 (null または '' = 未分類)。
  /// 既存メモに対しては null。 ユーザーがメモ一覧 UI からフォルダを
  /// 作成・移動させるときに設定される。 同じ folder 名のメモは
  /// メモ一覧でグループ化される。
  String? folder;
  /// ピン止めフラグ。 true のメモはメモ一覧の (フォルダ内の) 先頭に表示される。
  bool pinned;

  PdfMemo({
    required this.id,
    required this.text,
    this.pageNumber,
    this.url,
    this.scrollY,
    this.xRatio,
    this.yRatio,
    this.colorValue = 0xFFFFC107, // amber
    int? updatedAtMs,
    this.folder,
    this.pinned = false,
  }) : updatedAtMs =
            updatedAtMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;

  PdfMemo copyWith({
    String? text,
    int? pageNumber,
    Object? url = _sentinel,
    Object? scrollY = _sentinel,
    Object? xRatio = _sentinel,
    Object? yRatio = _sentinel,
    int? colorValue,
    int? updatedAtMs,
    Object? folder = _sentinel,
    bool? pinned,
  }) =>
      PdfMemo(
        id: id,
        text: text ?? this.text,
        pageNumber: pageNumber ?? this.pageNumber,
        url: url == _sentinel ? this.url : url as String?,
        scrollY: scrollY == _sentinel ? this.scrollY : scrollY as double?,
        xRatio: xRatio == _sentinel ? this.xRatio : xRatio as double?,
        yRatio: yRatio == _sentinel ? this.yRatio : yRatio as double?,
        colorValue: colorValue ?? this.colorValue,
        updatedAtMs: updatedAtMs ?? this.updatedAtMs,
        folder: folder == _sentinel ? this.folder : folder as String?,
        pinned: pinned ?? this.pinned,
      );

  static const Object _sentinel = Object();

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (pageNumber != null) 'pageNumber': pageNumber,
        if (url != null) 'url': url,
        if (scrollY != null) 'scrollY': scrollY,
        if (xRatio != null) 'xRatio': xRatio,
        if (yRatio != null) 'yRatio': yRatio,
        'colorValue': colorValue,
        'updatedAtMs': updatedAtMs,
        if (folder != null && folder!.isNotEmpty) 'folder': folder,
        if (pinned) 'pinned': true,
      };

  factory PdfMemo.fromJson(Map<String, dynamic> json) => PdfMemo(
        id: json['id'] as String,
        text: (json['text'] as String?) ?? '',
        pageNumber: (json['pageNumber'] as num?)?.toInt(),
        url: json['url'] as String?,
        scrollY: (json['scrollY'] as num?)?.toDouble(),
        xRatio: (json['xRatio'] as num?)?.toDouble(),
        yRatio: (json['yRatio'] as num?)?.toDouble(),
        colorValue: (json['colorValue'] as num?)?.toInt() ?? 0xFFFFC107,
        updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ??
            DateTime.now().toUtc().millisecondsSinceEpoch,
        folder: json['folder'] as String?,
        pinned: (json['pinned'] as bool?) ?? false,
      );
}

/// ─── 表 (テーブル) データ ──────────────────────────────────────────────────
///
/// マインドマップノードに紐づく「表」 のデータ本体。
///
/// `MindMapNode.tableData` に保持する。 null = 通常ノード、 非 null = 表ノード。
/// 表ノードはタイトル領域の下にグリッドが描画される。
///
/// 行/列の追加・削除は `insertRow` / `removeRow` / `insertColumn` /
/// `removeColumn` で行う (最低 1 行・1 列は保持して空テーブル化を防ぐ)。
///
/// JSON シリアライズは `toJson` / `fromJson` で対応し、 既存マップとの後方
/// 互換のため `MindMapNode.toJson` 側は `if (tableData != null)` で囲って
/// 出力する (= 旧マップは tableData キーを持たない)。
class TableData {
  /// セル本体。 `cells[row][col]` で参照する (0-indexed)。
  /// 全行で col 数は揃っている前提で扱う (整合性は内部メソッドで保証)。
  List<List<String>> cells;

  /// 列のデフォルト幅 (px)。 個別指定は [colWidths] で。
  double defaultColWidth;
  /// 行のデフォルト高さ (px)。 個別指定は [rowHeights] で。
  double defaultRowHeight;

  /// 列ごとのカスタム幅 (長さは colCount と同じ)。 null/負値はデフォルトを使う。
  List<double?> colWidths;
  /// 行ごとのカスタム高さ (長さは rowCount と同じ)。 null/負値はデフォルトを使う。
  List<double?> rowHeights;

  /// 先頭行をヘッダー (太字 + 強調背景) にするか。
  bool headerRow;
  /// 先頭列をヘッダー (太字 + 強調背景) にするか。
  bool headerCol;

  /// 罫線色 (ARGB int)。
  int borderColorValue;
  /// 罫線の太さ (px)。
  double borderWidth;

  TableData({
    required this.cells,
    this.defaultColWidth = 100.0,
    this.defaultRowHeight = 36.0,
    List<double?>? colWidths,
    List<double?>? rowHeights,
    this.headerRow = false,
    this.headerCol = false,
    this.borderColorValue = 0xFF888888,
    this.borderWidth = 1.5,
  })  : colWidths = colWidths ??
            List<double?>.filled(
                cells.isEmpty ? 0 : cells[0].length, null,
                growable: true),
        rowHeights = rowHeights ??
            List<double?>.filled(cells.length, null, growable: true);

  // ─── 行高さの内容ベース推定 + キャッシュ ───────────────────────────────
  //
  // セルが内容に応じて縦に伸びる仕様 (ユーザー要望「セルに入りきらない場合
  // は全部入り切るようにセルを縦に伸ばす」) を成立させるには、 visualHeight
  // が実描画と一致する必要がある。 そのために TextPainter で各行の高さを
  // 推定する。 推定が描画と完全一致しないケース (フォント差分等) もある
  // ため、 安全側に小さなバッファ +2px を加算する。
  //
  // 推定結果は (cellWidth, fontSize) と内容のハッシュをキーにキャッシュ。
  // セル編集・行/列追加・削除のたびに _heightCacheDirty を true にして
  // 次回呼び出し時に再計算させる。

  bool _heightCacheDirty = true;
  double _cachedTotalHeight = 0;
  double? _cachedCellWidth;
  double? _cachedFontSize;

  /// セル内容を変更した直後に呼ぶ。 次回 estimateTotalHeight 呼び出し時に
  /// キャッシュを破棄して再計算させる。 外部からも呼べる (provider 側で
  /// updateNodeTable などから明示的に呼んでも OK)。
  void invalidateHeightCache() {
    _heightCacheDirty = true;
  }

  /// 行 [row] の高さを、 セル幅とフォントサイズから推定する。
  /// 内容が空または defaultRowHeight 以下なら defaultRowHeight。
  /// 内容が複数行に折り返した場合はそれに応じて伸ばす。
  double estimateRowHeight(int row,
      {required double cellWidth, required double fontSize}) {
    if (row < 0 || row >= rowCount) return defaultRowHeight;
    double maxH = defaultRowHeight;
    // セル内のテキスト描画領域 = セル幅 - 左右パディング (6+6 = 12)
    final textWidth = (cellWidth - 12.0).clamp(1.0, double.infinity);
    for (int c = 0; c < colCount; c++) {
      final text = cellAt(row, c);
      if (text.isEmpty) continue;
      final isHeader = (headerRow && row == 0) || (headerCol && c == 0);
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: isHeader ? FontWeight.w700 : FontWeight.w400,
            height: 1.3, // node_widget の Text と揃える
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: null,
      );
      tp.layout(maxWidth: textWidth);
      // 上下パディング (4+4 = 8) + 安全バッファ 2px
      final h = tp.size.height + 8.0 + 2.0;
      if (h > maxH) maxH = h;
    }
    return maxH;
  }

  /// 内容に基づいた表全体の高さ。
  /// (各行の estimateRowHeight 合計 + 罫線分)。 結果はキャッシュされる。
  double estimateTotalHeight(
      {required double cellWidth, required double fontSize}) {
    if (!_heightCacheDirty &&
        _cachedCellWidth == cellWidth &&
        _cachedFontSize == fontSize) {
      return _cachedTotalHeight;
    }
    if (rowCount == 0) {
      _cachedTotalHeight = 0;
      _cachedCellWidth = cellWidth;
      _cachedFontSize = fontSize;
      _heightCacheDirty = false;
      return 0;
    }
    double total = 0;
    for (int r = 0; r < rowCount; r++) {
      total += estimateRowHeight(r,
          cellWidth: cellWidth, fontSize: fontSize);
    }
    total += (rowCount + 1) * borderWidth;
    _cachedTotalHeight = total;
    _cachedCellWidth = cellWidth;
    _cachedFontSize = fontSize;
    _heightCacheDirty = false;
    return total;
  }

  /// 空の表を新規作成する (全セル空文字)。
  /// rows / cols は 1 以上に正規化。
  factory TableData.empty(int rows, int cols, {
    double colWidth = 100.0,
    double rowHeight = 36.0,
  }) {
    final r = rows < 1 ? 1 : rows;
    final c = cols < 1 ? 1 : cols;
    return TableData(
      cells: List.generate(r,
          (_) => List<String>.filled(c, '', growable: true),
          growable: true),
      defaultColWidth: colWidth,
      defaultRowHeight: rowHeight,
    );
  }

  int get rowCount => cells.length;
  int get colCount => cells.isEmpty ? 0 : cells[0].length;

  double rowHeightAt(int r) {
    if (r < 0 || r >= rowHeights.length) return defaultRowHeight;
    final h = rowHeights[r];
    return (h != null && h > 0) ? h : defaultRowHeight;
  }

  double colWidthAt(int c) {
    if (c < 0 || c >= colWidths.length) return defaultColWidth;
    final w = colWidths[c];
    return (w != null && w > 0) ? w : defaultColWidth;
  }

  /// テーブル全体の幅 (列幅 + 罫線分の合計)。
  ///
  /// ★ 設計変更後は colWidths[] オーバーライドを参照しない (= 常に
  /// `colCount × defaultColWidth + 罫線分`)。 描画側 (node_widget の
  /// _NodeTableInlineWidget) も「ノード幅 / 列数」 で等分割するため、
  /// 個別列幅のオーバーライドは廃止された。 後方互換のため colWidths[]
  /// 配列自体は残しているが、 totalWidth の計算には使わない。
  double get totalWidth {
    if (colCount == 0) return 0;
    return colCount * defaultColWidth + (colCount + 1) * borderWidth;
  }

  /// テーブル全体の高さ (行高さ + 罫線分の合計)。
  ///
  /// ★ 同じく、 rowHeights[] オーバーライドは参照せず常に
  /// `rowCount × defaultRowHeight + 罫線分`。 これで描画と完全一致する。
  double get totalHeight {
    if (rowCount == 0) return 0;
    return rowCount * defaultRowHeight + (rowCount + 1) * borderWidth;
  }

  String cellAt(int r, int c) {
    if (r < 0 || r >= rowCount) return '';
    if (c < 0 || c >= colCount) return '';
    return cells[r][c];
  }

  void setCell(int r, int c, String value) {
    if (r < 0 || r >= rowCount) return;
    if (c < 0 || c >= colCount) return;
    if (cells[r][c] == value) return;
    cells[r][c] = value;
    _heightCacheDirty = true;
  }

  /// 行を挿入。 index<0 → 先頭、 index>=rowCount → 末尾。
  void insertRow(int index) {
    final newRow = List<String>.filled(colCount, '', growable: true);
    final i = index < 0 ? 0 : (index > rowCount ? rowCount : index);
    cells.insert(i, newRow);
    rowHeights.insert(i, null);
    _heightCacheDirty = true;
  }

  /// 列を挿入。 index<0 → 左端、 index>=colCount → 右端。
  void insertColumn(int index) {
    final i = index < 0 ? 0 : (index > colCount ? colCount : index);
    for (final row in cells) {
      row.insert(i, '');
    }
    colWidths.insert(i, null);
    _heightCacheDirty = true; // 列追加で各セル幅が変わる → 行高さも変わる
  }

  /// 行を削除。 最低 1 行は保持。 削除できたら true。
  bool removeRow(int index) {
    if (rowCount <= 1) return false;
    if (index < 0 || index >= rowCount) return false;
    cells.removeAt(index);
    if (index < rowHeights.length) rowHeights.removeAt(index);
    _heightCacheDirty = true;
    return true;
  }

  /// 列を削除。 最低 1 列は保持。 削除できたら true。
  bool removeColumn(int index) {
    if (colCount <= 1) return false;
    if (index < 0 || index >= colCount) return false;
    for (final row in cells) {
      if (index < row.length) row.removeAt(index);
    }
    if (index < colWidths.length) colWidths.removeAt(index);
    _heightCacheDirty = true; // 列削除でセル幅が変わる → 行高さも変わる
    return true;
  }

  /// 行の高さを設定 (null でデフォルト)。
  void setRowHeight(int r, double? h) {
    if (r < 0 || r >= rowHeights.length) return;
    rowHeights[r] = h;
  }

  /// 列の幅を設定 (null でデフォルト)。
  void setColWidth(int c, double? w) {
    if (c < 0 || c >= colWidths.length) return;
    colWidths[c] = w;
  }

  Map<String, dynamic> toJson() => {
        'cells': cells,
        'defaultColWidth': defaultColWidth,
        'defaultRowHeight': defaultRowHeight,
        'colWidths': colWidths,
        'rowHeights': rowHeights,
        'headerRow': headerRow,
        'headerCol': headerCol,
        'borderColorValue': borderColorValue,
        'borderWidth': borderWidth,
      };

  factory TableData.fromJson(Map<String, dynamic> json) {
    final rawCells = json['cells'] as List<dynamic>? ?? const [];
    final cells = rawCells.map((row) {
      final r = row as List<dynamic>;
      return r.map((c) => c?.toString() ?? '').toList(growable: true);
    }).toList(growable: true);
    // 列数不整合があれば最長に揃える
    int maxCols = 0;
    for (final row in cells) {
      if (row.length > maxCols) maxCols = row.length;
    }
    for (final row in cells) {
      while (row.length < maxCols) {
        row.add('');
      }
    }
    if (cells.isEmpty) {
      cells.add(<String>['']);
      maxCols = 1;
    }

    final rawColW = json['colWidths'] as List<dynamic>?;
    final colWidths = rawColW != null
        ? rawColW
            .map((e) => (e as num?)?.toDouble())
            .toList(growable: true)
        : List<double?>.filled(maxCols, null, growable: true);
    while (colWidths.length <
        (cells.isEmpty ? 0 : cells[0].length)) {
      colWidths.add(null);
    }

    final rawRowH = json['rowHeights'] as List<dynamic>?;
    final rowHeights = rawRowH != null
        ? rawRowH
            .map((e) => (e as num?)?.toDouble())
            .toList(growable: true)
        : List<double?>.filled(cells.length, null, growable: true);
    while (rowHeights.length < cells.length) {
      rowHeights.add(null);
    }

    return TableData(
      cells: cells,
      defaultColWidth:
          (json['defaultColWidth'] as num?)?.toDouble() ?? 100.0,
      defaultRowHeight:
          (json['defaultRowHeight'] as num?)?.toDouble() ?? 36.0,
      colWidths: colWidths,
      rowHeights: rowHeights,
      headerRow: json['headerRow'] as bool? ?? false,
      headerCol: json['headerCol'] as bool? ?? false,
      borderColorValue:
          (json['borderColorValue'] as num?)?.toInt() ?? 0xFF888888,
      borderWidth: (json['borderWidth'] as num?)?.toDouble() ?? 1.5,
    );
  }
}


/// アンカーモード: 接続可能な方向の数
enum NodeAnchorMode {
  twoWay,   // 左右のみ (east, west)
  fourWay,  // 上下左右 (north, south, east, west)
  eightWay, // 8方向 (上下左右＋斜め)
}

/// ノードの接続方向
enum AnchorDirection {
  north, south, east, west,
  northEast, northWest, southEast, southWest,
}

/// アンカーモードで使用可能な方向のリスト
List<AnchorDirection> anchorsForMode(NodeAnchorMode mode) {
  switch (mode) {
    case NodeAnchorMode.twoWay:
      return [AnchorDirection.east, AnchorDirection.west];
    case NodeAnchorMode.fourWay:
      return [
        AnchorDirection.north, AnchorDirection.south,
        AnchorDirection.east, AnchorDirection.west,
      ];
    case NodeAnchorMode.eightWay:
      return AnchorDirection.values;
  }
}

/// 2ノード間の接続情報
class NodeConnection {
  final String fromId;
  final AnchorDirection fromAnchor;
  final String toId;
  final AnchorDirection toAnchor;
  /// 接続線の太さ（デフォルト2.0）
  final double strokeWidth;
  /// 矢印を表示するか（デフォルト true）
  final bool showArrow;
  /// 矢印先端のサイズ倍率（デフォルト0.5＝表示100%）
  final double arrowHeadScale;
  /// 両方向矢印にするか (デフォルト false = 単方向)。
  /// true にすると from 側にも矢印を描画する。
  final bool bidirectional;
  /// 接続線の中央に表示するラベル文字列。 null or 空文字なら非表示。
  final String? label;

  const NodeConnection({
    required this.fromId,
    required this.fromAnchor,
    required this.toId,
    required this.toAnchor,
    this.strokeWidth = 2.0,
    this.showArrow = true,
    this.arrowHeadScale = 0.5,
    this.bidirectional = false,
    this.label,
  });

  NodeConnection copyWith({
    AnchorDirection? fromAnchor,
    AnchorDirection? toAnchor,
    double? strokeWidth,
    bool? showArrow,
    double? arrowHeadScale,
    bool? bidirectional,
    String? label,
    bool clearLabel = false,
  }) {
    return NodeConnection(
      fromId: fromId,
      fromAnchor: fromAnchor ?? this.fromAnchor,
      toId: toId,
      toAnchor: toAnchor ?? this.toAnchor,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      showArrow: showArrow ?? this.showArrow,
      arrowHeadScale: arrowHeadScale ?? this.arrowHeadScale,
      bidirectional: bidirectional ?? this.bidirectional,
      label: clearLabel ? null : (label ?? this.label),
    );
  }

  Map<String, dynamic> toJson() => {
        'fromId': fromId,
        'fromAnchor': fromAnchor.index,
        'toId': toId,
        'toAnchor': toAnchor.index,
        'strokeWidth': strokeWidth,
        'showArrow': showArrow,
        'arrowHeadScale': arrowHeadScale,
        if (bidirectional) 'bidirectional': bidirectional,
        if (label != null && label!.isNotEmpty) 'label': label,
      };

  factory NodeConnection.fromJson(Map<String, dynamic> json) {
    return NodeConnection(
      fromId: json['fromId'] as String,
      fromAnchor: AnchorDirection.values[json['fromAnchor'] as int],
      toId: json['toId'] as String,
      toAnchor: AnchorDirection.values[json['toAnchor'] as int],
      strokeWidth: (json['strokeWidth'] as num?)?.toDouble() ?? 2.0,
      showArrow: json['showArrow'] as bool? ?? true,
      arrowHeadScale: (json['arrowHeadScale'] as num?)?.toDouble() ?? 1.0,
      bidirectional: json['bidirectional'] as bool? ?? false,
      label: json['label'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NodeConnection &&
      fromId == other.fromId &&
      toId == other.toId;

  @override
  int get hashCode => Object.hash(fromId, toId);
}

class MindMapNode {
  final String id;
  String title;
  Offset position;
  NodeContentType contentType;
  String? memoText;
  String? youtubeUrl;
  String? linkUrl;
  Color color;
  double width;
  double height;
  bool collapsed;
  NodeAnchorMode anchorMode;
  /// 添付ファイルパス（jpg, png, pdf）
  String? attachmentPath;
  /// 添付ファイル名
  String? attachmentName;
  /// 添付ファイル (PDF / pptx 等) の 1 枚目をレンダリングしたサムネイル画像パス
  /// (= ユーザー要望: ドロップした PDF の表紙をサムネイル表示)。 これがあると
  /// ノードはアイコンの代わりにこの画像を表示する。
  String? attachmentThumbPath;
  /// ノード個別タイトルフォントサイズ（null = グローバルデフォルトを使用）
  double? titleFontSize;
  /// ノード個別メモフォントサイズ（null = グローバルデフォルトを使用）
  double? memoFontSize;
  /// 動画ファイルのFirebase Storage URL（同期用）
  String? videoStorageUrl;
  /// 添付ファイルのFirebase Storage URL（同期用）
  String? attachmentStorageUrl;
  /// mp4動画のサムネイル画像パス
  String? videoThumbnailPath;
  /// このノードが「格納ノード」かどうか
  /// true の場合、[containedNodeIds] に格納された子ノードIDを保持する
  bool isContainer;
  /// 格納ノード内に保持されているノードIDのリスト
  /// このリストに含まれるIDを持つノードは画面上に表示されず、
  /// 接続線もすべて非表示になる（格納ノードが代表として残る）
  List<String>? containedNodeIds;
  /// このノードがどの格納ノードに格納されているか（無ければ null）
  /// [hiddenInContainer] != null のノードは画面上にレンダリングされない
  String? hiddenInContainer;

  /// このノードに「埋め込まれた / リンクされたサブマップ」 のページ ID。
  /// null なら通常のノード。値が入っているとノード内部に「白いリンクピル」
  /// が描画され、 そこをタップすると該当ページへ遷移する。
  ///
  /// 設定方法:
  ///   - ノードを右クリック → 「サブマップを埋め込む」 → 既存マップ一覧から選択
  ///   - 解除する場合は同メニューから「サブマップを外す」
  ///
  /// 遷移ロジック:
  ///   `_MindMapScreenState._navigateToLinkedPage()` を経由し、 ナビゲーション
  ///   履歴スタックに積む。 戻る/進むは Alt+←/Alt+→ で履歴を辿れる。
  String? linkedPageId;

  /// このノードの PDF / 添付に対して書かれたメモ。
  /// null または空リストの場合はメモなし。
  /// 詳細は [PdfMemo] のクラスコメント参照。
  List<PdfMemo>? pdfMemos;

  /// PDF メモ用の「空フォルダも含む」フォルダ名リスト (= ユーザー要望
  ///   「空のフォルダーも作成できるように」)。メモが 1 件も無いフォルダも
  ///   ここに名前を保持して永続化する。null/空なら明示フォルダなし。
  List<String>? pdfMemoFolders;

  /// 添付画像の **オリジナルのアスペクト比** (= width / height)。
  ///
  /// 画像をオリジナルサイズで貼り付けた (= 設定 `pasteImageOriginalSize` ON)
  /// 場合にセットされる。 描画時に `node_widget` の attachH 計算で
  /// `nw / attachmentAspectRatio` という形で使われ、 画像エリアが画像本来の
  /// アスペクト比で表示される。
  ///
  /// null の場合は既存の `nw * 0.6` (= 高さがノード幅の 60%) で描画される
  /// (= 旧来の挙動)。
  ///
  /// 「タイトル部分の高さは画像サイズに連動させない」 ため、 `node.height`
  /// (= タイトル領域の高さ) は通常通り 40 のままにし、 画像エリアの高さ
  /// だけアスペクト比から割り出すために導入した。
  double? attachmentAspectRatio;

  /// 表 (テーブル) データ。 null = 通常ノード、 非 null = 表ノード。
  ///
  /// 表ノードはノード内部に行×列のグリッドを描画する。 タイトル領域は
  /// 維持され、 その下に表が表示される。 行/列の追加・削除は TableData
  /// 側のメソッド (insertRow / removeRow / insertColumn / removeColumn)
  /// で行い、 永続化は toJson/fromJson で対応。
  TableData? tableData;

  /// ノードの「リッチテキスト」 本文 (Quill Delta の JSON 文字列)。
  /// null = 旧来の title / memo を別々に表示する従来挙動。
  /// 非 null の場合、 node_widget はこの内容を **統合リッチテキスト** として
  /// 描画する (= ユーザー要望: タイトルとメモを分けず、 編集ボタンを押したら
  /// まとめてリッチテキストで書ける)。 title / memoText は 検索・サイズ計算
  /// (visualHeight)・後方互換のため、 リッチ本文の平文から派生して保持する。
  String? richText;

  MindMapNode({
    required this.id,
    required this.title,
    required this.position,
    this.contentType = NodeContentType.none,
    this.memoText,
    this.youtubeUrl,
    this.linkUrl,
    Color? color,
    this.width = 160.0,
    this.height = 40.0,
    this.collapsed = false,
    this.anchorMode = NodeAnchorMode.twoWay,
    this.attachmentPath,
    this.attachmentName,
    this.attachmentThumbPath,
    this.titleFontSize,
    this.memoFontSize,
    this.videoStorageUrl,
    this.attachmentStorageUrl,
    this.videoThumbnailPath,
    this.isContainer = false,
    this.containedNodeIds,
    this.hiddenInContainer,
    this.linkedPageId,
    this.pdfMemos,
    this.pdfMemoFolders,
    this.attachmentAspectRatio,
    this.tableData,
    this.richText,
  }) : color = color ?? const Color(0xFF6C63FF);

  /// タイトルの表示可能な最大行数
  /// node.height が大きいほど多くの行を表示する。最低2行を保証。
  int get titleMaxLines {
    final fs = (titleFontSize ?? 15.0).clamp(8.0, 28.0);
    // height 内のテキスト領域 (上下paddingを引く)
    final available = height - 16.0;
    if (available <= 0) return 2;
    final lines = (available / (fs * 1.2)).floor();
    return lines.clamp(2, 100);
  }

  /// 表ノードの上端タイトルバーの高さを推定する。
  ///
  /// タイトル空: 14px (ドラッグハンドル線のみ — 元の挙動)
  /// タイトル有: 上 padding(4) + ハンドル(14) + 間隔(2) + タイトル実高 + 下 padding(4)
  ///
  /// タイトル実高は TextPainter で実測。 最大 3 行で省略。 node_widget.dart
  /// の描画と合わせること (上下 padding=4、 maxLines=3、 line height=1.2)。
  double estimateTableTitleBarHeight() {
    if (title.isEmpty) return 14.0;
    final fs = (titleFontSize ?? 15.0).clamp(8.0, 28.0).toDouble();
    // 利用可能なテキスト幅 = ノード幅 - 左右 padding(14*2=28)
    final maxW = (width - 28.0).clamp(20.0, double.infinity).toDouble();
    final tp = TextPainter(
      text: TextSpan(
        text: title,
        style: TextStyle(
          fontSize: fs,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 3,
      ellipsis: '…',
    );
    tp.layout(maxWidth: maxW);
    final textH = tp.height;
    // 上 padding(4) + ハンドル(14) + 間隔(2) + タイトル + 下 padding(4)
    return 4.0 + 14.0 + 2.0 + textH + 4.0;
  }

  /// YouTube/リンク/メモを含めた実際の表示高さ
  double get visualHeight {
    // ── 表ノードはコンテンツが表だけ ──
    // 高さ = 上端タイトルバー (タイトル空時 14px、 タイトル有時はテキスト分膨らむ)
    //        + 表本体 (内容に応じて伸びる) + 下端パディング (14px)
    if (tableData != null) {
      final t = tableData!;
      final cellW = t.colCount > 0
          ? ((width - 28.0 - (t.colCount + 1) * t.borderWidth) / t.colCount)
              .clamp(20.0, double.infinity)
              .toDouble()
          : 60.0;
      final fs = (memoFontSize ?? 12.0).clamp(6.0, 22.0).toDouble();
      final tableH = t.estimateTotalHeight(cellWidth: cellW, fontSize: fs);
      final titleBarH = estimateTableTitleBarHeight();
      return titleBarH + tableH + 14.0;
    }

    double h = height;
    // タイトルの折り返し分の追加高さ（文字サイズはノード幅に連動しない）
    final effectiveTitleFont = (titleFontSize ?? 15.0).clamp(8.0, 28.0);
    // 利用可能なテキスト幅 = width - padding(20) - border(5)
    final textWidth = width - 25.0;
    final maxLines = titleMaxLines;
    if (title.isNotEmpty && textWidth > 0) {
      final hasJapanese = RegExp(r'[\u3000-\u9FFF\uF900-\uFAFF]').hasMatch(title);
      final avgCharWidth = hasJapanese
          ? effectiveTitleFont * 0.95
          : effectiveTitleFont * 0.55;
      final charsPerLine = (textWidth / avgCharWidth).floor().clamp(1, 100);
      // タイトル必要行数: テキスト長 / 1行の文字数。 最大は height で許容できる行数まで。
      final titleLines = (title.length / charsPerLine).ceil().clamp(1, maxLines);
      if (titleLines > 1) {
        final titleTotalH = titleLines * (effectiveTitleFont * 1.2) + 16;
        if (titleTotalH > height) {
          h += titleTotalH - height;
        }
      }
    }
    // メモ全文表示分の追加高さ
    if ((memoText ?? '').isNotEmpty) {
      final effectiveMemoFont = (memoFontSize ?? 12.0).clamp(6.0, 22.0);
      final memoTextWidth = width - 25.0;
      final hasJpMemo = RegExp(r'[\u3000-\u9FFF\uF900-\uFAFF]').hasMatch(memoText!);
      // 日本語は全角想定だが文字幅差のばらつきを考慮してやや大きめに見積もる
      final avgMemoCharW = hasJpMemo
          ? effectiveMemoFont * 1.0
          : effectiveMemoFont * 0.58;
      final memoCharsPerLine =
          (memoTextWidth / avgMemoCharW).floor().clamp(1, 200);
      // 明示的な改行（\n）ごとにセグメント分割して行数を合算
      // AI生成のメモは句点ごとに改行されるため、従来の「全長÷折り返し幅」では
      // 実際の表示行数を下回ってしまい、グループ枠が食み出す
      final segments = memoText!.split('\n');
      int memoLines = 0;
      for (final seg in segments) {
        // 空行は1行としてカウント、改行だけのケースも保証
        final segLen = seg.isEmpty ? 0 : seg.length;
        final lines = segLen == 0
            ? 1
            : (segLen / memoCharsPerLine).ceil();
        memoLines += lines < 1 ? 1 : lines;
      }
      memoLines = memoLines.clamp(1, 200);
      // line-height 1.3 + 上下の余白（8px）を加算
      h += memoLines * (effectiveMemoFont * 1.3) + 8;
    }
    // YouTubeサムネイル / mp4サムネイル高さ
    final hasYtId = (youtubeUrl ?? '').isNotEmpty &&
        _extractVideoId(youtubeUrl ?? '') != null;
    // ローカル動画判定:
    //   - 拡張子ベース (`_isMp4Url`) を第一優先
    //   - contentType == youtube かつローカルパス (http(s) で始まらない)
    //     なら拡張子に依らず動画扱い (DL fallback で予期しない拡張子で
    //     保存されたケースの取りこぼし防止)
    final ytUrl = youtubeUrl ?? '';
    final isHttpUrl =
        ytUrl.startsWith('http://') || ytUrl.startsWith('https://');
    final isLocalYoutubePath = ytUrl.isNotEmpty && !hasYtId && !isHttpUrl;
    final hasMp4 = ytUrl.isNotEmpty && !hasYtId &&
        (_isMp4Url(ytUrl) ||
            (isLocalYoutubePath &&
                contentType == NodeContentType.youtube));
    // ショート動画は縦長 (9:16)。横幅 = ノード幅、高さ = 幅の 16/9 倍
    // にしてノード本来の `height` (デフォルト 40px) に依存しないようにする。
    // 旧実装ではノード高さに合わせていたため、ダウンロード直後にユーザーが
    // ノードをリサイズしていないとサムネが極小 (40px 強) になっていた。
    // node_widget.dart の thumbH 計算と必ず一致させること。
    final bool isShort = (hasYtId || hasMp4) &&
        ((youtubeUrl ?? '').contains('/shorts/') ||
            (youtubeUrl ?? '').contains('_shorts_'));
    if (hasYtId || hasMp4) {
      // 本棚整列などで attachmentAspectRatio (= 幅/高さ) が指定されていれば
      // その比率で高さを決める (= 全タイルを同寸に切り揃えるため)。 指定が
      // 無ければ従来通り shorts=16/9 縦長 / 通常=9/16 横長。
      // node_widget.dart の thumbH 計算と必ず一致させること。
      final ar = attachmentAspectRatio;
      if (ar != null && ar > 0) {
        h += width / ar;
      } else if (isShort) {
        h += width * 16 / 9; // 9:16 比率の縦長サムネイル
      } else {
        h += width * 9 / 16; // 16:9 比率の通常サムネイル
      }
    }
    // リンクバーのみ残す（YouTube/mp4でない通常リンク）
    if ((linkUrl ?? '').isNotEmpty) {
      h += 28.0;
    }
    // 添付ファイル表示分の高さ
    if ((attachmentPath ?? '').isNotEmpty) {
      // URL のクエリ・フラグメントを除去してから拡張子を取る
      String p = attachmentPath!;
      final qIdx = p.indexOf('?');
      if (qIdx >= 0) p = p.substring(0, qIdx);
      final hIdx = p.indexOf('#');
      if (hIdx >= 0) p = p.substring(0, hIdx);
      final dot = p.lastIndexOf('.');
      final ext = dot >= 0 ? p.substring(dot + 1).toLowerCase() : '';
      if (ext == 'jpg' ||
          ext == 'jpeg' ||
          ext == 'png' ||
          ext == 'gif' ||
          ext == 'webp' ||
          ext == 'bmp') {
        // ── 画像プレビュー高さ ──
        // ユーザー要望: 「横長画像を貼り付けた際のリンクの接続位置がおかしい」。
        // 旧実装は一律 `width * 0.6` で高さを計算していたため、 横長画像
        // (= アスペクト比 > 1.66) の場合に実際の描画より太い visualHeight が
        // 計算されて、 リンク (接続線) の終点がノード境界の中ではなく外側に
        // 出てしまっていた。 修正: attachmentAspectRatio (= width/height) が
        // 既知なら正しい比率で高さを算出する。
        final ar = attachmentAspectRatio;
        if (ar != null && ar > 0) {
          // ar = width / height なので height = width / ar
          h += width / ar;
        } else {
          h += width * 0.6;  // 未取得時のフォールバック
        }
      } else if ((attachmentThumbPath ?? '').isNotEmpty) {
        // PDF / pptx 等のサムネイル (= ユーザー要望: 表紙をサムネイル表示) は
        //   画像と同じく attachmentAspectRatio で高さを決める (node_widget の
        //   attachH と一致させること)。
        final ar = attachmentAspectRatio;
        h += (ar != null && ar > 0) ? width / ar : width * 0.6;
      } else {
        h += 36.0; // PDFアイコンバー
      }
    }
    return h;
  }

  static bool _isMp4Url(String url) {
    final lower = url.toLowerCase();
    // クエリ/フラグメント除去 (DL 後のローカルパスは普通付かないが、
    // HTTP 直リンクの mp4 ?token=... 形式に備えて統一処理)
    var path = lower;
    final qi = path.indexOf('?');
    if (qi >= 0) path = path.substring(0, qi);
    final hi = path.indexOf('#');
    if (hi >= 0) path = path.substring(0, hi);
    // ── 動画拡張子 ──
    // YouTube ダウンロード経由 (youtube_explode_dart) の muxed コンテナは
    // mp4 / webm / 3gp 等が混ざり得る。Shorts 等で video-only fallback に
    // 落ちると `.webm` で保存されるケースが多い。
    // node_widget.dart の `NodeWidget.isMp4Url` と判定範囲を必ず揃えること
    // (ズレるとノードの visualHeight だけ「タイトル分」になり、サムネが
    // 描画されない or 描画されても親が縦幅を確保せず潰れる)。
    return path.endsWith('.mp4') ||
        path.endsWith('.m4v') ||
        path.endsWith('.mov') ||
        path.endsWith('.webm') ||
        path.endsWith('.ogv') ||
        path.endsWith('.ogg') ||
        path.endsWith('.3gp') ||
        lower.contains('.mp4?') ||
        lower.contains('/mp4/');
  }

  static String? _extractVideoId(String url) {
    for (final p in [
      RegExp(r'youtu\.be/([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube\.com/watch\?.*v=([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube\.com/embed/([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube\.com/shorts/([a-zA-Z0-9_-]{11})'),
    ]) {
      final m = p.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// 指定方向のアンカー座標を返す
  /// メモ・サムネイル含むvisualHeightの中心から接続
  Offset anchorPoint(AnchorDirection dir) {
    final vh = visualHeight;
    switch (dir) {
      case AnchorDirection.north:
        return Offset(position.dx + width / 2, position.dy);
      case AnchorDirection.south:
        return Offset(position.dx + width / 2, position.dy + vh);
      case AnchorDirection.east:
        return Offset(position.dx + width, position.dy + vh / 2);
      case AnchorDirection.west:
        return Offset(position.dx, position.dy + vh / 2);
      case AnchorDirection.northEast:
        return Offset(position.dx + width, position.dy);
      case AnchorDirection.northWest:
        return Offset(position.dx, position.dy);
      case AnchorDirection.southEast:
        return Offset(position.dx + width, position.dy + vh);
      case AnchorDirection.southWest:
        return Offset(position.dx, position.dy + vh);
    }
  }

  /// ノード中心（visualHeightを使用）
  Offset get center => Offset(position.dx + width / 2, position.dy + visualHeight / 2);

  MindMapNode copyWith({
    String? title,
    Offset? position,
    NodeContentType? contentType,
    String? memoText,
    String? youtubeUrl,
    String? linkUrl,
    Color? color,
    double? width,
    double? height,
    bool? collapsed,
    NodeAnchorMode? anchorMode,
    String? attachmentPath,
    String? attachmentName,
    String? attachmentThumbPath,
    Object? titleFontSize = _sentinel,
    Object? memoFontSize = _sentinel,
    String? videoStorageUrl,
    String? attachmentStorageUrl,
    String? videoThumbnailPath,
    bool? isContainer,
    Object? containedNodeIds = _sentinel,
    Object? hiddenInContainer = _sentinel,
    Object? linkedPageId = _sentinel,
    Object? pdfMemos = _sentinel,
    Object? pdfMemoFolders = _sentinel,
    Object? attachmentAspectRatio = _sentinel,
    Object? tableData = _sentinel,
    Object? richText = _sentinel,
  }) {
    return MindMapNode(
      id: id,
      title: title ?? this.title,
      position: position ?? this.position,
      contentType: contentType ?? this.contentType,
      memoText: memoText ?? this.memoText,
      youtubeUrl: youtubeUrl ?? this.youtubeUrl,
      linkUrl: linkUrl ?? this.linkUrl,
      color: color ?? this.color,
      width: width ?? this.width,
      height: height ?? this.height,
      collapsed: collapsed ?? this.collapsed,
      anchorMode: anchorMode ?? this.anchorMode,
      attachmentPath: attachmentPath ?? this.attachmentPath,
      attachmentName: attachmentName ?? this.attachmentName,
      attachmentThumbPath: attachmentThumbPath ?? this.attachmentThumbPath,
      titleFontSize: titleFontSize == _sentinel
          ? this.titleFontSize
          : titleFontSize as double?,
      memoFontSize: memoFontSize == _sentinel
          ? this.memoFontSize
          : memoFontSize as double?,
      videoStorageUrl: videoStorageUrl ?? this.videoStorageUrl,
      attachmentStorageUrl: attachmentStorageUrl ?? this.attachmentStorageUrl,
      videoThumbnailPath: videoThumbnailPath ?? this.videoThumbnailPath,
      isContainer: isContainer ?? this.isContainer,
      containedNodeIds: containedNodeIds == _sentinel
          ? this.containedNodeIds
          : containedNodeIds as List<String>?,
      hiddenInContainer: hiddenInContainer == _sentinel
          ? this.hiddenInContainer
          : hiddenInContainer as String?,
      linkedPageId: linkedPageId == _sentinel
          ? this.linkedPageId
          : linkedPageId as String?,
      pdfMemos: pdfMemos == _sentinel
          ? this.pdfMemos
          : pdfMemos as List<PdfMemo>?,
      pdfMemoFolders: pdfMemoFolders == _sentinel
          ? this.pdfMemoFolders
          : pdfMemoFolders as List<String>?,
      attachmentAspectRatio: attachmentAspectRatio == _sentinel
          ? this.attachmentAspectRatio
          : attachmentAspectRatio as double?,
      tableData: tableData == _sentinel
          ? this.tableData
          : tableData as TableData?,
      richText:
          richText == _sentinel ? this.richText : richText as String?,
    );
  }

  static const Object _sentinel = Object();

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'x': position.dx,
      'y': position.dy,
      'contentType': contentType.index,
      'memoText': memoText,
      'youtubeUrl': youtubeUrl,
      'linkUrl': linkUrl,
      'color': color.toARGB32(),
      'width': width,
      'height': height,
      'collapsed': collapsed,
      'anchorMode': anchorMode.index,
      'attachmentPath': attachmentPath,
      'attachmentName': attachmentName,
      'attachmentThumbPath': attachmentThumbPath,
      'titleFontSize': titleFontSize,
      'memoFontSize': memoFontSize,
      'videoStorageUrl': videoStorageUrl,
      'attachmentStorageUrl': attachmentStorageUrl,
      'videoThumbnailPath': videoThumbnailPath,
      'isContainer': isContainer,
      'containedNodeIds': containedNodeIds,
      'hiddenInContainer': hiddenInContainer,
      'linkedPageId': linkedPageId,
      // null/空のときはキー自体を出さず JSON サイズ・後方互換を最小化
      if (pdfMemos != null && pdfMemos!.isNotEmpty)
        'pdfMemos': pdfMemos!.map((m) => m.toJson()).toList(),
      if (pdfMemoFolders != null && pdfMemoFolders!.isNotEmpty)
        'pdfMemoFolders': pdfMemoFolders,
      // 添付画像のアスペクト比 (= width/height)。 オリジナルサイズ貼り付け
      // 時のみセットされる。 null のときはキーを出さない。
      if (attachmentAspectRatio != null)
        'attachmentAspectRatio': attachmentAspectRatio,
      // 表 (テーブル) データ。 通常ノードは tableData=null なのでキーを
      // 出さず、 既存マップとの後方互換を保つ。
      if (tableData != null)
        'tableData': tableData!.toJson(),
      // リッチテキスト本文 (Quill Delta JSON)。 null/空のときはキーを出さず
      // 既存マップとの後方互換を保つ。
      if (richText != null && richText!.isNotEmpty) 'richText': richText,
    };
  }

  factory MindMapNode.fromJson(Map<String, dynamic> json) {
    final ctIndex = (json['contentType'] as int?) ?? 0;
    final ct = ctIndex < NodeContentType.values.length
        ? NodeContentType.values[ctIndex]
        : NodeContentType.none;
    return MindMapNode(
      id: json['id'] as String,
      title: json['title'] as String,
      position: Offset(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
      ),
      contentType: ct,
      memoText: json['memoText'] as String?,
      youtubeUrl: json['youtubeUrl'] as String?,
      linkUrl: json['linkUrl'] as String?,
      color: Color(json['color'] as int),
      width: (json['width'] as num?)?.toDouble() ?? 140.0,
      height: (json['height'] as num?)?.toDouble() ?? 42.0,
      collapsed: json['collapsed'] as bool? ?? false,
      anchorMode: NodeAnchorMode.values[
          (json['anchorMode'] as int?) ?? 0],
      attachmentPath: json['attachmentPath'] as String?,
      attachmentName: json['attachmentName'] as String?,
      attachmentThumbPath: json['attachmentThumbPath'] as String?,
      titleFontSize: (json['titleFontSize'] as num?)?.toDouble(),
      memoFontSize: (json['memoFontSize'] as num?)?.toDouble(),
      videoStorageUrl: json['videoStorageUrl'] as String?,
      attachmentStorageUrl: json['attachmentStorageUrl'] as String?,
      videoThumbnailPath: json['videoThumbnailPath'] as String?,
      isContainer: json['isContainer'] as bool? ?? false,
      containedNodeIds: (json['containedNodeIds'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      hiddenInContainer: json['hiddenInContainer'] as String?,
      linkedPageId: json['linkedPageId'] as String?,
      pdfMemos: (json['pdfMemos'] as List<dynamic>?)
          ?.map((e) => PdfMemo.fromJson(e as Map<String, dynamic>))
          .toList(),
      pdfMemoFolders: (json['pdfMemoFolders'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      attachmentAspectRatio:
          (json['attachmentAspectRatio'] as num?)?.toDouble(),
      tableData: json['tableData'] is Map
          ? TableData.fromJson(
              (json['tableData'] as Map).cast<String, dynamic>())
          : null,
      richText: json['richText'] as String?,
    );
  }

  /// Quill Delta の JSON 文字列を Flutter の [InlineSpan] に変換する
  /// (= ノードのリッチテキスト表示用)。 [baseStyle] を土台に、 各 op の
  /// 属性 (bold / italic / underline / strike / color / size / header) を
  /// 反映する。 解析に失敗したときは平文として 1 つの span を返す (防御的)。
  static InlineSpan buildRichSpan(String deltaJson, TextStyle baseStyle) {
    List<dynamic> ops;
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is List) {
        ops = decoded;
      } else {
        return TextSpan(text: deltaJson, style: baseStyle);
      }
    } catch (_) {
      return TextSpan(text: deltaJson, style: baseStyle);
    }
    final children = <InlineSpan>[];
    for (final op in ops) {
      if (op is! Map) continue;
      final insert = op['insert'];
      if (insert is! String) continue; // 画像等の embed はスキップ
      final attrs = op['attributes'];
      var style = baseStyle;
      if (attrs is Map) {
        if (attrs['bold'] == true) {
          style = style.copyWith(fontWeight: FontWeight.w700);
        }
        if (attrs['italic'] == true) {
          style = style.copyWith(fontStyle: FontStyle.italic);
        }
        final deco = <TextDecoration>[];
        if (attrs['underline'] == true) deco.add(TextDecoration.underline);
        if (attrs['strike'] == true) deco.add(TextDecoration.lineThrough);
        if (deco.isNotEmpty) {
          style = style.copyWith(decoration: TextDecoration.combine(deco));
        }
        final color = attrs['color'];
        if (color is String) {
          final c = _parseCssColor(color);
          if (c != null) style = style.copyWith(color: c);
        }
        // 背景色 (ハイライト) も反映 (= ユーザー要望: 編集したデザインを
        //   マップ上に反映)。
        final bg = attrs['background'];
        if (bg is String) {
          final c = _parseCssColor(bg);
          if (c != null) style = style.copyWith(backgroundColor: c);
        }
        // フォント (Quill は 'sans-serif'/'serif'/'monospace' を持つ)。
        final font = attrs['font'];
        if (font is String && font.isNotEmpty) {
          final fam = font == 'monospace'
              ? 'monospace'
              : font == 'serif'
                  ? 'serif'
                  : font == 'sans-serif'
                      ? null // デフォルト
                      : font; // 任意のフォント名
          if (fam != null) style = style.copyWith(fontFamily: fam);
        }
        // リンクは青 + 下線で表示 (タップ動作はノード側に委譲)。
        if (attrs['link'] is String) {
          style = style.copyWith(
            color: const Color(0xFF4FC3F7),
            decoration: TextDecoration.underline,
          );
        }
        // 見出し (header: 1/2/3) はフォントを少し大きく + 太字に。
        final header = attrs['header'];
        if (header is num) {
          final mult = header == 1
              ? 1.5
              : header == 2
                  ? 1.3
                  : 1.15;
          style = style.copyWith(
            fontSize: (baseStyle.fontSize ?? 12.0) * mult,
            fontWeight: FontWeight.w700,
          );
        }
        // size: 'large'/'huge'/'small' or 数値
        final size = attrs['size'];
        if (size is String) {
          final base = baseStyle.fontSize ?? 12.0;
          if (size == 'large') style = style.copyWith(fontSize: base * 1.3);
          if (size == 'huge') style = style.copyWith(fontSize: base * 1.6);
          if (size == 'small') style = style.copyWith(fontSize: base * 0.85);
        } else if (size is num) {
          style = style.copyWith(fontSize: size.toDouble());
        }
      }
      children.add(TextSpan(text: insert, style: style));
    }
    if (children.isEmpty) {
      return TextSpan(text: '', style: baseStyle);
    }
    return TextSpan(children: children, style: baseStyle);
  }

  /// '#RRGGBB' / '#AARRGGBB' / 'rgb(r,g,b)' を [Color] に変換 (失敗時 null)。
  static Color? _parseCssColor(String s) {
    var t = s.trim();
    if (t.startsWith('#')) {
      t = t.substring(1);
      if (t.length == 6) t = 'FF$t';
      if (t.length == 8) {
        final v = int.tryParse(t, radix: 16);
        if (v != null) return Color(v);
      }
      return null;
    }
    final m = RegExp(r'rgba?\((\d+),\s*(\d+),\s*(\d+)').firstMatch(t);
    if (m != null) {
      final r = int.parse(m.group(1)!);
      final g = int.parse(m.group(2)!);
      final b = int.parse(m.group(3)!);
      return Color.fromARGB(255, r, g, b);
    }
    return null;
  }

  /// Quill Delta JSON の平文 (= 改行込みのプレーンテキスト) を返す。
  /// title / memoText の派生や検索に使う。
  static String richDeltaToPlainText(String deltaJson) {
    try {
      final decoded = jsonDecode(deltaJson);
      if (decoded is! List) return deltaJson;
      final buf = StringBuffer();
      for (final op in decoded) {
        if (op is Map && op['insert'] is String) {
          buf.write(op['insert'] as String);
        }
      }
      return buf.toString();
    } catch (_) {
      return deltaJson;
    }
  }
}
