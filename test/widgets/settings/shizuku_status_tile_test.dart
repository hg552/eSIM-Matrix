import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/widgets/settings/shizuku_status_tile.dart';

/// The row decides what the user is told and which single action is offered.
/// Getting a state wrong here sends people looking for a problem they do not
/// have, or hides the one step (starting the server) they actually need.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ee.nekoko.shizuku_installer');

  void mockStatus(
    Map<String, dynamic>? status, {
    String installResult = 'installer_opened',
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'status':
              return status;
            case 'install':
              return installResult;
            case 'allowInstall':
              return 'settings_opened';
            case 'launch':
              return true;
            default:
              return null;
          }
        });
  }

  Future<void> pumpTile(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ShizukuStatusTile())),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('offers install when Shizuku is missing', (tester) async {
    mockStatus({
      'installed': false,
      'running': false,
      'canInstall': true,
    });

    await pumpTile(tester);

    expect(find.textContaining('未安装'), findsOneWidget);
    expect(find.text('安装'), findsOneWidget);
    expect(find.text('启动指引'), findsNothing);
  });

  testWidgets('asks for the start step when installed but not running', (
    tester,
  ) async {
    const command = 'adb shell /data/app/x/lib/arm64/libshizuku.so';
    mockStatus({
      'installed': true,
      'running': false,
      'canInstall': true,
      'versionName': '13.6.0',
      'starterCommand': command,
    });

    await pumpTile(tester);

    expect(find.textContaining('服务端未运行'), findsOneWidget);
    expect(find.text('启动指引'), findsOneWidget);
    expect(find.text('安装'), findsNothing);

    await tester.tap(find.text('启动指引'));
    await tester.pumpAndSettle();

    expect(find.text('启动 Shizuku'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('复制命令'), findsOneWidget);
  });

  testWidgets('shows a healthy row without an extra step when running', (
    tester,
  ) async {
    mockStatus({
      'installed': true,
      'running': true,
      'canInstall': true,
      'versionName': '13.6.0',
      'starterCommand': 'adb shell /data/app/x/lib/arm64/libshizuku.so',
    });

    await pumpTile(tester);

    expect(find.textContaining('运行中'), findsOneWidget);
    expect(find.text('打开'), findsOneWidget);
    expect(find.text('启动指引'), findsNothing);
  });

  testWidgets('still renders a row when the channel answers nothing', (
    tester,
  ) async {
    mockStatus(null);

    await pumpTile(tester);

    // A missing answer must not leave the settings page without the row, and
    // must not claim Shizuku is ready.
    expect(find.text('Shizuku（QRTR / SE HAL 必需）'), findsOneWidget);
    expect(find.textContaining('运行中'), findsNothing);
  });
}
