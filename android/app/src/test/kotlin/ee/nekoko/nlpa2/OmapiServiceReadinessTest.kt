package ee.nekoko.nlpa2

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OmapiServiceReadinessTest {
    @Test
    fun discoveryWaitsForTheAsynchronousServiceCallback() {
        val readiness = OmapiServiceReadiness()
        val connected = AtomicBoolean(false)
        val executor = Executors.newSingleThreadExecutor()
        val result = executor.submit<Boolean> { readiness.awaitConnected({ connected.get() }) }
        assertFalse(result.isDone)
        connected.set(true)
        readiness.onConnected()
        assertTrue(result.get(2, TimeUnit.SECONDS))
        executor.shutdownNow()
    }

    @Test
    fun missingServiceTimesOutWithoutInventingReaders() {
        assertFalse(OmapiServiceReadiness().awaitConnected({ false }, timeoutMillis = 0))
    }

    @Test
    fun oldCallbackCannotReleaseAReplacementServiceWaiter() {
        val old = OmapiServiceReadiness()
        val replacement = OmapiServiceReadiness()
        old.onConnected()
        assertFalse(replacement.awaitConnected({ false }, timeoutMillis = 0))
    }
}
