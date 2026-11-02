import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/models/asn1/simple_reader.dart';

import 'asn1_hex.dart';

/// Behavioural tests for the hand-written TLV reader that the generated
/// SGP.22 model code is built on (`lib/models/asn1/simple_reader.dart`).
///
/// These pin *observable* behaviour only: tag values, value bytes, child
/// splitting and `encodedBytes`. Several deliberate quirks of the current
/// implementation are pinned too (and flagged with BUG/QUIRK comments) so a
/// rewritten generator can be proven behaviourally identical.
void main() {
  group('SimpleAsn1Reader single-byte tags', () {
    test('reads tag, value and the exact source bytes of one TLV', () {
      // OCTET STRING (universal 4), 3 bytes of content.
      final node = SimpleAsn1Reader(fromHex('04 03 AABBCC')).readNext()!;

      expect(node.tag, 0x04);
      expect(toHex(node.value), 'AABBCC');
      expect(toHex(node.encodedBytes), '0403AABBCC');
      expect(node.isTag(0x04), isTrue);
      expect(node.isTag(0x05), isFalse);
    });

    test('walks consecutive TLVs until hasMore goes false', () {
      final reader = SimpleAsn1Reader(fromHex('800101 810102 820103'));

      final tags = <int>[];
      while (reader.hasMore) {
        tags.add(reader.readNext()!.tag);
      }

      expect(tags, [0x80, 0x81, 0x82]);
      expect(reader.readNext(), isNull);
    });

    test('returns null for empty input', () {
      expect(SimpleAsn1Reader(Uint8List(0)).readNext(), isNull);
      expect(SimpleAsn1Reader(Uint8List(0)).hasMore, isFalse);
    });

    test('reads a zero-length value', () {
      // GetEuiccChallengeRequest on the wire: BF2E 00.
      final node = SimpleAsn1Reader(fromHex('BF2E00')).readNext()!;

      expect(node.tag, 0xBF2E);
      expect(node.value, isEmpty);
      expect(toHex(node.encodedBytes), 'BF2E00');
    });
  });

  group('SimpleAsn1Reader multi-byte tags', () {
    // SGP.22 uses high-tag-number form all over the place; the reader folds
    // the tag octets into a single int, big-endian, e.g. 'BF 2D' -> 0xBF2D.
    test('folds two-byte context tags into one int', () {
      expect(SimpleAsn1Reader(fromHex('BF2E00')).readNext()!.tag, 0xBF2E);
      expect(SimpleAsn1Reader(fromHex('BF2D00')).readNext()!.tag, 0xBF2D);
      expect(SimpleAsn1Reader(fromHex('BF2200')).readNext()!.tag, 0xBF22);
      expect(SimpleAsn1Reader(fromHex('BF2F00')).readNext()!.tag, 0xBF2F);
      expect(SimpleAsn1Reader(fromHex('BF3700')).readNext()!.tag, 0xBF37);
    });

    test('handles the ProfileInfo private/context tags 9F70, 9F24, 9F25', () {
      expect(SimpleAsn1Reader(fromHex('9F70 01 01')).readNext()!.tag, 0x9F70);
      expect(SimpleAsn1Reader(fromHex('9F24 01 00')).readNext()!.tag, 0x9F24);
      expect(SimpleAsn1Reader(fromHex('9F25 01 05')).readNext()!.tag, 0x9F25);
    });

    test('handles the application tag 5F37 (EuiccSign)', () {
      final node = SimpleAsn1Reader(fromHex('5F37 02 ABCD')).readNext()!;
      expect(node.tag, 0x5F37);
      expect(toHex(node.value), 'ABCD');
    });

    test('keeps consuming tag octets while the continuation bit is set', () {
      // 'BF 81 2E' is a three-octet tag; the reader folds all three.
      final node = SimpleAsn1Reader(fromHex('BF812E 00')).readNext()!;
      expect(node.tag, 0xBF812E);
    });

    test('a multi-byte tag does not confuse the following TLV', () {
      final reader = SimpleAsn1Reader(fromHex('9F70 01 01 90 02 4142'));
      expect(reader.readNext()!.tag, 0x9F70);
      final second = reader.readNext()!;
      expect(second.tag, 0x90);
      expect(toHex(second.value), '4142');
      expect(reader.hasMore, isFalse);
    });
  });

  group('SimpleAsn1Reader length forms', () {
    test('reads short-form lengths', () {
      final node = SimpleAsn1Reader(fromHex('04 7F ${'00' * 127}')).readNext()!;
      expect(node.value.length, 127);
    });

    test('reads one-octet long-form lengths (0x81 nn)', () {
      final node = SimpleAsn1Reader(
        fromHex('04 81 C8 ${'00' * 200}'),
      ).readNext()!;
      expect(node.value.length, 200);
    });

    test('reads two-octet long-form lengths (0x82 nn nn)', () {
      final node = SimpleAsn1Reader(
        fromHex('04 82 0100 ${'00' * 256}'),
      ).readNext()!;
      expect(node.value.length, 256);
    });

    test('clamps a truncated value instead of throwing', () {
      // Declares 10 bytes but only 3 are present.
      final node = SimpleAsn1Reader(fromHex('04 0A AABBCC')).readNext()!;
      expect(toHex(node.value), 'AABBCC');
      expect(toHex(node.encodedBytes), '040AAABBCC');
    });

    test('indefinite length (0x80) yields an empty value', () {
      // QUIRK: indefinite length is not supported; the reader returns an empty
      // value and stops rather than scanning for the 00 00 terminator.
      final node = SimpleAsn1Reader(fromHex('30 80 040100 0000')).readNext()!;
      expect(node.tag, 0x30);
      expect(node.value, isEmpty);
    });

    test('returns null when the length octets themselves are truncated', () {
      expect(SimpleAsn1Reader(fromHex('04')).readNext(), isNull);
      expect(SimpleAsn1Reader(fromHex('04 82 01')).readNext(), isNull);
    });
  });

  group('Asn1Node.children', () {
    test('splits a constructed value into child TLVs', () {
      // ProfileInfoListResponse-ish: A0 wrapping two E3 elements.
      final node = SimpleAsn1Reader(
        fromHex('A0 0A E3 02 5A00 E3 04 5A02 AABB'),
      ).readNext()!;

      final children = node.children;
      expect(children.length, 2);
      expect(children[0].tag, 0xE3);
      expect(children[1].tag, 0xE3);
      expect(toHex(children[1].children.single.value), 'AABB');
    });

    test('children of a primitive value are best-effort, not empty', () {
      // QUIRK: `children` re-parses whatever bytes are in `value`; it does not
      // check the constructed bit first. An OCTET STRING whose content happens
      // to look like a TLV therefore yields "children".
      final node = SimpleAsn1Reader(fromHex('04 03 040100')).readNext()!;
      expect(node.children.length, 1);
      expect(node.children.single.tag, 0x04);
    });

    test('children is empty for an empty value', () {
      final node = SimpleAsn1Reader(fromHex('30 00')).readNext()!;
      expect(node.children, isEmpty);
    });

    test('each child keeps its own exact source bytes', () {
      final node = SimpleAsn1Reader(fromHex('30 06 800101 810102')).readNext()!;
      expect(toHex(node.children[0].encodedBytes), '800101');
      expect(toHex(node.children[1].encodedBytes), '810102');
    });
  });

  group('Asn1Node.encodedBytes without source bytes', () {
    test('re-encodes a single-byte tag with a short-form length', () {
      final node = Asn1Node(0x80, fromHex('AABBCC'));
      expect(toHex(node.encodedBytes), '8003AABBCC');
    });

    test('re-encodes with a long-form length past 127 bytes', () {
      final node = Asn1Node(0x04, Uint8List(200));
      final encoded = node.encodedBytes;
      expect(toHex(encoded.sublist(0, 3)), '0481C8');
      expect(encoded.length, 3 + 200);
    });

    test('BUG: re-encoding a multi-byte tag emits base-128 tag octets', () {
      // `Asn1Node._encodeTag` uses the BER high-tag-number 7-bit continuation
      // scheme on the *already folded* tag integer, so 0xBF2E round-trips to
      // 82 FE 2E instead of BF 2E. The generated model code never hits this
      // path (it has its own byte-oriented `_tagBytes`, and nodes produced by
      // the reader carry their original bytes), but the behaviour is pinned
      // here because it is observable.
      final node = Asn1Node(0xBF2E, fromHex('AA'));
      expect(toHex(node.encodedBytes), '82FE2E01AA');
      expect(toHex(node.encodedBytes).startsWith('BF2E'), isFalse);

      // 0x9F70 is mangled the same way (82 BE 70 instead of 9F 70).
      expect(toHex(Asn1Node(0x9F70, fromHex('01')).encodedBytes), '82BE700101');
    });

    test('a node from the reader returns the original bytes verbatim', () {
      // This is what makes the generated `encode()` byte-perfect: it hands back
      // `asn1.encodedBytes`, which is the untouched source slice - including a
      // non-minimal length encoding.
      final node = SimpleAsn1Reader(fromHex('04 81 03 AABBCC')).readNext()!;
      expect(toHex(node.encodedBytes), '048103AABBCC');
    });
  });

  group('Asn1Node.prettyPrint', () {
    test('labels known universal tags and renders nested structure', () {
      final node = SimpleAsn1Reader(
        fromHex('30 07 020101 04024142'),
      ).readNext()!;
      final text = node.prettyPrint();

      expect(text, contains('SEQUENCE (0x30)'));
      expect(text, contains('INTEGER (0x2)'));
      expect(text, contains('OCTET STRING (0x4)'));
      expect(text, contains('"AB"')); // 41 42 renders as printable text
      expect(node.toString(), text);
    });

    test('labels context/private tags by class', () {
      final node = SimpleAsn1Reader(fromHex('BF2E 02 AABB')).readNext()!;
      expect(node.prettyPrint(), contains('[Context 0xBF2E]'));

      final priv = SimpleAsn1Reader(fromHex('E3 02 AABB')).readNext()!;
      expect(priv.prettyPrint(), contains('[Private 0xE3]'));
    });

    test('marks an empty primitive value as [Empty]', () {
      expect(
        SimpleAsn1Reader(fromHex('8000')).readNext()!.prettyPrint(),
        contains('[Empty]'),
      );
    });

    test('renders an empty constructed value as an empty block', () {
      // QUIRK: a zero-length *constructed* node (e.g. GetEuiccChallengeRequest
      // 'BF2E 00') is not labelled [Empty]; it prints as an empty child block.
      final text = SimpleAsn1Reader(
        fromHex('BF2E00'),
      ).readNext()!.prettyPrint();
      expect(text, contains('(0 bytes) {'));
      expect(text, isNot(contains('[Empty]')));
    });

    test('truncates long hex dumps', () {
      final node = SimpleAsn1Reader(
        fromHex('04 81 C8 ${'AB' * 200}'),
      ).readNext()!;
      final text = node.prettyPrint();
      expect(text, contains('[200 bytes]'));
      expect(text, contains('...'));
    });

    test('indents nested nodes by two spaces per level', () {
      final node = SimpleAsn1Reader(fromHex('30 04 04024142')).readNext()!;
      expect(node.prettyPrint(), contains('\n  OCTET STRING'));
    });
  });
}
