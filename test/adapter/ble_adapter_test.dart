import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/adapter/ble/ble_adapter.dart';
import 'package:nlpa2/adapter/ble/ble_manager.dart';
import 'package:nlpa2/widgets/profiles_screen/reader_helper.dart';

void main() {
  group('BleAdapterType', () {
    test('round-trips every stable reader ID', () {
      for (final type in BleAdapterType.values) {
        expect(BleAdapterType.tryFromId(type.id), type);
        expect(BleAdapterType.fromReaderId('${type.id}: reader|device'), type);
      }
      expect(BleAdapterType.tryFromId('unknown'), isNull);
      expect(BleAdapterType.fromReaderId('usb: reader'), isNull);
    });

    test('detects each supported device name', () {
      const cases = {
        'ESTKme': BleAdapterType.redBle,
        'ESTKme RED': BleAdapterType.redBle2,
        'GlocalMe': BleAdapterType.glocalMe,
        '9eSIM123456': BleAdapterType.nineEsim,
        'BeeSIM': BleAdapterType.beeSim,
        'eSIM_Writer': BleAdapterType.simLink,
      };

      for (final entry in cases.entries) {
        expect(
          BleAdapterType.fromDeviceNames(
            displayName: entry.key,
            advertisedName: '',
          ),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('uses the advertised name when the platform name is generic', () {
      expect(
        BleAdapterType.fromDeviceNames(
          displayName: 'Bluetooth Device',
          advertisedName: 'BeeSIM-Reader',
        ),
        BleAdapterType.beeSim,
      );
    });

    test('distinguishes six hex digits from eight-digit B0 Plus', () {
      const cases = {
        '9eSIM123456': BleAdapterType.nineEsim,
        '9eSIMabcdef': BleAdapterType.nineEsim,
        '9eSIMABCDEF': BleAdapterType.nineEsim,
        '9eSIMA1b2C3': BleAdapterType.nineEsim,
        ' 9esimf0a123 ': BleAdapterType.nineEsim,
        '9esim000001': BleAdapterType.nineEsim,
        ' 9ESIM123456 ': BleAdapterType.nineEsim,
        '9eSIM': null,
        '9eSIM12345': null,
        '9eSIMabcde': null,
        '9eSIMabcdef0': null,
        '9eSIMabcdeg': null,
        '9eSIM1234567': null,
        '9eSIM123456789': null,
        '9eSIM1234567A': null,
        'prefix9eSIM123456': null,
        '9eSIM123456suffix': null,
      };

      for (final entry in cases.entries) {
        expect(
          BleAdapterType.fromDeviceNames(
            displayName: entry.key,
            advertisedName: '',
          ),
          entry.value,
          reason: entry.key,
        );
        expect(
          BleAdapterType.fromDeviceNames(
            displayName: 'Bluetooth Device',
            advertisedName: entry.key,
          ),
          entry.value,
          reason: entry.key,
        );
      }
    });
  });

  group('BLE reader presentation', () {
    test('assigns every BLE adapter type a distinct icon', () {
      final iconKeys = BleAdapterType.values.map((type) {
        final icon = ReaderHelper.getBleAdapterIconData(type);
        return '${icon.fontPackage}:${icon.fontFamily}:${icon.codePoint}';
      }).toSet();

      expect(iconKeys, hasLength(BleAdapterType.values.length));
    });

    test('resolves icons and removal affordances from reader IDs', () {
      for (final type in BleAdapterType.values) {
        final readerId = '${type.id}: reader|device';
        expect(
          ReaderHelper.getIconData(readerId),
          ReaderHelper.getBleAdapterIconData(type),
        );
        expect(ReaderHelper.isPersistent(readerId), isTrue);
      }
    });
  });

  test('BleReaderInfo preserves stable string IDs in JSON', () {
    final info = BleReaderInfo.fromJson({
      'id': 'device',
      'name': '9eSIM123456',
      'type': 'nine_esim',
    });

    expect(info.type, BleAdapterType.nineEsim);
    expect(info.readerName, 'nine_esim: 9eSIM123456|device');
    expect(info.toJson()['type'], 'nine_esim');
  });
}
