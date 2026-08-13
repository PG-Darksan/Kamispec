import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/utils/embedded_oauth_guard.dart';

void main() {
  group('isBlockedEmbeddedOAuthUrl', () {
    test('matches only the parsed OAuth host', () {
      // Microsoft/Apple sign-in is refused by every embedded web view.
      expect(
        isBlockedEmbeddedOAuthUrl('https://login.microsoftonline.com/common/'),
        isTrue,
      );
      expect(
        isBlockedEmbeddedOAuthUrl('https://login.live.com./oauth20_authorize'),
        isTrue,
      );
      expect(
        isBlockedEmbeddedOAuthUrl('https://appleid.apple.com/auth/authorize'),
        isTrue,
      );
      // A look-alike host must not be treated as the real OAuth host.
      expect(
        isBlockedEmbeddedOAuthUrl('https://login.live.com.example.com/'),
        isFalse,
      );
      expect(
        isBlockedEmbeddedOAuthUrl(
          'https://example.com/?next=https://login.live.com/',
        ),
        isFalse,
      );
    });

    test('allows Google sign-in on desktop web views', () {
      // These tests run on the Dart VM (desktop), where the app embeds
      // WebView2 — a real Edge that Google accepts. Blocking it here made
      // the AI panel bounce back to the service page on "sign in".
      expect(
        isBlockedEmbeddedOAuthUrl(
            'https://accounts.google.com/o/oauth2/v2/auth'),
        isFalse,
      );
      expect(
        isBlockedEmbeddedOAuthUrl('https://accounts.google.com./o/oauth2/auth'),
        isFalse,
      );
      // Still not a "safe external service" target, so the handoff helpers
      // never navigate to it directly.
      expect(
        isSafeExternalServiceUrl('https://accounts.google.com/o/oauth2/auth'),
        isFalse,
      );
    });
  });

  group('isSafeExternalServiceUrl', () {
    test('accepts HTTPS pages for supported services', () {
      expect(isSafeExternalServiceUrl('https://chatgpt.com/'), isTrue);
      expect(
        isSafeExternalServiceUrl('https://www.perplexity.ai/search/example'),
        isTrue,
      );
    });

    test('rejects insecure, credentialed, broker, and unrelated URLs', () {
      expect(isSafeExternalServiceUrl('http://chatgpt.com/'), isFalse);
      expect(isSafeExternalServiceUrl('https://user@chatgpt.com/'), isFalse);
      expect(isSafeExternalServiceUrl('https://auth.openai.com/authorize'), isFalse);
      expect(isSafeExternalServiceUrl('https://chatgpt.com.example.com/'), isFalse);
      expect(isSafeExternalServiceUrl('https://example.com/'), isFalse);
    });
  });
}
