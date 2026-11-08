import 'package:flutter/services.dart';

enum VoiceRegistrationState {
  inService,
  outOfService,
  emergencyOnly,
  radioOff,
  unknown,
}

class NetworkStatusSubscription {
  const NetworkStatusSubscription({
    required this.subscriptionId,
    required this.slotIndex,
    required this.displayName,
    required this.carrierName,
    required this.serviceState,
    required this.roaming,
    required this.signalDbm,
    required this.signalLevel,
    required this.error,
  });

  factory NetworkStatusSubscription.fromPlatform(Map<Object?, Object?> map) {
    final serviceState = map['serviceState'];
    final roaming = map['roaming'];
    final signalDbm = map['signalDbm'];
    final signalLevel = map['signalLevel'];
    final displayName = map['displayName'];
    final carrierName = map['carrierName'];
    final error = map['error'];

    return NetworkStatusSubscription(
      subscriptionId: map['subscriptionId'] is int
          ? map['subscriptionId'] as int
          : -1,
      slotIndex: map['slotIndex'] is int ? map['slotIndex'] as int : -1,
      displayName: displayName is String ? displayName : null,
      carrierName: carrierName is String ? carrierName : null,
      serviceState: serviceState is int ? serviceState : null,
      roaming: roaming is bool ? roaming : null,
      signalDbm: signalDbm is int ? signalDbm : null,
      signalLevel: signalLevel is int ? signalLevel : null,
      error: error is String ? error : null,
    );
  }

  final int subscriptionId;
  final int slotIndex;
  final String? displayName;
  final String? carrierName;
  final int? serviceState;
  final bool? roaming;
  final int? signalDbm;
  final int? signalLevel;
  final String? error;

  VoiceRegistrationState get voiceRegistrationState => switch (serviceState) {
    0 => VoiceRegistrationState.inService,
    1 => VoiceRegistrationState.outOfService,
    2 => VoiceRegistrationState.emergencyOnly,
    3 => VoiceRegistrationState.radioOff,
    _ => VoiceRegistrationState.unknown,
  };
}

class NetworkStatusUpdate {
  const NetworkStatusUpdate({required this.subscriptions, required this.error});

  factory NetworkStatusUpdate.fromPlatform(Object? value) {
    if (value is! Map) {
      return const NetworkStatusUpdate(
        subscriptions: [],
        error: 'telephony_unavailable',
      );
    }

    final map = Map<Object?, Object?>.from(value);
    final rawSubscriptions = map['subscriptions'];
    final subscriptions = rawSubscriptions is List
        ? rawSubscriptions
              .whereType<Map>()
              .map(
                (entry) => NetworkStatusSubscription.fromPlatform(
                  Map<Object?, Object?>.from(entry),
                ),
              )
              .toList(growable: false)
        : const <NetworkStatusSubscription>[];
    final error = map['error'];

    return NetworkStatusUpdate(
      subscriptions: subscriptions,
      error: error is String ? error : null,
    );
  }

  final List<NetworkStatusSubscription> subscriptions;
  final String? error;
}

class NetworkStatusService {
  const NetworkStatusService();

  static const MethodChannel _methodChannel = MethodChannel(
    'ee.nekoko.network_status',
  );
  static const EventChannel _eventChannel = EventChannel(
    'ee.nekoko.network_status/events',
  );
  static Stream<NetworkStatusUpdate>? _sharedUpdates;

  Future<bool> isSupported() async =>
      await _methodChannel.invokeMethod<bool>('isSupported') ?? false;

  Stream<NetworkStatusUpdate> get updates =>
      _sharedUpdates ??= _eventChannel
          .receiveBroadcastStream()
          .map(NetworkStatusUpdate.fromPlatform)
          .asBroadcastStream(
            onCancel: (subscription) => subscription.cancel(),
          );

  Future<void> refresh() async {
    await _methodChannel.invokeMethod<void>('refresh');
  }

  Future<bool> accelerateNetworkSearch() async {
    try {
      final res = await _methodChannel.invokeMapMethod<String, dynamic>(
        'accelerateNetworkSearch',
      );
      return res?['success'] == true;
    } catch (_) {
      return false;
    }
  }
}
