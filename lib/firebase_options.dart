// このファイルは環境変数（--dart-define）で API キーを注入する設計です
// flutterfire configure で再生成すると上書きされるので、生成後にこのファイルで置き換えてください
//
// ビルド例:
//   flutter build windows --dart-define-from-file=env.json
//   flutter build apk --dart-define-from-file=env.json
//
// env.json の例:
// {
//   "FIREBASE_PROJECT_ID": "mindmap-b6115",
//   "FIREBASE_MESSAGING_SENDER_ID": "767346963841",
//   "FIREBASE_STORAGE_BUCKET": "mindmap-b6115.firebasestorage.app",
//   "FIREBASE_AUTH_DOMAIN": "mindmap-b6115.firebaseapp.com",
//   "FIREBASE_API_KEY_ANDROID": "AIza...",
//   "FIREBASE_APP_ID_ANDROID": "1:...:android:...",
//   "FIREBASE_API_KEY_WINDOWS": "AIza...",
//   "FIREBASE_APP_ID_WINDOWS": "1:...:web:...",
//   "FIREBASE_MEASUREMENT_ID": "G-..."
// }
// ※ GEMINI_API_KEY はビルドに含めない (BYOK)。 AI キーは利用者が設定画面で
//    自分で入力する方式に変更したため、 env.json / dart-define には不要。

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.macOS:
        return macos;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions: このプラットフォームはまだ設定されていません。\n'
          'flutterfire configure を実行して firebase_options.dart を生成してください。',
        );
    }
  }

  // ── 共通プロジェクト情報（環境変数）──
  static const String _projectId =
      String.fromEnvironment('FIREBASE_PROJECT_ID', defaultValue: '');
  static const String _messagingSenderId =
      String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID', defaultValue: '');
  static const String _storageBucket =
      String.fromEnvironment('FIREBASE_STORAGE_BUCKET', defaultValue: '');
  static const String _authDomain =
      String.fromEnvironment('FIREBASE_AUTH_DOMAIN', defaultValue: '');
  static const String _iosBundleId =
      String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID',
          defaultValue: 'com.example.mindmapApp');

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_WEB', defaultValue: ''),
    appId: String.fromEnvironment('FIREBASE_APP_ID_WEB', defaultValue: ''),
    messagingSenderId: _messagingSenderId,
    projectId: _projectId,
    authDomain: _authDomain,
    storageBucket: _storageBucket,
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_ANDROID', defaultValue: ''),
    appId: String.fromEnvironment('FIREBASE_APP_ID_ANDROID', defaultValue: ''),
    messagingSenderId: _messagingSenderId,
    projectId: _projectId,
    storageBucket: _storageBucket,
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_IOS', defaultValue: ''),
    appId: String.fromEnvironment('FIREBASE_APP_ID_IOS', defaultValue: ''),
    messagingSenderId: _messagingSenderId,
    projectId: _projectId,
    storageBucket: _storageBucket,
    iosBundleId: _iosBundleId,
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_WINDOWS', defaultValue: ''),
    appId: String.fromEnvironment('FIREBASE_APP_ID_WINDOWS', defaultValue: ''),
    messagingSenderId: _messagingSenderId,
    projectId: _projectId,
    authDomain: _authDomain,
    storageBucket: _storageBucket,
    measurementId:
        String.fromEnvironment('FIREBASE_MEASUREMENT_ID', defaultValue: ''),
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY_MACOS', defaultValue: ''),
    appId: String.fromEnvironment('FIREBASE_APP_ID_MACOS', defaultValue: ''),
    messagingSenderId: _messagingSenderId,
    projectId: _projectId,
    storageBucket: _storageBucket,
    iosBundleId: _iosBundleId,
  );
}
