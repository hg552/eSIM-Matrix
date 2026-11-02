import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/utils/hex_utils.dart';

void main() {
  group('bytesToHex', () {
    test('renders lowercase, zero-padded, without separators', () {
      expect(
        HexUtils.bytesToHex(Uint8List.fromList([0x00, 0x0A, 0xFF, 0x5A])),
        '000aff5a',
      );
    });

    test('handles every byte value', () {
      final all = Uint8List.fromList(List.generate(256, (i) => i));
      final hex = HexUtils.bytesToHex(all);
      expect(hex.length, 512);
      expect(hex.startsWith('000102'), isTrue);
      expect(hex.endsWith('fdfeff'), isTrue);
      // Round-trips.
      expect(HexUtils.hexToBytes(hex), all);
    });

    test('empty input gives an empty string', () {
      expect(HexUtils.bytesToHex(Uint8List(0)), '');
    });
  });

  group('hexToBytes', () {
    test('parses upper and lower case alike', () {
      expect(HexUtils.hexToBytes('bf2e'), HexUtils.hexToBytes('BF2E'));
      expect(HexUtils.hexToBytes('BF2e'), Uint8List.fromList([0xBF, 0x2E]));
    });

    test('ignores spaces', () {
      expect(
        HexUtils.hexToBytes('BF 2E 12 5A'),
        Uint8List.fromList([0xBF, 0x2E, 0x12, 0x5A]),
      );
    });

    test('an odd digit count reads as though left-padded with zero', () {
      expect(HexUtils.hexToBytes('F5A'), Uint8List.fromList([0x0F, 0x5A]));
      expect(HexUtils.hexToBytes('5'), Uint8List.fromList([0x05]));
    });

    test('empty input gives an empty list', () {
      expect(HexUtils.hexToBytes(''), Uint8List(0));
      expect(HexUtils.hexToBytes('   '), Uint8List(0));
    });

    test('rejects a non-hex character rather than dropping it', () {
      // Silently skipping would turn a malformed APDU into a shorter valid one.
      expect(() => HexUtils.hexToBytes('BFZZ'), throwsFormatException);
      expect(() => HexUtils.hexToBytes('BF-2E'), throwsFormatException);
    });

    test('round-trips a realistic APDU', () {
      const apdu = '81e2910006bf3e035c015a';
      expect(HexUtils.bytesToHex(HexUtils.hexToBytes(apdu)), apdu);
    });
  });

  group('swapNibbles', () {
    test('swaps each byte pair', () {
      expect(HexUtils.swapNibbles('9811'), '8911');
      expect(
        HexUtils.swapNibbles('980000000000000030F4'),
        '8900000000000000034F',
      );
    });

    test('is its own inverse', () {
      const stored = '98000000000000000081';
      expect(HexUtils.swapNibbles(HexUtils.swapNibbles(stored)), stored);
    });
  });
}
