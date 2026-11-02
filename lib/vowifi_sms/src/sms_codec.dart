import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

class SmsCodec {
  static VowifiSmsMessage decode(String contentType, List<int> body) {
    final lower = contentType.toLowerCase();
    if (lower.contains('message/cpim')) {
      final cpim = _parseCpim(body);
      if (cpim != null) {
        return decode(cpim.contentType, cpim.payload);
      }
    }
    if (lower.contains('application/vnd.3gpp.sms')) {
      try {
        if (body.isNotEmpty && (body.first & 0x07) == 0x01) {
          final tpdu = _extractTpduFromRpdu(body);
          if (tpdu != null) {
            return _decodeTpdu(tpdu);
          }
        }
        return _decodeRpdu(body);
      } catch (_) {
        try {
          return _decodeTpdu(body);
        } catch (_) {
          return _systemMessage(
            'SMS-RPDU hex:${_hex(body).toUpperCase()}',
            body,
          );
        }
      }
    }
    try {
      return _decodeTpdu(body);
    } catch (_) {
      return _systemMessage('SMS-TPDU hex:${_hex(body).toUpperCase()}', body);
    }
  }

  static List<int>? buildRpAck(List<int> body) {
    if (body.length < 2) {
      return null;
    }
    if ((body[0] & 0x07) != 0x01) {
      return null;
    }
    return <int>[0x02, body[1], 0x41, 0x02, 0x00, 0x00];
  }

  static List<int> encodeSubmitRpdu(
    String smsc,
    String to,
    String text,
    int mr,
  ) {
    final rpAddress = _encodeRpAddress(smsc);
    final address = _encodeAddressSemiOctet(to);
    final packedGsm7 = _tryPackGsm7(text);
    final int dcs;
    final int udl;
    final List<int> userData;
    if (packedGsm7 != null) {
      if (packedGsm7.septets > 160) {
        throw ArgumentError(
          'Text too long for single SMS: ${packedGsm7.septets}',
        );
      }
      dcs = 0x00;
      udl = packedGsm7.septets;
      userData = packedGsm7.bytes;
    } else {
      final ucs2 = _encodeUcs2(text);
      if (ucs2.length > 140) {
        throw ArgumentError(
          'Text too long for single UCS2 SMS: ${ucs2.length ~/ 2}',
        );
      }
      dcs = 0x08;
      udl = ucs2.length;
      userData = ucs2;
    }

    final tpdu = <int>[
      0x21,
      mr & 0xFF,
      address.digits,
      0x91,
      ...address.bytes,
      0x00,
      dcs,
      udl,
      ...userData,
    ];

    return <int>[0x00, mr & 0xFF, 0x00, ...rpAddress, tpdu.length, ...tpdu];
  }

  static VowifiSmsMessage _decodeRpdu(List<int> raw) {
    if (raw.length < 2) {
      throw FormatException('Short RPDU');
    }
    switch (raw[0] & 0x07) {
      case 0x01:
        final tpdu = _extractTpduFromRpdu(raw);
        if (tpdu == null) {
          throw FormatException('Invalid RPDU');
        }
        return _decodeTpdu(tpdu);
      case 0x03:
        var index = 2;
        while (index + 2 <= raw.length) {
          final iei = raw[index++];
          final length = raw[index++];
          if (index + length > raw.length) {
            break;
          }
          final value = raw.sublist(index, index + length);
          index += length;
          if (iei == 0x41 && value.isNotEmpty) {
            try {
              return _decodeTpdu(value);
            } catch (_) {
              return _systemMessage(
                'SMS-RP-ACK hex:${_hex(raw).toUpperCase()}',
                raw,
              );
            }
          }
        }
        return _systemMessage('SMS-RP-ACK', raw);
      case 0x05:
        return _systemMessage(
          'SMS-RP-ERROR hex:${_hex(raw).toUpperCase()}',
          raw,
        );
      default:
        return _systemMessage(
          'SMS-RP-MTI-${raw[0] & 0x07} hex:${_hex(raw).toUpperCase()}',
          raw,
        );
    }
  }

  static VowifiSmsMessage _decodeTpdu(List<int> raw) {
    if (raw.length < 2) {
      throw FormatException('Short TPDU');
    }
    final first = raw[0];
    final mti = first & 0x03;
    final udhi = (first & 0x40) != 0;
    if (mti != 0) {
      if (mti == 1) {
        return _decodeSubmitReport(raw);
      }
      if (mti == 2) {
        return _decodeStatusReport(raw);
      }
      return _systemMessage(
        'TPDU-MTI-$mti hex:${_hex(raw).toUpperCase()}',
        raw,
      );
    }

    var index = 1;
    if (index + 1 >= raw.length) {
      return _systemMessage('TPDU short hex:${_hex(raw).toUpperCase()}', raw);
    }
    final addressLength = raw[index++];
    final toa = raw[index++];
    final addressBytes = (addressLength + 1) ~/ 2;
    if (index + addressBytes > raw.length) {
      return _systemMessage(
        'TPDU short origin hex:${_hex(raw).toUpperCase()}',
        raw,
      );
    }
    final from = _decodeSemiOctetAddress(
      raw.sublist(index, index + addressBytes),
      addressLength,
      toa: toa,
    );
    index += addressBytes;
    if (index >= raw.length) {
      return _systemMessage(
        'TPDU short pid hex:${_hex(raw).toUpperCase()}',
        raw,
      );
    }
    index++;
    if (index >= raw.length) {
      return _systemMessage(
        'TPDU short dcs hex:${_hex(raw).toUpperCase()}',
        raw,
      );
    }
    final dcs = raw[index++];
    if (index + 7 > raw.length) {
      return _systemMessage(
        'TPDU short scts hex:${_hex(raw).toUpperCase()}',
        raw,
      );
    }
    final timestamp = _decodeTimestamp(raw.sublist(index, index + 7));
    index += 7;
    if (index >= raw.length) {
      return _systemMessage(
        'TPDU short udl hex:${_hex(raw).toUpperCase()}',
        raw,
      );
    }
    final udl = raw[index++];
    final userData = raw.sublist(index);
    final text = _decodeUserData(dcs, udl, userData, udhi);
    return VowifiSmsMessage(
      direction: VowifiSmsDirection.inbound,
      peer: from,
      timestamp: timestamp,
      text: text,
      raw: List<int>.from(raw),
    );
  }

  static VowifiSmsMessage _decodeSubmitReport(List<int> raw) {
    final accepted = raw.length >= 2 && raw[1] == 0x00;
    final status = accepted
        ? 'accepted'
        : 'failure-fcs=0x${raw[1].toRadixString(16).padLeft(2, '0').toUpperCase()}';
    return _systemMessage('SMS-SUBMIT-REPORT $status', raw);
  }

  static VowifiSmsMessage _decodeStatusReport(List<int> raw) {
    if (raw.length < 3) {
      return _systemMessage('SMS-STATUS-REPORT short', raw);
    }
    var index = 1;
    final mr = raw[index++];
    final digits = raw[index++];
    final toa = raw[index++];
    final addressBytes = (digits + 1) ~/ 2;
    final recipient = _decodeSemiOctetAddress(
      raw.sublist(index, index + addressBytes),
      digits,
      toa: toa,
    );
    index += addressBytes;
    if (index + 14 > raw.length) {
      return _systemMessage('SMS-STATUS-REPORT mr=$mr to=$recipient', raw);
    }
    final scts = _decodeTimestamp(raw.sublist(index, index + 7));
    index += 7;
    final dt = _decodeTimestamp(raw.sublist(index, index + 7));
    index += 7;
    final st = index < raw.length ? raw[index] : 0xFF;
    final status = switch (st) {
      0x00 => 'delivered',
      < 0x20 => 'temporary-congestion',
      < 0x40 => 'temporary-failure',
      < 0x60 => 'permanent-failure',
      _ => 'service-rejected',
    };
    return _systemMessage(
      'SMS-STATUS-REPORT mr=$mr to=$recipient status=$status st=0x${st.toRadixString(16).padLeft(2, '0').toUpperCase()} scts=${scts.toIso8601String()} dt=${dt.toIso8601String()}',
      raw,
    );
  }

  static VowifiSmsMessage _systemMessage(String text, List<int> raw) {
    return VowifiSmsMessage(
      direction: VowifiSmsDirection.system,
      text: text,
      timestamp: DateTime.now(),
      raw: List<int>.from(raw),
      status: text,
    );
  }

  static _CpimPayload? _parseCpim(List<int> body) {
    final raw = latin1.decode(body, allowInvalid: true);
    final parts = raw.split('\r\n\r\n');
    if (parts.length < 2) {
      return null;
    }
    var headerBlock = parts.first;
    var remaining = raw.substring(headerBlock.length + 4);
    var contentType = _findHeaderValue(headerBlock, 'content-type');
    if (contentType.isEmpty) {
      final secondSplit = remaining.split('\r\n\r\n');
      if (secondSplit.length < 2) {
        return null;
      }
      headerBlock = secondSplit.first;
      remaining = remaining.substring(headerBlock.length + 4);
      contentType = _findHeaderValue(headerBlock, 'content-type');
    }
    if (contentType.isEmpty) {
      return null;
    }
    return _CpimPayload(contentType, latin1.encode(remaining));
  }

  static String _findHeaderValue(String block, String key) {
    for (final line in block.split('\r\n')) {
      final index = line.indexOf(':');
      if (index <= 0) {
        continue;
      }
      final candidate = line.substring(0, index).trim().toLowerCase();
      if (candidate == key) {
        return line.substring(index + 1).trim();
      }
    }
    return '';
  }

  static List<int>? _extractTpduFromRpdu(List<int> raw) {
    if (raw.length < 4) {
      return null;
    }
    var index = 2;
    final oaLength = raw[index++];
    index += oaLength;
    final daLength = raw[index++];
    index += daLength;
    final udLength = raw[index++];
    if (index + udLength > raw.length) {
      return null;
    }
    return raw.sublist(index, index + udLength);
  }

  static List<int> _encodeRpAddress(String address) {
    var digits = _normalizeDialableAddress(address);
    digits = digits.replaceFirst('+', '');
    if (digits.isEmpty) {
      throw ArgumentError('Empty SMSC');
    }
    for (final codeUnit in digits.codeUnits) {
      if (codeUnit < 48 || codeUnit > 57) {
        throw ArgumentError('Invalid SMSC digit');
      }
    }
    if (digits.length.isOdd) {
      digits = '${digits}F';
    }
    final bcd = <int>[];
    for (var index = 0; index < digits.length; index += 2) {
      final lo = _nibble(digits[index]);
      final hi = _nibble(digits[index + 1]);
      bcd.add(lo | (hi << 4));
    }
    return <int>[1 + bcd.length, 0x91, ...bcd];
  }

  static _EncodedAddress _encodeAddressSemiOctet(String address) {
    var digits = _normalizeDialableAddress(address);
    digits = digits.replaceFirst('+', '');
    if (digits.isEmpty) {
      throw ArgumentError('Empty destination');
    }
    for (final codeUnit in digits.codeUnits) {
      if (codeUnit < 48 || codeUnit > 57) {
        throw ArgumentError('Invalid destination digit');
      }
    }
    final digitCount = digits.length;
    if (digits.length.isOdd) {
      digits = '${digits}F';
    }
    final bytes = <int>[];
    for (var index = 0; index < digits.length; index += 2) {
      final lo = _nibble(digits[index]);
      final hi = _nibble(digits[index + 1]);
      bytes.add(lo | (hi << 4));
    }
    return _EncodedAddress(bytes, digitCount);
  }

  static String _normalizeDialableAddress(String address) {
    var working = address.trim();
    final lower = working.toLowerCase();
    if (lower.startsWith('sip:')) {
      working = working.substring(4);
      final at = working.indexOf('@');
      if (at > 0) {
        working = working.substring(0, at);
      }
    } else if (lower.startsWith('tel:')) {
      working = working.substring(4);
    }
    working = working.replaceAll(RegExp(r'[\s().-]'), '');
    if (working.startsWith('00')) {
      working = '+${working.substring(2)}';
    }
    return working;
  }

  static _PackedGsm7? _tryPackGsm7(String text) {
    final septets = <int>[];
    for (final codeUnit in text.codeUnits) {
      final encoded = _encodeGsm7Char(codeUnit);
      if (encoded == null) {
        return null;
      }
      septets.addAll(encoded);
    }
    final bytes = BytesBuilder();
    var carry = 0;
    var bits = 0;
    for (final septet in septets) {
      carry |= (septet & 0x7F) << bits;
      bits += 7;
      while (bits >= 8) {
        bytes.addByte(carry & 0xFF);
        carry >>= 8;
        bits -= 8;
      }
    }
    if (bits > 0) {
      bytes.addByte(carry & 0xFF);
    }
    return _PackedGsm7(bytes.toBytes(), septets.length);
  }

  static List<int>? _encodeGsm7Char(int value) {
    final basic = _gsm7BasicReverse[value];
    if (basic != null) {
      return <int>[basic];
    }
    final ext = _gsm7ExtensionReverse[value];
    if (ext != null) {
      return <int>[0x1B, ext];
    }
    return null;
  }

  static List<int> _encodeUcs2(String text) {
    final bytes = BytesBuilder();
    for (final unit in text.codeUnits) {
      bytes.addByte((unit >> 8) & 0xFF);
      bytes.addByte(unit & 0xFF);
    }
    return bytes.toBytes();
  }

  static String _decodeSemiOctetAddress(
    List<int> raw,
    int digits, {
    int toa = 0x91,
  }) {
    final ton = (toa >> 4) & 0x07;
    final hasPlus = ton == 0x01;
    final output = StringBuffer(hasPlus ? '+' : '');
    for (final value in raw) {
      final lo = value & 0x0F;
      final hi = (value >> 4) & 0x0F;
      if (lo <= 9 && output.length - (hasPlus ? 1 : 0) < digits) {
        output.writeCharCode(48 + lo);
      }
      if (hi <= 9 && output.length - (hasPlus ? 1 : 0) < digits) {
        output.writeCharCode(48 + hi);
      }
    }
    return output.toString();
  }

  static DateTime _decodeTimestamp(List<int> raw) {
    int swap(int value) => (value & 0x0F) * 10 + ((value >> 4) & 0x0F);
    final year = 2000 + swap(raw[0]);
    final month = swap(raw[1]);
    final day = swap(raw[2]);
    final hour = swap(raw[3]);
    final minute = swap(raw[4]);
    final second = swap(raw[5]);
    final tzByte = raw[6];
    final tzQuarters = swap(tzByte & 0xF7);
    final tzNegative = (tzByte & 0x08) != 0;
    final offsetMinutes = tzQuarters * 15 * (tzNegative ? -1 : 1);
    final utc = DateTime.utc(
      year,
      month,
      day,
      hour,
      minute,
      second,
    ).subtract(Duration(minutes: offsetMinutes));
    return utc.toLocal();
  }

  static String _decodeUserData(int dcs, int udl, List<int> raw, bool udhi) {
    var udhBytes = 0;
    if (udhi) {
      udhBytes = raw.first + 1;
    }
    var textLength = udl;
    if (udhi) {
      textLength -= udhBytes;
      if (textLength < 0) {
        textLength = 0;
      }
    }
    switch (dcs & 0x0C) {
      case 0x08:
        final data = raw.sublist(udhBytes);
        final usableLength = data.length < textLength
            ? data.length
            : textLength;
        final evenLength = usableLength.isOdd ? usableLength - 1 : usableLength;
        final chars = <int>[];
        for (var index = 0; index < evenLength; index += 2) {
          chars.add((data[index] << 8) | data[index + 1]);
        }
        var output = String.fromCharCodes(chars);
        if (output.startsWith('\uFEFF')) {
          output = output.substring(1);
        }
        return output;
      case 0x04:
        final data = raw.sublist(udhBytes);
        final textBytes = data.take(textLength).toList(growable: false);
        if (_mostlyPrintableAscii(textBytes)) {
          return latin1.decode(textBytes, allowInvalid: true);
        }
        return 'hex:${_hex(textBytes).toUpperCase()}';
      default:
        if (udhi) {
          final skipBits = udhBytes * 8;
          final skipSeptets = (skipBits + 6) ~/ 7;
          final textSeptets = udl - skipSeptets;
          return _unpackGsm7WithOffset(
            raw,
            textSeptets < 0 ? 0 : textSeptets,
            skipBits,
          );
        }
        return _unpackGsm7(raw, udl);
    }
  }

  static bool _mostlyPrintableAscii(List<int> bytes) {
    if (bytes.isEmpty) {
      return true;
    }
    var printable = 0;
    for (final value in bytes) {
      if (value == 0x0A ||
          value == 0x0D ||
          value == 0x09 ||
          (value >= 32 && value <= 126)) {
        printable++;
      }
    }
    return printable * 100 ~/ bytes.length >= 85;
  }

  static String _unpackGsm7(List<int> raw, int septets) {
    final values = <int>[];
    var carry = 0;
    var carryBits = 0;
    for (final value in raw) {
      carry |= value << carryBits;
      carryBits += 8;
      while (carryBits >= 7 && values.length < septets) {
        values.add(carry & 0x7F);
        carry >>= 7;
        carryBits -= 7;
      }
    }
    return _decodeGsm7Septets(values);
  }

  static String _unpackGsm7WithOffset(
    List<int> raw,
    int septets,
    int bitOffset,
  ) {
    final values = <int>[];
    for (var index = 0; index < septets; index++) {
      final startBit = bitOffset + index * 7;
      final byteIndex = startBit ~/ 8;
      final shift = startBit % 8;
      if (byteIndex >= raw.length) {
        break;
      }
      var value = raw[byteIndex] >> shift;
      if (byteIndex + 1 < raw.length && shift > 1) {
        value |= raw[byteIndex + 1] << (8 - shift);
      }
      values.add(value & 0x7F);
    }
    return _decodeGsm7Septets(values);
  }

  static String _decodeGsm7Septets(List<int> septets) {
    final output = StringBuffer();
    var escaped = false;
    for (final septet in septets) {
      if (escaped) {
        output.writeCharCode(_gsm7ExtensionTable[septet] ?? '?'.codeUnitAt(0));
        escaped = false;
        continue;
      }
      if (septet == 0x1B) {
        escaped = true;
        continue;
      }
      output.writeCharCode(_gsm7Table[septet]);
    }
    return output.toString();
  }

  static int _nibble(String value) {
    if (value == 'F') {
      return 0x0F;
    }
    return value.codeUnitAt(0) - 48;
  }

  static String _hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final value in bytes) {
      buffer.write(value.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static final List<int> _gsm7Table =
      List<int>.generate(128, (index) {
          if (index >= 32 && index < 127) {
            return index;
          }
          return '?'.codeUnitAt(0);
        })
        ..[0] = '@'.codeUnitAt(0)
        ..[10] = '\n'.codeUnitAt(0)
        ..[13] = '\r'.codeUnitAt(0)
        ..[17] = '_'.codeUnitAt(0)
        ..[20] = '^'.codeUnitAt(0)
        ..[27] = ' '.codeUnitAt(0)
        ..[36] = r'$'.codeUnitAt(0);

  static final Map<int, int> _gsm7BasicReverse = <int, int>{
    '@'.codeUnitAt(0): 0,
    '\n'.codeUnitAt(0): 10,
    '\r'.codeUnitAt(0): 13,
    '_'.codeUnitAt(0): 17,
    '^'.codeUnitAt(0): 20,
    r'$'.codeUnitAt(0): 36,
    for (var index = 32; index < 127; index++) index: index,
  };

  static final Map<int, int> _gsm7ExtensionReverse = <int, int>{
    '^'.codeUnitAt(0): 0x14,
    '{'.codeUnitAt(0): 0x28,
    '}'.codeUnitAt(0): 0x29,
    '\\'.codeUnitAt(0): 0x2F,
    '['.codeUnitAt(0): 0x3C,
    '~'.codeUnitAt(0): 0x3D,
    ']'.codeUnitAt(0): 0x3E,
    '|'.codeUnitAt(0): 0x40,
    '€'.codeUnitAt(0): 0x65,
  };

  static final Map<int, int> _gsm7ExtensionTable = <int, int>{
    0x14: '^'.codeUnitAt(0),
    0x28: '{'.codeUnitAt(0),
    0x29: '}'.codeUnitAt(0),
    0x2F: '\\'.codeUnitAt(0),
    0x3C: '['.codeUnitAt(0),
    0x3D: '~'.codeUnitAt(0),
    0x3E: ']'.codeUnitAt(0),
    0x40: '|'.codeUnitAt(0),
    0x65: '€'.codeUnitAt(0),
  };
}

class _CpimPayload {
  const _CpimPayload(this.contentType, this.payload);

  final String contentType;
  final List<int> payload;
}

class _EncodedAddress {
  const _EncodedAddress(this.bytes, this.digits);

  final List<int> bytes;
  final int digits;
}

class _PackedGsm7 {
  const _PackedGsm7(this.bytes, this.septets);

  final Uint8List bytes;
  final int septets;
}
