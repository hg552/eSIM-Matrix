import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/cellular_data_guardian.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DataGuardCapabilities', () {
    test('unsupported build exposes no enforcement path', () {
      const caps = DataGuardCapabilities.unsupported();
      expect(caps.canEnforce, isFalse);
      expect(caps.modifyPhoneState, isFalse);
      expect(caps.root, isFalse);
      expect(caps.toJson()['canEnforce'], isFalse);
    });

    test('root alone is enough to enforce', () {
      const caps = DataGuardCapabilities(
        modifyPhoneState: false,
        root: true,
        telephonyApis: false,
        sdkInt: 34,
      );
      expect(caps.canEnforce, isTrue);
    });

    test('privileged telephony API is enough to enforce', () {
      const caps = DataGuardCapabilities(
        modifyPhoneState: true,
        root: false,
        telephonyApis: true,
        sdkInt: 34,
      );
      expect(caps.canEnforce, isTrue);
    });
  });

  group('SubscriptionDataState', () {
    test('reads platform map without inventing missing values', () {
      final state = SubscriptionDataState.fromMap({
        'subscriptionId': 3,
        'slotIndex': 1,
        'dataEnabled': false,
        'roamingEnabled': null,
      });
      expect(state.subscriptionId, 3);
      expect(state.slotIndex, 1);
      expect(state.dataEnabled, isFalse);
      expect(state.roamingEnabled, isNull);
    });

    test('tolerates a malformed map', () {
      final state = SubscriptionDataState.fromMap({});
      expect(state.subscriptionId, -1);
      expect(state.slotIndex, -1);
      expect(state.dataEnabled, isNull);
    });
  });

  group('DataGuardResult', () {
    test('lockdown result carries the pre-switch snapshot', () {
      final result = DataGuardResult.fromMap({
        'subscriptionId': 7,
        'enforced': true,
        'before': {
          'subscriptionId': 7,
          'slotIndex': 1,
          'dataEnabled': true,
          'roamingEnabled': false,
        },
        'data': {
          'applied': true,
          'viaApi': true,
          'viaShell': false,
          'observed': false,
        },
      });
      expect(result.enforced, isTrue);
      expect(result.viaApi, isTrue);
      expect(result.viaShell, isFalse);
      expect(result.observed, isFalse);
      expect(result.before?.dataEnabled, isTrue);
      expect(result.before?.roamingEnabled, isFalse);
      expect(result.toJson()['enforced'], isTrue);
      expect((result.toJson()['before'] as Map)['dataEnabled'], isTrue);
    });

    test('shell-only enforcement still counts as enforced', () {
      final result = DataGuardResult.fromMap({
        'subscriptionId': 2,
        'data': {'applied': true, 'viaApi': false, 'viaShell': true},
      });
      expect(result.enforced, isTrue);
      expect(result.viaShell, isTrue);
    });

    test('failed enforcement is reported, not silently swallowed', () {
      final result = DataGuardResult.fromMap({
        'subscriptionId': 2,
        'data': {'applied': false, 'viaApi': false, 'viaShell': false},
      });
      expect(result.enforced, isFalse);
    });

    test('skipped result is explicit', () {
      const skipped = DataGuardResult.skipped(-1);
      expect(skipped.enforced, isFalse);
      expect(skipped.error, 'skipped');
    });
  });

  group('CellularDataGuardian degradation', () {
    test('non-Android host returns unsupported without touching the channel', () async {
      final guardian = CellularDataGuardian();
      final caps = await guardian.capabilities();
      final states = await guardian.status();
      final result = await guardian.lockdown(5);
      final restored = await guardian.restore(subscriptionId: 5, dataEnabled: true);

      expect(caps.canEnforce, isFalse);
      expect(states, isEmpty);
      // Skipping must never claim enforcement happened.
      expect(result.enforced, isFalse);
      expect(restored.enforced, isFalse);
    });

    test('invalid subscription id is skipped instead of sent to the platform', () async {
      final guardian = CellularDataGuardian();
      final result = await guardian.lockdown(-1);
      expect(result.enforced, isFalse);
      expect(result.error, 'skipped');
    });
  });
}
