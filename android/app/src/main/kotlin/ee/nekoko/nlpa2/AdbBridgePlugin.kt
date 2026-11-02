package ee.nekoko.nlpa2

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * The app's side of the ADB bridge.
 *
 * It shows the command a person runs over ADB, holds the connection window
 * open while they do, and — once a `shell` helper has registered through
 * [AdbBridgeProvider] — forwards the card operations to it. The operations are
 * the ones [NBridgeAdapter] already drives, so the Dart adapter is shared in
 * shape; only the transport differs.
 *
 * Calls into the helper block on the binder, so they run off the UI thread. A
 * separate event channel tells Dart when a helper comes and goes, so the
 * connect screen can follow along without polling.
 */
class AdbBridgePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    AdbBridgeHub.Listener {
    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var context: Context

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, EVENTS)
        events.setStreamHandler(this)
        AdbBridgeHub.listener = this
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        if (AdbBridgeHub.listener === this) AdbBridgeHub.listener = null
        AdbBridgeHub.closeWindow()
        worker.shutdown()
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
        sink.success(if (AdbBridgeHub.isConnected()) STATE_CONNECTED else STATE_DISCONNECTED)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onBridgeConnected() {
        main.post { eventSink?.success(STATE_CONNECTED) }
    }

    override fun onBridgeDisconnected() {
        main.post { eventSink?.success(STATE_DISCONNECTED) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getConnectCommand" -> result.success(connectCommand())
            "isConnected" -> result.success(AdbBridgeHub.isConnected())

            "beginConnect" -> {
                val timeout = (call.argument<Number>("timeoutMs") ?: DEFAULT_WINDOW_MS).toLong()
                AdbBridgeHub.openWindow(timeout)
                result.success(timeout)
            }
            "cancelConnect" -> {
                AdbBridgeHub.closeWindow()
                result.success(null)
            }
            "disconnect" -> disconnect(result)

            "listSlots" -> forward(result) { it.listSlots() }
            "connectLogicalChannel" -> forward(result) {
                it.openLogicalChannel(
                    call.argument<String>("slotId") ?: invalid("slotId"),
                    call.argument<List<String>>("aids") ?: emptyList(),
                )
            }
            "transmitLogical" -> forward(result) {
                it.transmitLogical(
                    call.argument<String>("connectionId") ?: invalid("connectionId"),
                    call.argument<String>("apdu") ?: invalid("apdu"),
                )
            }
            "transmitBasic" -> forward(result) {
                it.transmitBasic(
                    call.argument<String>("slotId") ?: invalid("slotId"),
                    call.argument<String>("apdu") ?: invalid("apdu"),
                )
            }
            "closeLogicalChannel" -> forward(result) {
                it.closeLogicalChannel(
                    call.argument<String>("connectionId") ?: invalid("connectionId"),
                )
            }

            else -> result.notImplemented()
        }
    }

    private fun invalid(name: String): Nothing = throw IllegalArgumentException("$name is missing")

    /** Build the command for whichever flavour is installed. */
    private fun connectCommand(): String {
        val pkg = context.packageName
        return "adb shell \"CLASSPATH=\\\$(pm path $pkg | sed -n 's/^package://p' | " +
            "head -n1) app_process / ee.nekoko.nlpa2.AdbBridgeStarter $pkg\""
    }

    /** Run `call` against the helper off the UI thread, JSON answer to a map. */
    private fun forward(result: MethodChannel.Result, call: (IAdbBridge) -> String) {
        val binder = AdbBridgeHub.bridge()
        if (binder == null || !binder.isBinderAlive) {
            main.post {
                result.success(errorMap("NO_BRIDGE", "No computer connection is active"))
            }
            return
        }

        val service = IAdbBridge.Stub.asInterface(binder)
        worker.execute {
            val answer = try {
                jsonToMap(JSONObject(call(service)))
            } catch (e: Throwable) {
                Log.w(TAG, "helper call failed", e)
                errorMap("BRIDGE_CALL_FAILED", e.message ?: e.toString())
            }
            main.post { result.success(answer) }
        }
    }

    private fun disconnect(result: MethodChannel.Result) {
        val binder = AdbBridgeHub.bridge()
        worker.execute {
            if (binder != null && binder.isBinderAlive) {
                try {
                    // The helper exits while answering, so a dead binder here is
                    // the expected outcome, not a failure.
                    IAdbBridge.Stub.asInterface(binder).shutdown()
                } catch (_: Throwable) {
                }
            }
            AdbBridgeHub.disconnect()
            main.post { result.success(null) }
        }
    }

    private fun errorMap(code: String, message: String): Map<String, Any?> =
        linkedMapOf("ok" to false, "errorCode" to code, "errorMessage" to message)

    private fun jsonToMap(obj: JSONObject): Map<String, Any?> {
        val map = linkedMapOf<String, Any?>()
        for (key in obj.keys()) map[key] = normalize(obj.get(key))
        return map
    }

    private fun normalize(value: Any?): Any? = when (value) {
        is JSONObject -> jsonToMap(value)
        is JSONArray -> (0 until value.length()).map { normalize(value.get(it)) }
        JSONObject.NULL -> null
        else -> value
    }

    companion object {
        private const val TAG = "AdbBridgePlugin"
        private const val CHANNEL = "nlpa2/adb_bridge"
        private const val EVENTS = "nlpa2/adb_bridge/events"
        private const val STATE_CONNECTED = "connected"
        private const val STATE_DISCONNECTED = "disconnected"
        private const val DEFAULT_WINDOW_MS = 120_000L
    }
}
