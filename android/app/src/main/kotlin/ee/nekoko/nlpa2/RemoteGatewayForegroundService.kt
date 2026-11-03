package ee.nekoko.nlpa2

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.telephony.SubscriptionManager
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal class RemoteGatewayForegroundService : Service() {
    companion object {
        private const val TAG = "NexusGatewayService"
        private const val CHANNEL_ID = "remote_gateway"
        private const val NOTIFICATION_ID = 49021
        const val ACTION_RECOVER = "ee.nekoko.nlpa2.action.RECOVER_GATEWAY"
        private val SMS_URI = Uri.parse("content://sms")
        private val SMS_INBOX_URI = Uri.parse("content://sms/inbox")

        fun start(context: Context, action: String? = null) {
            val intent = Intent(context, RemoteGatewayForegroundService::class.java).apply {
                this.action = action
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RemoteGatewayForegroundService::class.java))
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val inboxScanner = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "sms-inbox-observer").apply { isDaemon = true }
    }
    @Volatile private var lastObservedSmsId: Long = -1L
    private var smsObserver: ContentObserver? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        initSmsInboxObserver()
    }

    override fun onDestroy() {
        smsObserver?.let {
            runCatching { contentResolver.unregisterContentObserver(it) }
        }
        smsObserver = null
        inboxScanner.shutdownNow()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (smsObserver == null) {
            initSmsInboxObserver()
        }
        return START_STICKY
    }

    private fun initSmsInboxObserver() {
        seedLatestSmsId()
        val observer = object : ContentObserver(mainHandler) {
            override fun onChange(selfChange: Boolean) {
                // Delay 700ms so normal SMS_RECEIVED broadcasts record first without racing.
                inboxScanner.schedule({ scanNewInboxSms() }, 700L, TimeUnit.MILLISECONDS)
            }
        }
        try {
            contentResolver.registerContentObserver(SMS_URI, true, observer)
            smsObserver = observer
        } catch (e: Exception) {
            Log.w(TAG, "SMS ContentObserver registration deferred: ${e.message}")
        }
        inboxScanner.scheduleWithFixedDelay({ scanNewInboxSms() }, 3L, 3L, TimeUnit.SECONDS)
    }

    private fun hasReadSmsPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED

    private fun seedLatestSmsId() {
        if (!hasReadSmsPermission()) return
        try {
            contentResolver.query(
                SMS_INBOX_URI,
                arrayOf("_id"),
                null,
                null,
                "_id DESC LIMIT 1",
            )?.use { cursor ->
                lastObservedSmsId = if (cursor.moveToFirst()) cursor.getLong(0) else 0L
            }
        } catch (_: Exception) {}
    }

    private fun scanNewInboxSms() {
        if (!hasReadSmsPermission()) return
        if (lastObservedSmsId < 0L) {
            seedLatestSmsId()
            if (lastObservedSmsId < 0L) lastObservedSmsId = 0L
        }
        try {
            val cutoffMillis = System.currentTimeMillis() - 90_000L
            contentResolver.query(
                SMS_INBOX_URI,
                arrayOf("_id", "address", "body", "date", "sub_id"),
                "_id > ? AND date >= ?",
                arrayOf(lastObservedSmsId.toString(), cutoffMillis.toString()),
                "_id ASC",
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(0)
                    val address = cursor.getString(1)?.trim().orEmpty()
                    val body = cursor.getString(2).orEmpty()
                    val date = cursor.getLong(3).takeIf { it > 0L } ?: System.currentTimeMillis()
                    val subId = if (!cursor.isNull(4)) cursor.getInt(4).takeIf { it >= 0 } else null
                    if (id > lastObservedSmsId) {
                        lastObservedSmsId = id
                    }
                    if (address.isNotEmpty() && body.isNotEmpty()) {
                        val origin = resolveOriginFromSubId(subId)
                        SmsRelayReceiver.enqueueIncomingSms(
                            context = applicationContext,
                            sender = address,
                            body = body,
                            origin = origin,
                            receivedAtMillis = date,
                            dedupWindowMillis = 25_000L,
                        )
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "scanNewInboxSms failed: ${e.message}")
        }
    }

    private fun resolveOriginFromSubId(subId: Int?): SmsRelayOrigin {
        if (subId == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) {
            return SmsRelayOrigin(subId, null, null)
        }
        return try {
            val manager = getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
            val info = manager?.getActiveSubscriptionInfo(subId)
            SmsRelayOrigin(
                subscriptionId = subId,
                slotIndex = info?.simSlotIndex?.takeIf { it >= 0 },
                carrierName = info?.carrierName?.toString()?.takeIf { it.isNotBlank() },
            )
        } catch (_: Exception) {
            SmsRelayOrigin(subId, null, null)
        }
    }
    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "eUICC-Nexus 常驻服务",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "保持私有 eSIM 远程切卡与短信转发服务常驻"
            },
        )
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("eUICC-Nexus 正在运行")
            .setContentText("短信实时转发与远程切卡网关已就绪")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
    }
}
