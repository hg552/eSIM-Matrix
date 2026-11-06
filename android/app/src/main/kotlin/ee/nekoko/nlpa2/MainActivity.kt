package ee.nekoko.nlpa2

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun getCachedEngineId(): String? =
        if (BuildConfig.FLAVOR == "m") MainApplication.FLUTTER_ENGINE_ID else null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        if (BuildConfig.FLAVOR == "m") return
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(NBridgePlugin())
        flutterEngine.plugins.add(OmapiPlugin())
        flutterEngine.plugins.add(TelephonyPlugin())
        flutterEngine.plugins.add(NetworkStatusPlugin())
        flutterEngine.plugins.add(SmsRelayPlugin())
        flutterEngine.plugins.add(CertificatePlugin())
        flutterEngine.plugins.add(QrtrPlugin())
        flutterEngine.plugins.add(AdbBridgePlugin())
        flutterEngine.plugins.add(MockLocationPlugin())
    }
}
