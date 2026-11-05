import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/remote_gateway_service.dart';

/// A resend sweep walks the whole history and waits out three attempts per
/// message when the endpoint is dead. The 20-second tick must not turn that
/// into a queue of sweeps, each one delivering the same code again.
void main() {
  final now = DateTime(2026, 11, 4, 12, 0);
  const interval = Duration(minutes: 5);

  test('the first sweep always runs', () {
    expect(
      shouldRunAutomaticSmsRetry(
        lastAttempt: null,
        now: now,
        interval: interval,
      ),
      isTrue,
    );
  });

  test('a sweep inside the interval is held back', () {
    expect(
      shouldRunAutomaticSmsRetry(
        lastAttempt: now.subtract(const Duration(minutes: 1)),
        now: now,
        interval: interval,
      ),
      isFalse,
    );
  });

  test('a sweep at the interval boundary runs', () {
    expect(
      shouldRunAutomaticSmsRetry(
        lastAttempt: now.subtract(interval),
        now: now,
        interval: interval,
      ),
      isTrue,
    );
  });

  test('a sweep after a long outage runs again', () {
    expect(
      shouldRunAutomaticSmsRetry(
        lastAttempt: now.subtract(const Duration(hours: 2)),
        now: now,
        interval: interval,
      ),
      isTrue,
    );
  });
}
