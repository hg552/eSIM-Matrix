package io.github.hg552.esimmatrix

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent


internal class GatewayAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (BuildConfig.FLAVOR != "m") return
        RemoteGatewayForegroundService.start(context, RemoteGatewayForegroundService.ACTION_RECOVER)
    }
}

internal object GatewayAlarm {
    private const val REQUEST_CODE = 49022

    fun schedule(context: Context, deadlineEpochMillis: Long): Boolean {
        val manager = context.getSystemService(android.app.AlarmManager::class.java) ?: return false
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S &&
            !manager.canScheduleExactAlarms()
        ) {
            return false
        }
        val pendingIntent = pendingIntent(context)
        return try {
            manager.setExactAndAllowWhileIdle(
                android.app.AlarmManager.RTC_WAKEUP,
                deadlineEpochMillis,
                pendingIntent,
            )
            true
        } catch (_: SecurityException) {
            false
        }
    }

    fun cancel(context: Context) {
        val manager = context.getSystemService(android.app.AlarmManager::class.java) ?: return
        manager.cancel(pendingIntent(context))
    }

    private fun pendingIntent(context: Context): android.app.PendingIntent =
        android.app.PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            Intent(context, GatewayAlarmReceiver::class.java),
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
        )
}
