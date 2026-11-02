# ASN.1 → Dart code generation

`lib/models/asn1/rsp_definitions.g.dart` is generated from the ASN.1 modules in
`tools/asn1/`. Regenerate it with:

```bash
python3 tools/asn1_dart_gen.py && dart format lib/models/asn1/rsp_definitions.g.dart
```

No third-party Python packages are required.

## Pipeline

| File | Role |
| --- | --- |
| `asn1/*.asn1` | The specs: SGP.22 (`RSPDefinitions`), TCA eUICC Profile Package (`PEDefinitions`), RFC 5280 (`PKIX1Explicit88`, `PKIX1Implicit88`), plus `Supplementary` |
| `asn1_syntax.py` | X.680 tokenizer + parser → AST |
| `asn1_model.py` | AST → the `TypeDef`/`FieldDef` model, flattening anonymous types |
| `asn1_emit.py` | The `TypeDef`/`FieldDef` model → Dart |
| `asn1_dart_gen.py` | Driver: parse → model → prune → emit |
| `test_asn1_gen.py` | Tests for all of the above (`python3 tools/test_asn1_gen.py`) |
| `asn1_format.py` | Whitespace hygiene for the `.asn1` sources |
| `euicc_probe.py` | Read-only ES10 capture from a card in a PC/SC reader |
| `euicc_exchange.py` | Sends a scripted list of ES10 requests; not read-only |
| `testdata/*.asn1` | Modules the app does not use, kept so the tests catch the generator growing a dependency on the shipped specs |

`Supplementary.asn1` holds types that SGP.22 references but defines elsewhere —
`ExtendedCardResource` (ETSI TS 102 226) and `RefArDo`/`ProprietaryTag`
(GlobalPlatform SEAC). They previously existed only inside a pre-compiled
intermediate, so they could not be regenerated from source.

The generator is a general X.680 tool, not an SGP.22 one: no type, tag or field
name from the shipped specs is special-cased anywhere in it. `tools/testdata/`
holds unrelated modules (RFC 1157 SNMP, plus a grab-bag of constructs the
shipped specs happen not to use) that the test suite generates and compiles, so
that stays true.

## Naming

Anonymous types are flattened and named by their path, so an inline SEQUENCE at
`RpmCommand.rpmCommandDetails.enable` becomes
`RpmCommand_rpmCommandDetails_enable`, and the element of a `SEQUENCE OF` an
inline type gets an `__item_` suffix. Hyphens become underscores. These names
are part of the public API — changing them breaks callers in `lib/`.

## Checking

```bash
python3 tools/asn1_dart_gen.py --check   # is the checked-in Dart up to date?
python3 tools/test_asn1_gen.py           # generator tests
python3 tools/asn1_format.py --check     # are the .asn1 sources tidy?
flutter test test/models/asn1/           # behaviour of the generated code
dart run test/models/asn1/asn1_benchmark.dart   # decode/encode timings
```

`asn1_format.py` only normalises whitespace. It does not reindent: these
modules follow three different house styles, and reindenting by brace depth
flattened the hanging indents in SGP.22 and the comment alignment carried over
from the PKIX RFCs.

`--check` compares declaration by declaration after `dart format`, so pure
layout differences are ignored.

## Corrections to the shipped behaviour

`rsp_definitions.g.dart` used to be produced by a different generator, and the
one here does not reproduce it exactly. Each difference below is a fix, and each
changes bytes on the wire or on decode — worth knowing if you are comparing
against an older build.

- **`DEFAULT` components are optional.** They used to be treated as mandatory
  and decoded positionally, so an absent one shifted every following field.
  Affects 26 components, e.g. `BasicConstraints.cA`,
  `AlgoParameter.rotationConstants`, `StoreMetadataRequest.profileClass`.
- **Automatic tagging follows X.680 12.3.** Tags are assigned only when *no*
  component of a SEQUENCE/SET/CHOICE carries one. Individual untagged
  components used to be tagged even in lists that already had tags, which gave
  `OtherSignedNotification` two `[1]` components and made `EventRecordV3`
  encode `eventId` as `[0]` rather than as UTF8String. Affects those two types.
- **Tagging an untagged CHOICE is explicit** (X.680 30.6 c), so the choice is
  wrapped rather than having its tag overwritten. Affects 17 components, e.g.
  `AlertData.pendingOperationAlert`, `ProfileInfo.deviceChangeConfiguration`.
  Conversely `CancelSessionRequestEs9.cancelSessionResponse` refers to an
  *already tagged* CHOICE and is now implicit, as the standard requires.
- **`SEQUENCE OF <inline type>` elements use the inline type.** The first
  nested definition with a type reference used to be picked instead,
  which silently typed `EuiccConfiguredDataResponse.ciList` as
  `List<SubjectKeyIdentifier>` — dropping the sibling `ciName` field.
  Affects 6 components.
- **`SEQUENCE OF <typedef>` encodes its elements as bytes.** A list of
  `VersionType` (a typedef for `Uint8List`, not a class) was emitted as
  `v.encode()`, which threw `NoSuchMethodError` the moment
  `EUICCInfo2.additionalProfilePackageVersions` was populated.
- **`ENUMERATED` becomes a Dart enum** rather than an opaque `Uint8List`
  typedef. Only `CRLReason` in this spec set, which nothing references.
- **SEQUENCE members are located by tag, not by position.** Previously only
  OPTIONAL members were tag-checked; a mandatory one consumed whatever element
  the cursor happened to be on, so a single absent or unexpected element shifted
  every field after it. Members are now found with a forward search for their
  tag, which also tolerates the unknown elements `EXTENSIBILITY IMPLIED`
  invites. Matching ignores the constructed bit: X.680 requires the members of
  a SEQUENCE to have distinct tag *numbers*, so it cannot be ambiguous, and
  cards do disagree with the schema about it — `EUICCInfo2.extCardResource`
  arrives as a primitive `84` although its content is constructed.
