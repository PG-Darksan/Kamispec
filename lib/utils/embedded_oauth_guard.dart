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

bool isBlockedEmbeddedOAuthUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null) return false;
  final host = _normalizedHost(uri);
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
