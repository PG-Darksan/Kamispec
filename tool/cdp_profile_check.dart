// アカウントを指定して開けるか / 窓が増えないかを確かめる。
//
//   dart run tool/cdp_profile_check.dart            … 一覧と名前引きだけ
//   dart run tool/cdp_profile_check.dart "浩靖"      … そのアカウントで開く
//
// = ユーザー報告「アカウントを指定してログインしてと頼んでいるのに
//   ログインできない」「実行が終わってもタブが複数回開く」。
//
// ★ 普段のプロファイルには**一切触らない** (呼び名を読むだけ)。
//   アカウントごとの自動操作用ブラウザは
//   %LOCALAPPDATA%\HisatorNotebook\cdp_chrome_acct_* に作られる。
import 'dart:io';

import 'package:mindmap_app/services/cdp_browser.dart';

int fails = 0;
void check(String what, bool ok, [String extra = '']) {
  stdout.writeln(
      '  ${ok ? "ok  " : "FAIL"} $what${extra.isEmpty ? '' : '  ($extra)'}');
  if (!ok) fails++;
}

/// 目に見える Chrome の窓の数 (タブ・窓が増えていないかの目安)。
int chromeWindows() {
  try {
    final r = Process.runSync('powershell', [
      '-NoProfile',
      '-Command',
      r'@(Get-Process chrome -ErrorAction SilentlyContinue | '
          r'Where-Object { $_.MainWindowTitle -ne "" }).Count',
    ]);
    return int.tryParse('${r.stdout}'.trim()) ?? -1;
  } catch (_) {
    return -1;
  }
}

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    stdout.writeln('Windows 専用の道具です。');
    exit(0);
  }
  const kind = CdpBrowserKind.chrome;

  stdout.writeln('== 普段の Chrome に入っているアカウント ==');
  final list = CdpBrowser.listProfiles(kind);
  for (final p in list) {
    stdout.writeln('       ${p.dir.padRight(11)} '
        '${p.name.padRight(12)} ${p.account}');
  }
  check('1 つ以上見つかる', list.isNotEmpty, '${list.length} 個');
  if (list.isEmpty) exit(1);

  stdout.writeln('\n== 呼び名から見分けられる ==');
  for (final p in list) {
    if (p.name.isEmpty) continue;
    check('「${p.name}の垢で立ち上げて」 → ${p.dir}',
        CdpBrowser.profileDirFor(kind, '${p.name}の垢で立ち上げて') == p.dir);
  }
  check('知らない名前は拾わない',
      CdpBrowser.profileDirFor(kind, 'そんな人はいない') == null);

  stdout.writeln('\n== アカウントごとに置き場が分かれる ==');
  final dirs = <String, String>{};
  for (final p in list) {
    if (p.name.trim().isEmpty) continue;
    dirs[p.name] = CdpBrowser.accountDataDir(kind, p.name);
  }
  for (final e in dirs.entries) {
    final tail = e.value.split(Platform.pathSeparator).last;
    stdout.writeln('       ${e.key.padRight(12)} $tail');
  }
  check('同じ置き場に衝突しない',
      dirs.values.toSet().length == dirs.length,
      '${dirs.length} 個 -> ${dirs.values.toSet().length} 通り');

  final want = args.isEmpty ? '' : args.first;
  if (want.isEmpty) {
    stdout.writeln('\n  (開く試験はしていません。 '
        '呼び名を渡すと、 そのアカウントで開いて確かめます)');
    stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
    exit(fails == 0 ? 0 : 1);
  }

  stdout.writeln('\n== 「$want」 専用のブラウザで開く ==');
  final dir = CdpBrowser.accountDataDir(kind, want);
  stdout.writeln('       置き場: $dir');
  final before = chromeWindows();
  final port = 9930 + (DateTime.now().millisecondsSinceEpoch % 40);

  CdpBrowser? b;
  try {
    b = await CdpBrowser.launchAndConnect(
      kind: kind,
      url: 'https://example.com/',
      port: port,
      useOwnProfile: true,
      profileHint: want,
    );
    check('つながった', true, 'ポート $port');
    check('狙ったアカウント', b.profileDir == want, b.profileDir);
    check('ゲストになっていない', !b.openedAsGuest);
    check('まっさらに落ちていない', !b.downgradedFromOwnProfile);
    check('専用の置き場ができた', Directory(dir).existsSync());
    stdout.writeln('       初回ログインが要るか: ${b.needsFirstLogin}');

    final mid = chromeWindows();
    check('窓は 1 つだけ増えた', mid <= before + 1, '前=$before 後=$mid');

    stdout.writeln('\n== もう一度 openBrowser しても増えないか ==');
    // パネルと同じで、 同じ口・同じアカウントなら開き直さない。
    final b2 = await CdpBrowser.launchAndConnect(
      kind: kind,
      url: 'https://example.org/',
      port: port,
      useOwnProfile: true,
      profileHint: want,
    );
    final after = chromeWindows();
    check('窓が増えていない', after <= mid, '前=$mid 後=$after');
    final cur = await b2.current();
    check('同じ窓のまま次のページへ移った',
        (cur?.url ?? '').contains('example.org'), cur?.url ?? '');
    await b2.dispose();

    stdout.writeln('\n== 2 回目は「初回ログイン」 と言わない ==');
    // クッキーが溜まっていれば false になる (今は空なので true のはず)。
    stdout.writeln('       ログイン済みの見立て: '
        '${CdpBrowser.accountLoggedInBefore(kind, want)}');
  } catch (e) {
    check('例外が出ていない', false, '$e');
  } finally {
    await b?.closeQuietly();
  }

  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
