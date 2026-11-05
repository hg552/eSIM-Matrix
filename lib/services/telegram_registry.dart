import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A private chat the bot has spoken to.
class TelegramSubscriber {
  const TelegramSubscriber({
    required this.chatId,
    required this.displayName,
    required this.firstSeenAt,
    required this.lastSeenAt,
  });

  factory TelegramSubscriber.fromJson(Map<String, Object?> json) {
    final chatId = json['chatId'];
    if (chatId is! String || chatId.isEmpty) {
      throw const FormatException('Invalid subscriber chat id');
    }
    return TelegramSubscriber(
      chatId: chatId,
      displayName: json['displayName'] as String? ?? '',
      firstSeenAt: json['firstSeenAt'] as int? ?? 0,
      lastSeenAt: json['lastSeenAt'] as int? ?? 0,
    );
  }

  final String chatId;
  final String displayName;
  final int firstSeenAt;
  final int lastSeenAt;

  Map<String, Object?> toJson() => {
    'chatId': chatId,
    'displayName': displayName,
    'firstSeenAt': firstSeenAt,
    'lastSeenAt': lastSeenAt,
  };
}

/// The chats the bot knows about.
///
/// Only the configured chat may command the device, but a release note has to
/// reach everybody who talks to the bot, so every private chat that writes to
/// the bot is remembered here. Registration grants no control rights: it only
/// makes the chat a recipient of announcements.
class TelegramRegistryState {
  TelegramRegistryState({
    Map<String, TelegramSubscriber>? subscribers,
    Map<String, int>? announcements,
  }) : _subscribers = {...?subscribers},
       _announcements = {...?announcements};

  factory TelegramRegistryState.fromJson(Map<String, Object?> json) {
    final subscribers = <String, TelegramSubscriber>{};
    final rawSubscribers = json['subscribers'];
    if (rawSubscribers is Map) {
      for (final entry in rawSubscribers.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        try {
          final subscriber = TelegramSubscriber.fromJson(
            Map<String, Object?>.from(value),
          );
          subscribers[subscriber.chatId] = subscriber;
        } on FormatException {
          continue;
        }
      }
    }
    final announcements = <String, int>{};
    final rawAnnouncements = json['announcements'];
    if (rawAnnouncements is Map) {
      for (final entry in rawAnnouncements.entries) {
        final value = entry.value;
        if (value is int) announcements['${entry.key}'] = value;
      }
    }
    return TelegramRegistryState(
      subscribers: subscribers,
      announcements: announcements,
    );
  }

  final Map<String, TelegramSubscriber> _subscribers;
  final Map<String, int> _announcements;

  /// The known chats, most recently seen first.
  List<TelegramSubscriber> get subscribers {
    final list = _subscribers.values.toList()
      ..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    return List.unmodifiable(list);
  }

  TelegramSubscriber? subscriber(String chatId) => _subscribers[chatId];

  int get count => _subscribers.length;

  /// Remembers a chat, keeping the time it was first seen.
  void record(String chatId, String displayName, {int? now}) {
    if (chatId.isEmpty) return;
    final timestamp = now ?? DateTime.now().millisecondsSinceEpoch;
    final existing = _subscribers[chatId];
    _subscribers[chatId] = TelegramSubscriber(
      chatId: chatId,
      displayName: displayName.isNotEmpty
          ? displayName
          : (existing?.displayName ?? ''),
      firstSeenAt: existing?.firstSeenAt ?? timestamp,
      lastSeenAt: timestamp,
    );
  }

  bool remove(String chatId) => _subscribers.remove(chatId) != null;

  /// Whether an announcement with this key already went out.
  bool wasAnnounced(String key) => _announcements.containsKey(key);

  void markAnnounced(String key, {int? now}) {
    _announcements[key] = now ?? DateTime.now().millisecondsSinceEpoch;
  }

  Map<String, Object?> toJson() => {
    'subscribers': {
      for (final entry in _subscribers.entries) entry.key: entry.value.toJson(),
    },
    'announcements': Map<String, int>.from(_announcements),
  };

  String encode() => jsonEncode(toJson());

  static TelegramRegistryState decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('Invalid registry');
    return TelegramRegistryState.fromJson(Map<String, Object?>.from(decoded));
  }
}

/// Persists [TelegramRegistryState] in the shared preferences.
class TelegramRegistry {
  TelegramRegistry._();

  static final TelegramRegistry instance = TelegramRegistry._();

  static const String _prefsKey = 'telegram_registry.v1';

  TelegramRegistryState? _cache;

  Future<TelegramRegistryState> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    TelegramRegistryState state;
    if (raw == null || raw.isEmpty) {
      state = TelegramRegistryState();
    } else {
      try {
        state = TelegramRegistryState.decode(raw);
      } on FormatException {
        state = TelegramRegistryState();
      }
    }
    _cache = state;
    return state;
  }

  Future<void> _persist(TelegramRegistryState state) async {
    _cache = state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, state.encode());
  }

  /// Remembers a chat that writes to the bot.
  Future<void> record(String chatId, String displayName) async {
    final state = await load();
    state.record(chatId, displayName);
    await _persist(state);
  }

  /// The chats an announcement should go to.
  ///
  /// [excludeChatId] is left out because the caller already delivers the
  /// announcement to that chat itself.
  Future<List<String>> announcementTargets({String? excludeChatId}) async {
    final state = await load();
    final targets = <String>[];
    for (final subscriber in state.subscribers) {
      if (subscriber.chatId == excludeChatId) continue;
      targets.add(subscriber.chatId);
    }
    return targets;
  }

  Future<int> subscriberCount() async => (await load()).count;

  /// Marks an announcement as delivered; returns false when it was already
  /// sent, so a retry cannot announce the same thing twice.
  Future<bool> markAnnounced(String key) async {
    final state = await load();
    if (state.wasAnnounced(key)) return false;
    state.markAnnounced(key);
    await _persist(state);
    return true;
  }
}
