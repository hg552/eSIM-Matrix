package io.github.hg552.esimmatrix

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.InvocationTargetException
import java.util.concurrent.TimeUnit

/**
 * Roaming data safeguard.
 *
 * A foreign keep-alive eSIM roaming in a domestic network can burn megabytes of
 * chargeable data before anything user-visible happens, so every profile switch
 * runs through here first: mobile data and data roaming are switched off for the
 * target subscription while the baseband still registers for SMS.
 *
 * Primary path is the hidden `TelephonyManager` APIs that need MODIFY_PHONE_STATE
 * (held by the privileged build). When that is unavailable the guardian falls back
 * to `svc data disable` through root, and reports exactly which path it used so the
 * caller never assumes a guarantee that was not actually enforced.
 */
class CellularDataGuardianPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "NexusDataGuard"
        private const val METHOD_CHANNEL = "ee.nekoko.data_guard"
        private const val SHELL_TIMEOUT_SECONDS = 5L
    }

    private var appContext: Context? = null
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "capabilities" -> result.success(capabilities())
                "getStatus" -> result.success(statusSnapshot())
                "setDataEnabled" -> {
                    val subscriptionId = requireSubId(call)
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    result.success(setDataEnabled(subscriptionId, enabled))
                }
                "setRoamingEnabled" -> {
                    val subscriptionId = requireSubId(call)
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    result.success(setRoamingEnabled(subscriptionId, enabled))
                }
                "applyLockdown" -> {
                    val subscriptionId = requireSubId(call)
                    result.success(applyLockdown(subscriptionId))
                }
                "restore" -> {
                    val subscriptionId = requireSubId(call)
                    val dataEnabled = call.argument<Boolean>("dataEnabled")
                    val roamingEnabled = call.argument<Boolean>("roamingEnabled")
                    result.success(restore(subscriptionId, dataEnabled, roamingEnabled))
                }
                else -> result.notImplemented()
            }
        } catch (error: SecurityException) {
            result.error("permission_denied", error.message, null)
        } catch (error: Throwable) {
            val root = rootCause(error)
            Log.w(TAG, "data guard call ${call.method} failed", root)
            result.error("data_guard_failed", root.message ?: root.javaClass.simpleName, null)
        }
    }

    // --- capability probing ------------------------------------------------

    private fun capabilities(): Map<String, Any?> {
        val context = appContext
        val hasModifyPhoneState = context?.checkSelfPermission(
            "android.permission.MODIFY_PHONE_STATE",
        ) == PackageManager.PERMISSION_GRANTED
        val hasRoot = runCatching {
            listOf("/system/bin/su", "/system/xbin/su", "/sbin/su").any { java.io.File(it).exists() } ||
                runCatching {
                    ProcessBuilder("su", "-c", "true")
                        .redirectErrorStream(true)
                        .start()
                        .apply { waitFor(SHELL_TIMEOUT_SECONDS, TimeUnit.SECONDS) }
                        .exitValue() == 0
                }.getOrDefault(false)
        }.getOrDefault(false)
        return mapOf(
            "modifyPhoneState" to hasModifyPhoneState,
            "root" to hasRoot,
            "telephonyApis" to hasModifyPhoneState,
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }

    // --- state -------------------------------------------------------------

    private fun statusSnapshot(): List<Map<String, Any?>> {
        val context = appContext ?: return emptyList()
        val manager = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            ?: return emptyList()
        val subscriptionManager = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
            as? SubscriptionManager
        val active = runCatching {
            subscriptionManager?.activeSubscriptionInfoList.orEmpty()
        }.getOrDefault(emptyList())
        return active.mapNotNull { info ->
            val subId = info.subscriptionId
            val perSub = runCatching { manager.createForSubscriptionId(subId) }.getOrNull()
                ?: return@mapNotNull null
            mapOf(
                "subscriptionId" to subId,
                "slotIndex" to info.simSlotIndex,
                "dataEnabled" to readDataEnabled(perSub, subId),
                "roamingEnabled" to readRoamingEnabled(perSub, subId),
            )
        }
    }

    private fun readDataEnabled(manager: TelephonyManager, subscriptionId: Int): Boolean? =
        invokeHidden(manager, "isDataEnabled", arrayOf(subscriptionId)) as? Boolean
            ?: runCatching { manager.isDataEnabled }.getOrNull()

    private fun readRoamingEnabled(manager: TelephonyManager, subscriptionId: Int): Boolean? =
        invokeHidden(manager, "isDataRoamingEnabled", arrayOf(subscriptionId)) as? Boolean
            ?: runCatching { manager.isDataRoamingEnabled }.getOrNull()

    // --- mutations ---------------------------------------------------------

    private fun setDataEnabled(subscriptionId: Int, enabled: Boolean): Map<String, Any?> {
        val manager = telephony() ?: throw IllegalStateException("telephony_unavailable")
        val viaApi = invokeHidden(
            manager,
            "setDataEnabled",
            arrayOf(subscriptionId, enabled),
        )
        val applied = viaApi != null
        val viaShell = if (!applied) {
            // `svc data` acts on the default data subscription; only meaningful
            // when the caller targets the current default, so it is a best effort.
            runShell("svc data ${if (enabled) "enable" else "disable"}")
        } else {
            false
        }
        val verified = if (applied) {
            val perSub = runCatching { manager.createForSubscriptionId(subscriptionId) }.getOrNull()
            perSub?.let { readDataEnabled(it, subscriptionId) }
        } else {
            null
        }
        return mapOf(
            "subscriptionId" to subscriptionId,
            "requested" to enabled,
            "applied" to (applied || viaShell),
            "viaApi" to applied,
            "viaShell" to viaShell,
            "observed" to verified,
        )
    }

    private fun setRoamingEnabled(subscriptionId: Int, enabled: Boolean): Map<String, Any?> {
        val manager = telephony() ?: throw IllegalStateException("telephony_unavailable")
        val applied = invokeHidden(
            manager,
            "setDataRoamingEnabled",
            arrayOf(subscriptionId, enabled),
        ) != null
        val verified = if (applied) {
            runCatching { manager.createForSubscriptionId(subscriptionId) }.getOrNull()
                ?.let { readRoamingEnabled(it, subscriptionId) }
        } else {
            null
        }
        return mapOf(
            "subscriptionId" to subscriptionId,
            "requested" to enabled,
            "applied" to applied,
            "viaApi" to applied,
            "viaShell" to false,
            "observed" to verified,
        )
    }

    /**
     * Captures the current data/roaming state for [subscriptionId] and turns both
     * off. The returned snapshot is what the caller persists so a revert can put
     * the phone back exactly as it was found.
     */
    private fun applyLockdown(subscriptionId: Int): Map<String, Any?> {
        val manager = telephony() ?: throw IllegalStateException("telephony_unavailable")
        val perSub = runCatching { manager.createForSubscriptionId(subscriptionId) }.getOrNull()
        val before = mapOf(
            "dataEnabled" to perSub?.let { readDataEnabled(it, subscriptionId) },
            "roamingEnabled" to perSub?.let { readRoamingEnabled(it, subscriptionId) },
        )
        val dataResult = setDataEnabled(subscriptionId, false)
        val roamingResult = setRoamingEnabled(subscriptionId, false)
        val dataApplied = dataResult["applied"] == true
        return mapOf(
            "subscriptionId" to subscriptionId,
            "before" to before,
            "data" to dataResult,
            "roaming" to roamingResult,
            // `enforced` means data is actually off; roaming-off alone does not
            // protect a domestic roaming eSIM whose home network is abroad.
            "enforced" to dataApplied,
        )
    }

    /** Puts the subscription back to a previously captured state. */
    private fun restore(
        subscriptionId: Int,
        dataEnabled: Boolean?,
        roamingEnabled: Boolean?,
    ): Map<String, Any?> {
        val results = mutableMapOf<String, Any?>()
        if (dataEnabled != null) {
            results["data"] = setDataEnabled(subscriptionId, dataEnabled)
        }
        if (roamingEnabled != null) {
            results["roaming"] = setRoamingEnabled(subscriptionId, roamingEnabled)
        }
        results["subscriptionId"] = subscriptionId
        results["restored"] = results["data"]?.let { (it as Map<*, *>)["applied"] == true } ?: true
        return results
    }

    // --- helpers -----------------------------------------------------------

    private fun telephony(): TelephonyManager? = appContext
        ?.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager

    private fun requireSubId(call: MethodCall): Int =
        call.argument<Int>("subscriptionId")
            ?: throw IllegalArgumentException("subscription_id_required")

    private fun invokeHidden(target: Any, name: String, args: Array<*>): Any? {
        val methods = target.javaClass.methods.filter { it.name == name }
        for (method in methods) {
            if (method.parameterCount != args.size) continue
            val compatible = method.parameterTypes.indices.all { index ->
                val type = method.parameterTypes[index]
                val arg = args[index]
                when {
                    type == Int::class.javaPrimitiveType || type == Int::class.javaObjectType ->
                        arg is Int
                    type == Boolean::class.javaPrimitiveType || type == Boolean::class.javaObjectType ->
                        arg is Boolean
                    else -> arg != null && type.isInstance(arg)
                }
            }
            if (!compatible) continue
            try {
                method.isAccessible = true
                return method.invoke(target, *args)
            } catch (error: InvocationTargetException) {
                throw rootCause(error)
            }
        }
        return null
    }

    private fun runShell(command: String): Boolean = runCatching {
        val args = if (command.startsWith("svc ")) {
            arrayOf("su", "-c", command)
        } else {
            arrayOf("sh", "-c", command)
        }
        val process = ProcessBuilder(*args)
            .redirectErrorStream(true)
            .start()
        process.inputStream.bufferedReader().use { it.readText() }
        process.waitFor(SHELL_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        process.exitValue() == 0
    }.getOrDefault(false)

    private fun rootCause(error: Throwable): Throwable {
        var current = error
        while (current is InvocationTargetException && current.targetException != null) {
            current = current.targetException
        }
        return current
    }
}
