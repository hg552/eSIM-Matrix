import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/adapter/ble/ty_ble_protocol.dart';

void main() {
  group('TY BLE device names and PINs', () {
    test('matches the documented Tianyu vector', () {
      expect(TYBLEProtocol.isDeviceName('SCT-BT-49535343'), isTrue);
      expect(TYBLEProtocol.uidFromDeviceName('SCT-BT-49535343'), '49535343');
      expect(
        ascii.decode(TYBLEProtocol.pinForDeviceName('SCT-BT-49535343')),
        '320436',
      );
      expect(TYBLEProtocol.authenticationApdu('SCT-BT-49535343'), [
        0xFF,
        0x60,
        0x5A,
        0x01,
        0x06,
        0x33,
        0x32,
        0x30,
        0x34,
        0x33,
        0x36,
      ]);
    });

    test('matches the live TES card vector', () {
      expect(TYBLEProtocol.isDeviceName('TES-BT-00000184'), isTrue);
      expect(
        ascii.decode(TYBLEProtocol.pinForDeviceName('TES-BT-00000184')),
        '858504',
      );
    });

    test('B0 Plus names derive the same PIN and authentication as Tianyu', () {
      expect(TYBLEProtocol.isDeviceName('9eSIM49535343'), isTrue);
      expect(TYBLEProtocol.uidFromDeviceName('9eSIM49535343'), '49535343');
      expect(
        ascii.decode(TYBLEProtocol.pinForDeviceName('9eSIM49535343')),
        '320436',
      );
      expect(
        TYBLEProtocol.authenticationApdu('9eSIM49535343'),
        TYBLEProtocol.authenticationApdu('SCT-BT-49535343'),
      );
      expect(TYBLEProtocol.uidFromDeviceName(' 9esim00000184 '), '00000184');
      expect(
        ascii.decode(TYBLEProtocol.pinForDeviceName('9eSIM00000184')),
        '858504',
      );
    });

    test('rejects six-digit and malformed 9eSIM names as Tyble', () {
      for (final name in [
        '9eSIM123456',
        '9eSIMabcdef',
        '9eSIMA1B2C3',
        '9eSIM1234567',
        '9eSIM123456789',
        '9eSIM1234567A',
        'prefix9eSIM12345678',
        '9eSIM12345678suffix',
      ]) {
        expect(TYBLEProtocol.isDeviceName(name), isFalse, reason: name);
        expect(
          () => TYBLEProtocol.authenticationApdu(name),
          throwsFormatException,
          reason: name,
        );
      }
    });

    test('rejects names without the required hexadecimal UID', () {
      expect(TYBLEProtocol.isDeviceName('TES-BT-not-a-uid'), isFalse);
      expect(
        () => TYBLEProtocol.pinForDeviceName('TES-BT-not-a-uid'),
        throwsFormatException,
      );
    });
  });

  group('TY BLE length framing', () {
    test('writes a two-byte big-endian payload length', () {
      expect(TYBLEProtocol.frame(Uint8List.fromList([0x90, 0x00])), [
        0x00,
        0x02,
        0x90,
        0x00,
      ]);
    });

    test('reassembles a response split across notifications', () {
      final decoder = TYBLEFrameDecoder();

      expect(decoder.add([0x00]), isEmpty);
      expect(decoder.add([0x02, 0x90]), isEmpty);
      expect(decoder.add([0x00]), [
        [0x90, 0x00],
      ]);
    });

    test('extracts multiple responses from one notification', () {
      final decoder = TYBLEFrameDecoder();

      expect(decoder.add([0x00, 0x02, 0x90, 0x00, 0x00, 0x02, 0x69, 0x82]), [
        [0x90, 0x00],
        [0x69, 0x82],
      ]);
    });

    test('rejects payloads longer than the unsigned length field', () {
      expect(
        () => TYBLEProtocol.frame(Uint8List(0x10000)),
        throwsArgumentError,
      );
    });
  });
}
