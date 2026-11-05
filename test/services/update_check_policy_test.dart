import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/update_check_policy.dart';

/// The update check reaches the network and can pop a dialog, so both the
/// schedule and the "already told you" rules have to hold.
void main() {
  final now = DateTime(2026, 11, 4, 12, 0);
  const interval = Duration(hours: 24);

  group('UpdateCheckPolicy.shouldCheck', () {
    test('checks when nothing was checked before', () {
      expect(
        UpdateCheckPolicy.shouldCheck(
          lastCheckAt: null,
          lastCheckBuild: 0,
          currentBuild: 133,
          now: now,
        ),
        isTrue,
      );
    });

    test('does not check again within the interval', () {
      expect(
        UpdateCheckPolicy.shouldCheck(
          lastCheckAt: now.subtract(const Duration(hours: 3)),
          lastCheckBuild: 133,
          currentBuild: 133,
          now: now,
        ),
        isFalse,
      );
    });

    test('checks again once the interval has passed', () {
      expect(
        UpdateCheckPolicy.shouldCheck(
          lastCheckAt: now.subtract(interval),
          lastCheckBuild: 133,
          currentBuild: 133,
          now: now,
        ),
        isTrue,
      );
    });

    test('checks right away after the app itself was updated', () {
      // A new build may be running against a feed that already knows about
      // something newer, so the schedule does not apply to it.
      expect(
        UpdateCheckPolicy.shouldCheck(
          lastCheckAt: now.subtract(const Duration(minutes: 1)),
          lastCheckBuild: 132,
          currentBuild: 133,
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('UpdateCheckPolicy.shouldNotify', () {
    test('announces a version that was never announced', () {
      expect(
        UpdateCheckPolicy.shouldNotify(
          lastNotifiedBuild: 133,
          availableBuild: 140,
        ),
        isTrue,
      );
    });

    test('stays quiet about a version already announced', () {
      expect(
        UpdateCheckPolicy.shouldNotify(
          lastNotifiedBuild: 140,
          availableBuild: 140,
        ),
        isFalse,
      );
    });

    test('announces a newer version after an older one was announced', () {
      expect(
        UpdateCheckPolicy.shouldNotify(
          lastNotifiedBuild: 140,
          availableBuild: 141,
        ),
        isTrue,
      );
    });
  });

  group('UpdateCheckPolicy.shouldPrompt', () {
    test('shows the dialog for a version that was not dismissed', () {
      expect(
        UpdateCheckPolicy.shouldPrompt(
          dismissedBuild: 133,
          availableBuild: 140,
        ),
        isTrue,
      );
    });

    test('does not show a dismissed version again', () {
      expect(
        UpdateCheckPolicy.shouldPrompt(
          dismissedBuild: 140,
          availableBuild: 140,
        ),
        isFalse,
      );
    });

    test('shows a newer version after an older one was dismissed', () {
      expect(
        UpdateCheckPolicy.shouldPrompt(
          dismissedBuild: 140,
          availableBuild: 141,
        ),
        isTrue,
      );
    });
  });
}
