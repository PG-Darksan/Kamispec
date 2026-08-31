// ログインの後、 ブラウザのタブに出す案内ページ。
//
// ★ 切り出してある理由: 「回るしるし (グルグル) を出す・出さない」 を
//   道具から確かめられるようにするため (tool/auth_page_check.dart)。
//   ここは Flutter に依らない (= 素の Dart で動かせる)。
library;

/// 案内ページに出す文言。
class GoogleAuthResultText {
  /// `<html lang="...">` に入れる言語コード。
  final String lang;
  final String okTitle;
  final String okBody;
  final String cancelTitle;
  final String cancelBody;

  /// この後、 このページが勝手に別の画面へ変わるか。
  ///
  /// ★ 回るしるし (グルグル) を出すのは、 これが真の時だけ。
  ///   遷移しないのに回り続けると、 何かを待っているように見えて、
  ///   閉じてよいのか分からなくなる
  ///   (= ユーザー報告: どこにも遷移しないのにグルグルが出る)。
  final bool waiting;

  const GoogleAuthResultText({
    this.lang = 'ja',
    required this.okTitle,
    required this.okBody,
    required this.cancelTitle,
    required this.cancelBody,
    this.waiting = false,
  });
}

/// 案内ページの HTML を組み立てる。
String buildAuthResultPage(bool ok, GoogleAuthResultText? txt) {
  final lang = txt?.lang ?? 'ja';
  final title = ok
      ? (txt?.okTitle ?? 'ログインできました')
      : (txt?.cancelTitle ?? 'ログインを中止しました');
  final body = ok
      ? (txt?.okBody ?? 'このタブを閉じて、 HisatorNotebook に戻ってください。')
      : (txt?.cancelBody ?? 'このタブを閉じて、 もう一度お試しください。');
  String esc(String v) => v
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  // ★ この後実際に画面が変わる時だけ、 回るしるしを出す。
  final spinner = ok && (txt?.waiting ?? false) ? '<div class="dot"></div>' : '';
  return '''
<!doctype html><html lang="${esc(lang)}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<style>
 body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;
      background:#12121c;color:#fff;display:flex;min-height:100vh;
      align-items:center;justify-content:center;margin:0}
 .card{text-align:center;padding:40px 48px;background:#1e1e32;
       border-radius:16px;box-shadow:0 8px 40px rgba(0,0,0,.4);
       max-width:420px}
 h1{font-size:20px;margin:0 0 12px}
 p{font-size:14px;color:#b0b0c0;margin:0;line-height:1.7}
 .dot{width:26px;height:26px;margin:0 auto 18px;border-radius:50%;
      border:3px solid rgba(255,255,255,.18);border-top-color:#4FC3F7;
      animation:spin 900ms linear infinite}
 @keyframes spin{to{transform:rotate(360deg)}}
</style></head><body>
<div class="card">$spinner<h1>${esc(title)}</h1><p>${esc(body)}</p></div>
</body></html>''';
}
