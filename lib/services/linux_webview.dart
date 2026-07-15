// ============================================================================
// Linux デスクトップ専用 WebView ラッパ (CEF / flutter_linux_webview)
// ============================================================================
// 目的: Windows は webview_windows、 モバイルは flutter_inappwebview のまま、
//   Linux だけ CEF ベースの WebView を提供する。 このファイルは **Linux 専用**
//   のコードを 1 箇所に隔離し、 アプリ本体 (screen) からは
//   `if (Platform.isLinux)` の枝でのみ参照する。
//
// ★ファイル容量への配慮 (= ユーザー要望「Windows/Android のビルド容量を
//   増やさない」):
//   - flutter_linux_webview は **Linux 専用プラグイン**なので、 そのネイティブ
//     (CEF 約200MB) は Windows / Android のビルドには一切含まれない (.exe/.apk
//     のネイティブ容量は不変)。
//   - ここで import しているのは flutter_linux_webview と純 Dart の
//     webview_flutter_platform_interface のみ。 アプリ向けの webview_flutter
//     (= webview_flutter_android/wkwebview を連れてくる) は **使わない**ので、
//     Android/iOS のネイティブにも追加は無い。
//   - Dart コードはこのファイル分だけ全プラットフォームに AOT される (数KB)。
//     Dart には OS 別の条件付き import が無いため、 これは単一コードベースで
//     避けられない最小増分 (実質ゼロ)。
//
// ★制約 (flutter_linux_webview 0.1.3 由来):
//   - JS→Dart の JavaScript チャンネルは **未実装**。 ページ側から Dart へ
//     メッセージを push する機能 (検索ページ→メモ取得・Ctrl+クリック横取り等)
//     は Linux では動かない。 Dart→JS の実行 (runJavascript) と結果取得
//     (runJavascriptReturningResult) は可能。
//   - NavigationDelegate も未実装 (onNavigationRequest は無視される)。
//   - JavaScriptMode は生成後に変更不可。 user-agent は initialize() で指定。
//
// ★★ LINUX-HOST VERIFY ★★
//   このファイルは Windows 上では **コンパイル検証していない** (アナライザ
//   破損 + Linux ネイティブ非対応)。 webview_flutter_platform_interface 1.9.5
//   の正確なシグネチャ (CreationParams / WebSettings / WebSetting.absent /
//   WebViewPlatformController のメソッド名) は Linux 実機の `flutter build linux`
//   で確定・修正すること。 想定 API は本ファイル末尾のコメント参照。
// ============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter_linux_webview/flutter_linux_webview.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// CEF の初期化が一度だけ走ったかのフラグ。
bool _linuxWebViewInitialized = false;

/// Linux WebView (CEF) を初期化する。 main() で `Platform.isLinux` の時だけ
/// 呼ぶ。 二重初期化は no-op。 失敗してもアプリ本体は動くよう try/catch で握る。
void initLinuxWebView() {
  if (_linuxWebViewInitialized) return;
  _linuxWebViewInitialized = true;
  try {
    // user-agent はデスクトップ Chrome を名乗ると YouTube 等の表示が安定する。
    LinuxWebViewPlugin.initialize(options: <String, String?>{
      'user-agent':
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      // 'remote-debugging-port': '8888', // デバッグ時のみ
    });
  } catch (e) {
    debugPrint('initLinuxWebView 失敗: $e');
  }
}

/// アプリ終了時に CEF を後始末する (Flutter 3.10+ 推奨)。
Future<void> terminateLinuxWebView() async {
  if (!_linuxWebViewInitialized) return;
  try {
    await LinuxWebViewPlugin.terminate();
  } catch (_) {/* 終了時なので握りつぶす */}
}

/// 画面側が webview_windows の `WebviewController` と同じ感覚で扱えるよう、
/// `WebViewPlatformController` を薄くラップしたコントローラ。
///
/// 画面側の Windows 経路 (`wv_win.WebviewController`) と **メソッド名を揃える**
/// ことで、 呼び出し側の分岐コードを左右対称に書けるようにする。
class LinuxWebViewController {
  LinuxWebViewController._(this._platformController);

  final WebViewPlatformController _platformController;

  /// ページ遷移などで URL が変わったときに流れるストリーム
  /// (webview_windows の `url` ストリーム相当)。 NavigationDelegate 未実装の
  /// 制約上、 onPageStarted/onPageFinished からベストエフォートで流す。
  final StreamController<String> _urlCtrl = StreamController<String>.broadcast();
  Stream<String> get url => _urlCtrl.stream;

  /// タイトル変更ストリーム (取得できる範囲でベストエフォート)。
  final StreamController<String> _titleCtrl =
      StreamController<String>.broadcast();
  Stream<String> get title => _titleCtrl.stream;

  /// ドキュメント生成時に毎回流し込みたい JS (webview_windows の
  /// `addScriptToExecuteOnDocumentCreated` 相当)。 onPageStarted で実行する。
  final List<String> _docStartScripts = <String>[];

  /// URL を読み込む。
  Future<void> loadUrl(String u) async {
    try {
      await _platformController.loadUrl(u, <String, String>{});
    } catch (e) {
      debugPrint('LinuxWebView loadUrl 失敗: $e');
    }
  }

  /// JS を実行する (戻り値不要)。 webview_windows の executeScript 相当。
  Future<void> executeScript(String js) async {
    try {
      await _platformController.runJavascript(js);
    } catch (e) {
      debugPrint('LinuxWebView executeScript 失敗: $e');
    }
  }

  /// JS を実行して結果文字列を取得する。 webview_windows の
  /// executeScript (戻り値あり) 相当。 動画の currentTime 取得などで使う。
  Future<String?> executeScriptReturning(String js) async {
    try {
      return await _platformController.runJavascriptReturningResult(js);
    } catch (e) {
      debugPrint('LinuxWebView executeScriptReturning 失敗: $e');
      return null;
    }
  }

  /// 現在の URL。
  Future<String?> currentUrl() async {
    try {
      return await _platformController.currentUrl();
    } catch (_) {
      return null;
    }
  }

  Future<void> reload() async {
    try {
      await _platformController.reload();
    } catch (_) {}
  }

  Future<bool> canGoBack() async {
    try {
      return await _platformController.canGoBack();
    } catch (_) {
      return false;
    }
  }

  Future<void> goBack() async {
    try {
      await _platformController.goBack();
    } catch (_) {}
  }

  Future<bool> canGoForward() async {
    try {
      return await _platformController.canGoForward();
    } catch (_) {
      return false;
    }
  }

  Future<void> goForward() async {
    try {
      await _platformController.goForward();
    } catch (_) {}
  }

  /// 「ドキュメント生成時に実行する JS」 を登録する。 webview_windows の
  /// addScriptToExecuteOnDocumentCreated 相当 (Linux では onPageStarted で再実行)。
  void addScriptToExecuteOnDocumentCreated(String js) {
    _docStartScripts.add(js);
  }

  /// Dart→JS のメッセージ送信 (webview_windows の postWebMessage 相当)。
  /// JS 側は `window.addEventListener('message', ...)` ではなく、 アプリが
  /// 仕込んだグローバル関数経由で受ける想定。 JS→Dart の push は未対応。
  Future<void> postWebMessage(String json) async {
    // ベストエフォート: ページ側に __mmReceiveHostMessage があれば呼ぶ。
    await executeScript(
      'if(window.__mmReceiveHostMessage){try{window.__mmReceiveHostMessage($json);}catch(e){}}',
    );
  }

  void _emitUrl(String u) {
    if (!_urlCtrl.isClosed) _urlCtrl.add(u);
  }

  void _emitTitle(String t) {
    if (!_titleCtrl.isClosed) _titleCtrl.add(t);
  }

  Future<void> _runDocStartScripts() async {
    for (final js in _docStartScripts) {
      await executeScript(js);
    }
  }

  void dispose() {
    _urlCtrl.close();
    _titleCtrl.close();
  }
}

/// Linux 用 WebView ウィジェット。 画面側の `_SplitWindowsWebView` と同じ
/// 感覚で使えるよう、 url / onControllerReady / onUrlChanged を受ける。
class LinuxWebViewWidget extends StatefulWidget {
  const LinuxWebViewWidget({
    super.key,
    required this.url,
    this.onControllerReady,
    this.onUrlChanged,
    this.onPageFinished,
    this.backgroundColor = const Color(0xFF000000),
  });

  final String url;
  final ValueChanged<LinuxWebViewController>? onControllerReady;
  final ValueChanged<String>? onUrlChanged;
  final ValueChanged<String>? onPageFinished;
  final Color backgroundColor;

  @override
  State<LinuxWebViewWidget> createState() => _LinuxWebViewWidgetState();
}

class _LinuxWebViewWidgetState extends State<LinuxWebViewWidget> {
  // flutter_linux_webview の WebViewPlatform 実装。 アプリ向け webview_flutter
  //   を使わず、 この実装を直接 build() することで Android/iOS を汚さない。
  final WebViewPlatform _platform = LinuxWebView();
  LinuxWebViewController? _controller;

  late final _CallbacksHandler _handler = _CallbacksHandler(
    onPageStarted: (u) {
      _controller?._emitUrl(u);
      widget.onUrlChanged?.call(u);
      // addScriptToExecuteOnDocumentCreated 相当を毎ページ実行。
      _controller?._runDocStartScripts();
    },
    onPageFinished: (u) {
      _controller?._emitUrl(u);
      widget.onPageFinished?.call(u);
    },
  );

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _platform.build(
      context: context,
      creationParams: CreationParams(
        initialUrl: widget.url,
        webSettings: WebSettings(
          javascriptMode: JavascriptMode.unrestricted,
          hasNavigationDelegate: false,
          hasProgressTracking: false,
          debuggingEnabled: false,
          gestureNavigationEnabled: false,
          allowsInlineMediaPlayback: true,
          userAgent: const WebSetting<String?>.absent(),
          zoomEnabled: true,
        ),
        javascriptChannelNames: const <String>{},
        autoMediaPlaybackPolicy: AutoMediaPlaybackPolicy.always_allow,
        backgroundColor: widget.backgroundColor,
      ),
      webViewPlatformCallbacksHandler: _handler,
      javascriptChannelRegistry:
          JavascriptChannelRegistry(const <JavascriptChannel>{}),
      onWebViewPlatformCreated: (WebViewPlatformController? controller) {
        if (controller == null) return;
        final c = LinuxWebViewController._(controller);
        _controller = c;
        widget.onControllerReady?.call(c);
      },
      gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
    );
  }
}

/// WebViewPlatformCallbacksHandler の最小実装。 JS チャンネルと
/// NavigationDelegate は flutter_linux_webview 未対応なので素通し。
class _CallbacksHandler extends WebViewPlatformCallbacksHandler {
  _CallbacksHandler(
      {required ValueChanged<String> onPageStarted,
      required ValueChanged<String> onPageFinished})
      : _onStart = onPageStarted,
        _onFinish = onPageFinished;

  final ValueChanged<String> _onStart;
  final ValueChanged<String> _onFinish;

  // 注: webview_flutter_platform_interface 1.9.5 の
  //   WebViewPlatformCallbacksHandler に onJavaScriptChannelMessage は無い
  //   (JS チャンネルは JavascriptChannelRegistry 経由)。 ここでは扱わない。

  @override
  FutureOr<bool> onNavigationRequest(
      {required String url, required bool isForMainFrame}) {
    return true; // 常に許可 (NavigationDelegate 未対応)。
  }

  @override
  void onPageStarted(String url) => _onStart(url);

  @override
  void onPageFinished(String url) => _onFinish(url);

  @override
  void onProgress(int progress) {}

  @override
  void onWebResourceError(WebResourceError error) {
    debugPrint('LinuxWebView resource error: ${error.description}');
  }
}

// ============================================================================
// 想定している webview_flutter_platform_interface 1.9.5 の API (LINUX-HOST VERIFY)
// ----------------------------------------------------------------------------
// abstract class WebViewPlatform {
//   Widget build({
//     required BuildContext context,
//     required CreationParams creationParams,
//     required WebViewPlatformCallbacksHandler webViewPlatformCallbacksHandler,
//     required JavascriptChannelRegistry javascriptChannelRegistry,
//     WebViewPlatformCreatedCallback? onWebViewPlatformCreated,
//     Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers,
//   });
// }
// abstract class WebViewPlatformController {
//   Future<void> loadUrl(String url, Map<String,String>? headers);
//   Future<String?> currentUrl();
//   Future<bool> canGoBack(); Future<bool> canGoForward();
//   Future<void> goBack(); Future<void> goForward(); Future<void> reload();
//   Future<void> runJavascript(String javascript);
//   Future<String> runJavascriptReturningResult(String javascript);
//   Future<String?> getTitle();
// }
// ※ 実際のシグネチャ差異 (例: runJavascriptReturningResult の戻り値型、
//   WebSetting.absent の型引数、 onPageStarted 等のハンドラ名) は Linux 実機の
//   ビルドエラーに合わせて微修正すること。
// ============================================================================
