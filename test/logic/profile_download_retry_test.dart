import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/logic/profile_download_retry.dart';
import 'package:nlpa2/utils/error_codes.dart';

void main() {
  group('ProfileDownloadRetry', () {
    test(
      'retries transient Bluetooth failures up to three attempts by default',
      () async {
        var calls = 0;
        final recoveries = <int>[];
        final delays = <Duration>[];

        final retry = ProfileDownloadRetry(
          initialBackoff: const Duration(milliseconds: 10),
          delay: (duration) async => delays.add(duration),
        );

        final result = await retry.run<String>((attempt) async {
          calls++;
          expect(attempt.maxAttempts, 3);
          if (!attempt.isLast) {
            throw AppException(AppErrorCode.ERROR_BLUETOOTH_TIMEOUT);
          }
          return 'installed';
        }, beforeRetry: (event) async => recoveries.add(event.attempt));

        expect(result, 'installed');
        expect(calls, 3);
        expect(recoveries, [1, 2]);
        expect(delays, const [
          Duration(milliseconds: 10),
          Duration(milliseconds: 20),
        ]);
      },
    );

    test('retries only the supported transient Bluetooth codes', () async {
      const transientCodes = [
        AppErrorCode.ERROR_BLUETOOTH_TIMEOUT,
        AppErrorCode.ERROR_BLUETOOTH_NOT_CONNECTED,
        AppErrorCode.ERROR_BLUETOOTH_CONNECT_FAILED,
        AppErrorCode.ERROR_BLUETOOTH_DISABLED,
      ];

      for (final code in transientCodes) {
        var calls = 0;
        final retry = ProfileDownloadRetry(
          maxAttempts: 2,
          initialBackoff: Duration.zero,
        );

        final result = await retry.run<int>((_) async {
          calls++;
          if (calls == 1) throw AppException(code);
          return calls;
        });

        expect(result, 2, reason: code.name);
      }
    });

    test('does not retry non-transient or non-AppException failures', () async {
      for (final error in <Object>[
        AppException(AppErrorCode.ERROR_BLUETOOTH_PERMISSION_DENIED),
        AppException(AppErrorCode.ERROR_TRANSACTION_FAILED),
        StateError('not Bluetooth'),
      ]) {
        var calls = 0;
        final retry = ProfileDownloadRetry(initialBackoff: Duration.zero);

        await expectLater(
          retry.run<void>((_) async {
            calls++;
            throw error;
          }),
          throwsA(same(error)),
        );
        expect(calls, 1);
      }
    });

    test(
      'clamps injected backoff and reports retry events for UI status',
      () async {
        final delays = <Duration>[];
        final events = <ProfileDownloadRetryEvent>[];
        var calls = 0;
        final retry = ProfileDownloadRetry(
          maxAttempts: 2,
          maxBackoff: const Duration(milliseconds: 75),
          backoff: (_) => const Duration(seconds: 30),
          delay: (duration) async => delays.add(duration),
        );

        await retry.run<void>((_) async {
          calls++;
          if (calls == 1) {
            throw AppException(AppErrorCode.ERROR_BLUETOOTH_NOT_CONNECTED);
          }
        }, onEvent: events.add);

        expect(delays, const [Duration(milliseconds: 75)]);
        expect(events.map((event) => event.type), [
          ProfileDownloadRetryEventType.attemptStarted,
          ProfileDownloadRetryEventType.retryScheduled,
          ProfileDownloadRetryEventType.attemptStarted,
          ProfileDownloadRetryEventType.succeeded,
        ]);
        final scheduled = events[1];
        expect(scheduled.attempt, 1);
        expect(scheduled.nextAttempt, 2);
        expect(scheduled.maxAttempts, 2);
        expect(scheduled.willRetry, isTrue);
        expect(scheduled.backoff, const Duration(milliseconds: 75));
        expect(scheduled.error, isA<AppException>());
        expect(scheduled.stackTrace, isNotNull);
      },
    );

    test('runs recovery before the backoff and next attempt', () async {
      final order = <String>[];
      var calls = 0;
      final retry = ProfileDownloadRetry(
        maxAttempts: 2,
        initialBackoff: const Duration(milliseconds: 1),
        delay: (duration) async => order.add('delay'),
      );

      await retry.run<void>((_) async {
        calls++;
        order.add('attempt$calls');
        if (calls == 1) {
          throw AppException(AppErrorCode.ERROR_BLUETOOTH_CONNECT_FAILED);
        }
      }, beforeRetry: (_) async => order.add('recover'));

      expect(order, ['attempt1', 'recover', 'delay', 'attempt2']);
    });

    test(
      'two mid-transfer Bluetooth cuts restart the complete download session',
      () async {
        const lastBppBlockOrdinal = 9;
        const cutAtBlockOrdinalByAttempt = {1: 2, 2: 7};
        final challenges = <String>[];
        final authenticatedSessions = <String>[];
        final workflowBySession = <String, List<String>>{};
        final bppBlocksBySession = <String, List<int>>{};
        final recoveredAttempts = <int>[];

        final retry = ProfileDownloadRetry(initialBackoff: Duration.zero);

        final result = await retry.run<String>(
          (attempt) async {
            final challenge = 'challenge-${attempt.number}';
            challenges.add(challenge);

            final session = 'session-${attempt.number}';
            authenticatedSessions.add('$session:$challenge');
            workflowBySession[session] = [
              'get-challenge:$challenge',
              'authenticate:$challenge',
              'prepare-download:$session',
              'fetch-bpp:$session',
            ];
            final writtenBlocks = bppBlocksBySession[session] = <int>[];

            for (
              var blockOrdinal = 1;
              blockOrdinal <= lastBppBlockOrdinal;
              blockOrdinal++
            ) {
              writtenBlocks.add(blockOrdinal);
              workflowBySession[session]!.add('store-data:$blockOrdinal');
              if (cutAtBlockOrdinalByAttempt[attempt.number] == blockOrdinal) {
                throw AppException(AppErrorCode.ERROR_BLUETOOTH_TIMEOUT);
              }
            }

            return 'installed-by:$session';
          },
          beforeRetry: (event) async {
            recoveredAttempts.add(event.attempt);
          },
        );

        expect(result, 'installed-by:session-3');
        expect(challenges, ['challenge-1', 'challenge-2', 'challenge-3']);
        expect(authenticatedSessions, [
          'session-1:challenge-1',
          'session-2:challenge-2',
          'session-3:challenge-3',
        ]);
        expect(recoveredAttempts, [1, 2]);

        expect(bppBlocksBySession, {
          'session-1': [1, 2],
          'session-2': [1, 2, 3, 4, 5, 6, 7],
          'session-3': [1, 2, 3, 4, 5, 6, 7, 8, 9],
        });
        for (final blocks in bppBlocksBySession.values) {
          expect(
            blocks.toSet().length,
            blocks.length,
            reason: 'an uncertain STORE DATA command must not be replayed',
          );
        }

        for (var attempt = 1; attempt <= 3; attempt++) {
          expect(workflowBySession['session-$attempt']!.take(4), [
            'get-challenge:challenge-$attempt',
            'authenticate:challenge-$attempt',
            'prepare-download:session-$attempt',
            'fetch-bpp:session-$attempt',
          ]);
        }
      },
    );

    test(
      'preserves the final failure stack trace after retries are exhausted',
      () async {
        final retry = ProfileDownloadRetry(initialBackoff: Duration.zero);

        Object? caughtError;
        StackTrace? caughtStack;
        try {
          await retry.run<void>((attempt) async {
            if (attempt.isLast) return _throwFinalBluetoothFailure();
            throw AppException(AppErrorCode.ERROR_BLUETOOTH_TIMEOUT);
          });
        } catch (error, stackTrace) {
          caughtError = error;
          caughtStack = stackTrace;
        }

        expect(caughtError, isA<AppException>());
        expect(caughtStack.toString(), contains('_throwFinalBluetoothFailure'));
      },
    );

    test(
      'reports the final failure with its attempt and stack trace',
      () async {
        final events = <ProfileDownloadRetryEvent>[];
        final error = AppException(AppErrorCode.ERROR_BLUETOOTH_TIMEOUT);
        final retry = ProfileDownloadRetry(
          maxAttempts: 1,
          initialBackoff: Duration.zero,
        );

        await expectLater(
          retry.run<void>((_) async => throw error, onEvent: events.add),
          throwsA(same(error)),
        );

        expect(events.last.type, ProfileDownloadRetryEventType.failed);
        expect(events.last.attempt, 1);
        expect(events.last.maxAttempts, 1);
        expect(events.last.error, same(error));
        expect(events.last.stackTrace, isNotNull);
        expect(events.last.willRetry, isFalse);
      },
    );
  });
}

Future<void> _throwFinalBluetoothFailure() async {
  throw AppException(AppErrorCode.ERROR_BLUETOOTH_TIMEOUT);
}
