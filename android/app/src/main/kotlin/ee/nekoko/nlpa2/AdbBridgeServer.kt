package ee.nekoko.nlpa2

import android.content.Context
import android.os.Binder
import android.os.Process
import android.telephony.TelephonyManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * The privileged half of the ADB bridge, running in the `shell` process.
 *
 * It opens logical channels and moves APDUs through the platform's telephony
 * service, which an ordinary app is not allowed to do but the `shell` user is.
 * It reaches those operations through the hidden `iccOpenLogicalChannel*` /
 * `iccTransmitApdu*` family on [TelephonyManager]. That family's exact
 * signatures drift between Android releases, so each is resolved reflectively
 * against a few known shapes and the first that exists is used.
 *
 * It calls only the documented privileged path. Where a release or a device
 * declines `shell` that access, a call fails and says so; nothing here reaches
 * the card another way.
 *
 * A connection id is `slotIndex:channel`, so routing a transmit or a close
 * needs no state kept across calls.
 */
class AdbBridgeServer(context: Context) : IAdbBridge.Stub() {
    private val telephony =
        context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
    private val telephonyClass: Class<*> = telephony.javaClass

    /** The package the platform attributes these calls to: the real caller. */
    private val callingPackage = "com.android.shell"

    override fun shutdown() {
        Log.i(TAG, "shutdown")
        AdbBridgeStarter.stop()
    }

    override fun ping(): String = ok {
        put("protocol", AdbBridgeHub.PROTOCOL_VERSION)
        put("uid", Binder.getCallingUid())
        put("serverUid", Process.myUid())
    }

    override fun listSlots(): String = guarded {
        ok {
            val slots = JSONArray()
            for (index in 0 until slotCount()) {
                slots.put(
                    JSONObject().apply {
                        put("id", index.toString())
                        put("displayName", "SIM slot ${index + 1}")
                    },
                )
            }
            put("slots", slots)
        }
    }

    override fun openLogicalChannel(slotId: String, aids: List<String>?): String = guarded {
        val slot = slotId.toInt()
        val candidates = aids?.filter { it.isNotBlank() } ?: emptyList()
        if (candidates.isEmpty()) return@guarded error("NO_AID", "No AID to select")

        var lastStatus = -1
        for (aid in candidates) {
            val response = openOnSlot(slot, aid) ?: continue
            val channel = responseChannel(response)
            if (channel <= 0) {
                lastStatus = responseStatus(response)
                continue
            }
            val selectResponse = responseSelect(response)
            return@guarded ok {
                put("connectionId", "$slot:$channel")
                put("selectedAid", aid)
                put("channelNumber", channel)
                put("responseApdu", selectResponse)
            }
        }
        error("CHANNEL_OPEN_FAILED", "No AID opened a channel on slot $slot (status $lastStatus)")
    }

    override fun transmitLogical(connectionId: String, apduHex: String): String = guarded {
        val (slot, channel) = parseConnection(connectionId)
        val apdu = Apdu.parse(apduHex)
        val response = transmitLogicalOnSlot(slot, channel, apdu)
            ?: return@guarded error("TRANSMIT_FAILED", "The platform returned no response")
        ok { put("responseApdu", response) }
    }

    override fun transmitBasic(slotId: String, apduHex: String): String = guarded {
        val slot = slotId.toInt()
        val apdu = Apdu.parse(apduHex)
        val response = transmitBasicOnSlot(slot, apdu)
            ?: return@guarded error("TRANSMIT_FAILED", "The platform returned no response")
        ok { put("responseApdu", response) }
    }

    override fun closeLogicalChannel(connectionId: String): String = guarded {
        val (slot, channel) = parseConnection(connectionId)
        closeOnSlot(slot, channel)
        ok {}
    }

    // --- platform calls, resolved against the signatures a release might carry -

    private fun slotCount(): Int {
        for (name in listOf("getActiveModemCount", "getPhoneCount", "getSupportedModemCount")) {
            invoke(name)?.let { return (it as Int).coerceAtLeast(1) }
        }
        return 1
    }

    private fun openOnSlot(slot: Int, aid: String): Any? {
        val p2 = 0
        return invokeFirst(
            Signature("iccOpenLogicalChannelBySlot", INT, STRING, INT) { arrayOf(slot, aid, p2) },
            Signature("iccOpenLogicalChannelBySlot", INT, STRING, STRING, INT) {
                arrayOf(slot, callingPackage, aid, p2)
            },
            Signature("iccOpenLogicalChannel", STRING, INT) { arrayOf(aid, p2) },
            Signature("iccOpenLogicalChannel", STRING, STRING, INT) {
                arrayOf(callingPackage, aid, p2)
            },
        )
    }

    private fun transmitLogicalOnSlot(slot: Int, channel: Int, a: Apdu): String? = invokeFirst(
        Signature(
            "iccTransmitApduLogicalChannelBySlot",
            INT, INT, INT, INT, INT, INT, INT, STRING,
        ) { arrayOf(slot, channel, a.cla, a.ins, a.p1, a.p2, a.p3, a.data) },
        Signature(
            "iccTransmitApduLogicalChannel",
            INT, INT, INT, INT, INT, INT, STRING,
        ) { arrayOf(channel, a.cla, a.ins, a.p1, a.p2, a.p3, a.data) },
    ) as String?

    private fun transmitBasicOnSlot(slot: Int, a: Apdu): String? = invokeFirst(
        Signature(
            "iccTransmitApduBasicChannelBySlot",
            INT, STRING, INT, INT, INT, INT, INT, STRING,
        ) { arrayOf(slot, callingPackage, a.cla, a.ins, a.p1, a.p2, a.p3, a.data) },
        Signature(
            "iccTransmitApduBasicChannelBySlot",
            INT, INT, INT, INT, INT, INT, STRING,
        ) { arrayOf(slot, a.cla, a.ins, a.p1, a.p2, a.p3, a.data) },
        Signature(
            "iccTransmitApduBasicChannel",
            STRING, INT, INT, INT, INT, INT, STRING,
        ) { arrayOf(callingPackage, a.cla, a.ins, a.p1, a.p2, a.p3, a.data) },
    ) as String?

    private fun closeOnSlot(slot: Int, channel: Int) {
        invokeFirst(
            Signature("iccCloseLogicalChannelBySlot", INT, INT) { arrayOf(slot, channel) },
            Signature("iccCloseLogicalChannel", INT) { arrayOf(channel) },
        )
    }

    private fun responseChannel(response: Any): Int =
        (response.javaClass.getMethod("getChannel").invoke(response) as? Int) ?: -1

    private fun responseStatus(response: Any): Int =
        (response.javaClass.getMethod("getStatus").invoke(response) as? Int) ?: -1

    private fun responseSelect(response: Any): String {
        val bytes = response.javaClass.getMethod("getSelectResponse").invoke(response) as? ByteArray
        return bytes?.toHex() ?: ""
    }

    // --- reflection plumbing ------------------------------------------------

    private class Signature(
        val name: String,
        vararg val types: Class<*>,
        val args: () -> Array<Any?>,
    )

    private fun invokeFirst(vararg signatures: Signature): Any? {
        for (signature in signatures) {
            val method = try {
                telephonyClass.getMethod(signature.name, *signature.types)
            } catch (_: NoSuchMethodException) {
                continue
            }
            return method.invoke(telephony, *signature.args())
        }
        throw NoSuchMethodException(
            "No telephony method matched ${signatures.firstOrNull()?.name}",
        )
    }

    private fun invoke(name: String): Any? = try {
        telephonyClass.getMethod(name).invoke(telephony)
    } catch (_: NoSuchMethodException) {
        null
    }

    private fun parseConnection(connectionId: String): Pair<Int, Int> {
        val parts = connectionId.split(":")
        require(parts.size == 2) { "Bad connection id $connectionId" }
        return parts[0].toInt() to parts[1].toInt()
    }

    // --- answers ------------------------------------------------------------

    private inline fun ok(build: JSONObject.() -> Unit): String =
        JSONObject().apply { put("ok", true); build() }.toString()

    private fun error(code: String, message: String): String =
        JSONObject().apply {
            put("ok", false)
            put("errorCode", code)
            put("errorMessage", message)
        }.toString()

    private inline fun guarded(body: () -> String): String = try {
        body()
    } catch (e: Throwable) {
        val root = generateSequence(e) { it.cause?.takeIf { c -> c !== it } }.last()
        Log.w(TAG, "call failed", root)
        error(root.javaClass.simpleName, root.message ?: root.javaClass.name)
    }

    companion object {
        private const val TAG = "AdbBridgeServer"
        private val INT = Integer.TYPE
        private val STRING = String::class.java

        private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
    }
}

/** An APDU split into the fields the telephony service takes it in. */
private class Apdu(
    val cla: Int,
    val ins: Int,
    val p1: Int,
    val p2: Int,
    val p3: Int,
    val data: String,
) {
    companion object {
        fun parse(hex: String): Apdu {
            val clean = hex.trim().replace(" ", "")
            val bytes = ByteArray(clean.length / 2) {
                clean.substring(it * 2, it * 2 + 2).toInt(16).toByte()
            }
            require(bytes.size >= 4) { "APDU shorter than a header: $hex" }
            val cla = bytes[0].toInt() and 0xFF
            val ins = bytes[1].toInt() and 0xFF
            val p1 = bytes[2].toInt() and 0xFF
            val p2 = bytes[3].toInt() and 0xFF
            // Header only: no body, no length.
            if (bytes.size == 4) return Apdu(cla, ins, p1, p2, 0, "")
            // Byte 4 is the length; what follows, if anything, is the body. A
            // lone length byte with no body is a case-2 Le, which the service
            // still takes here as p3.
            val p3 = bytes[4].toInt() and 0xFF
            val data = if (bytes.size > 5) {
                bytes.copyOfRange(5, bytes.size).joinToString("") { "%02x".format(it) }
            } else {
                ""
            }
            return Apdu(cla, ins, p1, p2, p3, data)
        }
    }
}
