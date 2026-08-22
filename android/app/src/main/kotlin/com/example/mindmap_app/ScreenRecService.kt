// ============================================================================
//  画面録画 (Android) — MediaProjection + MediaRecorder
// ============================================================================
//  ユーザー要望「画面録画機能が PC 版限定でモバイル版に対応していないから
//  対応できるなら対応させて欲しい」 への対応。
//
//  Windows は ffmpeg (gdigrab) で録るが、 Android にはその手段が無いため
//  OS の MediaProjection を使う。 Android 10 以降は「型 mediaProjection の
//  フォアグラウンドサービスが動いている状態」 でないと projection を作れない
//  ので、 録画の実体をこのサービスに置いている (Activity 側に置くと
//  Android 14 で SecurityException になる)。
//
//  流れ:
//    MainActivity: createScreenCaptureIntent → onActivityResult で許可を受け取る
//      → このサービスを ACTION_START で起動 (resultCode / data / 出力先を渡す)
//    Service: startForeground → getMediaProjection → MediaRecorder + VirtualDisplay
//    停止: ACTION_STOP → recorder.stop → ファイル確定 → stopSelf
//
//  録画中かどうかと出力先は companion の静的フィールドで Activity と共有する
//  (同一プロセスなので bind は不要)。
// ============================================================================

package com.example.mindmap_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import java.io.File

class ScreenRecService : Service() {

    companion object {
        const val ACTION_START = "com.example.mindmap_app.SCREENREC_START"
        const val ACTION_STOP = "com.example.mindmap_app.SCREENREC_STOP"

        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val EXTRA_PATH = "path"
        const val EXTRA_WIDTH = "width"
        const val EXTRA_HEIGHT = "height"
        const val EXTRA_DPI = "dpi"
        const val EXTRA_WITH_AUDIO = "withAudio"

        private const val CHANNEL_ID = "hn_screen_rec"
        private const val NOTIF_ID = 4711

        /// 録画中かどうか (Activity から参照する)。
        @Volatile
        var isRecording: Boolean = false
            private set

        /// 現在 / 直前の出力先。
        @Volatile
        var currentPath: String? = null
            private set

        /// 直近の失敗理由 (Dart 側にそのまま出す)。
        @Volatile
        var lastError: String? = null
            private set
    }

    private var projection: MediaProjection? = null
    private var recorder: MediaRecorder? = null
    private var display: VirtualDisplay? = null

    /// projection が OS 側から止められた時 (通知の「停止」 等) の後始末。
    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            finishRecording()
            stopSelf()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                finishRecording()
                stopSelf()
            }
            ACTION_START -> startRecording(intent)
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startRecording(intent: Intent) {
        if (isRecording) return
        lastError = null
        val path = intent.getStringExtra(EXTRA_PATH)
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        @Suppress("DEPRECATION")
        val data: Intent? = intent.getParcelableExtra(EXTRA_RESULT_DATA)
        if (path == null || data == null) {
            lastError = "録画の許可を受け取れませんでした"
            stopSelf()
            return
        }
        // Android 10+ は projection を作る前にフォアグラウンド化が必須。
        try {
            startForegroundCompat()
        } catch (t: Throwable) {
            lastError = "フォアグラウンド開始に失敗: ${t.message}"
            stopSelf()
            return
        }
        val width = intent.getIntExtra(EXTRA_WIDTH, 720)
        val height = intent.getIntExtra(EXTRA_HEIGHT, 1280)
        val dpi = intent.getIntExtra(EXTRA_DPI, 320)
        val withAudio = intent.getBooleanExtra(EXTRA_WITH_AUDIO, false)
        try {
            val mgr = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                as MediaProjectionManager
            val proj = mgr.getMediaProjection(resultCode, data)
                ?: throw IllegalStateException("MediaProjection を作れませんでした")
            projection = proj
            proj.registerCallback(projectionCallback, null)

            val rec = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            if (withAudio) rec.setAudioSource(MediaRecorder.AudioSource.MIC)
            rec.setVideoSource(MediaRecorder.VideoSource.SURFACE)
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setOutputFile(path)
            rec.setVideoSize(width, height)
            rec.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            if (withAudio) rec.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            // 画面録画としてほどほどの画質 (端末負荷とファイルサイズの兼ね合い)。
            rec.setVideoEncodingBitRate(width * height * 5)
            rec.setVideoFrameRate(30)
            rec.prepare()

            display = proj.createVirtualDisplay(
                "HisatorNotebookRec",
                width,
                height,
                dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                rec.surface,
                null,
                null,
            )
            rec.start()
            recorder = rec
            currentPath = path
            isRecording = true
        } catch (t: Throwable) {
            lastError = t.message ?: t.toString()
            releaseAll()
            stopForegroundCompat()
            stopSelf()
        }
    }

    /// 録画を止めてファイルを閉じる。 二重呼び出しでも安全。
    private fun finishRecording() {
        if (!isRecording) {
            releaseAll()
            stopForegroundCompat()
            return
        }
        isRecording = false
        try {
            recorder?.stop()
        } catch (t: Throwable) {
            // stop 直後に停止すると IllegalStateException (フレーム 0 枚) になる。
            // その場合は中身の無いファイルを残さない。
            lastError = "録画が短すぎます"
            try {
                currentPath?.let { File(it).delete() }
            } catch (_: Throwable) {
            }
            currentPath = null
        }
        releaseAll()
        stopForegroundCompat()
    }

    private fun releaseAll() {
        try {
            display?.release()
        } catch (_: Throwable) {
        }
        display = null
        try {
            recorder?.reset()
            recorder?.release()
        } catch (_: Throwable) {
        }
        recorder = null
        try {
            projection?.unregisterCallback(projectionCallback)
            projection?.stop()
        } catch (_: Throwable) {
        }
        projection = null
    }

    override fun onDestroy() {
        finishRecording()
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID,
                "画面録画",
                NotificationManager.IMPORTANCE_LOW,
            )
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
        val tapIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pending = if (tapIntent != null) {
            PendingIntent.getActivity(
                this,
                0,
                tapIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        } else {
            null
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notif = builder
            .setContentTitle("画面を録画しています")
            .setContentText("アプリに戻って停止できます")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .also { if (pending != null) it.setContentIntent(pending) }
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Throwable) {
        }
    }
}
