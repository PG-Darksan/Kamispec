// ゲストモードで開けるか、 そこでも操作できるかを確かめる。
//
//   dart run tool/cdp_guest_check.dart
//
// = ユーザー要望「(既定のプロファイルが無い時は) ゲストモードで
//   開かれるようにして欲しい」 の裏取り。
// ★ 普段のプロファイルには触らない (置き場を分けて開く)。
import 'dart:io';

import 'package:mindmap_app/services/cdp_browser.dart';

int fails = 0;
void check(String what, bool ok, [String extra = '']) {
  stdout.writeln(
      '  ${ok ? "ok  " : "FAIL"} $what${extra.isEmpty ? '' : '  ($extra)'}');
  if (!ok) fails++;
}

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    stdout.writeln('Windows 専用の道具です。');
    exit(0);
  }
  final found = CdpBrowser.installed();
  if (found.isEmpty) {
    stdout.writeln('ブラウザが見つかりません。');
    exit(1);
  }
  final kind = args.isEmpty
      ? found.first
      : (CdpBrowserKindName.fromText(args.first) ?? found.first);

  stdout.writeln('== 判定の材料 ==');
  stdout.writeln('       置き場: ${CdpBrowser.userDataRoot(kind)}');
  stdout.writeln('       Default がある: ${CdpBrowser.hasDefaultProfile(kind)}');
  stdout.writeln('       プロファイル数: ${CdpBrowser.profileCount(kind)}');

  final port = 9700 + (DateTime.now().millisecondsSinceEpoch % 150);
  CdpBrowser? b;
  try {
    stdout.writeln('\n== ゲストで開いてつなぐ (ポート $port) ==');
    b = await CdpBrowser.launchAndConnect(
      kind: kind,
      url: 'https://example.com/',
      port: port,
      guest: true,
    );
    check('つながった', true, kind.label);
    check('プロファイル選択画面ではない', !await b.isAtProfilePicker());

    await b.navigate('https://example.com/', waitMs: 2000);
    final cur = await b.current();
    check('ページを開けている', (cur?.url ?? '').contains('example.com'),
        cur?.url ?? '(取れず)');
    final h1 = await b.evaluate(
        "document.querySelector('h1')?document.querySelector('h1')"
        ".textContent:''");
    check('ゲストでも中身が読める', (h1 ?? '').contains('Example'), '$h1');
    final png = await b.screenshotBase64();
    check('ゲストでもスクショが撮れる', (png ?? '').length > 1000);
  } catch (e) {
    check('例外が出ていない', false, '$e');
  } finally {
    await b?.closeQuietly();
  }
  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
