import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/sms_relay_service.dart';

void main() {
  test('accepts an absolute HTTPS webhook URL', () {
    expect(
      SmsRelayService.isSecureEndpoint('https://relay.example.net/api/sms'),
      isTrue,
    );
  });

  test('rejects URLs that could expose credentials or weaken transport', () {
    for (final endpoint in [
      'http://relay.example.net/api/sms',
      'https://user@relay.example.net/api/sms',
      'https://relay.example.net/api/sms#fragment',
      'https:///api/sms',
      'https://relay.example.net:99999/api/sms',
    ]) {
      expect(SmsRelayService.isSecureEndpoint(endpoint), isFalse);
    }
  });
}
