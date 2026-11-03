import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:nlpa2/adapter/discovery_report.dart';
import 'package:nlpa2/services/diagnostics_service.dart';
import 'package:nlpa2/settings/app_settings.dart';

void main() {
  group('DiagnosticsService.redact', () {
    test('masks 19-20 digit ICCIDs while keeping prefix and suffix', () {
      const line = 'Processing card with ICCID 8986048123456789012F in slot 0';
      final redacted = DiagnosticsService.redact(line);
      expect(redacted, contains('8986...012F [ICCID masked]'));
      expect(redacted, isNot(contains('123456789')));
    });

    test('masks 32-character EIDs', () {
      const line = 'eUICC EID is 89049032000000000000000000001234';
      final redacted = DiagnosticsService.redact(line);
      expect(redacted, contains('8904...1234 [EID masked]'));
      expect(redacted, isNot(contains('00000000000000000000')));
    });

    test('masks Telegram bot tokens', () {
      const line = 'Sending alert with bot token 123456789:ABCdefGHIjklMNOpqrsTUVwxyz1234567_a';
      final redacted = DiagnosticsService.redact(line);
      expect(redacted, contains('[BOT_TOKEN_REDACTED]'));
      expect(redacted, isNot(contains('ABCdefGHIjklMNOpqrsTUVwxyz1234567_a')));
    });
  });

  group('DiagnosticsService.deriveHints', () {
    test('detects when built-in OMAPI is disabled in settings', () {
      final settings = AppSettings();
      settings.setEnableOmapiConnector(false);

      final hints = DiagnosticsService.deriveHints(
        discovery: null,
        native: const {
          'device': {'sdkInt': 34},
        },
        settings: settings,
      );

      expect(hints.any((h) => h.titleZh.contains('内置 OMAPI 读卡器已关闭')), isTrue);
    });

    test('detects when OMAPI is poisoned and advises reboot', () {
      final settings = AppSettings();
      settings.setEnableOmapiConnector(true);

      final hints = DiagnosticsService.deriveHints(
        discovery: null,
        native: const {
          'device': {'sdkInt': 34},
          'se': {
            'serviceCreated': true,
            'serviceConnected': true,
            'poison': 'reader=SIM1 reason=Binder transaction died',
          },
        },
        settings: settings,
      );

      final poisonHint = hints.firstWhere((h) => h.titleEn.contains('poisoned'));
      expect(poisonHint.severity, DiagnosticSeverity.error);
      expect(poisonHint.actionZh, contains('重启手机'));
    });

    test('detects when SEService connected but 0 readers returned by ROM', () {
      final settings = AppSettings();
      settings.setEnableOmapiConnector(true);

      final hints = DiagnosticsService.deriveHints(
        discovery: null,
        native: const {
          'device': {'sdkInt': 34, 'featureOmapiUicc': false},
          'se': {
            'serviceCreated': true,
            'serviceConnected': true,
            'readers': <dynamic>[],
          },
        },
        settings: settings,
      );

      expect(hints.any((h) => h.titleZh.contains('底层返回 0 个读卡器')), isTrue);
      expect(hints.any((h) => h.titleZh.contains('未声明 OMAPI UICC')), isTrue);
    });
  });

  group('DiagnosticsService.formatReport', () {
    test('formats all sections cleanly without throwing', () {
      final settings = AppSettings();
      final at = DateTime(2026, 11, 3, 14, 30);
      final discovery = ReaderDiscoveryReport(
        at: at,
        forced: true,
        sources: [
          const DiscoverySourceResult(
            source: 'Built-in OMAPI',
            status: DiscoveryStatus.ok,
            readerNames: ['omapi:SIM1 -> SIM 1'],
            elapsed: Duration(milliseconds: 45),
          ),
          const DiscoverySourceResult(
            source: 'CCID (USB)',
            status: DiscoveryStatus.skipped,
            detail: 'CCID connector is off in settings',
          ),
        ],
        totalReaders: 1,
      );

      final report = DiagnosticsService.formatReport(
        at: at,
        discovery: discovery,
        native: const {
          'device': {
            'manufacturer': 'Xiaomi',
            'brand': 'Redmi',
            'model': '22011211C',
            'device': 'rubens',
            'release': '14',
            'sdkInt': 34,
            'romDisplay': 'UKQ1.230804.001',
            'securityPatch': '2026-10-01',
            'featureOmapiUicc': true,
          },
          'telephony': {
            'modemCount': 2,
            'simState': 'READY',
            'slotSimStates': ['slot0=READY', 'slot1=READY'],
          },
          'se': {
            'serviceCreated': true,
            'serviceConnected': true,
            'readers': [
              {
                'name': 'SIM1',
                'secureElementPresent': true,
                'acceptedBySimFilter': true,
                'localSession': false,
                'openChannels': <String>[],
              }
            ],
          },
        },
        settings: settings,
        hints: const [
          DiagnosticHint(
            severity: DiagnosticSeverity.info,
            titleEn: 'SIM Ready',
            titleZh: 'SIM 卡就绪',
            detailZh: '卡槽通信正常',
          ),
        ],
        logs: [
          LogRecord(
            Level.INFO,
            'Discovery [Built-in OMAPI]: 1 reader(s)',
            'CompositeAdapter',
          ),
        ],
      );

      expect(report, contains('eUICC-Nexus Diagnostic Report'));
      expect(report, contains('1. Application Info'));
      expect(report, contains('2. Diagnosis Hints'));
      expect(report, contains('3. Reader Discovery Breakdown'));
      expect(report, contains('Built-in OMAPI'));
      expect(report, contains('5. Device & ROM Details'));
      expect(report, contains('Redmi 22011211C'));
      expect(report, contains('8. Recent Filtered Logs'));
    });
  });
}
