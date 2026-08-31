// ログイン後にブラウザへ出す案内ページを確かめる。
//
//   dart run tool/auth_page_check.dart
//
// = ユーザー報告「どこにも遷移しないのにグルグル読み込みループが出る」。
//   回るしるしは、 この後ページが本当に変わる時 (決済へ進む時) だけ。
//
// ★ ネットには出ない。 ページの中身を組み立てて確かめるだけ。
import 'dart:io';

import 'package:mindmap_app/services/auth_result_page.dart';

int fails = 0;
void check(String what, bool ok, [String extra = '']) {
  stdout.writeln(
      '  ${ok ? "ok  " : "FAIL"} $what${extra.isEmpty ? '' : '  ($extra)'}');
  if (!ok) fails++;
}

void main() {
  stdout.writeln('== ふつうのログイン (この後どこにも移らない) ==');
  final plain = buildAuthResultPage(
    true,
    const GoogleAuthResultText(
      okTitle: 'ログインできました',
      okBody: 'このタブを閉じて、 HisatorNotebook に戻ってください。',
      cancelTitle: 'ログインを中止しました',
      cancelBody: 'このタブを閉じて、 もう一度お試しください。',
    ),
  );
  check('回るしるしを出さない', !plain.contains('class="dot"'));
  check('案内は出ている', plain.contains('ログインできました'));
  check('閉じてと書いてある', plain.contains('タブを閉じて'));

  stdout.writeln('\n== 決済へ進むログイン (この後ページが変わる) ==');
  final wait = buildAuthResultPage(
    true,
    const GoogleAuthResultText(
      okTitle: 'ログインできました',
      okBody: 'このまま少しお待ちください。',
      cancelTitle: 'ログインを中止しました',
      cancelBody: 'このタブを閉じて、 もう一度お試しください。',
      waiting: true,
    ),
  );
  check('回るしるしを出す', wait.contains('class="dot"'));

  stdout.writeln('\n== 中止した時 ==');
  final cancel = buildAuthResultPage(
    false,
    const GoogleAuthResultText(
      okTitle: 'ログインできました',
      okBody: 'このタブを閉じて、 HisatorNotebook に戻ってください。',
      cancelTitle: 'ログインを中止しました',
      cancelBody: 'このタブを閉じて、 もう一度お試しください。',
      waiting: true,
    ),
  );
  check('中止では回るしるしを出さない', !cancel.contains('class="dot"'));
  check('中止の案内が出ている', cancel.contains('中止しました'));

  stdout.writeln('\n${fails == 0 ? "ALL PASS" : "$fails FAILED"}');
  exit(fails == 0 ? 0 : 1);
}
