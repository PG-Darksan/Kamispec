// lib/widgets/google_search_dialog.dart
//
// Google 検索 + メモ取り 統合 UI (複数メモ対応)。
//
// ## レイアウト
// AppBar: 検索バー + 検索ボタン + 閉じる
// 本体: 左 = WebView (Google検索結果) / 右 = メモパネル
//   メモパネルの構成 (上から):
//     1. 入力欄 ヘッダー (「編集中…」 / 「新規メモ」 の表示 + ✕キャンセル)
//     2. 入力 TextField (1行目=タイトル / 2行目以降=本文)
//     3. URL包含チェック
//     4. アクションボタン: [💾保存] [➕マップに追加]
//     5. 仕切り線
//     6. 「保存済みメモ」 見出し
//     7. 保存メモのリスト (各メモにアクションボタン)
//
// モバイル縦画面では WebView 上 / メモパネル下 の縦並びに切り替え。
//
// ## メモのライフサイクル
// - 新規入力 → 「保存」 で `GoogleSearchMemo` としてリストに追加
// - リストの「編集」 → そのメモを入力欄にロード (= 編集モード)
// - 「マップに追加」 (入力欄側) → 現在入力中の内容をノードに変換
//   - 編集モード時はリストからも削除 (= ノードに「昇格」 した扱い)
// - リスト内「マップに追加」 → そのメモ単体をノード化 + リスト削除
// - リスト内「削除」 → 確認なしでリストから除去 (Ctrl+Z で復元)
//
// ## ドラフト保存
// 入力欄の内容は 600ms debounce で SharedPreferences に下書き保存される。
// ダイアログを×で閉じても残り、 次回開いた時に復元される。
// 「保存」 で正規メモになった時点でドラフトはクリア。
//
// ## ノードからの検索 (🔍ボタン経由)
// `initialMemo` が指定された場合は単発編集モード扱い。 ドラフト機能・
// 保存済みメモリストはすべて非表示にし、 そのメモ 1 つを編集する UI に
// なる。 「マップに追加」 で完了。

import 'dart:async';
import 'dart:convert' show jsonEncode, jsonDecode;
import 'dart:io' show Platform, File;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;
import 'package:webview_windows/webview_windows.dart' as wv_win;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// 自動スクショ → PDF 化 (= ユーザー要望) に使用。
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;

import '../providers/mind_map_provider.dart';

/// 旧 API 互換のエントリポイント。 `_openGoogleSearchDialog` から呼ばれる。
class GoogleSearchDialog {
  static Future<void> show(
    BuildContext context, {
    String initialQuery = '',
    String initialMemo = '',
    String? customTitle,

    /// 初期表示する URL。 指定した場合は initialQuery より優先され、
    /// その URL を WebView でロードする。 Qiita 等を直接開く用途で使用。
    String? initialUrl,
    // ignore: avoid_unused_constructor_parameters
    void Function(String url)? onOpenWeb,
    required void Function(String title, String memo, String? linkUrl)
        onAddNode,

    /// 「画面分割で開く」 ボタン押下時、 現在の URL を引数として呼ばれる。
    /// `isLeftPanel: true` で左画面分割、 false (デフォルト) で右画面分割。
    /// null の場合はボタン非表示。
    void Function(String currentUrl, {bool isLeftPanel})? onMoveToSplitPanel,

    /// ★ ボタン押下時に呼ばれる動的ブックマークボタン作成コールバック。
    /// 戻り値: 作成成功なら true、 キャンセル / 失敗なら false。
    /// 未設定 (= null) の場合は従来通り SharedPreferences に直接追加。
    Future<bool> Function(String url, String title)? onCreateBookmarkButton,

    /// コンパクトモード = 画面いっぱいではなく、 中央に小さなダイアログとして
    /// 表示する。 ユーザー要望「ノードから検索を押して立ち上がる google 検索は
    /// 全画面ではなく、 メモから立ち上がる google 検索の様な小さなものにして
    /// 欲しい」 への対応。 「画面分割に切り替え」 ボタンも有効になる。
    bool compactMode = false,

    /// ミニマルモード = メモ欄なしの「縦長の小さな検索画面」 (= スマホ風の
    /// ポップアップ)。
    ///
    /// ユーザー要望「ノードをタップして出てくる検索ボタンを押したらメモ欄
    ///   なしの小さな縦長の検索画面が出てくるようにして、 で、 全画面表示を
    ///   押したら今の様なメモ欄アリの画面が出てくるようにして」 への対応。
    ///
    /// minimalMode が有効な時:
    ///   - メモ欄を非表示
    ///   - ダイアログサイズを縦長の小さなサイズに固定
    ///   - ヘッダーに「全画面表示」 ボタンを表示 (= 押すと compactMode で
    ///     開き直し、 現在の URL / クエリを引き継ぐ)
    bool minimalMode = false,
  }) async {
    if (minimalMode) {
      // ミニマル = メモ欄なし、 縦長の小さなダイアログ (= スマホ画面風)。
      // 中身は同じ _GoogleSearchPage を使うが、 サイズと minimalMode フラグ
      // で UI を調整。
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.6),
        builder: (dctx) {
          final size = MediaQuery.of(dctx).size;
          // 縦長サイズ: 横 360px、 縦は画面の 80% (最大 700px)
          final dialogW = math.min(360.0, size.width * 0.9);
          final dialogH = math.min(size.height * 0.85, 700.0);
          return Dialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            backgroundColor: Colors.transparent,
            alignment: Alignment.center,
            child: SizedBox(
              width: dialogW,
              height: dialogH,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: _GoogleSearchPage(
                  initialQuery: initialQuery,
                  initialMemo: initialMemo,
                  customTitle: customTitle,
                  initialUrl: initialUrl,
                  onAddNode: onAddNode,
                  onMoveToSplitPanel: onMoveToSplitPanel,
                  onCreateBookmarkButton: onCreateBookmarkButton,
                  compactMode: true,
                  minimalMode: true,
                  // 「全画面表示」 ボタン押下時のコールバック (= minimalMode を
                  // 抜けて compactMode で開き直す)
                  onExpandToCompact: (currentUrl, currentQuery, currentMemo) {
                    Navigator.of(dctx).pop();
                    // 新たに compactMode で開く。 同じ context を使うため
                    // ボタン押下後の async gap で context が無効化される
                    // ことはない (= showDialog の親 context は維持される)。
                    Future.microtask(() {
                      show(
                        context,
                        initialQuery: currentQuery,
                        initialMemo: currentMemo,
                        customTitle: customTitle,
                        initialUrl: currentUrl,
                        onAddNode: onAddNode,
                        onMoveToSplitPanel: onMoveToSplitPanel,
                        onCreateBookmarkButton: onCreateBookmarkButton,
                        compactMode: true,
                      );
                    });
                  },
                ),
              ),
            ),
          );
        },
      );
      return;
    }
    if (compactMode) {
      // コンパクト = showDialog ベース。 画面サイズの 80% 程度の Dialog。
      // 中身は同じ _GoogleSearchPage を使うが、 Scaffold ではなく Material
      // で包んで Dialog 内に納める。
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.6),
        builder: (dctx) {
          final size = MediaQuery.of(dctx).size;
          return Dialog(
            insetPadding: EdgeInsets.symmetric(
              horizontal: size.width * 0.05,
              vertical: size.height * 0.05,
            ),
            backgroundColor: Colors.transparent,
            child: SizedBox(
              width: size.width * 0.9,
              height: size.height * 0.9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _GoogleSearchPage(
                  initialQuery: initialQuery,
                  initialMemo: initialMemo,
                  customTitle: customTitle,
                  initialUrl: initialUrl,
                  onAddNode: onAddNode,
                  onMoveToSplitPanel: onMoveToSplitPanel,
                  onCreateBookmarkButton: onCreateBookmarkButton,
                  compactMode: true,
                ),
              ),
            ),
          );
        },
      );
      return;
    }
    // ── 真の全画面表示 ──
    // ユーザー要望「google 検索画面は中途半端な全画面表示ではなく、 ちゃんと
    //   した全画面表示で開かれるようにして」 への対応。
    //
    // 旧: `MaterialPageRoute(fullscreenDialog: true)` で開いていた。 これは
    //   iOS 風の「下からスライドアップするモーダル」 として表示され、
    //   ステータスバー領域に薄い余白が残る、 画面の角に丸みが残る等、
    //   「完全な全画面」 ではない見た目になっていた。
    // 新: `PageRouteBuilder(opaque: true)` で、 ステータスバーまで完全に覆う
    //   通常ページ遷移として表示。 フェードイン (200ms) に切替えて、
    //   PowerPoint 等の他フルスクリーン UI と統一感を持たせる。
    await Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: true,
        barrierDismissible: false,
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (_, __, ___) => _GoogleSearchPage(
          initialQuery: initialQuery,
          initialMemo: initialMemo,
          customTitle: customTitle,
          initialUrl: initialUrl,
          onAddNode: onAddNode,
          onMoveToSplitPanel: onMoveToSplitPanel,
          onCreateBookmarkButton: onCreateBookmarkButton,
        ),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  /// 現在表示中のフローティング検索ウィンドウ群 (= 複数同時に開ける)。
  /// ユーザー要望: 「ノードをタップしての google 検索は複数同時に検索ボックスを
  ///   起動できるように」。 以前は 1 つだけだったがリストで複数管理する。
  static final List<OverlayEntry> _floatingEntries = <OverlayEntry>[];

  /// ── フローティング (非モーダル + ドラッグ可能) 検索ウィンドウ ──
  ///
  /// ユーザー要望「ノードから検索ボックスを開く際はドラッグで自由に検索
  ///   ボックスを移動させれるようにして欲しいのと、 検索ボックスを立ち上げ
  ///   ながらマップの編集やら別の作業もできるようにして」 への対応。
  ///
  /// showDialog はモーダル (背後をブロック) なので、 OverlayEntry で
  ///   バリア無しの浮遊ウィンドウとして表示する。 これにより検索ウィンドウを
  ///   開いたままマップの操作 / 編集ができる。 ヘッダーをドラッグで移動可能。
  static void showFloating(
    BuildContext context, {
    String initialQuery = '',
    String initialMemo = '',
    String? customTitle,
    String? initialUrl,
    required void Function(String title, String memo, String? linkUrl)
        onAddNode,
    void Function(String currentUrl, {bool isLeftPanel})? onMoveToSplitPanel,
    Future<bool> Function(String url, String title)? onCreateBookmarkButton,
    Offset? anchorPos,
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    // 既に開いている数に応じて少しずつズラして配置 (= 重ならないように)。
    final int stackIndex = _floatingEntries.length;
    final Offset cascade = Offset(
      (stackIndex % 6) * 26.0,
      (stackIndex % 6) * 26.0,
    );
    late OverlayEntry entry;
    void closeEntry() {
      if (_floatingEntries.contains(entry)) {
        entry.remove();
        _floatingEntries.remove(entry);
      }
    }

    entry = OverlayEntry(
      builder: (ctx) => _FloatingSearchWindow(
        initialQuery: initialQuery,
        initialMemo: initialMemo,
        customTitle: customTitle,
        initialUrl: initialUrl,
        initialOffset: cascade,
        anchorPos: anchorPos,
        onAddNode: onAddNode,
        onMoveToSplitPanel: onMoveToSplitPanel,
        onCreateBookmarkButton: onCreateBookmarkButton,
        onClose: closeEntry,
        // 「全画面表示」 → このフローティングを閉じて compactMode で開き直す
        onExpandToCompact: (url, query, memo) {
          closeEntry();
          Future.microtask(() {
            show(
              context,
              initialQuery: query,
              initialMemo: memo,
              customTitle: customTitle,
              initialUrl: url,
              onAddNode: onAddNode,
              onMoveToSplitPanel: onMoveToSplitPanel,
              onCreateBookmarkButton: onCreateBookmarkButton,
              compactMode: true,
            );
          });
        },
      ),
    );
    _floatingEntries.add(entry);
    overlay.insert(entry);
  }
}

/// ドラッグ可能な非モーダルの浮遊検索ウィンドウ。
/// Overlay に挿入され、 ウィンドウ矩形の外側はイベントを透過する
/// (= 下のマップがそのまま操作できる)。
class _FloatingSearchWindow extends StatefulWidget {
  final String initialQuery;
  final String initialMemo;
  final String? customTitle;
  final String? initialUrl;
  final void Function(String title, String memo, String? linkUrl) onAddNode;
  final void Function(String currentUrl, {bool isLeftPanel})?
      onMoveToSplitPanel;
  final Future<bool> Function(String url, String title)? onCreateBookmarkButton;
  final VoidCallback onClose;
  final void Function(
          String currentUrl, String currentQuery, String currentMemo)
      onExpandToCompact;

  /// 複数同時表示時に重ならないようズラす初期オフセット (ユーザー要望)。
  final Offset initialOffset;

  /// 指定があれば、 この画面座標 (= ノード付近) にウィンドウを出す
  /// (= ユーザー要望: ノードからの Google 検索はノード付近に出す)。
  final Offset? anchorPos;
  const _FloatingSearchWindow({
    required this.initialQuery,
    required this.initialMemo,
    required this.customTitle,
    required this.initialUrl,
    required this.onAddNode,
    required this.onMoveToSplitPanel,
    required this.onCreateBookmarkButton,
    required this.onClose,
    required this.onExpandToCompact,
    this.initialOffset = Offset.zero,
    this.anchorPos,
  });

  @override
  State<_FloatingSearchWindow> createState() => _FloatingSearchWindowState();
}

class _FloatingSearchWindowState extends State<_FloatingSearchWindow> {
  Offset _pos = const Offset(-1, -1); // 未配置マーカー
  // 既定サイズ。 横幅はユーザー要望でもう少し広げた (300 → 430)。
  static const double _baseW = 430;
  static const double _baseH = 470;
  // ── ユーザー要望: 境界をドラッグして縦横の大きさを自由に変えられるように ──
  // null = 既定サイズ。 リサイズすると実寸 (px) を保持する。
  double? _userW;
  double? _userH;
  static const double _minW = 240;
  static const double _minH = 260;
  // リサイズ開始時のウィンドウ矩形とポインタ位置 (total-delta 方式で誤差防止)。
  Rect? _resizeStartRect;
  Offset? _resizeStartPointer;

  void _beginResize(Offset globalPointer, double w, double h) {
    _resizeStartRect = Rect.fromLTWH(_pos.dx, _pos.dy, w, h);
    _resizeStartPointer = globalPointer;
  }

  void _updateResize(Offset globalPointer, Size screen,
      {bool left = false,
      bool right = false,
      bool top = false,
      bool bottom = false}) {
    final start = _resizeStartRect;
    final p0 = _resizeStartPointer;
    if (start == null || p0 == null) return;
    final d = globalPointer - p0;
    final maxW = math.max(_minW, screen.width - 8);
    final maxH = math.max(_minH, screen.height - 8);
    double l = start.left, t = start.top, r = start.right, b = start.bottom;
    if (right) r = start.right + d.dx;
    if (left) l = start.left + d.dx;
    if (bottom) b = start.bottom + d.dy;
    if (top) t = start.top + d.dy;
    final double w = (r - l).clamp(_minW, maxW).toDouble();
    final double h = (b - t).clamp(_minH, maxH).toDouble();
    // 反対側の辺を固定したままクランプ (左/上ドラッグ時に右/下端を保つ)
    if (left) l = r - w;
    if (top) t = b - h;
    // 画面内にクランプ
    l = l.clamp(0.0, math.max(0.0, screen.width - w));
    t = t.clamp(0.0, math.max(0.0, screen.height - h));
    setState(() {
      _userW = w;
      _userH = h;
      _pos = Offset(l, t);
    });
  }

  /// 境界 / 隅のリサイズハンドル群。 ヘッダー (上 40px) はドラッグ移動用に
  /// 空けるため、 リサイズは左右辺・下辺・下の両隅で行う。
  List<Widget> _buildResizeHandles(Size screen, double w, double h) {
    Widget handle({
      double? left,
      double? top,
      double? right,
      double? bottom,
      double? width,
      double? height,
      required SystemMouseCursor cursor,
      bool l = false,
      bool r = false,
      bool t = false,
      bool b = false,
    }) {
      return Positioned(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        width: width,
        height: height,
        child: MouseRegion(
          cursor: cursor,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (d) => _beginResize(d.globalPosition, w, h),
            onPanUpdate: (d) => _updateResize(d.globalPosition, screen,
                left: l, right: r, top: t, bottom: b),
            child: const SizedBox.expand(),
          ),
        ),
      );
    }

    const double edge = 8;
    const double corner = 18;
    return [
      handle(
          left: 0,
          top: 44,
          bottom: corner,
          width: edge,
          cursor: SystemMouseCursors.resizeLeftRight,
          l: true),
      handle(
          right: 0,
          top: 44,
          bottom: corner,
          width: edge,
          cursor: SystemMouseCursors.resizeLeftRight,
          r: true),
      handle(
          bottom: 0,
          left: corner,
          right: corner,
          height: edge,
          cursor: SystemMouseCursors.resizeUpDown,
          b: true),
      handle(
          left: 0,
          bottom: 0,
          width: corner,
          height: corner,
          cursor: SystemMouseCursors.resizeDownLeft,
          l: true,
          b: true),
      handle(
          right: 0,
          bottom: 0,
          width: corner,
          height: corner,
          cursor: SystemMouseCursors.resizeDownRight,
          r: true,
          b: true),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MindMapProvider>();
    final screen = MediaQuery.of(context).size;
    final maxW = math.max(_minW, screen.width - 8);
    final maxH = math.max(_minH, screen.height - 8);
    final double w = (_userW ?? math.min(_baseW, screen.width - 16))
        .clamp(_minW, maxW)
        .toDouble();
    final double h = (_userH ?? math.min(_baseH, screen.height - 16))
        .clamp(_minH, maxH)
        .toDouble();
    final maxLeft = math.max(0.0, screen.width - w);
    final maxTop = math.max(0.0, screen.height - h);
    // 初回配置: anchorPos 指定があればノード付近、 無ければ右上寄り
    //   (複数表示時はオフセット分ズラす)。
    if (_pos.dx < 0) {
      if (widget.anchorPos != null) {
        final a = widget.anchorPos!;
        _pos = Offset(
          a.dx.clamp(0.0, maxLeft),
          a.dy.clamp(0.0, maxTop),
        );
      } else {
        _pos = Offset(
          (maxLeft - widget.initialOffset.dx).clamp(0.0, maxLeft),
          math.min(72.0 + widget.initialOffset.dy, maxTop),
        );
      }
    }
    final left = _pos.dx.clamp(0.0, maxLeft);
    final top = _pos.dy.clamp(0.0, maxTop);

    return Positioned(
      left: left,
      top: top,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: const Color(0xFF121212),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: const Color(0xFF4FC3F7).withValues(alpha: 0.45),
                width: 1),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black54, blurRadius: 22, offset: Offset(0, 8)),
            ],
          ),
          child: Stack(fit: StackFit.expand, children: [
            // 本体は Stack いっぱいに広げる (元の Container>Column と同じ
            // tight 制約にして、 リサイズハンドルだけを上に重ねる)。
            Column(
              children: [
                // ── ドラッグ可能なヘッダー ──
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) {
                    setState(() {
                      final np = _pos + d.delta;
                      _pos = Offset(
                        np.dx.clamp(0.0, maxLeft),
                        np.dy.clamp(0.0, maxTop),
                      );
                    });
                  },
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.only(left: 12, right: 4),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1A1A1A),
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(13)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.drag_indicator_rounded,
                            color: Colors.white38, size: 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(provider.t('gsearch.dragTitle'),
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded,
                              color: Colors.white54, size: 18),
                          tooltip: provider.t('btn.close'),
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 32, minHeight: 32),
                          onPressed: widget.onClose,
                        ),
                      ],
                    ),
                  ),
                ),
                // ── 検索本体 ──
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(13)),
                    child: _GoogleSearchPage(
                      initialQuery: widget.initialQuery,
                      initialMemo: widget.initialMemo,
                      customTitle: widget.customTitle,
                      initialUrl: widget.initialUrl,
                      onAddNode: widget.onAddNode,
                      onMoveToSplitPanel: widget.onMoveToSplitPanel,
                      onCreateBookmarkButton: widget.onCreateBookmarkButton,
                      compactMode: true,
                      minimalMode: true,
                      onExpandToCompact: widget.onExpandToCompact,
                      // フローティングは Overlay 上なので Navigator.pop ではなく
                      // onClose で閉じる。
                      onRequestClose: widget.onClose,
                      // ── ユーザー要望: 小さい検索窓のボタンが重なる対策 ──
                      // ウィンドウ幅を渡してツールバーを幅に応じて切り替える。
                      windowWidth: w,
                    ),
                  ),
                ),
              ],
            ),
            // ── リサイズハンドル (境界ドラッグで縦横を変更) ──
            ..._buildResizeHandles(screen, w, h),
          ]),
        ),
      ),
    );
  }
}

class _GoogleSearchPage extends StatefulWidget {
  final String initialQuery;
  final String initialMemo;
  final String? customTitle;

  /// 起動時に直接ロードする URL (= 検索クエリの代わり)。
  final String? initialUrl;
  final void Function(String title, String memo, String? linkUrl) onAddNode;

  /// 「画面分割で開く」 ボタン押下時、 現在の URL を引数として呼ばれる。
  /// `isLeftPanel: true` なら左パネル、 false (デフォルト) なら右パネルへ。
  /// null の場合はボタン非表示。
  final void Function(String currentUrl, {bool isLeftPanel})?
      onMoveToSplitPanel;

  /// ★ ボタン押下時に呼ばれる動的ブックマークボタン作成コールバック。
  /// 戻り値: 作成成功なら true、 キャンセル / 失敗なら false。
  final Future<bool> Function(String url, String title)? onCreateBookmarkButton;

  /// compactMode = true なら fullscreen ではなく小さなダイアログとして表示
  /// される (= GoogleSearchDialog.show で compactMode: true を指定された場合)。
  final bool compactMode;

  /// minimalMode = メモ欄なしの「縦長の小さな検索画面」 (= スマホ風)。
  ///
  /// ユーザー要望「ノードをタップして出てくる検索ボタンを押したらメモ欄
  ///   なしの小さな縦長の検索画面が出てくるようにして、 で、 全画面表示を
  ///   押したら今の様なメモ欄アリの画面が出てくるようにして」 への対応。
  ///
  /// 有効時:
  ///   - メモ欄を完全に非表示
  ///   - 検索バーと WebView だけのシンプル UI
  ///   - ヘッダーに「全画面表示」 ボタンを表示
  final bool minimalMode;

  /// 「全画面表示」 ボタン押下時のコールバック。
  /// 現在の URL / 検索クエリ / メモを引数として渡す。 minimalMode 時のみ
  /// 有効 (= ダイアログ側で受け取って compactMode で開き直す)。
  final void Function(
          String currentUrl, String currentQuery, String currentMemo)?
      onExpandToCompact;

  /// 閉じる要求時のコールバック。
  /// フローティング (非モーダル Overlay) 表示のときに指定する。 指定時は
  /// 各種「閉じる」 操作で Navigator.pop の代わりにこのコールバックを呼ぶ
  /// (= Overlay には pop すべき route が無く、 誤って下の画面を pop して
  /// しまうのを防ぐため)。 null のときは従来通り Navigator.pop で閉じる。
  final VoidCallback? onRequestClose;

  /// フローティング表示時の実ウィンドウ幅。 ツールバーのボタンを幅に応じて
  /// レスポンシブに切り替える (= 小窓でボタンが重なるのを防ぐ) のに使う。
  /// null のときは画面幅 (MediaQuery) を使う。
  final double? windowWidth;

  const _GoogleSearchPage({
    required this.initialQuery,
    required this.initialMemo,
    required this.customTitle,
    this.initialUrl,
    required this.onAddNode,
    this.onMoveToSplitPanel,
    this.onCreateBookmarkButton,
    this.compactMode = false,
    this.minimalMode = false,
    this.onExpandToCompact,
    this.onRequestClose,
    this.windowWidth,
  });

  @override
  State<_GoogleSearchPage> createState() => _GoogleSearchPageState();
}

class _GoogleSearchPageState extends State<_GoogleSearchPage> {
  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// このページを閉じる。 フローティング表示 (onRequestClose 指定時) は
  /// コールバックを呼び、 通常のダイアログ / ルート表示では Navigator.pop。
  void _closeSelf() {
    final cb = widget.onRequestClose;
    if (cb != null) {
      cb();
    } else {
      Navigator.of(context).pop();
    }
  }

  // ── UI 状態 ──
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _memoCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final FocusNode _memoFocus = FocusNode();
  // ── メモリスト専用の Focus ノード ──
  // Backspace/Delete/Ctrl+A/Ctrl+Z は上位 Focus の onKeyEvent で
  // 一元的に処理する方式に変更したため、 専用の `_memoListFocus` は廃止。
  bool _includeUrl = true;
  String _currentUrl = 'https://www.google.com/';
  String _pageTitle = 'Google';

  // ── 複数タブ (= ユーザー要望: Google 検索も複数タブ開けるように) ──
  // 方式A: 1 つの WebView を共有し、切替時にそのタブの URL を読み込み直す。
  late List<_GsTab> _gsTabs;
  int _gsActiveTab = 0;
  static const int _kGsMaxTabs = 15;

  /// アクティブタブの WebView が「戻れる」 履歴を持つか。
  ///
  /// ユーザー要望「google 検索で戻るのジェスチャーをすると検索画面自体が
  ///   閉じてしまう、 そうではなく手前のページに戻るようにして」 への対応。
  ///   PopScope の `canPop` をこの値で切り替え、 戻れるときは WebView の履歴を
  ///   1 つ戻す (= 検索画面は閉じない)。 戻れないとき (履歴の先頭) のみ通常通り
  ///   画面を閉じる。 ナビゲーション毎に `_refreshWebCanGoBack` で更新する。
  bool _webCanGoBack = false;
  // 閉じたタブの履歴 (Ctrl+Shift+T で復元)。 末尾が直近に閉じたタブ。
  final List<_GsTab> _closedGsTabs = [];

  /// 「リンク埋め込み / お気に入りボタン登録」 統合ボタンの現在モード
  /// (= ユーザー要望: 2 機能を 1 ボタンに統合し、PC は右クリック・モバイルは
  ///   長押しで切替)。false=リンク埋め込み / true=お気に入りボタン登録。
  bool _gsSaveAsBookmark = false;
  static const List<(String, String)> _gsSites = [
    ('Google 検索', 'https://www.google.com/'),
    ('YouTube', 'https://www.youtube.com/'),
    ('Instagram', 'https://www.instagram.com/'),
    ('X', 'https://x.com/'),
  ];

  /// メモ欄を展開表示しているかどうか (= ユーザー要望: Ctrl+Shift+F で
  /// 開く検索ボックスのメモ欄は閉じたり開いたりできるように)。
  /// 既定は閉じ (= ユーザー要望: リンクや検索ボタンから Google 検索を開いた
  /// ときは、メモ欄を閉じて表示領域を広く使いたい)。既存メモの編集
  /// (initialMemo あり) で開いたときだけ initState で展開する。
  /// ヘッダーの ▼/▶ トグルで切替。
  bool _memoExpanded = false;

  /// 入力エディタを表示中か (= ユーザー要望: PDF ビューア形式に合わせ、
  /// 普段はエディタを隠し「＋新規メモ」 や編集時だけ出す)。
  bool _memoEditorOpen = false;

  /// 現在編集中のメモ ID。 null = 新規メモ作成中。
  /// `googleSearchMemos` 内の既存メモを編集している場合のみセットされる。
  String? _editingMemoId;

  // ── 保存済みメモの複数選択 (Ctrl+クリック / Shift+クリック) ──
  //
  // 「編集中」 (= _editingMemoId) とは独立した状態。 編集モードで
  // 入力欄に出ているメモが、 同時にリスト内で複数選択にも含まれる
  // ことがあり得る (= 干渉しない設計)。
  //
  // Del / Backspace キー押下時に `_selectedMemoIds` を一括削除対象として
  // 使う。 1 つも選択されていなければ no-op。
  Set<String> _selectedMemoIds = <String>{};
  // Shift+クリックの範囲選択起点。
  String? _lastClickedMemoId;

  // ── 削除取り消し履歴 (Ctrl+Z 用) ──
  //
  // 各エントリは「1 回の削除操作」 のスナップショット (= List<GoogleSearchMemo>)。
  // 単独削除なら 1 要素、 一括削除なら複数要素。 削除直前のメモを丸ごと
  // コピーして積んでおき、 Ctrl+Z で最後のエントリを Provider に restore する。
  //
  // 履歴はダイアログ内でのみ保持 (= 永続化しない)。 ダイアログを閉じれば
  // 履歴は破棄される。 これは「削除取り消し」 がセッション内操作として
  // 自然な範囲であり、 永続化すると古い履歴で混乱しやすいため。
  // 最大件数は 20 (これを超えたら古いものから捨てる)。
  final List<List<GoogleSearchMemo>> _deletionHistory = [];
  static const int _kDeletionHistoryMax = 20;

  // ── メモのドラフト永続化 ──
  Timer? _draftSaveDebounce;
  late final bool _useDraft;

  // ── メモパネル開閉状態 ──
  // デフォルトは閉じた状態 (= Qiita 等のページを読むときに邪魔にならない)。
  // ユーザーがメモを取りたい時はヘッダーバーをタップして展開する。
  bool _memoPanelExpanded = false;

  // ── 縦分割 (= モバイル) でメモ欄を上下どちらに置くか ──
  // ユーザー要望: 「Instagram 等の下にメモ項目が出てくると邪魔な場合がある
  //   から別の場所に移動できるように」。 false = WebView の下 (既定)、
  //   true = WebView の上。 メモ欄ヘッダーの移動ボタンで切り替える。
  bool _memoPanelOnTop = false;

  // ── 横分割 (= デスクトップ / 横長画面) のメモパネルの表示状態 ──
  // ユーザー要望「Ctrl+Shift+F で出す Google 検索のメモ欄を、 閉じて
  //   非表示/表示を切り替えられるように」 への対応。
  // 横分割では従来メモパネルが固定幅 360px で常時表示だったが、 これを
  //   ツールバーのトグルで開閉できるようにした。
  // ── ユーザー要望: Google 検索を立ち上げた時にメモ欄が常に開いて表示領域が
  //    小さくなるのを避けたいので、 デフォルトは false (= 閉じた状態) にする。
  //    開きたいときはツールバーのメモボタン (F3) で開ける。
  // ※ 縦分割 (モバイル) は _memoPanelExpanded + _buildCollapsibleMemoPanel
  //   が同等の開閉を担うため、 こちらは横分割専用。
  bool _memoSideExpanded = false;

  // ── WebView コントローラ (タブごとに保持) ──
  // 検索用 WebView はタブごとに別インスタンスを持ち、 切替で再読み込みしない。
  // 以下は「アクティブタブ」 のコントローラ/状態を返すゲッターで、 既存の
  //   参照箇所をそのまま使えるようにしている。
  _GsTab? get _activeTab => (_gsActiveTab >= 0 && _gsActiveTab < _gsTabs.length)
      ? _gsTabs[_gsActiveTab]
      : null;
  wv_win.WebviewController? get _winCtrl => _activeTab?.winCtrl;
  bool get _winInitialized => _activeTab?.winReady ?? false;
  String? get _winInitError => _activeTab?.winError;
  iaw.InAppWebViewController? get _iawCtrl => _activeTab?.iawCtrl;

  // ── 生成 AI サイドパネル (= ユーザー要望: PDF ビューアと同様に 5 種の AI を
  //    サイドメニューで開いて、 メモを渡したり左右入れ替えたりできるように) ──
  /// AI チャット欄を開いているか。
  bool _aiPanelOpen = false;

  /// 開いている AI の URL (= ChatGPT 等)。 空なら未選択。
  String _aiPanelUrl = '';

  /// 直近に開いた AI の id (= メモを送るときの既定)。
  String _aiDefaultId = 'chatgpt';

  /// Google 検索内の埋め込み動画の再生速度 (= ユーザー要望)。
  double _searchVideoRate = 1.0;

  /// メモを AI 入力欄に渡すときの送信通し番号 (= 二重挿入防止トークン)。
  int _aiInjectSeq = 0;

  /// メモ欄と AI 欄の左右位置を入れ替えているか (横分割時のみ意味を持つ)。
  bool _panelsSwapped = false;

  /// AI 欄用 Windows WebView コントローラ (検索用 _winCtrl とは独立)。
  final wv_win.WebviewController _aiWinCtrl = wv_win.WebviewController();
  bool _aiWinInitStarted = false;
  bool _aiWinInitialized = false;
  String? _aiWinInitError;

  /// AI 欄用モバイル InAppWebView コントローラ (= JS 注入用)。
  iaw.InAppWebViewController? _aiIawCtrl;

  /// 5 種の AI とその URL。 PDF ビューアの AI パネルと同一。
  static const Map<String, String> _aiUrls = <String, String>{
    'chatgpt': 'https://chatgpt.com/',
    'gemini': 'https://gemini.google.com/app',
    'claude': 'https://claude.ai/',
    'deepseek': 'https://chat.deepseek.com/',
    'grok': 'https://grok.com/',
  };

  /// AI 選択用ポップアップメニュー項目 (5 種類)。
  List<PopupMenuItem<String>> _aiMenuItems() => const [
        PopupMenuItem(
            value: 'chatgpt',
            child: Text('ChatGPT', style: TextStyle(color: Colors.white))),
        PopupMenuItem(
            value: 'gemini',
            child: Text('Gemini', style: TextStyle(color: Colors.white))),
        PopupMenuItem(
            value: 'claude',
            child: Text('Claude', style: TextStyle(color: Colors.white))),
        PopupMenuItem(
            value: 'deepseek',
            child: Text('DeepSeek', style: TextStyle(color: Colors.white))),
        PopupMenuItem(
            value: 'grok',
            child: Text('Grok', style: TextStyle(color: Colors.white))),
      ];

  /// AI トグルボタンの右クリック (PC) / 長押し (モバイル) で、 使う AI を
  /// 切り替えるメニューを表示する (= ユーザー要望: ノードの AI ボタンと同様)。
  Future<void> _showAiServicePicker(Offset pos) async {
    final selected = await showMenu<String>(
      context: context,
      color: const Color(0xFF1E1E32),
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: _aiMenuItems(),
    );
    if (selected != null) _openAiPanel(selected);
  }

  /// Google 検索内の埋め込み動画の再生速度を変更する (= ユーザー要望)。
  /// 同一オリジンの <video> に playbackRate を設定し、 動的に増える動画にも
  /// 効くよう 1 秒ごとに再適用する。 (YouTube 等のクロスオリジン iframe には
  /// ブラウザ仕様上アクセスできないため効かない場合がある。)
  void _applySearchVideoRate(double rate) {
    // 動画が iframe の中にあると document 直下の querySelector では拾えず
    // 速度が適用されなかった (= ユーザー報告)。 同一オリジン iframe は中まで
    // 再帰し、 YouTube 埋め込みには iframe API の postMessage を試みる。
    final js = '''
(function(){
  window.__mmVideoRate = $rate;
  function applyDoc(doc){
    try {
      var vs = doc.querySelectorAll('video');
      for (var i=0;i<vs.length;i++){
        try { vs[i].playbackRate = window.__mmVideoRate; } catch(e){}
      }
      var fr = doc.querySelectorAll('iframe');
      for (var j=0;j<fr.length;j++){
        // 同一オリジン iframe は中の <video> にも適用 (クロスオリジンは例外で skip)
        try { var d = fr[j].contentDocument; if (d) applyDoc(d); } catch(e){}
        // YouTube 埋め込みは iframe API の postMessage で速度変更を試みる
        try {
          var src = fr[j].src || '';
          if (src.indexOf('youtube.com/embed') >= 0 ||
              src.indexOf('youtube-nocookie.com/embed') >= 0) {
            fr[j].contentWindow.postMessage(JSON.stringify(
              {event:'command', func:'setPlaybackRate', args:[window.__mmVideoRate]}), '*');
          }
        } catch(e){}
      }
    } catch(e){}
  }
  function apply(){ applyDoc(document); }
  apply();
  if (!window.__mmVideoRateTimer) {
    window.__mmVideoRateTimer = setInterval(apply, 1000);
  }
})();
''';
    try {
      if (_isDesktop) {
        _winCtrl?.executeScript(js);
      } else {
        _iawCtrl?.evaluateJavascript(source: js);
      }
    } catch (_) {}
  }

  /// 生成 AI チャット欄を開く / 切り替える (5 種類から選択)。
  void _openAiPanel(String aiId) {
    final url = _aiUrls[aiId];
    if (url == null) return;
    setState(() {
      _aiPanelUrl = url;
      _aiPanelOpen = true;
      _aiDefaultId = aiId;
    });
    if (_isDesktop) {
      if (!_aiWinInitStarted) {
        _aiWinInitStarted = true;
        _initAiWinWebView(url);
      } else if (_aiWinInitialized) {
        try {
          _aiWinCtrl.loadUrl(url);
        } catch (_) {}
      }
    } else {
      // モバイル: 既にパネルが生成済みならコントローラへ loadUrl。
      // 未生成 (初回) のときは InAppWebView の initialUrlRequest で開く。
      try {
        _aiIawCtrl?.loadUrl(urlRequest: iaw.URLRequest(url: iaw.WebUri(url)));
      } catch (_) {}
    }
  }

  /// AI 欄用 Windows WebView を初期化して URL をロード。
  Future<void> _initAiWinWebView(String url) async {
    try {
      await _aiWinCtrl.initialize();
      // ── AI チャット欄をマウスホイールでスクロールできるように (= ユーザー
      //    要望) ──。 AI サイトは内側のスクロールコンテナを使うため
      //    webview_windows のネイティブホイールでは動かないことがある。 検索
      //    タブと同じ wheel-tamer を注入して直下のスクロール可能要素を動かす。
      try {
        await _aiWinCtrl.addScriptToExecuteOnDocumentCreated(_kGsWheelTameJs);
      } catch (_) {}
      await _aiWinCtrl.loadUrl(url);
      if (mounted) setState(() => _aiWinInitialized = true);
    } catch (e) {
      if (mounted) setState(() => _aiWinInitError = e.toString());
    }
  }

  /// メモ本文を AI 入力欄に渡す (= ユーザー要望)。
  /// 1. クリップボードへコピー (フォールバック)
  /// 2. AI 欄が閉じていれば既定 AI で開く
  /// 3. JavaScript で AI 入力欄に改行付きで追加挿入する
  void _sendTextToAi(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) {
      _showCaptureSnack('このメモは本文が空のため AI に送れません', const Color(0xFFE57373));
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    final wasOpen = _aiPanelOpen;
    if (!wasOpen) {
      _openAiPanel(_aiDefaultId);
    }
    final initialDelay = wasOpen
        ? const Duration(milliseconds: 300)
        : const Duration(milliseconds: 1500);
    // ── 二重挿入防止 ──
    // AI ページの読み込みタイミング対策で複数回リトライ挿入するが、 これまでは
    //   毎回「追記」 していたため同じ文章が 2〜3 回入ってしまっていた。 送信ごとに
    //   一意な token を渡し、 1 回成功したら以降はスキップさせる (= ユーザー要望)。
    final token = ++_aiInjectSeq;
    Future.delayed(initialDelay, () => _injectTextToAi(text, token));
    Future.delayed(initialDelay + const Duration(milliseconds: 1200),
        () => _injectTextToAi(text, token));
    Future.delayed(initialDelay + const Duration(milliseconds: 2800),
        () => _injectTextToAi(text, token));
    // 「AI 入力欄に追加しました」 の通知は出さない (= ユーザー要望: 鬱陶しい)。
  }

  /// 表示中の検索ページの本文テキストを取得する (= AI へ共有する元データ)。
  /// 検索用 WebView (_winCtrl / _iawCtrl) に対し、 選択範囲があればそれを、
  /// なければ document.body.innerText を取得する (AI 欄用コントローラとは別)。
  /// webview_windows.executeScript / iaw.evaluateJavascript はどちらも値を
  /// デコード済みで返すため、 そのまま文字列化すればよい。 失敗時は空文字。
  Future<String> _readVisibleSearchPageText() async {
    const js =
        "(function(){try{var s=(window.getSelection&&window.getSelection().toString())||'';"
        "var t=(s&&s.trim())?s:((document.body&&document.body.innerText)||'');"
        "return t;}catch(e){return '';}})()";
    try {
      if (_isDesktop) {
        final r = await _winCtrl?.executeScript(js);
        return (r is String) ? r : (r?.toString() ?? '');
      } else {
        final r = await _iawCtrl?.evaluateJavascript(source: js);
        return (r is String) ? r : (r?.toString() ?? '');
      }
    } catch (_) {
      return '';
    }
  }

  /// 表示中の検索ページの内容を AI に共有して質問できるようにする
  /// (= ユーザー要望: Chrome の Gemini タブ共有のように、 Google 検索で表示して
  ///  いる内容を AI と共有)。 本文を抽出し「次のページについて…」 の枠組み
  /// プロンプトと共に既存の _sendTextToAi に渡す (AI 欄が閉じていれば開いて入力欄
  /// へ自動入力。 送信はユーザーが Enter で行う)。
  Future<void> _shareSearchPageWithAi() async {
    _showCaptureSnack('ページ内容を取得して AI に共有中…', const Color(0xFFFFC107));
    final raw = await _readVisibleSearchPageText();
    var body = raw.trim();
    if (body.isEmpty) {
      _showCaptureSnack('ページ本文を取得できませんでした', const Color(0xFFE57373));
      return;
    }
    // 長すぎる本文は AI 入力欄に収まらず挿入も不安定になるため上限を設ける。
    const int maxLen = 7000;
    if (body.length > maxLen) {
      body = '${body.substring(0, maxLen)}\n…(以下省略)';
    }
    final prompt = '次のWebページの内容について日本語で要約・説明してください。'
        '続けて質問するので把握しておいてください。\n'
        'タイトル: $_pageTitle\nURL: $_currentUrl\n\n----\n$body';
    _sendTextToAi(prompt);
  }

  /// メモ本文を DeepL 翻訳に渡す (= ユーザー要望)。
  /// AI 側パネルに DeepL を開き、 URL ハッシュにテキストを載せて自動翻訳。
  /// 既定 AI (_aiDefaultId) は変更しない (DeepL は翻訳用)。
  void _sendTextToDeepL(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) {
      _showCaptureSnack('このメモは本文が空のため DeepL に送れません', const Color(0xFFE57373));
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    // DeepL の URL ハッシュ形式: #<原文言語>/<訳文言語>/<URLエンコード文>
    //   auto = 原文言語を自動判定、 ja = 日本語に翻訳。
    final encoded = Uri.encodeComponent(text);
    final url = 'https://www.deepl.com/translator#auto/ja/$encoded';
    setState(() {
      _aiPanelUrl = url;
      _aiPanelOpen = true;
    });
    if (_isDesktop) {
      if (!_aiWinInitStarted) {
        _aiWinInitStarted = true;
        _initAiWinWebView(url);
      } else if (_aiWinInitialized) {
        try {
          _aiWinCtrl.loadUrl(url);
        } catch (_) {}
      }
    } else {
      try {
        _aiIawCtrl?.loadUrl(urlRequest: iaw.URLRequest(url: iaw.WebUri(url)));
      } catch (_) {}
    }
    if (mounted) {
      _showCaptureSnack('🌐 メモを DeepL に送りました', const Color(0xFF0F73B8));
    }
  }

  /// DeepL 翻訳サイトを AI 側パネルに開く (= ユーザー要望: Google 検索の上に
  ///   DeepL ボタン)。 既定 AI は変更しない (翻訳用)。
  void _openDeepLPanel() {
    const url = 'https://www.deepl.com/translator';
    setState(() {
      _aiPanelUrl = url;
      _aiPanelOpen = true;
    });
    if (_isDesktop) {
      if (!_aiWinInitStarted) {
        _aiWinInitStarted = true;
        _initAiWinWebView(url);
      } else if (_aiWinInitialized) {
        try {
          _aiWinCtrl.loadUrl(url);
        } catch (_) {}
      }
    } else {
      try {
        _aiIawCtrl?.loadUrl(urlRequest: iaw.URLRequest(url: iaw.WebUri(url)));
      } catch (_) {}
    }
  }

  /// AI サイトの入力欄に [text] を末尾へ改行付きで追加挿入する。
  /// contenteditable と textarea を総当たりで探し、 一番大きい可視要素に挿入。
  void _injectTextToAi(String text, int token) {
    if (!mounted) return;
    final escaped = jsonEncode(text);
    final js = '''
(function() {
  try {
    // 同一送信 (token) で既に挿入済みなら二重挿入しない (= ユーザー要望:
    //   同じ用語/文章が複数回渡されるバグの修正)。 挿入成功時にだけ token を
    //   記録し、 リトライ呼び出しはスキップさせる。
    if (window.__mmAiInjectToken === $token) return 'dup';
    var text = $escaped;
    var ceSelectors = [
      'div.ProseMirror[contenteditable="true"]',
      '#prompt-textarea',
      'div[contenteditable="true"].ql-editor',
      'div[contenteditable="true"]',
    ];
    function visibleArea(el) {
      var r = el.getBoundingClientRect();
      if (r.width < 80 || r.height < 16) return 0;
      if (r.bottom < 0 || r.top > window.innerHeight) return 0;
      return r.width * r.height;
    }
    function moveCursorToEnd(el) {
      el.focus();
      try {
        var range = document.createRange();
        range.selectNodeContents(el);
        range.collapse(false);
        var sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(range);
      } catch (e) {}
    }
    var best = null;
    var bestArea = 0;
    for (var i = 0; i < ceSelectors.length; i++) {
      var nodes = document.querySelectorAll(ceSelectors[i]);
      for (var j = 0; j < nodes.length; j++) {
        var n = nodes[j];
        var a = visibleArea(n);
        if (a > bestArea) { bestArea = a; best = n; }
      }
      if (best) break;
    }
    if (best) {
      var existing = (best.innerText || best.textContent || '').trim();
      moveCursorToEnd(best);
      var prefix = existing.length > 0 ? '\\n' : '';
      try {
        document.execCommand('insertText', false, prefix + text);
      } catch (e) {
        best.innerText = (existing + prefix + text);
        best.dispatchEvent(new InputEvent('input', { bubbles: true, data: text }));
      }
      window.__mmAiInjectToken = $token;
      return 'ok-ce';
    }
    var taList = document.querySelectorAll('textarea, input[type="text"]');
    var bestTa = null;
    var bestTaArea = 0;
    for (var k = 0; k < taList.length; k++) {
      var t = taList[k];
      var ta = visibleArea(t);
      if (ta > bestTaArea) { bestTaArea = ta; bestTa = t; }
    }
    if (bestTa) {
      bestTa.focus();
      var existing = bestTa.value || '';
      var prefix = existing.length > 0 ? '\\n' : '';
      var newVal = existing + prefix + text;
      var proto = bestTa.tagName === 'TEXTAREA'
        ? window.HTMLTextAreaElement.prototype
        : window.HTMLInputElement.prototype;
      var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      setter.call(bestTa, newVal);
      bestTa.dispatchEvent(new Event('input', { bubbles: true }));
      try {
        bestTa.selectionStart = bestTa.selectionEnd = newVal.length;
      } catch (e) {}
      window.__mmAiInjectToken = $token;
      return 'ok-ta';
    }
    return 'not-found';
  } catch (e) {
    return 'error: ' + e;
  }
})();
''';
    try {
      if (_isDesktop) {
        _aiWinCtrl.executeScript(js);
      } else {
        _aiIawCtrl?.evaluateJavascript(source: js);
      }
    } catch (_) {}
  }

  // 同意 (CONSENT/SOCS) Cookie を仕込み終えるまでモバイル WebView を作らない
  //   (= ユーザー報告: Android で Google 検索が結果を返さない。 同意ウォール
  //   回避)。 デスクトップ (webview_windows) では不要なので最初から true。
  bool _gsCookiesReady = false;

  Future<void> _seedGoogleConsentCookies() async {
    try {
      final cm = iaw.CookieManager.instance();
      Future<void> set(String url, String domain) async {
        final u = iaw.WebUri(url);
        await cm.setCookie(url: u, name: 'SOCS', value: 'CAI', domain: domain);
        await cm.setCookie(
            url: u,
            name: 'CONSENT',
            value: 'YES+cb.20210328-17-p0.en+FX+999',
            domain: domain);
      }

      await set('https://www.google.com', '.google.com');
      await set('https://www.youtube.com', '.youtube.com');
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = widget.initialQuery;

    // 同意 Cookie を仕込んでから検索 WebView をロードする (Android のみ)。
    //   ★ タイムアウト保険: 万一ハングしても 1.5 秒で WebView を作る
    //   (= 永久スピナーにしない)。
    if (!_isDesktop) {
      _seedGoogleConsentCookies()
          .timeout(const Duration(milliseconds: 1500), onTimeout: () {})
          .whenComplete(() {
        if (mounted) setState(() => _gsCookiesReady = true);
      });
    } else {
      _gsCookiesReady = true;
    }

    // ── メモの初期値ロジック ──
    final provider = context.read<MindMapProvider>();
    if (widget.initialMemo.isNotEmpty) {
      _memoCtrl.text = widget.initialMemo;
      _useDraft = false;
    } else {
      _memoCtrl.text = provider.googleSearchMemoDraft;
      _useDraft = true;
    }
    // メモ欄は既定で閉じる。既存メモの編集 (initialMemo あり) で開いたときだけ
    // 最初から展開しておく (= ユーザー要望: 検索を開いた時はメモ欄を閉じる)。
    _memoExpanded = widget.initialMemo.isNotEmpty;

    if (_useDraft) {
      _memoCtrl.addListener(_scheduleDraftSave);
    }

    // ── 初期 URL の決定 ──
    // 優先順位: initialUrl > initialQuery (= 検索) > Google ホーム
    // Qiita 等を直接 WebView で開きたい場合は initialUrl を指定する。
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      _currentUrl = widget.initialUrl!;
    } else if (widget.initialQuery.isNotEmpty) {
      _currentUrl = _buildSearchUrl(widget.initialQuery);
    } else {
      _currentUrl = 'https://www.google.com/';
    }
    // 最初のタブ = 現在開く URL
    _gsTabs = [_GsTab(url: _currentUrl, title: _pageTitle)];
    _gsActiveTab = 0;

    if (_isDesktop) {
      // 最初のタブの WebView を初期化 (2 個目以降は build 時に遅延初期化)。
      _initWinWebViewForTab(0);
    }

    // ── グローバルキーボードハンドラを登録 ──
    // Focus.onKeyEvent や CallbackShortcuts は Flutter の Focus 階層に
    // 依存するが、 WebView (Webview / InAppWebView) は native widget で
    // Flutter の Focus を持たないため、 WebView にフォーカスがある時は
    // 上位 Focus にキーイベントが届かない。
    //
    // `HardwareKeyboard.instance.addHandler` は **アプリ全体の物理キー
    // イベント**を受け取れる (= Focus 階層に依存しない)。 ハンドラ内で
    // TextField の hasFocus を確認することで、 メモ入力中の Backspace
    // 等は通常通り文字編集に使えるよう退避できる。
    HardwareKeyboard.instance.addHandler(_globalKeyHandler);
  }

  /// アプリ全体のキーイベントハンドラ。
  ///
  /// 戻り値:
  ///   - true : このハンドラがイベントを消費した (= 他のハンドラに渡らない)
  ///   - false: 何もしなかった / 他のハンドラに任せる
  ///
  /// TextField (検索バー / メモ入力欄) にフォーカスがある時は **何もせず
  /// false を返す**。 これにより Backspace で文字を消す、 Ctrl+A でテキスト
  /// 全選択、 Ctrl+Z で入力取消、 等の OS 標準動作が壊れない。
  bool _globalKeyHandler(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent) return false;

    // TextField にフォーカスがある時は素通り
    if (_searchFocus.hasFocus || _memoFocus.hasFocus) return false;

    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final key = event.logicalKey;

    // ── Del / Backspace: 選択中メモを一括削除 ──
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      if (_selectedMemoIds.isEmpty) return false;
      _deleteSelectedMemos();
      return true;
    }
    // ── Ctrl+W: アクティブタブを閉じる (最後の 1 枚なら検索画面ごと閉じる) ──
    if (key == LogicalKeyboardKey.keyW && ctrl && !shift) {
      if (_gsTabs.length <= 1) {
        Navigator.of(context).maybePop();
      } else {
        _closeGsTab(_gsActiveTab);
      }
      return true;
    }
    // ── Ctrl+Shift+T: 閉じたタブを復元 ──
    if (key == LogicalKeyboardKey.keyT && ctrl && shift) {
      _reopenClosedGsTab();
      return true;
    }
    // ── Ctrl+A: 保存済みメモを全選択 ──
    if (key == LogicalKeyboardKey.keyA && ctrl) {
      _selectAllSavedMemos();
      return true;
    }
    // ── Ctrl+Z: 削除取り消し (Undo) ──
    if (key == LogicalKeyboardKey.keyZ && ctrl && !shift) {
      _undoDelete();
      return true;
    }
    // ── F3 / Ctrl+M: メモ欄の開閉 (= ユーザー要望: F3 で左にメモ) ──
    // 既定レイアウトではメモは左側に出る (AI は右側)。
    if (key == LogicalKeyboardKey.f3 ||
        (ctrl && key == LogicalKeyboardKey.keyM)) {
      if (!widget.minimalMode) {
        setState(() => _memoSideExpanded = !_memoSideExpanded);
      }
      return true;
    }
    // ── F4 / Ctrl+I: AI 欄の開閉 (= ユーザー要望: F4 で右に AI) ──
    if (key == LogicalKeyboardKey.f4 ||
        (ctrl && key == LogicalKeyboardKey.keyI)) {
      if (!widget.minimalMode) {
        if (_aiPanelOpen) {
          setState(() => _aiPanelOpen = false);
        } else {
          _openAiPanel(_aiDefaultId);
        }
      }
      return true;
    }
    // ── F6: メモと AI の左右を入れ替え (= ユーザー要望: 入れ替えボタンに
    //    ショートカット) ──
    if (key == LogicalKeyboardKey.f6) {
      if (!widget.minimalMode) {
        setState(() => _panelsSwapped = !_panelsSwapped);
      }
      return true;
    }
    return false;
  }

  void _scheduleDraftSave() {
    _draftSaveDebounce?.cancel();
    _draftSaveDebounce = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      context.read<MindMapProvider>().setGoogleSearchMemoDraft(_memoCtrl.text);
    });
  }

  String _buildSearchUrl(String query) {
    final q = Uri.encodeQueryComponent(query.trim());
    // hl (表示言語) を付ける (= ユーザー報告: モバイルで Google 検索が結果を
    //   返さない)。 言語指定 + 同意 Cookie で同意ウォールを避け結果を確実にする。
    String hl = 'en';
    try {
      hl = context.read<MindMapProvider>().appLanguage;
    } catch (_) {}
    return 'https://www.google.com/search?q=$q&hl=$hl&num=20';
  }

  /// 指定タブの検索用 WebView (webview_windows) を初期化する。
  /// タブごとに別コントローラを持ち、 IndexedStack で生かしておくことで、
  /// タブを切り替えても再読み込みされない (= ユーザー要望)。
  Future<void> _initWinWebViewForTab(int i) async {
    if (i < 0 || i >= _gsTabs.length) return;
    final tab = _gsTabs[i];
    if (tab.winInitStarted) return;
    tab.winInitStarted = true;
    final ctrl = wv_win.WebviewController();
    tab.winCtrl = ctrl;
    try {
      await ctrl.initialize();
      // ポップアップ / 新規ウィンドウは現在の WebView 内で開く (広告から戻れる)。
      try {
        await ctrl
            .setPopupWindowPolicy(wv_win.WebviewPopupWindowPolicy.sameWindow);
      } catch (_) {}
      // Ctrl/中クリック・target=_blank/window.open を新しいタブで開く。
      try {
        await ctrl
            .addScriptToExecuteOnDocumentCreated(_kGsCtrlClickInterceptorJs);
      } catch (_) {}
      // ホイール感度を下げる (= ユーザー要望: スクロールが速すぎる)。
      try {
        await ctrl.addScriptToExecuteOnDocumentCreated(_kGsWheelTameJs);
      } catch (_) {}
      ctrl.webMessage.listen((msg) {
        if (!mounted) return;
        final url = _parseGsCtrlClickMessage(msg);
        if (url != null) _openGsTabBackground(url);
      });
      await ctrl.loadUrl(tab.url);
      ctrl.title.listen((t) {
        if (!mounted) return;
        tab.title = t.isEmpty ? 'Google' : t;
        if (identical(tab, _activeTab)) _pageTitle = tab.title;
        setState(() {});
      });
      ctrl.url.listen((u) {
        if (!mounted) return;
        tab.url = u;
        if (identical(tab, _activeTab)) {
          _currentUrl = u;
          // ページ遷移後も選択中の再生速度を維持する。
          if (_searchVideoRate != 1.0) _applySearchVideoRate(_searchVideoRate);
        }
        setState(() {});
      });
      tab.winReady = true;
      if (mounted) setState(() {});
    } catch (e) {
      tab.winError = e.toString();
      if (mounted) setState(() {});
    }
  }

  void _doSearch() {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;
    final url = _buildSearchUrl(query);
    if (_isDesktop) {
      if (_winInitialized) _winCtrl?.loadUrl(url);
    } else {
      _iawCtrl?.loadUrl(
        urlRequest: iaw.URLRequest(url: iaw.WebUri(url)),
      );
    }
    setState(() => _currentUrl = url);
    _searchFocus.unfocus();
  }

  // ── ブラウザナビゲーション (= ユーザー要望: ページに飛んだら戻れるように) ──
  // Windows (_winCtrl) / モバイル (_iawCtrl) の両方に対応。
  void _navBack() {
    if (_isDesktop) {
      try {
        if (_winInitialized) _winCtrl?.goBack();
      } catch (_) {}
    } else {
      _iawCtrl?.goBack();
    }
  }

  void _navForward() {
    if (_isDesktop) {
      try {
        if (_winInitialized) _winCtrl?.goForward();
      } catch (_) {}
    } else {
      _iawCtrl?.goForward();
    }
  }

  void _navReload() {
    if (_isDesktop) {
      try {
        if (_winInitialized) _winCtrl?.reload();
      } catch (_) {}
    } else {
      _iawCtrl?.reload();
    }
  }

  /// アクティブタブの WebView 履歴を見て `_webCanGoBack` を更新する
  /// (= 戻るジェスチャーで「手前のページに戻る」 か「画面を閉じる」 かの判定用)。
  /// モバイル (InAppWebView) のみ canGoBack API があるので、 そこで更新する。
  /// デスクトップは戻るジェスチャー自体が無いため不要 (= false のまま)。
  Future<void> _refreshWebCanGoBack() async {
    if (_isDesktop) return;
    try {
      final b = await _iawCtrl?.canGoBack() ?? false;
      if (mounted && b != _webCanGoBack) {
        setState(() => _webCanGoBack = b);
      }
    } catch (_) {}
  }

  /// 横分割レイアウトかどうか (= メモ左 / WebView / AI 右)。
  /// useHorizontal と同じ条件。 メモパネルのヘッダー出し分けに使う。
  bool get _isHorizontalLayout {
    final mq = MediaQuery.of(context);
    return _isDesktop ||
        mq.orientation == Orientation.landscape ||
        mq.size.width >= 700;
  }

  /// メモパネルを閉じる (= ユーザー要望: × ボタンで閉じられるように)。
  /// 横分割は _memoSideExpanded、 縦分割は _memoPanelExpanded を倒す。
  void _closeMemoPanel() {
    setState(() {
      _memoSideExpanded = false;
      _memoPanelExpanded = false;
    });
  }

  // ── メモ CRUD アクション ───────────────────────────────────────────

  /// 入力欄をクリアして「新規メモ」 モードに戻り、 エディタを閉じる。
  void _resetEditor() {
    _memoCtrl.clear();
    _editingMemoId = null;
    _memoEditorOpen = false;
    setState(() {});
  }

  /// 「＋新規メモ」 ボタン: エディタを開いて新規入力モードにする。
  void _openNewMemoEditor() {
    _memoCtrl.clear();
    setState(() {
      _editingMemoId = null;
      _memoEditorOpen = true;
      _memoExpanded = true;
    });
    _memoFocus.requestFocus();
  }

  /// 保存ボタン: 編集モードなら update、 新規なら add。
  /// 完了後は入力欄をクリアして「新規」 状態に戻る。
  Future<void> _saveMemo() async {
    final text = _memoCtrl.text.trim();
    if (text.isEmpty) {
      final provider = context.read<MindMapProvider>();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(provider.t('googleSearch.emptyWarn')),
        backgroundColor: const Color(0xFFFFA726),
        duration: const Duration(seconds: 2),
      ));
      return;
    }
    final provider = context.read<MindMapProvider>();
    final snapshotUrl = _includeUrl ? _currentUrl : null;
    if (_editingMemoId != null) {
      await provider.updateGoogleSearchMemo(
        _editingMemoId!,
        text: text,
        snapshotUrl: snapshotUrl,
      );
    } else {
      await provider.addGoogleSearchMemo(GoogleSearchMemo(
        id: 'gs-${DateTime.now().millisecondsSinceEpoch}-${text.hashCode}',
        text: text,
        snapshotUrl: snapshotUrl,
      ));
    }
    // 保存できたのでドラフトはクリア (= 入力欄が空になる)
    if (_useDraft) {
      _draftSaveDebounce?.cancel();
      provider.setGoogleSearchMemoDraft('');
    }
    _resetEditor();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(provider.t('googleSearch.memoSaved')),
      backgroundColor: const Color(0xFF43B97F),
      duration: const Duration(seconds: 2),
    ));
  }

  /// 既存メモを編集モードでロード。
  void _editSavedMemo(GoogleSearchMemo memo) {
    _memoCtrl.text = memo.text;
    setState(() {
      _editingMemoId = memo.id;
      _memoEditorOpen = true;
      _memoExpanded = true;
      _includeUrl = memo.snapshotUrl != null;
    });
    _memoFocus.requestFocus();
  }

  // ── 保存済みメモ: 選択 / 削除 ─────────────────────────────────

  /// メモカードがタップされた時の処理。 modifier キーで挙動分岐:
  /// - **通常タップ**: **何もしない** (= 反応しない)。 ダークさん要望:
  ///   「クリックしただけで選択モードに入る」 のは予期せぬ動作なので、
  ///   通常タップは無視する。 ページ遷移は専用の 🌐 ボタンで行う。
  /// - **Ctrl + タップ**: 当該メモのトグル選択 (他の選択は維持)。
  /// - **Shift + タップ**: 起点 ↔ 当該メモの範囲を全選択。
  ///
  /// Ctrl/Shift 操作時は **TextField からフォーカスを外してメモリスト
  /// Focus に移す**。 これで続けて Del を押すと一括削除ショートカットが
  /// 発火する。
  void _onMemoCardTap(GoogleSearchMemo memo) {
    final isCtrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed; // macOS の Cmd 対応
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    // 通常タップ (modifier 無し) は何もしない (ユーザー要望)
    if (!isCtrl && !isShift) return;

    // 選択操作開始 → TextField からフォーカスを外す (= 上位 Focus の
    // onKeyEvent が Del/Backspace を捕捉できるようにする)
    _searchFocus.unfocus();
    _memoFocus.unfocus();

    if (isCtrl) {
      setState(() {
        if (_selectedMemoIds.contains(memo.id)) {
          _selectedMemoIds.remove(memo.id);
        } else {
          _selectedMemoIds.add(memo.id);
        }
        _lastClickedMemoId = memo.id;
      });
    } else if (isShift && _lastClickedMemoId != null) {
      setState(() {
        final memos = context.read<MindMapProvider>().googleSearchMemos;
        final lastIdx = memos.indexWhere((m) => m.id == _lastClickedMemoId);
        final curIdx = memos.indexWhere((m) => m.id == memo.id);
        if (lastIdx >= 0 && curIdx >= 0) {
          final start = lastIdx < curIdx ? lastIdx : curIdx;
          final end = lastIdx > curIdx ? lastIdx : curIdx;
          for (int i = start; i <= end; i++) {
            _selectedMemoIds.add(memos[i].id);
          }
        }
      });
    } else if (isShift) {
      // Shift+クリックだが起点がない → 単独選択として扱う
      setState(() {
        _selectedMemoIds = {memo.id};
        _lastClickedMemoId = memo.id;
      });
    }
  }

  /// メモに紐づく URL のページを WebView で開く。
  /// snapshotUrl がない場合は呼ばれない (UI でボタンが非表示になる)。
  void _navigateToMemoPage(GoogleSearchMemo memo) {
    final url = memo.snapshotUrl;
    if (url == null || url.isEmpty) return;
    if (_isDesktop) {
      if (_winInitialized) _winCtrl?.loadUrl(url);
    } else {
      _iawCtrl?.loadUrl(
        urlRequest: iaw.URLRequest(url: iaw.WebUri(url)),
      );
    }
    setState(() => _currentUrl = url);
  }

  /// 指定のメモを一括削除。
  /// 単独削除 (✕ボタン) と複数削除 (Del/Backspace) で共通利用する内部関数。
  ///
  /// 削除後、 削除したメモ群を `_deletionHistory` に積んで Ctrl+Z 取消
  /// に備える。 復元時は `restoreGoogleSearchMemos` で元の id / updatedAtMs を
  /// 維持したまま戻すので、 ソート順 (新しい順) も元通り。
  Future<void> _deleteMemos(List<GoogleSearchMemo> memos) async {
    if (memos.isEmpty) return;
    final provider = context.read<MindMapProvider>();
    // 削除前にスナップショットを取って履歴へ (= Ctrl+Z で復元可能に)
    final snapshot = List<GoogleSearchMemo>.from(memos);
    final deletedIds = memos.map((m) => m.id).toSet();
    for (final id in deletedIds) {
      await provider.removeGoogleSearchMemo(id);
    }
    if (!mounted) return;
    setState(() {
      _selectedMemoIds.removeWhere(deletedIds.contains);
      // 編集中のメモが削除されたなら入力欄も初期化
      if (_editingMemoId != null && deletedIds.contains(_editingMemoId)) {
        _memoCtrl.clear();
        _editingMemoId = null;
      }
      // last clicked が消えたら起点をリセット
      if (_lastClickedMemoId != null &&
          deletedIds.contains(_lastClickedMemoId)) {
        _lastClickedMemoId = null;
      }
      // 削除履歴へ積む (上限超えたら古いものから捨てる)
      _deletionHistory.add(snapshot);
      while (_deletionHistory.length > _kDeletionHistoryMax) {
        _deletionHistory.removeAt(0);
      }
    });
    // 削除完了 SnackBar (取り消しの導線を案内する)
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        snapshot.length == 1
            ? provider.t('googleSearch.deletedOneHint')
            : provider
                .t('googleSearch.deletedManyHint')
                .replaceAll('{n}', '${snapshot.length}'),
      ),
      backgroundColor: const Color(0xFF455A64),
      duration: const Duration(seconds: 3),
      action: SnackBarAction(
        label: provider.t('googleSearch.undoLabel'),
        textColor: const Color(0xFFFFC107),
        onPressed: _undoDelete,
      ),
    ));
  }

  /// Ctrl+Z: 直前の削除を取り消し。
  /// 履歴 Stack の末尾を取り出して Provider に restore する。 履歴が空なら
  /// 控えめに SnackBar で通知。
  void _undoDelete() {
    final provider = context.read<MindMapProvider>();
    if (_deletionHistory.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(provider.t('googleSearch.nothingToUndo')),
        backgroundColor: const Color(0xFFFFA726),
        duration: const Duration(seconds: 2),
      ));
      return;
    }
    final batch = _deletionHistory.removeLast();
    provider.restoreGoogleSearchMemos(batch);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        provider
            .t('googleSearch.undoSuccess')
            .replaceAll('{n}', '${batch.length}'),
      ),
      backgroundColor: const Color(0xFF43B97F),
      duration: const Duration(seconds: 2),
    ));
  }

  /// カード内 🗑 アイコン: 単独削除。
  Future<void> _deleteSavedMemo(GoogleSearchMemo memo) => _deleteMemos([memo]);

  /// Del / Backspace ショートカット: 選択中メモを一括削除。
  /// 選択ゼロなら no-op。 入力欄を編集中の場合は TextField が Backspace を
  /// 吸収するのでここまで届かない (= 安全)。
  void _deleteSelectedMemos() {
    if (_selectedMemoIds.isEmpty) return;
    final memos = context
        .read<MindMapProvider>()
        .googleSearchMemos
        .where((m) => _selectedMemoIds.contains(m.id))
        .toList();
    _deleteMemos(memos);
  }

  /// Ctrl+A: 保存済みメモを全選択。 既に全選択状態の場合は無効化はせず、
  /// 同じ Set を再構築する (= 副作用なし)。
  void _selectAllSavedMemos() {
    final memos = context.read<MindMapProvider>().googleSearchMemos;
    if (memos.isEmpty) return;
    _searchFocus.unfocus();
    _memoFocus.unfocus();
    setState(() {
      _selectedMemoIds = memos.map((m) => m.id).toSet();
      _lastClickedMemoId = memos.first.id;
    });
  }

  /// 選択中のメモを一括でマップに追加 (ユーザー要望)。
  /// 「マップに追加してもメモは残す」 仕様にあわせ、 保存リストには
  /// 全部残す。 選択状態も維持する (= テンプレ的に同じセットを連続で
  /// 別マップに投入できる)。 解除したい場合は Esc。
  void _addSelectedMemosToMap() {
    if (_selectedMemoIds.isEmpty) return;
    final provider = context.read<MindMapProvider>();
    // 選択順ではなくソート順 (= 新しい順) で追加
    final memos = provider.googleSearchMemos
        .where((m) => _selectedMemoIds.contains(m.id))
        .toList();
    for (final memo in memos) {
      final lines = memo.text.split('\n');
      final title = lines.first.trim();
      final body = lines.length > 1 ? lines.sublist(1).join('\n').trim() : '';
      widget.onAddNode(title, body, memo.snapshotUrl);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        provider
            .t('googleSearch.batchAddedToMap')
            .replaceAll('{n}', '${memos.length}'),
      ),
      backgroundColor: const Color(0xFF43B97F),
      duration: const Duration(seconds: 2),
    ));
  }

  /// 入力欄の現在の内容をマップに追加。
  /// [keepOpen] = ダイアログを閉じずに続けるかどうか。
  ///
  /// ── 保存済みメモ (= 編集モード) の振る舞い ──
  /// 編集モード時 (`_editingMemoId != null`) でも、 マップに追加した後
  /// 該当メモは **リストに残す**。 「ノード化したテンプレを使い回す」
  /// ような使い方を想定。 重複したい・廃止したい場合はユーザーが個別に
  /// 削除する想定。
  ///
  /// 新規モード時 (= ドラフトから書き起こしている状態) はリストには元から
  /// 載っていないので、 入力欄をクリアするだけで実質「マップに移譲」 になる。
  void _addEditorToMap({required bool keepOpen}) {
    final memoRaw = _memoCtrl.text.trim();
    if (memoRaw.isEmpty) {
      final provider = context.read<MindMapProvider>();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(provider.t('googleSearch.emptyWarn')),
        backgroundColor: const Color(0xFFFFA726),
        duration: const Duration(seconds: 2),
      ));
      return;
    }
    final lines = memoRaw.split('\n');
    final title = lines.first.trim();
    final body = lines.length > 1 ? lines.sublist(1).join('\n').trim() : '';
    final linkUrl = _includeUrl ? _currentUrl : null;
    widget.onAddNode(title, body, linkUrl);

    final provider = context.read<MindMapProvider>();
    // ── 編集モードのメモを削除しない (= リストに残す) ──
    // 旧版は `provider.removeGoogleSearchMemo(_editingMemoId!)` で
    // 「ノードに昇格 = 保存リストから除去」 していたが、 ユーザー要望で
    // 「使い回し可能」 にするため削除をやめた。
    //
    // 新規モード (= _editingMemoId == null) の場合は、 そもそも保存
    // リストに載っていないので削除対象がない。 ドラフトクリアだけで OK。
    if (_useDraft && _editingMemoId == null) {
      // 新規モード時は ドラフトもクリア (= 入力欄が空になる)
      _draftSaveDebounce?.cancel();
      provider.setGoogleSearchMemoDraft('');
    }

    if (keepOpen) {
      _resetEditor();
      _memoFocus.requestFocus();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(provider.t('googleSearch.nodeAdded')),
        backgroundColor: const Color(0xFF43B97F),
        duration: const Duration(seconds: 2),
      ));
    } else {
      _closeSelf();
    }
  }

  /// リスト内のメモを直接マップに追加 (= 編集を経由せずワンタップで)。
  /// ユーザー要望で、 追加後もメモは **リストに残す** (テンプレ的使用)。
  void _addSavedMemoToMap(GoogleSearchMemo memo) {
    final lines = memo.text.split('\n');
    final title = lines.first.trim();
    final body = lines.length > 1 ? lines.sublist(1).join('\n').trim() : '';
    widget.onAddNode(title, body, memo.snapshotUrl);
    final provider = context.read<MindMapProvider>();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(provider.t('googleSearch.nodeAdded')),
      backgroundColor: const Color(0xFF43B97F),
      duration: const Duration(seconds: 2),
    ));
  }

  /// 日付フォーマッタ (リスト表示用)。
  /// 「2025/01/15 14:32」 形式。 1 日前以内なら「14:32」 のみ、 同年なら
  /// 「01/15 14:32」、 別年なら年も含める。
  String _formatTimestamp(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(dt.hour)}:${two(dt.minute)}';
    if (now.difference(dt).inDays < 1 &&
        dt.day == now.day &&
        dt.month == now.month) {
      return hm;
    }
    final md = '${two(dt.month)}/${two(dt.day)} $hm';
    if (dt.year == now.year) return md;
    return '${dt.year}/$md';
  }

  // ── UI 部品 ──────────────────────────────────────────────────────────

  Widget _buildSearchBar(MindMapProvider provider) {
    return Row(
      children: [
        // ── ブラウザナビゲーション (戻る/進む/再読み込み) ──
        // ユーザー要望: モバイルでページに飛ぶと戻れなくなるので、 戻る等の
        //   ボタンを設置 (PC 版にも無かったので両方に追加)。
        IconButton(
          icon: const Icon(Icons.arrow_back_rounded,
              color: Colors.white, size: 20),
          tooltip: '戻る',
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(),
          onPressed: _navBack,
        ),
        // 進む / 再読み込みは横幅に余裕がある時のみ検索バーに置く。
        //   モバイル等の狭い画面では上のボタンが被るため、 「⋮」 メニューへ
        //   移動する (= ユーザー要望: モバイルのボタンが被らないように)。
        if (_isHorizontalLayout) ...[
          IconButton(
            icon: const Icon(Icons.arrow_forward_rounded,
                color: Colors.white, size: 20),
            tooltip: '進む',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            onPressed: _navForward,
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded,
                color: Colors.white, size: 20),
            tooltip: '再読み込み',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            onPressed: _navReload,
          ),
        ],
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _doSearch(),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: provider.t('googleSearch.queryHint'),
              hintStyle: const TextStyle(
                color: Colors.white38,
                fontSize: 14,
              ),
            ),
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.search, color: Colors.white, size: 22),
          tooltip: provider.t('googleSearch.searchOnly'),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(),
          onPressed: _doSearch,
        ),
        // ── ブックマーク追加 / リンク埋め込み ──
        // モバイル (縦) ではここに置くと AI ボタン等と被るので、 横分割時
        //   のみ検索バーに置き、 モバイルでは AppBar の actions 側へ移す
        //   (= ユーザー要望: 被らないように)。
        // minimalMode (= ノードから立ち上げる小さな検索窓) では幅が狭く
        //   ボタンが重なるため非表示にする (= ユーザー要望)。 これらは
        //   「全画面表示」 で開き直した先で利用できる。
        if (_isHorizontalLayout && !widget.minimalMode)
          // リンク埋め込み / お気に入り登録 を統合した 1 ボタン
          _buildCombinedSaveButton(),
      ],
    );
  }

  // ─── スクリーンショット機能 ─────────────────────────────────────────
  //
  // WebView の内容を PNG として取得し、 マップにノードとして追加する。
  // 2 種類のキャプチャモード:
  //   ① _captureScrollToBottomAndAdd
  //       ページの末尾までスクロールしてから、 viewport を 1 枚キャプチャ。
  //   ② _captureFullPageAndAdd
  //       ページ全体を viewport ぶんずつスクロールしながら段階キャプチャし、
  //       縦に結合して 1 枚の長い PNG にする (= 画面外も含む全体)。
  //
  // 制限: Windows の `wv_win.WebviewController` には公開された screenshot
  //   API が無い (= takeScreenshot がない) ため、 InAppWebView 環境
  //   (Android / iOS / Linux / macOS) でのみ動作。 Windows では SnackBar
  //   で未対応を通知する。

  // ── 旧 _ensureCaptureAvailable は撤去 ──
  // Windows でも fallback (`_addPageInfoAsNode`) で代替動作するように
  // 各キャプチャメソッドの先頭で `_iawCtrl == null` を直接チェックして
  // 分岐する形に変更。

  void _showCaptureSnack(String msg, Color bgColor) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 12)),
      backgroundColor: bgColor,
      duration: const Duration(seconds: 3),
    ));
  }

  /// 一番下までスクロールしてからスクショを 1 枚撮ってマップに追加。
  /// Windows では WebView2 がスクショ API を持たないため、 代わりに
  /// ページ情報 (URL + タイトル) をテキストノードとしてマップに追加する。
  // 現在 UI からは未使用 (スクショボタンは _addPageInfoAsNode に変更済)。
  // 将来の再利用に備えて残置するため警告を抑制。
  // ignore: unused_element
  Future<void> _captureScrollToBottomAndAdd() async {
    // ── Windows fallback: 画像なしでページ情報だけマップに追加 ──
    if (_iawCtrl == null) {
      await _addPageInfoAsNode();
      return;
    }
    _showCaptureSnack('ページ末尾までスクロールしています...', const Color(0xFF4FC3F7));
    try {
      // ページの一番下にスクロール
      await _iawCtrl!.evaluateJavascript(source: '''
        window.scrollTo({
          top: document.documentElement.scrollHeight,
          behavior: 'instant'
        });
      ''');
      // スクロール後のレンダリング待ち (= 遅延読込みコンテンツの読み込み待ち)
      await Future<void>.delayed(const Duration(milliseconds: 600));
      // viewport をキャプチャ
      final png = await _iawCtrl!.takeScreenshot();
      if (png == null) {
        _showCaptureSnack('スクショの取得に失敗しました', const Color(0xFFE57373));
        return;
      }
      await _saveScreenshotAsNode(png);
    } catch (e) {
      _showCaptureSnack('スクショ生成に失敗しました: $e', const Color(0xFFE57373));
    }
  }

  /// ページ全体をスクロールしながら段階キャプチャし、 縦結合した 1 枚を
  /// マップに追加。 dart:ui で複数の PNG セグメントを Canvas に並べて合成。
  /// Windows ではテキストノードとして追加 (= fallback)。
  // 現在 UI からは未使用 (スクショボタンは _addPageInfoAsNode に変更済)。
  // 将来の再利用に備えて残置するため警告を抑制。
  // ignore: unused_element
  Future<void> _captureFullPageAndAdd() async {
    // ── Windows fallback ──
    if (_iawCtrl == null) {
      await _addPageInfoAsNode();
      return;
    }
    _showCaptureSnack('ページ全体をキャプチャ中...', const Color(0xFFFFC107));
    try {
      // ── 1. スクロール可能な総高さ + viewport 高さを取得 ──
      final scrollHeightRaw = await _iawCtrl!.evaluateJavascript(source: '''
        Math.max(
          document.documentElement.scrollHeight,
          document.body ? document.body.scrollHeight : 0
        )
      ''');
      final viewHeightRaw =
          await _iawCtrl!.evaluateJavascript(source: 'window.innerHeight');
      final scrollHeight = (scrollHeightRaw is num)
          ? scrollHeightRaw.toInt()
          : int.tryParse('$scrollHeightRaw') ?? 0;
      final viewHeight = (viewHeightRaw is num)
          ? viewHeightRaw.toInt()
          : int.tryParse('$viewHeightRaw') ?? 0;
      if (scrollHeight <= 0 || viewHeight <= 0) {
        _showCaptureSnack('ページサイズの取得に失敗しました', const Color(0xFFE57373));
        return;
      }
      // 安全のため最大セグメント数を制限 (= 異常な巨大ページで OOM 防止)
      const maxSegments = 30;
      final segments = <Uint8List>[];
      int y = 0;
      int count = 0;
      while (y < scrollHeight && count < maxSegments) {
        await _iawCtrl!.evaluateJavascript(
            source: 'window.scrollTo({top: $y, behavior: "instant"});');
        // スクロール後の paint + 遅延読込みコンテンツ待ち
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final png = await _iawCtrl!.takeScreenshot();
        if (png != null) segments.add(png);
        y += viewHeight;
        count++;
      }
      // 先頭に戻す (UX 維持)
      await _iawCtrl!.evaluateJavascript(
          source: 'window.scrollTo({top: 0, behavior: "instant"});');
      if (segments.isEmpty) {
        _showCaptureSnack('スクショの取得に失敗しました', const Color(0xFFE57373));
        return;
      }
      // ── 2. 縦結合 ──
      final combined = await _combineImagesVertically(segments);
      if (combined.isEmpty) {
        _showCaptureSnack('画像結合に失敗しました', const Color(0xFFE57373));
        return;
      }
      await _saveScreenshotAsNode(combined);
    } catch (e) {
      _showCaptureSnack('フルページスクショに失敗しました: $e', const Color(0xFFE57373));
    }
  }

  // ════════════════════════════════════════════════════════════════════
  // 自動スワイプ + スクショ → PDF (= ユーザー要望: 範囲(枚数)と秒間隔等を指定して
  //   スワイプしながらスクショを撮り、 1 つの PDF にまとめる)。 WebView のスクショ
  //   API はモバイル (InAppWebView) のみなので、 _iawCtrl がある時だけ動作する。
  // ════════════════════════════════════════════════════════════════════

  /// 自動スクショの設定 (枚数・秒間隔・スワイプ量) を尋ねるダイアログ。
  Future<({int count, int intervalMs, double swipeFrac})?>
      _showAutoCaptureConfig() async {
    final countCtrl = TextEditingController(text: '10');
    final intervalCtrl = TextEditingController(text: '1.5');
    double swipeFrac = 0.9;
    InputDecoration deco(String label) => InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54),
          enabledBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Colors.white24)),
          focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF4FC3F7))),
        );
    final result =
        await showDialog<({int count, int intervalMs, double swipeFrac})>(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setD) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E32),
          title: const Row(children: [
            Icon(Icons.burst_mode_rounded, color: Color(0xFF4FC3F7), size: 20),
            SizedBox(width: 10),
            Expanded(
                child: Text('自動スクショ → PDF',
                    style: TextStyle(color: Colors.white, fontSize: 16))),
          ]),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
                'スワイプ (スクロール) しながら指定枚数のスクショを撮り、'
                ' 1 つの PDF にまとめます。',
                style: TextStyle(color: Colors.white60, fontSize: 12)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: countCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: deco('枚数 (1〜100)'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: intervalCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(color: Colors.white),
                  decoration: deco('秒間隔'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              const Text('スワイプ量',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              Expanded(
                child: Slider(
                  value: swipeFrac,
                  min: 0.2,
                  max: 1.0,
                  activeColor: const Color(0xFF4FC3F7),
                  onChanged: (v) => setD(() => swipeFrac = v),
                ),
              ),
              Text('${(swipeFrac * 100).round()}%',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child:
                  const Text('キャンセル', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4FC3F7)),
              onPressed: () {
                final count =
                    (int.tryParse(countCtrl.text.trim()) ?? 10).clamp(1, 100);
                final interval =
                    (double.tryParse(intervalCtrl.text.trim()) ?? 1.5)
                        .clamp(0.0, 10.0);
                Navigator.pop(dctx, (
                  count: count,
                  intervalMs: (interval * 1000).round(),
                  swipeFrac: swipeFrac
                ));
              },
              child: const Text('開始', style: TextStyle(color: Colors.black)),
            ),
          ],
        );
      }),
    );
    countCtrl.dispose();
    intervalCtrl.dispose();
    return result;
  }

  /// 設定に従ってスワイプ + スクショを繰り返し、 PDF にまとめて保存する。
  Future<void> _autoSwipeCaptureToPdf() async {
    if (_iawCtrl == null) {
      _showCaptureSnack('この機能はモバイル版のブラウザで利用できます', const Color(0xFFE57373));
      return;
    }
    final cfg = await _showAutoCaptureConfig();
    if (cfg == null || !mounted) return;
    final shots = <Uint8List>[];
    try {
      final viewHeightRaw =
          await _iawCtrl!.evaluateJavascript(source: 'window.innerHeight');
      final viewHeight = (viewHeightRaw is num)
          ? viewHeightRaw.toInt()
          : int.tryParse('$viewHeightRaw') ?? 600;
      final step = (viewHeight * cfg.swipeFrac).round().clamp(1, 100000);
      int lastY = -1;
      for (int i = 0; i < cfg.count; i++) {
        if (!mounted) return;
        _showCaptureSnack(
            '自動キャプチャ中… ${i + 1}/${cfg.count}', const Color(0xFFFFC107));
        // スクロール後の描画 + 遅延読込み待ち
        await Future<void>.delayed(const Duration(milliseconds: 350));
        final png = await _iawCtrl!.takeScreenshot();
        if (png != null) shots.add(png);
        // スワイプ (= 1 画面ぶんスクロール)
        await _iawCtrl!.evaluateJavascript(
            source: 'window.scrollBy({top: $step, behavior: "instant"});');
        // 末尾に到達したら早期終了 (これ以上スクロールできない)
        final yRaw = await _iawCtrl!.evaluateJavascript(
            source:
                'window.scrollY || document.documentElement.scrollTop || 0');
        final y = (yRaw is num) ? yRaw.toInt() : int.tryParse('$yRaw') ?? 0;
        if (i > 0 && y == lastY) break;
        lastY = y;
        if (i < cfg.count - 1) {
          await Future<void>.delayed(Duration(milliseconds: cfg.intervalMs));
        }
      }
      // 先頭に戻す (UX 維持)
      await _iawCtrl!.evaluateJavascript(
          source: 'window.scrollTo({top: 0, behavior: "instant"});');
      if (shots.isEmpty) {
        _showCaptureSnack('スクショを取得できませんでした', const Color(0xFFE57373));
        return;
      }
      await _saveShotsAsPdf(shots);
    } catch (e) {
      _showCaptureSnack('自動キャプチャに失敗しました: $e', const Color(0xFFE57373));
    }
  }

  /// 撮ったスクショ群を 1 つの PDF にまとめて保存し、 マップに PDF ノードとして
  /// 追加する (= アプリ内 PDF ビューアで開ける)。
  Future<void> _saveShotsAsPdf(List<Uint8List> shots) async {
    _showCaptureSnack('PDF を作成中…', const Color(0xFFFFC107));
    try {
      final doc = pw.Document();
      for (final png in shots) {
        final img = pw.MemoryImage(png);
        doc.addPage(pw.Page(
          pageFormat: pdf.PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (ctx) =>
              pw.Center(child: pw.Image(img, fit: pw.BoxFit.contain)),
        ));
      }
      final bytes = await doc.save();
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final filename = 'capture_$ts.pdf';
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(bytes);
      if (!mounted) return;
      final provider = context.read<MindMapProvider>();
      String title;
      try {
        final raw =
            await _iawCtrl!.evaluateJavascript(source: 'document.title');
        title =
            (raw is String && raw.trim().isNotEmpty) ? raw.trim() : _currentUrl;
      } catch (_) {
        title = _currentUrl;
      }
      if (title.length > 40) title = '${title.substring(0, 40)}…';
      final newNode = provider.addNodeAtCenterReturning(const Offset(900, 900));
      provider.updateNodeTitle(newNode.id, '📄 $title (${shots.length}枚)');
      provider.updateNodeAttachment(newNode.id, file.path, filename);
      _showCaptureSnack(
          '${shots.length} 枚を PDF にまとめてマップに追加しました', const Color(0xFF43B97F));
    } catch (e) {
      _showCaptureSnack('PDF の作成に失敗しました: $e', const Color(0xFFE57373));
    }
  }

  /// 複数の PNG セグメントを縦に結合して 1 枚の PNG を返す。
  /// セグメント高さの単純な合計が出力高さ。 全セグメントは同じ幅を想定。
  Future<Uint8List> _combineImagesVertically(List<Uint8List> segments) async {
    final uiImages = <ui.Image>[];
    for (final bytes in segments) {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      uiImages.add(frame.image);
    }
    if (uiImages.isEmpty) return Uint8List(0);
    final width = uiImages.first.width;
    final totalHeight = uiImages.fold<int>(0, (a, img) => a + img.height);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder,
        Rect.fromLTWH(0, 0, width.toDouble(), totalHeight.toDouble()));
    double yOff = 0;
    for (final img in uiImages) {
      canvas.drawImage(img, Offset(0, yOff), Paint());
      yOff += img.height;
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, totalHeight);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List() ?? Uint8List(0);
  }

  /// PNG バイナリをファイルに保存し、 マップにノードとして追加。
  /// ノード名は現在ページの URL から推測 (= タイトル取得が間に合えばそれ)。
  // ─── ブックマーク機能 ──────────────────────────────────────────────
  //
  // 検索中に「気に入ったページ」 をブックマークとして保存し、 後で
  // ワンクリックで開けるようにする。 SharedPreferences ベースで永続化。
  //
  // データモデル: List<{url, title, savedAt}> を JSON 文字列で保存。

  /// 現在のページをブックマークに追加。
  ///
  /// 動作:
  /// - `onCreateBookmarkButton` コールバックが設定されている場合:
  ///   呼び出し元 (mind_map_screen) にカスタマイズダイアログを開かせて、
  ///   ユーザーに名前/アイコン/色を選んでもらい、 動的ボタンとして作成。
  /// - コールバック未設定 (= 旧互換) の場合:
  ///   従来通り SharedPreferences (`mokumoku_gs_bookmarks_v1`) に追加して、
  ///   検索ダイアログ内のお気に入り一覧に表示するだけ。
  /// 「リンク埋め込み」と「お気に入りボタン登録」を 1 つに統合したボタン。
  /// タップ=現在モードを実行 / PC は右クリック・モバイルは長押しでモード切替。
  Widget _buildCombinedSaveButton() {
    final isBookmark = _gsSaveAsBookmark;
    void toggle() => setState(() => _gsSaveAsBookmark = !_gsSaveAsBookmark);
    final desktop = _isDesktop;
    final switchHint = desktop ? '右クリック' : '長押し';
    return GestureDetector(
      onSecondaryTap: desktop ? toggle : null,
      onLongPress: desktop ? null : toggle,
      child: Tooltip(
        message: isBookmark
            ? 'お気に入りボタンに追加\n$switchHint でリンク埋め込みに切替'
            : 'リンクとして埋め込み\n$switchHint でお気に入り登録に切替',
        child: IconButton(
          icon: Icon(
            isBookmark ? Icons.bookmark_add_rounded : Icons.add_link_rounded,
            color:
                isBookmark ? const Color(0xFFFFB347) : const Color(0xFF4FC3F7),
            size: 22,
          ),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(),
          onPressed: () {
            if (isBookmark) {
              _addCurrentPageToBookmarks();
            } else {
              _addPageInfoAsNode();
            }
          },
        ),
      ),
    );
  }

  /// モバイルの「⋮」 オーバーフローメニュー用の項目。
  PopupMenuItem<String> _gsOverflowItem(
      String value, IconData icon, String label) {
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      child: Row(children: [
        Icon(icon, color: const Color(0xFF4FC3F7), size: 18),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
      ]),
    );
  }

  Future<void> _addCurrentPageToBookmarks() async {
    final url = _currentUrl;
    if (url.isEmpty) {
      _showCaptureSnack('URL が取れません', const Color(0xFFE57373));
      return;
    }
    String title;
    // Windows なら _pageTitle、 iaw なら JS で document.title を取得
    if (_pageTitle.isNotEmpty) {
      title = _pageTitle;
    } else if (_iawCtrl != null) {
      try {
        final raw =
            await _iawCtrl!.evaluateJavascript(source: 'document.title');
        title = (raw is String && raw.trim().isNotEmpty) ? raw.trim() : url;
      } catch (_) {
        title = url;
      }
    } else {
      title = url;
    }
    // ── 新仕組み: 動的ボタン作成コールバックがあればそちらに委譲 ──
    final cb = widget.onCreateBookmarkButton;
    if (cb != null) {
      final ok = await cb(url, title);
      if (!mounted) return;
      if (ok) {
        _showCaptureSnack('お気に入りボタンを作成: $title', const Color(0xFF43B97F));
      }
      // ok == false (= ユーザーがキャンセル) の場合はスナックを出さない
      return;
    }
    // ── 旧仕組み: 検索ダイアログ内のブックマーク一覧に追加するだけ ──
    await _GoogleSearchBookmarks.add(url: url, title: title);
    if (mounted) {
      _showCaptureSnack('ブックマークに追加: $title', const Color(0xFF43B97F));
    }
  }

  /// ブックマーク一覧を表示する PopupMenuButton ウィジェット。
  /// 各エントリのタップで該当 URL を WebView でロード、
  /// × ボタンで個別削除、 末尾に「全削除」 メニュー。
  Widget _buildBookmarksMenuButton() {
    return FutureBuilder<List<_BookmarkItem>>(
      future: _GoogleSearchBookmarks.load(),
      builder: (ctx, snapshot) {
        final items = snapshot.data ?? const <_BookmarkItem>[];
        return PopupMenuButton<int>(
          tooltip: 'お気に入りページ (${items.length}件)',
          color: const Color(0xFF22222E),
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.bookmarks_rounded,
                  color: Color(0xFFFFB347), size: 22),
              if (items.isNotEmpty)
                Positioned(
                  right: -6,
                  top: -6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFB347),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    constraints: const BoxConstraints(minWidth: 14),
                    child: Text(
                      '${items.length}',
                      style: const TextStyle(
                          color: Colors.black,
                          fontSize: 9,
                          fontWeight: FontWeight.w700),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          itemBuilder: (_) {
            if (items.isEmpty) {
              return [
                const PopupMenuItem<int>(
                  enabled: false,
                  child: SizedBox(
                    width: 280,
                    child: Text(
                      'お気に入りなし\n'
                      '★ ボタンで現在のページを追加すると、\n'
                      'ヘッダー/フッターの「お気に入り 1〜5」 から呼び出せる',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ),
                ),
              ];
            }
            return [
              for (int i = 0; i < items.length; i++)
                PopupMenuItem<int>(
                  value: i,
                  child: SizedBox(
                    width: 320,
                    child: Row(
                      children: [
                        // スロット番号 (= ヘッダー/フッターのお気に入り N に対応)
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: i < 5
                                ? const Color(0xFFFFB347).withValues(alpha: 0.2)
                                : Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: i < 5
                                  ? const Color(0xFFFFB347)
                                  : Colors.white24,
                              width: 0.5,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                color: i < 5
                                    ? const Color(0xFFFFB347)
                                    : Colors.white54,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                items[i].displayLabel.isEmpty
                                    ? items[i].url
                                    : items[i].displayLabel,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                items[i].url,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 10),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        // ── 編集 (= アイコン/ラベルカスタマイズ) ボタン ──
                        // 上位 5 件のみ表示 (= ヘッダー/フッターに配置できる
                        //                      お気に入り 1〜5 に対応)
                        if (i < 5)
                          InkWell(
                            onTap: () async {
                              Navigator.of(ctx).pop(); // PopupMenu を閉じる
                              await _editBookmarkCustomization(i, items[i]);
                              if (mounted) setState(() {});
                            },
                            borderRadius: BorderRadius.circular(4),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(Icons.edit_rounded,
                                  color: Color(0xFF4FC3F7), size: 16),
                            ),
                          ),
                        InkWell(
                          onTap: () async {
                            await _GoogleSearchBookmarks.removeAt(i);
                            if (mounted) {
                              Navigator.of(ctx).pop();
                              setState(() {});
                            }
                          },
                          borderRadius: BorderRadius.circular(4),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.close_rounded,
                                color: Colors.white54, size: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem<int>(
                value: -1,
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded,
                        color: Color(0xFFE57373), size: 16),
                    SizedBox(width: 8),
                    Text('全て削除',
                        style:
                            TextStyle(color: Color(0xFFE57373), fontSize: 12)),
                  ],
                ),
              ),
            ];
          },
          onSelected: (i) async {
            if (i == -1) {
              await _GoogleSearchBookmarks.clear();
              if (mounted) setState(() {});
              return;
            }
            if (i >= 0 && i < items.length) {
              _openUrl(items[i].url);
            }
          },
        );
      },
    );
  }

  /// お気に入り N (= ヘッダー/フッター用) のアイコンとラベルを編集する
  /// ダイアログ。 タイトルや URL は変更不可。 編集後は SharedPreferences
  /// に保存され、 customPage1〜5 ボタンの表示に反映される。
  Future<void> _editBookmarkCustomization(int idx, _BookmarkItem item) async {
    final labelCtrl = TextEditingController(
        text: item.customLabel.isEmpty ? item.title : item.customLabel);
    int selectedIconCode = item.customIconCode == 0
        ? Icons.bookmark_rounded.codePoint
        : item.customIconCode;
    String selectedIconFamily = item.customIconFontFamily.isEmpty
        ? (Icons.bookmark_rounded.fontFamily ?? 'MaterialIcons')
        : item.customIconFontFamily;

    final result = await showDialog<bool>(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (sctx, setS) {
        return AlertDialog(
          backgroundColor: const Color(0xFF22222E),
          title: Row(children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: const Color(0xFFFFB347).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFFFFB347)),
              ),
              child: Center(
                child: Text(
                  '${idx + 1}',
                  style: const TextStyle(
                      color: Color(0xFFFFB347),
                      fontSize: 13,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Text('お気に入りを編集', style: TextStyle(color: Colors.white)),
          ]),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // URL (読み取り専用)
                Text(item.url,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 12),
                const Text('表示名',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(height: 4),
                TextField(
                  controller: labelCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF1A1A24),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    hintText: item.title,
                    hintStyle: const TextStyle(color: Colors.white38),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('アイコンを選択',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(height: 6),
                // アイコン候補グリッド
                SizedBox(
                  height: 180,
                  child: GridView.count(
                    crossAxisCount: 8,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                    children: [
                      for (final icon in _bookmarkIconChoices)
                        InkWell(
                          onTap: () => setS(() {
                            selectedIconCode = icon.codePoint;
                            selectedIconFamily =
                                icon.fontFamily ?? 'MaterialIcons';
                          }),
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            decoration: BoxDecoration(
                              color: icon.codePoint == selectedIconCode
                                  ? const Color(0xFFFFB347)
                                      .withValues(alpha: 0.25)
                                  : Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: icon.codePoint == selectedIconCode
                                    ? const Color(0xFFFFB347)
                                    : Colors.transparent,
                              ),
                            ),
                            child: Icon(icon,
                                color: icon.codePoint == selectedIconCode
                                    ? const Color(0xFFFFB347)
                                    : Colors.white70,
                                size: 22),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child:
                  const Text('キャンセル', style: TextStyle(color: Colors.white54)),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dctx).pop(true),
              icon: const Icon(Icons.check_rounded, size: 16),
              label: const Text('保存'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFFB347),
                foregroundColor: Colors.black,
              ),
            ),
          ],
        );
      }),
    );
    if (result == true) {
      final updated = item.copyWith(
        customLabel: labelCtrl.text.trim(),
        customIconCode: selectedIconCode,
        customIconFontFamily: selectedIconFamily,
      );
      await _GoogleSearchBookmarks.updateAt(idx, updated);
      if (mounted) {
        _showCaptureSnack('お気に入り ${idx + 1} を更新しました', const Color(0xFF43B97F));
      }
    }
    labelCtrl.dispose();
  }

  /// アイコン候補。 ブックマーク向けに直感的な記号を 32 個。
  /// `static const` にしたいが IconData は const コンストラクタを持って
  /// いない場面があるため、 各要素は const Icon.icon を参照する形で安全に。
  static final List<IconData> _bookmarkIconChoices = [
    Icons.bookmark_rounded,
    Icons.star_rounded,
    Icons.favorite_rounded,
    Icons.home_rounded,
    Icons.work_rounded,
    Icons.school_rounded,
    Icons.shopping_cart_rounded,
    Icons.shopping_bag_rounded,
    Icons.email_rounded,
    Icons.chat_rounded,
    Icons.public_rounded,
    Icons.search_rounded,
    Icons.menu_book_rounded,
    Icons.article_rounded,
    Icons.description_rounded,
    Icons.code_rounded,
    Icons.terminal_rounded,
    Icons.cloud_rounded,
    Icons.cloud_download_rounded,
    Icons.photo_rounded,
    Icons.movie_rounded,
    Icons.music_note_rounded,
    Icons.podcasts_rounded,
    Icons.sports_esports_rounded,
    Icons.flight_rounded,
    Icons.restaurant_rounded,
    Icons.local_cafe_rounded,
    Icons.fitness_center_rounded,
    Icons.health_and_safety_rounded,
    Icons.account_balance_rounded,
    Icons.attach_money_rounded,
    Icons.language_rounded,
  ];

  /// 指定 URL を現在の WebView でロード。 既存の _doSearch と同じ仕組み。
  void _openUrl(String url) {
    if (_isDesktop) {
      if (_winInitialized) _winCtrl?.loadUrl(url);
    } else {
      _iawCtrl?.loadUrl(urlRequest: iaw.URLRequest(url: iaw.WebUri(url)));
    }
    setState(() => _currentUrl = url);
  }

  // ───────── 複数タブ (= ユーザー要望) ─────────
  String _gsTabLabel(int i) {
    if (i < 0 || i >= _gsTabs.length) return '';
    final t = _gsTabs[i].title;
    return t.isNotEmpty ? t : 'タブ ${i + 1}';
  }

  void _switchGsTab(int i) {
    if (i == _gsActiveTab || i < 0 || i >= _gsTabs.length) return;
    // 再読み込みせず表示だけ切り替える (= IndexedStack で各タブを保持済み)。
    setState(() {
      _gsActiveTab = i;
      _currentUrl = _gsTabs[i].url;
      _pageTitle = _gsTabs[i].title.isNotEmpty ? _gsTabs[i].title : 'Google';
    });
    if (_searchVideoRate != 1.0) _applySearchVideoRate(_searchVideoRate);
  }

  void _addGsTab() {
    if (_gsTabs.length >= _kGsMaxTabs) return;
    setState(() {
      _gsTabs.add(_GsTab(url: 'https://www.google.com/', title: 'Google'));
      _gsActiveTab = _gsTabs.length - 1;
      _currentUrl = 'https://www.google.com/';
      _pageTitle = 'Google';
    });
    // 新タブの WebView は build 時に初期化され、 その URL を読み込む。
  }

  void _closeGsTab(int i) {
    if (_gsTabs.length <= 1 || i < 0 || i >= _gsTabs.length) return;
    final wasActive = i == _gsActiveTab;
    final closing = _gsTabs[i];
    // 閉じたタブを履歴に積む (Ctrl+Shift+T で復元)。
    final closingUrl = wasActive ? _currentUrl : closing.url;
    if (closingUrl.isNotEmpty) {
      _closedGsTabs.add(_GsTab(url: closingUrl, title: closing.title));
      if (_closedGsTabs.length > 20) _closedGsTabs.removeAt(0);
    }
    setState(() {
      _gsTabs.removeAt(i);
      if (_gsActiveTab >= _gsTabs.length) {
        _gsActiveTab = _gsTabs.length - 1;
      } else if (i < _gsActiveTab) {
        _gsActiveTab--;
      }
      // 新しいアクティブタブの URL / タイトルを反映 (再読み込みはしない)。
      _currentUrl = _gsTabs[_gsActiveTab].url;
      _pageTitle = _gsTabs[_gsActiveTab].title.isNotEmpty
          ? _gsTabs[_gsActiveTab].title
          : 'Google';
    });
    // 閉じたタブの WebView をツリーから外れた後に破棄する。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        closing.winCtrl?.dispose();
      } catch (_) {}
      try {
        if (!_isDesktop) {
          iaw.InAppWebViewController.disposeKeepAlive(closing.iawKeepAlive);
        }
      } catch (_) {}
    });
  }

  /// Ctrl/中クリックで受け取った URL をバックグラウンドの新タブに開く
  /// (= ブラウザの Ctrl+クリックと同じく、 アクティブタブは切り替えない)。
  void _openGsTabBackground(String url) {
    if (url.isEmpty || _gsTabs.length >= _kGsMaxTabs) return;
    setState(() {
      _gsTabs.add(_GsTab(url: url, title: ''));
    });
  }

  /// 直近に閉じたタブを開き直す (Ctrl+Shift+T)。
  void _reopenClosedGsTab() {
    if (_closedGsTabs.isEmpty || _gsTabs.length >= _kGsMaxTabs) return;
    final t = _closedGsTabs.removeLast();
    _gsTabs[_gsActiveTab].url = _currentUrl; // 現タブ保存
    setState(() {
      _gsTabs.add(_GsTab(url: t.url, title: t.title));
      _gsActiveTab = _gsTabs.length - 1;
    });
    _openUrl(t.url);
  }

  void _openSiteGsTab(int i, String url, String name) {
    if (i < 0 || i >= _gsTabs.length) return;
    if (i != _gsActiveTab) _gsTabs[_gsActiveTab].url = _currentUrl;
    setState(() {
      _gsTabs[i].url = url;
      _gsTabs[i].title = name;
      _gsActiveTab = i;
    });
    _openUrl(url);
  }

  /// タブ右クリック: フォルダーに保存 / サイトを開く。
  Future<void> _showGsTabMenu(Offset pos, int i) async {
    if (i < 0 || i >= _gsTabs.length) return;
    final selected = await showMenu<String>(
      context: context,
      color: const Color(0xFF22222E),
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        const PopupMenuItem<String>(
          value: 'folder',
          child: Text('フォルダーに保存',
              style: TextStyle(color: Colors.white, fontSize: 13)),
        ),
        const PopupMenuDivider(),
        ..._gsSites.map((s) => PopupMenuItem<String>(
              value: 'site:${s.$1}',
              child: Text('${s.$1} を開く',
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            )),
      ],
    );
    if (selected == null || !mounted) return;
    if (selected == 'folder') {
      _gsSaveTabToFolder(i);
    } else if (selected.startsWith('site:')) {
      final name = selected.substring(5);
      final site = _gsSites.firstWhere((s) => s.$1 == name,
          orElse: () => _gsSites.first);
      _openSiteGsTab(i, site.$2, site.$1);
    }
  }

  /// サイトボタン: 一覧から選んで新しいタブで開く。
  Future<void> _showGsNewTabSiteMenu(Offset pos) async {
    final selected = await showMenu<String>(
      context: context,
      color: const Color(0xFF22222E),
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: _gsSites
          .map((s) => PopupMenuItem<String>(
                value: s.$1,
                child: Text('${s.$1} を新しいタブで開く',
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ))
          .toList(),
    );
    if (selected == null || !mounted) return;
    final site = _gsSites.firstWhere((s) => s.$1 == selected,
        orElse: () => _gsSites.first);
    if (_gsTabs.length >= _kGsMaxTabs) {
      _openSiteGsTab(_gsActiveTab, site.$2, site.$1);
      return;
    }
    _gsTabs[_gsActiveTab].url = _currentUrl;
    setState(() {
      _gsTabs.add(_GsTab(url: site.$2, title: site.$1));
      _gsActiveTab = _gsTabs.length - 1;
    });
    _openUrl(site.$2);
  }

  // ── フォルダー（保存グループ・ブックマーク風。YouTube と共通ストア） ──
  Future<void> _gsSaveTabToFolder(int i) async {
    if (i < 0 || i >= _gsTabs.length) return;
    final url = (i == _gsActiveTab) ? _currentUrl : _gsTabs[i].url;
    final title = (i == _gsActiveTab && _pageTitle.isNotEmpty)
        ? _pageTitle
        : _gsTabs[i].title;
    if (url.isEmpty) return;
    final folders = await TabFolderStore.load();
    if (!mounted) return;
    final name = await _gsPickFolderName(folders.keys.toList());
    if (name == null || name.isEmpty || !mounted) return;
    final list = folders.putIfAbsent(name, () => []);
    if (!list.any((e) => e['url'] == url)) {
      list.add({'url': url, 'title': title});
    }
    await TabFolderStore.save(folders);
  }

  Future<String?> _gsPickFolderName(List<String> existing) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E32),
        title: const Text('フォルダーに保存',
            style: TextStyle(color: Colors.white, fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (existing.isNotEmpty) ...[
              const Text('既存のフォルダー',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: existing
                    .map((f) => ActionChip(
                          label: Text(f),
                          backgroundColor: const Color(0xFF2A2A40),
                          labelStyle: const TextStyle(color: Colors.white),
                          onPressed: () => Navigator.pop(dctx, f),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 12),
              const Text('または新規フォルダー',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
            TextField(
              controller: ctrl,
              autofocus: existing.isEmpty,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'フォルダー名',
                hintStyle: TextStyle(color: Colors.white38),
              ),
              onSubmitted: (v) => Navigator.pop(dctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, null),
            child: const Text('キャンセル', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(dctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _showGsFoldersMenu() async {
    final folders = await TabFolderStore.load();
    if (!mounted) return;
    if (folders.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setD) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E32),
          title: const Text('フォルダー',
              style: TextStyle(color: Colors.white, fontSize: 15)),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: folders.entries
                  .map((e) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.folder_rounded,
                            color: Color(0xFFFFB347)),
                        title: Text(e.key,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14)),
                        subtitle: Text('${e.value.length} 件',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline_rounded,
                              color: Color(0xFFE57373), size: 20),
                          onPressed: () async {
                            folders.remove(e.key);
                            await TabFolderStore.save(folders);
                            setD(() {});
                          },
                        ),
                        onTap: () {
                          // フォルダーを押すと全タブが開いてしまうのを、
                          //   中身を一覧して個別に開けるように (= ユーザー要望)。
                          Navigator.pop(dctx);
                          _showGsFolderTabsMenu(e.key, e.value);
                        },
                      ))
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('閉じる', style: TextStyle(color: Colors.white54)),
            ),
          ],
        );
      }),
    );
  }

  void _gsOpenFolder(List<Map<String, String>> tabs) {
    if (tabs.isEmpty) return;
    if (_gsActiveTab >= 0 && _gsActiveTab < _gsTabs.length) {
      _gsTabs[_gsActiveTab].url = _currentUrl;
    }
    String? last;
    setState(() {
      for (final t in tabs) {
        if (_gsTabs.length >= _kGsMaxTabs) break;
        final u = t['url'] ?? '';
        if (u.isEmpty) continue;
        _gsTabs.add(_GsTab(url: u, title: t['title'] ?? ''));
        _gsActiveTab = _gsTabs.length - 1;
        last = u;
      }
    });
    if (last != null) _openUrl(last!);
  }

  /// フォルダー内の個別タブ一覧。 タップで 1 つだけ開ける (= ユーザー要望:
  /// フォルダーを押すと全部開いてしまうのを、 ピンポイントで開けるように)。
  Future<void> _showGsFolderTabsMenu(
      String folderName, List<Map<String, String>> tabs) async {
    if (tabs.isEmpty || !mounted) return;
    final items = List<Map<String, String>>.from(tabs); // 削除用にコピー
    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setD) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E32),
          title: Row(children: [
            const Icon(Icons.folder_open_rounded,
                color: Color(0xFFFFB347), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(folderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
            ),
          ]),
          content: SizedBox(
            width: 340,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (int idx = 0; idx < items.length; idx++)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.public_rounded,
                          color: Color(0xFF4FC3F7), size: 18),
                      title: Text(
                        (items[idx]['title'] ?? '').isNotEmpty
                            ? items[idx]['title']!
                            : (items[idx]['url'] ?? ''),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                      subtitle: Text(items[idx]['url'] ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: Color(0xFFE57373), size: 18),
                        tooltip: 'このタブを削除',
                        onPressed: () async {
                          final url = items[idx]['url'];
                          final folders = await TabFolderStore.load();
                          folders[folderName]
                              ?.removeWhere((e) => e['url'] == url);
                          if (folders[folderName]?.isEmpty ?? false) {
                            folders.remove(folderName);
                          }
                          await TabFolderStore.save(folders);
                          items.removeAt(idx);
                          if (!mounted) return;
                          setD(() {});
                          if (items.isEmpty) Navigator.pop(dctx);
                        },
                      ),
                      onTap: () {
                        Navigator.pop(dctx);
                        _gsOpenSingleFromFolder(
                            items[idx]['url'] ?? '', items[idx]['title'] ?? '');
                      },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('閉じる', style: TextStyle(color: Colors.white54)),
            ),
            if (items.isNotEmpty)
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white),
                icon: const Icon(Icons.open_in_full_rounded, size: 16),
                label: const Text('すべて開く'),
                onPressed: () {
                  Navigator.pop(dctx);
                  _gsOpenFolder(items);
                },
              ),
          ],
        );
      }),
    );
  }

  /// フォルダー内の 1 タブだけを新しいタブで開く。
  void _gsOpenSingleFromFolder(String url, String title) {
    if (url.isEmpty) return;
    if (_gsActiveTab >= 0 && _gsActiveTab < _gsTabs.length) {
      _gsTabs[_gsActiveTab].url = _currentUrl;
    }
    if (_gsTabs.length >= _kGsMaxTabs) {
      _openSiteGsTab(_gsActiveTab, url, title); // 上限なら現在のタブで開く
      return;
    }
    setState(() {
      _gsTabs.add(_GsTab(url: url, title: title));
      _gsActiveTab = _gsTabs.length - 1;
    });
    _openUrl(url);
  }

  /// 上部のタブバー（タブ一覧 + フォルダー + サイト + 新規タブ「＋」）。
  Widget _buildGsTabBar() {
    return Container(
      height: 34,
      color: const Color(0xFF0E0E1A),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: [
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _gsTabs.length,
            itemBuilder: (_, i) {
              final active = i == _gsActiveTab;
              return GestureDetector(
                onTap: () => _switchGsTab(i),
                onSecondaryTapDown: (d) => _showGsTabMenu(d.globalPosition, i),
                onLongPressStart: (d) => _showGsTabMenu(d.globalPosition, i),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 180),
                  margin:
                      const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  decoration: BoxDecoration(
                    color:
                        active ? const Color(0xFF2A2A40) : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color:
                            active ? const Color(0xFF6C63FF) : Colors.white12),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(
                      child: Text(
                        _gsTabLabel(i),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: active ? Colors.white : Colors.white54,
                            fontSize: 12),
                      ),
                    ),
                    if (_gsTabs.length > 1)
                      InkWell(
                        onTap: () => _closeGsTab(i),
                        borderRadius: BorderRadius.circular(10),
                        child: const Padding(
                          padding: EdgeInsets.all(3),
                          child: Icon(Icons.close_rounded,
                              size: 14, color: Colors.white38),
                        ),
                      ),
                  ]),
                ),
              );
            },
          ),
        ),
        GestureDetector(
          onTap: _showGsFoldersMenu,
          behavior: HitTestBehavior.opaque,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Tooltip(
              message: 'フォルダー（保存したタブを開く）',
              child: Icon(Icons.folder_rounded,
                  color: Color(0xFFFFB347), size: 18),
            ),
          ),
        ),
        // ── 新しいタブ「＋」 (= ユーザー要望: 地球ボタンと統合。 押すと、
        //    どのサイトのタブを作るかを選べるメニューを出す) ──
        if (_gsTabs.length < _kGsMaxTabs)
          GestureDetector(
            onTapDown: (d) => _showGsNewTabSiteMenu(d.globalPosition),
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Tooltip(
                message: '新しいタブ（サイトを選択）',
                child: Icon(Icons.add_rounded, color: Colors.white70, size: 20),
              ),
            ),
          ),
      ]),
    );
  }

  /// Windows 用 fallback: 現在のページ情報 (URL + タイトル) を
  /// テキストノードとしてマップに追加する。 画像はないが、 ページの
  /// 識別情報 (= 後で再アクセスできるリンク) はちゃんと残る。
  Future<void> _addPageInfoAsNode() async {
    try {
      if (!mounted) return;
      _showCaptureSnack('ページ情報をマップに追加中...', const Color(0xFF4FC3F7));
      final provider = context.read<MindMapProvider>();
      // タイトル: Windows なら _pageTitle (= _winCtrl.title.listen で更新済)、
      // それ以外なら _currentUrl のドメイン部分を抜き出して使う。
      String title = _pageTitle.isNotEmpty ? _pageTitle : _currentUrl;
      if (title.length > 50) title = '${title.substring(0, 50)}…';
      // ノードを生成。 座標はキャンバスの大体中央 (= 後で移動可能)。
      final newNode = provider.addNodeAtCenterReturning(const Offset(900, 900));
      provider.updateNodeTitle(newNode.id, '🔗 $title');
      // URL をノードのリンクとして保存 (= タップで再アクセス可能)
      try {
        provider.updateNodeLink(newNode.id, _currentUrl);
      } catch (_) {/* updateNodeLink が無い古い provider 用フォールバック */}
      _showCaptureSnack('ページ情報をマップに追加しました', const Color(0xFF43B97F));
    } catch (e) {
      _showCaptureSnack('追加に失敗しました: $e', const Color(0xFFE57373));
    }
  }

  Future<void> _saveScreenshotAsNode(Uint8List pngBytes) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final filename = 'gss_$ts.png';
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(pngBytes);
      if (!mounted) return;
      final provider = context.read<MindMapProvider>();
      // ノード名: WebView から document.title を取得 (失敗時は URL 切り抜き)
      String title;
      try {
        final raw =
            await _iawCtrl!.evaluateJavascript(source: 'document.title');
        title =
            (raw is String && raw.trim().isNotEmpty) ? raw.trim() : _currentUrl;
      } catch (_) {
        title = _currentUrl;
      }
      if (title.length > 50) title = '${title.substring(0, 50)}…';
      // ノードを生成 + 画像を attach
      // 座標はキャンバスの大体中央 (= 後でユーザーがドラッグ移動可能)
      final newNode = provider.addNodeAtCenterReturning(const Offset(900, 900));
      provider.updateNodeTitle(newNode.id, '📸 $title');
      provider.updateNodeAttachment(newNode.id, file.path, filename);
      _showCaptureSnack('スクショをマップに追加しました', const Color(0xFF43B97F));
    } catch (e) {
      _showCaptureSnack('保存に失敗しました: $e', const Color(0xFFE57373));
    }
  }

  Widget _buildWebView() {
    final idx =
        (_gsActiveTab >= 0 && _gsActiveTab < _gsTabs.length) ? _gsActiveTab : 0;
    if (_gsTabs.isEmpty) {
      return Container(color: const Color(0xFF1E1E1E));
    }
    // ── モバイル(Android): keepAlive 付き InAppWebView を IndexedStack で
    //    全タブ同時マウントすると、 ハイブリッド合成のプラットフォームビューが
    //    真っ白 / 操作不能になる既知の不具合が起きる (= ユーザー報告: モバイルで
    //    Google 検索等が使えない)。 各タブの keepAlive が状態を保持するので、
    //    アクティブタブの WebView だけをマウントすれば十分 (切替時は keepAlive
    //    から復元される)。 タブ切替で確実に作り直すよう ValueKey を付ける。 ──
    if (!_isDesktop) {
      // 同意 Cookie の準備が終わるまでは作らない (初回ロードが同意ページに
      //   飛ぶのを防ぐ)。
      if (!_gsCookiesReady) {
        return const Center(child: CircularProgressIndicator());
      }
      // 各タブの WebView は keepAlive 由来の安定キーを持つので、 タブ切替で
      //   不要に作り直されない (= プラットフォームビューの白画面churn防止)。
      return _buildIawTabWebView(idx);
    }
    // デスクトップ (webview_windows) は従来どおり全タブ保持で問題ない。
    return IndexedStack(
      index: idx,
      children: [
        for (int i = 0; i < _gsTabs.length; i++) _buildWinTabWebView(i),
      ],
    );
  }

  /// デスクトップ: 1 タブ分の webview_windows。 未初期化なら遅延初期化 + ローディング。
  Widget _buildWinTabWebView(int i) {
    final tab = _gsTabs[i];
    if (tab.winError != null) {
      return Container(
        color: const Color(0xFF1E1E1E),
        padding: const EdgeInsets.all(20),
        alignment: Alignment.center,
        child: SelectableText(
          'WebView2 の初期化に失敗しました:\n${tab.winError}\n\n'
          'Microsoft Edge WebView2 Runtime がインストール\n'
          'されているか確認してください。',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      );
    }
    if (!tab.winReady || tab.winCtrl == null) {
      if (!tab.winInitStarted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _initWinWebViewForTab(i);
        });
      }
      return Container(
        color: const Color(0xFF1E1E1E),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      );
    }
    return wv_win.Webview(tab.winCtrl!);
  }

  /// モバイル: 1 タブ分の InAppWebView。 keepAlive で切替時の状態を保持する。
  Widget _buildIawTabWebView(int i) {
    final tab = _gsTabs[i];
    return iaw.InAppWebView(
      // タブ固有の安定キー (keepAlive 由来)。 アクティブタブのみ描画する構成で
      //   タブ切替時にプラットフォームビューが churn しないようにする。
      key: ValueKey('gsiaw_${tab.iawKeepAlive.hashCode}'),
      keepAlive: tab.iawKeepAlive,
      initialUrlRequest: iaw.URLRequest(url: iaw.WebUri(tab.url)),
      initialSettings: iaw.InAppWebViewSettings(
        javaScriptEnabled: true,
        // 透明背景を無効化 (= ユーザー報告: Android で WebView が見えない/
        //   真っ白になる対策。 透明合成だと中身が描画されないことがある)。
        transparentBackground: false,
        // shouldOverrideUrlLoading コールバックを有効化 (= intent:// 等を弾く)
        useShouldOverrideUrlLoading: true,
        mediaPlaybackRequiresUserGesture: true,
        // ── Google ログイン情報を保持するための設定 ──
        // incognito をオフ + cache を有効にして、 Cookie をディスク永続化。
        // これでアプリ再起動後もログイン状態が保たれる。
        // (= 検索結果のパーソナライズ、 履歴、 Google アカウント連携が機能)
        incognito: false,
        cacheEnabled: true,
        clearCache: false,
        // サードパーティ Cookie (= Google ログイン連携で必要) も許可
        thirdPartyCookiesEnabled: true,
        // localStorage / sessionStorage / IndexedDB を ON
        // (= Google サービスの永続データを保存可能に)
        databaseEnabled: true,
        domStorageEnabled: true,
        // Android: Native View をハイブリッド合成 (= WebView の描画が
        //          Flutter のオーバーレイと正しく重なる)。 これがないと
        //          一部 Android 端末で WebView が真っ白 / 反応しない問題が起きる。
        useHybridComposition: true,
        // Android で混在コンテンツ (HTTP+HTTPS) を許可
        mixedContentMode: iaw.MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
        // ── User-Agent: OS ごとに振り分け ──
        // Windows で固定すると、 Android の WebView でも Windows UA に
        // なってしまい、 Google が「不正な端末」 と判定して検索結果を
        // 返さないことがある。 各プラットフォームの標準 UA を使う。
        userAgent: !kIsWeb && Platform.isAndroid
            ? 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'
            : !kIsWeb && Platform.isIOS
                ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                    'AppleWebKit/605.1.15 (KHTML, like Gecko) '
                    'Version/17.0 Mobile/15E148 Safari/604.1'
                : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                    'AppleWebKit/537.36 (KHTML, like Gecko) '
                    'Chrome/120.0.0.0 Safari/537.36',
        // 動画 / 音声を inline 再生 (= Android で別アプリに飛ばない)
        allowsInlineMediaPlayback: true,
        // ファイルアクセス許可 (file:// URI の page を含む)
        allowFileAccess: true,
      ),
      onWebViewCreated: (c) => tab.iawCtrl = c,
      onTitleChanged: (c, title) {
        if (!mounted) return;
        tab.title = (title ?? '').isEmpty ? 'Google' : title!;
        if (identical(tab, _activeTab)) _pageTitle = tab.title;
        setState(() {});
      },
      onLoadStop: (c, url) {
        if (!mounted) return;
        if (url != null) {
          tab.url = url.toString();
          if (identical(tab, _activeTab)) _currentUrl = tab.url;
          // ── 同意ページ (consent.google.com / consent.youtube.com) に飛んだら
          //   自動でボタンを押して通過する (= ユーザー報告: 検索結果が出ない。
          //   Cookie で回避しきれない時の保険)。 ──
          final u = tab.url;
          if (u.contains('consent.google.') || u.contains('consent.youtube.')) {
            c.evaluateJavascript(
                source:
                    "(function(){try{var bs=document.querySelectorAll('form button, button, input[type=\"submit\"]');for(var i=0;i<bs.length;i++){var t=((bs[i].textContent||'')+' '+(bs[i].getAttribute('aria-label')||'')).toLowerCase();if(t.indexOf('reject')>=0||t.indexOf('accept')>=0||t.indexOf('agree')>=0||t.indexOf('同意')>=0||t.indexOf('拒否')>=0||t.indexOf('すべて')>=0){bs[i].click();return;}}var f=document.querySelector('form[action*=\"consent\"]');if(f)f.submit();}catch(e){}})();");
          }
        }
        // ページ遷移後も選択中の再生速度を維持する。
        if (_searchVideoRate != 1.0) _applySearchVideoRate(_searchVideoRate);
        // 戻るジェスチャー判定用に「戻れるか」 を更新。
        if (identical(tab, _activeTab)) _refreshWebCanGoBack();
        setState(() {});
      },
      // ── SPA (Google / YouTube 等) では onLoadStop が発火しない遷移がある。
      //    履歴更新を検知して「戻れるか」 を更新し、 戻るジェスチャーで手前の
      //    ページに戻れるようにする (= 検索画面が閉じてしまう問題の対策)。
      onUpdateVisitedHistory: (c, url, isReload) {
        if (!mounted) return;
        if (url != null && identical(tab, _activeTab)) {
          tab.url = url.toString();
          _currentUrl = tab.url;
        }
        if (identical(tab, _activeTab)) _refreshWebCanGoBack();
      },
      // ── ロード失敗時のハンドラ (= Android で開けない問題の対策) ──
      // ネット接続無し / 証明書エラー / DNS 解決失敗 等を SnackBar で通知。
      // 旧実装はエラーを黙って飲み込んでいたため、 ユーザー側で「開けない」
      // としか分からなかった。 ここで具体的なエラー内容を出してリトライを促す。
      onReceivedError: (c, request, error) {
        if (!mounted) return;
        debugPrint('InAppWebView error: ${error.description} '
            '(type=${error.type}) url=${request.url}');
        // メインフレーム以外 (= サブリソース) のエラーは無視
        // (= 広告ブロック等で頻発し、 ユーザー体験を阻害するため)
        if (request.isForMainFrame != true) return;
        _showCaptureSnack(
          'ページの読み込みに失敗: ${error.description}',
          const Color(0xFFE57373),
        );
      },
      onReceivedHttpError: (c, request, errorResponse) {
        if (!mounted) return;
        debugPrint('InAppWebView HTTP error: ${errorResponse.statusCode} '
            'url=${request.url}');
        if (request.isForMainFrame != true) return;
        // 401/403 等は Google 側のレートリミット / ログイン要求の可能性
        if (errorResponse.statusCode == 401 ||
            errorResponse.statusCode == 403) {
          _showCaptureSnack(
            'Google からアクセス拒否 (${errorResponse.statusCode}): '
            '少し時間を置いて再試行してください',
            const Color(0xFFE57373),
          );
        } else if ((errorResponse.statusCode ?? 0) >= 500) {
          _showCaptureSnack(
            'サーバーエラー (${errorResponse.statusCode}): '
            'ネット接続を確認してください',
            const Color(0xFFE57373),
          );
        }
      },
      // ── 外部 URL を WebView 内で開く設定 ──
      // 通常はクリックで Chrome 等に飛ばないようにする (= 検索体験を維持)。
      // ただし intent:// 等の特殊スキームは外部処理に任せる。
      shouldOverrideUrlLoading: (c, navAction) async {
        final url = navAction.request.url?.toString() ?? '';
        if (url.startsWith('intent://') ||
            url.startsWith('market://') ||
            url.startsWith('tel:') ||
            url.startsWith('mailto:')) {
          return iaw.NavigationActionPolicy.CANCEL;
        }
        return iaw.NavigationActionPolicy.ALLOW;
      },
    );
  }

  /// 入力エディタ (上部) ─ 編集中 / 新規メモ作成時に表示。
  Widget _buildEditor(MindMapProvider provider) {
    final isEditing = _editingMemoId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 見出し: 編集中 / 新規メモ + キャンセル + 折りたたみトグル
        Row(
          children: [
            // ── 折りたたみトグル (= ユーザー要望: メモ欄は閉じたり開いたり
            //    できるように) ──
            // ▼ = 展開中 / ▶ = 折りたたみ中。 タップで _memoExpanded を反転。
            InkWell(
              onTap: () => setState(() => _memoExpanded = !_memoExpanded),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: AnimatedRotation(
                  turns: _memoExpanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white70, size: 18),
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              isEditing ? Icons.edit_rounded : Icons.edit_note_rounded,
              color:
                  isEditing ? const Color(0xFF4FC3F7) : const Color(0xFFFFB347),
              size: 18,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                isEditing
                    ? provider.t('googleSearch.editingNow')
                    : provider.t('googleSearch.newMemo'),
                style: TextStyle(
                  color: isEditing ? const Color(0xFF4FC3F7) : Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
            if (isEditing || _memoEditorOpen)
              IconButton(
                icon: const Icon(Icons.close_rounded,
                    size: 18, color: Colors.white54),
                tooltip: provider.t('googleSearch.cancelEdit'),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                onPressed: _resetEditor,
              ),
            // ドラフト保存中インジケーター (新規モード時のみ表示)
            if (!isEditing && _useDraft)
              Tooltip(
                message: provider.t('googleSearch.draftSavedTip'),
                child: const Icon(Icons.cloud_done_rounded,
                    color: Color(0xFF66BB6A), size: 16),
              ),
          ],
        ),
        // ── 折りたたみ時は本体 (入力欄 + URL リンク包含 + 操作ボタン群)
        //    を非表示にしてヘッダーだけ残す。 _memoExpanded が true の
        //    時だけ展開コンテンツを描画する ──
        if (_memoExpanded) ...[
          const SizedBox(height: 6),
          // 入力欄
          Container(
            height: 130,
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isEditing
                    ? const Color(0xFF4FC3F7).withValues(alpha: 0.5)
                    : Colors.white12,
                width: isEditing ? 1.5 : 1.0,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            // ── Enter キーの挙動制御 (ユーザー要望) ──
            // - Enter (修飾なし) → メモを保存 (= _saveMemo() を呼ぶ)
            // - Shift+Enter / Alt+Enter → 改行 (= TextField デフォルト動作)
            //
            // Focus.onKeyEvent で Enter のキーダウンを検出して保存にハンドル
            // する。 KeyEventResult.handled を返すと TextField に届かないので
            // 改行されない。 Shift/Alt が押されている時は ignored を返して
            // TextField のデフォルト改行に委ねる。
            //
            // IME 変換中の Enter (= 変換確定) もこの Focus に届く可能性が
            // あるが、 変換確定の Enter は KeyDownEvent としてではなく
            // KeyRepeatEvent / IME 経由で来るため、 通常タイプ時の Enter とは
            // 区別される (= 変換中は誤発火しない)。
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent) return KeyEventResult.ignored;
                if (event.logicalKey != LogicalKeyboardKey.enter &&
                    event.logicalKey != LogicalKeyboardKey.numpadEnter) {
                  return KeyEventResult.ignored;
                }
                final shiftPressed = HardwareKeyboard.instance.isShiftPressed;
                final altPressed = HardwareKeyboard.instance.isAltPressed;
                if (shiftPressed || altPressed) {
                  // Shift+Enter / Alt+Enter → デフォルトの改行に任せる
                  return KeyEventResult.ignored;
                }
                // 修飾なし Enter → 保存
                _saveMemo();
                return KeyEventResult.handled;
              },
              child: TextField(
                controller: _memoCtrl,
                focusNode: _memoFocus,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: provider.t('googleSearch.memoHint'),
                  hintStyle:
                      const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // URL リンク包含
          Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: _includeUrl,
                  onChanged: (v) => setState(() => _includeUrl = v ?? true),
                  activeColor: const Color(0xFF4285F4),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  provider.t('googleSearch.includeUrl'),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // アクションボタン (横並び 2 つ)
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saveMemo,
                  icon: const Icon(Icons.save_rounded, size: 16),
                  label: Text(provider.t('googleSearch.saveMemo')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _addEditorToMap(keepOpen: true),
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
                  label: Text(provider.t('googleSearch.searchAndAdd')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4285F4),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // ── 編集中のメモを DeepL に送る (= ユーザー要望) ──
              IconButton(
                icon: const Icon(Icons.translate_rounded,
                    color: Color(0xFF0F73B8), size: 20),
                tooltip: 'このメモを DeepL に送る',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(),
                onPressed: () => _sendTextToDeepL(_memoCtrl.text),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 選択中アクションバー (= 「N 件 選択中」 + アクション群)。
  ///
  /// `_selectedMemoIds.isNotEmpty` の時だけ呼ばれる前提。
  /// 構成 (横並び):
  ///   - ✓ アイコン + 「N 件 選択中」 表示
  ///   - スペーサー
  ///   - [➕ マップに追加]  ← `_addSelectedMemosToMap`
  ///   - [🗑 削除]         ← `_deleteSelectedMemos`
  ///   - [×]              ← 選択解除
  /// ボタンはコンパクトなアイコン + ラベル。 オレンジ系 (選択モードの
  /// アクセントカラー) で統一。
  Widget _buildSelectionActionBar(MindMapProvider provider) {
    final count = _selectedMemoIds.length;
    final countText =
        provider.t('googleSearch.selectionCount').replaceAll('{n}', '$count');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF3A2E1A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: const Color(0xFFFFA726).withValues(alpha: 0.6),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded,
              color: Color(0xFFFFA726), size: 14),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              countText,
              style: const TextStyle(
                color: Color(0xFFFFB347),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          _selectionBarIconBtn(
            icon: Icons.add_circle_outline_rounded,
            color: const Color(0xFF66BB6A),
            tooltip: provider.t('googleSearch.addSelectedToMap'),
            onTap: _addSelectedMemosToMap,
          ),
          _selectionBarIconBtn(
            icon: Icons.delete_outline_rounded,
            color: const Color(0xFFE57373),
            tooltip: provider.t('googleSearch.deleteMemo'),
            onTap: _deleteSelectedMemos,
          ),
          _selectionBarIconBtn(
            icon: Icons.close_rounded,
            color: Colors.white54,
            tooltip: provider.t('googleSearch.deselectAll'),
            onTap: () {
              setState(() {
                _selectedMemoIds.clear();
                _lastClickedMemoId = null;
              });
            },
          ),
        ],
      ),
    );
  }

  /// 選択バー内の小さなアイコンボタン。 `_miniIconButton` と似ているが、
  /// バーは横スペースが狭いので padding を更に詰める。
  Widget _selectionBarIconBtn({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        canRequestFocus: false,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, color: color, size: 16),
        ),
      ),
    );
  }

  /// 保存メモ 1 個のカード。
  ///
  /// 状態の組み合わせ:
  /// - 編集中 (`isEditing`): 入力欄に展開中 → 青枠 + 濃い青背景
  /// - 選択中 (`isSelected`): Ctrl/Shift+クリックで選択 → オレンジ枠 + 半透明青
  /// - 両方:                 編集中スタイル優先
  ///
  /// onTap で複数選択ロジック (`_onMemoCardTap`) を発火。 単純なタップは
  /// 単独選択になり、 他のメモ選択は解除される。
  Widget _buildMemoCard(MindMapProvider provider, GoogleSearchMemo memo) {
    final isEditing = _editingMemoId == memo.id;
    final isSelected = _selectedMemoIds.contains(memo.id);
    final Color borderColor;
    final Color bgColor;
    if (isEditing) {
      borderColor = const Color(0xFF4FC3F7).withValues(alpha: 0.6);
      bgColor = const Color(0xFF1E3A5F);
    } else if (isSelected) {
      borderColor = const Color(0xFFFFA726);
      bgColor = const Color(0xFF3A2E1A);
    } else {
      borderColor = Colors.white12;
      bgColor = const Color(0xFF252525);
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _onMemoCardTap(memo),
          borderRadius: BorderRadius.circular(6),
          // ── canRequestFocus: false ──
          // InkWell はデフォルトで自身の Focus ノードを持ち、 タップ時に
          // フォーカスを奪う。 これがあると `_onMemoCardTap` 内で
          // `_memoListFocus.requestFocus()` を呼んでも、 結局 InkWell の
          // 内部 Focus が直後に上書きしてしまい、 Del/Backspace ショート
          // カットがメモリスト Focus に届かない (= 削除できない症状の原因)。
          //
          // false にすることで InkWell はフォーカスを取らず、 タップ後の
          // フォーカス先は `_onMemoCardTap` の `requestFocus()` 指定どおり
          // `_memoListFocus` に確定する。 リップル効果や視覚は維持される。
          canRequestFocus: false,
          child: Container(
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: borderColor,
                width: (isEditing || isSelected) ? 1.5 : 1.0,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // タイトル行 (1 行目相当) + 選択チェック ✓
                Row(
                  children: [
                    if (isSelected)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.check_circle_rounded,
                            color: Color(0xFFFFA726), size: 14),
                      ),
                    Expanded(
                      child: Text(
                        memo.displayTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // タイムスタンプ + URL あれば 🔗
                Row(
                  children: [
                    Text(
                      _formatTimestamp(memo.updatedAtMs),
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                      ),
                    ),
                    if (memo.snapshotUrl != null) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.link_rounded,
                          color: Color(0xFF4FC3F7), size: 12),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                // アクションボタン (横並び、 アイコンのみ)
                // 順序: 🌐 ページを開く / ✏ 編集 / ➕ マップへ / 🗑 削除
                // 🌐 は snapshotUrl があるメモにだけ表示。
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (memo.snapshotUrl != null &&
                        memo.snapshotUrl!.isNotEmpty) ...[
                      _miniIconButton(
                        icon: Icons.open_in_browser_rounded,
                        color: const Color(0xFFFFB74D),
                        tooltip: provider.t('googleSearch.openMemoPage'),
                        onTap: () => _navigateToMemoPage(memo),
                      ),
                      const SizedBox(width: 2),
                    ],
                    _miniIconButton(
                      icon: Icons.edit_rounded,
                      color: const Color(0xFF4FC3F7),
                      tooltip: provider.t('googleSearch.editMemo'),
                      onTap: () => _editSavedMemo(memo),
                    ),
                    const SizedBox(width: 2),
                    // ── メモを AI 欄に送る (= ユーザー要望) ──
                    _miniIconButton(
                      icon: Icons.smart_toy_rounded,
                      color: const Color(0xFF4FC3F7),
                      tooltip: 'AI に送る',
                      onTap: () => _sendTextToAi(memo.text),
                    ),
                    const SizedBox(width: 2),
                    // ── メモを DeepL に送る (= ユーザー要望: メモ内容を翻訳) ──
                    _miniIconButton(
                      icon: Icons.translate_rounded,
                      color: const Color(0xFF0F73B8),
                      tooltip: 'DeepL に送る',
                      onTap: () => _sendTextToDeepL(memo.text),
                    ),
                    const SizedBox(width: 2),
                    _miniIconButton(
                      icon: Icons.add_circle_outline_rounded,
                      color: const Color(0xFF66BB6A),
                      tooltip: provider.t('googleSearch.searchAndAdd'),
                      onTap: () => _addSavedMemoToMap(memo),
                    ),
                    const SizedBox(width: 2),
                    _miniIconButton(
                      icon: Icons.delete_outline_rounded,
                      color: const Color(0xFFE57373),
                      tooltip: provider.t('googleSearch.deleteMemo'),
                      onTap: () => _deleteSavedMemo(memo),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 小さなアクションボタン (カード内用)。
  Widget _miniIconButton({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        // フォーカスを奪わない (= 押した後も _memoListFocus を維持)。
        // カード側の InkWell と同じ理由 (Del/Backspace ショートカット
        // が効かなくなるのを防ぐため)。
        canRequestFocus: false,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, color: color, size: 16),
        ),
      ),
    );
  }

  /// 生成 AI サイドパネル (= ユーザー要望: PDF ビューアと同様の AI 欄)。
  /// ヘッダー (AI 選択 5 種 + 左右入れ替え + 閉じる) + WebView 本体。
  /// [showSwap] が false なら左右入れ替えボタンを出さない (= モバイル縦並び)。
  Widget _buildAiPanel(MindMapProvider provider, {bool showSwap = true}) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E32),
        border: Border(
          left: BorderSide(color: Colors.white24),
          right: BorderSide(color: Colors.white24),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
            color: const Color(0xFF12121C),
            child: Row(children: [
              const Icon(Icons.smart_toy_rounded,
                  color: Color(0xFF4FC3F7), size: 18),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('AI',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ),
              PopupMenuButton<String>(
                tooltip: 'AI を選択',
                icon: const Icon(Icons.expand_more_rounded,
                    color: Colors.white70, size: 18),
                color: const Color(0xFF1E1E32),
                onSelected: _openAiPanel,
                itemBuilder: (_) => _aiMenuItems(),
              ),
              // ── AI チャット画面を再読み込み (= ユーザー要望) ──
              IconButton(
                tooltip: 'AI チャットを再読み込み',
                icon: const Icon(Icons.refresh_rounded,
                    color: Colors.white70, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: _reloadGsAiPanel,
              ),
              if (showSwap)
                IconButton(
                  tooltip: 'メモ欄と左右を入れ替え (F6)',
                  icon: const Icon(Icons.swap_horiz_rounded,
                      color: Colors.white70, size: 18),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () =>
                      setState(() => _panelsSwapped = !_panelsSwapped),
                ),
              IconButton(
                tooltip: 'AI 欄を閉じる',
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white60, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () => setState(() => _aiPanelOpen = false),
              ),
            ]),
          ),
          Expanded(child: _buildAiWebView()),
        ],
      ),
    );
  }

  /// google 検索の AI チャット画面を再読み込みする (= ユーザー要望)。
  void _reloadGsAiPanel() {
    try {
      if (_isDesktop) {
        if (_aiWinInitialized) _aiWinCtrl.reload();
      } else {
        _aiIawCtrl?.reload();
      }
    } catch (_) {}
  }

  /// AI 欄の WebView 本体 (Windows / モバイルで分岐)。
  Widget _buildAiWebView() {
    if (_aiPanelUrl.isEmpty) {
      return const Center(
        child: Text('AI を選択してください',
            style: TextStyle(color: Colors.white38, fontSize: 12)),
      );
    }
    if (_isDesktop) {
      if (_aiWinInitError != null) {
        return Container(
          color: const Color(0xFF1E1E1E),
          padding: const EdgeInsets.all(16),
          alignment: Alignment.center,
          child: SelectableText(
            'AI WebView の初期化に失敗しました:\n$_aiWinInitError',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        );
      }
      if (!_aiWinInitialized) {
        return Container(
          color: const Color(0xFF1E1E1E),
          alignment: Alignment.center,
          child: const CircularProgressIndicator(),
        );
      }
      return wv_win.Webview(_aiWinCtrl);
    }
    return iaw.InAppWebView(
      initialUrlRequest: iaw.URLRequest(url: iaw.WebUri(_aiPanelUrl)),
      initialSettings: iaw.InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        useHybridComposition: true,
        incognito: false,
        cacheEnabled: true,
        clearCache: false,
        thirdPartyCookiesEnabled: true,
        allowsInlineMediaPlayback: true,
      ),
      onWebViewCreated: (c) => _aiIawCtrl = c,
    );
  }

  /// モバイル縦並び用の AI 欄 (= 下端に出す)。 メモ欄と同時展開しても
  /// 画面からはみ出しにくいよう、 高さを画面の 42% (220〜380px) に収める。
  Widget _buildMobileAiPanel(MindMapProvider provider) {
    final h = MediaQuery.of(context).size.height;
    return SizedBox(
      height: (h * 0.42).clamp(220.0, 380.0),
      child: _buildAiPanel(provider, showSwap: false),
    );
  }

  /// 横分割時の「メモ欄」 ウィジェット (開閉アニメ付き)。
  Widget _memoSidePanel(MindMapProvider provider) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: SizedBox(
        width: _memoSideExpanded ? 360 : 0,
        child: _memoSideExpanded
            ? _buildMemoPanel(provider)
            : const SizedBox.shrink(),
      ),
    );
  }

  /// 横分割時の「AI 欄」 ウィジェット (開いている時のみ)。
  Widget? _aiSidePanel(MindMapProvider provider) {
    if (!_aiPanelOpen) return null;
    return SizedBox(width: 380, child: _buildAiPanel(provider));
  }

  /// 横分割 (= デスクトップ / 横長) の左パネル。
  /// ユーザー要望: メモと AI が同じ方向に出ないように。 既定はメモが左、
  ///   AI が右。 _panelsSwapped で左右を入れ替える。
  List<Widget> _horizontalLeftPanel(MindMapProvider provider) {
    if (widget.minimalMode) return const [];
    if (_panelsSwapped) {
      final ai = _aiSidePanel(provider);
      return ai != null ? [ai] : const [];
    }
    return [_memoSidePanel(provider)];
  }

  /// 横分割の右パネル (左パネルの逆)。
  List<Widget> _horizontalRightPanel(MindMapProvider provider) {
    if (widget.minimalMode) return const [];
    if (_panelsSwapped) {
      return [_memoSidePanel(provider)];
    }
    final ai = _aiSidePanel(provider);
    return ai != null ? [ai] : const [];
  }

  /// メモパネル全体 (エディタ + 仕切り + 保存済みリスト)。
  Widget _buildMemoPanel(MindMapProvider provider) {
    final memos = provider.googleSearchMemos;
    // ノードからの編集モード (initialMemo 指定) では複数メモ機能を非表示
    // にして、 そのメモ 1 つを編集するシンプルな UI に。
    final isNodeEdit = !_useDraft;

    return Container(
      color: const Color(0xFF1F1F1F),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── パネルヘッダー (入れ替え + × 閉じる) ──
          // ユーザー要望: メモ欄を左右入れ替えできるように + 閉じるボタン。
          //   横分割時のみ表示 (縦分割は _buildCollapsibleMemoPanel の
          //   ヘッダーが開閉を担うため)。
          if (_isHorizontalLayout && !widget.minimalMode)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  const Icon(Icons.sticky_note_2_rounded,
                      color: Color(0xFFFFB347), size: 16),
                  const SizedBox(width: 6),
                  const Text('メモ',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  // メモと AI を左右入れ替え (= AI 側ボタンと色を揃えて白に)
                  IconButton(
                    icon: const Icon(Icons.swap_horiz_rounded,
                        color: Colors.white70, size: 20),
                    tooltip: 'メモと AI を左右入れ替え (F6)',
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    onPressed: () =>
                        setState(() => _panelsSwapped = !_panelsSwapped),
                  ),
                  // × 閉じる
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white70, size: 20),
                    tooltip: 'メモを閉じる (F3)',
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    onPressed: _closeMemoPanel,
                  ),
                ],
              ),
            ),
          // ── 入力エディタ ──
          // PDF ビューアのメモ欄と同じく、 普段は隠して「＋新規メモ」 ボタンや
          //   既存メモの編集時だけ表示する (= ユーザー要望: 形式を揃える)。
          if (isNodeEdit || _memoEditorOpen || _editingMemoId != null)
            _buildEditor(provider),
          if (!isNodeEdit) ...[
            const SizedBox(height: 10),
            // ── 仕切り ──
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 10),
            // ── 保存済みメモ見出し (＋ 新規メモ ボタン) ──
            Row(
              children: [
                const Icon(Icons.bookmarks_rounded,
                    color: Color(0xFFFFB347), size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${provider.t('googleSearch.savedMemos')} (${memos.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                // ＋新規メモ (= PDF ビューアの「フリーメモ」 ボタンに相当)
                IconButton(
                  icon: const Icon(Icons.note_add_rounded,
                      color: Color(0xFFFFB347), size: 18),
                  tooltip: '新規メモ',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: _openNewMemoEditor,
                ),
              ],
            ),
            const SizedBox(height: 6),
            // ── 選択中アクションバー ──
            // 1 個以上選択している時のみ表示。 「N 件 選択中」 と一緒に
            // 「マップに追加 / 削除 / 選択解除」 のアクションを並べて、
            // 複数選択した後の動線を明示的に提供する。
            if (_selectedMemoIds.isNotEmpty) ...[
              _buildSelectionActionBar(provider),
              const SizedBox(height: 6),
            ],
            // ── 保存済みメモ一覧 ──
            // キーボードショートカット (Del/Backspace/Ctrl+A/Ctrl+Z) は
            // ダイアログ最上位の Focus の `onKeyEvent` で一括処理する。
            // TextField にフォーカスがある時は TextField が EditableText 内で
            // 先にキーイベントを消費するので、 親 Focus には届かず、
            // 「TextField で Backspace = 文字削除」 が壊れない。
            Expanded(
              child: memos.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          provider.t('googleSearch.savedMemosEmpty'),
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: memos.length,
                      itemBuilder: (_, i) => _buildMemoCard(provider, memos[i]),
                    ),
            ),
          ],
          // ノード編集モードでは「追加して閉じる」 ボタンを最下部に
          if (isNodeEdit) ...[
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () => _addEditorToMap(keepOpen: false),
              icon: const Icon(Icons.check_rounded, size: 18),
              label: Text(provider.t('googleSearch.addAndClose')),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MindMapProvider>();
    final mq = MediaQuery.of(context);
    final useHorizontal = _isDesktop ||
        mq.orientation == Orientation.landscape ||
        mq.size.width >= 700;
    // ── ツールバーのボタン配置を実ウィンドウ幅で出し分ける (= ユーザー要望:
    //    小さい検索窓でボタンが重なる / 左右分割ボタンが入り切らない対策) ──
    // フローティング時は windowWidth、 それ以外は画面幅で判定。 狭いときは
    //   左右分割を 1 ボタンに集約し、 入り切る幅になったら 2 ボタンに分ける。
    final toolbarW = widget.windowWidth ?? mq.size.width;
    final showTwoSplit = toolbarW >= 440;

    // ── キーボードショートカットの方式 ──
    // Del / Backspace / Ctrl+A / Ctrl+Z は **HardwareKeyboard.addHandler**
    // (initState で登録、 dispose で解除) で扱う。 WebView がフォーカスを
    // 持っていても確実にイベントが届くため。
    //
    // 一方、 Esc / Ctrl+Enter / Ctrl+S は CallbackShortcuts で扱う:
    // これらは TextField 入力中にも発火させたい (= 「メモ書きながら Ctrl+S
    // で保存」 のような操作)。 TextField 内でも CallbackShortcuts は機能
    // するので問題なし。 Esc は CallbackShortcuts でメモ選択解除 / 閉じる
    // の文脈分岐をハンドル。
    // ── 戻るジェスチャー傍受 (= ユーザー要望: google 検索で戻るジェスチャーを
    //    すると検索画面自体が閉じてしまう → 手前のページに戻るようにして) ──
    // canPop:false で OS のデフォルト pop を常に抑止し、 onPopInvoked で
    //   「WebView がまだ戻れるなら履歴を 1 つ戻す / 戻れないなら画面を閉じる」
    //   を判定する。 canGoBack() を都度取り直すのでタブ切替後もズレない。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // デスクトップは戻るジェスチャーが無い (= 主にダイアログの閉じる動作)。
        if (_isDesktop) {
          _closeSelf();
          return;
        }
        bool canBack = _webCanGoBack;
        try {
          canBack = await _iawCtrl?.canGoBack() ?? false;
        } catch (_) {}
        if (!mounted) return;
        if (canBack) {
          // 手前のページへ戻る (= 検索画面は閉じない)。
          _navBack();
          _refreshWebCanGoBack();
        } else {
          // 履歴の先頭 → 通常通り検索画面を閉じる。
          _closeSelf();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_selectedMemoIds.isNotEmpty) {
              setState(() {
                _selectedMemoIds.clear();
                _lastClickedMemoId = null;
              });
            } else {
              _closeSelf();
            }
          },
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
              _addEditorToMap(keepOpen: true),
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              _saveMemo,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: const Color(0xFF121212),
            appBar: AppBar(
              backgroundColor: const Color(0xFF1A1A1A),
              elevation: 0,
              automaticallyImplyLeading: false,
              title: _buildSearchBar(provider),
              titleSpacing: 12,
              toolbarHeight: 56,
              // 上部のタブバー（= ユーザー要望: Google 検索も複数タブ + フォルダー）
              // 小さいウィンドウ (minimalMode) ではスペースが限られるため、 タブバー
              //   ヘッダー自体を表示しない (= ユーザー要望)。 タブ操作は全画面表示に
              //   切り替えるか、 Ctrl+W / Ctrl+Shift+T のショートカットで行える。
              bottom: widget.minimalMode
                  ? null
                  : PreferredSize(
                      preferredSize: const Size.fromHeight(34),
                      child: _buildGsTabBar(),
                    ),
              actions: [
                // ── メモ欄の表示/非表示トグル (横分割時のみ) ──
                // 縦分割 (モバイル) では _buildCollapsibleMemoPanel のヘッダーが
                //   開閉を担うため、 ここでは横分割時のみ出す。
                if (useHorizontal && !widget.minimalMode)
                  IconButton(
                    icon: Icon(
                      _memoSideExpanded
                          ? Icons.sticky_note_2_rounded
                          : Icons.sticky_note_2_outlined,
                      color: const Color(0xFFFFB347),
                      size: 22,
                    ),
                    tooltip: (_memoSideExpanded
                            ? provider.t('gsearch.hideMemo')
                            : provider.t('gsearch.showMemo')) +
                        ' (F3)',
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    onPressed: () =>
                        setState(() => _memoSideExpanded = !_memoSideExpanded),
                  ),
                // ── モバイル: 進む/再読み込み/メモ/保存 を「⋮」 メニューに集約 ──
                // ユーザー要望: モバイルで上部ボタンが被るので、 二次的な操作は
                //   オーバーフローメニューにまとめてボタン数を減らす。
                if (!useHorizontal && !widget.minimalMode)
                  PopupMenuButton<String>(
                    tooltip: 'その他',
                    icon: const Icon(Icons.more_vert_rounded,
                        color: Colors.white, size: 22),
                    color: const Color(0xFF1E1E32),
                    padding: const EdgeInsets.all(6),
                    onSelected: (v) {
                      switch (v) {
                        case 'forward':
                          _navForward();
                          break;
                        case 'reload':
                          _navReload();
                          break;
                        case 'memo':
                          setState(
                              () => _memoPanelExpanded = !_memoPanelExpanded);
                          break;
                        case 'embed':
                          _addPageInfoAsNode();
                          break;
                        case 'bookmark':
                          _addCurrentPageToBookmarks();
                          break;
                        case 'autoCapture':
                          _autoSwipeCaptureToPdf();
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      _gsOverflowItem(
                          'forward', Icons.arrow_forward_rounded, '進む'),
                      _gsOverflowItem('reload', Icons.refresh_rounded, '再読み込み'),
                      _gsOverflowItem('memo', Icons.sticky_note_2_rounded,
                          _memoPanelExpanded ? 'メモ欄を閉じる' : 'メモ欄を開く'),
                      _gsOverflowItem(
                          'embed', Icons.add_link_rounded, 'リンクとして埋め込み'),
                      _gsOverflowItem(
                          'bookmark', Icons.bookmark_add_rounded, 'お気に入りに追加'),
                      // ── 自動スクショ → PDF (= ユーザー要望: 範囲/秒間隔を指定して
                      //    スワイプしながらスクショを撮り 1 つの PDF にまとめる)。
                      //    WebView のスクショ API はモバイル (InAppWebView) のみ。 ──
                      if (!_isDesktop)
                        _gsOverflowItem('autoCapture', Icons.burst_mode_rounded,
                            '自動スクショ → PDF'),
                    ],
                  ),
                // ── AI 欄の開閉トグル (= ユーザー要望: 5 種の AI をサイドで
                //    開けるように) ──
                // 閉じていれば既定 AI で開き、 開いていれば閉じる。
                if (!widget.minimalMode)
                  GestureDetector(
                    // 右クリック (PC) / 長押し (モバイル) で使う AI を切り替える。
                    onSecondaryTapDown: _isDesktop
                        ? (d) => _showAiServicePicker(d.globalPosition)
                        : null,
                    onLongPressStart: _isDesktop
                        ? null
                        : (d) => _showAiServicePicker(d.globalPosition),
                    child: IconButton(
                      icon: Icon(
                        _aiPanelOpen
                            ? Icons.smart_toy_rounded
                            : Icons.smart_toy_outlined,
                        color: const Color(0xFF4FC3F7),
                        size: 22,
                      ),
                      tooltip: (_aiPanelOpen ? 'AI 欄を閉じる' : 'AI 欄を開く') +
                          ' (F4)\n' +
                          (_isDesktop ? '右クリックで AI 切替' : '長押しで AI 切替'),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        if (_aiPanelOpen) {
                          setState(() => _aiPanelOpen = false);
                        } else {
                          _openAiPanel(_aiDefaultId);
                        }
                      },
                    ),
                  ),
                // ── このページの内容を AI に共有 (= ユーザー要望: Chrome の Gemini
                //    タブ共有のように、 表示中の検索結果を AI に渡して質問できる) ──
                if (!widget.minimalMode)
                  IconButton(
                    icon: const Icon(Icons.ios_share_rounded,
                        color: Color(0xFF4FC3F7), size: 20),
                    tooltip: '表示中のページの内容を AI に共有して質問',
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    onPressed: _shareSearchPageWithAi,
                  ),
                // ── 動画の再生速度 (= ユーザー要望: Google 検索で出てきた埋め込み
                //    動画の再生速度を変えられるように) ──
                if (!widget.minimalMode)
                  PopupMenuButton<double>(
                    tooltip: '動画の再生速度',
                    icon: Icon(
                      _searchVideoRate == 1.0
                          ? Icons.speed_rounded
                          : Icons.slow_motion_video_rounded,
                      color: const Color(0xFF4FC3F7),
                      size: 22,
                    ),
                    color: const Color(0xFF1E1E32),
                    padding: const EdgeInsets.all(6),
                    onSelected: (r) {
                      setState(() => _searchVideoRate = r);
                      _applySearchVideoRate(r);
                    },
                    itemBuilder: (_) => [
                      // 0.5 倍速刻みで 1.0〜4.0 倍まで (= ユーザー要望: 1 倍未満は出さない)。
                      for (final r in const [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0])
                        PopupMenuItem<double>(
                          value: r,
                          height: 38,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(
                              r == _searchVideoRate
                                  ? Icons.check_rounded
                                  : Icons.speed_rounded,
                              size: 16,
                              color: const Color(0xFF4FC3F7),
                            ),
                            const SizedBox(width: 8),
                            Text('${r}x',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13)),
                          ]),
                        ),
                    ],
                  ),
                // ── DeepL を側パネルで開く (= ユーザー要望: PC のみ搭載。
                //    モバイルはスペースが無いので非表示) ──
                if (!widget.minimalMode && useHorizontal)
                  IconButton(
                    icon: const Icon(Icons.translate_rounded,
                        color: Color(0xFF0F73B8), size: 22),
                    tooltip: 'DeepL を開く',
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    onPressed: _openDeepLPanel,
                  ),
                // ── 画面分割で開く ──
                // ユーザー要望: モバイルは 1 ボタンに統合して「上分割」 のみにする
                //   (= 分割した先のパネルで上下を入れ替えられるため)。 PC は左右
                //   分割を別々のボタンで残す。
                if (widget.onMoveToSplitPanel != null) ...[
                  if (showTwoSplit) ...[
                    IconButton(
                      icon: const Icon(Icons.splitscreen_rounded,
                          color: Color(0xFF43B97F), size: 22),
                      tooltip: provider.t('gsearch.splitLeft'),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        widget.onMoveToSplitPanel!(_currentUrl,
                            isLeftPanel: true);
                        _closeSelf();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.splitscreen_rounded,
                          color: Color(0xFF6C63FF), size: 22),
                      tooltip: provider.t('gsearch.splitRight'),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        widget.onMoveToSplitPanel!(_currentUrl);
                        _closeSelf();
                      },
                    ),
                  ] else
                    // 狭いとき: 1 ボタンに集約。 分割先パネルで左右/上下を入れ替え可。
                    IconButton(
                      icon: const Icon(Icons.splitscreen_rounded,
                          color: Color(0xFF43B97F), size: 22),
                      tooltip: '分割して開く',
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        widget.onMoveToSplitPanel!(_currentUrl,
                            isLeftPanel: true);
                        _closeSelf();
                      },
                    ),
                ],
                // ── 「全画面表示」 ボタン (minimalMode 時のみ) ──
                // ユーザー要望「全画面表示を押したら今の様なメモ欄アリの画面が
                //   出てくるようにして」 への対応。 minimalMode を抜けて
                //   compactMode (= メモ欄付きの大きい画面) で開き直す。
                //   現在の URL / 検索クエリ / メモを引き継いで遷移。
                if (widget.minimalMode && widget.onExpandToCompact != null)
                  IconButton(
                    icon: const Icon(Icons.fullscreen_rounded,
                        color: Colors.white, size: 22),
                    tooltip: provider.t('gsearch.fullscreen'),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      widget.onExpandToCompact!(
                        _currentUrl,
                        _searchCtrl.text,
                        _memoCtrl.text,
                      );
                    },
                  ),
                // ── 閉じるボタン (右上) ──
                // ユーザー要望により、 左上ではなく右上に配置 (= マウスカーソルで
                // 右上の X ボタンが反射的にクリックできる位置)。
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: Colors.white, size: 22),
                  tooltip: provider.t('btn.close'),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                  onPressed: () => _closeSelf(),
                ),
              ],
            ),
            body: useHorizontal
                ? Row(
                    children: [
                      // ── 左パネル (既定=メモ、 入れ替え時=AI) ──
                      // ユーザー要望: メモと AI が同じ方向に出ないように。
                      //   既定では F3 でメモが「左」、 F4 で AI が「右」 に出る。
                      ..._horizontalLeftPanel(provider),
                      Expanded(flex: 3, child: _buildWebView()),
                      // ── 右パネル (既定=AI、 入れ替え時=メモ) ──
                      ..._horizontalRightPanel(provider),
                    ],
                  )
                : Column(
                    children: [
                      // ── メモ欄を上に置く設定なら WebView の前に出す
                      //    (= ユーザー要望: メモ項目を別の場所に移動できるように) ──
                      if (!widget.minimalMode && _memoPanelOnTop)
                        _buildCollapsibleMemoPanel(provider),
                      Expanded(child: _buildWebView()),
                      // minimalMode 時はメモパネル非表示 (= WebView だけが表示)
                      if (!widget.minimalMode && !_memoPanelOnTop)
                        _buildCollapsibleMemoPanel(provider),
                      // ── AI 欄 (= モバイルでは下端に固定高さで表示) ──
                      if (!widget.minimalMode && _aiPanelOpen)
                        _buildMobileAiPanel(provider),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  /// 縦分割 (= モバイル想定) 時の折り畳み式メモパネル。
  /// 閉じている時: ヘッダーバー (高さ 42px) のみ表示。
  /// 開いている時: ヘッダー + 既存メモパネル (高さ 380px)。
  Widget _buildCollapsibleMemoPanel(MindMapProvider provider) {
    // ── ユーザー要望: 下端に常駐する「メモを開く」 ヘッダーバーが目障り ──
    // 閉じている間は何も表示せず (= バーを出さない)、 開閉は上部ツールバーの
    // メモボタンで行う。 開いている時だけメモパネル (ヘッダー + 中身) を出す。
    if (!_memoPanelExpanded) return const SizedBox.shrink();
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: SizedBox(
        height: _memoPanelExpanded ? 380 : 42,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── ヘッダー (タップで開閉) ──
            InkWell(
              onTap: () =>
                  setState(() => _memoPanelExpanded = !_memoPanelExpanded),
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A24),
                  border: Border(
                    top:
                        BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _memoPanelExpanded
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_up_rounded,
                      color: const Color(0xFFFFB347),
                      size: 22,
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.sticky_note_2_rounded,
                        color: Color(0xFFFFB347), size: 18),
                    const SizedBox(width: 8),
                    Text(
                      _memoPanelExpanded ? 'メモ' : 'メモを開く',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    // ── メモ欄を上 / 下へ移動 (= ユーザー要望: 邪魔なときに
                    //    別の場所に移動できるように) ──
                    IconButton(
                      icon: Icon(
                        _memoPanelOnTop
                            ? Icons.vertical_align_bottom_rounded
                            : Icons.vertical_align_top_rounded,
                        color: const Color(0xFFFFB347),
                        size: 20,
                      ),
                      tooltip: _memoPanelOnTop ? 'メモ欄を下に移動' : 'メモ欄を上に移動',
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(),
                      onPressed: () =>
                          setState(() => _memoPanelOnTop = !_memoPanelOnTop),
                    ),
                    // ── × 閉じる (= ユーザー要望: 「メモを閉じる」 は分かり
                    //    にくいので × ボタンにする) ──
                    if (_memoPanelExpanded)
                      IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white70, size: 20),
                        tooltip: 'メモを閉じる',
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(6),
                        constraints: const BoxConstraints(),
                        onPressed: () =>
                            setState(() => _memoPanelExpanded = false),
                      ),
                  ],
                ),
              ),
            ),
            // ── 中身 (= 開いてる時のみ) ──
            if (_memoPanelExpanded) Expanded(child: _buildMemoPanel(provider)),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _draftSaveDebounce?.cancel();
    if (_useDraft) {
      context.read<MindMapProvider>().setGoogleSearchMemoDraft(_memoCtrl.text);
    }
    _searchCtrl.dispose();
    _memoCtrl.dispose();
    _searchFocus.dispose();
    _memoFocus.dispose();
    // グローバルキーボードハンドラを必ず解除する。
    // 解除し忘れると、 ダイアログを閉じた後も古いコールバックが呼ばれて
    // `mounted == false` の State にアクセスする例外を発生させる可能性が
    // あるので必須。
    HardwareKeyboard.instance.removeHandler(_globalKeyHandler);
    // 全タブの検索用 WebView を破棄する。
    if (_isDesktop) {
      for (final t in _gsTabs) {
        // ── 閉じても動画の音が止まらない対策 (= ユーザー要望) ──
        // webview_windows は dispose だけだと音声が残ることがあるので、
        // 破棄前に video/audio を pause + src クリアして about:blank へ飛ばす。
        try {
          t.winCtrl?.executeScript(
              'try{document.querySelectorAll("video,audio").forEach(function(v){try{v.pause();v.muted=true;v.removeAttribute("src");if(v.load)v.load();}catch(e){}});}catch(e){}');
          t.winCtrl?.loadUrl('about:blank');
        } catch (_) {}
        try {
          t.winCtrl?.dispose();
        } catch (_) {}
      }
    } else {
      // モバイル: keepAlive の WebView を解放してリークを防ぐ。
      for (final t in _gsTabs) {
        try {
          iaw.InAppWebViewController.disposeKeepAlive(t.iawKeepAlive);
        } catch (_) {}
      }
    }
    if (_isDesktop && _aiWinInitialized) {
      try {
        _aiWinCtrl.executeScript(
            'try{document.querySelectorAll("video,audio").forEach(function(v){try{v.pause();v.muted=true;}catch(e){}});}catch(e){}');
        _aiWinCtrl.loadUrl('about:blank');
      } catch (_) {}
      _aiWinCtrl.dispose();
    }
    super.dispose();
  }
}

// ════════════════════════════════════════════════════════════════════════
//  Google 検索 ブックマーク 永続化
// ════════════════════════════════════════════════════════════════════════
//
// SharedPreferences に JSON 配列として保存。 1 エントリ = URL + タイトル。
// 上限は 50 件 (= 古いものから自動削除)。

class _BookmarkItem {
  final String url;
  final String title;
  final int savedAtMs;

  /// ユーザーがカスタマイズした表示名。 空文字なら title をそのまま使う。
  /// ヘッダー/フッターのお気に入り N ボタンに表示される。
  final String customLabel;

  /// ユーザーが選択したアイコンの IconData.codePoint。 0 ならデフォルト
  /// (= Icons.bookmark_rounded) を使う。
  /// 注: tree-shaking 対策で fontFamily も保存。
  final int customIconCode;
  final String customIconFontFamily;
  const _BookmarkItem({
    required this.url,
    required this.title,
    required this.savedAtMs,
    this.customLabel = '',
    this.customIconCode = 0,
    this.customIconFontFamily = '',
  });
  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'savedAt': savedAtMs,
        'customLabel': customLabel,
        'customIconCode': customIconCode,
        'customIconFontFamily': customIconFontFamily,
      };
  factory _BookmarkItem.fromJson(Map<String, dynamic> j) => _BookmarkItem(
        url: (j['url'] as String?) ?? '',
        title: (j['title'] as String?) ?? '',
        savedAtMs: (j['savedAt'] as int?) ?? 0,
        customLabel: (j['customLabel'] as String?) ?? '',
        customIconCode: (j['customIconCode'] as int?) ?? 0,
        customIconFontFamily: (j['customIconFontFamily'] as String?) ?? '',
      );

  _BookmarkItem copyWith({
    String? url,
    String? title,
    int? savedAtMs,
    String? customLabel,
    int? customIconCode,
    String? customIconFontFamily,
  }) =>
      _BookmarkItem(
        url: url ?? this.url,
        title: title ?? this.title,
        savedAtMs: savedAtMs ?? this.savedAtMs,
        customLabel: customLabel ?? this.customLabel,
        customIconCode: customIconCode ?? this.customIconCode,
        customIconFontFamily: customIconFontFamily ?? this.customIconFontFamily,
      );

  /// 表示名: customLabel があればそれを優先、 なければ title。
  String get displayLabel => customLabel.isNotEmpty ? customLabel : title;
}

/// タブの「フォルダー（保存グループ・ブックマーク風）」を永続化する共有ストア。
/// YouTube ビューア（_WindowsWebViewSheet）と Google 検索の両方から使う
/// (= ユーザー要望: フォルダーにタブを格納)。
/// 形式: { "フォルダー名": [ {"url":.., "title":..}, ... ], ... }
class TabFolderStore {
  static const String _kKey = 'mokumoku_tab_folders_v1';

  static Future<Map<String, List<Map<String, String>>>> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kKey);
      if (raw == null || raw.isEmpty) return {};
      final m = jsonDecode(raw);
      if (m is! Map) return {};
      final out = <String, List<Map<String, String>>>{};
      m.forEach((k, v) {
        if (v is List) {
          out[k.toString()] = v
              .whereType<Map>()
              .map((e) => {
                    'url': (e['url'] ?? '').toString(),
                    'title': (e['title'] ?? '').toString(),
                  })
              .where((e) => (e['url'] ?? '').isNotEmpty)
              .toList();
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(
      Map<String, List<Map<String, String>>> folders) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kKey, jsonEncode(folders));
    } catch (_) {}
  }
}

/// Google 検索の 1 タブ分の状態（URL / ページ名）。
class _GsTab {
  String url;
  String title;
  // ── タブごとに独立した検索用 WebView (= ユーザー要望: タブを切り替えても
  //    再読み込みされないように。 IndexedStack で全タブを生かしておく) ──
  // デスクトップ (webview_windows)
  wv_win.WebviewController? winCtrl;
  bool winReady = false; // initialize 完了
  bool winInitStarted = false; // initialize 起動済み (二重起動防止)
  String? winError;
  // モバイル (flutter_inappwebview)。 keepAlive で切替時の状態を保持する。
  iaw.InAppWebViewController? iawCtrl;
  final iaw.InAppWebViewKeepAlive iawKeepAlive = iaw.InAppWebViewKeepAlive();
  _GsTab({required this.url, this.title = ''});
}

/// 検索 WebView のホイール感度を下げる (= ユーザー要望: ノードから開いた
/// Google 検索のマウスホイールが速すぎるので、 もう少し小さくする)。
/// wheel を capture で横取りして preventDefault し、 縮小した量で手動スクロール。
const String _kGsWheelTameJs = r'''
(function(){
  if (window.__mmWheelTamed) return;
  window.__mmWheelTamed = true;
  var FACTOR = 0.45; // 感度 (1.0 = ブラウザ標準)
  window.addEventListener('wheel', function(e){
    if (e.ctrlKey) return;            // Ctrl+ホイールのズームはそのまま
    if (e.defaultPrevented) return;
    e.preventDefault();
    var dy = e.deltaY * FACTOR;
    var dx = e.deltaX * FACTOR;
    var el = e.target;
    while (el && el.nodeType === 1 &&
           el !== document.body && el !== document.documentElement) {
      var st = window.getComputedStyle(el);
      if (((st.overflowY === 'auto' || st.overflowY === 'scroll') &&
           el.scrollHeight > el.clientHeight) ||
          ((st.overflowX === 'auto' || st.overflowX === 'scroll') &&
           el.scrollWidth > el.clientWidth)) {
        el.scrollTop += dy; el.scrollLeft += dx; return;
      }
      el = el.parentElement;
    }
    window.scrollBy(dx, dy);
  }, { passive: false, capture: true });
})();
''';

/// webview_windows のドキュメント生成時に注入し、 リンクの Ctrl/⌘+クリック・
/// 中クリックを捕まえて既定の遷移を止め、 URL を Flutter 側へ postMessage する
/// (= ユーザー要望: 検索中に Ctrl+クリックで新しいタブ)。
const String _kGsCtrlClickInterceptorJs = r'''
(function(){
  if (window.__mmGsCtrlClickHook) return;
  window.__mmGsCtrlClickHook = true;
  function send(href){
    try { window.chrome.webview.postMessage(JSON.stringify({t:'ctrlclick', url: href})); } catch(e){}
  }
  function anchorFrom(e){
    var n = e.target;
    while (n && n !== document) {
      if (n.tagName && n.tagName.toLowerCase() === 'a' && n.href) return n;
      n = n.parentNode;
    }
    return null;
  }
  function handle(e, isAux){
    if (isAux && e.button !== 1) return;
    var a = anchorFrom(e);
    if (!a) return;
    var ctrlish = e.ctrlKey || e.metaKey;
    var mid = isAux && e.button === 1;
    var tgt = (a.getAttribute('target') || a.target || '');
    var blank = (tgt === '_blank');
    // Ctrl/中クリック、 または target=_blank (= 普通のブラウザで新しいタブが
    //   開かれるリンク・広告等) のときだけ新しいタブで開く。
    if (!ctrlish && !mid && !blank) return;
    var href = a.href;
    if (!href || href.indexOf('javascript:') === 0) return;
    e.preventDefault(); e.stopPropagation();
    send(href);
  }
  document.addEventListener('click', function(e){ handle(e, false); }, true);
  document.addEventListener('auxclick', function(e){ handle(e, true); }, true);
  try {
    var _open = window.open;
    window.open = function(url, name, feats){
      try {
        if (name === '_self' || name === '_top' || name === '_parent') {
          return _open ? _open.apply(window, arguments) : null;
        }
        var u = '' + (url || '');
        if (u.indexOf('http://') === 0 || u.indexOf('https://') === 0) {
          send(u);
          return null;
        }
      } catch(e){}
      return _open ? _open.apply(window, arguments) : null;
    };
  } catch(e){}
})();
''';

/// webMessageReceived のメッセージが Ctrl+クリック由来なら URL を返す。
String? _parseGsCtrlClickMessage(dynamic msg) {
  try {
    dynamic data = msg;
    if (data is String) {
      final s = data.trim();
      if (!s.startsWith('{')) return null;
      data = jsonDecode(s);
    }
    if (data is Map && data['t'] == 'ctrlclick') {
      final u = (data['url'] ?? '').toString();
      return u.isEmpty ? null : u;
    }
  } catch (_) {}
  return null;
}

class _GoogleSearchBookmarks {
  static const String _kKey = 'mokumoku_gs_bookmarks_v1';
  static const int _kMax = 50;

  static Future<List<_BookmarkItem>> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kKey);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map((j) => _BookmarkItem.fromJson(j))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> save(List<_BookmarkItem> items) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = jsonEncode(items.map((e) => e.toJson()).toList());
      await sp.setString(_kKey, raw);
    } catch (_) {}
  }

  /// 追加。 既に同じ URL があれば先頭に移動 (= 重複なし)。
  static Future<void> add({
    required String url,
    required String title,
  }) async {
    final items = (await load()).toList();
    items.removeWhere((e) => e.url == url);
    items.insert(
      0,
      _BookmarkItem(
        url: url,
        title: title,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    while (items.length > _kMax) {
      items.removeLast();
    }
    await save(items);
  }

  static Future<void> removeAt(int idx) async {
    final items = (await load()).toList();
    if (idx < 0 || idx >= items.length) return;
    items.removeAt(idx);
    await save(items);
  }

  /// 指定インデックスのブックマークを更新 (= カスタムラベル / アイコン変更用)。
  static Future<void> updateAt(int idx, _BookmarkItem updated) async {
    final items = (await load()).toList();
    if (idx < 0 || idx >= items.length) return;
    items[idx] = updated;
    await save(items);
  }

  static Future<void> clear() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kKey);
    } catch (_) {}
  }
}
