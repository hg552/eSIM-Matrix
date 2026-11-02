import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/network_status_service.dart';

void main() {
  test('roaming remains separate from the voice registration state', () {
    final update = NetworkStatusUpdate.fromPlatform({
      'error': null,
      'subscriptions': [
        {
          'subscriptionId': 17,
          'slotIndex': 1,
          'displayName': 'Travel line',
          'carrierName': 'Carrier',
          'serviceState': 0,
          'roaming': true,
          'signalDbm': -85,
          'signalLevel': 3,
          'error': null,
        },
      ],
    });
    final subscription = update.subscriptions.single;

    expect(
      subscription.voiceRegistrationState,
      VoiceRegistrationState.inService,
    );
    expect(subscription.roaming, isTrue);
    expect(subscription.signalDbm, -85);
  });

  test('unknown telephony values are not presented as registered', () {
    final subscription = NetworkStatusSubscription.fromPlatform({
      'subscriptionId': 18,
      'slotIndex': -1,
      'serviceState': 99,
      'roaming': null,
      'signalDbm': null,
      'signalLevel': null,
    });

    expect(subscription.voiceRegistrationState, VoiceRegistrationState.unknown);
    expect(subscription.roaming, isNull);
    expect(subscription.signalDbm, isNull);
  });

  test('an empty active-subscription snapshot stays a valid empty result', () {
    final update = NetworkStatusUpdate.fromPlatform({
      'error': null,
      'subscriptions': <Object?>[],
    });

    expect(update.subscriptions, isEmpty);
    expect(update.error, isNull);
  });

  test('updates returns a shared broadcast stream supporting multiple listeners', () {
    const service1 = NetworkStatusService();
    const service2 = NetworkStatusService();
    expect(identical(service1.updates, service2.updates), isTrue);
    expect(service1.updates.isBroadcast, isTrue);
  });
}
