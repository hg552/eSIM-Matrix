#!/usr/bin/env python3
"""
Tests for the ASN.1 -> Dart generator.

Run with:
    python3 tools/test_asn1_gen.py

Pure stdlib (unittest), so it needs no Flutter toolchain. The Dart-side
behaviour of the generated code is covered separately by
test/models/asn1/*_test.dart.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from asn1_dart_gen import build, source_paths  # noqa: E402
from asn1_emit import tag_int  # noqa: E402
from asn1_model import ModelBuilder, clean_name  # noqa: E402
from asn1_syntax import Parser, parse_file, tokenize  # noqa: E402

PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
GENERATED_DART = os.path.join(PROJECT_ROOT, "lib", "models", "asn1", "rsp_definitions.g.dart")


def parse_snippet(text: str):
    """Parse a standalone module body and return its assignments by name."""
    module = Parser(tokenize(text)).parse_module()
    return module, {a.name: a for a in module.assignments}


def encoded_tag(type_def) -> int:
    constructed = type_def.kind in ("seq", "choice", "seq_of")
    return tag_int(type_def.tag_num, type_def.tag_class, constructed, type_def.is_explicit)


class TokenizerTest(unittest.TestCase):
    def test_strips_line_comments_including_the_double_dash_terminator(self):
        toks = tokenize("A ::= INTEGER -- a comment -- B ::= BOOLEAN\n")
        self.assertEqual([t.text for t in toks],
                         ["A", "::=", "INTEGER", "B", "::=", "BOOLEAN"])

    def test_strips_block_comments(self):
        toks = tokenize("A /* B ::= NULL */ ::= INTEGER")
        self.assertEqual([t.text for t in toks], ["A", "::=", "INTEGER"])

    def test_hyphenated_identifiers_stay_one_token(self):
        toks = tokenize("PE-Dummy ::= NULL")
        self.assertEqual(toks[0].text, "PE-Dummy")

    def test_distinguishes_range_from_extension_marker(self):
        toks = tokenize("A ::= INTEGER (1..16) B ::= SEQUENCE { ... }")
        texts = [t.text for t in toks]
        self.assertIn("..", texts)
        self.assertIn("...", texts)


class ParsingTest(unittest.TestCase):
    """Syntax the shipped modules use, plus the corners they only touch once."""

    def parse(self, body, header="M DEFINITIONS AUTOMATIC TAGS ::= BEGIN"):
        module = Parser(tokenize(f"{header}\n{body}\nEND")).parse_module()
        return module, {a.name: a for a in module.assignments}

    # -- module header ------------------------------------------------------
    def test_module_identifier_with_an_oid_block(self):
        module, a = self.parse(
            "A ::= NULL",
            "M {joint-iso-itu-t (2) international-organizations (23) gsma (146)}"
            " DEFINITIONS AUTOMATIC TAGS EXTENSIBILITY IMPLIED ::= BEGIN")
        self.assertEqual(module.name, "M")
        self.assertEqual(module.tag_default, "AUTOMATIC")
        self.assertTrue(module.extensibility_implied)
        self.assertIn("A", a)

    def test_module_without_a_tag_default_is_explicit(self):
        module, _ = self.parse("A ::= NULL", "M DEFINITIONS ::= BEGIN")
        self.assertEqual(module.tag_default, "EXPLICIT")

    def test_imports_and_exports_are_skipped(self):
        _, a = self.parse(
            "EXPORTS A, B;\n"
            "IMPORTS Certificate, Time FROM PKIX1Explicit88 {1 3 6};\n"
            "A ::= NULL\nB ::= BOOLEAN")
        self.assertEqual(sorted(a), ["A", "B"])

    # -- comments -----------------------------------------------------------
    def test_a_comment_may_close_early_and_leave_code_after_it(self):
        _, a = self.parse("A ::= -- note -- BOOLEAN\nB ::= NULL")
        self.assertEqual(a["A"].type.base, "BOOLEAN")
        self.assertIn("B", a)

    def test_a_comment_containing_an_assignment_is_not_parsed(self):
        _, a = self.parse("A ::= NULL -- B ::= BOOLEAN\nC ::= NULL")
        self.assertEqual(sorted(a), ["A", "C"])

    def test_block_comments_span_lines(self):
        _, a = self.parse("/* B ::= NULL\n   still a comment */\nA ::= NULL")
        self.assertEqual(sorted(a), ["A"])

    def test_a_double_hyphen_inside_a_hyphenated_name(self):
        # `PE-Dummy` must not start a comment.
        _, a = self.parse("PE-Dummy ::= NULL")
        self.assertIn("PE-Dummy", a)

    # -- values -------------------------------------------------------------
    def test_value_assignments_do_not_become_types(self):
        _, a = self.parse(
            "id-rsp OBJECT IDENTIFIER ::= {joint-iso-itu-t (2) 23 146 1}\n"
            "maxSize INTEGER ::= 4096\n"
            "A ::= NULL")
        self.assertTrue(a["id-rsp"].is_value)
        self.assertTrue(a["maxSize"].is_value)
        self.assertFalse(a["A"].is_value)

    def test_hex_and_binary_default_values(self):
        _, a = self.parse(
            "A ::= SEQUENCE {\n"
            "  x [0] OCTET STRING DEFAULT '4000204060'H,\n"
            "  y [1] BIT STRING DEFAULT '0101'B,\n"
            "  z [2] INTEGER\n}")
        names = [c.name for c in a["A"].type.components]
        self.assertEqual(names, ["x", "y", "z"])
        self.assertTrue(a["A"].type.components[0].has_default)

    # -- structure ----------------------------------------------------------
    def test_extension_marker_is_recorded_and_skipped(self):
        _, a = self.parse("A ::= SEQUENCE { x [0] INTEGER, ... }")
        self.assertTrue(a["A"].type.extensible)
        self.assertEqual([c.name for c in a["A"].type.components], ["x"])

    def test_extension_marker_with_an_exception_spec(self):
        _, a = self.parse("A ::= SEQUENCE { x [0] INTEGER, ... ! 1 }")
        self.assertEqual([c.name for c in a["A"].type.components], ["x"])

    def test_version_brackets_contribute_their_members(self):
        _, a = self.parse(
            "A ::= SEQUENCE { x [0] INTEGER, ..., [[ y [1] BOOLEAN ]] }")
        self.assertEqual([c.name for c in a["A"].type.components], ["x", "y"])

    def test_components_of_is_skipped_rather_than_inlined(self):
        _, a = self.parse(
            "B ::= SEQUENCE { y [1] INTEGER }\n"
            "A ::= SEQUENCE { COMPONENTS OF B, x [0] INTEGER }")
        self.assertEqual([c.name for c in a["A"].type.components], ["x"])

    def test_size_constrained_sequence_of(self):
        _, a = self.parse("A ::= SEQUENCE SIZE (1..MAX) OF OCTET STRING")
        self.assertEqual(a["A"].type.base, "SEQUENCE OF")
        self.assertEqual(a["A"].type.element.base, "OCTET STRING")

    def test_sequence_of_with_a_named_element(self):
        _, a = self.parse("A ::= SEQUENCE OF item INTEGER")
        self.assertEqual(a["A"].type.base, "SEQUENCE OF")
        self.assertEqual(a["A"].type.element.base, "INTEGER")

    def test_nested_constraints_are_consumed(self):
        _, a = self.parse(
            "A ::= SEQUENCE {\n"
            "  x [0] OCTET STRING (SIZE (0..32)),\n"
            "  y [1] UTF8String (SIZE (1..8 | 16)),\n"
            "  z [2] INTEGER (0..4294967295)\n}")
        self.assertEqual([c.name for c in a["A"].type.components], ["x", "y", "z"])

    def test_any_defined_by(self):
        _, a = self.parse(
            "A ::= SEQUENCE { algorithm OBJECT IDENTIFIER,\n"
            "                 parameters ANY DEFINED BY algorithm OPTIONAL }")
        params = a["A"].type.components[1]
        self.assertEqual(params.type.base, "ANY")
        self.assertTrue(params.optional)

    def test_universal_class_tag(self):
        _, a = self.parse("A ::= [UNIVERSAL 16] SEQUENCE { x [0] INTEGER }")
        self.assertIsNone(a["A"].type.tag.tag_class)
        self.assertEqual(a["A"].type.tag.number, 16)

    def test_forward_and_self_references_resolve_later(self):
        _, a = self.parse(
            "A ::= SEQUENCE { b [0] B }\nB ::= SEQUENCE { a [0] A OPTIONAL }")
        self.assertEqual(a["A"].type.components[0].type.ref, "B")
        self.assertEqual(a["B"].type.components[0].type.ref, "A")

    def test_choice_alternatives_keep_their_order(self):
        _, a = self.parse(
            "A ::= CHOICE { first [0] INTEGER, second [1] BOOLEAN, third [2] NULL }")
        self.assertEqual([c.name for c in a["A"].type.components],
                         ["first", "second", "third"])

    def test_empty_sequence(self):
        _, a = self.parse("A ::= [32] SEQUENCE { }")
        self.assertEqual(a["A"].type.components, [])
        self.assertEqual(a["A"].type.tag.number, 32)

    # -- failure ------------------------------------------------------------
    def test_a_truncated_module_is_an_error_not_a_silent_success(self):
        from asn1_syntax import Asn1SyntaxError
        with self.assertRaises(Asn1SyntaxError):
            Parser(tokenize("M DEFINITIONS ::= BEGIN\nA ::= SEQUENCE {")).parse_module()

    def test_an_unparseable_type_is_an_error(self):
        from asn1_syntax import Asn1SyntaxError
        with self.assertRaises(Asn1SyntaxError):
            self.parse("A ::= 42")

    # -- the shipped modules ------------------------------------------------
    def test_shipped_modules_parse_to_a_stable_shape(self):
        expected = {
            "PKIX1Explicit88": (169, "EXPLICIT"),
            "PKIX1Implicit88": (85, "IMPLICIT"),
            "PEDefinitions": (66, "AUTOMATIC"),
            "RSPDefinitions": (219, "AUTOMATIC"),
        }
        seen = {}
        for path in source_paths(SCRIPT_DIR):
            module = parse_file(path)
            seen[module.name] = (len(module.assignments), module.tag_default)
        for name, want in expected.items():
            with self.subTest(name):
                self.assertEqual(seen.get(name), want)


class TaggingTest(unittest.TestCase):
    """X.680 tagging rules, which decide the bytes on the wire."""

    AUTOMATIC = "M DEFINITIONS AUTOMATIC TAGS ::= BEGIN\n%s\nEND"

    def test_automatic_tags_apply_when_no_component_is_tagged(self):
        _, a = parse_snippet(self.AUTOMATIC % "A ::= SEQUENCE { x INTEGER, y BOOLEAN }")
        tags = [c.type.tag.number for c in a["A"].type.components]
        self.assertEqual(tags, [0, 1])

    def test_automatic_tags_are_suppressed_when_any_component_is_tagged(self):
        # X.680 12.3: a single explicit tag disables automatic tagging for the
        # whole component list, so the untagged members keep their own tags.
        _, a = parse_snippet(self.AUTOMATIC % "A ::= SEQUENCE { x INTEGER, y [17] BOOLEAN }")
        comps = a["A"].type.components
        self.assertIsNone(comps[0].type.tag)
        self.assertEqual(comps[1].type.tag.number, 17)

    def test_tagging_an_inline_choice_is_explicit(self):
        _, a = parse_snippet(self.AUTOMATIC % "A ::= SEQUENCE { x CHOICE { p INTEGER, q BOOLEAN } }")
        tag = a["A"].type.components[0].type.tag
        self.assertEqual(tag.number, 0)
        self.assertTrue(tag.explicit, "an untagged CHOICE can only be tagged explicitly")

    def test_explicit_tags_module_default(self):
        _, a = parse_snippet("M DEFINITIONS EXPLICIT TAGS ::= BEGIN\n"
                             "A ::= SEQUENCE { x [0] INTEGER }\nEND")
        self.assertTrue(a["A"].type.components[0].type.tag.explicit)

    def test_implicit_tags_module_default(self):
        _, a = parse_snippet("M DEFINITIONS IMPLICIT TAGS ::= BEGIN\n"
                             "A ::= SEQUENCE { x [0] INTEGER }\nEND")
        self.assertFalse(a["A"].type.components[0].type.tag.explicit)

    def test_explicit_keyword_overrides_module_default(self):
        _, a = parse_snippet("M DEFINITIONS IMPLICIT TAGS ::= BEGIN\n"
                             "A ::= SEQUENCE { x [0] EXPLICIT INTEGER }\nEND")
        self.assertTrue(a["A"].type.components[0].type.tag.explicit)

    def test_tag_classes(self):
        _, a = parse_snippet("M DEFINITIONS IMPLICIT TAGS ::= BEGIN\n"
                             "A ::= [APPLICATION 26] OCTET STRING\n"
                             "B ::= [PRIVATE 3] SEQUENCE { x INTEGER }\n"
                             "C ::= [7] INTEGER\nEND")
        self.assertEqual(a["A"].type.tag.tag_class, "TAG_APPLICATION")
        self.assertEqual(a["B"].type.tag.tag_class, "TAG_PRIVATE")
        self.assertEqual(a["C"].type.tag.tag_class, "TAG_CONTEXT_SPEC")


class TagEncodingTest(unittest.TestCase):
    """The identifier octets tag_int() produces for known SGP.22 tags."""

    def test_low_tag_numbers(self):
        self.assertEqual(tag_int(26, "TAG_APPLICATION", False), 0x5A)   # Iccid
        self.assertEqual(tag_int(3, "TAG_PRIVATE", True), 0xE3)         # ProfileInfo
        self.assertEqual(tag_int(0, "TAG_CONTEXT_SPEC", True), 0xA0)

    def test_high_tag_numbers_use_the_multi_byte_form(self):
        self.assertEqual(tag_int(46, "TAG_CONTEXT_SPEC", True), 0xBF2E)  # GetEuiccChallengeResponse
        self.assertEqual(tag_int(34, "TAG_CONTEXT_SPEC", True), 0xBF22)  # EUICCInfo2
        self.assertEqual(tag_int(55, "TAG_APPLICATION", False), 0x5F37)  # signatures

    def test_explicit_tagging_forces_the_constructed_bit(self):
        self.assertEqual(tag_int(1, "TAG_CONTEXT_SPEC", False, is_explicit=True), 0xA1)


class InlineNamingTest(unittest.TestCase):
    """Flattened names for anonymous types, which are part of the public API."""

    def build(self, body):
        module = Parser(tokenize("M DEFINITIONS AUTOMATIC TAGS ::= BEGIN\n%s\nEND" % body)).parse_module()
        return {t.name: t for t in ModelBuilder([module]).build()}

    def test_inline_sequence_is_named_after_its_path(self):
        types = self.build("A ::= SEQUENCE { inner SEQUENCE { x INTEGER } }")
        self.assertIn("A_inner", types)
        self.assertEqual(types["A_inner"].kind, "seq")

    def test_nested_inline_types_keep_nesting_in_the_name(self):
        types = self.build("A ::= SEQUENCE { b CHOICE { c SEQUENCE { x INTEGER } } }")
        self.assertIn("A_b_c", types)

    def test_sequence_of_inline_element_uses_the_item_suffix(self):
        types = self.build("A ::= SEQUENCE OF SEQUENCE { x INTEGER }")
        self.assertIn("A__item_", types)
        self.assertEqual(types["A"].element_type, "A__item_")

    def test_sequence_of_named_element_refers_to_that_name(self):
        types = self.build("B ::= SEQUENCE { x INTEGER }\nA ::= SEQUENCE OF B")
        self.assertEqual(types["A"].element_type, "B")

    def test_hyphens_become_underscores(self):
        self.assertEqual(clean_name("PE-GenericFileManagement"), "PE_GenericFileManagement")
        self.assertEqual(clean_name("_Foo_bar"), "Foo_bar")


class ModelKindTest(unittest.TestCase):
    def build(self, body):
        module = Parser(tokenize("M DEFINITIONS AUTOMATIC TAGS ::= BEGIN\n%s\nEND" % body)).parse_module()
        return {t.name: t for t in ModelBuilder([module]).build()}

    def test_integer_with_named_numbers_becomes_an_enum(self):
        types = self.build("A ::= INTEGER { ok (0), bad (127) }")
        self.assertEqual(types["A"].enum_values, {"ok": 0, "bad": 127})

    def test_integer_without_named_numbers_is_not_a_standalone_type(self):
        self.assertNotIn("A", self.build("A ::= INTEGER"))

    def test_bit_string_with_named_bits_keeps_the_bit_positions(self):
        types = self.build("A ::= BIT STRING { first (0), ninth (8) }")
        self.assertEqual(types["A"].kind, "bits")
        self.assertEqual(types["A"].enum_values, {"first": 0, "ninth": 8})

    def test_type_reference_resolves_to_the_target_kind(self):
        types = self.build("B ::= OCTET STRING\nA ::= SEQUENCE { x B }")
        self.assertEqual(types["A"].fields[0].type_name, "B")
        self.assertEqual(types["A"].fields[0].kind, "octets")

    def test_default_marks_a_component_optional(self):
        types = self.build("A ::= SEQUENCE { x [0] BOOLEAN DEFAULT FALSE, y [1] INTEGER }")
        self.assertTrue(types["A"].fields[0].is_optional)
        self.assertFalse(types["A"].fields[1].is_optional)


class RealSpecTest(unittest.TestCase):
    """Checks against the actual SGP.22 / PKIX modules in tools/asn1/."""

    @classmethod
    def setUpClass(cls):
        cls.paths = source_paths(SCRIPT_DIR)
        cls.types = {t.name: t for t in build(SCRIPT_DIR)}

    def test_every_module_parses(self):
        names = {parse_file(p).name for p in self.paths}
        self.assertIn("RSPDefinitions", names)
        self.assertIn("PEDefinitions", names)
        self.assertIn("PKIX1Explicit88", names)
        self.assertIn("PKIX1Implicit88", names)

    def test_documented_tags_match_the_generated_tags(self):
        """The spec files annotate many types with `-- Tag 'BF2E'`; honour them.

        This is an oracle independent of both the old and the new generator.
        """
        mismatches = []
        checked = 0
        for path in self.paths:
            current = None
            for line in open(path, encoding="utf-8", errors="replace"):
                assignment = re.match(r"^([A-Za-z][\w-]*)\s*::=", line)
                if assignment:
                    current = clean_name(assignment.group(1))
                comment = re.search(r"--.*?\b[Tt]ag\s+'([0-9A-Fa-f]{2,6})'", line)
                if not (comment and assignment and current in self.types):
                    continue
                want = int(comment.group(1), 16)
                got = encoded_tag(self.types[current])
                checked += 1
                if got != want:
                    mismatches.append(f"{current}: documented 0x{want:X}, generated {got and hex(got)}")
        self.assertGreater(checked, 50, "expected the spec files to document many tags")
        self.assertEqual(mismatches, [], "\n".join(mismatches))

    def test_well_known_sgp22_tags(self):
        expected = {
            "GetEuiccChallengeResponse": 0xBF2E,
            "EUICCInfo2": 0xBF22,
            "StoreMetadataRequest": 0xBF25,
            "ProfileInfo": 0xE3,
            "ProfileInfoListResponse": 0xBF2D,
            "NotificationMetadata": 0xBF2F,
            "EnableProfileRequest": 0xBF31,
            "Iccid": 0x5A,
            "EuiccSign": 0x5F37,
        }
        for name, tag in expected.items():
            with self.subTest(name):
                self.assertIn(name, self.types)
                self.assertEqual(encoded_tag(self.types[name]), tag)

    def test_types_the_app_depends_on_are_present(self):
        # Referenced directly from lib/; losing any of them breaks the build.
        required = [
            "AuthenticateClientRequest", "AuthenticateClientResponseEs9",
            "AuthenticateServerRequest", "AuthenticateServerResponse",
            "DeleteProfileResponse", "DisableProfileRequest", "DisableProfileResponse",
            "EUICCInfo1", "EUICCInfo2", "EnableProfileRequest", "EnableProfileResponse",
            "ExtendedCardResource", "GetEuiccChallengeResponse", "GetEuiccDataResponse",
            "InitiateAuthenticationRequest", "InitiateAuthenticationResponse",
            "ListNotificationResponse", "NotificationMetadata", "NotificationSentResponse",
            "PendingNotification", "PrepareDownloadResponse", "ProfileInfoListResponse",
            "RetrieveNotificationsListResponse", "ServerSigned1", "SetNicknameRequest",
            "SmdpSigned2", "StoreMetadataRequest", "Certificate",
        ]
        missing = [name for name in required if name not in self.types]
        self.assertEqual(missing, [])

    def test_euiccinfo2_extended_card_resource_is_structured(self):
        fields = {f.name: f for f in self.types["EUICCInfo2"].fields}
        self.assertEqual(fields["extCardResource"].type_name, "ExtendedCardResource")
        inner = {f.name for f in self.types["ExtendedCardResource"].fields}
        self.assertEqual(inner, {"installedApplication", "freeNonVolatileMemory",
                                 "freeVolatileMemory"})

    def test_store_metadata_request_untagged_iccid_keeps_its_application_tag(self):
        # `iccid Iccid` carries no tag of its own, so it must fall back to the
        # [APPLICATION 26] tag of Iccid, i.e. '5A'.
        field = next(f for f in self.types["StoreMetadataRequest"].fields if f.name == "iccid")
        self.assertEqual(tag_int(field.tag_num, field.tag_class, False), 0x5A)

    def test_enable_profile_request_wraps_its_choice_explicitly(self):
        field = next(f for f in self.types["EnableProfileRequest"].fields
                     if f.name == "profileIdentifier")
        self.assertTrue(field.is_explicit)
        self.assertEqual(tag_int(field.tag_num, field.tag_class, True, True), 0xA0)

    # Sequences where the source spec itself gives an OPTIONAL component the
    # same tag as its neighbour, so presence cannot be decided by tag alone.
    # These are inherent to PKIX / TCA / SGP.22, not artefacts of generation;
    # the test exists to catch *new* ambiguities creeping in.
    KNOWN_AMBIGUOUS = {
        "TBSCertList: signature / revokedCertificates",
        "PDSParameter: printable_string / teletex_string",
        "ApplicationLoadPackage: loadPackageAID / securityDomainAID",
        "ApplicationInstance: instanceAID / extraditeSecurityDomainAID",
        "PE_RFM: instanceAID / securityDomainAID",
        "PE_RFM: rfm_header / tarList",
        "CtxParamsForDeviceChange: iccid / targetEidValue",
    }

    def test_optional_components_do_not_gain_ambiguous_tags(self):
        """An OPTIONAL component sharing a neighbour's tag cannot be decoded.

        The previous front end produced exactly this by auto-tagging component
        lists that already carried tags (OtherSignedNotification ended up with
        two [1] components).
        """
        offenders = set()
        for type_def in self.types.values():
            if type_def.kind != "seq":
                continue
            seen = {}
            for field in type_def.fields:
                if field.tag_num is None:
                    continue
                key = (field.tag_num, field.tag_class)
                previous = seen.get(key)
                if previous and (previous[1] or field.is_optional):
                    offenders.add(f"{type_def.name}: {previous[0]} / {field.name}")
                seen[key] = (field.name, field.is_optional)
        self.assertEqual(offenders, self.KNOWN_AMBIGUOUS)

    def test_every_field_type_resolves(self):
        known = set(self.types) | {"int", "bool", "String", "Uint8List", "dynamic"}
        dangling = [f"{t.name}.{f.name} -> {f.type_name}"
                    for t in self.types.values() for f in t.fields
                    if f.type_name not in known]
        self.assertEqual(dangling, [])


class ForeignSpecTest(unittest.TestCase):
    """The generator must be a general X.680 tool, not an SGP.22 one.

    tools/testdata/ holds modules nothing in the app uses. If a change starts
    relying on something particular to the shipped specs, these break.
    """

    @classmethod
    def setUpClass(cls):
        import asn1_emit
        from asn1_model import build_model
        paths = [os.path.join(SCRIPT_DIR, "testdata", name)
                 for name in ("RFC1157-SNMP.asn1", "Constructs.asn1")]
        types = build_model(paths)
        types = asn1_emit.prune_types(types, [t.name for t in types])
        asn1_emit.fill_missing_field_tags(types)
        asn1_emit.extend_basic_types(types)
        cls.types = {t.name: t for t in types}

    def test_implicit_tags_module_and_application_tagged_aliases(self):
        # SNMP's PDU tags and application types, straight from RFC 1157.
        expected = {
            "GetRequest_PDU": 0xA0, "GetNextRequest_PDU": 0xA1,
            "GetResponse_PDU": 0xA2, "SetRequest_PDU": 0xA3, "Trap_PDU": 0xA4,
            "IpAddress": 0x40, "Counter": 0x41, "Gauge": 0x42,
            "TimeTicks": 0x43, "Opaque": 0x44,
        }
        for name, tag in expected.items():
            with self.subTest(name):
                self.assertIn(name, self.types)
                self.assertEqual(encoded_tag(self.types[name]), tag)

    def test_enumerated_becomes_an_enum(self):
        self.assertEqual(self.types["Colour"].enum_values,
                         {"red": 0, "green": 1, "blue": 2})

    def test_enumerated_keeps_its_own_universal_tag(self):
        # ENUMERATED is modelled as an INTEGER, but encodes as '0A' not '02'.
        self.assertEqual(encoded_tag(self.types["Colour"]), 0x0A)

    def test_named_bits_keep_sparse_positions(self):
        self.assertEqual(self.types["Flags"].enum_values,
                         {"alpha": 0, "beta": 3, "gamma": 17})

    def test_inline_integer_named_numbers(self):
        self.assertEqual(self.types["PDU_error_status"].enum_values["genErr"], 5)

    def test_set_of_and_set(self):
        self.assertEqual(self.types["Names"].kind, "seq_of")
        self.assertEqual([f.name for f in self.types["Coordinates"].fields], ["x", "y"])

    def test_default_marks_optional_and_extension_marker_is_tolerated(self):
        fields = {f.name: f for f in self.types["Extensible"].fields}
        self.assertFalse(fields["required"].is_optional)
        self.assertTrue(fields["optional"].is_optional)

    def test_time_types(self):
        kinds = {f.name: f.kind for f in self.types["Stamped"].fields}
        self.assertEqual(kinds["createdAt"], "time_utc")
        self.assertEqual(kinds["expiresAt"], "time_gen")

    def test_nested_anonymous_types_are_flattened(self):
        for name in ("Nested_inner", "Nested_inner_pick", "Nested_inner_list__item_"):
            self.assertIn(name, self.types)

    def test_self_referential_type(self):
        fields = {f.name: f.type_name for f in self.types["Recursive"].fields}
        self.assertEqual(fields["next"], "Recursive")

    def test_generated_dart_has_no_analyzer_errors(self):
        """Emit the foreign modules and let the Dart analyzer judge the result."""
        import asn1_emit
        import shutil
        if shutil.which("dart") is None:
            self.skipTest("dart not on PATH")
        out = os.path.join(PROJECT_ROOT, "lib", "models", "asn1", "_foreign_probe.g.dart")
        try:
            asn1_emit.generate_dart(list(self.types.values()), out)
            result = subprocess.run(["dart", "analyze", out], capture_output=True, text=True)
            errors = [l for l in result.stdout.splitlines() if l.strip().startswith("error")]
            self.assertEqual(errors, [], "\n".join(errors))
        finally:
            if os.path.exists(out):
                os.unlink(out)


class DeterminismTest(unittest.TestCase):
    def test_output_is_identical_across_runs_and_hash_seeds(self):
        import hashlib
        import tempfile

        digests = set()
        for seed in ("0", "1", "12345"):
            with tempfile.NamedTemporaryFile(suffix=".dart", delete=False) as tmp:
                path = tmp.name
            env = dict(os.environ, PYTHONHASHSEED=seed)
            subprocess.run([sys.executable, os.path.join(SCRIPT_DIR, "asn1_dart_gen.py"),
                            "--output", path], check=True, env=env,
                           stdout=subprocess.DEVNULL)
            digests.add(hashlib.sha256(open(path, "rb").read()).hexdigest())
            os.unlink(path)
        self.assertEqual(len(digests), 1,
                         "generation must be reproducible; got %d distinct outputs" % len(digests))


class CheckedInDartTest(unittest.TestCase):
    """The generated file in lib/ must be what the generator produces."""

    @unittest.skipUnless(os.path.exists(GENERATED_DART), "generated Dart not present")
    def test_checked_in_file_is_up_to_date(self):
        result = subprocess.run(
            [sys.executable, os.path.join(SCRIPT_DIR, "asn1_dart_gen.py"), "--check"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0,
                         "lib/models/asn1/rsp_definitions.g.dart is stale; "
                         "run python3 tools/asn1_dart_gen.py\n" + result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
