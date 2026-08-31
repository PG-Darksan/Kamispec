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

  /// 掴んでいるタブの id (自分のタブだけを閉じるのに使う)。
  String? _targetId;

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
    // 0 なら種類ごとの既定 (= Chrome の口に Edge としてつないでしまう
    //   取り違えを防ぐ。 ポートの向こうが何のブラウザかは分からないため)。
    int port = 0,
    bool useOwnProfile = false,
    // ゲストで開く (= ユーザー要望: 既定のプロファイルが無い時は、
    //   プロファイル選択画面で止まらずゲストモードで開いてほしい)。
    bool guest = false,
    // どのアカウント (プロファイル) で開くか。 呼び名 / メール /
    //   'Profile 1' のいずれでもよい (= ユーザー要望: アカウントを指定)。
    String profileHint = '',
    Duration timeout = const Duration(seconds: 20),
    // 逃げ道を何度も辿らないための数え (内部用)。
    int retry = 0,
  }) async {
    if (!Platform.isWindows) {
      throw Exception('外のブラウザの操作は Windows 版だけです');
    }
    final exe = findExe(kind);
    if (exe == null) {
      throw Exception('${kind.label} が見つかりませんでした');
    }
    if (port <= 0) port = defaultPortFor(kind);
    // 逃げ道は 2 回まで (普段のプロファイル → 使い捨て → ゲスト)。
    //   これ以上は窓を増やすだけなので、 理由を付けて止める。
    if (retry > 2) {
      throw Exception('${kind.label} の操作口を開けませんでした。\n'
          '${kind.label} をいったん完全に閉じてからもう一度お試しください。');
    }
    // 既にその口が開いていれば、 起動せずにつなぐ。
    if (await _probe(port) != null) {
      final b = await _connect(port, kind, timeout, wantUrl: url);
      // ★ 前に開いた窓が残っていることがある。 指定の URL に居なければ
      //   そこへ移動する (= これが無いと、 2 回目の実行が前のページの
      //   ままで進んでいた)。
      await _ensureUrl(b, url);
      // ★ 前回が選択画面のまま残っている場合もある。 その時はゲストで
      //   開き直す (つながっているからと素通りしない)。
      if (await b.isAtProfilePicker()) {
        await b.closeQuietly();
        return launchAndConnect(
          kind: kind,
          url: url,
          port: port + 7,
          guest: true,
          timeout: timeout,
          retry: retry + 1,
        );
      }
      return b;
    }
    // ★ 普段のプロファイルで開く時は、 どのプロファイルかを必ず名指しする。
    //
    //   = ユーザー報告「Chrome はどなたが使用しますか？ の画面で止まる」。
    //   プロファイルが 2 つ以上あると、 Chrome は起動時に選択画面を出して
    //   人が選ぶまで待つ。 自動操作は誰も選べないので、 そこで止まっていた。
    //   --profile-directory を渡せば選択画面を飛ばせて、 ログイン済みの
    //   ままで開ける。 --no-first-run / --no-default-browser-check では
    //   この画面は止まらない (初回案内と既定ブラウザの確認は別物)。
    //
    //   既定 (Default) が無い時は、 ユーザー要望どおりゲストで開く。
    // ★ アカウントを指定された時は、 その写しを使う。
    //
    //   普段の置き場をそのまま指定しても、 新しい Chrome は操作口を
    //   開けてくれず、 既に開いている Chrome にタブだけ増やして終わる。
    //   写しなら、 普段の Chrome を開いたままでも確実に操作できる。
    String? acctDir;
    var pickedProfile = '';
    if (useOwnProfile && !guest) {
      // 呼び名 (「浩靖」 など) から、 そのアカウントを見分ける。
      final hit = profileHint.trim().isEmpty
          ? null
          : listProfiles(kind).where((p) {
              final d = profileDirFor(kind, profileHint);
              return d != null && p.dir == d;
            }).firstOrNull;
      pickedProfile = hit?.name ?? (profileHint.trim().isEmpty
          ? 'default'
          : profileHint.trim());
      acctDir = accountDataDir(kind, pickedProfile);
    }
    final wantGuest = guest;
    // 置き場は必ず自分で用意した所にする (= 普段の置き場を指定すると
    //   操作口が開かず、 既に起動中の Chrome へタブだけ増やして終わる)。
    final dataDir = acctDir ?? _scratchProfileDir(kind, port);
    // ★ 「初めて使うアカウントか」 は、 置き場がまだ無いかどうかで見る。
    //   クッキーの大きさで見ると、 まっさらなプロファイルでも
    //   入れ物だけで数十 KB になるので見分けられない。
    final firstUse = acctDir != null && !Directory(acctDir).existsSync();
    final args = <String>[
      '--remote-debugging-port=$port',
      // 初回の案内や既定ブラウザの確認で止まらないように。
      '--no-first-run',
      '--no-default-browser-check',
      // --guest と --profile-directory は排他 (両方渡すと片方が無視される)。
      if (wantGuest) '--guest',
      '--user-data-dir=$dataDir',
      if (url != null && url.isNotEmpty) url,
    ];
    try {
      await Process.start(exe, args,
          mode: ProcessStartMode.detached, runInShell: false);
    } catch (e) {
      throw Exception('${kind.label} を起動できませんでした: $e');
    }
    CdpBrowser b;
    try {
      b = await _connect(port, kind, timeout, wantUrl: url);
    } catch (_) {
      // ★ 普段のプロファイルは、 新しい Chrome では操作口そのものが
      //   開かないことがある (安全のため、 既定の置き場に対する
      //   remote-debugging が塞がれた)。 ここで諦めず、 使い捨ての
      //   プロファイルで開き直して先へ進める
      //   (= ユーザーの困りごとは「止まってしまう」 こと)。
      if (useOwnProfile) {
        // 写しでも開けなかった。 まっさらな置き場で開き直して先へ進める
        //   (ログインは引き継がれないが、 止まってしまうよりはよい)。
        final alt = await launchAndConnect(
          kind: kind,
          url: url,
          port: port + 7,
          timeout: timeout,
          retry: retry + 1,
        );
        alt.downgradedFromOwnProfile = true;
        return alt;
      }
      throw Exception(
          '${kind.label} の操作口につながりませんでした (ポート $port)。\n'
          '${kind.label} を閉じてから試すか、 別のポートでお試しください。');
    }
    b.ownWindow = true;
    b.openedAsGuest = wantGuest;
    b.profileDir = pickedProfile;
    // 「まだこのアカウント専用のブラウザでログインしていない」 かどうか。
    //   呼び出し側が、 その場合だけ案内を出せるようにする。
    b.needsFirstLogin = firstUse;
    // ★ それでも選択画面に居たら、 ゲストで開き直す (最後の砦)。
    //   会社の設定などで --profile-directory が効かない場合に効く。
    if (!wantGuest && await b.isAtProfilePicker()) {
      // ここで掴んでいるのはユーザー本来のブラウザなので、 窓ごとは
      //   閉じない (自分のタブだけ閉じる)。
      await b.closeQuietly();
      final alt = await launchAndConnect(
        kind: kind,
        url: url,
        // 前の窓が閉じきる前でもぶつからないよう、 別の口で開く。
        port: port + 7,
        guest: true,
        timeout: timeout,
        retry: retry + 1,
      );
      alt.downgradedFromOwnProfile = useOwnProfile;
      return alt;
    }
    // 起動時の URL が効かなかった時のための念押し。
    await _ensureUrl(b, url);
    // 片付けは**つないだ後**に、 今使っている置き場を除いて行う
    //   (先に消しにいくと、 起動中のブラウザの置き場を壊しうる)。
    unawaited(cleanupScratchProfiles(
        keep: {_scratchProfileDir(kind, port).split('\\').last}));
    return b;
  }

  /// 指定の URL に居なければ、 そこへ移動する。
  static Future<void> _ensureUrl(CdpBrowser b, String? url) async {
    final want = (url ?? '').trim();
    if (want.isEmpty) return;
    try {
      final now = (await b.current())?.url ?? '';
      if (now.startsWith(want.split('#').first)) return;
      await b.navigate(want);
    } catch (_) {}
  }

  /// いまプロファイル選択画面 (Chrome はどなたが使用しますか？) に居るか。
  Future<bool> isAtProfilePicker() async {
    try {
      final u = (await current())?.url ?? '';
      return u.contains('://profile-picker') ||
          u.contains('://profile-internals');
    } catch (_) {
      return false;
    }
  }

  /// つながりを切る。 自分で立ち上げた使い捨ての窓なら、 窓も閉じる。
  ///
  /// ★ ユーザーの普段のブラウザには `Browser.close` を送らない。
  ///   あれはプロセスごと終わらせる命令なので、 開いていた作業中のタブまで
  ///   巻き添えで閉じてしまう (= 点検で判明)。 その時は自分が掴んでいる
  ///   タブだけを閉じる。
  Future<void> closeQuietly() async {
    try {
      if (ownWindow) {
        await _send('Browser.close', const {})
            .timeout(const Duration(seconds: 2));
      } else {
        // 掴んでいるタブだけ閉じる (窓は残す)。
        final t = _targetId;
        if (t != null) {
          await _send('Target.closeTarget', {'targetId': t})
              .timeout(const Duration(seconds: 2));
        }
      }
    } catch (_) {}
    await dispose();
  }

  /// 種類ごとの既定の口 (ポート)。
  ///
  /// ★ 全部を 9222 にすると、 先に開いていた別のブラウザの口へつないで
  ///   しまい、 画面には「Edge につながりました」 と出るのに実際は
  ///   Chrome を操作する、 という取り違えが起きる。
  static int defaultPortFor(CdpBrowserKind kind) => 9222 + kind.index * 20;

  /// そのブラウザの「普段の置き場」 (User Data フォルダ)。
  ///
  /// = ユーザーの問い「既定のプロファイルが存在しないから止まるのか？」。
  ///   ここに Default があるかどうかで判断する。
  static String? userDataRoot(CdpBrowserKind kind) {
    final local = Platform.environment['LOCALAPPDATA'];
    final roaming = Platform.environment['APPDATA'];
    switch (kind) {
      case CdpBrowserKind.chrome:
        return local == null ? null : '$local\\Google\\Chrome\\User Data';
      case CdpBrowserKind.edge:
        return local == null ? null : '$local\\Microsoft\\Edge\\User Data';
      case CdpBrowserKind.brave:
        return local == null
            ? null
            : '$local\\BraveSoftware\\Brave-Browser\\User Data';
      case CdpBrowserKind.vivaldi:
        return local == null ? null : '$local\\Vivaldi\\User Data';
      case CdpBrowserKind.opera:
        return roaming == null
            ? null
            : '$roaming\\Opera Software\\Opera Stable';
    }
  }

  /// 既定のプロファイル (Default) が実際にあるか。
  static bool hasDefaultProfile(CdpBrowserKind kind) {
    final root = userDataRoot(kind);
    if (root == null) return false;
    try {
      // Opera は Default という名前のフォルダを作らないので、
      //   置き場があれば「ある」 とみなす。
      if (kind == CdpBrowserKind.opera) return Directory(root).existsSync();
      return Directory('$root\\Default').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 普段の置き場に入っているアカウント (プロファイル) の一覧。
  ///
  /// = ユーザー報告「アカウントを指定してログインしてと頼んでいるのに
  ///   ログインできない」。 これまでは Default しか開けず、 Default は
  ///   たいてい**誰もログインしていない**入れ物なので、 どのアカウントを
  ///   指定しても未ログインのまま開いていた。
  ///
  /// 返すのは (dir, name, account) の並び。 dir は 'Default' /
  /// 'Profile 1' … のフォルダ名、 name は画面に出ている呼び名。
  static List<({String dir, String name, String account})> listProfiles(
      CdpBrowserKind kind) {
    final root = userDataRoot(kind);
    if (root == null) return const [];
    try {
      final f = File('$root\\Local State');
      if (!f.existsSync()) return const [];
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map) return const [];
      final p = j['profile'];
      if (p is! Map) return const [];
      final cache = p['info_cache'];
      if (cache is! Map) return const [];
      final out = <({String dir, String name, String account})>[];
      cache.forEach((k, v) {
        final dir = '$k';
        final m = v is Map ? v : const {};
        out.add((
          dir: dir,
          name: '${m['name'] ?? dir}',
          account: '${m['user_name'] ?? ''}',
        ));
      });
      // Default を先頭に、 あとは名前順。
      out.sort((a, b) {
        if (a.dir == 'Default') return -1;
        if (b.dir == 'Default') return 1;
        return a.dir.compareTo(b.dir);
      });
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 呼び名やアカウント名から、 プロファイルのフォルダ名を探す。
  /// 見つからなければ null。
  static String? profileDirFor(CdpBrowserKind kind, String hint) {
    final h = hint.trim().toLowerCase();
    if (h.isEmpty) return null;
    final list = listProfiles(kind);
    for (final p in list) {
      if (p.dir.toLowerCase() == h) return p.dir;
    }
    for (final p in list) {
      if (p.name.toLowerCase() == h) return p.dir;
    }
    for (final p in list) {
      if (p.account.toLowerCase() == h) return p.dir;
    }
    // 一部でも合えば拾う (「浩靖の垢」 のような書き方に備える)。
    for (final p in list) {
      if (p.name.isNotEmpty && h.contains(p.name.toLowerCase())) return p.dir;
      if (p.account.isNotEmpty &&
          h.contains(p.account.split('@').first.toLowerCase())) {
        return p.dir;
      }
    }
    return null;
  }

  /// その呼び名のアカウントに紐づくメール (無ければ空)。
  ///
  /// 初回だけ人にログインしてもらう時、 どのアカウントで入るのかを
  /// あらかじめ選んだ状態の画面へ連れて行くのに使う。
  static String accountEmailFor(CdpBrowserKind kind, String label) {
    final dir = profileDirFor(kind, label);
    if (dir == null) return '';
    for (final p in listProfiles(kind)) {
      if (p.dir == dir) return p.account;
    }
    return '';
  }

  /// 入っているプロファイルの数 (選択画面が出るかどうかの目安)。
  /// 読めなければ 1 (= 今までどおり)。
  static int profileCount(CdpBrowserKind kind) {
    final root = userDataRoot(kind);
    if (root == null) return 1;
    try {
      final f = File('$root\\Local State');
      if (!f.existsSync()) return 1;
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map) return 1;
      final p = j['profile'];
      if (p is! Map) return 1;
      final cache = p['info_cache'];
      if (cache is! Map) return 1;
      return cache.isEmpty ? 1 : cache.length;
    } catch (_) {
      return 1;
    }
  }

  /// 前に作った使い捨ての置き場を片付ける (= 溜まり続けるため)。
  /// 触っていないものだけ、 静かに消す。
  static Future<void> cleanupScratchProfiles(
      {Duration olderThan = const Duration(days: 3),
      Set<String> keep = const {}}) async {
    try {
      final base = Platform.environment['LOCALAPPDATA'];
      if (base == null) return;
      final dir = Directory('$base\\HisatorNotebook');
      if (!dir.existsSync()) return;
      final now = DateTime.now();
      for (final e in dir.listSync()) {
        if (e is! Directory) continue;
        final name = e.path.split('\\').last;
        if (!name.startsWith('cdp_')) continue;
        // 今まさに使っている置き場は消さない。
        if (keep.contains(name) || keep.contains(e.path)) continue;
        try {
          // ブラウザが掴んでいる置き場も消さない (壊れる)。
          if (File('${e.path}\\lockfile').existsSync()) continue;
          if (now.difference(e.statSync().modified) < olderThan) continue;
          e.deleteSync(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// そのアカウント専用の置き場 (自動操作用のブラウザ) を用意して返す。
  ///
  /// なぜ「普段のプロファイルをそのまま使う」 のではないのか
  /// (どちらも実測で確かめた事実):
  ///
  ///   1. 新しい Chrome (136 以降) は、 **普段の置き場に対しては操作口
  ///      (remote debugging) を開けてくれない**。 実際に試すと、 Chrome を
  ///      完全に閉じた状態でも口は開かなかった。 安全のための制限。
  ///   2. ならば中身を写せばよいかというと、 それも通らない。 Chrome 127
  ///      以降はクッキーの鍵をアプリに縛り付けており (App-Bound
  ///      Encryption)、 プロファイルを写してもログインは引き継がれない。
  ///      「プロファイルを写してログインを盗む」 手口を止めるための仕組み
  ///      なので、 迂回すべきではない。
  ///
  /// そこで、 **アカウントごとに自動操作専用のブラウザを持つ**。
  /// 初回だけ人がそこでログインすれば、 次からはログイン済みで開く。
  /// 普段の Chrome は開いたままでよく、 元のプロファイルには一切触らない。
  static String accountDataDir(CdpBrowserKind kind, String label) {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Directory.systemTemp.path;
    final raw = label.trim();
    if (raw.isEmpty) {
      return '$base\\HisatorNotebook\\cdp_${kind.name}_acct_default';
    }
    // ★ 名前に使えない文字 (日本語など) は落ちてしまうので、 それだけだと
    //   「浩靖」 も「陽香」 も同じ置き場になり、 アカウントが混ざる。
    //   呼び名から作った短い目印を必ず付けて分ける。
    final safe = raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    var h = 0;
    for (final c in raw.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final tag = h.toRadixString(36);
    final head = safe.isEmpty
        ? 'acct'
        : (safe.length > 16 ? safe.substring(0, 16) : safe);
    return '$base\\HisatorNotebook\\cdp_${kind.name}_acct_${head}_$tag';
  }

  /// そのアカウント専用のブラウザで、 もうログイン済みか
  /// (= クッキーが溜まっているか) のおおよその目安。
  static bool accountLoggedInBefore(CdpBrowserKind kind, String label) {
    try {
      final d = accountDataDir(kind, label);
      for (final rel in const [
        'Default\\Network\\Cookies',
        'Default\\Cookies',
      ]) {
        final f = File('$d\\$rel');
        // 空の器だけの時もあるので、 ある程度の大きさを見る。
        if (f.existsSync() && f.lengthSync() > 20 * 1024) return true;
      }
    } catch (_) {}
    return false;
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
        b._targetId = '${pick['id'] ?? ''}'.isEmpty ? null : '${pick['id']}';
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
      b._targetId =
          '${fallback['id'] ?? ''}'.isEmpty ? null : '${fallback['id']}';
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
          return;
        }
        // ★ 返事ではない知らせ (イベント)。 以前は捨てていたので、
        //   ページのログもダウンロードの進み具合も受け取れなかった。
        final method = m['method'];
        if (method is String) {
          _onEvent(method, m['params'] is Map
              ? Map<String, dynamic>.from(m['params'] as Map)
              : const <String, dynamic>{});
        }
      } catch (_) {}
    }, onDone: () => _failAll('つながりが切れました'),
        onError: (Object e) => _failAll('$e'));
  }

  // ─── ページのログ (= ユーザー要望: エラーが起こっている画面の
  //     デバッグログを取れるように) ───────────────────────────────
  final List<String> _logLines = [];
  bool _logCapturing = false;

  /// 集めたログ (新しい物が後ろ)。
  List<String> get consoleLines => List.unmodifiable(_logLines);

  void _addLog(String level, String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _logLines.add('[$level] $t');
    // 溜め込みすぎない。
    while (_logLines.length > 400) {
      _logLines.removeAt(0);
    }
  }

  /// 引数の並びを読める形にする。
  static String _argsText(dynamic args) {
    if (args is! List) return '';
    final out = <String>[];
    for (final a in args) {
      if (a is! Map) continue;
      final v = a['value'];
      if (v != null) {
        out.add(v is String ? v : jsonEncode(v));
        continue;
      }
      final d = a['description'];
      if (d != null) out.add('$d');
    }
    return out.join(' ');
  }

  void _onEvent(String method, Map<String, dynamic> p) {
    switch (method) {
      // console.log / warn / error …
      case 'Runtime.consoleAPICalled':
        if (!_logCapturing) return;
        _addLog('${p['type'] ?? 'log'}', _argsText(p['args']));
        break;
      // 捕まえられなかった例外 (画面が壊れる原因になる物)
      case 'Runtime.exceptionThrown':
        if (!_logCapturing) return;
        final d = p['exceptionDetails'];
        if (d is! Map) return;
        final desc = d['exception'] is Map
            ? '${(d['exception'] as Map)['description'] ?? ''}'
            : '';
        final where = '${d['url'] ?? ''}:${d['lineNumber'] ?? ''}';
        _addLog('error',
            '${desc.isEmpty ? d['text'] ?? '例外' : desc}  ($where)');
        break;
      // 読み込み失敗 / 混在コンテンツなど、 ブラウザ側の記録
      case 'Log.entryAdded':
        if (!_logCapturing) return;
        final e = p['entry'];
        if (e is! Map) return;
        _addLog('${e['level'] ?? 'info'}',
            '${e['text'] ?? ''}  (${e['url'] ?? ''})');
        break;
      // ダウンロードの始まりと終わり
      case 'Browser.downloadWillBegin':
      case 'Page.downloadWillBegin':
        final guid = '${p['guid'] ?? ''}';
        final name = '${p['suggestedFilename'] ?? ''}';
        if (guid.isNotEmpty) _downloadNames[guid] = name;
        _addLog('download', '始まりました: $name');
        break;
      case 'Browser.downloadProgress':
      case 'Page.downloadProgress':
        final state = '${p['state'] ?? ''}';
        final guid = '${p['guid'] ?? ''}';
        if (state == 'completed') {
          final name = _downloadNames[guid] ?? '';
          _downloadDone.add(name);
          _addLog('download', '終わりました: $name');
        } else if (state == 'canceled') {
          _addLog('download', '止まりました');
        }
        break;
    }
  }

  /// ページのログを集め始める。
  Future<void> startConsoleCapture() async {
    if (_logCapturing) return;
    _logCapturing = true;
    for (final m in const ['Runtime.enable', 'Log.enable', 'Page.enable']) {
      try {
        await _send(m);
      } catch (_) {}
    }
  }

  /// 集めたログを消す。
  void clearConsole() => _logLines.clear();

  // ─── ダウンロード (= ユーザー要望: ページのダウンロードボタンを
  //     押して保存できるように) ───────────────────────────────────
  final Map<String, String> _downloadNames = {};
  final List<String> _downloadDone = [];

  /// 終わったダウンロードのファイル名 (古い順)。
  List<String> get downloadedNames => List.unmodifiable(_downloadDone);

  /// ダウンロードの受け入れを始める。 [dir] に保存される。
  ///
  /// 返り値は「その場で断られなかったか」。 新しめの Chromium は
  /// Browser.setDownloadBehavior、 古い物は Page.setDownloadBehavior。
  Future<bool> enableDownloads(String dir) async {
    _downloadDone.clear();
    var ok = false;
    try {
      await _send('Browser.setDownloadBehavior', {
        'behavior': 'allow',
        'downloadPath': dir,
        'eventsEnabled': true,
      });
      ok = true;
    } catch (_) {}
    if (!ok) {
      try {
        await _send('Page.setDownloadBehavior', {
          'behavior': 'allow',
          'downloadPath': dir,
        });
        ok = true;
      } catch (_) {}
    }
    return ok;
  }

  /// ダウンロードが 1 つ終わるまで待つ。 終わったファイル名を返す。
  Future<String?> waitForDownload(
      {Duration timeout = const Duration(seconds: 60)}) async {
    final until = DateTime.now().add(timeout);
    final from = _downloadDone.length;
    while (DateTime.now().isBefore(until)) {
      if (_downloadDone.length > from) return _downloadDone.last;
      if (_closed) return null;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return null;
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
  ///
  /// [clip] を渡すとその範囲だけ、 [fullPage] が true ならページの
  /// 上から下まで 1 枚で撮る (= 手順の「範囲」 と「縦長 1 枚」 に対応)。
  Future<String?> screenshotBase64({
    ({double x, double y, double w, double h})? clip,
    bool fullPage = false,
  }) async {
    try {
      final params = <String, dynamic>{'format': 'png'};
      if (clip != null) {
        params['clip'] = {
          'x': clip.x,
          'y': clip.y,
          'width': clip.w,
          'height': clip.h,
          'scale': 1,
        };
      } else if (fullPage) {
        // ページ全体。 高さは実測してから渡す (対応していない版のための保険)。
        params['captureBeyondViewport'] = true;
        final raw = await evaluate('(function(){'
            'var e=document.scrollingElement||document.documentElement;'
            'return String(Math.round(e.scrollWidth))+","'
            '+String(Math.round(e.scrollHeight));})();');
        final p = (raw ?? '').replaceAll('"', '').split(',');
        final w = p.length == 2 ? double.tryParse(p[0]) : null;
        final h = p.length == 2 ? double.tryParse(p[1]) : null;
        if (w != null && h != null && w > 0 && h > 0) {
          params['clip'] = {
            'x': 0,
            'y': 0,
            'width': w,
            // あまりに長いと失敗するので上限を設ける。
            'height': h > 20000 ? 20000 : h,
            'scale': 1,
          };
        }
      }
      final res = await _send('Page.captureScreenshot', params);
      final r = res['result'];
      if (r is! Map) return null;
      return r['data'] as String?;
    } catch (_) {
      // 全面撮影に対応していない相手では、 見えている分だけでも返す。
      if (clip != null || fullPage) {
        try {
          final res = await _send('Page.captureScreenshot', {'format': 'png'});
          final r = res['result'];
          if (r is Map) return r['data'] as String?;
        } catch (_) {}
      }
      return null;
    }
  }

  /// 自分が使い捨ての置き場で立ち上げた窓か。
  ///
  /// ★ これが false の窓へ `Browser.close` を送ってはいけない。 相手は
  ///   ユーザーが普段使っている Chrome そのもので、 開いていた窓もタブも
  ///   まとめて閉じてしまう (= 点検で判明)。
  bool ownWindow = false;

  /// 普段のプロファイルで開けず、 使い捨てに切り替えたか
  /// (呼び出し側が「ログインは引き継がれていない」 と伝えるための印)。
  bool downgradedFromOwnProfile = false;

  /// ゲストで開いたか。
  bool openedAsGuest = false;

  /// どのアカウントで開いたか (画面に出ている呼び名)。
  String profileDir = '';

  /// このアカウント専用のブラウザで、 まだ一度もログインしていない。
  ///
  /// 初回だけ人がログインする必要がある (Chrome の保護のため、 普段の
  /// プロファイルのログインは持ってこられない)。
  bool needsFirstLogin = false;

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
