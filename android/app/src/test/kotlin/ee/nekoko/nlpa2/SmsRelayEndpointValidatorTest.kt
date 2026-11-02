package ee.nekoko.nlpa2

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SmsRelayEndpointValidatorTest {
    @Test
    fun acceptsAbsoluteHttpsEndpoint() {
        assertEquals(
            "https://relay.example.net/hooks/sms",
            SmsRelayEndpointValidator.normalize(" https://relay.example.net/hooks/sms "),
        )
    }

    @Test
    fun rejectsInsecureOrAmbiguousEndpoints() {
        listOf(
            "http://relay.example.net/hooks/sms",
            "https://user@relay.example.net/hooks/sms",
            "https://relay.example.net/hooks/sms#fragment",
            "https:///hooks/sms",
        ).forEach { endpoint ->
            assertThrows(IllegalArgumentException::class.java) {
                SmsRelayEndpointValidator.normalize(endpoint)
            }
        }
    }
}
