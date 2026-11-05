import 'package:nlpa2/services/telegram_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TelegramRegistryState', () {
    test('records a chat and keeps the first seen time', () {
      final state = TelegramRegistryState();
      state.record('1001', 'Ada', now: 1000);
      state.record('1001', 'Ada Lovelace', now: 2000);

      expect(state.count, 1);
      final subscriber = state.subscriber('1001');
      expect(subscriber, isNotNull);
      expect(subscriber!.chatId, '1001');
      expect(subscriber.displayName, 'Ada Lovelace');
      expect(subscriber.firstSeenAt, 1000);
      expect(subscriber.lastSeenAt, 2000);
    });

    test('keeps the old display name when the new one is empty', () {
      final state = TelegramRegistryState();
      state.record('1001', 'Ada', now: 1000);
      state.record('1001', '', now: 2000);

      expect(state.subscriber('1001')!.displayName, 'Ada');
    });

    test('ignores an empty chat id', () {
      final state = TelegramRegistryState();
      state.record('', 'Nobody');
      expect(state.count, 0);
    });

    test('sorts the chats by the last time they were seen', () {
      final state = TelegramRegistryState();
      state.record('1001', 'Ada', now: 1000);
      state.record('1002', 'Bob', now: 5000);
      state.record('1003', 'Cleo', now: 3000);

      expect(
        state.subscribers.map((s) => s.chatId),
        ['1002', '1003', '1001'],
      );
    });

    test('removes a chat', () {
      final state = TelegramRegistryState();
      state.record('1001', 'Ada');
      expect(state.remove('1001'), isTrue);
      expect(state.remove('1001'), isFalse);
      expect(state.count, 0);
    });

    test('survives a persistence round trip', () {
      final state = TelegramRegistryState();
      state.record('1001', 'Ada', now: 1000);
      state.record('1002', 'Bob', now: 2000);
      state.markAnnounced('release-1', now: 3000);

      final restored = TelegramRegistryState.decode(state.encode());
      expect(restored.count, 2);
      expect(restored.subscriber('1002')!.displayName, 'Bob');
      expect(restored.subscriber('1001')!.firstSeenAt, 1000);
      expect(restored.wasAnnounced('release-1'), isTrue);
      expect(restored.wasAnnounced('release-2'), isFalse);
    });

    test('drops malformed entries instead of failing to load', () {
      final restored = TelegramRegistryState.decode(
        '{"subscribers":{"1001":{"displayName":"Ada"}},'
        '"announcements":{"release-1":"not a number"}}',
      );
      expect(restored.count, 0);
      expect(restored.wasAnnounced('release-1'), isFalse);
    });
  });
}
