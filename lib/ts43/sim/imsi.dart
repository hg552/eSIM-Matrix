import 'identifier.dart';

/// IMSI / EF_AD helpers, ported from `sim/imsi.go`.

class Imsi {
  final String value;
  const Imsi(this.value);

  /// Parses EF_IMSI binary content (length-prefixed swapped BCD).
  factory Imsi.fromBytes(List<int> data) {
    if (data.isEmpty) {
      throw const FormatException('reading EF_IMSI: empty payload');
    }
    final n = data[0];
    if (data.length < n + 1) {
      throw const FormatException('reading EF_IMSI: truncated payload');
    }
    final digits = decodeSwappedBcd(
      data.sublist(1, 1 + n),
      stripLeadingNine: true,
    );
    if (digits.length < 6) {
      throw const FormatException(
        'reading EF_IMSI: decoded payload is too short',
      );
    }
    return Imsi(digits);
  }

  String get mcc {
    if (value.length < 3) {
      throw const FormatException('IMSI is too short for MCC');
    }
    return value.substring(0, 3);
  }

  @override
  String toString() => value;
}

/// Decodes the MNC length from EF_AD content.
int decodeMncLength(List<int> data) {
  if (data.length < 4) {
    throw const FormatException('parsing EF_AD: truncated payload');
  }
  switch (data[3] & 0x0f) {
    case 0x02:
    case 0x03:
      return data[3] & 0x0f;
    case 0x00:
      throw const FormatException('parsing EF_AD: MNC length is unavailable');
    default:
      throw const FormatException('parsing EF_AD: invalid MNC length');
  }
}

/// Extracts the MNC substring from the IMSI given the MNC length.
String formatMnc(String imsi, int n) {
  if (imsi.length < 3 + n) {
    throw const FormatException('IMSI is too short for MNC length');
  }
  switch (n) {
    case 2:
      return imsi.substring(3, 5);
    case 3:
      return imsi.substring(3, 6);
    default:
      throw FormatException('unsupported MNC length $n');
  }
}
