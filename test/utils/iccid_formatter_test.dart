import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/utils/hex_utils.dart';
import 'package:nlpa2/utils/iccid_formatter.dart';

void main() {
  group('IccidFormatter', () {
    test('removes trailing filler nibbles', () {
      expect(
        IccidFormatter.forDisplay('8988211000000000000F'),
        '8988211000000000000',
      );
      expect(
        IccidFormatter.forDisplay('8988211000000000000fff'),
        '8988211000000000000',
      );
    });

    test('preserves an F that is not trailing filler', () {
      // An F can genuinely occur inside an ICCID, so only the tail is filler.
      expect(
        IccidFormatter.forDisplay('8988F211000000000000'),
        '8988F211000000000000',
      );
      expect(
        IccidFormatter.forDisplay('8988F21100000000000F'),
        '8988F21100000000000',
      );
    });

    test('leaves a full-length ICCID alone', () {
      expect(
        IccidFormatter.forDisplay('8900000000000000034'),
        '8900000000000000034',
      );
    });

    test('handles an empty string', () {
      expect(IccidFormatter.forDisplay(''), '');
    });
  });

  group('ICCID byte order', () {
    // ICCIDs are stored nibble-swapped on the card, so the bytes read out of
    // ProfileInfo are not the printed number. This pair is a real profile:
    // stored form on the left, printed form on the right.
    const stored = '980000000000000030F4';
    const printed = '8900000000000000034';

    test('swap then strip gives the printed number', () {
      expect(IccidFormatter.forDisplay(HexUtils.swapNibbles(stored)), printed);
    });

    test('stripping before swapping leaves the filler in the output', () {
      // Why the order matters: in the stored form the filler is second from
      // last, so there is no trailing F to match and the strip does nothing.
      // Swapping afterwards moves it to the end, where it is now too late to
      // be removed.
      expect(stored.indexOf('F'), stored.length - 2);
      expect(IccidFormatter.forDisplay(stored), stored);
      // What you get is the right digits with the filler still attached.
      expect(
        HexUtils.swapNibbles(IccidFormatter.forDisplay(stored)),
        '${printed}F',
      );
      expect(
        HexUtils.swapNibbles(IccidFormatter.forDisplay(stored)),
        isNot(printed),
      );
    });

    test('the filler only reaches the end after swapping', () {
      expect(HexUtils.swapNibbles(stored).indexOf('F'), stored.length - 1);
    });

    test('swapping is its own inverse', () {
      expect(HexUtils.swapNibbles(HexUtils.swapNibbles(stored)), stored);
    });

    test('an even-length ICCID needs no filler at all', () {
      const evenStored = '98000000000000000081';
      expect(evenStored.contains('F'), isFalse);
      expect(
        IccidFormatter.forDisplay(HexUtils.swapNibbles(evenStored)),
        '89000000000000000018',
      );
    });
  });
}
