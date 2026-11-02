#!/usr/bin/env python3
"""
A small X.680 parser covering the subset of ASN.1 used by the SGP.22 / SGP.32
and PKIX modules shipped in tools/asn1/.

It produces a plain AST (Module / Assignment / TypeNode / Component) that
tools/asn1_model.py turns into the TypeDef/FieldDef model consumed by the Dart
emitter in tools/asn1_emit.py.

Deliberately not a general ASN.1 compiler: information object classes,
parameterisation and value-set arithmetic are recognised well enough to be
skipped, not to be interpreted.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Dict, List, Optional

# ---------------------------------------------------------------------------
# Tokenizer
# ---------------------------------------------------------------------------

# Longest punctuation first so that '::=' beats ':' and '...' beats '..'.
_PUNCT = [
    "::=", "...", "..", "[[", "]]",
    "{", "}", "(", ")", "[", "]", ",", ";", "|", "<", ">", "@", "!", "^", ".",
    ":",  # after '::=', which must win the alternation
]

_TOKEN_RE = re.compile(
    r"""
      (?P<ws>\s+)
    | (?P<linecomment>--(?:[^\n-]|-(?!-))*(?:--|(?=\n)|$))
    | (?P<blockcomment>/\*)
    | (?P<bstring>'[01\s]*'[Bb])
    | (?P<hstring>'[0-9A-Fa-f\s]*'[Hh])
    | (?P<cstring>"(?:[^"]|"")*")
    | (?P<number>-?\d+)
    | (?P<word>[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]|[A-Za-z])
    | (?P<punct>""" + "|".join(re.escape(p) for p in _PUNCT) + r""")
    """,
    re.VERBOSE,
)


@dataclass
class Token:
    kind: str      # 'word' | 'number' | 'string' | 'punct'
    text: str
    line: int


class Asn1SyntaxError(Exception):
    pass


def tokenize(text: str) -> List[Token]:
    tokens: List[Token] = []
    pos = 0
    line = 1
    end = len(text)
    while pos < end:
        m = _TOKEN_RE.match(text, pos)
        if not m:
            raise Asn1SyntaxError(f"line {line}: cannot tokenize {text[pos:pos + 30]!r}")
        kind = m.lastgroup
        chunk = m.group()
        if kind == "blockcomment":
            close = text.find("*/", m.end())
            close = end if close < 0 else close + 2
            line += text.count("\n", pos, close)
            pos = close
            continue
        line += chunk.count("\n")
        pos = m.end()
        if kind in ("ws", "linecomment"):
            continue
        if kind in ("bstring", "hstring", "cstring"):
            tokens.append(Token("string", chunk, line))
        elif kind == "number":
            tokens.append(Token("number", chunk, line))
        elif kind == "word":
            tokens.append(Token("word", chunk, line))
        else:
            tokens.append(Token("punct", chunk, line))
    return tokens


# ---------------------------------------------------------------------------
# AST
# ---------------------------------------------------------------------------

# Universal ASN.1 types we recognise by keyword.
_STRING_TYPES = {
    "UTF8String", "PrintableString", "IA5String", "BMPString", "NumericString",
    "TeletexString", "UniversalString", "VisibleString", "GeneralString",
    "GraphicString", "T61String", "VideotexString", "ISO646String",
    "ObjectDescriptor",
}


@dataclass
class Tag:
    number: int
    tag_class: Optional[str]   # 'TAG_APPLICATION' | 'TAG_PRIVATE' | 'TAG_CONTEXT_SPEC' | None (universal)
    explicit: bool = False


@dataclass
class TypeNode:
    base: str                                  # see _BASE_* usage in asn1_model
    tag: Optional[Tag] = None
    ref: Optional[str] = None                  # base == 'REF'
    components: List["Component"] = field(default_factory=list)
    element: Optional["TypeNode"] = None       # base in ('SEQUENCE OF', 'SET OF')
    named_values: Dict[str, int] = field(default_factory=dict)  # INTEGER/BIT STRING/ENUMERATED
    extensible: bool = False


@dataclass
class Component:
    name: str
    type: TypeNode
    optional: bool = False
    has_default: bool = False


@dataclass
class Assignment:
    name: str
    type: TypeNode
    module: str
    is_value: bool = False


@dataclass
class Module:
    name: str
    tag_default: str                   # 'AUTOMATIC' | 'EXPLICIT' | 'IMPLICIT'
    extensibility_implied: bool
    assignments: List[Assignment] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

class Parser:
    def __init__(self, tokens: List[Token]):
        self.toks = tokens
        self.i = 0

    # -- token helpers ------------------------------------------------------
    def peek(self, offset: int = 0) -> Optional[Token]:
        idx = self.i + offset
        return self.toks[idx] if idx < len(self.toks) else None

    def peek_text(self, offset: int = 0) -> Optional[str]:
        tok = self.peek(offset)
        return tok.text if tok else None

    def next(self) -> Token:
        tok = self.peek()
        if tok is None:
            raise Asn1SyntaxError("unexpected end of input")
        self.i += 1
        return tok

    def accept(self, text: str) -> bool:
        if self.peek_text() == text:
            self.i += 1
            return True
        return False

    def expect(self, text: str) -> Token:
        tok = self.next()
        if tok.text != text:
            raise Asn1SyntaxError(f"line {tok.line}: expected {text!r}, got {tok.text!r}")
        return tok

    def skip_balanced(self, opener: str, closer: str) -> None:
        """Consume a balanced bracket group, assuming the opener is next."""
        self.expect(opener)
        depth = 1
        while depth:
            tok = self.next()
            if tok.text == opener:
                depth += 1
            elif tok.text == closer:
                depth -= 1

    # -- module -------------------------------------------------------------
    def parse_module(self) -> Module:
        name_tok = self.next()
        module_name = name_tok.text
        if self.peek_text() == "{":
            self.skip_balanced("{", "}")
        self.expect("DEFINITIONS")

        tag_default = "EXPLICIT"
        extensibility = False
        while self.peek_text() != "::=":
            word = self.next().text
            if word in ("AUTOMATIC", "IMPLICIT", "EXPLICIT") and self.peek_text() == "TAGS":
                self.next()
                tag_default = word
            elif word == "EXTENSIBILITY" and self.peek_text() == "IMPLIED":
                self.next()
                extensibility = True
        self.expect("::=")
        self.expect("BEGIN")

        module = Module(module_name, tag_default, extensibility)

        # Optional EXPORTS / IMPORTS clauses, both terminated by ';'.
        while self.peek_text() in ("EXPORTS", "IMPORTS"):
            while self.peek_text() != ";":
                self.next()
            self.next()

        while self.peek_text() not in (None, "END"):
            assignment = self.parse_assignment(module)
            if assignment is not None:
                module.assignments.append(assignment)
        self.accept("END")
        return module

    def parse_assignment(self, module: Module) -> Optional[Assignment]:
        start = self.i
        name_tok = self.next()
        name = name_tok.text

        # Parameterised assignment: Name {Params} ::= Type. Skip the parameter
        # list; the modules here only use it for information object classes.
        if self.peek_text() == "{" and self._brace_group_is_parameter_list():
            self.skip_balanced("{", "}")

        if self.peek_text() == "::=":
            self.next()
            if name[:1].isupper():
                if self.peek_text() == "CLASS":
                    self._skip_value()
                    return None
                node = self.parse_type(module)
                return Assignment(name, node, module.name)
            # lowercase ::= — a value assignment without a type, skip it.
            self._skip_value()
            return None

        # valuereference Type ::= Value  (also ObjectSet / ValueSet assignments)
        self.i = start
        return self._parse_value_assignment(module)

    def _brace_group_is_parameter_list(self) -> bool:
        """True when the '{' at the cursor opens a DefinedSyntax parameter list."""
        depth = 0
        idx = self.i
        while idx < len(self.toks):
            text = self.toks[idx].text
            if text == "{":
                depth += 1
            elif text == "}":
                depth -= 1
                if depth == 0:
                    return self.toks[idx + 1].text == "::=" if idx + 1 < len(self.toks) else False
            idx += 1
        return False

    def _parse_value_assignment(self, module: Module) -> Optional[Assignment]:
        name = self.next().text
        # Consume the type, but keep what kind it was: the historical generator
        # emitted a typedef for every value assignment, so we mirror that.
        try:
            node = self.parse_type(module)
        except Asn1SyntaxError:
            self._skip_to_next_assignment()
            return None
        if self.peek_text() != "::=":
            self._skip_to_next_assignment()
            return None
        self.next()
        self._skip_value()
        return Assignment(name, node, module.name, is_value=True)

    def _skip_value(self) -> None:
        if self.peek_text() == "{":
            self.skip_balanced("{", "}")
            return
        # A bare value: consume tokens until the next assignment starts.
        self._skip_to_next_assignment()

    def _skip_to_next_assignment(self) -> None:
        while True:
            tok = self.peek()
            if tok is None or tok.text == "END":
                return
            # An assignment begins at `word [{...}] ::=` or `word Type ::=`;
            # detecting the '::=' two-or-more tokens ahead is good enough here.
            if tok.kind == "word" and self._starts_assignment(self.i):
                return
            self.next()

    def _starts_assignment(self, idx: int) -> bool:
        if idx == 0:
            return True
        # Look ahead a bounded distance for '::=' with no intervening '}' at depth 0.
        depth = 0
        for j in range(idx, min(idx + 40, len(self.toks))):
            text = self.toks[j].text
            if text in ("{", "(", "["):
                depth += 1
            elif text in ("}", ")", "]"):
                depth -= 1
                if depth < 0:
                    return False
            elif text == "::=" and depth == 0:
                return True
            elif text == "END":
                return False
        return False

    # -- types --------------------------------------------------------------
    def parse_type(self, module: Module) -> TypeNode:
        tag = self.parse_tag(module)
        node = self.parse_base_type(module)
        if tag is not None:
            if node.tag is not None:
                # Doubly tagged type; the outer tag is the one on the wire.
                inner = TypeNode(base=node.base, tag=node.tag, ref=node.ref,
                                 components=node.components, element=node.element,
                                 named_values=node.named_values, extensible=node.extensible)
                node = TypeNode(base="TAGGED", tag=tag, element=inner)
            else:
                node.tag = tag
            # X.680 30.6 c): tagging an untagged CHOICE is explicit. ANY is
            # excluded on purpose: these modules use it as a stand-in for opaque
            # bytes, and the tags the spec comments document for those fields
            # (e.g. serverSignature1 '5F37') are primitive, not constructed.
            if tag.explicit is False and node.base == "CHOICE":
                tag.explicit = True
        self.skip_constraints()
        return node

    def parse_tag(self, module: Module) -> Optional[Tag]:
        if self.peek_text() != "[":
            return None
        self.next()
        tag_class = None
        word = self.peek_text()
        if word in ("APPLICATION", "PRIVATE", "UNIVERSAL", "CONTEXT"):
            self.next()
            tag_class = {
                "APPLICATION": "TAG_APPLICATION",
                "PRIVATE": "TAG_PRIVATE",
                "UNIVERSAL": None,
                "CONTEXT": "TAG_CONTEXT_SPEC",
            }[word]
        else:
            tag_class = "TAG_CONTEXT_SPEC"
        num_tok = self.next()
        try:
            number = int(num_tok.text)
        except ValueError:
            raise Asn1SyntaxError(f"line {num_tok.line}: non-numeric tag {num_tok.text!r}")
        self.expect("]")

        if self.accept("IMPLICIT"):
            explicit = False
        elif self.accept("EXPLICIT"):
            explicit = True
        else:
            explicit = module.tag_default == "EXPLICIT"
        return Tag(number, tag_class, explicit)

    def skip_constraints(self) -> None:
        while True:
            text = self.peek_text()
            if text == "(":
                self.skip_balanced("(", ")")
            elif text == "{" and self.peek_text(-1) in ("SIZE",):
                self.skip_balanced("{", "}")
            else:
                return

    def parse_base_type(self, module: Module) -> TypeNode:
        tok = self.next()
        word = tok.text

        if word == "SEQUENCE" or word == "SET":
            # A SIZE constraint may sit between SEQUENCE/SET and OF.
            self.accept("SIZE")
            if self.peek_text() == "(":
                self.skip_balanced("(", ")")
            if self.accept("OF"):
                # `SEQUENCE OF name Type` names the element; the name is unused.
                if (self.peek(0) and self.peek(0).kind == "word"
                        and self.peek_text(0)[:1].islower()
                        and self.peek_text(1) not in (",", "}", None)
                        and not self._is_type_start(self.peek_text(0))):
                    self.next()
                element = self.parse_type(module)
                return TypeNode(base=f"{word} OF", element=element)
            node = TypeNode(base=word)
            self.parse_component_list(module, node)
            return node

        if word == "CHOICE":
            node = TypeNode(base="CHOICE")
            self.parse_component_list(module, node)
            return node

        if word == "INTEGER":
            node = TypeNode(base="INTEGER")
            if self.peek_text() == "{":
                node.named_values = self.parse_named_values()
            return node

        if word == "BIT":
            self.expect("STRING")
            node = TypeNode(base="BIT STRING")
            if self.peek_text() == "{":
                node.named_values = self.parse_named_values()
            return node

        if word == "OCTET":
            self.expect("STRING")
            return TypeNode(base="OCTET STRING")

        if word == "OBJECT":
            self.expect("IDENTIFIER")
            return TypeNode(base="OBJECT IDENTIFIER")

        if word == "RELATIVE-OID":
            return TypeNode(base="OBJECT IDENTIFIER")

        if word == "ENUMERATED":
            node = TypeNode(base="ENUMERATED")
            node.named_values = self.parse_named_values()
            return node

        if word == "ANY":
            if self.accept("DEFINED"):
                self.expect("BY")
                self.next()
            return TypeNode(base="ANY")

        if word in ("BOOLEAN", "NULL", "UTCTime", "GeneralizedTime", "EXTERNAL",
                    "REAL", "EMBEDDED"):
            if word == "EMBEDDED":
                self.accept("PDV")
                return TypeNode(base="ANY")
            return TypeNode(base=word)

        if word in _STRING_TYPES:
            return TypeNode(base="STRING", ref=word)

        if word[:1].isupper():
            # Module-qualified reference: Module.Type
            if self.peek_text() == "." and self.peek(1) and self.peek(1).kind == "word":
                self.next()
                word = self.next().text
            # Parameterised reference: Type {Params}
            if self.peek_text() == "{" and self._looks_like_actual_parameters():
                self.skip_balanced("{", "}")
            return TypeNode(base="REF", ref=word)

        raise Asn1SyntaxError(f"line {tok.line}: unexpected type token {word!r}")

    def _is_type_start(self, text: Optional[str]) -> bool:
        return bool(text) and (text[:1].isupper() or text in (
            "SEQUENCE", "SET", "CHOICE", "INTEGER", "BIT", "OCTET", "OBJECT",
            "BOOLEAN", "NULL", "ENUMERATED", "ANY",
        ))

    def _looks_like_actual_parameters(self) -> bool:
        nxt = self.peek(1)
        return nxt is not None and nxt.kind == "word" and nxt.text[:1].isupper()

    def parse_named_values(self) -> Dict[str, int]:
        values: Dict[str, int] = {}
        self.expect("{")
        while True:
            if self.accept("}"):
                break
            if self.accept(","):
                continue
            if self.accept("..."):
                continue
            name = self.next().text
            if self.peek_text() == "(":
                self.next()
                num = self.next().text
                # ENUMERATED/INTEGER named numbers may reference a value name.
                try:
                    values[name] = int(num)
                except ValueError:
                    pass
                while not self.accept(")"):
                    self.next()
            else:
                values[name] = len(values)
        return values

    def parse_component_list(self, module: Module, node: TypeNode) -> None:
        self.expect("{")
        components: List[Component] = []
        while True:
            if self.accept("}"):
                break
            if self.accept(","):
                continue
            text = self.peek_text()
            if text == "...":
                self.next()
                node.extensible = True
                self.skip_exception_spec()
                continue
            if text == "[[":
                self.next()
                # Version brackets: parse the group inline, then close.
                if self.peek() and self.peek().kind == "number" and self.peek_text(1) == ":":
                    self.next()
                    self.next()
                continue
            if text == "]]":
                self.next()
                continue
            if text == "COMPONENTS":
                self.next()
                self.expect("OF")
                self.parse_type(module)
                continue
            components.append(self.parse_component(module))
        node.components = components
        self.apply_automatic_tags(module, node)

    def parse_component(self, module: Module) -> Component:
        name_tok = self.next()
        name = name_tok.text
        type_node = self.parse_type(module)
        optional = False
        has_default = False
        if self.accept("OPTIONAL"):
            optional = True
        elif self.accept("DEFAULT"):
            has_default = True
            optional = True
            self._skip_default_value()
        return Component(name, type_node, optional, has_default)

    def skip_exception_spec(self) -> None:
        """Consume `! ExceptionIdentification` after an extension marker.

        X.680 53.4: a signed number, a defined value, or `Type : Value`. It is
        bounded, so it must not fall back to the run-to-the-next-assignment
        skip, which would swallow the rest of the component list.
        """
        if not self.accept("!"):
            return
        self.next()
        if self.accept(":"):
            self.next()

    def _skip_default_value(self) -> None:
        if self.peek_text() == "{":
            self.skip_balanced("{", "}")
            return
        self.next()

    def apply_automatic_tags(self, module: Module, node: TypeNode) -> None:
        """X.680 12.3: automatic tags apply only when no component carries one."""
        if module.tag_default != "AUTOMATIC":
            return
        if any(c.type.tag is not None for c in node.components):
            return
        for index, component in enumerate(node.components):
            component.type.tag = Tag(index, "TAG_CONTEXT_SPEC",
                                     component.type.base == "CHOICE")


def parse_file(path: str) -> Module:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    tokens = tokenize(text)
    # Some of the shipped modules are RFC extracts with prose ahead of the
    # module header, so start at the module reference preceding DEFINITIONS
    # rather than at the first token.
    start = next((i for i, tok in enumerate(tokens) if tok.text == "DEFINITIONS"), 0) - 1
    if start >= 0 and tokens[start].text == "}":
        depth = 0
        while start >= 0:
            if tokens[start].text == "}":
                depth += 1
            elif tokens[start].text == "{":
                depth -= 1
                if depth == 0:
                    break
            start -= 1
        start -= 1
    return Parser(tokens[max(start, 0):]).parse_module()
