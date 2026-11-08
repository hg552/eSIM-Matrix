package io.github.hg552.esimmatrix

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

        /** `cmd location` forks a process; 5 s keeps the system provider fresh at a sane cost. */
        private const val SHIZUKU_PUSH_INTERVAL_MS = 5_000L

        /**
         * The live plugin, so the foreground service's "停止定位" action can tear
         * the test providers down. It runs in the same process as the engine that
         * owns this plugin, and a null value means the engine is already gone,
         * in which case [onDetachedFromEngine] has stopped the injection anyway.
         */
        @Volatile private var active: MockLocationPlugin? = null

        fun requestStopFromNotification() {
            val plugin = active
            if (plugin == null) {
                Log.w(TAG, "Stop requested with no plugin attached; nothing to tear down")
                return
            }
            plugin.handler.post { plugin.stopMockLocationInternal() }
        }
    }

    private var appContext: Context? = null
    private var channel: MethodChannel? = null
    private val handler = Handler(Looper.getMainLooper())
    private val shizukuExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "mock-loc-shizuku").apply { isDaemon = true }
    }
    private var activeMode: String = "system"
    private var currentLatitude: Double = 0.0
    private var currentLongitude: Double = 0.0
    private var currentAltitude: Double = 15.0
    private var currentAccuracy: Float = 3.0f
    private var currentLabel: String = ""
    private val isMocking = AtomicBoolean(false)
    private val activeProviders = mutableSetOf<String>()

    private val periodicPusher = object : Runnable {
        override fun run() {
            if (!isMocking.get()) return
            pushCurrentLocation()
            handler.postDelayed(this, 1000)
        }
    }

    /** Wall clock of the last Shizuku push, so the 1 s tick does not fork a process every second. */
    private var lastShizukuPushAt: Long = 0L

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        active = this
        channel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopMockLocationInternal()
        if (active === this) active = null
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isMockApp" -> result.success(isMockApp())
                "isShizukuAvailable" -> result.success(isShizukuAvailable())
                "grantMockViaShizuku" -> {
                    shizukuExecutor.execute {
                        val ok = grantMockViaShizuku()
                        handler.post { result.success(ok) }
                    }
                }
                "startMockLocation" -> {
                    val mode = call.argument<String>("mode") ?: "system"
                    val lat = call.argument<Double>("latitude") ?: 0.0
                    val lng = call.argument<Double>("longitude") ?: 0.0
                    val acc = (call.argument<Double>("accuracy") ?: 3.0).toFloat()
                    val alt = call.argument<Double>("altitude") ?: 15.0
                    currentLabel = call.argument<String>("label") ?: ""
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
            if (p != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val finished = p.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)
                    if (!finished) {
                        p.destroyForcibly()
                        false
                    } else {
                        p.exitValue() == 0
                    }
                } else {
                    p.waitFor() == 0
                }
            } else {
                false
            }
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
            shizukuExecutor.execute {
                // First attempt to grant mock permission via Shizuku silently if not already granted
                grantMockViaShizuku()
                // Also register test providers via shizuku process for system-wide fused coverage
                runShizukuCmd("cmd", "location", "providers", "add-test-provider", "gps")
                runShizukuCmd("cmd", "location", "providers", "set-test-provider-enabled", "gps", "true")
                runShizukuCmd("cmd", "location", "providers", "add-test-provider", "network")
                runShizukuCmd("cmd", "location", "providers", "set-test-provider-enabled", "network", "true")
            }
        }

        // Setup Android LocationManager test providers
        setupTestProviders(lm)

        // No provider means the mock app permission is missing (or the ROM blocks
        // test providers). Reporting true here is what made the UI claim success
        // while every app still saw the real position.
        if (activeProviders.isEmpty()) {
            isMocking.set(false)
            handler.removeCallbacks(periodicPusher)
            Log.w(TAG, "Mock location refused: no test provider could be registered")
            return false
        }

        isMocking.set(true)
        handler.removeCallbacks(periodicPusher)
        handler.post(periodicPusher)

        // Without this the process is reclaimable and the injection dies with it
        // while the console would still report "正在注入".
        val label = currentLabel
        runCatching {
            MockLocationForegroundService.start(context, label, latitude, longitude)
        }.onFailure { Log.w(TAG, "Could not start the mock location service", it) }

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
            val now = System.currentTimeMillis()
            if (now - lastShizukuPushAt >= SHIZUKU_PUSH_INTERVAL_MS) {
                lastShizukuPushAt = now
                runShizukuCmdAsync(
                    "cmd", "location", "providers", "set-test-provider-location",
                    "gps", "--location", "$currentLatitude,$currentLongitude",
                    "--accuracy", "$currentAccuracy"
                )
            }
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

        appContext?.let { ctx ->
            runCatching { MockLocationForegroundService.stop(ctx) }
        }

        if (activeMode == "shizuku") {
            shizukuExecutor.execute {
                runShizukuCmd("cmd", "location", "providers", "remove-test-provider", "gps")
                runShizukuCmd("cmd", "location", "providers", "remove-test-provider", "network")
                runShizukuCmd("cmd", "location", "providers", "remove-test-provider", "fused")
            }
        }

        Log.i(TAG, "Mock location stopped")
        return true
    }

    private fun runShizukuCmd(vararg cmd: String) {
        try {
            val p = executeShizukuProcess(*cmd)
            if (p != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val finished = p.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)
                    if (!finished) {
                        p.destroyForcibly()
                    }
                } else {
                    p.waitFor()
                }
            }
        } catch (_: Throwable) {}
    }

    private fun runShizukuCmdAsync(vararg cmd: String) {
        shizukuExecutor.execute {
            runShizukuCmd(*cmd)
        }
    }

    private fun getStatusMap(): Map<String, Any?> {
        return mapOf(
            "isMocking" to isMocking.get(),
            "mode" to activeMode,
            "latitude" to currentLatitude,
            "longitude" to currentLongitude,
            "accuracy" to currentAccuracy,
            "isMockApp" to isMockApp(),
            "isShizukuAvailable" to isShizukuAvailable(),
            "providers" to activeProviders.toList()
        )
    }
}
