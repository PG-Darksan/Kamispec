// 依頼文から「どのブラウザの話か」 を拾う判定を確かめる。
//
//   dart run tool/browser_name_check.dart
//
// = 点検で見つかった「ブラウザと無関係な依頼が外部ブラウザ起動に化ける」
//   (例: 「オペラを見に行く予定を立ち上げて」) を防げているかの裏取り。
//
// ★ 判定そのものは web_automation_panel.dart の中の private なので、
//   同じ規則をここに写して確かめる。 規則を直す時は両方直すこと。
import 'dart:io';

String? browserNameIn(String request) {
  final r = request.toLowerCase();
  const context = [
    'ブラウザ', 'browser', '立ち上げ', '起動', '開い', '開く',
    'url', 'http', 'タブ', 'サイト', 'ページ', 'ログイン', '検索',
  ];
  final looksBrowser = context.any(r.contains);
  bool word(String w) =>
      RegExp(r'(^|[^a-z0-9])' + w + r'([^a-z0-9]|$)').hasMatch(r);
  const latin = ['chrome', 'edge', 'brave', 'vivaldi', 'opera'];
  for (final n in latin) {
    if (word(n) && looksBrowser) return n;
  }
  if (r.contains('クローム') || r.contains('グーグルクローム')) return 'chrome';
  if (r.contains('エッジ') && looksBrowser) return 'edge';
  const generic = [
    '外のブラウザ', '外部ブラウザ', '別のブラウザ', 'ブラウザアプリ',
    'パソコンのブラウザ', 'pcのブラウザ', 'pc のブラウザ',
  ];
  if (generic.any(r.contains)) return '';
  return null;
}

int fails = 0;
void expect(String request, String? want) {
  final got = browserNameIn(request);
  final ok = got == want;
  if (!ok) fails++;
  stdout.writeln('  ${ok ? "ok  " : "FAIL"} ${want == null ? "拾わない" : (want.isEmpty ? "名前なし" : want)}'
      '  ←「$request」${ok ? '' : '  (実際: ${got ?? "null"})'}');
}

void main() {
  stdout.writeln('== 拾ってほしい ==');
  expect('chrome立ち上げてhttps://example.com のスクショ撮ってきて', 'chrome');
  expect('Chrome で検索して', 'chrome');
  expect('クロームで開いて', 'chrome');
  expect('edgeを起動してページを見て', 'edge');
  expect('エッジでログインして', 'edge');
  expect('brave でこのサイトを開いて', 'brave');
  expect('opera を立ち上げて', 'opera');
  expect('外のブラウザで開いて', '');
  expect('パソコンのブラウザでこのURLを開いて', '');

  stdout.writeln('\n== 拾ってはいけない ==');
  expect('オペラを見に行く予定を立ち上げて', null);
  expect('エッジの効いたデザインを考えて', null);
  expect('braveryについて調べて', null);
  expect('chromebookの値段を調べて', null);
  expect('acknowledgeの意味を教えて', null);
  expect('メモ帳を立ち上げて文章を書いて', null);
  expect('今日の予定をまとめて', null);
  expect('この画像を編集して', null);

  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
