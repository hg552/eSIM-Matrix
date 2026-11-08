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

/// Minimal control surface: applyProxyForProfile only reads AppSettings and
/// talks to the Clash HTTP controller, so no card access is needed here.
class _StubProfiles implements RemoteProfileControl {
  final StreamController<NetworkStatusUpdate> _updates =
      StreamController<NetworkStatusUpdate>.broadcast();

  @override
  String? get selectedReaderId => 'reader_0';
  @override
  int? get networkSlotIndex => 1;
  @override
  Stream<NetworkStatusUpdate> get networkUpdates => _updates.stream;
  @override
  Future<void> refreshNetworkStatus() async {}
  @override
  Future<List<RemoteProfileEntry>> listProfiles() async => const [];
  @override
  Future<void> enableProfile(String iccid) async {}
  @override
  Future<String> downloadProfile(
    String activationCode, {
    String? confirmationCode,
    void Function(String message)? onStatus,
  }) async =>
      '';
  @override
  Future<void> deleteProfile(String iccid) async {}
  @override
  Future<void> purgeSwitchNotifications() async {}
  @override
  Future<void> renameProfile(String iccid, String nickname) async {}
  @override
  Future<RemoteCardResourceInfo> getCardResourceInfo() async =>
      const RemoteCardResourceInfo();
  @override
  Future<List<RemoteReaderEntry>> listReaders() async => const [];
  @override
  Future<RemoteReaderEntry> selectReader(String selector) async =>
      const RemoteReaderEntry(id: 'reader_0', name: 'SIM2', selected: true);
  @override
  Future<bool> accelerateNetworkSearch() async => true;
}

const List<String> _nodes = [
  '🇭🇰 香港 01',
  '🇺🇸 美国 01',
  '🇩🇪 德国 01',
  'DIRECT',
  '剩余流量: 100GB',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  group('Per-profile proxy node binding', () {
    late HttpServer server;
    late String currentNode;
    final putBodies = <Map<String, dynamic>>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      putBodies.clear();
      currentNode = '🇭🇰 香港 01';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final path = request.uri.path;
        if (request.method == 'PUT' && path == '/proxies/PROXY') {
          final body = await utf8.decoder.bind(request).join();
          putBodies.add(jsonDecode(body) as Map<String, dynamic>);
          currentNode = (jsonDecode(body) as Map)['name'] as String;
          request.response.statusCode = HttpStatus.noContent;
        } else if (request.method == 'GET' && path == '/version') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'version': 'mock-mihomo'}));
        } else if (request.method == 'GET' &&
            (path == '/proxies/PROXY' || path == '/proxies')) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'name': 'PROXY',
            'type': 'Selector',
            'now': currentNode,
            'all': _nodes,
          }));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });

      final settings = AppSettings();
      await settings.setProxyControllerUrl('http://127.0.0.1:${server.port}');
      await settings.setProxySecret(null);
      await settings.setProxyTargetGroup('PROXY');
      await settings.setProxyLinkageEnabled(true);
      await settings.setProxyCustomRules(const {});
    });

    tearDown(() async => server.close(force: true));

    RemoteGatewayService newService() => RemoteGatewayService(
          smsRelay: const SmsRelayService(),
          profiles: _StubProfiles(),
        );

    test('settings store and clear a binding by ICCID', () async {
      final settings = AppSettings();
      expect(settings.proxyNodeForIccid('8901'), isNull);
      await settings.setProxyNodeForIccid('8901', '  🇺🇸 美国 01  ');
      expect(settings.proxyNodeForIccid('8901'), '🇺🇸 美国 01');
      await settings.setProxyNodeForIccid('8902', '🇯🇵 日本 01');
      expect(settings.proxyCustomRules.length, 2);
      await settings.setProxyNodeForIccid('8901', '');
      expect(settings.proxyNodeForIccid('8901'), isNull);
      expect(settings.proxyCustomRules.length, 1);
    });

    test('an explicit binding wins over the country resolver', () async {
      await AppSettings().setProxyCustomRules(const {
        '8901000000000000001': '🇺🇸 美国 01',
      });
      final result = await newService().applyProxyForProfile(
        iccid: '8901000000000000001',
        alias: 'ClubSim HK (+852)', // would otherwise pick the HK node
      );
      expect(result, isNotNull);
      expect(result!.success, isTrue);
      expect(result.currentNode, '🇺🇸 美国 01');
      expect(putBodies.single['name'], '🇺🇸 美国 01');
    });

    test('without a binding the country resolver still applies', () async {
      final result = await newService().applyProxyForProfile(
        iccid: '8948000000000000003',
        alias: 'Elisa Estonia (+372)',
      );
      expect(result, isNotNull);
      expect(result!.success, isTrue);
      // No Estonian node in the pool: regional fallback picks Germany.
      expect(putBodies.single['name'], '🇩🇪 德国 01');
    });

    test('a binding missing from the live node list falls back, never fails',
        () async {
      await AppSettings().setProxyCustomRules(const {
        '8901000000000000001': '🇯🇵 已下线的旧节点',
      });
      // Make the fallback observable: the controller currently sits on US,
      // so falling back to the HK card must actually issue a PUT.
      currentNode = '🇺🇸 美国 01';
      final result = await newService().applyProxyForProfile(
        iccid: '8901000000000000001',
        alias: 'ClubSim HK (+852)',
      );
      expect(result, isNotNull);
      expect(result!.success, isTrue);
      expect(putBodies.single['name'], '🇭🇰 香港 01');
    });

    test('disabled linkage is a no-op and touches nothing', () async {
      await AppSettings().setProxyLinkageEnabled(false);
      await AppSettings().setProxyCustomRules(const {
        '8901000000000000001': '🇺🇸 美国 01',
      });
      final result = await newService().applyProxyForProfile(
        iccid: '8901000000000000001',
        alias: 'ClubSim HK (+852)',
      );
      expect(result, isNull);
      expect(putBodies, isEmpty);
    });
  });
}
