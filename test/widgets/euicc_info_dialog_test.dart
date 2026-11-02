import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/l10n/app_localizations.dart';
import 'package:nlpa2/models/asn1/rsp_definitions.g.dart';
import 'package:nlpa2/widgets/euicc_info_dialog.dart';

import '../models/asn1/asn1_hex.dart';

void main() {
  // Real responses from an eUICC, so the dialog is fed what a card actually
  // sends rather than a hand-built object.
  const info2Hex =
      'BF227B810302030182030203008303241127840D81010A82040016274083027FE3'
      '8505067F36F7C086030F0100870302030088020398A916041481370F5125D0B1D4'
      '08D4C3B232E6D25E795BEBFBAA16041481370F5125D0B1D408D4C3B232E6D25E79'
      '5BEBFB9902064004030100000C0D4B4E2D42542D55502D30393234';
  const configuredHex =
      'BF3C32'
      '801F736D64702D706C75732D302E65752E63642E7273702E6B6967656E2E636F6D'
      '810F6C70612E64732E67736D612E636F6D';

  Future<void> openDialog(
    WidgetTester tester, {
    EuiccConfiguredDataResponse? configured,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => EuiccInfoDialog.show(
                context,
                EUICCInfo2.decode(fromHex(info2Hex)),
                configured: configured,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the configured addresses when the card reported them', (
    tester,
  ) async {
    await openDialog(
      tester,
      configured: EuiccConfiguredDataResponse.decode(fromHex(configuredHex)),
    );

    expect(find.text('CONFIGURED ADDRESSES'), findsOneWidget);
    expect(find.text('smdp-plus-0.eu.cd.rsp.kigen.com'), findsOneWidget);
    expect(find.text('lpa.ds.gsma.com'), findsOneWidget);
  });

  testWidgets('omits the section entirely when there is nothing to show', (
    tester,
  ) async {
    await openDialog(tester);

    expect(find.text('CONFIGURED ADDRESSES'), findsNothing);
    expect(find.text('lpa.ds.gsma.com'), findsNothing);
    // The rest of the dialog is unaffected.
    expect(find.text('KN-BT-UP-0924'), findsOneWidget);
  });

  testWidgets('falls back for an absent default SM-DP+', (tester) async {
    // rootDsAddress is mandatory in SGP.22; defaultDpAddress is not, and a card
    // with no default configured omits it.
    const rootOnly = 'BF3C11810F6C70612E64732E67736D612E636F6D';
    await openDialog(
      tester,
      configured: EuiccConfiguredDataResponse.decode(fromHex(rootOnly)),
    );

    expect(find.text('lpa.ds.gsma.com'), findsOneWidget);
    expect(find.text('smdp-plus-0.eu.cd.rsp.kigen.com'), findsNothing);
    // Shown as unavailable rather than blank or crashing.
    expect(find.text('Unavailable'), findsWidgets);
  });

  testWidgets('addresses are selectable, so they can be copied', (
    tester,
  ) async {
    await openDialog(
      tester,
      configured: EuiccConfiguredDataResponse.decode(fromHex(configuredHex)),
    );

    expect(
      find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == 'lpa.ds.gsma.com',
      ),
      findsOneWidget,
    );
  });
}
