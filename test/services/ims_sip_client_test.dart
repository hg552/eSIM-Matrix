import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/vowifi_sms/src/ims_digest.dart';
import 'package:nlpa2/vowifi_sms/vowifi_sms_plugin.dart';

void main() {
  Future<(_Peer, VowifiSmsClient)> setup(
    FutureOr<void> Function(_Request request, Socket socket) handler, {
    Future<VowifiAkaResponse?> Function(VowifiDigestChallenge)? aka,
  }) async {
    final peer = await _Peer.open(handler);
    addTearDown(peer.close);
    final client = VowifiSmsClient(
      config: VowifiSmsConfig(
        sipServer: '127.0.0.1:${peer.server.port}',
        domain: 'ims.example',
        username: 'alice',
        privateIdentity: 'alice@ims.example',
        password: 'test-password',
        publicIdentity: 'sip:alice@ims.example',
        smsc: '+12025550123',
        mcc: '310',
        transport: VowifiTransport.tcp,
      ),
      digestAkaProvider: aka,
    );
    addTearDown(client.disconnect);
    return (peer, client);
  }

  test(
    'waits for the matching final response, including fragmented compact headers',
    () async {
      final (_, client) = await setup((request, socket) async {
        socket.add(request.reply(100));
        socket.add(request.reply(403, override: {'Call-ID': 'other'}));
        socket.add(request.reply(403, override: {'CSeq': '900 REGISTER'}));
        socket.add(
          request.reply(
            403,
            override: {'Via': 'SIP/2.0/TCP host;branch=other'},
          ),
        );
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final reply = request.reply(200, compact: true);
        socket.add([13, 10, 13, 10, ...reply.sublist(0, 17)]);
        await socket.flush();
        socket.add(reply.sublist(17));
      });
      await client.connectAndRegister();
      expect(client.registeredUntil, isNotNull);
    },
  );

  test(
    'AUTS obtains a fresh challenge and combined public identities are retained',
    () async {
      var register = 0;
      var challenges = 0;
      final nonces = [
        base64.encode(List<int>.generate(32, (i) => i)),
        base64.encode(List<int>.generate(32, (i) => i + 32)),
      ];
      final (_, client) = await setup(
        (request, socket) {
          if (request.startLine.startsWith('SIP/2.0')) return;
          if (register++ < 2) {
            if (register == 2) {
              final auth = parseImsDigestChallenge(
                request.header('authorization'),
              );
              expect(auth['auts'], base64.encode(List.filled(14, 7)));
              expect(auth['qop'], 'auth');
            }
            socket.add(
              request.reply(
                401,
                headers: [
                  [
                    'WWW-Authenticate',
                    'Digest realm="ims.example", nonce="${nonces[register - 1]}", algorithm=AKAv1-MD5, qop="auth-int,auth"',
                  ],
                ],
              ),
            );
          } else {
            final auth = parseImsDigestChallenge(
              request.header('authorization'),
            );
            expect(auth.containsKey('auts'), isFalse);
            expect(auth['nonce'], nonces[1]);
            socket.add(
              request.reply(
                200,
                headers: [
                  [
                    'P-Associated-URI',
                    '"Line, One" <sip:+12025550123@ims.example>, <tel:+12025550124>',
                  ],
                ],
              ),
            );
          }
        },
        aka: (challenge) async {
          challenges++;
          return VowifiAkaResponse(
            res: Uint8List.fromList(
              challenges == 1 ? [] : [0x81, 8, 0x7b, 0xd0],
            ),
            ck: Uint8List(0),
            ik: Uint8List(0),
            auts: challenges == 1 ? List.filled(14, 7) : [],
          );
        },
      );
      await client.connectAndRegister();
      expect(challenges, 2);
      expect(register, 3);
      expect(client.associatedIdentities, [
        'sip:+12025550123@ims.example',
        'tel:+12025550124',
      ]);
    },
  );

  test(
    'retains Service-Route order for SMS and clears it after a refresh without routes',
    () async {
      var registrations = 0;
      var messages = 0;
      final (_, client) = await setup((request, socket) {
        if (request.startLine.startsWith('REGISTER')) {
          registrations++;
          socket.add(
            request.reply(
              200,
              headers: registrations == 1
                  ? [
                      [
                        'Service-Route',
                        '<sip:one.ims.example;lr>, <sip:two.ims.example;lr>',
                      ],
                      ['Service-Route', '<sip:three.ims.example;lr>'],
                    ]
                  : [],
            ),
          );
        } else if (request.startLine.startsWith('MESSAGE')) {
          messages++;
          expect(
            request.headers['route'] ?? [],
            messages == 1
                ? [
                    '<sip:one.ims.example;lr>',
                    '<sip:two.ims.example;lr>',
                    '<sip:three.ims.example;lr>',
                  ]
                : [],
          );
          socket.add(request.reply(200));
          socket.add(_report(messages));
        }
      });
      await client.connectAndRegister();
      await client.sendTextSms('+12025550125', 'first');
      await client.refreshRegistration();
      await client.sendTextSms('+12025550125', 'second');
      expect(messages, 2);
    },
  );

  test('honors Min-Expires once and refuses a repeated 423', () async {
    var count = 0;
    final (_, client) = await setup((request, socket) {
      count++;
      if (count == 2) expect(request.header('expires'), '7200');
      socket.add(
        request.reply(
          423,
          headers: [
            ['Min-Expires', '7200'],
          ],
        ),
      );
    });
    await expectLater(client.connectAndRegister(), throwsStateError);
    expect(count, 2);
  });

  test('accepts the negotiated registration interval after 423', () async {
    var count = 0;
    final (_, client) = await setup((request, socket) {
      count++;
      socket.add(
        count == 1
            ? request.reply(
                423,
                headers: [
                  ['Min-Expires', '7200'],
                ],
              )
            : request.reply(
                200,
                headers: [
                  ['Expires', '7200'],
                ],
              ),
      );
    });
    await client.connectAndRegister();
    expect(
      client.registeredUntil!.difference(DateTime.now()).inMinutes,
      greaterThan(118),
    );
    expect(count, 2);
  });

  test(
    'closing the connection fails the pending transaction promptly',
    () async {
      final (_, client) = await setup((request, socket) => socket.destroy());
      await expectLater(
        client.connectAndRegister().timeout(const Duration(seconds: 2)),
        throwsStateError,
      );
    },
  );

  test(
    'rejects negative Content-Length without an uncaught stream error',
    () async {
      final (_, client) = await setup((request, socket) {
        socket.add(request.reply(200, override: {'Content-Length': '-1'}));
      });
      await expectLater(client.connectAndRegister(), throwsFormatException);
    },
  );
  test(
    'keeps every Via header in an inbound request acknowledgement',
    () async {
      final answered = Completer<_Request>();
      final (_, client) = await setup((request, socket) {
        if (request.startLine.startsWith('REGISTER')) {
          socket.add(request.reply(200));
          final incoming = latin1
              .decode(_report(40))
              .replaceFirst(
                'From:',
                'Via: SIP/2.0/TCP second;branch=z9hG4bKsecond\r\nFrom:',
              );
          socket.add(latin1.encode(incoming));
        } else if (request.startLine.startsWith('SIP/2.0') &&
            !answered.isCompleted) {
          answered.complete(request);
        }
      });
      await client.connectAndRegister();
      final reply = await answered.future.timeout(const Duration(seconds: 2));
      expect(reply.headers['via'], hasLength(2));
      expect(reply.headers['via']!.last, contains('z9hG4bKsecond'));
    },
  );

  test('rejects conflicting compact and full Content-Length headers', () async {
    final (_, client) = await setup((request, socket) {
      socket.add(
        request.reply(
          200,
          headers: [
            ['l', '1'],
          ],
        ),
      );
    });
    await expectLater(client.connectAndRegister(), throwsFormatException);
  });
  test(
    'unsupported digest algorithms are rejected before SIM authentication',
    () async {
      var calls = 0;
      final (_, client) = await setup(
        (request, socket) {
          socket.add(
            request.reply(
              401,
              headers: [
                [
                  'WWW-Authenticate',
                  'Digest realm="ims.example", nonce="${base64.encode(List.filled(32, 1))}", algorithm=AKAv2-MD5',
                ],
              ],
            ),
          );
        },
        aka: (_) async {
          calls++;
          throw StateError('Must not contact the SIM');
        },
      );
      await expectLater(client.connectAndRegister(), throwsUnsupportedError);
      expect(calls, 0);
    },
  );

  test('a long SHA-256 nonce is not misidentified as an AKA challenge', () async {
    var calls = 0;
    var requests = 0;
    final (_, client) = await setup(
      (request, socket) {
        if (requests++ == 0) {
          socket.add(
            request.reply(
              401,
              headers: [
                [
                  'WWW-Authenticate',
                  'Digest realm="ims.example", nonce="${base64.encode(List.filled(32, 2))}", algorithm=SHA-256, qop="auth"',
                ],
              ],
            ),
          );
        } else {
          final authorization = parseImsDigestChallenge(
            request.header('authorization'),
          );
          expect(authorization['algorithm'], 'SHA-256');
          expect(authorization['response'], hasLength(64));
          socket.add(request.reply(200));
        }
      },
      aka: (_) async {
        calls++;
        throw StateError('Must not contact the SIM');
      },
    );
    await client.connectAndRegister();
    expect(calls, 0);
    expect(requests, 2);
  });
}

List<int> _report(int id) {
  const body = [3, 42, 0x41, 2, 1, 0];
  return [
    ...ascii.encode(
      'MESSAGE sip:alice@ims.example SIP/2.0\r\n'
      'Via: SIP/2.0/TCP peer;branch=z9hG4bKreport$id\r\n'
      'From: <sip:smsc@ims.example>;tag=server\r\nTo: <sip:alice@ims.example>\r\n'
      'Call-ID: report$id\r\nCSeq: 1 MESSAGE\r\n'
      'Content-Type: application/vnd.3gpp.sms\r\nContent-Length: ${body.length}\r\n\r\n',
    ),
    ...body,
  ];
}

class _Peer {
  _Peer(this.server);
  final ServerSocket server;
  final sockets = <Socket>[];
  final errors = <Object>[];
  static Future<_Peer> open(
    FutureOr<void> Function(_Request, Socket) handler,
  ) async {
    final peer = _Peer(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    peer.server.listen((socket) {
      peer.sockets.add(socket);
      var buffer = <int>[];
      socket.listen((data) {
        buffer.addAll(data);
        while (true) {
          final split = latin1.decode(buffer).indexOf('\r\n\r\n');
          if (split < 0) return;
          final header = latin1.decode(buffer.sublist(0, split));
          final length = int.parse(
            RegExp(
              r'Content-Length: (\d+)',
              caseSensitive: false,
            ).firstMatch(header)!.group(1)!,
          );
          if (buffer.length < split + 4 + length) return;
          final raw = buffer.sublist(0, split + 4 + length);
          buffer = buffer.sublist(raw.length);
          unawaited(
            Future<void>.sync(() => handler(_Request(raw), socket)).catchError((
              Object e,
            ) {
              peer.errors.add(e);
              socket.destroy();
            }),
          );
        }
      }, onError: (Object error) => peer.errors.add(error));
    });
    return peer;
  }

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
    expect(errors, isEmpty);
  }
}

class _Request {
  _Request(List<int> raw) {
    final text = latin1.decode(raw);
    final lines = text.substring(0, text.indexOf('\r\n\r\n')).split('\r\n');
    startLine = lines.first;
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      headers
          .putIfAbsent(line.substring(0, colon).toLowerCase(), () => [])
          .add(line.substring(colon + 1).trim());
    }
  }
  late final String startLine;
  final headers = <String, List<String>>{};
  String header(String name) => headers[name]?.first ?? '';
  Uint8List reply(
    int status, {
    List<List<String>> headers = const [],
    Map<String, String> override = const {},
    bool compact = false,
  }) {
    final fields = <String, String>{
      'Via': header('via'),
      'From': header('from'),
      'To': header('to'),
      'Call-ID': header('call-id'),
      'CSeq': header('cseq'),
      'Content-Length': '0',
      ...override,
    };
    return Uint8List.fromList(
      ascii.encode(
        'SIP/2.0 $status Test\r\n${[
          for (final entry in fields.entries) '${compact ? const {'Via': 'v', 'Call-ID': 'i', 'Content-Length': 'l'}[entry.key] ?? entry.key : entry.key}: ${entry.value}',
          for (final entry in headers) '${entry[0]}: ${entry[1]}',
        ].join('\r\n')}\r\n\r\n',
      ),
    );
  }
}
