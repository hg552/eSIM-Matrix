import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/models/asn1/rsp_definitions.g.dart';
import 'package:nlpa2/utils/hex_utils.dart';

/// The `resetOptions` value builder mirrored from ProfileManager, kept here so
/// the encoding it feeds [EuiccMemoryResetRequest] is pinned by a test.
int resetOptionsValue({
  required bool deleteOperationalProfiles,
  required bool deleteFieldLoadedTestProfiles,
  required bool resetDefaultSmdpAddress,
}) {
  var bits = 0;
  if (deleteOperationalProfiles) bits |= 0x80;
  if (deleteFieldLoadedTestProfiles) bits |= 0x40;
  if (resetDefaultSmdpAddress) bits |= 0x20;
  if (bits == 0) return 0;
  var unusedBits = 0;
  while (unusedBits < 8 && (bits & (1 << unusedBits)) == 0) {
    unusedBits++;
  }
  return (unusedBits << 8) | bits;
}

void main() {
  group('EuiccMemoryResetRequest', () {
    test('purge encodes byte-for-byte as lpac chip purge', () {
      // lpac euicc/es10c.c: tag 0x82, length 2, value {0x05, 0xE0}.
      final options = resetOptionsValue(
        deleteOperationalProfiles: true,
        deleteFieldLoadedTestProfiles: true,
        resetDefaultSmdpAddress: true,
      );
      final encoded = EuiccMemoryResetRequest(resetOptions: options).encode();
      expect(HexUtils.bytesToHex(encoded).toUpperCase(), 'BF3404820205E0');
    });

    test('the named-bit constants would encode a BIT STRING with no data', () {
      // Why the mask is not passed straight through: bit 0 as 1<<0 collapses
      // to a single octet that the card reads as an unused-bit count.
      final wrong = EuiccMemoryResetRequest(
        resetOptions:
            EuiccMemoryResetRequest_resetOptions.deleteOperationalProfiles |
            EuiccMemoryResetRequest_resetOptions.deleteFieldLoadedTestProfiles |
            EuiccMemoryResetRequest_resetOptions.resetDefaultSmdpAddress,
      ).encode();
      expect(HexUtils.bytesToHex(wrong).toUpperCase(), 'BF3403820107');
    });

    test('a single option still carries its unused-bit count', () {
      final options = resetOptionsValue(
        deleteOperationalProfiles: true,
        deleteFieldLoadedTestProfiles: false,
        resetDefaultSmdpAddress: false,
      );
      final encoded = EuiccMemoryResetRequest(resetOptions: options).encode();
      expect(HexUtils.bytesToHex(encoded).toUpperCase(), 'BF340482020780');
    });
  });
}
