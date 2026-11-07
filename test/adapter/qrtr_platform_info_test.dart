import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/adapter/qrtr/qrtr_host.dart';

void main() {
  group('ReaderPlatformInfo', () {
    test('reads the native map a Qualcomm handset answers', () {
      final info = ReaderPlatformInfo.fromMap({
        'hardware': 'qcom',
        'socManufacturer': 'QTI',
        'socModel': 'SM8650',
        'isQualcomm': true,
        'secureElementFeature': true,
        'omapiUiccFeature': true,
      });

      expect(info.isQualcomm, isTrue);
      expect(info.secureElementFeature, isTrue);
      expect(info.omapiUiccFeature, isTrue);
      expect(info.socLabel, 'QTI SM8650');
    });

    test('names a MediaTek chip so QRTR can be ruled out by name', () {
      final info = ReaderPlatformInfo.fromMap({
        'hardware': 'mt6769z',
        'socManufacturer': 'MediaTek',
        'socModel': 'MT6769Z',
        'isQualcomm': false,
        'secureElementFeature': false,
        'omapiUiccFeature': false,
      });

      expect(info.isQualcomm, isFalse);
      expect(info.socLabel, 'MediaTek MT6769Z');
    });

    test('falls back to the board name when no SoC field is set', () {
      final info = ReaderPlatformInfo.fromMap({
        'hardware': 'mt6768',
        'socManufacturer': '',
        'socModel': '',
        'isQualcomm': false,
      });

      expect(info.socLabel, 'mt6768');
    });

    test('an absent answer reads as an unknown, non-Qualcomm handset', () {
      const info = ReaderPlatformInfo();

      expect(info.isQualcomm, isFalse);
      expect(info.secureElementFeature, isFalse);
      expect(info.socLabel, 'unknown SoC');
    });

    test('a missing map is tolerated rather than thrown', () {
      expect(ReaderPlatformInfo.fromMap(null).socLabel, 'unknown SoC');
    });
  });
}
