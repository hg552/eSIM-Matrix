import 'dart:io';
import 'dart:typed_data';

import '../ts43/errors.dart';
import 'ts43_entitlement_http.dart';

/// Native (dart:io) TS.43 transport. Gives full control over per-cookie
/// `Set-Cookie` parsing and raw response bytes, unlike package:http.
class _IoTransport implements Ts43Transport {
  final HttpClient _client;

  _IoTransport(Duration? timeout) : _client = HttpClient() {
    if (timeout != null) _client.connectionTimeout = timeout;
  }

  @override
  Future<Ts43HttpResponse> doRaw(Ts43HttpRequest request) async {
    final uri = Uri.parse(request.url);
    final HttpClientRequest httpReq = request.method == Ts43Method.post
        ? await _client.postUrl(uri)
        : await _client.getUrl(uri);

    request.headers.forEach(httpReq.headers.set);
    if (request.cookies.isNotEmpty) {
      httpReq.headers.set('cookie', request.cookies.join('; '));
    }
    if (request.body != null && request.body!.isNotEmpty) {
      httpReq.add(request.body!);
    }

    final resp = await httpReq.close();
    final cookies = <String>[];
    for (final c in resp.cookies) {
      cookies.add('${c.name}=${c.value}');
    }

    final builder = BytesBuilder();
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    final bytes = builder.toBytes();

    if (resp.statusCode < 200 || resp.statusCode > 299) {
      throw Ts43HttpError(statusCode: resp.statusCode, body: bytes);
    }
    return Ts43HttpResponse(bytes, cookies);
  }

  @override
  void close() => _client.close(force: true);
}

Ts43Transport createTransport({Duration? timeout}) => _IoTransport(timeout);
