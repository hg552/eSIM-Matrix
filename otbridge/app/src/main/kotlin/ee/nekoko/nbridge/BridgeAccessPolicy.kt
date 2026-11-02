package ee.nekoko.nbridge

/** Caller identity is an Android UID, never a package name supplied over IPC. */
internal class BridgeAccessPolicy(private val serviceUid: Int) {
    private val owners = HashMap<String, Int>()

    fun isManager(uid: Int): Boolean = uid == 0 || uid == serviceUid

    fun enforceCaller(uid: Int, approved: Boolean) {
        if (!isManager(uid) && uid != 2000 && !approved) {
            throw SecurityException("Open OTBridge and explicitly approve this app first")
        }
    }

    fun recordOwner(connectionId: String, uid: Int) {
        owners[connectionId] = uid
    }

    fun canAccess(uid: Int, connectionId: String): Boolean =
        isManager(uid) || owners[connectionId] == uid

    fun enforceOwner(uid: Int, connectionId: String) {
        if (!canAccess(uid, connectionId)) {
            throw SecurityException("Connection belongs to another caller")
        }
    }

    fun forget(connectionId: String) {
        owners.remove(connectionId)
    }

    fun ownedConnections(uid: Int): List<String> {
        val result = ArrayList<String>()
        for ((id, owner) in owners) if (owner == uid) result.add(id)
        return result
    }
}
