import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/pages/location_console_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The console exists so the virtual location can be driven without touching an
/// eSIM at all. These tests pin that: nothing here provides a profile, reader or
/// ICCID, and every action still has to reach the native mock-location channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ee.nekoko.mock_location');
  final List<MethodCall> calls = <MethodCall>[];

  void answerStatus(Map<String, dynamic> Function() status) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getStatus':
          return status();
        case 'startMockLocation':
          return true;
        case 'stopMockLocation':
          return true;
        default:
          return null;
      }
    });
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    calls.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpConsole(WidgetTester tester) async {
    // The console is a phone page: the default 800x600 test surface cuts off the
    // sections below the fold and their taps would miss.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: LocationConsolePage()),
    );
    await tester.pumpAndSettle();
  }

  /// The console scrolls; a tap on an off-screen button silently misses, which
  /// would make the assertions below vacuous.
  Future<void> tapInject(WidgetTester tester) async {
    final inject = find.text('注入当前坐标');
    await tester.ensureVisible(inject);
    await tester.pumpAndSettle();
    await tester.tap(inject);
    await tester.pumpAndSettle();
  }

  testWidgets('works with no card and reports the providers in effect',
      (tester) async {
    answerStatus(() => <String, dynamic>{
          'isMocking': true,
          'mode': 'system',
          'latitude': 22.3193,
          'longitude': 114.1694,
          'accuracy': 3.0,
          'isMockApp': true,
          'isShizukuAvailable': false,
          'providers': <String>['gps', 'network'],
        });

    await pumpConsole(tester);

    expect(find.text('🟢 正在注入'), findsOneWidget);
    expect(find.text('22.31930, 114.16940'), findsOneWidget);
    expect(find.text('gps / network'), findsOneWidget);
    expect(find.textContaining('系统模拟位置：✅ 已授权'), findsOneWidget);
  });

  testWidgets('says so when no test provider could be registered',
      (tester) async {
    answerStatus(() => <String, dynamic>{
          'isMocking': false,
          'mode': 'system',
          'latitude': 0.0,
          'longitude': 0.0,
          'accuracy': 0.0,
          'isMockApp': false,
          'isShizukuAvailable': false,
          'providers': <String>[],
        });

    await pumpConsole(tester);

    expect(find.text('无（未注册测试 Provider）'), findsOneWidget);
    expect(find.textContaining('两种通道都不可用'), findsOneWidget);
  });

  testWidgets('injects the selected template through the native channel',
      (tester) async {
    answerStatus(() => <String, dynamic>{
          'isMocking': false,
          'mode': 'system',
          'latitude': 0.0,
          'longitude': 0.0,
          'accuracy': 0.0,
          'isMockApp': true,
          'isShizukuAvailable': false,
          'providers': <String>[],
        });

    await pumpConsole(tester);
    await tapInject(tester);

    final start = calls.firstWhere((c) => c.method == 'startMockLocation');
    expect(start.arguments['latitude'], closeTo(22.3193, 0.0001));
    expect(start.arguments['longitude'], closeTo(114.1694, 0.0001));
    expect(start.arguments['mode'], 'system');
  });

  testWidgets('rejects an out-of-range manual coordinate before injecting',
      (tester) async {
    answerStatus(() => <String, dynamic>{
          'isMocking': false,
          'mode': 'system',
          'latitude': 0.0,
          'longitude': 0.0,
          'accuracy': 0.0,
          'isMockApp': true,
          'isShizukuAvailable': false,
          'providers': <String>[],
        });

    await pumpConsole(tester);
    await tester.tap(find.text('手动输入'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), '120');
    await tester.enterText(find.byType(TextField).at(1), '114');
    await tester.pump();

    await tapInject(tester);

    expect(find.textContaining('纬度'), findsWidgets);
    expect(
      calls.where((c) => c.method == 'startMockLocation'),
      isEmpty,
      reason: 'an invalid coordinate must never reach the card/GPS layer',
    );
  });
}
