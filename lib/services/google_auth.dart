import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Google アカウントでのログイン (= ユーザー要望: 同じ Google アカウントで
/// ログインしている端末の間で、 有料プランやクラウド使用量を共有する)。
///
/// 仕組みは「ループバック方式」。 アプリの中にログイン画面を持たず、
/// ふだん使っているブラウザで Google のログイン画面を開き、 その結果を
/// 127.0.0.1 で待ち受けて受け取る。 埋め込みブラウザでの Google ログインは
/// Google 自身が拒否するので、 この形にしている
/// (`lib/utils/embedded_oauth_guard.dart` と同じ理由)。
///
/// 合言葉 (client secret) は「インストール型アプリ」 用のもので、 Google の
/// 仕様上ひみつにはできない。 代わりに PKCE (使い捨ての符号) で、 横取り
/// されても他人が使えないようにしている。
/// ログインで受け取ったもの。
/// [idToken] は Firebase の利用者に引き換えるための証明書、
/// [accessToken] は Google の API (People API など) を呼ぶための鍵。
class GoogleSignInResult {
  final String idToken;
  final String accessToken;
  final String grantedScopes;
  const GoogleSignInResult({
    required this.idToken,
    this.accessToken = '',
    this.grantedScopes = '',
  });
}

/// ログインが終わった直後にブラウザへ出す案内。
///
/// 中身はアプリ側 (翻訳を持っている所) から渡す。 ここで文字を持つと
/// 日本語決め打ちになり、 海外の利用者に読めないため
/// (= ユーザー要望: 契約まわりは色々な言語で出す)。
class GoogleAuthResultText {
  /// `<html lang="...">` に入れる言語コード。
  final String lang;
  final String okTitle;
  final String okBody;
  final String cancelTitle;
  final String cancelBody;
  const GoogleAuthResultText({
    this.lang = 'ja',
    required this.okTitle,
    required this.okBody,
    required this.cancelTitle,
    required this.cancelBody,
  });
}

class GoogleAuth {
  GoogleAuth._();

  // 旧 `profileDetailScopes` (生年月日 / 性別 / 住所を読む機密スコープ) は
  //   廃止 (= ユーザー要望: 自分自身のアカウント情報を取りに行っても意味が
  //   無い)。 機密スコープを一切要求しなくなったので、 Google の OAuth 審査
  //   (検証) も不要になった。 `signIn` の [extraScopes] の仕組みだけ残して
  //   ある (将来また追加の許可が要る時のため)。

  /// Google Cloud コンソールで作る「デスクトップアプリ」 の認証情報。
  /// 未設定ならログイン機能そのものを出さない。
  static const String clientId =
      String.fromEnvironment('GOOGLE_OAUTH_CLIENT_ID', defaultValue: '');
  static const String clientSecret =
      String.fromEnvironment('GOOGLE_OAUTH_CLIENT_SECRET', defaultValue: '');

  static bool get isConfigured => clientId.isNotEmpty;

  /// この端末でログイン画面を出せるか。 ブラウザを開いて 127.0.0.1 で
  /// 受け取れる環境が要る (Windows / Android / macOS / Linux)。
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isWindows ||
        Platform.isAndroid ||
        Platform.isMacOS ||
        Platform.isLinux;
  }

  static String _randomUrlSafe(int bytes) {
    final rand = Random.secure();
    final data = List<int>.generate(bytes, (_) => rand.nextInt(256));
    return base64Url.encode(data).replaceAll('=', '');
  }

  /// ログインさせて Google の ID トークン (と API 用の鍵) を返す。
  /// 利用者が閉じた / 断った場合は null。
  ///
  /// [onWaiting] はブラウザを開いた直後に呼ばれる (画面に案内を出す用)。
  /// [extraScopes] を渡すと、 その許可も一緒に聞く (= 生年月日・性別)。
  /// [includeGrantedScopes] true なら今まで許した分もそのまま持ち越す
  /// (= 追加の許可だけを聞き直す「段階的な同意」)。
  /// [resultText] ブラウザに出す案内。 省略すると日本語の既定文になる。
  static Future<GoogleSignInResult?> signIn({
    VoidCallback? onWaiting,
    Duration timeout = const Duration(minutes: 3),
    List<String> extraScopes = const [],
    bool includeGrantedScopes = false,
    GoogleAuthResultText? resultText,
  }) async {
    if (!isConfigured) {
      throw Exception('GOOGLE_OAUTH_CLIENT_ID が設定されていません');
    }

    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final redirectUri = 'http://127.0.0.1:${server.port}';

      // PKCE: 使い捨ての符号を作り、 その要約だけを先に Google へ預ける。
      final verifier = _randomUrlSafe(48);
      final challenge = base64Url
          .encode(sha256.convert(utf8.encode(verifier)).bytes)
          .replaceAll('=', '');
      final state = _randomUrlSafe(16);

      final scope =
          ['openid', 'email', 'profile', ...extraScopes].join(' ');
      final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': scope,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        // 毎回アカウントを選べるように (端末を渡す時に別人が入らないよう)。
        // 追加の許可を聞く時は、 今のアカウントのまま同意画面だけ出す。
        'prompt': includeGrantedScopes ? 'consent' : 'select_account',
        if (includeGrantedScopes) 'include_granted_scopes': 'true',
      });

      if (!await launchUrl(authUrl, mode: LaunchMode.externalApplication)) {
        throw Exception('ブラウザを開けませんでした');
      }
      onWaiting?.call();

      final completer = Completer<String?>();
      late final StreamSubscription<HttpRequest> sub;
      sub = server.listen((req) async {
        final q = req.uri.queryParameters;
        // ── 本物のコールバック以外は無視して待ち続ける (PKCE 点検で強化) ──
        // ブラウザの favicon.ico 取得や、 ポートスキャン等の無関係な
        // アクセスが 1 回来ただけでログイン待ちが打ち切られていた。
        // state 不一致 (= 第三者が偽のコードを差し込もうとした) も同様に
        // 捨てて、 正しい state の応答だけを受け付ける。
        final isCallback = q.containsKey('code') || q.containsKey('error');
        if (!isCallback || q['state'] != state) {
          try {
            req.response.statusCode = HttpStatus.notFound;
            await req.response.close();
          } catch (_) {}
          return;
        }
        final ok = q['code']?.isNotEmpty ?? false;
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_resultPage(ok, resultText));
        await req.response.close();
        if (!completer.isCompleted) {
          completer.complete(ok ? q['code'] : null);
        }
        await sub.cancel();
      }, onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      });

      final code = await completer.future.timeout(timeout, onTimeout: () => null);
      if (code == null) return null;

      // 受け取った引換券を ID トークンに交換する。
      final res = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        body: {
          'code': code,
          'client_id': clientId,
          if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
          'redirect_uri': redirectUri,
          'grant_type': 'authorization_code',
          'code_verifier': verifier,
        },
      ).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw Exception('Google 認証に失敗しました (${res.statusCode}) ${res.body}');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final idToken = data['id_token'] as String?;
      if (idToken == null || idToken.isEmpty) {
        throw Exception('Google から ID トークンが返りませんでした');
      }
      return GoogleSignInResult(
        idToken: idToken,
        accessToken: (data['access_token'] as String?) ?? '',
        grantedScopes: (data['scope'] as String?) ?? '',
      );
    } finally {
      await server?.close(force: true);
    }
  }

  /// ブラウザに出す案内。
  ///
  /// ★ 用件によって文言を変える (= ユーザー報告: 決済に進む時も
  ///   「このタブを閉じて戻ってください」 と出るのに、 待っていると
  ///   勝手に料金プランの画面へ変わって戸惑う)。 決済へ進む時は
  ///   アプリ側から「このまま少しお待ちください」 の文言を渡す。
  static String _resultPage(bool ok, GoogleAuthResultText? txt) {
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
    // 成功時だけ、 待ってもらう合図として回るしるしを出す。
    final spinner = ok
        ? '<div class="dot"></div>'
        : '';
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
}
