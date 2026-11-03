package ee.nekoko.nlpa2

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.net.URI
import java.net.URISyntaxException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal object SmsRelayMode {
    const val WEBHOOK = "webhook"
    const val TELEGRAM = "telegram"
}

internal data class SmsRelaySettings(
    val mode: String,
    val enabled: Boolean,
    val endpoint: String?,
    val telegramChatId: String?,
    val token: String?,
    val webhookToken: String?,
    val telegramToken: String?,
    val lastDeliveryAtMillis: Long?,
    val lastDeliveryError: String?,
)

internal object SmsRelayEndpointValidator {
    fun normalize(rawValue: String): String {
        val value = rawValue.trim()
        require(value.isNotEmpty()) { "invalid_endpoint" }

        val uri = try {
            URI(value)
        } catch (error: URISyntaxException) {
            throw IllegalArgumentException("invalid_endpoint", error)
        }
        require(uri.scheme.equals("https", ignoreCase = true)) { "https_required" }
        require(!uri.host.isNullOrBlank()) { "invalid_endpoint" }
        require(uri.userInfo == null && uri.fragment == null) { "invalid_endpoint" }
        require(uri.port == -1 || uri.port in 1..65535) { "invalid_endpoint" }
        return value
    }
}
internal object TelegramChatIdValidator {
    private val chatIdPattern = Regex("^-?[1-9][0-9]{0,18}$")

    fun normalize(rawValue: String): String {
        val value = rawValue.trim()
        require(chatIdPattern.matches(value)) { "invalid_chat_id" }
        require(value.toLongOrNull()?.let { it != 0L } == true) { "invalid_chat_id" }
        return value
    }
}

internal data class GatewaySettings(
    val enabled: Boolean,
    val apiToken: String?,
)

internal object SmsRelayStore {
    private const val PREFERENCES = "euicc_nexus_sms_relay"
    private const val KEY_ALIAS = "ee.nekoko.nlpa2.nexus.sms_relay"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_MODE = "mode"
    private const val KEY_ENDPOINT = "endpoint"
    private const val KEY_TELEGRAM_CHAT_ID = "telegram_chat_id"
    private const val KEY_WEBHOOK_TOKEN_IV = "token_iv"
    private const val KEY_WEBHOOK_TOKEN_CIPHERTEXT = "token_ciphertext"
    private const val KEY_TELEGRAM_TOKEN_IV = "telegram_token_iv"
    private const val KEY_TELEGRAM_TOKEN_CIPHERTEXT = "telegram_token_ciphertext"
    private const val KEY_LAST_DELIVERY = "last_delivery_at"
    private const val KEY_LAST_ERROR = "last_delivery_error"
    private const val MAX_TOKEN_BYTES = 4096
    private const val GATEWAY_KEY_ALIAS = "ee.nekoko.nlpa2.gateway"
    private const val KEY_GATEWAY_ENABLED = "gateway_enabled"
    private const val KEY_GATEWAY_TOKEN_IV = "gateway_token_iv"
    private const val KEY_GATEWAY_TOKEN_CIPHERTEXT = "gateway_token_ciphertext"
    private val apiTokenPattern = Regex("^[A-Za-z0-9_-]{43}$")
    private const val KEY_SMS_HISTORY = "sms_history_v1"
    private const val MAX_HISTORY_ITEMS = 100

    @Synchronized
    fun load(context: Context): SmsRelaySettings {
        val preferences = preferences(context)
        val mode = if (preferences.getString(KEY_MODE, SmsRelayMode.TELEGRAM) == SmsRelayMode.WEBHOOK) {
            SmsRelayMode.WEBHOOK
        } else {
            SmsRelayMode.TELEGRAM
        }
        val endpoint = preferences.getString(KEY_ENDPOINT, null)
        val telegramChatId = preferences.getString(KEY_TELEGRAM_CHAT_ID, null)?.let { raw ->
            runCatching { TelegramChatIdValidator.normalize(raw) }.getOrNull()
        }
        val webhookToken = try {
            decryptToken(
                preferences.getString(KEY_WEBHOOK_TOKEN_IV, null),
                preferences.getString(KEY_WEBHOOK_TOKEN_CIPHERTEXT, null),
            )
        } catch (_: Exception) {
            null
        }
        val telegramToken = try {
            decryptToken(
                preferences.getString(KEY_TELEGRAM_TOKEN_IV, null),
                preferences.getString(KEY_TELEGRAM_TOKEN_CIPHERTEXT, null),
            )
        } catch (_: Exception) {
            null
        }

        val activeToken = if (mode == SmsRelayMode.TELEGRAM) telegramToken else webhookToken
        val configured = when (mode) {
            SmsRelayMode.TELEGRAM -> !telegramChatId.isNullOrBlank() && !telegramToken.isNullOrBlank()
            else -> !endpoint.isNullOrBlank() && !webhookToken.isNullOrBlank()
        }
        val enabled = preferences.getBoolean(KEY_ENABLED, false) && configured
        val lastDelivery = if (preferences.contains(KEY_LAST_DELIVERY)) {
            preferences.getLong(KEY_LAST_DELIVERY, 0L)
        } else {
            null
        }
        return SmsRelaySettings(
            mode = mode,
            enabled = enabled,
            endpoint = endpoint,
            telegramChatId = telegramChatId,
            token = activeToken,
            webhookToken = webhookToken,
            telegramToken = telegramToken,
            lastDeliveryAtMillis = lastDelivery,
            lastDeliveryError = preferences.getString(KEY_LAST_ERROR, null),
        )
    }

    @Synchronized
    fun save(
        context: Context,
        rawMode: String,
        rawEndpoint: String?,
        rawTelegramChatId: String?,
        rawToken: String?,
        enabled: Boolean,
    ) {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) { "secure_storage_unavailable" }
        val mode = rawMode.trim()
        require(mode == SmsRelayMode.WEBHOOK || mode == SmsRelayMode.TELEGRAM) { "invalid_mode" }
        val existing = load(context)
        val endpoint = if (mode == SmsRelayMode.WEBHOOK) {
            val value = rawEndpoint?.trim()?.takeIf(String::isNotEmpty) ?: existing.endpoint.orEmpty()
            SmsRelayEndpointValidator.normalize(value)
        } else {
            existing.endpoint
        }
        val telegramChatId = if (mode == SmsRelayMode.TELEGRAM) {
            val value = rawTelegramChatId?.trim()?.takeIf(String::isNotEmpty)
                ?: existing.telegramChatId.orEmpty()
            TelegramChatIdValidator.normalize(value)
        } else {
            existing.telegramChatId
        }
        val suppliedToken = rawToken?.trim()?.takeIf(String::isNotEmpty)
        val token = suppliedToken ?: if (mode == SmsRelayMode.TELEGRAM) {
            existing.telegramToken
        } else {
            existing.webhookToken
        }
        require(!token.isNullOrBlank()) { "token_required" }
        require(token.toByteArray(Charsets.UTF_8).size <= MAX_TOKEN_BYTES) { "token_too_large" }

        val editor = preferences(context).edit()
            .putString(KEY_MODE, mode)
            .putBoolean(KEY_ENABLED, enabled)
            .remove(KEY_LAST_ERROR)
        if (mode == SmsRelayMode.WEBHOOK) {
            editor.putString(KEY_ENDPOINT, endpoint)
        } else {
            editor.putString(KEY_TELEGRAM_CHAT_ID, telegramChatId)
        }
        if (suppliedToken != null) {
            if (mode == SmsRelayMode.TELEGRAM) {
                encryptToken(editor, suppliedToken, KEY_TELEGRAM_TOKEN_IV, KEY_TELEGRAM_TOKEN_CIPHERTEXT)
            } else {
                encryptToken(editor, suppliedToken, KEY_WEBHOOK_TOKEN_IV, KEY_WEBHOOK_TOKEN_CIPHERTEXT)
            }
        }
        check(editor.commit()) { "storage_error" }
    }

    @Synchronized
    fun loadGateway(context: Context): GatewaySettings {
        val preferences = preferences(context)
        var token: String? = null
        var tokenUnavailable = false
        try {
            token = decryptToken(
                preferences.getString(KEY_GATEWAY_TOKEN_IV, null),
                preferences.getString(KEY_GATEWAY_TOKEN_CIPHERTEXT, null),
                GATEWAY_KEY_ALIAS,
            )
        } catch (_: Exception) {
            tokenUnavailable = true
        }
        val enabled = preferences.getBoolean(KEY_GATEWAY_ENABLED, false) &&
            !token.isNullOrBlank() && !tokenUnavailable
        if (preferences.getBoolean(KEY_GATEWAY_ENABLED, false) && !enabled) {
            preferences.edit().putBoolean(KEY_GATEWAY_ENABLED, false).commit()
        }
        return GatewaySettings(enabled = enabled, apiToken = token)
    }

    @Synchronized
    fun saveGatewayToken(context: Context, rawToken: String) {
        check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) { "secure_storage_unavailable" }
        val token = rawToken.trim()
        require(apiTokenPattern.matches(token)) { "invalid_api_token" }
        val editor = preferences(context).edit()
        encryptToken(
            editor,
            token,
            KEY_GATEWAY_TOKEN_IV,
            KEY_GATEWAY_TOKEN_CIPHERTEXT,
            GATEWAY_KEY_ALIAS,
        )
        check(editor.commit()) { "storage_error" }
    }

    @Synchronized
    fun setGatewayEnabled(context: Context, enabled: Boolean) {
        if (enabled) require(!loadGateway(context).apiToken.isNullOrBlank()) { "token_required" }
        check(preferences(context).edit().putBoolean(KEY_GATEWAY_ENABLED, enabled).commit()) {
            "storage_error"
        }
    }

    @Synchronized
    fun clearGatewayToken(context: Context) {
        check(
            preferences(context).edit()
                .putBoolean(KEY_GATEWAY_ENABLED, false)
                .remove(KEY_GATEWAY_TOKEN_IV)
                .remove(KEY_GATEWAY_TOKEN_CIPHERTEXT)
                .commit(),
        ) { "storage_error" }
        runCatching {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                .deleteEntry(GATEWAY_KEY_ALIAS)
        }
    }

    @Synchronized
    fun clearToken(context: Context) {
        val committed = preferences(context).edit()
            .putBoolean(KEY_ENABLED, false)
            .remove(KEY_WEBHOOK_TOKEN_IV)
            .remove(KEY_WEBHOOK_TOKEN_CIPHERTEXT)
            .remove(KEY_TELEGRAM_TOKEN_IV)
            .remove(KEY_TELEGRAM_TOKEN_CIPHERTEXT)
            .commit()
        check(committed) { "storage_error" }
        runCatching {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(KEY_ALIAS)
        }
    }

    @Synchronized
    fun recordDelivery(
        context: Context,
        delivered: Boolean,
        errorCode: String? = null,
        sender: String? = null,
        body: String? = null,
        slotIndex: Int? = null,
        carrierName: String? = null,
        receivedAtMillis: Long = System.currentTimeMillis(),
        mode: String = SmsRelayMode.TELEGRAM,
    ) {
        val prefs = preferences(context)
        val editor = prefs.edit()
        if (delivered) {
            editor.putLong(KEY_LAST_DELIVERY, System.currentTimeMillis())
                .remove(KEY_LAST_ERROR)
        } else {
            editor.putString(KEY_LAST_ERROR, errorCode ?: "network_error")
        }
        if (!sender.isNullOrBlank() && !body.isNullOrBlank()) {
            val existingRaw = prefs.getString(KEY_SMS_HISTORY, null)
            val existingArr = runCatching {
                if (existingRaw.isNullOrBlank()) JSONArray() else JSONArray(existingRaw)
            }.getOrDefault(JSONArray())
            val nextArr = JSONArray()
            val item = JSONObject()
                .put("id", UUID.randomUUID().toString())
                .put("sender", sender)
                .put("body", body)
                .put("slotIndex", slotIndex ?: JSONObject.NULL)
                .put("carrierName", carrierName ?: JSONObject.NULL)
                .put("receivedAtMillis", receivedAtMillis)
                .put("mode", mode)
                .put("delivered", delivered)
                .put("errorCode", errorCode ?: JSONObject.NULL)
            nextArr.put(item)
            val limit = minOf(existingArr.length(), MAX_HISTORY_ITEMS - 1)
            for (i in 0 until limit) {
                existingArr.optJSONObject(i)?.let(nextArr::put)
            }
            editor.putString(KEY_SMS_HISTORY, nextArr.toString())
        }
        editor.commit()
    }

    @Synchronized
    fun recordIncomingIfNew(
        context: Context,
        sender: String,
        body: String,
        slotIndex: Int? = null,
        carrierName: String? = null,
        receivedAtMillis: Long = System.currentTimeMillis(),
        mode: String = SmsRelayMode.TELEGRAM,
        dedupWindowMillis: Long = 0L,
    ): String? {
        if (sender.isBlank() || body.isBlank()) return null
        val prefs = preferences(context)
        val existingRaw = prefs.getString(KEY_SMS_HISTORY, null)
        val existingArr = runCatching {
            if (existingRaw.isNullOrBlank()) JSONArray() else JSONArray(existingRaw)
        }.getOrDefault(JSONArray())
        if (dedupWindowMillis > 0L) {
            val checkCount = minOf(existingArr.length(), 25)
            for (i in 0 until checkCount) {
                val obj = existingArr.optJSONObject(i) ?: continue
                val prevSender = obj.optString("sender", "")
                val prevBody = obj.optString("body", "")
                val prevTime = obj.optLong("receivedAtMillis", 0L)
                if (prevSender == sender && prevBody == body &&
                    kotlin.math.abs(receivedAtMillis - prevTime) <= dedupWindowMillis
                ) {
                    return null
                }
            }
        }
        val id = UUID.randomUUID().toString()
        val nextArr = JSONArray()
        val item = JSONObject()
            .put("id", id)
            .put("sender", sender)
            .put("body", body)
            .put("slotIndex", slotIndex ?: JSONObject.NULL)
            .put("carrierName", carrierName ?: JSONObject.NULL)
            .put("receivedAtMillis", receivedAtMillis)
            .put("mode", mode)
            .put("delivered", false)
            .put("errorCode", "sending")
        nextArr.put(item)
        val limit = minOf(existingArr.length(), MAX_HISTORY_ITEMS - 1)
        for (i in 0 until limit) {
            existingArr.optJSONObject(i)?.let(nextArr::put)
        }
        prefs.edit().putString(KEY_SMS_HISTORY, nextArr.toString()).commit()
        return id
    }

    @Synchronized
    fun loadHistory(context: Context): List<Map<String, Any?>> {
        val raw = preferences(context).getString(KEY_SMS_HISTORY, null)
        if (raw.isNullOrBlank()) return emptyList()
        val arr = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val list = ArrayList<Map<String, Any?>>(arr.length())
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            val id = obj.optString("id", "")
            val sender = obj.optString("sender", "")
            val body = obj.optString("body", "")
            if (id.isEmpty() || body.isEmpty()) continue
            val slotIndex = if (obj.isNull("slotIndex")) null else obj.optInt("slotIndex", -1).takeIf { it >= 0 }
            val carrierName = if (obj.isNull("carrierName")) null else obj.optString("carrierName", "").takeIf { it.isNotBlank() }
            val errorCode = if (obj.isNull("errorCode")) null else obj.optString("errorCode", "").takeIf { it.isNotBlank() }
            list.add(
                mapOf(
                    "id" to id,
                    "sender" to sender,
                    "body" to body,
                    "otp" to TelegramBotClient.extractOtp(body),
                    "slotIndex" to slotIndex,
                    "carrierName" to carrierName,
                    "receivedAtMillis" to obj.optLong("receivedAtMillis", 0L),
                    "mode" to obj.optString("mode", SmsRelayMode.TELEGRAM),
                    "delivered" to obj.optBoolean("delivered", true),
                    "errorCode" to errorCode,
                ),
            )
        }
        return list
    }

    @Synchronized
    fun markDelivered(
        context: Context,
        targetId: String,
        delivered: Boolean,
        errorCode: String? = null,
    ) {
        val prefs = preferences(context)
        val raw = prefs.getString(KEY_SMS_HISTORY, null) ?: return
        val arr = runCatching { JSONArray(raw) }.getOrNull() ?: return
        var updated = false
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            if (obj.optString("id", "") == targetId) {
                obj.put("delivered", delivered)
                obj.put("errorCode", errorCode ?: JSONObject.NULL)
                updated = true
                break
            }
        }
        if (updated) {
            val editor = prefs.edit().putString(KEY_SMS_HISTORY, arr.toString())
            if (delivered) {
                editor.putLong(KEY_LAST_DELIVERY, System.currentTimeMillis())
                    .remove(KEY_LAST_ERROR)
            }
            editor.commit()
        }
    }

    @Synchronized
    fun deleteHistoryItem(context: Context, targetId: String) {
        val prefs = preferences(context)
        val raw = prefs.getString(KEY_SMS_HISTORY, null) ?: return
        val arr = runCatching { JSONArray(raw) }.getOrNull() ?: return
        val nextArr = JSONArray()
        for (i in 0 until arr.length()) {
            val obj = arr.optJSONObject(i) ?: continue
            if (obj.optString("id", "") != targetId) {
                nextArr.put(obj)
            }
        }
        prefs.edit().putString(KEY_SMS_HISTORY, nextArr.toString()).commit()
    }

    @Synchronized
    fun clearHistory(context: Context) {
        preferences(context).edit().remove(KEY_SMS_HISTORY).commit()
    }

    private fun preferences(context: Context) =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    private fun encryptToken(
        editor: android.content.SharedPreferences.Editor,
        token: String,
        ivKey: String,
        ciphertextKey: String,
        keyAlias: String = KEY_ALIAS,
    ) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey(keyAlias))
        val ciphertext = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        editor.putString(ivKey, Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString(ciphertextKey, Base64.encodeToString(ciphertext, Base64.NO_WRAP))
    }

    private fun decryptToken(
        ivValue: String?,
        ciphertextValue: String?,
        keyAlias: String = KEY_ALIAS,
    ): String? {
        if (ivValue == null || ciphertextValue == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return null
        }
        val iv = Base64.decode(ivValue, Base64.NO_WRAP)
        val ciphertext = Base64.decode(ciphertextValue, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(keyAlias), GCMParameterSpec(128, iv))
        return cipher.doFinal(ciphertext).toString(Charsets.UTF_8)
    }

    private fun getOrCreateKey(keyAlias: String = KEY_ALIAS): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(keyAlias, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }
}
