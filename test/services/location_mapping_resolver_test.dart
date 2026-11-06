import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/location_mapping_resolver.dart';

void main() {
  group('LocationMappingResolver', () {
    const resolver = LocationMappingResolver();

    group('Real-World Carrier Names and Country Resolution', () {
      test('matches Hong Kong carriers by alias', () {
        final clubSim = resolver.resolveLocation(
          iccid: '8985200014632217637',
          alias: 'ClubSim HK (+852 95594632)',
        );
        expect(clubSim.matched, isTrue);
        expect(clubSim.confidence, equals('exact_country'));
        expect(clubSim.coordinate?.countryCode, equals('HK'));
        expect(clubSim.coordinate?.latitude, closeTo(22.3193, 0.001));
        expect(clubSim.coordinate?.longitude, closeTo(114.1694, 0.001));
        expect(clubSim.coordinate?.cityName, equals('Hong Kong (Tsim Sha Tsui)'));

        final csl = resolver.resolveLocation(
          iccid: '8985200000000000001',
          alias: 'CSL Hong Kong Mobile',
        );
        expect(csl.coordinate?.countryCode, equals('HK'));

        final smartoneHk = resolver.resolveLocation(
          iccid: '8985200000000000002',
          alias: 'SmarTone 香港 5G',
        );
        expect(smartoneHk.coordinate?.countryCode, equals('HK'));
      });

      test('matches USA carriers by alias', () {
        final saily = resolver.resolveLocation(
          iccid: '89852350826069307603',
          alias: 'saily +1 859-943-7305',
        );
        expect(saily.matched, isTrue);
        expect(saily.confidence, equals('exact_country'));
        expect(saily.coordinate?.countryCode, equals('US'));
        expect(saily.coordinate?.latitude, closeTo(34.0522, 0.001));
        expect(saily.coordinate?.longitude, closeTo(-118.2437, 0.001));
        expect(saily.coordinate?.cityName, equals('Los Angeles, USA'));

        final tmobile = resolver.resolveLocation(
          iccid: '8901240000000000001',
          alias: 'T-Mobile USA Unlimited',
        );
        expect(tmobile.coordinate?.countryCode, equals('US'));

        final att = resolver.resolveLocation(
          iccid: '8901410000000000001',
          alias: 'AT&T United States Prepaid',
        );
        expect(att.coordinate?.countryCode, equals('US'));

        final usChinese = resolver.resolveLocation(
          iccid: '8901410000000000002',
          alias: '美国原生卡',
        );
        expect(usChinese.coordinate?.countryCode, equals('US'));
      });

      test('matches Estonia carriers by alias', () {
        final turtle = resolver.resolveLocation(
          iccid: '8937204017271161906',
          alias: '爱沙尼亚乌龟卡 (+372 57009330)',
        );
        expect(turtle.matched, isTrue);
        expect(turtle.confidence, equals('exact_country'));
        expect(turtle.coordinate?.countryCode, equals('EE'));
        expect(turtle.coordinate?.latitude, closeTo(59.4370, 0.001));
        expect(turtle.coordinate?.longitude, closeTo(24.7536, 0.001));
        expect(turtle.coordinate?.cityName, equals('Tallinn, Estonia'));

        final elisa = resolver.resolveLocation(
          iccid: '8937204000000000001',
          alias: 'Elisa Estonia Travel eSIM',
        );
        expect(elisa.coordinate?.countryCode, equals('EE'));

        final topConnect = resolver.resolveLocation(
          iccid: '8937204000000000002',
          alias: 'Top_Connect Roaming',
        );
        expect(topConnect.coordinate?.countryCode, equals('EE'));
      });

      test('matches UK and Japan carriers by alias', () {
        final giffgaff = resolver.resolveLocation(
          iccid: '8944123456789',
          alias: 'Giffgaff UK (+44 7123456789)',
        );
        expect(giffgaff.coordinate?.countryCode, equals('GB'));
        expect(giffgaff.coordinate?.latitude, closeTo(51.5074, 0.001));
        expect(giffgaff.coordinate?.longitude, closeTo(-0.1278, 0.001));
        expect(giffgaff.coordinate?.cityName, equals('London, UK'));

        final docomo = resolver.resolveLocation(
          iccid: '8981123456789',
          alias: 'Docomo Japan (+81 9012345678)',
        );
        expect(docomo.coordinate?.countryCode, equals('JP'));
        expect(docomo.coordinate?.latitude, closeTo(35.6762, 0.001));
        expect(docomo.coordinate?.longitude, closeTo(139.6503, 0.001));
        expect(docomo.coordinate?.cityName, equals('Tokyo, Japan'));

        final softbank = resolver.resolveLocation(
          iccid: '8981200000000000001',
          alias: 'SoftBank Tokyo Data',
        );
        expect(softbank.coordinate?.countryCode, equals('JP'));
      });

      test('matches Australia carriers by alias', () {
        final telstra = resolver.resolveLocation(
          iccid: '8961010000000000001',
          alias: 'Telstra Australia (+61 412345678)',
        );
        expect(telstra.matched, isTrue);
        expect(telstra.confidence, equals('exact_country'));
        expect(telstra.coordinate?.countryCode, equals('AU'));
        expect(telstra.coordinate?.latitude, closeTo(-33.8688, 0.001));
        expect(telstra.coordinate?.longitude, closeTo(151.2093, 0.001));
        expect(telstra.coordinate?.cityName, equals('Sydney, Australia'));

        final optus = resolver.resolveLocation(
          iccid: '8961020000000000001',
          alias: 'Optus Sydney 5G',
        );
        expect(optus.coordinate?.countryCode, equals('AU'));

        final vodafoneAu = resolver.resolveLocation(
          iccid: '8961030000000000001',
          alias: 'Vodafone 澳大利亚 eSIM',
        );
        expect(vodafoneAu.coordinate?.countryCode, equals('AU'));

        final aussieTelecom = resolver.resolveLocation(
          iccid: '8961040000000000001',
          alias: '澳洲电信 Prepaid',
        );
        expect(aussieTelecom.coordinate?.countryCode, equals('AU'));
      });

      test('matches Canada carriers by alias', () {
        final rogers = resolver.resolveLocation(
          iccid: '8910200000000000001',
          alias: 'Rogers Canada Toronto (+1 416-555-0199)',
        );
        expect(rogers.matched, isTrue);
        expect(rogers.confidence, equals('exact_country'));
        expect(rogers.coordinate?.countryCode, equals('CA'));
        expect(rogers.coordinate?.latitude, closeTo(43.6532, 0.001));
        expect(rogers.coordinate?.longitude, closeTo(-79.3832, 0.001));
        expect(rogers.coordinate?.cityName, equals('Toronto, Canada'));

        final bell = resolver.resolveLocation(
          iccid: '8910200000000000002',
          alias: 'Bell 加拿大 eSIM',
        );
        expect(bell.coordinate?.countryCode, equals('CA'));

        final freedom = resolver.resolveLocation(
          iccid: '8910200000000000003',
          alias: 'Freedom Mobile Canada',
        );
        expect(freedom.coordinate?.countryCode, equals('CA'));
      });

      test('matches Singapore carriers by alias', () {
        final singtel = resolver.resolveLocation(
          iccid: '8965010000000000001',
          alias: 'Singtel Singapore (+65 9123 4567)',
        );
        expect(singtel.matched, isTrue);
        expect(singtel.confidence, equals('exact_country'));
        expect(singtel.coordinate?.countryCode, equals('SG'));
        expect(singtel.coordinate?.latitude, closeTo(1.3521, 0.001));
        expect(singtel.coordinate?.longitude, closeTo(103.8198, 0.001));
        expect(singtel.coordinate?.cityName, equals('Singapore (Marina Bay)'));

        final starhub = resolver.resolveLocation(
          iccid: '8965020000000000001',
          alias: 'StarHub 新加坡 5G',
        );
        expect(starhub.coordinate?.countryCode, equals('SG'));

        final m1 = resolver.resolveLocation(
          iccid: '8965030000000000001',
          alias: 'M1 Singapore Roaming',
        );
        expect(m1.coordinate?.countryCode, equals('SG'));
      });

      test('matches Taiwan carriers by alias', () {
        final cht = resolver.resolveLocation(
          iccid: '8988600000000000001',
          alias: 'Chunghwa Telecom Taiwan (+886 912-345-678)',
        );
        expect(cht.matched, isTrue);
        expect(cht.confidence, equals('exact_country'));
        expect(cht.coordinate?.countryCode, equals('TW'));
        expect(cht.coordinate?.latitude, closeTo(25.0330, 0.001));
        expect(cht.coordinate?.longitude, closeTo(121.5654, 0.001));
        expect(cht.coordinate?.cityName, equals('Taipei, Taiwan'));

        final twm = resolver.resolveLocation(
          iccid: '8988600000000000002',
          alias: '台灣大哥大 5G eSIM',
        );
        expect(twm.coordinate?.countryCode, equals('TW'));

        final fet = resolver.resolveLocation(
          iccid: '8988600000000000003',
          alias: '远传电信 台湾预付卡',
        );
        expect(fet.coordinate?.countryCode, equals('TW'));
      });

      test('matches Macau carriers by alias', () {
        final ctm = resolver.resolveLocation(
          iccid: '8985300000000000001',
          alias: 'CTM Macau (+853 6612 3456)',
        );
        expect(ctm.matched, isTrue);
        expect(ctm.confidence, equals('exact_country'));
        expect(ctm.coordinate?.countryCode, equals('MO'));
        expect(ctm.coordinate?.latitude, closeTo(22.1987, 0.001));
        expect(ctm.coordinate?.longitude, closeTo(113.5439, 0.001));
        expect(ctm.coordinate?.cityName, equals('Macau'));

        final ctmZhTrad = resolver.resolveLocation(
          iccid: '8985300000000000002',
          alias: '澳門電訊 預付卡',
        );
        expect(ctmZhTrad.coordinate?.countryCode, equals('MO'));

        final ctmZhSimp = resolver.resolveLocation(
          iccid: '8985300000000000003',
          alias: '澳门电讯 5G',
        );
        expect(ctmZhSimp.coordinate?.countryCode, equals('MO'));
      });

      test('matches Germany carriers by alias', () {
        final telekom = resolver.resolveLocation(
          iccid: '8949010000000000001',
          alias: 'Telekom Deutschland Germany (+49 151 12345678)',
        );
        expect(telekom.matched, isTrue);
        expect(telekom.confidence, equals('exact_country'));
        expect(telekom.coordinate?.countryCode, equals('DE'));
        expect(telekom.coordinate?.latitude, closeTo(50.1109, 0.001));
        expect(telekom.coordinate?.longitude, closeTo(8.6821, 0.001));
        expect(telekom.coordinate?.cityName, equals('Frankfurt, Germany'));

        final vodafoneDe = resolver.resolveLocation(
          iccid: '8949020000000000001',
          alias: 'Vodafone 德国 Frankfurt',
        );
        expect(vodafoneDe.coordinate?.countryCode, equals('DE'));

        final o2De = resolver.resolveLocation(
          iccid: '8949030000000000001',
          alias: 'O2 德國 eSIM',
        );
        expect(o2De.coordinate?.countryCode, equals('DE'));
      });

      test('matches France carriers by alias', () {
        final orange = resolver.resolveLocation(
          iccid: '8933010000000000001',
          alias: 'Orange France (+33 6 12 34 56 78)',
        );
        expect(orange.matched, isTrue);
        expect(orange.confidence, equals('exact_country'));
        expect(orange.coordinate?.countryCode, equals('FR'));
        expect(orange.coordinate?.latitude, closeTo(48.8566, 0.001));
        expect(orange.coordinate?.longitude, closeTo(2.3522, 0.001));
        expect(orange.coordinate?.cityName, equals('Paris, France'));

        final sfr = resolver.resolveLocation(
          iccid: '8933020000000000001',
          alias: 'SFR Paris 法国',
        );
        expect(sfr.coordinate?.countryCode, equals('FR'));

        final freeMobile = resolver.resolveLocation(
          iccid: '8933030000000000001',
          alias: 'Free Mobile 法國',
        );
        expect(freeMobile.coordinate?.countryCode, equals('FR'));
      });

      test('matches Netherlands carriers by alias', () {
        final kpn = resolver.resolveLocation(
          iccid: '8931010000000000001',
          alias: 'KPN Netherlands (+31 6 12345678)',
        );
        expect(kpn.matched, isTrue);
        expect(kpn.confidence, equals('exact_country'));
        expect(kpn.coordinate?.countryCode, equals('NL'));
        expect(kpn.coordinate?.latitude, closeTo(52.3676, 0.001));
        expect(kpn.coordinate?.longitude, closeTo(4.9041, 0.001));
        expect(kpn.coordinate?.cityName, equals('Amsterdam, Netherlands'));

        final vodafoneNl = resolver.resolveLocation(
          iccid: '8931020000000000001',
          alias: 'Vodafone 荷兰 Amsterdam',
        );
        expect(vodafoneNl.coordinate?.countryCode, equals('NL'));

        final odido = resolver.resolveLocation(
          iccid: '8931030000000000001',
          alias: 'Odido 荷蘭 5G',
        );
        expect(odido.coordinate?.countryCode, equals('NL'));
      });
    });

    group('MCC Fallback Resolution', () {
      test('resolves all standard MCC codes correctly', () {
        final mccMap = {
          '454': 'HK',
          '455': 'MO',
          '310': 'US',
          '311': 'US',
          '312': 'US',
          '313': 'US',
          '314': 'US',
          '315': 'US',
          '316': 'US',
          '248': 'EE',
          '234': 'GB',
          '235': 'GB',
          '440': 'JP',
          '441': 'JP',
          '525': 'SG',
          '262': 'DE',
          '204': 'NL',
          '208': 'FR',
          '466': 'TW',
          '505': 'AU',
          '302': 'CA',
        };

        for (final entry in mccMap.entries) {
          final res = resolver.resolveLocation(
            iccid: '8900000000000000000',
            alias: 'Generic Carrier',
            mcc: entry.key,
          );
          expect(res.matched, isTrue, reason: 'Failed for MCC ${entry.key}');
          expect(res.confidence, equals('mcc'), reason: 'Failed confidence for MCC ${entry.key}');
          expect(res.coordinate?.countryCode, equals(entry.value), reason: 'Failed countryCode for MCC ${entry.key}');
        }
      });

      test('falls back to Hong Kong default when MCC is unknown and alias has no country', () {
        final unknownMcc = resolver.resolveLocation(
          iccid: '8999900000000000000',
          alias: 'Mystery SIM Card',
          mcc: '999',
        );
        expect(unknownMcc.matched, isTrue);
        expect(unknownMcc.confidence, equals('fallback'));
        expect(unknownMcc.coordinate?.countryCode, equals('HK'));
        expect(unknownMcc.coordinate?.cityName, equals('Hong Kong (Tsim Sha Tsui)'));
      });
    });

    group('Mixed Casing, Emojis, and Bracketed Strings', () {
      test('matches exact test cases specified in requirements', () {
        final usBracket = resolver.resolveLocation(
          iccid: '8901000000000000001',
          alias: '[US] Saily eSIM +1',
        );
        expect(usBracket.matched, isTrue);
        expect(usBracket.confidence, equals('exact_country'));
        expect(usBracket.coordinate?.countryCode, equals('US'));

        final hkEmoji = resolver.resolveLocation(
          iccid: '8985200000000000002',
          alias: 'ClubSim (HK) 🇭🇰',
        );
        expect(hkEmoji.matched, isTrue);
        expect(hkEmoji.confidence, equals('exact_country'));
        expect(hkEmoji.coordinate?.countryCode, equals('HK'));

        final eeEmoji = resolver.resolveLocation(
          iccid: '8937200000000000003',
          alias: 'Elisa EE 🇪🇪',
        );
        expect(eeEmoji.matched, isTrue);
        expect(eeEmoji.confidence, equals('exact_country'));
        expect(eeEmoji.coordinate?.countryCode, equals('EE'));
      });

      test('matches mixed casing variants for all supported countries', () {
        final mixedCases = [
          {'alias': 'sAiLy eSiM +1 (uSa)', 'expected': 'US'},
          {'alias': 'cLUBsIM hOnG kOnG', 'expected': 'HK'},
          {'alias': 'eLiSa eStOnIa', 'expected': 'EE'},
          {'alias': 'gIfFgAfF uK lOnDoN', 'expected': 'GB'},
          {'alias': 'dOcOmO jApAn', 'expected': 'JP'},
          {'alias': 'sInGtEl sInGaPoRe', 'expected': 'SG'},
          {'alias': 'dEuTsChE tElEkOm gErMaNy', 'expected': 'DE'},
          {'alias': 'vOdAfOnE nEtHeRlAnDs aMsTeRdAm', 'expected': 'NL'},
          {'alias': 'oRaNgE fRaNcE pArIs', 'expected': 'FR'},
          {'alias': 'cHuNgHwA tAiWaN', 'expected': 'TW'},
          {'alias': 'cTm mAcAu', 'expected': 'MO'},
          {'alias': 'tElStRa aUsTrAlIa sYdNeY', 'expected': 'AU'},
          {'alias': 'rOgErS cAnAdA tOrOnTo', 'expected': 'CA'},
        ];

        for (final item in mixedCases) {
          final res = resolver.resolveLocation(
            iccid: '8900000000000000000',
            alias: item['alias'],
          );
          expect(res.matched, isTrue, reason: 'Failed for ${item['alias']}');
          expect(res.confidence, equals('exact_country'), reason: 'Failed confidence for ${item['alias']}');
          expect(res.coordinate?.countryCode, equals(item['expected']), reason: 'Failed code for ${item['alias']}');
        }
      });

      test('matches emoji strings across all regions and flag positions', () {
        final emojiCases = [
          {'alias': '🇭🇰 ClubSim 香港', 'expected': 'HK'},
          {'alias': '🇺🇸 [US] AT&T eSIM', 'expected': 'US'},
          {'alias': '🇪🇪 Elisa 爱沙尼亚', 'expected': 'EE'},
          {'alias': '🇬🇧 Vodafone UK', 'expected': 'GB'},
          {'alias': '🇯🇵 NTT Docomo Japan', 'expected': 'JP'},
          {'alias': '🇸🇬 Singtel 5G Singapore', 'expected': 'SG'},
          {'alias': '🇩🇪 Deutsche Telekom Germany', 'expected': 'DE'},
          {'alias': '🇳🇱 KPN Telecom Netherlands', 'expected': 'NL'},
          {'alias': '🇫🇷 Orange France Paris', 'expected': 'FR'},
          {'alias': '🇹🇼 中華電信 台灣', 'expected': 'TW'},
          {'alias': '🇲🇴 CTM 澳門電訊', 'expected': 'MO'},
          {'alias': '🇦🇺 Telstra 5G Australia', 'expected': 'AU'},
          {'alias': '🇨🇦 Rogers LTE Canada', 'expected': 'CA'},
        ];

        for (final item in emojiCases) {
          final res = resolver.resolveLocation(
            iccid: '8900000000000000000',
            alias: item['alias'],
          );
          expect(res.matched, isTrue, reason: 'Failed for ${item['alias']}');
          expect(res.coordinate?.countryCode, equals(item['expected']), reason: 'Failed code for ${item['alias']}');
        }
      });

      test('matches bracketed and nested strings with various bracket characters', () {
        final bracketCases = [
          {'alias': '[US] Saily eSIM +1', 'expected': 'US'},
          {'alias': '【HK】(ClubSim) [Hong Kong]', 'expected': 'HK'},
          {'alias': '(EE) [Elisa Estonia] {Roaming}', 'expected': 'EE'},
          {'alias': '<GB> [Giffgaff UK] (Standby)', 'expected': 'GB'},
          {'alias': '[JP] (Docomo Japan) 【Business】', 'expected': 'JP'},
          {'alias': '[SG] (Singtel Singapore) {Travel}', 'expected': 'SG'},
          {'alias': '[DE] (Telekom Germany) [Frankfurt]', 'expected': 'DE'},
          {'alias': '[FR] (Orange France) [Paris eSIM]', 'expected': 'FR'},
          {'alias': '[NL] (KPN Netherlands) {Amsterdam}', 'expected': 'NL'},
          {'alias': '【TW】(Chunghwa Telecom Taiwan) <Main>', 'expected': 'TW'},
          {'alias': '[MO] (CTM Macau) [Primary]', 'expected': 'MO'},
          {'alias': '[AU] (Telstra Australia) <Sydney 5G>', 'expected': 'AU'},
          {'alias': '[CA] (Rogers Canada) [Toronto eSIM]', 'expected': 'CA'},
        ];

        for (final item in bracketCases) {
          final res = resolver.resolveLocation(
            iccid: '8900000000000000000',
            alias: item['alias'],
          );
          expect(res.matched, isTrue, reason: 'Failed for ${item['alias']}');
          expect(res.coordinate?.countryCode, equals(item['expected']), reason: 'Failed code for ${item['alias']}');
        }
      });
    });

    group('Custom Override Rules - Valid Cases', () {
      test('honours custom override rule by ICCID with custom label', () {
        final res = resolver.resolveLocation(
          iccid: '8985200014632217637',
          alias: 'ClubSim HK (+852)',
          customRules: {
            '8985200014632217637': '22.2783, 114.1747, Wan Chai',
          },
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('custom'));
        expect(res.coordinate?.latitude, closeTo(22.2783, 0.0001));
        expect(res.coordinate?.longitude, closeTo(114.1747, 0.0001));
        expect(res.coordinate?.cityName, equals('Wan Chai'));
        expect(res.coordinate?.countryCode, equals('CUSTOM'));
      });

      test('honours custom override rule by ICCID with default label when label omitted', () {
        final res = resolver.resolveLocation(
          iccid: '8985200014632217637',
          alias: 'ClubSim HK (+852)',
          customRules: {
            '8985200014632217637': '22.2783, 114.1747',
          },
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('custom'));
        expect(res.coordinate?.latitude, closeTo(22.2783, 0.0001));
        expect(res.coordinate?.longitude, closeTo(114.1747, 0.0001));
        expect(res.coordinate?.cityName, equals('Custom'));
      });

      test('honours custom override rule by Alias when ICCID is not in custom rules', () {
        final res = resolver.resolveLocation(
          iccid: '8999999999999999999',
          alias: 'My Special eSIM',
          customRules: {
            'My Special eSIM': '1.3521, 103.8198, Custom Singapore Office',
          },
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('custom'));
        expect(res.coordinate?.latitude, closeTo(1.3521, 0.0001));
        expect(res.coordinate?.longitude, closeTo(103.8198, 0.0001));
        expect(res.coordinate?.cityName, equals('Custom Singapore Office'));
      });

      test('trims surrounding whitespace in custom rule string', () {
        final res = resolver.resolveLocation(
          iccid: '8985200014632217637',
          alias: 'ClubSim HK',
          customRules: {
            '8985200014632217637': '   52.3676  ,   4.9041   ,   Amsterdam Datacenter   ',
          },
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('custom'));
        expect(res.coordinate?.latitude, closeTo(52.3676, 0.0001));
        expect(res.coordinate?.longitude, closeTo(4.9041, 0.0001));
        expect(res.coordinate?.cityName, equals('Amsterdam Datacenter'));
      });
    });

    group('Custom Override Rules - Malformed and Invalid Inputs', () {
      const testIccid = '8985200014632217637';

      test('ignores empty custom rule string and falls back to alias match', () {
        final res = resolver.resolveLocation(
          iccid: testIccid,
          alias: 'ClubSim HK (+852)',
          customRules: {testIccid: ''},
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('exact_country'));
        expect(res.coordinate?.countryCode, equals('HK'));
      });

      test('ignores whitespace-only custom rule string and falls back to alias match', () {
        final res = resolver.resolveLocation(
          iccid: testIccid,
          alias: 'ClubSim HK (+852)',
          customRules: {testIccid: '   '},
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('exact_country'));
        expect(res.coordinate?.countryCode, equals('HK'));
      });

      test('ignores single coordinate without comma and falls back to alias match', () {
        final res = resolver.resolveLocation(
          iccid: testIccid,
          alias: 'saily +1 859-943-7305',
          customRules: {testIccid: '22.3193'},
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('exact_country'));
        expect(res.coordinate?.countryCode, equals('US'));
      });

      test('ignores single coordinate with trailing comma and falls back to alias match', () {
        final res = resolver.resolveLocation(
          iccid: testIccid,
          alias: 'saily +1 859-943-7305',
          customRules: {testIccid: '34.0522,'},
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('exact_country'));
        expect(res.coordinate?.countryCode, equals('US'));
      });

      test('ignores leading comma without latitude and falls back to alias match', () {
        final res = resolver.resolveLocation(
          iccid: testIccid,
          alias: 'saily +1 859-943-7305',
          customRules: {testIccid: ',-118.2437'},
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('exact_country'));
        expect(res.coordinate?.countryCode, equals('US'));
      });

      test('ignores only-comma custom rule and falls back to alias match', () {
        final res = resolver.resolveLocation(
          iccid: testIccid,
          alias: 'saily +1 859-943-7305',
          customRules: {testIccid: ','},
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('exact_country'));
        expect(res.coordinate?.countryCode, equals('US'));
      });

      test('ignores non-numeric coordinates and falls back to alias match', () {
        final resBothNonNumeric = resolver.resolveLocation(
          iccid: testIccid,
          alias: 'Giffgaff UK (+44)',
          customRules: {testIccid: 'not_a_latitude, not_a_longitude'},
        );
        expect(resBothNonNumeric.confidence, equals('exact_country'));
        expect(resBothNonNumeric.coordinate?.countryCode, equals('GB'));

        final resBadLat = resolver.resolveLocation(
          iccid: testIccid,
          alias: 'Giffgaff UK (+44)',
          customRules: {testIccid: 'bad_lat, -0.1278'},
        );
        expect(resBadLat.confidence, equals('exact_country'));
        expect(resBadLat.coordinate?.countryCode, equals('GB'));

        final resBadLng = resolver.resolveLocation(
          iccid: testIccid,
          alias: 'Giffgaff UK (+44)',
          customRules: {testIccid: '51.5074, bad_lng'},
        );
        expect(resBadLng.confidence, equals('exact_country'));
        expect(resBadLng.coordinate?.countryCode, equals('GB'));

        final resSpecialChars = resolver.resolveLocation(
          iccid: testIccid,
          alias: 'Giffgaff UK (+44)',
          customRules: {testIccid: r'$$HASH$$, NaN, Invalid'},
        );
        expect(resSpecialChars.confidence, equals('exact_country'));
        expect(resSpecialChars.coordinate?.countryCode, equals('GB'));
      });

      test('ignores invalid custom rule and falls back to MCC when alias is generic', () {
        final res = resolver.resolveLocation(
          iccid: testIccid,
          alias: 'Generic Standby Card',
          mcc: '525',
          customRules: {testIccid: 'invalid_lat, invalid_lng'},
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('mcc'));
        expect(res.coordinate?.countryCode, equals('SG'));
      });

      test('ignores invalid custom rule and falls back to Hong Kong default when alias and MCC are absent', () {
        final resEmpty = resolver.resolveLocation(
          iccid: testIccid,
          customRules: {testIccid: ''},
        );
        expect(resEmpty.matched, isTrue);
        expect(resEmpty.confidence, equals('fallback'));
        expect(resEmpty.coordinate?.countryCode, equals('HK'));

        final resSingleCoord = resolver.resolveLocation(
          iccid: testIccid,
          customRules: {testIccid: '45.1234'},
        );
        expect(resSingleCoord.matched, isTrue);
        expect(resSingleCoord.confidence, equals('fallback'));
        expect(resSingleCoord.coordinate?.countryCode, equals('HK'));

        final resNonNumeric = resolver.resolveLocation(
          iccid: testIccid,
          customRules: {testIccid: 'abc, def'},
        );
        expect(resNonNumeric.matched, isTrue);
        expect(resNonNumeric.confidence, equals('fallback'));
        expect(resNonNumeric.coordinate?.countryCode, equals('HK'));
      });

      test('ignores invalid custom rule keyed by alias', () {
        final res = resolver.resolveLocation(
          iccid: '8900000000000000000',
          alias: 'Docomo Japan (+81)',
          customRules: {'Docomo Japan (+81)': 'single_coord_only'},
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('exact_country'));
        expect(res.coordinate?.countryCode, equals('JP'));
      });
    });

    group('Default and Edge Cases', () {
      test('falls back to Hong Kong default when alias is empty and MCC is null', () {
        final res = resolver.resolveLocation(
          iccid: '8900000000000000000',
          alias: '',
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('fallback'));
        expect(res.coordinate?.countryCode, equals('HK'));
      });

      test('falls back to Hong Kong default when alias has no match and MCC is empty', () {
        final res = resolver.resolveLocation(
          iccid: '8900000000000000000',
          alias: 'Unknown Standby Profile',
          mcc: '',
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('fallback'));
        expect(res.coordinate?.countryCode, equals('HK'));
      });

      test('handles completely null alias, null mcc, null customRules', () {
        final res = resolver.resolveLocation(
          iccid: '8900000000000000000',
        );
        expect(res.matched, isTrue);
        expect(res.confidence, equals('fallback'));
        expect(res.coordinate?.countryCode, equals('HK'));
      });
    });
  });
}
