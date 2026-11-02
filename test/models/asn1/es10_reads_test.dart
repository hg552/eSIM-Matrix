import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/models/asn1/rsp_definitions.g.dart';

import 'asn1_hex.dart';

/// ES10 read commands, decoded from bytes a real eUICC returned.
///
/// The last two are not commands the app sends: the generated model covers
/// them, so this is the only thing keeping them honest. Capture your own with
/// `python3 tools/euicc_probe.py`, which sends exactly these.
void main() {
  group('GetEuiccChallengeResponse (BF2E)', () {
    const responseHex = 'BF2E1280107256979D4D5A49F537812EC293FB90D1';

    test('decodes the 16-byte challenge', () {
      final response = GetEuiccChallengeResponse.decode(fromHex(responseHex));

      expect(response.euiccChallenge, hasLength(16));
      expect(
        toHex(response.euiccChallenge!),
        '7256979D4D5A49F537812EC293FB90D1',
      );
    });

    test('re-encodes byte-for-byte', () {
      expect(
        toHex(GetEuiccChallengeResponse.decode(fromHex(responseHex)).encode()),
        normHex(responseHex),
      );
    });
  });

  group('EuiccConfiguredDataResponse (BF3C)', () {
    // ES10a GetEuiccConfiguredAddresses: where the card looks by default.
    const responseHex =
        'BF3C32'
        '801F736D64702D706C75732D302E65752E63642E7273702E6B6967656E2E636F6D'
        '810F6C70612E64732E67736D612E636F6D';

    test('decodes both addresses', () {
      final response = EuiccConfiguredDataResponse.decode(fromHex(responseHex));

      expect(response.defaultDpAddress, 'smdp-plus-0.eu.cd.rsp.kigen.com');
      expect(response.rootDsAddress, 'lpa.ds.gsma.com');
    });

    test('the optional v3 fields are absent on a v2 card', () {
      final response = EuiccConfiguredDataResponse.decode(fromHex(responseHex));

      expect(response.additionalRootDsAddresses, isNull);
      expect(response.allowedCiPKId, isNull);
    });

    test('re-encodes byte-for-byte', () {
      expect(
        toHex(
          EuiccConfiguredDataResponse.decode(fromHex(responseHex)).encode(),
        ),
        normHex(responseHex),
      );
    });
  });

  group('GetRatResponse (BF43)', () {
    // The Rules Authorisation Table decides which profile policy rules the
    // card will accept, so its BIT STRING has to decode correctly.
    const responseHex =
        'BF4318A016301480020560A10B30098003EEEEEE81008200820100';

    test('decodes the rule and its policy identifiers', () {
      final response = GetRatResponse.decode(fromHex(responseHex));

      expect(response.rat, hasLength(1));
      final rule = response.rat!.single;
      expect(rule.pprIds, isNotNull);
      // '0560' -> ppr1 and ppr2 set, pprUpdateControl clear.
      expect(rule.pprIds.toString(), contains('ppr1'));
      expect(rule.pprIds.toString(), contains('ppr2'));
      expect(rule.pprIds.toString(), isNot(contains('pprUpdateControl')));
    });

    test('decodes the operator the rule applies to', () {
      final response = GetRatResponse.decode(fromHex(responseHex));
      final rule = response.rat!.single;

      expect(rule.allowedOperators, hasLength(1));
      // 'EEEEEE' is the wildcard MCC/MNC: the rule covers every operator.
      expect(toHex(rule.allowedOperators!.single.mccMnc!), 'EEEEEE');
    });

    test('re-encodes byte-for-byte', () {
      expect(
        toHex(GetRatResponse.decode(fromHex(responseHex)).encode()),
        normHex(responseHex),
      );
    });
  });
}
