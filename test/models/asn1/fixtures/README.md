# Captures

Recorded from a real eUICC in a card reader and a real ES9+ download from the
public test SM-DP+ at `smdp.io`. The checkers in the parent directory take one
of these as an argument:

```bash
dart run test/models/asn1/hardware_capture_check.dart  fixtures/live_capture.json
dart run test/models/asn1/hardware_exchange_check.dart fixtures/responses.json
dart run test/models/asn1/es9_capture_check.dart       fixtures/es9_flow.json
```

| file | contents |
| --- | --- |
| `live_capture.json` | the ES10 reads: GetEID, GetEUICCInfo1/2, GetProfilesInfo, GetEUICCChallenge, GetEuiccConfiguredAddresses, GetRAT |
| `responses.json` | the enable/disable round-trip, request and response per step |
| `postdownload.json` | the same reads with the downloaded profile present |
| `es9_flow.json` | every ES9+ request and response body of a full download |

To record your own:

```bash
python3 tools/euicc_probe.py    test/models/asn1/fixtures/live_capture.json
python3 tools/euicc_exchange.py requests.json responses.json
```

`euicc_probe.py` is read-only -- see its REQUESTS list; eUICCMemoryReset and
the Set* commands are deliberately absent. `euicc_exchange.py` sends whatever
the input file contains, so it can change profile state.

The last two reads are not commands the app sends. The generated model covers
them, so `es10_reads_test.dart` is the only thing keeping them honest.

ICCIDs in these files are in the stored, nibble-swapped form. An odd-length one
carries its BCD filler second from last — `980000000000000030F4` — and the
filler only reaches the end once the nibbles are swapped for display. An `F`
elsewhere in an ICCID is real and must not be stripped.
