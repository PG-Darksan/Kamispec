// アカウント指定の初回ログイン案内が、 400 にならずに出るかを確かめる。
//
//   dart run tool/cdp_firstlogin_check.dart
//
// = ユーザー報告「400 エラーが出る」。 原因は Google の continue が
//   **Google のドメインしか受け付けない**こと (実測)。 自分のページを
//   渡していたので弾かれていた。
//
// ★ 検査用の使い捨てアカウント名で試すので、 普段のブラウザには触らない。
import 'dart:io';

import 'package:mindmap_app/services/cdp_browser.dart';

int fails = 0;
void check(String what, bool ok, [String extra = '']) {
  stdout.writeln(
      '  ${ok ? "ok  " : "FAIL"} $what${extra.isEmpty ? '' : '  ($extra)'}');
  if (!ok) fails++;
}

Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('Windows 専用の道具です。');
    exit(0);
  }
  final kind = CdpBrowser.installed().first;
  // 実在しない呼び名にして、 普段のアカウントの置き場を触らない。
  final label = 'zz検査${DateTime.now().millisecondsSinceEpoch % 100000}';
  final dir = CdpBrowser.accountDataDir(kind, label);
  final port = 9860 + (DateTime.now().millisecondsSinceEpoch % 40);

  CdpBrowser? b;
  try {
    stdout.writeln('== 初めて使うアカウント ==');
    check('置き場はまだ無い', !Directory(dir).existsSync(),
        dir.split(Platform.pathSeparator).last);
    b = await CdpBrowser.launchAndConnect(
      kind: kind,
      url: 'https://example.com/',
      port: port,
      useOwnProfile: true,
      profileHint: label,
    );
    check('つながった', true);
    check('初回だと分かる', b.needsFirstLogin);

    stdout.writeln('\n== ログイン画面が 400 にならない ==');
    const mail = 'someone@gmail.com';
    // アプリと同じ URL の組み立て (continue は付けない)。
    await b.navigate(
        'https://accounts.google.com/AccountChooser'
        '?Email=${Uri.encodeComponent(mail)}',
        waitMs: 2800);
    final txt = await b.evaluate(
        "(document.body?document.body.innerText:'')"
        ".replace(/\\s+/g,' ').slice(0,120)");
    final bad = (txt ?? '').contains('400') ||
        (txt ?? '').contains("That’s an error") ||
        (txt ?? '').contains("That's an error");
    check('400 にならない', !bad, txt ?? '');
    check('ログイン画面が出ている',
        (txt ?? '').contains('ログイン') || (txt ?? '').toLowerCase().contains('sign in'),
        '');

    stdout.writeln('\n== 自分のページを continue に付けると弾かれる (直す前) ==');
    await b.navigate(
        'https://accounts.google.com/AccountChooser'
        '?Email=${Uri.encodeComponent(mail)}'
        '&continue=${Uri.encodeComponent('https://hisator-notebook.com')}',
        waitMs: 2800);
    final txt2 = await b.evaluate(
        "(document.body?document.body.innerText:'')"
        ".replace(/\\s+/g,' ').slice(0,60)");
    check('確かに 400 になる (原因の裏取り)',
        (txt2 ?? '').contains('400'), txt2 ?? '');

    stdout.writeln('\n== 2 回目は初回扱いにならない ==');
    await b.closeQuietly();
    b = null;
    check('置き場ができている', Directory(dir).existsSync());
    final b2 = await CdpBrowser.launchAndConnect(
      kind: kind,
      url: 'https://example.com/',
      port: port + 3,
      useOwnProfile: true,
      profileHint: label,
    );
    check('2 回目は初回と言わない', !b2.needsFirstLogin);
    await b2.closeQuietly();
  } catch (e) {
    check('例外が出ていない', false, '$e');
  } finally {
    await b?.closeQuietly();
    // 検査で作った置き場は片付ける。
    try {
      final d = Directory(dir);
      if (d.existsSync()) d.deleteSync(recursive: true);
      stdout.writeln('\n  後始末: 検査用の置き場を消しました');
    } catch (_) {}
  }

  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
