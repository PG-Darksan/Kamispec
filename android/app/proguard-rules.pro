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
