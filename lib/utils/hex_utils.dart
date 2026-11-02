import 'dart:typed_data';

class HexUtils {
  static const String _lowerHex = '0123456789abcdef';

  /// Lowercase hex, no separators.
  ///
  /// Written a nibble at a time into one buffer rather than mapping each byte
  /// to its own String: this runs on every APDU in both directions, and a
  /// bound profile package is tens of kilobytes of it.
  static String bytesToHex(Uint8List bytes) {
    final out = Uint8List(bytes.length * 2);
    var i = 0;
    for (final byte in bytes) {
      out[i++] = _lowerHex.codeUnitAt((byte >> 4) & 0x0F);
      out[i++] = _lowerHex.codeUnitAt(byte & 0x0F);
    }
    return String.fromCharCodes(out);
  }

  /// Parses hex, ignoring spaces. An odd number of digits is read as though
  /// the string were left-padded with a zero.
  ///
  /// Throws [FormatException] on any other character, so a malformed APDU
  /// surfaces rather than silently decoding to something shorter.
  static Uint8List hexToBytes(String hex) {
    final codes = hex.codeUnits;
    final nibbles = Uint8List(codes.length);
    var count = 0;
    for (final code in codes) {
      if (code == 0x20) continue; // space
      final value = _nibbleOf(code);
      if (value < 0) {
        throw FormatException('not a hex digit', hex, codes.indexOf(code));
      }
      nibbles[count++] = value;
    }

    final result = Uint8List((count + 1) ~/ 2);
    var read = 0;
    var write = 0;
    if (count.isOdd) {
      result[write++] = nibbles[read++]; // the implied leading zero
    }
    while (read < count) {
      result[write++] = (nibbles[read] << 4) | nibbles[read + 1];
      read += 2;
    }
    return result;
  }

  static int _nibbleOf(int code) {
    if (code >= 0x30 && code <= 0x39) return code - 0x30; // 0-9
    if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10; // a-f
    if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10; // A-F
    return -1;
  }

  static String swapNibbles(String input) {
    final buffer = StringBuffer();
    // Ensure even length for safe swapping
    if (input.length % 2 != 0) input = 'F$input';

    for (int i = 0; i < input.length; i += 2) {
      if (i + 1 < input.length) {
        buffer.write(input[i + 1]);
        buffer.write(input[i]);
      } else {
        buffer.write(input[i]);
      }
    }
    return buffer.toString();
  }
}
