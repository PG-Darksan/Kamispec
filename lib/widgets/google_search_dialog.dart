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
import 'dart:convert' show base64Decode, jsonEncode, jsonDecode;
import 'dart:io'
    show
        Platform,
        File,
        Directory,
        HttpClient,
        HttpHeaders,
        // メモに貼った画像 / PDF を既定のアプリで開くのに使う。
        Process,
        ProcessStartMode;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;
import 'package:webview_windows/webview_windows.dart' as wv_win;
import '../services/page_extract_js.dart';
import '../services/screen_capture.dart';
import 'auto_clicker.dart';
import 'paywall_hook.dart';
import 'shot_manager_dialog.dart';
import 'web_automation_panel.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
// 自動スクショ → PDF 化 (= ユーザー要望) に使用。
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
// ページ全体を 1 枚の縦長画像に繋げるのに使う (= ユーザー要望)。
import 'package:image/image.dart' as img;

import '../providers/mind_map_provider.dart';
import 'node_widget.dart' show NodeWidget;
import '../utils/embedded_oauth_guard.dart';
// ★ 絵の拡張子の共通一覧 (jpe / jfif 対応)。
import '../utils/image_file_types.dart';
import '../utils/google_map_pinch_utils.dart';

enum _GSearchSplitIconFill { left, right, top, bottom }

Widget _gSearchSplitIcon(
  _GSearchSplitIconFill fill, {
  required Color color,
  double size = 22,
}) {
  return SizedBox(
    width: size,
    height: size,
    child: CustomPaint(
      painter: _GSearchSplitIconPainter(fill, color),
    ),
  );
}

class _GSearchSplitIconPainter extends CustomPainter {
  const _GSearchSplitIconPainter(this.fill, this.color);

  final _GSearchSplitIconFill fill;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = (size.shortestSide * 0.09).clamp(1.4, 2.2).toDouble();
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: 0.5);
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(strokeWidth),
      Radius.circular(size.shortestSide * 0.18),
    );

    canvas.save();
    canvas.clipRRect(rrect);
    final Rect active;
    switch (fill) {
      case _GSearchSplitIconFill.left:
        active = Rect.fromLTWH(0, 0, size.width / 2, size.height);
        break;
      case _GSearchSplitIconFill.right:
        active = Rect.fromLTWH(size.width / 2, 0, size.width / 2, size.height);
        break;
      case _GSearchSplitIconFill.top:
        active = Rect.fromLTWH(0, 0, size.width, size.height / 2);
        break;
      case _GSearchSplitIconFill.bottom:
        active = Rect.fromLTWH(0, size.height / 2, size.width, size.height / 2);
        break;
    }
    canvas.drawRect(active, fillPaint);
    canvas.restore();

    canvas.drawRRect(rrect, stroke);
    final inset = strokeWidth / 2;
    if (fill == _GSearchSplitIconFill.left ||
        fill == _GSearchSplitIconFill.right) {
      canvas.drawLine(
        Offset(size.width / 2, inset),
        Offset(size.width / 2, size.height - inset),
        stroke,
      );
    } else {
      canvas.drawLine(
        Offset(inset, size.height / 2),
        Offset(size.width - inset, size.height / 2),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GSearchSplitIconPainter oldDelegate) =>
      oldDelegate.fill != fill || oldDelegate.color != color;
}

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
    String initialAiPrompt = '',
    // ignore: avoid_unused_constructor_parameters
    void Function(String url)? onOpenWeb,
    required void Function(String title, String memo, String? linkUrl)
        onAddNode,

    /// 「画面分割で開く」 ボタン押下時、 現在の URL を引数として呼ばれる。
    /// `isLeftPanel: true` で左画面分割、 false (デフォルト) で右画面分割。
    /// null の場合はボタン非表示。
    void Function(String currentUrl, {bool isLeftPanel})? onMoveToSplitPanel,

    /// 「フローティングで開く」 ボタン押下時、 現在の URL を引数として
    /// 呼ばれる (= ユーザー要望: サイトボタンにフローティング機能)。
    /// null の場合はボタン非表示。 デスクトップ専用。
    void Function(String currentUrl)? onFloatRequest,

    /// ★ ボタン押下時に呼ばれる動的ブックマークボタン作成コールバック。
    /// 戻り値: 作成成功なら true、 キャンセル / 失敗なら false。
    /// 未設定 (= null) の場合は従来通り SharedPreferences に直接追加。
    Future<bool> Function(String url, String title)? onCreateBookmarkButton,

    /// コンパクトモード = 画面いっぱいではなく、 中央に小さなダイアログとして
    /// 表示する。 ユーザー要望「ノードから検索を押して立ち上がる google 検索は
    /// 全画面ではなく、 メモから立ち上がる google 検索の様な小さなものにして
    /// 欲しい」 への対応。 「画面分割に切り替え」 ボタンも有効になる。
    bool compactMode = false,

    /// コンパクトモードの大きさを指定する (= ユーザー要望: 規約類は
    /// 設定の枠と同じ大きさで開く)。 null なら今までどおり画面の 9 割。
    Size? dialogSize,

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

    /// 開いた時に自動操作パネルを出す (= ユーザー要望: 「自動化」 を
    /// カスタムボタンとしても使えるように)。
    bool openAutomation = false,

    /// 自動操作の窓だけを出す (= ユーザー要望: 後ろに Google 検索の画面を
    /// 出さない)。 ページを開くまでは中身を透明にしておき、 手順が
    /// ページを開いた時にだけブラウザが姿を見せる。
    bool automationOnly = false,

    /// 上のヘッダー (検索欄と道具の並び) を出さないで開く。
    ///
    /// = ユーザー要望: 設定から公式 Instagram や利用規約へ行く時は、
    ///   ヘッダーの項目が出ないようにして欲しい。
    ///   読むだけの画面なので、 検索欄もタブも要らない。
    ///   代わりに右上へ小さな閉じるボタンだけ出す。
    bool hideAppBar = false,
  }) async {
    // ── 自動操作だけ: 透明な入れ物に載せて、 浮いている窓だけを見せる ──
    if (automationOnly) {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.transparent,
        barrierDismissible: false,
        // 本物の全画面にする (= ユーザー報告: 全画面のはずがフローティングの
        // 様に開き、 透明な幕で他の場所が触れず、 バグの様に見える)。
        // 他の道具 (_openToolDialog) と同じ不透明背景の Dialog.fullscreen。
        builder: (dctx) => Dialog.fullscreen(
          backgroundColor: const Color(0xFF12121C),
          child: _GoogleSearchPage(
            initialQuery: '',
            initialMemo: '',
            customTitle: customTitle,
            onAddNode: onAddNode,
            onMoveToSplitPanel: onMoveToSplitPanel,
            onFloatRequest: onFloatRequest,
            onCreateBookmarkButton: onCreateBookmarkButton,
            openAutomation: true,
            automationOnly: true,
          ),
        ),
      );
      return;
    }
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
                  initialAiPrompt: initialAiPrompt,
                  onAddNode: onAddNode,
                  onMoveToSplitPanel: onMoveToSplitPanel,
                  onFloatRequest: onFloatRequest,
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
                        initialAiPrompt: initialAiPrompt,
                        onAddNode: onAddNode,
                        onMoveToSplitPanel: onMoveToSplitPanel,
                  onFloatRequest: onFloatRequest,
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
            insetPadding: dialogSize == null
                ? EdgeInsets.symmetric(
                    horizontal: size.width * 0.05,
                    vertical: size.height * 0.05,
                  )
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            backgroundColor: Colors.transparent,
            child: SizedBox(
              width: dialogSize?.width ?? size.width * 0.9,
              height: dialogSize?.height ?? size.height * 0.9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _GoogleSearchPage(
                  initialQuery: initialQuery,
                  initialMemo: initialMemo,
                  customTitle: customTitle,
                  initialUrl: initialUrl,
                  initialAiPrompt: initialAiPrompt,
                  onAddNode: onAddNode,
                  onMoveToSplitPanel: onMoveToSplitPanel,
                  onFloatRequest: onFloatRequest,
                  onCreateBookmarkButton: onCreateBookmarkButton,
                  compactMode: true,
                  // ★ 大きさを決めた時は、 中の部品にもその大きさを教える。
                  //   教えないと画面いっぱいの幅で組み立てて、 メモ欄と AI 欄を
                  //   両方開いた時にはみ出す (= 点検で判明)。
                  windowWidth: dialogSize?.width,
                  windowHeight: dialogSize?.height,
                  openAutomation: openAutomation,
                  hideAppBar: hideAppBar,
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
          initialAiPrompt: initialAiPrompt,
          onAddNode: onAddNode,
          onMoveToSplitPanel: onMoveToSplitPanel,
                  onFloatRequest: onFloatRequest,
          onCreateBookmarkButton: onCreateBookmarkButton,
          openAutomation: openAutomation,
          hideAppBar: hideAppBar,
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
  static final Map<String, OverlayEntry> _floatingSingletonEntries =
      <String, OverlayEntry>{};
  static final Map<String, GlobalKey<_GoogleSearchPageState>>
      _floatingSingletonPageKeys =
      <String, GlobalKey<_GoogleSearchPageState>>{};

  /// 指定 singleton の浮遊ウィンドウを root overlay の最前面へ戻す。
  /// 集中ロック画面は復帰時に自分の OverlayEntry を再挿入するため、
  /// ロック中メモから開いた AI / Google が背面へ潜ることがある。
  static void bringFloatingSingletonToFront(
      BuildContext context, String singletonKey) {
    final entry = _floatingSingletonEntries[singletonKey];
    if (entry == null || !entry.mounted) return;
    try {
      final overlay = Overlay.of(context, rootOverlay: true);
      entry.remove();
      overlay.insert(entry);
      _floatingEntries.remove(entry);
      _floatingEntries.add(entry);
    } catch (_) {}
  }

  /// 指定接頭辞の singleton を、現在の重なり順を保って最前面へ戻す。
  /// 集中ロック復帰時はロック自身が root Overlay の先頭へ戻るため、
  /// その直後に `focus_lock_` 系ウィンドウをまとめて上へ積み直す。
  static void bringFloatingSingletonsWithPrefixToFront(
      BuildContext context, String keyPrefix) {
    final targets = _floatingSingletonEntries.entries
        .where((item) => item.key.startsWith(keyPrefix))
        .map((item) => item.value)
        .where((entry) => entry.mounted)
        .toSet();
    if (targets.isEmpty) return;
    final ordered = _floatingEntries.where(targets.contains).toList();
    try {
      final overlay = Overlay.of(context, rootOverlay: true);
      for (final entry in ordered) {
        entry.remove();
        overlay.insert(entry);
      }
    } catch (_) {}
  }

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
    String initialAiPrompt = '',
    required void Function(String title, String memo, String? linkUrl)
        onAddNode,
    void Function(String currentUrl, {bool isLeftPanel})? onMoveToSplitPanel,
    Future<bool> Function(String url, String title)? onCreateBookmarkButton,
    // ── ウィンドウをドラッグして離した位置で埋め込み等を行うコールバック
    //    (= ユーザー要望: 分割画面のところへドラッグしたら埋め込める)。
    //    true を返すとウィンドウを閉じる。 ──
    bool Function(Offset globalPos, String currentUrl)? onDragDrop,
    // ── アプリの外の本物の窓へ出す (= ユーザー要望: 要素から立ち上がる
    //    Google 検索も外に出せるフローティングで開けるように)。
    //    true を返すとこの浮遊窓は閉じる。 null ならボタンを出さない。 ──
    bool Function(String currentUrl)? onPopOut,
    Offset? anchorPos,
    String? singletonKey,
    // 初期ウィンドウサイズの上書き (null = 既定)。 ロック中メモの AI /
    // Google 検索ポップアップは既定より縦を抑えたい (= ユーザー要望) ので
    // 呼び出し側から指定できるようにする。 リサイズは従来どおり可能。
    double? initialWidth,
    double? initialHeight,
    bool hideChromeWhenExpanded = false,
    bool initiallyExpanded = false,
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    if (singletonKey != null) {
      final existingEntry = _floatingSingletonEntries[singletonKey];
      final existingState =
          _floatingSingletonPageKeys[singletonKey]?.currentState;
      if (existingEntry != null && existingState != null) {
        // ── 既存ウィンドウを再利用 (= ユーザー要望: ロック中の「AIに渡す」を
        //    連打しても複数ウィンドウを積まず、 既存の入力欄へ渡す) ──
        // 集中ロック画面はアプリ復帰時に自分の OverlayEntry を最前面へ
        // 再 insert するため、 既存ウィンドウがその裏に隠れている場合がある。
        // remove → insert し直して最前面へ出す (OverlayEntry は内部
        // GlobalKey を持つので、 同一フレーム内の再挿入なら位置・サイズ・
        // WebView の State はそのまま維持される)。
        try {
          if (existingEntry.mounted) {
            existingEntry.remove();
            overlay.insert(existingEntry);
            _floatingEntries.remove(existingEntry);
            _floatingEntries.add(existingEntry);
          }
        } catch (_) {}
        existingState.updateFloatingRequest(
          query: initialQuery,
          memo: initialMemo,
          url: initialUrl,
          aiPrompt: initialAiPrompt,
        );
        return;
      }
      if (existingEntry != null) {
        try {
          existingEntry.remove();
        } catch (_) {}
        _floatingEntries.remove(existingEntry);
        _floatingSingletonEntries.remove(singletonKey);
        _floatingSingletonPageKeys.remove(singletonKey);
      }
    }
    final pageKey = singletonKey == null
        ? null
        : GlobalKey<_GoogleSearchPageState>(
            debugLabel: 'floating_search_$singletonKey');
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
      if (singletonKey != null &&
          _floatingSingletonEntries[singletonKey] == entry) {
        _floatingSingletonEntries.remove(singletonKey);
        _floatingSingletonPageKeys.remove(singletonKey);
      }
    }

    entry = OverlayEntry(
      builder: (ctx) => _FloatingSearchWindow(
        initialQuery: initialQuery,
        initialMemo: initialMemo,
        customTitle: customTitle,
        initialUrl: initialUrl,
        initialAiPrompt: initialAiPrompt,
        initialOffset: cascade,
        anchorPos: anchorPos,
        initialWidth: initialWidth,
        initialHeight: initialHeight,
        hideChromeWhenExpanded: hideChromeWhenExpanded,
        initiallyExpanded: initiallyExpanded,
        pageKey: pageKey,
        onAddNode: onAddNode,
        onMoveToSplitPanel: onMoveToSplitPanel,
        onCreateBookmarkButton: onCreateBookmarkButton,
        onDragDrop: onDragDrop,
        onPopOut: onPopOut,
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
              initialAiPrompt: initialAiPrompt,
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
    if (singletonKey != null) {
      _floatingSingletonEntries[singletonKey] = entry;
      if (pageKey != null) _floatingSingletonPageKeys[singletonKey] = pageKey;
    }
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
  final String initialAiPrompt;
  final void Function(String title, String memo, String? linkUrl) onAddNode;
  final void Function(String currentUrl, {bool isLeftPanel})?
      onMoveToSplitPanel;
  final Future<bool> Function(String url, String title)? onCreateBookmarkButton;

  /// ドラッグ終了時に呼ばれる。 true を返すとウィンドウを閉じる
  /// (= 分割セルへの埋め込み成功など)。
  final bool Function(Offset globalPos, String currentUrl)? onDragDrop;

  /// 「アプリの外の窓へ出す」 (= ユーザー要望)。 true を返すとこの窓を閉じる。
  /// null なら外出しボタンを出さない (= 外の窓を作れない環境)。
  final bool Function(String currentUrl)? onPopOut;
  final VoidCallback onClose;
  final void Function(
          String currentUrl, String currentQuery, String currentMemo)
      onExpandToCompact;

  /// 複数同時表示時に重ならないようズラす初期オフセット (ユーザー要望)。
  final Offset initialOffset;

  /// 指定があれば、 この画面座標 (= ノード付近) にウィンドウを出す
  /// (= ユーザー要望: ノードからの Google 検索はノード付近に出す)。
  final Offset? anchorPos;

  /// 初期サイズの上書き (null = 既定サイズ)。
  final double? initialWidth;
  final double? initialHeight;
  final bool hideChromeWhenExpanded;
  final bool initiallyExpanded;
  final GlobalKey<_GoogleSearchPageState>? pageKey;
  const _FloatingSearchWindow({
    required this.initialQuery,
    required this.initialMemo,
    required this.customTitle,
    required this.initialUrl,
    required this.initialAiPrompt,
    required this.onAddNode,
    required this.onMoveToSplitPanel,
    required this.onCreateBookmarkButton,
    this.onDragDrop,
    this.onPopOut,
    required this.onClose,
    required this.onExpandToCompact,
    this.initialOffset = Offset.zero,
    this.anchorPos,
    this.initialWidth,
    this.initialHeight,
    this.hideChromeWhenExpanded = false,
    this.initiallyExpanded = false,
    this.pageKey,
  });

  @override
  State<_FloatingSearchWindow> createState() => _FloatingSearchWindowState();
}

class _FloatingSearchWindowState extends State<_FloatingSearchWindow> {
  /// ウィンドウ位置 (未配置は dx < 0)。
  ///
  /// ★ 移動のたびに setState で中身 (WebView を含む) ごと作り直すと、
  ///   動かすだけで画面が更新されたように見える (= ユーザー報告: 大きさを
  ///   変えていないのに移動のたびに画面更新が入る)。 位置は ValueNotifier
  ///   にして、 Positioned のオフセットだけを動かす (中身は再ビルドしない)。
  final ValueNotifier<Offset> _posN = ValueNotifier(const Offset(-1, -1));
  Offset get _pos => _posN.value;
  set _pos(Offset v) => _posN.value = v;

  @override
  void dispose() {
    _posN.dispose();
    super.dispose();
  }

  /// ドロップ判定用: 現在 URL を読むためのページキー (singleton 指定が
  /// 無い時も自前で持つ)。
  late final GlobalKey<_GoogleSearchPageState> _pageKeyForDrop =
      widget.pageKey ?? GlobalKey<_GoogleSearchPageState>();

  /// ヘッダードラッグ中の最後のポインタ位置 (ドロップ判定用)。
  Offset? _headerDragGlobal;
  bool _expandedToCompact = false;
  Offset? _expandedCloseButtonPos;
  bool _draggingExpandedCloseButton = false;
  // 既定サイズ。ノード内容から検索した時に少し余裕を持たせる。
  static const double _baseW = 480;
  static const double _baseH = 540;
  // ── ユーザー要望: 境界をドラッグして縦横の大きさを自由に変えられるように ──
  // null = 既定サイズ。 リサイズすると実寸 (px) を保持する。
  double? _userW;
  double? _userH;
  static const double _minW = 240;
  static const double _minH = 260;
  // リサイズ開始時のウィンドウ矩形とポインタ位置 (total-delta 方式で誤差防止)。
  Rect? _resizeStartRect;
  Offset? _resizeStartPointer;

  @override
  void initState() {
    super.initState();
    _expandedToCompact = widget.initiallyExpanded;
  }

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
    final maxW = _expandedToCompact
        ? screen.width
        : math.max(_minW, screen.width - 8);
    final maxH = _expandedToCompact
        ? screen.height
        : math.max(_minH, screen.height - 8);
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
    final maxW = _expandedToCompact
        ? screen.width
        : math.max(_minW, screen.width - 8);
    final maxH = _expandedToCompact
        ? screen.height
        : math.max(_minH, screen.height - 8);
    final double w = (_userW ??
            (_expandedToCompact
                ? screen.width
                : math.min(widget.initialWidth ?? _baseW, screen.width - 16)))
        .clamp(_minW, maxW)
        .toDouble();
    final double h = (_userH ??
            (_expandedToCompact
                ? screen.height
                : math.min(widget.initialHeight ?? _baseH, screen.height - 16)))
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
    final radius = _expandedToCompact ? 0.0 : 14.0;
    final hideExpandedChrome =
        widget.hideChromeWhenExpanded && _expandedToCompact;
    const expandedCloseSize = 48.0;
    final expandedCloseDefault = Offset(
      (screen.width - expandedCloseSize) / 2,
      MediaQuery.of(context).padding.top + 8,
    );
    final expandedClosePos = _expandedCloseButtonPos ?? expandedCloseDefault;
    final expandedCloseLeft = expandedClosePos.dx
        .clamp(8.0, math.max(8.0, screen.width - expandedCloseSize - 8.0));
    final expandedCloseTop = expandedClosePos.dy.clamp(
      MediaQuery.of(context).padding.top + 4,
      math.max(MediaQuery.of(context).padding.top + 4,
          screen.height - expandedCloseSize - 8.0),
    );

    // ── 中身は 1 回だけ作り、 移動 (位置変更) では再ビルドしない ──
    final content = Material(
        type: MaterialType.transparency,
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: const Color(0xFF121212),
            borderRadius: BorderRadius.circular(radius),
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
                if (!hideExpandedChrome)
                  // ── ドラッグ可能なヘッダー ──
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) {
                      if (_expandedToCompact) return;
                      _headerDragGlobal = d.globalPosition;
                      // setState しない: 位置は ValueNotifier 経由で
                      // Positioned だけが動く (= 中身の再ビルドを避けて、
                      // 移動のたびの画面更新を無くす)。
                      final np = _pos + d.delta;
                      _pos = Offset(
                        np.dx.clamp(0.0, maxLeft),
                        np.dy.clamp(0.0, maxTop),
                      );
                    },
                    // ── ドロップ埋め込み (= ユーザー要望: 分割画面の所へ
                    //    ドラッグしたら埋め込めるように)。 ──
                    onPanEnd: (_) {
                      final g = _headerDragGlobal;
                      _headerDragGlobal = null;
                      if (g == null || widget.onDragDrop == null) return;
                      final url =
                          _pageKeyForDrop.currentState?._currentUrl ?? '';
                      if (url.isEmpty) return;
                      if (widget.onDragDrop!(g, url)) widget.onClose();
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
                          // ── アプリの外の本物の窓へ出す (= ユーザー要望:
                          //    要素から立ち上がる Google 検索も、 アプリの外に
                          //    出せるフローティングで開けるように) ──
                          //    出した窓は分割ペインの上に置くと埋め込まれる。
                          if (widget.onPopOut != null)
                            IconButton(
                              icon: const Icon(Icons.open_in_new_rounded,
                                  color: Color(0xFFFFB347), size: 17),
                              tooltip: provider.t('gs.popOut'),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 32, minHeight: 32),
                              onPressed: () {
                                final url =
                                    _pageKeyForDrop.currentState?._currentUrl ??
                                        widget.initialUrl ??
                                        '';
                                if (widget.onPopOut!(url)) widget.onClose();
                              },
                            ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded,
                                color: Colors.white54, size: 18),
                            tooltip: provider.t('btn.close'),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
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
                      key: _pageKeyForDrop,
                      initialQuery: widget.initialQuery,
                      initialMemo: widget.initialMemo,
                      customTitle: widget.customTitle,
                      initialUrl: widget.initialUrl,
                      initialAiPrompt: widget.initialAiPrompt,
                      onAddNode: widget.onAddNode,
                      onMoveToSplitPanel: widget.onMoveToSplitPanel,
                      onCreateBookmarkButton: widget.onCreateBookmarkButton,
                      compactMode: true,
                      minimalMode: !_expandedToCompact,
                      hideAppBar: hideExpandedChrome,
                      onExpandToCompact: (_, __, ___) {
                        setState(() {
                          _expandedToCompact = true;
                          _userW = screen.width;
                          _userH = screen.height;
                          _pos = Offset.zero;
                        });
                      },
                      // フローティングは Overlay 上なので Navigator.pop ではなく
                      // onClose で閉じる。
                      onRequestClose: widget.onClose,
                      // ── ユーザー要望: 小さい検索窓のボタンが重なる対策 ──
                      // ウィンドウ幅を渡してツールバーを幅に応じて切り替える。
                      windowWidth: w,
                      // 自動操作パネルの大きさを窓の実寸に合わせる
                      // (渡さないと画面の高さを基準にして窓からはみ出す)。
                      windowHeight: h,
                    ),
                  ),
                ),
              ],
            ),
            if (hideExpandedChrome)
              Positioned(
                left: expandedCloseLeft.toDouble(),
                top: expandedCloseTop.toDouble(),
                child: MouseRegion(
                  cursor: _draggingExpandedCloseButton
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onClose,
                    onLongPressStart: (details) {
                      setState(() {
                        _draggingExpandedCloseButton = true;
                        _expandedCloseButtonPos = Offset(
                          details.globalPosition.dx - expandedCloseSize / 2,
                          details.globalPosition.dy - expandedCloseSize / 2,
                        );
                      });
                    },
                    onLongPressMoveUpdate: (details) {
                      setState(() {
                        _expandedCloseButtonPos = Offset(
                          details.globalPosition.dx - expandedCloseSize / 2,
                          details.globalPosition.dy - expandedCloseSize / 2,
                        );
                      });
                    },
                    onLongPressEnd: (_) =>
                        setState(() => _draggingExpandedCloseButton = false),
                    child: Material(
                      color: Colors.black.withValues(
                          alpha: _draggingExpandedCloseButton ? 0.68 : 0.48),
                      shape: const CircleBorder(),
                      child: SizedBox(
                        width: expandedCloseSize,
                        height: expandedCloseSize,
                        child: Center(
                          child: Icon(Icons.close_rounded,
                              color: Colors.white, size: 24),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // ── リサイズハンドル (境界ドラッグで縦横を変更) ──
            if (!_expandedToCompact) ..._buildResizeHandles(screen, w, h),
          ]),
        ));
    // 位置の変更 (ドラッグ移動) では Positioned のオフセットだけを更新し、
    // 中身 (WebView 含む) は再ビルドしない (= ユーザー報告: 移動のたびに
    // 画面更新が入る問題の対策)。
    return ValueListenableBuilder<Offset>(
      valueListenable: _posN,
      child: content,
      builder: (context, pos, child) => Positioned(
        left: _expandedToCompact ? 0.0 : pos.dx.clamp(0.0, maxLeft),
        top: _expandedToCompact ? 0.0 : pos.dy.clamp(0.0, maxTop),
        child: child!,
      ),
    );
  }
}

/// 自動操作 (実行フロー) の画面を、 ダイアログ以外の場所 —— アプリ内の
/// フローティング窓や外の別プロセス窓 —— に埋め込むための公開の入り口
/// (= ユーザー要望: フローティングモードで自動操作のフローを外に出したい)。
/// 中身は automationOnly の _GoogleSearchPage そのもの。
class GoogleSearchAutomationHost extends StatelessWidget {
  const GoogleSearchAutomationHost({
    super.key,
    required this.onRequestClose,
    this.hostHasCloseButton = false,
    this.storageKey = '',
  });

  /// 手順の置き場。 空なら道具として開いた時と同じ共通の置き場を使う。
  /// ページとして開く時は、 そのページ専用の鍵を渡す
  /// (= ユーザー要望: 自動操作をページとして設定できるように)。
  final String storageKey;

  /// 「閉じる」 が押された時の処理。 Overlay / 別プロセス窓には pop すべき
  /// route が無いので必須 (Navigator.pop の誤爆防止)。
  final VoidCallback onRequestClose;

  /// 包んでいる側 (浮遊窓の帯など) がすでに閉じるを持っているか。
  /// true なら自分では出さない (= ユーザー要望: × が 2 つあるのを
  /// どちらか一方だけに)。
  final bool hostHasCloseButton;

  @override
  Widget build(BuildContext context) {
    // 窓の実寸を測って渡す (MediaQuery は本体画面の大きさを返すため)。
    return LayoutBuilder(builder: (ctx, cns) {
      return _GoogleSearchPage(
        initialQuery: '',
        initialMemo: '',
        customTitle: null,
        onAddNode: (title, memo, linkUrl) {},
        openAutomation: true,
        automationOnly: true,
        automationStorageKey: storageKey,
        hostHasCloseButton: hostHasCloseButton,
        onRequestClose: onRequestClose,
        windowWidth: cns.maxWidth.isFinite ? cns.maxWidth : null,
        windowHeight: cns.maxHeight.isFinite ? cns.maxHeight : null,
      );
    });
  }
}

class _GoogleSearchPage extends StatefulWidget {
  final String initialQuery;
  final String initialMemo;
  final String? customTitle;

  /// 起動時に直接ロードする URL (= 検索クエリの代わり)。
  final String? initialUrl;
  final String initialAiPrompt;
  final void Function(String title, String memo, String? linkUrl) onAddNode;

  /// 「画面分割で開く」 ボタン押下時、 現在の URL を引数として呼ばれる。
  /// `isLeftPanel: true` なら左パネル、 false (デフォルト) なら右パネルへ。
  /// null の場合はボタン非表示。
  final void Function(String currentUrl, {bool isLeftPanel})?
      onMoveToSplitPanel;

  /// 「フローティングで開く」 ボタン押下時、 現在の URL を引数として呼ばれる。
  /// null の場合はボタン非表示 (= ユーザー要望: サイトボタンにフローティング)。
  final void Function(String currentUrl)? onFloatRequest;

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
  /// フローティング (非モーダル Overlay) 表示の時に指定する。 指定時は
  /// 各種「閉じる」 操作で Navigator.pop の代わりにこのコールバックを呼ぶ
  /// (= Overlay には pop すべき route が無く、 誤って下の画面を pop して
  /// しまうのを防ぐため)。 null の時は従来通り Navigator.pop で閉じる。
  final VoidCallback? onRequestClose;

  /// フローティング表示時の実ウィンドウ幅。 ツールバーのボタンを幅に応じて
  /// レスポンシブに切り替える (= 小窓でボタンが重なるのを防ぐ) のに使う。
  /// null の時は画面幅 (MediaQuery) を使う。
  final double? windowWidth;

  /// フローティング表示時の実ウィンドウ高さ (自動操作パネルの大きさ計算用)。
  /// null の時は画面高さ (MediaQuery) を使う。
  final double? windowHeight;

  /// ロック画面から開いたフローティングを全画面化した時など、上部の検索バー・
  /// タブバー・追加タブ操作を出したくない場合に true。
  final bool hideAppBar;

  /// 自動操作の窓だけを見せるか (= ユーザー要望)。
  final bool automationOnly;

  /// 自動操作の手順の置き場 (空 = 道具として開いた時の共通の置き場)。
  /// ページとして開いた時だけ、 そのページ専用の鍵が入る。
  final String automationStorageKey;

  /// 外側の帯がすでに閉じるを持っているか (= × の重複を避ける)。
  final bool hostHasCloseButton;

  /// 開いた時に自動操作パネルを出すか (= ユーザー要望: 自動化のボタン)。
  final bool openAutomation;

  const _GoogleSearchPage({
    super.key,
    required this.initialQuery,
    required this.initialMemo,
    required this.customTitle,
    this.initialUrl,
    this.initialAiPrompt = '',
    required this.onAddNode,
    this.onMoveToSplitPanel,
    this.onFloatRequest,
    this.onCreateBookmarkButton,
    this.compactMode = false,
    this.minimalMode = false,
    this.openAutomation = false,
    this.automationOnly = false,
    this.automationStorageKey = '',
    this.hostHasCloseButton = false,
    this.onExpandToCompact,
    this.onRequestClose,
    this.windowWidth,
    this.windowHeight,
    this.hideAppBar = false,
  });

  @override
  State<_GoogleSearchPage> createState() => _GoogleSearchPageState();
}

class _GoogleSearchPageState extends State<_GoogleSearchPage> {
  // (openAutomation は initState で _autoPanelOpen に反映する)

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

  // ── タブどうしの分割ビュー (= ユーザー要望「google 検索の分割ビューって
  //    いうのは開いている別のタブと分割して表示するもの」) ──────────────
  //
  //    ★ 本体のページと並べるのではなく、 **この窓の中で 2 つのタブを
  //      並べる**。 デスクトップはもともと全タブの WebView を同時に持って
  //      いる (IndexedStack) ので、 出す所を変えるだけで済む。
  //    ★ モバイルは「複数の keepAlive を同時にマウントすると真っ白になる」
  //      という既知の不具合があるので出さない ([_buildWebViewCore] の覚書)。
  //    ★ = ユーザー要望「3 画面や 2×2 表示もできるように」。 相方 1 枚
  //      (`int? _gsSplitTab`) を **枠の並び** へ広げた。
  /// 枠に出している札の位置。 **枠の並び順** (左上 → 右下) で持つ。
  ///
  /// 空 = 並べていない (全画面)。 長さ 2 = 左右/上下、 3 = 主 1 + 従 2、
  /// 4 = 2×2。
  ///
  /// ★ 決まり (崩れても [_gsPanesResolved] が黙って直す):
  ///   ・重複なし … **1 つの WebviewController を 2 か所へ挿さない**
  ///     (挿すと描画の受け皿 (Texture) を取り合って片方が真っ黒になる)
  ///   ・全部が今ある札 / 今のタブと固定した札は必ず入る
  /// ★ **直接読むのは [_gsPanesResolved] と番号の付け替えだけ**。 他は必ず
  ///   [_gsPanesResolved] 経由で読む (古い値が漏れて別のページが出る事故を
  ///   構造で止める)。
  List<int> _gsPanes = const <int>[];

  /// 並べる向き (true = 上下、 false = 左右)。
  ///
  /// ★ 3 枚の時は「主枠を左に置く (false) / 上に置く (true)」 の意味。
  ///   4 枚 (2×2) では使わない。
  bool _gsSplitVertical = false;

  /// 「今のタブ」 を入れる枠の番号 (0 = 左 / 上)。
  ///
  /// ★ = ユーザー要望「最初に画面分割をする際の並びはタブの順に。 その後は
  ///   切り替えた際にアクティブな側、 もしくは固定されていない側に新規画面が
  ///   来るように」。 並べ始めた時だけ札の順で決め、 それ以降は**枠の位置を
  ///   動かさず**、 中身だけ入れ替える。
  /// ★ 3 枚・4 枚にも広げたので、 元の `bool _gsActiveOnLeft` から枠の番号へ
  ///   変えた (`true` が 0 に当たる)。
  int _gsActiveSlot = 0;

  /// 固定している枠の札の位置 (= ユーザー要望「画面分割したページを右クリック
  /// すると固定することができて、 固定中は固定されていない側の画面が他のタブを
  /// クリックした時に切り替わるように」)。 null = 固定なし。
  ///
  /// ★ 外れていたら効かない物として扱う ([_pinnedPaneIndex])。 こうしておくと、
  ///   どこかで数が食い違っても「固定が効かなくなる」 だけで済み、 別のページが
  ///   出てしまう事故にはならない。
  /// ★ 固定できるのは 1 つだけ (枚数が増えても同じ)。
  int? _gsPinnedTab;

  /// 今ほんとうに効いている固定 (並べていない / 札が消えていたら null)。
  ///
  /// ★ = ユーザー報告「右枠を固定したのに、 新規でタブを開くと右枠が
  ///   切り替わってしまう」。 以前は「今出ている 2 枚のどちらか」 でないと
  ///   効かない事にしていたので、 新しい札を開いて組み合わせが変わった
  ///   瞬間に固定が黙って外れていた。 札が並びに居る限り生きている事にして、
  ///   出す時に**必ず固定した札を片側へ入れる**ようにする。
  int? get _pinnedPaneIndex {
    final p = _gsPinnedTab;
    // ★ ここで [_gsPanesResolved] を呼ばない (無限再帰になる)。
    if (p == null || _gsPanes.length < 2) return null;
    if (p < 0 || p >= _gsTabs.length) return null;
    return p;
  }

  /// 今のタブ (範囲外なら 0 に丸めた物)。
  int get _gsActiveIdx =>
      (_gsActiveTab >= 0 && _gsActiveTab < _gsTabs.length) ? _gsActiveTab : 0;

  /// 今ほんとうに出す枠の中身 (= 出す時と一覧の判定に使う**唯一の入口**)。
  ///
  /// ★ 旧 `_effectiveSplitTab` と同じ考え方。 畑が食い違っていても、 ここで
  ///   「重複なし・今ある札だけ・今のタブと固定した札は必ず入る」 に直してから
  ///   使う。 直しきれなければ「並べるのをやめた」 事にする。 こうしておくと、
  ///   数が食い違っても**別のページが出る事故**にはならない。
  List<int> get _gsPanesResolved {
    if (!_isDesktop || _gsPanes.length < 2 || _gsTabs.length < 2) {
      return const <int>[];
    }
    final out = <int>[];
    for (final t in _gsPanes) {
      if (t < 0 || t >= _gsTabs.length) continue;
      // ★ 同じ札を 2 枠に出さない (描画の取り合いを構造で止める)。
      if (out.contains(t)) continue;
      out.add(t);
    }
    if (out.length < 2) return const <int>[];
    final pin = _gsPinnedTab;
    final hasPin = pin != null && pin >= 0 && pin < _gsTabs.length;
    final pinSlot = hasPin ? out.indexOf(pin) : -1;
    // 「今のタブ」 が枠に無い = 新しい札を開いた直後。 覚えている枠へ入れる
    // (= 枠は動かさず中身だけ差し替える、 という決まりを守るため)。
    if (!out.contains(_gsActiveIdx)) {
      var s = _gsActiveSlot.clamp(0, out.length - 1);
      if (s == pinSlot) {
        // 固定した枠は動かさない (= ユーザー要望)。 次の枠へ回す。
        for (var n = 1; n <= out.length; n++) {
          final c = (s + n) % out.length;
          if (c != pinSlot) {
            s = c;
            break;
          }
        }
      }
      out[s] = _gsActiveIdx;
    }
    // 固定した札が押し出されていたら、 今のタブ以外の枠へ戻す。
    if (hasPin && !out.contains(pin)) {
      final a = out.indexOf(_gsActiveIdx);
      var s = 0;
      for (var n = 0; n < out.length; n++) {
        if (n != a) {
          s = n;
          break;
        }
      }
      out[s] = pin;
    }
    return out;
  }

  /// 新しい札を入れる枠 (= 固定していない枠。 まずは「今のタブ」 の枠)。
  int _gsTargetSlot(List<int> panes) {
    final pin = _pinnedPaneIndex;
    final pinSlot = pin == null ? -1 : panes.indexOf(pin);
    final s = _gsActiveSlot.clamp(0, panes.length - 1);
    if (s != pinSlot) return s;
    for (var n = 1; n <= panes.length; n++) {
      final c = (s + n) % panes.length;
      if (c != pinSlot) return c;
    }
    return s;
  }

  /// 出せる枠の数。
  ///
  /// ★ 2 枚は**広さに関係なく今までどおり出す** (今は広さの制限が無いので、
  ///   ここで絞ると退行になる)。 絞るのは 3 枚以上だけ。
  int _gsMaxPanes(Size area) {
    const minW = 320.0, minH = 240.0;
    if (area.width < minW * 2 + 8 || area.height < minH * 2 + 8) return 2;
    return 4;
  }

  /// 前の組み立てで測った枠置き場の広さ (一覧の出し分けと境界の計算に使う)。
  Size _gsPaneArea = Size.zero;

  Size get _gsPaneAreaOrScreen =>
      (_gsPaneArea.width > 1 && _gsPaneArea.height > 1)
          ? _gsPaneArea
          : MediaQuery.sizeOf(context);

  /// 実際に出す枠 (狭い時は後ろの枠を落とす)。
  ///
  /// ★ 畑 ([_gsPanes]) は削らない。 窓を広げれば 3/4 枚に戻る。
  List<int> _gsPanesVisible(Size area) {
    final all = _gsPanesResolved;
    final max = _gsMaxPanes(area);
    if (all.length <= max) return all;
    final keep = <int>{};
    final a = all.indexOf(_gsActiveIdx);
    if (a >= 0) keep.add(a);
    final pin = _pinnedPaneIndex;
    final p = pin == null ? -1 : all.indexOf(pin);
    if (p >= 0) keep.add(p);
    for (var s = 0; s < all.length && keep.length < max; s++) {
      keep.add(s);
    }
    final slots = keep.toList()..sort();
    return <int>[for (final s in slots.take(max)) all[s]];
  }

  bool _gsTabBarExpanded = false;

  /// ヘッダー (AppBar) を隠しているか (= ユーザー要望: Google 検索の
  /// ヘッダーを非表示にするボタン)。 隠すと本文だけになり、 左上の小さな
  /// 目のボタンで戻せる。
  bool _gsHeaderHidden = false;

  /// ブラウザ側を見せない状態か (= 自動操作だけを出していて、 まだページを
  /// 開いていない間)。 ページを開いたら false になり、 普通に表示される。
  bool get _browserHidden =>
      widget.automationOnly &&
      // ★ 座標を指している間 / 記録している間は必ず見せる。
      //   隠している間はブラウザ側が IgnorePointer で触れないので、
      //   「位置」「終点」 を押しても指す場所が無く、 いつまでも決まらな
      //   かった (= ユーザー報告: スワイプの始点・終点が設定できない)。
      _pickPointCompleter == null &&
      _pickRectCompleter == null &&
      !_autoRecording &&
      // ★ ページを開いた後も、 動かしていない間はブラウザを出さない
      //   (= ユーザー要望: 枠の中に枠があるのが気になる、 フローを
      //   実行する時だけブラウザモードに切り替わる形)。
      //   座標を指す間・記録中・実行中は上の条件で見える。
      !_autoRunning;

  /// ヘッダーを隠している間、 上端にカーソルが乗っているか
  /// (= ユーザー要望: 隠したら、 ホバーするまで戻すボタンも出さない)。
  bool _gsHeaderHover = false;

  /// カーソルのある環境か。 スマホはホバーが無いので、 戻すボタンを
  /// 隠してしまうと二度と戻せなくなる → 常に出す。
  bool get _gsHoverCapable =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  bool _gsMobileToolsExpanded = false;
  bool _webDownloadInProgress = false;
  Timer? _captureNoticeTimer;

  /// お知らせ帯 (MaterialBanner) を出した messenger。 この画面が閉じた後でも
  /// 帯を消せるように掴んでおく。
  ScaffoldMessengerState? _bannerMessenger;
  static const int _kMaxInAppDownloadBytes = 96 * 1024 * 1024;

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
  /// (initialMemo あり) で開いた時だけ initState で展開する。
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
  //    開きたいときはツールバーのメモボタンまたは Ctrl+M で開ける。
  // ※ 縦分割 (モバイル) は _memoPanelExpanded + _buildCollapsibleMemoPanel
  //   が同等の開閉を担うため、 こちらは横分割専用。
  bool _memoSideExpanded = false;

  /// モバイルの分割ボタンの方向 (= ユーザー要望: 長押しで上/下を切り替えて
  /// アイコンも追従)。 false = 上分割 / true = 下分割。
  bool _gsSplitDown = false;

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

  void _beginDesktopMapPinch(_GsTab tab) {
    tab.mapPinchLastScale = 1.0;
    tab.mapPinchLogRemainder = 0.0;
  }

  void _updateDesktopMapPinch(
      _GsTab tab, PointerPanZoomUpdateEvent event) {
    if (!isGoogleMapOrEarthUrl(tab.url) || tab.winCtrl == null) return;
    final currentScale = event.scale.clamp(0.01, 100.0).toDouble();
    final previousScale =
        tab.mapPinchLastScale.clamp(0.01, 100.0).toDouble();
    tab.mapPinchLastScale = currentScale;
    final zoom = accumulateGoogleMapZoomSteps(
      previousScale: previousScale,
      currentScale: currentScale,
      remainder: tab.mapPinchLogRemainder,
    );
    tab.mapPinchLogRemainder = zoom.remainder;
    if (zoom.steps == 0) return;
    _queueDesktopMapZoom(
      tab,
      zoom.steps,
      event.localPosition,
    );
  }

  void _handleDesktopMapPointerSignal(
      _GsTab tab, PointerSignalEvent event) {
    // 一部の Windows Precision Touchpad ドライバーは pinch を
    // PointerPanZoom ではなく Ctrl+trackpad-wheel として送る。
    if (event is! PointerScrollEvent ||
        event.kind != PointerDeviceKind.trackpad ||
        (!HardwareKeyboard.instance.isControlPressed &&
            !HardwareKeyboard.instance.isMetaPressed) ||
        !isGoogleMapOrEarthUrl(tab.url)) {
      return;
    }
    final dy = event.scrollDelta.dy;
    if (!dy.isFinite || dy == 0) return;
    tab.mapPinchSignalRemainder += -dy;
    final steps = (tab.mapPinchSignalRemainder / 60.0)
        .truncate()
        .clamp(-3, 3)
        .toInt();
    if (steps == 0) return;
    tab.mapPinchSignalRemainder -= steps * 60.0;
    _queueDesktopMapZoom(tab, steps, event.localPosition);
  }

  void _queueDesktopMapZoom(_GsTab tab, int steps, Offset localPosition) {
    if (steps == 0 || !isGoogleMapOrEarthUrl(tab.url)) return;
    tab.mapPinchPendingSteps =
        (tab.mapPinchPendingSteps + steps).clamp(-12, 12).toInt();
    tab.mapPinchLocalPosition = localPosition;
    if (!tab.mapPinchDispatching) {
      unawaited(_drainDesktopMapZoom(tab));
    }
  }

  Future<void> _drainDesktopMapZoom(_GsTab tab) async {
    if (tab.mapPinchDispatching) return;
    tab.mapPinchDispatching = true;
    try {
      while (mounted && tab.mapPinchPendingSteps != 0) {
        final controller = tab.winCtrl;
        if (controller == null || !isGoogleMapOrEarthUrl(tab.url)) {
          tab.mapPinchPendingSteps = 0;
          break;
        }

        final batch = tab.mapPinchPendingSteps.clamp(-4, 4).toInt();
        tab.mapPinchPendingSteps -= batch;
        final x = tab.mapPinchLocalPosition.dx
            .clamp(1.0, 100000.0)
            .toStringAsFixed(2);
        final y = tab.mapPinchLocalPosition.dy
            .clamp(1.0, 100000.0)
            .toStringAsFixed(2);
        try {
          await controller.executeScript(_desktopMapZoomScript(batch, x, y));
        } catch (_) {
          tab.mapPinchPendingSteps = 0;
          break;
        }
        // WebGL pages occasionally discard consecutive synchronous clicks.
        await Future<void>.delayed(const Duration(milliseconds: 18));
      }
    } finally {
      tab.mapPinchDispatching = false;
      if (mounted &&
          tab.mapPinchPendingSteps != 0 &&
          isGoogleMapOrEarthUrl(tab.url)) {
        unawaited(_drainDesktopMapZoom(tab));
      }
    }
  }

  String _desktopMapZoomScript(int steps, String x, String y) {
    final count = steps.abs().clamp(1, 4).toInt();
    final zoomIn = steps > 0;
    final wheelDelta = zoomIn ? -100 : 100;
    return '''
(function() {
  try {
    var host = (location.hostname || '').toLowerCase();
    var path = (location.pathname || '').toLowerCase();
    var googleHost = /(^|\\.)google\\.(com|[a-z]{2,3}|co\\.[a-z]{2}|com\\.[a-z]{2})\$/.test(host);
    var first = host.split('.')[0] || '';
    var mapPage = googleHost && (first === 'maps' || first === 'earth' ||
                  path === '/maps' || path.indexOf('/maps/') === 0);
    if (!mapPage) return 'wrong-page';

    var zoomIn = ${zoomIn ? 'true' : 'false'};
    var count = $count;
    var selectors = zoomIn
      ? [
          'button[jsaction*="zoomIn" i]',
          '[role="button"][jsaction*="zoomIn" i]',
          '.widget-zoom-in',
          'button[aria-label*="Zoom in" i]',
          'button[title*="Zoom in" i]',
          'button[aria-label*="拡大"]',
          'button[aria-label*="ズームイン"]'
        ]
      : [
          'button[jsaction*="zoomOut" i]',
          '[role="button"][jsaction*="zoomOut" i]',
          '.widget-zoom-out',
          'button[aria-label*="Zoom out" i]',
          'button[title*="Zoom out" i]',
          'button[aria-label*="縮小"]',
          'button[aria-label*="ズームアウト"]'
        ];

    function visible(el) {
      if (!el || el.disabled || el.getAttribute('aria-disabled') === 'true') {
        return false;
      }
      var rect = el.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    }

    // Maps の通常 DOM ならここで即座に見つかる。大きな地図 DOM を毎回
    // 全走査しないため、Shadow DOM 探索より先に高速経路を試す。
    for (var fastIndex = 0; fastIndex < selectors.length; fastIndex++) {
      var fastButton = null;
      try { fastButton = document.querySelector(selectors[fastIndex]); }
      catch (_) {}
      if (visible(fastButton)) {
        for (var fastClick = 0; fastClick < count; fastClick++) {
          fastButton.click();
        }
        return 'button-fast:' + count;
      }
    }

    // Earth のコントロールは Shadow DOM 内に入る版があるため、開いている
    // shadowRoot と同一オリジン iframe も探索する。
    var roots = [document];
    var rootIndex = 0;
    while (rootIndex < roots.length && roots.length < 300) {
      var root = roots[rootIndex++];
      var all;
      try { all = root.querySelectorAll('*'); } catch (_) { all = []; }
      for (var ai = 0; ai < all.length; ai++) {
        if (all[ai].shadowRoot) roots.push(all[ai].shadowRoot);
        if (all[ai].tagName === 'IFRAME') {
          try {
            if (all[ai].contentDocument) roots.push(all[ai].contentDocument);
          } catch (_) {}
        }
      }
    }

    function findButton() {
      for (var ri = 0; ri < roots.length; ri++) {
        for (var si = 0; si < selectors.length; si++) {
          var direct = null;
          try { direct = roots[ri].querySelector(selectors[si]); } catch (_) {}
          if (visible(direct)) return direct;
        }
      }
      var words = zoomIn
        ? ['zoom in', '拡大', 'ズームイン', '放大', '확대', 'acercar',
           'agrandir', 'vergrößern', 'ampliar', 'aproximar', 'приблизить']
        : ['zoom out', '縮小', 'ズームアウト', '缩小', '축소', 'alejar',
           'dézoomer', 'verkleinern', 'reduzir', 'afastar', 'отдалить'];
      for (var rj = 0; rj < roots.length; rj++) {
        var candidates;
        try {
          candidates = roots[rj].querySelectorAll(
            'button,[role="button"],[tabindex="0"]'
          );
        } catch (_) { candidates = []; }
        for (var ci = 0; ci < candidates.length; ci++) {
          var candidate = candidates[ci];
          if (!visible(candidate)) continue;
          var label = [
            candidate.getAttribute('aria-label') || '',
            candidate.getAttribute('title') || '',
            candidate.getAttribute('data-tooltip') || ''
          ].join(' ').toLowerCase();
          for (var wi = 0; wi < words.length; wi++) {
            if (label.indexOf(words[wi]) >= 0) return candidate;
          }
        }
      }
      return null;
    }

    var button = findButton();
    if (button) {
      for (var bi = 0; bi < count; bi++) button.click();
      return 'button:' + count;
    }

    // 最終手段。Maps が DOM wheel を受ける版ではピンチ位置を中心にズームする。
    // ボタンが見つかった場合とは排他的なので二重ズームしない。
    var px = Math.max(1, Math.min(window.innerWidth - 1, $x));
    var py = Math.max(1, Math.min(window.innerHeight - 1, $y));
    var target = document.elementFromPoint(px, py) ||
                 document.querySelector('canvas') ||
                 document.body ||
                 document.documentElement;
    if (!target) return 'no-target';
    for (var ei = 0; ei < count; ei++) {
      target.dispatchEvent(new WheelEvent('wheel', {
        deltaX: 0,
        deltaY: $wheelDelta,
        deltaMode: 0,
        clientX: px,
        clientY: py,
        bubbles: true,
        cancelable: true,
        composed: true
      }));
    }
    return 'wheel:' + count;
  } catch (e) {
    return 'error: ' + e;
  }
})();
''';
  }

  void _endDesktopMapPinch(_GsTab tab) {
    tab.mapPinchLastScale = 1.0;
    tab.mapPinchLogRemainder = 0.0;
  }

  // ── 生成 AI サイドパネル (= ユーザー要望: PDF ビューアと同様に 5 種の AI を
  //    サイドメニューで開いて、 メモを渡したり左右入れ替えたりできるように) ──
  /// AI チャット欄を開いているか。
  bool _aiPanelOpen = false;

  /// 開いている AI の URL (= ChatGPT 等)。 空なら未選択。
  String _aiPanelUrl = '';

  bool get _aiPanelIsDeepL => _aiPanelUrl.toLowerCase().contains('deepl.com');

  /// 今ひらいている AI の名前 (= ユーザー要望: 見出しを「AI」 ではなく、
  /// 開いている LLM の名前にしてほしい)。
  ///
  /// まず URL から見分ける (翻訳の DeepL は id を変えずに URL だけ変わる
  /// ため)。 分からない時は直近に選んだ id の名前を使う。
  String get _aiPanelHeaderLabel {
    final u = _aiPanelUrl.toLowerCase();
    if (u.contains('deepl.com')) return 'DeepL';
    if (u.contains('chatgpt.com') || u.contains('openai.com')) {
      return 'ChatGPT';
    }
    if (u.contains('gemini.google.com')) return 'Gemini';
    if (u.contains('claude.ai')) return 'Claude';
    if (u.contains('deepseek.com')) return 'DeepSeek';
    if (u.contains('grok.com') || u.contains('x.ai')) return 'Grok';
    if (u.contains('perplexity.ai')) return 'Perplexity';
    for (final t in MindMapProvider.browserAiTargets) {
      if (t['id'] == _aiDefaultId) return t['label'] ?? 'AI';
    }
    return 'AI';
  }

  /// 直近に開いた AI の id (= メモを送るときの既定)。
  String _aiDefaultId = 'chatgpt';

  /// Google 検索内の埋め込み動画の再生速度 (= ユーザー要望)。
  double _searchVideoRate = 1.0;

  /// メモを AI 入力欄に渡すときの送信通し番号 (= 二重挿入防止トークン)。
  int _aiInjectSeq = 0;

  /// 注入が 1 回成功した送信の token (= 以降のリトライを打ち切る)。
  /// 旧実装は「古い送信の残リトライ」 と「新しい送信のリトライ」 が
  /// ページ側 token を互いに上書きし合い、 過去の文章が何度も再注入されて
  /// 入力欄が使い物にならなくなるバグがあった (= ユーザー報告)。
  int _aiInjectDoneToken = -1;

  /// メモ欄と AI 欄の左右位置を入れ替えているか (横分割時のみ意味を持つ)。
  ///
  /// ★ = ユーザー要望「メモはデフォルトでは右側に表示されるようにして、
  ///   以後は最後に開いた側に出るように」。 true = メモが右 / AI が左。
  ///   初期値は設定 (`provider.gsMemoOnRight`、 既定は右) から入れ、
  ///   入れ替えるたびに覚える ([_togglePanelsSwapped])。
  bool _panelsSwapped = true;

  /// メモ欄と AI 欄の左右を入れ替えて、 その向きを覚える。
  void _togglePanelsSwapped() {
    final next = !_panelsSwapped;
    setState(() => _panelsSwapped = next);
    unawaited(context.read<MindMapProvider>().setGsMemoOnRight(next));
  }

  /// AI 欄用 Windows WebView コントローラ (検索用 _winCtrl とは独立)。
  final wv_win.WebviewController _aiWinCtrl = wv_win.WebviewController();
  bool _aiWinInitStarted = false;
  bool _aiWinInitialized = false;
  String? _aiWinInitError;
  bool _aiWinOAuthHandoffInProgress = false;
  DateTime? _aiWinLastOAuthHandoffAt;
  String _aiWinLastSafeServiceUrl = '';

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
      position: RelativeRect.fromLTRB(pos.dx + 6, pos.dy + 6, pos.dx + 6, pos.dy + 6),
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
    if (isSafeExternalServiceUrl(url)) {
      _aiWinLastSafeServiceUrl = url;
    }
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
      // 未生成 (初回) の時は InAppWebView の initialUrlRequest で開く。
      try {
        _aiIawCtrl?.loadUrl(urlRequest: iaw.URLRequest(url: iaw.WebUri(url)));
      } catch (_) {}
    }
  }

  /// AI 欄用 Windows WebView を初期化して URL をロード。
  Future<void> _initAiWinWebView(String url) async {
    try {
      await _aiWinCtrl.initialize();
      try {
        await _aiWinCtrl
            .setPopupWindowPolicy(wv_win.WebviewPopupWindowPolicy.sameWindow);
      } catch (_) {}
      // ── AI チャット欄をマウスホイールでスクロールできるように (= ユーザー
      //    要望) ──。 AI サイトは内側のスクロールコンテナを使うため
      //    webview_windows のネイティブホイールでは動かないことがある。 検索
      //    タブと同じ wheel-tamer を注入して直下のスクロール可能要素を動かす。
      try {
        await _aiWinCtrl.addScriptToExecuteOnDocumentCreated(_kGsWheelTameJs);
        await _aiWinCtrl
            .addScriptToExecuteOnDocumentCreated(_kGsAutoHideScrollbarJs);
      } catch (_) {}
      if (isSafeExternalServiceUrl(url)) {
        _aiWinLastSafeServiceUrl = url;
      }
      _aiWinCtrl.url.listen((currentUrl) {
        if (currentUrl.isEmpty) return;
        if (isBlockedEmbeddedOAuthUrl(currentUrl)) {
          unawaited(_handoffAiOAuthToExternalBrowser());
          return;
        }
        if (isSafeExternalServiceUrl(currentUrl)) {
          _aiWinLastSafeServiceUrl = currentUrl;
        }
      });
      await _aiWinCtrl.loadUrl(url);
      if (mounted) setState(() => _aiWinInitialized = true);
    } catch (e) {
      if (mounted) setState(() => _aiWinInitError = e.toString());
    }
  }

  /// Google 等が埋め込み WebView を拒否した場合は、直前の AI サービスを
  /// 既定ブラウザで開く。WebView 自体も直前ページへ戻し、認証 URL との間で
  /// SourceChanged が発火し続ける状態を止める。
  Future<void> _handoffAiOAuthToExternalBrowser() async {
    if (_aiWinOAuthHandoffInProgress) return;
    final fallback = isSafeExternalServiceUrl(_aiWinLastSafeServiceUrl)
        ? _aiWinLastSafeServiceUrl
        : (isSafeExternalServiceUrl(_aiPanelUrl) ? _aiPanelUrl : '');
    if (fallback.isEmpty) return;

    _aiWinOAuthHandoffInProgress = true;
    try {
      final now = DateTime.now();
      final recentlyOpened = _aiWinLastOAuthHandoffAt != null &&
          now.difference(_aiWinLastOAuthHandoffAt!) <
              const Duration(seconds: 30);
      if (!recentlyOpened) {
        _aiWinLastOAuthHandoffAt = now;
        try {
          await launchUrl(
            Uri.parse(fallback),
            mode: LaunchMode.externalApplication,
          );
          if (mounted) {
            _showCaptureSnack(
              'Googleログインは既定のブラウザで続けてください',
              const Color(0xFF6C63FF),
            );
          }
        } catch (_) {}
      }
      try {
        await _aiWinCtrl.loadUrl(fallback);
      } catch (_) {}
    } finally {
      Future<void>.delayed(const Duration(seconds: 2), () {
        if (mounted) _aiWinOAuthHandoffInProgress = false;
      });
    }
  }

  Future<void> _handoffSearchOAuthToExternalBrowser(
    _GsTab tab,
    wv_win.WebviewController controller,
  ) async {
    if (tab.oauthHandoffInProgress) return;
    final fallback = isSafeExternalServiceUrl(tab.lastSafeServiceUrl)
        ? tab.lastSafeServiceUrl
        : 'https://www.google.com/';

    tab.oauthHandoffInProgress = true;
    try {
      final now = DateTime.now();
      final recentlyOpened = tab.lastOAuthHandoffAt != null &&
          now.difference(tab.lastOAuthHandoffAt!) <
              const Duration(seconds: 30);
      if (!recentlyOpened) {
        tab.lastOAuthHandoffAt = now;
        try {
          await launchUrl(
            Uri.parse(fallback),
            mode: LaunchMode.externalApplication,
          );
          if (mounted) {
            _showCaptureSnack(
              'Googleログインは既定のブラウザで続けてください',
              const Color(0xFF6C63FF),
            );
          }
        } catch (_) {}
      }
      try {
        await controller.loadUrl(fallback);
      } catch (_) {}
    } finally {
      Future<void>.delayed(const Duration(seconds: 2), () {
        tab.oauthHandoffInProgress = false;
      });
    }
  }

  /// メモ本文を AI 入力欄に渡す (= ユーザー要望)。
  /// 1. クリップボードへコピー (フォールバック)
  /// 2. AI 欄が閉じていれば既定 AI で開く
  /// 3. JavaScript で AI 入力欄に改行付きで追加挿入する
  void _sendTextToAi(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.memoEmptyAi'), const Color(0xFFE57373));
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    // ── メインタブ自体が AI サイトなら、 そこへ直接注入する ──
    // ロック中メモの「AIに渡す」は initialUrl で AI サイトをメインタブに
    // 開く。 従来は AI パネル (別 WebView) にだけ注入していたため、 画面に
    // 見えている入力欄には何も入らなかった (= ユーザー報告「用語が渡せて
    // いない」)。 ページ読み込みに時間がかかるためリトライ間隔は長めに取る。
    if (_mainTabIsAiSite) {
      final token = ++_aiInjectSeq;
      for (final ms in const [500, 1600, 3200, 6000, 9000]) {
        Future.delayed(Duration(milliseconds: ms), () {
          // ── 古い送信の残リトライは走らせない ──
          // 新しい送信 / 再オープンが始まったら (token が進む)、 または
          // 1 回注入に成功したら、 以降のリトライは無効。 これをしないと
          // 過去の文章が繰り返し再注入されて入力欄が操作不能になる
          // (= ユーザー報告)。
          if (token != _aiInjectSeq || _aiInjectDoneToken >= token) return;
          _injectTextToAi(text, token, mainWebView: true);
        });
      }
      return;
    }
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
    void guardedInject() {
      if (token != _aiInjectSeq || _aiInjectDoneToken >= token) return;
      _injectTextToAi(text, token);
    }

    Future.delayed(initialDelay, guardedInject);
    Future.delayed(
        initialDelay + const Duration(milliseconds: 1200), guardedInject);
    Future.delayed(
        initialDelay + const Duration(milliseconds: 2800), guardedInject);
    // 「AI 入力欄に追加しました」 の通知は出さない (= ユーザー要望: 鬱陶しい)。
  }

  /// 表示中の検索ページの本文テキストを取得する (= AI へ共有する元データ)。
  /// 検索用 WebView (_winCtrl / _iawCtrl) に対し、 選択範囲があればそれを、
  /// なければ document.body.innerText を取得する (AI 欄用コントローラとは別)。
  /// webview_windows.executeScript / iaw.evaluateJavascript はどちらも値を
  /// デコード済みで返すため、 そのまま文字列化すればよい。 失敗時は空文字。
  Future<String> _readVisibleSearchPageText() async {
    // 先頭の 1 文字で「選んだ所 (S)」 か「ページ全体 (B)」 かを返す
    // (= 選んだ所はそのまま渡し、 全体は要らない時に削れるようにする)。
    const js =
        "(function(){try{var s=(window.getSelection&&window.getSelection().toString())||'';"
        "return (s&&s.trim())?('S'+s):('B'+((document.body&&document.body.innerText)||''));"
        "}catch(e){return '';}})()";
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
    _showCaptureSnack(context.read<MindMapProvider>().t('gs.sharingPageWithAi'),
        const Color(0xFFFFC107));
    final raw = await _readVisibleSearchPageText();
    // 先頭 1 文字が種類 (S = 選んだ所 / B = ページ全体)。
    final isSelection = raw.isNotEmpty && raw[0] == 'S';
    var body = (raw.isEmpty ? '' : raw.substring(1)).trim();

    // ── 相手 (ブラウザ版 AI) が自分で開ける URL なら、 中身は渡さない ──
    //    = ユーザー指摘「URL を渡してあるのに中の要素も全部渡す必要ある?」。
    //    ただし次の場合は AI が開けないので、 今までどおり本文を渡す:
    //      ・検索結果のページ (google.com/search など。 自動取得を弾かれる)
    //      ・ローカルのファイル / 手元だけのアドレス (file:, about:, 家の中)
    final u = _currentUrl.trim();
    final lower = u.toLowerCase();
    final host = Uri.tryParse(u)?.host.toLowerCase() ?? '';
    final fetchable = (lower.startsWith('http://') ||
            lower.startsWith('https://')) &&
        !lower.contains('/search?') &&
        !lower.contains('/search/') &&
        host != 'localhost' &&
        !RegExp(r'^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)')
            .hasMatch(host) &&
        !host.endsWith('.local');

    if (body.isEmpty && !fetchable) {
      _showCaptureSnack(
          context.read<MindMapProvider>().t('gs.pageTextFailed'),
          const Color(0xFFE57373));
      return;
    }

    // 選んだ所はそのまま渡す (それが渡したい物なので)。
    // 自分で開けるページは URL だけ + 念のため冒頭 500 文字。
    // 開けないページは今までどおり本文 (上限 7000 文字)。
    final int maxLen = isSelection
        ? 7000
        : fetchable
            ? 500
            : 7000;
    if (body.length > maxLen) {
      body = '${body.substring(0, maxLen)}\n…(以下省略)';
    }
    final head = '次のWebページの内容について日本語で要約・説明してください。'
        '続けて質問するので把握しておいてください。\n'
        'タイトル: $_pageTitle\nURL: $_currentUrl';
    final prompt = body.isEmpty
        ? '$head\n\n(ページはこの URL を開いて読んでください)'
        : fetchable && !isSelection
            ? '$head\n\n----\n(冒頭だけ載せます。 足りなければ URL を開いて'
                '読んでください)\n$body'
            : '$head\n\n----\n$body';
    _sendTextToAi(prompt);
  }

  /// メモ本文を DeepL 翻訳に渡す (= ユーザー要望)。
  /// AI 側パネルに DeepL を開き、 URL ハッシュにテキストを載せて自動翻訳。
  /// 既定 AI (_aiDefaultId) は変更しない (DeepL は翻訳用)。
  void _sendTextToDeepL(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.memoEmptyDeepl'), const Color(0xFFE57373));
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
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.memoSentDeepl'), const Color(0xFF0F73B8));
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
  /// メインタブに開いた URL が生成 AI サイトかどうか。
  /// (ロック中メモの「AIに渡す」 など、 AI サイト本体をメインタブに開く
  ///  フローでは AI パネルではなくメインタブへ注入する。)
  bool get _mainTabIsAiSite {
    final host = Uri.tryParse(_currentUrl)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    return host.contains('chatgpt.com') ||
        host.contains('chat.openai.com') ||
        host.contains('gemini.google.com') ||
        host.contains('claude.ai') ||
        host.contains('deepseek.com') ||
        host.contains('grok.com');
  }

  Future<void> _injectTextToAi(String text, int token,
      {bool mainWebView = false}) async {
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
      dynamic result;
      if (_isDesktop) {
        if (mainWebView) {
          result = await _winCtrl?.executeScript(js);
        } else {
          result = await _aiWinCtrl.executeScript(js);
        }
      } else {
        result = await (mainWebView ? _iawCtrl : _aiIawCtrl)
            ?.evaluateJavascript(source: js);
      }
      // 注入に成功 (or ページ側で既に注入済み) したら、 この送信の残りの
      // リトライを打ち切る (= 過去の文章が再注入され続けるバグの修正)。
      final s = result?.toString() ?? '';
      if (s.contains('ok-') || s.contains('dup')) {
        if (token > _aiInjectDoneToken) _aiInjectDoneToken = token;
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
    // ★ メモ欄は最後に出していた側へ (= ユーザー要望: 既定は右、 以後は
    //   最後に開いた側)。 読み込みが間に合っていない時は既定 (右) のまま。
    _panelsSwapped = context.read<MindMapProvider>().gsMemoOnRight;
    // 自動操作パネルを開いた状態で出す (= ユーザー要望: 「自動化」 の
    // カスタムボタンから直接開けるように)。
    if (widget.openAutomation) _autoPanelOpen = true;

    // 同意 Cookie を仕込んでから検索 WebView をロードする (Android のみ)。
    //   ★ タイムアウト保険: 万一ハングしても 1.5 秒で WebView を作る
    //   (= 永久スピナーにしない)。
    if (!_isDesktop) {
      // ── 直接サイト起動 (Google マップ/Earth/paiza 等、 initialUrl 指定) は
      //    同意 Cookie の投入完了を待たずに WebView を即生成して立ち上がりを
      //    速くする (= ユーザー要望: Google マップ/Earth の立ち上がりが遅い)。
      //    Cookie はバックグラウンドで引き続き投入する。 Google 検索/ホームは
      //    従来通り投入完了を待つ (= 同意ページへのリダイレクトを避けるため)。 ──
      final bool directSiteOpen =
          (widget.initialUrl ?? '').trim().isNotEmpty;
      if (directSiteOpen) {
        _gsCookiesReady = true;
        _seedGoogleConsentCookies()
            .timeout(const Duration(milliseconds: 1500), onTimeout: () {});
      } else {
        _seedGoogleConsentCookies()
            .timeout(const Duration(milliseconds: 1500), onTimeout: () {})
            .whenComplete(() {
          if (mounted) setState(() => _gsCookiesReady = true);
        });
      }
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
    // メモ欄は既定で閉じる。既存メモの編集 (initialMemo あり) で開いた時だけ
    // 最初から展開しておく (= ユーザー要望: 検索を開いた時はメモ欄を閉じる)。
    _memoExpanded = widget.initialMemo.isNotEmpty;

    if (_useDraft) {
      _memoCtrl.addListener(_scheduleDraftSave);
    }

    final initialAiPrompt = widget.initialAiPrompt.trim();
    if (initialAiPrompt.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _sendTextToAi(initialAiPrompt);
      });
    }

    // ── 初期 URL の決定 ──
    // 優先順位: initialUrl > initialQuery (= 検索) > Google ホーム
    // Qiita 等を直接 WebView で開きたい場合は initialUrl を指定する。
    if (widget.initialUrl != null && widget.initialUrl!.isNotEmpty) {
      _currentUrl = widget.initialUrl!;
    } else if (widget.initialQuery.isNotEmpty) {
      _currentUrl = _buildSearchUrl(widget.initialQuery);
    } else if (widget.openAutomation) {
      // 自動操作のボタンから開いた時は白紙で始める (= ユーザー要望:
      // 後ろで Google 検索まで立ち上がらないように)。 行き先は
      // 自動操作の手順か、 上のアドレス欄から指定する。
      _currentUrl = 'about:blank';
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

  /// どこかの文字入力欄に書き込んでいる最中か。
  ///
  /// TextField の中身は EditableText が持っていて、 入力中はその
  /// フォーカスが一番手前に来る。 それを見れば、 この画面が知らない
  /// 入力欄でも「今は文字を打っている」 と分かる。
  bool get _typingSomewhere {
    final f = FocusManager.instance.primaryFocus;
    final c = f?.context;
    if (c == null) return false;
    if (c.widget is EditableText) return true;
    return c.findAncestorWidgetOfExactType<EditableText>() != null;
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
    // ★ 自分が知っている欄だけでは足りない。
    //
    //   = ユーザー報告「自動化のプロンプト欄で Ctrl+Z を押すと、 文字は
    //   戻っているのに『取り消せる削除がありません』 と出る」。 この画面が
    //   知らない入力欄 (自動化の欄など) にフォーカスがあっても素通りさせる。
    //   文字の取り消しは、 その欄自身が受け持つ。
    if (_typingSomewhere) return false;

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
    // ── Ctrl+M: メモ欄の開閉 ──
    // 既定レイアウトではメモは左側に出る (AI は右側)。
    if (ctrl && key == LogicalKeyboardKey.keyM) {
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
        _togglePanelsSwapped();
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
      // ── 初期化をタイムアウト + 数回リトライで堅牢に (= ユーザー報告:
      //    WebView の所でエラーが出る) ──
      //    多数の WebView を同時に立ち上げると initialize が一時的に失敗
      //    (unsupported_platform 等) する事があり、 一度で諦めると
      //    「WebView2 が無い」 かのように見えてしまう。 少し待って作り直す。
      Object? initErr;
      var ok = false;
      for (var attempt = 0; attempt < 3 && !ok; attempt++) {
        try {
          if (attempt > 0) {
            await Future<void>.delayed(
                Duration(milliseconds: 400 * attempt));
          }
          await ctrl.initialize().timeout(const Duration(seconds: 12));
          ok = true;
        } catch (e) {
          initErr = e;
        }
      }
      if (!ok) throw initErr ?? Exception('WebView init failed');
      // ★ WebView2 の既定の背景は白。 下で入れる CSS がスクロールバーの
      //   溝を透明にしているので、 そのままだと右端に白い柱が残り続ける
      //   (= ユーザー報告: スクロールバーの後ろの白い所が消えない)。
      try {
        await ctrl.setBackgroundColor(const Color(0xFF14141F));
      } catch (_) {}
      // ポップアップ / 新規ウィンドウは現在の WebView 内で開く (広告から戻れる)。
      try {
        await ctrl
            .setPopupWindowPolicy(wv_win.WebviewPopupWindowPolicy.sameWindow);
      } catch (_) {}
      // Ctrl/中クリックだけを新しいタブで開く。target=_blank / window.open は
      // WebView2 に任せ、Google 等の OAuth ポップアップを壊さない。
      try {
        await ctrl
            .addScriptToExecuteOnDocumentCreated(_kGsCtrlClickInterceptorJs);
        // ── 位置情報を渡す (= ユーザー報告: Google マップ / Earth で現在地
        //    が表示されない)。 詳細は provider の geolocationShimJs 参照。 ──
        try {
          final prov = context.read<MindMapProvider>();
          await prov.ensureApproxLocation();
          final geoJs = prov.geolocationShimJs();
          if (geoJs != null) {
            await ctrl.addScriptToExecuteOnDocumentCreated(geoJs);
          }
        } catch (_) {}
      } catch (_) {}
      // ホイール感度を下げる (= ユーザー要望: スクロールが速すぎる)。
      try {
        await ctrl.addScriptToExecuteOnDocumentCreated(_kGsWheelTameJs);
      } catch (_) {}
      // スクロールバーは、 動かした時とバーに触れた時だけ出す
      // (= ユーザー要望: 常時表示をやめる)。
      try {
        await ctrl
            .addScriptToExecuteOnDocumentCreated(_kGsAutoHideScrollbarJs);
      } catch (_) {}
      // ── 広告落とし (= ユーザー要望) ──
      //    ★ **タブごと**に入れる。 _winCtrl (今のタブ) に入れただけでは
      //      後から開いたタブが素通りになる。
      try {
        final adJs = context.read<MindMapProvider>().adBlockInstallJsOrNull();
        if (adJs != null) {
          // ★ 後で切られた時に外せるよう、 登録の id をタブに控える
          //   (= ヘッダーの入切をその場で効かせるため)。
          tab.adScriptId =
              await ctrl.addScriptToExecuteOnDocumentCreated(adJs);
        }
      } catch (_) {}
      // ★ 自動操作から預かっている物があれば、 後から作ったタブにも
      //   入れる (= ページのエラーを拾う仕掛け)。
      final pageJs = _autoPageScript;
      if (pageJs != null && pageJs.isNotEmpty) {
        try {
          await ctrl.addScriptToExecuteOnDocumentCreated(pageJs);
        } catch (_) {}
      }
      ctrl.webMessage.listen((msg) {
        if (!mounted) return;
        final url = _parseGsCtrlClickMessage(msg);
        if (url != null) {
          _openGsTabBackground(url);
          return;
        }
        // ── ページの中で押された Ctrl+W / Ctrl+Shift+T (= ユーザー要望) ──
        //    検索結果に焦点がある間は打鍵が Flutter へ届かないので、
        //    ページから渡してもらう。 中身は `_globalKeyHandler` と同じ。
        final tabKey = _parseGsTabKeyMessage(msg);
        if (tabKey == 'closetab') {
          if (_gsTabs.length <= 1) {
            Navigator.of(context).maybePop();
          } else {
            _closeGsTab(_gsActiveTab);
          }
        } else if (tabKey == 'reopentab') {
          _reopenClosedGsTab();
        }
      });
      ctrl.title.listen((t) {
        if (!mounted) return;
        tab.title = t.isEmpty ? 'Google' : t;
        if (identical(tab, _activeTab)) _pageTitle = tab.title;
        setState(() {});
      });
      ctrl.url.listen((u) {
        if (!mounted) return;
        if (isBlockedEmbeddedOAuthUrl(u)) {
          unawaited(_handoffSearchOAuthToExternalBrowser(tab, ctrl));
          return;
        }
        if (isSafeExternalServiceUrl(u)) {
          tab.lastSafeServiceUrl = u;
        }
        tab.url = u;
        if (identical(tab, _activeTab)) {
          _currentUrl = u;
          // ページ遷移後も選択中の再生速度を維持する。
          if (_searchVideoRate != 1.0) _applySearchVideoRate(_searchVideoRate);
        }
        setState(() {});
      });
      // 初回 URL が認証ページへリダイレクトする場合も取りこぼさないよう、
      // URL 監視を登録してから読み込む。
      await ctrl.loadUrl(tab.url);
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
    _memoAttachments.clear();
    setState(() {});
  }

  /// 「＋新規メモ」 ボタン: エディタを開いて新規入力モードにする。
  void _openNewMemoEditor() {
    _memoCtrl.clear();
    setState(() {
      _editingMemoId = null;
      _memoEditorOpen = true;
      _memoExpanded = true;
      _memoAttachments.clear();
    });
    _memoFocus.requestFocus();
  }

  // ── メモに貼る画像 / PDF (= ユーザー要望: メモにも画像や PDF を残したい) ──
  //    置き場所はアプリの添付フォルダへ写しを取る (元を消しても残るように)。
  final List<String> _memoAttachments = <String>[];

  Future<void> _pickMemoAttachment() async {
    final provider = context.read<MindMapProvider>();
    try {
      final res = await FilePicker.platform.pickFiles(
        dialogTitle: provider.t('gs.memoAttach'),
        type: FileType.custom,
        // ★ 絵の拡張子は共通の一覧から (jpe / jfif も選べる)。
        allowedExtensions: const [...kImagePickerExts, 'pdf'],
        allowMultiple: true,
      );
      if (res == null || !mounted) return;
      final dir = await getApplicationDocumentsDirectory();
      final attachDir = Directory('${dir.path}/attachments');
      if (!await attachDir.exists()) await attachDir.create(recursive: true);
      final added = <String>[];
      for (final f in res.files) {
        final src = f.path;
        if (src == null || src.isEmpty) continue;
        final name = src.split(RegExp(r'[\\/]')).last;
        final dest =
            '${attachDir.path}/memo_${DateTime.now().millisecondsSinceEpoch}_$name';
        try {
          await File(src).copy(dest);
          added.add(dest);
        } catch (_) {
          added.add(src); // 写せない時は元の場所を指す。
        }
      }
      if (!mounted || added.isEmpty) return;
      setState(() => _memoAttachments.addAll(added));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$e'),
        backgroundColor: const Color(0xFFE57373),
        duration: const Duration(seconds: 3),
      ));
    }
  }

  /// 貼った物を既定のアプリで開く。
  Future<void> _openAttachmentFile(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer', [path],
            mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path], mode: ProcessStartMode.detached);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [path],
            mode: ProcessStartMode.detached);
      } else {
        await launchUrl(Uri.file(path));
      }
    } catch (_) {}
  }

  /// 編集欄の下に出す「貼った物」 の一覧。
  Widget _buildMemoAttachmentChips() {
    if (_memoAttachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: [
          for (var i = 0; i < _memoAttachments.length; i++)
            Builder(builder: (_) {
              final p = _memoAttachments[i];
              final name = p.split(RegExp(r'[\\/]')).last;
              final isPdf = name.toLowerCase().endsWith('.pdf');
              return InputChip(
                backgroundColor: const Color(0xFF23233A),
                side: const BorderSide(color: Color(0xFF3A3A55)),
                avatar: isPdf
                    ? const Icon(Icons.picture_as_pdf_rounded,
                        size: 14, color: Color(0xFFE57373))
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Image.file(File(p),
                            width: 18,
                            height: 18,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.image_rounded,
                                size: 14,
                                color: Color(0xFF80CBC4))),
                      ),
                label: Text(
                  name.length > 22 ? '${name.substring(0, 22)}…' : name,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 10.5),
                ),
                // 押すと開いて中身を確かめられる。
                onPressed: () => _openAttachmentFile(p),
                onDeleted: () =>
                    setState(() => _memoAttachments.removeAt(i)),
                deleteIconColor: Colors.white38,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              );
            }),
        ],
      ),
    );
  }

  /// 保存ボタン: 編集モードなら update、 新規なら add。
  /// 完了後は入力欄をクリアして「新規」 状態に戻る。
  Future<void> _saveMemo() async {
    final text = _memoCtrl.text.trim();
    // 添付だけでも残せるようにする (= ユーザー要望: 画像や PDF を貼る)。
    if (text.isEmpty && _memoAttachments.isEmpty) {
      final provider = context.read<MindMapProvider>();
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
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
        attachments: List<String>.from(_memoAttachments),
      );
    } else {
      await provider.addGoogleSearchMemo(GoogleSearchMemo(
        id: 'gs-${DateTime.now().millisecondsSinceEpoch}-${text.hashCode}',
        text: text,
        snapshotUrl: snapshotUrl,
        attachments: List<String>.from(_memoAttachments),
      ));
    }
    // 保存できたのでドラフトはクリア (= 入力欄が空になる)
    if (_useDraft) {
      _draftSaveDebounce?.cancel();
      provider.setGoogleSearchMemoDraft('');
    }
    _resetEditor();
    // ★ = ユーザー要望「メモ欄に追加したり、 削除した時に一々メッセージが
    //   出ないようにして欲しい」。 保存できた事は一覧に行が増える / 入力欄が
    //   空になる事で分かるので、 知らせは出さない。
  }

  /// 既存メモを編集モードでロード。
  void _editSavedMemo(GoogleSearchMemo memo) {
    _memoCtrl.text = memo.text;
    setState(() {
      _editingMemoId = memo.id;
      _memoEditorOpen = true;
      _memoExpanded = true;
      _includeUrl = memo.snapshotUrl != null;
      // 貼ってあった画像 / PDF も編集欄へ戻す。
      _memoAttachments
        ..clear()
        ..addAll(memo.attachments);
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
    // ★ = ユーザー要望「メモを削除しましたのメッセージが消えずに残り続ける」
    //   +「メモ欄に追加したり、 削除した時に一々メッセージが出ないように」。
    //   消えなかったのは知らせが**順番待ちで積まれる**ため (ScaffoldMessenger
    //   は 1 枚ずつ出すので、 3 件消すと 3 秒 × 3 件ぶん出続けて「消えない」
    //   ように見えていた)。 出すのをやめれば両方とも起きない。
    //   取り消しは Ctrl+Z (パソコン) / 一覧の取り消しボタンで今までどおり。
    //   ついでに、 既に出ている知らせが残っていたら畳んでおく。
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  /// Ctrl+Z: 直前の削除を取り消し。
  /// 履歴 Stack の末尾を取り出して Provider に restore する。 履歴が空なら
  /// 控えめに SnackBar で通知。
  void _undoDelete() {
    final provider = context.read<MindMapProvider>();
    if (_deletionHistory.isEmpty) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
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
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
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
      // ★ リンクを含めるかは設定で切り替える (= ユーザー要望)。
      widget.onAddNode(
          title, body, provider.gsMemoEmbedLink ? memo.snapshotUrl : null);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
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
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
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
    final provider = context.read<MindMapProvider>();
    // ★ 入力欄の「URL を含める」 の印と、 埋め込みの設定 (= ユーザー要望)
    //   の**両方**が立っている時だけリンクを付ける。
    final linkUrl =
        (_includeUrl && provider.gsMemoEmbedLink) ? _currentUrl : null;
    widget.onAddNode(title, body, linkUrl);

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
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
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
    final provider = context.read<MindMapProvider>();
    // ★ リンクを含めるかは設定で切り替える (= ユーザー要望)。
    widget.onAddNode(
        title, body, provider.gsMemoEmbedLink ? memo.snapshotUrl : null);
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
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
          tooltip: context.read<MindMapProvider>().t('btn.back'),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(),
          onPressed: _navBack,
        ),
        // 進む / 再読み込みは常に検索バーに置く (= ユーザー要望: 戻る/進む/更新
        //   は格納メニューに入れず、 いつでも押せるように)。 アイコンは小さめ +
        //   詰めた余白で、 狭いモバイルでも重ならず収まるようにする。
        IconButton(
          icon: const Icon(Icons.arrow_forward_rounded,
              color: Colors.white, size: 20),
          tooltip: context.read<MindMapProvider>().t('split.forward'),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(),
          onPressed: _navForward,
        ),
        IconButton(
          icon:
              const Icon(Icons.refresh_rounded, color: Colors.white, size: 20),
          tooltip: context.read<MindMapProvider>().t('player.reload'),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints(),
          onPressed: _navReload,
        ),
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
        // ── 自動操作パネル (= ユーザー要望: 指定箇所のタップ / スワイプ /
        //    ホールドの回数や時間を設定して自動実行、 スクショとの組合せも) ──
        // ── 実行中の停止ボタンは全体ヘッダーに常設する (= ユーザー要望:
        //    スクショのたびに出たり消えたりしないように)。 ここは
        //    キャプチャ範囲 (WebView 部分) の外なので写り込まない。 ──
        if (_autoRunning)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 30),
              ),
              icon: const Icon(Icons.stop_rounded, size: 17),
              label: Text(provider.t('auto.stop'),
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700)),
              onPressed: () => _autoStop?.call(),
            ),
          ),
        // ★ 自動操作の窓は 460px 幅あるので、 小さな浮遊窓には収まらない
        //   (= ユーザー報告: フローティングだと欄が入り切らない)。
        //   全画面で開いている時だけ出す。 浮遊窓からは「全画面表示」 を
        //   押せばこのボタンが現れる。
        if (!widget.minimalMode)
          // ★ = ユーザー要望「google 検索のヘッダーには、 クリック手順ではなく
          //   オートクリッカーのボタン項目を配置して欲しい」。 手順を組む方の
          //   パネルは 自動操作ページ 側に任せ、 ブラウザの帯からはその場で
          //   使うオートクリッカーを出す。
          if (autoClickerSupported)
            IconButton(
              icon: Icon(Icons.ads_click_rounded,
                  color: _autoClickerOpen
                      ? const Color(0xFF80CBC4)
                      : Colors.white,
                  size: 20),
              tooltip: provider.t('hdr.autoClicker'),
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(),
              onPressed: () =>
                  setState(() => _autoClickerOpen = !_autoClickerOpen),
            ),
        // ── ブックマーク追加 / リンク埋め込み ──
        // モバイル (縦) ではここに置くと AI ボタン等と被るので、 横分割時
        //   のみ検索バーに置き、 モバイルでは AppBar の actions 側へ移す
        //   (= ユーザー要望: 被らないように)。
        // minimalMode (= ノードから立ち上げる小さな検索窓) では幅が狭く
        //   ボタンが重なるため非表示にする (= ユーザー要望)。 これらは
        //   「全画面表示」 で開き直した先で利用できる。
        if (_isHorizontalLayout && !widget.minimalMode) ...[
          // ページへ貼る
          _buildEmbedLinkButton(),
          // ★ = ユーザー要望「google 検索にお気に入り登録ボタンがないから
          //   付けて欲しい」。 前は上のボタンと 1 つに束ねてあり、 右クリック
          //   (PC) / 長押し (スマホ) でモードを切り替えないとお気に入りに
          //   入れられなかった。 いつも見えるボタンにする。
          _buildBookmarkAddButton(),
        ],
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
  //       ページ全体を viewport 分ずつスクロールしながら段階キャプチャし、
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
    if (messenger == null) return;
    _captureNoticeTimer?.cancel();
    messenger.clearMaterialBanners();
    messenger.showMaterialBanner(MaterialBanner(
      content: Text(
        msg,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      backgroundColor: bgColor,
      leading: const Icon(Icons.info_outline_rounded, color: Colors.white),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      actions: [
        IconButton(
          tooltip: context.read<MindMapProvider>().t('btn.close'),
          visualDensity: VisualDensity.compact,
          onPressed: () {
            _captureNoticeTimer?.cancel();
            messenger.hideCurrentMaterialBanner();
          },
          icon: const Icon(Icons.close_rounded, color: Colors.white70),
        ),
      ],
    ));
    // ScaffoldMessenger の MaterialBanner は AppBar 直下に表示される。
    // メモ / AI パネルや下部バーの高さに依存せず、必ずそれらより上で
    // ダウンロード結果を確認できる。
    //
    // ★ 3 秒で必ず閉じる (= ユーザー報告: 「ページ情報をマップに追加しま
    //   した」 がいつまでも消えない)。 MaterialBanner は SnackBar と違い
    //   自分では消えないので、 この Timer だけが頼り。 以前は
    //   `if (!mounted) return;` で抜けていたため、 3 秒経つ前にこの画面を
    //   閉じると (= マップに追加した直後に検索を閉じる、 よくある流れ)
    //   消し手が居なくなって出しっぱなしになっていた。 掴んでおいた
    //   messenger を使い、 この画面が生きているかに関係なく消す。
    _bannerMessenger = messenger;
    _captureNoticeTimer = Timer(const Duration(seconds: 3), () {
      try {
        messenger.hideCurrentMaterialBanner();
      } catch (_) {/* messenger が既に無い時は何もしなくてよい */}
    });
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
    _showCaptureSnack(context.read<MindMapProvider>().t('gs.scrollingToBottom'), const Color(0xFF4FC3F7));
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
        _showCaptureSnack(context.read<MindMapProvider>().t('gs.shotFailed'), const Color(0xFFE57373));
        return;
      }
      await _saveScreenshotAsNode(png);
    } catch (e) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.shotGenFailed').replaceFirst('{e}', '$e'), const Color(0xFFE57373));
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
    _showCaptureSnack(context.read<MindMapProvider>().t('gs.capturingFullPage'), const Color(0xFFFFC107));
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
        _showCaptureSnack(context.read<MindMapProvider>().t('gs.pageSizeFailed'), const Color(0xFFE57373));
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
        _showCaptureSnack(context.read<MindMapProvider>().t('gs.shotFailed'), const Color(0xFFE57373));
        return;
      }
      // ── 2. 縦結合 ──
      final combined = await _combineImagesVertically(segments);
      if (combined.isEmpty) {
        _showCaptureSnack(context.read<MindMapProvider>().t('gs.combineFailed'), const Color(0xFFE57373));
        return;
      }
      await _saveScreenshotAsNode(combined);
    } catch (e) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.fullShotFailed').replaceFirst('{e}', '$e'), const Color(0xFFE57373));
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
          title: Row(children: [
            const Icon(Icons.burst_mode_rounded,
                color: Color(0xFF4FC3F7), size: 20),
            const SizedBox(width: 10),
            Expanded(
                child: Text(context.read<MindMapProvider>().t('gs.autoShotPdf'),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 16))),
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
              Text(context.read<MindMapProvider>().t('gs.swipeAmount'),
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12)),
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
              child: Text(context.read<MindMapProvider>().t('btn.cancel'),
                  style: const TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4FC3F7),
                  foregroundColor: Color(0xFF10241F),),
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
              child: Text(context.read<MindMapProvider>().t('gs.start'),
                  style: const TextStyle(color: Colors.black)),
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
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.mobileOnly'), const Color(0xFFE57373));
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
        // スワイプ (= 1 画面分スクロール)
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
        _showCaptureSnack(context.read<MindMapProvider>().t('gs.shotFailed'), const Color(0xFFE57373));
        return;
      }
      await _saveShotsAsPdf(shots);
    } catch (e) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.autoCaptureFailed').replaceFirst('{e}', '$e'), const Color(0xFFE57373));
    }
  }

  /// 撮ったスクショ群を 1 つの PDF にまとめて保存し、 マップに PDF ノードとして
  /// 追加する (= アプリ内 PDF ビューアで開ける)。
  Future<void> _saveShotsAsPdf(List<Uint8List> shots) async {
    _showCaptureSnack(context.read<MindMapProvider>().t('gs.makingPdf'), const Color(0xFFFFC107));
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
          context.read<MindMapProvider>().t('gs.pdfDone').replaceFirst('{n}', '${shots.length}'), const Color(0xFF43B97F));
    } catch (e) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.pdfFailed').replaceFirst('{e}', '$e'), const Color(0xFFE57373));
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

  /// 「いま見ているページをマップへ貼る」 ボタン。
  ///
  /// ★ 以前は下の「お気に入り登録」 と 1 つのボタンに束ねてあり、 PC は
  ///   右クリック / スマホは長押しでモードを切り替える作りだった。
  ///   = ユーザー報告「google 検索にお気に入り登録ボタンがない」。 切り替えに
  ///   気付けないので**別々のボタン**に分けた (押した物がそのまま起きる)。
  Widget _buildEmbedLinkButton() {
    final p = context.read<MindMapProvider>();
    return IconButton(
      // ★ = ユーザー要望「リンクとして埋め込みのボタンがタブ追加と似ている
      //   から別のものに」。 四角に＋の絵柄は右の「＋」 (新しいタブ) と
      //   見分けが付かないので、 「ページへ貼る」 絵柄にする。
      // ★ 押すだけのボタンは白 (= ユーザー要望: 周りに合わせて)。
      icon: const Icon(Icons.note_add_outlined,
          color: Colors.white70, size: 22),
      tooltip: p.t('gs.embedAsLink'),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(),
      onPressed: _addPageInfoAsNode,
    );
  }

  /// 「いま見ているページをお気に入りに登録」 ボタン (= ユーザー要望)。
  ///
  /// 押すと名前 / アイコン / 色を選ぶ窓が出て、 ヘッダーやフッターに置ける
  /// お気に入りボタンになる ([_addCurrentPageToBookmarks])。
  Widget _buildBookmarkAddButton() {
    final p = context.read<MindMapProvider>();
    // ★ = ユーザー要望「お気に入りボタンとして登録の項目は押しやすいように
    //   押したボタンの近くに表示して欲しい」。 登録の窓は本体 (マップの
    //   画面) 側が出すので、 押した所をここで控えて渡す。
    final key = GlobalKey();
    return IconButton(
      key: key,
      // ★ 押すだけのボタンは白 (= ユーザー要望: 周りに合わせて)。
      icon: const Icon(Icons.star_rounded, color: Colors.white70, size: 22),
      tooltip: p.t('gs.addBookmarkBtn'),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(),
      onPressed: () {
        _rememberFavButtonPos(key);
        _addCurrentPageToBookmarks();
      },
    );
  }

  /// お気に入り登録を押した所を控える (窓をその近くに出してもらうため)。
  void _rememberFavButtonPos(GlobalKey key) {
    try {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        gsLastFavButtonPos = box.localToGlobal(box.size.center(Offset.zero));
        return;
      }
    } catch (_) {}
    gsLastFavButtonPos = null;
  }

  /// 再生速度のボタン (押すとスライドバーが出る)。
  ///
  /// ★ = ユーザー要望「再生速度はスライドバー設定の方が嬉しい」。 以前は
  ///   0.5 倍刻みの一覧 (PopupMenu) だったので、 細かく決められず、 押す
  ///   たびに一覧をたどる必要があった。
  /// ★ 色は「等速ではない時」 だけ付ける (= ユーザー要望: オフの時は色を
  ///   消す)。
  Widget _buildVideoRateButton() {
    final on = _searchVideoRate != 1.0;
    return Builder(
      builder: (btnCtx) => IconButton(
        icon: Icon(
          on ? Icons.slow_motion_video_rounded : Icons.speed_rounded,
          color: on ? const Color(0xFF4FC3F7) : Colors.white70,
          size: 22,
        ),
        tooltip: '${context.read<MindMapProvider>().t('gs.videoRate')}'
            ' (${_searchVideoRate.toStringAsFixed(2)}x)',
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(),
        onPressed: () => _showVideoRateSlider(btnCtx),
      ),
    );
  }

  /// 速度のスライドバーを、 押したボタンの下に出す。
  ///
  /// ★ 動かしている間ずっと当て直す (= つまみを放す前から速さが変わるので、
  ///   ちょうど良い所で止められる)。
  Future<void> _showVideoRateSlider(BuildContext btnCtx) async {
    final p = context.read<MindMapProvider>();
    final box = btnCtx.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(btnCtx).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final pos = RelativeRect.fromLTRB(
      topLeft.dx - 150,
      topLeft.dy + box.size.height + 4,
      overlay.size.width - topLeft.dx - box.size.width,
      0,
    );
    await showMenu<void>(
      context: btnCtx,
      position: pos,
      color: const Color(0xFF1E1E32),
      items: <PopupMenuEntry<void>>[
        PopupMenuItem<void>(
          // ★ 押しても閉じない項目にする (= つまみを動かしている最中に
          //   menu が閉じてしまわないように)。 中のスライダーはそのまま
          //   触れる。
          enabled: false,
          height: 56,
          child: StatefulBuilder(
            builder: (_, setM) => SizedBox(
              width: 240,
              child: Row(children: [
                const Icon(Icons.speed_rounded,
                    size: 16, color: Color(0xFF4FC3F7)),
                const SizedBox(width: 6),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF4FC3F7),
                      inactiveTrackColor: Colors.white24,
                      thumbColor: const Color(0xFF4FC3F7),
                      overlayColor:
                          const Color(0xFF4FC3F7).withValues(alpha: 0.18),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      value: _searchVideoRate.clamp(1.0, 4.0),
                      min: 1.0,
                      max: 4.0,
                      // 0.05 刻み (= 細かく決められるように)。
                      divisions: 60,
                      onChanged: (v) {
                        final r = double.parse(v.toStringAsFixed(2));
                        setM(() {});
                        setState(() => _searchVideoRate = r);
                        _applySearchVideoRate(r);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 44,
                  child: Text('${_searchVideoRate.toStringAsFixed(2)}x',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ),
        ),
        PopupMenuItem<void>(
          height: 34,
          onTap: () {
            setState(() => _searchVideoRate = 1.0);
            _applySearchVideoRate(1.0);
          },
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.restart_alt_rounded,
                size: 15, color: Colors.white54),
            const SizedBox(width: 8),
            Text(p.t('btn.reset'),
                style: const TextStyle(color: Colors.white, fontSize: 12.5)),
          ]),
        ),
      ],
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

  /// 現在のページをブックマーク (お気に入り) に追加。
  ///
  /// 動作:
  /// - `onCreateBookmarkButton` コールバックが設定されている場合:
  ///   呼び出し元 (mind_map_screen) にカスタマイズダイアログを開かせて、
  ///   ユーザーに名前/アイコン/色を選んでもらい、 動的ボタンとして作成。
  /// - コールバック未設定 (= 旧互換) の場合:
  ///   従来通り SharedPreferences (`mokumoku_gs_bookmarks_v1`) に追加して、
  ///   検索ダイアログ内のお気に入り一覧に表示するだけ。
  /// いま出している中身の `document.title` を聞く (取れなければ空)。
  ///
  /// ★ 窓の題名の控え (`_pageTitle`) と違い、 ページを読み直さずに中身だけ
  ///   差し替える作り (YouTube など) でも今の題名が取れる。
  Future<String> _readLiveDocumentTitle() async {
    const js = "(function(){try{return document.title||'';}"
        "catch(e){return '';}})()";
    try {
      if (_isDesktop) {
        final r = await _winCtrl?.executeScript(js);
        return (r is String) ? r : (r?.toString() ?? '');
      }
      final r = await _iawCtrl?.evaluateJavascript(source: js);
      return (r is String) ? r : (r?.toString() ?? '');
    } catch (_) {
      return '';
    }
  }

  /// お気に入りの名前を整える。
  ///
  /// ★ = ユーザー要望「youtube 見ている時はその動画名が名前に入るように」。
  ///   YouTube の題名は「動画名 - YouTube」 なので、 後ろの札を落として
  ///   動画名だけにする (他のサイトはそのまま)。 落とした結果が空になる時
  ///   (= ホーム画面のように題名が「YouTube」 だけの時) は落とさない。
  String _tidyBookmarkTitle(String raw, String url) {
    var t = raw.trim();
    if (t.isEmpty) return url;
    const suffixes = <String>[' - YouTube', ' – YouTube', ' — YouTube'];
    for (final s in suffixes) {
      if (t.length > s.length && t.endsWith(s)) {
        final head = t.substring(0, t.length - s.length).trim();
        if (head.isNotEmpty) t = head;
        break;
      }
    }
    // 見ている最中の「(3) 動画名」 のような未読の数は邪魔なので落とす。
    t = t.replaceFirst(RegExp(r'^\(\d+\)\s*'), '');
    return t.isEmpty ? url : t;
  }

  Future<void> _addCurrentPageToBookmarks() async {
    final url = _currentUrl;
    if (url.isEmpty) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.noUrl'), const Color(0xFFE57373));
      return;
    }
    // ★ = ユーザー要望「youtube 見ている時は youtube ではなく、 その動画名が
    //   名前に入るようにして欲しい」。
    //   以前は控えてある `_pageTitle` を**先に**使っていた。 これは窓の題名を
    //   見張って入れている値で、 YouTube のようにページを読み直さずに中身だけ
    //   差し替える作り (SPA) では「YouTube」 のまま更新されない事がある。
    //   いま開いている中身の `document.title` を毎回聞きに行き、 取れなかった
    //   時だけ控えへ落とす。
    final live = (await _readLiveDocumentTitle()).trim();
    String title = live.isNotEmpty
        ? live
        : (_pageTitle.isNotEmpty ? _pageTitle : url);
    title = _tidyBookmarkTitle(title, url);
    // ── 新仕組み: 動的ボタン作成コールバックがあればそちらに委譲 ──
    final cb = widget.onCreateBookmarkButton;
    if (cb != null) {
      final ok = await cb(url, title);
      if (!mounted) return;
      if (ok) {
        _showCaptureSnack(context.read<MindMapProvider>().t('gs.favCreated').replaceFirst('{t}', title), const Color(0xFF43B97F));
      }
      // ok == false (= ユーザーがキャンセル) の場合はスナックを出さない
      return;
    }
    // ── 旧仕組み: 検索ダイアログ内のブックマーク一覧に追加するだけ ──
    await _GoogleSearchBookmarks.add(url: url, title: title);
    if (mounted) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.bookmarkAdded').replaceFirst('{t}', title), const Color(0xFF43B97F));
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
          tooltip: context.read<MindMapProvider>().t('gs.favPages').replaceFirst('{n}', '${items.length}'),
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
              PopupMenuItem<int>(
                value: -1,
                child: Row(
                  children: [
                    const Icon(Icons.delete_outline_rounded,
                        color: Color(0xFFE57373), size: 16),
                    const SizedBox(width: 8),
                    Text(context.read<MindMapProvider>().t('gs.deleteAll'),
                        style: const TextStyle(
                            color: Color(0xFFE57373), fontSize: 12)),
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
            Text(context.read<MindMapProvider>().t('gs.editFav'),
                style: const TextStyle(color: Colors.white)),
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
                Text(context.read<MindMapProvider>().t('gs.displayName'),
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12)),
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
                Text(context.read<MindMapProvider>().t('gs.chooseIcon'),
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12)),
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
              child: Text(context.read<MindMapProvider>().t('btn.cancel'),
                  style: const TextStyle(color: Colors.white54)),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dctx).pop(true),
              icon: const Icon(Icons.check_rounded, size: 16),
              label: Text(context.read<MindMapProvider>().t('btn.save')),
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
        _showCaptureSnack(context.read<MindMapProvider>().t('gs.favUpdated').replaceFirst('{n}', '${idx + 1}'), const Color(0xFF43B97F));
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

  void updateFloatingRequest({
    String? query,
    String? memo,
    String? url,
    String? aiPrompt,
  }) {
    final nextMemo = (memo ?? '').trim();
    final nextQuery = (query ?? '').trim();
    final nextUrl = (url ?? '').trim();
    if (nextMemo.isNotEmpty) {
      _memoCtrl.text = nextMemo;
      _memoCtrl.selection =
          TextSelection.collapsed(offset: _memoCtrl.text.length);
    }
    if (nextQuery.isNotEmpty) {
      _searchCtrl.text = nextQuery;
      _searchCtrl.selection =
          TextSelection.collapsed(offset: _searchCtrl.text.length);
    }
    if (nextUrl.isNotEmpty) {
      // ── 既に同じ URL (= 同じ AI サイト) を開いているならリロードしない ──
      // (= ユーザー報告: 再度開くと過去の文章が謎に入力される / 入力が
      //    効かない)。 リロードするとページ側の注入済みマーカーが消えて
      //    古いリトライと新しいリトライが二重注入し合っていた。 会話も
      //    リロードで失われるため、 同一サイトなら現状のページを維持して
      //    プロンプトだけ追記する。
      final sameUrl = nextUrl == _currentUrl;
      if (!sameUrl) {
        if (_gsTabs.isNotEmpty) {
          _gsTabs[_gsActiveTab].url = nextUrl;
          _gsTabs[_gsActiveTab].title = 'AI';
        }
        _openUrl(nextUrl);
      }
      final prompt = (aiPrompt ?? '').trim();
      if (prompt.isNotEmpty) {
        Future.delayed(
            const Duration(milliseconds: 300), () => _sendTextToAi(prompt));
      }
      return;
    }
    if (nextQuery.isNotEmpty) {
      final searchUrl = _buildSearchUrl(nextQuery);
      if (_gsTabs.isNotEmpty) {
        _gsTabs[_gsActiveTab].url = searchUrl;
        _gsTabs[_gsActiveTab].title = 'Google';
      }
      _openUrl(searchUrl);
    }
    final prompt = (aiPrompt ?? '').trim();
    if (prompt.isNotEmpty) {
      Future.delayed(
          const Duration(milliseconds: 300), () => _sendTextToAi(prompt));
    }
  }

  // ───────── 複数タブ (= ユーザー要望) ─────────
  String _gsTabLabel(int i) {
    if (i < 0 || i >= _gsTabs.length) return '';
    final t = _gsTabs[i].title;
    return t.isNotEmpty ? t : 'タブ ${i + 1}';
  }

  void _switchGsTab(int i) {
    if (i == _gsActiveTab || i < 0 || i >= _gsTabs.length) return;
    void apply(List<int>? panes, int? slot) {
      setState(() {
        if (panes != null) _gsPanes = panes;
        if (slot != null) _gsActiveSlot = slot;
        _gsActiveTab = i;
        _currentUrl = _gsTabs[i].url;
        _pageTitle = _gsTabs[i].title.isNotEmpty ? _gsTabs[i].title : 'Google';
      });
      if (_searchVideoRate != 1.0) _applySearchVideoRate(_searchVideoRate);
    }

    final panes = _gsPanesResolved;
    if (panes.length >= 2) {
      final at = panes.indexOf(i);
      if (at >= 0) {
        // ★ もう出ている札 = 枠も中身も動かさず「今のタブ」 の役だけ移す
        //   (= ユーザー要望「クリックした側が自動で左側に来ない様に」)。
        apply(panes, at);
        return;
      }
      // ★ 出ていない札 = **固定していない枠**へ入れる。 枠は動かない
      //   (= ユーザー要望「固定中は固定されていない側の画面が切り替わる」
      //    「切り替えた側に新しい画面が来る」)。
      final slot = _gsTargetSlot(panes);
      apply(List<int>.of(panes)..[slot] = i, slot);
      return;
    }
    // 並べていない時は今までどおり (再読み込みせず表示だけ切り替える)。
    apply(null, null);
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
      // ★ 並べている枠の札も、 アクティブと同じようにずらす
      //   (= ずらさないと、 左のタブを閉じた時に別のページが枠に出る)。
      //   ★ 古い `i` と比べているので、 アクティブをずらす**前**に済ませる。
      if (_gsPanes.isNotEmpty) {
        final next = <int>[];
        for (final t in _gsPanes) {
          if (t == i) continue; // 閉じた札の枠は無くなる
          next.add(t > i ? t - 1 : t); // ずらす (単調なので重複しない)
        }
        _gsPanes = next.length >= 2 ? next : const <int>[];
      }
      if (_gsActiveTab >= _gsTabs.length) {
        _gsActiveTab = _gsTabs.length - 1;
      } else if (i < _gsActiveTab) {
        _gsActiveTab--;
      }
      // 固定していた札も同じようにずらす (= ずらさないと別の枠を固定した事になる)。
      if (_gsPinnedTab != null) {
        if (_gsPinnedTab == i) {
          _gsPinnedTab = null;
        } else if (i < _gsPinnedTab!) {
          _gsPinnedTab = _gsPinnedTab! - 1;
        }
      }
      if (_gsPanes.isEmpty) _gsPinnedTab = null;
      // 「今のタブ」 の枠を引き直す (枠に居なければ控えを丸めるだけ)。
      final at = _gsPanes.indexOf(_gsActiveTab);
      _gsActiveSlot = at >= 0
          ? at
          : (_gsPanes.isEmpty
              ? 0
              : _gsActiveSlot.clamp(0, _gsPanes.length - 1));
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

  /// タブを複製 (= ユーザー要望: 右クリックの項目に「タブを複製」 を追加)。
  ///
  /// ★ 並べ (分割) の枠は札の**番号**で覚えているので、 途中へ挿すと枠が
  ///   別の札を指してしまう。 ブラウザのように隣へ挿さず**末尾へ足す**
  ///   ([_addGsTab] と同じ作り)。
  /// ★ 今見ている札の URL は `_currentUrl` が最新 (札の `url` は切り替えた
  ///   時にだけ書き戻す作りなので、 そこを読むと 1 つ前の住所になる)。
  void _duplicateGsTab(int i) {
    if (i < 0 || i >= _gsTabs.length) return;
    if (_gsTabs.length >= _kGsMaxTabs) return;
    final url = (i == _gsActiveTab ? _currentUrl : _gsTabs[i].url).trim();
    if (url.isEmpty) return;
    final title = _gsTabs[i].title;
    // 今の札の住所を控えてから移る (切り替えの作法と同じ)。
    _gsTabs[_gsActiveTab].url = _currentUrl;
    setState(() {
      _gsTabs.add(_GsTab(url: url, title: title));
      _gsActiveTab = _gsTabs.length - 1;
      _currentUrl = url;
      _pageTitle = title;
    });
    _openUrl(url);
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
      position: RelativeRect.fromLTRB(pos.dx + 6, pos.dy + 6, pos.dx + 6, pos.dy + 6),
      items: [
        // ★ = ユーザー要望「タブを複製する機能を右クリックの項目に追加」。
        if (_gsTabs.length < _kGsMaxTabs)
          PopupMenuItem<String>(
            value: 'duplicate',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.copy_all_rounded,
                  size: 15, color: Color(0xFF4FC3F7)),
              const SizedBox(width: 8),
              Text(context.read<MindMapProvider>().t('gs.duplicateTab'),
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ]),
          ),
        PopupMenuItem<String>(
          value: 'folder',
          child: Text(context.read<MindMapProvider>().t('gs.saveToFolder'),
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
        // ★ = ユーザー要望「開いている別のタブと分割して表示する」。
        //   デスクトップだけ (モバイルは同時マウントで白画面になる)。
        // ★ = ユーザー報告「右クリックしても分割ビューの項目が出てこない」。
        //   今見ている札を右クリックした時に出していなかったのが原因
        //   (利用者は今の札を右クリックする)。 どの札からでも出す。
        //   ・別の札 … その札と今の札を並べる
        //   ・今の札 … 隣の札と並べる
        if (_isDesktop && _gsTabs.length > 1)
          PopupMenuItem<String>(
            value: 'splitwith',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.vertical_split_rounded,
                  size: 15, color: Color(0xFF7CD992)),
              const SizedBox(width: 8),
              Text(
                  context.read<MindMapProvider>().t(i == _gsActiveTab
                      ? 'gs.splitWithNext'
                      : 'gs.splitWithTab'),
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ]),
          ),
        // ★ = ユーザー要望「3 画面や 2×2 表示もできるように」。 この札を
        //   今の並びへ**足す** (どの札を足すか選べる入口)。
        if (_isDesktop &&
            _gsPanesResolved.length >= 2 &&
            _gsPanesResolved.length < _gsMaxPanes(_gsPaneAreaOrScreen) &&
            !_gsPanesResolved.contains(i))
          PopupMenuItem<String>(
            value: 'splitadd',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.grid_view_rounded,
                  size: 15, color: Color(0xFF7CD992)),
              const SizedBox(width: 8),
              Text(context.read<MindMapProvider>().t('gs.splitAddTab'),
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ]),
          ),
        if (_isDesktop && _gsPanesResolved.length >= 2) ...[
          if (_gsPanesResolved.length <= 3)
            PopupMenuItem<String>(
              value: 'splitdir',
              child: Text(
                  context.read<MindMapProvider>().t(_gsSplitVertical
                      ? 'gs.splitSideBySide'
                      : 'gs.splitStacked'),
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          PopupMenuItem<String>(
            value: 'unsplit',
            child: Text(context.read<MindMapProvider>().t('gs.splitStop'),
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
        const PopupMenuDivider(),
        ..._gsSites.map((s) => PopupMenuItem<String>(
              value: 'site:${s.$1}',
              child: Text(
                  context.read<MindMapProvider>().t('gs.openSite').replaceFirst('{s}', s.$1),
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            )),
      ],
    );
    if (selected == null || !mounted) return;
    if (selected == 'duplicate') {
      _duplicateGsTab(i);
    } else if (selected == 'folder') {
      _gsSaveTabToFolder(i);
    } else if (selected == 'splitwith') {
      // 今の札を右クリックした時は、 隣 (右優先、 無ければ左) と並べる。
      var mate = i;
      if (i == _gsActiveTab) {
        mate = (i + 1 < _gsTabs.length) ? i + 1 : i - 1;
      }
      if (mate < 0 || mate >= _gsTabs.length || mate == _gsActiveTab) return;
      setState(() {
        // ★ 並べ始めの並びだけは札の順 (= ユーザー要望)。
        _gsPanes = _gsActiveTab < mate
            ? <int>[_gsActiveTab, mate]
            : <int>[mate, _gsActiveTab];
        _gsActiveSlot = _gsPanes.indexOf(_gsActiveTab);
      });
    } else if (selected == 'splitadd') {
      setState(() {
        _gsPanes = List<int>.of(_gsPanesResolved)..add(i);
      });
    } else if (selected == 'unsplit') {
      setState(() {
        _gsPanes = const <int>[];
        _gsPinnedTab = null;
      });
    } else if (selected == 'splitdir') {
      setState(() => _gsSplitVertical = !_gsSplitVertical);
    } else if (selected.startsWith('site:')) {
      final name = selected.substring(5);
      final site = _gsSites.firstWhere((s) => s.$1 == name,
          orElse: () => _gsSites.first);
      _openSiteGsTab(i, site.$2, site.$1);
    }
  }

  /// 並べた 2 枚の取り分 (左 / 上 の割合)。
  double _gsSplitRatio = 0.5;

  /// 副の境界の取り分 (3 枚の従側 / 2×2 の段境界)。 2 枚の時は使わない。
  double _gsSplitRatio2 = 0.5;

  /// 境界を掴んでから動かした量 (放した時にまとめて効かせる)。
  double? _gsSplitDrag;

  /// 今掴んでいるのが副の境界か (同時に掴めるのは 1 本だけ)。
  bool _gsSplitDragSub = false;

  /// 掴んでいた分を取り分へ反映する。 [secondary] = 副の境界 (3 枚の従側 /
  /// 2×2 の段境界)。
  void _commitGsSplitDrag(bool vertical, bool secondary) {
    final moved = _gsSplitDrag ?? 0;
    _gsSplitDrag = null;
    final box = context.findRenderObject() as RenderBox?;
    final full = (box != null && box.hasSize)
        ? (vertical ? box.size.height : box.size.width)
        : 1200.0;
    if (full <= 1) {
      setState(() {});
      return;
    }
    setState(() {
      if (secondary) {
        _gsSplitRatio2 = (_gsSplitRatio2 + moved / full).clamp(0.15, 0.85);
      } else {
        _gsSplitRatio = (_gsSplitRatio + moved / full).clamp(0.15, 0.85);
      }
    });
  }

  /// 境界の掴み棒 (= ユーザー要望: 分割境界を動かせるように)。
  ///
  /// ★ 掴んでいる間だけ色を付ける。 二度押しで半々へ戻す。
  /// ★ 3 枚・2×2 では境界が 2 本になるので、 向きと「主/副」 を引数で受ける。
  Widget _buildGsSplitHandle({required bool vertical, bool secondary = false}) {
    final dragging = _gsSplitDrag != null && _gsSplitDragSub == secondary;
    return MouseRegion(
      cursor: vertical
          ? SystemMouseCursors.resizeUpDown
          : SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => setState(() {
          if (secondary) {
            _gsSplitRatio2 = 0.5;
          } else {
            _gsSplitRatio = 0.5;
          }
        }),
        // ★ = ユーザー報告「画面境界を動かすと何もない黒い領域が大きく出る」。
        //   掴んでいる間ずっと幅を変えていたので、 WebView2 の描画の受け皿
        //   (Texture) が追い付かず、 縮め切れていない所が黒いまま見えていた。
        //   **放した時に 1 回だけ**変える (掴んでいる間は棒が光るだけ)。
        onHorizontalDragStart: vertical
            ? null
            : (_) => setState(() {
                  _gsSplitDrag = 0;
                  _gsSplitDragSub = secondary;
                }),
        onHorizontalDragUpdate: vertical
            ? null
            : (d) => _gsSplitDrag = (_gsSplitDrag ?? 0) + d.delta.dx,
        onHorizontalDragEnd:
            vertical ? null : (_) => _commitGsSplitDrag(vertical, secondary),
        onVerticalDragStart: !vertical
            ? null
            : (_) => setState(() {
                  _gsSplitDrag = 0;
                  _gsSplitDragSub = secondary;
                }),
        onVerticalDragUpdate: !vertical
            ? null
            : (d) => _gsSplitDrag = (_gsSplitDrag ?? 0) + d.delta.dy,
        onVerticalDragEnd:
            !vertical ? null : (_) => _commitGsSplitDrag(vertical, secondary),
        child: Container(
          width: vertical ? null : 8,
          height: vertical ? 8 : null,
          color: Colors.white.withValues(alpha: 0.06),
          child: Center(
            child: Container(
              width: vertical ? 34 : (dragging ? 3 : 2),
              height: vertical ? (dragging ? 3 : 2) : 34,
              decoration: BoxDecoration(
                color: dragging
                    ? const Color(0xFF6C63FF)
                    : Colors.white.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 枠 (ペイン) の右クリック: 固定する / 固定をやめる / 向き / 並べるのをやめる。
  ///
  /// ★ = ユーザー要望「画面分割したページを右クリックすると固定することが
  ///   できて、 固定中は固定されていない側の画面が他のタブをクリックした時に
  ///   切り替わるように」。
  Widget _gsPaneMenuText(String s) =>
      Text(s, style: const TextStyle(color: Colors.white, fontSize: 13));

  Future<void> _showGsPaneMenu(Offset pos, int paneTab) async {
    final panes = _gsPanesResolved;
    if (!_isDesktop || panes.length < 2 || !mounted) return;
    final slot = panes.indexOf(paneTab);
    if (slot < 0) return;
    final p = context.read<MindMapProvider>();
    final pinned = _pinnedPaneIndex == paneTab;
    final n = panes.length;
    final canAdd = n < _gsMaxPanes(_gsPaneAreaOrScreen);
    final sel = await showMenu<String>(
      context: context,
      color: const Color(0xFF22222E),
      position:
          RelativeRect.fromLTRB(pos.dx + 6, pos.dy + 6, pos.dx + 6, pos.dy + 6),
      items: [
        PopupMenuItem<String>(
          value: pinned ? 'unpin' : 'pin',
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
                size: 15, color: const Color(0xFFFFB347)),
            const SizedBox(width: 8),
            Text(
                p.t(pinned
                    ? 'gs.unpinPane'
                    : (_pinnedPaneIndex != null
                        // 固定できるのは片側だけ (= ユーザー要望)。 もう片方を
                        // 固定すると、 こちらへ移る。
                        ? 'gs.pinPaneMove'
                        : 'gs.pinPane')),
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ]),
        ),
        const PopupMenuDivider(),
        // ── 枠の中身を入れ替える (= ユーザー要望「右クリックした際に分割画面の
        //    左右を入れ替える項目が欲しい」) ──
        if (n == 2)
          PopupMenuItem<String>(
            value: 'swap:${slot == 0 ? 1 : 0}',
            child: _gsPaneMenuText(
                p.t(_gsSplitVertical ? 'gs.swapPanesTB' : 'gs.swapPanesLR')),
          ),
        if (n == 3)
          PopupMenuItem<String>(
            value: 'swap:${(slot + 1) % 3}',
            child: _gsPaneMenuText(p.t('gs.swapPaneNext')),
          ),
        if (n == 4) ...[
          // 2×2 は「横の相手」「縦の相手」 が決まるので 2 つ出す。
          PopupMenuItem<String>(
            value: 'swap:${slot ^ 1}',
            child: _gsPaneMenuText(p.t('gs.swapPanesLR')),
          ),
          PopupMenuItem<String>(
            value: 'swap:${slot ^ 2}',
            child: _gsPaneMenuText(p.t('gs.swapPanesTB')),
          ),
        ],
        // 向き (2×2 は対称なので出さない)。
        if (n <= 3)
          PopupMenuItem<String>(
            value: 'splitdir',
            child: _gsPaneMenuText(p
                .t(_gsSplitVertical ? 'gs.splitSideBySide' : 'gs.splitStacked')),
          ),
        // 枚数 (= ユーザー要望「3 画面や 2×2 表示もできるように」)。
        if (n != 2)
          PopupMenuItem<String>(
              value: 'panes:2', child: _gsPaneMenuText(p.t('gs.split2Panes'))),
        if (n != 3 && (n > 3 || canAdd))
          PopupMenuItem<String>(
              value: 'panes:3', child: _gsPaneMenuText(p.t('gs.split3Panes'))),
        if (n != 4 && canAdd)
          PopupMenuItem<String>(
              value: 'panes:4', child: _gsPaneMenuText(p.t('gs.split4Panes'))),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
            value: 'unsplit', child: _gsPaneMenuText(p.t('gs.splitStop'))),
      ],
    );
    if (sel == null || !mounted) return;
    if (sel == 'pin') {
      setState(() => _gsPinnedTab = paneTab);
    } else if (sel == 'unpin') {
      setState(() => _gsPinnedTab = null);
    } else if (sel == 'splitdir') {
      setState(() => _gsSplitVertical = !_gsSplitVertical);
    } else if (sel.startsWith('swap:')) {
      _swapGsPanes(slot, int.parse(sel.substring(5)));
    } else if (sel.startsWith('panes:')) {
      _setGsPaneCount(int.parse(sel.substring(6)));
    } else if (sel == 'unsplit') {
      setState(() {
        _gsPanes = const <int>[];
        _gsPinnedTab = null;
      });
    }
  }

  /// 枠の中身を入れ替える (= ユーザー要望「左右を入れ替える」)。
  ///
  /// ★ 枠そのもの (大きさ・位置) は動かさず、 中に出す札だけ交換する。
  ///   固定 ([_gsPinnedTab]) も「今のタブ」 も**札の位置**で覚えているので、
  ///   印は勝手に付いて回る。 直すのは [_gsActiveSlot] だけ。
  void _swapGsPanes(int slotA, int slotB) {
    final panes = List<int>.of(_gsPanesResolved);
    if (slotA < 0 ||
        slotB < 0 ||
        slotA >= panes.length ||
        slotB >= panes.length ||
        slotA == slotB) {
      return;
    }
    final t = panes[slotA];
    panes[slotA] = panes[slotB];
    panes[slotB] = t;
    setState(() {
      _gsPanes = panes;
      final at = panes.indexOf(_gsActiveIdx);
      if (at >= 0) _gsActiveSlot = at;
    });
  }

  /// 枠を [n] 枚にする。 足りない札は札の順で拾い、 無ければ新しく開く。
  /// 減らす時は後ろから落とす (「今のタブ」 と固定した札は残す)。
  void _setGsPaneCount(int n) {
    final max = _gsMaxPanes(_gsPaneAreaOrScreen);
    n = n.clamp(2, max < 2 ? 2 : max);
    setState(() {
      var panes = List<int>.of(_gsPanesResolved);
      if (panes.isEmpty) {
        final mate =
            _gsActiveIdx + 1 < _gsTabs.length ? _gsActiveIdx + 1 : _gsActiveIdx - 1;
        if (mate < 0) return;
        panes = _gsActiveIdx < mate
            ? <int>[_gsActiveIdx, mate]
            : <int>[mate, _gsActiveIdx];
      }
      while (panes.length > n) {
        final drop = panes
            .lastIndexWhere((t) => t != _gsActiveIdx && t != _pinnedPaneIndex);
        if (drop < 0) break;
        panes.removeAt(drop);
      }
      while (panes.length < n) {
        var add = -1;
        for (var k = 0; k < _gsTabs.length; k++) {
          if (!panes.contains(k)) {
            add = k;
            break;
          }
        }
        if (add < 0) {
          if (_gsTabs.length >= _kGsMaxTabs) break; // 上限は守る
          _gsTabs.add(_GsTab(url: 'https://www.google.com/', title: 'Google'));
          add = _gsTabs.length - 1; // 末尾追加 = 既存の番号は動かない
        }
        panes.add(add);
      }
      _gsPanes = panes.length >= 2 ? panes : const <int>[];
      if (_gsPanes.isEmpty) _gsPinnedTab = null;
      final at = _gsPanes.indexOf(_gsActiveIdx);
      if (at >= 0) _gsActiveSlot = at;
    });
  }

  /// サイトボタン: 一覧から選んで新しいタブで開く。
  Future<void> _showGsNewTabSiteMenu(Offset pos) async {
    final selected = await showMenu<String>(
      context: context,
      color: const Color(0xFF22222E),
      position: RelativeRect.fromLTRB(pos.dx + 6, pos.dy + 6, pos.dx + 6, pos.dy + 6),
      items: _gsSites
          .map((s) => PopupMenuItem<String>(
                value: s.$1,
                child: Text(
                    context.read<MindMapProvider>().t('gs.openSiteNewTab')
                        .replaceFirst('{s}', s.$1),
                    style:
                        const TextStyle(color: Colors.white, fontSize: 13)),
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
        title: Text(context.read<MindMapProvider>().t('gs.saveToFolder'),
            style: const TextStyle(color: Colors.white, fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (existing.isNotEmpty) ...[
              Text(context.read<MindMapProvider>().t('gs.existingFolders'),
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12)),
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
              Text(context.read<MindMapProvider>().t('gs.orNewFolder'),
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
            TextField(
              controller: ctrl,
              autofocus: existing.isEmpty,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: context.read<MindMapProvider>().t('gs.folderName'),
                hintStyle: const TextStyle(color: Colors.white38),
              ),
              onSubmitted: (v) => Navigator.pop(dctx, v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, null),
            child: Text(context.read<MindMapProvider>().t('btn.cancel'),
                style: const TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(dctx, ctrl.text.trim()),
            child: Text(context.read<MindMapProvider>().t('btn.save')),
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
          title: Text(context.read<MindMapProvider>().t('gs.folder'),
              style: const TextStyle(color: Colors.white, fontSize: 15)),
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
                        subtitle: Text(
                            context.read<MindMapProvider>().t('gs.itemCount')
                                .replaceFirst('{n}', '${e.value.length}'),
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
              child: Text(context.read<MindMapProvider>().t('btn.close'),
                  style: const TextStyle(color: Colors.white54)),
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
                        tooltip: context.read<MindMapProvider>().t('gs.deleteThisTab'),
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
              child: Text(context.read<MindMapProvider>().t('btn.close'),
                  style: const TextStyle(color: Colors.white54)),
            ),
            if (items.isNotEmpty)
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white),
                icon: const Icon(Icons.open_in_full_rounded, size: 16),
                label: Text(context.read<MindMapProvider>().t('gs.openAll')),
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
  /// 札と札の間の受け口 (= 並べ替え)。 [index] は「ここへ入れる」 位置。
  Widget _buildGsTabGap(int index) {
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) =>
          d.data >= 0 && d.data < _gsTabs.length,
      onAcceptWithDetails: (d) {
        final from = d.data;
        var to = index;
        if (from < to) to -= 1;
        if (from == to || from < 0 || from >= _gsTabs.length) return;
        // ★ 位置ではなく**その札そのもの**を覚えてから動かす (= 動かした後に
        //   番号だけ足し引きすると、 並べている枠が別のページを指す)。
        final active = _gsTabs[_gsActiveTab];
        // ★ 枠に出している札も**その札そのもの**で覚える (位置で覚えると、
        //   動かした後に足し引きした番号が別のページを指す)。
        final paneTabs = <_GsTab>[
          for (final k in _gsPanes)
            if (k >= 0 && k < _gsTabs.length) _gsTabs[k],
        ];
        final pinned = (_gsPinnedTab != null &&
                _gsPinnedTab! >= 0 &&
                _gsPinnedTab! < _gsTabs.length)
            ? _gsTabs[_gsPinnedTab!]
            : null;
        setState(() {
          final moved = _gsTabs.removeAt(from);
          _gsTabs.insert(to.clamp(0, _gsTabs.length), moved);
          _gsActiveTab = _gsTabs.indexOf(active);
          if (_gsActiveTab < 0) _gsActiveTab = 0;
          final next = <int>[];
          for (final t in paneTabs) {
            final k = _gsTabs.indexOf(t); // _GsTab は == 未定義 = 同一性で引く
            if (k >= 0 && !next.contains(k)) next.add(k);
          }
          _gsPanes = next.length >= 2 ? next : const <int>[];
          // 固定した札も、 位置ではなく札そのもので引き直す。
          _gsPinnedTab = pinned == null ? null : _gsTabs.indexOf(pinned);
          if (_gsPinnedTab != null && _gsPinnedTab! < 0) _gsPinnedTab = null;
          final at = _gsPanes.indexOf(_gsActiveTab);
          if (at >= 0) _gsActiveSlot = at;
          _gsDraggingTab = false;
        });
      },
      builder: (_, cand, __) => Container(
        width: cand.isNotEmpty ? 26 : (_gsDraggingTab ? 20 : 6),
        height: 24,
        margin: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: cand.isEmpty
              ? Colors.transparent
              : const Color(0xFF4FC3F7).withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }

  /// 札を掴んでいる間か (受け口を広げて狙いやすくする)。
  bool _gsDraggingTab = false;

  /// 帯を横に流すための控え (パソコンでは車輪でだけ流す。 下の説明を見る)。
  final ScrollController _gsTabBarScroll = ScrollController();

  /// 車輪で帯を流す (パソコン用)。
  void _gsTabBarWheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    if (!_gsTabBarScroll.hasClients) return;
    final p = _gsTabBarScroll.position;
    // 縦の車輪でも横へ流す (帯は横向きなので、 そのまま足す)。
    final d = e.scrollDelta.dy.abs() > e.scrollDelta.dx.abs()
        ? e.scrollDelta.dy
        : e.scrollDelta.dx;
    final next = (p.pixels + d).clamp(
        p.minScrollExtent, p.maxScrollExtent);
    if (next != p.pixels) _gsTabBarScroll.jumpTo(next);
  }

  Widget _buildGsTabBar() {
    // ★ = ユーザー要望「タブ上を右クリックした時だけ項目が表示されるが、
    //   何もないヘッダー欄を右クリックしても同様の項目が出るように」。
    //   帯ぜんぶを包む。 札の上はその札の受け口 (より内側) が勝つので、
    //   今までどおりその札の一覧が出る。 何も無い所ではここが受け取り、
    //   今見ている札を相手にした同じ一覧を出す。
    // ★ 包みは `Row` の**外側**に置く (中に挟むと帯の高さが崩れる)。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (d) =>
          _showGsTabMenu(d.globalPosition, _gsActiveTab),
      onLongPressStart: _isDesktop
          ? null
          : (d) => _showGsTabMenu(d.globalPosition, _gsActiveTab),
      child: _buildGsTabBarBody(),
    );
  }

  Widget _buildGsTabBarBody() {
    return Container(
      height: 34,
      color: const Color(0xFF0E0E1A),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(children: [
        Expanded(
          // ★ = ユーザー要望「タブをドラッグで順番を入れ替えられるように」。
          //   受け口 ([_buildGsTabGap]) も掴み ([LongPressDraggable]) も前から
          //   在ったのに**一度も始まらなかった**のは、 帯が横に流れる一覧
          //   (ListView) だから。 マウスの掴み判定は **1px** 動いた時点で
          //   立つので、 長押し (220ms) を待つ前に**スクロールが先に掴みを
          //   取って**しまい、 札のドラッグは毎回負けていた。
          //   パソコンでは帯を指で流す必要が無い (車輪がある) ので、
          //   **流すのは車輪だけ**にして、 掴みの取り合いそのものを無くす。
          //   触って使う端末 (Android) は今までどおり指で流せる。
          child: Listener(
            onPointerSignal: _isDesktop ? _gsTabBarWheel : null,
            child: ListView.builder(
            controller: _gsTabBarScroll,
            physics: _isDesktop
                ? const NeverScrollableScrollPhysics()
                : null,
            scrollDirection: Axis.horizontal,
            // ★ = ユーザー要望「タブの並び順はドラッグで自由に変えられる
            //   ように」。 札と札の**間**に受け口 (_buildGsTabGap) を挟んで、
            //   掴んだ札をそこへ落とす。 偶数 = 受け口 / 奇数 = 札。
            //   帯は横に流れるので、 掴むのは長押し (すぐ掴む形にすると
            //   帯を流せなくなる。 本体のタブと同じ作法)。
            itemCount: _gsTabs.length * 2 + 1,
            itemBuilder: (_, raw) {
              if (raw.isEven) return _buildGsTabGap(raw ~/ 2);
              final i = raw ~/ 2;
              final active = i == _gsActiveTab;
              return GestureDetector(
                onTap: () => _switchGsTab(i),
                onSecondaryTapDown: (d) => _showGsTabMenu(d.globalPosition, i),
                // ★ 長押しの一覧は右クリックの無い端末だけ (= 点検で判明:
                //   長押しで掴む並べ替えと同じ押し方を取り合い、 一覧が勝つと
                //   ドラッグが一度も始まらない)。
                onLongPressStart: _isDesktop
                    ? null
                    : (d) => _showGsTabMenu(d.globalPosition, i),
                child: LongPressDraggable<int>(
                  data: i,
                  delay: const Duration(milliseconds: 220),
                  dragAnchorStrategy: pointerDragAnchorStrategy,
                  onDragStarted: () => setState(() => _gsDraggingTab = true),
                  onDragEnd: (_) => setState(() => _gsDraggingTab = false),
                  onDraggableCanceled: (_, __) =>
                      setState(() => _gsDraggingTab = false),
                  feedback: Material(
                    color: Colors.transparent,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF3C3C6E),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_gsTabLabel(i),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11.5)),
                    ),
                  ),
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
                        color: active
                            ? const Color(0xFF6C63FF)
                            // ★ 並べている相方の印。 = ユーザー要望「黄緑の方が
                            //   目立つから、 ディアクティブの画面の色はもっと目立たなく」。
                            //   明るい緑をやめて、 今見ている札より弱い色にする。
                            : (i == _pinnedPaneIndex
                                ? const Color(0xFFFFB347)
                                : (_gsPanesResolved.contains(i)
                                    ? const Color(0xFF3F5A4B)
                                    : Colors.white12))),
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
                ),
              );
            },
          ),
          ),
        ),
        GestureDetector(
          onTap: _showGsFoldersMenu,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Tooltip(
              message: context.read<MindMapProvider>().t('gs.folderTip'),
              child: const Icon(Icons.folder_rounded,
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Tooltip(
                message: context.read<MindMapProvider>().t('gs.newTabTip'),
                child: const Icon(Icons.add_rounded,
                    color: Colors.white70, size: 20),
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
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.addingPageInfo'), const Color(0xFF4FC3F7));
      final provider = context.read<MindMapProvider>();
      // タイトル: Windows なら _pageTitle (= _winCtrl.title.listen で更新済)、
      // それ以外なら _currentUrl のドメイン部分を抜き出して使う。
      String title = _pageTitle.isNotEmpty ? _pageTitle : _currentUrl;
      if (title.length > 50) title = '${title.substring(0, 50)}…';
      // ノードを生成。 座標はキャンバスの大体中央 (= 後で移動可能)。
      final newNode = provider.addNodeAtCenterReturning(const Offset(900, 900));
      // ── YouTube の動画ページは、 ただのリンクではなく「動画」 として
      //    貼る (= ユーザー報告: ここから埋め込むと動画のサムネイルが
      //    表示されない)。 リンク扱いのままだとサムネイルも再生も付かない。 ──
      final videoId = NodeWidget.extractVideoId(_currentUrl);
      if (videoId != null) {
        provider.updateNodeTitle(newNode.id, '📺 $title');
        provider.updateNodeYoutube(newNode.id, _currentUrl);
      } else {
        provider.updateNodeTitle(newNode.id, '🔗 $title');
        // URL をノードのリンクとして保存 (= タップで再アクセス可能)
        try {
          provider.updateNodeLink(newNode.id, _currentUrl);
        } catch (_) {/* updateNodeLink が無い古い provider 用フォールバック */}
      }
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.pageInfoAdded'), const Color(0xFF43B97F));
    } catch (e) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.addFailed').replaceFirst('{e}', '$e'), const Color(0xFFE57373));
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
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.shotAdded'), const Color(0xFF43B97F));
    } catch (e) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.saveFailed').replaceFirst('{e}', '$e'), const Color(0xFFE57373));
    }
  }

  String? _downloadNameFromDisposition(String? disposition) {
    if (disposition == null || disposition.trim().isEmpty) return null;
    final encoded = RegExp("filename\\*=UTF-8''([^;]+)", caseSensitive: false)
        .firstMatch(disposition)
        ?.group(1);
    if (encoded != null && encoded.isNotEmpty) {
      try {
        return Uri.decodeComponent(encoded.trim());
      } catch (_) {
        return encoded.trim();
      }
    }
    return RegExp(r'filename="?([^";]+)"?', caseSensitive: false)
        .firstMatch(disposition)
        ?.group(1)
        ?.trim();
  }

  String _safeDownloadFileName(
    iaw.DownloadStartRequest request, {
    String? responseDisposition,
    String? responseMime,
  }) {
    var name = (request.suggestedFilename ?? '').trim();
    name = name.isEmpty
        ? (_downloadNameFromDisposition(responseDisposition) ??
            _downloadNameFromDisposition(request.contentDisposition) ??
            '')
        : name;
    if (name.isEmpty) {
      try {
        final uri = Uri.parse(request.url.toString());
        name = uri.pathSegments.lastWhere((part) => part.trim().isNotEmpty,
            orElse: () => '');
      } catch (_) {}
    }
    if (name.isEmpty || name == 'uc' || name == 'export') {
      name = 'download_${DateTime.now().millisecondsSinceEpoch}';
    }
    try {
      name = Uri.decodeComponent(name);
    } catch (_) {}
    name = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'^\.+'), '')
        .trim();
    if (name.isEmpty) name = 'download_${DateTime.now().millisecondsSinceEpoch}';
    if (!name.contains('.')) {
      final mime = (responseMime ?? request.mimeType ?? '').toLowerCase();
      const extensions = <String, String>{
        'application/pdf': '.pdf',
        'application/zip': '.zip',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
            '.docx',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
            '.xlsx',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation':
            '.pptx',
        'image/png': '.png',
        'image/jpeg': '.jpg',
        'text/plain': '.txt',
      };
      name += extensions[mime] ?? '';
    }
    return name;
  }

  Future<({Uint8List bytes, String? disposition, String? mime})>
      _readHttpDownload(iaw.DownloadStartRequest request) async {
    final uri = Uri.parse(request.url.toString());
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final httpRequest = await client.getUrl(uri);
      final userAgent = request.userAgent?.trim();
      if (userAgent != null && userAgent.isNotEmpty) {
        httpRequest.headers.set(HttpHeaders.userAgentHeader, userAgent);
      }
      try {
        final cookies = await iaw.CookieManager.instance()
            .getCookies(url: iaw.WebUri(uri.toString()));
        if (cookies.isNotEmpty) {
          httpRequest.headers.set(HttpHeaders.cookieHeader,
              cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; '));
        }
      } catch (_) {}
      final response = await httpRequest.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('HTTP ${response.statusCode}');
      }
      if (response.contentLength > _kMaxInAppDownloadBytes) {
        throw StateError('ファイルがアプリ内保存の上限（96MB）を超えています');
      }
      final output = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        if (received > _kMaxInAppDownloadBytes) {
          throw StateError('ファイルがアプリ内保存の上限（96MB）を超えています');
        }
        output.add(chunk);
      }
      return (
        bytes: output.takeBytes(),
        disposition: response.headers.value('content-disposition'),
        mime: response.headers.contentType?.mimeType,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<({Uint8List bytes, String? disposition, String? mime})>
      _readWebDownload(iaw.InAppWebViewController controller,
          iaw.DownloadStartRequest request) async {
    final url = request.url.toString();
    if (url.startsWith('data:')) {
      final data = Uri.parse(url).data;
      if (data == null) throw StateError('data URLを読み取れませんでした');
      final bytes = Uint8List.fromList(data.contentAsBytes());
      if (bytes.length > _kMaxInAppDownloadBytes) {
        throw StateError('ファイルがアプリ内保存の上限（96MB）を超えています');
      }
      return (bytes: bytes, disposition: null, mime: data.mimeType);
    }
    if (url.startsWith('blob:')) {
      final result = await controller.callAsyncJavaScript(
        functionBody: r'''
          const response = await fetch(downloadUrl, {credentials: 'include'});
          if (!response.ok) throw new Error('HTTP ' + response.status);
          const blob = await response.blob();
          if (blob.size > maxBytes) return {tooLarge: true, size: blob.size};
          const dataUrl = await new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result);
            reader.onerror = () => reject(reader.error);
            reader.readAsDataURL(blob);
          });
          return {dataUrl: dataUrl, mime: blob.type, size: blob.size};
        ''',
        arguments: <String, dynamic>{
          'downloadUrl': url,
          'maxBytes': _kMaxInAppDownloadBytes,
        },
      );
      if (result?.error != null) throw StateError(result!.error!);
      final value = result?.value;
      if (value is! Map) throw StateError('blob URLを読み取れませんでした');
      if (value['tooLarge'] == true) {
        throw StateError('ファイルがアプリ内保存の上限（96MB）を超えています');
      }
      final dataUrl = value['dataUrl']?.toString() ?? '';
      final comma = dataUrl.indexOf(',');
      if (comma < 0) throw StateError('blobデータの形式が不正です');
      final bytes = Uint8List.fromList(base64Decode(dataUrl.substring(comma + 1)));
      return (
        bytes: bytes,
        disposition: null,
        mime: value['mime']?.toString(),
      );
    }
    return _readHttpDownload(request);
  }

  Future<void> _handleMobileWebDownload(iaw.InAppWebViewController controller,
      iaw.DownloadStartRequest request) async {
    if (_webDownloadInProgress) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.dlBusy'), const Color(0xFFFFC107));
      return;
    }
    if (request.contentLength > _kMaxInAppDownloadBytes) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.dlTooBig'),
          const Color(0xFFE57373));
      return;
    }
    _webDownloadInProgress = true;
    _showCaptureSnack(context.read<MindMapProvider>().t('gs.dlFetching'), const Color(0xFF4FC3F7));
    // 保存ダイアログのタイトルは await の前に取っておく (= context を
    // 非同期ギャップ後に触らないため)。
    final saveDialogTitle = context.read<MindMapProvider>().t('save.downloadDir');
    try {
      final payload = await _readWebDownload(controller, request);
      final fileName = _safeDownloadFileName(
        request,
        responseDisposition: payload.disposition,
        responseMime: payload.mime,
      );
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: saveDialogTitle,
        fileName: fileName,
        type: FileType.any,
        bytes: payload.bytes,
      );
      if (!mounted) return;
      if (saved != null) {
        _showCaptureSnack(context.read<MindMapProvider>().t('gs.dlSaved').replaceFirst('{f}', fileName), const Color(0xFF43B97F));
      }
    } catch (e) {
      if (mounted) {
        _showCaptureSnack(context.read<MindMapProvider>().t('gs.dlFailed').replaceFirst('{e}', '$e'),
            const Color(0xFFE57373));
      }
    } finally {
      _webDownloadInProgress = false;
    }
  }

  Widget _buildWebViewCore() {
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
    // ★ 固定している札は必ず片側に残す (= ユーザー要望「固定した側は動かない
    //   ように」)。 新しい札を開いても、 固定していない側だけが変わる。
    // ★ = ユーザー要望: この窓の中で 2〜4 つのタブを並べる。 どの枠も
    //   **同じ IndexedStack から 1 枚だけ**描き、 同じ札を 2 枠に出さない
    //   (1 つの WebviewController を 2 か所へ挿すと、 描画の受け皿 (Texture)
    //   を取り合って片方が真っ黒になる)。 重複は [_gsPanesResolved] が潰す。
    if (_gsPanes.length >= 2) {
      return LayoutBuilder(builder: (context, c) {
        // 一覧の出し分け用に広さを覚える (組み立て中なので setState しない)。
        _gsPaneArea = Size(c.maxWidth, c.maxHeight);
        final panes = _gsPanesVisible(_gsPaneArea);
        if (panes.length < 2) return _buildGsSingleStack(idx);
        return _buildGsPaneLayout(panes);
      });
    }

    return _buildGsSingleStack(idx);
  }

  /// 並べていない時の中身 (= 従来どおり全タブ保持の IndexedStack)。
  Widget _buildGsSingleStack(int idx) => IndexedStack(
        index: idx,
        children: [
          for (int i = 0; i < _gsTabs.length; i++) _buildWinTabWebView(i),
        ],
      );

  /// 枠の並べ方。
  ///   2 枚 … 左右 / 上下 (今までどおり)
  ///   3 枚 … 主枠 1 つ + 反対側に 2 段 (向きは [_gsSplitVertical])
  ///   4 枚 … 2×2 (縦の境界は上下の段で同じ取り分を使うので 1 本に見える)
  Widget _buildGsPaneLayout(List<int> panes) {
    // ★ = ユーザー要望「分割境界を動かせるように」。 掴んで動かした取り分を
    //   覚えておく (0.15〜0.85 の間)。 二度押しで半々に戻す。
    final main = (_gsSplitRatio.clamp(0.15, 0.85) * 1000).round();
    final sub = (_gsSplitRatio2.clamp(0.15, 0.85) * 1000).round();
    final v = _gsSplitVertical;
    if (panes.length == 2) {
      final kids = <Widget>[
        Expanded(flex: main, child: _buildGsPane(panes[0])),
        _buildGsSplitHandle(vertical: v),
        Expanded(flex: 1000 - main, child: _buildGsPane(panes[1])),
      ];
      return v ? Column(children: kids) : Row(children: kids);
    }
    if (panes.length == 3) {
      final side = <Widget>[
        Expanded(flex: sub, child: _buildGsPane(panes[1])),
        _buildGsSplitHandle(vertical: !v, secondary: true),
        Expanded(flex: 1000 - sub, child: _buildGsPane(panes[2])),
      ];
      final kids = <Widget>[
        Expanded(flex: main, child: _buildGsPane(panes[0])),
        _buildGsSplitHandle(vertical: v),
        Expanded(
            flex: 1000 - main,
            child: v ? Row(children: side) : Column(children: side)),
      ];
      return v ? Column(children: kids) : Row(children: kids);
    }
    Widget row(int a, int b) => Row(children: [
          Expanded(flex: main, child: _buildGsPane(a)),
          _buildGsSplitHandle(vertical: false),
          Expanded(flex: 1000 - main, child: _buildGsPane(b)),
        ]);
    return Column(children: [
      Expanded(flex: sub, child: row(panes[0], panes[1])),
      _buildGsSplitHandle(vertical: true, secondary: true),
      Expanded(flex: 1000 - sub, child: row(panes[2], panes[3])),
    ]);
  }

  /// 1 つの枠 (= 札 [show] を 1 枚だけ描く)。
  Widget _buildGsPane(int show) {
    final focused = show == _gsActiveIdx;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          // ★ 固定している枠は一目で分かるようにする (= ユーザー要望)。
          color: _pinnedPaneIndex == show
              ? const Color(0xFFFFB347)
              : focused
                  ? const Color(0xFF6C63FF)
                  // ★ 選んでいない側はほぼ見えない線にする (= ユーザー要望)。
                  : Colors.white.withValues(alpha: 0.05),
          width: 1.5,
        ),
      ),
      // 枠を押したら、 そちらを「今のタブ」 にする (URL 欄や戻る/進むは
      // 今のタブに付いて回るので、 これだけで道具が付いてくる)。
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          // ★ 右クリックは焦点を動かさず、 枠の一覧だけ出す (= ユーザー要望)。
          //   ジェスチャーは WebView が右ボタンを先に取ると来ない事があるので、
          //   生のポインタで見る。
          if (e.kind == PointerDeviceKind.mouse &&
              e.buttons == kSecondaryButton) {
            unawaited(_showGsPaneMenu(e.position, show));
            return;
          }
          if (_gsActiveTab == show) return;
          // ★ 「今のタブ」 の役を移すだけ。 枠も中身も動かさない。
          final at = _gsPanesResolved.indexOf(show);
          setState(() {
            if (at >= 0) _gsActiveSlot = at;
            _gsActiveTab = show;
            _currentUrl = _gsTabs[show].url;
            _pageTitle =
                _gsTabs[show].title.isNotEmpty ? _gsTabs[show].title : 'Google';
          });
        },
        child: IndexedStack(
          index: show,
          children: [
            for (int i = 0; i < _gsTabs.length; i++)
              i == show ? _buildWinTabWebView(i) : const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }

  // ── 自動操作 (= ユーザー要望: 指定箇所のタップ/スワイプ/ホールド回数や
  //    時間を設定して自動実行 + スクショと組み合わせ) ──
  final GlobalKey _webAreaKey = GlobalKey();
  bool _autoPanelOpen = false;

  // ── オートクリッカー (= ユーザー要望: ブラウザの帯から出す道具) ──────
  //    ★ 手順を組む「クリック手順」 とは別物。 こちらは今見ているページの
  //      上で、 決めた場所を決めた間隔で押し続けるだけの道具。
  bool _autoClickerOpen = false;
  Offset _autoClickerPos = const Offset(80, 90);

  /// 自動操作の記録中か (= ユーザー要望: フローを組まなくても操作を覚えて
  /// 再現できるように)。 ON の間は WebView にオーバーレイを重ね、 タップを
  /// パネルへ流してから同じ位置をページへ送る。
  bool _autoRecording = false;
  final GlobalKey<WebAutomationPanelState> _autoPanelKey =
      GlobalKey<WebAutomationPanelState>();

  /// 座標ピック中の completer (1 点 / 2 点)。
  Completer<Offset?>? _pickPointCompleter;
  Completer<Rect?>? _pickRectCompleter;
  Offset? _pickRectFirst;

  Future<Offset?> _pickPointOnPage() {
    _pickPointCompleter?.complete(null);
    final c = Completer<Offset?>();
    setState(() => _pickPointCompleter = c);
    return c.future;
  }

  Future<Rect?> _pickRectOnPage() {
    _pickRectCompleter?.complete(null);
    final c = Completer<Rect?>();
    setState(() {
      _pickRectCompleter = c;
      _pickRectFirst = null;
    });
    return c.future;
  }

  /// 座標を指すのをやめる (= 欄に戻す)。
  void _cancelPick() {
    final p = _pickPointCompleter;
    final r = _pickRectCompleter;
    setState(() {
      _pickPointCompleter = null;
      _pickRectCompleter = null;
      _pickRectFirst = null;
    });
    p?.complete(null);
    r?.complete(null);
  }

  void _handlePickTap(Offset local) {
    if (_pickPointCompleter != null) {
      final c = _pickPointCompleter!;
      setState(() => _pickPointCompleter = null);
      c.complete(local);
      return;
    }
    if (_pickRectCompleter != null) {
      if (_pickRectFirst == null) {
        setState(() => _pickRectFirst = local);
        return;
      }
      final a = _pickRectFirst!;
      final c = _pickRectCompleter!;
      setState(() {
        _pickRectCompleter = null;
        _pickRectFirst = null;
      });
      c.complete(Rect.fromPoints(a, local));
    }
  }

  /// 有料プランが必要な時の誘導モーダル (= ユーザー要望)。
  void _showPlanNotice(String message) {
    if (!mounted) return;
    showPaywallModal(context, message);
  }

  /// フローティング自動操作パネルの位置 / 折りたたみ状態
  /// (= ユーザー要望: 欄を設けるとスクショできる範囲が狭まるので浮遊窓に)。
  Offset _autoPanelPos = const Offset(80, 90);
  bool _autoPanelCollapsed = false;

  /// AI 欄を浮遊窓にするか (= ユーザー要望: AI チャット欄のフローティング
  /// 機能も使えるように)。 true の間は横の欄には出さず、 ドラッグできる
  /// 窓として前面に出す。 WebView コントローラは同じものを使い回すので、
  /// 会話は途切れない。
  bool _aiPanelFloating = false;
  Offset _aiFloatPos = const Offset(140, 120);
  double _aiFloatW = 460;
  double _aiFloatH = 560;

  /// 自動操作の実行状態 (= ユーザー要望: 実行中は窓のヘッダーに停止ボタン
  /// だけを出す)。
  bool _autoRunning = false;
  VoidCallback? _autoStop;

  /// この実行分の保存先 (= ユーザー要望: フロー実行の度に別フォルダ)。
  String? _autoRunDir;

  /// キャプチャ中だけパネルを隠すためのフラグ (= ユーザー要望: スクショに
  /// ボタンや欄が写り込まないように)。
  bool _autoPanelHiddenForShot = false;

  /// WebView 領域 (または指定した部分矩形) を画面キャプチャして PNG 保存。
  /// パネル / ピック用オーバーレイは一時的に隠してから撮る。
  Future<String?> _captureWebArea(Rect? region) async {
    if (mounted) {
      setState(() => _autoPanelHiddenForShot = true);
      // 隠した状態を実際に画面へ反映させてから撮る
      await WidgetsBinding.instance.endOfFrame;
      await Future.delayed(const Duration(milliseconds: 90));
    }
    try {
      final box =
          _webAreaKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return null;
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final origin = box.localToGlobal(Offset.zero);
      final area = region == null
          ? Rect.fromLTWH(0, 0, box.size.width, box.size.height)
          : region;
      // JPEG で保存する (= ユーザー要望: データ容量が小さく済む)。
      final png = captureScreenRectJpg(
        ((origin.dx + area.left) * dpr).round(),
        ((origin.dy + area.top) * dpr).round(),
        (area.width * dpr).round(),
        (area.height * dpr).round(),
      );
      if (png == null) return null;
      final path = await _nextShotPath();
      await File(path).writeAsBytes(png, flush: true);
      return path;
    } catch (_) {
      return null;
    } finally {
      if (mounted) setState(() => _autoPanelHiddenForShot = false);
    }
  }

  /// 外のブラウザ (CDP) で撮った PNG を、 いつもの置き場に保存する。
  ///
  /// = ユーザー要望「CDP が実装できているのだから、 外のブラウザの
  ///   ページをそのまま撮ってほしい」。 撮る所は自動操作の側にあるが、
  ///   連番と実行ごとのフォルダはここが持っているので、 保存だけ引き受ける。
  Future<String?> _saveShotBytes(Uint8List png) async {
    try {
      final path = await _nextShotPath(ext: 'png');
      await File(path).writeAsBytes(png, flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 次に保存するスクショの置き場所 (実行ごとのフォルダ + 連番)。
  /// = ユーザー要望「画像名が長すぎる」 ので 1.jpg, 2.jpg … の形。
  Future<String> _nextShotPath({String ext = 'jpg'}) async {
    final shotDir = _autoRunDir != null
        ? Directory(_autoRunDir!)
        : await automationShotsDir();
    if (!await shotDir.exists()) await shotDir.create(recursive: true);
    var next = 1;
    try {
      for (final f in shotDir.listSync().whereType<File>()) {
        final name = f.path.split(Platform.pathSeparator).last;
        final lower = name.toLowerCase();
        if (!lower.endsWith('.png') && !lower.endsWith('.jpg')) continue;
        final n = int.tryParse(name.substring(0, name.length - 4));
        if (n != null && n >= next) next = n + 1;
      }
    } catch (_) {}
    return '${shotDir.path}/$next.$ext';
  }

  /// ページの上から下までを 1 枚の縦長画像にして保存する (= ユーザー要望)。
  ///
  /// WebView には「ページ全体を撮る」 口が無い (Windows の webview_windows は
  /// 撮影 API 自体が無く、 モバイルの takeScreenshot も見えている分だけ) ので、
  /// 1 画面分ずつ撮って縦に繋げる。 継ぎ目がずれないよう、 送った後に
  /// **ページが実際に何 px 動いたか**を聞いてから貼る位置を決める。
  Future<String?> _captureFullPageTall() async {
    final ev = _autoEvalJs;
    // 画面に固定されている帯 (ヘッダー等) は 2 枚目以降で隠す。
    const hideFixedJs = '''
(function(){var n=0,all=document.body?document.body.getElementsByTagName('*'):[];
 for(var i=0;i<all.length&&n<600;i++){var cs=getComputedStyle(all[i]);
  if(cs.position==='fixed'||cs.position==='sticky'){all[i].setAttribute('data-hnfs','1');n++;}}
 var s=document.getElementById('__hnfs');
 if(!s){s=document.createElement('style');s.id='__hnfs';document.documentElement.appendChild(s);}
 s.textContent='[data-hnfs="1"]{visibility:hidden !important;}html{scroll-behavior:auto !important;}';
 return String(n);})();''';
    const unhideFixedJs = '''
(function(){var s=document.getElementById('__hnfs');if(s)s.remove();
 var m=document.querySelectorAll('[data-hnfs]');
 for(var i=0;i<m.length;i++)m[i].removeAttribute('data-hnfs');return '1';})();''';

    /// JS の戻り値から数値を取り出す (WebView2 は二重に囲って返す)。
    int? numOf(String? raw, String key) {
      if (raw == null) return null;
      var s = raw.trim();
      if (s.startsWith('"') && s.endsWith('"') && s.length > 1) {
        try {
          s = jsonDecode(s) as String;
        } catch (_) {}
      }
      try {
        final j = jsonDecode(s);
        if (j is Map && j[key] is num) return (j[key] as num).round();
      } catch (_) {}
      return null;
    }

    if (mounted) {
      setState(() => _autoPanelHiddenForShot = true);
      await WidgetsBinding.instance.endOfFrame;
      await Future.delayed(const Duration(milliseconds: 90));
    }
    try {
      const metricsJs = '''
(function(){var d=document.documentElement,b=document.body;
 return JSON.stringify({
  pageH: Math.max(d.scrollHeight, b?b.scrollHeight:0, d.offsetHeight),
  viewH: Math.round(d.clientHeight||window.innerHeight),
  y: Math.round(window.scrollY||d.scrollTop||0)});})();''';
      final m0 = await ev(metricsJs);
      final viewH = numOf(m0, 'viewH') ?? 0;
      final startY = numOf(m0, 'y') ?? 0;
      if (viewH <= 0) return null;

      /// 1 画面分の絵を撮る。
      Future<img.Image?> grabSegment() async {
        if (_isDesktop) {
          final box =
              _webAreaKey.currentContext?.findRenderObject() as RenderBox?;
          if (box == null) return null;
          final dpr = MediaQuery.of(context).devicePixelRatio;
          final o = box.localToGlobal(Offset.zero);
          final bytes = captureScreenRectJpg(
            (o.dx * dpr).round(),
            (o.dy * dpr).round(),
            (box.size.width * dpr).round(),
            (box.size.height * dpr).round(),
          );
          return bytes == null ? null : img.decodeJpg(bytes);
        }
        try {
          final bytes = await _iawCtrl?.takeScreenshot();
          return bytes == null ? null : img.decodeImage(bytes);
        } catch (_) {
          return null;
        }
      }

      // ── 上端から順に撮って、 実際の送り量で貼っていく ──
      const maxSegments = 30;
      const maxTallPx = 12000;
      const overlapCss = 2; // 端の丸め誤差を吸収する重ね幅
      final segments = <img.Image>[];
      final tops = <int>[]; // 画像の中での貼り位置 (px)
      double pxPerCss = 1.0;
      var prevY = -1;
      var y = startY;
      for (var i = 0; i < maxSegments; i++) {
        final moved = await ev(
            '(function(){window.scrollTo(0, $y);return String(Math.round('
            'window.scrollY||document.documentElement.scrollTop||0));})();');
        var actual = y;
        if (moved != null) {
          final t = moved.replaceAll('"', '').trim();
          actual = int.tryParse(t) ?? y;
        }
        // ページが動かなくなったら終わり (一番下 or 動かせない)。
        if (i > 0 && actual == prevY) break;
        prevY = actual;
        await Future.delayed(const Duration(milliseconds: 380));
        final seg = await grabSegment();
        if (seg == null) break;
        if (i == 0) {
          // 1 画面が画像で何 px になるかを実測で決める (拡大率に左右されない)。
          pxPerCss = seg.height / viewH;
          // 2 枚目からは固定ヘッダーを隠す (1 枚目は本来の見た目を残す)。
          await ev(hideFixedJs);
        }
        final top = ((actual - startY) * pxPerCss).round();
        if (top + seg.height > maxTallPx) {
          segments.add(seg);
          tops.add(top);
          break;
        }
        segments.add(seg);
        tops.add(top);
        y = actual + viewH - overlapCss;
      }
      if (segments.isEmpty) return null;
      if (segments.length == 1) {
        final path = await _nextShotPath();
        await File(path)
            .writeAsBytes(img.encodeJpg(segments.first, quality: 85), flush: true);
        return path;
      }
      final width = segments.first.width;
      final totalH = tops.last + segments.last.height;
      final canvas = img.Image(width: width, height: totalH, numChannels: 3);
      for (var i = 0; i < segments.length; i++) {
        img.compositeImage(canvas, segments[i],
            dstY: tops[i], blend: img.BlendMode.direct);
      }
      final path = await _nextShotPath();
      await File(path)
          .writeAsBytes(img.encodeJpg(canvas, quality: 85), flush: true);
      return path;
    } catch (e) {
      debugPrint('縦長スクショに失敗: $e');
      return null;
    } finally {
      try {
        await ev(unhideFixedJs);
      } catch (_) {}
      if (mounted) setState(() => _autoPanelHiddenForShot = false);
    }
  }

  /// フローティングの自動操作パネル。
  ///
  /// [hidden] = 見えなくするだけ (木からは外さない)。 スクショの間に木から
  /// 外すと State ごと捨てられ、 作りかけの手順が消えてしまうため。
  /// オートクリッカーを浮かせて出す (= ユーザー要望: ブラウザの帯から)。
  ///
  /// ★ ページを見ながら使う道具なので、 塞がない小さな窓にして掴んで
  ///   動かせるようにする (「クリック手順」 の浮遊窓と同じ作法)。
  Widget _buildFloatingAutoClicker(MindMapProvider provider) {
    var size = MediaQuery.of(context).size;
    if (widget.windowWidth != null || widget.windowHeight != null) {
      size = Size(
          widget.windowWidth ?? size.width, widget.windowHeight ?? size.height);
    }
    // ★ = ユーザー要望: 縦長のパレットにしたので、 幅は細くする。
    final w = (size.width - 24).clamp(96.0, 150.0).toDouble();
    final h = (size.height - 120).clamp(280.0, 620.0).toDouble();
    final left = _autoClickerPos.dx.clamp(0.0, (size.width - w).clamp(0.0, 1e5));
    final top = _autoClickerPos.dy.clamp(0.0, (size.height - 60).clamp(0.0, 1e5));
    return Positioned(
      left: left,
      top: top,
      width: w,
      height: h,
      child: Material(
        color: const Color(0xFF15151F),
        elevation: 12,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          // 掴んで動かす帯。
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (d) => setState(() {
              _autoClickerPos = Offset(
                  _autoClickerPos.dx + d.delta.dx,
                  _autoClickerPos.dy + d.delta.dy);
            }),
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              color: const Color(0xFF1E1E2E),
              child: Row(children: [
                // ★ = ユーザー要望「ヘッダーの文字は要らない」「アイコン自体も
                //   意味がないから要らない」。 ここは掴む帯なので、 中身は
                //   閉じるだけにする (双子: lib/widgets/auto_clicker.dart)。
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _autoClickerOpen = false),
                  child: const SizedBox(
                    width: 30,
                    height: 30,
                    child: Icon(Icons.close_rounded,
                        size: 16, color: Colors.white54),
                  ),
                ),
              ]),
            ),
          ),
          Expanded(
            child: AutoClickerView(
              provider: provider,
              onRequestClose: () =>
                  setState(() => _autoClickerOpen = false),
              // この枠は自前の帯に閉じるを持っている (= × を 2 つ出さない)。
              hostHasCloseButton: true,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildFloatingAutoPanel(MindMapProvider provider,
      {bool hidden = false}) {
    var size = MediaQuery.of(context).size;
    // フローティング窓 / 外の窓の中では、 窓の実寸を基準にする
    // (MediaQuery は本体画面の大きさを返すため)。
    if (widget.windowWidth != null || widget.windowHeight != null) {
      size = Size(
          widget.windowWidth ?? size.width, widget.windowHeight ?? size.height);
    }
    // 画面に合わせて大きめに (= ユーザー要望: 自動操作の画面をもう少し
    // 大きく)。 画面が狭い時ははみ出さないよう縮める。
    // ── モバイルでも収まる大きさにする (= ユーザー要望: オーバーフロー
    //    してしまうので人間が使いやすいサイズに)。 画面幅いっぱいまで許し、
    //    高さは操作の邪魔にならないよう画面の 6 割程度に抑える。 ──
    final narrow = size.width < 560;
    // ── 専用画面 (automationOnly) は大きな全画面のフロー画面として使う
    //    (= ユーザー要望: もっと大きな全画面のフローの画面に)。 ページを
    //    開いていない間は窓いっぱい、 ページを見ながらの時は右に寄せて
    //    ページも見えるようにする。 ──
    final bigFlow = widget.automationOnly && !narrow;
    // ★ 後ろにブラウザを出していない間は、 窓いっぱいに広げる
    //   (= ユーザー要望: フローティングで 「枠の中に枠」 になるのをやめる)。
    //   自前の見出しも枠も出さず、 中の自動操作パネルだけを見せる。
    final fillWindow = widget.automationOnly && _browserHidden;
    // 畳むのは後ろを見せたい時だけ。 広げている間は畳まない
    //   (畳むと何も残らないため)。
    final collapsed = _autoPanelCollapsed && !fillWindow;
    final w = fillWindow
        ? size.width
        : narrow
            ? (size.width - 16).clamp(260.0, 460.0).toDouble()
            : bigFlow
                ? (size.width * 0.52).clamp(460.0, 1000.0).toDouble()
                : 460.0;
    final h = collapsed
        ? 42.0
        : (fillWindow
            ? size.height
            : narrow
                ? (size.height * 0.62)
                    .clamp(260.0, size.height - 120)
                    .toDouble()
                : bigFlow
                    ? (size.height - 72).clamp(320.0, 99999.0).toDouble()
                    : (size.height - 90).clamp(320.0, 720.0).toDouble());
    final double posLeft;
    final double posTop;
    if (fillWindow) {
      posLeft = 0;
      posTop = 0;
    } else if (bigFlow) {
      posLeft = (size.width - w - 12).clamp(0.0, 99999.0).toDouble();
      posTop = ((size.height - h) / 2).clamp(0.0, 36.0).toDouble();
    } else {
      posLeft =
          _autoPanelPos.dx.clamp(0.0, (size.width - w).clamp(0.0, 99999.0));
      posTop =
          _autoPanelPos.dy.clamp(0.0, (size.height - h).clamp(0.0, 99999.0));
    }
    return Positioned(
      left: posLeft,
      top: posTop,
      // hidden の間は描かないだけ (木からは外さない = State を保つ)。
      child: Offstage(
        offstage: hidden,
        child: Material(
        color: Colors.transparent,
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: const Color(0xFF1B1B2A),
            // 広げている間は角も枠も影も付けない (= 枠の二重を避ける)。
            borderRadius: fillWindow ? null : BorderRadius.circular(12),
            border: fillWindow ? null : Border.all(color: Colors.white24),
            boxShadow: fillWindow
                ? null
                : const [BoxShadow(color: Colors.black54, blurRadius: 18)],
          ),
          clipBehavior: fillWindow ? Clip.none : Clip.antiAlias,
          child: Column(children: [
            // ドラッグ用ヘッダー
            //   広げている間は出さない。 下の自動操作パネルに
            //   同じ 「自動操作」 の見出しがあり、 二重になるため
            //   (= ユーザー要望: 今の内枠だけでよい)。
            if (!fillWindow) GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => setState(() {
                _autoPanelPos += d.delta;
              }),
              child: Container(
                height: 30,
                color: const Color(0xFF23233A),
                padding: const EdgeInsets.only(left: 8, right: 2),
                child: Row(children: [
                  const Icon(Icons.drag_indicator_rounded,
                      size: 15, color: Colors.white38),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(provider.t('auto.title'),
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11.5)),
                  ),
                  // 実行中は停止ボタンだけにする (= ユーザー要望)。
                  if (_autoRunning)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: Colors.redAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 26),
                      ),
                      icon: const Icon(Icons.stop_rounded, size: 15),
                      label: Text(provider.t('auto.stop'),
                          style: const TextStyle(fontSize: 11)),
                      onPressed: () => _autoStop?.call(),
                    )
                  else ...[
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 26, minHeight: 26),
                      icon: Icon(
                          _autoPanelCollapsed
                              ? Icons.expand_more_rounded
                              : Icons.expand_less_rounded,
                          size: 16,
                          color: Colors.white54),
                      onPressed: () => setState(
                          () => _autoPanelCollapsed = !_autoPanelCollapsed),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 26, minHeight: 26),
                      icon: const Icon(Icons.close_rounded,
                          size: 16, color: Colors.white54),
                      onPressed: () {
                        // 自動操作だけを出している時は、 窓を閉じる =
                        // 画面ごと閉じる (= ユーザー要望)。
                        if (widget.automationOnly) {
                          _closeSelf();
                          return;
                        }
                        setState(() => _autoPanelOpen = false);
                      },
                    ),
                  ],
                ]),
              ),
            ),
            if (!collapsed)
              Expanded(
                child: WebAutomationPanel(
                  key: _autoPanelKey,
                  // ページとして開いている時は、 そのページ専用の置き場
                  // (= ユーザー要望: 自動操作をページとして設定できるように)。
                  storageKey: widget.automationStorageKey,
                  // 外側の帯を出さない時は、 見出しの端に閉じるを出す。
                  // ただし、 包んでいる側 (浮遊窓の帯など) がもう閉じるを
                  // 持っているなら出さない (= ユーザー要望: × が 2 つあるのを
                  // どちらか一方だけに)。
                  showCloseButton:
                      fillWindow && !widget.hostHasCloseButton,
                  // ★ = ユーザー要望: ページを移った先のエラーも拾うため、
                  //   「ページが出来るたびに流す JS」 を受け取る。
                  installPageScript: _autoInstallPageScript,
                  exec: _autoExecJs,
                  evalJs: _autoEvalJs,
                  // ★ = ユーザー報告「HP に飛んでと言っても飛べていない」。
                  //   ページ移動は JS ではなく WebView 自身に頼む。
                  openUrl: _autoOpenUrl,
                  onRecordingChanged: (rec) {
                    if (!mounted) return;
                    setState(() => _autoRecording = rec);
                  },
                  capture: _captureWebArea,
                  // ページ全体を 1 枚の縦長画像に (= ユーザー要望)。
                  captureFull: _captureFullPageTall,
                  // 外のブラウザ (CDP) で撮った絵の保存先 (= 採番はここが持つ)。
                  saveShotBytes: _saveShotBytes,
                  // 1 回の実行ごとに保存先を分ける (見せない実行でも)。
                  onRunStarted: () async {
                    try {
                      final d = await newAutomationRunDir();
                      _autoRunDir = d.path;
                    } catch (_) {}
                  },
                  pickPoint: _pickPointOnPage,
                  pickRect: _pickRectOnPage,
                  onClose: () {
                    // 自動操作だけを出している時は、 画面ごと閉じる。
                    if (widget.automationOnly) {
                      _closeSelf();
                      return;
                    }
                    setState(() => _autoPanelOpen = false);
                  },
                  onRunningChanged: (running, stop) async {
                    if (!mounted) return;
                    if (running) {
                      // 実行ごとに保存先フォルダを分ける (= ユーザー要望)。
                      try {
                        final d = await newAutomationRunDir();
                        _autoRunDir = d.path;
                      } catch (_) {}
                    }
                    if (!mounted) return;
                    setState(() {
                      _autoRunning = running;
                      _autoStop = stop;
                      // ★ 畳むのはやめた (= 上の ★ と同じ理由: 畳むと中身の
                      //   `WebAutomationPanel` が木から外れて State が消え、
                      //   走っている最中の処理が黙って止まる)。 走っている間は
                      //   上で Offstage にしてあるので、 見た目は今までどおり
                      //   「窓が引っ込んで停止ボタンだけ」 になる。
                    });
                  },
                ),
              ),
          ]),
        ),
      ),
      ),
    );
  }

  /// 自動操作の open 手順で、 WebView をその URL へ移す。
  ///
  /// ★ JS (`location.href`) だと、 操作口がまだ無い / about:blank から
  ///   動かせない / 例外が出る のどれでも**黙って何も起きない**。
  ///   ここでは WebView そのものに開かせて、 成否を返す。
  /// ★ 自動操作だけを出している間はブラウザを隠しているので、 開いた事を
  ///   控えて姿を見せる (隠れたまま進むと、 撮っても真っ暗になる)。
  Future<bool> _autoOpenUrl(String url) async {
    try {
      if (_isDesktop) {
        if (!_winInitialized) {
          // 操作口が出来るまで少し待つ (開いた直後に呼ばれる事がある)。
          for (var i = 0; i < 40 && !_winInitialized; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
        }
        final c = _winCtrl;
        if (c == null || !_winInitialized) return false;
        await c.loadUrl(url);
      } else {
        final c = _iawCtrl;
        if (c == null) return false;
        await c.loadUrl(urlRequest: iaw.URLRequest(url: iaw.WebUri(url)));
      }
      if (mounted) {
        // 実行している間は [_browserHidden] が false になるので、
        // ここで見せる細工は要らない (URL の控えだけ合わせる)。
        setState(() => _currentUrl = url);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 自動操作から預かった「ページが出来るたびに流す JS」。
  ///
  /// ★ = ユーザー要望「web ページでエラーが出た時のデバッグログを取れる
  ///   ように」。 今のページに入れるだけだと、 この後 open やリンクで
  ///   移った先のエラーが 1 つも残らない。 新しいタブを作った時にも
  ///   入れ直せるよう、 預かった物は控えておく。
  String? _autoPageScript;

  Future<void> _autoInstallPageScript(String js) async {
    _autoPageScript = js;
    if (!_isDesktop) return;
    try {
      await _winCtrl?.addScriptToExecuteOnDocumentCreated(js);
    } catch (_) {}
  }

  Future<void> _autoExecJs(String js) async {
    try {
      if (_isDesktop) {
        await _winCtrl?.executeScript(js);
      } else {
        await _iawCtrl?.evaluateJavascript(source: js);
      }
    } catch (_) {}
  }

  /// JS を評価して結果を文字列で受け取る (= ユーザー要望: テキストの
  /// 入力先要素を GUI で選べるように)。 取得できなければ null。
  Future<String?> _autoEvalJs(String js) async {
    try {
      if (_isDesktop) {
        final r = await _winCtrl?.executeScript(js);
        return r?.toString();
      }
      final r = await _iawCtrl?.evaluateJavascript(source: js);
      return r?.toString();
    } catch (_) {
      return null;
    }
  }

  /// WebView 本体 + 座標ピック用オーバーレイ。
  /// ヘッダーを隠している間にモバイルで出す、 戻すためだけの細い帯。
  ///
  /// ★ webview の外 (AppBar の場所) に置くのが肝。 重ねると Android では
  ///   触りを webview に奪われて押せない。
  PreferredSizeWidget _buildHiddenHeaderStrip(MindMapProvider provider) {
    // ★ 点検で判明: 自前の PreferredSize は AppBar と違って状態表示の帯
    //   (ノッチ / ステータスバー) を避けてくれない。 その分を自分で足す
    //   (足さないと、 押せるはずの帯が時計や電池の下に潜る)。
    final top = MediaQuery.paddingOf(context).top;
    return PreferredSize(
        preferredSize: Size.fromHeight(30 + top),
        child: Container(
          height: 30 + top,
          padding: EdgeInsets.only(top: top),
          color: const Color(0xFF1A1A1A),
          alignment: Alignment.center,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            InkWell(
              onTap: () => setState(() => _gsHeaderHidden = false),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.keyboard_arrow_down_rounded,
                      color: Colors.white70, size: 20),
                  const SizedBox(width: 6),
                  Text(provider.t('gs.showHeader'),
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 11.5)),
                ]),
              ),
            ),
          ]),
        ));
  }

  /// ヘッダーを隠している間に出す帯。
  ///
  /// ★ = ユーザー要望「タブは表示して、 ヘッダーボタンだけ隠す機能が欲しい。
  ///   タブを非表示とヘッダーを非表示のボタンを分けて 2 つ用意して欲しい」。
  ///   タブの帯は AppBar の `bottom` に居るので、 ヘッダーを隠すと**タブまで
  ///   一緒に消えて**いた。 2 つの印 ([_gsHeaderHidden] と
  ///   [_gsTabBarExpanded]) を切り離し、 ヘッダーを隠している間も
  ///   タブを出しているなら帯だけ残す。
  /// ★ 帯の左端にヘッダーを戻す山形を置く (隠している間の入口)。
  PreferredSizeWidget? _buildHeaderHiddenAppBar(
      MindMapProvider provider, bool isMobileHeader) {
    final showTabs =
        !widget.minimalMode && !isMobileHeader && _gsTabBarExpanded;
    if (!showTabs) {
      // タブも出していない時は今までどおり (指で使う端末だけ、 戻す帯を出す)。
      return _gsHoverCapable ? null : _buildHiddenHeaderStrip(provider);
    }
    final top = MediaQuery.paddingOf(context).top;
    return PreferredSize(
      preferredSize: Size.fromHeight(34 + top),
      child: Container(
        height: 34 + top,
        padding: EdgeInsets.only(top: top),
        color: const Color(0xFF0E0E1A),
        child: Row(children: [
          Tooltip(
            message: provider.t('gs.showHeader'),
            child: InkWell(
              onTap: () => setState(() => _gsHeaderHidden = false),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.keyboard_arrow_down_rounded,
                    color: Colors.white70, size: 18),
              ),
            ),
          ),
          Expanded(child: _buildGsTabBar()),
        ]),
      ),
    );
  }

  Widget _buildWebView() {
    final picking = !_autoPanelHiddenForShot &&
        (_pickPointCompleter != null || _pickRectCompleter != null);
    // 記録中はタップを拾って記録 → 同じ位置をページへ送る (= ユーザー要望)。
    final recording = _autoRecording && !_autoPanelHiddenForShot;
    return Stack(
      key: _webAreaKey,
      children: [
        Positioned.fill(child: _buildWebViewCore()),
        if (!picking && recording)
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              // ホイール / スワイプのスクロールも記録する。
              onPointerSignal: (e) {
                if (e is PointerScrollEvent) {
                  _autoPanelKey.currentState?.recordScroll(e.scrollDelta.dy);
                }
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  // ignore: discarded_futures
                  _autoPanelKey.currentState?.recordTap(d.localPosition);
                },
                child: Container(
                  color: const Color(0x14E57373),
                  alignment: Alignment.topCenter,
                  child: Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xCCE57373),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.fiber_manual_record_rounded,
                          size: 12, color: Colors.white),
                      const SizedBox(width: 5),
                      Text(
                          context
                              .read<MindMapProvider>()
                              .t('auto.recordingBadge'),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        if (picking)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _handlePickTap(d.localPosition),
              child: Container(
                color: const Color(0x224FC3F7),
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.only(
                      left: 12, right: 4, top: 4, bottom: 4),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      _pickRectCompleter != null
                          ? (_pickRectFirst == null
                              ? context.read<MindMapProvider>().t('auto.pickA')
                              : context.read<MindMapProvider>().t('auto.pickB'))
                          : context.read<MindMapProvider>().t('auto.pickTap'),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(width: 8),
                    // ── やめる (= 指すのを取り消して欄に戻る) ──
                    //   指している間は自動操作の欄を引っ込めているので、
                    //   ここに出口が無いと戻れなくなる。
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 26),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _cancelPick,
                      child: Text(
                          context.read<MindMapProvider>().t('btn.cancel'),
                          style: const TextStyle(fontSize: 11)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
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
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerPanZoomStart: (_) => _beginDesktopMapPinch(tab),
      onPointerPanZoomUpdate: (event) =>
          _updateDesktopMapPinch(tab, event),
      onPointerPanZoomEnd: (_) => _endDesktopMapPinch(tab),
      onPointerSignal: (event) =>
          _handleDesktopMapPointerSignal(tab, event),
      child: wv_win.Webview(
        tab.winCtrl!,
        // 位置情報などの権限要求を許可する (= ユーザー要望: Google マップ /
        // Earth を開いた時に現在地を有効化できるように)。
        permissionRequested: (url, kind, isUserInitiated) async =>
            wv_win.WebviewPermissionDecision.allow,
      ),
    );
  }

  /// モバイル: 1 タブ分の InAppWebView。 keepAlive で切替時の状態を保持する。
  /// 広告落としを 1 枚の WebView へ当てる (モバイル用)。
  ///
  /// 名前で分かる広告 (広告用の CSS 選択子 + 「スポンサー」 等の札) を
  /// 隠す JS を入れるだけ。 外へは何も送らない。
  Future<void> _applyAdBlock(iaw.InAppWebViewController c) async {
    if (!mounted) return;
    final prov = context.read<MindMapProvider>();
    final js = prov.adBlockInstallJsOrNull();
    if (js == null) {
      // ★ 切っている時は、 前に隠した分を戻す (= 切ったのに戻らない対策。
      //   このページには前の読み込みで入れた style / 見張りが残っている)。
      try {
        await c.evaluateJavascript(source: googleAdBlockRemoveJs);
      } catch (_) {}
      return;
    }
    try {
      await c.evaluateJavascript(source: js);
    } catch (_) {}
  }

  /// 広告落とし (名前で分かる広告を CSS で隠す) の入切を切り替える。
  ///
  /// = ユーザー要望「設定の奥ではなく、 使う画面から入切できるように」。
  /// ★ 切り替えたら [_reapplyAdBlockToOpenTabs] で **今 開いているページへ
  ///   その場で当て直す**。 読み込み直しはしない (見ている所が消えるので)。
  Future<void> _toggleAdBlock() async {
    final prov = context.read<MindMapProvider>();
    await prov.setAdBlockEnabled(!prov.adBlockEnabled);
    if (!mounted) return;
    await _reapplyAdBlockToOpenTabs();
  }

  /// 今の広告落とし設定を、 開いている全タブへその場で当て直す。
  ///
  /// ★ 落とし穴: デスクトップの差し込みは
  ///   `addScriptToExecuteOnDocumentCreated` (= タブを作る時にしか入らない)、
  ///   モバイルは `onLoadStop` 頼み。 どちらも「今 見ているページ」 には
  ///   後から当たらないので、 切り替えただけでは黙って効かない。
  /// ★ まず [googleAdBlockRemoveJs] で必ず素へ戻す (style / 見張り /
  ///   付けた目印を消す)。 入っていればその上で入れ直すので、
  ///   入→切・切→入 のどちらも同じ道で片が付く。
  /// ★ デスクトップは doc-created の登録も合わせる (入れた時は登録し、 切った
  ///   時は id で外す)。 そうしないと **次に開くページ** でまた食い違う。
  Future<void> _reapplyAdBlockToOpenTabs() async {
    if (!mounted) return;
    final prov = context.read<MindMapProvider>();
    final install = prov.adBlockInstallJsOrNull(); // 切っている時は null
    for (final t in _gsTabs) {
      try {
        if (_isDesktop) {
          final c = t.winCtrl;
          if (c == null || !t.winReady) continue;
          final id = t.adScriptId;
          if (install == null) {
            if (id != null) {
              t.adScriptId = null;
              await c.removeScriptToExecuteOnDocumentCreated(id);
            }
          } else if (id == null) {
            t.adScriptId =
                await c.addScriptToExecuteOnDocumentCreated(install);
          }
          await c.executeScript(googleAdBlockRemoveJs);
          if (install == null) continue;
          await c.executeScript(install);
        } else {
          final c = t.iawCtrl;
          if (c == null) continue;
          await c.evaluateJavascript(source: googleAdBlockRemoveJs);
          if (install == null) continue;
          if (identical(t, _activeTab)) {
            await _applyAdBlock(c);
          } else {
            await c.evaluateJavascript(source: install);
          }
        }
      } catch (_) {}
    }
  }

  /// 広告落としの項目 (入っている時は ✓)。 PC のヘッダーと「⋮」 で共用。
  PopupMenuItem<String> _gsAdBlockItem({
    required String value,
    required IconData icon,
    required bool on,
    required String label,
    bool enabled = true,
  }) {
    final color = on ? const Color(0xFF7FD8A0) : Colors.white38;
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      enabled: enabled,
      child: Row(children: [
        Icon(
            on
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded,
            color: color,
            size: 17),
        const SizedBox(width: 8),
        Icon(icon, color: color, size: 17),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(label,
              maxLines: 2,
              style: TextStyle(
                  color: enabled ? Colors.white : Colors.white38,
                  fontSize: 13)),
        ),
      ]),
    );
  }

  Widget _buildIawTabWebView(int i) {
    final tab = _gsTabs[i];
    return iaw.InAppWebView(
      // タブ固有の安定キー (keepAlive 由来)。 アクティブタブのみ描画する構成で
      //   タブ切替時にプラットフォームビューが churn しないようにする。
      key: ValueKey('gsiaw_${tab.iawKeepAlive.hashCode}'),
      keepAlive: tab.iawKeepAlive,
      initialUrlRequest: iaw.URLRequest(url: iaw.WebUri(tab.url)),
      // ── 位置情報 (= ユーザー要望: Google マップ / Earth で現在地を使える
      //    ように)。 端末側の権限を求めた上で、 サイトからの要求を許可する。 ──
      onGeolocationPermissionsShowPrompt: (c, origin) async {
        try {
          if (!await Permission.location.isGranted) {
            await Permission.location.request();
          }
        } catch (_) {}
        return iaw.GeolocationPermissionShowPromptResponse(
            origin: origin, allow: true, retain: true);
      },
      onPermissionRequest: (c, req) async =>
          iaw.PermissionResponse(
              resources: req.resources,
              action: iaw.PermissionResponseAction.GRANT),
      initialSettings: iaw.InAppWebViewSettings(
        javaScriptEnabled: true,
        // ── ピンチによる拡大・縮小を有効化 (= ユーザー要望: Google マップ/Earth
        //    等で拡大縮小ジェスチャーに対応) ──
        //   Android の WebView はピンチズームを既定で無効化しており、
        //   builtInZoomControls を true にしないと二本指ズームが効かない。
        //   +/- のオンスクリーンボタンは邪魔なので displayZoomControls で隠す。
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        // 透明背景を無効化 (= ユーザー報告: Android で WebView が見えない/
        //   真っ白になる対策。 透明合成だと中身が描画されないことがある)。
        transparentBackground: false,
        // shouldOverrideUrlLoading コールバックを有効化 (= intent:// 等を弾く)
        useShouldOverrideUrlLoading: true,
        // Drive等のContent-Disposition / blobダウンロードをFlutter側で保存する。
        useOnDownloadStart: true,
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
      onDownloadStartRequest: (controller, request) {
        unawaited(_handleMobileWebDownload(controller, request));
      },
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
        // スクロールバーは、 動かした時とバーに触れた時だけ出す
        // (= ユーザー要望)。 読み込みのたびに入れ直す (二重実行は先頭の
        // 見張りで弾かれる)。
        c.evaluateJavascript(source: _kGsAutoHideScrollbarJs);
        // 広告落とし (= ユーザー要望)。 モバイルは doc-created の口が
        //   無いのでここで入れる。 二重実行は JS 側で弾く。
        _applyAdBlock(c);
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
        // ★ Google は検索し直しても onLoadStop が走らない。 広告落としは
        //   ここでも当てる (= 2 回目の検索で広告が戻るのを防ぐ)。
        _applyAdBlock(c);
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
            // ★ = ユーザー要望「メモ欄に編集中であっても『編集中』 と書かないで
            //   欲しい、 邪魔」。 編集中は札を出さない (鉛筆のアイコンと ✕ で
            //   じゅうぶん分かる)。 「新規メモ」 の時は今までどおり出す。
            Expanded(
              child: isEditing
                  ? const SizedBox.shrink()
                  : Text(
                      provider.t('googleSearch.newMemo'),
                      style: const TextStyle(
                        color: Colors.white,
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
          // 貼った画像 / PDF (= ユーザー要望)。
          _buildMemoAttachmentChips(),
          const SizedBox(height: 6),
          // アクションボタン (横並び 2 つ)
          Row(
            children: [
              // 画像 / PDF を貼る (= ユーザー要望)。
              IconButton(
                icon: const Icon(Icons.attach_file_rounded,
                    color: Color(0xFF80CBC4), size: 19),
                tooltip: provider.t('gs.memoAttach'),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(),
                onPressed: () {
                  // ignore: discarded_futures
                  _pickMemoAttachment();
                },
              ),
              const SizedBox(width: 4),
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
                tooltip: context.read<MindMapProvider>().t('gs.memoToDeepl'),
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
                    // 貼ってある画像 / PDF の数 (= ユーザー要望)。
                    if (memo.attachments.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.attach_file_rounded,
                          size: 11, color: Color(0xFF80CBC4)),
                      Text('${memo.attachments.length}',
                          style: const TextStyle(
                              color: Color(0xFF80CBC4), fontSize: 10)),
                    ],
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
                      tooltip: context.read<MindMapProvider>().t('gs.sendToAi'),
                      onTap: () => _sendTextToAi(memo.text),
                    ),
                    const SizedBox(width: 2),
                    // ── メモの中身で YouTube を探す (= ユーザー要望:
                    //    「メモ欄の内容で youtube 検索を掛けられるボタン」) ──
                    _miniIconButton(
                      icon: Icons.smart_display_rounded,
                      color: const Color(0xFFE57373),
                      tooltip: provider.t('gs.searchYoutube'),
                      onTap: () => _searchYoutubeWithText(memo.text),
                    ),
                    const SizedBox(width: 2),
                    // ── メモを DeepL に送る (= ユーザー要望: メモ内容を翻訳) ──
                    _miniIconButton(
                      icon: Icons.translate_rounded,
                      color: const Color(0xFF0F73B8),
                      tooltip: context.read<MindMapProvider>().t('gs.sendToDeepl'),
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

  /// メモの中身で YouTube を探す (= ユーザー要望: 「google 検索のメモ欄の
  /// 内容で youtube 検索を掛けられるボタンを実装して欲しい」)。
  ///
  /// ★ 新しいタブで開く (= 今見ているページを潰さない)。 メモは何行にも
  ///   なるので、 探す語は**1 行目**にして、 長すぎる時は切る
  ///   (YouTube の検索欄は長い文を入れても結果が返らない)。
  void _searchYoutubeWithText(String raw) {
    var q = raw.trim();
    if (q.isEmpty) return;
    final nl = q.indexOf('\n');
    if (nl > 0) q = q.substring(0, nl).trim();
    if (q.runes.length > 80) {
      q = String.fromCharCodes(q.runes.take(80));
    }
    if (q.isEmpty) return;
    final url =
        'https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(q)}';
    if (_gsTabs.length < _kGsMaxTabs) {
      _gsTabs[_gsActiveTab].url = _currentUrl;
      setState(() {
        _gsTabs.add(_GsTab(url: url, title: 'YouTube'));
        _gsActiveTab = _gsTabs.length - 1;
        _currentUrl = url;
        _pageTitle = 'YouTube';
      });
    }
    _openUrl(url);
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
              // 名前と切り替えボタンをくっつける (= ユーザー要望: 切り替えは
              //   名前のすぐ右に)。 名前が長い時だけ縮める。
              Flexible(
                child: Text(_aiPanelHeaderLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ),
              PopupMenuButton<String>(
                tooltip: context.read<MindMapProvider>().t('gs.chooseAi'),
                icon: const Icon(Icons.expand_more_rounded,
                    color: Colors.white70, size: 18),
                color: const Color(0xFF1E1E32),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                onSelected: _openAiPanel,
                itemBuilder: (_) => _aiMenuItems(),
              ),
              // 名前 + 切り替えの右は空けて、 道具のボタンを右端へ寄せる。
              const Spacer(),
              // ── 浮遊窓にする / 欄に戻す (= ユーザー要望) ──
              IconButton(
                tooltip: provider.t(
                    _aiPanelFloating ? 'gs.aiDock' : 'gs.aiFloat'),
                icon: Icon(
                    _aiPanelFloating
                        ? Icons.picture_in_picture_alt_rounded
                        : Icons.open_in_new_rounded,
                    color: _aiPanelFloating
                        ? const Color(0xFF4FC3F7)
                        : Colors.white70,
                    size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () =>
                    setState(() => _aiPanelFloating = !_aiPanelFloating),
              ),
              // ── AI チャット画面を再読み込み (= ユーザー要望) ──
              IconButton(
                tooltip: context.read<MindMapProvider>().t('gs.reloadAi'),
                icon: const Icon(Icons.refresh_rounded,
                    color: Colors.white70, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: _reloadGsAiPanel,
              ),
              if (showSwap)
                IconButton(
                  tooltip: context.read<MindMapProvider>().t('gs.swapMemoAi'),
                  icon: const Icon(Icons.swap_horiz_rounded,
                      color: Colors.white70, size: 18),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () =>
                      _togglePanelsSwapped(),
                ),
              IconButton(
                tooltip: context.read<MindMapProvider>().t('gs.closeAi'),
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
      return Center(
        child: Text(context.read<MindMapProvider>().t('gs.chooseAiFirst'),
            style: const TextStyle(color: Colors.white38, fontSize: 12)),
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
      return wv_win.Webview(
        _aiWinCtrl,
        permissionRequested: (url, kind, isUserInitiated) async =>
            wv_win.WebviewPermissionDecision.allow,
      );
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
    // 浮遊表示中は横の欄には出さない (= ユーザー要望)。
    if (_aiPanelFloating) return const [];
    final ai = _aiSidePanel(provider);
    return ai != null ? [ai] : const [];
  }

  /// AI 欄の浮遊窓 (= ユーザー要望: AI チャット欄もフローティングで使いたい)。
  Widget _buildFloatingAiPanel(MindMapProvider provider) {
    final screen = MediaQuery.of(context).size;
    final w = _aiFloatW.clamp(300.0, screen.width);
    final h = _aiFloatH.clamp(240.0, screen.height);
    final maxLeft = math.max(0.0, screen.width - w);
    final maxTop = math.max(0.0, screen.height - h);
    return Positioned(
      left: _aiFloatPos.dx.clamp(0.0, maxLeft),
      top: _aiFloatPos.dy.clamp(0.0, maxTop),
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E32),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 18)],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(children: [
            Column(children: [
              // ドラッグ用の帯 (パネル自身のヘッダーは中に残る)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => setState(() => _aiFloatPos += d.delta),
                child: Container(
                  height: 18,
                  color: const Color(0xFF12121C),
                  alignment: Alignment.center,
                  child: const Icon(Icons.drag_handle_rounded,
                      size: 14, color: Colors.white38),
                ),
              ),
              Expanded(child: _buildAiPanel(provider, showSwap: false)),
            ]),
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => setState(() {
                  _aiFloatW = (_aiFloatW + d.delta.dx)
                      .clamp(300.0, screen.width);
                  _aiFloatH = (_aiFloatH + d.delta.dy)
                      .clamp(240.0, screen.height);
                }),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.south_east_rounded,
                      size: 14, color: Colors.white38),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
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
                  Text(context.read<MindMapProvider>().t('gs.memo'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  // メモと AI を左右入れ替え (= AI 側ボタンと色を揃えて白に)
                  IconButton(
                    icon: const Icon(Icons.swap_horiz_rounded,
                        color: Colors.white70, size: 20),
                    tooltip: context.read<MindMapProvider>().t('gs.swapAiMemo'),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    onPressed: () =>
                        _togglePanelsSwapped(),
                  ),
                  // × 閉じる
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white70, size: 20),
                    tooltip: context.read<MindMapProvider>().t('gs.closeMemoKey'),
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
                // ── ページに埋め込む時にリンクも含めるか (= ユーザー要望:
                //    「リンクまで含めるかどうかは設定で変えられるように」) ──
                //    覚える設定なので、 次に開いた時もこのままになる。
                IconButton(
                  icon: Icon(
                      provider.gsMemoEmbedLink
                          ? Icons.link_rounded
                          : Icons.link_off_rounded,
                      color: provider.gsMemoEmbedLink
                          ? const Color(0xFF4FC3F7)
                          : Colors.white38,
                      size: 18),
                  tooltip: provider.t(provider.gsMemoEmbedLink
                      ? 'gs.embedLinkTip'
                      : 'gs.embedLinkOffTip'),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => unawaited(
                      provider.setGsMemoEmbedLink(!provider.gsMemoEmbedLink)),
                ),
                // ＋新規メモ (= PDF ビューアの「フリーメモ」 ボタンに相当)
                IconButton(
                  icon: const Icon(Icons.note_add_rounded,
                      color: Color(0xFFFFB347), size: 18),
                  tooltip: context.read<MindMapProvider>().t('gs.newMemo'),
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

  Widget _mobileHeaderActionShell({
    required Widget icon,
    required String label,
    required Color color,
  }) {
    return Container(
      width: 70,
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.34)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mobileHeaderAction({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    return Tooltip(
      message: tooltip ?? label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: _mobileHeaderActionShell(
          icon: Icon(icon, color: color, size: 17),
          label: label,
          color: color,
        ),
      ),
    );
  }

  Widget _buildMobileHeaderTools(MindMapProvider provider) {
    final splitColor =
        _gsSplitDown ? const Color(0xFF4FC3F7) : const Color(0xFFFF6B6B);
    final actions = <Widget>[
      _mobileHeaderAction(
        icon: _gsTabBarExpanded
            ? Icons.view_week_rounded
            : Icons.view_week_outlined,
        label: context.read<MindMapProvider>().t('gs.tabShort'),
        color: const Color(0xFF4FC3F7),
        tooltip: context
            .read<MindMapProvider>()
            .t(_gsTabBarExpanded ? 'gs.tabsHide' : 'gs.tabsShow'),
        onTap: () => setState(() => _gsTabBarExpanded = !_gsTabBarExpanded),
      ),
      if (widget.onMoveToSplitPanel != null)
        Tooltip(
          message: _gsSplitDown ? '下分割で開く\n長押しで上分割へ切替' : '上分割で開く\n長押しで下分割へ切替',
          child: InkWell(
            onTap: () {
              widget.onMoveToSplitPanel!(_currentUrl,
                  isLeftPanel: !_gsSplitDown);
              _closeSelf();
            },
            onLongPress: () {
              setState(() => _gsSplitDown = !_gsSplitDown);
              ScaffoldMessenger.of(context)
                ..clearSnackBars()
                ..showSnackBar(SnackBar(
                  content: Text(_gsSplitDown ? '下分割' : '上分割'),
                  duration: const Duration(milliseconds: 900),
                  backgroundColor: const Color(0xFF2A2A3E),
                ));
            },
            borderRadius: BorderRadius.circular(8),
            child: _mobileHeaderActionShell(
              icon: _gSearchSplitIcon(
                _gsSplitDown
                    ? _GSearchSplitIconFill.bottom
                    : _GSearchSplitIconFill.top,
                color: splitColor,
                size: 17,
              ),
              label: _gsSplitDown ? '下分割' : '上分割',
              color: splitColor,
            ),
          ),
        ),
      _mobileHeaderAction(
        icon: _aiPanelOpen ? Icons.smart_toy_rounded : Icons.smart_toy_outlined,
        label: 'AI',
        color: const Color(0xFF4FC3F7),
        tooltip: context
            .read<MindMapProvider>()
            .t(_aiPanelOpen ? 'gs.aiClose' : 'gs.aiOpen'),
        onTap: () {
          if (_aiPanelOpen) {
            setState(() => _aiPanelOpen = false);
          } else {
            _openAiPanel(_aiDefaultId);
          }
        },
      ),
      _mobileHeaderAction(
        icon: Icons.ios_share_rounded,
        label: '共有',
        color: const Color(0xFF4FC3F7),
        onTap: _shareSearchPageWithAi,
      ),
      PopupMenuButton<double>(
        tooltip: context.read<MindMapProvider>().t('gs.videoRate'),
        color: const Color(0xFF1E1E32),
        padding: EdgeInsets.zero,
        onSelected: (r) {
          setState(() => _searchVideoRate = r);
          _applySearchVideoRate(r);
        },
        itemBuilder: (_) => [
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
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ]),
            ),
        ],
        child: _mobileHeaderActionShell(
          icon: Icon(
            _searchVideoRate == 1.0
                ? Icons.speed_rounded
                : Icons.slow_motion_video_rounded,
            color: const Color(0xFF4FC3F7),
            size: 17,
          ),
          label: '速度',
          color: const Color(0xFF4FC3F7),
        ),
      ),
      // 戻る/進む/更新 は検索バーに常設したのでここには置かない (= ユーザー要望)。
      _mobileHeaderAction(
        icon: Icons.sticky_note_2_rounded,
        label: 'メモ',
        color: const Color(0xFFFFB347),
        onTap: () => setState(() => _memoPanelExpanded = !_memoPanelExpanded),
      ),
      _mobileHeaderAction(
        icon: Icons.add_link_rounded,
        label: '埋込',
        color: const Color(0xFF43B97F),
        onTap: _addPageInfoAsNode,
      ),
      _mobileHeaderAction(
        icon: Icons.bookmark_add_rounded,
        label: '保存',
        color: const Color(0xFFFFB347),
        onTap: _addCurrentPageToBookmarks,
      ),
      // ── 広告を隠す (= ユーザー要望: 使う画面から入切できるように) ──
      //    押した後はその場で当て直すので、 読み込み直しは要らない。
      _mobileHeaderAction(
        icon: provider.adBlockEnabled
            ? Icons.block_rounded
            : Icons.block_outlined,
        label: '広告',
        color: provider.adBlockEnabled
            ? const Color(0xFF7FD8A0)
            : Colors.white54,
        tooltip: provider.t('jev.adBlock'),
        onTap: () => _toggleAdBlock(),
      ),
      // ── スクショ (= ユーザー要望: PDF ボタンは分かりにくいのでスクショに変更) ──
      if (!_isDesktop)
        _mobileHeaderAction(
          icon: Icons.photo_camera_rounded,
          label: 'スクショ',
          color: const Color(0xFFBA68C8),
          tooltip: context.read<MindMapProvider>().t('gs.shotToMap'),
          onTap: _captureViewportAndAdd,
        ),
    ];

    return Container(
      height: _gsTabBarExpanded ? 92 : 52,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF171720),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 格納ボタンは横一列 (= ユーザー要望)。 入り切らない時は横スクロール。──
          SizedBox(
            height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    actions[i],
                  ],
                ],
              ),
            ),
          ),
          if (_gsTabBarExpanded)
            SizedBox(
              height: 34,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _buildGsTabBar(),
              ),
            ),
        ],
      ),
    );
  }

  /// 現在表示中のページを 1 枚スクショしてマップに追加する
  /// (= ユーザー要望: PDF ボタンは分かりにくいのでスクショに変更)。
  /// Windows では WebView2 にスクショ API が無いため、 ページ情報を
  /// テキストノードとして追加する (= 他のスクショ機能と同じ fallback)。
  Future<void> _captureViewportAndAdd() async {
    if (_iawCtrl == null) {
      await _addPageInfoAsNode();
      return;
    }
    _showCaptureSnack(context.read<MindMapProvider>().t('gs.takingShot'), const Color(0xFF4FC3F7));
    try {
      final png = await _iawCtrl!.takeScreenshot();
      if (png == null) {
        _showCaptureSnack(context.read<MindMapProvider>().t('gs.shotFailed'), const Color(0xFFE57373));
        return;
      }
      await _saveScreenshotAsNode(png);
    } catch (e) {
      _showCaptureSnack(context.read<MindMapProvider>().t('gs.shotGenFailed').replaceFirst('{e}', '$e'), const Color(0xFFE57373));
    }
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
    final showTwoSplit = _isDesktop && toolbarW >= 440;
    final isMobileHeader = !useHorizontal && !widget.minimalMode;

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
            // ── 座標ピック中は「選択モードの解除」 だけを行う
            //    (= ユーザー報告: Esc で検索画面ごと閉じてしまう) ──
            if (_pickPointCompleter != null || _pickRectCompleter != null) {
              final pc = _pickPointCompleter;
              final rc = _pickRectCompleter;
              setState(() {
                _pickPointCompleter = null;
                _pickRectCompleter = null;
                _pickRectFirst = null;
              });
              pc?.complete(null);
              rc?.complete(null);
              return;
            }
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
            backgroundColor: _browserHidden
                ? Colors.transparent
                : const Color(0xFF121212),
            // ヘッダーを隠している間は AppBar ごと出さない (= ユーザー要望)。
            //
            // ★ = ユーザー報告「モバイル版の google 検索のヘッダー項目を
            //   非表示にすると、 ヘッダー項目を戻すことができない」。
            //   戻す山形は本文の上に**重ねて**置いていたが、 Android の
            //   InAppWebView は画面に貼り付いた OS の部品なので、 その矩形に
            //   重ねた Flutter の部品は**見えているのに押せない**
            //   (触りが webview に吸われる)。 だからモバイルでは重ねずに、
            //   webview の外側である AppBar の場所へ細い帯を出す。
            appBar: (widget.hideAppBar || _browserHidden)
                ? null
                // ★ ヘッダーを隠していても、 タブを出しているなら帯は残す
                //   (= ユーザー要望: タブとヘッダーを別々に隠せるように)。
                : _gsHeaderHidden
                    ? _buildHeaderHiddenAppBar(provider, isMobileHeader)
                    : AppBar(
                    backgroundColor: const Color(0xFF1A1A1A),
                    elevation: 0,
                    automaticallyImplyLeading: false,
                    // ★ 帯の**何もない所**を押したら畳む (= ユーザー要望)。
                    //   `flexibleSpace` は題と操作より**後ろ**に敷かれるので、
                    //   ボタンや入力欄を押した時はそちらが先に受け取る。
                    //   タブの帯は自前の受け口 (opaque) が押しを吸うので、
                    //   そこを押しても畳まない。
                    //   戻せる口を持たない触る端末では畳ませない。
                    flexibleSpace: _gsHoverCapable
                        ? GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () =>
                                setState(() => _gsHeaderHidden = true),
                          )
                        : null,
                    title: _buildSearchBar(provider),
                    titleSpacing: 12,
                    toolbarHeight: 56,
                    // 上部のタブバー（= ユーザー要望: Google 検索も複数タブ + フォルダー）
                    // 小さいウィンドウ (minimalMode) ではスペースが限られるため、 タブバー
                    //   ヘッダー自体を表示しない (= ユーザー要望)。 タブ操作は全画面表示に
                    //   切り替えるか、 Ctrl+W / Ctrl+Shift+T のショートカットで行える。
                    bottom: widget.minimalMode
                        ? null
                        : isMobileHeader && _gsMobileToolsExpanded
                            ? PreferredSize(
                                preferredSize: Size.fromHeight(
                                    _gsTabBarExpanded ? 92 : 52),
                                child: _buildMobileHeaderTools(provider),
                              )
                            : isMobileHeader || !_gsTabBarExpanded
                                ? null
                                : PreferredSize(
                                    preferredSize: const Size.fromHeight(34),
                                    child: _buildGsTabBar(),
                                  ),
                    actions: [
                      if (isMobileHeader)
                        IconButton(
                          icon: Icon(
                            _gsMobileToolsExpanded
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.apps_rounded,
                            color: Colors.white70,
                            size: 22,
                          ),
                          tooltip: _gsMobileToolsExpanded ? '操作を隠す' : '操作を表示',
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(),
                          onPressed: () => setState(() =>
                              _gsMobileToolsExpanded = !_gsMobileToolsExpanded),
                        ),
                      if (!widget.minimalMode && useHorizontal)
                        IconButton(
                          icon: Icon(
                            _gsTabBarExpanded
                                ? Icons.view_week_rounded
                                : Icons.view_week_outlined,
                            color: _gsTabBarExpanded
                                ? const Color(0xFF4FC3F7)
                                : Colors.white70,
                            size: 22,
                          ),
                          tooltip: context.read<MindMapProvider>().t(
                              _gsTabBarExpanded
                                  ? 'gs.tabsHide'
                                  : 'gs.tabsShow'),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(),
                          onPressed: () => setState(
                              () => _gsTabBarExpanded = !_gsTabBarExpanded),
                        ),
                      // ── メモ欄の表示/非表示トグル (横分割時のみ) ──
                      // 縦分割 (モバイル) では _buildCollapsibleMemoPanel のヘッダーが
                      //   開閉を担うため、 ここでは横分割時のみ出す。
                      if (useHorizontal && !widget.minimalMode)
                        IconButton(
                          icon: Icon(
                            _memoSideExpanded
                                ? Icons.sticky_note_2_rounded
                                : Icons.sticky_note_2_outlined,
                            // ★ 開いている時だけ色を付ける (= ユーザー要望)。
                            color: _memoSideExpanded
                                ? const Color(0xFFFFB347)
                                : Colors.white70,
                            size: 22,
                          ),
                          tooltip: (_memoSideExpanded
                                  ? provider.t('gsearch.hideMemo')
                                  : provider.t('gsearch.showMemo')) +
                              ' (Ctrl+M)',
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(),
                          onPressed: () => setState(
                              () => _memoSideExpanded = !_memoSideExpanded),
                        ),
                      // ── モバイル: 分割ボタンは検索バー右端の操作群内で、
                      //    「その他」メニューの直前に置く。縦分割なので上/下を
                      //    塗ったアイコンで示す。 長押しで上分割⇔下分割を切り替え、
                      //    アイコンも追従する (= ユーザー要望)。 タップは現在の方向。
                      if (!useHorizontal &&
                          !widget.minimalMode &&
                          !isMobileHeader &&
                          widget.onMoveToSplitPanel != null)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            widget.onMoveToSplitPanel!(_currentUrl,
                                isLeftPanel: !_gsSplitDown);
                            _closeSelf();
                          },
                          onLongPress: () {
                            setState(() => _gsSplitDown = !_gsSplitDown);
                            ScaffoldMessenger.of(context)
                              ..clearSnackBars()
                              ..showSnackBar(SnackBar(
                                content: Text(_gsSplitDown ? '下分割' : '上分割'),
                                duration: const Duration(milliseconds: 900),
                                backgroundColor: const Color(0xFF2A2A3E),
                              ));
                          },
                          child: Tooltip(
                            message: _gsSplitDown ? '下分割で開く' : '上分割で開く',
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: _gSearchSplitIcon(
                                _gsSplitDown
                                    ? _GSearchSplitIconFill.bottom
                                    : _GSearchSplitIconFill.top,
                                // 押すだけのボタンは白 (= ユーザー要望)。
                                color: Colors.white70,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      // ── AI 欄の開閉トグル (= ユーザー要望: 5 種の AI をサイドで
                      //    開けるように) ──
                      // 閉じていれば既定 AI で開き、 開いていれば閉じる。
                      if (!widget.minimalMode && !isMobileHeader)
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
                              // ★ 開いている時だけ色を付ける (= ユーザー要望)。
                              color: _aiPanelOpen
                                  ? const Color(0xFF4FC3F7)
                                  : Colors.white70,
                              size: 22,
                            ),
                            tooltip: () {
                              // 多言語対応 (= ユーザー報告)。
                              final p = context.read<MindMapProvider>();
                              final hint = p.t(_isDesktop
                                  ? 'gs.hintRightClick'
                                  : 'gs.hintLongPress');
                              return '${p.t(_aiPanelOpen ? 'gs.aiClose' : 'gs.aiOpen')} (F4)\n'
                                  '${p.t('gs.aiSwitchHint').replaceFirst('{hint}', hint)}';
                            }(),
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
                      if (!widget.minimalMode && !isMobileHeader)
                        IconButton(
                          icon: const Icon(Icons.ios_share_rounded,
                              color: Colors.white70, size: 20),
                          tooltip: context.read<MindMapProvider>().t('gs.sharePageAi'),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(),
                          onPressed: _shareSearchPageWithAi,
                        ),
                      // ── 動画の再生速度 (= ユーザー要望: Google 検索で出てきた埋め込み
                      //    動画の再生速度を変えられるように) ──
                      // ★ = ユーザー要望「再生速度はスライドバー設定の方が
                      //   嬉しい」。 0.5 倍刻みの一覧から、 つまみを滑らせて
                      //   決める形にした ([_buildVideoRateButton])。
                      if (!widget.minimalMode && !isMobileHeader)
                        _buildVideoRateButton(),
                      // ── 広告を隠す (= ユーザー要望: 設定の奥ではなく、
                      //    使う画面から入切できるように) ──
                      if (!widget.minimalMode && !isMobileHeader)
                        PopupMenuButton<String>(
                          tooltip: provider.t('jev.adBlock'),
                          icon: Icon(
                            provider.adBlockEnabled
                                ? Icons.block_rounded
                                : Icons.block_outlined,
                            color: provider.adBlockEnabled
                                ? const Color(0xFF7FD8A0)
                                : Colors.white70,
                            size: 20,
                          ),
                          color: const Color(0xFF1E1E32),
                          padding: const EdgeInsets.all(6),
                          onSelected: (_) => _toggleAdBlock(),
                          itemBuilder: (_) => [
                            _gsAdBlockItem(
                              value: 'adBlock',
                              icon: Icons.block_rounded,
                              on: provider.adBlockEnabled,
                              label: provider.t('jev.adBlock'),
                            ),
                          ],
                        ),
                      // ── DeepL を側パネルで開く (= ユーザー要望: PC のみ搭載。
                      //    モバイルはスペースが無いので非表示) ──
                      if (!widget.minimalMode && useHorizontal)
                        IconButton(
                          // ★ DeepL の欄を開いている時だけ色を付ける
                          //   (= ユーザー要望: オフの時は色を消す)。
                          icon: Icon(Icons.translate_rounded,
                              color: (_aiPanelOpen && _aiPanelIsDeepL)
                                  ? const Color(0xFF0F73B8)
                                  : Colors.white70,
                              size: 22),
                          tooltip: context.read<MindMapProvider>().t('gs.openDeepl'),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(),
                          onPressed: _openDeepLPanel,
                        ),
                      // ── フローティングで開く (= ユーザー要望: Instagram
                      //    等のサイトボタンにフローティング機能) ──
                      // ドラッグできる浮遊パネルに現在のページを移す。
                      if (widget.onFloatRequest != null && _isDesktop)
                        IconButton(
                          icon: const Icon(
                              Icons.picture_in_picture_alt_rounded,
                              color: Colors.white70,
                              size: 20),
                          tooltip: context
                              .read<MindMapProvider>()
                              .t('split.toFloating'),
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(6),
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            widget.onFloatRequest!(_currentUrl);
                            _closeSelf();
                          },
                        ),
                      // ── 画面分割で開く ──
                      // ユーザー要望: モバイルは 1 ボタンに統合して「上分割」 のみにする
                      //   (= 分割した先のパネルで上下を入れ替えられるため)。 PC は左右
                      //   分割を別々のボタンで残す。
                      if (widget.onMoveToSplitPanel != null &&
                          useHorizontal) ...[
                        if (showTwoSplit) ...[
                          IconButton(
                            icon: _gSearchSplitIcon(
                              _GSearchSplitIconFill.left,
                              // 押すだけのボタンは白 (= ユーザー要望)。
                              //   左右の見分けは絵柄の塗り分けが持つ。
                              color: Colors.white70,
                              size: 22,
                            ),
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
                            icon: _gSearchSplitIcon(
                              _GSearchSplitIconFill.right,
                              color: Colors.white70,
                              size: 22,
                            ),
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
                            icon: _gSearchSplitIcon(
                              _isDesktop
                                  ? _GSearchSplitIconFill.left
                                  : _GSearchSplitIconFill.top,
                              color: Colors.white70,
                              size: 22,
                            ),
                            tooltip: _isDesktop
                                ? provider.t('gsearch.splitLeft')
                                : '分割して開く',
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
                      // ── モバイル: 進む/再読み込み/メモ/保存 を「⋮」 メニューに集約 ──
                      // 三点メニューは操作列の末尾に置き、どのサイト起点でも右端へ揃える。
                      if (!useHorizontal &&
                          !widget.minimalMode &&
                          !isMobileHeader)
                        PopupMenuButton<String>(
                          tooltip:
                              context.read<MindMapProvider>().t('gs.other'),
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
                                setState(() =>
                                    _memoPanelExpanded = !_memoPanelExpanded);
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
                              // ── 広告を隠す (= ユーザー要望: 使う画面から) ──
                              case 'adBlock':
                                _toggleAdBlock();
                                break;
                            }
                          },
                          itemBuilder: (_) => [
                            _gsOverflowItem(
                                'forward', Icons.arrow_forward_rounded, '進む'),
                            _gsOverflowItem(
                                'reload', Icons.refresh_rounded, '再読み込み'),
                            _gsOverflowItem('memo', Icons.sticky_note_2_rounded,
                                _memoPanelExpanded ? 'メモ欄を閉じる' : 'メモ欄を開く'),
                            _gsOverflowItem('embed', Icons.add_box_rounded,
                                context.read<MindMapProvider>().t('gs.embedAsLink')),
                            _gsOverflowItem(
                                'bookmark',
                                Icons.bookmark_add_rounded,
                                context
                                    .read<MindMapProvider>()
                                    .t('gs.addBookmarkBtn')),
                            if (!_isDesktop)
                              _gsOverflowItem('autoCapture',
                                  Icons.burst_mode_rounded, '自動スクショ → PDF'),
                            // ── 広告を隠す (= ユーザー要望: 設定の奥ではなく
                            //    使う画面から入切できるように) ──
                            _gsAdBlockItem(
                              value: 'adBlock',
                              icon: Icons.block_rounded,
                              on: provider.adBlockEnabled,
                              label: provider.t('jev.adBlock'),
                            ),
                          ],
                        ),
                      // ── 「全画面表示」 ボタン (minimalMode 時のみ) ──
                      // ユーザー要望「全画面表示を押したら今の様なメモ欄アリの画面が
                      //   出てくるようにして」 への対応。 minimalMode を抜けて
                      //   compactMode (= メモ欄付きの大きい画面) で開き直す。
                      //   現在の URL / 検索クエリ / メモを引き継いで遷移。
                      if (widget.minimalMode &&
                          widget.onExpandToCompact != null)
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
                      // ★ = ユーザー要望「ヘッダーを隠すボタンは無くして、
                      //   ヘッダーの何もない箇所をクリックしたら閉じて、
                      //   ヘッダー上部にカーソルがホバー状態になったら表示する
                      //   ボタンが出てくるように」。 隠すボタンはここから外し、
                      //   畳むのは帯の空いた所を押す形にした (下の
                      //   `flexibleSpace`)。 戻す山形は本文の上端に出る。
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
            body: Stack(children: [
              // ── 自動操作だけを出している間は、 ブラウザ側を見えなくする
              //    (= ユーザー要望: 後ろに Google 検索を出さない)。
              //    消してしまうと手順が動かせないので、 場所は取ったまま
              //    透明にして触れなくするだけ。 手順がページを開いた時点で
              //    元どおり姿を見せる。 ──
              Positioned.fill(
                child: Opacity(
                  opacity: _browserHidden ? 0.0 : 1.0,
                  child: IgnorePointer(
                    ignoring: _browserHidden,
                    child: useHorizontal
                ? Row(
                    children: [
                      // ── 左パネル (既定=メモ、 入れ替え時=AI) ──
                      // ユーザー要望: メモと AI が同じ方向に出ないように。
                      //   既定ではメモが「左」、AI が「右」に出る。
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
                      if (!widget.minimalMode &&
                          _aiPanelOpen &&
                          !_aiPanelFloating)
                        _buildMobileAiPanel(provider),
                    ],
                  ),
                  ),
                ),
              ),
              // ── 自動操作はフローティング窓で出す (= ユーザー要望: 欄を
              //    設けるとスクショできる範囲が狭まるため)。 キャプチャ中は
              //    写り込まないよう一時的に隠す。 ──
              // 実行中は窓自体を出さない (停止はヘッダーのボタンで行う
              // = ユーザー要望: 点滅しないように)。
              // ★ 座標を指している間は、 窓が指したい場所を覆ってしまうので
              //   一時的に引っ込める (= ユーザー報告: スワイプの始点・終点を
              //   押しても座標が決まらない)。 指し終われば元に戻る。
              // ★ スクショの間は「消す」 のではなく「見えなくする」 だけに
              //   する (= ユーザー報告: エージェントに任せて動かすと、 途中で
              //   止まってフローも残らない)。 木から外すとパネルの State が
              //   捨てられ、 作りかけの手順が prefs から読み直されて消え、
              //   エージェント側の !mounted で処理も終わっていた。
              // ★ = ユーザー報告「AI に『URL にアクセスしてスクショ』 と頼んでも
              //   どこにもアクセスしてくれない」 の主因。 走り始めた瞬間に
              //   `!_autoRunning` でこのパネルを**木から外して**いたので、
              //   `WebAutomationPanelState` が dispose され、 AI の返事を
              //   待っていた `_runAgent` が `!mounted` で黙って終わっていた
              //   (手順は 1 つも実行されず、 失敗の知らせも出ない)。
              //   外さずに、 見せないだけにする (スクショの時と同じ作法。
              //   すぐ下の `Offstage` が受け取る)。
              if (_autoPanelOpen)
                _buildFloatingAutoPanel(provider,
                    hidden: _autoPanelHiddenForShot ||
                        _autoRunning ||
                        _pickPointCompleter != null ||
                        _pickRectCompleter != null),
              // AI 欄の浮遊窓 (= ユーザー要望)
              if (_aiPanelOpen && _aiPanelFloating)
                _buildFloatingAiPanel(provider),
              // オートクリッカーの浮遊窓 (= ユーザー要望)
              if (_autoClickerOpen && autoClickerSupported)
                _buildFloatingAutoClicker(provider),
              // ── ヘッダーを隠している時に戻す小さなボタン ──
              //    ★ 隠すボタンと同じ「右上」 に出す (= ユーザー要望: 右端で
              //      押したのに左端に出てきて押しにくい)。 閉じるボタンの
              //      すぐ左あたりに来るので、 指/カーソルをほぼ動かさずに
              //      戻せる。 最前面に置かないと WebView の下に隠れる。
              // ★ ヘッダーを隠している間は、 上端にカーソルを乗せるまで
              //   この「戻す」 ボタンも出さない (= ユーザー要望: 隠したのに
              //   ボタンだけ残っていると隠した意味が薄い)。 上端の細い帯に
              //   カーソルが入った時だけ現れる。 触れる手段が無いスマホでは
              //   従来どおり常に出す (ホバーが無いため)。
              // ★ ヘッダーを丸ごと出さない時は、 閉じる手段が無くなるので
              //   右上に小さな × だけ置く (= 読むだけの画面用)。
              if (widget.hideAppBar)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Material(
                    color: const Color(0xCC1A1A1A),
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: MaterialLocalizations.of(context)
                          .closeButtonTooltip,
                      iconSize: 18,
                      constraints:
                          const BoxConstraints(minWidth: 34, minHeight: 34),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white70),
                      onPressed: _closeSelf,
                    ),
                  ),
                ),
              // ★ 重ねて出す戻し口は、 触りを奪われないパソコンだけ
              //   (モバイルは上の細い帯で戻す)。
              if (_gsHeaderHidden && !widget.hideAppBar && _gsHoverCapable)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 40,
                  child: MouseRegion(
                    opaque: false,
                    onEnter: (_) {
                      if (!_gsHeaderHover) {
                        setState(() => _gsHeaderHover = true);
                      }
                    },
                    onExit: (_) {
                      if (_gsHeaderHover) {
                        setState(() => _gsHeaderHover = false);
                      }
                    },
                    child: Align(
                      // 上部中央に置く (= ユーザー要望: 他の画面と合わせる)。
                      alignment: Alignment.topCenter,
                      child: (_gsHeaderHover || !_gsHoverCapable)
                          ? Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Material(
                                color: Colors.black.withValues(alpha: 0.55),
                                shape: const CircleBorder(),
                                child: IconButton(
                                  // 柔らかい印象のアイコンにする (= ユーザー要望:
                                  // 目のアイコンが不気味)。 下向きの山形 = 「出てくる」。
                                  icon: const Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                      color: Colors.white70,
                                      size: 20),
                                  tooltip: provider.t('gs.showHeader'),
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.all(6),
                                  constraints: const BoxConstraints(),
                                  onPressed: () =>
                                      setState(() => _gsHeaderHidden = false),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
            ]),
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
                        tooltip: context.read<MindMapProvider>().t('gs.closeMemo'),
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
    // 出しっぱなしのお知らせ帯があれば、 閉じる時に一緒に消す
    // (= 消し手が居なくなって残り続けるのを防ぐ)。
    if (_captureNoticeTimer?.isActive ?? false) {
      try {
        _bannerMessenger?.hideCurrentMaterialBanner();
      } catch (_) {}
    }
    _captureNoticeTimer?.cancel();
    _draftSaveDebounce?.cancel();
    if (_useDraft) {
      context.read<MindMapProvider>().setGoogleSearchMemoDraft(_memoCtrl.text);
    }
    _searchCtrl.dispose();
    _memoCtrl.dispose();
    _gsTabBarScroll.dispose();
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
  String lastSafeServiceUrl;
  bool oauthHandoffInProgress = false;
  DateTime? lastOAuthHandoffAt;
  // ── タブごとに独立した検索用 WebView (= ユーザー要望: タブを切り替えても
  //    再読み込みされないように。 IndexedStack で全タブを生かしておく) ──
  // デスクトップ (webview_windows)
  wv_win.WebviewController? winCtrl;
  /// 広告落としの doc-created 登録の id (切った時に外すため。 未登録は null)。
  String? adScriptId;
  bool winReady = false; // initialize 完了
  bool winInitStarted = false; // initialize 起動済み (二重起動防止)
  String? winError;
  double mapPinchLastScale = 1.0;
  double mapPinchLogRemainder = 0.0;
  double mapPinchSignalRemainder = 0.0;
  int mapPinchPendingSteps = 0;
  bool mapPinchDispatching = false;
  Offset mapPinchLocalPosition = Offset.zero;
  // モバイル (flutter_inappwebview)。 keepAlive で切替時の状態を保持する。
  iaw.InAppWebViewController? iawCtrl;
  final iaw.InAppWebViewKeepAlive iawKeepAlive = iaw.InAppWebViewKeepAlive();
  _GsTab({required this.url, this.title = ''})
      : lastSafeServiceUrl =
            isSafeExternalServiceUrl(url) ? url : 'https://www.google.com/';
}

/// お気に入り登録 (★) を押した所 (画面座標)。
///
/// ★ = ユーザー要望「お気に入りボタンとして登録の項目は押しやすいように
///   押したボタンの近くに表示して欲しい」。 登録の窓を出すのは本体
///   (`_MindMapScreenState._showCreateBookmarkButtonDialog`) なので、
///   押した場所をここへ置いて拾ってもらう。 使ったら本体側が null に戻す。
Offset? gsLastFavButtonPos;

/// 検索 WebView のホイール感度を下げる (= ユーザー要望: ノードから開いた
/// Google 検索のマウスホイールが速すぎるので、 もう少し小さくする)。
/// wheel を capture で横取りして preventDefault し、 縮小した量で手動スクロール。
/// アプリの中で開いたページのスクロールバーを、 ふだんは消しておく
/// (= ユーザー要望: 常時表示ではなく、 スクロールする時か、 スクロール
/// バーにカーソルが乗った時だけ出す)。 公式 Instagram / プライバシー
/// ポリシー / 利用規約 / 特定商取引法 の画面もこの枠で開いている。
///
/// ★ 素の文字列だと \n や \d が Dart 側で潰れるので raw 文字列で書く。
const String _kGsAutoHideScrollbarJs = r'''
(function(){
  if (window.__mmAutoHideBar) return;
  window.__mmAutoHideBar = true;
  // ★ 溝 (track) を「透明」 にすると、 その下にある WebView の地の色が
  //   そのまま出る。 WebView2 の地は白なので、 暗いページでも右端に白い
  //   柱が残り続ける (= ユーザー報告)。 ページ自身の背景色で塗って隠す。
  function pageBg(){
    try {
      var b = getComputedStyle(document.documentElement).backgroundColor;
      if (!b || b === 'transparent' || b === 'rgba(0, 0, 0, 0)') {
        b = document.body
            ? getComputedStyle(document.body).backgroundColor : '';
      }
      if (!b || b === 'transparent' || b === 'rgba(0, 0, 0, 0)') return '';
      return b;
    } catch(e){ return ''; }
  }
  function buildCss(){
    var bg = pageBg();
    var track = bg ? bg : 'transparent';
    return ''
    + '::-webkit-scrollbar{width:10px;height:10px;background:' + track + '}'
    + '::-webkit-scrollbar-track{background:' + track + '}'
    + '::-webkit-scrollbar-corner{background:' + track + '}'
    + '::-webkit-scrollbar-thumb{background:transparent;border-radius:8px;'
    + 'border:2px solid transparent;background-clip:content-box;'
    + 'transition:background-color .25s ease}'
    + 'html.__mmBarOn ::-webkit-scrollbar-thumb,'
    + 'html.__mmBarOn::-webkit-scrollbar-thumb'
    + '{background:rgba(140,140,140,.75);background-clip:content-box}';
  }
  function addCss(){
    var head = document.head || document.documentElement;
    if (!head) return;
    var st = document.getElementById('__mmBarCss');
    if (!st) {
      st = document.createElement('style');
      st.id = '__mmBarCss';
      head.appendChild(st);
    }
    st.textContent = buildCss();
  }
  addCss();
  document.addEventListener('DOMContentLoaded', addCss);
  // ページの色が後から決まる (テーマの切り替え等) 事があるので、 少し
  // 経ってからもう一度塗り直す。
  setTimeout(addCss, 600);
  setTimeout(addCss, 2500);
  var timer = null;
  function show(){
    var el = document.documentElement;
    if (!el) return;
    el.classList.add('__mmBarOn');
    if (timer) clearTimeout(timer);
    timer = setTimeout(function(){
      try { el.classList.remove('__mmBarOn'); } catch(e){}
    }, 1000);
  }
  // 動かしている間 (スクロール / ホイール / キー) は出す。
  window.addEventListener('scroll', show, true);
  window.addEventListener('wheel', show, {passive:true, capture:true});
  window.addEventListener('keydown', function(e){
    var k = e.key || '';
    if (k === 'PageUp' || k === 'PageDown' || k === 'Home' || k === 'End'
        || k === 'ArrowUp' || k === 'ArrowDown' || k === ' ') show();
  }, true);
  // バーの上 (右端 / 下端) にカーソルが来た時も出す。
  window.addEventListener('mousemove', function(e){
    var w = window.innerWidth || 0;
    var h = window.innerHeight || 0;
    if ((w - e.clientX) < 18 || (h - e.clientY) < 18) show();
  }, {passive:true, capture:true});
})();
''';

const String _kGsWheelTameJs = r'''
(function(){
  if (window.__mmWheelTamed) return;
  window.__mmWheelTamed = true;
  var FACTOR = 0.45; // 感度 (1.0 = ブラウザ標準)
  window.addEventListener('wheel', function(e){
    if (e.ctrlKey) return;            // Ctrl+ホイールのズームはそのまま
    if (e.defaultPrevented) return;
    // Maps / Earth はホイール自体をズーム入力として使う。ここで横取りすると
    // ページスクロールへ変換されて地図を拡大縮小できなくなるため素通しする。
    var host = (location.hostname || '').toLowerCase();
    var path = (location.pathname || '').toLowerCase();
    var googleHost = /(^|\.)google\.(com|[a-z]{2,3}|co\.[a-z]{2}|com\.[a-z]{2})$/.test(host);
    var first = host.split('.')[0] || '';
    var googleMap = googleHost &&
                    (first === 'maps' || first === 'earth' ||
                     path === '/maps' || path.indexOf('/maps/') === 0);
    if (googleMap) return;
    var dy = e.deltaY * FACTOR;
    var dx = e.deltaX * FACTOR;
    // ── 動かせる相手を**先に**探し、 見つかった時だけ横取りする ──
    //
    // ★ = ユーザー報告「google 検索の AI チャット欄のマウスによるスクロール
    //   操作ができない」。 以前は必ず preventDefault してから相手を探して
    //   いたので、 見つからないページ (ChatGPT / Gemini のような、 中身を
    //   独自の入れ物で流すつくりの画面) ではブラウザの標準動作まで止めて
    //   しまい、 どこも動かなかった。 見つからない時は素通しして
    //   WebView2 に任せる。
    function movable(el){
      if (!el || el.nodeType !== 1) return false;
      var st = window.getComputedStyle(el);
      var oy = st.overflowY, ox = st.overflowX;
      var scrollableY = (oy === 'auto' || oy === 'scroll' || oy === 'overlay');
      var scrollableX = (ox === 'auto' || ox === 'scroll' || ox === 'overlay');
      if (dy && scrollableY && el.scrollHeight > el.clientHeight + 1) {
        if (dy > 0 ? (el.scrollTop + el.clientHeight < el.scrollHeight - 1)
                   : (el.scrollTop > 0)) return true;
      }
      if (dx && scrollableX && el.scrollWidth > el.clientWidth + 1) {
        if (dx > 0 ? (el.scrollLeft + el.clientWidth < el.scrollWidth - 1)
                   : (el.scrollLeft > 0)) return true;
      }
      return false;
    }
    // 影の DOM (shadow DOM) の中から始まった時も辿れるようにする。
    var path = (typeof e.composedPath === 'function') ? e.composedPath() : null;
    var el = (path && path.length) ? path[0] : e.target;
    var hops = 0;
    while (el && el.nodeType === 1 && hops++ < 80) {
      if (movable(el)) {
        e.preventDefault();
        if (dy) el.scrollTop += dy;
        if (dx) el.scrollLeft += dx;
        return;
      }
      el = el.parentElement ||
           (el.parentNode && el.parentNode.host) || null;
    }
    var doc = document.scrollingElement || document.documentElement;
    if (movable(doc) || movable(document.body)) {
      e.preventDefault();
      window.scrollBy(dx, dy);
    }
    // ここまで来たら横取りしない (= ブラウザに任せる)。
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
    // 通常クリックや target=_blank は WebView2 の popup policy に任せる。
    // OAuth SDK が window.open の戻り値を監視できる状態も維持する。
    if (!ctrlish && !mid) return;
    var href = a.href;
    if (!href || href.indexOf('javascript:') === 0) return;
    e.preventDefault(); e.stopPropagation();
    send(href);
  }
  document.addEventListener('click', function(e){ handle(e, false); }, true);
  document.addEventListener('auxclick', function(e){ handle(e, true); }, true);
  // ── Ctrl+W / Ctrl+Shift+T をこちら側へ渡す (= ユーザー要望: Ctrl+W で
  //    タブを閉じられるように) ──
  //    検索結果の上に焦点がある間、 打鍵は WebView が受け取ってしまい
  //    Flutter 側の受け口 (`_globalKeyHandler`) には届かない。 ページの中で
  //    捕まえて postMessage で渡す (Ctrl+クリックと同じ道)。
  function key(e){
    try {
      if (!(e.ctrlKey || e.metaKey)) return;
      var k = String(e.key || '').toLowerCase();
      if (k === 'w' && !e.shiftKey) {
        e.preventDefault(); e.stopPropagation();
        try { window.chrome.webview.postMessage(
          JSON.stringify({t:'closetab'})); } catch(err){}
      } else if (k === 't' && e.shiftKey) {
        e.preventDefault(); e.stopPropagation();
        try { window.chrome.webview.postMessage(
          JSON.stringify({t:'reopentab'})); } catch(err){}
      }
    } catch(err){}
  }
  document.addEventListener('keydown', key, true);
})();
''';

/// ページの中で押された Ctrl+W / Ctrl+Shift+T の知らせなら、 その種類を返す。
String? _parseGsTabKeyMessage(dynamic msg) {
  try {
    dynamic data = msg;
    if (data is String) {
      final s = data.trim();
      if (!s.startsWith('{')) return null;
      data = jsonDecode(s);
    }
    if (data is Map) {
      final t = data['t'];
      if (t == 'closetab' || t == 'reopentab') return '$t';
    }
  } catch (_) {}
  return null;
}

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
