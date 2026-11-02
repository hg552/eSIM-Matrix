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
                    val errorCode = when (settings.mode) {
                        SmsRelayMode.WEBHOOK -> {
                            val endpoint = settings.endpoint ?: throw IllegalStateException("endpoint_missing")
                            val responseCode = SmsRelayWebhookClient.post(endpoint, token, payload)
                            if (responseCode in 200..299) null else "http_$responseCode"
                        }
                        SmsRelayMode.TELEGRAM -> {
                            val chatId = settings.telegramChatId ?: throw IllegalStateException("chat_id_missing")
                            TelegramBotClient.sendSms(token, chatId, sender, body, origin)
                            null
                        }
                        else -> "invalid_mode"
                    }
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
                } catch (error: TelegramBotException) {
                    SmsRelayStore.recordDelivery(
                        applicationContext,
                        delivered = false,
                        errorCode = error.errorCode,
                        sender = sender,
                        body = body,
                        slotIndex = origin.slotIndex,
                        carrierName = origin.carrierName,
                        receivedAtMillis = receivedAtMillis,
                        mode = settings.mode,
                    )
                    Log.w(TAG, "SMS Telegram delivery failed (${error.errorCode})")
                } catch (_: Exception) {
                    SmsRelayStore.recordDelivery(
                        applicationContext,
                        delivered = false,
                        errorCode = "network_error",
                        sender = sender,
                        body = body,
                        slotIndex = origin.slotIndex,
                        carrierName = origin.carrierName,
                        receivedAtMillis = receivedAtMillis,
                        mode = settings.mode,
                    )
                    Log.w(TAG, "SMS relay delivery failed")
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

    private fun readOrigin(context: Context, intent: Intent): SmsRelayOrigin {
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
            } catch (_: RuntimeException) {
                // Missing permission, unavailable telephony, or a stale subscription.
            }
            if (carrierName == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                try {
                    carrierName = (context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager)
                        ?.createForSubscriptionId(subscriptionId)?.simOperatorName?.takeIf { it.isNotBlank() }
                } catch (_: RuntimeException) {
                    // Keep unknown rather than attributing this SMS to another SIM.
                }
            }
        }
        return SmsRelayOrigin(subscriptionId, slotIndex, carrierName)
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
