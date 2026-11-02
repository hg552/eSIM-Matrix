import 'dart:convert';
import 'dart:typed_data';

import '../../utils/hex_utils.dart';

class NineEsimUsbProtocol {
  static const defaultAtr = '3B9F96801F038031E073FE21136702434F537EC101FF';

  static String passwordHex(String value) {
    final trimmed = value.trim();
    if (trimmed.length == 6 && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(trimmed)) {
      return trimmed.toUpperCase();
    }

    var crc = 0xB704CE;
    for (final byte in utf8.encode(value)) {
      crc ^= byte << 16;
      for (var bit = 0; bit < 8; bit++) {
        crc <<= 1;
        if ((crc & 0x1000000) != 0) crc ^= 0x1864CFB;
      }
    }
    return (crc & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
  }

  static Uint8List setPasswordCommand({
    required String deviceName,
    required String password,
  }) {
    final name = deviceName.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(name)) {
      throw const FormatException('Device ID must be exactly 6 hex characters');
    }
    return HexUtils.hexToBytes(
      '3027000009'
      '111111'
      '$name'
      '${passwordHex(password)}',
    );
  }

  static Uint8List enableAtrProgrammingCommand() =>
      HexUtils.hexToBytes('3097431800');

  static Uint8List setAtrCommand(String atr) {
    final normalized = _normalizeAtr(atr);
    final bytes = HexUtils.hexToBytes(normalized);
    if (bytes.length > 255) {
      throw const FormatException('ATR is too long');
    }

    // The writer expects DATA = ATR length + ATR without TS (3B).
    final data = Uint8List(bytes.length);
    data[0] = bytes.length - 1;
    data.setRange(1, data.length, bytes, 1);
    final command = Uint8List(5 + data.length);
    command.setAll(0, [0x30, 0x38, 0x00, 0x00, data.length]);
    command.setAll(5, data);
    return command;
  }

  static bool euiccCapabilityEnabled(String atr) {
    final bytes = HexUtils.hexToBytes(_normalizeAtr(atr));
    return (bytes[_globalInterfaceByteIndex(bytes)] & 0x02) != 0;
  }

  static String setEuiccCapability(String atr, bool enabled) {
    final bytes = HexUtils.hexToBytes(_normalizeAtr(atr));
    final index = _globalInterfaceByteIndex(bytes);
    bytes[index] = enabled ? bytes[index] | 0x02 : bytes[index] & ~0x02;

    // T=15 means TCK is present. Make XOR(T0..TCK) equal zero again.
    var checksum = 0;
    for (var i = 1; i < bytes.length - 1; i++) {
      checksum ^= bytes[i];
    }
    bytes[bytes.length - 1] = checksum;
    return HexUtils.bytesToHex(bytes).toUpperCase();
  }

  static int _globalInterfaceByteIndex(Uint8List atr) {
    var index = 2;
    var presence = atr[1] >> 4;
    while (true) {
      if ((presence & 0x1) != 0) index++;
      if ((presence & 0x2) != 0) index++;
      if ((presence & 0x4) != 0) index++;
      if ((presence & 0x8) == 0) break;
      if (index >= atr.length - 1) {
        throw const FormatException('Malformed ATR interface bytes');
      }
      final td = atr[index++];
      presence = td >> 4;
      if ((td & 0x0F) == 0x0F) {
        if (presence == 0 || index >= atr.length - 1) {
          throw const FormatException(
            'ATR has no global interface byte after T=15',
          );
        }
        return index;
      }
    }
    throw const FormatException('ATR does not advertise protocol T=15');
  }

  static String _normalizeAtr(String atr) {
    final normalized = atr.replaceAll(RegExp(r'\s+'), '').toUpperCase();
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(normalized) ||
        normalized.length.isOdd ||
        !normalized.startsWith('3B') ||
        normalized.length < 6) {
      throw const FormatException('Enter a valid direct-convention ATR');
    }
    return normalized;
  }
}
