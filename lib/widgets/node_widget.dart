import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/mind_map_node.dart';
import '../providers/mind_map_provider.dart';
import 'doc_preview.dart';

/// ドラッグ中のスナップ先情報
///
/// - 単一ノードドラッグ: [sourceNodeId] = null。「ドラッグ中のノード」は
///   呼び出し側 (`_moveModeNodeId`) が握っているのでここでは不要。
/// - 範囲（複数選択）ドラッグ: [sourceNodeId] に「選択ノード群のうちスナップ
///   起点となった 1 つの ID」を入れる。実際の接続生成では選択ノードすべてを
///   [nodeId] (= ターゲット) に対して接続するが、UI ハイライトとアンカーペア
///   の根拠としてどのソースが基準だったかを保持しておく。
class SnapTarget {
  final String nodeId;
  final AnchorDirection fromAnchor; // ドラッグ元のアンカー
  final AnchorDirection toAnchor; // スナップ先のアンカー
  /// 範囲ドラッグ時のみ設定。null なら単一ノードドラッグ。
  final String? sourceNodeId;

  const SnapTarget({
    required this.nodeId,
    required this.fromAnchor,
    required this.toAnchor,
    this.sourceNodeId,
  });
}

class NodeWidget extends StatefulWidget {
  final MindMapNode node;
  final bool isSelected;

  /// 切り取り状態 (= Ctrl+X で「切り取り」 した直後、 貼り付け待ちのノード)。
  /// Windows の切り取りと同じく、 該当ノードを薄く表示して「移動待ち」 である
  /// ことを示す。 貼り付け (Ctrl+V) で元ノードは削除され通常表示に戻る。
  final bool isCut;

  /// 検索ヒット（黄枠）
  final bool isSearchHit;

  /// 現在フォーカス中の検索結果（明るい黄色 + 強めグロー）
  final bool isCurrentSearchResult;
  final Offset? positionOverride;
  final bool forceDragging;

  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  /// 長押し開始（グローバル座標）
  final void Function(Offset globalPosition)? onLongPressStart;

  /// 長押しドラッグ中（グローバル座標）
  final void Function(Offset globalPosition)? onLongPressMoveUpdate;

  /// 長押しドラッグ終了
  final VoidCallback? onLongPressEnd;

  /// YouTubeサムネイルがタップされた時のコールバック
  final VoidCallback? onThumbnailTap;

  /// 添付ファイルがタップされた時のコールバック
  final VoidCallback? onAttachmentTap;

  /// サブマップ埋め込みピル (ノード内の白いリンクバー) がタップされた
  /// ときのコールバック。 ノード本体のタップとは独立しており、 ここを
  /// 押した時だけサブマップへ遷移する。
  final VoidCallback? onLinkedMapTap;

  /// メモノードに表示されている `[mm:ss]` 形式のタイムスタンプが
  /// タップされた時に、 解析済みの秒数 (double) を渡して呼ばれる。
  /// 動画メモ機能で生成されたメモノードでは、 親動画ノードに繋がった
  /// 動画をこの秒数からシークして再生開始する用途。
  /// 親側で「親動画ノード探索 → 動画オープン」 の流れを実装する。
  final void Function(double seconds)? onMemoTimestampTap;

  /// PC版右クリック時のコールバック（グローバル座標）
  final void Function(Offset globalPosition)? onRightClick;

  /// 表ノードのセル編集が終了した時、 画面ルートの KeyboardListener に
  /// 確実にキーボードフォーカスを戻すためのコールバック。
  /// MindMapScreen 側で `_keyboardFocusNode.requestFocus()` を呼ぶ関数を
  /// 渡す。 これがないと、 セル編集 → Esc 抜けの直後に Backspace / Del
  /// で「選択ノード削除」 が効かない (フォーカスツリーの primary が
  /// KeyboardListener に戻りきらないため)。
  final VoidCallback? onRequestScreenFocus;

  /// ノード内部の TextField（現在は表セル）が編集を開始/終了した通知。
  /// モバイル側でソフトキーボードに隠れない位置へキャンバスを移動し、
  /// 編集終了後に通常の下部ツールバー表示へ戻すために使う。
  final VoidCallback? onInlineEditingStarted;
  final VoidCallback? onInlineEditingEnded;

  /// スナップ元/先として光っているアンカー方向。
  /// 接続候補の「元」と「先」を同時に見せるため複数保持する。
  final Set<AnchorDirection> highlightAnchors;

  /// ドラッグ中に表示するスナップラベル
  final SnapTarget? currentSnap;

  /// デフォルト文字サイズ（サイドバーで設定）
  final double defaultTitleFontSize;
  final double defaultMemoFontSize;

  /// アップロード/ダウンロード進捗（null=転送なし, 0.0〜1.0）
  final double? uploadProgress;

  /// ノードサイズ変更コールバック（エッジドラッグ用）
  /// dx, dy は位置移動量（左/上からリサイズ時に使用）
  final void Function(double width, double height, double dx, double dy)?
      onSizeChanged;

  /// リサイズハンドルの表示 (通常は選択中のみ)
  final bool showResizeHandles;

  /// モバイル版で通常の pan で即ドラッグを開始する(通常は長押し必須)。
  /// 複数選択モードでまとめて動かしたいときに true にする。
  final bool enablePanDrag;

  /// ダークモード設定。
  /// - true(ダーク): 検索ハイライトに明るい黄色を使用 (背景が暗いので見える)
  /// - false(ライト): 黄色は白背景で見えづらいため濃いオレンジ/アンバーに切替
  final bool isDarkMode;

  /// ギャラリー (本棚) ページ上のセルとして描画しているか (= ユーザー要望:
  /// ギャラリーのメモ付き PDF だけ背景色を変えるための判定に使う)。
  final bool isShelf;

  /// ギャラリーで別要素をドラッグ中、 この要素が「入れ替わる先」 として
  /// 現在ターゲットになっているか (= ユーザー要望: どこと入れ替わるか
  /// 分かるよう枠を目立たせる)。 オレンジの強い枠 + グローで強調する。
  final bool isSwapTarget;

  /// ギャラリーのタイルに文字が入り切らなかった時に出す「全文を見る」 ボタンの
  /// 押下 (= ユーザー要望: 入り切らない文字を表示する)。
  /// ギャラリーのタイルは大きさが固定なので、 長い文章は途中で切れる。
  /// 切れている時だけ隅にボタンを出し、 押すと全文を読めるようにする。
  /// null を渡すとボタン自体を出さない (= ギャラリー以外)。
  final VoidCallback? onShowFullText;

  const NodeWidget({
    required super.key,
    required this.node,
    required this.isSelected,
    this.isCut = false,
    this.isShelf = false,
    this.isSwapTarget = false,
    this.onShowFullText,
    this.isSearchHit = false,
    this.isCurrentSearchResult = false,
    this.positionOverride,
    this.forceDragging = false,
    required this.onTap,
    this.onDoubleTap,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressEnd,
    this.onThumbnailTap,
    this.onAttachmentTap,
    this.onLinkedMapTap,
    this.onMemoTimestampTap,
    this.onRightClick,
    this.onRequestScreenFocus,
    this.onInlineEditingStarted,
    this.onInlineEditingEnded,
    this.highlightAnchors = const <AnchorDirection>{},
    this.currentSnap,
    this.defaultTitleFontSize = 15.0,
    this.defaultMemoFontSize = 12.0,
    this.uploadProgress,
    this.onSizeChanged,
    this.showResizeHandles = false,
    this.enablePanDrag = false,
    this.isDarkMode = true,
  });

  static String? extractVideoId(String url) {
    for (final p in [
      RegExp(r'youtu\.be/([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube\.com/watch\?.*v=([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube\.com/embed/([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube-nocookie\.com/embed/([a-zA-Z0-9_-]{11})'),
      RegExp(r'youtube\.com/shorts/([a-zA-Z0-9_-]{11})'),
    ]) {
      final m = p.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// メモ本文がタイムスタンプ形式 (`[mm:ss]` または `[h:mm:ss]`) なら
  /// その秒数を double で返す。 マッチしなければ null。
  ///
  /// 動画メモ機能で `provider.addVideoMemoNode` が生成したメモは
  /// `memoText` にこの形式の文字列を入れているので、 ここで判定して
  /// クリック可能なリンク表示に切り替える用途。
  /// 桁数は柔軟に受け、 `[3:24]` / `[03:24]` / `[1:23:45]` どれも OK。
  static double? parseTimestamp(String text) {
    final m = RegExp(r'^\[(\d+):(\d+)(?::(\d+))?\]$').firstMatch(text.trim());
    if (m == null) return null;
    if (m.group(3) != null) {
      // h:mm:ss 形式
      final h = int.tryParse(m.group(1)!) ?? 0;
      final mm = int.tryParse(m.group(2)!) ?? 0;
      final ss = int.tryParse(m.group(3)!) ?? 0;
      return (h * 3600 + mm * 60 + ss).toDouble();
    } else {
      // mm:ss 形式
      final mm = int.tryParse(m.group(1)!) ?? 0;
      final ss = int.tryParse(m.group(2)!) ?? 0;
      return (mm * 60 + ss).toDouble();
    }
  }

  /// mp4/動画URLかどうか判定
  static bool isMp4Url(String url) {
    final lower = url.toLowerCase();
    // クエリ/フラグメント除去
    var path = lower;
    final qi = path.indexOf('?');
    if (qi >= 0) path = path.substring(0, qi);
    final hi = path.indexOf('#');
    if (hi >= 0) path = path.substring(0, hi);
    // .webm / .ogv / .ogg / .3gp も含める。これは YouTube ダウンロード経由
    // で muxed コンテナが webm 形式になったローカル動画をノードのサムネ /
    // 動画再生 UI で正しく扱うため。ノード描画 (NodeWidget.build) はこの
    // 戻り値で `if (videoId != null || isMp4)` 分岐に入るかを決めるので、
    // false だとサムネが出ず、タップ時もただの URL 扱いになって外部アプリ
    // (= システム標準プレイヤー) に取られてしまう。
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

  /// 画像 URL かどうか判定（拡張子ベース）
  /// 動作: jpg / jpeg / png / gif / webp / bmp / svg のいずれかで終わるか、
  /// クエリ前に該当拡張子があれば true。
  /// http/https の絶対 URL のみ対象（ローカルパスは別ルートの attachmentPath で扱う）。
  static bool isImageUrl(String url) {
    final u = url.trim().toLowerCase();
    if (!(u.startsWith('http://') || u.startsWith('https://'))) return false;
    // クエリやフラグメントを取り除いてから拡張子をチェック
    String path = u;
    final qIdx = path.indexOf('?');
    if (qIdx >= 0) path = path.substring(0, qIdx);
    final hIdx = path.indexOf('#');
    if (hIdx >= 0) path = path.substring(0, hIdx);
    return path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.png') ||
        path.endsWith('.gif') ||
        path.endsWith('.webp') ||
        path.endsWith('.bmp') ||
        path.endsWith('.svg');
  }

  // ★ mqdefault は 16:9 (320x180) で上下の黒帯が無い。 hqdefault (480x360) は
  //   4:3 で上下に黒帯が入り、 16:9 枠に topCenter で表示すると上に黒帯が出て
  //   映像が下にずれて見えていた (= ユーザー報告: サムネが微妙に下にずれる)。
  static String thumbnailUrl(String v) =>
      'https://img.youtube.com/vi/$v/mqdefault.jpg';

  @override
  State<NodeWidget> createState() => _NodeWidgetState();
}

class _NodeWidgetState extends State<NodeWidget> {
  Offset get _displayPos => widget.positionOverride ?? widget.node.position;
  bool get _dragging => widget.forceDragging;

  /// Office / テキスト添付の「表紙カード」 (= ユーザー要望: docx/xlsx/txt 等を
  /// 埋め込んだら表紙が見えるように)。 タイプ色の背景 + アイコン + 拡張子
  /// バッジ + ファイル名で本の表紙風に描画する。
  Widget _buildDocCoverCard({
    required String ext,
    required String name,
    required double width,
    required double height,
    required bool squareBottom,
    String? path,
  }) {
    Color color;
    IconData icon;
    switch (ext) {
      case 'docx':
      case 'doc':
        color = const Color(0xFF2B579A); // Word ブルー
        icon = Icons.description_rounded;
        break;
      case 'xlsx':
      case 'xls':
      case 'csv':
        color = const Color(0xFF217346); // Excel グリーン
        icon = Icons.table_chart_rounded;
        break;
      case 'pptx':
      case 'ppt':
        color = const Color(0xFFD24726); // PowerPoint オレンジ
        icon = Icons.slideshow_rounded;
        break;
      // ── HTML / CSS (= ユーザー要望: html も中身をサムネイルで) ──
      case 'html':
      case 'htm':
        color = const Color(0xFFE44D26); // HTML5 オレンジ
        icon = Icons.code_rounded;
        break;
      case 'css':
      case 'scss':
      case 'sass':
      case 'less':
        color = const Color(0xFF264DE4); // CSS ブルー
        icon = Icons.css_rounded;
        break;
      default: // txt / md
        color = const Color(0xFF455A64);
        icon = Icons.notes_rounded;
    }
    final compact = height < 110;
    // ── 中身のさわりを出す (= ユーザー要望: xlsx などもサムネイルで
    //    中身が見えるように) ──
    //    読めた時だけ、 アイコンの代わりに文字を並べた「紙面風」 にする。
    //    読めない / 小さすぎる時は従来どおりアイコンだけ。
    final canPreview =
        !compact && path != null && path.isNotEmpty && DocPreview.supports(ext);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color.lerp(color, Colors.black, 0.35)!],
        ),
        borderRadius: BorderRadius.vertical(
          bottom: squareBottom ? Radius.zero : const Radius.circular(18),
        ),
      ),
      // ── 中身だけを大きく出す (= ユーザー要望: 拡張子やファイル名は
      //    ノードの実体側に出ているので、 表紙は中身の表示に使う) ──
      padding: const EdgeInsets.all(6),
      child: canPreview
          ? _docPaper(path!, ext, icon)
          : Center(
              child: Icon(icon,
                  size: compact ? 24 : 34,
                  color: Colors.white.withValues(alpha: 0.95)),
            ),
    );
  }

  /// 表紙に敷く「白い紙」。 一度読んだ中身は控えから即座に描くので、
  /// タイルを動かしても点滅しない (= ユーザー報告)。
  Widget _docPaper(String path, String ext, IconData icon) {
    final cached = DocPreview.cachedFor(path);
    if (cached != null) return _paperOf(cached, icon, path);
    return FutureBuilder<List<String>>(
      future: DocPreview.load(path, ext),
      builder: (ctx, snap) {
        // まだ読めていない間はアイコン。 読み終われば紙にする。
        if (snap.connectionState != ConnectionState.done) {
          return Center(
            child: Icon(icon,
                size: 34, color: Colors.white.withValues(alpha: 0.95)),
          );
        }
        return _paperOf(snap.data ?? const <String>[], icon, path);
      },
    );
  }

  /// 紙 + 中身の先頭。 中身が空でも紙のまま出す (= ユーザー要望)。
  ///
  /// pptx は 1 枚目の配色を拾ってあれば、 その色で塗る (= ユーザー要望:
  /// 表紙のデザインがサムネイルに出るように)。
  Widget _paperOf(List<String> lines, IconData icon, [String? path]) {
    // pptx は 1 枚目の置き場所ごと控えてあれば、 そのまま縮小して描く
    // (= ユーザー要望: 文字の配置まで 1 枚目と同じに)。
    final slide = path == null ? null : DocPreview.slideFor(path);
    if (slide != null && slide.boxes.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: AspectRatio(
          aspectRatio: slide.width / slide.height,
          child: CustomPaint(
            painter: _SlideThumbPainter(slide),
            child: const SizedBox.expand(),
          ),
        ),
      );
    }
    final style = path == null ? null : DocPreview.styleFor(path);
    final paper = style?.bg != null
        ? Color(0xFF000000 | style!.bg!)
        : Colors.white.withValues(alpha: 0.94);
    final ink = style?.fg != null
        ? Color(0xFF000000 | style!.fg!)
        : const Color(0xFF212121);
    return Container(
        width: double.infinity,
        height: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        decoration: BoxDecoration(
          color: paper,
          borderRadius: BorderRadius.circular(4),
        ),
        child: ClipRect(
          child: lines.isEmpty
              // ── 中身が無い時は「空」 と出す (= ユーザー要望: 真っ白
              //    だけだと味がない)。 ──
              // 中身が無い時は白紙の真ん中にアイコンだけ (= ユーザー要望:
              // 「空」 の文字は出さない)。
              ? Center(
                  child: Icon(icon,
                      size: 26,
                      color: ink.withValues(alpha: 0.16)),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final l in lines)
                      Text(l,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: ink,
                            fontSize: 7.5,
                            height: 1.45,
                          )),
                  ],
                ),
        ),
      );
  }

  /// ギャラリーのリンク専用ノードを「ブックマークカード」 として本体いっぱいに
  /// 描画する (= ユーザー要望: ギャラリーにリンクを貼ると空の実体部分が大き
  /// 過ぎるので、 カードで埋めて見栄えを良くする)。
  Widget _buildLinkCoverCard({
    required String url,
    required String title,
    required double width,
    required double height,
  }) {
    final host = Uri.tryParse(url)?.host ?? url;
    final compact = height < 110;
    const color = Color(0xFF5C6BC0); // インディゴ系 (リンク = 情報)
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, Color(0xFF37474F)],
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.link_rounded,
              size: compact ? 24 : 34,
              color: Colors.white.withValues(alpha: 0.95)),
          SizedBox(height: compact ? 3 : 6),
          if (title.trim().isNotEmpty) ...[
            Flexible(
              child: Text(
                title.trim(),
                maxLines: compact ? 2 : 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
            ),
            SizedBox(height: compact ? 2 : 4),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
            ),
            child: Text(
              host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // デスクトップ判定
  static bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  // デスクトップ用ドラッグ状態
  bool _panDragActive = false;

  // リサイズドラッグ状態
  bool _resizing = false;
  double _resizeStartW = 0;
  double _resizeStartH = 0;
  Offset _resizeDragStart = Offset.zero;
  // 累積posDx/Dy: onSizeChangedに渡す位置オフセットは
  // 「前フレームからの増分」でなければ呼び出し側で多重加算されてしまうため、
  // 各ドラッグ開始時にリセットして増分を計算する。
  double _accumPosDx = 0;
  double _accumPosDy = 0;

  void _emitResize(double w, double h, double posDx, double posDy) {
    final incDx = posDx - _accumPosDx;
    final incDy = posDy - _accumPosDy;
    _accumPosDx = posDx;
    _accumPosDy = posDy;
    widget.onSizeChanged!(w, h, incDx, incDy);
  }

  // ── ダブルタップを自前検出 ──
  DateTime _lastTapTime = DateTime(0);
  static const _doubleTapWindow = Duration(milliseconds: 300);

  void _handleTap() {
    final now = DateTime.now();
    final diff = now.difference(_lastTapTime);
    _lastTapTime = now;

    if (diff <= _doubleTapWindow && widget.onDoubleTap != null) {
      _lastTapTime = DateTime(0);
      widget.onDoubleTap!();
    } else {
      widget.onTap();
    }
  }

  /// カーソルを乗せた時に出す下読み用の文字。 長すぎる時は途中で切る
  /// (画面を覆う大きさの吹き出しにしないため)。 全文は窓の方で読む。
  static String _fullTextPreview(MindMapNode node) {
    final rich = node.richText;
    String text;
    if (rich != null && rich.isNotEmpty) {
      text = MindMapNode.buildRichSpan(rich, const TextStyle())
          .toPlainText()
          .trim();
    } else {
      final memo = (node.memoText ?? '').trim();
      text = memo.isEmpty ? node.title : '${node.title}\n$memo'.trim();
    }
    if (text.length > 400) return '${text.substring(0, 400)}…';
    return text;
  }

  /// ギャラリーのタイルに文字が入り切っているかを測る。
  ///
  /// タイルは大きさが固定 (clampHeight) なので、 長い文章は
  ///   - 平文のタイトル / メモ → maxLines + 省略記号 (…) で途中まで
  ///   - リッチテキスト        → 枠からはみ出して見えないまま
  /// のどちらかで読めなくなる。 実際に描くのと同じ span を組んで測り、
  /// 入り切らない時だけ「全文を見る」 ボタンを出す (= ユーザー要望)。
  bool _shelfTextOverflows({
    required MindMapNode node,
    required double maxWidth,
    required double maxHeight,
    required TextStyle titleStyle,
    required TextStyle memoStyle,
    required TextStyle richBaseStyle,
    required double richSizeScale,
    required Color linkColor,
  }) {
    if (maxWidth <= 1 || maxHeight <= 1) return false;
    final rich = node.richText;
    final InlineSpan span;
    if (rich != null && rich.isNotEmpty) {
      span = MindMapNode.buildRichSpan(rich, richBaseStyle,
          sizeScale: richSizeScale, linkColor: linkColor);
    } else {
      final memo = node.memoText ?? '';
      if (node.title.isEmpty && memo.isEmpty) return false;
      span = TextSpan(children: [
        TextSpan(text: node.title, style: titleStyle),
        // 描画側はメモを 4px の間を空けた別 Text にしている。 改行 1 つで
        //   近い高さになるので、 測定はこれで足りる。
        if (memo.isNotEmpty) TextSpan(text: '\n$memo', style: memoStyle),
      ]);
    }
    final tp = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: maxWidth);
    // 端数で毎回ボタンが出ないよう、 少しだけ余裕を見る。
    return tp.height > maxHeight + 2.0;
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final canLongPressDrag = widget.onLongPressStart != null;
    final canPanDrag = (_isDesktop || widget.enablePanDrag) && canLongPressDrag;
    // ── ノード背景の表示色補正 ──
    // 黄色系の色 (HSL hue 40-70°, lightness > 55%) はライトモードの白い
    // canvas に対してコントラスト不足で視認性が悪い。ユーザー要望により
    // 黄色は全廃して、データを変更せずレンダリング時のみブラック寄り
    // (Blue Gray 900) に補正する。これにより既存の黄色ノードも自動的に
    // 視認しやすい色で表示される。
    final Color effectiveColor = (() {
      // ── ギャラリーで「メモが付属する PDF」 は背景色を変える (= ユーザー
      //    要望)。 pdfMemos は PDF にのみ付くので、 これが空でなければ
      //    メモ付き PDF と判定できる。 琥珀色で一目で分かるようにする。 ──
      if (widget.isShelf && (node.pdfMemos?.isNotEmpty ?? false)) {
        return const Color(0xFFFFE0B2);
      }
      final hsl = HSLColor.fromColor(node.color);
      if (hsl.hue >= 40 && hsl.hue <= 70 && hsl.lightness > 0.55) {
        return const Color(0xFF263238);
      }
      return node.color;
    })();
    final videoId = (node.youtubeUrl ?? '').isNotEmpty
        ? NodeWidget.extractVideoId(node.youtubeUrl!)
        : null;
    // ショート動画判定:
    //   1. URL に /shorts/ が含まれる (= まだ DL されていない、または Web URL)
    //   2. ローカルパスに `_shorts_` が含まれる (= DL 後のローカル動画)
    //      DL 側がファイル名に `_shorts_<videoId>.mp4` 規約で書き出す。
    final bool isShort = (node.youtubeUrl ?? '').contains('/shorts/') ||
        (node.youtubeUrl ?? '').contains('_shorts_');
    // 動画として描画するかの判定:
    //   - YouTube URL (videoId 抽出可) → サムネ + プレイ
    //   - HTTP 直リンクの mp4 / webm → サムネ + プレイ
    //   - ローカルパス (DL 済み動画ファイル) → サムネ + プレイ
    //
    // ローカル判定は拡張子ベース (`isMp4Url`) を **第一優先** とするが、
    // それを取りこぼしたケース (例: Shorts の video-only fallback で
    // `.opus` / 拡張子なし等の予期しない名前で保存された) もカバーする
    // ため、 contentType が youtube かつローカルパスなら強制的に動画
    // 扱いする。これでダウンロード後にサムネが出ない不具合を防ぐ。
    final ytUrl = node.youtubeUrl ?? '';
    final isHttpUrl =
        ytUrl.startsWith('http://') || ytUrl.startsWith('https://');
    final isLocalYoutubePath =
        ytUrl.isNotEmpty && videoId == null && !isHttpUrl;
    final isMp4 = ytUrl.isNotEmpty && videoId == null
        ? (NodeWidget.isMp4Url(ytUrl) ||
            (isLocalYoutubePath && node.contentType == NodeContentType.youtube))
        : false;
    // オフライン (= 端末ローカルに保存済みでネット接続なしで再生可能) かを
    // 判定する。`isMp4 == true` かつ URL が `http(s)://` で始まらないなら
    // ローカルファイルパスなのでオフライン扱い。NodeWidget は
    // YouTube ダウンロード経由のローカル動画と HTTP 直リンクの mp4 を
    // 同じ `isMp4` として扱うため、明示的に区別が必要。
    final isOffline = isMp4 &&
        !((node.youtubeUrl ?? '').startsWith('http://') ||
            (node.youtubeUrl ?? '').startsWith('https://'));
    final linkUrl = (node.linkUrl ?? '').isNotEmpty ? node.linkUrl! : null;
    final hasAnyLink = videoId != null || linkUrl != null || isMp4;
    final memoExists = (node.memoText ?? '').isNotEmpty;
    // グローバル「メモ欄を閉じる」 設定の読み取り。
    // ON 時はメモ全文表示を抑制し、 代わりに「メモあり」 を示す小さな
    // インジケーターだけ表示する。 context.watch でフラグ変化を購読し、
    // 切替時に即時再描画する。
    bool memoCollapsedGlobal = false;
    try {
      memoCollapsedGlobal =
          context.watch<MindMapProvider>().memoCollapsedGlobal;
    } catch (_) {
      // Provider が無い場面 (テスト等) ではデフォルト OFF。
    }
    final hasMemo = memoExists && !memoCollapsedGlobal;
    final memoIndicatorOnly = memoExists && memoCollapsedGlobal;
    final hasAttachment = (node.attachmentPath ?? '').isNotEmpty;
    // 拡張子抽出: URL のクエリやフラグメントを除いてから last セグメントを取る
    String attachExt = '';
    if (hasAttachment) {
      String p = node.attachmentPath!;
      final qIdx = p.indexOf('?');
      if (qIdx >= 0) p = p.substring(0, qIdx);
      final hIdx = p.indexOf('#');
      if (hIdx >= 0) p = p.substring(0, hIdx);
      final dot = p.lastIndexOf('.');
      attachExt = dot >= 0 ? p.substring(dot + 1).toLowerCase() : '';
    }
    final isImageAttach = attachExt == 'jpg' ||
        attachExt == 'jpeg' ||
        // .jpe も JPEG (= 手元のファイルで見かける綴り)。
        attachExt == 'jpe' ||
        attachExt == 'png' ||
        attachExt == 'gif' ||
        attachExt == 'webp' ||
        attachExt == 'bmp';
    // 添付サムネイル (PDF / pptx 等の 1 枚目) があるか (= ユーザー要望:
    //   ドロップした PDF / pptx の表紙をサムネイル表示)。
    final hasThumb = (node.attachmentThumbPath ?? '').isNotEmpty;
    // ── 見出しに出す文字 (= ユーザー要望: 画像のファイル名も、 周りの
    //    ノードと同じように実体 (見出し) の方に入れる)。
    //    タイトルが空の添付ノードだけ、 ファイル名で代用する。
    //    1 行で収まるので visualHeight (= 既定の高さ) の中に入る。 ──
    final String headerTitle = node.title.trim().isNotEmpty
        ? node.title
        : ((node.attachmentName ?? '').trim());
    // ノードに表示する画像パス: 画像添付はそのパス、 PDF/pptx はサムネイル。
    final String attachImgPath = isImageAttach
        ? (node.attachmentPath ?? '')
        : (hasThumb ? (node.attachmentThumbPath ?? '') : '');

    // ── ギャラリー (本棚) のテキストタイルは幅を +ボックス幅 (kShelfTileW) に
    //    固定する (= ユーザー要望: ギャラリー要素を後からテキスト編集しても、
    //    文字数が限界を超えるまで大きさ (横幅) が変わらないように)。 表紙系
    //    (動画/画像/添付サムネ) は従来どおり自前の幅を使う。 provider 側の
    //    整列でも幅は固定されるが、 整列前の旧データ等でも描画で必ず一定幅に
    //    なるよう描画側でも保証する。 ──
    final bool _isShelfTextTile = widget.isShelf &&
        node.tableData == null &&
        (node.youtubeUrl ?? '').isEmpty &&
        (node.attachmentPath ?? '').isEmpty &&
        (node.attachmentThumbPath ?? '').isEmpty;
    final double nw =
        _isShelfTextTile ? MindMapProvider.kShelfTileW : node.width;
    // ── リサイズハンドルの幅上限 ──
    // 画像ノード (= attachmentAspectRatio あり) は、 ギャラリーで +ボックスに
    //   収めて貼った後でも大きく拡大できるよう幅の上限を広げる
    //   (= ユーザー要望: 埋めた後から拡大率を変えられるように)。 通常ノードは
    //   従来どおり 300px まで。
    final double _maxHandleW =
        node.attachmentAspectRatio != null ? 900.0 : 300.0;
    // YouTubeサムネイル高さ / 幅:
    // - 通常動画 (16:9): thumbH = nw * 9/16, 幅 = nw
    // - ショート動画 (9:16, 縦長):
    //     ユーザー要望に合わせ「ノード幅基準で縦長」に表示する。
    //     thumbH = nw * 16/9 (ノード幅の 16/9 倍)、幅 = nw 全幅。
    //     旧実装は thumbH = nh (ノード高さ依存) だったが、デフォルト
    //     `nh = 40` のままダウンロード後にノードを編集していないと
    //     サムネが 40x40 程度に潰れて再生できない不具合があった。
    //     ノード幅基準にすれば常に視認可能なサイズが保証される。
    //     ただし極端に縦長になりすぎないよう 1:1 〜 9:16 の範囲で
    //     クランプする (= 通常動画の 16:9 と区別しつつ画面占有を抑制)。
    final double thumbH;
    final double? shelfAr = node.attachmentAspectRatio;
    final bool isVideoThumb = videoId != null || isMp4;
    if (!isVideoThumb) {
      thumbH = 0;
    } else if (shelfAr != null && shelfAr > 0) {
      // 本棚整列で attachmentAspectRatio (= 幅/高さ) が指定された動画は、
      // その比率で高さを決めて全タイルを同寸に切り揃える。
      // mind_map_node.dart visualHeight の動画分岐と必ず一致させること。
      thumbH = nw / shelfAr;
    } else if (isShort) {
      thumbH = nw * 16 / 9; // 9:16 縦長
    } else {
      thumbH = nw * 9 / 16; // 16:9 通常
    }
    // ハイパーリンクバーを表示するか
    // 動画が貼られているケースでは本体タップ = 動画再生にしたいので非表示。
    final bool hasLinkBar = linkUrl != null && videoId == null && !isMp4;
    // ── ギャラリーのリンクだけのノードは「リンクカード」 で本体を埋める ──
    // (= ユーザー報告: ギャラリーにリンクを貼ると空の実体部分が大き過ぎる)。
    // カードにリンク情報を含めるので、 別途の細いリンクバーは出さない。
    // clampHeight 前提 (= ギャラリー整列で高さ固定済み) にすることで、
    // model の visualHeight (clampHeight 時は height をそのまま返す) と
    // 描画高さ (linkBarH=0 なので bodyH=height) が一致しレイアウトがずれない。
    final bool isShelfLinkCard =
        widget.isShelf && node.clampHeight && hasLinkBar && !hasAttachment;
    final double linkBarH = (hasLinkBar && !isShelfLinkCard) ? 28.0 : 0;
    // サブマップ埋め込みピル: ノード内部に配置する「白背景 + 🌳 + マップ名」
    // のリンクバー。 リンク URL バーと同じ感覚で、 マップへの遷移ボタンと
    // して機能する。 ノード本体のタップとは独立 (ピルだけがリンク部分)。
    final linkedPageId = node.linkedPageId;
    String? linkedMapName;
    if ((linkedPageId ?? '').isNotEmpty) {
      try {
        final provider = context.read<MindMapProvider>();
        final matched = provider.pages.where((p) => p.id == linkedPageId);
        if (matched.isNotEmpty) {
          linkedMapName = matched.first.name;
        }
      } catch (_) {}
    }
    final bool hasLinkedMap = linkedMapName != null;
    final double linkedMapBarH = hasLinkedMap ? 28.0 : 0;
    // ── Office / テキスト添付は「表紙カード」 として描画する ──
    // (= ユーザー要望: docx や xlsx, txt 等をマップに埋め込んだら表紙が
    //    見えるように)。 PDF / pptx は 1 ページ目を実際に描画したサムネイルが
    //    あるので、 従来どおり画像を表紙にする。
    //
    // ★ docx / xlsx / テキスト系はサムネイルがあっても使わない。
    //   これらを描画する手段をアプリは持っておらず、 過去に作られた
    //   サムネイルは**真っ白な画像**になっていた (実測: 395x512 の全画素 255)。
    //   その白画像が優先されて、 タイルが真っ白に見えていた。
    //   いまは中身の文字を読んで表紙に出せるので、 常に表紙カードを使う。
    const docCoverExts = {
      'docx', 'doc', 'xlsx', 'xls', 'csv', 'txt', 'md', //
      // HTML / CSS も中身の見える表紙にする (= ユーザー要望)。
      'html', 'htm', 'css', 'scss', 'sass', 'less', //
    };
    const thumbnailableExts = {'pptx', 'ppt'};
    final bool isDocCoverAttach = hasAttachment &&
        !isImageAttach &&
        (docCoverExts.contains(attachExt) ||
            (!hasThumb && thumbnailableExts.contains(attachExt)));
    final double attachH = hasAttachment
        ? ((isImageAttach || hasThumb)
            // 添付画像 / サムネイルにアスペクト比 (= width / height) が指定
            // されていれば、 ノード幅を使って本来の比率で高さを決める。
            // 未指定なら「ノード幅 × 0.6」 で固定の縮小表示。
            ? (node.attachmentAspectRatio != null &&
                    node.attachmentAspectRatio! > 0
                ? (nw / node.attachmentAspectRatio!)
                : nw * 0.6)
            : isDocCoverAttach
                // 表紙カード: ギャラリー整列の統一比があればそれに従い、
                // 無ければ幅 × 0.72 の横長カード。
                // mind_map_node.dart の visualHeight と必ず一致させること。
                ? (node.attachmentAspectRatio != null &&
                        node.attachmentAspectRatio! > 0
                    ? (nw / node.attachmentAspectRatio!)
                    : nw * 0.72)
                : 36.0)
        : 0;

    // フォントサイズ: ノード個別設定があればそれを優先、なければグローバルデフォルト
    // ノードの大きさに関わらず文字サイズは固定
    final double titleFontSize =
        (node.titleFontSize ?? widget.defaultTitleFontSize).clamp(8.0, 28.0);
    final double memoFontSize =
        (node.memoFontSize ?? widget.defaultMemoFontSize).clamp(6.0, 22.0);

    // ── タイトル / メモのテキスト色 ──
    // 実際の描画背景 effectiveColor の輝度に応じて自動で黒文字 / 白文字を
    // 切り替える。 旧実装は node.color を見ていたが、 上の effectiveColor
    // ロジックで黄色系は 0xFF263238 (ほぼ黒) に強制変換されるため、 元色は
    // 明るくても実背景は暗いケースが発生し、 黒地に黒文字で読めない問題が
    // 起きていた (ユーザー報告「黒地の時だけ文字が白じゃない」)。
    // effectiveColor で判定すれば実描画と必ず整合する。
    final bool _isLightBg = effectiveColor.computeLuminance() > 0.55;
    final Color titleTextColor =
        _isLightBg ? const Color(0xDD000000) : Colors.white;
    final Color memoTextColor = _isLightBg
        ? const Color(0xCC000000)
        : Colors.white.withValues(alpha: 0.75);
    // ── リンク文字色は実背景の明暗で自動調整 (= ユーザー要望: 黒背景では
    //    白リンク、 白背景では黒リンクになるように。 中間の色付き背景は
    //    従来の水色) ──
    final double _bgLum = effectiveColor.computeLuminance();
    final Color linkTextColor = _bgLum > 0.7
        ? const Color(0xDD000000) // 白系背景 → 黒リンク
        : _bgLum < 0.12
            ? Colors.white // 黒系背景 → 白リンク
            : const Color(0xFF4FC3F7); // 中間 → 従来の水色

    // メモ全文表示のための推定高さ。
    // ★ mind_map_node.dart の visualHeight のメモ計算と必ず一致させる
    //   (= ユーザー報告: メモ分の縦幅が考慮されず、 配置候補が重なる)。
    //   改行(\n)ごとにセグメント分割し、 日本語/英語で 1 行の文字数を変える。
    //   旧実装は「全長 ÷ 16文字」 で改行を無視していたため、 描画(自然折返し)が
    //   visualHeight より高くなり、 レイアウト計算とズレて重なっていた。
    // clampHeight (= ギャラリーのテキストタイル) の時は本文ぶんの高さを
    //   加算しない。 totalH が node.height に固定され、 下のメモ Text は
    //   maxLines + ellipsis で height 内に省略表示する (= ユーザー要望:
    //   テキストを後から変えてもタイルの大きさが変わらない)。
    double memoExtraH = 0;
    if (hasMemo && !node.clampHeight) {
      final hasJpMemo = RegExp(r'[　-鿿豈-﫿]').hasMatch(node.memoText!);
      final avgMemoCharW = hasJpMemo ? memoFontSize * 1.0 : memoFontSize * 0.58;
      final memoCharsPerLine =
          ((nw - 25.0) / avgMemoCharW).floor().clamp(1, 200);
      final segments = node.memoText!.split('\n');
      int memoLines = 0;
      for (final seg in segments) {
        final segLen = seg.isEmpty ? 0 : seg.length;
        final lines = segLen == 0 ? 1 : (segLen / memoCharsPerLine).ceil();
        memoLines += lines < 1 ? 1 : lines;
      }
      memoLines = memoLines.clamp(1, 200);
      memoExtraH = memoLines * (memoFontSize * 1.3) + 8;
    }

    // ── 高さ固定タイル (ギャラリー) で「隙間」 を作らない ──
    // (= ユーザー要望: YouTube の動画を埋め込んだ時に隙間が生まれる。
    //    サムネイルの大きさは変えずに文章を書く領域を広げて、 周りの要素と
    //    同じ大きさになるように)。
    // 旧: 本文枠を必ず node.height 取ってから、 その下にサムネイルを足して
    //     いたため、 動画タイルだけ (node.height + サムネイル高) になり、
    //     周りのテキストタイル (node.height) より背が高く / 余白が目立った。
    // 新: clampHeight の時は合計を node.height に固定し、 サムネイルや
    //     リンクバーが使う分を引いた「残り全部」 を本文領域にする。
    //     サムネイル自体のサイズ (thumbH) は変えない。
    final double fixedExtras = thumbH + linkBarH + linkedMapBarH + attachH;
    final double minBodyH = node.height < 28.0 ? node.height : 28.0;
    final double clampedBodyH = node.clampHeight
        ? (node.height - fixedExtras).clamp(minBodyH, node.height).toDouble()
        : node.height;
    final double bodyH =
        node.clampHeight ? clampedBodyH : node.height + memoExtraH;
    // ── ギャラリーで文字が入り切らないタイルを見つける (= ユーザー要望:
    //    入り切らない文字を表示する)。 タイルの大きさは固定なので長い文章は
    //    途中で切れる。 切れている時だけ隅に「全文」 のボタンを出す。 ──
    final double _richFontSize =
        (node.memoFontSize ?? node.titleFontSize ?? widget.defaultMemoFontSize)
            .clamp(6.0, 28.0);
    final bool _shelfTextClipped = widget.isShelf &&
        node.clampHeight &&
        widget.onShowFullText != null &&
        node.tableData == null &&
        !isShelfLinkCard &&
        _shelfTextOverflows(
          node: node,
          // 本文枠は Container の左右 padding 10 を引いた幅 (描画と同じ)。
          maxWidth: nw - 20,
          // 同じく上下 padding 8 を引いた高さ。
          maxHeight: clampedBodyH - 16,
          titleStyle:
              TextStyle(fontSize: titleFontSize, fontWeight: FontWeight.w700),
          // ギャラリーはメモもタイトルと同じ大きさ・太さで描いている。
          memoStyle: TextStyle(
              fontSize: titleFontSize,
              height: 1.3,
              fontWeight: FontWeight.w700),
          richBaseStyle: TextStyle(
              color: titleTextColor,
              fontSize: _richFontSize,
              height: 1.3,
              fontWeight: FontWeight.w600),
          richSizeScale:
              _richFontSize / widget.defaultMemoFontSize.clamp(6.0, 28.0),
          linkColor: linkTextColor,
        );
    // ── 表ノードはタイトル/メモ/サムネイル等を持たない ──
    // totalH = タイトルバー (タイトル空時 14px、 タイトル有時はテキスト分膨らむ)
    //        + 表本体 (内容ベースの推定値) + 14 (下端パディング)。
    // mind_map_node.dart の visualHeight と必ず一致させる
    // (= estimateTableTitleBarHeight + estimateTotalHeight + 14)。
    final double totalH;
    if (node.tableData != null) {
      final t = node.tableData!;
      final cellW = t.colCount > 0
          ? ((node.width - 28.0 - (t.colCount + 1) * t.borderWidth) /
                  t.colCount)
              .clamp(20.0, double.infinity)
              .toDouble()
          : 60.0;
      final fs = (memoFontSize).clamp(6.0, 22.0).toDouble();
      final tableH = t.estimateTotalHeight(cellWidth: cellW, fontSize: fs);
      final titleBarH = node.estimateTableTitleBarHeight();
      totalH = titleBarH + tableH + 14.0;
    } else {
      totalH = bodyH + thumbH + linkBarH + linkedMapBarH + attachH;
    }
    final bool active = widget.isSelected || _dragging;
    final bool hasHighlight = widget.highlightAnchors.isNotEmpty;
    final bool isSearchCurrent = widget.isCurrentSearchResult;
    final bool isSearchHit = widget.isSearchHit && !isSearchCurrent;
    // ギャラリー入れ替えターゲット (= ユーザー要望)。 ドラッグ操作中の
    //   一時強調なので、 検索/選択枠より優先して表示する。
    final bool isSwapTarget = widget.isSwapTarget;
    const Color kSwapColor = Color(0xFFFF6D00); // 鮮やかなオレンジ

    // ── フローチャート形状 (= ユーザー要望: 基本記法にブロックの形状を
    //    変えられるように) ──
    // rounded(既定)/rect は角丸半径の違いで、 diamond/parallelogram は
    // ShapeDecoration (_FlowShapeBorder) で多角形として描画する。
    final rawNodeShape = node.shape ?? 'rounded';
    final String nodeShape =
        rawNodeShape == 'stadium' ? 'rounded' : rawNodeShape;
    // 多角形 (ShapeDecoration で描く) 形状の一覧。 端子の種類を増やした
    // (= ユーザー要望: 追加できる端子の種類を増やして)。
    const polyShapes = {
      'diamond',
      'parallelogram',
      'hexagon',
      'document',
      'cylinder',
      'trapezoid',
      'chevron',
      'circle',
    };
    final bool polyShape = polyShapes.contains(nodeShape);
    final double bodyRadius = node.tableData != null
        ? 8.0
        : nodeShape == 'rect'
            ? 4.0
            : 18.0;
    // 枠線・影は BoxDecoration / ShapeDecoration で共用する。
    final Color borderColor = isSwapTarget
        ? kSwapColor
        : isSearchCurrent
            ? const Color(0xFF00E5FF)
            : isSearchHit
                ? const Color(0xFF18FFFF)
                : hasHighlight
                    ? Colors.white
                    : widget.forceDragging
                        ? Colors.orangeAccent
                        : active
                            ? Colors.white
                            : Colors.transparent;
    final double borderWidth = isSwapTarget
        ? 3.5
        : isSearchCurrent
            ? 3.0
            : isSearchHit
                ? 2.0
                : 2.5;
    final List<BoxShadow> nodeShadows = [
      BoxShadow(
        color: isSwapTarget
            ? kSwapColor.withValues(alpha: 0.8)
            : isSearchCurrent
                // 旧: Colors.yellow / Colors.amber を使っていたが、
                // 黄色系は視認性が低い (特にライトモード) ためユーザー
                // 要望で全廃。代わりにシアン系の高彩度色を使用。
                ? const Color(0xFF00E5FF).withValues(alpha: 0.85)
                : isSearchHit
                    ? const Color(0xFF18FFFF).withValues(alpha: 0.55)
                    : hasHighlight
                        ? Colors.white.withValues(alpha: 0.6)
                        : effectiveColor.withValues(
                            alpha: _dragging ? 0.75 : 0.4),
        blurRadius: isSwapTarget
            ? 28
            : isSearchCurrent
                ? 32
                : isSearchHit
                    ? 20
                    : hasHighlight
                        ? 28
                        : (_dragging ? 22 : (active ? 18 : 8)),
        spreadRadius: isSwapTarget
            ? 8
            : isSearchCurrent
                ? 10
                : isSearchHit
                    ? 5
                    : hasHighlight
                        ? 8
                        : (_dragging ? 5 : (active ? 4 : 1)),
        offset: _dragging ? const Offset(0, 10) : const Offset(0, 4),
      ),
    ];

    return Positioned(
      left: _displayPos.dx,
      top: _displayPos.dy,
      // 切り取り中 (Ctrl+X) のノードは Windows と同じく薄く表示する。
      child: Opacity(
        opacity: widget.isCut ? 0.45 : 1.0,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              width: nw,
              constraints: node.clampHeight
                  ? BoxConstraints.tightFor(height: totalH)
                  : BoxConstraints(minHeight: totalH),
              decoration: polyShape
                  // ひし形 / 平行四辺形は ShapeDecoration で影も形状に沿わせる
                  ? ShapeDecoration(
                      color: effectiveColor,
                      shape: _FlowShapeBorder(
                        nodeShape,
                        side:
                            BorderSide(color: borderColor, width: borderWidth),
                      ),
                      shadows: nodeShadows,
                    )
                  : BoxDecoration(
                      color: effectiveColor,
                      borderRadius: BorderRadius.circular(bodyRadius),
                      boxShadow: nodeShadows,
                      border:
                          Border.all(color: borderColor, width: borderWidth),
                    ),
              child: ClipRRect(
                borderRadius:
                    BorderRadius.circular(polyShape ? 0.0 : bodyRadius),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ─── テキスト部分 ──────────────────────────────────
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _handleTap,
                      onSecondaryTapUp: _isDesktop
                          ? (details) =>
                              widget.onRightClick?.call(details.globalPosition)
                          : null,
                      onLongPressStart: canLongPressDrag
                          ? (details) {
                              HapticFeedback.mediumImpact();
                              widget.onLongPressStart!(details.globalPosition);
                            }
                          : null,
                      onLongPressMoveUpdate: canLongPressDrag
                          ? (details) {
                              widget.onLongPressMoveUpdate
                                  ?.call(details.globalPosition);
                            }
                          : null,
                      onLongPressEnd: canLongPressDrag
                          ? (_) {
                              widget.onLongPressEnd?.call();
                            }
                          : null,
                      onLongPressCancel: canLongPressDrag
                          ? () {
                              widget.onLongPressEnd?.call();
                            }
                          : null,
                      // ── デスクトップ: マウスドラッグで即座に移動 ──
                      // ── モバイル: 複数選択モード時は通常パンで即移動 (enablePanDrag) ──
                      // 範囲選択中は親キャンバスが pan を受け取る必要がある。
                      // コールバックが無いノードまで recognizer を登録すると
                      // ジェスチャーアリーナを奪い、選択矩形が出ないことがある。
                      onPanStart: canPanDrag
                          ? (details) {
                              _panDragActive = true;
                              widget.onLongPressStart
                                  ?.call(details.globalPosition);
                            }
                          : null,
                      onPanUpdate: canPanDrag
                          ? (details) {
                              if (_panDragActive) {
                                widget.onLongPressMoveUpdate
                                    ?.call(details.globalPosition);
                              }
                            }
                          : null,
                      onPanEnd: canPanDrag
                          ? (_) {
                              if (_panDragActive) {
                                _panDragActive = false;
                                widget.onLongPressEnd?.call();
                              }
                            }
                          : null,
                      onPanCancel: canPanDrag
                          ? () {
                              if (_panDragActive) {
                                _panDragActive = false;
                                widget.onLongPressEnd?.call();
                              }
                            }
                          : null,
                      child: node.tableData != null
                          // ── 表ノード: ドラッグハンドル帯 + 表を一括 wrap ──
                          // ・上端 14px: ノード色の細い帯 + 中央に ≡ アイコン
                          //   → ドラッグ用ヒットエリア
                          // ・タイトル有: 上にタイトルテキストも表示 (= 膨らむ)
                          // ・左右下 14px の Padding に表本体
                          //
                          // 両方を「親の GestureDetector」 の child Column 内に
                          // 入れることで、 padding 領域 (= セル外の余白) でも
                          // 親の onTap (= ノード選択) / onSecondaryTapUp (=
                          // ノードの右クリックメニュー) / onLongPressStart (=
                          // ドラッグ) が反応する。
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: nw,
                                  padding: headerTitle.isEmpty
                                      ? EdgeInsets.zero
                                      : const EdgeInsets.only(
                                          top: 4,
                                          left: 14,
                                          right: 14,
                                          bottom: 4),
                                  alignment: Alignment.topCenter,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        height: 14,
                                        child: Icon(
                                          Icons.drag_handle_rounded,
                                          size: 10,
                                          color: titleTextColor.withValues(
                                              alpha: 0.45),
                                        ),
                                      ),
                                      if (headerTitle.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          headerTitle,
                                          textAlign: TextAlign.center,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: titleTextColor,
                                            fontSize: node.titleFontSize ??
                                                widget.defaultTitleFontSize,
                                            fontWeight: FontWeight.w700,
                                            height: 1.2,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(
                                      left: 14, right: 14, bottom: 14),
                                  child: _NodeTableInlineWidget(
                                    table: node.tableData!,
                                    nodeId: node.id,
                                    maxWidth: (nw - 28)
                                        .clamp(20, double.infinity)
                                        .toDouble(),
                                    textColor: titleTextColor,
                                    fontSize: memoFontSize,
                                    isLightBg: _isLightBg,
                                    provider: context.read<MindMapProvider>(),
                                    onNodeSelectTap: _handleTap,
                                    onRequestScreenFocus:
                                        widget.onRequestScreenFocus,
                                    onInlineEditingStarted:
                                        widget.onInlineEditingStarted,
                                    onInlineEditingEnded:
                                        widget.onInlineEditingEnded,
                                    onChanged: (newTable) {
                                      context
                                          .read<MindMapProvider>()
                                          .updateNodeTable(node.id, newTable);
                                    },
                                  ),
                                ),
                              ],
                            )
                          : isShelfLinkCard
                              // ── ギャラリーのリンク専用ノード: ブックマークカードで
                              //    本体を埋める (= ユーザー要望: 空の実体が大きすぎる) ──
                              ? _buildLinkCoverCard(
                                  url: linkUrl!,
                                  title: node.title,
                                  width: nw,
                                  height: node.height,
                                )
                              : Container(
                                  width: nw,
                                  // 高さ固定タイルでは「サムネイル等を除いた
                                  // 残り」 が本文領域 (= ユーザー要望: 隙間を
                                  // 作らず周りの要素と同じ大きさに)。
                                  constraints: node.clampHeight
                                      ? BoxConstraints.tightFor(
                                          height: clampedBodyH)
                                      : BoxConstraints(minHeight: node.height),
                                  alignment: Alignment.center,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 8),
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      SizedBox(
                                        width: nw - 20,
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            // ── リッチテキスト統合表示 (= ユーザー要望:
                                            //   タイトルとメモを分けず 1 ブロックで表示) ──
                                            // richText があれば Text.rich で統合描画。
                                            //   無ければ従来どおりタイトル Text + メモ。
                                            if (node.richText != null &&
                                                node.richText!.isNotEmpty)
                                              Text.rich(
                                                MindMapNode.buildRichSpan(
                                                  node.richText!,
                                                  TextStyle(
                                                    color: titleTextColor,
                                                    // ── ノード個別の文字サイズ設定を
                                                    //   反映 (= ユーザー要望: ギャラリー
                                                    //   要素の文字サイズが効かない時が
                                                    //   ある問題の修正)。 メモ →
                                                    //   タイトルの順で個別設定を拾う。
                                                    fontSize: (node
                                                                .memoFontSize ??
                                                            node
                                                                .titleFontSize ??
                                                            widget
                                                                .defaultMemoFontSize)
                                                        .clamp(6.0, 28.0),
                                                    height: 1.3,
                                                    // 既定は読みやすい太めを維持しつつ、
                                                    // 明示 bold (w800) との差が見える重さ。
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                  // 明示サイズ付き span も設定に比例
                                                  // させる (デフォルト時は 1.0 = 従来)。
                                                  sizeScale: (node.memoFontSize ??
                                                              node
                                                                  .titleFontSize ??
                                                              widget
                                                                  .defaultMemoFontSize)
                                                          .clamp(6.0, 28.0) /
                                                      widget.defaultMemoFontSize
                                                          .clamp(6.0, 28.0),
                                                  // 背景の明暗に応じたリンク色
                                                  // (= ユーザー要望)。
                                                  linkColor: linkTextColor,
                                                ),
                                                textAlign: TextAlign.center,
                                              )
                                            else
                                              Text(
                                                node.title,
                                                style: TextStyle(
                                                  color: titleTextColor,
                                                  fontSize: titleFontSize,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                                textAlign: TextAlign.center,
                                                maxLines: node.clampHeight
                                                    ? ((node.height -
                                                                (hasMemo
                                                                    ? 28.0
                                                                    : 16.0)) /
                                                            (titleFontSize *
                                                                1.2))
                                                        .floor()
                                                        .clamp(1, 99)
                                                    : node.titleMaxLines,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            if (hasMemo &&
                                                (node.richText == null ||
                                                    node.richText!.isEmpty))
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                    top: 4),
                                                child: () {
                                                  // ── タイムスタンプ判定 ──
                                                  // memoText が `[mm:ss]` または
                                                  // `[h:mm:ss]` の形式 (= 動画メモから
                                                  // 自動生成されたもの) なら、 タップで
                                                  // 動画のその時刻に飛べるハイパーリンク
                                                  // 風表示にする。 そうでなければ通常の
                                                  // メモテキスト表示。
                                                  final mt =
                                                      node.memoText!.trim();
                                                  final tsSec =
                                                      NodeWidget.parseTimestamp(
                                                          mt);
                                                  final canJump = tsSec !=
                                                          null &&
                                                      widget.onMemoTimestampTap !=
                                                          null;
                                                  if (!canJump) {
                                                    // ── ギャラリーのタイルは
                                                    //   1 行目 (タイトル) と
                                                    //   2 行目以降 (メモ) の
                                                    //   太さ・大きさ・色を揃える
                                                    //   (= ユーザー要望: 全て
                                                    //   1 行目の太さになるように)。
                                                    final double effMemoSize =
                                                        widget.isShelf
                                                            ? titleFontSize
                                                            : memoFontSize;
                                                    final Color effMemoColor =
                                                        widget.isShelf
                                                            ? titleTextColor
                                                            : memoTextColor;
                                                    return Text(
                                                      node.memoText!,
                                                      style: TextStyle(
                                                        color: effMemoColor,
                                                        fontSize: effMemoSize,
                                                        height: 1.3,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                      textAlign:
                                                          TextAlign.center,
                                                      maxLines: node.clampHeight
                                                          ? ((node.height - 22) /
                                                                  (effMemoSize *
                                                                      1.3))
                                                              .floor()
                                                              .clamp(1, 99)
                                                          : null,
                                                      overflow: node.clampHeight
                                                          ? TextOverflow
                                                              .ellipsis
                                                          : TextOverflow.clip,
                                                    );
                                                  }
                                                  // ハイパーリンク版: 下線 + ライト系
                                                  // ブルーで「クリッカブル」 と分かる
                                                  // 見た目にする。 タップ領域は十分広く
                                                  // 取るため Padding 込みで GestureDetector
                                                  // で包む (ノード本体の onTap とは
                                                  // 独立して動く)。
                                                  return GestureDetector(
                                                    behavior:
                                                        HitTestBehavior.opaque,
                                                    onTap: () {
                                                      widget.onMemoTimestampTap!(
                                                          tsSec);
                                                    },
                                                    child: Padding(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 6,
                                                          vertical: 2),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        mainAxisAlignment:
                                                            MainAxisAlignment
                                                                .center,
                                                        children: [
                                                          Icon(
                                                            Icons
                                                                .play_circle_fill_rounded,
                                                            size: memoFontSize +
                                                                2,
                                                            color: const Color(
                                                                0xFF4FC3F7),
                                                          ),
                                                          const SizedBox(
                                                              width: 4),
                                                          Text(
                                                            node.memoText!,
                                                            style: TextStyle(
                                                              color: const Color(
                                                                  0xFF4FC3F7),
                                                              fontSize:
                                                                  memoFontSize,
                                                              height: 1.3,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              decoration:
                                                                  TextDecoration
                                                                      .underline,
                                                              decorationColor:
                                                                  const Color(
                                                                      0xFF4FC3F7),
                                                            ),
                                                            textAlign: TextAlign
                                                                .center,
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  );
                                                }(),
                                              ),
                                            // メモが折りたたまれている時の小さなインジケータ
                                            if (memoIndicatorOnly)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                    top: 3),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                    Icon(
                                                      Icons.notes_rounded,
                                                      size: 11,
                                                      color: Colors.white
                                                          .withValues(
                                                              alpha: 0.45),
                                                    ),
                                                    const SizedBox(width: 3),
                                                    Text(
                                                      '…',
                                                      style: TextStyle(
                                                        color: Colors.white
                                                            .withValues(
                                                                alpha: 0.45),
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        height: 1.0,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      if (hasAnyLink)
                                        // 右上のインジケーターアイコンは表示しない
                                        const SizedBox.shrink(),
                                    ],
                                  ),
                                ),
                    ),

                    // ─── YouTubeサムネイル / mp4サムネイル ──────────────────
                    if (videoId != null || isMp4)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => widget.onThumbnailTap?.call(),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // 通常動画は 16:9、Shorts は 9:16 の枠を確保し、
                            // サムネイル自体は切り抜かず全体を表示する。
                            SizedBox(
                              width: nw,
                              height: thumbH,
                              child: ClipRect(
                                child: ColoredBox(
                                  color: Colors.black,
                                  child: Center(
                                    child: SizedBox(
                                      width: nw,
                                      height: thumbH,
                                      child: videoId != null
                                          ? Image.network(
                                              NodeWidget.thumbnailUrl(videoId),
                                              fit: BoxFit.contain,
                                              alignment: Alignment.center,
                                              errorBuilder: (_, __, ___) =>
                                                  Container(
                                                color: Colors.black87,
                                                child: const Icon(
                                                    Icons.play_circle_outline,
                                                    color: Colors.white38,
                                                    size: 32),
                                              ),
                                            )
                                          : (node.videoThumbnailPath ?? '')
                                                  .isNotEmpty
                                              ? Image.file(
                                                  File(
                                                      node.videoThumbnailPath!),
                                                  fit: BoxFit.contain,
                                                  alignment: Alignment.center,
                                                  errorBuilder: (_, __, ___) =>
                                                      _Mp4Placeholder(
                                                    url: node.youtubeUrl!,
                                                    thumbH: thumbH,
                                                    nw: nw,
                                                  ),
                                                )
                                              : _Mp4Placeholder(
                                                  url: node.youtubeUrl!,
                                                  thumbH: thumbH,
                                                  nw: nw,
                                                ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // 再生ボタンオーバーレイ
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.55),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.play_arrow_rounded,
                                  color: Colors.white, size: 26),
                            ),
                            // ── オフライン (= ダウンロード済み) バッジ ──
                            // サムネの右下に小さく表示。緑の `download_done`
                            // アイコンで「端末に保存済み = ネット無しでも再生
                            // できる」ことを一目で分かるようにする。
                            // YouTube オンライン動画 (videoId != null) には
                            // 表示しない。
                            if (isOffline)
                              Positioned(
                                right: 4,
                                bottom: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF43B97F)
                                        .withValues(alpha: 0.95),
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: [
                                      BoxShadow(
                                        color:
                                            Colors.black.withValues(alpha: 0.4),
                                        blurRadius: 3,
                                        offset: const Offset(0, 1),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.download_done_rounded,
                                          color: Colors.white, size: 11),
                                      const SizedBox(width: 2),
                                      Text(
                                        // Provider が context にあれば翻訳した
                                        // ラベルを使う。無ければ日本語フォール
                                        // バック。
                                        Provider.of<MindMapProvider?>(context,
                                                    listen: false)
                                                ?.t('video.offline') ??
                                            'オフライン',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                            height: 1.1),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),

                    // ─── ハイパーリンクバーは attach の後ろ (= 一番下) に配置 ──
                    // ノードに画像が添付されているとき、 リンクピルが画像の上に
                    // 来てしまうと「画像が何のリンクのプレビューか」 が直感的に
                    // 分からなくなる。 「画像 → リンクピル」 の順 (= chip が画像の
                    // 下に来る) の方が、 「この画像はこの URL 由来」 という関係が
                    // 自然に読み取れる。 該当ブロックは attach の後に置く。

                    // ─── サブマップ埋め込みリンクバー ──────────────────
                    // ノード内部に「白背景 + 🌳 アイコン + マップ名」 のピル
                    // を表示。 タップで該当マップへ遷移する。 リンク URL バー
                    // と同じデザイン言語で「これはリンク」 と一目で分かる。
                    // ノード本体のタップとは独立しているため、 通常通り編集
                    // できる (= リンクの貼り付けと同じ設計思想)。
                    if (hasLinkedMap)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => widget.onLinkedMapTap?.call(),
                        child: Container(
                          width: nw,
                          height: linkedMapBarH,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.vertical(
                              // linkedMapBar の後ろに attach か linkBar が
                              // 来るときは下隅を四角に。 どちらも来ないときだけ
                              // 自分が末端なので下隅を丸める。
                              bottom: (hasAttachment || hasLinkBar)
                                  ? Radius.zero
                                  : const Radius.circular(18),
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          // 上のハイパーリンクバーと同様、 中央揃えに統一
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.account_tree_rounded,
                                  size: 12, color: Color(0xFF6C63FF)),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  linkedMapName ?? '???',
                                  style: const TextStyle(
                                    color: Color(0xFF6C63FF),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    decoration: TextDecoration.underline,
                                    decorationColor: Color(0xFF6C63FF),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // ─── 添付ファイル表示 ──────────────────────────────
                    if (hasAttachment)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => widget.onAttachmentTap?.call(),
                        child: isDocCoverAttach
                            ? _buildDocCoverCard(
                                ext: attachExt,
                                name: node.attachmentName ??
                                    attachExt.toUpperCase(),
                                path: node.attachmentPath,
                                width: nw,
                                height: attachH,
                                squareBottom: hasLinkBar,
                              )
                            : (isImageAttach || hasThumb)
                                ? SizedBox(
                                    width: nw,
                                    height: attachH,
                                    child: Stack(children: [
                                      Positioned.fill(
                                        child: ClipRRect(
                                      // 後ろに linkBar が来るときは下隅を四角に。
                                      borderRadius: BorderRadius.vertical(
                                        bottom: hasLinkBar
                                            ? Radius.zero
                                            : const Radius.circular(18),
                                      ),
                                      // 画像はそのパス、 PDF/pptx はサムネイル画像
                                      //   (attachImgPath)。 http はネットワーク画像、
                                      //   ローカルは File 経由。実画像は端を切らず
                                      //   全体表示し、文書サムネイルだけ表紙として
                                      //   上端基準の cover を維持する。
                                      child: ColoredBox(
                                        color: Colors.white,
                                        child: attachImgPath
                                                    .startsWith('http://') ||
                                                attachImgPath
                                                    .startsWith('https://')
                                            ? Image.network(
                                                attachImgPath,
                                                fit: isImageAttach
                                                    ? BoxFit.contain
                                                    : BoxFit.cover,
                                                alignment: isImageAttach
                                                    ? Alignment.center
                                                    : Alignment.topCenter,
                                                errorBuilder: (_, __, ___) =>
                                                    Container(
                                                  color: Colors.black54,
                                                  child: const Icon(
                                                      Icons
                                                          .broken_image_outlined,
                                                      color: Colors.white38),
                                                ),
                                              )
                                            : Image.file(
                                                File(attachImgPath),
                                                fit: isImageAttach
                                                    ? BoxFit.contain
                                                    : BoxFit.cover,
                                                alignment: isImageAttach
                                                    ? Alignment.center
                                                    : Alignment.topCenter,
                                                errorBuilder: (_, __, ___) =>
                                                    Container(
                                                  color: Colors.black54,
                                                  child: const Icon(
                                                      Icons
                                                          .broken_image_outlined,
                                                      color: Colors.white38),
                                                ),
                                              ),
                                      ),
                                    ),
                                      ),
                                      // (ファイル名は上のタイトル欄に出す
                                      //  = ユーザー要望: 周りのノードと揃える)
                                    ]),
                                  )
                                : Container(
                                    width: nw,
                                    height: attachH,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFE8EAF6),
                                      borderRadius: BorderRadius.vertical(
                                        // 後ろに linkBar が来るときは下隅を四角に。
                                        bottom: hasLinkBar
                                            ? Radius.zero
                                            : const Radius.circular(18),
                                      ),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8),
                                    // ── 中央揃え ──
                                    // ユーザー要望「埋め込まれるリンクは中央揃えに
                                    // なるようにして」 に合わせて、 添付ファイル名を
                                    // ピル中央に表示する。 アイコン + ファイル名 +
                                    // 「外部リンク」 アイコンの 3 つを mainAxisAlignment
                                    // .center で中央に寄せ、 ファイル名 (Flexible) は
                                    // 必要に応じて ellipsis で省略される。
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          attachExt == 'pdf'
                                              ? Icons.picture_as_pdf_rounded
                                              : Icons.insert_drive_file_rounded,
                                          size: 16,
                                          color: attachExt == 'pdf'
                                              ? const Color(0xFFFF7043)
                                              : const Color(0xFF00ACC1),
                                        ),
                                        const SizedBox(width: 4),
                                        Flexible(
                                          child: Text(
                                            node.attachmentName ??
                                                (attachExt == 'pdf'
                                                    ? 'PDF'
                                                    : (attachExt.isEmpty
                                                        ? 'ファイル'
                                                        : attachExt
                                                            .toUpperCase())),
                                            style: const TextStyle(
                                              color: Color(0xFF37474F),
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        const Icon(Icons.open_in_new_rounded,
                                            size: 10, color: Color(0xFF00ACC1)),
                                      ],
                                    ),
                                  ),
                      ),

                    // ─── ハイパーリンクバー (画像/添付ファイルの下) ──────────
                    // ノード本体の最下段に配置。 画像が attach されている場合は
                    // 「画像 → リンクピル」 の順で並び、 ピルが画像の下に来る。
                    // ギャラリーのリンクカードはカード内にホストを表示するので、
                    //   別途のリンクバーは出さない (= isShelfLinkCard)。
                    if (hasLinkBar && !isShelfLinkCard)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => widget.onThumbnailTap?.call(),
                        child: Container(
                          width: nw,
                          height: linkBarH,
                          decoration: const BoxDecoration(
                            color: Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.vertical(
                                bottom: Radius.circular(18)),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          // ── 中央揃え ──
                          // 旧実装は Expanded で Text をバー全幅に広げて
                          // 左寄せだったが、 ユーザーから「埋め込まれる
                          // リンクは中央揃えになるようにして」 と要望が
                          // あったため、 アイコン + テキストをグループとして
                          // 中央配置する。 テキストが長い場合は Flexible で
                          // 最大幅に達して ellipsis に切り替わる。
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.open_in_new_rounded,
                                  size: 12, color: Color(0xFF7C4DFF)),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  Uri.tryParse(linkUrl)?.host ?? linkUrl,
                                  style: const TextStyle(
                                    color: Color(0xFF7C4DFF),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    decoration: TextDecoration.underline,
                                    decorationColor: Color(0xFF7C4DFF),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // ─── アンカードット ─────────────────────────────────────
            if (hasHighlight)
              for (final anchor in widget.highlightAnchors)
                _buildAnchorDot(anchor, nw, totalH),

            // ─── 折りたたみバッジ ──────────────────────────────────
            if (node.collapsed)
              Positioned(
                right: -6,
                bottom: -6,
                child: IgnorePointer(
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: const Color(0xFF7E57C2),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: const Icon(Icons.more_horiz,
                        size: 12, color: Colors.white),
                  ),
                ),
              ),
            if (!node.collapsed &&
                (node.collapsedChildIds?.isNotEmpty ?? false))
              Positioned(
                right: -6,
                bottom: -6,
                child: IgnorePointer(
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: const Color(0xFF7E57C2),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: const Icon(Icons.call_split_rounded,
                        size: 12, color: Colors.white),
                  ),
                ),
              ),

            // ─── スナップラベル ─────────────────────────────────────
            if (_dragging && widget.currentSnap != null)
              Positioned(
                top: -30,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF43B97F),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.4),
                              blurRadius: 8)
                        ],
                      ),
                      child: Text(
                          context.read<MindMapProvider>().t('nw.connect'),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ),

            // ─── アップロード/ダウンロード進捗オーバーレイ ─────────────
            if (widget.uploadProgress != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.55),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: nw * 0.6,
                            child: LinearProgressIndicator(
                              value: widget.uploadProgress!,
                              backgroundColor: Colors.white24,
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFF4FC3F7)),
                              minHeight: 6,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${(widget.uploadProgress! * 100).toInt()}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // ─── リサイズハンドル（選択時のみ表示） ─────────────
            if (widget.showResizeHandles && widget.onSizeChanged != null) ...[
              // ── 辺ハンドル（4辺） ──
              // 右
              _buildEdgeHandle(
                right: -10,
                top: totalH * 0.25,
                width: 18,
                height: totalH * 0.5,
                cursor: SystemMouseCursors.resizeLeftRight,
                onDrag: (dx, dy) => _emitResize(
                    (_resizeStartW + dx).clamp(80.0, _maxHandleW),
                    _resizeStartH,
                    0,
                    0),
              ),
              // 左
              _buildEdgeHandle(
                left: -10,
                top: totalH * 0.25,
                width: 18,
                height: totalH * 0.5,
                cursor: SystemMouseCursors.resizeLeftRight,
                onDrag: (dx, dy) {
                  final newW = (_resizeStartW - dx).clamp(80.0, _maxHandleW);
                  final posDx = _resizeStartW - newW;
                  _emitResize(newW, _resizeStartH, posDx, 0);
                },
              ),
              // 下
              _buildEdgeHandle(
                bottom: -10,
                left: nw * 0.25,
                width: nw * 0.5,
                height: 18,
                cursor: SystemMouseCursors.resizeUpDown,
                onDrag: (dx, dy) => _emitResize(_resizeStartW,
                    (_resizeStartH + dy).clamp(36.0, 200.0), 0, 0),
              ),
              // 上
              _buildEdgeHandle(
                top: -10,
                left: nw * 0.25,
                width: nw * 0.5,
                height: 18,
                cursor: SystemMouseCursors.resizeUpDown,
                onDrag: (dx, dy) {
                  final newH = (_resizeStartH - dy).clamp(36.0, 200.0);
                  final posDy = _resizeStartH - newH;
                  _emitResize(_resizeStartW, newH, 0, posDy);
                },
              ),
              // ── コーナーハンドル（4隅） ──
              // 右下
              _buildCornerHandle(
                right: -12,
                bottom: -12,
                cursor: SystemMouseCursors.resizeDownRight,
                onDrag: (dx, dy) => _emitResize(
                    (_resizeStartW + dx).clamp(80.0, _maxHandleW),
                    (_resizeStartH + dy).clamp(36.0, 200.0),
                    0,
                    0),
              ),
              // 左下
              _buildCornerHandle(
                left: -12,
                bottom: -12,
                cursor: SystemMouseCursors.resizeDownLeft,
                onDrag: (dx, dy) {
                  final newW = (_resizeStartW - dx).clamp(80.0, _maxHandleW);
                  _emitResize(newW, (_resizeStartH + dy).clamp(36.0, 200.0),
                      _resizeStartW - newW, 0);
                },
              ),
              // 右上
              _buildCornerHandle(
                right: -12,
                top: -12,
                cursor: SystemMouseCursors.resizeUpRight,
                onDrag: (dx, dy) {
                  final newH = (_resizeStartH - dy).clamp(36.0, 200.0);
                  _emitResize((_resizeStartW + dx).clamp(80.0, _maxHandleW),
                      newH, 0, _resizeStartH - newH);
                },
              ),
              // 左上
              _buildCornerHandle(
                left: -12,
                top: -12,
                cursor: SystemMouseCursors.resizeUpLeft,
                onDrag: (dx, dy) {
                  final newW = (_resizeStartW - dx).clamp(80.0, _maxHandleW);
                  final newH = (_resizeStartH - dy).clamp(36.0, 200.0);
                  _emitResize(
                      newW, newH, _resizeStartW - newW, _resizeStartH - newH);
                },
              ),
            ],
            // ── 文字が入り切らないギャラリータイルの「全文」 ボタン ──
            // (= ユーザー要望: 入り切らない文字を表示する)。 切れている時だけ
            //   右下に出る。 押すと全文を読める窓が開く。 パソコンでは
            //   カーソルを乗せるだけでも中身が覗ける。
            //   Tooltip は triggerMode を manual にして、 このタイル自身の
            //   長押し (= 並べ替えのドラッグ) を邪魔しないようにする。
            //   選択中はここに大きさ変更のつまみが出るので、 その時は隠す
            //   (重なるとつまみを掴めなくなる)。
            if (_shelfTextClipped && !widget.showResizeHandles)
              Positioned(
                right: 2,
                bottom: 2,
                child: Tooltip(
                  triggerMode: TooltipTriggerMode.manual,
                  waitDuration: const Duration(milliseconds: 300),
                  message: _fullTextPreview(node),
                  textStyle: const TextStyle(
                      color: Colors.white, fontSize: 12, height: 1.4),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onShowFullText,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: _isLightBg
                            ? const Color(0xCC000000)
                            : const Color(0xCCFFFFFF),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(
                        Icons.more_horiz_rounded,
                        size: 13,
                        color: _isLightBg ? Colors.white : Colors.black87,
                      ),
                    ),
                  ),
                ),
              ),
            // ── 格納ノード（isContainer = true）の右上バッジ ──
            // 📦 アイコン + 含まれているノード数で、一目で格納ノードと分かるように
            if (node.isContainer)
              Positioned(
                right: -6,
                top: -8,
                child: IgnorePointer(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFA726),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFFA726).withValues(alpha: 0.6),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Text('📦',
                          style: TextStyle(fontSize: 11, height: 1.0)),
                      const SizedBox(width: 2),
                      Text('${node.containedNodeIds?.length ?? 0}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnchorDot(AnchorDirection dir, double nw, double totalH) {
    const double dotSize = 12.0;
    double? left, top;
    switch (dir) {
      case AnchorDirection.north:
        left = nw / 2 - dotSize / 2;
        top = -dotSize / 2;
        break;
      case AnchorDirection.south:
        left = nw / 2 - dotSize / 2;
        top = totalH - dotSize / 2;
        break;
      case AnchorDirection.east:
        left = nw - dotSize / 2;
        top = totalH / 2 - dotSize / 2;
        break;
      case AnchorDirection.west:
        left = -dotSize / 2;
        top = totalH / 2 - dotSize / 2;
        break;
      case AnchorDirection.northEast:
        left = nw - dotSize / 2;
        top = -dotSize / 2;
        break;
      case AnchorDirection.northWest:
        left = -dotSize / 2;
        top = -dotSize / 2;
        break;
      case AnchorDirection.southEast:
        left = nw - dotSize / 2;
        top = totalH - dotSize / 2;
        break;
      case AnchorDirection.southWest:
        left = -dotSize / 2;
        top = totalH - dotSize / 2;
        break;
    }
    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Container(
          width: dotSize,
          height: dotSize,
          decoration: BoxDecoration(
            color: const Color(0xFF43B97F),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: [
              BoxShadow(
                  color: const Color(0xFF43B97F).withValues(alpha: 0.5),
                  blurRadius: 6,
                  spreadRadius: 1)
            ],
          ),
        ),
      ),
    );
  }

  // ── リサイズハンドルビルダー ──

  Widget _buildEdgeHandle({
    double? left,
    double? right,
    double? top,
    double? bottom,
    required double width,
    required double height,
    required MouseCursor cursor,
    required void Function(double dx, double dy) onDrag,
  }) {
    return Positioned(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          _resizing = true;
          _resizeStartW = widget.node.width;
          _resizeStartH = widget.node.height;
          _resizeDragStart = d.globalPosition;
          _accumPosDx = 0;
          _accumPosDy = 0;
        },
        onPanUpdate: (d) {
          if (!_resizing) return;
          final dx = d.globalPosition.dx - _resizeDragStart.dx;
          final dy = d.globalPosition.dy - _resizeDragStart.dy;
          onDrag(dx, dy);
        },
        onPanEnd: (_) => _resizing = false,
        child: MouseRegion(
          cursor: cursor,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.58),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF6C63FF), width: 1.2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCornerHandle({
    double? left,
    double? right,
    double? top,
    double? bottom,
    required MouseCursor cursor,
    required void Function(double dx, double dy) onDrag,
  }) {
    return Positioned(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) {
          _resizing = true;
          _resizeStartW = widget.node.width;
          _resizeStartH = widget.node.height;
          _resizeDragStart = d.globalPosition;
          _accumPosDx = 0;
          _accumPosDy = 0;
        },
        onPanUpdate: (d) {
          if (!_resizing) return;
          final dx = d.globalPosition.dx - _resizeDragStart.dx;
          final dy = d.globalPosition.dy - _resizeDragStart.dy;
          onDrag(dx, dy);
        },
        onPanEnd: (_) => _resizing = false,
        child: MouseRegion(
          cursor: cursor,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF6C63FF), width: 1.8),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayBtn extends StatelessWidget {
  const _PlayBtn();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.9), shape: BoxShape.circle),
      child:
          const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 22),
    );
  }
}

/// フローチャート形状 (ひし形 / 平行四辺形) 用の ShapeBorder
/// (= ユーザー要望: フローチャートの基本記法にブロックの形状を変えられる
///    ように)。 ShapeDecoration に渡すことで塗り・影・枠線が形状に沿う。
class _FlowShapeBorder extends ShapeBorder {
  /// 'diamond' (判断) | 'parallelogram' (入出力) | 'hexagon' (準備) |
  /// 'document' (書類) | 'cylinder' (データベース) | 'trapezoid' (手作業) |
  /// 'chevron' (工程/矢印) | 'circle' (結合子)
  final String kind;
  final BorderSide side;
  const _FlowShapeBorder(this.kind, {this.side = BorderSide.none});

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  Path _path(Rect rect) {
    switch (kind) {
      case 'diamond':
        return Path()
          ..moveTo(rect.center.dx, rect.top)
          ..lineTo(rect.right, rect.center.dy)
          ..lineTo(rect.center.dx, rect.bottom)
          ..lineTo(rect.left, rect.center.dy)
          ..close();
      case 'hexagon':
        {
          // 準備 (六角形)
          final c = (rect.width * 0.16).clamp(8.0, 34.0).toDouble();
          return Path()
            ..moveTo(rect.left + c, rect.top)
            ..lineTo(rect.right - c, rect.top)
            ..lineTo(rect.right, rect.center.dy)
            ..lineTo(rect.right - c, rect.bottom)
            ..lineTo(rect.left + c, rect.bottom)
            ..lineTo(rect.left, rect.center.dy)
            ..close();
        }
      case 'document':
        {
          // 書類 (下辺が波打つ長方形)
          final w = rect.height * 0.16;
          return Path()
            ..moveTo(rect.left, rect.top)
            ..lineTo(rect.right, rect.top)
            ..lineTo(rect.right, rect.bottom - w)
            ..quadraticBezierTo(rect.left + rect.width * 0.75,
                rect.bottom - w * 2.4, rect.center.dx, rect.bottom - w)
            ..quadraticBezierTo(rect.left + rect.width * 0.25,
                rect.bottom + w * 0.4, rect.left, rect.bottom - w)
            ..close();
        }
      case 'cylinder':
        {
          // データベース (円筒)
          final e = (rect.height * 0.18).clamp(6.0, 24.0).toDouble();
          return Path()
            ..moveTo(rect.left, rect.top + e)
            ..arcToPoint(Offset(rect.right, rect.top + e),
                radius: Radius.elliptical(rect.width / 2, e),
                clockwise: true)
            ..lineTo(rect.right, rect.bottom - e)
            ..arcToPoint(Offset(rect.left, rect.bottom - e),
                radius: Radius.elliptical(rect.width / 2, e),
                clockwise: true)
            ..close();
        }
      case 'trapezoid':
        {
          // 手作業 (台形)
          final s = (rect.width * 0.14).clamp(8.0, 34.0).toDouble();
          return Path()
            ..moveTo(rect.left + s, rect.top)
            ..lineTo(rect.right - s, rect.top)
            ..lineTo(rect.right, rect.bottom)
            ..lineTo(rect.left, rect.bottom)
            ..close();
        }
      case 'chevron':
        {
          // 工程 (右向き矢印ブロック)
          final s = (rect.width * 0.14).clamp(10.0, 40.0).toDouble();
          return Path()
            ..moveTo(rect.left, rect.top)
            ..lineTo(rect.right - s, rect.top)
            ..lineTo(rect.right, rect.center.dy)
            ..lineTo(rect.right - s, rect.bottom)
            ..lineTo(rect.left, rect.bottom)
            ..lineTo(rect.left + s, rect.center.dy)
            ..close();
        }
      case 'circle':
        // 結合子 (楕円)
        return Path()..addOval(rect);
      default:
        {
          // parallelogram: 上辺を右へずらした平行四辺形
          final double skew = (rect.width * 0.18).clamp(10.0, 40.0).toDouble();
          return Path()
            ..moveTo(rect.left + skew, rect.top)
            ..lineTo(rect.right, rect.top)
            ..lineTo(rect.right - skew, rect.bottom)
            ..lineTo(rect.left, rect.bottom)
            ..close();
        }
    }
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect.deflate(side.width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width <= 0) return;
    if (side.color.a == 0.0) return; // 透明枠 (非選択時) は描かない
    canvas.drawPath(
      _path(rect.deflate(side.width / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = side.width
        ..color = side.color
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  ShapeBorder scale(double t) => _FlowShapeBorder(kind, side: side.scale(t));
}

/// mp4動画のプレースホルダー表示（サムネイルが無い場合に使用）
class _Mp4Placeholder extends StatelessWidget {
  final String url;
  final double thumbH;
  final double nw;
  const _Mp4Placeholder({
    required this.url,
    required this.thumbH,
    required this.nw,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            url.startsWith('http')
                ? Icons.video_library_rounded
                : Icons.video_file_rounded,
            color: const Color(0xFF4FC3F7),
            size: thumbH * 0.35,
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              url.split('/').last.split('\\').last,
              style: TextStyle(
                  color: Colors.white54,
                  fontSize: (nw * 0.06).clamp(8.0, 11.0)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _NodeTableInlineWidget extends StatefulWidget {
  /// 描画する TableData 本体 (provider 経由でノードから取得)。
  final TableData table;

  /// 変更通知 (親で provider.updateNodeTable() に転送)。
  final ValueChanged<TableData> onChanged;

  /// セル文字色 (ノード背景に応じて親が決定)。
  final Color textColor;

  /// ノード内テーブル表示エリアの最大幅 (= ノード幅)。 超えると横スクロール。
  final double maxWidth;

  /// セル内フォントサイズ。
  final double fontSize;

  /// 翻訳キー解決用 + provider 直接呼び出し (列幅・行高さの変更等) 用。
  final MindMapProvider provider;

  /// このテーブルが属するノード ID。 右クリックメニューからの列幅・行高さ
  /// 変更で provider のメソッドを呼ぶときに必要。
  final String? nodeId;

  /// ノードの背景輝度。 罫線色を背景コントラストに応じて白/黒に自動切替する。
  /// true = 明るい背景 → 黒寄り罫線、 false = 暗い背景 → 白寄り罫線。
  final bool isLightBg;

  /// セルがタップされた時、 編集開始と同時に「ノード選択」 も発火する
  /// ためのコールバック。 親 NodeWidget から `_handleTap` を渡す。
  ///
  /// これがないと、 セルクリック → 編集モード → Esc で抜ける、 という
  /// 流れの後にノードが「選択状態」 になっておらず、 Backspace 等の
  /// 画面ルートのショートカットで削除できない。
  final VoidCallback? onNodeSelectTap;

  /// 編集終了時に画面ルートのキーボードフォーカスを取り戻すための
  /// コールバック。 _MindMapScreenState の `_keyboardFocusNode.requestFocus()`
  /// を呼び出す関数を渡す。
  ///
  /// `UnfocusDisposition.previouslyFocusedChild` だけだとフォーカスが
  /// FocusScope ノード自体に戻る (= KeyboardListener が primaryFocus を
  /// 取り戻せない) ケースがあり、 そうなると Backspace / Del での「選択
  /// ノード削除」 コマンドが画面ルートに届かない。 このコールバックで
  /// 明示的に画面ルートの FocusNode に primary を戻すことで、 セル編集を
  /// 抜けた直後でも Backspace / Del などのショートカットが効くようになる。
  final VoidCallback? onRequestScreenFocus;
  final VoidCallback? onInlineEditingStarted;
  final VoidCallback? onInlineEditingEnded;

  const _NodeTableInlineWidget({
    required this.table,
    required this.onChanged,
    required this.maxWidth,
    required this.fontSize,
    required this.provider,
    this.textColor = Colors.white,
    this.nodeId,
    this.isLightBg = false,
    this.onNodeSelectTap,
    this.onRequestScreenFocus,
    this.onInlineEditingStarted,
    this.onInlineEditingEnded,
  });

  @override
  State<_NodeTableInlineWidget> createState() => _NodeTableInlineWidgetState();
}

class _NodeTableInlineWidgetState extends State<_NodeTableInlineWidget> {
  /// 編集中のセル位置 (row, col)。 null = 編集していない。
  (int, int)? _editing;
  TextEditingController? _ctrl;
  FocusNode? _focus;

  @override
  void dispose() {
    final wasEditing = _editing != null;
    _ctrl?.dispose();
    _focus?.dispose();
    if (wasEditing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onInlineEditingEnded?.call();
      });
    }
    super.dispose();
  }

  void _startEdit(int row, int col) {
    _commitEditing();
    widget.onInlineEditingStarted?.call();
    final focus = FocusNode();
    // フォーカスを失ったら自動コミット (= TextField 外をタップした時)。
    // 別セルへ移動する場合は _startEdit が先に _commitEditing するので
    // 二重コミットにはならない。
    focus.addListener(() {
      if (!focus.hasFocus && _editing != null && _focus == focus) {
        _endEdit(commit: true);
      }
    });
    setState(() {
      _editing = (row, col);
      _ctrl = TextEditingController(text: widget.table.cellAt(row, col));
      _focus = focus;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus?.requestFocus();
      _ctrl?.selection =
          TextSelection(baseOffset: 0, extentOffset: _ctrl?.text.length ?? 0);
    });
  }

  bool _commitEditing() {
    final e = _editing;
    if (e == null || _ctrl == null) return false;
    final r = e.$1;
    final c = e.$2;
    final newText = _ctrl!.text;
    final oldText = widget.table.cellAt(r, c);
    if (newText == oldText) return false;
    widget.table.setCell(r, c, newText);
    widget.onChanged(widget.table);
    return true;
  }

  void _endEdit({bool commit = true}) {
    if (commit) _commitEditing();
    // ── ★ ショートカット不具合の修正 ★ ──
    // TextField が FocusNode を握ったまま dispose すると、 画面ルートの
    // KeyboardListener / Focus が「以前は自分にフォーカスがあった」 状態
    // から復帰せず、 Ctrl+Shift+N や Space などのグローバルショートカット
    // が効かなくなる (ユーザー報告の不具合)。
    //
    // 対策: primaryFocus が自分の FocusNode の場合に限り、
    // UnfocusDisposition.previouslyFocusedChild を指定して unfocus する。
    // これで「自分にフォーカスが来る直前にフォーカスがあったノード」 へ
    // フォーカスが戻り、 画面ルートの KeyboardListener が再び反応する。
    //
    // primaryFocus が別の場所 (他ノードの TextField 等) に既に移っている
    // 場合は触らない — そちらの編集状態を壊さないため。
    if (mounted && _focus != null) {
      final fm = FocusManager.instance;
      if (fm.primaryFocus == _focus) {
        fm.primaryFocus!.unfocus(
          disposition: UnfocusDisposition.previouslyFocusedChild,
        );
      }
    }
    _ctrl?.dispose();
    _focus?.dispose();
    if (!mounted) return;
    setState(() {
      _editing = null;
      _ctrl = null;
      _focus = null;
    });
    // ── 画面ルートに primary focus を確実に戻す ──
    // previouslyFocusedChild だけでは KeyboardListener が primary を取り
    // 戻せないケースがあり、 そうなると Backspace / Del などのショート
    // カットが効かなくなる (ユーザー報告: 「ノードをクリックして
    // backspace や del で削除できなくなった」)。 画面側の callback で
    // _keyboardFocusNode.requestFocus() を明示呼び出しすることで解決。
    //
    // setState の後、 次フレームで呼ぶ (= 現在の焦点遷移が落ち着いてから
    // 取り戻す)。 そうしないと dispose 中の FocusNode に対する競合で
    // assertion が走る恐れがある。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onInlineEditingEnded?.call();
        widget.onRequestScreenFocus?.call();
      }
    });
  }

  /// 次のセルへ移動。 末尾セル + dx=+1 で `addRowIfNeeded` なら行追加。
  void _moveTo(int dx, int dy, {bool addRowIfNeeded = false}) {
    final e = _editing;
    if (e == null) return;
    final t = widget.table;
    int r = e.$1 + dy;
    int c = e.$2 + dx;
    _commitEditing();

    if (c >= t.colCount) {
      c = 0;
      r += 1;
    } else if (c < 0) {
      c = t.colCount - 1;
      r -= 1;
    }
    if (r >= t.rowCount) {
      if (addRowIfNeeded) {
        t.insertRow(t.rowCount);
        widget.onChanged(t);
        r = t.rowCount - 1;
      } else {
        r = t.rowCount - 1;
        c = t.colCount - 1;
      }
    }
    if (r < 0) {
      r = 0;
      c = 0;
    }

    _ctrl?.dispose();
    _focus?.dispose();
    final focus = FocusNode();
    focus.addListener(() {
      if (!focus.hasFocus && _editing != null && _focus == focus) {
        _endEdit(commit: true);
      }
    });
    setState(() {
      _editing = (r, c);
      _ctrl = TextEditingController(text: t.cellAt(r, c));
      _focus = focus;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus?.requestFocus();
      _ctrl?.selection =
          TextSelection(baseOffset: 0, extentOffset: _ctrl?.text.length ?? 0);
    });
  }

  Future<void> _showContextMenu(
      BuildContext ctx, Offset globalPos, int row, int col) async {
    final p = widget.provider;
    final selected = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromLTRB(
          globalPos.dx, globalPos.dy, globalPos.dx + 1, globalPos.dy + 1),
      items: [
        PopupMenuItem(
            value: 'insertRowAbove',
            child: Text(p.t('tableMenu.insertRowAbove'))),
        PopupMenuItem(
            value: 'insertRowBelow',
            child: Text(p.t('tableMenu.insertRowBelow'))),
        const PopupMenuDivider(),
        PopupMenuItem(
            value: 'insertColLeft',
            child: Text(p.t('tableMenu.insertColLeft'))),
        PopupMenuItem(
            value: 'insertColRight',
            child: Text(p.t('tableMenu.insertColRight'))),
        const PopupMenuDivider(),
        PopupMenuItem(
            value: 'removeRow', child: Text(p.t('tableMenu.removeRow'))),
        PopupMenuItem(
            value: 'removeCol', child: Text(p.t('tableMenu.removeCol'))),
        const PopupMenuDivider(),
        // ── サイズ変更 ──
        // この列の幅 / この行の高さを個別に変更するダイアログを開く。
        // 入力単位は px。 列幅は 40〜400、 行高さは 20〜200 の範囲でクランプ。
        PopupMenuItem(
            value: 'setColWidth', child: Text(p.t('tableMenu.setColWidth'))),
        PopupMenuItem(
            value: 'setRowHeight', child: Text(p.t('tableMenu.setRowHeight'))),
        // すべての列幅 / 行高さを一括でデフォルト値に戻す + デフォルト値自体を変更。
        PopupMenuItem(
            value: 'resetAllColWidths',
            child: Text(p.t('tableMenu.resetAllColWidths'))),
        PopupMenuItem(
            value: 'resetAllRowHeights',
            child: Text(p.t('tableMenu.resetAllRowHeights'))),
        const PopupMenuDivider(),
        PopupMenuItem(
            value: 'toggleHeaderRow',
            child: Text(p.t('tableMenu.toggleHeaderRow'))),
        PopupMenuItem(
            value: 'toggleHeaderCol',
            child: Text(p.t('tableMenu.toggleHeaderCol'))),
      ],
    );
    if (selected == null) return;
    final t = widget.table;
    final nid = widget.nodeId;
    switch (selected) {
      case 'insertRowAbove':
        t.insertRow(row);
        widget.onChanged(t);
        break;
      case 'insertRowBelow':
        t.insertRow(row + 1);
        widget.onChanged(t);
        break;
      case 'insertColLeft':
        t.insertColumn(col);
        widget.onChanged(t);
        break;
      case 'insertColRight':
        t.insertColumn(col + 1);
        widget.onChanged(t);
        break;
      case 'removeRow':
        t.removeRow(row);
        widget.onChanged(t);
        break;
      case 'removeCol':
        t.removeColumn(col);
        widget.onChanged(t);
        break;
      case 'toggleHeaderRow':
        t.headerRow = !t.headerRow;
        widget.onChanged(t);
        break;
      case 'toggleHeaderCol':
        t.headerCol = !t.headerCol;
        widget.onChanged(t);
        break;
      case 'setColWidth':
        if (nid != null) {
          final cur = t.colWidthAt(col);
          final v = await _askNumericDialog(
            ctx,
            title: p.t('tableMenu.setColWidth'),
            label: p.t('tableSize.colWidthLabel'),
            initial: cur,
            min: 40,
            max: 400,
          );
          if (v != null) {
            p.setTableColumnWidth(nid, col, v);
          }
        }
        break;
      case 'setRowHeight':
        if (nid != null) {
          final cur = t.rowHeightAt(row);
          final v = await _askNumericDialog(
            ctx,
            title: p.t('tableMenu.setRowHeight'),
            label: p.t('tableSize.rowHeightLabel'),
            initial: cur,
            min: 20,
            max: 200,
          );
          if (v != null) {
            p.setTableRowHeight(nid, row, v);
          }
        }
        break;
      case 'resetAllColWidths':
        if (nid != null) {
          final v = await _askNumericDialog(
            ctx,
            title: p.t('tableMenu.resetAllColWidths'),
            label: p.t('tableSize.colWidthLabel'),
            initial: t.defaultColWidth,
            min: 40,
            max: 400,
          );
          if (v != null) {
            p.resetTableColumnWidths(nid, newDefault: v);
          }
        }
        break;
      case 'resetAllRowHeights':
        if (nid != null) {
          final v = await _askNumericDialog(
            ctx,
            title: p.t('tableMenu.resetAllRowHeights'),
            label: p.t('tableSize.rowHeightLabel'),
            initial: t.defaultRowHeight,
            min: 20,
            max: 200,
          );
          if (v != null) {
            p.resetTableRowHeights(nid, newDefault: v);
          }
        }
        break;
    }
    _endEdit(commit: false);
  }

  /// サイズ変更用の小さな数値入力ダイアログ。
  ///
  /// `initial` を初期値とし、 [min] 〜 [max] の範囲にクランプ。
  /// キャンセル時は null、 OK 時はクランプ後の値を返す。
  Future<double?> _askNumericDialog(
    BuildContext ctx, {
    required String title,
    required String label,
    required double initial,
    required double min,
    required double max,
  }) async {
    final p = widget.provider;
    final controller = TextEditingController(text: initial.round().toString());
    final isDark = !widget.isLightBg; // ノード背景輝度を基に推測
    final bg = isDark ? const Color(0xFF2A2A35) : const Color(0xFFFAFAFA);
    final fg = isDark ? Colors.white : const Color(0xFF222222);
    final mutedFg = isDark ? Colors.white70 : const Color(0xFF555555);
    const accent = Color(0xFF6C63FF);

    return showDialog<double>(
      context: ctx,
      barrierDismissible: true,
      builder: (dctx) {
        return Dialog(
          backgroundColor: bg,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: fg,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: TextStyle(color: fg, fontSize: 15),
                    decoration: InputDecoration(
                      labelText: '$label (${min.round()}–${max.round()})',
                      labelStyle: TextStyle(color: mutedFg, fontSize: 12),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: mutedFg.withValues(alpha: 0.4)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: accent, width: 1.4),
                      ),
                    ),
                    onSubmitted: (v) {
                      final n = double.tryParse(v.trim());
                      if (n == null) {
                        Navigator.of(dctx).pop();
                      } else {
                        Navigator.of(dctx).pop(n.clamp(min, max));
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(dctx).pop(),
                        child: Text(p.t('tableSize.cancel'),
                            style: TextStyle(color: mutedFg)),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          final n = double.tryParse(controller.text.trim());
                          if (n == null) {
                            Navigator.of(dctx).pop();
                          } else {
                            Navigator.of(dctx).pop(n.clamp(min, max));
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text(p.t('tableSize.ok')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.table;
    // ── 罫線色とセル背景: 背景輝度で自動切替 ──
    // 暗い背景 (デフォルトのノード色は彩度の高い濃色が多い) → 白寄り罫線。
    // 明るい背景 (ライトモード / 淡い色のノード) → 黒寄り罫線。
    // これで「グレー罫線が背景に溶けて見えない」 問題を解消する。
    // ユーザー要望: 「枠線を白や黒で分かり易くして」。
    final Color borderColor = widget.isLightBg
        ? const Color(0xCC000000)
        : const Color(0xE6FFFFFF); // ほぼ不透明な白
    // セル背景: 透明度を上げて罫線とのコントラストを稼ぐ。
    // 暗い背景の上では白寄り、 明るい背景の上では黒寄り (淡く)。
    final Color cellBg = widget.isLightBg
        ? Colors.black.withValues(alpha: 0.05)
        : Colors.white.withValues(alpha: 0.18);
    final Color headerBg = widget.isLightBg
        ? Colors.black.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.30);

    final tableBody = SizedBox(
      // 表全体の幅は ノード幅 (maxWidth) にぴったり合わせる。
      // _buildCell 側でセル幅 = (maxWidth - 罫線分) / colCount を計算するので、
      // colCount × cellW + (colCount+1) × 1.5 = maxWidth ぴったりとなる。
      // colWidths[] オーバーライドや totalWidth の値はここでは見ない (等分割
      // 優先のため)。
      width: widget.maxWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: List.generate(t.rowCount, (r) {
          // ── 行ごとに IntrinsicHeight でラップ ──
          // 行内の各セルが内容に応じて縦に伸びるが、 IntrinsicHeight +
          // CrossAxisAlignment.stretch により行内の全セルが同じ高さ
          // (= 行内の最大セル高さ) に揃う。 ユーザー要望「セルに入りきら
          // ない場合は全部入り切るようにセルを縦に伸ばす」 に対応。
          // IntrinsicHeight は子の自然な高さを計算するため、 大きな表で
          // は描画コストが線形に増える。 通常用途 (〜20 行) では問題なし。
          return IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: List.generate(t.colCount, (c) {
                return _buildCell(r, c, borderColor, cellBg, headerBg);
              }),
            ),
          );
        }),
      ),
    );

    // 表本体の幅 = ノード幅。 maxWidth より大きい列数を持つ表が出る場面は
    // 現状ないが、 安全のため SingleChildScrollView は残す (将来 minCellWidth
    // 制限を導入した時に横スクロールできる)。
    return SizedBox(
      width: widget.maxWidth,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: tableBody,
      ),
    );
  }

  Widget _buildCell(
      int r, int c, Color borderColor, Color cellBg, Color headerBg) {
    final t = widget.table;
    // ── セルサイズ: 常に等分割 ──
    // ・幅: ノード幅 (widget.maxWidth) を列数で割る。 罫線分 (各列の左右
    //   それぞれ 1.5px) を引いてから割ることで、 表全体の描画幅がぴったり
    //   maxWidth に収まる。
    // ・高さ: defaultRowHeight を一律使用。
    // 個別の colWidths[i] / rowHeights[i] オーバーライドは無視 (= 旧仕様で
    // 残っていても等分割を優先)。 ユーザー要望「大きさを変えても各セルの
    // 縦幅横幅が均等割り当てされるように」 に対応。
    const double bw = 1.5; // 罫線太さ (固定)
    final double availableW =
        (widget.maxWidth - (t.colCount + 1) * bw).clamp(0.0, double.infinity);
    final double w =
        t.colCount > 0 ? (availableW / t.colCount).clamp(40.0, 1000.0) : 40.0;
    final double h = t.defaultRowHeight;
    final isEditing =
        _editing != null && _editing!.$1 == r && _editing!.$2 == c;
    final isHeader = (t.headerRow && r == 0) || (t.headerCol && c == 0);
    final bg = isHeader ? headerBg : cellBg;
    final textStyle = TextStyle(
      color: widget.textColor,
      fontSize: widget.fontSize,
      fontWeight: isHeader ? FontWeight.w700 : FontWeight.w400,
    );

    Widget content;
    if (isEditing) {
      final editor = Focus(
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          final isShift = HardwareKeyboard.instance.isShiftPressed;
          if (key == LogicalKeyboardKey.tab) {
            final isLast = (r == t.rowCount - 1) && (c == t.colCount - 1);
            _moveTo(isShift ? -1 : 1, 0, addRowIfNeeded: !isShift && isLast);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.enter) {
            if (isShift) return KeyEventResult.ignored; // Shift+Enter で改行
            _moveTo(0, 1);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.escape) {
            _endEdit(commit: false);
            return KeyEventResult.handled;
          }
          // ── Backspace / Delete を画面ルートに伝播させない ──
          // セルが空文字の時 TextField/EditableText は Backspace を
          // 「何もすることがない」 と判断して `ignored` を返す。 そのまま
          // バブルアップすると画面ルートのキーハンドラに到達し、 「選択
          // ノード削除」 コマンドが発火 → 表ノードが丸ごと消える、 という
          // 致命的バグになる (ユーザー報告: 「セルの入力がアクティブに
          // なっている状態で backspace や del で表全体が消えるのはおかしい」)。
          //
          // 対策: セル編集中はこれらのキーを Focus 層で必ず handled として
          // 消費し、 画面ルートへの伝播を完全に止める。 TextField 自身が
          // 文字削除する場合は、 そちらの handled が先に走るためここに
          // は来ない (Focus.onKeyEvent は子が消費し損ねた残りを拾う仕様)。
          if (key == LogicalKeyboardKey.backspace ||
              key == LogicalKeyboardKey.delete) {
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: TextField(
          controller: _ctrl,
          focusNode: _focus,
          autofocus: true,
          maxLines: null,
          minLines: 1,
          style: textStyle,
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          ),
          onSubmitted: (_) => _endEdit(commit: true),
          onEditingComplete: () => _endEdit(commit: true),
        ),
      );
      content = Stack(
        clipBehavior: Clip.none,
        children: [
          editor,
          Positioned(
            top: -30,
            right: 4,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (_) => _endEdit(commit: true),
              child: Material(
                color: const Color(0xFF43B97F),
                elevation: 6,
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.check_rounded,
                        color: Colors.white, size: 14),
                    const SizedBox(width: 3),
                    Text(context.read<MindMapProvider>().t('paint.confirm'),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      content = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            t.cellAt(r, c),
            maxLines: null,
            softWrap: true,
            overflow: TextOverflow.clip,
            style: textStyle,
          ),
        ),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // セル編集を開始する前にノード選択も発火させる。
        // これにより、 編集中 (Backspace でセル内テキスト削除) → Esc で
        // 抜けた直後でも「ノードが選択された状態」 が残り、 もう一度
        // Backspace を押すとノードを削除できる。
        widget.onNodeSelectTap?.call();
        _startEdit(r, c);
      },
      onSecondaryTapDown: (d) =>
          _showContextMenu(context, d.globalPosition, r, c),
      onLongPressStart: (d) =>
          _showContextMenu(context, d.globalPosition, r, c),
      child: Container(
        width: w,
        // 固定 height ではなく minHeight にすることで、 セル内容 (TextField や
        // 折り返した Text) が縦に伸びる。 行内の全セルは IntrinsicHeight +
        // CrossAxisAlignment.stretch によって最大高さに揃う。
        // ユーザー要望「セルを縦に伸ばせるようにして」 に対応。
        constraints: BoxConstraints(minHeight: h),
        decoration: BoxDecoration(
          color: bg,
          // 罫線太さは固定 1.5px (TableData.borderWidth より優先)。
          // ユーザー要望「枠線を白や黒で分かり易く」 に応えるため、
          // 細すぎず・太すぎずの幅にして視認性を確保する。
          border: Border(
            top: BorderSide(color: borderColor, width: 1.5),
            left: BorderSide(color: borderColor, width: 1.5),
            right: (c == t.colCount - 1)
                ? BorderSide(color: borderColor, width: 1.5)
                : BorderSide.none,
            bottom: (r == t.rowCount - 1)
                ? BorderSide(color: borderColor, width: 1.5)
                : BorderSide.none,
          ),
        ),
        child: content,
      ),
    );
  }
}

/// pptx の 1 枚目をサムネイルに縮小して描く (= ユーザー要望:
/// 文字の配置まで 1 枚目と同じに)。
class _SlideThumbPainter extends CustomPainter {
  final SlidePreview slide;
  const _SlideThumbPainter(this.slide);

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / slide.width;
    final sy = size.height / slide.height;
    // 下地。
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..color = slide.bg != null
              ? Color(0xFF000000 | slide.bg!)
              : Colors.white);
    for (final b in slide.boxes) {
      final rect =
          Rect.fromLTWH(b.x * sx, b.y * sy, b.w * sx, b.h * sy);
      if (rect.width <= 0 || rect.height <= 0) continue;
      // 文字が無い枠は塗りの図形 (帯やブロック) として描く。
      if (b.text == null || b.text!.isEmpty) {
        if (b.fill != null) {
          canvas.drawRect(rect, Paint()..color = Color(0xFF000000 | b.fill!));
        }
        continue;
      }
      // 文字。 スライド上の文字サイズを、 そのまま縮尺に掛ける。
      final ptSize = (b.sizeHundredths ?? 1800) / 100.0;
      // 1pt = 12700 EMU。 スライド幅に対する比で縮める。
      final px = math.max(3.0, ptSize * 12700 * sx);
      final tp = TextPainter(
        text: TextSpan(
          text: b.text,
          style: TextStyle(
            color: b.color != null
                ? Color(0xFF000000 | b.color!)
                : (slide.bg != null && _isDark(slide.bg!)
                    ? Colors.white
                    : const Color(0xFF212121)),
            fontSize: px,
            height: 1.2,
            fontWeight: px > 9 ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 6,
        ellipsis: '…',
      )..layout(maxWidth: math.max(4.0, rect.width));
      tp.paint(canvas, Offset(rect.left, rect.top));
    }
  }

  static bool _isDark(int rgb) {
    final r = (rgb >> 16) & 0xFF;
    final g = (rgb >> 8) & 0xFF;
    final b = rgb & 0xFF;
    return (0.299 * r + 0.587 * g + 0.114 * b) < 128;
  }

  @override
  bool shouldRepaint(covariant _SlideThumbPainter old) =>
      !identical(old.slide, slide);
}
