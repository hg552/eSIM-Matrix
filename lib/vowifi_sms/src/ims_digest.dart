import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Splits SIP header lists without splitting quoted strings or name-addresses.
List<String> splitSipHeaderValues(String value) {
  final result = <String>[];
  var start = 0;
  var quoted = false;
  var escaped = false;
  var angleDepth = 0;
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    if (escaped) {
      escaped = false;
    } else if (quoted && char == r'\') {
      escaped = true;
    } else if (char == '"') {
      quoted = !quoted;
    } else if (!quoted && char == '<') {
      angleDepth++;
    } else if (!quoted && char == '>') {
      if (--angleDepth < 0) throw const FormatException('Invalid SIP header');
    } else if (!quoted && angleDepth == 0 && char == ',') {
      result.add(value.substring(start, i).trim());
      start = i + 1;
    }
  }
  if (quoted || escaped || angleDepth != 0) {
    throw const FormatException('Unterminated SIP header value');
  }
  final last = value.substring(start).trim();
  if (last.isNotEmpty) result.add(last);
  return result;
}

Map<String, String> parseImsDigestChallenge(String raw) {
  if (raw.contains('\r') || raw.contains('\n')) {
    throw const FormatException('Invalid digest header');
  }
  final scheme = RegExp(
    r'^Digest\s+',
    caseSensitive: false,
  ).firstMatch(raw.trim());
  if (scheme == null) {
    throw const FormatException('Digest authentication required');
  }
  final fields = <String, String>{};
  for (final part in splitSipHeaderValues(raw.trim().substring(scheme.end))) {
    final equals = part.indexOf('=');
    if (equals < 1) throw const FormatException('Invalid digest parameter');
    final key = part.substring(0, equals).trim().toLowerCase();
    var value = part.substring(equals + 1).trim();
    if (value.startsWith('"')) {
      if (!value.endsWith('"') || value.length < 2) {
        throw const FormatException('Invalid digest quoted string');
      }
      value = value
          .substring(1, value.length - 1)
          .replaceAllMapped(RegExp(r'\\(.)'), (match) => match.group(1)!);
    }
    if (fields.containsKey(key)) {
      throw const FormatException('Duplicate digest parameter');
    }
    fields[key] = value;
  }
  if ((fields['nonce'] ?? '').isEmpty) {
    throw const FormatException('Missing digest nonce');
  }
  return fields;
}

/// RFC 3310 AKA uses the raw RES octets as the Digest password. The digest
/// calculation and qop negotiation otherwise follow RFC 7616 / RFC 3261.
class ImsDigestAuth {
  final _nonceCounts = <String, int>{};

  static bool supportsAlgorithm(String algorithm) => const {
    'MD5',
    'MD5-SESS',
    'AKAV1-MD5',
    'SHA-256',
    'SHA-256-SESS',
  }.contains(algorithm.toUpperCase());

  void clear() => _nonceCounts.clear();

  String authorization({
    required String username,
    required String realm,
    required String nonce,
    required String method,
    required String uri,
    required String cnonce,
    required List<int> password,
    required Map<String, String> challenge,
    List<int> body = const [],
    List<int> auts = const [],
  }) {
    final algorithm = challenge['algorithm'] ?? 'MD5';
    final normalized = algorithm.toUpperCase();
    final hash = switch (normalized) {
      'MD5' || 'MD5-SESS' || 'AKAV1-MD5' => md5,
      'SHA-256' || 'SHA-256-SESS' => sha256,
      _ => throw UnsupportedError(
        'Unsupported IMS digest algorithm: $algorithm',
      ),
    };
    final offered = (challenge['qop'] ?? '')
        .split(',')
        .map((v) => v.trim().toLowerCase())
        .toSet();
    final qop = offered.contains('auth')
        ? 'auth'
        : offered.contains('auth-int')
        ? 'auth-int'
        : offered.every((v) => v.isEmpty)
        ? ''
        : throw UnsupportedError('Unsupported IMS digest qop');
    if (auts.isNotEmpty && auts.length != 14) {
      throw const FormatException('Invalid IMS AUTS length');
    }
    final secret = auts.isEmpty ? password : const <int>[];
    var ha1 = hash.convert([
      ...utf8.encode('$username:$realm:'),
      ...secret,
    ]).toString();
    if (normalized.endsWith('-SESS')) {
      ha1 = hash.convert(utf8.encode('$ha1:$nonce:$cnonce')).toString();
    }
    final a2 = qop == 'auth-int'
        ? '$method:$uri:${hash.convert(body)}'
        : '$method:$uri';
    final ha2 = hash.convert(utf8.encode(a2)).toString();
    final nonceKey = jsonEncode([username, realm, nonce, normalized]);
    if (!_nonceCounts.containsKey(nonceKey) && _nonceCounts.length >= 64) {
      _nonceCounts.remove(_nonceCounts.keys.first);
    }
    final count = (_nonceCounts[nonceKey] ?? 0) + 1;
    if (count > 0xffffffff) {
      throw StateError('IMS digest nonce count exhausted');
    }
    _nonceCounts[nonceKey] = count;
    final nc = count.toRadixString(16).padLeft(8, '0');
    final response = hash
        .convert(
          utf8.encode(
            qop.isEmpty
                ? '$ha1:$nonce:$ha2'
                : '$ha1:$nonce:$nc:$cnonce:$qop:$ha2',
          ),
        )
        .toString();
    String quote(String value) {
      if (value.contains('\r') || value.contains('\n')) {
        throw const FormatException('Invalid digest field');
      }
      return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    }

    return 'Digest ${[
      'username=${quote(username)}',
      'realm=${quote(realm)}',
      'nonce=${quote(nonce)}',
      'uri=${quote(uri)}',
      'response=${quote(response)}',
      'algorithm=$algorithm',
      if (challenge['opaque'] case final opaque?) 'opaque=${quote(opaque)}',
      if (auts.isNotEmpty) 'auts=${quote(base64.encode(auts))}',
      if (qop.isNotEmpty) ...['qop=$qop', 'nc=$nc'],
      if (qop.isNotEmpty || normalized.endsWith('-SESS')) 'cnonce=${quote(cnonce)}',
    ].join(', ')}';
  }
}
