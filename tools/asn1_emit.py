#!/usr/bin/env python3
"""
Emits Dart from the TypeDef/FieldDef model.

This is the back end only. tools/asn1_dart_gen.py is the entry point; it reads
the ASN.1 in tools/asn1/ via tools/asn1_syntax.py and tools/asn1_model.py, then
calls generate_dart() here.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple


# ---------------
# The type model
# ---------------

@dataclass
class FieldDef:
    name: str
    type_name: str
    tag_num: Optional[int]
    tag_class: Optional[str]
    is_list: bool = False
    is_explicit: bool = False
    is_optional: bool = False
    kind: Optional[str] = None


@dataclass
class TypeDef:
    name: str
    kind: str  # seq, choice, seq_of, int, bool, string, octets, bits, typedef
    tag_num: Optional[int] = None
    tag_class: Optional[str] = None
    is_explicit: bool = False
    is_inline: bool = False
    fields: List[FieldDef] = field(default_factory=list)
    enum_values: Dict[str, int] = field(default_factory=dict)
    element_type: Optional[str] = None  # for seq_of
    base_type: Optional[str] = None     # for typedef/basic


# Global helpers populated at generation time
enums_in_scope: set = set()
bits_in_scope: set = set()
basic_types = {"String", "Uint8List", "int", "bool"}


# -------------------
# Dart code emission
# -------------------

def tag_class_base(tag_class: Optional[str]) -> int:
    if tag_class == "TAG_APPLICATION":
        return 0x40
    if tag_class == "TAG_PRIVATE":
        return 0xC0
    if tag_class == "TAG_CONTEXT_SPEC":
        return 0x80
    return 0x00


def encode_tag_value(tag_num: int, class_base: int, constructed: bool) -> int:
    first = class_base | (0x20 if constructed else 0x00)
    if tag_num < 31:
        return first | tag_num
    first |= 0x1F
    tag_bytes: List[int] = []
    v = tag_num
    while v > 0:
        tag_bytes.insert(0, v & 0x7F)
        v >>= 7
    value = first
    for idx, b in enumerate(tag_bytes):
        octet = b | 0x80 if idx < len(tag_bytes) - 1 else b
        value = (value << 8) | octet
    return value


def tag_int(tag_num: Optional[int], tag_class: Optional[str], constructed: bool, is_explicit: bool = False) -> Optional[int]:
    if tag_num is None:
        return None
    return encode_tag_value(tag_num, tag_class_base(tag_class), constructed or is_explicit)


def dart_type_name(t: TypeDef, resolve_typedef: bool = False) -> str:
    # print(f"DART_TYPE: {t.name} (kind={t.kind}, elem={t.element_type})")
    if t.name in ("OPENTYPE", "typedef", "dynamic"):
        return "Uint8List"
    if not resolve_typedef and t.kind == "typedef" and t.base_type:
        return t.name
    if t.enum_values:
        return t.name
    if t.kind in ("time_utc", "time_gen", "string", "oid"):
        return "String"
    if t.kind == "octets":
        return "Uint8List"
    if t.kind == "bits":
        return t.name if t.name in bits_in_scope else "int"
    if t.kind == "bool":
        return "bool"
    if t.kind == "int":
        return "int"
    if t.kind == "seq_of":
        inner = t.element_type or "dynamic"
        if inner == t.name:
            inner = "dynamic"
        return f"List<{inner}>"
    if t.base_type:
        # If we are here and resolve_typedef is True, map base_type kind to Dart
        return {
            "int": "int",
            "time_utc": "String",
            "time_gen": "String",
            "string": "String",
            "octets": "Uint8List",
            "bool": "bool",
            "oid": "String",
            "bits": "int",
        }.get(t.base_type, t.base_type)
    return t.name


def emit_helpers(f):
    f.write("import 'dart:typed_data';\n")
    f.write("import 'dart:convert';\n")
    f.write("import './simple_reader.dart';\n\n")
    f.write("// GENERATED FILE - do not edit.\n")
    f.write("// Source: tools/asn1/*.asn1  Regenerate: python3 tools/asn1_dart_gen.py\n\n")
    f.write("Uint8List _asn1EncodeLength(int length) {\n")
    f.write("  if (length < 0x80) return Uint8List.fromList([length]);\n")
    f.write("  final bytes = <int>[];\n")
    f.write("  var v = length;\n")
    f.write("  while (v > 0) { bytes.insert(0, v & 0xFF); v >>= 8; }\n")
    f.write("  bytes.insert(0, 0x80 | bytes.length);\n")
    f.write("  return Uint8List.fromList(bytes);\n")
    f.write("}\n\n")
    f.write("Uint8List _asn1EncodeInt(int value) {\n")
    f.write("  if (value == 0) return Uint8List.fromList([0]);\n")
    f.write("  List<int> bytes = [];\n")
    f.write("  int v = value;\n")
    f.write("  for (int i = 0; i < 8; i++) {\n")
    f.write("    bytes.insert(0, v & 0xFF);\n")
    f.write("    v >>= 8;\n")
    f.write("  }\n")
    f.write("  while (bytes.length > 1) {\n")
    f.write("    if (bytes[0] == 0x00 && (bytes[1] & 0x80) == 0) {\n")
    f.write("      bytes.removeAt(0);\n")
    f.write("    } else if (bytes[0] == 0xFF && (bytes[1] & 0x80) != 0) {\n")
    f.write("      bytes.removeAt(0);\n")
    f.write("    } else {\n")
    f.write("      break;\n")
    f.write("    }\n")
    f.write("  }\n")
    f.write("  return Uint8List.fromList(bytes);\n")
    f.write("}\n\n")
    f.write("int _asn1DecodeInt(Uint8List bytes) {\n")
    f.write("  if (bytes.isEmpty) return 0;\n")
    f.write("  int v = bytes[0] >= 0x80 ? -1 : 0;\n")
    f.write("  for (final b in bytes) {\n")
    f.write("    v = (v << 8) | b;\n")
    f.write("  }\n")
    f.write("  return v;\n")
    f.write("}\n\n")
    f.write("Uint8List _asn1EncodeBits(int value) {\n")
    f.write("  if (value == 0) return Uint8List.fromList([0, 0]);\n")
    f.write("  int maxBit = -1;\n")
    f.write("  for (int i = 63; i >= 0; i--) {\n")
    f.write("    if ((value & (1 << i)) != 0) {\n")
    f.write("      maxBit = i;\n")
    f.write("      break;\n")
    f.write("    }\n")
    f.write("  }\n")
    f.write("  if (maxBit == -1) return Uint8List.fromList([0, 0]);\n")
    f.write("  int numDataBytes = (maxBit / 8).floor() + 1;\n")
    f.write("  int unused = (8 - (maxBit + 1) % 8) % 8;\n")
    f.write("  final out = Uint8List(1 + numDataBytes);\n")
    f.write("  out[0] = unused;\n")
    f.write("  for (int i = 0; i <= maxBit; i++) {\n")
    f.write("    if ((value & (1 << i)) != 0) {\n")
    f.write("       int byteIdx = (i / 8).floor() + 1;\n")
    f.write("       int bitInByte = 7 - (i % 8);\n")
    f.write("       out[byteIdx] |= (1 << bitInByte);\n")
    f.write("    }\n")
    f.write("  }\n")
    f.write("  return out;\n")
    f.write("}\n\n")
    f.write("int _asn1DecodeBits(Uint8List bytes) {\n")
    f.write("  if (bytes.length < 2) return 0;\n")
    f.write("  int unused = bytes[0];\n")
    f.write("  int result = 0;\n")
    f.write("  for (int i = 1; i < bytes.length; i++) {\n")
    f.write("    int b = bytes[i];\n")
    f.write("    if (i == bytes.length - 1) {\n")
    f.write("       b &= (0xFF << unused) & 0xFF;\n")
    f.write("    }\n")
    f.write("    for (int j = 0; j < 8; j++) {\n")
    f.write("       if ((b & (0x80 >> j)) != 0) {\n")
    f.write("          int bitIdx = (i - 1) * 8 + j;\n")
    f.write("          if (bitIdx < 64) {\n")
    f.write("             result |= (1 << bitIdx);\n")
    f.write("          }\n")
    f.write("       }\n")
    f.write("    }\n")
    f.write("  }\n")
    f.write("  return result;\n")
    f.write("}\n\n")
    f.write("List<int> _tagBytes(int tag) { final out = <int>[]; var v = tag; while (v > 0) { out.insert(0, v & 0xFF); v >>= 8; } return out; }\n\n")
    f.write("Uint8List _asn1EncodeRaw(int tag, Uint8List value) {\n")
    f.write("  final tb = _tagBytes(tag);\n")
    f.write("  final lb = _asn1EncodeLength(value.length);\n")
    f.write("  final out = Uint8List(tb.length + lb.length + value.length);\n")
    f.write("  out.setRange(0, tb.length, tb);\n")
    f.write("  out.setRange(tb.length, tb.length + lb.length, lb);\n")
    f.write("  out.setRange(tb.length + lb.length, out.length, value);\n")
    f.write("  return out;\n")
    f.write("}\n\n")
    f.write("/// Concatenates already-encoded children under [tag].\n")
    f.write("///\n")
    f.write("/// Sized once and filled, rather than folded: growing a new list per\n")
    f.write("/// child copies everything before it, which made encoding a long\n")
    f.write("/// SEQUENCE OF quadratic in its length.\n")
    f.write("Uint8List _asn1EncodeConstructed(int tag, List<Uint8List> children) {\n")
    f.write("  var total = 0;\n")
    f.write("  for (final child in children) {\n")
    f.write("    total += child.length;\n")
    f.write("  }\n")
    f.write("  final body = Uint8List(total);\n")
    f.write("  var offset = 0;\n")
    f.write("  for (final child in children) {\n")
    f.write("    body.setRange(offset, offset + child.length, child);\n")
    f.write("    offset += child.length;\n")
    f.write("  }\n")
    f.write("  return _asn1EncodeRaw(tag, body);\n")
    f.write("}\n\n")
    f.write("/// Clears the constructed bit in a tag's leading identifier octet.\n")
    f.write("int _tagClass(int tag) {\n")
    f.write("  var shift = 0;\n")
    f.write("  var head = tag;\n")
    f.write("  while (head > 0xFF) {\n")
    f.write("    head >>= 8;\n")
    f.write("    shift += 8;\n")
    f.write("  }\n")
    f.write("  return tag & ~(0x20 << shift);\n")
    f.write("}\n\n")
    f.write("/// Index of the first child at or after [from] carrying [tag], else -1.\n")
    f.write("///\n")
    f.write("/// SEQUENCE members are located by tag rather than by position: these\n")
    f.write("/// modules are EXTENSIBILITY IMPLIED, so a newer card may send elements a\n")
    f.write("/// build does not know about, and OPTIONAL members may simply be absent.\n")
    f.write("/// Counting positions instead makes every following member decode into\n")
    f.write("/// the wrong field.\n")
    f.write("///\n")
    f.write("/// The constructed bit is ignored when matching. X.680 requires the\n")
    f.write("/// members of a SEQUENCE to have distinct tag numbers, so this cannot be\n")
    f.write("/// ambiguous, and cards do disagree with the schema about it: EUICCInfo2\n")
    f.write("/// carries extCardResource as a primitive '84' even though its content is\n")
    f.write("/// a constructed structure.\n")
    f.write("int _seekTag(List<Asn1Node> children, int from, int tag) {\n")
    f.write("  final want = _tagClass(tag);\n")
    f.write("  for (var i = from; i < children.length; i++) {\n")
    f.write("    if (_tagClass(children[i].tag) == want) return i;\n")
    f.write("  }\n")
    f.write("  return -1;\n")
    f.write("}\n\n")
    f.write("const String _hexDigits = '0123456789ABCDEF';\n\n")
    f.write("/// Uppercase hex for toString(). A nibble at a time into one\n")
    f.write("/// buffer, rather than a String per byte.\n")
    f.write("String _hex(dynamic bytes) {\n")
    f.write("  if (bytes is! Uint8List) return bytes.toString();\n")
    f.write("  final out = Uint8List(bytes.length * 2);\n")
    f.write("  var i = 0;\n")
    f.write("  for (final b in bytes) {\n")
    f.write("    out[i++] = _hexDigits.codeUnitAt((b >> 4) & 0x0F);\n")
    f.write("    out[i++] = _hexDigits.codeUnitAt(b & 0x0F);\n")
    f.write("  }\n")
    f.write("  return String.fromCharCodes(out);\n")
    f.write("}\n\n")


def emit_enum(f, t: TypeDef):
    f.write(f"enum {t.name} {{\n")
    for name, val in sorted(t.enum_values.items(), key=lambda x: x[1]):
        f.write(f"  {name}, // {val}\n")
    f.write("}\n\n")
    f.write(f"extension {t.name}Ext on {t.name} {{\n")
    f.write("  int get value {\n")
    f.write("    switch (this) {\n")
    for name, val in sorted(t.enum_values.items(), key=lambda x: x[1]):
        f.write(f"      case {t.name}.{name}: return {val};\n")
    f.write("    }\n")
    f.write("  }\n")
    f.write(f"  static {t.name}? fromValue(int v) {{\n")
    f.write("    switch (v) {\n")
    for name, val in sorted(t.enum_values.items(), key=lambda x: x[1]):
        f.write(f"      case {val}: return {t.name}.{name};\n")
    f.write("      default: return null;\n")
    f.write("    }\n")
    f.write("  }\n")
    f.write("}\n\n")


def emit_bits_class(f, t: TypeDef):
    f.write(f"class {t.name} {{\n")
    f.write(f"  final int value;\n")
    f.write(f"  const {t.name}(this.value);\n\n")
    for name, bit in sorted(t.enum_values.items(), key=lambda x: x[1]):
        f.write(f"  static const int {name} = 1 << {bit};\n")
    f.write("\n")
    f.write("  @override\n")
    f.write("  String toString() {\n")
    f.write("    final parts = <String>[];\n")
    for name, bit in sorted(t.enum_values.items(), key=lambda x: x[1]):
        f.write(f"    if ((value & {name}) != 0) parts.add('{t.name}.{name}');\n")
    f.write("    if (parts.isEmpty && value != 0) return '0x${value.toRadixString(16).toUpperCase()}';\n")
    f.write("    return parts.join(' | ');\n")
    f.write("  }\n")
    f.write("}\n\n")


def emit_typedef(f, t: TypeDef):
    if t.name in enums_in_scope or t.name in bits_in_scope:
        return
    dart = dart_type_name(t, resolve_typedef=True)
    if dart.startswith("List<") and t.name in dart:
        dart = "List<dynamic>"
    if dart == t.name:
        return
    f.write(f"typedef {t.name} = {dart};\n\n")


def get_decode_expr(type_name: str, node_var: str, type_map: Dict[str, TypeDef], depth: int = 0) -> str:
    # Recursively resolve typedefs
    curr_type = type_name
    while curr_type in type_map and type_map[curr_type].kind == "typedef" and type_map[curr_type].base_type:
        bt = type_map[curr_type].base_type
        # If it's a List<T>, it's a seq_of, we should stop and use seq_of logic
        if bt.startswith("List<"): 
            break
        curr_type = bt

    t = type_map.get(curr_type)
    if not t:
        if type_name == "String": return f"String.fromCharCodes({node_var}.value)"
        if type_name == "int": return f"_asn1DecodeInt({node_var}.value)"
        if type_name == "Uint8List": return f"{node_var}.value"
        if type_name == "bool": return f"({node_var}.value.isNotEmpty && {node_var}.value.first != 0)"
        return f"{type_name}.decode({node_var})"

    if t.kind == "seq_of":
        inner = t.element_type or "dynamic"
        if inner == t.name:
            inner = "dynamic"
        lvar = f"sn{depth}"
        inner_expr = get_decode_expr(inner, lvar, type_map, depth + 1)
        return f"{node_var}.children.map(({lvar}) => {inner_expr}).toList()"
    
    if t.kind in ("string", "time_utc", "time_gen", "oid"):
        return f"String.fromCharCodes({node_var}.value)"
    if t.kind == "octets":
        return f"{node_var}.value"
    if t.kind == "int":
        return f"_asn1DecodeInt({node_var}.value)"
    if t.kind == "bool":
        return f"({node_var}.value.isNotEmpty && {node_var}.value.first != 0)"
    if t.kind == "bits":
        return f"{t.name}(_asn1DecodeBits({node_var}.value))" if t.name in bits_in_scope else f"_asn1DecodeBits({node_var}.value)"
    
    return f"{type_name}.decode({node_var})" # Fallback for known types not handled above


def decodes_from_inner_node(ref: Optional[TypeDef]) -> bool:
    """Whether an explicitly tagged field must unwrap before handing over.

    A generated class for an untagged CHOICE switches on the alternative's own
    tag, so it needs the node inside the explicit wrapper. Every other class --
    a SEQUENCE, or a CHOICE that carries a tag of its own -- consumes the
    wrapper itself by iterating its children, and must be given the whole node.
    """
    if ref is None or ref.kind != "choice":
        return False
    return tag_int(ref.tag_num, ref.tag_class, True, ref.is_explicit) is None


def emit_class(f, t: TypeDef, type_map: Dict[str, TypeDef]):
    tag_value = tag_int(t.tag_num, t.tag_class, True, t.is_explicit)
    tag_literal = f"0x{tag_value:X}" if tag_value is not None else "0x30"

    def get_primitive(t: Optional[TypeDef], type_name: Optional[str] = None) -> str:
        if not t:
            if type_name in ("String", "int", "bool", "Uint8List"): return type_name
            return "Uint8List"
        if t.kind == "typedef" and t.base_type:
            return {
                "int": "int",
                "time_utc": "String",
                "time_gen": "String",
                "string": "String",
                "octets": "Uint8List",
                "bool": "bool",
                "oid": "String",
                "bits": "int",
            }.get(t.base_type, "Uint8List")
        if t.kind == "octets": return "Uint8List"
        if t.kind in ("string", "time_utc", "time_gen"): return "String"
        if t.kind == "int": return "int"
        if t.kind == "bool": return "bool"
        if t.kind == "oid": return "String"
        if t.kind == "bits": return "int"
        return t.name

    # field declarations / ctor
    for field in t.fields:
        ref_def = type_map.get(field.type_name)
        if field.is_list and ref_def and ref_def.kind == "seq_of":
            dart_type = ref_def.name
        else:
            dart_type = dart_type_name(ref_def) if ref_def else field.type_name
            if field.is_list:
                dart_type = f"List<{dart_type}>"
        f.write(f"  final {dart_type}? {field.name};\n")
    
    # Add asn1 field to store original node
    f.write("  final Asn1Node? asn1; // Original ASN.1 node for byte-perfect re-encoding\n")
    
    if t.fields:
        f.write(f"\n  const {t.name}._({{\n")
        for field in t.fields:
            f.write(f"    this.{field.name},\n")
        f.write("    this.asn1,\n")
        f.write("  });\n\n")
        f.write(f"  const {t.name}({{\n")
        for field in t.fields:
            ref_def = type_map.get(field.type_name)
            if field.is_list and ref_def and ref_def.kind == "seq_of":
                dart_type = ref_def.name
            else:
                dart_type = dart_type_name(ref_def) if ref_def else field.type_name
                if field.is_list:
                    dart_type = f"List<{dart_type}>"
            f.write(f"    {dart_type}? {field.name},\n")
        f.write("  }) : this._(\n")
        for field in t.fields:
            f.write(f"    {field.name}: {field.name},\n")
        f.write("    asn1: null,\n")
        f.write("  );\n\n")
    else:
        f.write(f"\n  const {t.name}._({{this.asn1}});\n")
        f.write(f"  const {t.name}() : this._(asn1: null);\n\n")

    # encode
    f.write("  Uint8List encode({int? tag}) {\n")
    f.write("    // If we have the original ASN.1 node, re-encode it for byte-perfect output\n")
    f.write("    if (asn1 != null) {\n")
    f.write("      return asn1!.encodedBytes;\n")
    f.write("    }\n")
    f.write("    final children = <Uint8List>[];\n")
    f.write(f"    final defaultTag = {tag_literal};\n")
    def encode_tag_literal(ref: Optional[TypeDef], constructed: bool, default_tag: str) -> str:
        if ref and ref.tag_num is not None:
            val = tag_int(ref.tag_num, ref.tag_class, constructed, ref.is_explicit)
            if val is not None:
                return f"0x{val:X}"
        return default_tag

    for field in t.fields:
        ref_def = type_map.get(field.type_name)
        if field.is_list and ref_def and ref_def.kind == "seq_of":
            field_dart = ref_def.name
        else:
            field_dart = dart_type_name(ref_def) if ref_def else field.type_name
            if field.is_list:
                field_dart = f"List<{field_dart}>"
        
        field_primitive = get_primitive(ref_def, field_dart)
        constructed = field.is_list or (ref_def and ref_def.kind in ("seq", "choice", "seq_of")) or field.is_explicit
        field_tag = tag_int(field.tag_num, field.tag_class, constructed, field.is_explicit)
        
        # If no explicit tag on field, try to get it from the type or use natural tag
        if field_tag is None:
            if ref_def and ref_def.tag_num is not None:
                field_tag = tag_int(ref_def.tag_num, ref_def.tag_class, True, ref_def.is_explicit)
            
            if field_tag is None:
                # Natural tags
                if field.type_name in enums_in_scope or field_primitive == "int": field_tag = 0x02
                elif field_primitive == "String":
                    fk = field.kind
                    if fk == "time_utc": field_tag = 0x17
                    elif fk == "time_gen": field_tag = 0x18
                    else:
                        type_info = type_map.get(field.type_name)
                        if type_info and type_info.kind == "time_utc": field_tag = 0x17
                        elif type_info and type_info.kind == "time_gen": field_tag = 0x18
                        else: field_tag = 0x0C
                elif field_primitive == "Uint8List": field_tag = 0x04
                elif field_primitive == "bool": field_tag = 0x01
                elif (ref_def and ref_def.kind in ("seq", "seq_of")) or field.is_list: field_tag = 0x30
        
        if field_tag is None:
            if not (ref_def and ref_def.kind == "choice"):
                continue
        
        tag_lit = f"0x{field_tag:X}" if field_tag is not None else "null"

        def write_encode_value(var_name: str, dart_type: str, ref: Optional[TypeDef]):
            if field.type_name in enums_in_scope:
                tag_lit = encode_tag_literal(ref, False, "0x02")
                f.write(f"      items.add(_asn1EncodeRaw({tag_lit}, _asn1EncodeInt({var_name}.value)));\n")
            elif field.type_name in bits_in_scope:
                tag_lit = encode_tag_literal(ref, False, "0x03")
                f.write(f"      items.add(_asn1EncodeRaw({tag_lit}, _asn1EncodeBits({var_name}.value)));\n")
            elif dart_type == "String" or (ref and ref.kind == "typedef" and ref.base_type in ("string", "oid")):
                tag_lit = encode_tag_literal(ref, False, "0x0C")
                f.write(f"      items.add(_asn1EncodeRaw({tag_lit}, Uint8List.fromList({var_name}.codeUnits)));\n")
            elif dart_type == "Uint8List" or (ref and ref.kind == "typedef" and ref.base_type == "octets"):
                tag_lit = encode_tag_literal(ref, False, "0x04")
                f.write(f"      items.add(_asn1EncodeRaw({tag_lit}, {var_name}));\n")
            elif dart_type == "int" or (ref and ref.kind == "typedef" and ref.base_type in ("int", "bits")):
                is_bits = (dart_type == "int" and ref and ref.kind == "bits") or (ref and ref.base_type == "bits")
                tag_lit = encode_tag_literal(ref, False, "0x03" if is_bits else "0x02")
                if is_bits:
                    f.write(f"      items.add(_asn1EncodeRaw({tag_lit}, _asn1EncodeBits({var_name})));\n")
                else:
                    f.write(f"      items.add(_asn1EncodeRaw({tag_lit}, _asn1EncodeInt({var_name})));\n")
            elif dart_type == "bool" or (ref and ref.kind == "typedef" and ref.base_type == "bool"):
                tag_lit = encode_tag_literal(ref, False, "0x01")
                f.write(f"      items.add(_asn1EncodeRaw({tag_lit}, Uint8List.fromList([{var_name} ? 0xFF : 0x00])));\n")
            elif ref and (ref.kind in ("time_utc", "time_gen") or (ref.kind == "typedef" and ref.base_type in ("time_utc", "time_gen"))):
                tag_num = 0x17 if (ref.kind == "time_utc" or ref.base_type == "time_utc") else 0x18
                tag_lit = encode_tag_literal(ref, False, f"0x{tag_num:X}")
                f.write(f"      items.add(_asn1EncodeRaw({tag_lit}, Uint8List.fromList({var_name}.codeUnits)));\n")
            else:
                tag_lit = encode_tag_literal(ref, ref.kind in ("seq", "choice", "seq_of") if ref else True, "0x30")
                if field.is_explicit:
                    f.write(f"      items.add(_asn1EncodeConstructed({tag_lit}, [({var_name} as dynamic).encode()]));\n")
                else:
                    f.write(f"      items.add(({var_name} as dynamic).encode(tag: {tag_lit}));\n")

        if field.is_list:
            if ref_def and ref_def.kind == "seq_of":
                elem_type_name = ref_def.element_type or "dynamic"
                elem_def = type_map.get(elem_type_name)
            else:
                elem_type_name = field.type_name
                elem_def = ref_def
            elem_dart = dart_type_name(elem_def) if elem_def else elem_type_name
            f.write(f"    if ({field.name} != null) {{\n")
            f.write("      final items = <Uint8List>[];\n")
            f.write(f"      for (final v in {field.name}!) {{\n")
            write_encode_value("v", elem_dart, elem_def)
            f.write("      }\n")
            f.write(f"      children.add(_asn1EncodeConstructed(0x{field_tag:X}, items));\n")
            f.write("    }\n")
            continue

        if field.type_name in enums_in_scope:
            f.write(f"    if ({field.name} != null) children.add(_asn1EncodeRaw(0x{field_tag:X}, _asn1EncodeInt({field.name}!.value)));\n")
        elif field.type_name in bits_in_scope:
            f.write(f"    if ({field.name} != null) children.add(_asn1EncodeRaw(0x{field_tag:X}, _asn1EncodeBits({field.name}!.value)));\n")
        elif field_primitive == "int":
            if ref_def and (ref_def.kind == "bits" or ref_def.base_type == "bits"):
                f.write(f"    if ({field.name} != null) children.add(_asn1EncodeRaw(0x{field_tag:X}, _asn1EncodeBits({field.name}!)));\n")
            else:
                f.write(f"    if ({field.name} != null) children.add(_asn1EncodeRaw(0x{field_tag:X}, _asn1EncodeInt({field.name}!)));\n")
        elif field_primitive == "String":
            f.write(f"    if ({field.name} != null) children.add(_asn1EncodeRaw(0x{field_tag:X}, Uint8List.fromList({field.name}!.codeUnits)));\n")
        elif field_primitive == "Uint8List":
            f.write(f"    if ({field.name} != null) children.add(_asn1EncodeRaw(0x{field_tag:X}, {field.name}!));\n")
        elif field_primitive == "bool":
            f.write(f"    if ({field.name} != null) children.add(_asn1EncodeRaw(0x{field_tag:X}, Uint8List.fromList([{field.name}! ? 0xFF : 0x00])));\n")
        else:
            if field_tag is not None:
                if field.is_explicit:
                    f.write(f"    if ({field.name} != null) children.add(_asn1EncodeConstructed({tag_lit}, [({field.name} as dynamic).encode()]));\n")
                else:
                    f.write(f"    if ({field.name} != null) children.add(({field.name} as dynamic).encode(tag: {tag_lit}));\n")
            else:
                f.write(f"    if ({field.name} != null) children.add(({field.name} as dynamic).encode());\n")
    if t.kind == "choice" and (t.is_inline or tag_literal == "0x30"):
        f.write("    if (tag != null) {\n")
        f.write("      return _asn1EncodeConstructed(tag, children);\n")
        f.write("    }\n")
        f.write("    return children.isNotEmpty ? children.first : Uint8List(0);\n")
    else:
        f.write(f"    return _asn1EncodeConstructed(tag ?? defaultTag, children);\n")
    f.write("  }\n\n")

    # factory fromAsn1
    f.write(f"  factory {t.name}.fromAsn1(Asn1Node node, {{int? tag}}) {{\n")
    f.write(f"    final defaultTag = {tag_literal};\n")
    if tag_value is not None:
        f.write(f"    if (node.tag != (tag ?? defaultTag)) {{ /* tag mismatch */ }}\n")
    for field in t.fields:
        ref_def = type_map.get(field.type_name)
        if field.is_list and ref_def and ref_def.kind == "seq_of":
            dart_type = ref_def.name
        else:
            dart_type = dart_type_name(ref_def) if ref_def else field.type_name
            if field.is_list:
                dart_type = f"List<{dart_type}>"
        f.write(f"    {dart_type}? {field.name};\n")
    
    # For CHOICE types, behavior depends on whether it has an explicit tag
    # - If CHOICE has explicit tag: iterate through children (choice is wrapped)
    # - If CHOICE is inline (no tag): check node.tag directly (node IS the choice)
    if t.kind == "choice" and tag_value is None:
        # Inline CHOICE: check node's tag directly
        f.write("    // CHOICE: check node's tag directly\n")
        f.write("    switch (node!.tag) {\n")
        for field in t.fields:
            ref_def = type_map.get(field.type_name)
            if field.is_list and ref_def and ref_def.kind == "seq_of":
                field_dart = ref_def.name
            else:
                field_dart = dart_type_name(ref_def) if ref_def else field.type_name
                if field.is_list:
                    field_dart = f"List<{field_dart}>"
            
            field_primitive = get_primitive(ref_def, field_dart)
            constructed = field.is_list or (ref_def and ref_def.kind in ("seq", "choice", "seq_of")) or field.is_explicit
            field_tag = tag_int(field.tag_num, field.tag_class, constructed, field.is_explicit)
            
            if field_tag is None:
                # Infer universal tags if missing
                fk = field.kind
                if not fk:
                    type_info = type_map.get(field.type_name)
                    if type_info: fk = type_info.kind
                
                if field_primitive == "String":
                    if fk == "time_utc": field_tag = 0x17
                    elif fk == "time_gen": field_tag = 0x18
                    else: field_tag = 0x0C
                elif field_primitive == "int": field_tag = 0x02
                elif field_primitive == "Uint8List": field_tag = 0x04
                elif field_primitive == "bool": field_tag = 0x01
                elif (ref_def and ref_def.kind in ("seq", "seq_of")) or field.is_list: field_tag = 0x30
            
            if field_tag is None:
                continue
            
            f.write(f"      case 0x{field_tag:X}:\n")
            
            # Handle list fields
            if field.is_list:
                if ref_def and ref_def.kind == "seq_of":
                    elem_type_name = ref_def.element_type or "dynamic"
                    elem_def = type_map.get(elem_type_name)
                else:
                    elem_type_name = field.type_name
                    elem_def = ref_def
                elem_dart = dart_type_name(elem_def) if elem_def else elem_type_name
                elem_primitive = get_primitive(elem_def, elem_dart)
                f.write(f"        final items = <{elem_dart}>[];\n")
                f.write("        for (final n in node.children) {\n")
                if elem_type_name in enums_in_scope:
                    f.write(f"          final v = {elem_type_name}Ext.fromValue(_asn1DecodeInt(n.value));\n")
                    f.write("          if (v != null) items.add(v);\n")
                elif elem_primitive == "String":
                    f.write("          items.add(String.fromCharCodes(n.value));\n")
                elif elem_primitive == "Uint8List":
                    f.write("          items.add(n.value);\n")
                elif elem_primitive == "int":
                    f.write("          items.add(_asn1DecodeInt(n.value));\n")
                elif elem_primitive == "bool":
                    f.write("          items.add(n.value.isNotEmpty && n.value.first != 0);\n")
                else:
                    decode_expr = get_decode_expr(elem_type_name, "n", type_map)
                    f.write(f"        items.add({decode_expr});\n")
                f.write("        }\n")
                f.write(f"        {field.name} = items;\n")
            elif field.type_name in enums_in_scope:
                f.write(f"        {field.name} = {field.type_name}Ext.fromValue(_asn1DecodeInt(node.value));\n")
            elif field_primitive == "String":
                f.write(f"        {field.name} = String.fromCharCodes(node.value);\n")
            elif field_primitive == "Uint8List":
                f.write(f"        {field.name} = node.value;\n")
            elif field_primitive == "int":
                f.write(f"        {field.name} = _asn1DecodeInt(node.value);\n")
            elif field_primitive == "bool":
                f.write(f"        {field.name} = node.value.isNotEmpty && node.value.first != 0;\n")
            else:
                if field.is_explicit and decodes_from_inner_node(ref_def):
                    f.write(f"        {field.name} = {field.type_name}.decode(node.children.first);\n")
                elif field.is_explicit:
                    f.write(f"        {field.name} = {field.type_name}.decode(node);\n")
                else:
                    f.write(f"        {field.name} = {field.type_name}.decode(node, tag: 0x{field_tag:X});\n")
            f.write("        break;\n")
        f.write("    }\n")
    else:
        # SEQUENCE or tagged CHOICE
        if t.kind == "seq":
            f.write("    int childIdx = 0;\n")
            if any(tag_int(fd.tag_num, fd.tag_class, True, fd.is_explicit) is not None
                   or tag_int(fd.tag_num, fd.tag_class, False, fd.is_explicit) is not None
                   for fd in t.fields):
                f.write("    int found;\n")
            for field in t.fields:
                ref_def = type_map.get(field.type_name)
                if field.is_list and ref_def and ref_def.kind == "seq_of":
                    field_dart = ref_def.name
                else:
                    field_dart = dart_type_name(ref_def) if ref_def else field.type_name
                    if field.is_list:
                        field_dart = f"List<{field_dart}>"
                
                field_primitive = get_primitive(ref_def, field_dart)
                constructed = field.is_list or (ref_def and ref_def.kind in ("seq", "choice", "seq_of")) or field.is_explicit
                field_tag = tag_int(field.tag_num, field.tag_class, constructed, field.is_explicit)
                
                if field_tag is not None:
                    f.write(f"    found = _seekTag(node!.children, childIdx, 0x{field_tag:X});\n")
                    f.write("    if (found >= 0) {\n")
                    f.write("      final child = node!.children[found];\n")
                else:
                    # No determinate tag (an untagged CHOICE, or an open type):
                    # position is all there is to go on.
                    f.write("    if (childIdx < node!.children.length) {\n")
                    f.write("      final child = node!.children[childIdx];\n")
                
                if field.is_list:
                    if ref_def and ref_def.kind == "seq_of":
                        elem_type_name = ref_def.element_type or "dynamic"
                        elem_def = type_map.get(elem_type_name)
                    else:
                        elem_type_name = field.type_name
                        elem_def = ref_def
                    elem_dart = dart_type_name(elem_def) if elem_def else elem_type_name
                    elem_primitive = get_primitive(elem_def, elem_dart)
                    f.write(f"      final items = <{elem_dart}>[];\n")
                    f.write("      for (final n in child.children) {\n")
                    if elem_type_name in enums_in_scope:
                        f.write(f"            final v = {elem_type_name}Ext.fromValue(_asn1DecodeInt(n.value));\n")
                        f.write("            if (v != null) items.add(v);\n")
                    elif elem_type_name in bits_in_scope:
                        f.write(f"            items.add({elem_type_name}(_asn1DecodeBits(n.value)));\n")
                    elif elem_primitive == "String":
                        f.write("        items.add(String.fromCharCodes(n.value));\n")
                    elif elem_primitive == "Uint8List":
                        f.write("        items.add(n.value);\n")
                    elif elem_primitive == "int":
                        f.write("        items.add(_asn1DecodeInt(n.value));\n")
                    elif elem_primitive == "bool":
                        f.write("        items.add(n.value.isNotEmpty && n.value.first != 0);\n")
                    else:
                        f.write(f"        items.add({elem_type_name}.decode(n));\n")
                    f.write("      }\n")
                    f.write(f"      {field.name} = items;\n")
                elif field.type_name in enums_in_scope:
                    f.write(f"      {field.name} = {field.type_name}Ext.fromValue(_asn1DecodeInt(child.value));\n")
                elif field.type_name in bits_in_scope:
                    f.write(f"      {field.name} = {field.type_name}(_asn1DecodeBits(child.value));\n")
                elif field_primitive == "String":
                    f.write(f"      {field.name} = String.fromCharCodes(child.value);\n")
                elif field_primitive == "Uint8List":
                    f.write(f"      {field.name} = child.value;\n")
                elif field_primitive == "int":
                    if ref_def and ref_def.kind == "bits":
                        f.write(f"      {field.name} = _asn1DecodeBits(child.value);\n")
                    else:
                        f.write(f"      {field.name} = _asn1DecodeInt(child.value);\n")
                elif field_primitive == "bool":
                    f.write(f"      {field.name} = child.value.isNotEmpty && child.value.first != 0;\n")
                else:
                    if field.is_explicit and decodes_from_inner_node(ref_def):
                        f.write(f"      {field.name} = {field.type_name}.decode(child.children.first);\n")
                    elif field.is_explicit:
                        f.write(f"      {field.name} = {field.type_name}.decode(child, tag: child.tag);\n")
                    else:
                        f.write(f"      {field.name} = {field.type_name}.decode(child, tag: child.tag);\n")
                
                if field_tag is not None:
                    f.write("      childIdx = found + 1;\n")
                else:
                    f.write("      childIdx++;\n")
                f.write("    }\n")
        else:
            # Tagged CHOICE: iterate through children (usually only one)
            f.write("    for (final child in node!.children) {\n")
            f.write("      switch (child.tag) {\n")
            for field in t.fields:
                ref_def = type_map.get(field.type_name)
                if field.is_list and ref_def and ref_def.kind == "seq_of":
                    field_dart = ref_def.name
                else:
                    field_dart = dart_type_name(ref_def) if ref_def else field.type_name
                    if field.is_list:
                        field_dart = f"List<{field_dart}>"
                
                field_primitive = get_primitive(ref_def, field_dart)
                constructed = field.is_list or (ref_def and ref_def.kind in ("seq", "choice", "seq_of")) or field.is_explicit
                field_tag = tag_int(field.tag_num, field.tag_class, constructed, field.is_explicit)
                if field_tag is None:
                    continue
                f.write(f"        case 0x{field_tag:X}:\n")
                if field.is_list:
                    if ref_def and ref_def.kind == "seq_of":
                        elem_type_name = ref_def.element_type or "dynamic"
                        elem_def = type_map.get(elem_type_name)
                    else:
                        elem_type_name = field.type_name
                        elem_def = ref_def
                    elem_dart = dart_type_name(elem_def) if elem_def else elem_type_name
                    elem_primitive = get_primitive(elem_def, elem_dart)
                    f.write(f"          final items = <{elem_dart}>[];\n")
                    f.write("          for (final n in child.children) {\n")
                    if field.type_name in enums_in_scope:
                        f.write(f"            final v = {field.type_name}Ext.fromValue(_asn1DecodeInt(n.value));\n")
                        f.write("            if (v != null) items.add(v);\n")
                    elif elem_primitive == "String":
                        f.write("            items.add(String.fromCharCodes(n.value));\n")
                    elif elem_primitive == "Uint8List":
                        f.write("            items.add(n.value);\n")
                    elif elem_primitive == "int":
                        f.write("            items.add(_asn1DecodeInt(n.value));\n")
                    elif elem_primitive == "bool":
                        f.write("            items.add(n.value.isNotEmpty && n.value.first != 0);\n")
                    else:
                        f.write(f"            items.add({elem_type_name}.decode(n));\n")
                    f.write("          }\n")
                    f.write(f"          {field.name} = items;\n")
                    f.write("          break;\n")
                    continue

                if field.type_name in enums_in_scope:
                    f.write(f"          {field.name} = {field.type_name}Ext.fromValue(_asn1DecodeInt(child.value));\n")
                elif field.type_name in bits_in_scope:
                    f.write(f"          {field.name} = {field.type_name}(_asn1DecodeBits(child.value));\n")
                elif field_primitive == "String":
                    f.write(f"          {field.name} = String.fromCharCodes(child.value);\n")
                elif field_primitive == "Uint8List":
                    f.write(f"          {field.name} = child.value;\n")
                elif field_primitive == "int":
                    if ref_def and ref_def.kind == "bits":
                        f.write(f"          {field.name} = _asn1DecodeBits(child.value);\n")
                    else:
                        f.write(f"          {field.name} = _asn1DecodeInt(child.value);\n")
                elif field_primitive == "bool":
                    f.write(f"          {field.name} = child.value.isNotEmpty && child.value.first != 0;\n")
                else:
                    if field.is_explicit and decodes_from_inner_node(ref_def):
                        f.write(f"          {field.name} = {field.type_name}.decode(child.children.first);\n")
                    elif field.is_explicit:
                        f.write(f"          {field.name} = {field.type_name}.decode(child, tag: 0x{field_tag:X});\n")
                    else:
                        f.write(f"          {field.name} = {field.type_name}.decode(child, tag: 0x{field_tag:X});\n")
                f.write("          break;\n")
            f.write("      }\n")
            f.write("    }\n")
    
    f.write(f"    return {t.name}._(\n")
    for field in t.fields:
        f.write(f"      {field.name}: {field.name},\n")
    f.write("      asn1: node, // Store original node\n")
    f.write("    );\n")
    f.write("  }\n\n")

    f.write(f"  static {t.name} decode(dynamic data, {{int? tag}}) {{\n")
    f.write(f"    if (data is Asn1Node) return {t.name}.fromAsn1(data, tag: tag);\n")
    f.write(f"    if (data is Uint8List) {{\n")
    f.write("      final node = SimpleAsn1Reader(data).readNext();\n")
    f.write(f"      if (node != null) return {t.name}.fromAsn1(node, tag: tag);\n")
    f.write("    }\n")
    f.write(f"    return {t.name}();\n")
    f.write("  }\n\n")
    f.write("  @override\n")
    f.write("  String toString() {\n")
    
    # Pattern 1: Multi-choice string Forwarder (like Time or CHOICE of strings)
    # Check if all fields are string-like kinds
    def is_string_like(f: FieldDef) -> bool:
        if f.kind in ("string", "time_utc", "time_gen", "oid"): return True
        ref = type_map.get(f.type_name)
        return ref and ref.kind in ("string", "time_utc", "time_gen", "oid")

    if t.kind == "choice" and all(is_string_like(field) for field in t.fields):
        for field in t.fields:
            if field.name == "asn1": continue
            f.write(f"    if ({field.name} != null) return {field.name}!;\n")
        f.write(f"    return '{t.name}()';\n")
        
    # Pattern 2: AttributeTypeAndValue-like (type OID + value ANY)
    elif len(t.fields) == 2 and any(f.name == "type" for f in t.fields) and any(f.name == "value" for f in t.fields):
        value_field = next(f for f in t.fields if f.name == "value")
        val_primitive = get_primitive(type_map.get(value_field.type_name), value_field.type_name)
        
        f.write("    String t = type ?? 'unknown';\n")
        f.write("    if (t == \"\\x55\\x04\\x03\") t = \"CN\";\n")
        f.write("    else if (t == \"\\x55\\x04\\x06\") t = \"C\";\n")
        f.write("    else if (t == \"\\x55\\x04\\x0A\") t = \"O\";\n")
        f.write("    else if (t == \"\\x55\\x04\\x0B\") t = \"OU\";\n")
        f.write("    else if (t == \"\\x55\\x04\\x07\") t = \"L\";\n")
        f.write("    else if (t == \"\\x55\\x04\\x08\") t = \"ST\";\n")
        
        f.write("    String v = 'null';\n")
        f.write("    final val = value;\n")
        f.write("    if (val != null) {\n")
        if val_primitive == "String":
            f.write("      v = val;\n")
        else:
            f.write("      try {\n")
            f.write("        v = utf8.decode(val);\n")
            f.write("      } catch (_) {\n")
            f.write("        v = val.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');\n")
            f.write("      }\n")
        f.write("    }\n")
        f.write("    return '$t=$v';\n")

    # Pattern 3: Nested List Forwarder (like Name)
    elif t.kind == "choice" and len(t.fields) == 1 and t.fields[0].is_list:
        fname = t.fields[0].name
        f.write(f"    if ({fname} == null) return '{t.name}()';\n")
        f.write(f"    return {fname}!.map((item) {{\n")
        f.write("      if (item is List) {\n")
        f.write("        return item.map((e) => e.toString()).join(\" + \");\n")
        f.write("      }\n")
        f.write("      return item.toString();\n")
        f.write("    }).join(\", \");\n")
    
    # Default: Verbose Object Dump
    else:
        f.write("    final buffer = StringBuffer();\n")
        f.write(f"    buffer.writeln('{t.name}(');\n")
        for field in t.fields:
            if field.name == "asn1": continue
            f.write("    final " + field.name + "Val = " + field.name + ";\n")
            f.write("    if (" + field.name + "Val != null) {\n")
            f.write("      final val = " + field.name + "Val;\n")
            if field.name == 'iconType':
                f.write("      buffer.writeln('  iconType: $val,');\n")
            elif field.name == 'icon':
                if field.type_name == 'Uint8List':
                    f.write("      buffer.writeln('  icon: ${val.length} bytes,');\n")
                else:
                    # Fallback for non-binary icons
                    f.write("      buffer.writeln('  icon: ${val.toString().replaceAll(\"\\n\", \"\\n  \")},');\n")
            else:
                f.write("      if (val is Uint8List) {\n")
                f.write("        buffer.writeln('  " + field.name + ": ${_hex(val)},');\n")
                if field.is_list:
                    f.write("      } else if (val is List) {\n")
                    f.write("        buffer.writeln('  " + field.name + ": [${val.map((e) => e.toString().replaceAll(\"\\n\", \"\\n  \")).join(\", \")}],');\n")
                f.write("      } else {\n")
                f.write("        buffer.writeln('  " + field.name + ": ${val.toString().replaceAll(\"\\n\", \"\\n  \")},');\n")
                f.write("      }\n")
            f.write("    }\n")
        f.write("    buffer.write(')');\n")
        f.write("    return buffer.toString();\n")
    f.write("  }\n\n")


def prune_types(types: List[TypeDef], roots: List[str]) -> List[TypeDef]:
    type_map = {t.name: t for t in types}
    needed = set(roots)
    queue = list(roots)
    missing_refs: set[str] = set()
    while queue:
        name = queue.pop(0)
        t = type_map.get(name)
        if not t:
            continue
        if t.kind in ("seq", "choice"):
            for field in t.fields:
                if field.type_name in basic_types or field.type_name in enums_in_scope:
                    continue
                if field.type_name in type_map:
                    if field.type_name not in needed:
                        needed.add(field.type_name)
                        queue.append(field.type_name)
                else:
                    missing_refs.add(field.type_name)
        elif t.kind == "seq_of" and t.element_type and t.element_type not in basic_types:
            if t.element_type in type_map:
                if t.element_type not in needed:
                    needed.add(t.element_type)
                    queue.append(t.element_type)
            else:
                missing_refs.add(t.element_type)
    # Include enums referenced
    for name in list(needed):
        t = type_map.get(name)
        if t and t.kind == "seq":
            for field in t.fields:
                if field.type_name in type_map and type_map[field.type_name].enum_values:
                    needed.add(field.type_name)
    needed.update(missing_refs)
    pruned = [type_map[n] for n in needed if n in type_map]
    # Add fallback typedefs for missing external references
    # Placeholder names the model itself can produce for an unresolved type.
    fallback = {
        "typedef": "Uint8List",
        "dynamic": "Uint8List",
    }
    basic_types.update(fallback.keys())
    for name, dart in fallback.items():
        if name in needed:
            if name in type_map:
                type_map[name].kind = "typedef"
                type_map[name].base_type = dart
            else:
                pruned.append(TypeDef(name=name, kind="typedef", base_type=dart))
    for name in sorted(missing_refs):
        if name not in fallback:
            pruned.append(TypeDef(name=name, kind="typedef", base_type="Uint8List"))
    for t in pruned:
        if t.kind == "seq_of" and not t.element_type:
            t.element_type = "Uint8List"
    deduped: Dict[str, TypeDef] = {}
    def score(t: TypeDef) -> Tuple[int, int, int]:
        return (1 if t.fields else 0, 1 if t.element_type else 0, 1 if t.base_type else 0)
    for t in pruned:
        existing = deduped.get(t.name)
        if existing is None or score(t) > score(existing):
            deduped[t.name] = t
    return list(deduped.values())


def fill_missing_field_tags(types: List[TypeDef]):
    type_map = {t.name: t for t in types}
    for t in types:
        for f in t.fields:
            if f.tag_num is None:
                # Check basic types first
                if f.type_name == "int":
                    f.tag_num = 2
                    f.tag_class = None
                elif f.type_name == "bool":
                    f.tag_num = 1
                    f.tag_class = None
                elif f.type_name == "String":
                    if f.kind == "time_utc": f.tag_num = 23
                    elif f.kind == "time_gen": f.tag_num = 24
                    else: f.tag_num = 12
                    f.tag_class = None
                elif f.type_name == "Uint8List":
                    f.tag_num = 4
                    f.tag_class = None
                else:
                    ref = type_map.get(f.type_name)
                    if ref:
                        # If the field references a type with an explicit tag, use it
                        if ref.tag_num is not None:
                            f.tag_num = ref.tag_num
                            f.tag_class = ref.tag_class
                        # Otherwise, infer the natural tag from the referenced type's kind
                        else:
                            # Infer natural tag based on the referenced type's kind
                            kind = ref.kind
                            if kind == "typedef" and ref.base_type:
                                kind = ref.base_type

                            if kind == "seq":
                                f.tag_num = 16  # SEQUENCE tag number (encoded as 0x30 with constructed bit)
                                f.tag_class = None  # UNIVERSAL class (default)
                            elif kind == "choice":
                                pass
                            elif kind == "int":
                                f.tag_num = 2
                                f.tag_class = None
                            elif kind == "octets":
                                f.tag_num = 4
                                f.tag_class = None
                            elif kind == "string":
                                f.tag_num = 12
                                f.tag_class = None
                            elif kind == "bool":
                                f.tag_num = 1
                                f.tag_class = None


def extend_basic_types(types: List[TypeDef]):
    primitive_targets = {"int", "String", "Uint8List", "bool"}
    for t in types:
        dt = dart_type_name(t)
        if dt in primitive_targets and t.kind not in ("seq", "choice"):
            basic_types.add(t.name)


def generate_dart(types: List[TypeDef], output_file: str):
    # maintain enums set for later reference
    reserved = {"typedef", "dynamic"}
    with open(output_file, "w", encoding="utf-8") as f:
        # Populate enums/bits scope before emission
        global enums_in_scope, bits_in_scope
        enums_in_scope = {t.name for t in types if t.enum_values and t.kind == "int"}
        bits_in_scope = {t.name for t in types if t.enum_values and t.kind == "bits"}

        emit_helpers(f)
        for t in types:
            if t.name in enums_in_scope:
                emit_enum(f, t)
            elif t.name in bits_in_scope:
                emit_bits_class(f, t)

        for t in types:
            if t.name in enums_in_scope or t.name in bits_in_scope:
                continue
            if t.kind in ("int", "bool", "string", "octets", "bits", "oid") and not t.enum_values and not t.fields:
                if t.name not in reserved:
                    emit_typedef(f, t)
            elif t.kind == "seq_of":
                if t.name not in reserved:
                    emit_typedef(f, t)
            elif t.kind == "typedef" and t.base_type:
                if t.name not in reserved:
                    emit_typedef(f, t)
        type_map = {t.name: t for t in types}
        for t in types:
            if t.kind in ("seq", "choice"):
                f.write(f"class {t.name} {{\n")
                emit_class(f, t, type_map)
                f.write("}\n\n")

        # No universal decoder is emitted. Dispatching on the outer tag alone
        # cannot work here: many types share one (EUICCInfo2 and
        # GetEuiccInfo2Request are both [34]/'BF22'), and most context tags only
        # ever occur nested inside another structure. Callers know which type
        # they asked for, so they call that type's decode() directly.
