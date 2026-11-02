package ee.nekoko.nbridge

import android.content.Context
import android.content.pm.PackageManager
import android.os.Process

/** Explicit user consent, pinned to an installed package/UID, not a public signing key. */
internal class CallerAccessStore private constructor(private val context: Context) {
    private val prefs = context.getSharedPreferences("nbridge_callers", Context.MODE_PRIVATE)
    val policy = BridgeAccessPolicy(Process.myUid())

    @Suppress("DEPRECATION")
    fun isApproved(uid: Int): Boolean =
        context.packageManager.getPackagesForUid(uid).orEmpty().any { name ->
            val saved = prefs.getString(name, null) ?: return@any false
            val info = try {
                context.packageManager.getPackageInfo(name, 0)
            } catch (_: PackageManager.NameNotFoundException) {
                return@any false
            }
            saved == "$uid:${info.firstInstallTime}"
        }

    @Suppress("DEPRECATION")
    fun isPackageApproved(name: String): Boolean {
        val info = context.packageManager.getPackageInfo(name, 0)
        val uid = info.applicationInfo?.uid ?: return false
        return prefs.getString(name, null) == "$uid:${info.firstInstallTime}"
    }

    fun savedPackages(): Set<String> = prefs.all.keys

    @Suppress("DEPRECATION")
    fun setApproved(name: String, approved: Boolean, backend: NBridgeBackend) {
        // Provider admission, opening channels and revocation share this lock.
        synchronized(policy) {
            if (approved) {
                val info = context.packageManager.getPackageInfo(name, 0)
                val uid = info.applicationInfo?.uid ?: throw IllegalStateException("App is unavailable")
                check(prefs.edit().putString(name, "$uid:${info.firstInstallTime}").commit())
            } else {
                val uid = prefs.getString(name, null)?.substringBefore(':')?.toIntOrNull()
                check(prefs.edit().remove(name).commit())
                if (uid != null && !isApproved(uid)) {
                    // Revoke access before closing: a failed close must never restore permission.
                    var failure: Exception? = null
                    for (id in policy.ownedConnections(uid)) {
                        try {
                            backend.closeLogicalChannel(id)
                            policy.forget(id)
                        } catch (error: Exception) {
                            failure = error
                        }
                    }
                    failure?.let { throw it }
                }
            }
        }
    }

    companion object {
        @Volatile private var instance: CallerAccessStore? = null

        fun getInstance(context: Context): CallerAccessStore =
            instance ?: synchronized(this) {
                instance ?: CallerAccessStore(context.applicationContext).also { instance = it }
            }
    }
}
