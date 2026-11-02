# Desktop VoWiFi / IMS

The public Dart implementation under `lib/vowifi_sms/` provides experimental SMS over IMS on Windows, macOS and Linux, backed by an external SIM/eUICC reader. The reader supplies AKA authentication; the app does not extract the SIM's long-term authentication key. The separate iOS calling stack is documented in [ios-vowifi.txt](ios-vowifi.txt).

## Platform and reader policy

- Android VoWiFi is disabled. A capable external adapter does not bypass this restriction.
- OMAPI adapters are ineligible even if a wrapper advertises raw APDUs. Both the selected reader and the adapter executing its APDUs are checked before the session or AKA operation begins.
- Desktop VoWiFi requires explicit opt-in and is disabled in 9eSIM-branded builds.
- Generic plain-SIM probing is separate from enabling a VoWiFi session. It remains available on compatible raw-APDU readers; the basic-channel probe rejects OMAPI.
- The iOS Manage entry retains its existing external CCID / RED BLE allowlist. It also uses the shared Android/OMAPI restriction.

## IMS behavior

The protocol changes were implemented against the following standards, with independent unit vectors and loopback SIP-peer tests:

| Area | Behavior | Reference |
| --- | --- | --- |
| SIP transactions | Ignore provisional and unrelated responses; match Call-ID, CSeq and the top Via branch before accepting a final response. Fail promptly on connection loss. | [RFC 3261, sections 17–18](https://www.rfc-editor.org/rfc/rfc3261.html#section-17) |
| AKA synchronization | Carry the SIM's AUTS into the next REGISTER with an empty Digest password, then process a fresh challenge within a bounded authentication loop. Accept standard base64 RAND/AUTN and exact 64-digit hexadecimal encodings. | [RFC 3310](https://www.rfc-editor.org/rfc/rfc3310.html) |
| Digest authentication | Preserve quoted commas/escapes; use binary RES, negotiate `auth` or `auth-int` for every MCC, hash the MESSAGE body for `auth-int`, echo opaque and increment nonce counts. Support MD5, MD5-sess, AKAv1-MD5, SHA-256 and SHA-256-sess; reject unsupported alternatives. | [RFC 7616](https://www.rfc-editor.org/rfc/rfc7616.html) |
| Registration routes | Preserve the ordered loose-routing Service-Route list for outbound MESSAGE/RP-ACK requests; replace or clear it after a successful refresh. | [RFC 3608](https://www.rfc-editor.org/rfc/rfc3608.html) |
| Registration interval | Honor valid Min-Expires after a 423 response, retrying once rather than looping indefinitely. | [RFC 3261, section 10.2.8](https://www.rfc-editor.org/rfc/rfc3261.html#section-10.2.8) |
| Stream handling | Accept fragmented/combined SIP messages, compact header names and leading CRLF keepalives; reject invalid/oversized frames. Serialize socket writes so an inbound acknowledgement cannot collide with a new registration request. | [RFC 3261](https://www.rfc-editor.org/rfc/rfc3261.html) |

## Open-source implementations reviewed

Research snapshot: 2026-10-28. These are engineering references, not claims that another project's carrier results apply to NekokoLPA2. No external implementation source was copied into this change.

- [selvakn/gsm-sip-bridge](https://github.com/selvakn/gsm-sip-bridge/tree/162c5cd6887e1f62a733a5779fa54e533058aeda): reviewed [Digest calculations](https://github.com/selvakn/gsm-sip-bridge/blob/162c5cd6887e1f62a733a5779fa54e533058aeda/gsm-sip-bridge/src/ims/digest.rs), [AKA reauthentication](https://github.com/selvakn/gsm-sip-bridge/blob/162c5cd6887e1f62a733a5779fa54e533058aeda/gsm-sip-bridge/src/ims/registration_auth.rs) and [SIP parsing/transactions](https://github.com/selvakn/gsm-sip-bridge/blob/162c5cd6887e1f62a733a5779fa54e533058aeda/gsm-sip-bridge/src/ims/sip_client.rs). The relevant comparisons were binary RES handling, AUTS recovery and compact-header transaction matching.
- [deeeeeeeeap/shannon-ims](https://github.com/deeeeeeeeap/shannon-ims/tree/82e53c0b429af9b6df5efd7b8317ea3bc7c0122d): reviewed its [REGISTER challenge regressions](https://github.com/deeeeeeeeap/shannon-ims/blob/82e53c0b429af9b6df5efd7b8317ea3bc7c0122d/vowifi-go/internal/vowifi/imscore/register_401_unit_test.go), routing and SMS implementation. In particular, its nonce tests distinguish hexadecimal RAND/AUTN from base64 encoding.
- [pagecat/vowifi_gateway](https://github.com/pagecat/vowifi_gateway/tree/e3719840b93961f933aab3dac8bd2641936e2bcc): reviewed its reader-backed ePDG / Asterisk architecture and [IMS PJSIP configuration](https://github.com/pagecat/vowifi_gateway/blob/e3719840b93961f933aab3dac8bd2641936e2bcc/engine/templates/pjsip.conf.j2). NekokoLPA2 continues to run its desktop SMS stack inside the app; this work adds no Asterisk, Docker or privileged routing requirement.

## Regression checks

From the Flutter app directory:

```sh
flutter test --no-pub test/services/ims_digest_test.dart \
  test/services/ims_sip_client_test.dart \
  test/services/vowifi_reader_support_test.dart
```

The local SIP peer exercises provisional/stray responses, fragmented compact headers, AUTS followed by a fresh nonce, combined associated identities, route refresh, Min-Expires, connection loss and malformed frame lengths. The reader tests use synthetic identities and fake adapters; they do not contact a carrier.

## Remaining limits

This change does not establish carrier interoperability. Real reader/SIM/carrier testing is still required. The desktop implementation remains SMS-focused and does not gain the iOS voice/audio stack. Existing ePDG certificate behavior, IMS IPsec profile negotiation, UDP retransmission policy, automatic long-duration refresh and handover need separate validation; the local TCP SIP tests do not establish those properties. AKAv2 and unimplemented Digest algorithms are rejected rather than treated as MD5. A session reporting a SIP success is distinct from end-to-end SMS delivery.
