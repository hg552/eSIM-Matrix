import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/vowifi_sms/src/ims_digest.dart';

void main() {
  for (final entry in {
    'MD5-sess': 'a3457a19c3935c178356e21f635e0fbb',
    'SHA-256-sess':
        '1536d15151c033a35ae82722c543488a3d8a8085f2df4162ed4070871cf9592a',
  }.entries) {
    test('${entry.key} binds the session hash to nonce and cnonce', () {
      final header = ImsDigestAuth().authorization(
        username: 'alice',
        realm: 'ims.example',
        nonce: 'nonce',
        method: 'REGISTER',
        uri: 'sip:ims.example',
        cnonce: 'client',
        password: utf8.encode('password'),
        challenge: {'algorithm': entry.key, 'qop': 'auth'},
      );
      expect(header, contains('response="${entry.value}"'));
      expect(header, contains('cnonce="client"'));
    });
  }
  test('Digest parsing retains quoted qop lists, commas and escaped quotes', () {
    final fields = parseImsDigestChallenge(
      r'Digest realm="test, realm", nonce="abc", qop="auth-int,auth", opaque="say\"hello"',
    );
    expect(fields['realm'], 'test, realm');
    expect(fields['qop'], 'auth-int,auth');
    expect(fields['opaque'], 'say"hello');
    expect(
      splitSipHeaderValues(
        '"Name, Person" <sip:a@example.com>, <tel:+12025550123>',
      ),
      ['"Name, Person" <sip:a@example.com>', '<tel:+12025550123>'],
    );
  });

  test('rejects malformed or ambiguous challenges', () {
    for (final value in [
      'Basic realm="x"',
      'Digest realm="x"',
      'Digest nonce="x", nonce="y"',
      'Digest nonce="unfinished',
      'Digest nonce="a\r\nb"',
    ]) {
      expect(
        () => parseImsDigestChallenge(value),
        throwsFormatException,
        reason: value,
      );
    }
  });

  test(
    'matches the RFC 2617 MD5 qop=auth example and increments nonce count',
    () {
      final digest = ImsDigestAuth();
      String authorize() => digest.authorization(
        username: 'Mufasa',
        realm: 'testrealm@host.com',
        nonce: 'dcd98b7102dd2f0e8b11d0f600bfb0c093',
        method: 'GET',
        uri: '/dir/index.html',
        cnonce: '0a4f113b',
        password: utf8.encode('Circle Of Life'),
        challenge: {'qop': 'auth'},
      );
      final first = authorize();
      expect(first, contains('response="6629fae49393a05397450978507c4ef1"'));
      expect(first, contains('nc=00000001'));
      expect(authorize(), contains('nc=00000002'));
      digest.clear();
      expect(authorize(), first);
    },
  );

  for (final entry in {
    'MD5': '48c51fdb6eb244b163890226811243bc',
    'SHA-256':
        '14bdaab2451dc5b2b6a8badd0073a4727d5ad610c692d30723a8602dbe735f8f',
  }.entries) {
    test(
      '${entry.key} auth-int hashes the actual MESSAGE body and raw RES',
      () {
        final authorization = ImsDigestAuth().authorization(
          username: 'alice',
          realm: 'ims.example',
          nonce: 'nonce',
          method: 'MESSAGE',
          uri: 'sip:ims.example',
          cnonce: 'client',
          password: [0x81, 0x08, 0x7b, 0xd0],
          challenge: {'algorithm': entry.key, 'qop': 'auth-int'},
          body: utf8.encode('hello'),
        );
        expect(authorization, contains('response="${entry.value}"'));
        expect(authorization, contains('qop=auth-int'));
      },
    );
  }

  test('AUTS uses an empty digest password and is base64 encoded', () {
    final auts = List<int>.generate(14, (i) => i);
    final authorization = ImsDigestAuth().authorization(
      username: 'alice',
      realm: 'ims.example',
      nonce: 'nonce',
      method: 'REGISTER',
      uri: 'sip:ims.example',
      cnonce: 'client',
      password: [0x81, 0x08, 0x7b, 0xd0],
      challenge: {'algorithm': 'AKAv1-MD5'},
      auts: auts,
    );
    expect(
      authorization,
      contains('response="45da4d394e6624d136b008681bcd1f5c"'),
    );
    expect(authorization, contains('auts="${base64.encode(auts)}"'));
  });

  test('prefers auth from a mixed qop list and echoes opaque', () {
    final header = ImsDigestAuth().authorization(
      username: 'alice',
      realm: 'ims.example',
      nonce: 'nonce',
      method: 'REGISTER',
      uri: 'sip:ims.example',
      cnonce: 'client',
      password: [1],
      challenge: {'qop': 'auth-int, auth', 'opaque': 'opaque,token'},
    );
    expect(header, contains('qop=auth,'));
    expect(header, contains('opaque="opaque,token"'));
  });

  test(
    'unsupported algorithms and qop fail instead of silently downgrading',
    () {
      for (final challenge in [
        {'algorithm': 'AKAv2-MD5'},
        {'qop': 'unknown'},
      ]) {
        expect(
          () => ImsDigestAuth().authorization(
            username: 'a',
            realm: 'r',
            nonce: 'n',
            method: 'REGISTER',
            uri: 'sip:r',
            cnonce: 'c',
            password: [1],
            challenge: challenge,
          ),
          throwsUnsupportedError,
        );
      }
    },
  );
}
