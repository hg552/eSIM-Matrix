import '../../adapter/euicc_adapter.dart';
import '../../l10n/app_localizations.dart';

/// The loading message for the step a reader's connect has reached.
///
/// The attempt number appears only on a retry.
String connectStepMessage(
  AppLocalizations l10n,
  ReaderConnectProgress progress,
) {
  return switch (progress.step) {
    ReaderConnectStep.waitingForBluetooth => l10n.waitingForBluetooth,
    ReaderConnectStep.connectingBluetooth =>
      progress.attempt > 1
          ? l10n.connectingOverBluetoothAttempt(
              progress.attempt,
              progress.attempts,
            )
          : l10n.connectingOverBluetooth,
    ReaderConnectStep.discoveringServices => l10n.discoveringReaderServices,
    ReaderConnectStep.enablingNotifications => l10n.settingUpBluetoothLink,
    ReaderConnectStep.authenticating => l10n.authenticatingWithReader,
    ReaderConnectStep.initializing => l10n.initializingReader,
    ReaderConnectStep.switchingMode => l10n.switchingReaderToEuiccMode,
    ReaderConnectStep.waitingForRestart => l10n.waitingForReaderRestart,
  };
}
