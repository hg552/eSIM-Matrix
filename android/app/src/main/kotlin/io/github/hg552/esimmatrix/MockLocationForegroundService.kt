package io.github.hg552.esimmatrix

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps a virtual-location injection alive while the app is in the background.
 *
 * The injection itself is a one-second push from [MockLocationPlugin]. Without a
 * foreground service the process is a normal background process, so the system
 * may reclaim it at any time and every app silently falls back to the real
 * position while the console still says "正在注入". This service owns that
 * lifetime and puts the current position in a notification, so the state is
 * visible outside the app too.
 */
internal class MockLocationForegroundService : Service() {
    companion object {
        private const val TAG = "NexusMockLocationService"
        private const val CHANNEL_ID = "mock_location"
        private const val NOTIFICATION_ID = 49022
        const val ACTION_STOP = "io.github.hg552.esimmatrix.action.STOP_MOCK_LOCATION"

        /** Latest position, kept here so the notification can name it. */
        @Volatile private var label: String = ""
        @Volatile private var latitude: Double = 0.0
        @Volatile private var longitude: Double = 0.0
        @Volatile private var running: Boolean = false

        fun start(context: Context, label: String, latitude: Double, longitude: Double) {
            this.label = label
            this.latitude = latitude
            this.longitude = longitude
            running = true
            val intent = Intent(context, MockLocationForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            running = false
            context.stopService(Intent(context, MockLocationForegroundService::class.java))
        }

        fun isRunning(): Boolean = running
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        Log.i(TAG, "Mock location foreground service started")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // The plugin is the only thing that knows how to tear the test
            // providers down, so it is asked to do it rather than the service
            // guessing at LocationManager state.
            MockLocationPlugin.requestStopFromNotification()
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        Log.i(TAG, "Mock location foreground service stopped")
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "虚拟定位",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "虚拟定位注入期间的常驻提示"
            },
        )
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            NOTIFICATION_ID + 1,
            Intent(this, MockLocationForegroundService::class.java).apply {
                action = ACTION_STOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val where = if (label.isBlank()) "自定义位置" else label
        val coordinates = "%.5f, %.5f".format(latitude, longitude)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("正在虚拟定位 · $where")
            .setContentText(coordinates)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "停止定位",
                    stopIntent,
                ).build(),
            )
            .build()
    }
}
