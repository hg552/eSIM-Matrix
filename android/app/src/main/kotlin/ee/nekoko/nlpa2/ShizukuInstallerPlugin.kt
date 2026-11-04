package ee.nekoko.nlpa2

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import rikka.shizuku.Shizuku
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Installs Shizuku on request, without carrying its APK in this build.
 *
 * Shizuku is a separate app; nothing here can merge it into this one. QRTR and
 * SE HAL reach the card through a process the `shell` user owns, and Shizuku is
 * what runs that process on a phone without root. Without it both reader types
 * have nothing to talk to.
 *
 * Nothing is downloaded until the user asks for it, and what is downloaded goes
 * straight to the system installer for confirmation — this app never installs
 * anything silently and carries no copy of Shizuku in its own package.
 */
class ShizukuInstallerPlugin :
    FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: android.app.Activity? = null

    private val worker = Executors.newSingleThreadExecutor()
    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel =
            MethodChannel(binding.binaryMessenger, CHANNEL).also {
                it.setMethodCallHandler(this)
            }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.error("NO_CONTEXT", "plugin not attached", null)
        when (call.method) {
            "status" -> result.success(status(ctx))
            "install" -> install(ctx, result)
            "allowInstall" -> allowInstall(ctx, result)
            "launch" -> result.success(launchShizuku(ctx))
            else -> result.notImplemented()
        }
    }

    private fun status(ctx: Context): Map<String, Any?> {
        val info = packageInfo(ctx)
        var running = false
        try {
            running = Shizuku.pingBinder()
        } catch (_: Throwable) {
            // Absent or its binder is gone; both mean "not running".
        }
        return mapOf(
            "installed" to (info != null),
            "versionName" to info?.versionName,
            "running" to running,
            "canInstall" to canInstall(ctx),
            "starterCommand" to if (info != null) starterCommand(info) else null,
        )
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(ctx: Context): android.content.pm.PackageInfo? =
        try {
            ctx.packageManager.getPackageInfo(SHIZUKU_PACKAGE, 0)
        } catch (_: Throwable) {
            null
        }

    private fun canInstall(ctx: Context): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ctx.packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    /**
     * Shizuku's starter is a shared object inside its APK, which `adb shell` can
     * execute directly. Naming the resolved path is the whole instruction.
     */
    private fun starterCommand(info: android.content.pm.PackageInfo): String? {
        val dir = info.applicationInfo?.nativeLibraryDir ?: return null
        val starter = File(dir, "libshizuku.so")
        return if (starter.exists()) "adb shell ${starter.absolutePath}" else null
    }

    /**
     * Downloads Shizuku's APK on demand and hands it to the system installer.
     *
     * Runs off the main thread because it is a network round trip; the Flutter
     * call answers once the installer is on screen, or with the reason it is
     * not.
     */
    private fun install(ctx: Context, result: MethodChannel.Result) {
        if (packageInfo(ctx) != null) {
            // Upgrading an installed Shizuku is not this button's job.
            main.post { result.success("already_installed") }
            return
        }
        if (!canInstall(ctx)) {
            // The system drops an install intent from a disallowed app without
            // saying so, so open the switch instead of pretending it worked.
            allowInstall(ctx, result)
            return
        }

        worker.execute {
            var launched: String? = null
            var failure: Throwable? = null
            try {
                launched = openInstaller(ctx, download(ctx))
            } catch (e: Throwable) {
                Log.e(TAG, "could not install Shizuku", e)
                failure = e
            }
            val done = launched
            val cause = failure
            main.post {
                if (done != null) {
                    result.success(done)
                } else {
                    result.error(
                        "INSTALL_FAILED",
                        cause?.message ?: "download failed",
                        null,
                    )
                }
            }
        }
    }

    private fun download(ctx: Context): File {
        val dir = File(ctx.cacheDir, "shizuku").apply { mkdirs() }
        val target = File(dir, "shizuku.apk")

        var lastError: Throwable? = null
        for (url in candidateUrls()) {
            try {
                fetch(url, target)
                if (!ShizukuDownload.isPlausibleApk(target.length())) {
                    throw IllegalStateException("downloaded file is too small to be an APK")
                }
                Log.i(TAG, "downloaded Shizuku from $url (${target.length()} bytes)")
                return target
            } catch (e: Throwable) {
                lastError = e
                Log.w(TAG, "Shizuku download failed from $url", e)
                target.delete()
            }
        }
        throw lastError ?: IllegalStateException("no download source available")
    }

    private fun candidateUrls(): List<String> {
        val latest =
            try {
                resolveLatestApkUrl()
            } catch (e: Throwable) {
                Log.w(TAG, "could not ask GitHub for the latest Shizuku release", e)
                null
            }
        return ShizukuDownload.candidateUrls(latest)
    }

    private fun resolveLatestApkUrl(): String? {
        val connection =
            (URL(ShizukuDownload.LATEST_RELEASE_API).openConnection() as HttpURLConnection)
                .apply {
                    connectTimeout = 15000
                    readTimeout = 20000
                    setRequestProperty("Accept", "application/vnd.github+json")
                    setRequestProperty("User-Agent", "eUICC-Nexus")
                }
        try {
            if (connection.responseCode != 200) return null
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            return ShizukuDownload.apkUrlFromReleaseJson(body)
        } finally {
            connection.disconnect()
        }
    }

    private fun fetch(url: String, target: File) {
        val connection =
            (URL(url).openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = true
                connectTimeout = 15000
                readTimeout = 60000
                setRequestProperty("User-Agent", "eUICC-Nexus")
            }
        try {
            val code = connection.responseCode
            if (code !in 200..299) throw IllegalStateException("HTTP $code from $url")
            connection.inputStream.use { input ->
                target.outputStream().use { output -> input.copyTo(output, 64 * 1024) }
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun openInstaller(ctx: Context, apk: File): String {
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.shizuku_install", apk)
        val intent =
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                if (activity == null) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        try {
            (activity ?: ctx).startActivity(intent)
            return "installer_opened"
        } catch (e: ActivityNotFoundException) {
            throw IllegalStateException("no package installer answered", e)
        }
    }

    private fun allowInstall(ctx: Context, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return result.success("not_needed")
        }
        openUnknownSourcesSettings(ctx, result)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun openUnknownSourcesSettings(ctx: Context, result: MethodChannel.Result) {
        val intent =
            Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${ctx.packageName}"),
                )
                .also { if (activity == null) it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
        try {
            (activity ?: ctx).startActivity(intent)
            result.success("settings_opened")
        } catch (e: Throwable) {
            Log.e(TAG, "could not open the unknown-sources switch", e)
            result.error("NO_SETTINGS", e.message, null)
        }
    }

    private fun launchShizuku(ctx: Context): Boolean {
        val intent =
            ctx.packageManager.getLaunchIntentForPackage(SHIZUKU_PACKAGE) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            ctx.startActivity(intent)
            true
        } catch (e: Throwable) {
            Log.e(TAG, "could not open Shizuku", e)
            false
        }
    }

    private companion object {
        private const val TAG = "ShizukuInstaller"
        private const val CHANNEL = "ee.nekoko.shizuku_installer"
        private const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
    }
}
