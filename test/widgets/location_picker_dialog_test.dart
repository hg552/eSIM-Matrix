import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/location_mapping_resolver.dart';
import 'package:nlpa2/settings/app_settings.dart';
import 'package:nlpa2/widgets/profiles_screen/location_picker_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocationPickerDialog', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    Future<void> pumpDialog(
      WidgetTester tester,
      void Function(String?) onResult, {
      String? currentLocationRule,
      List<LocationTemplate>? initialTemplates,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  final result = await showDialog<String>(
                    context: context,
                    builder: (_) => LocationPickerDialog(
                      profileName: 'ClubSim HK (+852)',
                      iccid: '8985200014632217637',
                      currentLocationRule: currentLocationRule,
                      settings: AppSettings(),
                      initialTemplates: initialTemplates,
                    ),
                  );
                  onResult(result);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('displays built-in templates list and allows selection', (tester) async {
      String? picked;
      await pumpDialog(tester, (res) => picked = res);

      expect(find.text('指定虚拟定位 · ClubSim HK (+852)'), findsOneWidget);
      expect(find.text('🌐 自动根据卡国别匹配'), findsOneWidget);
      expect(find.text('中国香港 · 尖沙咀海旁'), findsOneWidget);

      // Select Hong Kong Tsim Sha Tsui
      await tester.tap(find.text('中国香港 · 尖沙咀海旁'));
      await tester.pumpAndSettle();

      // Tap confirm
      await tester.tap(find.text('确定绑定'));
      await tester.pumpAndSettle();

      expect(picked, contains('22.3193, 114.1694'));
    });

    testWidgets('filters templates via search box', (tester) async {
      String? picked;
      await pumpDialog(tester, (res) => picked = res);

      // Enter search query "洛杉矶"
      await tester.enterText(find.byType(TextField).first, '洛杉矶');
      await tester.pumpAndSettle();

      expect(find.text('美国 · 洛杉矶市政中心'), findsOneWidget);
      expect(find.text('中国香港 · 尖沙咀海旁'), findsNothing);

      await tester.tap(find.text('美国 · 洛杉矶市政中心'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('确定绑定'));
      await tester.pumpAndSettle();

      expect(picked, contains('34.0522, -118.2437'));
    });

    testWidgets('switches to manual input and submits custom coordinates', (tester) async {
      String? picked;
      await pumpDialog(tester, (res) => picked = res);

      // Switch to manual mode
      await tester.tap(find.text('手动输入经纬度'));
      await tester.pumpAndSettle();

      expect(find.text('纬度 (Latitude)'), findsOneWidget);
      expect(find.text('经度 (Longitude)'), findsOneWidget);

      // Enter coordinates for Wan Chai
      await tester.enterText(find.widgetWithText(TextField, '纬度 (Latitude)'), '22.2783');
      await tester.enterText(find.widgetWithText(TextField, '经度 (Longitude)'), '114.1747');
      await tester.enterText(find.widgetWithText(TextField, '地点/备注名称'), '香港湾仔');
      await tester.pumpAndSettle();

      await tester.tap(find.text('确定绑定'));
      await tester.pumpAndSettle();

      expect(picked, equals('22.2783, 114.1747, 香港湾仔'));
    });

    testWidgets('validates coordinate boundaries in manual mode', (tester) async {
      String? picked;
      await pumpDialog(tester, (res) => picked = res);

      await tester.tap(find.text('手动输入经纬度'));
      await tester.pumpAndSettle();

      // Enter invalid latitude (> 90.0)
      await tester.enterText(find.widgetWithText(TextField, '纬度 (Latitude)'), '95.5');
      await tester.enterText(find.widgetWithText(TextField, '经度 (Longitude)'), '114.0');
      await tester.pumpAndSettle();

      await tester.tap(find.text('确定绑定'));
      await tester.pumpAndSettle();

      // Dialog should still be open with error message
      expect(find.text('纬度必须为 -90.0 到 90.0 之间的数值'), findsOneWidget);
      expect(picked, isNull);
    });

    testWidgets('clears custom binding when tapping 清除指定', (tester) async {
      String? picked;
      await pumpDialog(
        tester,
        (res) => picked = res,
        currentLocationRule: '22.3193, 114.1694, Custom',
      );

      expect(find.text('清除指定'), findsOneWidget);
      await tester.tap(find.text('清除指定'));
      await tester.pumpAndSettle();

      expect(picked, equals(''));
    });

    testWidgets('returns null when tapping 取消', (tester) async {
      String? picked;
      await pumpDialog(tester, (res) => picked = res);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(picked, isNull);
    });
  });
}
