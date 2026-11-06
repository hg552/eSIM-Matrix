import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:logging/logging.dart';

class CryptoUtils {
  static final Logger _log = Logger('CryptoUtils');

  /// HashCc = SHA256 (SHA256 (Confirmation Code) | TransactionID)
  ///
  /// [transactionId] must be the octets, never the hex text the SM-DP+ sends
  /// over ES9+ — hashing that text produces a value the server rejects while
  /// consuming one of the few confirmation-code attempts an order allows.
  /// ProfileDownloadSession decodes it at the boundary so callers hold octets.
  static Uint8List computeHashCc(
    String confirmationCode,
    Uint8List transactionId,
  ) {
    // SGP.22: TransactionId ::= OCTET STRING (SIZE(1..16))
    if (transactionId.isEmpty || transactionId.length > 16) {
      _log.warning(
        "TransactionID is ${transactionId.length} bytes, outside the 1..16 "
        "octets SGP.22 allows; hashCc will not match the server's.",
      );
    }

    // 1. SHA256 of CC (UTF-8 encoded)
    final ccBytes = utf8.encode(confirmationCode);
    final firstHash = sha256.convert(ccBytes).bytes;

    // 2. Concatenate firstHash (32 bytes) and the transaction id
    final combined = Uint8List(firstHash.length + transactionId.length);
    combined.setAll(0, firstHash);
    combined.setAll(firstHash.length, transactionId);

    // 3. Final SHA256
    final finalHash = sha256.convert(combined).bytes;

    return Uint8List.fromList(finalHash);
  }

  /// Generate AES key from password using SHA256
  static Uint8List keyFromPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return Uint8List.fromList(digest.bytes);
  }

  /// Encrypt JSON data using AES-256-CBC
  /// Returns base64(iv + ciphertext)
  static String encryptAES(String plaintext, String password) {
    final key = keyFromPassword(password);
    return encryptAESWithKey(plaintext, key);
  }

  static String encryptAESWithKey(String plaintext, Uint8List key) {
    try {
      final iv = Uint8List(16);
      final random = Random.secure();
      for (var i = 0; i < 16; i++) {
        iv[i] = random.nextInt(256);
      }

      final params = PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(key), iv),
        null,
      );

      final cipher = PaddedBlockCipher('AES/CBC/PKCS7');
      cipher.init(true, params);

      final input = Uint8List.fromList(utf8.encode(plaintext));
      final encrypted = cipher.process(input);

      final combined = Uint8List(iv.length + encrypted.length);
      combined.setAll(0, iv);
      combined.setAll(iv.length, encrypted);

      return base64Encode(combined);
    } catch (e) {
      throw Exception('Encryption failed: $e');
    }
  }

  /// Decrypt JSON data using AES-256-CBC
  /// Expects base64(iv + ciphertext)
  static String decryptAES(String ciphertext, String password) {
    final key = keyFromPassword(password);
    return decryptAESWithKey(ciphertext, key);
  }

  static String decryptAESWithKey(String ciphertext, Uint8List key) {
    try {
      final combined = base64Decode(ciphertext);
      final iv = combined.sublist(0, 16);
      final encrypted = combined.sublist(16);

      final params = PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(key), iv),
        null,
      );

      final cipher = PaddedBlockCipher('AES/CBC/PKCS7');
      cipher.init(false, params);

      final decrypted = cipher.process(encrypted);
      return utf8.decode(decrypted);
    } catch (e) {
      throw Exception('Decryption failed: $e');
    }
  }

  /// Constant-time comparison between two strings to mitigate timing attacks.
  /// Uses bitwise XOR accumulation across all code units. If lengths differ,
  /// dummy constant-time XOR is still computed over the reference length to
  /// reduce execution time divergence.
  static bool fixedTimeEquals(String left, String right) {
    if (left.length != right.length) {
      var dummy = 0;
      for (var index = 0; index < right.length; index++) {
        dummy |= right.codeUnitAt(index) ^ right.codeUnitAt(index);
      }
      return dummy != 0;
    }
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }

  /// Constant-time comparison between two byte lists to mitigate timing attacks.
  static bool fixedTimeEqualsBytes(List<int> left, List<int> right) {
    if (left.length != right.length) {
      var dummy = 0;
      for (var index = 0; index < right.length; index++) {
        dummy |= right[index] ^ right[index];
      }
      return dummy != 0;
    }
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
