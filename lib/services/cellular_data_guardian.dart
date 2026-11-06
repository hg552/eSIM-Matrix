import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// What the platform can actually enforce on this build/ROM.
class DataGuardCapabilities {
  const DataGuardCapabilities({
    required this.modifyPhoneState,
    required this.root,
    required this.telephonyApis,
    required this.sdkInt,
  });

  const DataGuardCapabilities.unsupported()
      : modifyPhoneState = false,
        root = false,
        telephonyApis = false,
        sdkInt = 0;

  final bool modifyPhoneState;
  final bool root;
  final bool telephonyApis;
  final int sdkInt;

  /// True when at least one path can turn mobile data off.
  bool get canEnforce => telephonyApis || root;

  Map<String, dynamic> toJson() => {
        'modifyPhoneState': modifyPhoneState,
        'root': root,
        'telephonyApis': telephonyApis,
        'sdkInt': sdkInt,
        'canEnforce': canEnforce,
      };
}

/// Per-subscription mobile data / roaming state.
class SubscriptionDataState {
  const SubscriptionDataState({
    required this.subscriptionId,
    required this.slotIndex,
    this.dataEnabled,
    this.roamingEnabled,
  });

  final int subscriptionId;
  final int slotIndex;
  final bool? dataEnabled;
  final bool? roamingEnabled;

  factory SubscriptionDataState.fromMap(Map<dynamic, dynamic> map) =>
      SubscriptionDataState(
        subscriptionId: map['subscriptionId'] is int
            ? map['subscriptionId'] as int
            : -1,
        slotIndex: map['slotIndex'] is int ? map['slotIndex'] as int : -1,
        dataEnabled: map['dataEnabled'] is bool
            ? map['dataEnabled'] as bool
            : null,
        roamingEnabled: map['roamingEnabled'] is bool
            ? map['roamingEnabled'] as bool
            : null,
      );

  Map<String, dynamic> toJson() => {
        'subscriptionId': subscriptionId,
        'slotIndex': slotIndex,
        'dataEnabled': dataEnabled,
        'roamingEnabled': roamingEnabled,
      };
}

/// Result of a lockdown or restore, including the enforcement path used.
class DataGuardResult {
  const DataGuardResult({
    required this.subscriptionId,
    required this.enforced,
    required this.viaApi,
    required this.viaShell,
    this.before,
    this.observed,
    this.error,
  });

  const DataGuardResult.skipped(this.subscriptionId)
      : enforced = false,
        viaApi = false,
        viaShell = false,
        before = null,
        observed = null,
        error = 'skipped';

  final int subscriptionId;

  /// Whether mobile data is actually off (or back on, for a restore).
  final bool enforced;
  final bool viaApi;
  final bool viaShell;
  final SubscriptionDataState? before;
  final bool? observed;
  final String? error;

  factory DataGuardResult.fromMap(Map<dynamic, dynamic> map) {
    final beforeMap = map['before'];
    final dataMap = map['data'];
    return DataGuardResult(
      subscriptionId:
          map['subscriptionId'] is int ? map['subscriptionId'] as int : -1,
      enforced: map['enforced'] == true ||
          (dataMap is Map && dataMap['applied'] == true),
      viaApi: dataMap is Map && dataMap['viaApi'] == true,
      viaShell: dataMap is Map && dataMap['viaShell'] == true,
      before: beforeMap is Map
          ? SubscriptionDataState.fromMap(beforeMap)
          : null,
      observed: dataMap is Map && dataMap['observed'] is bool
          ? dataMap['observed'] as bool
          : null,
      error: map['error']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'subscriptionId': subscriptionId,
        'enforced': enforced,
        'viaApi': viaApi,
        'viaShell': viaShell,
        if (before != null) 'before': before!.toJson(),
        if (observed != null) 'observed': observed,
        if (error != null) 'error': error,
      };
}

/// Dart facade over the native cellular data safeguard.
///
/// Every call degrades to a no-op when the platform channel is absent (desktop,
/// web, or an app variant without the native plugin), so callers can wire this
/// into the switch state machine without branching on platform.
class CellularDataGuardian {
  CellularDataGuardian({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('ee.nekoko.data_guard');

  static final Logger _log = Logger('CellularDataGuardian');

  final MethodChannel _channel;

  bool get _available => Platform.isAndroid;

  Future<DataGuardCapabilities> capabilities() async {
    if (!_available) return const DataGuardCapabilities.unsupported();
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'capabilities',
      );
      if (raw == null) return const DataGuardCapabilities.unsupported();
      return DataGuardCapabilities(
        modifyPhoneState: raw['modifyPhoneState'] == true,
        root: raw['root'] == true,
        telephonyApis: raw['telephonyApis'] == true,
        sdkInt: raw['sdkInt'] is int ? raw['sdkInt'] as int : 0,
      );
    } catch (error) {
      _log.fine('capabilities unavailable: $error');
      return const DataGuardCapabilities.unsupported();
    }
  }

  Future<List<SubscriptionDataState>> status() async {
    if (!_available) return const [];
    try {
      final raw = await _channel.invokeListMethod<dynamic>('getStatus');
      if (raw == null) return const [];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map(SubscriptionDataState.fromMap)
          .toList(growable: false);
    } catch (error) {
      _log.fine('status unavailable: $error');
      return const [];
    }
  }

  /// Turns mobile data and data roaming off for [subscriptionId] and returns the
  /// pre-lockdown state so a later revert can restore it.
  Future<DataGuardResult> lockdown(int subscriptionId) async {
    if (!_available || subscriptionId < 0) {
      return DataGuardResult.skipped(subscriptionId);
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'applyLockdown',
        {'subscriptionId': subscriptionId},
      );
      if (raw == null) return DataGuardResult.skipped(subscriptionId);
      final result = DataGuardResult.fromMap(raw);
      _log.info(
        'lockdown sub=$subscriptionId enforced=${result.enforced} '
        'viaApi=${result.viaApi} viaShell=${result.viaShell}',
      );
      return result;
    } catch (error) {
      _log.warning('lockdown failed for sub=$subscriptionId: $error');
      return DataGuardResult(
        subscriptionId: subscriptionId,
        enforced: false,
        viaApi: false,
        viaShell: false,
        error: error.toString(),
      );
    }
  }

  /// Restores a previously captured data/roaming state.
  Future<DataGuardResult> restore({
    required int subscriptionId,
    bool? dataEnabled,
    bool? roamingEnabled,
  }) async {
    if (!_available || subscriptionId < 0) {
      return DataGuardResult.skipped(subscriptionId);
    }
    if (dataEnabled == null && roamingEnabled == null) {
      return DataGuardResult.skipped(subscriptionId);
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('restore', {
        'subscriptionId': subscriptionId,
        'dataEnabled': ?dataEnabled,
        'roamingEnabled': ?roamingEnabled,
      });
      if (raw == null) return DataGuardResult.skipped(subscriptionId);
      return DataGuardResult.fromMap(raw);
    } catch (error) {
      _log.warning('restore failed for sub=$subscriptionId: $error');
      return DataGuardResult(
        subscriptionId: subscriptionId,
        enforced: false,
        viaApi: false,
        viaShell: false,
        error: error.toString(),
      );
    }
  }

  Future<DataGuardResult> setDataEnabled(int subscriptionId, bool enabled) async {
    if (!_available || subscriptionId < 0) {
      return DataGuardResult.skipped(subscriptionId);
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'setDataEnabled',
        {'subscriptionId': subscriptionId, 'enabled': enabled},
      );
      if (raw == null) return DataGuardResult.skipped(subscriptionId);
      return DataGuardResult(
        subscriptionId: subscriptionId,
        enforced: raw['applied'] == true,
        viaApi: raw['viaApi'] == true,
        viaShell: raw['viaShell'] == true,
        observed: raw['observed'] is bool ? raw['observed'] as bool : null,
      );
    } catch (error) {
      _log.warning('setDataEnabled failed: $error');
      return DataGuardResult(
        subscriptionId: subscriptionId,
        enforced: false,
        viaApi: false,
        viaShell: false,
        error: error.toString(),
      );
    }
  }

  Future<DataGuardResult> setRoamingEnabled(int subscriptionId, bool enabled) async {
    if (!_available || subscriptionId < 0) {
      return DataGuardResult.skipped(subscriptionId);
    }
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'setRoamingEnabled',
        {'subscriptionId': subscriptionId, 'enabled': enabled},
      );
      if (raw == null) return DataGuardResult.skipped(subscriptionId);
      return DataGuardResult(
        subscriptionId: subscriptionId,
        enforced: raw['applied'] == true,
        viaApi: raw['viaApi'] == true,
        viaShell: raw['viaShell'] == true,
      );
    } catch (error) {
      _log.warning('setRoamingEnabled failed: $error');
      return DataGuardResult(
        subscriptionId: subscriptionId,
        enforced: false,
        viaApi: false,
        viaShell: false,
        error: error.toString(),
      );
    }
  }
}
