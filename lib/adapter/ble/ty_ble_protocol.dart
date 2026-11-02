import 'dart:typed_data';

/// Helpers for the Tianyu Bluetooth eSIM wire protocol.
class TYBLEProtocol {
  TYBLEProtocol._();

  static final RegExp _deviceNamePattern = RegExp(
    r'^(?:[A-Za-z0-9]+-BT-([0-9A-Fa-f]{8})|9eSIM([0-9]{8}))$',
    caseSensitive: false,
  );

  static bool isDeviceName(String name) =>
      _deviceNamePattern.hasMatch(name.trim());

  static String uidFromDeviceName(String name) {
    final match = _deviceNamePattern.firstMatch(name.trim());
    if (match == null) {
      throw FormatException(
        'TY BLE device name must end with an 8-character hexadecimal UID: $name',
      );
    }
    return (match.group(1) ?? match.group(2))!.toUpperCase();
  }

  /// Derives the six ASCII PIN bytes described by the Tianyu manual.
  static Uint8List pinForDeviceName(String name) {
    final uid = uidFromDeviceName(name);
    final uidBytes = List<int>.generate(
      4,
      (index) => int.parse(uid.substring(index * 2, index * 2 + 2), radix: 16),
    );

    final sum = uidBytes.fold<int>(0, (value, byte) => value + byte) & 0xFF;
    final xor = uidBytes.fold<int>(0, (value, byte) => value ^ byte);
    final mixed = (sum + xor) & 0xFF;

    final pin = Uint8List(6);
    var offset = 0;
    for (final value in [sum, xor, mixed]) {
      pin[offset++] = _asciiDigitForNibble(value >> 4);
      pin[offset++] = _asciiDigitForNibble(value & 0x0F);
    }
    return pin;
  }

  static int _asciiDigitForNibble(int nibble) {
    final digit = nibble <= 9 ? nibble : nibble - 6;
    return 0x30 + digit;
  }

  static Uint8List authenticationApdu(String deviceName) {
    final pin = pinForDeviceName(deviceName);
    return Uint8List(5 + pin.length)
      ..setAll(0, const [0xFF, 0x60, 0x5A, 0x01, 0x06])
      ..setAll(5, pin);
  }

  /// Adds the two-byte, big-endian payload length used by the BLE transport.
  static Uint8List frame(Uint8List payload) {
    if (payload.length > 0xFFFF) {
      throw ArgumentError.value(
        payload.length,
        'payload.length',
        'TY BLE frames cannot exceed 65535 bytes',
      );
    }
    return Uint8List(2 + payload.length)
      ..[0] = (payload.length >> 8) & 0xFF
      ..[1] = payload.length & 0xFF
      ..setAll(2, payload);
  }
}

/// Reassembles length-prefixed messages across BLE notifications.
class TYBLEFrameDecoder {
  final List<int> _buffer = [];

  List<Uint8List> add(List<int> bytes) {
    _buffer.addAll(bytes);
    final frames = <Uint8List>[];

    while (_buffer.length >= 2) {
      final payloadLength = (_buffer[0] << 8) | _buffer[1];
      final frameLength = 2 + payloadLength;
      if (_buffer.length < frameLength) break;

      frames.add(Uint8List.fromList(_buffer.sublist(2, frameLength)));
      _buffer.removeRange(0, frameLength);
    }

    return frames;
  }

  void clear() => _buffer.clear();
}
