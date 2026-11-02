#!/usr/bin/env python3
"""
Turns the ASN.1 AST from tools/asn1_syntax.py into the TypeDef/FieldDef model
that the Dart emitter in tools/asn1_emit.py consumes.

Inline types are flattened into `Parent_field` / `Parent__item_` names and
value assignments produce typedefs. Those names are the generated Dart's public
API, so they are fixed by compatibility rather than chosen.
"""

from __future__ import annotations

from typing import Dict, List, Optional, Tuple

from asn1_emit import FieldDef, TypeDef
from asn1_syntax import Assignment, Component, Module, TypeNode, parse_file

# Module order decides who wins a name collision across modules. RSPDefinitions
# is last, so its definition of a shared name is the one that survives.
MODULE_ORDER = ["PKIX1Explicit88", "PKIX1Implicit88", "PEDefinitions", "RSPDefinitions"]

# TypeNode.base -> the kind string used by the emitter. NULL and ANY land on
# "octets" because the emitter has no better representation for them.
# ENUMERATED is treated as an INTEGER with named numbers, which is what it is
# on the wire bar the universal tag.
_BASE_KIND = {
    "SEQUENCE": "seq",
    "SET": "seq",
    "CHOICE": "choice",
    "SEQUENCE OF": "seq_of",
    "SET OF": "seq_of",
    "INTEGER": "int",
    "BIT STRING": "bits",
    "OCTET STRING": "octets",
    "OBJECT IDENTIFIER": "oid",
    "STRING": "string",
    "BOOLEAN": "bool",
    "UTCTime": "time_utc",
    "GeneralizedTime": "time_gen",
    "NULL": "octets",
    "ANY": "octets",
    "ENUMERATED": "int",
    "EXTERNAL": "octets",
    "REAL": "octets",
    "TAGGED": "octets",
}

# Bases whose `{ name (n), ... }` list becomes a Dart enum or bit-flag class.
_NAMED_VALUE_BASES = ("INTEGER", "BIT STRING", "ENUMERATED")

# Universal tag numbers for types that are not simply "whatever INTEGER is".
_UNIVERSAL_ENUMERATED = 10

_KIND_TO_DART = {
    "int": "int",
    "bool": "bool",
    "string": "String",
    "time_utc": "String",
    "time_gen": "String",
    "octets": "Uint8List",
    "bits": "int",
}


def clean_name(name: str) -> str:
    return name.lstrip("_").replace("-", "_")


class ModelBuilder:
    def __init__(self, modules: List[Module]):
        self.modules = modules
        # Every type assignment across all modules, later modules winning.
        self.assignments: Dict[str, Assignment] = {}
        for module in modules:
            for assignment in module.assignments:
                if not assignment.is_value:
                    self.assignments[assignment.name] = assignment

        self.types: Dict[str, TypeDef] = {}
        self._order: List[str] = []
        # path -> (TypeDef, TypeNode) for seq/choice types whose fields are
        # built once every type is known.
        self._pending_fields: List[Tuple[TypeDef, TypeNode]] = []

    # -- resolution helpers -------------------------------------------------
    def resolve_ref(self, name: str, seen: Optional[set] = None) -> Optional[TypeNode]:
        """Follow a chain of type references to the first non-REF TypeNode."""
        seen = seen or set()
        node = self.assignments.get(name)
        while node is not None:
            type_node = node.type
            if type_node.base != "REF" or type_node.ref is None:
                return type_node
            if type_node.ref in seen:
                return None
            seen.add(type_node.ref)
            node = self.assignments.get(type_node.ref)
        return None

    def kind_of(self, node: TypeNode) -> str:
        if node.base == "REF" and node.ref:
            target = self.resolve_ref(node.ref)
            return self.kind_of(target) if target is not None else "octets"
        return _BASE_KIND.get(node.base, "octets")

    def is_untagged_choice(self, node: TypeNode) -> bool:
        """True for an untagged CHOICE/open type, which forces explicit tagging."""
        if node.tag is not None:
            return False
        if node.base == "CHOICE":
            return True
        if node.base == "REF" and node.ref:
            target = self.assignments.get(node.ref)
            return self.is_untagged_choice(target.type) if target else False
        return False

    # -- registration -------------------------------------------------------
    def register(self, name: str, type_def: TypeDef) -> TypeDef:
        if name not in self.types:
            self._order.append(name)
        self.types[name] = type_def
        return type_def

    def build(self) -> List[TypeDef]:
        for module in self.modules:
            for assignment in module.assignments:
                self.add_assignment(assignment)

        for type_def, node in self._pending_fields:
            type_def.fields = [self.build_field(c, type_def.name) for c in node.components]

        # `X ::= INTEGER` with no named numbers is a pure alias for int, so it
        # is dropped and references to it fall back to int. A tagged one is
        # kept: its tag is what its encoding depends on (SNMP's
        # `Counter ::= [APPLICATION 1] INTEGER` must still emit '41').
        for name in list(self.types):
            type_def = self.types[name]
            if (type_def.kind == "int" and not type_def.enum_values
                    and type_def.tag_num is None):
                del self.types[name]
        return [self.types[n] for n in self._order if n in self.types]

    def add_assignment(self, assignment: Assignment) -> None:
        name = clean_name(assignment.name)
        node = assignment.type
        kind = self.kind_of(node)
        type_def = TypeDef(name=name, kind="typedef")
        if kind in ("seq", "choice", "seq_of", "int", "bits"):
            type_def.kind = kind
        else:
            type_def.base_type = kind
        self.apply_tag(type_def, node)
        if node.base in _NAMED_VALUE_BASES and node.named_values:
            type_def.enum_values = {clean_name(k): v for k, v in node.named_values.items()}
        self.register(name, type_def)

        if assignment.is_value:
            return
        self.collect(node, name, type_def)

    def collect(self, node: TypeNode, path: str, type_def: Optional[TypeDef]) -> None:
        """Register inline types reachable from `node`, under flattened names."""
        if node.base in ("SEQUENCE", "SET", "CHOICE"):
            if type_def is not None:
                self._pending_fields.append((type_def, node))
            for component in node.components:
                self.collect_component(component, path)
        elif node.base in ("SEQUENCE OF", "SET OF") and node.element is not None:
            item_path = f"{path}__item_"
            element = node.element
            if type_def is not None:
                if element.base == "REF" and element.ref:
                    type_def.element_type = clean_name(element.ref)
                else:
                    type_def.element_type = item_path
            self.collect_inline(element, item_path)

    def collect_component(self, component: Component, parent_path: str) -> None:
        self.collect_inline(component.type, f"{parent_path}_{clean_name(component.name)}")

    def collect_inline(self, node: TypeNode, path: str) -> None:
        """Register `node` as its own type if it needs a name of its own."""
        if node.base == "REF":
            return
        if node.base in ("SEQUENCE", "SET", "CHOICE"):
            kind = "choice" if node.base == "CHOICE" else "seq"
            type_def = TypeDef(name=path, kind=kind, is_inline=True)
            self.apply_tag(type_def, node)
            self.register(path, type_def)
            self.collect(node, path, type_def)
            return
        if node.base in _NAMED_VALUE_BASES and node.named_values:
            kind = "int" if node.base == "INTEGER" else "bits"
            type_def = TypeDef(name=path, kind=kind, is_inline=True)
            self.apply_tag(type_def, node)
            type_def.enum_values = {clean_name(k): v for k, v in node.named_values.items()}
            self.register(path, type_def)
            return
        # Not registered as a type of its own, but may still nest inline types.
        self.collect(node, path, None)

    @staticmethod
    def apply_tag(type_def: TypeDef, node: TypeNode) -> None:
        if node.tag is not None:
            type_def.tag_num = node.tag.number
            type_def.tag_class = node.tag.tag_class
            type_def.is_explicit = node.tag.explicit
        elif node.base == "ENUMERATED":
            # Modelled as an INTEGER, so record the universal tag explicitly;
            # otherwise a field referring to it would inherit INTEGER's '02'.
            type_def.tag_num = _UNIVERSAL_ENUMERATED

    # -- fields -------------------------------------------------------------
    def build_field(self, component: Component, parent_path: str) -> FieldDef:
        node = component.type
        path = f"{parent_path}_{clean_name(component.name)}"
        kind = self.kind_of(node)
        type_name = self.field_type_name(node, path, kind)

        explicit = node.tag.explicit if node.tag is not None else False
        if node.tag is not None and not explicit and self.is_untagged_choice_target(node):
            explicit = True

        return FieldDef(
            name=clean_name(component.name),
            type_name=type_name,
            tag_num=node.tag.number if node.tag is not None else None,
            tag_class=node.tag.tag_class if node.tag is not None else None,
            is_list=kind == "seq_of",
            is_explicit=explicit,
            is_optional=component.optional,
            kind=kind,
        )

    def is_untagged_choice_target(self, node: TypeNode) -> bool:
        if node.base == "CHOICE":
            return True
        if node.base == "REF" and node.ref:
            target = self.assignments.get(node.ref)
            return self.is_untagged_choice(target.type) if target else False
        return False

    def field_type_name(self, node: TypeNode, path: str, kind: str) -> str:
        if node.base == "REF" and node.ref:
            return clean_name(node.ref)

        if kind == "seq_of":
            element = node.element
            if element is not None and element.base == "REF" and element.ref:
                return clean_name(element.ref)
            # An inline element gets its own flattened type; refer to it rather
            # than to the first field of it, which is what the previous
            # front end used to do.
            item = f"{path}__item_"
            return item if item in self.types else "dynamic"

        if kind in ("seq", "choice"):
            return path
        if kind == "int":
            # Inline INTEGERs only become a named type when they carry named
            # numbers; everything else collapses to a plain int.
            return path if path in self.types else "int"
        return _KIND_TO_DART.get(kind, "dynamic")


def build_model(paths: List[str]) -> List[TypeDef]:
    modules = [parse_file(p) for p in paths]
    modules.sort(key=lambda m: MODULE_ORDER.index(m.name) if m.name in MODULE_ORDER else len(MODULE_ORDER))
    return ModelBuilder(modules).build()
