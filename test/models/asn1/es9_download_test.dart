import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/models/asn1/rsp_definitions.g.dart';

import 'asn1_hex.dart';

/// Decoding of structures captured from a real ES9+ profile download.
///
/// Every fixture below came off the wire during a download from a public test
/// SM-DP+ (smdp.io) onto an eUICC in a card reader. Hand-written fixtures prove
/// the decoder matches the spec; these prove it matches what a server and a
/// card actually send, which is not always the same thing.
///
/// Deliberately limited to the SM-DP+ side and the test profile's own metadata:
/// nothing here carries an EID, an eUICC certificate or a real subscriber's
/// ICCID. To run the full trace, including the BoundProfilePackage, capture
/// your own with tools/euicc_probe.py and the checkers in this directory.
void main() {
  const euiccInfo1Hex =
      'BF20358203020300A916041481370F5125D0B1D408D4C3B232E6D25E795BEBFB'
      'AA16041481370F5125D0B1D408D4C3B232E6D25E795BEBFB';

  const serverSigned1Hex =
      '30378008000000001D006587811002F17C74E813B0CCBAF1901B8BC2DDDB8307'
      '736D64702E696F841045D0FB2CFBFDEC57AE5113226AC9B96E';

  const serverCertificateHex =
      '3082028330820228A003020102021064055185218BD277DFA47D746D99432430'
      '0A06082A8648CE3D040302304431183016060355040A130F47534D204173736F'
      '63696174696F6E312830260603550403131F47534D204173736F63696174696F'
      '6E202D205253503220526F6F7420434931301E170D3234303232373030303030'
      '305A170D3237303232363233353935395A306C310B3009060355040613024742'
      '310F300D060355040713064C6F6E646F6E31253023060355040A131C54502047'
      '6C6F62616C204F7065726174696F6E73204C696D69746564310C300A06035504'
      '0B1303525350311730150603550403130E31474C4F42414C20534D2D44502B30'
      '59301306072A8648CE3D020106082A8648CE3D030107034200046FBF48592158'
      '490C37D65380F6CF1C15EC02FB0E04CB9788A371731BD2AFA627EA906C12BD02'
      'B74A05C08163CE1EFFDC357332DCD9C3139729922221D6A7A51CA381D33081D0'
      '30170603551D200101FF040D300B3009060767811201020104304D0603551D1F'
      '044630443042A040A03E863C687474703A2F2F67736D612D63726C2E73796D61'
      '7574682E636F6D2F6F66666C696E6563612F67736D612D727370322D726F6F74'
      '2D6369312E63726C300E0603551D0F0101FF04040302078030160603551D1104'
      '0F300D880B2B0601040181EC45010101301D0603551D0E0416041418F04C54D7'
      'A617353B0662E1BD055474D19CD33F301F0603551D2304183016801481370F51'
      '25D0B1D408D4C3B232E6D25E795BEBFB300A06082A8648CE3D04030203490030'
      '46022100BFBFD9279495D8A09531E55C9728C99B7B7533629FB3D564AC0C5CAD'
      '09405972022100F4BAF4758E94D403A6F66EB746A3C6D2FBF24E19067128182E'
      '7794FAD1FA1FBA';

  const profileMetadataHex =
      'BF255D5A0A980000000000000030F491094865696E656D616E6E920D42657474'
      '6572526F616D696E67B61830168002047081107273702E74727570686F6E652E'
      '636F6DB71B800302F4808109547275554B3030656E8209547275554B3030656E';

  const smdpSigned2Hex = '300D8008000000001D006587010100';

  group('ES10b.GetEUICCInfo1 (BF20)', () {
    test('decodes what the LPA sends to the SM-DP+', () {
      final info = EUICCInfo1.decode(fromHex(euiccInfo1Hex));

      expect(toHex(info.lowestSvn!), '020300'); // SGP.22 v2.3.0
      expect(info.euiccCiPKIdListForVerification, hasLength(1));
      expect(info.euiccCiPKIdListForSigning, hasLength(1));
      // Both lists name the same GSMA test CI.
      expect(
        toHex(info.euiccCiPKIdListForVerification!.first),
        '81370F5125D0B1D408D4C3B232E6D25E795BEBFB',
      );
    });

    test('re-encodes byte-for-byte', () {
      final bytes = fromHex(euiccInfo1Hex);
      expect(toHex(EUICCInfo1.decode(bytes).encode()), normHex(euiccInfo1Hex));
    });
  });

  group('ES9+.InitiateAuthentication response', () {
    test('decodes serverSigned1', () {
      final signed = ServerSigned1.decode(fromHex(serverSigned1Hex));

      expect(toHex(signed.transactionId!), '000000001D006587');
      expect(signed.serverAddress, 'smdp.io');
      expect(signed.euiccChallenge, hasLength(16));
      expect(signed.serverChallenge, hasLength(16));
    });

    test('serverSigned1 is an untagged SEQUENCE, so it starts with 30', () {
      expect(serverSigned1Hex.substring(0, 2), '30');
    });

    test('re-encodes serverSigned1 byte-for-byte', () {
      expect(
        toHex(ServerSigned1.decode(fromHex(serverSigned1Hex)).encode()),
        normHex(serverSigned1Hex),
      );
    });

    test('decodes the SM-DP+ X.509 certificate structure', () {
      final certificate = Certificate.decode(fromHex(serverCertificateHex));

      expect(certificate.tbsCertificate, isNotNull);
      expect(certificate.signatureAlgorithm, isNotNull);
      expect(certificate.tbsCertificate!.serialNumber, isNotNull);
      expect(certificate.tbsCertificate!.validity, isNotNull);
      expect(certificate.tbsCertificate!.subject, isNotNull);
    });

    test('GAP: certificate RDN values do not decode', () {
      // The subject really is C=GB, L=London, O=TP Global Operations Limited,
      // OU=RSP, CN=1GLOBAL SM-DP+. The attribute *types* are recognised but
      // every value comes back null, because AttributeTypeAndValue.value is an
      // open type the generator renders as opaque bytes and the toString
      // helper does not reach into. The bytes survive -- the certificate still
      // re-encodes exactly -- so this only affects display, but anything that
      // wants the subject has to parse it itself.
      final subject = Certificate.decode(
        fromHex(serverCertificateHex),
      ).tbsCertificate!.subject.toString();

      expect(subject, 'C=null, L=null, O=null, OU=null, CN=null');
    });

    test('re-encodes the certificate byte-for-byte', () {
      // 647 bytes through the PKIX SEQUENCE/SET/CHOICE nest.
      expect(
        toHex(Certificate.decode(fromHex(serverCertificateHex)).encode()),
        normHex(serverCertificateHex),
      );
    });
  });

  group('ES9+.AuthenticateClient response', () {
    test(
      'decodes the profile metadata the user is shown before installing',
      () {
        final metadata = StoreMetadataRequest.decode(
          fromHex(profileMetadataHex),
        );

        expect(metadata.iccid, hasLength(10));
        expect(metadata.serviceProviderName, 'Heinemann');
        expect(metadata.profileName, 'BetterRoaming');
        expect(toHex(metadata.profileOwner!.mccMnc!), '02F480');
        // The SM-DP+ sends no icon or policy rules for this profile.
        expect(metadata.icon, isNull);
        expect(metadata.profilePolicyRules, isNull);
      },
    );

    test('re-encodes the metadata byte-for-byte', () {
      expect(
        toHex(
          StoreMetadataRequest.decode(fromHex(profileMetadataHex)).encode(),
        ),
        normHex(profileMetadataHex),
      );
    });

    test('decodes smdpSigned2', () {
      final signed = SmdpSigned2.decode(fromHex(smdpSigned2Hex));

      expect(toHex(signed.transactionId!), '000000001D006587');
      // No confirmation code was required for this download.
      expect(signed.ccRequiredFlag, isFalse);
    });
  });

  group('fixture integrity', () {
    test('every fixture is a well-formed TLV of its stated length', () {
      const fixtures = <String, String>{
        'euiccInfo1': euiccInfo1Hex,
        'serverSigned1': serverSigned1Hex,
        'serverCertificate': serverCertificateHex,
        'profileMetadata': profileMetadataHex,
        'smdpSigned2': smdpSigned2Hex,
      };
      fixtures.forEach((name, hex) {
        final bytes = fromHex(hex);
        final tagLength = (bytes[0] & 0x1F) == 0x1F ? 2 : 1;
        var index = tagLength;
        var length = bytes[index];
        if (length & 0x80 != 0) {
          final count = length & 0x7F;
          length = 0;
          for (var i = 0; i < count; i++) {
            length = (length << 8) | bytes[index + 1 + i];
          }
          index += count;
        }
        expect(
          bytes.length - index - 1,
          length,
          reason: '$name declares $length content bytes',
        );
      });
    });
  });
}
