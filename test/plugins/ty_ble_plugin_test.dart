import 'package:ble/ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/adapter/ble/ble_adapter.dart';
import 'package:nlpa2/adapter/ble/ble_manager.dart';
import 'package:nlpa2/plugins/plugin_manager.dart';
import 'package:nlpa2/plugins/ty_ble_plugin.dart';
import 'package:nlpa2/widgets/profiles_screen/reader_helper.dart';

void main() {
  setUpAll(() {
    expect(PluginManager().hasPlugin('ty_ble'), isTrue);
  });

  final tyBle = TyBlePlugin.kind.type;

  test('detects TYBLE and eight-digit B0 Plus names', () {
    for (final name in [
      '9eSIM12345678',
      '9esim00000184',
      ' 9ESIM49535343 ',
      'TES-BT-00000184',
    ]) {
      expect(
        BleAdapterType.fromDeviceNames(displayName: name, advertisedName: ''),
        tyBle,
        reason: name,
      );
      expect(
        BleAdapterType.fromDeviceNames(
          displayName: 'Bluetooth Device',
          advertisedName: name,
        ),
        tyBle,
        reason: name,
      );
    }
    expect(
      BleAdapterType.fromDeviceNames(
        displayName: '9eSIM123456',
        advertisedName: '',
      ),
      BleAdapterType.nineEsim,
    );
  });

  test('B0 Plus advertisement takes precedence over a cached 9eSIM name', () {
    expect(
      BleAdapterType.fromDeviceNames(
        displayName: '9eSIM123456',
        advertisedName: '9eSIM12345678',
      ),
      tyBle,
    );
  });

  test('round-trips the TYBLE reader ID and has its own icon', () {
    expect(BleAdapterType.tryFromId('ty_ble'), tyBle);
    expect(BleAdapterType.fromReaderId('ty_ble: reader|device'), tyBle);
    expect(ReaderHelper.getBleAdapterIconData(tyBle), TyBlePlugin.kind.icon);

    final info = BleReaderInfo.fromJson({
      'id': 'device',
      'name': 'TES-BT-00000184',
      'type': 'ty_ble',
    });
    expect(info.type, tyBle);
    expect(info.readerName, 'ty_ble: TES-BT-00000184|device');
  });

  test('B0 Plus reader keeps its advertised UID for authentication', () {
    for (final platformName in ['Bluetooth Device', '9eSIM123456', '']) {
      final info = BleReaderInfo.fromScanResult(
        ScanResult(
          device: _NamedBluetoothDevice(platformName),
          advertisementData: AdvertisementData(
            advName: '9eSIM00000184',
            txPowerLevel: null,
            appearance: null,
            connectable: true,
            manufacturerData: const {},
            serviceData: const {},
            serviceUuids: const [],
          ),
          rssi: -50,
          timeStamp: DateTime(2026, 10, 2),
        ),
      );

      expect(info.type, tyBle);
      expect(info.name, '9eSIM00000184');
      expect(info.readerName, 'ty_ble: 9eSIM00000184|device');
    }
  });
}

class _NamedBluetoothDevice extends Fake implements BluetoothDevice {
  _NamedBluetoothDevice(this.platformName);

  @override
  final DeviceIdentifier remoteId = DeviceIdentifier('device');

  @override
  final String platformName;
}
