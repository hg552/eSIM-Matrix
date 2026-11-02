import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/adapter/ccid/nine_esim_usb_protocol.dart';
import 'package:nlpa2/utils/hex_utils.dart';

void main() {
  group('NineEsimUsbProtocol', () {
    test('builds the documented ATR programming commands', () {
      expect(
        HexUtils.bytesToHex(
          NineEsimUsbProtocol.enableAtrProgrammingCommand(),
        ).toUpperCase(),
        '3097431800',
      );
      expect(
        HexUtils.bytesToHex(
          NineEsimUsbProtocol.setAtrCommand(
            '3B9F12801F038031E073FE21136702434F537EC1017B',
          ),
        ).toUpperCase(),
        '3038000016159F12801F038031E073FE21136702434F537EC1017B',
      );
    });

    test('toggles the T=15 eUICC capability and repairs TCK', () {
      const enabled = NineEsimUsbProtocol.defaultAtr;
      expect(NineEsimUsbProtocol.euiccCapabilityEnabled(enabled), isTrue);

      final disabled = NineEsimUsbProtocol.setEuiccCapability(enabled, false);
      expect(disabled, '3B9F96801F018031E073FE21136702434F537EC101FD');
      expect(NineEsimUsbProtocol.euiccCapabilityEnabled(disabled), isFalse);
      expect(NineEsimUsbProtocol.setEuiccCapability(disabled, true), enabled);
    });

    test('builds the existing password command for USB transport', () {
      expect(
        HexUtils.bytesToHex(
          NineEsimUsbProtocol.setPasswordCommand(
            deviceName: 'A1B2C3',
            password: '123456',
          ),
        ).toUpperCase(),
        '3027000009111111A1B2C3123456',
      );
    });
  });
}
