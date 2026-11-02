import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/plugins/plugin_manager.dart';
import 'package:nlpa2/services/vowifi_sms_service.dart';
import 'package:nlpa2/settings/app_settings.dart';

void main() {
  group('VowifiPlugin', () {
    test(
      'SIM probing is registered independently of desktop VoWiFi opt-in',
      () {
        expect(AppSettings().vowifiEnabled, isFalse);
        expect(PluginManager().hasPlugin('vowifi_sim_probe'), isTrue);
      },
    );

    test('plugin registration follows VoWiFi availability', () {
      final settings = AppSettings();
      final plugins = PluginManager();

      expect(plugins.hasPlugin('vowifi'), settings.vowifiAvailable);
      expect(
        plugins.plugins.any((plugin) => plugin.id == 'vowifi'),
        settings.vowifiAvailable,
      );
      expect(plugins.appTabs.any((tab) => tab.id == 'vowifi'), isFalse);
    });

    test('tab and service only activate after explicit opt-in', () async {
      final settings = AppSettings();
      final plugins = PluginManager();
      final service = VowifiSmsService();

      await expectLater(
        service.refreshSession('missing'),
        throwsA(isA<UnsupportedError>()),
      );

      await settings.setVowifiEnabled(true, disclaimerAccepted: true);
      expect(
        plugins.appTabs.any((tab) => tab.id == 'vowifi'),
        settings.vowifiAvailable,
      );

      if (settings.vowifiAvailable) {
        await service.refreshSession('missing');
        await expectLater(
          service.sendTextSms('missing', to: '+12025550123', text: 'test'),
          throwsA(isA<StateError>()),
        );
      } else {
        await expectLater(
          service.refreshSession('missing'),
          throwsA(isA<UnsupportedError>()),
        );
        await expectLater(
          service.sendTextSms('missing', to: '+12025550123', text: 'test'),
          throwsA(isA<UnsupportedError>()),
        );
      }

      await settings.setVowifiEnabled(false);
      expect(plugins.appTabs.any((tab) => tab.id == 'vowifi'), isFalse);
    });
  });
}
