import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:nlpa2/adapter/euicc_adapter.dart';
import 'package:nlpa2/logic/profile_manager.dart';
import 'package:nlpa2/models/asn1/rsp_definitions.g.dart';
import 'package:nlpa2/utils/hex_utils.dart';
import 'package:nlpa2/utils/notification_address.dart';

void main() {
  test('accepts notification-server FQDNs', () {
    expect(isValidNotificationAddress('rsp-eu.redteamobile.com'), isTrue);
    expect(isValidNotificationAddress('rsp.example.test.'), isTrue);
  });

  test('rejects malformed address from ListNotification response', () {
    final response = ListNotificationResponse.decode(
      Uint8List.fromList(
        HexUtils.hexToBytes(
          'BF2832A030BF2F2D8002008F810207800C17'
          '1029227273702D65752E7265647465616D6F62696C652E'
          '5A0A90010298583205240404',
        ),
      ),
    );

    final address =
        response.notificationMetadataList!.single.notificationAddress;
    expect(address, endsWith('rsp-eu.redteamobile.'));
    expect(isValidNotificationAddress(address), isFalse);
  });

  test('rejects whitespace, control bytes, and invalid labels', () {
    expect(isValidNotificationAddress(' rsp.example.com'), isFalse);
    expect(isValidNotificationAddress('\u0010rsp.example.com'), isFalse);
    expect(isValidNotificationAddress('-rsp.example.com'), isFalse);
    expect(isValidNotificationAddress('rsp.example'), isTrue);
    expect(isValidNotificationAddress('localhost'), isFalse);
  });

  test(
    'two-step listing replaces malformed metadata from signed copy',
    () async {
      final adapter = _TwoStepAdapter([
        _response(
          'BF2832A030BF2F2D8002008F810207800C17'
          '1029227273702D65752E7265647465616D6F62696C652E'
          '5A0A90010298583205240404',
        ),
        _response(
          'BF2B34A0323030BF2F2D8002008F810207800C17'
          '7273702D65752E7265647465616D6F62696C652E636F6D'
          '5A0A90010298583205240404',
        ),
      ]);
      final manager = ProfileManager(adapter);

      final notifications = await manager.retrieveNotifications(
        useChannel: adapter.channel,
      );

      expect(adapter.channel.requestCount, 2);
      expect(notifications, hasLength(1));
      expect(notifications.single.asn1, isNotNull);
      expect(
        ProfileManager.extractMetadata(
          notifications.single,
        )?.notificationAddress,
        'rsp-eu.redteamobile.com',
      );
    },
  );
}

Uint8List _response(String dataHex) =>
    Uint8List.fromList(HexUtils.hexToBytes('${dataHex}9000'));

class _TwoStepAdapter extends BaseAdapter {
  _TwoStepAdapter(List<Uint8List> responses)
    : super(Logger('TwoStepNotificationTest')) {
    channel = _TestChannel(this, responses);
  }

  late final _TestChannel channel;

  @override
  NotificationStrategy get notificationStrategy => NotificationStrategy.twoStep;

  @override
  Stream<EuiccPortState> get stateStream => const Stream.empty();

  @override
  bool get requiresRefresh => false;

  @override
  String? get lastAtr => null;

  @override
  Future<List<Reader>> listReaders({bool force = false}) async => const [];

  @override
  Future<void> connect(Reader reader) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<Channel> openChannel({List<String>? aids}) async => channel;

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) => throw UnimplementedError();
}

class _TestChannel implements Channel {
  _TestChannel(this.adapter, this._responses);

  @override
  final Adapter adapter;
  final List<Uint8List> _responses;
  int requestCount = 0;

  @override
  String? get aid => null;

  @override
  int get channelNumber => 1;

  @override
  Future<void> close() async {}

  @override
  Future<Uint8List> transmit(
    int cla,
    int ins,
    int p1,
    int p2, [
    Uint8List? data,
    int? le,
  ]) async {
    if (requestCount >= _responses.length) {
      throw StateError('Unexpected APDU request');
    }
    return _responses[requestCount++];
  }
}
