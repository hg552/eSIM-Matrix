package ee.nekoko.nlpa2

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class SmsRelayPlugin :
    FlutterPlugin,
    ActivityAware,
    MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "ee.nekoko.sms_relay"
        private const val REQUEST_SMS_PERMISSION = 8421
        private val networkExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "sms-relay-network").apply { isDaemon = true }
        }
    }

    private var appContext: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var methodChannel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private val permissionResultListener =
        object : PluginRegistry.RequestPermissionsResultListener {
            override fun onRequestPermissionsResult(
                requestCode: Int,
                permissions: Array<out String>,
                grantResults: IntArray,
            ): Boolean {
                if (requestCode != REQUEST_SMS_PERMISSION) return false
                val smsIdx = permissions.indexOf(Manifest.permission.RECEIVE_SMS)
                val granted = if (smsIdx >= 0 && smsIdx < grantResults.size) {
                    grantResults[smsIdx] == PackageManager.PERMISSION_GRANTED
                } else {
                    grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
                }
                pendingPermissionResult?.success(granted)
                pendingPermissionResult = null
                return true
            }
        }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isAvailable())
            "hasPermission" -> result.success(hasSmsPermission())
            "requestPermission" -> requestPermission(result)
            "loadConfiguration" -> loadConfiguration(result)
            "saveConfiguration" -> saveConfiguration(call, result)
            "discoverTelegramChat" -> discoverTelegramChat(call, result)
            "testTelegram" -> testTelegram(result)
            "clearToken" -> clearToken(result)
            "isGatewayAvailable" -> result.success(isGatewayAvailable())
            "loadGatewayConfiguration" -> loadGatewayConfiguration(result)
            "saveGatewayToken" -> saveGatewayToken(call, result)
            "canScheduleExactAlarms" -> result.success(canScheduleExactAlarms())
            "requestExactAlarmPermission" -> requestExactAlarmPermission(result)
            "startGateway" -> startGateway(result)
            "stopGateway" -> stopGateway(result)
            "scheduleGatewayRevert" -> scheduleGatewayRevert(call, result)
            "cancelGatewayRevert" -> cancelGatewayRevert(result)
            "clearGatewayToken" -> clearGatewayToken(result)
            "loadHistory" -> loadHistory(result)
            "deleteHistoryItem" -> deleteHistoryItem(call, result)
            "clearHistory" -> clearHistory(result)
            "retryFailedHistory" -> retryFailedHistory(call, result)
            "getDeviceHealth" -> getDeviceHealth(result)
            else -> result.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detachActivity()
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        appContext = null
    }

    private fun attachActivity(binding: ActivityPluginBinding) {
        detachActivity()
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(permissionResultListener)
    }

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(permissionResultListener)
        activityBinding = null
        activity = null
        pendingPermissionResult?.error("activity_unavailable", "Activity was detached", null)
        pendingPermissionResult = null
    }

    private fun isAvailable(): Boolean {
        val context = appContext ?: return false
        return BuildConfig.FLAVOR in setOf("nexus", "m") &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)
    }

    private fun isGatewayAvailable(): Boolean {
        val context = appContext ?: return false
        return BuildConfig.FLAVOR == "m" &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)
    }


    private fun hasSmsPermission(): Boolean {
        val context = appContext ?: return false
        return isAvailable() &&
            context.checkSelfPermission(Manifest.permission.RECEIVE_SMS) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (!isAvailable()) {
            result.error("unsupported", "SMS relay is not included in this app variant", null)
            return
        }
        if (hasSmsPermission()) {
            result.success(true)
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("activity_unavailable", "Permission request needs a foreground activity", null)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_request_pending", "A permission request is already active", null)
            return
        }
        pendingPermissionResult = result
        val perms = mutableListOf(
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.READ_SMS,
            Manifest.permission.READ_PHONE_STATE,
            Manifest.permission.READ_CALL_LOG,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        currentActivity.requestPermissions(
            perms.toTypedArray(),
            REQUEST_SMS_PERMISSION,
        )
    }

    private fun loadConfiguration(result: MethodChannel.Result) {
        if (!isAvailable()) {
            result.error("unsupported", "SMS relay is not included in this app variant", null)
            return
        }
        try {
            val settings = SmsRelayStore.load(appContext!!)
            result.success(
                mapOf(
                    "mode" to settings.mode,
                    "enabled" to settings.enabled,
                    "endpoint" to settings.endpoint,
                    "telegramChatId" to settings.telegramChatId,
                    "tokenConfigured" to !settings.token.isNullOrBlank(),
                    "webhookTokenConfigured" to !settings.webhookToken.isNullOrBlank(),
                    "telegramTokenConfigured" to !settings.telegramToken.isNullOrBlank(),
                    "lastDeliveryAtMillis" to settings.lastDeliveryAtMillis,
                    "lastDeliveryError" to settings.lastDeliveryError,
                ),
            )
        } catch (_: Exception) {
            result.error("settings_unavailable", "SMS relay settings could not be read", null)
        }
    }

    private fun saveConfiguration(call: MethodCall, result: MethodChannel.Result) {
        if (!isAvailable()) {
            result.error("unsupported", "SMS relay is not included in this app variant", null)
            return
        }
        val mode = call.argument<String>("mode") ?: SmsRelayMode.WEBHOOK
        val endpoint = call.argument<String>("endpoint")
        val telegramChatId = call.argument<String>("telegramChatId")
        val token = call.argument<String>("token")
        val enabled = call.argument<Boolean>("enabled") ?: false
        try {
            SmsRelayStore.save(appContext!!, mode, endpoint, telegramChatId, token, enabled)
            if (isGatewayAvailable()) {
                val updatedSms = SmsRelayStore.load(appContext!!)
                val hasTelegramControl = !updatedSms.telegramToken.isNullOrBlank() &&
                    !updatedSms.telegramChatId.isNullOrBlank()
                if (enabled || hasTelegramControl) {
                    RemoteGatewayForegroundService.start(appContext!!)
                } else if (!SmsRelayStore.loadGateway(appContext!!).enabled) {
                    RemoteGatewayForegroundService.stop(appContext!!)
                }
            }
            result.success(null)
        } catch (error: IllegalArgumentException) {
            val code = error.message?.takeIf {
                it in setOf(
                    "invalid_endpoint",
                    "https_required",
                    "invalid_mode",
                    "invalid_chat_id",
                    "token_required",
                    "token_too_large",
                )
            } ?: "invalid_config"
            result.error(code, code, null)
        } catch (_: Exception) {
            result.error("storage_error", "SMS relay settings could not be saved", null)
        }
    }

    private fun discoverTelegramChat(call: MethodCall, result: MethodChannel.Result) {
        if (!isAvailable()) {
            result.error("unsupported", "SMS relay is not included in this app variant", null)
            return
        }
        val context = appContext ?: run {
            result.error("unavailable", "SMS relay is not ready", null)
            return
        }
        val token = try {
            call.argument<String>("token")?.trim()?.takeIf(String::isNotEmpty)
                ?: SmsRelayStore.load(context).telegramToken
        } catch (_: Exception) {
            result.error("settings_unavailable", "SMS relay settings could not be read", null)
            return
        }
        if (token.isNullOrBlank()) {
            result.error("token_required", "Enter a Telegram bot token first", null)
            return
        }

        try {
            networkExecutor.execute {
                try {
                    val chat = TelegramBotClient.discoverPrivateChat(token)
                    Handler(Looper.getMainLooper()).post {
                        result.success(mapOf("chatId" to chat.chatId, "displayName" to chat.displayName))
                    }
                } catch (error: TelegramBotException) {
                    Handler(Looper.getMainLooper()).post {
                        result.error(error.errorCode, error.errorCode, null)
                    }
                } catch (_: Exception) {
                    Handler(Looper.getMainLooper()).post {
                        result.error("telegram_network_error", "Telegram request failed", null)
                    }
                }
            }
        } catch (_: Exception) {
            result.error("telegram_unavailable", "Telegram request could not be queued", null)
        }
    }

    private fun loadGatewayConfiguration(result: MethodChannel.Result) {
        if (!isGatewayAvailable()) {
            result.error("unsupported", "Remote control is not included in this app variant", null)
            return
        }
        try {
            val gateway = SmsRelayStore.loadGateway(appContext!!)
            val sms = SmsRelayStore.load(appContext!!)
            result.success(
                mapOf(
                    "enabled" to gateway.enabled,
                    "apiToken" to gateway.apiToken,
                    "telegramToken" to sms.telegramToken,
                    "telegramChatId" to sms.telegramChatId,
                    "canScheduleExactAlarms" to canScheduleExactAlarms(),
                ),
            )
        } catch (_: Exception) {
            result.error("settings_unavailable", "Gateway settings could not be read", null)
        }
    }

    private fun saveGatewayToken(call: MethodCall, result: MethodChannel.Result) {
        if (!isGatewayAvailable()) {
            result.error("unsupported", "Remote control is not included in this app variant", null)
            return
        }
        val token = call.argument<String>("token")
        if (token.isNullOrBlank()) {
            result.error("token_required", "Generate an API token before saving", null)
            return
        }
        try {
            SmsRelayStore.saveGatewayToken(appContext!!, token)
            result.success(null)
        } catch (error: IllegalArgumentException) {
            result.error(error.message ?: "invalid_api_token", "API token is invalid", null)
        } catch (_: Exception) {
            result.error("storage_error", "API token could not be saved", null)
        }
    }

    private fun canScheduleExactAlarms(): Boolean {
        val context = appContext ?: return false
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val manager = context.getSystemService(android.app.AlarmManager::class.java) ?: return false
        return manager.canScheduleExactAlarms()
    }

    private fun requestExactAlarmPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || canScheduleExactAlarms()) {
            result.success(canScheduleExactAlarms())
            return
        }
        val context = appContext
        val currentActivity = activity
        if (context == null || currentActivity == null) {
            result.error("activity_unavailable", "Exact-alarm access needs a foreground activity", null)
            return
        }
        try {
            currentActivity.startActivity(
                android.content.Intent(
                    android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                    android.net.Uri.parse("package:${context.packageName}"),
                ),
            )
            result.success(false)
        } catch (_: Exception) {
            result.error("exact_alarm_unavailable", "Open app alarm access in system settings", null)
        }
    }

    private fun startGateway(result: MethodChannel.Result) {
        if (!isGatewayAvailable()) {
            result.error("unsupported", "Remote control is not included in this app variant", null)
            return
        }
        val context = appContext ?: run {
            result.error("unavailable", "Gateway is not ready", null)
            return
        }
        try {
            SmsRelayStore.setGatewayEnabled(context, true)
            RemoteGatewayForegroundService.start(context)
            result.success(null)
        } catch (error: IllegalArgumentException) {
            SmsRelayStore.setGatewayEnabled(context, false)
            result.error(error.message ?: "start_failed", "Gateway could not be started", null)
        } catch (_: Exception) {
            SmsRelayStore.setGatewayEnabled(context, false)
            result.error("start_failed", "Gateway could not be started", null)
        }
    }

    private fun stopGateway(result: MethodChannel.Result) {
        if (!isGatewayAvailable()) {
            result.error("unsupported", "Remote control is not included in this app variant", null)
            return
        }
        val context = appContext ?: run {
            result.error("unavailable", "Gateway is not ready", null)
            return
        }
        try {
            SmsRelayStore.setGatewayEnabled(context, false)
            GatewayAlarm.cancel(context)
            RemoteGatewayForegroundService.stop(context)
            result.success(null)
        } catch (_: Exception) {
            result.error("stop_failed", "Gateway could not be stopped", null)
        }
    }

    private fun scheduleGatewayRevert(call: MethodCall, result: MethodChannel.Result) {
        if (!isGatewayAvailable()) {
            result.error("unsupported", "Remote control is not included in this app variant", null)
            return
        }
        val deadline = call.argument<Long>("deadlineEpochMillis")
        if (deadline == null || deadline <= System.currentTimeMillis()) {
            result.error("invalid_deadline", "Revert deadline must be in the future", null)
            return
        }
        val context = appContext ?: run {
            result.error("unavailable", "Gateway is not ready", null)
            return
        }
        if (!GatewayAlarm.schedule(context, deadline)) {
            result.error("exact_alarm_required", "Exact-alarm access is required for profile fallback", null)
            return
        }
        result.success(null)
    }

    private fun cancelGatewayRevert(result: MethodChannel.Result) {
        if (!isGatewayAvailable()) {
            result.error("unsupported", "Remote control is not included in this app variant", null)
            return
        }
        GatewayAlarm.cancel(appContext!!)
        result.success(null)
    }

    private fun clearGatewayToken(result: MethodChannel.Result) {
        if (!isGatewayAvailable()) {
            result.error("unsupported", "Remote control is not included in this app variant", null)
            return
        }
        try {
            GatewayAlarm.cancel(appContext!!)
            SmsRelayStore.clearGatewayToken(appContext!!)
            RemoteGatewayForegroundService.stop(appContext!!)
            result.success(null)
        } catch (_: Exception) {
            result.error("storage_error", "API token could not be removed", null)
        }
    }

    private fun testTelegram(result: MethodChannel.Result) {
        if (!isAvailable()) {
            result.error("unsupported", "SMS relay is not included in this app variant", null)
            return
        }
        val settings = try {
            SmsRelayStore.load(appContext!!)
        } catch (_: Exception) {
            result.error("settings_unavailable", "SMS relay settings could not be read", null)
            return
        }
        val token = settings.telegramToken
        val chatId = settings.telegramChatId
        if (token.isNullOrBlank() || chatId.isNullOrBlank()) {
            result.error("telegram_config_required", "Save a Telegram bot token and destination Chat ID first", null)
            return
        }

        try {
            networkExecutor.execute {
                try {
                    TelegramBotClient.sendTestMessage(token, chatId)
                    SmsRelayStore.recordDelivery(
                        appContext!!,
                        delivered = true,
                        sender = "eUICC-Nexus 测试",
                        body = "这是一条来自 eUICC-Nexus 的 Telegram 转发连通性测试消息。",
                        mode = SmsRelayMode.TELEGRAM,
                    )
                    Handler(Looper.getMainLooper()).post { result.success(true) }
                } catch (error: TelegramBotException) {
                    Handler(Looper.getMainLooper()).post {
                        result.error(error.errorCode, error.errorCode, null)
                    }
                } catch (_: Exception) {
                    Handler(Looper.getMainLooper()).post {
                        result.error("telegram_network_error", "Telegram request failed", null)
                    }
                }
            }
        } catch (_: Exception) {
            result.error("telegram_unavailable", "Telegram request could not be queued", null)
        }
    }



    private fun clearToken(result: MethodChannel.Result) {
        if (!isAvailable()) {
            result.error("unsupported", "SMS relay is not included in this app variant", null)
            return
        }
        try {
            SmsRelayStore.clearToken(appContext!!)
            if (isGatewayAvailable() && !SmsRelayStore.loadGateway(appContext!!).enabled) {
                RemoteGatewayForegroundService.stop(appContext!!)
            }
            result.success(null)
        } catch (_: Exception) {
            result.error("storage_error", "Saved token could not be removed", null)
        }
    }

    private fun loadHistory(result: MethodChannel.Result) {
        val context = appContext ?: run {
            result.success(emptyList<Map<String, Any?>>())
            return
        }
        try {
            result.success(SmsRelayStore.loadHistory(context))
        } catch (_: Exception) {
            result.success(emptyList<Map<String, Any?>>())
        }
    }

    private fun deleteHistoryItem(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext ?: run {
            result.success(null)
            return
        }
        val id = call.argument<String>("id")?.trim().orEmpty()
        if (id.isNotEmpty()) {
            runCatching { SmsRelayStore.deleteHistoryItem(context, id) }
        }
        result.success(null)
    }

    private fun clearHistory(result: MethodChannel.Result) {
        val context = appContext ?: run {
            result.success(null)
            return
        }
        runCatching { SmsRelayStore.clearHistory(context) }
        result.success(null)
    }

    private fun retryFailedHistory(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext ?: run {
            result.success(0)
            return
        }
        val targetId = call.argument<String>("id")?.trim()?.takeIf { it.isNotEmpty() }
        try {
            networkExecutor.execute {
                val deliveredCount = runCatching {
                    SmsRelayReceiver.retryUndelivered(context, targetId)
                }.getOrDefault(0)
                Handler(Looper.getMainLooper()).post {
                    result.success(deliveredCount)
                }
            }
        } catch (_: Exception) {
            result.success(0)
        }
    }

    private fun getDeviceHealth(result: MethodChannel.Result) {
        val context = appContext ?: run {
            result.success(emptyMap<String, Any?>())
            return
        }
        try {
            val batteryIntent = context.registerReceiver(
                null,
                android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED),
            )
            val level = batteryIntent?.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = batteryIntent?.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, -1) ?: -1
            val batteryPercent = if (level >= 0 && scale > 0) (level * 100) / scale else null
            val status = batteryIntent?.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) ?: -1
            val plugged = batteryIntent?.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, 0) ?: 0
            val charging = status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
                status == android.os.BatteryManager.BATTERY_STATUS_FULL ||
                plugged != 0
            val powerSource = when (plugged) {
                android.os.BatteryManager.BATTERY_PLUGGED_AC -> "AC"
                android.os.BatteryManager.BATTERY_PLUGGED_USB -> "USB"
                android.os.BatteryManager.BATTERY_PLUGGED_WIRELESS -> "Wireless"
                else -> if (charging) "Charging" else "Battery"
            }
            val rawTemp = batteryIntent?.getIntExtra(android.os.BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
            val temperatureCelsius = if (rawTemp > 0) rawTemp / 10.0 else null

            var networkType = "Offline"
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? android.net.ConnectivityManager
            if (cm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val activeNet = cm.activeNetwork
                val caps = if (activeNet != null) cm.getNetworkCapabilities(activeNet) else null
                if (caps != null) {
                    val parts = mutableListOf<String>()
                    if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)) parts.add("Wi-Fi")
                    if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR)) parts.add("Cellular")
                    if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET)) parts.add("Ethernet")
                    if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN)) parts.add("VPN")
                    networkType = if (parts.isEmpty()) "Connected" else parts.joinToString("+")
                }
            }
            result.success(
                mapOf(
                    "batteryPercent" to batteryPercent,
                    "charging" to charging,
                    "powerSource" to powerSource,
                    "temperatureCelsius" to temperatureCelsius,
                    "networkType" to networkType,
                ),
            )
        } catch (_: Exception) {
            result.success(emptyMap<String, Any?>())
        }
    }
}
