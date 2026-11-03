package ee.nekoko.nlpa2

import org.json.JSONObject
import java.io.InputStream
import java.io.InputStreamReader
import java.net.URL
import java.nio.charset.StandardCharsets
import javax.net.ssl.HttpsURLConnection

internal data class TelegramPrivateChat(
    val chatId: String,
    val displayName: String,
)

internal class TelegramBotException(val errorCode: String) : Exception(errorCode)

internal object TelegramBotClient {
    private const val MAX_TOKEN_BYTES = 4096
    private const val MAX_RESPONSE_CHARS = 64 * 1024
    private const val MAX_MESSAGE_UTF16_UNITS = 4000
    private const val CONNECT_TIMEOUT_MILLIS = 5000
    private const val READ_TIMEOUT_MILLIS = 5000
    private const val UPDATES_METHOD =
        "getUpdates?limit=50&timeout=0&allowed_updates=%5B%22message%22%5D"
    private val tokenPattern = Regex("^[0-9]+:[A-Za-z0-9_-]+$")
    private val startCommandPattern = Regex("^/start(?:@[A-Za-z0-9_]+)?(?:\\s|$)")
    private val keywordOtpPattern = Regex(
        "(?:验证码|驗證碼|动态码|校验码|認証コード|코드|verification\\s*code|security\\s*code|auth(?:entication)?\\s*code|confirmation\\s*code|login\\s*code|passcode|one-time\\s*password|otp|pin|code)[^0-9A-Za-z]{0,16}((?:[A-Z]-)?[0-9]{4,8})(?![0-9])",
        RegexOption.IGNORE_CASE,
    )
    private val prefixOtpPattern = Regex("\\b([A-Z]-[0-9]{4,8})\\b")
    private val standaloneDigitsPattern = Regex("(?<![0-9+-])([0-9]{4,8})(?![0-9])")
    fun discoverPrivateChat(rawToken: String): TelegramPrivateChat {
        val token = normalizeToken(rawToken)
        val response = execute(token, UPDATES_METHOD, null)
        return parsePrivateStartChat(response.toString())
            ?: throw TelegramBotException("private_chat_not_found")
    }

    fun sendSms(
        rawToken: String,
        rawChatId: String,
        sender: String,
        body: String,
        origin: SmsRelayOrigin = SmsRelayOrigin(),
    ) {
        val token = normalizeToken(rawToken)
        val chatId = TelegramChatIdValidator.normalize(rawChatId).toLong()
        val chunks = htmlSmsMessages(sender, body, origin)
        chunks.forEachIndexed { index, htmlText ->
            val isLast = index == chunks.lastIndex
            sendHtmlText(token, chatId, htmlText, includeQuickActions = isLast)
        }
    }

    fun sendCallAlert(
        rawToken: String,
        rawChatId: String,
        caller: String,
        origin: SmsRelayOrigin = SmsRelayOrigin(),
    ) {
        val token = normalizeToken(rawToken)
        val chatId = TelegramChatIdValidator.normalize(rawChatId).toLong()
        val safeCaller = escapeHtml(caller.replace('\n', ' ').replace('\r', ' ').take(128))
        val html = buildString {
            append("<b>").append(escapeHtml(origin.label)).append("</b>\n")
            append("📞 <b>收到呼入来电提醒</b>\n")
            append("👤 <b>主叫号码：</b><code>").append(safeCaller).append("</code>")
        }
        sendHtmlText(token, chatId, html, includeQuickActions = true)
    }

    internal fun extractOtp(body: String): String? {
        keywordOtpPattern.find(body)?.groupValues?.getOrNull(1)?.takeIf { it.isNotEmpty() }?.let {
            return it
        }
        prefixOtpPattern.find(body)?.groupValues?.getOrNull(1)?.takeIf { it.isNotEmpty() }?.let {
            return it
        }
        val candidates = standaloneDigitsPattern.findAll(body)
            .map { it.groupValues[1] }
            .filterNot { token ->
                token.length == 4 && token.toIntOrNull()?.let { it in 1990..2035 } == true
            }
            .toList()
        if (candidates.isEmpty()) return null
        return candidates.firstOrNull { it.length == 6 } ?: candidates.first()
    }

    internal fun escapeHtml(value: String): String = buildString(value.length + 16) {
        for (ch in value) {
            when (ch) {
                '&' -> append("&amp;")
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                else -> append(ch)
            }
        }
    }

    internal fun htmlSmsMessages(
        sender: String,
        body: String,
        origin: SmsRelayOrigin = SmsRelayOrigin(),
    ): List<String> {
        val plainChunks = smsMessages(sender, body, origin)
        val otp = extractOtp(body)
        val singleLineSender = sender.replace('\n', ' ').replace('\r', ' ')
        val safeSender = singleLineSender.substring(0, safeChunkEnd(singleLineSender, 0, 256))
        return plainChunks.mapIndexed { idx, chunk ->
            val rawBodyPart = chunk.substringAfter("\n\n", "")
            buildString {
                append("<b>").append(escapeHtml(origin.label)).append("</b>\n")
                append("📩 <b>来自：</b><code>").append(escapeHtml(safeSender)).append("</code>")
                if (idx > 0) append(" <i>(续)</i>")
                if (idx == 0 && otp != null) {
                    append("\n🔑 <b>验证码 (点击复制)：</b><code>").append(escapeHtml(otp)).append("</code>")
                }
                append("\n\n")
                append(escapeHtml(rawBodyPart))
            }
        }
    }
    fun sendTestMessage(rawToken: String, rawChatId: String) {
        val token = normalizeToken(rawToken)
        val chatId = TelegramChatIdValidator.normalize(rawChatId).toLong()
        sendText(token, chatId, "eUICC-Nexus SMS relay test")
    }

    internal fun parsePrivateStartChat(responseJson: String): TelegramPrivateChat? {
        val response = runCatching { JSONObject(responseJson) }.getOrNull() ?: return null
        if (!response.optBoolean("ok", false)) return null
        val updates = response.optJSONArray("result") ?: return null
        var latestMatch: TelegramPrivateChat? = null

        for (index in 0 until updates.length()) {
            val message = updates.optJSONObject(index)?.optJSONObject("message") ?: continue
            val chat = message.optJSONObject("chat") ?: continue
            val sender = message.optJSONObject("from") ?: continue
            val chatId = chat.optLong("id", 0L)
            if (chat.optString("type") != "private" ||
                chatId <= 0L ||
                sender.optLong("id", 0L) != chatId ||
                sender.optBoolean("is_bot", false)
            ) {
                continue
            }

            val text = message.optString("text", "").trimStart()
            if (!startCommandPattern.containsMatchIn(text)) continue

            val username = sender.optString("username", "").takeIf(String::isNotBlank)
            val firstName = sender.optString("first_name", "").takeIf(String::isNotBlank)
            val lastName = sender.optString("last_name", "").takeIf(String::isNotBlank)
            val name = listOfNotNull(firstName, lastName).joinToString(" ")
            latestMatch = TelegramPrivateChat(
                chatId = chatId.toString(),
                displayName = username?.let { "@$it" }
                    ?: name.takeIf(String::isNotBlank)
                    ?: "Telegram user $chatId",
            )
        }
        return latestMatch
    }

    internal fun smsMessages(sender: String, body: String, origin: SmsRelayOrigin = SmsRelayOrigin()): List<String> {
        val singleLineSender = sender.replace('\n', ' ').replace('\r', ' ')
        val safeSender = singleLineSender.substring(0, safeChunkEnd(singleLineSender, 0, 256))
        val firstHeader = "${origin.label}\nSMS from: $safeSender\n\n"
        val continuationHeader = "${origin.label}\nSMS from: $safeSender (continued)\n\n"
        val messages = mutableListOf<String>()
        var bodyOffset = 0

        while (bodyOffset < body.length) {
            val header = if (messages.isEmpty()) firstHeader else continuationHeader
            val capacity = MAX_MESSAGE_UTF16_UNITS - header.length
            val end = safeChunkEnd(body, bodyOffset, capacity)
            if (end <= bodyOffset) throw TelegramBotException("message_too_large")
            messages += header + body.substring(bodyOffset, end)
            bodyOffset = end
        }

        if (messages.isEmpty()) messages += firstHeader
        return messages
    }

    private fun safeChunkEnd(value: String, start: Int, maxUtf16Units: Int): Int {
        var end = minOf(value.length, start + maxUtf16Units)
        if (end < value.length && end > start &&
            Character.isHighSurrogate(value[end - 1]) && Character.isLowSurrogate(value[end])
        ) {
            end--
        }
        return end
    }

    private fun sendText(token: String, chatId: Long, text: String) {
        val payload = JSONObject()
            .put("chat_id", chatId)
            .put("text", text)
            .toString()
        execute(token, "sendMessage", payload)
    }

    private fun sendHtmlText(
        token: String,
        chatId: Long,
        htmlText: String,
        includeQuickActions: Boolean = false,
    ) {
        val payload = JSONObject()
            .put("chat_id", chatId)
            .put("text", htmlText)
            .put("parse_mode", "HTML")
        if (includeQuickActions) {
            val row = org.json.JSONArray()
                .put(JSONObject().put("text", "🏠 已收到码，切回主卡").put("callback_data", "cmd:back"))
                .put(JSONObject().put("text", "📋 卡列表").put("callback_data", "cmd:list"))
                .put(JSONObject().put("text", "📡 状态").put("callback_data", "cmd:status"))
            val markup = JSONObject().put("inline_keyboard", org.json.JSONArray().put(row))
            payload.put("reply_markup", markup)
        }
        execute(token, "sendMessage", payload.toString())
    }

    private fun normalizeToken(rawValue: String): String {
        val token = rawValue.trim()
        if (token.toByteArray(StandardCharsets.UTF_8).size > MAX_TOKEN_BYTES ||
            !tokenPattern.matches(token)
        ) {
            throw TelegramBotException("invalid_bot_token")
        }
        return token
    }

    private fun execute(token: String, method: String, payload: String?): JSONObject {
        val connection = try {
            URL("https://api.telegram.org/bot$token/$method")
                .openConnection() as? HttpsURLConnection
                ?: throw TelegramBotException("telegram_transport_error")
        } catch (error: TelegramBotException) {
            throw error
        } catch (_: Exception) {
            throw TelegramBotException("telegram_network_error")
        }

        try {
            connection.connectTimeout = CONNECT_TIMEOUT_MILLIS
            connection.readTimeout = READ_TIMEOUT_MILLIS
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            if (payload != null) {
                val bytes = payload.toByteArray(StandardCharsets.UTF_8)
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { output -> output.write(bytes) }
            } else {
                connection.requestMethod = "GET"
            }

            val responseCode = connection.responseCode
            val stream = if (responseCode in 200..299) connection.inputStream else connection.errorStream
            val responseBody = readBounded(stream)
            if (responseCode == 429) {
                val retryAfterSec = runCatching {
                    JSONObject(responseBody)
                        .optJSONObject("parameters")
                        ?.optInt("retry_after", 2)
                        ?.coerceIn(1, 10)
                }.getOrNull() ?: 2
                try {
                    Thread.sleep(retryAfterSec * 1000L)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
                throw TelegramBotException("telegram_rate_limited")
            }
            if (responseCode !in 200..299) {
                throw TelegramBotException("telegram_api_error")
            }
            val response = try {
                JSONObject(responseBody)
            } catch (_: Exception) {
                throw TelegramBotException("telegram_invalid_response")
            }
            if (!response.optBoolean("ok", false)) {
                throw TelegramBotException("telegram_api_rejected")
            }
            return response
        } catch (error: TelegramBotException) {
            throw error
        } catch (_: Exception) {
            throw TelegramBotException("telegram_network_error")
        } finally {
            connection.disconnect()
        }
    }

    private fun readBounded(stream: InputStream?): String {
        if (stream == null) return ""
        InputStreamReader(stream, StandardCharsets.UTF_8).use { reader ->
            val buffer = CharArray(2048)
            val result = StringBuilder()
            while (true) {
                val count = reader.read(buffer)
                if (count < 0) break
                if (result.length + count > MAX_RESPONSE_CHARS) {
                    throw TelegramBotException("telegram_response_too_large")
                }
                result.append(buffer, 0, count)
            }
            return result.toString()
        }
    }
}
