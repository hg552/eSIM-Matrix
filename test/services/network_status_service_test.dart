import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/network_status_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ee.nekoko.network_status');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, Object?> payload({int signal = -85}) => {
    'error': null,
    'subscriptions': [
      {
        'subscriptionId': 7,
        'slotIndex': 1,
        'displayName': 'SIM 2',
        'carrierName': 'AT&T',
        'serviceState': 0,
        'roaming': true,
        'signalDbm': signal,
        'signalLevel': 3,
        'error': null,
      },
    ],
  };

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('refresh returns the live state instead of a bare acknowledgement', () async {
    // The page asks for data immediately after subscribing; the answer has to
    // carry the subscriptions, or it renders empty until the app restarts.
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'refresh') return null;
      calls++;
      return payload();
    });

    final update = await const NetworkStatusService().refresh();

    expect(calls, 1);
    expect(update, isNotNull);
    expect(update!.subscriptions, hasLength(1));
    expect(update.subscriptions.single.carrierName, 'AT&T');
    expect(update.subscriptions.single.voiceRegistrationState,
        VoiceRegistrationState.inService);
    expect(update.subscriptions.single.roaming, isTrue);
  });

  test('snapshot reads once through its own method', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'snapshot');
      return payload(signal: -101);
    });

    final update = await const NetworkStatusService().snapshot();

    expect(update, isNotNull);
    expect(update!.subscriptions.single.signalDbm, -101);
  });

  test('a non-map answer is not mistaken for an empty-but-valid state', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);

    expect(await const NetworkStatusService().refresh(), isNull);
  });
}
