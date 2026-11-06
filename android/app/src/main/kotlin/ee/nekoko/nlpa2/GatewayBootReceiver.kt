package ee.nekoko.nlpa2

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

internal class GatewayBootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "GatewayBootReceiver"
        private const val ACTION_QUICKBOOT_POWERON = "android.intent.action.QUICKBOOT_POWERON"
        private const val ACTION_HTC_QUICKBOOT_POWERON = "com.htc.intent.action.QUICKBOOT_POWERON"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (BuildConfig.FLAVOR != "m") return
        val action = intent?.action ?: return
        val isBoot = action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_LOCKED_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == ACTION_QUICKBOOT_POWERON ||
            action == ACTION_HTC_QUICKBOOT_POWERON
        if (!isBoot) return

        Log.i(TAG, "Boot/restart broadcast received: $action")
        val shouldStart = runCatching {
            val gateway = SmsRelayStore.loadGateway(context)
            val sms = SmsRelayStore.load(context)
            gateway.enabled || sms.enabled ||
                (!sms.telegramToken.isNullOrBlank() && !sms.telegramChatId.isNullOrBlank())
        }.getOrDefault(true)

        if (shouldStart) {
            Log.i(TAG, "Initiating RemoteGatewayForegroundService recovery")
            RemoteGatewayForegroundService.start(context, RemoteGatewayForegroundService.ACTION_RECOVER)
        }
    }
}
