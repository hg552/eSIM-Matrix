#!/usr/bin/env python3
"""
Tidy the ASN.1 sources in tools/asn1/.

    python3 tools/asn1_format.py [--check] [files...]

Whitespace hygiene only: CRLF to LF, no trailing blanks, no runs of blank
lines, exactly one newline at the end.

It deliberately does not reindent. These modules follow three different house
styles -- SGP.22 puts its named-number lists under a hanging indent, the PKIX
extracts align comment continuations under the statement they belong to, and
value assignments wrap their OID arcs by eye. Reindenting by brace depth was
tried and flattened all of that, including comments carried over from the
RFCs, so the sources keep whatever layout their authors gave them.

`python3 tools/asn1_dart_gen.py --check` proves nothing here reaches the
generated Dart.
"""

from __future__ import annotations

import os
import sys


def format_text(text: str) -> str:
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out: list[str] = []
    for line in lines:
        line = line.rstrip()
        if not line and out and not out[-1]:
            continue  # collapse runs of blank lines
        out.append(line)
    while out and not out[-1]:
        out.pop()
    return "\n".join(out) + "\n"


def main() -> int:
    check = "--check" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    if not args:
        asn1_dir = os.path.join(script_dir, "asn1")
        args = [os.path.join(asn1_dir, name)
                for name in sorted(os.listdir(asn1_dir)) if name.endswith(".asn1")]

    changed = []
    for path in args:
        with open(path, encoding="utf-8", errors="replace") as handle:
            original = handle.read()
        formatted = format_text(original)
        if formatted == original:
            continue
        changed.append(path)
        if not check:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(formatted)

    for path in changed:
        verb = "would reformat" if check else "reformatted"
        print(f"{verb} {os.path.relpath(path, script_dir)}")
    if not changed:
        print(f"{len(args)} file(s) already tidy")
    return 1 if (check and changed) else 0


if __name__ == "__main__":
    raise SystemExit(main())
