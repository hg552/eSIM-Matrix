import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/models/asn1/rsp_definitions.g.dart';
import 'package:nlpa2/utils/hex_utils.dart';

void main() {
  test('CancelSessionRequest encodes as SGP.22 BF41', () {
    final request = CancelSessionRequest(
      transactionId: Uint8List.fromList([0x01, 0x02, 0x03, 0x04]),
      reason: CancelSessionReason.endUserRejection,
    );

    // BF41 <len> 80 <transactionId> 81 01 <reason>
    expect(
      HexUtils.bytesToHex(request.encode()).toUpperCase(),
      'BF4109800401020304810100',
    );
  });

  test('rejecting a previewed profile reports endUserRejection', () {
    expect(CancelSessionReason.endUserRejection.value, 0);
  });

  test('CancelSessionRequest round-trips through the decoder', () {
    final transactionId = Uint8List.fromList([0xAA, 0xBB, 0xCC]);
    final encoded = CancelSessionRequest(
      transactionId: transactionId,
      reason: CancelSessionReason.timeout,
    ).encode();

    final decoded = CancelSessionRequest.decode(encoded);

    expect(decoded.transactionId, transactionId);
    expect(decoded.reason, CancelSessionReason.timeout);
  });
}
