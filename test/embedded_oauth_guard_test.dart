import 'package:flutter_test/flutter_test.dart';
import 'package:mindmap_app/utils/embedded_oauth_guard.dart';

void main() {
  group('isBlockedEmbeddedOAuthUrl', () {
    test('matches only the parsed OAuth host', () {
      expect(
        isBlockedEmbeddedOAuthUrl('https://accounts.google.com/o/oauth2/v2/auth'),
        isTrue,
      );
      expect(
        isBlockedEmbeddedOAuthUrl('https://accounts.google.com./o/oauth2/auth'),
        isTrue,
      );
      expect(
        isBlockedEmbeddedOAuthUrl('https://accounts.google.com.example.com/'),
        isFalse,
      );
      expect(
        isBlockedEmbeddedOAuthUrl(
          'https://example.com/?next=https://accounts.google.com/',
        ),
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
