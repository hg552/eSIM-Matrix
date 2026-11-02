#!/usr/bin/env python3
"""
Generate lib/models/asn1/rsp_definitions.g.dart directly from the ASN.1 modules
in tools/asn1/.

Reads the ASN.1 with tools/asn1_syntax.py, turns it into the TypeDef model with
tools/asn1_model.py, and emits Dart with tools/asn1_emit.py. Stdlib only.

Usage:
    python3 tools/asn1_dart_gen.py [--output PATH] [--check]

--check regenerates into a temporary file and reports whether the checked-in
Dart still matches, declaration by declaration.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Dict, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import asn1_emit as emitter
from asn1_emit import TypeDef
from asn1_model import build_model

ASN1_FILES = [
    "PKIXExplicit88.asn1",
    "PKIXImplicit88.asn1",
    "PEDefinitions.asn1",
    "RSPDefinitions.asn1",
    "Supplementary.asn1",
]


def source_paths(script_dir: str) -> List[str]:
    asn1_dir = os.path.join(script_dir, "asn1")
    paths = []
    for name in ASN1_FILES:
        path = os.path.join(asn1_dir, name)
        if os.path.exists(path):
            paths.append(path)
        elif name != "Supplementary.asn1":
            raise SystemExit(f"missing ASN.1 source: {path}")
    return paths


def order_preserving_prune(types: List[TypeDef]) -> List[TypeDef]:
    """prune_types() returns a set-ordered list; restore a stable order.

    Everything the model produced keeps its source order; the synthetic
    typedefs prune_types() adds for dangling references are appended in name
    order, so the output is byte-stable across runs.
    """
    original = [t.name for t in types]
    pruned = emitter.prune_types(types, original)
    by_name: Dict[str, TypeDef] = {t.name: t for t in pruned}
    ordered = [by_name.pop(name) for name in original if name in by_name]
    ordered.extend(by_name[name] for name in sorted(by_name))
    return ordered


def build(script_dir: str) -> List[TypeDef]:
    types = build_model(source_paths(script_dir))
    types = order_preserving_prune(types)
    emitter.fill_missing_field_tags(types)
    emitter.extend_basic_types(types)
    return types


def declarations(path: str) -> Dict[str, str]:
    """Split a generated Dart file into top-level declarations, keyed by name."""
    import re

    blocks: Dict[str, List[str]] = {}
    name = None
    current: List[str] = []
    for line in open(path, encoding="utf-8").read().splitlines():
        match = re.match(r"^(class|enum|extension|typedef|dynamic) ([A-Za-z0-9_]+)", line)
        if match:
            if name:
                blocks.setdefault(name, []).extend(current)
            name = f"{match.group(1)} {match.group(2)}"
            current = [line]
        elif name is not None:
            current.append(line)
    if name:
        blocks.setdefault(name, []).extend(current)
    return {k: "\n".join(v).strip() for k, v in blocks.items()}


def dart_format(path: str) -> None:
    """Best-effort `dart format`, so comparisons ignore pure layout differences."""
    import subprocess
    try:
        subprocess.run(["dart", "format", path], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        pass


def run_check(generated: str, reference: str) -> int:
    if not os.path.exists(reference):
        print(f"no reference file at {reference}")
        return 1
    dart_format(generated)
    new = declarations(generated)
    old = declarations(reference)
    only_new = sorted(set(new) - set(old))
    only_old = sorted(set(old) - set(new))
    changed = sorted(k for k in set(new) & set(old) if new[k] != old[k])

    print(f"declarations: {len(new)} generated, {len(old)} in {os.path.basename(reference)}")
    for label, names in (("only in generated", only_new), ("missing from generated", only_old),
                         ("body differs", changed)):
        if names:
            print(f"  {label}: {len(names)}")
            for entry in names[:20]:
                print(f"    {entry}")
            if len(names) > 20:
                print(f"    ... and {len(names) - 20} more")
    return 0 if not (only_new or only_old or changed) else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="destination .dart file")
    parser.add_argument("--check", action="store_true",
                        help="compare against the checked-in Dart instead of overwriting it")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    default_output = os.path.join(project_root, "lib", "models", "asn1", "rsp_definitions.g.dart")
    output = args.output or default_output

    types = build(script_dir)

    if args.check:
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".dart", delete=False) as tmp:
            temp_path = tmp.name
        emitter.generate_dart(types, temp_path)
        try:
            return run_check(temp_path, output)
        finally:
            os.unlink(temp_path)

    os.makedirs(os.path.dirname(output), exist_ok=True)
    emitter.generate_dart(types, output)
    print(f"Generated {output} from {len(types)} ASN.1 types")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
