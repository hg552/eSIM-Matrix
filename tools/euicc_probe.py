#!/usr/bin/env python3
"""
Read-only eUICC probe over PC/SC.

Selects the ISD-R and issues the ES10 read commands below, then writes the raw
response TLVs to a JSON file so the generated Dart models can decode exactly the
bytes a real card produced.

Read-only by construction: see REQUESTS. Nothing enables, disables, deletes or
writes anything, and eUICCMemoryReset and the Set* commands are deliberately
absent.
"""

import ctypes
import json
import sys

PCSC = ctypes.CDLL("/System/Library/Frameworks/PCSC.framework/PCSC")
SCARD_SCOPE_SYSTEM = 2
SCARD_SHARE_SHARED = 2
SCARD_PROTOCOL_T0 = 1
SCARD_PROTOCOL_T1 = 2

ISD_R_AID = bytes.fromhex("A0000005591010FFFFFFFF8900000100")

# ES10 requests. Read-only, every one of them: each either returns state or,
# in GetEUICCChallenge's case, consumes a random challenge the card is happy to
# hand out. Nothing here writes.
REQUESTS = {
    "GetEID": bytes.fromhex("BF3E035C015A"),
    "GetEUICCInfo1": bytes.fromhex("BF2000"),
    "GetEUICCInfo2": bytes.fromhex("BF2200"),
    "GetProfilesInfo": bytes.fromhex("BF2D00"),
    "GetEUICCChallenge": bytes.fromhex("BF2E00"),
    # ES10a: the default SM-DP+ and root SM-DS the card is configured with.
    "GetEuiccConfiguredAddresses": bytes.fromhex("BF3C00"),
    # ES10c: the Rules Authorisation Table, which decides what profile policy
    # rules the card will accept.
    "GetRat": bytes.fromhex("BF4300"),
}


class Card:
    def __init__(self):
        self.ctx = ctypes.c_void_p()
        rc = PCSC.SCardEstablishContext(SCARD_SCOPE_SYSTEM, None, None, ctypes.byref(self.ctx))
        if rc & 0xFFFFFFFF:
            raise SystemExit(f"SCardEstablishContext failed: {rc & 0xFFFFFFFF:#x}")
        size = ctypes.c_uint32(0)
        PCSC.SCardListReaders(self.ctx, None, None, ctypes.byref(size))
        if not size.value:
            raise SystemExit("no PC/SC reader attached")
        buf = ctypes.create_string_buffer(size.value)
        PCSC.SCardListReaders(self.ctx, None, buf, ctypes.byref(size))
        self.reader = [n for n in buf.raw.split(b"\0") if n][0]
        self.handle = ctypes.c_void_p()
        proto = ctypes.c_uint32()
        # Ask for one protocol at a time. A cold card that only supports T=0
        # rejects the T=0|T=1 union outright rather than negotiating down, and
        # reports it as SCARD_W_UNPOWERED_CARD, which reads like an absent card.
        attempts = []
        for wanted in (SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1,
                       SCARD_PROTOCOL_T0, SCARD_PROTOCOL_T1):
            rc = PCSC.SCardConnect(self.ctx, self.reader, SCARD_SHARE_SHARED,
                                   wanted, ctypes.byref(self.handle),
                                   ctypes.byref(proto)) & 0xFFFFFFFF
            if rc == 0:
                break
            attempts.append(f"protocol {wanted}: {rc:#x}")
        else:
            raise SystemExit(f"cannot connect to a card in {self.reader.decode()} "
                             f"({'; '.join(attempts)})")
        self.proto = proto.value
        self.pci = (ctypes.c_uint32 * 2)(self.proto, 8)

    def transmit(self, apdu: bytes) -> tuple[bytes, int]:
        out = ctypes.create_string_buffer(4096)
        out_len = ctypes.c_uint32(4096)
        rc = PCSC.SCardTransmit(self.handle, ctypes.byref(self.pci), apdu, len(apdu),
                                None, out, ctypes.byref(out_len)) & 0xFFFFFFFF
        if rc:
            raise SystemExit(f"SCardTransmit failed: {rc:#x}")
        data = out.raw[:out_len.value]
        if len(data) < 2:
            # A reader that refuses to send a malformed APDU returns nothing;
            # report it as a status word of 0 rather than indexing off the end.
            return b"", 0
        return data[:-2], (data[-2] << 8) | data[-1]

    def send(self, apdu: bytes) -> bytes:
        """Transmit, following 61xx GET RESPONSE chains."""
        body, sw = self.transmit(apdu)
        while sw >> 8 == 0x61:
            more, sw = self.transmit(bytes([0x00, 0xC0, 0x00, 0x00, sw & 0xFF]))
            body += more
        if sw != 0x9000:
            raise SystemExit(f"card returned SW {sw:04X} for {apdu.hex().upper()}")
        return body

    def open_channel(self) -> int:
        """MANAGE CHANNEL open. The ISD-R is not reachable on the basic channel."""
        body, sw = self.transmit(bytes([0x00, 0x70, 0x00, 0x00, 0x00]))
        if sw >> 8 == 0x6C:  # wrong Le, the card just told us the right one
            body, sw = self.transmit(bytes([0x00, 0x70, 0x00, 0x00, sw & 0xFF]))
        if sw != 0x9000 or not body:
            raise SystemExit(f"MANAGE CHANNEL failed: SW {sw:04X}")
        self.channel = body[0]
        return self.channel

    def close_channel(self) -> None:
        if getattr(self, "channel", 0):
            self.transmit(bytes([0x00, 0x70, 0x80, self.channel, 0x00]))
            self.channel = 0

    def select(self, aid: bytes) -> bytes:
        cla = getattr(self, "channel", 0)
        return self.send(bytes([cla, 0xA4, 0x04, 0x00, len(aid)]) + aid + b"\x00")

    def store_data(self, payload: bytes) -> bytes:
        """ES10 STORE DATA, splitting into 255-byte blocks when needed."""
        cla = 0x80 | getattr(self, "channel", 0)
        blocks = [payload[i:i + 255] for i in range(0, len(payload), 255)] or [b""]
        for block in blocks[:-1]:
            self.send(bytes([cla, 0xE2, 0x11, 0x00, len(block)]) + block)
        last = blocks[-1]
        return self.send(bytes([cla, 0xE2, 0x91, 0x00, len(last)]) + last + b"\x00")


def main() -> int:
    card = Card()
    print(f"reader : {card.reader.decode()}")
    channel = card.open_channel()
    print(f"channel: {channel}")
    captured = {}
    try:
        fcp = card.select(ISD_R_AID)
        print(f"ISD-R  : selected ({len(fcp)} byte FCP)")

        for name, request in REQUESTS.items():
            try:
                response = card.store_data(request)
            except SystemExit as exc:
                print(f"{name:16s}: {exc}")
                continue
            captured[name] = response.hex().upper()
            print(f"{name:16s}: {len(response)} bytes, tag {response[:2].hex().upper()}")
    finally:
        card.close_channel()

    out = sys.argv[1] if len(sys.argv) > 1 else "euicc_capture.json"
    with open(out, "w") as handle:
        json.dump(captured, handle, indent=2)
    print(f"\nwrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
