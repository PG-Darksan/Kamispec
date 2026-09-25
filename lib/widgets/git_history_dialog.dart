// lib/widgets/git_history_dialog.dart
//
// 開いたフォルダーの git のコミット履歴を見る窓 (= ユーザー要望)。
//
// ## なぜ独立したファイルなのか
// lib/screens/mind_map_screen.dart は 29 万行あり、 ここに足すと後から
// 探せなくなる。 要るのは provider の言葉 (t) と services/git_history.dart
// だけの葉っぱなので、 widgets の下に出した。
//
// ## 出し方
// 画面の側 (_showGitHistory) が既存の _showNearDialogMain に包んで出すので、
// 押したメニューのすぐ近くに出る (= 既存の作法)。 外側が巻物なので、 中身は
// 高さを決め打ちした SizedBox にして、 その中で一覧を巻く
// (ListView を直に入れると高さが決まらず落ちる)。
//
// ## 枝の絵
// `git log --graph` の記号を等幅の桝でそのまま並べる。 列の幅は読み込んだ
// 記号の最長から決める (決め打ちだと 3 筋を超えた所で切れて、 枝の絵が
// 嘘になる)。 記号だけの行 (分かれ / 合流の線) も直前のコミットの下に
// 続けて描くので、 縦の線が繋がって見える。
//
// ## 段階的に読む
//   1. 開いた時   … git の有無 → リポジトリの根 → 枝の名前 → 履歴 200 件
//   2. 1 件押した … そのコミットで変わったファイルの一覧
//   3. ファイル押 … そのファイルの差分だけ (行数に上限あり)
// 「もっと読む」 は件数を増やして読み直す (枝の絵が途中で嘘にならないように)。
// リポジトリの根より下を開いている時は 「このフォルダーだけ」 に絞れる。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/mind_map_provider.dart';
import '../services/git_history.dart';

class GitHistoryDialog extends StatefulWidget {
  const GitHistoryDialog({super.key, required this.dir});

  /// 履歴を見るフォルダーの道筋 (= 開いたフォルダー)。
  final String dir;

  @override
  State<GitHistoryDialog> createState() => _GitHistoryDialogState();
}

class _GitHistoryDialogState extends State<GitHistoryDialog> {
  /// 一度に読む件数。 全部読むと大きなリポジトリで待たされる。
  static const int _kPage = 200;

  bool _loading = true;

  /// 'noGit' (git が無い) / 'notRepo' (git の管理下でない) / null (問題なし)。
  String? _error;

  String? _repoRoot;
  String _branch = '';

  final List<GitCommit> _commits = <GitCommit>[];

  /// 枝の記号の桝の幅 (読み込んだ内容から決める)。
  double _graphW = 30;

  bool _more = false;
  bool _loadingMore = false;

  /// 開いたフォルダーを触ったコミットだけに絞るか。
  bool _folderOnly = false;

  /// いま開いている (= 変更ファイルを見せている) コミット。
  String? _openHash;
  List<GitFileChange>? _files;
  bool _filesLoading = false;

  String? _patchFile;
  String? _patch;
  bool _patchLoading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  /// 道筋を比べられる形に均す (Windows は大小を区別しない)。
  static String _norm(String p) {
    var t = p.trim().replaceAll('\\', '/');
    while (t.length > 1 && t.endsWith('/')) {
      t = t.substring(0, t.length - 1);
    }
    return t.toLowerCase();
  }

  /// 「このフォルダーだけ」 を出すか (根そのものを開いている時は無意味)。
  bool get _canFilter =>
      _repoRoot != null && _norm(_repoRoot!) != _norm(widget.dir);

  /// 枝の記号の桝の幅を内容から決める。
  ///
  /// ★ 決め打ちの幅にすると、 筋が増えた行が切れて枝の絵が嘘になる。
  ///   Consolas 12px は 1 文字およそ 6.8px。
  /// ★ clamp は num を返すので、 double の欄へ渡す前に toDouble() する。
  static double _graphWidthFor(List<GitCommit> list) {
    var maxLen = 2;
    for (final c in list) {
      if (c.graph.length > maxLen) maxLen = c.graph.length;
      for (final g in c.graphExtra) {
        if (g.length > maxLen) maxLen = g.length;
      }
    }
    final w = maxLen * 6.8 + 8;
    return w.clamp(26.0, 132.0).toDouble();
  }

  Future<void> _boot() async {
    final exe = await GitHistory.findGitExe();
    if (!mounted) return;
    if (exe == null) {
      setState(() {
        _loading = false;
        _error = 'noGit';
      });
      return;
    }
    final root = await GitHistory.repoRoot(widget.dir);
    if (!mounted) return;
    if (root == null) {
      setState(() {
        _loading = false;
        _error = 'notRepo';
      });
      return;
    }
    final branch = await GitHistory.currentBranch(widget.dir);
    final list = await GitHistory.log(widget.dir, count: _kPage);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _repoRoot = root;
      _branch = branch;
      _commits
        ..clear()
        ..addAll(list ?? const <GitCommit>[]);
      _graphW = _graphWidthFor(_commits);
      _more = (list?.length ?? 0) >= _kPage;
    });
  }

  /// [want] 件まで読み直す (増やす / 絞りを変える のどちらでも使う)。
  Future<void> _fetch(int want) async {
    final list = await GitHistory.log(widget.dir,
        count: want, filePath: _folderOnly ? widget.dir : null);
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      // 読み直したら、 開いていた差分は閉じる (別の物を指しかねない)。
      _openHash = null;
      _files = null;
      _patchFile = null;
      _patch = null;
      if (list != null) {
        _commits
          ..clear()
          ..addAll(list);
        _graphW = _graphWidthFor(_commits);
        _more = list.length >= want;
      } else {
        _more = false;
      }
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    await _fetch(_commits.length + _kPage);
  }

  Future<void> _toggleFolderOnly() async {
    if (_loadingMore) return;
    setState(() {
      _folderOnly = !_folderOnly;
      _loadingMore = true;
    });
    await _fetch(_kPage);
  }

  Future<void> _toggle(GitCommit c) async {
    if (_openHash == c.hash) {
      setState(() {
        _openHash = null;
        _files = null;
        _patchFile = null;
        _patch = null;
      });
      return;
    }
    setState(() {
      _openHash = c.hash;
      _files = null;
      _filesLoading = true;
      _patchFile = null;
      _patch = null;
    });
    final f = await GitHistory.changedFiles(widget.dir, c.hash);
    if (!mounted || _openHash != c.hash) return;
    setState(() {
      _files = f ?? const <GitFileChange>[];
      _filesLoading = false;
    });
  }

  Future<void> _showPatch(GitCommit c, String path) async {
    setState(() {
      _patchFile = path;
      _patch = null;
      _patchLoading = true;
    });
    final p = await GitHistory.patch(widget.dir, c.hash, filePath: path);
    if (!mounted || _patchFile != path) return;
    setState(() {
      _patch = p ?? '';
      _patchLoading = false;
    });
  }

  static String _baseName(String p) {
    final t = p.replaceAll('\\', '/');
    final parts = t.split('/').where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? p : parts.last;
  }

  static Color _statusColor(String s) {
    if (s.startsWith('A')) return const Color(0xFF7CD992);
    if (s.startsWith('D')) return const Color(0xFFFF8A80);
    if (s.startsWith('R')) return const Color(0xFFFFB347);
    return const Color(0xFF4FC3F7);
  }

  /// 枝の記号は等幅で揃えないと線がずれる。
  static const TextStyle _monoGraph = TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: <String>['Courier New', 'monospace'],
      fontSize: 12,
      height: 1.25,
      color: Color(0xFF6C63FF));

  @override
  Widget build(BuildContext context) {
    final provider = context.read<MindMapProvider>();
    final head = _repoRoot == null
        ? widget.dir
        : '${_baseName(_repoRoot!)}'
            '${_branch.isEmpty ? '' : '  ·  $_branch'}';
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E32),
      contentPadding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      title: Row(children: [
        const Icon(Icons.account_tree_rounded,
            color: Color(0xFF6C63FF), size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(provider.t('git.history'),
                  style: const TextStyle(color: Colors.white, fontSize: 15)),
              Text(head,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11)),
            ],
          ),
        ),
      ]),
      // ★ 外側 (_showNearDialogMain) が巻物なので、 ここで高さを決めて
      //   中の一覧だけを巻く。
      content: SizedBox(
        width: double.maxFinite,
        height: 440,
        child: _body(provider),
      ),
      actions: [
        if (_error == null && !_loading)
          Text(
              provider
                  .t('git.shownCount')
                  .replaceFirst('{n}', '${_commits.length}'),
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
        if (_error == null && !_loading && _more)
          TextButton(
            onPressed: _loadingMore ? null : () => unawaited(_loadMore()),
            child: Text(provider.t('git.more'),
                style: const TextStyle(color: Color(0xFF4FC3F7))),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(provider.t('btn.close'),
              style: const TextStyle(color: Colors.white54)),
        ),
      ],
    );
  }

  Widget _body(MindMapProvider provider) {
    if (_loading) {
      return const Center(
        child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      final noGit = _error == 'noGit';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                  noGit
                      ? Icons.help_outline_rounded
                      : Icons.info_outline_rounded,
                  color: Colors.white38,
                  size: 30),
              const SizedBox(height: 10),
              Text(provider.t(noGit ? 'git.noGit' : 'git.notRepo'),
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 6),
              Text(widget.dir,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.white24, fontSize: 10.5)),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ★ 根より下を開いている時は「このフォルダーだけ」 に絞れるように
        //   (= ユーザー要望の文言は「開いたフォルダー内の履歴」)。
        if (_canFilter)
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              onTap: _loadingMore ? null : () => unawaited(_toggleFolderOnly()),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                      _folderOnly
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 15,
                      color: _folderOnly
                          ? const Color(0xFF6C63FF)
                          : Colors.white38),
                  const SizedBox(width: 5),
                  Text(provider.t('git.thisFolderOnly'),
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11.5)),
                ]),
              ),
            ),
          ),
        Expanded(
          child: _commits.isEmpty
              ? Center(
                  child: Text(provider.t('git.empty'),
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 12.5)),
                )
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: _commits.length,
                  // 枝の桝の所では切らない (線が途切れて見えるため)。
                  separatorBuilder: (_, __) => Divider(
                      height: 1, color: Colors.white12, indent: _graphW),
                  itemBuilder: (_, i) => _commitTile(provider, _commits[i]),
                ),
        ),
      ],
    );
  }

  Widget _commitTile(MindMapProvider provider, GitCommit c) {
    final open = _openHash == c.hash;
    final graph = <String>[
      c.graph.isEmpty ? '*' : c.graph,
      ...c.graphExtra,
    ].join('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => unawaited(_toggle(c)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _graphW,
                  child: Text(graph,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: _monoGraph),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.subject,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                      const SizedBox(height: 2),
                      Row(children: [
                        Text(c.shortHash,
                            style: const TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 11,
                                color: Color(0xFFFFB347))),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text('${c.author} · ${c.dateText}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 11)),
                        ),
                        if (c.isMerge) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.call_merge_rounded,
                              size: 12, color: Colors.white38),
                        ],
                      ]),
                      if (c.refs.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Wrap(
                          spacing: 4,
                          runSpacing: 3,
                          children: c.refs
                              .map((r) => Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: const Color(0x336C63FF),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                          color: const Color(0x556C63FF)),
                                    ),
                                    child: Text(r,
                                        style: const TextStyle(
                                            color: Color(0xFFBFB9FF),
                                            fontSize: 9.5)),
                                  ))
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: provider.t('git.copyHash'),
                  iconSize: 15,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.content_copy_rounded,
                      color: Colors.white38),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: c.hash));
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
                      duration: const Duration(seconds: 2),
                      backgroundColor: const Color(0xFF6C63FF),
                      content: Text(provider.t('git.copied'),
                          style: const TextStyle(color: Colors.white)),
                    ));
                  },
                ),
                Icon(
                    open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: Colors.white24),
              ],
            ),
          ),
        ),
        if (open) _detail(provider, c),
      ],
    );
  }

  Widget _detail(MindMapProvider provider, GitCommit c) {
    final files = _files ?? const <GitFileChange>[];
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(left: _graphW, right: 4, bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(provider.t('git.changedFiles'),
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          if (_filesLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (files.isEmpty)
            Text(provider.t('git.noFiles'),
                style:
                    const TextStyle(color: Colors.white38, fontSize: 11.5))
          else
            ...files.map((f) => InkWell(
                  onTap: () => unawaited(_showPatch(c, f.path)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      SizedBox(
                        width: 30,
                        child: Text(f.status,
                            style: TextStyle(
                                fontFamily: 'Consolas',
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: _statusColor(f.status))),
                      ),
                      Expanded(
                        child: Text(f.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11.5)),
                      ),
                    ]),
                  ),
                )),
          if (_patchFile != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.compare_arrows_rounded,
                  size: 13, color: Colors.white38),
              const SizedBox(width: 5),
              Expanded(
                child: Text(_patchFile!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11)),
              ),
              IconButton(
                iconSize: 15,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, color: Colors.white38),
                onPressed: () => setState(() {
                  _patchFile = null;
                  _patch = null;
                }),
              ),
            ]),
            if (_patchLoading)
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF14141F),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: _patchText(_patch ?? ''),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 差分に色を付けて等幅で出す (足した行 = 緑 / 消した行 = 赤)。
  Widget _patchText(String patch) {
    final spans = <TextSpan>[];
    for (final raw in patch.split('\n')) {
      var color = Colors.white60;
      if (raw.startsWith('+') && !raw.startsWith('+++')) {
        color = const Color(0xFF7CD992);
      } else if (raw.startsWith('-') && !raw.startsWith('---')) {
        color = const Color(0xFFFF8A80);
      } else if (raw.startsWith('@@')) {
        color = const Color(0xFF4FC3F7);
      } else if (raw.startsWith('diff ') || raw.startsWith('index ')) {
        color = Colors.white38;
      }
      spans.add(TextSpan(text: '$raw\n', style: TextStyle(color: color)));
    }
    return RichText(
      text: TextSpan(
        style: const TextStyle(
            fontFamily: 'Consolas', fontSize: 11, height: 1.35),
        children: spans,
      ),
    );
  }
}
