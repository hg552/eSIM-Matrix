package ee.nekoko.nlpa2

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TelegramBotClientTest {
    @Test
    fun discoversOnlyPrivateStartFromThatSameUser() {
        val response = """
            {
              "ok": true,
              "result": [
                {"message":{"chat":{"id":-1001,"type":"supergroup"},"from":{"id":91},"text":"/start"}},
                {"message":{"chat":{"id":42,"type":"private"},"from":{"id":41,"is_bot":false},"text":"/start"}},
                {"message":{"chat":{"id":42,"type":"private"},"from":{"id":42,"is_bot":false,"username":"nexus_owner"},"text":"/start"}}
              ]
            }
        """.trimIndent()

        val chat = TelegramBotClient.parsePrivateStartChat(response)

        assertNotNull(chat)
        assertEquals("42", chat!!.chatId)
        assertEquals("@nexus_owner", chat.displayName)
    }

    @Test
    fun ignoresPrivateUpdatesWithoutStartCommand() {
        val response = """
            {"ok":true,"result":[
              {"message":{"chat":{"id":42,"type":"private"},"from":{"id":42,"is_bot":false},"text":"hello"}},
              {"message":{"chat":{"id":43,"type":"private"},"from":{"id":43,"is_bot":true},"text":"/start"}}
            ]}
        """.trimIndent()

        assertNull(TelegramBotClient.parsePrivateStartChat(response))
    }


    @Test
    fun longSmsIsSplitWithoutLossOrBrokenSurrogatePairs() {
        val body = "A".repeat(3990) + "😀" + "B".repeat(100)

        val messages = TelegramBotClient.smsMessages("+3725550100", body)

        assertTrue(messages.size > 1)
        assertTrue(messages.all { it.length <= 4000 })
        val bodies = messages.map { it.substringAfter("\n\n") }
        assertFalse(bodies.any { it.isNotEmpty() && Character.isHighSurrogate(it.last()) })
        assertFalse(bodies.any { it.isNotEmpty() && Character.isLowSurrogate(it.first()) })
        assertEquals(body, bodies.joinToString(""))
    }

    @Test
    fun acceptsExplicitPrivateGroupAndChannelDestinations() {
        listOf("123456", "-123456", "-1001234567890").forEach { id ->
            assertEquals(id, TelegramChatIdValidator.normalize(" $id "))
        }
    }

    @Test
    fun rejectsMalformedZeroAndOverflowDestinations() {
        listOf("", "0", "-0", "+123", "01", "-01", "12 34", "9223372036854775808", "-9223372036854775809").forEach { id ->
            assertThrows(IllegalArgumentException::class.java) { TelegramChatIdValidator.normalize(id) }
        }
    }

    @Test
    fun smsAboveOldReceiverLimitPreservesEveryCharacterAndOrigin() {
        val body = "验证码 😀 123456 ".repeat(800)
        val origin = SmsRelayOrigin(subscriptionId = 7, slotIndex = 1, carrierName = "Test Carrier")
        val parts = TelegramBotClient.smsMessages("10086", body, origin)
        assertEquals(body, parts.joinToString("") { it.substringAfter("\n\n") })
        assertTrue(parts.all { it.length <= 4000 && it.startsWith(origin.label + "\n") })
    }

    @Test
    fun missingSimMetadataDoesNotPretendToBeSimOne() {
        assertEquals("[SIM unknown]", SmsRelayOrigin().label)
        assertEquals("[SIM 1 · subId 7]", SmsRelayOrigin(7, 0).label)
        assertEquals("[SIM 2 · subId 8 · Carrier name]", SmsRelayOrigin(8, 1, "Carrier\nname").label)
    }

    @Test
    fun senderTruncationDoesNotBreakSurrogatePair() {
        val part = TelegramBotClient.smsMessages("A".repeat(255) + "😀", "123456").single()
        assertFalse(part.any { Character.isSurrogate(it) })
        assertTrue(part.endsWith("\n\n123456"))
    }
}
