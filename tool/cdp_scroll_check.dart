// 「一番下までスクロールして」 が本当に効くかを、 外のブラウザで確かめる。
//
//   dart run tool/cdp_scroll_check.dart
//
// ★ 使い捨てのプロファイルで開くので、 普段の Chrome やログイン状態には
//   触らない。 3 通りのページで試す:
//     1. ふつうの縦長ページ
//     2. body の高さが 0 で、 内側の枠がスクロールするページ
//     3. 下へ行くほど中身が増えるページ (遅延読み込み)
import 'dart:convert';
import 'dart:io';

import 'package:mindmap_app/services/cdp_browser.dart';
import 'package:mindmap_app/services/page_scroll_js.dart';

int fails = 0;
void check(String what, bool ok, [String extra = '']) {
  stdout.writeln(
      '  ${ok ? "ok  " : "FAIL"} $what${extra.isEmpty ? '' : '  ($extra)'}');
  if (!ok) fails++;
}

/// パネルと同じ進め方: 位置も高さも変わらなくなるまで押し込む。
Future<({int y, int h})> scrollToEnd(CdpBrowser b, bool toTop,
    {int maxTries = 8}) async {
  final js = scrollEndJs(toTop);
  var lastY = -1;
  var lastH = -1;
  for (var i = 0; i < (toTop ? 2 : maxTries); i++) {
    final raw = await b.evaluate(js);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (raw == null) break;
    final p = raw.replaceAll('"', '').trim().split(',');
    if (p.length != 2) break;
    final y = int.tryParse(p[0]);
    final h = int.tryParse(p[1]);
    if (y == null || h == null) break;
    if (y == lastY && h == lastH) return (y: y, h: h);
    lastY = y;
    lastH = h;
  }
  return (y: lastY, h: lastH);
}

String dataUrl(String html) =>
    'data:text/html;charset=utf-8,${Uri.encodeComponent(html)}';

// 1. ふつうの縦長ページ
const _tall = '''
<!doctype html><meta charset="utf-8"><title>tall</title>
<body style="margin:0">
<div style="height:6000px;background:linear-gradient(#eef,#fee)"></div>
<div id="foot" style="height:200px;background:#333;color:#fff">FOOTER</div>
</body>''';

// 2. body は動かず、 内側の枠がスクロールする
const _innerScroll = '''
<!doctype html><meta charset="utf-8"><title>inner</title>
<body style="margin:0;height:100vh;overflow:hidden">
<div id="box" style="height:100vh;overflow-y:auto">
  <div style="height:5000px;background:linear-gradient(#efe,#eef)"></div>
  <div id="foot" style="height:200px;background:#333;color:#fff">FOOTER</div>
</div>
</body>''';

// 3. 下へ行くほど中身が増える (遅延読み込み)
const _lazy = '''
<!doctype html><meta charset="utf-8"><title>lazy</title>
<body style="margin:0"><div id="c"></div><script>
var n=0;
function grow(){var d=document.createElement('div');
 d.style.height='1500px';d.style.background=(n%2?'#eef':'#fee');
 d.textContent='block '+n;document.getElementById('c').appendChild(d);n++;}
for(var i=0;i<3;i++)grow();
window.addEventListener('scroll',function(){
 var e=document.scrollingElement;
 if(e.scrollTop+window.innerHeight>e.scrollHeight-200&&n<8)grow();});
</script></body>''';

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

  stdout.writeln('== 既定のプロファイルの様子 (選択画面が出る条件) ==');
  stdout.writeln('       置き場: ${CdpBrowser.userDataRoot(kind)}');
  check('Default がある', CdpBrowser.hasDefaultProfile(kind),
      'profileCount=${CdpBrowser.profileCount(kind)}');

  final port = 9500 + (DateTime.now().millisecondsSinceEpoch % 200);
  CdpBrowser? b;
  try {
    b = await CdpBrowser.launchAndConnect(
      kind: kind,
      url: dataUrl(_tall),
      port: port,
    );
    check('つながった', true, '${kind.label} / ポート $port');
    check('選択画面ではない', !await b.isAtProfilePicker());

    stdout.writeln('\n== 1. ふつうの縦長ページ ==');
    await b.navigate(dataUrl(_tall), waitMs: 1200);
    final r1 = await scrollToEnd(b, false);
    final seen1 = await b.evaluate(
        "(function(){var f=document.getElementById('foot');"
        "if(!f)return 'no';var r=f.getBoundingClientRect();"
        "return (r.top < window.innerHeight && r.bottom > 0)?'yes':'no';})()");
    check('一番下まで届いた', r1.y > 5000, 'scrollTop=${r1.y} / 全体=${r1.h}');
    check('フッターが画面に入っている', seen1 == 'yes', '$seen1');

    stdout.writeln('\n== 2. 内側の枠がスクロールするページ ==');
    await b.navigate(dataUrl(_innerScroll), waitMs: 1200);
    final r2 = await scrollToEnd(b, false);
    final seen2 = await b.evaluate(
        "(function(){var f=document.getElementById('foot');"
        "if(!f)return 'no';var r=f.getBoundingClientRect();"
        "return (r.top < window.innerHeight && r.bottom > 0)?'yes':'no';})()");
    check('内側の枠を送れた', r2.y > 4000, 'scrollTop=${r2.y}');
    check('フッターが画面に入っている', seen2 == 'yes', '$seen2');

    stdout.writeln('\n== 3. 下へ行くほど中身が増えるページ ==');
    await b.navigate(dataUrl(_lazy), waitMs: 1200);
    final r3 = await scrollToEnd(b, false);
    final blocks = await b.evaluate(
        "String(document.getElementById('c').children.length)");
    check('増えた分まで追いかけた', (int.tryParse(blocks ?? '0') ?? 0) >= 6,
        'ブロック数=$blocks / scrollTop=${r3.y}');

    stdout.writeln('\n== 一番上へ戻す ==');
    final r4 = await scrollToEnd(b, true);
    check('先頭へ戻った', r4.y == 0, 'scrollTop=${r4.y}');

    stdout.writeln('\n== 外のブラウザのスクショ ==');
    await b.navigate(dataUrl(_tall), waitMs: 1200);
    final png = await b.screenshotBase64();
    final bytes = png == null ? 0 : base64Decode(png).length;
    check('見えている分の PNG', bytes > 2000,
        '${(bytes / 1024).toStringAsFixed(0)} KB');

    final full = await b.screenshotBase64(fullPage: true);
    final fullBytes = full == null ? 0 : base64Decode(full).length;
    check('ページ全体の 1 枚はもっと大きい', fullBytes > bytes,
        '全体=${(fullBytes / 1024).toStringAsFixed(0)} KB / '
        '見えている分=${(bytes / 1024).toStringAsFixed(0)} KB');

    final clipped =
        await b.screenshotBase64(clip: (x: 0, y: 0, w: 200, h: 120));
    final clipBytes = clipped == null ? 0 : base64Decode(clipped).length;
    check('範囲を指定すると小さくなる', clipBytes > 100 && clipBytes < bytes,
        '範囲=${(clipBytes / 1024).toStringAsFixed(1)} KB');
  } catch (e) {
    check('例外が出ていない', false, '$e');
  } finally {
    await b?.closeQuietly();
  }

  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
