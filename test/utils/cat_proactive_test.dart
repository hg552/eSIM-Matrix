import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/utils/cat_proactive.dart';
import 'package:nlpa2/utils/hex_utils.dart';

void main() {
  group('parseFetchResponse', () {
    test('reads the command details of a profile state change REFRESH', () {
      // D0 = proactive command, 81 03 01 01 09 = command details for REFRESH
      // with the eUICC profile state change qualifier.
      final details = CatProactive.parseFetchResponse(
        HexUtils.hexToBytes(
          'D009810301010982028182'
          '9000',
        ),
      );

      expect(details.number, 0x01);
      expect(details.type, ProactiveCommandDetails.typeRefresh);
      expect(details.qualifier, 0x09);
      expect(details.isRefresh, isTrue);
    });

    test('reads command details that are not the first TLV', () {
      final details = CatProactive.parseFetchResponse(
        HexUtils.hexToBytes(
          'D009820281828103020104'
          '9000',
        ),
      );

      expect(details.number, 0x02);
      expect(details.type, 0x01);
      expect(details.qualifier, 0x04);
    });

    test('accepts a long form BER length', () {
      // D0 81 86 wraps 0x86 bytes: the command details plus a 127 byte filler
      // TLV, so the outer length has to use the long form.
      final filler = '00' * 0x7F;
      final details = CatProactive.parseFetchResponse(
        HexUtils.hexToBytes('D081868103010109057F${filler}9000'),
      );

      expect(details.qualifier, 0x09);
    });

    test('rejects a response that is not a proactive command', () {
      expect(
        () => CatProactive.parseFetchResponse(HexUtils.hexToBytes('6F008400')),
        throwsA(isA<CatProactiveException>()),
      );
    });

    test('rejects a proactive command without command details', () {
      expect(
        () => CatProactive.parseFetchResponse(
          HexUtils.hexToBytes(
            'D00482028182'
            '9000',
          ),
        ),
        throwsA(isA<CatProactiveException>()),
      );
    });

    test('rejects command details that are not three bytes', () {
      expect(
        () => CatProactive.parseFetchResponse(
          HexUtils.hexToBytes('D004810201019000'),
        ),
        throwsA(isA<CatProactiveException>()),
      );
    });

    test('rejects a truncated TLV value', () {
      expect(
        () => CatProactive.parseFetchResponse(
          HexUtils.hexToBytes(
            'D00A810301'
            '9000',
          ),
        ),
        throwsA(isA<CatProactiveException>()),
      );
    });

    test('rejects an empty response', () {
      expect(
        () => CatProactive.parseFetchResponse(HexUtils.hexToBytes('90')),
        throwsA(isA<CatProactiveException>()),
      );
    });
  });

  group('decision', () {
    test('acknowledges a profile state change REFRESH', () {
      const details = ProactiveCommandDetails(
        number: 1,
        type: ProactiveCommandDetails.typeRefresh,
        qualifier: ProactiveCommandDetails.qualifierProfileStateChange,
      );

      expect(details.decision, CatResponseDecision.acknowledgeSuccess);
    });

    test('performs a NAA session reset rather than declining it', () {
      // This is the REFRESH a card raises after a profile switch. It needs the
      // application session dropped, not the card power cycled, so it can be
      // carried out here -- and must be, or the modem stays on the old profile.
      const details = ProactiveCommandDetails(
        number: 1,
        type: ProactiveCommandDetails.typeRefresh,
        qualifier: ProactiveCommandDetails.qualifierNaaSessionReset,
      );

      expect(details.decision, CatResponseDecision.restartNaaSession);
    });

    test('never claims to have performed a REFRESH that needs a reset', () {
      // 0x06 is excluded: it is genuinely performable, see above.
      for (final qualifier in <int>[0x00, 0x01, 0x02, 0x03, 0x04, 0x05]) {
        final details = ProactiveCommandDetails(
          number: 1,
          type: ProactiveCommandDetails.typeRefresh,
          qualifier: qualifier,
        );

        expect(
          details.decision,
          CatResponseDecision.requiresCardReset,
          reason: 'REFRESH qualifier 0x${qualifier.toRadixString(16)}',
        );
      }
    });

    test('declines commands a tunnelling reader cannot perform', () {
      // 0x21 DISPLAY TEXT, 0x05 SET UP EVENT LIST, 0x03 POLL INTERVAL.
      for (final type in <int>[0x21, 0x05, 0x03]) {
        final details = ProactiveCommandDetails(
          number: 1,
          type: type,
          qualifier: 0x00,
        );

        expect(details.decision, CatResponseDecision.declineUnableToProcess);
      }
    });
  });

  group('terminalResponse', () {
    test('echoes the command details and reports success', () {
      const details = ProactiveCommandDetails(
        number: 0x01,
        type: 0x01,
        qualifier: 0x09,
      );

      final response = CatProactive.terminalResponse(
        details,
        generalResult: CatProactive.resultSuccess,
      );

      expect(
        HexUtils.bytesToHex(response).toUpperCase(),
        '801400000C810301010982028281830100',
      );
    });

    test('reports that the terminal cannot process the command', () {
      const details = ProactiveCommandDetails(
        number: 0x02,
        type: 0x21,
        qualifier: 0x80,
      );

      final response = CatProactive.terminalResponse(
        details,
        generalResult: CatProactive.resultUnableToProcess,
      );

      expect(response.last, 0x20);
      expect(
        HexUtils.bytesToHex(response.sublist(0, 5)).toUpperCase(),
        '801400000C',
      );
      // The echoed command details must match the fetched command exactly.
      expect(response.sublist(5, 10), <int>[0x81, 0x03, 0x02, 0x21, 0x80]);
    });

    test('round trips a fetched command back into a terminal response', () {
      final details = CatProactive.parseFetchResponse(
        HexUtils.hexToBytes(
          'D009810305010982028182'
          '9000',
        ),
      );

      final response = CatProactive.terminalResponse(
        details,
        generalResult: CatProactive.resultSuccess,
      );

      expect(response.sublist(5, 10), <int>[0x81, 0x03, 0x05, 0x01, 0x09]);
    });
  });

  group('command APDUs', () {
    test('builds STATUS', () {
      expect(
        HexUtils.bytesToHex(CatProactive.status()).toUpperCase(),
        '80F2000000',
      );
    });

    test('builds FETCH with the length advertised by 91xx', () {
      expect(
        HexUtils.bytesToHex(CatProactive.fetch(0x12)).toUpperCase(),
        '8012000012',
      );
      expect(CatProactive.fetch(0x100).last, 0x00);
    });
  });
}
