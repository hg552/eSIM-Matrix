import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/vowifi_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ee.nekoko.vowifi');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, Object?> statusPayload({
    bool enabled = true,
    int mode = 0,
    bool roamingEnabled = false,
    int roamingMode = 2,
  }) => {
    'available': true,
    'subscriptionId': 3,
    'enabled': enabled,
    'mode': mode,
    'roamingEnabled': roamingEnabled,
    'roamingMode': roamingMode,
    'error': null,
  };

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('status decodes the mode values the platform actually stores', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'status');
      return statusPayload(mode: 0, roamingMode: 2);
    });

    final status = await const VowifiService().status();

    expect(status, isNotNull);
    expect(status!.enabled, isTrue);
    expect(status.mode, VowifiCallingMode.wifiOnly);
    expect(status.roamingMode, VowifiCallingMode.wifiPreferred);
    expect(status.prefersWifi, isTrue);
  });

  test('an unknown mode is not silently read as wifi-only', () async {
    // wifiOnly is 0, so a missing or unrecognised value must not collapse to it:
    // that would report "Wi-Fi only" for a device that is cellular-preferred.
    messenger.setMockMethodCallHandler(channel, (call) async {
      return statusPayload(mode: 99);
    });

    final status = await const VowifiService().status();

    expect(status!.mode, VowifiCallingMode.unknown);
    expect(status.prefersWifi, isFalse);
  });

  test('setMode sends the numeric mode and returns the persisted state', () async {
    int? sentMode;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'setMode') return null;
      sentMode = call.arguments['mode'] as int?;
      return {
        'success': true,
        'error': null,
        'status': statusPayload(mode: 0),
      };
    });

    final status = await const VowifiService().setMode(
      subscriptionId: 3,
      mode: VowifiCallingMode.wifiOnly,
    );

    expect(sentMode, 0);
    expect(status!.mode, VowifiCallingMode.wifiOnly);
  });

  test('a write that the platform rejected does not report a new state', () async {
    // The plugin answers with success:false and no status when the table write
    // fails; the caller must not read that as "applied".
    messenger.setMockMethodCallHandler(channel, (call) async {
      return {'success': false, 'error': 'write_rejected'};
    });

    final status = await const VowifiService().setEnabled(
      subscriptionId: 3,
      enabled: true,
    );

    expect(status, isNull);
  });

  test('capabilities require root: the binder setters are signature-gated', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return {
        'sdkInt': 36,
        'root': false,
        'telephony': true,
        'binderReadable': false,
      };
    });

    final capabilities = await const VowifiService().capabilities();

    expect(capabilities.sdkInt, 36);
    expect(capabilities.root, isFalse);
    expect(capabilities.usable, isFalse);
  });

  test('an unavailable subscription is reported, not thrown', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      return {
        'available': false,
        'subscriptionId': -1,
        'error': 'no_subscription',
      };
    });

    final status = await const VowifiService().status();

    expect(status!.available, isFalse);
    expect(status.error, 'no_subscription');
    expect(status.prefersWifi, isFalse);
  });
}
