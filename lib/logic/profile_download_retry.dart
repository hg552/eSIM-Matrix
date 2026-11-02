import '../utils/error_codes.dart';

typedef ProfileDownloadRetryOperation<T> =
    Future<T> Function(ProfileDownloadRetryAttempt attempt);
typedef ProfileDownloadBeforeRetry =
    Future<void> Function(ProfileDownloadRetryEvent event);
typedef ProfileDownloadRetryEventCallback =
    void Function(ProfileDownloadRetryEvent event);
typedef ProfileDownloadRetryBackoff = Duration Function(int failedAttempt);
typedef ProfileDownloadRetryDelay = Future<void> Function(Duration duration);

/// Lifecycle events suitable for translating retry progress into UI status.
enum ProfileDownloadRetryEventType {
  attemptStarted,
  retryScheduled,
  succeeded,
  failed,
}

class ProfileDownloadRetryAttempt {
  const ProfileDownloadRetryAttempt({
    required this.number,
    required this.maxAttempts,
  });

  final int number;
  final int maxAttempts;

  bool get isLast => number == maxAttempts;
}

class ProfileDownloadRetryEvent {
  const ProfileDownloadRetryEvent({
    required this.type,
    required this.attempt,
    required this.maxAttempts,
    this.backoff,
    this.error,
    this.stackTrace,
  });

  final ProfileDownloadRetryEventType type;
  final int attempt;
  final int maxAttempts;
  final Duration? backoff;
  final Object? error;
  final StackTrace? stackTrace;

  int? get nextAttempt =>
      type == ProfileDownloadRetryEventType.retryScheduled ? attempt + 1 : null;

  bool get willRetry => type == ProfileDownloadRetryEventType.retryScheduled;
}

bool isTransientProfileDownloadBluetoothError(Object error) {
  if (error is! AppException) return false;

  return switch (error.code) {
    AppErrorCode.ERROR_BLUETOOTH_TIMEOUT ||
    AppErrorCode.ERROR_BLUETOOTH_NOT_CONNECTED ||
    AppErrorCode.ERROR_BLUETOOTH_CONNECT_FAILED ||
    AppErrorCode.ERROR_BLUETOOTH_DISABLED => true,
    _ => false,
  };
}

/// Retries a profile-download operation after narrowly scoped Bluetooth errors.
///
/// [beforeRetry] is called after a retry is scheduled and before the bounded
/// backoff delay. Recovery errors are intentionally propagated to the caller.
class ProfileDownloadRetry {
  ProfileDownloadRetry({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 2),
    ProfileDownloadRetryBackoff? backoff,
    ProfileDownloadRetryDelay? delay,
  }) : _backoff = backoff,
       _delay = delay ?? Future<void>.delayed {
    if (maxAttempts < 1) {
      throw ArgumentError.value(maxAttempts, 'maxAttempts', 'must be positive');
    }
    if (initialBackoff.isNegative) {
      throw ArgumentError.value(
        initialBackoff,
        'initialBackoff',
        'must not be negative',
      );
    }
    if (maxBackoff.isNegative) {
      throw ArgumentError.value(
        maxBackoff,
        'maxBackoff',
        'must not be negative',
      );
    }
  }

  final int maxAttempts;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final ProfileDownloadRetryBackoff? _backoff;
  final ProfileDownloadRetryDelay _delay;

  /// Runs [operation] until it succeeds, fails permanently, or exhausts the
  /// configured attempt count.
  Future<T> run<T>(
    ProfileDownloadRetryOperation<T> operation, {
    ProfileDownloadBeforeRetry? beforeRetry,
    ProfileDownloadRetryEventCallback? onEvent,
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final attemptInfo = ProfileDownloadRetryAttempt(
        number: attempt,
        maxAttempts: maxAttempts,
      );
      onEvent?.call(
        ProfileDownloadRetryEvent(
          type: ProfileDownloadRetryEventType.attemptStarted,
          attempt: attempt,
          maxAttempts: maxAttempts,
        ),
      );

      try {
        final result = await operation(attemptInfo);
        onEvent?.call(
          ProfileDownloadRetryEvent(
            type: ProfileDownloadRetryEventType.succeeded,
            attempt: attempt,
            maxAttempts: maxAttempts,
          ),
        );
        return result;
      } catch (error, stackTrace) {
        final canRetry =
            attempt < maxAttempts &&
            isTransientProfileDownloadBluetoothError(error);
        if (!canRetry) {
          onEvent?.call(
            ProfileDownloadRetryEvent(
              type: ProfileDownloadRetryEventType.failed,
              attempt: attempt,
              maxAttempts: maxAttempts,
              error: error,
              stackTrace: stackTrace,
            ),
          );
          Error.throwWithStackTrace(error, stackTrace);
        }

        final backoff = _boundedBackoff(attempt);
        final retryEvent = ProfileDownloadRetryEvent(
          type: ProfileDownloadRetryEventType.retryScheduled,
          attempt: attempt,
          maxAttempts: maxAttempts,
          backoff: backoff,
          error: error,
          stackTrace: stackTrace,
        );
        onEvent?.call(retryEvent);
        await beforeRetry?.call(retryEvent);
        if (backoff > Duration.zero) {
          await _delay(backoff);
        }
      }
    }

    throw StateError('Profile download retry loop ended unexpectedly');
  }

  Duration _boundedBackoff(int failedAttempt) {
    final requested =
        _backoff?.call(failedAttempt) ?? _defaultBackoff(failedAttempt);
    if (requested.isNegative) return Duration.zero;
    if (requested > maxBackoff) return maxBackoff;
    return requested;
  }

  Duration _defaultBackoff(int failedAttempt) {
    var microseconds = initialBackoff.inMicroseconds;
    final maximum = maxBackoff.inMicroseconds;
    if (microseconds >= maximum) return maxBackoff;

    for (var retry = 1; retry < failedAttempt; retry++) {
      if (microseconds >= maximum ~/ 2) return maxBackoff;
      microseconds *= 2;
    }
    return Duration(microseconds: microseconds);
  }
}
