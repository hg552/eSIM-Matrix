import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/network_status_service.dart';
import 'package:nlpa2/services/remote_gateway_service.dart';
import 'package:nlpa2/services/remote_profile_controller.dart';
import 'package:nlpa2/services/sms_relay_service.dart';
import 'package:nlpa2/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; // 43 chars

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The REST listener is a real socket; the test HTTP client must not be the
  // flutter_test override that answers 400 to everything.
  setUpAll(() {
    HttpOverrides.global = null;
  });

  group('Remote gateway REST surface', () {
    late _Profiles profiles;
    late _Relay relay;
    late RemoteGatewayService service;
    late HttpClient client;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await AppSettings().setDataGuardEnabled(true);
      await AppSettings().setProxyLinkageEnabled(false);
      profiles = _Profiles();
      relay = _Relay();
      service = RemoteGatewayService(
        smsRelay: relay,
        profiles: profiles,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      client = HttpClient();
      await service.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });

    tearDown(() async {
      client.close(force: true);
      await service.stop();
    });

    Future<HttpClientResponse> get(String path, {bool auth = true}) async {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${RemoteGatewayService.port}$path'),
      );
      if (auth) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      }
      return request.close();
    }

    Future<({int status, Object? body})> post(
      String path, {
      Map<String, Object?>? payload,
      bool auth = true,
    }) async {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${RemoteGatewayService.port}$path'),
      );
      if (auth) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      }
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload ?? const <String, Object?>{}));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return (
        status: response.statusCode,
        body: text.isEmpty ? null : jsonDecode(text),
      );
    }

    test('dashboard root is served as HTML without a token', () async {
      final response = await get('/', auth: false);
      final body = await response.transform(utf8.decoder).join();
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, 'text/html');
      // The console is useless if the token gate or the data-guard panel is
      // missing, so both are asserted as part of the served document.
      expect(body, contains('id="login"'));
      expect(body, contains('id="guardBox"'));
      expect(body, contains('/api/v1/dashboard'));
    });

    test('dashboard endpoint rejects a missing token', () async {
      final response = await get('/api/v1/dashboard', auth: false);
      expect(response.statusCode, HttpStatus.unauthorized);
      await response.drain<void>();
    });

    test('dashboard endpoint returns status, profiles, messages and data guard', () async {
      final response = await get('/api/v1/dashboard');
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.transform(utf8.decoder).join()) as Map;

      final status = body['status'] as Map;
      expect(status['gateway'], 'running');
      expect((status['device'] as Map)['batteryPercent'], 96);
      expect(status['proxy'], isA<Map>());
      expect(status['dataGuard'], isA<Map>());
      expect((status['dataGuard'] as Map)['enabled'], isTrue);

      final profiles = (body['profiles'] as List).cast<Map>();
      expect(profiles.length, 2);
      expect(profiles.first['iccidPrefix'], '890100');

      final messages = (body['messages'] as List).cast<Map>();
      expect(messages.length, 2);
      expect(messages.first['otp'], '194820');

      final guard = body['dataGuard'] as Map;
      expect((guard['capabilities'] as Map)['canEnforce'], isFalse);
      expect(guard['subscriptions'], isA<List>());
    });

    test('sms history endpoint honours the limit and keeps otp', () async {
      final response = await get('/api/v1/sms/history?limit=1');
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.transform(utf8.decoder).join()) as Map;
      final messages = (body['messages'] as List).cast<Map>();
      expect(messages.length, 1);
      expect(messages.single['otp'], '194820');
      expect(messages.single['delivered'], isTrue);
    });

    test('data guard config toggles are persisted and echoed', () async {
      final result = await post(
        '/api/v1/dataguard',
        payload: {'enabled': false, 'restoreOnRevert': false},
      );
      expect(result.status, HttpStatus.ok);
      final body = result.body! as Map;
      expect(body['enabled'], isFalse);
      expect(body['restoreOnRevert'], isFalse);

      final status = (jsonDecode(
        await (await get('/api/v1/status')).transform(utf8.decoder).join(),
      ) as Map)['dataGuard'] as Map;
      expect(status['enabled'], isFalse);
      expect(status['restoreOnRevert'], isFalse);
    });

    test('data guard apply reports a missing subscription instead of faking success', () async {
      final result = await post('/api/v1/dataguard/apply');
      expect(result.status, HttpStatus.conflict);
      expect((result.body! as Map)['error'], 'subscription_not_found');
    });

    Map<String, Object?> textCommand(String name, [String argument = '']) {
      final text = argument.isEmpty ? '/$name' : '/$name $argument';
      return {
        'update_id': 900,
        'message': {
          'message_id': 900,
          'from': {'id': 10000001, 'is_bot': false},
          'chat': {'id': 10000001, 'type': 'private'},
          'text': text,
        },
      };
    }

    test('guard command reports state and the real enforcement capability', () async {
      final payload = await service.handleTelegramUpdateForTesting(
        textCommand('guard'),
        '10000001',
      );
      final text = '${payload!['text']}';
      expect(text, contains('流量卫士'));
      expect(text, contains('强制能力'));
      // The test host has no MODIFY_PHONE_STATE and no root, so the reply must
      // state that enforcement is unavailable rather than imply it worked.
      expect(text, contains('不可用'));
      final rows = (payload['reply_markup'] as Map)['inline_keyboard'] as List;
      expect(rows, isNotEmpty);
    });

    test('guard_toggle flips the persisted setting', () async {
      final before = AppSettings().dataGuardEnabled;
      await service.handleTelegramUpdateForTesting(
        textCommand('guard_toggle'),
        '10000001',
      );
      expect(AppSettings().dataGuardEnabled, isNot(before));
    });

    test('proxy command explains the controller state and where to configure it', () async {
      final payload = await service.handleTelegramUpdateForTesting(
        textCommand('proxy'),
        '10000001',
      );
      final text = '${payload!['text']}';
      expect(text, contains('代理联动'));
      expect(text, contains('控制器'));
      expect(text, contains('配置入口'));
      // No Clash controller runs in the test host: it must say disconnected.
      expect(text, contains('未连接'));
    });

    test('tunnel command surfaces the Cloudflare channel with a masked id', () async {
      final payload = await service.handleTelegramUpdateForTesting(
        textCommand('tunnel'),
        '10000001',
      );
      final text = '${payload!['text']}';
      expect(text, contains('Cloudflare 加密隧道'));
      expect(text, contains('通道 ID'));
      expect(text, contains('加密存储'));
      expect(text, contains('配置位置'));
      // The full channel id must never be printed back to the chat.
      expect(text, isNot(contains('ch_7a4c947e0aa1')));
      expect(text, contains('ch_7a4…0aa1'));
    });
  });
}

class _Profiles implements RemoteProfileControl {
  final List<RemoteProfileEntry> _entries = const [
    RemoteProfileEntry(
      iccid: '8901000000000000001',
      rawIccid: '8901000000000000001',
      alias: 'ClubSim HK (+852)',
      enabled: true,
    ),
    RemoteProfileEntry(
      iccid: '8901000000000000002',
      rawIccid: '8901000000000000002',
      alias: 'Saily US (+1 805)',
      enabled: false,
    ),
  ];
  final StreamController<NetworkStatusUpdate> _networks =
      StreamController<NetworkStatusUpdate>.broadcast();

  @override
  String? get selectedReaderId => 'reader_0';

  @override
  int? get networkSlotIndex => 1;

  @override
  Stream<NetworkStatusUpdate> get networkUpdates => _networks.stream;

  @override
  Future<void> refreshNetworkStatus() async {}

  @override
  Future<List<RemoteProfileEntry>> listProfiles() async => _entries;

  @override
  Future<void> enableProfile(String iccid) async {
    profilesEnabled = iccid;
  }

  String? profilesEnabled;

  @override
  Future<String> downloadProfile(
    String activationCode, {
    String? confirmationCode,
    void Function(String message)? onStatus,
  }) async => '';

  @override
  Future<void> deleteProfile(String iccid) async {}

  @override
  Future<void> purgeSwitchNotifications() async {}

  @override
  Future<void> renameProfile(String iccid, String nickname) async {}

  @override
  Future<RemoteCardResourceInfo> getCardResourceInfo() async =>
      const RemoteCardResourceInfo(eid: '89049032005008882600033148712345');

  @override
  Future<List<RemoteReaderEntry>> listReaders() async => const [
    RemoteReaderEntry(id: 'reader_0', name: 'SIM2', selected: true),
  ];

  @override
  Future<RemoteReaderEntry> selectReader(String selector) async =>
      const RemoteReaderEntry(id: 'reader_0', name: 'SIM2', selected: true);
  @override
  Future<bool> accelerateNetworkSearch() async => true;
}

class _Relay extends SmsRelayService {
  const _Relay();

  @override
  Future<RemoteGatewayConfiguration> loadGatewayConfiguration() async {
    return const RemoteGatewayConfiguration(
      enabled: true,
      apiToken: _token,
      telegramToken: null,
      telegramChatId: null,
      canScheduleExactAlarms: false,
    );
  }

  @override
  Future<void> startGateway() async {}

  @override
  Future<void> stopGateway() async {}

  @override
  Future<void> scheduleGatewayRevert(DateTime deadline) async {}

  @override
  Future<void> cancelGatewayRevert() async {}

  @override
  Future<DeviceHealthStatus> getDeviceHealth() async => const DeviceHealthStatus(
    batteryPercent: 96,
    charging: true,
    powerSource: 'AC',
    temperatureCelsius: 31.2,
    networkType: 'Wi-Fi',
  );

  @override
  Future<List<SmsHistoryEntry>> loadHistory() async => [
    SmsHistoryEntry(
      id: 'newest',
      sender: 'AuthBank',
      body: 'Your verification code is 194820.',
      otp: '194820',
      slotIndex: 1,
      carrierName: 'Elisa',
      receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
      mode: SmsRelayMode.telegram,
      delivered: true,
      errorCode: null,
    ),
    SmsHistoryEntry(
      id: 'older',
      sender: 'ServiceAlert',
      body: 'No numeric code here.',
      otp: null,
      slotIndex: 1,
      carrierName: 'Elisa',
      receivedAtMillis: DateTime.now().millisecondsSinceEpoch - 60000,
      mode: SmsRelayMode.telegram,
      delivered: false,
      errorCode: 'network_error',
    ),
  ];

  @override
  Future<SmsRelayConfiguration> loadConfiguration() async =>
      const SmsRelayConfiguration(
        mode: SmsRelayMode.cfWorker,
        enabled: true,
        endpoint: 'https://nexus-relay.example.workers.dev',
        telegramChatId: null,
        cfChannelId: 'ch_7a4c947e0aa1',
        tokenConfigured: true,
        webhookTokenConfigured: false,
        telegramTokenConfigured: false,
        cfTokenConfigured: true,
        lastDeliveryAtMillis: null,
        lastDeliveryError: null,
      );

  @override
  Future<int> retryFailedHistory({String? id}) async => 1;
}
