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
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val LOCK_CHANNEL = "app/lock"
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
        super.configureFlutterEngine(flutterEngine)

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
