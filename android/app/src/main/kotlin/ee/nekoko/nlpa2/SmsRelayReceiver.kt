package ee.nekoko.nlpa2

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Telephony
import android.os.PowerManager
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import android.util.Log
import org.json.JSONObject
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection

internal class SmsRelayReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "NexusSmsRelay"

        private val executor = ThreadPoolExecutor(
            2,
            2,
            0L,
            TimeUnit.MILLISECONDS,
            ArrayBlockingQueue(16),
            ThreadPoolExecutor.AbortPolicy(),
        )
        private val retryBackoffMillis = longArrayOf(0L, 1500L, 3500L)

        internal fun deliverSingle(
            settings: SmsRelaySettings,
            sender: String,
            body: String,
            origin: SmsRelayOrigin,
            receivedAtMillis: Long,
        ): String? {
            val token = settings.token ?: return "token_missing"
            var lastError: String? = "network_error"
            for (delayMs in retryBackoffMillis) {
                if (delayMs > 0L) {
                    try {
                        Thread.sleep(delayMs)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        break
                    }
                }
                try {
                    val errorCode = when (settings.mode) {
                        SmsRelayMode.WEBHOOK -> {
                            val endpoint = settings.endpoint ?: return "endpoint_missing"
                            val payload = JSONObject()
                                .put("event", "sms.received")
                                .put("messageId", UUID.randomUUID().toString())
                                .put("sender", sender)
                                .put("body", body)
                                .put("otp", TelegramBotClient.extractOtp(body) ?: JSONObject.NULL)
                                .put("receivedAtEpochMillis", receivedAtMillis)
                                .put("subscriptionId", origin.subscriptionId ?: JSONObject.NULL)
                                .put("slotIndex", origin.slotIndex ?: JSONObject.NULL)
                                .put("carrierName", origin.carrierName ?: JSONObject.NULL)
                                .toString()
                            val responseCode = SmsRelayWebhookClient.post(endpoint, token, payload)
                            if (responseCode in 200..299) null else "http_$responseCode"
                        }
                        SmsRelayMode.TELEGRAM -> {
                            val chatId = settings.telegramChatId ?: return "chat_id_missing"
                            TelegramBotClient.sendSms(token, chatId, sender, body, origin)
                            null
                        }
                        else -> return "invalid_mode"
                    }
                    if (errorCode == null) return null
                    lastError = errorCode
                } catch (error: TelegramBotException) {
                    lastError = error.errorCode
                    if (error.errorCode in setOf("invalid_bot_token", "invalid_chat_id", "telegram_api_rejected")) {
                        break
                    }
                } catch (_: Exception) {
                    lastError = "network_error"
                }
            }
            return lastError
        }

        fun retryUndelivered(context: Context, targetId: String? = null): Int {
            val settings = runCatching { SmsRelayStore.load(context.applicationContext) }.getOrNull() ?: return 0
            if (!settings.enabled || settings.token.isNullOrBlank()) return 0
            val items = SmsRelayStore.loadHistory(context.applicationContext)
            var deliveredCount = 0
            for (item in items) {
                val id = item["id"] as? String ?: continue
                if (targetId != null && id != targetId) continue
                val alreadyDelivered = item["delivered"] as? Boolean ?: true
                if (alreadyDelivered && targetId == null) continue
                val sender = item["sender"] as? String ?: continue
                val body = item["body"] as? String ?: continue
                val slotIndex = item["slotIndex"] as? Int
                val carrierName = item["carrierName"] as? String
                val receivedAtMillis = (item["receivedAtMillis"] as? Number)?.toLong() ?: System.currentTimeMillis()
                val origin = SmsRelayOrigin(null, slotIndex, carrierName)
                val err = deliverSingle(settings, sender, body, origin, receivedAtMillis)
                SmsRelayStore.markDelivered(context.applicationContext, id, err == null, err)
                if (err == null) deliveredCount++
            }
            return deliveredCount
        }

        internal fun readOriginFromIntent(context: Context, intent: Intent): SmsRelayOrigin {
            fun nonNegativeExtra(vararg keys: String): Int? = keys.firstNotNullOfOrNull { key ->
                if (intent.hasExtra(key)) intent.getIntExtra(key, -1).takeIf { it >= 0 } else null
            }
            val subscriptionId = nonNegativeExtra("android.telephony.extra.SUBSCRIPTION_INDEX", "subscription")
            var slotIndex = nonNegativeExtra("android.telephony.extra.SLOT_INDEX", "slot", "phone")
            var carrierName: String? = null
            if (subscriptionId != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                try {
                    val manager = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
                    val subscription = manager?.getActiveSubscriptionInfo(subscriptionId)
                    if (slotIndex == null) slotIndex = subscription?.simSlotIndex?.takeIf { it >= 0 }
                    carrierName = subscription?.carrierName?.toString()?.takeIf { it.isNotBlank() }
                } catch (_: RuntimeException) {}
                if (carrierName == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    try {
                        carrierName = (context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager)
                            ?.createForSubscriptionId(subscriptionId)?.simOperatorName?.takeIf { it.isNotBlank() }
                    } catch (_: RuntimeException) {}
                }
            }
            return SmsRelayOrigin(subscriptionId, slotIndex, carrierName)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION ||
            BuildConfig.FLAVOR !in setOf("nexus", "m")
        ) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            context.checkSelfPermission(Manifest.permission.RECEIVE_SMS) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val settings = try {
            SmsRelayStore.load(context.applicationContext)
        } catch (_: Exception) {
            return
        }
        if (!settings.enabled) return
        val token = settings.token ?: return

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isNullOrEmpty()) return
        val sender = messages.firstOrNull()?.originatingAddress?.trim().orEmpty()
        val body = messages.joinToString(separator = "") { it.messageBody.orEmpty() }
        if (sender.isEmpty() || body.isEmpty()) return

        val origin = readOrigin(context, intent)
        val receivedAtMillis = messages.minOf { it.timestampMillis }
        val payload = JSONObject()
            .put("event", "sms.received")
            .put("messageId", UUID.randomUUID().toString())
            .put("sender", sender)
            .put("body", body)
            .put("receivedAtEpochMillis", receivedAtMillis)
            .put("subscriptionId", origin.subscriptionId ?: JSONObject.NULL)
            .put("slotIndex", origin.slotIndex ?: JSONObject.NULL)
            .put("carrierName", origin.carrierName ?: JSONObject.NULL)
            .toString()
        val applicationContext = context.applicationContext
        val pendingResult = goAsync()
        // Bounded protection while the asynchronous broadcast performs network IO.
        // This does not extend Android's broadcast execution deadline.
        val wakeLock = try {
            (applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "${applicationContext.packageName}:sms-relay")
                .apply {
                    setReferenceCounted(false)
                    acquire(30_000L)
                }
        } catch (_: Exception) {
            Log.w(TAG, "SMS relay wake lock unavailable")
            null
        }
        try {
            executor.execute {
                try {
                    val errorCode = deliverSingle(settings, sender, body, origin, receivedAtMillis)
                    SmsRelayStore.recordDelivery(
                        applicationContext,
                        delivered = errorCode == null,
                        errorCode = errorCode,
                        sender = sender,
                        body = body,
                        slotIndex = origin.slotIndex,
                        carrierName = origin.carrierName,
                        receivedAtMillis = receivedAtMillis,
                        mode = settings.mode,
                    )
                    if (errorCode == null) {
                        runCatching { retryUndelivered(applicationContext) }
                    } else {
                        Log.w(TAG, "SMS relay delivery failed after retries ($errorCode)")
                    }
                } finally {
                    try {
                        wakeLock?.release()
                    } finally {
                        pendingResult.finish()
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            try {
                SmsRelayStore.recordDelivery(
                    applicationContext,
                    delivered = false,
                    errorCode = "queue_full",
                    sender = sender,
                    body = body,
                    slotIndex = origin.slotIndex,
                    carrierName = origin.carrierName,
                    receivedAtMillis = receivedAtMillis,
                    mode = settings.mode,
                )
            } finally {
                try {
                    wakeLock?.release()
                } finally {
                    pendingResult.finish()
                }
            }
        }
    }

    private fun readOrigin(context: Context, intent: Intent): SmsRelayOrigin =
        readOriginFromIntent(context, intent)
}

internal class CallRelayReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "NexusCallRelay"
        @Volatile private var lastRingAtMillis: Long = 0L
        @Volatile private var lastRingCaller: String = ""
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED ||
            BuildConfig.FLAVOR !in setOf("nexus", "m")
        ) return
        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
        if (state != TelephonyManager.EXTRA_STATE_RINGING) return
        val settings = runCatching { SmsRelayStore.load(context.applicationContext) }.getOrNull() ?: return
        if (!settings.enabled || settings.token.isNullOrBlank()) return

        @Suppress("DEPRECATION")
        val rawNumber = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)?.trim().orEmpty()
        val now = System.currentTimeMillis()
        synchronized(this) {
            if (rawNumber.isEmpty() && now - lastRingAtMillis < 4000L) {
                return
            }
            if (rawNumber.isNotEmpty() && rawNumber == lastRingCaller && now - lastRingAtMillis < 15_000L) {
                return
            }
            lastRingAtMillis = now
            if (rawNumber.isNotEmpty()) lastRingCaller = rawNumber
        }
        val callerDisplay = rawNumber.ifEmpty { "未知号码 (来电振铃)" }
        val origin = SmsRelayReceiver.readOriginFromIntent(context, intent)
        val appContext = context.applicationContext
        val pendingResult = goAsync()
        Thread {
            try {
                if (rawNumber.isEmpty()) {
                    try { Thread.sleep(500L) } catch (_: InterruptedException) {}
                    if (lastRingCaller.isNotEmpty() && System.currentTimeMillis() - lastRingAtMillis < 2000L) {
                        return@Thread
                    }
                }
                val errorCode = try {
                    when (settings.mode) {
                        SmsRelayMode.TELEGRAM -> {
                            val chatId = settings.telegramChatId ?: "chat_id_missing"
                            TelegramBotClient.sendCallAlert(settings.token, chatId, callerDisplay, origin)
                            null
                        }
                        SmsRelayMode.WEBHOOK -> {
                            val endpoint = settings.endpoint ?: "endpoint_missing"
                            val payload = JSONObject()
                                .put("event", "call.ringing")
                                .put("caller", callerDisplay)
                                .put("receivedAtEpochMillis", now)
                                .put("slotIndex", origin.slotIndex ?: JSONObject.NULL)
                                .put("carrierName", origin.carrierName ?: JSONObject.NULL)
                                .toString()
                            val code = SmsRelayWebhookClient.post(endpoint, settings.token, payload)
                            if (code in 200..299) null else "http_$code"
                        }
                        else -> "invalid_mode"
                    }
                } catch (e: TelegramBotException) {
                    e.errorCode
                } catch (_: Exception) {
                    "network_error"
                }
                SmsRelayStore.recordDelivery(
                    appContext,
                    delivered = errorCode == null,
                    errorCode = errorCode,
                    sender = "📞 来电: $callerDisplay",
                    body = "收到呼入电话振铃提醒 (${origin.label})",
                    slotIndex = origin.slotIndex,
                    carrierName = origin.carrierName,
                    receivedAtMillis = now,
                    mode = settings.mode,
                )
            } catch (e: Exception) {
                Log.w(TAG, "Call relay error: $e")
            } finally {
                pendingResult.finish()
            }
        }.start()
    }
}

internal object SmsRelayWebhookClient {
    fun post(endpoint: String, token: String, payload: String): Int {
        val normalizedEndpoint = SmsRelayEndpointValidator.normalize(endpoint)
        val connection = URL(normalizedEndpoint).openConnection() as? HttpsURLConnection
            ?: throw IllegalArgumentException("https_required")
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.doOutput = true
            connection.setRequestProperty("Authorization", "Bearer $token")
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.setRequestProperty("Accept", "application/json")

            val bytes = payload.toByteArray(StandardCharsets.UTF_8)
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { output -> output.write(bytes) }

            val responseCode = connection.responseCode
            if (responseCode in 200..299) {
                connection.inputStream?.close()
            } else {
                connection.errorStream?.close()
            }
            return responseCode
        } finally {
            connection.disconnect()
        }
    }
}
