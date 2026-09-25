// lib/services/git_history.dart
//
// 開いたフォルダーの git のコミット履歴を読む小さな道具。
//
// ★ 隠し powershell / cmd は絶対に挟まない (= セキュリティソフトに撃たれて
//   アプリごと落ちる既知の問題)。 `Process.run` へ git の実行ファイルを
//   **直に** 渡し、 `runInShell` は付けない (既定の false のまま)。
// ★ 読むだけ。 枝を切り替える / 書き戻す命令 (checkout / reset / pull など)
//   は一切呼ばない。 利用者のリポジトリには触らない。
// ★ `GIT_OPTIONAL_LOCKS=0` を渡して、 別で開いている編集ソフトの邪魔を
//   しないようにする。 `environment` は親の環境に**足される**ので
//   (`includeParentEnvironment` の既定が true)、 PATH は残る。
// ★ 相対日時 (%ar) は git の都合で必ず英語になるので使わない。 日時は
//   `--date=format:` で数字に揃えて、 どの言語でも同じに見せる。
// ★ 起こし方は lib/services/ffmpeg_path.dart の findFfmpegExe() と同じ流儀
//   (PATH を試す → Windows の定番の置き場を見る)。

import 'dart:convert';
import 'dart:io';

/// コミット 1 件。
class GitCommit {
  GitCommit({
    required this.graph,
    required this.hash,
    required this.shortHash,
    required this.author,
    required this.dateText,
    required this.refs,
    required this.parents,
    required this.subject,
    List<String>? graphExtra,
  }) : graphExtra = graphExtra ?? <String>[];

  /// `git log --graph` が描いた枝の記号 (このコミットの行の分)。
  final String graph;

  /// このコミットの後ろに続く**記号だけの行** (枝の分かれ / 合流の線)。
  ///
  /// ★ ここを捨てると枝が繋がって見えなくなる。 `--graph` の出力は
  ///   「コミットの行」 と 「記号だけの行」 の 2 種類でできているので、
  ///   後者は直前のコミットに付けて持っておき、 同じ等幅の桝で下に
  ///   続けて描く。
  final List<String> graphExtra;

  /// 完全なコミット ID。
  final String hash;

  /// 短いコミット ID。
  final String shortHash;
  final String author;

  /// 作者日時 (YYYY-MM-DD HH:MM)。
  final String dateText;

  /// 枝 / 名札の名前 (無ければ空)。
  final List<String> refs;
  final List<String> parents;
  final String subject;

  /// 合流 (merge) のコミットか。
  bool get isMerge => parents.length >= 2;
}

/// 1 件のコミットで変わったファイル。
class GitFileChange {
  const GitFileChange(this.status, this.path);

  /// A (追加) / M (変更) / D (削除) / R100 (名前替え) など。
  final String status;
  final String path;
}

/// git を起こして履歴を読む。
class GitHistory {
  GitHistory._();

  /// 見つかった git の道筋 (見つからない時は覚えない = 後で入れたらすぐ使える)。
  static String? _exe;

  /// 「ここは git の管理下か」 の答えの控え。
  ///
  /// メニューを組む時に毎回ディスクを触らせないため。 控えを捨てる口は
  /// [forgetRepoMemo] で、 ドロワーの「ディスクの読み直し」 から呼んでいる。
  static final Map<String, bool> _repoMemo = <String, bool>{};

  /// 控えを捨てる (フォルダーを clone / git init した直後などに使う)。
  static void forgetRepoMemo() => _repoMemo.clear();

  /// git の実体を探す (PATH → Windows の定番の置き場)。 無ければ null。
  static Future<String?> findGitExe() async {
    final cached = _exe;
    if (cached != null) return cached;
    for (final c in <String>['git', 'git.exe']) {
      try {
        final r = await Process.run(c, <String>['--version'],
            stdoutEncoding: utf8, stderrEncoding: utf8);
        if (r.exitCode == 0) {
          _exe = c;
          return c;
        }
      } catch (_) {
        // PATH に無い。 下の定番の置き場へ落とす。
      }
    }
    if (Platform.isWindows) {
      final local = Platform.environment['LOCALAPPDATA'] ?? '';
      for (final p in <String>[
        r'C:\Program Files\Git\cmd\git.exe',
        r'C:\Program Files\Git\bin\git.exe',
        r'C:\Program Files (x86)\Git\cmd\git.exe',
        if (local.isNotEmpty) '$local\\Programs\\Git\\cmd\\git.exe',
      ]) {
        try {
          if (await File(p).exists()) {
            _exe = p;
            return p;
          }
        } catch (_) {}
      }
    }
    return null;
  }

  /// 上へ `.git` を辿って、 git の管理下らしいかを **同期で** 見る。
  ///
  /// メニューを組む時に使う (押してから初めて知らせるより親切)。 入れ子の
  /// 作業ツリー (worktree) では `.git` がファイルになるので、 両方見る。
  static bool looksLikeRepo(String dir) {
    final key = dir.trim();
    if (key.isEmpty) return false;
    final memo = _repoMemo[key];
    if (memo != null) return memo;
    var found = false;
    try {
      var d = Directory(key);
      for (var i = 0; i < 24; i++) {
        final g = '${d.path}${Platform.pathSeparator}.git';
        if (Directory(g).existsSync() || File(g).existsSync()) {
          found = true;
          break;
        }
        final up = d.parent;
        if (up.path == d.path) break;
        d = up;
      }
    } catch (_) {
      found = false;
    }
    _repoMemo[key] = found;
    return found;
  }

  /// git を 1 回起こす。 git が無い / 起こせない時は null。
  static Future<ProcessResult?> _run(String dir, List<String> args) async {
    final exe = await findGitExe();
    if (exe == null) return null;
    try {
      return await Process.run(
        exe,
        <String>[
          // 日本語のファイル名を \xxx へ化けさせない。
          '-c', 'core.quotepath=false',
          // 署名の確認で待たされないように。
          '-c', 'log.showSignature=false',
          '--no-pager',
          ...args,
        ],
        workingDirectory: dir,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: const <String, String>{'GIT_OPTIONAL_LOCKS': '0'},
      );
    } catch (_) {
      return null;
    }
  }

  /// この場所が属するリポジトリの根 (git の管理下でなければ null)。
  static Future<String?> repoRoot(String dir) async {
    final r = await _run(dir, <String>['rev-parse', '--show-toplevel']);
    if (r == null || r.exitCode != 0) return null;
    final s = ((r.stdout as String?) ?? '').trim();
    return s.isEmpty ? null : s;
  }

  /// いまの枝の名前 (切り離した HEAD なら短いコミット ID)。
  static Future<String> currentBranch(String dir) async {
    final r = await _run(dir, <String>['rev-parse', '--abbrev-ref', 'HEAD']);
    final s = (((r?.stdout) as String?) ?? '').trim();
    if (s.isNotEmpty && s != 'HEAD') return s;
    final h = await _run(dir, <String>['rev-parse', '--short', 'HEAD']);
    return (((h?.stdout) as String?) ?? '').trim();
  }

  /// 項目の区切りに使う制御文字 (コミットの表題には出てこない物を選ぶ)。
  static const String _recSep = '\u0001';
  static const String _fldSep = '\u001f';

  /// コミット履歴を新しい順に [count] 件だけ読む。
  ///
  /// git が無い時は null、 コミットが無い時は空を返す。
  /// [filePath] を渡すと、 その道筋を触ったコミットだけに絞る
  /// (= 「開いたフォルダーだけ」 の切り替え)。
  ///
  /// `--graph` を付けて枝の記号ごと受け取り、 記号の後ろに自分で決めた
  /// 区切り文字を挟んで項目を読み分ける。
  /// ★ 記号だけの行 (= 分かれ / 合流の線) は**捨てずに**直前のコミットへ
  ///   付ける。 捨てると枝が繋がって見えなくなる。
  /// ★ 「もっと読む」 は `--skip` ではなく [count] を増やして読み直す。
  ///   `--skip` だと枝の絵が途中から描き直されて嘘になるため。
  static Future<List<GitCommit>?> log(String dir,
      {int count = 200, String? filePath}) async {
    final fmt = '$_recSep%H$_fldSep%h$_fldSep%an$_fldSep%ad'
        '$_fldSep%D$_fldSep%P$_fldSep%s';
    final r = await _run(dir, <String>[
      'log',
      '--graph',
      '--date=format:%Y-%m-%d %H:%M',
      '--pretty=format:$fmt',
      '-n', '$count',
      if (filePath != null && filePath.trim().isNotEmpty) ...<String>[
        '--',
        filePath.trim(),
      ],
    ]);
    if (r == null) return null;
    // まだ 1 件も無い / HEAD が無い時も exitCode は 0 以外になる。
    if (r.exitCode != 0) return <GitCommit>[];
    final out = (r.stdout as String?) ?? '';
    final list = <GitCommit>[];
    for (final raw in out.split('\n')) {
      final line = raw.replaceAll('\r', '');
      final i = line.indexOf(_recSep);
      if (i < 0) {
        // 記号だけの行。 直前のコミットに付ける (多すぎる分は捨てる)。
        final g = line.trimRight();
        if (g.isEmpty || list.isEmpty) continue;
        if (list.last.graphExtra.length < 4) list.last.graphExtra.add(g);
        continue;
      }
      final f = line.substring(i + 1).split(_fldSep);
      if (f.length < 7) continue;
      list.add(GitCommit(
        graph: line.substring(0, i).trimRight(),
        hash: f[0],
        shortHash: f[1],
        author: f[2],
        dateText: f[3],
        refs: f[4]
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        parents:
            f[5].split(' ').where((e) => e.trim().isNotEmpty).toList(),
        subject: f[6],
      ));
    }
    return list;
  }

  /// 1 件のコミットで変わったファイル (押されるまで読まない)。
  ///
  /// ★ 合流コミットの差分は git 2.31 以降で `--first-parent` が
  ///   「第一親に対する差分」 を意味する。 それより古い git では合流の
  ///   ファイル一覧が空になる (落ちはしない)。
  static Future<List<GitFileChange>?> changedFiles(
      String dir, String hash) async {
    final r = await _run(dir, <String>[
      'show',
      '--name-status',
      '--first-parent',
      '--format=',
      hash,
    ]);
    if (r == null) return null;
    final list = <GitFileChange>[];
    for (final raw in ((r.stdout as String?) ?? '').split('\n')) {
      final line = raw.replaceAll('\r', '').trim();
      if (line.isEmpty) continue;
      final parts = line.split('\t');
      if (parts.length < 2) continue;
      // 名前替え (R100 old new) は新しい名前を見せる。
      list.add(GitFileChange(parts.first, parts.last));
    }
    return list;
  }

  /// 1 件のコミットの差分 (行数に上限を付ける = 巨大な物で固まらせない)。
  static Future<String?> patch(String dir, String hash,
      {String? filePath, int maxLines = 600}) async {
    final r = await _run(dir, <String>[
      'show',
      '--first-parent',
      '--format=',
      '--unified=3',
      hash,
      if (filePath != null && filePath.trim().isNotEmpty) ...<String>[
        '--',
        filePath.trim(),
      ],
    ]);
    if (r == null) return null;
    final lines = ((r.stdout as String?) ?? '').split('\n');
    if (lines.length <= maxLines) return lines.join('\n');
    return '${lines.take(maxLines).join('\n')}\n…';
  }
}
