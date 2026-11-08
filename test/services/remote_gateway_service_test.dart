import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nlpa2/services/network_status_service.dart';
import 'package:nlpa2/services/remote_gateway_service.dart';
import 'package:nlpa2/services/remote_profile_controller.dart';
import 'package:nlpa2/services/sms_relay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('RemoteGatewayService token generation', () {
    test('generateApiToken produces 43-char base64url string without padding', () {
      final token = RemoteGatewayService.generateApiToken();
      expect(token.length, equals(43));
      expect(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token), isTrue);
      expect(token.contains('='), isFalse);
    });

    test('consecutive generated tokens are distinct', () {
      final t1 = RemoteGatewayService.generateApiToken();
      final t2 = RemoteGatewayService.generateApiToken();
      expect(t1, isNot(equals(t2)));
    });
  });

  group('RemoteGatewayService download & safe two-step deletion', () {
    late MockProfileControl mockProfiles;
    late RemoteGatewayService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      mockProfiles = MockProfileControl(profiles: [
        const RemoteProfileEntry(
          iccid: '8901000000000000001',
          rawIccid: '8901000000000000001',
          alias: 'Default eSIM (+86)',
          enabled: true,
        ),
        const RemoteProfileEntry(
          iccid: '8901000000000000002',
          rawIccid: '8901000000000000002',
          alias: 'Test Inactive (+1)',
          enabled: false,
        ),
      ]);
      service = RemoteGatewayService(
        smsRelay: const FakeSmsRelay(),
        profiles: mockProfiles,
      );
      await service.start();
      await service.setDefaultProfile();
    });

    tearDown(() async {
      await service.stop();
    });

    test('downloadProfile downloads and adds profile', () async {
      final result = await service.downloadProfile('LPA:1\$rsp.truphone.com\$QRF-SPEEDTEST');
      expect(result['state'], equals('downloaded'));
      expect(result['iccid'], equals('8900000000000000999'));
      expect(mockProfiles.downloadedCodes, contains('LPA:1\$rsp.truphone.com\$QRF-SPEEDTEST'));
    });

    test('requestDeleteProfile rejects deleting currently active profile', () async {
      expect(
        () => service.requestDeleteProfile('8901000000000000001'),
        throwsA(isA<RemoteGatewayException>().having((e) => e.code, 'code', 'cannot_delete_active_profile')),
      );
    });

    test('requestDeleteProfile generates token for inactive profile', () async {
      final res = await service.requestDeleteProfile('8901000000000000002');
      expect(res['state'], equals('confirm_required'));
      expect(res['token'], isNotNull);
      expect(res['iccid'], equals('8901000000000000002'));
    });

    test('confirmDeleteProfile rejects wrong token and succeeds with correct token', () async {
      final req = await service.requestDeleteProfile('8901000000000000002');
      final token = req['token'] as String;

      expect(
        () => service.confirmDeleteProfile('wrong_token'),
        throwsA(isA<RemoteGatewayException>().having((e) => e.code, 'code', 'invalid_delete_token')),
      );

      final confirmRes = await service.confirmDeleteProfile(token);
      expect(confirmRes['state'], equals('deleted'));
      expect(confirmRes['iccid'], equals('8901000000000000002'));
      expect(mockProfiles.deletedIccids, contains('8901000000000000002'));
    });

    test('requestDeleteProfile rejects deleting saved default profile even if inactive', () async {
      // Switch active profile to profile 2
      await service.switchProfile('8901000000000000002');
      // Profile 1 is now inactive, but it remains the saved default profile
      expect(
        () => service.requestDeleteProfile('8901000000000000001'),
        throwsA(isA<RemoteGatewayException>().having((e) => e.code, 'code', 'cannot_delete_default_profile')),
      );
    });

    test('confirmation rechecks a default changed after the delete request', () async {
      final pending = await service.requestDeleteProfile('8901000000000000002');
      await mockProfiles.enableProfile('8901000000000000002');
      await service.setDefaultProfile();
      await mockProfiles.enableProfile('8901000000000000001');

      await expectLater(
        service.confirmDeleteProfile(pending['token'] as String),
        throwsA(isA<RemoteGatewayException>().having(
          (e) => e.code, 'code', 'cannot_delete_default_profile')),
      );
      expect(mockProfiles.profiles.map((p) => p.iccid), contains('8901000000000000002'));
    });

    test('changing default profile updates session default and allows deleting the former default profile', () async {
      await service.switchProfile('8901000000000000002');
      await service.setDefaultProfile();
      final pending = await service.requestDeleteProfile('8901000000000000001');
      expect(pending['state'], 'confirm_required');
      expect(pending['iccid'], '8901000000000000001');
    });

    test('permanent profile selection survives gateway restoration without a timer', () async {
      await service.switchProfile('8901000000000000002');
      final prefs = await SharedPreferences.getInstance();
      final session = prefs.getString('remote_gateway.session.v1')!;
      // stop() is an explicit back operation; simulate process loss by restoring
      // the saved on-disk state and the card that remains enabled across death.
      await service.stop();
      await mockProfiles.enableProfile('8901000000000000002');
      await prefs.setString('remote_gateway.session.v1', session);
      service = RemoteGatewayService(smsRelay: const FakeSmsRelay(), profiles: mockProfiles);
      await service.start();
      await Future<void>.delayed(Duration.zero);

      expect(mockProfiles.profiles.singleWhere((p) => p.enabled).iccid, '8901000000000000002');
      final status = await service.status();
      expect((status['session'] as Map)['state'], 'waiting_for_service');
      expect((status['session'] as Map)['remainingSeconds'], isNull);
    });

    test('failed enableProfile rolls back session instead of lying waiting_for_service', () async {
      mockProfiles.failNextEnable = true;
      await expectLater(
        service.switchProfile('8901000000000000002'),
        throwsA(isA<StateError>()),
      );
      final status = await service.status();
      expect(status['session'], isNull);
      expect(status['lastSwitchEpochMillis'], isNull);
    });

    test('failed revertProfile preserves active session instead of clearing it', () async {
      await service.switchProfile('8901000000000000002');
      mockProfiles.failNextEnable = true;
      await expectLater(
        service.revertProfile(),
        throwsA(isA<StateError>()),
      );
      final status = await service.status();
      expect((status['session'] as Map)['target'], 'Test Inactive (+1)');
    });

    test('external reader without slot number in readerId still transitions to ready on inService', () async {
      mockProfiles.slotIndexOverride = null;
      await service.switchProfile('8901000000000000002');
      mockProfiles.emitNetwork(
        const NetworkStatusUpdate(
          error: null,
          subscriptions: [
            NetworkStatusSubscription(
              subscriptionId: 2,
              slotIndex: 1,
              displayName: 'Roaming SIM',
              carrierName: 'Elisa',
              serviceState: 0,
              roaming: true,
              signalDbm: -79,
              signalLevel: 3,
              error: null,
            ),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final status = await service.status();
      expect((status['session'] as Map)['state'], 'ready');
      expect((status['network'] as Map)['carrier'], 'Elisa');
    });

    test('service can stop and restart cleanly', () async {
      await service.stop();
      expect(service.isRunning, isFalse);
      await service.start();
      expect(service.isRunning, isTrue);
    });

    test('Telegram callback_query cmd:download_test downloads Speedtest eSIM and returns inline keyboard actions', () async {
      const chatId = '10000001';
      final dlPayload = await service.handleTelegramUpdateForTesting({
        'update_id': 1001,
        'callback_query': {
          'id': 'cb_1',
          'from': {'id': 10000001, 'is_bot': false},
          'message': {
            'chat': {'id': 10000001, 'type': 'private'},
          },
          'data': 'cmd:download_test',
        },
      }, chatId);

      expect(dlPayload, isNotNull);
      expect(mockProfiles.downloadedCodes, contains(RemoteGatewayService.speedtestActivationCode));
      expect('${dlPayload!['text']}', contains('Speedtest 公开测试 eSIM 下载并安装成功'));
      expect('${dlPayload['text']}', contains('8900000000000000999'));
      final markup = dlPayload['reply_markup'] as Map<String, Object?>?;
      expect(markup, isNotNull);
      final rows = markup!['inline_keyboard'] as List;
      expect(rows, isNotEmpty);

      // Now request delete via callback_query del:3 (the newly added Speedtest card at slot 3)
      final delReqPayload = await service.handleTelegramUpdateForTesting({
        'update_id': 1002,
        'callback_query': {
          'id': 'cb_2',
          'from': {'id': 10000001, 'is_bot': false},
          'message': {
            'chat': {'id': 10000001, 'type': 'private'},
          },
          'data': 'del:3',
        },
      }, chatId);
      expect(delReqPayload, isNotNull);
      expect('${delReqPayload!['text']}', contains('Speedtest Test'));
      final delMarkup = delReqPayload['reply_markup'] as Map<String, Object?>;
      final delRows = delMarkup['inline_keyboard'] as List;
      final confirmBtn = (delRows.first as List).first as Map;
      final confirmCallbackData = '${confirmBtn['callback_data']}';
      expect(confirmCallbackData, startsWith('del_ok:'));

      // Confirm deletion via callback_query del_ok:<token>
      final delConfirmPayload = await service.handleTelegramUpdateForTesting({
        'update_id': 1003,
        'callback_query': {
          'id': 'cb_3',
          'from': {'id': 10000001, 'is_bot': false},
          'message': {
            'chat': {'id': 10000001, 'type': 'private'},
          },
          'data': confirmCallbackData,
        },
      }, chatId);
      expect(delConfirmPayload, isNotNull);
      expect('${delConfirmPayload!['text']}', contains('已成功从物理 eUICC 芯片中彻底删除'));
      expect(mockProfiles.deletedIccids, contains('8900000000000000999'));
    });

    test('v1.1.0 features: temporary 5-min switch, /rename, /keepalive, /readers, NVRAM/EID and battery health in /status & /list', () async {
      const chatId = '10000001';

      // 1. Check /list includes Free NVRAM KB, EID, and 5-min temp switch button
      final listPayload = await service.handleTelegramUpdateForTesting({
        'update_id': 2001,
        'message': {
          'chat': {'id': 10000001, 'type': 'private'},
          'from': {'id': 10000001, 'is_bot': false},
          'text': '/list',
        },
      }, chatId);
      expect(listPayload, isNotNull);
      expect('${listPayload!['text']}', contains('277.3 KB'));
      expect('${listPayload['text']}', contains('89049032000001234567'));

      // 2. Rename profile #2 via /rename 2 英国主力 +44
      final renamePayload = await service.handleTelegramUpdateForTesting({
        'update_id': 2002,
        'message': {
          'chat': {'id': 10000001, 'type': 'private'},
          'from': {'id': 10000001, 'is_bot': false},
          'text': '/rename 2 英国主力 +44',
        },
      }, chatId);
      expect(renamePayload, isNotNull);
      expect('${renamePayload!['text']}', contains('已成功重命名为：【英国主力 +44】'));
      expect(mockProfiles.profiles[1].alias, equals('英国主力 +44'));

      // 3. Configure keep-alive via callback_query ka_set:2:90 and trigger ka_now:2
      final kaSetPayload = await service.handleTelegramUpdateForTesting({
        'update_id': 2003,
        'callback_query': {
          'id': 'cb_ka1',
          'from': {'id': 10000001, 'is_bot': false},
          'message': {
            'chat': {'id': 10000001, 'type': 'private'},
          },
          'data': 'ka_set:2:90',
        },
      }, chatId);
      expect(kaSetPayload, isNotNull);
      expect('${kaSetPayload!['text']}', contains('每 90 天'));

      // 4. Temporary 5-minute OTP switch via use_temp:2
      final tempSwitchPayload = await service.handleTelegramUpdateForTesting({
        'update_id': 2004,
        'callback_query': {
          'id': 'cb_temp',
          'from': {'id': 10000001, 'is_bot': false},
          'message': {
            'chat': {'id': 10000001, 'type': 'private'},
          },
          'data': 'use_temp:2',
        },
      }, chatId);
      expect(tempSwitchPayload, isNotNull);
      expect('${tempSwitchPayload!['text']}', contains('5 分钟后将自动切回默认主卡'));

      // 5. Check /status includes battery health, NVRAM, and remaining countdown
      final statusPayload = await service.handleTelegramUpdateForTesting({
        'update_id': 2005,
        'callback_query': {
          'id': 'cb_st',
          'from': {'id': 10000001, 'is_bot': false},
          'message': {
            'chat': {'id': 10000001, 'type': 'private'},
          },
          'data': 'cmd:status',
        },
      }, chatId);
      expect(statusPayload, isNotNull);
      expect('${statusPayload!['text']}', contains('96%'));
      expect('${statusPayload['text']}', contains('自动回主卡'));

      // 6. Switch active reader via reader:2
      final readerSwitchPayload = await service.handleTelegramUpdateForTesting({
        'update_id': 2006,
        'callback_query': {
          'id': 'cb_rd',
          'from': {'id': 10000001, 'is_bot': false},
          'message': {
            'chat': {'id': 10000001, 'type': 'private'},
          },
          'data': 'reader:2',
        },
      }, chatId);
      expect(readerSwitchPayload, isNotNull);
      expect('${readerSwitchPayload!['text']}', contains('SIM 2'));
      expect(mockProfiles.selectedReaderId, equals('omapi:SIM2'));
    });
    test('telegram /kick command accelerates network search', () async {
      final kickPayload = await service.handleTelegramUpdateForTesting({
        'update_id': 9991,
        'message': {
          'message_id': 9991,
          'date': 1700000000,
          'chat': {'id': 10000001, 'type': 'private'},
          'from': {'id': 10000001, 'is_bot': false},
          'text': '/kick',
        },
      }, '10000001');
      expect(kickPayload, isNotNull);
      expect(kickPayload!['text'], contains('已向基带下发快速重搜与射频复位指令'));
      expect(mockProfiles.accelerateCalls, greaterThanOrEqualTo(1));
    });
  });
}

class FakeSmsRelay extends SmsRelayService {
  const FakeSmsRelay() : super();
  @override
  Future<RemoteGatewayConfiguration> loadGatewayConfiguration() async {
    return const RemoteGatewayConfiguration(
      enabled: true,
      apiToken: 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG',
      telegramToken: null,
      telegramChatId: null,
      canScheduleExactAlarms: false,
    );
  }
  @override
  Future<void> stopGateway() async {}
  @override
  Future<void> scheduleGatewayRevert(DateTime deadline) async {}
  @override
  Future<void> cancelGatewayRevert() async {}
  @override
  Future<int> retryFailedHistory({String? id}) async => 1;
  @override
  Future<DeviceHealthStatus> getDeviceHealth() async => const DeviceHealthStatus(
    batteryPercent: 96,
    charging: true,
    powerSource: 'AC',
    temperatureCelsius: 31.2,
    networkType: 'Wi-Fi',
  );
}

class MockProfileControl implements RemoteProfileControl {
  MockProfileControl({required this.profiles});
  List<RemoteProfileEntry> profiles;
  final List<String> deletedIccids = [];
  final List<String> downloadedCodes = [];
  final StreamController<NetworkStatusUpdate> _networkController =
      StreamController<NetworkStatusUpdate>.broadcast();
  bool failNextEnable = false;
  int? slotIndexOverride = 1;
  String currentReaderId = 'reader_0';

  void emitNetwork(NetworkStatusUpdate update) => _networkController.add(update);

  @override
  String? get selectedReaderId => currentReaderId;
  @override
  int? get networkSlotIndex => slotIndexOverride;

  @override
  Stream<NetworkStatusUpdate> get networkUpdates => _networkController.stream;

  @override
  Future<void> refreshNetworkStatus() async {}

  @override
  Future<List<RemoteProfileEntry>> listProfiles() async => profiles;

  @override
  Future<void> enableProfile(String iccid) async {
    if (failNextEnable) {
      failNextEnable = false;
      throw StateError('enable_failed');
    }
    profiles = profiles.map((p) => RemoteProfileEntry(
      iccid: p.iccid,
      rawIccid: p.rawIccid,
      alias: p.alias,
      enabled: p.iccid == iccid,
    )).toList();
  }

  @override
  Future<String> downloadProfile(
    String activationCode, {
    String? confirmationCode,
    void Function(String message)? onStatus,
  }) async {
    downloadedCodes.add(activationCode);
    const newIccid = '8900000000000000999';
    profiles.add(const RemoteProfileEntry(
      iccid: newIccid,
      rawIccid: newIccid,
      alias: 'Speedtest Test',
      enabled: false,
    ));
    return newIccid;
  }

  @override
  Future<void> deleteProfile(String iccid) async {
    deletedIccids.add(iccid);
    profiles.removeWhere((p) => p.iccid == iccid);
  }

  @override
  Future<void> purgeSwitchNotifications() async {}

  @override
  Future<RemoteCardResourceInfo> getCardResourceInfo() async =>
      const RemoteCardResourceInfo(
        eid: '89049032000001234567',
        freeNonVolatileMemoryBytes: 284000,
        freeVolatileMemoryBytes: 12000,
      );

  @override
  Future<void> renameProfile(String iccid, String nickname) async {
    final idx = profiles.indexWhere((p) => p.iccid == iccid);
    if (idx < 0) throw StateError('profile_not_found');
    final old = profiles[idx];
    profiles[idx] = RemoteProfileEntry(
      iccid: old.iccid,
      rawIccid: old.rawIccid,
      alias: nickname,
      enabled: old.enabled,
    );
  }
  int accelerateCalls = 0;
  @override
  Future<bool> accelerateNetworkSearch() async {
    accelerateCalls++;
    return true;
  }

  @override
  Future<List<RemoteReaderEntry>> listReaders() async => [
    RemoteReaderEntry(
      id: 'reader_0',
      name: 'SIM 1',
      selected: currentReaderId == 'reader_0',
    ),
    RemoteReaderEntry(
      id: 'omapi:SIM2',
      name: 'SIM 2',
      selected: currentReaderId == 'omapi:SIM2',
    ),
  ];

  @override
  Future<RemoteReaderEntry> selectReader(String selector) async {
    final all = await listReaders();
    final idx = int.tryParse(selector);
    final target = (idx != null && idx >= 1 && idx <= all.length)
        ? all[idx - 1]
        : all.firstWhere(
            (r) =>
                r.id.toLowerCase().contains(selector.toLowerCase()) ||
                r.name.toLowerCase().contains(selector.toLowerCase()),
            orElse: () => throw StateError('reader_not_found'),
          );
    currentReaderId = target.id;
    return RemoteReaderEntry(id: target.id, name: target.name, selected: true);
  }
}

