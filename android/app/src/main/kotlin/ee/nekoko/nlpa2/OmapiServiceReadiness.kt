package ee.nekoko.nlpa2

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** One connection attempt; a late callback must not release a replacement service's waiters. */
internal class OmapiServiceReadiness {
    private val connected = CountDownLatch(1)

    fun onConnected() = connected.countDown()

    fun awaitConnected(
            isConnected: () -> Boolean,
            timeoutMillis: Long = 3_000,
    ): Boolean {
        if (isConnected()) return true
        return try {
            connected.await(timeoutMillis, TimeUnit.MILLISECONDS) && isConnected()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
    }
}
