// 外のブラウザから「スクショ以外のデータ」 を取れるかを確かめる。
//
//   dart run tool/cdp_data_check.dart
//
// = ユーザー要望「ページからダウンロードボタンを押してダウンロードしたり、
//   エラーが起こっている画面のデバッグログを取ったりできるようにして」。
// ★ 使い捨てのプロファイルで開くので、 普段の Chrome には触らない。
import 'dart:io';

import 'package:mindmap_app/services/cdp_browser.dart';
import 'package:mindmap_app/services/page_extract_js.dart';

int fails = 0;
void check(String what, bool ok, [String extra = '']) {
  stdout.writeln(
      '  ${ok ? "ok  " : "FAIL"} $what${extra.isEmpty ? '' : '  ($extra)'}');
  if (!ok) fails++;
}

String dataUrl(String html) =>
    'data:text/html;charset=utf-8,${Uri.encodeComponent(html)}';

// ログとエラーを出すページ
const _noisy = '''
<!doctype html><meta charset="utf-8"><title>noisy</title>
<body><h1>noisy</h1><script>
console.log('ふつうの記録です');
console.warn('気を付けてください');
console.error('ここで失敗しました');
setTimeout(function(){ null.こわれる(); }, 100);
</script></body>''';

// ダウンロードのボタンがあるページ
const _dl = '''
<!doctype html><meta charset="utf-8"><title>dl</title>
<body><h1>download</h1>
<a id="b" download="sample.txt"
   href="data:text/plain;charset=utf-8,%E3%81%93%E3%82%93%E3%81%AB%E3%81%A1%E3%81%AF">
  ダウンロード</a>
</body>''';


// 取り出しを試すページ (表とリンクと本文)
const _rich = '''
<!doctype html><meta charset="utf-8"><title>rich</title>
<body><div id="main"><h1>見出し</h1>
<p>本文です。</p>
<table><tr><th>名前</th><th>数</th><th>備考</th></tr>
<tr><td>あ,い</td><td>12</td><td>引用"つき"</td></tr>
<tr><td>う</td><td>3</td><td></td></tr></table>
<a href="https://example.com/a">ひとつめ</a>
<a href="https://example.com/b">ふたつめ</a>
<a id="d" download="s.txt"
   href="data:text/plain;charset=utf-8,ok">ダウンロード</a>
</div></body>''';

Future<void> main() async {
  if (!Platform.isWindows) {
    stdout.writeln('Windows 専用の道具です。');
    exit(0);
  }
  final found = CdpBrowser.installed();
  if (found.isEmpty) {
    stdout.writeln('ブラウザが見つかりません。');
    exit(1);
  }
  final kind = found.first;
  final port = 9860 + (DateTime.now().millisecondsSinceEpoch % 100);

  final dir = Directory('${Directory.systemTemp.path}'
      '\\hn_cdp_dl_${DateTime.now().millisecondsSinceEpoch}');
  dir.createSync(recursive: true);

  CdpBrowser? b;
  try {
    b = await CdpBrowser.launchAndConnect(kind: kind, port: port);
    check('つながった', true, '${kind.label} / ポート $port');

    stdout.writeln('\n== ページのログ・エラーを取る ==');
    await b.startConsoleCapture();
    await b.navigate(dataUrl(_noisy), waitMs: 2500);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final lines = b.consoleLines;
    stdout.writeln('       集めた行数: ${lines.length}');
    for (final l in lines.take(8)) {
      stdout.writeln('       $l');
    }
    check('console.log を拾える',
        lines.any((l) => l.contains('ふつうの記録')), '');
    check('console.error を拾える',
        lines.any((l) => l.contains('ここで失敗')), '');
    check('捕まえていない例外を拾える',
        lines.any((l) => l.toLowerCase().contains('typeerror') ||
            l.contains('こわれる')), '');

    stdout.writeln('\n== ダウンロード ==');
    final okDl = await b.enableDownloads(dir.path);
    check('受け入れを設定できた', okDl, dir.path);
    await b.navigate(dataUrl(_dl), waitMs: 1500);
    final clicked = await b.evaluate(
        "(function(){var a=document.getElementById('b');"
        "if(!a) return 'no';a.click();return 'ok';})()");
    check('ボタンを押せた', clicked == 'ok', '$clicked');
    final name = await b.waitForDownload(
        timeout: const Duration(seconds: 20));
    check('ダウンロードが終わった', name != null, name ?? '(来ませんでした)');
    // ★ 途中の .crdownload (書きかけ) は数えない。
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => !f.path.toLowerCase().endsWith('.crdownload'))
        .toList();
    check('ファイルが保存されている', files.isNotEmpty,
        files.map((f) => f.path.split('\\').last).join(', '));
    final saved = files.where((f) => f.path.endsWith('sample.txt'));
    check('中身が読める',
        saved.isNotEmpty && saved.first.readAsStringSync().contains('こんにちは'),
        saved.isEmpty ? '(sample.txt が無い)' : saved.first.readAsStringSync());

    stdout.writeln('\n== ページの中身を取り出す ==');
    await b.navigate(dataUrl(_rich), waitMs: 1500);

    final text = await b.evaluate(extractJs('text', ''));
    check('本文が取れる', (text ?? '').contains('見出し'),
        (text ?? '').replaceAll('\n', ' / '));

    final csv = await b.evaluate(extractJs('table', 'table'));
    stdout.writeln('       表:\n${(csv ?? '').split('\n').map(
        (l) => '         $l').join('\n')}');
    check('表が CSV になる', (csv ?? '').startsWith('名前,数,備考'), '');
    // 「,」 を含む値は引用符で囲む。
    check('区切り文字を含む値を囲む',
        (csv ?? '').contains('"あ,い"'), '');
    // 引用符そのものは 2 つ重ねる。
    check('引用符を二重にする',
        (csv ?? '').contains('""'), '');

    final links = await b.evaluate(extractJs('links', ''));
    check('リンクの一覧が取れる',
        (links ?? '').contains('example.com') &&
            (links ?? '').contains('\t'),
        (links ?? '').replaceAll('\n', ' | '));

    final html = await b.evaluate(extractJs('html', '#main'));
    check('範囲を指定した HTML が取れる',
        (html ?? '').startsWith('<div id="main"'), '');

    final href = await b.evaluate(hrefOfJs('', 'ダウンロード'));
    check('押す物の飛び先を読める',
        (href ?? '').startsWith('data:text/plain'), '');
  } catch (e) {
    check('例外が出ていない', false, '$e');
  } finally {
    await b?.closeQuietly();
    stdout.writeln('\n  置き場: ${dir.path}');
  }

  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
