import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/ts43_entitlement_http.dart';

class _ClientTrust extends HttpOverrides {
  _ClientTrust(this.context);
  final SecurityContext? context;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(this.context ?? context);
}

void main() {
  const cert = 'test/fixtures/ts43_tls/cert.pem';
  const key = 'test/fixtures/ts43_tls/key.pem';
  late HttpServer server;
  late String url;
  var receivedRequests = 0;

  setUp(() async {
    receivedRequests = 0;
    final context = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    url = 'https://127.0.0.1:${server.port}/entitlement';
    server.listen((request) async {
      receivedRequests++;
      request.response.write('operator-entitlement');
      await request.response.close();
    }, onError: (Object error) {
      if (error is! HandshakeException) throw error;
    });
  });
  tearDown(() async { await server.close(force: true); });

  test('untrusted TLS peer cannot receive entitlement credentials', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final transport = createTs43Transport(timeout: const Duration(seconds: 3));
      try {
        await expectLater(
          transport.doRaw(Ts43HttpRequest(method: Ts43Method.get, url: url,
            headers: {'authorization': 'fixture-credential-only'})),
          throwsA(isA<HandshakeException>()),
        );
        expect(receivedRequests, 0);
      } finally {
        transport.close();
      }
    }, _ClientTrust(null));
  });

  test('an explicitly trusted TLS peer returns its entitlement response', () async {
    final trust = SecurityContext(withTrustedRoots: false)..setTrustedCertificates(cert);
    await HttpOverrides.runWithHttpOverrides(() async {
      final transport = createTs43Transport(timeout: const Duration(seconds: 3));
      try {
        final response = await transport.doRaw(Ts43HttpRequest(method: Ts43Method.get, url: url));
        expect(String.fromCharCodes(response.body), 'operator-entitlement');
      } finally {
        transport.close();
      }
    }, _ClientTrust(trust));
  });
}
