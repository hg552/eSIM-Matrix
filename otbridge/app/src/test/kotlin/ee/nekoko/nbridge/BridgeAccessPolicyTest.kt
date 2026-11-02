package ee.nekoko.nbridge

import org.junit.Assert.*
import org.junit.Test

class BridgeAccessPolicyTest {
    @Test fun unapprovedApplicationsAreDeniedEvenWithKnownConnectionIds() {
        val policy = BridgeAccessPolicy(10050)
        policy.recordOwner("omapi:channel", 10051)
        assertThrows(SecurityException::class.java) { policy.enforceCaller(10051, false) }
        policy.enforceCaller(10051, true)
        policy.enforceOwner(10051, "omapi:channel")
        // Revocation must deny new calls even while a hardware close is pending.
        assertThrows(SecurityException::class.java) { policy.enforceCaller(10051, false) }
    }

    @Test fun rootShellAndBridgeItselfRemainAdministrativeCallers() {
        val policy = BridgeAccessPolicy(10050)
        for (uid in listOf(0, 2000, 10050)) policy.enforceCaller(uid, false)
        assertThrows(SecurityException::class.java) { policy.enforceCaller(10052, false) }
    }

    @Test fun approvedApplicationsCannotEnumerateTransmitOrCloseAnotherCallersChannel() {
        val policy = BridgeAccessPolicy(10050)
        policy.recordOwner("omapi:first", 10051)
        policy.recordOwner("tmapi:second", 10052)
        policy.enforceCaller(10052, true)
        assertFalse(policy.canAccess(10052, "omapi:first"))
        assertThrows(SecurityException::class.java) { policy.enforceOwner(10052, "omapi:first") }
        assertEquals(listOf("tmapi:second"), policy.ownedConnections(10052))
        policy.enforceOwner(10052, "tmapi:second")
        policy.forget("tmapi:second")
        assertThrows(SecurityException::class.java) { policy.enforceOwner(10052, "tmapi:second") }
    }

    @Test fun bridgeCanManageAllChannelsButShellCannotHijackAnAppChannel() {
        val policy = BridgeAccessPolicy(10050)
        policy.recordOwner("omapi:app", 10051)
        policy.enforceOwner(10050, "omapi:app")
        policy.enforceOwner(0, "omapi:app")
        assertThrows(SecurityException::class.java) { policy.enforceOwner(2000, "omapi:app") }
        assertThrows(SecurityException::class.java) { policy.enforceOwner(10051, "unknown") }
    }
}
