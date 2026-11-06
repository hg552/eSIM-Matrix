package io.github.hg552.esimmatrix

import android.Manifest
import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.NetworkRegistrationInfo
import android.telephony.ServiceState
import android.telephony.SignalStrength
import android.telephony.SubscriptionManager
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.annotation.RequiresApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class NetworkStatusPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    companion object {
        private const val METHOD_CHANNEL = "ee.nekoko.network_status"
        private const val EVENT_CHANNEL = "ee.nekoko.network_status/events"

        internal fun isPlaceholderCarrierName(name: String?): Boolean {
            if (name.isNullOrBlank()) return true
            val lower = name.trim().lowercase()
            return lower.contains("紧急") ||
                lower.contains("emergency") ||
                lower.contains("无服务") ||
                lower.contains("no service") ||
                lower.contains("仅限") ||
                lower.contains("searching") ||
                lower.contains("正在搜索")
        }

        @Suppress("DEPRECATION")
        internal fun extractServiceState(serviceState: ServiceState): Triple<Int, Boolean, String?> {
            var isRegistered = serviceState.state == ServiceState.STATE_IN_SERVICE
            var isRoaming = serviceState.roaming
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val regInfos = runCatching { serviceState.networkRegistrationInfoList }.getOrNull().orEmpty()
                for (reg in regInfos) {
                    val domain = reg.domain
                    if ((domain == NetworkRegistrationInfo.DOMAIN_CS || domain == NetworkRegistrationInfo.DOMAIN_PS) &&
                        reg.isRegistered && !reg.isSearching
                    ) {
                        isRegistered = true
                    }
                    if (reg.isRoaming) {
                        isRoaming = true
                    }
                }
            }
            val rawText = serviceState.operatorAlphaLong?.takeIf(String::isNotBlank)
                ?: serviceState.operatorAlphaShort?.takeIf(String::isNotBlank)
            if (rawText != null && isPlaceholderCarrierName(rawText) && serviceState.state != ServiceState.STATE_IN_SERVICE) {
                isRegistered = false
            }
            val effectiveState = if (isRegistered) {
                ServiceState.STATE_IN_SERVICE
            } else {
                serviceState.state
            }
            val liveOperator = serviceState.operatorAlphaLong?.takeIf { !isPlaceholderCarrierName(it) }
                ?: serviceState.operatorAlphaShort?.takeIf { !isPlaceholderCarrierName(it) }
                ?: serviceState.operatorNumeric?.takeIf { !isPlaceholderCarrierName(it) }
            return Triple(effectiveState, isRoaming, liveOperator)
        }

        @RequiresApi(Build.VERSION_CODES.Q)
        internal fun extractSignalStrength(signalStrength: SignalStrength): Pair<Int?, Int> {
            val strongestDbm = signalStrength.cellSignalStrengths
                .asSequence()
                .map { it.dbm }
                .filter { it != SignalStrength.INVALID && it in -150..-30 }
                .maxOrNull()
            return Pair(strongestDbm, signalStrength.level)
        }
    }

    private var appContext: Context? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var subscriptionManager: SubscriptionManager? = null
    private var subscriptionsListener: SubscriptionManager.OnSubscriptionsChangedListener? = null
    private var simStateReceiver: BroadcastReceiver? = null
    private var currentError: String? = null
    private val registrations = linkedMapOf<Int, CallbackRegistration>()
    private val snapshots = linkedMapOf<Int, SubscriptionSnapshot>()
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(isSupported(appContext))
            "refresh" -> {
                if (eventSink == null) {
                    result.error("not_listening", "Network status stream is not active", null)
                    return
                }
                if (subscriptionsListener == null) {
                    startMonitoring()
                }
                val error = refreshSubscriptions()
                if (error == null) {
                    result.success(null)
                } else {
                    result.error(error, error, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        startMonitoring()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        stopMonitoring()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        eventSink = null
        stopMonitoring()
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        appContext = null
    }

    private fun isSupported(context: Context?): Boolean {
        if (context == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY_SUBSCRIPTION)
    }

    private fun availabilityError(context: Context?): String? {
        if (!isSupported(context)) return "unsupported"
        if (context!!.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return "permission_required"
        }
        return null
    }

    @SuppressLint("MissingPermission")
    private fun startMonitoring() {
        val context = appContext
        val error = availabilityError(context)
        if (error != null) {
            publishError(error)
            return
        }

        val manager = context!!.getSystemService(SubscriptionManager::class.java)
        if (manager == null) {
            publishError("telephony_unavailable")
            return
        }
        subscriptionManager = manager

        if (subscriptionsListener == null) {
            val listener = object : SubscriptionManager.OnSubscriptionsChangedListener() {
                override fun onSubscriptionsChanged() {
                    refreshSubscriptions()
                }
            }
            subscriptionsListener = listener
            try {
                manager.addOnSubscriptionsChangedListener(context.mainExecutor, listener)
            } catch (_: SecurityException) {
                subscriptionsListener = null
                publishError("permission_required")
                return
            } catch (_: RuntimeException) {
                subscriptionsListener = null
                publishError("telephony_unavailable")
                return
            }
        }
        if (simStateReceiver == null) {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context?, intent: Intent?) {
                    refreshSubscriptions()
                }
            }
            simStateReceiver = receiver
            try {
                context.registerReceiver(receiver, IntentFilter("android.intent.action.SIM_STATE_CHANGED"))
            } catch (_: RuntimeException) {
                simStateReceiver = null
            }
        }

        refreshSubscriptions()
    }

    @SuppressLint("MissingPermission")
    private fun refreshSubscriptions(): String? {
        val context = appContext ?: run {
            publishError("telephony_unavailable")
            return "telephony_unavailable"
        }
        val error = availabilityError(context)
        if (error != null) {
            publishError(error)
            return error
        }

        val manager = subscriptionManager
            ?: context.getSystemService(SubscriptionManager::class.java)
            ?: run {
                publishError("telephony_unavailable")
                return "telephony_unavailable"
            }
        subscriptionManager = manager

        val telephonyManager = context.getSystemService(TelephonyManager::class.java)
        if (telephonyManager == null) {
            publishError("telephony_unavailable")
            return "telephony_unavailable"
        }

        val activeSubscriptions = try {
            manager.activeSubscriptionInfoList.orEmpty()
        } catch (_: SecurityException) {
            publishError("permission_required")
            return "permission_required"
        } catch (_: RuntimeException) {
            publishError("telephony_unavailable")
            return "telephony_unavailable"
        }

        val activeIds = activeSubscriptions.mapTo(mutableSetOf()) { it.subscriptionId }
        (registrations.keys - activeIds).toList().forEach(::removeRegistration)
        (snapshots.keys - activeIds).toList().forEach(snapshots::remove)

        activeSubscriptions.forEach { info ->
            val subscriptionId = info.subscriptionId
            val existing = snapshots[subscriptionId]
            val subManager = runCatching { telephonyManager.createForSubscriptionId(subscriptionId) }.getOrNull()
            val liveService = subManager?.let {
                runCatching { it.serviceState }.getOrNull()?.let(::extractServiceState)
            }
            val liveSignal = subManager?.let {
                runCatching { it.signalStrength }.getOrNull()?.let(::extractSignalStrength)
            }
            val tmRoaming = subManager?.let {
                runCatching { it.isNetworkRoaming }.getOrDefault(false)
            } ?: false
            val tmOperator = subManager?.let {
                runCatching { it.networkOperatorName?.takeIf { name -> !isPlaceholderCarrierName(name) } }.getOrNull()
            }
            val rawSubCarrier = info.carrierName?.toString()?.takeIf(String::isNotBlank)
            val validCarrier = liveService?.third
                ?: tmOperator
                ?: rawSubCarrier?.takeIf { !isPlaceholderCarrierName(it) }
                ?: existing?.carrierName?.takeIf { !isPlaceholderCarrierName(it) }
            val rawIsEmergencyOrNoService = rawSubCarrier != null &&
                isPlaceholderCarrierName(rawSubCarrier) &&
                liveService?.third == null &&
                tmOperator == null
            val effectiveServiceState = when {
                rawIsEmergencyOrNoService -> ServiceState.STATE_OUT_OF_SERVICE
                liveService != null -> liveService.first
                else -> existing?.serviceState
            }
            val effectiveRoaming = when {
                liveService?.second == true || tmRoaming -> true
                liveService != null -> liveService.second
                else -> existing?.roaming
            }
            val resolvedCarrier = validCarrier ?: rawSubCarrier ?: existing?.carrierName
            snapshots[subscriptionId] = SubscriptionSnapshot(
                subscriptionId = subscriptionId,
                slotIndex = info.simSlotIndex,
                displayName = info.displayName?.toString()?.takeIf(String::isNotBlank) ?: existing?.displayName,
                carrierName = resolvedCarrier,
                serviceState = effectiveServiceState,
                roaming = effectiveRoaming,
                signalDbm = liveSignal?.first ?: existing?.signalDbm,
                signalLevel = liveSignal?.second ?: existing?.signalLevel,
                error = null,
            )
            if (subscriptionId !in registrations) {
                registerCallback(telephonyManager, subscriptionId)
            }
        }

        currentError = null
        publish()
        return null
    }

    @SuppressLint("MissingPermission")
    @RequiresApi(Build.VERSION_CODES.S)
    private fun registerCallback(baseManager: TelephonyManager, subscriptionId: Int) {
        val context = appContext ?: return
        val manager = baseManager.createForSubscriptionId(subscriptionId)
        val callback = SubscriptionTelephonyCallback(
            onServiceState = { serviceState, roaming, liveCarrier ->
                updateSnapshot(subscriptionId) {
                    it.copy(
                        serviceState = serviceState,
                        roaming = roaming,
                        carrierName = liveCarrier ?: it.carrierName,
                        error = null,
                    )
                }
            },
            onSignalStrength = { dbm, level ->
                updateSnapshot(subscriptionId) {
                    it.copy(signalDbm = dbm, signalLevel = level, error = null)
                }
            },
        )

        try {
            manager.registerTelephonyCallback(context.mainExecutor, callback)
            registrations[subscriptionId] = CallbackRegistration(manager, callback)
        } catch (_: SecurityException) {
            updateSnapshot(subscriptionId) { it.copy(error = "permission_required") }
        } catch (_: RuntimeException) {
            updateSnapshot(subscriptionId) { it.copy(error = "telephony_unavailable") }
        }
    }

    private fun updateSnapshot(
        subscriptionId: Int,
        transform: (SubscriptionSnapshot) -> SubscriptionSnapshot,
    ) {
        val snapshot = snapshots[subscriptionId] ?: return
        snapshots[subscriptionId] = transform(snapshot)
        publish()
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun removeRegistration(subscriptionId: Int) {
        val registration = registrations.remove(subscriptionId) ?: return
        try {
            registration.manager.unregisterTelephonyCallback(registration.callback)
        } catch (_: RuntimeException) {
            // The subscription may already have disappeared from the telephony service.
        }
    }

    private fun stopMonitoring() {
        subscriptionsListener?.let { listener ->
            try {
                subscriptionManager?.removeOnSubscriptionsChangedListener(listener)
            } catch (_: RuntimeException) {
                // The telephony service may already be unavailable during engine teardown.
            }
        }
        simStateReceiver?.let { receiver ->
            try {
                appContext?.unregisterReceiver(receiver)
            } catch (_: RuntimeException) {}
        }
        simStateReceiver = null
        subscriptionsListener = null
        subscriptionManager = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            registrations.keys.toList().forEach(::removeRegistration)
        } else {
            registrations.clear()
        }
        snapshots.clear()
        currentError = null
    }

    private fun publishError(error: String) {
        currentError = error
        publish()
    }

    private fun publish() {
        val orderedSnapshots = snapshots.values
            .sortedWith(compareBy<SubscriptionSnapshot> { it.slotIndex }.thenBy { it.subscriptionId })
            .map(SubscriptionSnapshot::toMap)
        eventSink?.success(
            mapOf(
                "error" to currentError,
                "subscriptions" to orderedSnapshots,
            ),
        )
    }

    private data class CallbackRegistration(
        val manager: TelephonyManager,
        val callback: TelephonyCallback,
    )

    private data class SubscriptionSnapshot(
        val subscriptionId: Int,
        val slotIndex: Int,
        val displayName: String?,
        val carrierName: String?,
        val serviceState: Int? = null,
        val roaming: Boolean? = null,
        val signalDbm: Int? = null,
        val signalLevel: Int? = null,
        val error: String? = null,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "subscriptionId" to subscriptionId,
            "slotIndex" to slotIndex,
            "displayName" to displayName,
            "carrierName" to carrierName,
            "serviceState" to serviceState,
            "roaming" to roaming,
            "signalDbm" to signalDbm,
            "signalLevel" to signalLevel,
            "error" to error,
        )
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private class SubscriptionTelephonyCallback(
        private val onServiceState: (Int, Boolean, String?) -> Unit,
        private val onSignalStrength: (Int?, Int) -> Unit,
    ) : TelephonyCallback(),
        TelephonyCallback.ServiceStateListener,
        TelephonyCallback.SignalStrengthsListener {
        override fun onServiceStateChanged(serviceState: ServiceState) {
            val (state, roaming, carrier) = extractServiceState(serviceState)
            onServiceState(state, roaming, carrier)
        }

        override fun onSignalStrengthsChanged(signalStrength: SignalStrength) {
            val (strongestDbm, level) = extractSignalStrength(signalStrength)
            onSignalStrength(strongestDbm, level)
        }
    }
}
