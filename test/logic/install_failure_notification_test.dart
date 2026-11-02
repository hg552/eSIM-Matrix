import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:nlpa2/adapter/euicc_adapter.dart';
import 'package:nlpa2/logic/profile_manager.dart';
import 'package:nlpa2/models/asn1/rsp_definitions.g.dart';

/// A card holding [count] install notifications, newest sequence number last.
ListNotificationResponse _metadataFor(List<int> seqNumbers) {
  return ListNotificationResponse(
    notificationMetadataList: [
      for (final seq in seqNumbers)
        NotificationMetadata(
          seqNumber: seq,
          profileManagementOperation: const NotificationEvent(
            NotificationEvent.notificationInstall,
          ),
          notificationAddress: 'smdp.example.com',
        ),
    ],
  );
}

RetrieveNotificationsListResponse _installFailure(int seq) {
  return RetrieveNotificationsListResponse(
    notificationList: [
      PendingNotification(
        profileInstallationResult: ProfileInstallationResult(
          profileInstallationResultData: ProfileInstallationResultData(
            transactionId: Uint8List.fromList([0x01, 0x02]),
            notificationMetadata: NotificationMetadata(
              seqNumber: seq,
              profileManagementOperation: const NotificationEvent(
                NotificationEvent.notificationInstall,
              ),
              notificationAddress: 'smdp.example.com',
            ),
            finalResult: ProfileInstallationResultData_finalResult(
              errorResult: ErrorResult(
                bppCommandId: BppCommandId.loadProfileElements,
                errorReason:
                    ErrorReason.installFailedDueToInsufficientMemoryForProfile,
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

void main() {
  group('getLatestInstallNotification', () {
    test(
      'reads metadata first and retrieves exactly one notification',
      () async {
        final adapter = _ScriptedAdapter([
          _metadataFor([4, 9, 7]).encode(),
          _installFailure(9).encode(),
        ]);

        final notification = await ProfileManager(
          adapter,
        ).getLatestInstallNotification(useChannel: adapter.channel);

        expect(notification, isNotNull);
        expect(adapter.channel.requests, hasLength(2));

        // The first request is ES10b.ListNotification, which carries metadata
        // only -- no certificate chains, so its size does not grow with the
        // number of notifications the card is holding.
        final listRequest = ListNotificationRequest.decode(
          adapter.channel.requests[0],
        );
        expect(listRequest, isNotNull);

        // The second asks for one sequence number. Searching by
        // profileManagementOperation instead would return every install
        // notification at once, which is what overran the BLE transport.
        final retrieve = RetrieveNotificationsListRequest.decode(
          adapter.channel.requests[1],
        );
        expect(retrieve.searchCriteria?.seqNumber, 9);
        expect(retrieve.searchCriteria?.profileManagementOperation, isNull);
      },
    );

    test('picks the highest sequence number, not the last listed', () async {
      final adapter = _ScriptedAdapter([
        _metadataFor([12, 3, 8]).encode(),
        _installFailure(12).encode(),
      ]);

      await ProfileManager(
        adapter,
      ).getLatestInstallNotification(useChannel: adapter.channel);

      final retrieve = RetrieveNotificationsListRequest.decode(
        adapter.channel.requests[1],
      );
      expect(retrieve.searchCriteria?.seqNumber, 12);
    });

    test('a card with no install notification is not asked for one', () async {
      final adapter = _ScriptedAdapter([
        ListNotificationResponse(
          notificationMetadataList: [
            NotificationMetadata(
              seqNumber: 2,
              profileManagementOperation: const NotificationEvent(
                NotificationEvent.notificationLocalDelete,
              ),
              notificationAddress: 'smdp.example.com',
            ),
          ],
        ).encode(),
      ]);

      final notification = await ProfileManager(
        adapter,
      ).getLatestInstallNotification(useChannel: adapter.channel);

      expect(notification, isNull);
      expect(adapter.channel.requests, hasLength(1));
    });
  });
}

class _ScriptedAdapter extends BaseAdapter {
  _ScriptedAdapter(List<Uint8List> responses)
    : super(Logger('InstallFailureNotificationTest')) {
    channel = _ScriptedChannel(this, responses);
  }

  late final _ScriptedChannel channel;

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

class _ScriptedChannel implements Channel {
  _ScriptedChannel(this.adapter, this._responses);

  @override
  final Adapter adapter;
  final List<Uint8List> _responses;

  /// The ES10b request TLV of every command the card was sent.
  final List<Uint8List> requests = <Uint8List>[];

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
    if (requests.length >= _responses.length) {
      fail('the card received an unscripted APDU');
    }
    requests.add(Uint8List.fromList(data!));
    return Uint8List.fromList([..._responses[requests.length - 1], 0x90, 0x00]);
  }
}
