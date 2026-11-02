package ee.nekoko.nlpa2;

/**
 * What the app asks of a helper it cannot start itself.
 *
 * Opening a logical channel to the ISD-R applet takes a caller the platform
 * trusts, which the app is not. The `shell` user is, and a person with a
 * computer can start a process as `shell` over ADB. [AdbBridgeStarter] is that
 * process: it implements this interface and hands the binder back to the app
 * through [AdbBridgeProvider]. From then on the app sends the card work here
 * and the privileged half runs in the `shell` process.
 *
 * This is the same shape [NBridgePlugin] uses to reach OTBridge and the same
 * reader operations [NBridgeAdapter] drives, so the Dart side is shared. The
 * difference is only where the privilege comes from: a Magisk module there, an
 * ADB session here.
 *
 * Structured answers are JSON, so the wire never depends on a Parcelable class
 * being loadable in both processes. Every answer carries `ok`; a false `ok`
 * carries `errorCode` and `errorMessage` instead of a result.
 */
interface IAdbBridge {
    /**
     * Stop the helper. Reserved for the app, which calls it when it is done
     * with the session; the process exits once it returns.
     */
    void shutdown() = 16777114;

    /**
     * A liveness and version check. Answers JSON with the protocol version the
     * helper speaks and the user it runs as, so the app can refuse a helper it
     * does not understand or one that is not actually `shell`.
     */
    String ping() = 1;

    /**
     * The eUICC slots the helper can reach, as JSON `{ ok, slots: [ { id,
     * displayName } ] }`. `id` is what the app passes back as `slotId`.
     */
    String listSlots() = 2;

    /**
     * Open a logical channel on `slotId`, selecting the first of `aids` that
     * answers. Answers JSON `{ ok, connectionId, selectedAid, channelNumber,
     * responseApdu }`; `connectionId` is what the app passes to
     * [transmitLogical] and [closeLogicalChannel].
     */
    String openLogicalChannel(String slotId, in List<String> aids) = 3;

    /** Send one APDU on a channel opened by [openLogicalChannel]. */
    String transmitLogical(String connectionId, String apduHex) = 4;

    /** Send one APDU on the basic channel of `slotId`. */
    String transmitBasic(String slotId, String apduHex) = 5;

    /** Close a channel opened by [openLogicalChannel]. */
    String closeLogicalChannel(String connectionId) = 6;
}
