package io.github.hg552.esimmatrix

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Controls the platform's own Wi-Fi Calling (VoWiFi) state.
 *
 * This is deliberately separate from the Dart VoWiFi stack under `lib/vowifi_sms`:
 * that one builds its own ePDG tunnel and SIP registration from a card reader, so
 * it works with no phone at all. This plugin instead flips the switch the phone's
 * ImsService already honours, which is what makes the *carrier's* own number
 * reachable over Wi-Fi through the system dialer and SMS app.
 *
 * ## Why the table, not the binder
 *
 * `ImsMmTelManager.setVoWiFiSettingEnabled` is `@SystemApi` and requires
 * `MODIFY_PHONE_STATE`, a signature-level permission that cannot be granted to a
 * sideloaded app by any user-facing means (`pm grant` refuses signature perms).
 * Calling it from this process therefore always throws SecurityException.
 *
 * What the setter ultimately does is `ImsManager.setWfcSetting`, which writes the
 * `wfc_ims_*` columns of the `siminfo` subscription table. Writing those columns
 * directly is equivalent for persistence, and ImsService reads them when it
 * starts, so the value survives a reboot. The trade-off is that a running
 * ImsService does not observe the write until it next re-reads, which is why
 * [reloadIms] exists: it restarts the IMS stack so the new value takes effect
 * without a reboot.
 *
 * Everything here needs root; without it the plugin reports `root: false` and
 * every mutation fails loudly rather than silently doing nothing.
 */
class VowifiPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler {

    companion object {
        private const val METHOD_CHANNEL = "ee.nekoko.vowifi"
        private const val SU_TIMEOUT_SECONDS = 10L

        // ImsMmTelManager.WIFI_MODE_*
        const val WIFI_MODE_UNKNOWN = -1
        const val WIFI_MODE_WIFI_ONLY = 0
        const val WIFI_MODE_CELLULAR_PREFERRED = 1
        const val WIFI_MODE_WIFI_PREFERRED = 2

        private val WFC_COLUMNS = listOf(
            "wfc_ims_enabled",
            "wfc_ims_mode",
            "wfc_ims_roaming_enabled",
            "wfc_ims_roaming_mode",
        )

        /** Runs a shell command as root. Returns (exitCode, combinedOutput). */
        internal fun runAsRoot(script: String): Pair<Int, String> = try {
            val process = ProcessBuilder("su", "-c", script)
                .redirectErrorStream(true)
                .start()
            val output = process.inputStream.bufferedReader().use { it.readText() }
            if (!process.waitFor(SU_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                process.destroyForcibly()
                Pair(-1, "timeout")
            } else {
                Pair(process.exitValue(), output.trim())
            }
        } catch (e: Throwable) {
            Pair(-1, e.message ?: e.javaClass.simpleName)
        }

        internal fun hasRoot(): Boolean = runAsRoot("id -u").let { it.first == 0 }

        /**
         * Reads the WFC columns for one subscription.
         *
         * `content query` runs as root, so it is not limited by the app's own
         * permission set. Output looks like:
         * `Row: 0 wfc_ims_enabled=1, wfc_ims_mode=2, ...`
         */
        internal fun readWfcColumns(subId: Int): Map<String, Int> {
            val projection = WFC_COLUMNS.joinToString(":")
            val (code, output) = runAsRoot(
                "content query --uri content://telephony/siminfo " +
                    "--projection $projection --where \"_id=$subId\"",
            )
            if (code != 0 || output.isBlank()) return emptyMap()
            val row = output.lineSequence().firstOrNull { it.startsWith("Row:") }
                ?: return emptyMap()
            // Drop the "Row: N " prefix, then split the comma-separated fields.
            val body = row.substringAfter("Row:").trim().substringAfter(' ').trim()
            return body.split(',')
                .mapNotNull { field ->
                    val trimmed = field.trim()
                    val eq = trimmed.indexOf('=')
                    if (eq <= 0) return@mapNotNull null
                    val key = trimmed.substring(0, eq).trim()
                    val value = trimmed.substring(eq + 1).trim().toIntOrNull()
                    if (key.isEmpty() || value == null) null else key to value
                }
                .toMap()
        }

        /**
         * Writes WFC columns for one subscription.
         *
         * `content update` prints nothing on success and an "Error:" line on
         * failure, so the output decides the result rather than the exit code
         * (which is 0 even for some rejected updates).
         */
        internal fun writeWfcColumns(subId: Int, values: Map<String, Int>): Pair<Boolean, String> {
            if (values.isEmpty()) return Pair(false, "no values")
            val bind = values.entries.joinToString(", ") { (k, v) -> "$k=$v" }
            val (code, output) = runAsRoot(
                "content update --uri content://telephony/siminfo " +
                    "--bind \"$bind\" --where \"_id=$subId\"",
            )
            val failed = code != 0 || output.contains("Error", ignoreCase = true)
            return Pair(!failed, output)
        }

        /**
         * Asks the platform to re-read the subscription values.
         *
         * There is no public "reload IMS settings" entry point, and `cmd phone`
         * exposes no WFC subcommand, so the supported way to make a persisted
         * change take effect is to restart the IMS stack. Toggling airplane mode
         * does that through the normal framework path and needs no privileged
         * API, which keeps this step honest instead of poking at internal
         * services.
         */
        internal fun reloadIms(): Pair<Boolean, String> {
            val (code, output) = runAsRoot(
                "cmd connectivity airplane-mode enable; sleep 1; " +
                    "cmd connectivity airplane-mode disable",
            )
            return Pair(code == 0, output)
        }
    }

    private var appContext: Context? = null
    private var methodChannel: MethodChannel? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // Every branch shells out to `su`, so none of it may run on the
        // platform thread.
        executor.execute {
            val answer = runCatching { dispatch(call) }
            mainHandler.post {
                answer.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { result.error("vowifi_failed", it.message, null) },
                )
            }
        }
    }

    private fun dispatch(call: MethodCall): Map<String, Any?> = when (call.method) {
        "capabilities" -> capabilities()
        "status" -> status(call.argument<Int>("subscriptionId"))
        "setEnabled" -> setEnabled(requireSubId(call), call.argument<Boolean>("enabled") ?: false)
        "setMode" -> setMode(requireSubId(call), call.argument<Int>("mode") ?: WIFI_MODE_WIFI_ONLY)
        "setRoamingEnabled" ->
            setRoamingEnabled(requireSubId(call), call.argument<Boolean>("enabled") ?: false)
        "setRoamingMode" ->
            setRoamingMode(requireSubId(call), call.argument<Int>("mode") ?: WIFI_MODE_WIFI_ONLY)
        "reloadIms" -> reloadImsReport()
        else -> throw IllegalArgumentException("unknown method ${call.method}")
    }

    private fun requireSubId(call: MethodCall): Int {
        val subId = call.argument<Int>("subscriptionId")
            ?: throw IllegalArgumentException("subscriptionId is required")
        if (!SubscriptionManager.isValidSubscriptionId(subId)) {
            throw IllegalArgumentException("invalid subscriptionId $subId")
        }
        return subId
    }

    private fun capabilities(): Map<String, Any?> {
        val context = appContext
        val telephony = context?.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        val root = hasRoot()
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "root" to root,
            "telephony" to (telephony != null),
            // The binder getters need READ_PRIVILEGED_PHONE_STATE, which the app
            // does not hold; report the honest capability rather than the API
            // level alone.
            "binderReadable" to canReadViaBinder(),
            "modes" to mapOf(
                "wifiOnly" to WIFI_MODE_WIFI_ONLY,
                "cellularPreferred" to WIFI_MODE_CELLULAR_PREFERRED,
                "wifiPreferred" to WIFI_MODE_WIFI_PREFERRED,
            ),
        )
    }

    /**
     * Whether this build can read the WFC state through the platform binder.
     *
     * `ImsMmTelManager.createForSubscriptionId` is `@SystemApi`, so it is absent
     * from the public SDK and cannot be referenced at compile time. Reflection
     * keeps the probe honest: it reports what this device would actually allow
     * rather than what the API level suggests.
     */
    private fun canReadViaBinder(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        val subId = SubscriptionManager.getDefaultSubscriptionId()
        if (!SubscriptionManager.isValidSubscriptionId(subId)) return false
        return runCatching {
            val managerClass = Class.forName("android.telephony.ims.ImsMmTelManager")
            val manager = managerClass
                .getMethod("createForSubscriptionId", Int::class.javaPrimitiveType)
                .invoke(null, subId)
            managerClass.getMethod("isVoWiFiSettingEnabled").invoke(manager)
        }.isSuccess
    }

    private fun status(subIdArg: Int?): Map<String, Any?> {
        val subId = subIdArg ?: SubscriptionManager.getDefaultSubscriptionId()
        if (!SubscriptionManager.isValidSubscriptionId(subId)) {
            return mapOf("available" to false, "error" to "no_subscription")
        }
        val columns = readWfcColumns(subId)
        if (columns.isEmpty()) {
            return mapOf(
                "available" to false,
                "subscriptionId" to subId,
                "error" to "siminfo_unreadable",
            )
        }
        // Each value is typed before it enters the map: `columns[k] ?: 0` binds
        // as `columns[k] ?: (0 to ...)` inside a mapOf argument, which made
        // Kotlin infer Pair instead of Int.
        val enabled: Boolean = (columns["wfc_ims_enabled"] ?: 0) != 0
        val mode: Int = columns["wfc_ims_mode"] ?: WIFI_MODE_UNKNOWN
        val roamingEnabled: Boolean = (columns["wfc_ims_roaming_enabled"] ?: 0) != 0
        val roamingMode: Int = columns["wfc_ims_roaming_mode"] ?: WIFI_MODE_UNKNOWN
        return mapOf(
            "available" to true,
            "subscriptionId" to subId,
            "enabled" to enabled,
            "mode" to mode,
            "roamingEnabled" to roamingEnabled,
            "roamingMode" to roamingMode,
        )
    }

    private fun setEnabled(subId: Int, enabled: Boolean): Map<String, Any?> =
        apply(subId, mapOf("wfc_ims_enabled" to if (enabled) 1 else 0))

    private fun setMode(subId: Int, mode: Int): Map<String, Any?> {
        require(mode in WIFI_MODE_WIFI_ONLY..WIFI_MODE_WIFI_PREFERRED) { "invalid mode $mode" }
        return apply(subId, mapOf("wfc_ims_mode" to mode))
    }

    private fun setRoamingEnabled(subId: Int, enabled: Boolean): Map<String, Any?> =
        apply(subId, mapOf("wfc_ims_roaming_enabled" to if (enabled) 1 else 0))

    private fun setRoamingMode(subId: Int, mode: Int): Map<String, Any?> {
        require(mode in WIFI_MODE_WIFI_ONLY..WIFI_MODE_WIFI_PREFERRED) { "invalid mode $mode" }
        return apply(subId, mapOf("wfc_ims_roaming_mode" to mode))
    }

    /**
     * Writes the change, then re-reads it so the answer is the persisted state
     * rather than an assumption that the write landed.
     */
    private fun apply(subId: Int, values: Map<String, Int>): Map<String, Any?> {
        val (written, output) = writeWfcColumns(subId, values)
        return mapOf(
            "success" to written,
            "error" to if (written) null else output.ifBlank { "write_rejected" },
            "status" to status(subId),
        )
    }

    private fun reloadImsReport(): Map<String, Any?> {
        // Companion scope, not this instance: `reloadIms()` here would resolve
        // to the member and recurse.
        val (ok, output) = Companion.reloadIms()
        return mapOf(
            "success" to ok,
            "output" to output.ifBlank { null },
        )
    }
}
