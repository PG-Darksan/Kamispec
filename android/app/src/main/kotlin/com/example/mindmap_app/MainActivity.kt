// ============================================================================
//  MainActivity.kt  ―  集中ロック (画面固定 / screen pinning) のネイティブ実装
// ============================================================================
//
//  置き場所:
//    android/app/src/main/kotlin/<あなたのパッケージのパス>/MainActivity.kt
//    例) android/app/src/main/kotlin/com/example/mindmap_app/MainActivity.kt
//
//  ■ なぜネイティブが必要か
//    Flutter (Dart) 側のオーバーレイ (_FocusLockOverlay) は「アプリの画面の上に
//    黒い全画面を被せているだけ」 なので、 ホームボタンや履歴ボタンを押されると
//    OS のホームに抜けられてしまう (= 他アプリが使えてしまう)。
//    ホーム/履歴ボタン自体をブロックするには、 Android の
//    「画面固定 (lock task / screen pinning)」 を使う必要があり、 これは
//    ネイティブ (Kotlin) からしか呼べない。 mind_map_screen.dart は
//    MethodChannel('app/lock') の startLock / stopLock を呼んでいるが、 その
//    受け側 (このファイル) が無いと MissingPluginException で握りつぶされ、
//    実際の画面固定は一切効いていなかった。 ← 今回の「抜け道」 の原因。
//
//  ■ 既に MainActivity.kt がある場合 (ほぼ必ずある)
//    丸ごと置き換えず、 以下を既存クラスにマージしてください:
//      ① import 群
//      ② companion object の LOCK_CHANNEL と lockRequested フィールド
//      ③ configureFlutterEngine の中身 (MethodChannel の設定)
//      ④ startScreenPinning / stopScreenPinning / onResume
//    package 行は必ず「既存の MainActivity.kt と同じ」 にしてください。
//
//  ■ 重要な前提・制限 (Play ストア配布の通常アプリの場合)
//    ・端末側で「画面固定 (screen pinning)」 が有効である必要がある
//      (設定 → セキュリティ → 画面固定 / アプリ固定)。 無効だと startLockTask()
//      は効かない (= 従来どおりオーバーレイのみ)。
//    ・Device Owner ではない通常アプリの startLockTask() は「ピン留めモード」 で、
//      初回などに OS の確認や通知が出ることがある。 ユーザーが [戻る]+[履歴]
//      長押しで自分でピン留め解除する余地は残る (これは OS の仕様で塞げない)。
//    ・WiFi/SMS/電話 ショートタットは「別アプリを開く」 ため、 開く瞬間だけ
//      stopLockTask() でピン留めを外す必要がある (ピン留め中は他アプリを起動
//      できないため)。 そのため外部アプリ滞在中〜ホームに居る一瞬は固定が
//      外れる。 アプリに戻った瞬間に onResume / Flutter 側の resumed ハンドラが
//      再固定するので、 「戻ってきたら必ず再ロック」 は担保される。
//    ・完全な KIOSK (一切抜けられない) が要るなら Device Owner 化が必要
//      (ADB か QR プロビジョニング)。 個人開発の一般配布では現実的でないため、
//      ここでは「ホーム/履歴ブロック + 復帰時の確実な再固定」 を狙う。
// ============================================================================

package com.example.mindmap_app // ★★★ 既存の MainActivity.kt と同じ package に変更 ★★★

import android.app.ActivityManager
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        private const val LOCK_CHANNEL = "app/lock"
        private const val CLIPBOARD_CHANNEL = "app/clipboard"
        private const val DEVICE_CHANNEL = "app/device"
        // ホーム画面ショートカット用 (= マップごとにアプリ風アイコンを作る)
        private const val SHORTCUT_CHANNEL = "app/shortcuts"
        private const val EXTRA_PAGE_ID = "mindmap_page_id"
    }

    /// 集中ロックが要求されている間 true。
    /// onResume での「アプリに戻ってきたら再固定」 判定に使う。
    private var lockRequested = false

    /// ショートカット (既に起動中にタップされた時) の通知用。
    private var shortcutChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // ── 起動必須プラグインを先に登録 (= release で初回設定が出ない問題の対策) ──
        // ★ ユーザー報告: release ビルドだけ初回の言語/TZ/ユーザー名設定が出ない。
        //   真因は、 ffmpeg_kit のネイティブ初期化が (特に x86_64 端末/エミュレータの
        //   release で) `UnsatisfiedLinkError: Bad JNI version returned from
        //   JNI_OnLoad` という **java.lang.Error** を投げること。
        //   GeneratedPluginRegistrant は各プラグイン登録を `catch (Exception)` でしか
        //   保護しておらず、 Error はそのまま素通りして registerWith 全体を中断させる。
        //   ffmpeg_kit はアルファベット順で shared_preferences より前に登録されるため、
        //   super.configureFlutterEngine に丸投げすると shared_preferences 等の以降の
        //   プラグインが未登録のままになり、 SharedPreferences が channel-error で
        //   読めず _isFirstLaunch が確定せず初回オンボーディングが出ない。
        // 対策: 起動に必須のプラグイン (設定/ファイルパス) を、 後続プラグインの
        //   致命的エラーに先んじて Throwable 安全に登録しておく。 こうすれば
        //   ffmpeg_kit が落ちても SharedPreferences は確実に使える。 既に登録済みの
        //   クラスは Flutter 側が二重登録を無視するため、 super 実行後も冪等。
        // (path_provider はこの repo の依存に無いので登録しない。
        //  shared_preferences が確実に登録されれば初回オンボーディングは出る。)
        safeAddPlugin(flutterEngine, "io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin")

        // 残りのプラグインは従来どおり自動登録。 本来は下の proguard keep
        //   (com.antonkarpenko) で ffmpeg_kit のロードが直り中断しなくなるが、
        //   万一 ffmpeg_kit が別要因で落ちても上の事前登録で SharedPreferences
        //   だけは生存する (二重の保険)。
        try {
            super.configureFlutterEngine(flutterEngine)
        } catch (t: Throwable) {
            android.util.Log.e(
                "MainActivity",
                "GeneratedPluginRegistrant が中断 (重要プラグインは登録済みのため続行)", t)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LOCK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // 集中ロック開始 / 復帰時の再固定 (Dart: _osLockStart / _reassertOsLock)
                    "startLock" -> {
                        lockRequested = true
                        startScreenPinning()
                        result.success(true)
                    }
                    // 集中ロック解除 / WiFi等を開くための一時解除 (Dart: _osLockStop / _launchWhileLocked)
                    "stopLock" -> {
                        // 注意: WiFi/SMS ショートカットからの一時解除でも呼ばれる。
                        //   その場合 Dart 側が外部アプリ起動 → 復帰時に startLock を
                        //   再度呼ぶので、 ここで lockRequested を false にしても
                        //   復帰時に true へ戻り、 再固定される。
                        lockRequested = false
                        stopScreenPinning()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CLIPBOARD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "readClipboardImage" -> result.success(readClipboardImage())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAndroidId" -> {
                        val id = Settings.Secure.getString(
                            contentResolver,
                            Settings.Secure.ANDROID_ID
                        ) ?: ""
                        result.success(id)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── ホーム画面ショートカット (マップごとのアプリ風アイコン) ──
        val sc = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, SHORTCUT_CHANNEL)
        shortcutChannel = sc
        sc.setMethodCallHandler { call, result ->
            when (call.method) {
                // ホーム画面にマップのピン留めショートカットを作成
                "pinMapShortcut" -> {
                    val pageId = call.argument<String>("pageId")
                    val label = call.argument<String>("label") ?: "Map"
                    if (pageId.isNullOrEmpty()) {
                        result.success(false)
                    } else {
                        result.success(pinMapShortcut(pageId, label))
                    }
                }
                "isPinSupported" -> {
                    result.success(
                        ShortcutManagerCompat.isRequestPinShortcutSupported(this))
                }
                // コールド起動時、 起動 intent の extra からページ ID を取り出す
                //   (一度読んだら消費して、 再オープンを防ぐ)。
                "getInitialPageId" -> {
                    val id = intent?.getStringExtra(EXTRA_PAGE_ID)
                    intent?.removeExtra(EXTRA_PAGE_ID)
                    result.success(id)
                }
                else -> result.notImplemented()
            }
        }
    }

    /// プラグインをリフレクションで安全に (Throwable まで握って) 事前登録する。
    /// クラスが見つからない / インスタンス化やアタッチで例外・エラーが出ても
    /// アプリ起動は止めない。 GeneratedPluginRegistrant が後続プラグインの
    /// java.lang.Error で中断しても、 ここで登録した必須プラグインは生き残る。
    private fun safeAddPlugin(flutterEngine: FlutterEngine, className: String) {
        try {
            val cls = Class.forName(className)
            val plugin = cls.getDeclaredConstructor().newInstance() as FlutterPlugin
            flutterEngine.plugins.add(plugin)
        } catch (t: Throwable) {
            android.util.Log.e("MainActivity", "事前登録に失敗: $className", t)
        }
    }

    /// ホーム画面にマップを開くピン留めショートカットを作成する。
    private fun pinMapShortcut(pageId: String, label: String): Boolean {
        return try {
            if (!ShortcutManagerCompat.isRequestPinShortcutSupported(this)) {
                return false
            }
            val launch = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
                addCategory(Intent.CATEGORY_LAUNCHER)
                putExtra(EXTRA_PAGE_ID, pageId)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            val safe = if (label.isBlank()) "Map" else label
            val shortcut = ShortcutInfoCompat.Builder(this, "mindmap_page_$pageId")
                .setShortLabel(safe)
                .setLongLabel(safe)
                .setIcon(IconCompat.createWithResource(this, R.mipmap.ic_launcher))
                .setIntent(launch)
                .build()
            ShortcutManagerCompat.requestPinShortcut(this, shortcut, null)
            true
        } catch (e: Exception) {
            false
        }
    }

    /// Android のスクリーンショット直後など、Flutter 側の super_clipboard が
    /// content:// 画像を取りこぼすケース用のフォールバック。
    private fun readClipboardImage(): Map<String, Any>? {
        return try {
            val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = manager.primaryClip ?: return null
            val describedImageMime = (0 until clip.description.mimeTypeCount)
                .map { clip.description.getMimeType(it) }
                .firstOrNull { it.startsWith("image/", ignoreCase = true) }
            for (i in 0 until clip.itemCount) {
                val item = clip.getItemAt(i)
                // 共有シートや一部の画像アプリは ClipData.Item.uri ではなく
                // Intent.EXTRA_STREAM に content:// URI を格納する。モバイルで
                // 貼り付け不能になっていたこの形式も読み取る。
                val streamUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    item.intent?.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    item.intent?.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                }
                val uri = item.uri
                    ?: item.intent?.data
                    ?: streamUri
                    ?: uriFromClipboardText(item.text?.toString())
                if (uri == null) continue
                val guessed = guessImageMime(uri)
                val declaredImageMime = try {
                    contentResolver.getType(uri)
                } catch (_: Exception) {
                    null
                }
                    ?.takeIf { it.startsWith("image/", ignoreCase = true) }
                val bytes = try {
                    contentResolver.openInputStream(uri)?.use { it.readBytes() }
                } catch (_: Exception) {
                    null
                } ?: continue
                if (bytes.isEmpty()) continue
                val sniffed = sniffImageMime(bytes)
                val imageMime = declaredImageMime ?: guessed ?: sniffed ?: describedImageMime
                if (imageMime == null) continue
                return mapOf("bytes" to bytes, "mime" to imageMime)
            }
            null
        } catch (e: Exception) {
            null
        }
    }

    private fun uriFromClipboardText(text: String?): Uri? {
        val raw = text?.trim().orEmpty()
        if (raw.isEmpty()) return null
        if (raw.startsWith("content://") || raw.startsWith("file://")) {
            return Uri.parse(raw)
        }
        return if (raw.startsWith("/") && guessImageMime(raw) != null) {
            Uri.fromFile(File(raw))
        } else {
            null
        }
    }

    private fun guessImageMime(uri: Uri): String? {
        return guessImageMime(uri.lastPathSegment ?: uri.toString())
    }

    private fun guessImageMime(name: String): String? {
        val lower = name.lowercase()
        return when {
            lower.endsWith(".jpg") || lower.endsWith(".jpeg") -> "image/jpeg"
            lower.endsWith(".webp") -> "image/webp"
            lower.endsWith(".gif") -> "image/gif"
            lower.endsWith(".bmp") -> "image/bmp"
            lower.endsWith(".tif") || lower.endsWith(".tiff") -> "image/tiff"
            lower.endsWith(".heic") -> "image/heic"
            lower.endsWith(".heif") -> "image/heif"
            lower.endsWith(".avif") -> "image/avif"
            lower.endsWith(".png") -> "image/png"
            else -> null
        }
    }

    /// MIME が application/octet-stream でも、画像のマジックバイトから判定する。
    private fun sniffImageMime(bytes: ByteArray): String? {
        if (matchesBytes(bytes, 0, intArrayOf(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))) {
            return "image/png"
        }
        if (matchesBytes(bytes, 0, intArrayOf(0xFF, 0xD8, 0xFF))) return "image/jpeg"
        if (matchesAscii(bytes, 0, "GIF87a") || matchesAscii(bytes, 0, "GIF89a")) {
            return "image/gif"
        }
        if (matchesAscii(bytes, 0, "RIFF") && matchesAscii(bytes, 8, "WEBP")) {
            return "image/webp"
        }
        if (matchesAscii(bytes, 0, "BM")) return "image/bmp"
        if (matchesBytes(bytes, 0, intArrayOf(0x49, 0x49, 0x2A, 0x00)) ||
            matchesBytes(bytes, 0, intArrayOf(0x4D, 0x4D, 0x00, 0x2A))) {
            return "image/tiff"
        }
        if (matchesAscii(bytes, 4, "ftyp")) {
            val brands = listOf("heic", "heix", "hevc", "hevx", "mif1", "msf1")
            if (brands.any { matchesAscii(bytes, 8, it) }) return "image/heic"
            if (matchesAscii(bytes, 8, "avif") || matchesAscii(bytes, 8, "avis")) {
                return "image/avif"
            }
        }
        return null
    }

    private fun matchesBytes(bytes: ByteArray, offset: Int, expected: IntArray): Boolean {
        if (offset < 0 || bytes.size < offset + expected.size) return false
        return expected.indices.all { index ->
            (bytes[offset + index].toInt() and 0xFF) == expected[index]
        }
    }

    private fun matchesAscii(bytes: ByteArray, offset: Int, expected: String): Boolean {
        if (offset < 0 || bytes.size < offset + expected.length) return false
        return expected.indices.all { index ->
            (bytes[offset + index].toInt() and 0xFF) == expected[index].code
        }
    }

    /// 既に起動中にショートカットがタップされた場合 (singleTop)。
    /// 新しい intent からページ ID を取り出して Flutter 側へ通知する。
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val id = intent.getStringExtra(EXTRA_PAGE_ID)
        if (!id.isNullOrEmpty()) {
            shortcutChannel?.invokeMethod("openPage", id)
            intent.removeExtra(EXTRA_PAGE_ID)
        }
    }

    /// 画面固定 (lock task / screen pinning) を開始する。
    /// 既に固定中なら何もしない (二重開始による例外を避ける)。
    private fun startScreenPinning() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        try {
            if (!isInLockTaskModeCompat()) {
                startLockTask()
            }
        } catch (e: Exception) {
            // 端末が画面固定をサポートしない / 設定で無効 / 状態不正 などは無視。
            // (= Flutter 側のオーバーレイロックだけは従来どおり機能する)
        }
    }

    /// 画面固定を解除する。
    private fun stopScreenPinning() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return
        try {
            if (isInLockTaskModeCompat()) {
                stopLockTask()
            }
        } catch (e: Exception) {
        }
    }

    /// 現在 lock task (画面固定) 中かどうかを API レベル差を吸収して返す。
    private fun isInLockTaskModeCompat(): Boolean {
        return try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
            } else {
                @Suppress("DEPRECATION")
                am.isInLockTaskMode
            }
        } catch (e: Exception) {
            false
        }
    }

    /// アプリが前面に戻ったとき、 ロック要求中なら画面固定を再適用する。
    /// WiFi/SMS/電話 などで一時的に固定を外して外部アプリへ飛んだあと、
    /// 戻ってきたら必ず再固定して「抜け道」 を塞ぐ。
    /// (Flutter 側の _FocusLockOverlay の resumed ハンドラと二重の保険。
    ///  どちらが先でも startScreenPinning は冪等なので問題ない。)
    override fun onResume() {
        super.onResume()
        if (lockRequested) {
            startScreenPinning()
        }
    }
}
