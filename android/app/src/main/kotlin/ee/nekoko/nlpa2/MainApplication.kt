package ee.nekoko.nlpa2

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

class MainApplication : Application() {
    companion object {
        const val FLUTTER_ENGINE_ID = "nlpa2_multi_engine"
    }

    override fun onCreate() {
        super.onCreate()
        if (BuildConfig.FLAVOR != "m") return

        val engine = FlutterEngine(this)
        engine.plugins.add(NBridgePlugin())
        engine.plugins.add(OmapiPlugin())
        engine.plugins.add(TelephonyPlugin())
        engine.plugins.add(NetworkStatusPlugin())
        engine.plugins.add(CellularDataGuardianPlugin())
        engine.plugins.add(SmsRelayPlugin())
        engine.plugins.add(CertificatePlugin())
        engine.plugins.add(QrtrPlugin())
        engine.plugins.add(AdbBridgePlugin())
        engine.plugins.add(ShizukuInstallerPlugin())
        engine.plugins.add(MockLocationPlugin())
        FlutterEngineCache.getInstance().put(FLUTTER_ENGINE_ID, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        runCatching { RemoteGatewayForegroundService.start(this) }
    }
}

