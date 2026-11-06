import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/settings/app_settings.dart';
import 'package:nlpa2/widgets/profiles_screen/proxy_node_picker_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const List<String> _nodes = ['🇭🇰 香港 01', '🇺🇸 美国 01', '🇩🇪 德国 01', 'DIRECT'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  group('ProxyNodePickerDialog', () {
    late HttpServer server;

    Future<void> configure(String url) async {
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings();
      await settings.setProxyControllerUrl(url);
      await settings.setProxySecret(null);
      await settings.setProxyTargetGroup('PROXY');
      await settings.setProxyCustomRules(const {});
    }

    Future<void> pumpPicker(
      WidgetTester tester,
      void Function(String?) onResult, {
      String? currentNode,
      List<String>? initialNodes,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final value = await showDialog<String>(
                    context: context,
                    builder: (_) => ProxyNodePickerDialog(
                      profileName: 'Saily US (+1)',
                      iccid: '8901000000000000001',
                      currentNode: currentNode,
                      settings: AppSettings(),
                      initialNodes: initialNodes,
                    ),
                  );
                  onResult(value);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      // The picker talks to a real loopback socket, which needs runAsync.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump();
    }

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.method == 'GET' &&
            (request.uri.path == '/proxies/PROXY' ||
                request.uri.path == '/proxies')) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'name': 'PROXY',
            'type': 'Selector',
            'now': '🇭🇰 香港 01',
            'all': _nodes,
          }));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      await configure('http://127.0.0.1:${server.port}');
    });

    tearDown(() async => server.close(force: true));

    testWidgets('lists live controller nodes and returns the picked one',
        (tester) async {
      String? result;
      await pumpPicker(tester, (value) => result = value,
          initialNodes: _nodes);

      expect(find.text('🇺🇸 美国 01'), findsOneWidget);
      expect(find.text('自动匹配（按卡国别）'), findsOneWidget);
      expect(find.text('已指定代理节点'), findsNothing);

      await tester.tap(find.text('🇺🇸 美国 01'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(result, '🇺🇸 美国 01');
    });

    testWidgets('auto-match option clears the binding', (tester) async {
      await AppSettings().setProxyNodeForIccid(
        '8901000000000000001',
        '🇺🇸 美国 01',
      );
      String? result;
      await pumpPicker(
        tester,
        (value) => result = value,
        currentNode: '🇺🇸 美国 01',
        initialNodes: _nodes,
      );

      expect(find.text('🇺🇸 美国 01'), findsOneWidget);
      await tester.tap(find.text('自动匹配（按卡国别）'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(result, '');
    });

    testWidgets('controller offline falls back to a manual node field',
        (tester) async {
      await configure('http://127.0.0.1:49999');
      String? result;
      await pumpPicker(tester, (value) => result = value);

      expect(find.text('控制器未连接或策略组为空，可手动输入节点名：'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '🇯🇵 自定义节点');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(result, '🇯🇵 自定义节点');
    });
  });
}
