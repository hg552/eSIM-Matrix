package ee.nekoko.nlpa2

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.util.Log

/**
 * How a `shell` helper reaches back into the app.
 *
 * [AdbBridgeStarter] runs outside the app and has no handle to it, but it can
 * call an exported provider the way any process calls a `content://` authority.
 * It asks here for the nonce of the open connection window, then hands its
 * binder over with that nonce. Both land in [AdbBridgeHub], where the plugin
 * picks them up.
 *
 * The provider is exported because the helper is not the app, but the only call
 * that grants anything — `register` — is refused unless the caller really is
 * the `shell` user. `acquire` only reveals a short-lived nonce and is harmless
 * on its own: a nonce without a `shell` caller registers nothing.
 */
class AdbBridgeProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        return when (method) {
            METHOD_ACQUIRE -> Bundle().apply {
                putInt(KEY_PROTOCOL, AdbBridgeHub.PROTOCOL_VERSION)
                AdbBridgeHub.currentNonce()?.let { putString(KEY_NONCE, it) }
            }

            METHOD_REGISTER -> {
                val uid = Binder.getCallingUid()
                if (uid != AdbBridgeHub.SHELL_UID) {
                    Log.w(TAG, "register refused from uid $uid")
                    return Bundle().apply { putBoolean(KEY_OK, false) }
                }

                val nonce = extras?.getString(KEY_NONCE)
                val binder = extras?.getBinder(KEY_BINDER)
                val ok = nonce != null && binder != null &&
                    AdbBridgeHub.register(nonce, binder)
                Bundle().apply { putBoolean(KEY_OK, ok) }
            }

            else -> null
        }
    }

    // A provider has to carry the table methods even when it is only a door for
    // the call above; nothing queries or writes it.
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    companion object {
        private const val TAG = "AdbBridgeProvider"

        /** The authority, completed with the running package's id at build time. */
        const val AUTHORITY_SUFFIX = ".adbbridge"

        const val METHOD_ACQUIRE = "acquire"
        const val METHOD_REGISTER = "register"

        const val KEY_PROTOCOL = "protocol"
        const val KEY_NONCE = "nonce"
        const val KEY_BINDER = "binder"
        const val KEY_OK = "ok"
    }
}
