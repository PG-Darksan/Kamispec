// 外のブラウザ (Chrome / Edge / Brave …) を DOM ごしに操作する。
//
// なぜ要るのか:
//   自動操作がこれまで動かせたのは「アプリの中のブラウザ」 だけだった。
//   外の Chrome は別プロセスなので中身が見えず、 OS のマウス操作しか
//   手が無い。 しかし座標を知る術が無いので、 結局「押せない」 状態だった
//   (= ユーザー報告: アカウントを指定してもログインしてくれない)。
//
//   CDP (Chrome DevTools Protocol) は、 F12 の開発者ツールが Chrome 本体と
//   話すのに使っている規約。 デバッグ用の口を開けて起動すれば、 外の
//   ブラウザに対しても **JavaScript をそのまま実行できる**。 つまり
//   アプリ内ブラウザ向けに書いた仕掛け (文字で要素を探して押す等) が、
//   そっくりそのまま外のブラウザに効く。 座標も画像も要らない。
//
//   Playwright や Puppeteer も中身はこれ。
//
// 対応するブラウザ:
//   Chromium 系 (Chrome / Edge / Brave / Vivaldi / Opera) はすべて同じ
//   規約なので、 実行ファイルの場所が違うだけで中身は共通。
//
//   ★ Firefox は対象外。 Firefox 141 (2025-06) で CDP の実装が完全に
//     取り除かれ、 WebDriver BiDi という別の規約に移った。 こちらに
//     対応するには別の実装が要る。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 操作できるブラウザの種類。
enum CdpBrowserKind { chrome, edge, brave, vivaldi, opera }

extension CdpBrowserKindName on CdpBrowserKind {
  String get label => switch (this) {
        CdpBrowserKind.chrome => 'Chrome',
        CdpBrowserKind.edge => 'Edge',
        CdpBrowserKind.brave => 'Brave',
        CdpBrowserKind.vivaldi => 'Vivaldi',
        CdpBrowserKind.opera => 'Opera',
      };

  /// 名前の一部から見分ける ('chrome' / 'クローム' など)。
  static CdpBrowserKind? fromText(String s) {
    final t = s.toLowerCase();
    if (t.contains('edge') || t.contains('エッジ')) return CdpBrowserKind.edge;
    if (t.contains('brave') || t.contains('ブレイブ')) {
      return CdpBrowserKind.brave;
    }
    if (t.contains('vivaldi')) return CdpBrowserKind.vivaldi;
    if (t.contains('opera') || t.contains('オペラ')) {
      return CdpBrowserKind.opera;
    }
    if (t.contains('chrome') || t.contains('クローム') || t.contains('グーグル')) {
      return CdpBrowserKind.chrome;
    }
    return null;
  }
}

/// 外のブラウザとの会話。
///
/// 使い方:
///   final b = await CdpBrowser.launchAndConnect(kind: CdpBrowserKind.chrome);
///   await b.navigate('https://example.com/');
///   final title = await b.evaluate('document.title');
///   await b.dispose();
class CdpBrowser {
  CdpBrowser._(this._ws, this.port, this.kind);

  final WebSocket _ws;
  final int port;
  final CdpBrowserKind kind;

  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _waiting = {};
  StreamSubscription<dynamic>? _sub;
  bool _closed = false;

  /// この端末で見つかったブラウザの置き場所。
  static List<String> _candidatePaths(CdpBrowserKind kind) {
    final pf = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final pf86 = Platform.environment['ProgramFiles(x86)'] ??
        r'C:\Program Files (x86)';
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    switch (kind) {
      case CdpBrowserKind.chrome:
        return [
          '$pf\\Google\\Chrome\\Application\\chrome.exe',
          '$pf86\\Google\\Chrome\\Application\\chrome.exe',
          '$local\\Google\\Chrome\\Application\\chrome.exe',
        ];
      case CdpBrowserKind.edge:
        return [
          '$pf86\\Microsoft\\Edge\\Application\\msedge.exe',
          '$pf\\Microsoft\\Edge\\Application\\msedge.exe',
        ];
      case CdpBrowserKind.brave:
        return [
          '$pf\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
          '$pf86\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
          '$local\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
        ];
      case CdpBrowserKind.vivaldi:
        return [
          '$local\\Vivaldi\\Application\\vivaldi.exe',
          '$pf\\Vivaldi\\Application\\vivaldi.exe',
        ];
      case CdpBrowserKind.opera:
        return [
          '$local\\Programs\\Opera\\opera.exe',
          '$pf\\Opera\\opera.exe',
        ];
    }
  }

  /// この端末に入っているブラウザを探す。 無ければ null。
  static String? findExe(CdpBrowserKind kind) {
    for (final p in _candidatePaths(kind)) {
      try {
        if (File(p).existsSync()) return p;
      } catch (_) {}
    }
    return null;
  }

  /// 入っているブラウザの一覧 (画面に選択肢として出す用)。
  static List<CdpBrowserKind> installed() {
    if (!Platform.isWindows) return const [];
    return [
      for (final k in CdpBrowserKind.values)
        if (findExe(k) != null) k,
    ];
  }

  /// ブラウザを「操作できる口を開けた状態」 で起動し、 つなぐ。
  ///
  /// [useOwnProfile] true なら普段のプロファイルを使う。 ログイン済みの
  /// まま開けるので、 ログイン操作そのものが要らなくなる
  /// (= Google は自動化されたブラウザでのサインインを拒むため、 これが
  ///  現実的な回避になる)。 ただし同じブラウザが既に起動していると、
  /// プロファイルが使用中で口が開かないので、 その時は別の置き場を使う。
  static Future<CdpBrowser> launchAndConnect({
    required CdpBrowserKind kind,
    String? url,
    int port = 9222,
    bool useOwnProfile = false,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!Platform.isWindows) {
      throw Exception('外のブラウザの操作は Windows 版だけです');
    }
    final exe = findExe(kind);
    if (exe == null) {
      throw Exception('${kind.label} が見つかりませんでした');
    }
    // 既にその口が開いていれば、 起動せずにつなぐ。
    if (await _probe(port) != null) {
      return _connect(port, kind, timeout, wantUrl: url);
    }
    final args = <String>[
      '--remote-debugging-port=$port',
      // 初回の案内や既定ブラウザの確認で止まらないように。
      '--no-first-run',
      '--no-default-browser-check',
      if (!useOwnProfile)
        '--user-data-dir=${_scratchProfileDir(kind, port)}',
      if (url != null && url.isNotEmpty) url,
    ];
    try {
      await Process.start(exe, args,
          mode: ProcessStartMode.detached, runInShell: false);
    } catch (e) {
      throw Exception('${kind.label} を起動できませんでした: $e');
    }
    try {
      return await _connect(port, kind, timeout, wantUrl: url);
    } catch (_) {
      // ★ 一番よくある行き止まりを、 そのまま言葉にする (= 実測で判明)。
      //   ブラウザが既に起動していると、 新しく起動しても「既にある窓に
      //   仕事を渡して自分は終了」 するため、 操作口が開かない。
      //   普段のプロファイルを使う時は置き場を分けて逃げることもできない。
      if (useOwnProfile) {
        throw Exception(
            '${kind.label} が既に起動しているため、 操作口を開けませんでした。\n'
            '普段のプロファイル (ログイン済み) で使う時は、 '
            '${kind.label} をいったん完全に閉じてから実行してください。');
      }
      throw Exception(
          '${kind.label} の操作口につながりませんでした (ポート $port)。\n'
          '${kind.label} を閉じてから試すか、 別のポートでお試しください。');
    }
  }

  /// 自動操作用の置き場 (普段のプロファイルを汚さない)。
  ///
  /// ★ ポートごとに分ける。 同じ置き場を使い回すと、 前の窓が生きている
  ///   間は新しく起動してもそちらへ引き継がれて終了してしまい、 新しい
  ///   操作口が開かない (= 実測で判明)。
  static String _scratchProfileDir(CdpBrowserKind kind, int port) {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Directory.systemTemp.path;
    return '$base\\HisatorNotebook\\cdp_${kind.name}_$port';
  }

  /// 口が開いているか見る。 開いていればタブの一覧を返す。
  static Future<List<dynamic>?> _probe(int port) async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final req = await c.getUrl(Uri.parse('http://127.0.0.1:$port/json'));
      final res = await req.close().timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      return j is List ? j : null;
    } catch (_) {
      return null;
    }
  }

  static Future<CdpBrowser> _connect(
      int port, CdpBrowserKind kind, Duration timeout,
      {String? wantUrl}) async {
    final until = DateTime.now().add(timeout);
    Map<String, dynamic>? fallback;
    while (DateTime.now().isBefore(until)) {
      final tabs = await _probe(port);
      // 普通のページのタブだけを見る (拡張機能や裏方は避ける)。
      final pages = (tabs ?? const []).cast<Map<String, dynamic>>().where((t) {
        final type = '${t['type'] ?? ''}';
        final u = '${t['url'] ?? ''}';
        return type == 'page' &&
            !u.startsWith('devtools://') &&
            '${t['webSocketDebuggerUrl'] ?? ''}'.isNotEmpty;
      }).toList();

      // ★ 「まだ何も開いていないタブ」 を掴まない
      //   (= 実測で判明: URL を指定して起動しても、 一覧の先頭は
      //    about:blank のことがあり、 そこにつなぐと中身が空に見える)。
      bool blank(Map<String, dynamic> t) {
        final u = '${t['url'] ?? ''}';
        return u.isEmpty ||
            u == 'about:blank' ||
            u.startsWith('chrome://newtab') ||
            u.startsWith('edge://newtab');
      }

      // 開きたい URL が分かっているなら、 それを開いているタブを選ぶ。
      Map<String, dynamic>? pick;
      if (wantUrl != null && wantUrl.isNotEmpty) {
        for (final t in pages) {
          if ('${t['url'] ?? ''}'.startsWith(wantUrl.split('#').first)) {
            pick = t;
            break;
          }
        }
      }
      pick ??= pages.where((t) => !blank(t)).firstOrNull;
      if (pick != null) {
        final ws = await WebSocket.connect('${pick['webSocketDebuggerUrl']}');
        final b = CdpBrowser._(ws, port, kind);
        b._listen();
        return b;
      }
      // 中身のあるタブがまだ無い。 少し待って見直す。 時間切れの時のために
      //   空のタブも控えておく (何も掴めないよりはまし)。
      fallback ??= pages.firstOrNull;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    if (fallback != null) {
      final ws = await WebSocket.connect('${fallback['webSocketDebuggerUrl']}');
      final b = CdpBrowser._(ws, port, kind);
      b._listen();
      return b;
    }
    throw Exception('${kind.label} の操作口につながりませんでした '
        '(ポート $port)。 既に別のプロファイルで起動していないか確かめてください。');
  }

  void _listen() {
    _sub = _ws.listen((data) {
      try {
        final m = jsonDecode('$data');
        if (m is! Map) return;
        final id = m['id'];
        if (id is int) {
          _waiting.remove(id)?.complete(Map<String, dynamic>.from(m));
        }
      } catch (_) {}
    }, onDone: () => _failAll('つながりが切れました'),
        onError: (Object e) => _failAll('$e'));
  }

  void _failAll(String why) {
    _closed = true;
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.completeError(Exception(why));
    }
    _waiting.clear();
  }

  /// 命令を 1 つ送って返事を待つ。
  Future<Map<String, dynamic>> _send(String method,
      [Map<String, dynamic>? params]) async {
    if (_closed) throw Exception('もうつながっていません');
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _waiting[id] = c;
    _ws.add(jsonEncode({
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    return c.future.timeout(const Duration(seconds: 30), onTimeout: () {
      _waiting.remove(id);
      throw Exception('$method の返事がありませんでした');
    });
  }

  /// URL を開いて、 読み込みが落ち着くまで待つ。
  Future<void> navigate(String url, {int waitMs = 2500}) async {
    await _send('Page.enable');
    await _send('Page.navigate', {'url': url});
    await Future<void>.delayed(Duration(milliseconds: waitMs));
  }

  /// そのページで JavaScript を実行する。
  ///
  /// ★ ここがすべての要。 アプリ内ブラウザ向けに書いた仕掛け
  ///   (文字で要素を探して押す / 欄に打つ / 画面の中身を集める) が、
  ///   送り先をここに替えるだけでそのまま外のブラウザに効く。
  Future<String?> evaluate(String js) async {
    final res = await _send('Runtime.evaluate', {
      'expression': js,
      'returnByValue': true,
      'awaitPromise': true,
      // ページ側の例外でこちらが落ちないように。
      'silent': true,
    });
    final r = res['result'];
    if (r is! Map) return null;
    final inner = r['result'];
    if (inner is! Map) return null;
    final v = inner['value'];
    if (v == null) return null;
    return v is String ? v : jsonEncode(v);
  }

  /// 今の URL とタイトル (つながっているか確かめるのにも使う)。
  Future<({String url, String title})?> current() async {
    try {
      final u = await evaluate('location.href') ?? '';
      final t = await evaluate('document.title') ?? '';
      return (url: u, title: t);
    } catch (_) {
      return null;
    }
  }

  /// 画面を撮る (PNG の base64)。
  Future<String?> screenshotBase64() async {
    try {
      final res = await _send('Page.captureScreenshot', {'format': 'png'});
      final r = res['result'];
      if (r is! Map) return null;
      return r['data'] as String?;
    } catch (_) {
      return null;
    }
  }

  bool get isClosed => _closed;

  Future<void> dispose() async {
    _closed = true;
    await _sub?.cancel();
    try {
      await _ws.close();
    } catch (_) {}
    _failAll('閉じました');
  }
}
