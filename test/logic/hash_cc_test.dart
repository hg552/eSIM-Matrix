import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/logic/profile_download_session.dart';
import 'package:nlpa2/utils/crypto_utils.dart';
import 'package:nlpa2/utils/hex_utils.dart';

/// HashCc as SGP.22 defines it, computed independently of the implementation:
/// SHA256(SHA256(CC) | TransactionID-octets).
Uint8List expectedHashCc(String cc, Uint8List transactionIdOctets) {
  final firstHash = sha256.convert(utf8.encode(cc)).bytes;
  return Uint8List.fromList(
    sha256.convert([...firstHash, ...transactionIdOctets]).bytes,
  );
}

ProfileDownloadSession sessionWithTransactionId(String hex) {
  return ProfileDownloadSession(smdpAddress: 'smdp.example.com')
    ..processInitiateAuthenticationResponse(
      'Executed-Success',
      hex,
      Uint8List(0),
    );
}

void main() {
  test('hashCc is computed over the transaction id octets', () {
    const hex = '0123456789abcdef0123456789abcdef'; // 16 octets
    final session = sessionWithTransactionId(hex);

    expect(
      CryptoUtils.computeHashCc('1234', session.getTransactionId()!),
      expectedHashCc('1234', HexUtils.hexToBytes(hex)),
    );
  });

  test('an 8 octet transaction id is not hashed as its hex text', () {
    // The regression: a 16-character hex id decodes to 8 octets, so the old
    // "is it 32 ASCII characters?" rescue never fired and the hex text itself
    // was hashed, burning a confirmation-code attempt on a correct code.
    const hex = '0123456789abcdef'; // 8 octets
    final session = sessionWithTransactionId(hex);
    final octets = session.getTransactionId()!;

    expect(octets, hasLength(8));
    expect(
      CryptoUtils.computeHashCc('1234', octets),
      expectedHashCc('1234', HexUtils.hexToBytes(hex)),
    );
    expect(
      CryptoUtils.computeHashCc('1234', octets),
      isNot(expectedHashCc('1234', Uint8List.fromList(utf8.encode(hex)))),
    );
  });

  test('the session keeps the server spelling for ES9+ bodies', () {
    // bytesToHex is lowercase-only, so re-encoding would silently rewrite an
    // uppercase id that the SM-DP+ may compare verbatim.
    const hex = '0123456789ABCDEF0123456789ABCDEF';
    final session = sessionWithTransactionId(hex);

    expect(session.getTransactionIdHex(), hex);
    expect(session.getTransactionId(), HexUtils.hexToBytes(hex));
  });
}
