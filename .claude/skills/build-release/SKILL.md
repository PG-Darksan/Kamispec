---
name: build-release
description: Build the Windows desktop and Android APK RELEASE artifacts sequentially — runs `flutter build windows --release` then `flutter build apk --release`, each with `--dart-define-from-file=env.json -v`. Use when you want to produce both release builds in one go.
disable-model-invocation: true
allowed-tools: Bash(flutter build:*)
---

# Build release: Windows + Android APK (sequential)

Run the two release builds **one after the other** — Windows first, then the
Android APK — each with the `env.json` compile-time defines and verbose output.

## Before building
- Confirm `env.json` exists in the project root. It holds the Firebase / Gemini /
  billing keys read at compile time via `--dart-define-from-file`. If it's
  missing, stop and tell the user (the build needs it; it is git-ignored).
- Work from the project root (`c:\Users\Study\mindmap_app_out`).

## Run these, in order
1. Windows release:
   ```
   flutter build windows --release --dart-define-from-file=env.json -v
   ```
2. After the Windows build has fully finished, Android APK release:
   ```
   flutter build apk --release --dart-define-from-file=env.json -v
   ```

These `--release` builds are slow and a cold APK/Gradle build can exceed the
10-minute foreground limit, so run **each one in the background** and wait for it
to finish before starting the next. Run the APK build even if the Windows build
failed (the failure may be platform-specific), so the user sees the result of
both.

## Report when done
Give a short summary — do **not** paste the whole verbose `-v` log:
- ✅ / ❌ for each of the two builds.
- Output paths on success:
  - Windows: `build\windows\x64\runner\Release\` (`mindmap_app.exe` + DLLs)
  - APK: `build\app\outputs\flutter-apk\app-release.apk`
- For a failure, quote only the key error lines (Dart compile / CMake / Gradle)
  plus a one-line likely cause.

This skill only builds and reports — do not modify any source files.
