# ─────────────────────────────────────────────────────────────────────────
# Kamispec ProGuard / R8 keep ルール
# build.gradle で minifyEnabled true + shrinkResources true を有効化したため、
# reflection を使う Android 側ライブラリの keep ルールをここに集約する。
# (Dart コードは R8 の対象外なので、 純粋な Dart パッケージ ―― excel / csv /
#  youtube_explode_dart 等 ―― はここに書く必要はない。)
# ─────────────────────────────────────────────────────────────────────────

# ── flutter_local_notifications (内部で GSON によるリフレクションを使用) ──
-keep class com.dexterous.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# ── GSON 本体 ──
-keep class com.google.gson.** { *; }
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
# @SerializedName を付けたフィールドはリフレクション対象なので残す
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
-dontwarn sun.misc.**

# ── audio_service (Foreground Service / MediaSession) ──
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }

# ── 一般的な保険 (列挙体や native メソッドはリフレクションされがち) ──
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}
-keepclasseswithmembernames class * {
    native <methods>;
}

# ── Flutter プラグイン全般を keep ──
# (= ユーザー報告: release で SharedPreferences が読めず初回設定が出ない /
#  YouTube WebView が空)。 R8 が各プラグインの Pigeon / MethodChannel の
#  native ハンドラ (setUp / onMethodCall 等) を strip すると、 起動時に
#  「channel-error」「MissingPluginException」 が出て SharedPreferences・
#  inappwebview 等が機能しなくなる。 プラグインクラスを丸ごと keep して防ぐ。
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**
# Pigeon が生成するチャンネル実装 (shared_preferences_android 等)
-keep class dev.flutter.pigeon.** { *; }
-keep class io.flutter.plugins.sharedpreferences.** { *; }
# flutter_inappwebview (Android WebView)
-keep class com.pichillilorenzo.** { *; }
-dontwarn com.pichillilorenzo.**

# ── ffmpeg_kit を keep ★最重要 (= release だけ各機能が動かない真因) ──
# この repo は fork 版 `ffmpeg_kit_flutter_new(_full)` を使っており、 実際の
#   パッケージは **com.antonkarpenko.ffmpegkit** (本家 com.arthenica ではない)。
# ffmpeg_kit のネイティブ .so は JNI_OnLoad の中で FindClass(
#   "com/.../ffmpegkit/...") + RegisterNatives を行う。 R8 がこれらの Java
#   クラスを難読化/除去すると FindClass が失敗し、 JNI_OnLoad が JNI_ERR を
#   返して `UnsatisfiedLinkError: Bad JNI version returned from JNI_OnLoad: 0`
#   になる。 すると FFmpegKit プラグイン登録が java.lang.Error を投げ、
#   GeneratedPluginRegistrant (各プラグインは catch(Exception) のみ) が Error を
#   拾えず registerWith 全体が中断 → shared_preferences 含む以降のプラグインが
#   すべて未登録 (channel-error) → SharedPreferences が読めず初回オンボーディング
#   非表示。 debug は R8 無しで難読化されないため再現しない。
# 対策: fork(antonkarpenko) と本家(arthenica) 両方のクラス・ネイティブメソッド
#   名を保持する (native .so がどちらの FQCN を FindClass しても通るように)。
-keep class com.antonkarpenko.** { *; }
-keepclassmembers class com.antonkarpenko.** { *; }
-keepnames class com.antonkarpenko.** { *; }
-dontwarn com.antonkarpenko.**
-keep class com.arthenica.** { *; }
-keepclassmembers class com.arthenica.** { *; }
-keepnames class com.arthenica.** { *; }
-dontwarn com.arthenica.**
