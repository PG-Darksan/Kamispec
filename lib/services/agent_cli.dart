// ── パソコンに入っている AI の CLI をアプリの中で使う ──
//
// (= ユーザー要望: codex CLI / Gemini CLI / Claude Code をアプリ内にログインして
//  指示出して使えるように)
//
// **なぜ擬似端末 (pty) を使うのか**
//   これらの CLI のログインは「端末に出た案内を読んで、ブラウザで承認し、
//   CLI 自身が待ち受けているコールバックへ戻る」という流れ。ブラウザを開く所も
//   戻りを受け取る所も **CLI が自分で持っている**ので、アプリ側が OAuth を
//   実装する必要は無い。詰まるのはその手前で、CLI は「対話できる端末がある」
//   と判断できないと起動を拒む (パイプ越しだと待ちっぱなしになる)。
//   そこで本物の擬似端末 (Windows は ConPTY) を用意する。VSCode の統合
//   ターミナルと同じ仕組み (向こうは node-pty)。
//
// **どこまでやるか**
//   アプリはターミナルを用意するだけ。ログインの中身にも資格情報にも触らない。
//   資格情報は CLI 自身が自分の場所 (~/.claude, ~/.codex 等) に保存する。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:win32/win32.dart' as w32;

import '../utils/build_flags.dart';

/// 書庫 (.tgz) の中の 1 ファイル。
class _UnpackedFile {
  const _UnpackedFile(this.name, this.bytes);
  final String name;
  final List<int> bytes;
}

/// .tgz を解く (別の isolate で回すので、 画面が固まらない)。
///
/// ★ ここは `compute` から呼ぶので、 トップレベルの関数でなければならない。
List<_UnpackedFile> _unpackTgz(List<int> bytes) {
  final tar = GZipDecoder().decodeBytes(bytes);
  final archive = TarDecoder().decodeBytes(tar);
  final out = <_UnpackedFile>[];
  for (final f in archive.files) {
    if (!f.isFile) continue;
    out.add(_UnpackedFile(f.name, f.content as List<int>));
  }
  return out;
}

/// 相手にする CLI。
///
/// ★ gemini は一覧から外した (= ユーザー判断)。 Gemini CLI の Google
///   ログインは CLI 自身が 127.0.0.1 の待ち受けを立てる形で、 この環境では
///   セキュリティソフトに必ず止められる。 残る道は API キーを渡す事だけで、
///   それは「契約しているぶんを使うので AI の残高は減りません」 という
///   この画面の前提と食い違う (API キーは使った分だけ課金される)。
///   種別そのものは、 控えの読み書き等で参照が残っているので消さない。
enum AgentCliKind { claude, codex, gemini }

/// 1 つの CLI の呼び方。
///
/// ★ 引数の形はバージョンで変わる。ここを 1 か所にまとめておき、
///   利用者が設定で直せるようにするための置き場でもある。
class AgentCliSpec {
  const AgentCliSpec({
    required this.kind,
    required this.label,
    required this.exeNames,
    required this.installHint,
    this.loginArgs = const <String>[],
  });

  final AgentCliKind kind;
  final String label;

  /// 探す実行ファイル名。
  ///
  /// ★ Windows の npm グローバル導入は実体が `claude.cmd` (バッチのシム)。
  ///   `.cmd` / `.ps1` を候補に入れないと「入っているのに見つからない」になる。
  final List<String> exeNames;

  /// 入っていない時に出す案内 (そのまま打てるコマンド)。
  final String installHint;

  /// npm で入れる時の包名。
  String get npmPackage {
    final i = installHint.indexOf('-g ');
    return i < 0 ? '' : installHint.substring(i + 3).trim();
  }

  /// ログインを明示的に始める引数 (空なら素で起動するだけ)。
  final List<String> loginArgs;

  static const List<AgentCliSpec> all = <AgentCliSpec>[
    AgentCliSpec(
      kind: AgentCliKind.claude,
      label: 'Claude Code',
      exeNames: ['claude.cmd', 'claude.exe', 'claude.ps1', 'claude'],
      installHint: 'npm i -g @anthropic-ai/claude-code',
    ),
    AgentCliSpec(
      kind: AgentCliKind.codex,
      label: 'Codex CLI',
      exeNames: ['codex.cmd', 'codex.exe', 'codex.ps1', 'codex'],
      installHint: 'npm i -g @openai/codex',
      loginArgs: ['login'],
    ),
    // ★ Gemini CLI は出さない (理由は AgentCliKind の覚書)。
  ];

  /// ★ 一覧に無い種別 (= 出さなくなった Gemini) を渡されても落ちないよう、
  ///   その場で最低限の姿を作って返す。 `firstWhere` のままだと、 控えに
  ///   残っている種別を読んだだけで例外になる。
  static AgentCliSpec of(AgentCliKind k) {
    for (final e in all) {
      if (e.kind == k) return e;
    }
    return AgentCliSpec(
      kind: k,
      label: k.name,
      exeNames: <String>['${k.name}.cmd', '${k.name}.exe', k.name],
      installHint: '',
    );
  }
}

/// 見つかった CLI の情報。
class AgentCliFound {
  const AgentCliFound({
    required this.spec,
    this.exePath,
    this.loggedInHint,
    this.launchExe,
    this.launchPrefixArgs = const <String>[],
  });

  final AgentCliSpec spec;

  /// 見つかった実行ファイルの絶対パス (null = 見つからない)。
  final String? exePath;

  /// ログインしていそうか (**目安**。設定ファイルの有無で見るだけなので、
  /// 期限切れでも true になる。最終判定は実際に動かした結果に任せる)。
  final bool? loggedInHint;

  /// 実際に起こす物 (= ユーザー報告: 「悪意のあるプロセスがブロックされました」
  /// がしょっちゅう出る)。
  ///
  /// ★ npm でグローバルに入れた CLI の実体は `codex.cmd` のようなバッチの
  ///   薄皮で、 これは `CreateProcessW` では起こせない。 今までは
  ///   `runInShell` でごまかしていたが、 それは **AI に頼むたびに
  ///   `cmd.exe /c …` を黙って起こす**ということで、 セキュリティソフトから
  ///   見ると「画面のあるアプリが裏でシェルを起こした」 という一番疑われる
  ///   形になっていた。 薄皮の中身を読んで本体 (`…\node.exe` +
  ///   `…\cli.js`、 または同梱の `.exe`) を割り出し、 それを直に起こす。
  ///   こうすればシェルは 1 つも挟まらない。
  final String? launchExe;
  final List<String> launchPrefixArgs;

  bool get installed => (exePath ?? '').isNotEmpty;

  /// 起こす実行ファイル (割り出せていなければ見つけた物そのまま)。
  String? get runExe => launchExe ?? exePath;

  /// シェル (`cmd.exe /c`) を挟まないと起こせない形か。
  ///
  /// 薄皮の中身を割り出せた時は false になる = シェルを起こさない。
  bool get needsShell {
    final e = (runExe ?? '').toLowerCase();
    return e.endsWith('.cmd') || e.endsWith('.bat');
  }
}

class AgentCli {
  /// この機能を出してよい環境か。
  ///
  /// ・Android / iOS … 子プロセスを起こせない
  /// ・ストア提出版 … 外から持ってきた実行ファイルを動かすのは規約上まずい
  ///   (Web 自動操作のコマンド実行も同じ理由で落としてある)
  static bool get supported =>
      !kIsWeb &&
      !kStoreBuild &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  static final Map<AgentCliKind, AgentCliFound> _cache = {};

  /// 調べている最中の物 (= 同じ物を何度も探しに行かせないため)。
  ///
  /// ★ 画面は `FutureBuilder(future: findAll())` の形で作られており、 描き
  ///   直しのたびに新しい探索が始まる。 控えに入る前に次が始まると、 その
  ///   ぶんだけ余計に走ってしまう。 走っている物があればそれを使い回す。
  static final Map<AgentCliKind, Future<AgentCliFound>> _inflight = {};

  /// 調べ直す (入れた直後に押してもらう用)。
  static void forget() {
    _cache.clear();
    _inflight.clear();
    _npmPath = null;
    _npmSearched = false;
  }

  /// CLI を探す。
  ///
  /// 探し方は 2 段 (どちらもファイルを見るだけ。 外のプログラムは起こさない):
  ///   1. よくある置き場を直に見る (npm / bun / ローカル bin)
  ///   2. PATH の各所を総当たり (Windows は PATHEXT の拡張子も試す)
  ///
  /// ★ 以前は最後に `where` / `which` に聞いていた。 見つからない CLI 1 つに
  ///   つき 4 回、 3 種類まとめて調べると最大 12 個のプロセスが一気に立つ。
  ///   画面のあるアプリが短時間に大量の小さなプロセスを起こす形は、
  ///   セキュリティソフトが真っ先に疑う形 (= ユーザー報告)。 `where` が
  ///   見る場所は PATH なので、 下の総当たりで同じ物が見つかる。 やめた。
  static Future<AgentCliFound> find(AgentCliKind kind) {
    final hit = _cache[kind];
    if (hit != null) return Future.value(hit);
    final running = _inflight[kind];
    if (running != null) return running;
    final task = _find(kind);
    _inflight[kind] = task;
    return task.whenComplete(() => _inflight.remove(kind));
  }

  static Future<AgentCliFound> _find(AgentCliKind kind) async {
    final spec = AgentCliSpec.of(kind);
    String? found;
    if (supported) {
      // ★ npm を通さずに入れた物を先に見る (= ユーザー報告: npm の途中で
      //   node が止められて入れ終わらない)。 こちらは PATH に何も撒かない
      //   ので、 探し方を知っているのはアプリだけ。
      final manual = manualInstalls[kind] ?? '';
      if (manual.isNotEmpty && File(manual).existsSync()) {
        found = manual;
      }
      found ??= await _search(spec);
    }
    final launch = found == null ? null : resolveLauncher(found);
    final res = AgentCliFound(
      spec: spec,
      exePath: found,
      loggedInHint: found == null ? null : await _loggedInHint(kind),
      launchExe: launch?.exe,
      launchPrefixArgs: launch?.args ?? const <String>[],
    );
    _cache[kind] = res;
    return res;
  }

  static Future<List<AgentCliFound>> findAll() async {
    final out = <AgentCliFound>[];
    for (final s in AgentCliSpec.all) {
      out.add(await find(s.kind));
    }
    return out;
  }

  static Future<String?> _search(AgentCliSpec spec) async {
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    final sep = Platform.pathSeparator;
    final dirs = <String>[
      if ((env['APPDATA'] ?? '').isNotEmpty) '${env['APPDATA']}${sep}npm',
      if ((env['LOCALAPPDATA'] ?? '').isNotEmpty)
        '${env['LOCALAPPDATA']}${sep}Programs',
      if (home.isNotEmpty) ...[
        '$home$sep.local${sep}bin',
        '$home$sep.bun${sep}bin',
        '$home$sep.npm-global${sep}bin',
        '$home${sep}bin',
      ],
      '/usr/local/bin',
      '/opt/homebrew/bin',
      ...(env['PATH'] ?? '').split(Platform.isWindows ? ';' : ':'),
    ];
    // Windows は「拡張子を書かずに置いてある物」 も拾えるよう、 PATHEXT の
    //   拡張子を足して試す (= `where` がやっていたのと同じこと)。
    final exts = Platform.isWindows
        ? (Platform.environment['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD')
            .split(';')
            .map((e) => e.trim().toLowerCase())
            .where((e) => e.startsWith('.'))
            .toList()
        : const <String>[];
    for (final d in dirs) {
      final dir = d.trim();
      if (dir.isEmpty) continue;
      for (final name in spec.exeNames) {
        try {
          final f = File('$dir$sep$name');
          if (f.existsSync()) return f.path;
          if (exts.isNotEmpty && !name.contains('.')) {
            for (final ext in exts) {
              final g = File('$dir$sep$name$ext');
              if (g.existsSync()) return g.path;
            }
          }
        } catch (_) {}
      }
    }
    return null;
  }

  /// バッチの薄皮 (`codex.cmd` など) から、 本当に起こす物を割り出す。
  ///
  /// = ユーザー報告「悪意のあるプロセスがブロックされましたとしょっちゅう出る」。
  ///
  /// npm でグローバルに入れた CLI の実体は、 `node.exe` に JS を渡すだけの
  /// バッチ。 バッチは `CreateProcessW` では起こせないので、 今までは
  /// `runInShell` (= 中で `cmd.exe /c` が走る) に頼っていた。 それだと
  /// **AI に頼むたびに黙ってシェルが立つ**ので、 セキュリティソフトから
  /// 見れば「画面のあるアプリが裏でシェルを起こしている」 という、 一番
  /// 疑われる形になる。
  ///
  /// 薄皮の中身は決まった形なので、 引用符の中の道筋を読めば本体が分かる。
  /// 同じ場所に本物の `.exe` が同梱されている作りもあるので、 そちらを先に探す。
  /// 割り出せない時は null (呼び出し側は今までどおりシェル経由で起こす)。
  static ({String exe, List<String> args})? resolveLauncher(String exePath) {
    final lower = exePath.toLowerCase();
    // ★ npm を通さずに入れた物は、 JavaScript のまま置いてある。 node に
    //   渡して走らせる (薄皮も PATH の登録も無い)。
    if (lower.endsWith('.js') || lower.endsWith('.mjs') ||
        lower.endsWith('.cjs')) {
      final node = _findNodeExe(File(exePath).parent.path);
      if (node == null) return null;
      return (exe: ptySafePath(node), args: <String>[ptySafePath(exePath)]);
    }
    if (!Platform.isWindows) return null;
    if (!lower.endsWith('.cmd') && !lower.endsWith('.bat')) return null;
    try {
      final file = File(exePath);
      if (!file.existsSync()) return null;
      final dir = file.parent.path;
      final sep = Platform.pathSeparator;
      final text = file.readAsStringSync();
      // 引用符の中にある、 %dp0% からの相対の道筋を拾う。
      final hits = RegExp('"%(?:dp0|~dp0)%[\\\\/]?([^"]+)"')
          .allMatches(text)
          .map((m) => m.group(1) ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
      String? js;
      String? exe;
      for (final rel in hits) {
        final path = '$dir$sep${rel.replaceAll('/', sep)}';
        final base = path.split(RegExp(r'[\\/]')).last.toLowerCase();
        // ★ node は「走らせる人」 であって CLI 本体ではない。 薄皮の頭には
        //   `IF EXIST "%dp0%\node.exe" (` という行があり、 引用符の中の
        //   最初の道筋はこれに当たる。 ここを本体と取り違えると、 ただの
        //   node が立ち上がって CLI が動かない (= 点検で判明)。
        if (base == 'node.exe' || base == 'node') continue;
        if (!File(path).existsSync()) continue;
        if (base.endsWith('.exe')) {
          exe ??= path;
        } else if (base.endsWith('.js') ||
            base.endsWith('.mjs') ||
            base.endsWith('.cjs')) {
          js ??= path;
        }
      }
      // ★ 隣に在る `.exe` を適当に拾う事はしない。 同じ bin に別の道具の
      //   実行ファイルが入っている事があり、 名前も確かめずに拾うと
      //   まるで違う物を起こしてしまう (= 点検で判明)。 薄皮が名指しして
      //   いる物だけを使う。
      if (exe != null) {
        return (exe: ptySafePath(exe), args: const <String>[]);
      }
      if (js == null) return null;
      final node = _findNodeExe(dir);
      if (node == null) return null;
      // node は `C:\Program Files\nodejs\node.exe` に入っている事が多い。
      //   擬似端末は引用符を付けずに空白でつなぐだけなので、 短い名前にする。
      return (exe: ptySafePath(node), args: <String>[ptySafePath(js)]);
    } catch (e) {
      debugPrint('resolveLauncher failed: $e');
      return null;
    }
  }

  /// node.exe を探す (薄皮の隣 → PATH の順)。
  static String? _findNodeExe(String shimDir) {
    final sep = Platform.pathSeparator;
    final names = Platform.isWindows
        ? const ['node.exe']
        : const ['node'];
    for (final n in names) {
      final sibling = File('$shimDir$sep$n');
      if (sibling.existsSync()) return sibling.path;
    }
    final dirs = <String>[
      ...(Platform.environment['PATH'] ?? '')
          .split(Platform.isWindows ? ';' : ':'),
      if (!Platform.isWindows) ...['/usr/local/bin', '/opt/homebrew/bin'],
    ];
    for (final d in dirs) {
      final dir = d.trim();
      if (dir.isEmpty) continue;
      for (final n in names) {
        try {
          final f = File('$dir$sep$n');
          if (f.existsSync()) return f.path;
        } catch (_) {}
      }
    }
    return null;
  }

  /// ログイン済みかの**目安**。
  ///
  /// ★ あくまで目安。ファイルが在るだけで中身も期限も見ていないので、
  ///   これを根拠に「使えます」と断言しないこと。
  static Future<bool?> _loggedInHint(AgentCliKind kind) async {
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    if (home.isEmpty) return null;
    final sep = Platform.pathSeparator;
    final candidates = switch (kind) {
      AgentCliKind.claude => [
          '$home$sep.claude$sep.credentials.json',
          '$home$sep.claude${sep}credentials.json',
        ],
      AgentCliKind.codex => [
          '$home$sep.codex${sep}auth.json',
        ],
      AgentCliKind.gemini => [
          '$home$sep.gemini${sep}oauth_creds.json',
          '$home$sep.config${sep}gemini${sep}oauth_creds.json',
        ],
    };
    for (final c in candidates) {
      try {
        if (File(c).existsSync()) return true;
      } catch (_) {}
    }
    // ★ Gemini を API キーで使う時は、 ログインの控え (oauth_creds.json) が
    //   どこにも出来ない。 それだけを見ていると、 使えているのに永遠に
    //   「要ログイン」 と出てしまう (= ユーザー報告の迂回策と噛み合わない)。
    //   アプリがキーを預かっているならログイン済みとみなす。
    if (kind == AgentCliKind.gemini && geminiApiKeyForCli.isNotEmpty) {
      return true;
    }
    return false;
  }

  /// アプリが預かっている Gemini の API キー (画面側が入れてくれる)。
  ///
  /// ここに入っていると、 ブラウザでの承認を通さずに Gemini CLI を使える
  /// (= ユーザー報告: ログインがセキュリティソフトに止められる)。
  static String geminiApiKeyForCli = '';

  // ─── npm を通さずに入れる ───────────────────────────────────────────
  //
  //   = ユーザー報告「Gemini CLI が依然としてインストールできない。
  //     コード 3221226528 が出て、 『Node.js JavaScript Runtime の
  //     Lockdown の悪意のある動作はブロックされました』 と出る」。
  //
  //   3221226528 は 0xC0000420 で、 「外から強制的に終わらされた」 形。
  //   つまり npm の途中で node ごと落とされている。 引数を減らしても
  //   npm を使う限り node は走るので、 **npm を一切使わない道**を用意する。
  //
  //   npm の取り込み先 (registry.npmjs.org) は、 ただの HTTPS で置いてある
  //   書庫 (.tgz)。 アプリが自分で落として、 自分で開いて、 自分の
  //   フォルダーへ置けばよい。 外のプログラムは 1 つも起こさない。
  //
  //   ★ 使う時は node が要る (どの CLI も中身は JavaScript)。 ただし
  //     「入れる時に止められる」 のと「使う時に止められる」 のは別の話で、
  //     止められているのは入れる時の振る舞い (書庫を開いて PATH の通った
  //     場所に起動用の小さなファイルを撒く) の方。
  //   ★ 後片付けの JS を持つ包 (Claude Code) はこの道では入れられない。
  //     据え付けを自分でやる作りなので、 npm に任せる。

  /// この道で入れた物の置き場 (種類 → 入口のファイル)。
  static final Map<AgentCliKind, String> manualInstalls = {};

  static String _manualKey(AgentCliKind k) => 'agent_cli_manual_${k.name}';

  /// 起動時に読み出す。
  static Future<void> loadManualInstalls() async {
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in AgentCliKind.values) {
        final v = p.getString(_manualKey(k)) ?? '';
        if (v.isNotEmpty && File(v).existsSync()) manualInstalls[k] = v;
      }
    } catch (_) {}
  }

  /// npm を使わずに入れられる相手か。
  ///
  /// Claude Code は取り込んだ後の据え付け (postinstall) で本体を置く作りなので、
  /// 書庫を開いただけでは動かない。 そこだけ除く。
  static bool canInstallWithoutNpm(AgentCliKind kind) =>
      kind != AgentCliKind.claude;

  /// npm を使わずに入れる。 入口のファイルの道を返す (失敗は null)。
  static Future<String?> installWithoutNpm(
    AgentCliKind kind, {
    void Function(String line)? onLog,
  }) async {
    if (!supported) return null;
    final spec = AgentCliSpec.of(kind);
    final pkg = spec.npmPackage;
    if (pkg.isEmpty) return null;
    void log(String s) {
      debugPrint('installWithoutNpm: $s');
      onLog?.call(s);
    }

    try {
      log('$pkg の置き場を調べています…');
      final metaRes = await http
          .get(Uri.parse('https://registry.npmjs.org/$pkg/latest'))
          .timeout(const Duration(seconds: 40));
      if (metaRes.statusCode != 200) {
        log('取り込み先が応答しません (${metaRes.statusCode})');
        return null;
      }
      final meta = jsonDecode(utf8.decode(metaRes.bodyBytes));
      if (meta is! Map) return null;
      final version = '${meta['version'] ?? ''}';
      final tarball = '${(meta['dist'] as Map?)?['tarball'] ?? ''}';
      if (tarball.isEmpty) {
        log('書庫の場所が分かりませんでした');
        return null;
      }
      // 入口 (bin) の中の道。 1 つだけの事がほとんど。
      final bin = meta['bin'];
      var entryRel = '';
      if (bin is Map && bin.isNotEmpty) {
        entryRel = '${bin[spec.exeNames.last] ?? bin.values.first}';
      }
      if (entryRel.isEmpty) {
        log('入口のファイルが分かりませんでした');
        return null;
      }

      final sup = await getApplicationSupportDirectory();
      final sep = Platform.pathSeparator;
      final dir =
          Directory('${sup.path}${sep}agent_cli${sep}tools$sep${kind.name}');
      if (await dir.exists()) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
      await dir.create(recursive: true);

      log('$pkg $version を取り込んでいます…');
      await _fetchAndUnpack(tarball, dir.path, log);

      // 土台ごとに分かれている部品 (win32-x64 など) も一緒に。
      final opt = meta['optionalDependencies'];
      if (opt is Map) {
        final want = Platform.isWindows
            ? 'win32-x64'
            : Platform.isMacOS
                ? 'darwin'
                : 'linux-x64';
        for (final e in opt.entries) {
          final name = '${e.key}';
          if (!name.contains(want)) continue;
          log('$name を取り込んでいます…');
          try {
            final sub = await http
                .get(Uri.parse('https://registry.npmjs.org/$name/latest'))
                .timeout(const Duration(seconds: 40));
            if (sub.statusCode != 200) continue;
            final sm = jsonDecode(utf8.decode(sub.bodyBytes));
            final st = '${(sm is Map ? sm['dist'] : null) is Map ? (sm['dist'] as Map)['tarball'] : ''}';
            if (st.isEmpty) continue;
            // node は自分の場所から上へ node_modules を辿るので、 ここへ置く。
            final into =
                '${dir.path}${sep}package${sep}node_modules$sep${name.replaceAll('/', sep)}';
            await Directory(into).create(recursive: true);
            await _fetchAndUnpack(st, into, log, strip: 'package/');
          } catch (err) {
            log('$name は取り込めませんでした (使わずに続けます)');
          }
        }
      }

      final entry =
          '${dir.path}${sep}package$sep${entryRel.replaceAll('/', sep)}';
      if (!File(entry).existsSync()) {
        log('入口のファイルが見つかりません: $entry');
        return null;
      }
      manualInstalls[kind] = entry;
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString(_manualKey(kind), entry);
      } catch (_) {}
      forget();
      log('入りました。');
      return entry;
    } catch (e) {
      log('入れられませんでした: $e');
      return null;
    }
  }

  /// .tgz を落として開く。 [strip] を渡すとその前置きを外して展開する。
  static Future<void> _fetchAndUnpack(
      String url, String intoDir, void Function(String) log,
      {String strip = ''}) async {
    final res =
        await http.get(Uri.parse(url)).timeout(const Duration(minutes: 5));
    if (res.statusCode != 200) {
      throw Exception('書庫を落とせませんでした (${res.statusCode})');
    }
    // 解くのは重いので、 別の isolate で。 画面が固まらない。
    final files = await compute(_unpackTgz, res.bodyBytes);
    final sep = Platform.pathSeparator;
    for (final f in files) {
      var rel = f.name;
      if (strip.isNotEmpty && rel.startsWith(strip)) {
        rel = rel.substring(strip.length);
      }
      if (rel.isEmpty) continue;
      // 書庫の中の「..」 で外へ抜けさせない。
      if (rel.contains('..')) continue;
      final path = '$intoDir$sep${rel.replaceAll('/', sep)}';
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(f.bytes, flush: false);
    }
  }
  /// npm を探す (「インストール」 ボタン用)。
  ///
  /// ★ 隠した PowerShell を撃つやり方は取らない。 画面の見える端末で
  ///   npm をそのまま動かす (= 何が起きているか利用者に見えるし、
  ///   セキュリティソフトに「黙ってシェルを起こした」 と見られない)。
  static String? _npmPath;
  static bool _npmSearched = false;

  static Future<String?> findNpm() async {
    if (!supported) return null;
    // ★ 押すたびに探し直さない (= 無駄なファイル走査を減らす)。 入れ直した
    //   時は [forget] で控えごと消える。
    if (_npmSearched) return _npmPath;
    const spec = AgentCliSpec(
      kind: AgentCliKind.claude,
      label: 'npm',
      exeNames: ['npm.cmd', 'npm.exe', 'npm'],
      installHint: '',
    );
    _npmPath = await _search(spec);
    _npmSearched = true;
    return _npmPath;
  }

  // ── ただのターミナル (= ユーザー要望: ターミナルを開くボタン) ──────────

  /// 擬似端末に渡しても壊れない環境変数。
  ///
  /// ★ flutter_pty は環境変数も 1 バイトずつ WCHAR へ広げるので、 日本語を
  ///   含む値はそのまま渡すと子プロセス側で文字化けする。 このパソコンでは
  ///   `Path` と `PSModulePath` に `…\OneDrive\ドキュメント\…` が入っており、
  ///   黙って壊れた道筋が渡っていた。
  ///   道筋の並びは壊れた所だけ捨て、 それ以外で非英数の値は丸ごと落とす。
  static Map<String, String> asciiEnvironment() {
    final out = <String, String>{};
    Platform.environment.forEach((k, v) {
      if (!isAscii(k)) return;
      if (isAscii(v)) {
        out[k] = v;
        return;
      }
      if (v.contains(';')) {
        // 道筋の並びは、 壊れる所だけ抜いて残す。
        final keep = v.split(';').where((e) => e.isNotEmpty && isAscii(e));
        if (keep.isNotEmpty) out[k] = keep.join(';');
        return;
      }
      // 直しようが無い物は渡さない (壊れた値より無い方が安全)。
    });
    return out;
  }

  /// シェルをどう起こすか (実行ファイル・引数・最初の居場所)。
  ///
  /// ★ 日本語を含む場所では、 作業フォルダーとしても引数としても素では
  ///   渡せない (どちらも 1 バイトずつ広げられて壊れる)。 そこで
  ///   **場所を base64 にして**英数字だけの 1 語に畳み、 PowerShell 自身に
  ///   復元させて移動させる。 引用符も空白も無いので、 引数を空白で切る
  ///   flutter_pty の作りとも噛み合う。 (8.3 形式の短い名前は、 日本語
  ///   Windows では短い名前自体に日本語が残るため使えない — 実測)
  static ({String exe, List<String> args, String dir}) shellLaunch(
      String workingDir) {
    final exe = systemShell();
    if (!Platform.isWindows || isAscii(workingDir)) {
      return (exe: exe, args: const <String>[], dir: workingDir);
    }
    if (!exe.toLowerCase().endsWith('powershell.exe')) {
      // cmd では畳んだ指示を渡せないので、 英数字の場所で開く。
      return (exe: exe, args: const <String>[], dir: _asciiStartDir());
    }
    final b64 = base64.encode(utf8.encode(workingDir));
    return (
      exe: exe,
      args: <String>[
        '-NoLogo',
        '-NoExit',
        '-Command',
        "Set-Location([Text.Encoding]::UTF8.GetString("
            "[Convert]::FromBase64String('$b64')))",
      ],
      dir: _asciiStartDir(),
    );
  }

  static String _asciiStartDir() {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    return isAscii(root) ? root : r'C:\Windows';
  }

  /// OS のシェル。 Windows は PowerShell (無ければ cmd)。
  static String systemShell() {
    if (Platform.isWindows) {
      final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      for (final p in [
        '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
        '$root\\System32\\cmd.exe',
      ]) {
        try {
          if (File(p).existsSync()) return p;
        } catch (_) {}
      }
      return 'cmd.exe';
    }
    final sh = Platform.environment['SHELL'] ?? '';
    return sh.isNotEmpty ? sh : '/bin/bash';
  }

  /// 英数字だけで出来ているか。
  static bool isAscii(String s) {
    for (final c in s.codeUnits) {
      if (c > 0x7e || c < 0x20) return false;
    }
    return true;
  }

  /// 擬似端末にそのまま渡せる形の作業フォルダー (渡せないなら null)。
  ///
  /// ★ flutter_pty の Windows 実装は、 受け取った道筋を **1 バイトずつ
  ///   そのまま WCHAR へ広げる**だけ
  ///   (`src/flutter_pty_win.c` の `build_working_directory`)。
  ///   英数字なら偶然それで正しいが、 日本語が入ると文字化けした道筋で
  ///   `CreateProcessW` を呼ぶので「Failed to create process」 になる
  ///   (= ユーザー報告: デスクトップの下でターミナルが開けない)。
  ///
  ///   8.3 形式の短い名前 (`GetShortPathNameW`) は英数字だけなので、
  ///   それに直して渡す。 短い名前が無効な環境では null を返すので、
  ///   呼び出し側 (AgentCliSession) が別の手 (プロセスの現在地を一時的に
  ///   移す) に切り替える。
  static String? ptySafeDirectory(String path) {
    if (path.isEmpty) return null;
    if (!Platform.isWindows || isAscii(path)) return path;
    final src = path.toNativeUtf16();
    final buf = calloc<ffi.Uint16>(1024).cast<Utf16>();
    try {
      final n = w32.GetShortPathName(src, buf, 1024);
      if (n == 0 || n >= 1024) return null;
      final short = buf.toDartString();
      return isAscii(short) ? short : null;
    } catch (e) {
      debugPrint('ptySafeDirectory failed: $e');
      return null;
    } finally {
      calloc.free(src);
      calloc.free(buf);
    }
  }

  /// 擬似端末へ「引数として」 渡しても壊れない形の道筋。
  ///
  /// ★ flutter_pty の Windows 実装は、 実行ファイルと引数を**空白でつなぐ
  ///   だけ**で、 引用符を一切付けない (`build_command`)。 つまり
  ///   `C:\Program Files\nodejs\node.exe` のように空白を含む道筋は、 その
  ///   まま渡すと 2 つの引数に割れて起動に失敗する。 8.3 形式の短い名前
  ///   (`C:\PROGRA~1\nodejs\node.exe`) は空白も日本語も含まないので、 その
  ///   形に直して渡す。 直せない時は元のまま返す (今までどおりの挙動)。
  static String ptySafePath(String path) {
    if (path.isEmpty || !Platform.isWindows) return path;
    if (isAscii(path) && !path.contains(' ')) return path;
    final src = path.toNativeUtf16();
    final buf = calloc<ffi.Uint16>(1024).cast<Utf16>();
    try {
      final n = w32.GetShortPathName(src, buf, 1024);
      if (n == 0 || n >= 1024) return path;
      final short = buf.toDartString();
      if (short.isEmpty || short.contains(' ') || !isAscii(short)) return path;
      return short;
    } catch (e) {
      debugPrint('ptySafePath failed: $e');
      return path;
    } finally {
      calloc.free(src);
      calloc.free(buf);
    }
  }

  /// 管理者として別窓のターミナルを開く (= ユーザー要望: 右クリックで
  /// 管理者権限)。
  ///
  /// ★ アプリの中の端末には出せない。 昇格は「別のプロセスとして起こす」
  ///   ことでしか得られず (UAC)、 昇格した子は権限の壁でこちらの擬似端末に
  ///   繋げられないため。 なので管理者の時だけ OS の窓を開く。
  /// ★ 隠した PowerShell は撃たない。 `ShellExecute` の runas をアプリの中
  ///   から直に呼ぶ (= セキュリティソフトに「黙ってシェルを起こした」 と
  ///   見られないため)。
  static bool openAdminTerminal(String workingDir) {
    if (!Platform.isWindows) return false;
    final op = 'runas'.toNativeUtf16();
    final file = systemShell().toNativeUtf16();
    final dir = workingDir.toNativeUtf16();
    try {
      final r = w32.ShellExecute(
          0, op, file, ffi.nullptr, dir, 1 /* SW_SHOWNORMAL */);
      // 32 以下は失敗 (利用者が UAC で「いいえ」 を押した時も含む)。
      return r > 32;
    } catch (e) {
      debugPrint('openAdminTerminal failed: $e');
      return false;
    } finally {
      calloc.free(op);
      calloc.free(file);
      calloc.free(dir);
    }
  }

  // ── 画面の AI 機能を PC 内の CLI にやらせる ────────────────────────────
  //
  //   (= ユーザー要望: pptx などのファイル編集や自動化の AI にも、
  //    PC に入れた AI を使えるように)
  //
  //   対話用の擬似端末とは別に、 **1 回聞いて 1 回答えてもらう**だけの
  //   呼び方がどの CLI にもある。 指示は引数ではなく標準入力から渡す
  //   (引数だと引用符や空白で壊れるため)。
  static const Duration _kPromptTimeout = Duration(minutes: 5);

  /// 1 回聞く相手 (入っていてログイン済みの物を、 この順で選ぶ)。
  static Future<AgentCliFound?> pickForPrompt() async {
    if (!supported) return null;
    final found = await findAll();
    for (final k in const [
      AgentCliKind.claude,
      AgentCliKind.codex,
    ]) {
      for (final f in found) {
        if (f.spec.kind != k) continue;
        // ★ .ps1 はそのまま起こせないので選ばない。
        final exe = (f.exePath ?? '').toLowerCase();
        if (exe.endsWith('.ps1')) continue;
        if (f.installed && f.loggedInHint == true) {
          lastPickKind = f.spec.kind;
          return f;
        }
      }
    }
    return null;
  }

  /// 1 回聞き用の小さな作業フォルダー (毎回きれいな場所で動かすため)。
  /// [allowFiles] が true の時は「ファイルを作るな」 の一行を出さない。
  ///
  /// ★ = ユーザー報告「codex から txt ファイル等を生成することができない」。
  ///   ここで書く覚書 (AGENTS.md / CLAUDE.md / GEMINI.md) は、 CLI が作業
  ///   フォルダーから**必ず読む**。 そこに「ファイルを作らない」 と書いて
  ///   あったので、 画面の AI から「txt を作って」 と頼んでも、 CLI 側は
  ///   最初から作らない前提で答えていた (アプリの指示と真っ向から矛盾して
  ///   いた)。 純粋な問い合わせ (要約・分類など) では今までどおり禁じ、
  ///   道具を使わせる会話では許す。
  static Future<String?> _promptWorkingDir(String guide,
      {bool allowFiles = false}) async {
    try {
      final sup = await getApplicationSupportDirectory();
      final sep = Platform.pathSeparator;
      final dir = Directory('${sup.path}${sep}agent_cli${sep}oneshot');
      if (!await dir.exists()) await dir.create(recursive: true);
      final body = StringBuffer()
        ..writeln('# 1 回だけの問い合わせ')
        ..writeln();
      if (guide.trim().isNotEmpty) {
        body
          ..writeln(guide.trim())
          ..writeln();
      }
      body.writeln('- 聞かれた事だけに答える。 前置き・復唱・言い訳は書かない。');
      if (allowFiles) {
        body
          ..writeln('- 頼まれたファイルは作ってよい (この作業フォルダーの中)。')
          ..writeln('- アプリの道具 (MCP) が使える時は、 そちらを優先する。');
      } else {
        body.writeln('- ファイルを作ったり書き換えたりしない。');
      }
      body.writeln('- 形式 (JSON など) を指定されたら、 それだけを返す。');
      // ★ 中身が前と同じなら書かない (= ユーザー要望: API より遅すぎる)。
      //   1 回聞くたびに 3 つのファイルを毎回書き直していた。
      final text = body.toString();
      if (text != _lastOneshotGuide) {
        _lastOneshotGuide = text;
        for (final name in const ['CLAUDE.md', 'AGENTS.md', 'GEMINI.md']) {
          try {
            await File('${dir.path}$sep$name')
                .writeAsString(text, flush: true);
          } catch (_) {}
        }
      }
      return dir.path;
    } catch (e) {
      debugPrint('_promptWorkingDir failed: $e');
      return null;
    }
  }

  /// 1 回聞く相手の名前 (「PC内AI (Claude Code)」 の括弧の中)。
  static Future<String?> preferredLabel() async =>
      (await pickForPrompt())?.spec.label;

  /// 直前に書いた 1 回聞き用の覚書 (同じなら書き直さない)。
  static String _lastOneshotGuide = '';

  /// 直前の失敗の理由 (黙って API に落とさず、 画面に出すため)。
  static String lastPromptError = '';

  /// 問い合わせの通し番号 (一時ファイルの名前をぶつけないため)。
  static int _promptSeq = 0;

  /// codex が `--output-last-message` を知らない版だった (= 一度でも
  /// 「知らない引数」 で落ちた) か。 落ちたら以後は付けない。
  static bool _codexNoLastMessage = false;

  /// 直前に実際に使われたモデル (例 `claude-opus-5[1m]`)。
  static String lastModel = '';

  /// 直前に使ったトークン (= ユーザー要望: 消費量を出す)。
  static int lastInputTokens = 0;
  static int lastOutputTokens = 0;

  /// 選べるモデル (= ユーザー要望: この画面でモデルを切り替えたい)。
  ///
  /// ★ 空文字は「CLI の既定に任せる」。 どの CLI も `--model` で指定できる。
  static List<({String id, String label})> modelChoices(AgentCliKind kind) {
    switch (kind) {
      case AgentCliKind.claude:
        return const [
          (id: '', label: 'CLI の設定のまま'),
          (id: 'opus', label: 'Opus'),
          (id: 'sonnet', label: 'Sonnet'),
          (id: 'haiku', label: 'Haiku'),
        ];
      case AgentCliKind.codex:
        return const [
          (id: '', label: 'CLI の設定のまま'),
          (id: 'gpt-5-codex', label: 'GPT-5 Codex'),
          (id: 'o4-mini', label: 'o4-mini'),
        ];
      case AgentCliKind.gemini:
        return const [
          (id: '', label: 'CLI の設定のまま'),
          (id: 'gemini-2.5-pro', label: '2.5 Pro'),
          (id: 'gemini-2.5-flash', label: '2.5 Flash'),
        ];
    }
  }

  /// 選んだモデル (prefs の控えを画面から入れてもらう)。
  static String chosenModel = '';

  /// 考える深さ ('low' / 'medium' / 'high'、 空 = CLI の設定のまま)。
  ///
  /// ★ = ユーザー要望「API で呼んだ時に比べて CLI だと資料作成が遅すぎる」。
  ///   1 回聞くだけの問い合わせに深く考えさせても待ち時間が伸びるだけなので、
  ///   画面で選んだ深さをそのまま渡す。
  static String chosenReasoning = '';

  /// 直前に選ばれた CLI の種類 (モデルの候補を出すのに使う)。
  static AgentCliKind? lastPickKind;

  /// npm が使えるか (= Node.js が入っているか) の控え。
  /// null = まだ調べていない。
  static bool? npmAvailable;

  static Future<bool> checkNpm() async {
    final r = await findNpm();
    npmAvailable = (r ?? '').isNotEmpty;
    return npmAvailable!;
  }

  /// 札に出す形に整える (`claude-opus-5[1m]` → `Opus 5`)。
  static String prettyModel(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    s = s.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    s = s.replaceFirst(RegExp(r'^(claude|models/|gemini-|gpt-)'), '');
    s = s.replaceAll(RegExp(r'-\d{8}$'), '');
    s = s.replaceAll(RegExp(r'^[-_]+'), '');
    // 4-5 → 4.5 (版の数字はつなげて読ませる)。
    s = s.replaceAllMapped(
        RegExp(r'(\d)-(\d)'), (m) => '${m[1]}.${m[2]}');
    final parts = s.split(RegExp(r'[-_]')).where((e) => e.isNotEmpty).toList();
    return parts
        .map((w) => w.length > 1 && RegExp(r'^[a-z]').hasMatch(w)
            ? w[0].toUpperCase() + w.substring(1)
            : w)
        .join(' ');
  }

  /// 1 回分の問い合わせ。 使える CLI が無い / 失敗した時は null。
  ///
  /// [allowFiles] を true にすると、 作業フォルダーの中でファイルを作る事を
  /// 許す (= ユーザー報告: codex から txt などを作れない)。 覚書の文面と
  /// codex の砂箱 (sandbox) の両方が効く。
  static Future<String?> runPrompt(String prompt,
      {Duration? timeout,
      String? workingDir,
      String guide = '',
      bool allowFiles = false,
      Map<String, String> extraEnvironment = const <String, String>{}}) async {
    lastPromptError = '';
    if (!supported || prompt.trim().isEmpty) return null;
    // ★ 何も指定が無い時は、 専用の小さなフォルダーで動かす。
    //   指定しないとアプリの置き場 (実行ファイルの隣) で動いてしまい、
    //   そこにある設定を読みに行ったり、 余計なファイルを見に行ったりする。
    workingDir ??= await _promptWorkingDir(guide, allowFiles: allowFiles);
    final pick = await pickForPrompt();
    // ★ 起こすのは薄皮 (.cmd) ではなく、 割り出した本体。 薄皮を
    //   `runInShell` で起こすと裏で `cmd.exe` が立ち、 頼むたびに
    //   セキュリティソフトに咎められていた (= ユーザー報告)。
    final exe = pick?.runExe;
    if (exe == null || exe.isEmpty) {
      lastPromptError = '使える CLI が見つかりません (入れてログインしてください)';
      return null;
    }
    // ★ Claude Code は JSON で受け取る。 答えが `result` に入るので、
    //   設定の警告などが混ざらないうえ、 使ったモデル名まで分かる
    //   (= ユーザー要望: 何のモデルか明記して欲しい)。
    final asJson = pick!.spec.kind == AgentCliKind.claude;
    // codex の返事だけを受け取るための一時ファイル (下の説明を参照)。
    //
    // ★ 名前は 1 回ごとに変える。 作業フォルダーは 1 つしかなく、 問い合わせ
    //   は同時に走り得る (会話の輪が裏で回っている間に、 別の AI 機能を
    //   押せる) ので、 固定名だと互いの返事を踏み合う (= 点検で判明)。
    var lastMessageFile = '';
    if (pick.spec.kind == AgentCliKind.codex &&
        !_codexNoLastMessage &&
        (workingDir ?? '').isNotEmpty) {
      _promptSeq++;
      lastMessageFile = '$workingDir${Platform.pathSeparator}'
          '.last_message_${pid}_$_promptSeq.txt';
      try {
        final f = File(lastMessageFile);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        lastMessageFile = '';
      }
    }
    // 選んだモデルがあれば指定する (空なら CLI の既定に任せる)。
    final m = chosenModel.trim();
    final args = <String>[
      ...pick.launchPrefixArgs,
      ...switch (pick.spec.kind) {
        AgentCliKind.claude => <String>[
            '-p',
            '--output-format',
            'json',
            // ★ 1 回聞くだけの問い合わせに、 利用者が登録している
            //   MCP サーバーをいちいち繋ぎに行かせない
            //   (= ユーザー要望: API より遅すぎる)。 遠くの
            //   サーバーが 1 つでもあると、 毎回その分だけ起動が伸びる。
            '--strict-mcp-config',
            if (m.isNotEmpty) ...['--model', m],
          ],
        AgentCliKind.codex => <String>[
            'exec',
            // ★ codex は既定だと「読むだけ」 の状態で動くので、 頼まれても
            //   ファイルを 1 つも作れない (= ユーザー報告)。 作業フォルダー
            //   の中だけ書けるようにする。 外は今までどおり書けない。
            // ★ ここ (1 回聞くだけの道) では**縛りを外さない**。 端末と違って
            //   1 件ずつ人に尋ねる作りではないので、 外すと誰も見ていない所で
            //   何でも走らせられることになる。 [codexRestrictedRun] を切って
            //   いても、 こちらは作業フォルダーの中だけに留める。
            if (allowFiles) ...['--sandbox', 'workspace-write'],
            // ★ git の管理下でないと動かない既定があるので外す。 アプリが
            //   用意する作業フォルダーは git ではない。
            '--skip-git-repo-check',
            // ★ 1 回聞くだけの問い合わせでは、 毎回付いて回る重い物を
            //   外す (= ユーザー要望: API に比べて CLI だと資料作成が
            //   遅すぎる)。
            //   ・notify … 1 手ごとに外のプログラムを起こす知らせ。
            //     利用者の設定に PowerShell が入っていることが多く、
            //     遅いうえにセキュリティソフトにも咎められる。
            //   ・mcp_servers … 起動のたびに遠くのサーバーへ繋ぎに行く。
            //     1 問 1 答に道具は要らない。
            //   ★ モデルや契約の筋 (service_tier) は**残す**ので、
            //     `--ignore-user-config` で丸ごと捨てることはしない。
            '-c',
            'notify=[]',
            '-c',
            'mcp_servers={}',
            if (chosenReasoning.isNotEmpty) ...[
              '-c',
              'model_reasoning_effort="$chosenReasoning"',
            ],
            // ★ 返事だけを別のファイルへ書かせる (= ユーザー報告: PC 内の
            //   codex に自動操作のフロー作成を頼んでも、 何も作られない
            //   まま終わる)。 `codex exec` は標準出力に **頼んだ文まで
            //   そのまま書き写す**ので、 呼び出し側が「最初の { から最後の
            //   } まで」 を切り出すと、 書き写された指示ごと拾ってしまい
            //   JSON として読めずに失敗していた。 ここで本文だけ受け取る。
            if (lastMessageFile.isNotEmpty) ...[
              '--output-last-message',
              lastMessageFile,
            ],
            if (m.isNotEmpty) ...['-m', m],
            '-',
          ],
        AgentCliKind.gemini => <String>[
            '-p',
            if (m.isNotEmpty) ...['-m', m],
          ],
      },
    ];
    try {
      final proc = await Process.start(
        exe,
        args,
        workingDirectory: workingDir,
        environment: extraEnvironment.isEmpty
            ? null
            : {...Platform.environment, ...extraEnvironment},
        // 薄皮の中身を割り出せなかった時だけ、 今までどおりシェル経由。
        // 引数は固定文字だけなので、 これで危ない物が混ざることはない。
        runInShell: pick.needsShell,
      );
      proc.stdin.write(prompt);
      await proc.stdin.flush();
      await proc.stdin.close();
      final out = StringBuffer();
      final err = StringBuffer();
      final subs = [
        proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(out.write),
        proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(err.write),
      ];
      int code;
      try {
        code = await proc.exitCode.timeout(timeout ?? _kPromptTimeout);
      } on TimeoutException {
        proc.kill();
        for (final sub in subs) {
          await sub.cancel();
        }
        lastPromptError = '時間切れ';
        debugPrint('runPrompt timed out');
        return null;
      }
      for (final sub in subs) {
        await sub.cancel();
      }
      var text = out.toString().trim();
      // ★ codex は返事だけを別ファイルへ書いてくれる。 標準出力には
      //   飾りの帯・頼んだ文の写し・考えている途中の独り言・使ったトークン
      //   まで全部混ざるので、 そちらは当てにしない (= ユーザー報告: PC 内の
      //   codex にフロー作成を頼んでも何も作られないまま終わる)。
      //   古い版でこの指定が効かなかった時のために、 空なら今までどおり。
      if (lastMessageFile.isNotEmpty) {
        try {
          final f = File(lastMessageFile);
          if (f.existsSync()) {
            final only = f.readAsStringSync().trim();
            if (only.isNotEmpty) text = only;
            try {
              f.deleteSync();
            } catch (_) {}
          }
        } catch (e) {
          debugPrint('codex last-message read failed: $e');
        }
        // ★ 古い版はこの指定を知らず、 「知らない引数」 で即座に落ちる
        //   (黙って無視はしてくれない)。 一度そうなったら覚えておいて、
        //   付けずにもう一度だけ試す (= 点検で判明: そのままだと
        //   「返事がありませんでした」 で固定になる)。
        if (text.isEmpty &&
            err.toString().toLowerCase().contains('unexpected argument')) {
          _codexNoLastMessage = true;
          debugPrint('codex has no --output-last-message; retrying without it');
          return runPrompt(prompt,
              timeout: timeout,
              workingDir: workingDir,
              guide: guide,
              allowFiles: allowFiles,
              extraEnvironment: extraEnvironment);
        }
      }
      if (asJson && text.startsWith('{')) {
        try {
          final j = jsonDecode(text);
          if (j is Map) {
            // 使ったモデルを控える (札に出す)。 小さな下働きの分は除く。
            final mu = j['modelUsage'];
            if (mu is Map && mu.isNotEmpty) {
              // ★ haiku は CLI 自身の下働き用なので、 他があればそちらを
              //   本命とする (= 札に出すのは実際に答えたモデル)。
              final keys = mu.keys.map((e) => '$e').toList();
              final main = keys.where((k) => !k.contains('haiku')).toList();
              final pool = main.isEmpty ? keys : main;
              var best = pool.first;
              num bestOut = -1;
              for (final k in pool) {
                final v = mu[k];
                final o = (v is Map ? (v['outputTokens'] as num?) : null) ?? 0;
                if (o > bestOut) {
                  bestOut = o;
                  best = k;
                }
              }
              lastModel = best;
            }
            // 使ったトークン (入力は cache 込みで数える)。
            lastInputTokens = 0;
            lastOutputTokens = 0;
            final u = j['usage'];
            if (u is Map) {
              int v(String k) => (u[k] as num?)?.toInt() ?? 0;
              lastInputTokens = v('input_tokens') +
                  v('cache_creation_input_tokens') +
                  v('cache_read_input_tokens');
              lastOutputTokens = v('output_tokens');
            }
            if (j['is_error'] == true) {
              lastPromptError = '${j['result'] ?? j['subtype'] ?? 'エラー'}';
              return null;
            }
            text = '${j['result'] ?? ''}'.trim();
          }
        } catch (_) {
          // JSON で来なかった時は、 そのままの文字として扱う。
        }
      }
      if (text.isEmpty) {
        final e = err.toString().trim();
        lastPromptError = e.isEmpty
            ? '返事がありませんでした (コード $code)'
            : e.split('\n').last.trim();
        debugPrint('runPrompt failed ($code): $e');
        return null;
      }
      return text;
    } catch (e) {
      lastPromptError = '$e';
      debugPrint('runPrompt failed: $e');
      return null;
    }
  }

  /// CLI に渡す作業フォルダー。
  ///
  /// ★ 利用者のプロジェクトや実行ファイルの隣は**絶対に渡さない**。
  ///   CLI はファイルを書き換えられるので、既定の作業場所は狭くしておく。
  ///   (CLI 側の設定で許可を広げられている場合まではアプリから防げない)
  static Future<String> workingDirectory(String appSupportPath) async {
    final dir = Directory(
        '$appSupportPath${Platform.pathSeparator}agent_cli');
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (_) {}
    return dir.path;
  }

  /// 作業フォルダーへ置く覚書を書く (= ユーザー要望: AGENTS.md / CLAUDE.md を
  /// フォルダーの中に置いて読ませたい)。
  ///
  /// Claude Code は CLAUDE.md、 Codex は AGENTS.md、 Gemini CLI は GEMINI.md を
  /// 作業フォルダーから読む。 同じ内容を 3 つ置いておけばどれでも効く。
  ///
  /// ★ **覚書は短く保つ** (= ユーザー要望: 性能を落とさずトークンを抑える)。
  ///   覚書は毎回まるごと前置きに入るので、 ここへ全部書くと、 何を頼んでも
  ///   その分の費用が乗る。 アプリの詳しい説明書 (2 万字超) は
  ///   `docs/HisatorNotebook.md` へ別に置き、 覚書からは「要る時だけ読め」 と
  ///   指しておく。
  static Future<void> writeGuide(
    String workingDir, {
    required String instruction,
    String appGuide = '',
  }) async {
    final sep = Platform.pathSeparator;
    final lang = instruction.trim();
    final body = StringBuffer()
      ..writeln('# この作業フォルダーの決まり')
      ..writeln();
    if (lang.isNotEmpty) {
      body
        ..writeln(lang)
        ..writeln();
    }
    body
      ..writeln('## むだな費用を出さない (答えの質は落とさない)')
      ..writeln()
      ..writeln('- 結論から書く。 前置き・復唱・謝辞・作業の実況は書かない。')
      ..writeln('- 同じ物を読み直さない。 要る範囲だけ読む。')
      ..writeln('- まとめて渡せる道具は 1 回にまとめる (1 件ずつ呼ばない)。')
      ..writeln('- 長い出力をそのまま貼らない。 要る行だけ引く。')
      ..writeln('- 説明書は**要る時だけ**開く。 先に全部読まない。')
      ..writeln('- 終わったら、 やった事を数行で。 水増しした表や箇条書きにしない。')
      ..writeln();
    if (appGuide.trim().isNotEmpty) {
      body
        ..writeln('## このアプリ (HisatorNotebook) を操作できる')
        ..writeln()
        ..writeln('`hisator` という MCP サーバーをこのフォルダーに登録してある。')
        ..writeln('ページや要素の作成・編集は、 ファイルを直接いじらずこの道具で行う。')
        ..writeln()
        ..writeln('- 道具の使い方に迷ったら `list_app_docs` → `read_app_doc`。')
        ..writeln('- アプリ全体の作りは `docs/HisatorNotebook.md`。')
        ..writeln('  長いので、 必要になった所だけ読む事。')
        ..writeln();
    }
    body
      ..writeln('## このフォルダーについて')
      ..writeln()
      ..writeln('アプリが CLI のために用意した作業場所で、 利用者の資料は入っていない。')
      // ★ = ユーザー報告「codex から txt ファイル等を生成することが
      //   できない」。 「勝手に書き換えるな」 しか書いていなかったので、
      //   頼まれたファイルまで作らずに終わっていた。 ここでは作ってよい、
      //   と先に言っておく (外は今までどおり触らせない)。
      ..writeln('**頼まれたファイル (txt / md など) は、 このフォルダーの中に作ってよい。**')
      // ★ = ユーザー報告「新規作成したファイルが docs フォルダーに入る」。
      //   `docs/` はアプリの説明書を置くだけの場所なので、 作った物を
      //   そこへ入れられると一覧に出てこない。 置き場をはっきり書く。
      ..writeln('置き場は**このフォルダーの直下**。 `docs/` の中には作らない')
      ..writeln('(`docs/` はアプリの説明書だけを置く所)。 下位フォルダーも作らない。')
      ..writeln('ここ以外のフォルダーを勝手に書き換えない。')
      // ★ = ユーザー要望「作成するファイルのパスを明示しない場合等を
      //   除き、 今開いているフォルダー外に新規ファイルやフォルダーを
      //   作成しないで欲しい」。 上の行だけだと「書き換えない」 としか
      //   読めず、 外へ**新しく**作るのは良いと取られかねない。
      ..writeln('置き場を**はっきり指示された時以外**は、 このフォルダーの外に')
      ..writeln('新しいファイルやフォルダーを作らない (デスクトップや書類の中も含む)。');
    final text = body.toString();
    for (final name in const ['CLAUDE.md', 'AGENTS.md', 'GEMINI.md']) {
      try {
        await File('$workingDir$sep$name').writeAsString(text, flush: true);
      } catch (e) {
        debugPrint('writeGuide($name) failed: $e');
      }
    }
    // 詳しい説明書は別置き (読むかどうかは CLI に任せる)。
    if (appGuide.trim().isNotEmpty) {
      try {
        final dir = Directory('$workingDir${sep}docs');
        if (!await dir.exists()) await dir.create(recursive: true);
        await File('${dir.path}${sep}HisatorNotebook.md')
            .writeAsString(appGuide, flush: true);
      } catch (e) {
        debugPrint('writeGuide(docs) failed: $e');
      }
    }
  }

  /// Claude Code に、 このフォルダーの MCP サーバーを最初から許しておく。
  ///
  /// ★ 一度「いいえ」 と答えると `.claude/settings.local.json` の
  ///   `disabledMcpjsonServers` に残り、 以後ずっと道具が見えなくなる
  ///   (= 実際に起きた: CLI が「無効化されているので直接 HTTP を叩いた」 と
  ///   言ってきた)。 起動のたびにここで許可へ直す。
  static Future<void> allowMcpServer(
    String workingDir, {
    String name = 'hisator',
  }) async {
    final sep = Platform.pathSeparator;
    try {
      final dir = Directory('$workingDir$sep.claude');
      if (!await dir.exists()) await dir.create(recursive: true);
      final f = File('${dir.path}${sep}settings.local.json');
      Map<String, dynamic> cfg = {};
      if (await f.exists()) {
        try {
          final raw = jsonDecode(await f.readAsString());
          if (raw is Map<String, dynamic>) cfg = raw;
        } catch (_) {}
      }
      List<String> listOf(String key) {
        final v = cfg[key];
        return v is List ? v.map((e) => '$e').toList() : <String>[];
      }
      final enabled = listOf('enabledMcpjsonServers');
      final disabled = listOf('disabledMcpjsonServers');
      disabled.remove(name);
      if (!enabled.contains(name)) enabled.add(name);
      cfg['enabledMcpjsonServers'] = enabled;
      cfg['disabledMcpjsonServers'] = disabled;
      await f.writeAsString(
          const JsonEncoder.withIndent('  ').convert(cfg),
          flush: true);
    } catch (e) {
      debugPrint('allowMcpServer failed: $e');
    }
  }

  /// このアプリの MCP サーバーだけを登録した設定を作業フォルダーへ置く。
  ///
  /// こうしておくと、CLI から「ページを作って」と頼めばアプリが動く
  /// (= 逆方向は既に出来ているので、その口をそのまま使う)。
  /// 合言葉が平文で入るので、作業フォルダーの外には置かないこと。
  static Future<void> writeMcpConfig(
    String workingDir, {
    required String url,
    required String token,
  }) async {
    if (url.isEmpty) return;
    final plain = url.contains('?') ? url.split('?').first : url;
    final cfg = <String, dynamic>{
      'mcpServers': {
        'hisator': {
          'type': 'http',
          'url': plain,
          'headers': {'Authorization': 'Bearer $token'},
        }
      }
    };
    try {
      final f = File('$workingDir${Platform.pathSeparator}.mcp.json');
      await f.writeAsString(
          const JsonEncoder.withIndent('  ').convert(cfg),
          flush: true);
    } catch (e) {
      debugPrint('writeMcpConfig failed: $e');
    }
  }

  /// 起動時に渡す、 CLI ごとの追加の引数。
  ///
  /// ★ = ユーザー報告「codex から txt ファイル等を生成することができない」。
  ///   理由は 2 つあり、 どちらもここで解ける。
  ///
  ///   1. **砂箱 (sandbox)**。 codex は「信用していないフォルダー」 では
  ///      読むだけの状態で始まる。 アプリが用意する作業フォルダーは利用者の
  ///      `~/.codex/config.toml` の信用一覧に入っていないので、 頼んでも
  ///      ファイルを 1 つも作れなかった。 `--sandbox workspace-write` で
  ///      **この作業フォルダーの中だけ**書けるようにする。
  ///   2. **アプリの道具が見えない**。 `.mcp.json` は Claude Code の書式で、
  ///      codex は読まない (codex は `~/.codex/config.toml` の
  ///      `[mcp_servers.*]` を見る)。 利用者の設定を書き換えるのは避けたい
  ///      ので、 起動のたびに `-c` で上書きして渡す。 合言葉は URL の
  ///      `?token=` に入っているので、 ヘッダーは要らない。
  /// 合言葉を渡す時に使う環境変数の名前。
  ///
  /// ★ 合言葉を**引数に書かない**ため (= 点検で判明: 起動時に端末へ
  ///   `> codex -c mcp_servers.hisator.url="…?token=◯◯"` と、 そのまま
  ///   書き出していた。 画面に出る = 覗かれる・控えに残る)。 codex は
  ///   `bearer_token_env_var` で「この環境変数から読め」 と指定できる。
  static const String kMcpTokenEnvVar = 'HISATOR_MCP_TOKEN';

  // ─── どこまで任せるか ───────────────────────────────────────────────
  //
  //   = ユーザー要望「何故、 1 件 1 件確認を取らないと動かないのか。
  //     VSCode の codex のように承認なしに任せられるようにしてほしい。
  //     確認を取られない + 動作がストップしない仕様に」。
  //
  //   以前は必ず `--ask-for-approval on-request` を付けていた。 引数は設定
  //   ファイルより強いので、 利用者が自分の CLI 側に「たずねずに進めてよい」
  //   と書いても**効かなかった**。 選べるようにする。
  //
  //   'ask'  … 毎回たずねる
  //   'auto' … たずねない。 書き換えるのは作業フォルダーの中だけ
  //   'full' … たずねない。 場所の縛りも無し (VSCode の codex の
  //            「フルアクセス」 と同じ)
  //
  //   ★ 'full' の時だけ、 codex は権限を落とすための手先
  //     (codex-command-….exe) を起こさない。 あの手先は署名が無く、 版ごとに
  //     名前が変わるのでセキュリティソフトに毎回咎められる (= ユーザー報告)。
  //     縛りを外す = 手先が要らない、 という関係。
  //
  //   ★ この設定が効くのは**端末 (人が画面を見ている所)** だけ。 画面の AI が
  //     裏で 1 回だけ問い合わせる道 ([runPrompt]) は、 誰も見ていないので
  //     この設定に関わらず作業フォルダーの中に留める。
  static const List<String> autonomyLevels = ['ask', 'auto', 'full'];

  /// 既定は 'auto'。
  ///
  /// ★ 「1 件ずつ確認されると手が止まる」 という困りごとはこれで解ける
  ///   (たずねずに進む)。 そのうえで、 書き換えられるのは作業フォルダーの
  ///   中だけなので、 うっかり他所を壊す事にはならない。
  ///   場所の縛りまで外したい人は、 自分で 'full' を選ぶ。
  static String autonomy = 'auto';

  static bool get _noAsk => autonomy != 'ask';
  static bool get _noLimit => autonomy == 'full';

  static List<String> extraLaunchArgs(
    AgentCliKind kind, {
    String mcpUrl = '',
  }) {
    switch (kind) {
      case AgentCliKind.codex:
        // 合言葉はクエリに入っているので、 引数には**外した**道筋を渡す。
        final plain =
            mcpUrl.contains('?') ? mcpUrl.split('?').first : mcpUrl;
        return <String>[
          // 任せ方 (上の [autonomy] の説明)。
          '--sandbox',
          _noLimit ? 'danger-full-access' : 'workspace-write',
          '--ask-for-approval',
          _noAsk ? 'never' : 'on-request',
          if (plain.isNotEmpty) ...[
            '-c',
            'mcp_servers.hisator.url="$plain"',
            '-c',
            'mcp_servers.hisator.bearer_token_env_var="$kMcpTokenEnvVar"',
            // ★ = ユーザー報告「Hisator MCP の読み取りが承認ポリシーで
            //   拒否されました。 アプリ側で MCP 操作を許可に変更してから
            //   再度お知らせください」。
            //
            //   アプリ側の設定の話ではない (端末を開く時に 3 つとも強制で
            //   ON にしてある)。 codex の決まりで、
            //     ・道具に「読むだけ」 の注記が無ければ「壊す道具」 と見なす
            //     ・見なされた道具は承認を求める
            //     ・`--ask-for-approval never` の時、 その承認は即「否」
            //   となり、 **読み取りまで全部**拒否されていた。
            //   砂箱が `danger-full-access` の時だけは素通りするので、
            //   b392 で既定を「全部任せる」 から「作業フォルダー内」 へ
            //   変えた時に表に出た (= 社用 PC で動くのは、 そちらが
            //   まだ「全部任せる」 のため)。
            //
            //   この 1 行で「この待ち受けの道具は聞かずに通してよい」 と
            //   伝える。 砂箱は緩めないので、 ファイルの守りはそのまま。
            //   自分で 127.0.0.1 に立てた、 合言葉付きの、 自分で書いた
            //   道具だけが対象。
            //   「確認しながら」 を選んだ人には付けない (聞かれたいので)。
            if (_noAsk) ...[
              '-c',
              'mcp_servers.hisator.default_tools_approval_mode="approve"',
            ],
          ],
        ];
      case AgentCliKind.claude:
        // Claude Code は許可の出し方を `--permission-mode` で選ぶ。
        //   acceptEdits … 書き換えは通す (その他は都度たずねる)
        //   bypassPermissions … たずねない
        return <String>[
          if (_noLimit)
            ...['--permission-mode', 'bypassPermissions']
          else if (_noAsk)
            ...['--permission-mode', 'acceptEdits'],
        ];
      case AgentCliKind.gemini:
        // Gemini CLI は `--approval-mode`。
        return <String>[
          if (_noLimit)
            ...['--approval-mode', 'yolo']
          else if (_noAsk)
            ...['--approval-mode', 'auto_edit'],
        ];
    }
  }

  /// ブラウザを使わないログインの引数 (無ければ空)。
  ///
  /// ★ = ユーザー報告「ログインしようとするとセキュリティソフトにブロック
  ///   される」。 どの CLI も既定のログインは「ブラウザを開く + 自分で
  ///   127.0.0.1 の待ち受けを立てて戻りを受ける」 形で、 その待ち受けが
  ///   止められる。 codex には合言葉を画面に出すだけの方式があるので、
  ///   そちらを選べるようにする (待ち受けを立てないので止められない)。
  ///   Gemini は API キーを環境変数で渡す方 ([MindMapProvider.cliAiEnvironment])
  ///   で回避する。
  static List<String> deviceLoginArgs(AgentCliKind kind) {
    switch (kind) {
      case AgentCliKind.codex:
        return const <String>['login', '--device-auth'];
      case AgentCliKind.claude:
      case AgentCliKind.gemini:
        return const <String>[];
    }
  }

  /// ブラウザを使わないログインを出せる相手か。
  static bool supportsDeviceLogin(AgentCliKind kind) =>
      deviceLoginArgs(kind).isNotEmpty;
}
