import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/vowifi_sms/src/eap_aka_codec.dart';
import 'package:nlpa2/vowifi_sms/src/ike_datagram_codec.dart';
import 'package:nlpa2/vowifi_sms/vowifi_sms_plugin.dart';

void main() {
  test('frames and strips IKE datagrams for NAT-T', () {
    final ike = Uint8List.fromList(<int>[0x01, 0x02, 0x03]);

    final framed = VowifiIkeDatagramCodec.frame(ike, natt: true);

    expect(framed, <int>[0, 0, 0, 0, 1, 2, 3]);
    expect(VowifiIkeDatagramCodec.stripNattMarker(framed), ike);
    expect(VowifiIkeDatagramCodec.frame(ike, natt: false), same(ike));
  });

  test('encodes EAP-AKA synchronization failure with AUTS', () {
    final auts = List<int>.generate(14, (index) => index);

    final response = VowifiEapAkaCodec.buildSynchronizationFailureResponse(
      identifier: 0x7a,
      auts: auts,
    );

    expect(response.length, 24);
    expect(response.sublist(0, 10), <int>[2, 0x7a, 0, 24, 23, 4, 0, 0, 4, 4]);
    expect(response.sublist(10), auts);
  });

  test('rejects malformed AUTS lengths', () {
    expect(
      () => VowifiEapAkaCodec.buildSynchronizationFailureResponse(
        identifier: 1,
        auts: const <int>[1, 2, 3],
      ),
      throwsArgumentError,
    );
  });

  test('preserves device identity in config serialization', () {
    const config = VowifiSmsConfig(deviceIdentity: '3538374112345600');

    final restored = VowifiSmsConfig.fromJson(config.toJson());

    expect(restored.deviceIdentity, config.deviceIdentity);
  });
}
