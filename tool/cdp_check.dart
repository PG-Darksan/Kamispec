// 外のブラウザを CDP で操作できるかを確かめる道具。
//
//   dart run tool/cdp_check.dart          … 入っている物の先頭で試す
//   dart run tool/cdp_check.dart edge     … ブラウザを指定
//
// ★ 普段のプロファイルは使わない (使い捨ての置き場で開く) ので、
//   開いているタブやログイン状態には触らない。
// ★ 毎回ちがうポートを使う。 前回の窓が残っていると、 そちらに繋がって
//   「別のページを見ている」 ことになり、 検査がすれ違うため。
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

  stdout.writeln('== 入っているブラウザ ==');
  final found = CdpBrowser.installed();
  for (final k in found) {
    stdout.writeln('       - ${k.label}  ${CdpBrowser.findExe(k)}');
  }
  check('1 つ以上見つかる', found.isNotEmpty, '${found.length} 個');
  if (found.isEmpty) exit(1);

  final want = args.isEmpty
      ? found.first
      : (CdpBrowserKindName.fromText(args.first) ?? found.first);
  check('${want.label} が使える', found.contains(want));
  if (!found.contains(want)) exit(1);

  // 前回の窓を掴まないよう、 毎回ちがうポートで開く。
  final port = 9400 + (DateTime.now().millisecondsSinceEpoch % 300);

  CdpBrowser? b;
  try {
    stdout.writeln('\n== 開いてつなぐ (${want.label}, ポート $port) ==');
    final t0 = DateTime.now();
    b = await CdpBrowser.launchAndConnect(
      kind: want,
      url: 'https://example.com/',
      port: port,
    );
    check('つながった', true,
        '${DateTime.now().difference(t0).inMilliseconds} ms');

    // 検査する場所を自分で揃える (起動時の URL に頼らない)。
    await b.navigate('https://example.com/', waitMs: 2500);

    stdout.writeln('\n== ページの中身が見える (= 座標が要らない証拠) ==');
    final cur = await b.current();
    check('URL が取れる', (cur?.url ?? '').contains('example.com'),
        cur?.url ?? '(取れず)');
    check('タイトルが取れる', (cur?.title ?? '').isNotEmpty,
        cur?.title ?? '(取れず)');

    final h1 = await b.evaluate(
        "document.querySelector('h1') ? document.querySelector('h1')"
        ".textContent : ''");
    check('見出しの文字が読める', (h1 ?? '').contains('Example'), '$h1');

    // アプリの自動操作と同じやり方 (押せる物を文字で集める)。
    final items = await b.evaluate(
        "JSON.stringify(Array.from(document.querySelectorAll("
        "'a,button,input[type=submit]')).slice(0,10)"
        ".map(function(e){return (e.innerText||e.value||'').trim();})"
        ".filter(function(t){return t;}))");
    // example.com のリンクは「Learn more」 (以前は "More information..." )。
    //   文言が変わっても壊れないよう、 拾えていること自体を見る。
    check('押せる物を文字で拾える',
        (items ?? '').toLowerCase().contains('more'), '$items');

    stdout.writeln('\n== 動かせる ==');
    await b.navigate('https://example.org/', waitMs: 2500);
    final cur2 = await b.current();
    check('別のページへ移れる', (cur2?.url ?? '').contains('example.org'),
        cur2?.url ?? '(取れず)');

    // 文字で要素を探して押す = 座標を使わない操作。
    final clicked = await b.evaluate(
        "(function(){var a=Array.from(document.querySelectorAll('a'))"
        ".find(function(e){return (e.innerText||'').toLowerCase()"
        ".indexOf('more')>=0;});"
        "if(!a) return 'not found'; a.click(); return 'clicked';})()");
    check('文字で要素を探して押せる', clicked == 'clicked', '$clicked');

    stdout.writeln('\n== 画面も撮れる ==');
    final png = await b.screenshotBase64();
    check('スクショが取れる', (png ?? '').length > 1000,
        '${((png ?? '').length / 1024).toStringAsFixed(0)} KB (base64)');
  } catch (e) {
    check('例外が出ていない', false, '$e');
  } finally {
    await b?.dispose();
    stdout.writeln('\n  後始末: つながりを閉じました '
        '(開いた窓は手で閉じてください)');
  }

  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
