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

class GoogleAuth {
  GoogleAuth._();

  /// 生年月日・性別を読むための追加の許可 (= ユーザー要望: 年齢や性別を
  /// 分析に使いたい)。
  ///
  /// ★ この 2 つは Google の「機密スコープ」。 一般公開するには Google の
  ///   審査 (OAuth 検証) が要る。 審査前はテストユーザーだけが許可でき、
  ///   それ以外の人には同意画面でブロックされる。 そのため、 ふだんの
  ///   ログインには含めず、 必要な時だけ追加で聞く形にしている
  ///   (= 失敗してもログインそのものは壊れない)。
  static const List<String> profileDetailScopes = [
    'https://www.googleapis.com/auth/user.birthday.read',
    'https://www.googleapis.com/auth/user.gender.read',
    'https://www.googleapis.com/auth/user.addresses.read',
  ];

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
  static Future<GoogleSignInResult?> signIn({
    VoidCallback? onWaiting,
    Duration timeout = const Duration(minutes: 3),
    List<String> extraScopes = const [],
    bool includeGrantedScopes = false,
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
        final ok = q['state'] == state && (q['code']?.isNotEmpty ?? false);
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(_resultPage(ok));
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

  /// ブラウザに出す「戻ってください」 の案内。
  static String _resultPage(bool ok) {
    final title = ok ? 'ログインできました' : 'ログインを中止しました';
    final body = ok
        ? 'このタブを閉じて、 HisatorNotebook に戻ってください。'
        : 'このタブを閉じて、 もう一度お試しください。';
    return '''
<!doctype html><html lang="ja"><head><meta charset="utf-8">
<title>$title</title>
<style>
 body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;
      background:#12121c;color:#fff;display:flex;min-height:100vh;
      align-items:center;justify-content:center;margin:0}
 .card{text-align:center;padding:40px 48px;background:#1e1e32;
       border-radius:16px;box-shadow:0 8px 40px rgba(0,0,0,.4)}
 h1{font-size:20px;margin:0 0 12px}
 p{font-size:14px;color:#b0b0c0;margin:0}
</style></head><body>
<div class="card"><h1>$title</h1><p>$body</p></div>
</body></html>''';
  }
}
