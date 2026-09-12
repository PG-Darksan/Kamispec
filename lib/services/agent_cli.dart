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
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart' as w32;

import '../utils/build_flags.dart';

/// 相手にする CLI。
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
    AgentCliSpec(
      kind: AgentCliKind.gemini,
      label: 'Gemini CLI',
      exeNames: ['gemini.cmd', 'gemini.exe', 'gemini.ps1', 'gemini'],
      installHint: 'npm i -g @google/gemini-cli',
    ),
  ];

  static AgentCliSpec of(AgentCliKind k) =>
      all.firstWhere((e) => e.kind == k);
}

/// 見つかった CLI の情報。
class AgentCliFound {
  const AgentCliFound({required this.spec, this.exePath, this.loggedInHint});

  final AgentCliSpec spec;

  /// 見つかった実行ファイルの絶対パス (null = 見つからない)。
  final String? exePath;

  /// ログインしていそうか (**目安**。設定ファイルの有無で見るだけなので、
  /// 期限切れでも true になる。最終判定は実際に動かした結果に任せる)。
  final bool? loggedInHint;

  bool get installed => (exePath ?? '').isNotEmpty;
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

  /// 調べ直す (入れた直後に押してもらう用)。
  static void forget() => _cache.clear();

  /// CLI を探す。
  ///
  /// 探し方は 3 段:
  ///   1. よくある置き場を直に見る (npm / bun / ローカル bin)
  ///   2. PATH の各所を総当たり
  ///   3. Windows は最後に `where` に聞く
  static Future<AgentCliFound> find(AgentCliKind kind) async {
    final hit = _cache[kind];
    if (hit != null) return hit;
    final spec = AgentCliSpec.of(kind);
    String? found;
    if (supported) {
      found = await _search(spec);
    }
    final res = AgentCliFound(
      spec: spec,
      exePath: found,
      loggedInHint: found == null ? null : await _loggedInHint(kind),
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
    for (final d in dirs) {
      final dir = d.trim();
      if (dir.isEmpty) continue;
      for (final name in spec.exeNames) {
        try {
          final f = File('$dir$sep$name');
          if (f.existsSync()) return f.path;
        } catch (_) {}
      }
    }
    // 最後の手段: OS に聞く。
    if (Platform.isWindows) {
      for (final name in spec.exeNames) {
        try {
          final r = await Process.run('where', [name],
              stdoutEncoding: utf8, stderrEncoding: utf8);
          if (r.exitCode == 0) {
            final first = '${r.stdout}'
                .split('\n')
                .map((e) => e.trim())
                .firstWhere((e) => e.isNotEmpty, orElse: () => '');
            if (first.isNotEmpty) return first;
          }
        } catch (_) {}
      }
    } else {
      for (final name in spec.exeNames) {
        try {
          final r = await Process.run('which', [name],
              stdoutEncoding: utf8, stderrEncoding: utf8);
          if (r.exitCode == 0) {
            final first = '${r.stdout}'.trim();
            if (first.isNotEmpty) return first;
          }
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
    return false;
  }

  /// npm を探す (「インストール」 ボタン用)。
  ///
  /// ★ 隠した PowerShell を撃つやり方は取らない。 画面の見える端末で
  ///   npm をそのまま動かす (= 何が起きているか利用者に見えるし、
  ///   セキュリティソフトに「黙ってシェルを起こした」 と見られない)。
  static Future<String?> findNpm() async {
    if (!supported) return null;
    const spec = AgentCliSpec(
      kind: AgentCliKind.claude,
      label: 'npm',
      exeNames: ['npm.cmd', 'npm.exe', 'npm'],
      installHint: '',
    );
    return _search(spec);
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
      ..writeln('ここ以外のフォルダーを勝手に書き換えない。');
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
}
