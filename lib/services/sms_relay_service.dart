import 'package:flutter/services.dart';

class SmsRelayMode {
  static const String webhook = 'webhook';
  static const String telegram = 'telegram';
}

class SmsRelayConfiguration {
  const SmsRelayConfiguration({
    required this.mode,
    required this.enabled,
    required this.endpoint,
    required this.telegramChatId,
    required this.tokenConfigured,
    required this.webhookTokenConfigured,
    required this.telegramTokenConfigured,
    required this.lastDeliveryAtMillis,
    required this.lastDeliveryError,
  });

  factory SmsRelayConfiguration.fromPlatform(Object? value) {
    if (value is! Map) {
      return const SmsRelayConfiguration(
        mode: SmsRelayMode.webhook,
        enabled: false,
        endpoint: null,
        telegramChatId: null,
        tokenConfigured: false,
        webhookTokenConfigured: false,
        telegramTokenConfigured: false,
        lastDeliveryAtMillis: null,
        lastDeliveryError: null,
      );
    }
    final map = Map<Object?, Object?>.from(value);
    final endpoint = map['endpoint'];
    final telegramChatId = map['telegramChatId'];
    final lastDeliveryAtMillis = map['lastDeliveryAtMillis'];
    final lastDeliveryError = map['lastDeliveryError'];
    return SmsRelayConfiguration(
      mode: map['mode'] == SmsRelayMode.telegram
          ? SmsRelayMode.telegram
          : SmsRelayMode.webhook,
      enabled: map['enabled'] == true,
      endpoint: endpoint is String ? endpoint : null,
      telegramChatId: telegramChatId is String ? telegramChatId : null,
      tokenConfigured: map['tokenConfigured'] == true,
      webhookTokenConfigured: map['webhookTokenConfigured'] == true,
      telegramTokenConfigured: map['telegramTokenConfigured'] == true,
      lastDeliveryAtMillis: lastDeliveryAtMillis is int
          ? lastDeliveryAtMillis
          : null,
      lastDeliveryError: lastDeliveryError is String ? lastDeliveryError : null,
    );
  }

  final String mode;
  final bool enabled;
  final String? endpoint;
  final String? telegramChatId;
  final bool tokenConfigured;
  final bool webhookTokenConfigured;
  final bool telegramTokenConfigured;
  final int? lastDeliveryAtMillis;
  final String? lastDeliveryError;
}

class TelegramPrivateChat {
  const TelegramPrivateChat({required this.chatId, required this.displayName});

  factory TelegramPrivateChat.fromPlatform(Object? value) {
    if (value is! Map)
      throw const FormatException('Invalid Telegram chat response');
    final map = Map<Object?, Object?>.from(value);
    final chatId = map['chatId'];
    final displayName = map['displayName'];
    if (chatId is! String || displayName is! String) {
      throw const FormatException('Invalid Telegram chat response');
    }
    return TelegramPrivateChat(chatId: chatId, displayName: displayName);
  }

  final String chatId;
  final String displayName;
}

class RemoteGatewayConfiguration {
  const RemoteGatewayConfiguration({
    required this.enabled,
    required this.apiToken,
    required this.telegramToken,
    required this.telegramChatId,
    required this.canScheduleExactAlarms,
  });

  factory RemoteGatewayConfiguration.fromPlatform(Object? value) {
    if (value is! Map) {
      return const RemoteGatewayConfiguration(
        enabled: false,
        apiToken: null,
        telegramToken: null,
        telegramChatId: null,
        canScheduleExactAlarms: false,
      );
    }
    final map = Map<Object?, Object?>.from(value);
    return RemoteGatewayConfiguration(
      enabled: map['enabled'] == true,
      apiToken: map['apiToken'] is String ? map['apiToken'] as String : null,
      telegramToken: map['telegramToken'] is String
          ? map['telegramToken'] as String
          : null,
      telegramChatId: map['telegramChatId'] is String
          ? map['telegramChatId'] as String
          : null,
      canScheduleExactAlarms: map['canScheduleExactAlarms'] == true,
    );
  }

  final bool enabled;
  final String? apiToken;
  final String? telegramToken;
  final String? telegramChatId;
  final bool canScheduleExactAlarms;
}

class SmsHistoryEntry {
  const SmsHistoryEntry({
    required this.id,
    required this.sender,
    required this.body,
    required this.slotIndex,
    required this.carrierName,
    required this.receivedAtMillis,
    required this.mode,
    required this.delivered,
    required this.errorCode,
  });

  factory SmsHistoryEntry.fromPlatform(Map<Object?, Object?> map) {
    final slot = map['slotIndex'];
    final carrier = map['carrierName'];
    final receivedAt = map['receivedAtMillis'];
    final err = map['errorCode'];
    return SmsHistoryEntry(
      id: '${map['id'] ?? ''}',
      sender: '${map['sender'] ?? ''}',
      body: '${map['body'] ?? ''}',
      slotIndex: slot is int ? slot : null,
      carrierName: carrier is String && carrier.isNotEmpty ? carrier : null,
      receivedAtMillis: receivedAt is int ? receivedAt : 0,
      mode: map['mode'] == SmsRelayMode.webhook
          ? SmsRelayMode.webhook
          : SmsRelayMode.telegram,
      delivered: map['delivered'] != false,
      errorCode: err is String && err.isNotEmpty ? err : null,
    );
  }

  final String id;
  final String sender;
  final String body;
  final int? slotIndex;
  final String? carrierName;
  final int receivedAtMillis;
  final String mode;
  final bool delivered;
  final String? errorCode;
}

class SmsRelayService {
  const SmsRelayService();

  static const MethodChannel _channel = MethodChannel('ee.nekoko.sms_relay');

  Future<bool> isAvailable() async =>
      await _channel.invokeMethod<bool>('isAvailable') ?? false;

  Future<bool> hasPermission() async =>
      await _channel.invokeMethod<bool>('hasPermission') ?? false;

  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;

  Future<SmsRelayConfiguration> loadConfiguration() async =>
      SmsRelayConfiguration.fromPlatform(
        await _channel.invokeMethod<Object?>('loadConfiguration'),
      );

  Future<void> saveConfiguration({
    required String mode,
    required String? endpoint,
    required String? telegramChatId,
    required String token,
    required bool enabled,
  }) async {
    await _channel.invokeMethod<void>('saveConfiguration', {
      'mode': mode,
      'endpoint': endpoint,
      'telegramChatId': telegramChatId,
      'token': token,
      'enabled': enabled,
    });
  }

  Future<TelegramPrivateChat> discoverTelegramChat({
    required String token,
  }) async {
    final value = await _channel.invokeMethod<Object?>('discoverTelegramChat', {
      'token': token,
    });
    return TelegramPrivateChat.fromPlatform(value);
  }

  Future<void> testTelegram() async {
    await _channel.invokeMethod<bool>('testTelegram');
  }

  Future<void> clearToken() => _channel.invokeMethod<void>('clearToken');
  Future<bool> isGatewayAvailable() async =>
      await _channel.invokeMethod<bool>('isGatewayAvailable') ?? false;

  Future<RemoteGatewayConfiguration> loadGatewayConfiguration() async =>
      RemoteGatewayConfiguration.fromPlatform(
        await _channel.invokeMethod<Object?>('loadGatewayConfiguration'),
      );

  Future<void> saveGatewayToken(String token) =>
      _channel.invokeMethod<void>('saveGatewayToken', {'token': token});

  Future<bool> canScheduleExactAlarms() async =>
      await _channel.invokeMethod<bool>('canScheduleExactAlarms') ?? false;

  Future<bool> requestExactAlarmPermission() async =>
      await _channel.invokeMethod<bool>('requestExactAlarmPermission') ?? false;

  Future<void> startGateway() => _channel.invokeMethod<void>('startGateway');

  Future<void> stopGateway() => _channel.invokeMethod<void>('stopGateway');

  Future<void> scheduleGatewayRevert(DateTime deadline) =>
      _channel.invokeMethod<void>('scheduleGatewayRevert', {
        'deadlineEpochMillis': deadline.millisecondsSinceEpoch,
      });

  Future<void> cancelGatewayRevert() =>
      _channel.invokeMethod<void>('cancelGatewayRevert');

  Future<void> clearGatewayToken() =>
      _channel.invokeMethod<void>('clearGatewayToken');

  Future<List<SmsHistoryEntry>> loadHistory() async {
    final raw = await _channel.invokeMethod<Object?>('loadHistory');
    if (raw is! List) return const <SmsHistoryEntry>[];
    return raw
        .whereType<Map>()
        .map((item) => SmsHistoryEntry.fromPlatform(Map<Object?, Object?>.from(item)))
        .where((item) => item.id.isNotEmpty && item.body.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> deleteHistoryItem(String id) =>
      _channel.invokeMethod<void>('deleteHistoryItem', {'id': id});

  Future<void> clearHistory() => _channel.invokeMethod<void>('clearHistory');


  static bool isSecureEndpoint(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return false;
    }
    try {
      return !uri.hasPort || (uri.port > 0 && uri.port <= 65535);
    } on FormatException {
      return false;
    }
  }
}
