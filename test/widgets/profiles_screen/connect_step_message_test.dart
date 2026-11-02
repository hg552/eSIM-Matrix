import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/adapter/euicc_adapter.dart';
import 'package:nlpa2/l10n/app_localizations.dart';
import 'package:nlpa2/widgets/profiles_screen/connect_step_message.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  test('mentions the attempt only on a retry', () {
    expect(
      connectStepMessage(
        l10n,
        const ReaderConnectProgress(
          ReaderConnectStep.connectingBluetooth,
          attempts: 3,
        ),
      ),
      'Connecting over Bluetooth...',
    );
    expect(
      connectStepMessage(
        l10n,
        const ReaderConnectProgress(
          ReaderConnectStep.connectingBluetooth,
          attempt: 2,
          attempts: 3,
        ),
      ),
      'Connecting over Bluetooth (attempt 2 of 3)...',
    );
  });

  test('gives every step a message of its own', () {
    final messages = {
      for (final step in ReaderConnectStep.values)
        connectStepMessage(l10n, ReaderConnectProgress(step)),
    };

    expect(messages, hasLength(ReaderConnectStep.values.length));
    expect(messages, isNot(contains(l10n.connectingToReader)));
  });
}
