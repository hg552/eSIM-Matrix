import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/vowifi_sms/src/sms_codec.dart';

void main() {
  test('concatenated GSM 7-bit SMS decodes after the UDH fill bits', () {
    // DELIVER, UDHI set. UDH = 05 00 03 (concat, 3 bytes follow) 2A 2A 02.
    // UDL = 12 septets: ceil(48/7)=7 UDH septets + the 5 text septets "HELLO".
    // The text therefore starts at bit 49, not bit 48.
    final tpdu = <int>[
      0x40, // DELIVER + UDHI
      0x05, 0x81, 0x21, 0x43, 0xF5, // sender "12345"
      0x00, // PID
      0x00, // DCS: GSM 7-bit
      0x62, 0x10, 0x10, 0x12, 0x00, 0x00, 0x00, // SCTS
      0x0C, // UDL
      0x05, 0x00, 0x03, 0x2A, 0x2A, 0x02, // UDH (6 bytes)
      0x90, 0x45, 0x26, 0xF3, 0x09, // "HELLO" starting at bit 49
    ];

    final message = SmsCodec.decode('application/octet-stream', tpdu);

    expect(message.text, 'HELLO');
    expect(message.peer, '12345');
  });
}
