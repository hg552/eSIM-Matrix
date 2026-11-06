package ee.nekoko.nlpa2

import android.app.AppOpsManager
import android.content.Context
import android.location.Location
import android.location.LocationManager
import android.location.provider.ProviderProperties
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Rootless virtual location plugin.
 *
 * Supports two distinct rootless modes:
 * 1. System Mock Location (`ACCESS_MOCK_LOCATION` via Android Developer Options "Select mock location app").
 * 2. Shizuku-based FusedLocation spoofer (`cmd location providers set-test-provider-location` & silent appops grant).
 */
class MockLocationPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "NexusMockLocation"
        private const val METHOD_CHANNEL = "ee.nekoko.mock_location"
        private val PROVIDERS = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, "fused")
    }

    private var appContext: Context? = null
    private var channel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())

    private var activeMode: String = "system"
    private var currentLatitude: Double = 0.0
    private var currentLongitude: Double = 0.0
    private var currentAltitude: Double = 15.0
    private var currentAccuracy: Float = 3.0f
    private val isMocking = AtomicBoolean(false)
    private val activeProviders = mutableSetOf<String>()

    private val periodicPusher = object : Runnable {
        override fun run() {
            if (!isMocking.get()) return
            pushCurrentLocation()
            handler.postDelayed(this, 1000)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopMockLocationInternal()
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isMockApp" -> result.success(isMockApp())
                "isShizukuAvailable" -> result.success(isShizukuAvailable())
                "grantMockViaShizuku" -> result.success(grantMockViaShizuku())
                "startMockLocation" -> {
                    val mode = call.argument<String>("mode") ?: "system"
                    val lat = call.argument<Double>("latitude") ?: 0.0
                    val lng = call.argument<Double>("longitude") ?: 0.0
                    val acc = (call.argument<Double>("accuracy") ?: 3.0).toFloat()
                    val alt = call.argument<Double>("altitude") ?: 15.0
                    result.success(startMockLocationInternal(mode, lat, lng, acc, alt))
                }
                "stopMockLocation" -> {
                    result.success(stopMockLocationInternal())
                }
                "getStatus" -> {
                    result.success(getStatusMap())
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            Log.e(TAG, "MockLocation call failed: ${call.method}", e)
            result.error("ERROR", e.message, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun isMockApp(): Boolean {
        val context = appContext ?: return false
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager ?: return false
        return try {
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                appOps.unsafeCheckOpNoThrow(
                    AppOpsManager.OPSTR_MOCK_LOCATION,
                    Process.myUid(),
                    context.packageName
                )
            } else {
                appOps.checkOpNoThrow(
                    AppOpsManager.OPSTR_MOCK_LOCATION,
                    Process.myUid(),
                    context.packageName
                )
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (e: Throwable) {
            Log.w(TAG, "isMockApp check failed", e)
            false
        }
    }

    private fun isShizukuAvailable(): Boolean {
        return try {
            Shizuku.pingBinder() && Shizuku.checkSelfPermission() == android.content.pm.PackageManager.PERMISSION_GRANTED
        } catch (e: Throwable) {
            false
        }
    }

    private fun executeShizukuProcess(vararg cmd: String): java.lang.Process? {
        if (!isShizukuAvailable()) return null
        return try {
            val method = (Shizuku::class.java.declaredMethods + Shizuku::class.java.methods)
                .firstOrNull { it.name == "newProcess" }
            if (method != null) {
                method.isAccessible = true
                val args = when (method.parameterCount) {
                    1 -> arrayOf(cmd)
                    3 -> arrayOf(cmd, null, null)
                    else -> arrayOf(cmd, null, null)
                }
                method.invoke(null, *args) as? java.lang.Process
            } else {
                null
            }
        } catch (e: Throwable) {
            Log.v(TAG, "executeShizukuProcess failed: ${e.message}")
            null
        }
    }

    private fun grantMockViaShizuku(): Boolean {
        val pkg = appContext?.packageName ?: return false
        return try {
            val p = executeShizukuProcess("cmd", "appops", "set", pkg, "android:mock_location", "allow")
            p?.waitFor() == 0
        } catch (e: Throwable) {
            Log.w(TAG, "grantMockViaShizuku failed", e)
            false
        }
    }

    private fun startMockLocationInternal(
        mode: String,
        latitude: Double,
        longitude: Double,
        accuracy: Float,
        altitude: Double
    ): Boolean {
        activeMode = mode
        currentLatitude = latitude
        currentLongitude = longitude
        currentAccuracy = accuracy
        currentAltitude = altitude

        val context = appContext ?: return false
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false

        if (mode == "shizuku") {
            // First attempt to grant mock permission via Shizuku silently if not already granted
            grantMockViaShizuku()
            // Also register test providers via shizuku process for system-wide fused coverage
            runShizukuCmd("cmd", "location", "providers", "add-test-provider", "gps")
            runShizukuCmd("cmd", "location", "providers", "set-test-provider-enabled", "gps", "true")
            runShizukuCmd("cmd", "location", "providers", "add-test-provider", "network")
            runShizukuCmd("cmd", "location", "providers", "set-test-provider-enabled", "network", "true")
        }

        // Setup Android LocationManager test providers
        setupTestProviders(lm)

        isMocking.set(true)
        handler.removeCallbacks(periodicPusher)
        handler.post(periodicPusher)
        Log.i(TAG, "Mock location started: mode=$mode, lat=$latitude, lng=$longitude, acc=$accuracy")
        return true
    }

    private fun setupTestProviders(lm: LocationManager) {
        for (provider in PROVIDERS) {
            try {
                lm.removeTestProvider(provider)
            } catch (_: Throwable) {}

            try {
                val requiresNetwork = provider == LocationManager.NETWORK_PROVIDER
                val requiresSatellite = provider == LocationManager.GPS_PROVIDER
                val accuracy = if (provider == LocationManager.GPS_PROVIDER) {
                    ProviderProperties.ACCURACY_FINE
                } else {
                    ProviderProperties.ACCURACY_COARSE
                }
                lm.addTestProvider(
                    provider,
                    requiresNetwork,
                    requiresSatellite,
                    false, // requiresCell
                    false, // hasMonetaryCost
                    true,  // supportsAltitude
                    true,  // supportsSpeed
                    true,  // supportsBearing
                    ProviderProperties.POWER_USAGE_LOW,
                    accuracy
                )
                lm.setTestProviderEnabled(provider, true)
                activeProviders.add(provider)
            } catch (e: Throwable) {
                Log.w(TAG, "addTestProvider failed for $provider: ${e.message}")
            }
        }
    }

    private fun pushCurrentLocation() {
        val context = appContext ?: return
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return

        val now = System.currentTimeMillis()
        val elapsed = SystemClock.elapsedRealtimeNanos()

        for (provider in activeProviders) {
            try {
                val loc = Location(provider).apply {
                    this.latitude = currentLatitude
                    this.longitude = currentLongitude
                    this.altitude = currentAltitude
                    this.accuracy = currentAccuracy
                    this.time = now
                    this.elapsedRealtimeNanos = elapsed
                    this.speed = 0.0f
                    this.bearing = 0.0f
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        this.bearingAccuracyDegrees = 0.1f
                        this.verticalAccuracyMeters = 0.5f
                        this.speedAccuracyMetersPerSecond = 0.1f
                    }
                }
                lm.setTestProviderLocation(provider, loc)
            } catch (e: Throwable) {
                Log.v(TAG, "setTestProviderLocation failed for $provider: ${e.message}")
            }
        }

        if (activeMode == "shizuku") {
            runShizukuCmd(
                "cmd", "location", "providers", "set-test-provider-location",
                "gps", "--location", "$currentLatitude,$currentLongitude",
                "--accuracy", "$currentAccuracy"
            )
        }
    }

    private fun stopMockLocationInternal(): Boolean {
        isMocking.set(false)
        handler.removeCallbacks(periodicPusher)

        val context = appContext
        val lm = context?.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

        if (lm != null) {
            for (provider in activeProviders) {
                try {
                    lm.setTestProviderEnabled(provider, false)
                    lm.removeTestProvider(provider)
                } catch (e: Throwable) {
                    Log.v(TAG, "removeTestProvider failed for $provider: ${e.message}")
                }
            }
        }
        activeProviders.clear()

        if (activeMode == "shizuku") {
            runShizukuCmd("cmd", "location", "providers", "remove-test-provider", "gps")
            runShizukuCmd("cmd", "location", "providers", "remove-test-provider", "network")
        }

        Log.i(TAG, "Mock location stopped")
        return true
    }

    private fun runShizukuCmd(vararg cmd: String) {
        try {
            val p = executeShizukuProcess(*cmd)
            p?.waitFor()
        } catch (_: Throwable) {}
    }

    private fun getStatusMap(): Map<String, Any?> {
        return mapOf(
            "isMocking" to isMocking.get(),
            "mode" to activeMode,
            "latitude" to currentLatitude,
            "longitude" to currentLongitude,
            "accuracy" to currentAccuracy,
            "isMockApp" to isMockApp(),
            "isShizukuAvailable" to isShizukuAvailable()
        )
    }
}
