import 'dart:typed_data';

/// Parses a hex string into bytes. Whitespace is ignored so that fixtures can
/// be laid out one TLV per line.
Uint8List fromHex(String hex) {
  final cleaned = hex.replaceAll(RegExp(r'\s'), '');
  if (cleaned.length.isOdd) {
    throw ArgumentError.value(hex, 'hex', 'odd number of hex digits');
  }
  final out = Uint8List(cleaned.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Renders bytes as an upper-case hex string (no separators).
String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

/// Normalises a fixture literal so it can be compared against [toHex] output.
String normHex(String hex) => hex.replaceAll(RegExp(r'\s'), '').toUpperCase();
