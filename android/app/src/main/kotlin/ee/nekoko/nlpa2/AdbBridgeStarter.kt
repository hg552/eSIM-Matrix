package ee.nekoko.nlpa2

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Looper
import android.os.Process
import kotlin.system.exitProcess

/**
 * The entry point a person runs over ADB.
 *
 * `adb shell` can start a process as the `shell` user, which the platform
 * trusts with the card operations the app is not allowed to do. The app shows a
 * command that loads its own code and runs this `main` in such a process:
 *
 *     CLASSPATH=$(pm path <pkg> | sed -n 's/^package://p' | head -n1) \
 *         app_process / ee.nekoko.nlpa2.AdbBridgeStarter <pkg>
 *
 * The command carries no secret and downloads nothing; it resolves the
 * installed APK by package each time. The one argument is the running package,
 * which names the app's provider ([AdbBridgeProvider]).
 *
 * This process builds a system context for telephony access, asks the app's
 * provider for the nonce through shell-attributed Binder IPC, and hands over an
 * [AdbBridgeServer]. The app checks that the caller really is `shell` before it
 * takes the binder. Then the process stays, serving the app's calls, until the
 * app stops it or the window is closed.
 */
class AdbBridgeStarter {
    companion object {
        private const val SHELL_PACKAGE = "com.android.shell"

        @JvmStatic
        fun main(args: Array<String>) {
            val packageName = args.firstOrNull()
            if (packageName.isNullOrBlank()) {
                fail("Run the command the app shows; it names the package to connect to.", 1)
            }

            val context = systemContext()
            val authority = packageName + AdbBridgeProvider.AUTHORITY_SUFFIX

            val acquired = try {
                callProvider(authority, AdbBridgeProvider.METHOD_ACQUIRE, null, null)
            } catch (e: Throwable) {
                val cause = e.cause ?: e
                fail("Could not reach the app. Is it installed and open? (${cause.message})", 2)
            }

            val protocol = acquired?.getInt(AdbBridgeProvider.KEY_PROTOCOL, -1) ?: -1
            if (protocol != AdbBridgeHub.PROTOCOL_VERSION) {
                fail(
                    "This command and the installed app disagree on version " +
                        "($protocol vs ${AdbBridgeHub.PROTOCOL_VERSION}). Update both.",
                    3,
                )
            }

            val nonce = acquired?.getString(AdbBridgeProvider.KEY_NONCE)
            if (nonce.isNullOrBlank()) {
                fail(
                    "No connection is waiting. Open \"Connect using computer\" in the app, " +
                        "then run this within the time it shows.",
                    4,
                )
            }

            val server = AdbBridgeServer(context)
            val registration = Bundle().apply {
                putString(AdbBridgeProvider.KEY_NONCE, nonce)
                putBinder(AdbBridgeProvider.KEY_BINDER, server.asBinder())
            }

            val answer = try {
                callProvider(authority, AdbBridgeProvider.METHOD_REGISTER, null, registration)
            } catch (e: Throwable) {
                val cause = e.cause ?: e
                fail("Handing the connection over failed (${cause.message}).", 5)
            }

            if (answer?.getBoolean(AdbBridgeProvider.KEY_OK, false) != true) {
                fail(
                    "The app did not accept this connection. It may have timed out; " +
                        "start the connection again from the app.",
                    6,
                )
            }

            println(
                "Connected to the app as shell (uid ${Process.myUid()}). " +
                    "Keep this window open — closing it disconnects.",
            )
            Looper.loop()
        }

        /** Called by the server when the app asks the helper to stop. */
        fun stop() {
            exitProcess(0)
        }

        /**
         * Build the system context for telephony access in a standalone process.
         *
         * `ActivityThread.systemMain()` constructs a Handler, so `app_process`
         * must prepare its main Looper first. Android attributes this context to
         * `android`, not the shell UID; provider IPC uses the explicit shell
         * attribution in [callProvider].
         */
        private fun systemContext(): Context {
            if (Looper.myLooper() == null) {
                Looper.prepareMainLooper()
            }
            val activityThread = Class.forName("android.app.ActivityThread")
            val thread = activityThread.getMethod("systemMain").invoke(null)
            return activityThread.getMethod("getSystemContext").invoke(thread) as Context
        }

        /**
         * `ContentResolver` would attribute the system context to `android`,
         * which does not match the ADB shell UID. Acquire the exported provider
         * through ActivityManager and call it with explicit shell attribution.
         */
        private fun callProvider(
            authority: String,
            method: String,
            arg: String?,
            extras: Bundle?,
        ): Bundle? {
            val activityManagerClass = Class.forName("android.app.ActivityManager")
            val activityManagerInterface = Class.forName("android.app.IActivityManager")
            val activityManager = activityManagerClass.getMethod("getService").invoke(null)
            val holder = activityManagerInterface.getMethod(
                "getContentProviderExternal",
                String::class.java,
                Int::class.javaPrimitiveType!!,
                IBinder::class.java,
                String::class.java,
            ).invoke(
                activityManager,
                authority,
                0, // ADB shell runs in the primary Android user.
                null,
                authority,
            ) ?: return null

            try {
                val provider = holder.javaClass.getField("provider").get(holder) ?: return null
                val providerInterface = Class.forName("android.content.IContentProvider")
                val parameterTypes: Array<Class<*>>
                val arguments: Array<Any?>

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val attributionSourceClass = Class.forName("android.content.AttributionSource")
                    val builderClass = Class.forName("android.content.AttributionSource\$Builder")
                    val builder = builderClass
                        .getConstructor(Int::class.javaPrimitiveType!!)
                        .newInstance(Process.myUid())
                    builderClass.getMethod("setPackageName", String::class.java)
                        .invoke(builder, SHELL_PACKAGE)
                    val attributionSource = builderClass.getMethod("build").invoke(builder)

                    parameterTypes = arrayOf(
                        attributionSourceClass,
                        String::class.java,
                        String::class.java,
                        String::class.java,
                        Bundle::class.java,
                    )
                    arguments = arrayOf(attributionSource, authority, method, arg, extras)
                } else if (Build.VERSION.SDK_INT >= 30) {
                    parameterTypes = arrayOf(
                        String::class.java,
                        String::class.java,
                        String::class.java,
                        String::class.java,
                        String::class.java,
                        Bundle::class.java,
                    )
                    arguments = arrayOf(SHELL_PACKAGE, null, authority, method, arg, extras)
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    parameterTypes = arrayOf(
                        String::class.java,
                        String::class.java,
                        String::class.java,
                        String::class.java,
                        Bundle::class.java,
                    )
                    arguments = arrayOf(SHELL_PACKAGE, authority, method, arg, extras)
                } else {
                    parameterTypes = arrayOf(
                        String::class.java,
                        String::class.java,
                        String::class.java,
                        Bundle::class.java,
                    )
                    arguments = arrayOf(SHELL_PACKAGE, method, arg, extras)
                }

                return providerInterface.getMethod("call", *parameterTypes)
                    .invoke(provider, *arguments) as Bundle?
            } finally {
                activityManagerInterface.getMethod(
                    "removeContentProviderExternal",
                    String::class.java,
                    IBinder::class.java,
                ).invoke(activityManager, authority, null)
            }
        }

        private fun fail(message: String, code: Int): Nothing {
            System.err.println(message)
            exitProcess(code)
        }
    }
}
