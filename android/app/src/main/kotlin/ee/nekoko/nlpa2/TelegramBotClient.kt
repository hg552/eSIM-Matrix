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

    fun discoverPrivateChat(rawToken: String): TelegramPrivateChat {
        val token = normalizeToken(rawToken)
        val response = execute(token, UPDATES_METHOD, null)
        return parsePrivateStartChat(response.toString())
            ?: throw TelegramBotException("private_chat_not_found")
    }

    fun sendSms(rawToken: String, rawChatId: String, sender: String, body: String, origin: SmsRelayOrigin = SmsRelayOrigin()) {
        val token = normalizeToken(rawToken)
        val chatId = TelegramChatIdValidator.normalize(rawChatId).toLong()
        smsMessages(sender, body, origin).forEach { text ->
            sendText(token, chatId, text)
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
