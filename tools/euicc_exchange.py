#!/usr/bin/env python3
"""
Send a scripted list of ES10 requests to the eUICC and record the responses.

Unlike tools/euicc_probe.py this is NOT read-only: it sends whatever the input
file contains, which is how the enable/disable round-trip is exercised. The
input is the JSON that test/models/asn1/hardware_build_requests.dart writes,
i.e. a list of {"name": ..., "request": "<hex TLV>"}.

    python3 tools/euicc_exchange.py requests.json responses.json

Each response is recorded whether or not the card reports success, so a failed
step still ends up in the trace.
"""

import json
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])

from euicc_probe import ISD_R_AID, Card  # noqa: E402


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    steps = json.load(open(sys.argv[1]))

    card = Card()
    print(f"reader : {card.reader.decode()}")
    channel = card.open_channel()
    print(f"channel: {channel}")
    results = []
    try:
        fcp = card.select(ISD_R_AID)
        print(f"ISD-R  : selected ({len(fcp)} byte FCP)\n")
        for step in steps:
            name, request = step["name"], step["request"]
            try:
                response = card.store_data(bytes.fromhex(request))
                status = "ok"
            except SystemExit as exc:
                response, status = b"", str(exc)
            results.append({"name": name, "request": request,
                            "response": response.hex().upper(), "status": status})
            print(f"{name:24s} -> {status:4s} {len(response):3d} bytes  "
                  f"{response[:24].hex().upper()}")
    finally:
        card.close_channel()

    with open(sys.argv[2], "w") as handle:
        json.dump(results, handle, indent=2)
    print(f"\nwrote {sys.argv[2]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
