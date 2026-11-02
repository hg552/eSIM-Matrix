import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/l10n/app_localizations.dart';
import 'package:nlpa2/pages/settings_page.dart';
import 'package:nlpa2/plugins/plugin_manager.dart';
import 'package:nlpa2/settings/app_settings.dart';

void main() {
  testWidgets(
    'VoWiFi requires confirmation and disables without a dialog',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 4000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final settings = AppSettings();
      await settings.setVowifiEnabled(false);

      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsPage(),
        ),
      );
      await tester.pumpAndSettle();

      final vowifiTile = find.text('VoWiFi');
      expect(vowifiTile, findsOneWidget);
      expect(settings.vowifiEnabled, isFalse);
      expect(PluginManager().appTabs.any((tab) => tab.id == 'vowifi'), isFalse);

      await tester.ensureVisible(vowifiTile);
      await tester.tap(vowifiTile);
      await tester.pumpAndSettle();

      expect(find.text('Enable experimental VoWiFi?'), findsOneWidget);
      expect(
        find.textContaining('communicates directly with your mobile network'),
        findsOneWidget,
      );
      expect(settings.vowifiEnabled, isFalse);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(settings.vowifiEnabled, isFalse);

      await tester.tap(vowifiTile);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enable'));
      await tester.pumpAndSettle();

      expect(settings.vowifiEnabled, isTrue);
      expect(PluginManager().appTabs.any((tab) => tab.id == 'vowifi'), isTrue);

      await tester.tap(vowifiTile);
      await tester.pumpAndSettle();
      expect(find.text('Enable experimental VoWiFi?'), findsNothing);
      expect(settings.vowifiEnabled, isFalse);
      expect(PluginManager().appTabs.any((tab) => tab.id == 'vowifi'), isFalse);
    },
    skip: !AppSettings().vowifiAvailable,
  );
}
