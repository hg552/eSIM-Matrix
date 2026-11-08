import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/proxy_linkage_service.dart';

/// A selector only accepts the names in its own `all` list. The console used to
/// render every node in the profile, so it offered switches the controller would
/// reject and buried the real choices among policy nodes (PASS, REJECT-DROP).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  late HttpServer server;
  late ProxyLinkageService service;

  /// `all` deliberately omits nodes that `/proxies` knows about, and names one
  /// that `/proxies` does not describe, because both happen in real profiles.
  const groupAll = <String>['🇭🇰 香港 01', '🇺🇸 美国 01', 'DIRECT', 'Nested Group'];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      request.response.headers.contentType = ContentType.json;
      if (path == '/proxies/PROXY') {
        request.response.write(jsonEncode({
          'name': 'PROXY',
          'type': 'Selector',
          'now': '🇭🇰 香港 01',
          'all': groupAll,
        }));
      } else if (path == '/proxies') {
        request.response.write(jsonEncode({
          'proxies': {
            'PROXY': {
              'name': 'PROXY',
              'type': 'Selector',
              'now': '🇭🇰 香港 01',
              'all': groupAll,
            },
            '🇭🇰 香港 01': {
              'type': 'Vless',
              'udp': true,
              'history': [
                {'delay': 88},
              ],
            },
            '🇺🇸 美国 01': {'type': 'Hysteria2', 'udp': true},
            'DIRECT': {'type': 'Direct', 'udp': false},
            // Reachable through /proxies but not a member of PROXY.
            '🇯🇵 日本 01': {'type': 'Vless', 'udp': true},
            'PASS': {'type': 'Pass', 'udp': false},
          },
        }));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    service = ProxyLinkageService(
      controllerUrl: 'http://127.0.0.1:${server.port}',
    );
  });

  tearDown(() async {
    service.close();
    await server.close(force: true);
  });

  test('lists the group members, not every node in the profile', () async {
    final nodes = await service.listGroupNodes('PROXY');
    final names = nodes.map((n) => n.name).toList();

    expect(names, groupAll);
    expect(names, contains('DIRECT'));
    expect(
      names,
      isNot(contains('🇯🇵 日本 01')),
      reason: 'a node outside the group cannot be selected from it',
    );
    expect(names, isNot(contains('PASS')));
  });

  test('keeps the delay the controller already measured', () async {
    final nodes = await service.listGroupNodes('PROXY');
    final hk = nodes.firstWhere((n) => n.name == '🇭🇰 香港 01');
    expect(hk.delay, 88);
    expect(hk.type, 'Vless');
  });

  test('still lists a member the controller does not describe', () async {
    final nodes = await service.listGroupNodes('PROXY');
    final nested = nodes.firstWhere((n) => n.name == 'Nested Group');
    expect(nested.type, 'Unknown');
    expect(nested.delay, isNull);
  });

  test('an unknown group yields nothing instead of the whole profile', () async {
    expect(await service.listGroupNodes('NO-SUCH-GROUP'), isEmpty);
    expect(await service.listGroupNodes(''), isEmpty);
  });
}
