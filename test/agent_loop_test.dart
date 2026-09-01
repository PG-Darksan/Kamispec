// エージェントが同じ所で足踏みしていないかの見張り。
//
//   flutter test test/agent_loop_test.dart
//
// = ユーザー報告「AI エージェントが止まらずに同じフローをひたすら
//   作り続ける」。 画面が変わっていないのに次の一手も同じなら、 何度
//   やっても結果は同じなので、 そこで打ち切る。
//
// あわせて「この手順にインターネットが要るか」 の見分けも確かめる
// (= ユーザー要望: つながっていない時に案内を出す)。
import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/widgets/web_automation_panel.dart';

WebAutoStep step(
  WebAutoKind kind, {
  String text = '',
  String selector = '',
  String scrollDir = '',
  List<WebAutoStep>? children,
}) =>
    WebAutoStep(
      kind: kind,
      text: text,
      selector: selector,
      scrollDir: scrollDir,
      children: children,
    );

void main() {
  group('AgentProgressGuard', () {
    test('同じ画面で同じ手順を出したら、 足踏みと分かる', () {
      final g = AgentProgressGuard();
      final plan = [step(WebAutoKind.openBrowser, text: 'chrome')];
      const screen = 'url: about:blank / title: -';

      expect(g.advance(plan, screen), isTrue, reason: '1 回目は進む');
      expect(g.advance(plan, screen), isFalse, reason: '2 回目は足踏み');
    });

    test('画面が変わっていれば、 同じ手順でも進んでいるとみなす', () {
      // 端まで送るを繰り返して下へ下りていく形 (= ふつうの使い方)。
      final g = AgentProgressGuard();
      final plan = [step(WebAutoKind.scrollTo, scrollDir: 'bottom')];

      expect(g.advance(plan, 'scrollY: 0 / pageH: 9000'), isTrue);
      expect(g.advance(plan, 'scrollY: 2400 / pageH: 9000'), isTrue);
      expect(g.advance(plan, 'scrollY: 4800 / pageH: 9000'), isTrue);
      // もう動かなくなったら止める。
      expect(g.advance(plan, 'scrollY: 4800 / pageH: 9000'), isFalse);
    });

    test('画面が同じでも、 別の手なら進む', () {
      final g = AgentProgressGuard();
      const screen = 'url: https://example.com / title: れい';

      expect(g.advance([step(WebAutoKind.click, text: 'ログイン')], screen),
          isTrue);
      expect(
          g.advance(
              [step(WebAutoKind.type, text: 'hisatasan1@gmail.com')], screen),
          isTrue);
      expect(
          g.advance(
              [step(WebAutoKind.type, text: 'hisatasan1@gmail.com')], screen),
          isFalse);
    });

    test('手の見分けは中身まで見る', () {
      final a = AgentProgressGuard.planSignature(
          [step(WebAutoKind.click, text: 'つぎへ')]);
      final b = AgentProgressGuard.planSignature(
          [step(WebAutoKind.click, text: 'もどる')]);
      final c = AgentProgressGuard.planSignature([
        step(WebAutoKind.click, text: 'つぎへ'),
        step(WebAutoKind.wait),
      ]);

      expect(a == b, isFalse, reason: '文字が違えば別の手');
      expect(a == c, isFalse, reason: '手数が違えば別の手');
    });

    test('画面の末尾だけが毎回変わっても、 足踏みと分かる', () {
      // 時計のように毎回変わる文字が末尾に混ざる画面でも見分けられる。
      final g = AgentProgressGuard();
      final head = 'x' * 420;
      final plan = [step(WebAutoKind.click, text: 'ログイン')];

      expect(g.advance(plan, '$head 12:00:01'), isTrue);
      expect(g.advance(plan, '$head 12:00:09'), isFalse);
    });
  });

  group('autoStepsNeedNetwork', () {
    test('通信が要る手順を見分ける', () {
      expect(
          autoStepsNeedNetwork(
              [step(WebAutoKind.open, text: 'https://a.example')]),
          isTrue);
      expect(
          autoStepsNeedNetwork([step(WebAutoKind.openBrowser, text: 'chrome')]),
          isTrue);
      expect(autoStepsNeedNetwork([step(WebAutoKind.download, text: '保存')]),
          isTrue);
      expect(
          autoStepsNeedNetwork(
              [step(WebAutoKind.openExternal, text: 'https://a.example')]),
          isTrue);
    });

    test('画面の中だけで済む手順は、 通信が要らない', () {
      expect(
          autoStepsNeedNetwork(
              [step(WebAutoKind.wait), step(WebAutoKind.type, text: 'あ')]),
          isFalse);
    });

    test('繰り返しの中身も見る', () {
      expect(
          autoStepsNeedNetwork([
            step(WebAutoKind.loop, children: [
              step(WebAutoKind.wait),
              step(WebAutoKind.open, text: 'https://a.example'),
            ])
          ]),
          isTrue);
      expect(
          autoStepsNeedNetwork([
            step(WebAutoKind.loop, children: [step(WebAutoKind.shot)])
          ]),
          isFalse);
    });
  });

  group('accountFromRequest', () {
    test('メールが書いてあれば、 それを使う', () {
      expect(
          accountFromRequest(
              'chromeをhisatasan1@gmail.comの垢で立ち上げて', const []),
          'hisatasan1@gmail.com');
    });

    test('呼び名が文の中にあれば、 それを使う', () {
      expect(accountFromRequest('浩靖のアカウントで開いて', const ['浩靖', '仕事']),
          '浩靖');
    });

    test('メールは呼び名より先', () {
      expect(
          accountFromRequest('浩靖の a@b.com で開いて', const ['浩靖']), 'a@b.com');
    });

    test('何も書いていなければ空', () {
      expect(accountFromRequest('一番下までスクロールして', const ['浩靖']), '');
    });

    test('1 文字の呼び名はたまたま混ざるので使わない', () {
      expect(accountFromRequest('この画面を見て', const ['画']), '');
    });
  });

  group('requestWantsLogin', () {
    test('「ログインして」 はログインの合図', () {
      expect(requestWantsLogin('hisatasan1@gmail.com にログインして'), isTrue);
      expect(requestWantsLogin('サインインしてから開いて'), isTrue);
      expect(requestWantsLogin('please sign in to gmail'), isTrue);
    });

    test('「垢で立ち上げて」 だけならログインではない (= シークレット)', () {
      expect(
          requestWantsLogin(
              'chromeをhisatasan1@gmail.comの垢で立ち上げてスクロールして'),
          isFalse);
      expect(requestWantsLogin('一番下までスクロールして'), isFalse);
    });
  });
}
