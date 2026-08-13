import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// OAuth providers that intentionally reject sign-in from embedded web views.
///
/// Match parsed hosts exactly. A substring check would also match attacker-owned
/// hosts such as `accounts.google.com.example.com`.
const Set<String> _embeddedOAuthHosts = <String>{
  'accounts.google.com',
  'accounts.youtube.com',
  'login.microsoftonline.com',
  'login.live.com',
  'appleid.apple.com',
};

const Set<String> _externalHandoffServiceHosts = <String>{
  'chatgpt.com',
  'openai.com',
  'claude.ai',
  'anthropic.com',
  'gemini.google.com',
  'chat.deepseek.com',
  'grok.com',
  'grok.x.ai',
  'perplexity.ai',
  'copilot.microsoft.com',
  'youtube.com',
  'www.google.com',
  'www.google.co.jp',
};

String _normalizedHost(Uri uri) =>
    uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');

bool _isHostOrSubdomain(String host, String allowedHost) =>
    host == allowedHost || host.endsWith('.$allowedHost');

/// Google sign-in is only rejected by the *mobile* system web views
/// (Android/iOS send an embedded-browser user agent that Google refuses).
///
/// On Windows the app embeds WebView2, which is Edge itself and reports a
/// normal desktop user agent, so `accounts.google.com` works there. Treating
/// it as blocked made the view bounce straight back to the service page the
/// moment the user pressed "sign in" — reported as "the screen refreshes and
/// goes back" when signing in to Gemini from the AI panel.
bool get _mobileWebViewRejectsGoogleSignIn {
  if (kIsWeb) return false;
  return Platform.isAndroid || Platform.isIOS;
}

const Set<String> _googleSignInHosts = <String>{
  'accounts.google.com',
  'accounts.youtube.com',
};

bool isBlockedEmbeddedOAuthUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null) return false;
  final host = _normalizedHost(uri);
  if (_googleSignInHosts.contains(host) &&
      !_mobileWebViewRejectsGoogleSignIn) {
    return false;
  }
  return _embeddedOAuthHosts.contains(host);
}

bool isSafeExternalServiceUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.userInfo.isNotEmpty ||
      isBlockedEmbeddedOAuthUrl(rawUrl)) {
    return false;
  }
  final host = _normalizedHost(uri);
  final isAuthBroker = host == 'auth.openai.com' ||
      host == 'auth0.openai.com' ||
      host == 'auth.anthropic.com' ||
      host.endsWith('.auth0.com');
  return !isAuthBroker &&
      _externalHandoffServiceHosts
          .any((allowed) => _isHostOrSubdomain(host, allowed));
}
