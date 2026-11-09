import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/sms_relay_service.dart';

void main() {
  test('accepts an absolute HTTPS webhook URL', () {
    expect(
      SmsRelayService.isSecureEndpoint('https://relay.example.net/api/sms'),
      isTrue,
    );
  });

  test('accepts private LAN, loopback, and Tailscale HTTP webhook URLs', () {
    for (final endpoint in [
      'http://127.0.0.1:9787/webhook',
      'http://localhost:9787/webhook',
      'http://192.168.1.50:9787/webhook',
      'http://10.0.0.12:9787/webhook',
      'http://172.20.1.5:9787/webhook',
      'http://100.100.10.20:9787/webhook',
    ]) {
      expect(SmsRelayService.isSecureEndpoint(endpoint), isTrue, reason: endpoint);
    }
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
