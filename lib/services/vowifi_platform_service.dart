import 'package:flutter/services.dart';

/// Wi-Fi Calling mode values, mirroring `ImsMmTelManager.WIFI_MODE_*`.
enum VowifiCallingMode {
  /// `WIFI_MODE_WIFI_ONLY`: use Wi-Fi whenever it is available.
  wifiOnly(0),

  /// `WIFI_MODE_CELLULAR_PREFERRED`: prefer the cellular network.
  cellularPreferred(1),

  /// `WIFI_MODE_WIFI_PREFERRED`: prefer Wi-Fi but fall back to cellular.
  wifiPreferred(2),

  /// The platform reported a mode this build does not know.
  unknown(-1);

  const VowifiCallingMode(this.value);

  final int value;

  static VowifiCallingMode fromValue(int? value) => switch (value) {
    0 => VowifiCallingMode.wifiOnly,
    1 => VowifiCallingMode.cellularPreferred,
    2 => VowifiCallingMode.wifiPreferred,
    _ => VowifiCallingMode.unknown,
  };
}

/// The platform Wi-Fi Calling state for one subscription.
class VowifiStatus {
  const VowifiStatus({
    required this.available,
    required this.subscriptionId,
    required this.enabled,
    required this.mode,
    required this.roamingEnabled,
    required this.roamingMode,
    this.error,
  });

  factory VowifiStatus.fromPlatform(Map<Object?, Object?> map) {
    return VowifiStatus(
      available: map['available'] == true,
      subscriptionId: map['subscriptionId'] is int
          ? map['subscriptionId'] as int
          : -1,
      enabled: map['enabled'] == true,
      mode: VowifiCallingMode.fromValue(
        map['mode'] is int ? map['mode'] as int : null,
      ),
      roamingEnabled: map['roamingEnabled'] == true,
      roamingMode: VowifiCallingMode.fromValue(
        map['roamingMode'] is int ? map['roamingMode'] as int : null,
      ),
      error: map['error'] is String ? map['error'] as String : null,
    );
  }

  final bool available;
  final int subscriptionId;
  final bool enabled;
  final VowifiCallingMode mode;
  final bool roamingEnabled;
  final VowifiCallingMode roamingMode;
  final String? error;

  /// True when the platform will route calls over Wi-Fi at all.
  ///
  /// `wifiOnly` is the mode that actually keeps the radio quiet, so it is worth
  /// distinguishing from "enabled but cellular-preferred".
  bool get prefersWifi =>
      enabled &&
      (mode == VowifiCallingMode.wifiOnly ||
          mode == VowifiCallingMode.wifiPreferred);
}

/// What this device can do, decided on the platform side.
class VowifiCapabilities {
  const VowifiCapabilities({
    required this.root,
    required this.telephony,
    required this.binderReadable,
    required this.sdkInt,
  });

  factory VowifiCapabilities.fromPlatform(Map<Object?, Object?> map) {
    return VowifiCapabilities(
      root: map['root'] == true,
      telephony: map['telephony'] == true,
      binderReadable: map['binderReadable'] == true,
      sdkInt: map['sdkInt'] is int ? map['sdkInt'] as int : 0,
    );
  }

  final bool root;
  final bool telephony;
  final bool binderReadable;
  final int sdkInt;

  /// Without root the `siminfo` columns cannot be written, and the binder
  /// setters are signature-gated, so there is no working path at all.
  bool get usable => root && telephony;
}

class VowifiService {
  const VowifiService();

  static const MethodChannel _channel = MethodChannel('ee.nekoko.vowifi');

  Future<VowifiCapabilities> capabilities() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('capabilities');
    return VowifiCapabilities.fromPlatform(map ?? const {});
  }

  /// Reads the state for [subscriptionId], or the default subscription.
  Future<VowifiStatus?> status({int? subscriptionId}) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('status', {
      'subscriptionId': ?subscriptionId,
    });
    return map == null ? null : VowifiStatus.fromPlatform(map);
  }

  Future<VowifiStatus?> setEnabled({
    required int subscriptionId,
    required bool enabled,
  }) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('setEnabled', {
      'subscriptionId': subscriptionId,
      'enabled': enabled,
    });
    return _statusFromResult(map);
  }

  Future<VowifiStatus?> setMode({
    required int subscriptionId,
    required VowifiCallingMode mode,
  }) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('setMode', {
      'subscriptionId': subscriptionId,
      'mode': mode.value,
    });
    return _statusFromResult(map);
  }

  Future<VowifiStatus?> setRoamingEnabled({
    required int subscriptionId,
    required bool enabled,
  }) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'setRoamingEnabled',
      {'subscriptionId': subscriptionId, 'enabled': enabled},
    );
    return _statusFromResult(map);
  }

  Future<VowifiStatus?> setRoamingMode({
    required int subscriptionId,
    required VowifiCallingMode mode,
  }) async {
    final map = await _channel.invokeMapMethod<Object?, Object?>(
      'setRoamingMode',
      {'subscriptionId': subscriptionId, 'mode': mode.value},
    );
    return _statusFromResult(map);
  }

  /// Restarts the IMS stack so a persisted change takes effect now.
  ///
  /// Writing the table alone leaves the running ImsService on the old value
  /// until it next re-reads, so the caller decides whether to pay the cost of a
  /// brief radio cycle.
  Future<bool> reloadIms() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('reloadIms');
    return map?['success'] == true;
  }

  static VowifiStatus? _statusFromResult(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final status = map['status'];
    return status is Map ? VowifiStatus.fromPlatform(status) : null;
  }
}
