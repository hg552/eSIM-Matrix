# OMAPI restart regression

Reports from Xiaomi 15 and both standard and 9eSIM 2.4.0+600 builds show this diagnostic:

```text
OMAPI_SESSION_CORRUPTED
reason: OMAPI safety guard survived an unclean process exit on this boot
```

This blocks reader discovery before any ATR or card application is read. It is different from an ARA-M signing-certificate rejection. Repeated refreshes cannot clear the latched safety state.

## Cause and fix

2.4.0 armed a durable crash guard when it bound the Secure Element service and before hardware operations. It cleared the guard only during confirmed service shutdown. Android can terminate a background process without the engine-detach cleanup callback, so a routine idle process exit left the same marker as interrupted unsafe cleanup. The next launch inferred corruption and hid OMAPI readers; the composite reader list swallowed the error and showed the empty-reader prompt.

The fix adds a serialized safe-idle checkpoint. It verifies that no logical channels remain open and no profile switch is in progress, retains verified-empty sessions for reuse without invoking Samsung's unsafe bulk-close methods, and then clears the guard. A live channel, an active profile switch, a real failed close or a failed persistence write cannot take that path. Actual poisoned state remains reboot-required, including across process restarts.

Discovery also waits for the asynchronous service callback, refreshes when the service becomes available and honors manual forced refresh. If OMAPI remains blocked and no other reader is available, the app shows the recovery error rather than asking the user to connect Bluetooth.

These changes are newer than the original 2.4.0+600 release APKs. For a device already carrying the ambiguous old guard, install a build with the fix and **reboot once**; the old state is not silently deleted. Clearing app data is unnecessary and loses local settings/notes. Device confirmation is still needed after the automated regression tests.

## ATR capability and signing lineage

An ATR's global interface byte can advertise eUICC functionality. That is a capability indicator, not proof that a profile is currently enabled, that ARA-M permits this app, or that OMAPI discovery is healthy. This particular failure occurs before ATR retrieval. See [ETSI TS 102 221](https://www.etsi.org/deliver/etsi_ts/102200_102299/102221/18.04.00_60/ts_102221v180400p.pdf).

`apksigner rotate` creates a signing-certificate succession chain. It supports compatible app upgrades; it is not interchangeable with simultaneously presenting multiple signing certificates for card access. OMAPI certificate handling varies across Android/vendor implementations, so changing signing to a lineage needs separate card/device validation. The restart fix does not require a signing-key change. See [Android apksigner](https://developer.android.com/tools/apksigner#usage-rotate).
