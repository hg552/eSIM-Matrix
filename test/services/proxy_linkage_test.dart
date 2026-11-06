import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/proxy_linkage_service.dart';
import 'package:nlpa2/services/proxy_mapping_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProxyMappingResolver', () {
    const resolver = ProxyMappingResolver();

    final testCandidates = <String>[
      'DIRECT',
      'REJECT',
      '剩余流量: 500GB',
      '🇭🇰 香港 01 [BGP专线]',
      '🇭🇰 香港 02 [原生IP]',
      '🇺🇸 美国 01 [优化线路]',
      '🇺🇸 美国 02 [洛杉矶BGP]',
      '🇯🇵 日本 01 [东京]',
      '🇸🇬 新加坡 01',
      '🇬🇧 英国 01',
      '🇩🇪 德国 01 [法兰克福]',
      '🇹🇼 台湾 01',
    ];

    test('extracts country code from flag emoji', () {
      expect(resolver.extractCountryCode(alias: '🇺🇸 Saily eSIM'), equals('US'));
      expect(resolver.extractCountryCode(alias: '🇭🇰 ClubSim'), equals('HK'));
      expect(resolver.extractCountryCode(alias: '🇬🇧 Giffgaff'), equals('GB'));
      expect(resolver.extractCountryCode(alias: '🇪🇪 Elisa'), equals('EE'));
      expect(resolver.extractCountryCode(alias: '🇯🇵 IIJmio'), equals('JP'));
    });

    test('extracts country code from phone prefix', () {
      expect(resolver.extractCountryCode(alias: 'US Phone (+1 805)'), equals('US'));
      expect(resolver.extractCountryCode(alias: 'CSL Mobile (+852 9123)'), equals('HK'));
      expect(resolver.extractCountryCode(alias: 'Travel eSIM (+372 5123)'), equals('EE'));
      expect(resolver.extractCountryCode(alias: 'UK SIM (+44 7123)'), equals('GB'));
    });

    test('extracts country code from keywords or MCC', () {
      expect(resolver.extractCountryCode(alias: 'T-Mobile America'), equals('US'));
      expect(resolver.extractCountryCode(mcc: '310'), equals('US'));
      expect(resolver.extractCountryCode(mcc: '454'), equals('HK'));
      expect(resolver.extractCountryCode(mcc: '248'), equals('EE'));
    });

    test('resolves US profile to US proxy node', () {
      final res = resolver.resolveNode(
        candidates: testCandidates,
        alias: '🇺🇸 Saily (+1 805)',
      );
      expect(res.matched, isTrue);
      expect(res.countryCode, equals('US'));
      expect(res.nodeName, equals('🇺🇸 美国 01 [优化线路]'));
      expect(res.confidence, equals('exact_country'));
    });

    test('resolves HK profile to HK proxy node', () {
      final res = resolver.resolveNode(
        candidates: testCandidates,
        alias: 'ClubSim (+852)',
      );
      expect(res.matched, isTrue);
      expect(res.countryCode, equals('HK'));
      expect(res.nodeName, equals('🇭🇰 香港 01 [BGP专线]'));
    });

    test('falls back to regional EU/DE node when Estonia node is absent', () {
      final res = resolver.resolveNode(
        candidates: testCandidates,
        alias: 'Elisa Estonia (+372)',
      );
      expect(res.matched, isTrue);
      expect(res.countryCode, equals('EE'));
      // No Estonia node in testCandidates, falls back to Germany
      expect(res.nodeName, equals('🇩🇪 德国 01 [法兰克福]'));
      expect(res.confidence, equals('regional_fallback'));
    });

    test('custom rule override takes precedence over auto matching', () {
      final customRules = {
        '8901000000000000001': '🇯🇵 日本 01 [东京]',
        'custom_us': '.*洛杉矶.*',
      };
      // Explicit ICCID custom rule
      final res1 = resolver.resolveNode(
        candidates: testCandidates,
        iccid: '8901000000000000001',
        alias: '🇺🇸 Saily US',
        customRules: customRules,
      );
      expect(res1.matched, isTrue);
      expect(res1.nodeName, equals('🇯🇵 日本 01 [东京]'));
      expect(res1.confidence, equals('custom_rule'));

      // Regex custom rule
      final res2 = resolver.resolveNode(
        candidates: testCandidates,
        alias: 'custom_us',
        customRules: customRules,
      );
      expect(res2.matched, isTrue);
      expect(res2.nodeName, equals('🇺🇸 美国 02 [洛杉矶BGP]'));
      expect(res2.confidence, equals('custom_rule'));
    });

    test('ignores metadata/status nodes', () {
      final res = resolver.resolveNode(
        candidates: ['DIRECT', 'REJECT', '剩余流量: 100G'],
        alias: '🇺🇸 Saily',
      );
      expect(res.matched, isFalse);
    });
  });

  group('ProxyLinkageService Mock HTTP server integration', () {
    late HttpServer mockServer;
    late ProxyLinkageService proxyService;
    String currentProxyNode = '🇭🇰 香港 01';
    final requestLog = <String>[];

    setUp(() async {
      requestLog.clear();
      currentProxyNode = '🇭🇰 香港 01';

      mockServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      mockServer.listen((HttpRequest request) async {
        requestLog.add('${request.method} ${request.uri.path}');
        final auth = request.headers.value(HttpHeaders.authorizationHeader);

        if (request.uri.path == '/version') {
          if (auth != 'Bearer test_secret') {
            request.response.statusCode = HttpStatus.unauthorized;
            await request.response.close();
            return;
          }
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'version': 'Mihomo v1.18.0'}));
          await request.response.close();
        } else if (request.uri.path == '/proxies') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'proxies': {
              'GLOBAL': {
                'name': 'GLOBAL',
                'type': 'Selector',
                'now': currentProxyNode,
                'all': ['DIRECT', 'PROXY'],
              },
              'PROXY': {
                'name': 'PROXY',
                'type': 'Selector',
                'now': currentProxyNode,
                'all': ['🇭🇰 香港 01', '🇺🇸 美国 01', '🇯🇵 日本 01'],
              },
              '🇭🇰 香港 01': {'name': '🇭🇰 香港 01', 'type': 'Shadowsocks'},
              '🇺🇸 美国 01': {'name': '🇺🇸 美国 01', 'type': 'Shadowsocks'},
              '🇯🇵 日本 01': {'name': '🇯🇵 日本 01', 'type': 'Shadowsocks'},
            }
          }));
          await request.response.close();
        } else if (request.uri.path.startsWith('/proxies/')) {
          final groupName = Uri.decodeComponent(request.uri.path.substring('/proxies/'.length));
          if (request.method == 'GET') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'name': groupName,
              'type': 'Selector',
              'now': currentProxyNode,
              'all': ['🇭🇰 香港 01', '🇺🇸 美国 01', '🇯🇵 日本 01'],
            }));
            await request.response.close();
          } else if (request.method == 'PUT') {
            final bodyStr = await utf8.decodeStream(request);
            final body = jsonDecode(bodyStr) as Map<String, dynamic>;
            final targetNode = body['name'] as String;
            currentProxyNode = targetNode;
            request.response.statusCode = HttpStatus.noContent;
            await request.response.close();
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });

      proxyService = ProxyLinkageService(
        controllerUrl: 'http://${mockServer.address.host}:${mockServer.port}',
        secret: 'test_secret',
        timeout: const Duration(seconds: 2),
      );
    });

    tearDown(() async {
      await mockServer.close(force: true);
    });

    test('testConnection checks health and authentication', () async {
      final conn = await proxyService.testConnection();
      expect(conn.alive, isTrue);
      expect(conn.version, equals('Mihomo v1.18.0'));

      // Test with wrong secret
      final wrongSecretService = ProxyLinkageService(
        controllerUrl: 'http://${mockServer.address.host}:${mockServer.port}',
        secret: 'wrong_secret',
      );
      final connWrong = await wrongSecretService.testConnection();
      expect(connWrong.alive, isFalse);
      expect(connWrong.error, equals('unauthorized_secret'));
    });

    test('getSelectorGroups discovers selector groups', () async {
      final groups = await proxyService.getSelectorGroups();
      expect(groups.length, equals(2));
      expect(groups.map((g) => g.name), containsAll(['GLOBAL', 'PROXY']));
      final proxyGroup = groups.firstWhere((g) => g.name == 'PROXY');
      expect(proxyGroup.now, equals('🇭🇰 香港 01'));
      expect(proxyGroup.all, contains('🇺🇸 美国 01'));
    });

    test('selectNode switches node successfully', () async {
      final result = await proxyService.selectNode('PROXY', '🇺🇸 美国 01');
      expect(result.success, isTrue);
      expect(result.group, equals('PROXY'));
      expect(result.previousNode, equals('🇭🇰 香港 01'));
      expect(result.currentNode, equals('🇺🇸 美国 01'));
      expect(currentProxyNode, equals('🇺🇸 美国 01'));
    });

    test('snapshot and restore workflow', () async {
      // 1. Take snapshot when initial node is HK
      final snap = await proxyService.snapshot('PROXY');
      expect(snap, isNotNull);
      expect(snap!.node, equals('🇭🇰 香港 01'));

      // 2. Switch to US node for OTP receiving
      final switchRes = await proxyService.selectNode('PROXY', '🇺🇸 美国 01');
      expect(switchRes.success, isTrue);
      expect(currentProxyNode, equals('🇺🇸 美国 01'));

      // 3. Revert to original snapshot
      final restoreRes = await proxyService.restore(snap);
      expect(restoreRes.success, isTrue);
      expect(restoreRes.currentNode, equals('🇭🇰 香港 01'));
      expect(currentProxyNode, equals('🇭🇰 香港 01'));
    });

    test('handles controller offline gracefully without throwing', () async {
      final deadService = ProxyLinkageService(
        controllerUrl: 'http://127.0.0.1:49999',
        timeout: const Duration(milliseconds: 300),
      );

      final conn = await deadService.testConnection();
      expect(conn.alive, isFalse);

      final groups = await deadService.getSelectorGroups();
      expect(groups, isEmpty);

      final switchRes = await deadService.selectNode('PROXY', 'US-01');
      expect(switchRes.success, isFalse);
    });
  });
}
