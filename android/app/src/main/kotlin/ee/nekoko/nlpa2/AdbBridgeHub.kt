package ee.nekoko.nlpa2

import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import java.security.SecureRandom

/**
 * The meeting point between the app's provider and its plugin.
 *
 * [AdbBridgeProvider] and [AdbBridgePlugin] run in the same process but are
 * created by the platform independently, so they find each other here rather
 * than by holding references. The provider writes the binder a `shell` helper
 * hands over; the plugin reads it and listens for it coming and going.
 *
 * A connection is expected only inside a short window the plugin opens when the
 * user is on the connect screen. The window carries a one-time nonce: the
 * helper has to quote it to register, which ties a registration to a
 * connection the user actually started and keeps a stale helper from taking the
 * session over later. The nonce is not the real gate, though — the provider
 * only accepts a registration from the `shell` user, which an ordinary app
 * cannot pretend to be.
 */
object AdbBridgeHub {
    private const val TAG = "AdbBridgeHub"

    /** Bumped when the wire changes in a way an old helper would get wrong. */
    const val PROTOCOL_VERSION = 1

    /** The user a real helper runs as. */
    const val SHELL_UID = 2000

    private val random = SecureRandom()

    private var windowNonce: String? = null
    private var windowExpiresAt: Long = 0L

    private var binder: IBinder? = null
    private var deathRecipient: IBinder.DeathRecipient? = null

    /** Told when a helper connects or goes away, on whatever thread it happens. */
    @Volatile
    var listener: Listener? = null

    interface Listener {
        fun onBridgeConnected()

        fun onBridgeDisconnected()
    }

    /**
     * Open a connection window and return its nonce. The plugin calls this when
     * the user asks to connect; the nonce goes into nothing the user sees, the
     * helper fetches it from the provider at run time.
     */
    @Synchronized
    fun openWindow(timeoutMs: Long): String {
        val nonce = ByteArray(24).also { random.nextBytes(it) }
            .joinToString("") { "%02x".format(it) }
        windowNonce = nonce
        windowExpiresAt = SystemClock.elapsedRealtime() + timeoutMs
        Log.i(TAG, "connection window open for ${timeoutMs}ms")
        return nonce
    }

    @Synchronized
    fun closeWindow() {
        windowNonce = null
        windowExpiresAt = 0L
    }

    /** The nonce a helper may quote right now, or null if no window is open. */
    @Synchronized
    fun currentNonce(): String? {
        if (windowNonce != null && SystemClock.elapsedRealtime() > windowExpiresAt) {
            Log.i(TAG, "connection window expired")
            windowNonce = null
        }
        return windowNonce
    }

    /**
     * Accept a helper's binder, if a window is open and `nonce` matches it. The
     * caller's user is checked by the provider before this is reached. Returns
     * whether the binder was taken.
     */
    @Synchronized
    fun register(nonce: String, candidate: IBinder): Boolean {
        val expected = currentNonce()
        if (expected == null || nonce != expected) {
            Log.w(TAG, "register refused: no matching open window")
            return false
        }

        clearBinderLocked()

        val recipient = IBinder.DeathRecipient { onDeath(candidate) }
        try {
            candidate.linkToDeath(recipient, 0)
        } catch (e: Throwable) {
            Log.w(TAG, "helper was already gone", e)
            return false
        }

        binder = candidate
        deathRecipient = recipient
        windowNonce = null
        windowExpiresAt = 0L
        Log.i(TAG, "helper registered")

        listener?.onBridgeConnected()
        return true
    }

    @Synchronized
    fun bridge(): IBinder? = binder

    @Synchronized
    fun isConnected(): Boolean = binder?.isBinderAlive == true

    /** Drop the current helper, telling it to stop if it is still there. */
    @Synchronized
    fun disconnect() {
        val current = binder
        clearBinderLocked()
        if (current != null) {
            listener?.onBridgeDisconnected()
        }
    }

    private fun onDeath(dead: IBinder) {
        synchronized(this) {
            if (binder !== dead) return
            clearBinderLocked()
        }
        Log.i(TAG, "helper process ended")
        listener?.onBridgeDisconnected()
    }

    private fun clearBinderLocked() {
        val current = binder
        val recipient = deathRecipient
        if (current != null && recipient != null) {
            try {
                current.unlinkToDeath(recipient, 0)
            } catch (_: Throwable) {
            }
        }
        binder = null
        deathRecipient = null
    }
}
