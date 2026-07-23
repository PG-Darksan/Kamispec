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

import android.Manifest
import android.app.ActivityManager
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import android.util.Base64
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {

    companion object {
        private const val LOCK_CHANNEL = "app/lock"
        private const val CLIPBOARD_CHANNEL = "app/clipboard"
        private const val DEVICE_CHANNEL = "app/device"
        private const val DOWNLOADS_CHANNEL = "app/downloads"
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
        // ffmpeg の初期化で GeneratedPluginRegistrant が中断しても、Android の
        // 画像クリップボード経路が失われないよう依存順で先に登録する。
        safeAddPlugin(flutterEngine, "dev.irondash.engine_context.IrondashEngineContextPlugin")
        safeAddPlugin(flutterEngine, "com.superlist.super_native_extensions.SuperNativeExtensionsPlugin")

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
                    "readClipboardImage" -> {
                        // 高解像度スクリーンショットをUIスレッドで全読み込みすると、
                        // HyperOS端末などで貼り付けが固まるためバックグラウンドで処理。
                        Thread {
                            val payload = readClipboardImage()
                            runOnUiThread { result.success(payload) }
                        }.start()
                    }
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

        // ── 画像を端末共有の Download フォルダーへ保存 ──
        // path_provider の Android Downloads はアプリ専用領域になるため、
        // Android 10+ は MediaStore、Android 9 以下は公開 Download を使う。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DOWNLOADS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImage" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val requestedName = call.argument<String>("fileName")
                        if (sourcePath.isNullOrBlank() || requestedName.isNullOrBlank()) {
                            result.error(
                                "bad_arguments",
                                "sourcePath and fileName are required",
                                null
                            )
                        } else {
                            val source = File(sourcePath)
                            if (!source.isFile) {
                                result.error("source_missing", "Image file was not found", null)
                            } else if (
                                Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
                                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                                    PackageManager.PERMISSION_GRANTED
                            ) {
                                result.error(
                                    "permission_required",
                                    "Storage permission is required on Android 9 or earlier",
                                    null
                                )
                            } else {
                                Thread {
                                    try {
                                        val saved = saveImageToDownloads(source, requestedName)
                                        runOnUiThread { result.success(saved) }
                                    } catch (e: Exception) {
                                        android.util.Log.e(
                                            "MainActivity",
                                            "Saving image to Downloads failed",
                                            e
                                        )
                                        runOnUiThread {
                                            result.error(
                                                "save_failed",
                                                e.message ?: e.javaClass.simpleName,
                                                null
                                            )
                                        }
                                    }
                                }.start()
                            }
                        }
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
    private fun readClipboardImage(): Map<String, Any> {
        return try {
            val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = manager.primaryClip
                ?: return mapOf("hasImageHint" to false, "status" to "empty")
            val describedImageMime = (0 until clip.description.mimeTypeCount)
                .map { clip.description.getMimeType(it) }
                .firstOrNull { it.startsWith("image/", ignoreCase = true) }
            var hasImageHint = describedImageMime != null

            for (i in 0 until clip.itemCount) {
                val item = clip.getItemAt(i)
                val textCandidates = linkedSetOf<String>()
                item.text?.toString()?.let(textCandidates::add)
                item.htmlText?.let(textCandidates::add)
                item.intent?.getCharSequenceExtra(Intent.EXTRA_TEXT)
                    ?.toString()?.let(textCandidates::add)
                try {
                    item.coerceToText(this)?.toString()?.let(textCandidates::add)
                } catch (_: Exception) {
                }

                for (text in textCandidates) {
                    decodeClipboardDataImage(text)?.let { (bytes, mime) ->
                        return cacheClipboardImage(bytes, mime, true)
                    }
                }

                val uriCandidates = linkedSetOf<Uri>()
                item.uri?.let(uriCandidates::add)
                item.intent?.data?.let(uriCandidates::add)
                addIntentStreamUris(item.intent, uriCandidates)
                item.intent?.clipData?.let { nested ->
                    for (j in 0 until nested.itemCount) {
                        val nestedItem = nested.getItemAt(j)
                        nestedItem.uri?.let(uriCandidates::add)
                        nestedItem.intent?.data?.let(uriCandidates::add)
                        addIntentStreamUris(nestedItem.intent, uriCandidates)
                    }
                }
                for (text in textCandidates) {
                    uriFromClipboardText(text)?.let(uriCandidates::add)
                    Regex("""(?:content|file)://[^\s\"'<>]+""",
                        RegexOption.IGNORE_CASE).findAll(text).forEach { match ->
                        runCatching {
                            Uri.parse(match.value.replace("&amp;", "&"))
                        }.getOrNull()?.let(uriCandidates::add)
                    }
                }

                for (uri in uriCandidates) {
                    val guessed = guessImageMime(uri)
                    if (guessed != null || uri.scheme == "content" || uri.scheme == "file") {
                        hasImageHint = true
                    }
                    val declaredImageMime = try {
                        contentResolver.getType(uri)
                    } catch (_: Exception) {
                        null
                    }?.takeIf { it.startsWith("image/", ignoreCase = true) }
                    if (declaredImageMime != null) hasImageHint = true

                    var bytes: ByteArray? = null
                    // HyperOSの一時URIはコピー直後に公開が間に合わないことがあるため、
                    // 短い間隔で再試行する。
                    for (attempt in 0 until 3) {
                        bytes = readClipboardUriBytes(uri)
                        if (bytes != null && bytes.isNotEmpty()) break
                        if (attempt < 2) Thread.sleep(140L)
                    }
                    if (bytes == null || bytes.isEmpty()) continue
                    val sniffed = sniffImageMime(bytes)
                    val imageMime = sniffed ?: declaredImageMime ?: guessed ?: describedImageMime
                    if (imageMime == null) continue
                    return cacheClipboardImage(bytes, imageMime, true)
                }
            }
            mapOf(
                "hasImageHint" to hasImageHint,
                "status" to if (hasImageHint) "unreadable" else "not_image"
            )
        } catch (e: Exception) {
            android.util.Log.w("MainActivity", "Clipboard image read failed: ${e.javaClass.simpleName}")
            mapOf(
                "hasImageHint" to true,
                "status" to "error",
                "errorType" to e.javaClass.simpleName
            )
        }
    }

    private fun addIntentStreamUris(intent: Intent?, target: MutableSet<Uri>) {
        if (intent == null) return
        val single = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }
        single?.let(target::add)
        val multiple = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        }
        multiple?.forEach(target::add)
    }

    private fun decodeClipboardDataImage(text: String): Pair<ByteArray, String>? {
        val match = Regex(
            """data:(image/[A-Za-z0-9.+-]+);base64,([A-Za-z0-9+/=\r\n\t ]+)""",
            RegexOption.IGNORE_CASE
        ).find(text) ?: return null
        return try {
            val mime = match.groupValues[1].lowercase()
            val bytes = Base64.decode(match.groupValues[2], Base64.DEFAULT)
            if (bytes.isEmpty()) null else Pair(bytes, mime)
        } catch (_: Exception) {
            null
        }
    }

    private fun readClipboardUriBytes(uri: Uri): ByteArray? {
        if (uri.scheme == "file") {
            return try {
                uri.path?.let { File(it) }?.takeIf { it.isFile }?.readBytes()
            } catch (_: Exception) {
                null
            }
        }
        try {
            contentResolver.openInputStream(uri)?.use { input ->
                val bytes = input.readBytes()
                if (bytes.isNotEmpty()) return bytes
            }
        } catch (e: Exception) {
            android.util.Log.d("MainActivity",
                "Clipboard openInputStream failed (${uri.authority}): ${e.javaClass.simpleName}")
        }
        try {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                descriptor.createInputStream().use { input ->
                    val bytes = input.readBytes()
                    if (bytes.isNotEmpty()) return bytes
                }
            }
        } catch (_: Exception) {
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            try {
                contentResolver.openTypedAssetFileDescriptor(uri, "image/*", null)
                    ?.use { descriptor ->
                        descriptor.createInputStream().use { input ->
                            val bytes = input.readBytes()
                            if (bytes.isNotEmpty()) return bytes
                        }
                    }
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun cacheClipboardImage(
        bytes: ByteArray,
        mime: String,
        hasImageHint: Boolean
    ): Map<String, Any> {
        val dir = File(cacheDir, "clipboard_import")
        if (!dir.exists()) dir.mkdirs()
        val cutoff = System.currentTimeMillis() - 24L * 60L * 60L * 1000L
        dir.listFiles()?.filter { it.lastModified() < cutoff }?.forEach {
            runCatching { it.delete() }
        }
        val ext = when {
            mime.contains("jpeg") || mime.contains("jpg") -> "jpg"
            mime.contains("webp") -> "webp"
            mime.contains("gif") -> "gif"
            mime.contains("bmp") -> "bmp"
            mime.contains("tiff") || mime.contains("tif") -> "tiff"
            mime.contains("heic") || mime.contains("heif") -> "heic"
            mime.contains("avif") -> "avif"
            else -> "png"
        }
        val file = File(dir, "clipboard_${System.currentTimeMillis()}.$ext")
        file.writeBytes(bytes)
        return mapOf(
            "path" to file.absolutePath,
            "mime" to mime,
            "hasImageHint" to hasImageHint,
            "status" to "ok"
        )
    }

    private data class DownloadImageSpec(
        val displayName: String,
        val mimeType: String
    )

    /// 編集処理が PNG データを元の .jpg パスへ書く場合もあるため、
    /// 拡張子だけでなくマジックバイトを優先して公開ファイル名と MIME を決める。
    private fun downloadImageSpec(source: File, requestedName: String): DownloadImageSpec {
        val header = ByteArray(32)
        val readCount = source.inputStream().use { input -> input.read(header) }
        val detected = if (readCount > 0) {
            sniffImageMime(header.copyOf(readCount))
        } else {
            null
        }
        val mime = detected ?: guessImageMime(requestedName) ?: "image/jpeg"
        val extension = when (mime) {
            "image/png" -> "png"
            "image/gif" -> "gif"
            "image/webp" -> "webp"
            "image/bmp" -> "bmp"
            "image/tiff" -> "tiff"
            "image/heic", "image/heif" -> "heic"
            "image/avif" -> "avif"
            else -> "jpg"
        }
        val baseName = requestedName
            .replace('\\', '/')
            .substringAfterLast('/')
            .replace(Regex("""[\u0000-\u001F\u007F]"""), "_")
            .trim()
        val dot = baseName.lastIndexOf('.')
        val stem = (if (dot > 0) baseName.substring(0, dot) else baseName)
            .ifBlank { "image_${System.currentTimeMillis()}" }
        return DownloadImageSpec("$stem.$extension", mime)
    }

    private fun saveImageToDownloads(
        source: File,
        requestedName: String
    ): Map<String, String> {
        val spec = downloadImageSpec(source, requestedName)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, spec.displayName)
                put(MediaStore.MediaColumns.MIME_TYPE, spec.mimeType)
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    "${Environment.DIRECTORY_DOWNLOADS}/"
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values
            ) ?: throw IOException("MediaStore insert failed")
            try {
                contentResolver.openOutputStream(uri, "w")?.use { output ->
                    source.inputStream().use { input -> input.copyTo(output) }
                } ?: throw IOException("Download output stream is unavailable")
                contentResolver.update(
                    uri,
                    ContentValues().apply {
                        put(MediaStore.MediaColumns.IS_PENDING, 0)
                    },
                    null,
                    null
                )
                return mapOf(
                    "uri" to uri.toString(),
                    "displayName" to spec.displayName,
                    "displayPath" to "${Environment.DIRECTORY_DOWNLOADS}/${spec.displayName}"
                )
            } catch (e: Exception) {
                contentResolver.delete(uri, null, null)
                throw e
            }
        }

        @Suppress("DEPRECATION")
        val directory =
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IOException("Could not create the public Download directory")
        }
        val dot = spec.displayName.lastIndexOf('.')
        val stem = if (dot > 0) spec.displayName.substring(0, dot) else spec.displayName
        val suffix = if (dot > 0) spec.displayName.substring(dot) else ""
        var destination = File(directory, spec.displayName)
        var copyNumber = 1
        while (destination.exists()) {
            destination = File(directory, "$stem ($copyNumber)$suffix")
            copyNumber += 1
        }
        source.copyTo(destination, overwrite = false)
        MediaScannerConnection.scanFile(
            this,
            arrayOf(destination.absolutePath),
            arrayOf(spec.mimeType),
            null
        )
        return mapOf(
            "uri" to Uri.fromFile(destination).toString(),
            "displayName" to destination.name,
            "displayPath" to "${Environment.DIRECTORY_DOWNLOADS}/${destination.name}"
        )
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
