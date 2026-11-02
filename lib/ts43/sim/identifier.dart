import 'dart:typed_data';

/// Swapped GSM BCD encode/decode helpers, ported from
/// `github.com/damonto/ts43-go/sim/identifier.go`.

/// Encodes a decimal/hex string as swapped GSM BCD.
Uint8List encodeBcd(String value) {
  for (final r in value.codeUnits) {
    final isDigit = r >= 0x30 && r <= 0x39;
    final isUpper = r >= 0x41 && r <= 0x46;
    final isLower = r >= 0x61 && r <= 0x66;
    if (!isDigit && !isUpper && !isLower) {
      throw const FormatException('invalid BCD value');
    }
  }
  if (value.length % 2 != 0) {
    value += 'F';
  }
  final out = Uint8List(value.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = int.parse(value[i * 2], radix: 16);
    final lo = int.parse(value[i * 2 + 1], radix: 16);
    // Swap nibbles (GSM BCD stores least significant nibble first).
    out[i] = ((lo << 4) & 0xF0) | (hi & 0x0F);
  }
  return out;
}

/// Decodes swapped GSM BCD bytes to a decimal string, trimming the trailing
/// 'f' padding nibble if present.
String decodeBcd(List<int> value) {
  final sb = StringBuffer();
  for (final b in value) {
    final hi = (b >> 4) & 0x0F;
    final lo = b & 0x0F;
    // Swapped order: low nibble is the first digit.
    sb.write(lo.toRadixString(16));
    sb.write(hi.toRadixString(16));
  }
  var out = sb.toString();
  final index = out.lastIndexOf('f');
  if (index != -1) {
    out = out.substring(0, index);
  }
  return out;
}

/// Decodes swapped BCD, optionally stripping a leading '9' (used for EF_ICCID).
String decodeSwappedBcd(List<int> data, {bool stripLeadingNine = false}) {
  var out = decodeBcd(data);
  if (stripLeadingNine && out.startsWith('9')) {
    out = out.substring(1);
  }
  return out;
}

/// Renders an EF_GID value as an upper-case hex string with 0xFF padding
/// trimmed from the right.
String groupIdentifierString(List<int> data) {
  var end = data.length;
  while (end > 0 && data[end - 1] == 0xff) {
    end--;
  }
  if (end == 0) return '';
  final sb = StringBuffer();
  for (var i = 0; i < end; i++) {
    sb.write(data[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString().toUpperCase();
}
