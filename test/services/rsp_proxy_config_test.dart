import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/rsp_proxy_config.dart';

void main() {
  group('RspProxyConfig', () {
    test('builds direct RSP URLs', () {
      final config = RspProxyConfig.direct();

      final uri = config.buildRspUri(
        rspAddress: 'smdp.example.com',
        endpoint: 'initiateAuthentication',
        useDefaultWebProxy: false,
      );

      expect(
        uri.toString(),
        'https://smdp.example.com/gsma/rsp2/es9plus/initiateAuthentication',
      );
    });

    test('builds reverse proxy prefix URLs', () {
      final config = RspProxyConfig(
        mode: RspProxyMode.reverse,
        reverseUrlPrefix: 'https://proxy.example/rsp/',
      );

      final uri = config.buildRspUri(
        rspAddress: 'https://smdp.example.com',
        endpoint: '/authenticateClient',
        useDefaultWebProxy: false,
      );

      expect(
        uri.toString(),
        'https://proxy.example/rsp/smdp.example.com/gsma/rsp2/es9plus/authenticateClient',
      );
    });

    test('uses default web reverse proxy when requested', () {
      final config = RspProxyConfig.direct();

      final uri = config.buildRspUri(
        rspAddress: 'smdp.example.com',
        endpoint: 'getBoundProfilePackage',
        useDefaultWebProxy: true,
      );

      expect(
        uri.toString(),
        'https://nlpa-data.nekoko.ee/rsp/smdp.example.com/gsma/rsp2/es9plus/getBoundProfilePackage',
      );
    });

    test('builds Dart HttpClient HTTP forward proxy rule', () {
      final config = RspProxyConfig(
        mode: RspProxyMode.forward,
        forwardProtocol: 'http',
        forwardHost: '127.0.0.1',
        forwardPort: 8080,
      );

      expect(config.dartHttpProxyRule, 'PROXY 127.0.0.1:8080');
    });

    test('builds Dart HttpClient SOCKS forward proxy rule', () {
      final config = RspProxyConfig(
        mode: RspProxyMode.forward,
        forwardProtocol: 'socks',
        forwardHost: '127.0.0.1',
        forwardPort: 1080,
      );

      expect(config.dartHttpProxyRule, 'SOCKS 127.0.0.1:1080');
    });

    test('rejects invalid forward proxy ports', () {
      expect(RspProxyConfig.parsePort('0'), isNull);
      expect(RspProxyConfig.parsePort('65536'), isNull);
      expect(RspProxyConfig.parsePort('8080'), 8080);
    });
  });
}
