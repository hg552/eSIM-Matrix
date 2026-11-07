import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/zxing_decoder.dart'
    if (dart.library.js_interop) '../utils/zxing_decoder_web.dart';
import 'update_notifier.dart';
import 'update_service.dart';
import 'remote_profile_controller.dart';
import 'sms_relay_service.dart';
import 'network_status_service.dart';
import 'telegram_registry.dart';
import '../settings/app_settings.dart';
import 'cellular_data_guardian.dart';
import 'proxy_linkage_service.dart';
import 'proxy_mapping_resolver.dart';
import 'mock_location_service.dart';
import 'location_mapping_resolver.dart';

/// Distinguishes "argument not supplied" from an explicit null in copyWith.
const Object _absent = Object();

/// Interface names that carry mobile data. A carrier CGNAT bearer is also
/// numbered out of 100.64/10, so the address range alone cannot separate it
/// from the tailnet.
const List<String> _cellularInterfacePrefixes = <String>[
  'rmnet',
  'ccmni',
  'pdp',
  'wwan',
  'clat',
  'v4-',
];

bool _isCellularInterface(String name) {
  final lower = name.toLowerCase();
  return _cellularInterfacePrefixes.any(lower.startsWith);
}

bool _looksLikeTailnetInterface(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('tailscale') || lower.startsWith('ts');
}

bool _isTailscaleAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes.length == 4 && bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127;
  }
  return bytes.length == 16 &&
      bytes[0] == 0xfd &&
      bytes[1] == 0x7a &&
      bytes[2] == 0x11 &&
      bytes[3] == 0x5c &&
      bytes[4] == 0xa1 &&
      bytes[5] == 0xe0;
}

InternetAddress? _firstTailnetAddress(
  ({String name, List<InternetAddress> addresses}) interface,
) {
  for (final type in [InternetAddressType.IPv4, InternetAddressType.IPv6]) {
    for (final address in interface.addresses) {
      if (address.type == type && _isTailscaleAddress(address)) return address;
    }
  }
  return null;
}

/// Picks the address the control API binds to.
///
/// A carrier CGNAT bearer also lives in 100.64/10, and binding there would
/// publish the API on mobile data instead of the tailnet — and never be
/// reachable over Tailscale. The interface name is what separates the two, so
/// mobile bearers are dropped before any range check, and a named tailnet
/// interface is preferred over an unnamed match.
@visibleForTesting
InternetAddress? pickTailnetAddress(
  Iterable<({String name, List<InternetAddress> addresses})> interfaces,
) {
  final usable = interfaces
      .where((interface) => !_isCellularInterface(interface.name))
      .toList(growable: false);
  for (final interface in usable) {
    if (!_looksLikeTailnetInterface(interface.name)) continue;
    final address = _firstTailnetAddress(interface);
    if (address != null) return address;
  }
  for (final interface in usable) {
    final address = _firstTailnetAddress(interface);
    if (address != null) return address;
  }
  return null;
}

/// Whether an automatic resend sweep may run now.
///
/// The first sweep always runs; afterwards one has to wait out the interval, so
/// a dead endpoint cannot turn the 20-second tick into a retry storm.
@visibleForTesting
bool shouldRunAutomaticSmsRetry({
  required DateTime? lastAttempt,
  required DateTime now,
  required Duration interval,
}) => lastAttempt == null || now.difference(lastAttempt) >= interval;

class RemoteGatewayException implements Exception {
  const RemoteGatewayException(this.code);

  final String code;

  @override
  String toString() => code;
}

class RemoteGatewayService {
  RemoteGatewayService({
    SmsRelayService smsRelay = const SmsRelayService(),
    RemoteProfileControl? profiles,
    @visibleForTesting InternetAddress? bindAddress,
  }) : _smsRelay = smsRelay,
       _profiles = profiles ?? LpaRemoteProfileControl(),
       _bindAddressOverride = bindAddress;

  static final RemoteGatewayService instance = RemoteGatewayService();
  static const int port = 8787;
  static const Duration sessionDuration = Duration(minutes: 5);
  static const Duration switchCooldown = Duration(seconds: 6);
  static const String speedtestActivationCode = 'LPA:1\$rsp.truphone.com\$QRF-SPEEDTEST';
  static const String _sessionKey = 'remote_gateway.session.v1';
  static const String _defaultKey = 'remote_gateway.default.v1';
  static const String _lastSwitchKey = 'remote_gateway.last_switch.v1';
  static const String _telegramOffsetKey = 'remote_gateway.telegram_offset.v1';
  static const String _keepAliveKey = 'remote_gateway.keepalive.v1';
  static final Logger _log = Logger('RemoteGatewayService');

  final SmsRelayService _smsRelay;
  final RemoteProfileControl _profiles;

  /// Tests bind the REST listener to loopback; production always derives the
  /// address from the Tailscale interface so the API never lands on mobile data.
  final InternetAddress? _bindAddressOverride;
  HttpClient _telegramHttpClient = _createTelegramHttpClient();
  int _telegramPollGeneration = 0;

  static HttpClient _createTelegramHttpClient() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 5);
  Future<void> _operationTail = Future<void>.value();
  HttpServer? _server;
  String? _serverAddress;
  Timer? _serverRefreshTimer;
  Timer? _revertTimer;
  Timer? _basebandPollTimer;
  StreamSubscription<NetworkStatusUpdate>? _networkSubscription;
  RemoteGatewayConfiguration? _configuration;
  _RemoteSession? _session;
  _PendingDeletion? _pendingDeletion;
  NetworkStatusUpdate? _networkStatus;
  bool _running = false;
  bool _readyNotificationSent = false;
  bool _wasInServiceBeforeSwitch = false;
  bool _sawDisconnectAfterSwitch = false;
  int _switchCompletedAtMillis = 0;
  String? _lastTelegramError;
  bool? _wasCharging;
  int _lastHealthAlertMillis = 0;
  int _maintenanceTickCount = 0;
  final ProxyLinkageService _proxyLinkage = ProxyLinkageService();
  final ProxyMappingResolver _proxyResolver = const ProxyMappingResolver();
  final CellularDataGuardian _dataGuard = CellularDataGuardian();
  ProxySnapshot? _proxySnapshot;
  String? _lastLinkedProxyNode;
  DataGuardResult? _lastGuardResult;
  final MockLocationService _mockLocationService = const MockLocationService();
  final LocationMappingResolver _locationResolver = const LocationMappingResolver();
  LocationCoordinate? _lastMockLocation;
  LocationCoordinate? get lastMockLocation => _lastMockLocation;

  /// One maintenance run at a time; the 20-second timer must not overlap them.
  bool _maintenanceInFlight = false;

  /// One SMS retry batch at a time, so a code is never delivered twice.
  bool _smsRetryInFlight = false;
  DateTime? _lastAutomaticSmsRetry;

  /// How long to wait between automatic resend sweeps. An unreachable endpoint
  /// makes every sweep take minutes, so they must not be packed together.
  static const Duration _automaticSmsRetryInterval = Duration(minutes: 5);

  bool get isRunning => _running;
  String? get apiUrl => _serverAddress == null
      ? null
      : 'http://$_serverAddress:$port/';

  static String generateApiToken() {
    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> start() async {
    var config = await _smsRelay.loadGatewayConfiguration();
    if (config.apiToken == null || config.apiToken!.length != 43) {
      final token = generateApiToken();
      try {
        await _smsRelay.saveGatewayToken(token);
        config = await _smsRelay.loadGatewayConfiguration();
      } catch (_) {}
    }
    if (!config.enabled) {
      try {
        await _smsRelay.startGateway();
        config = await _smsRelay.loadGatewayConfiguration();
      } catch (_) {}
    }
    final previousConfig = _configuration;
    _configuration = config;
    await _seedOwnerSubscriber(config.telegramChatId);
    if (_running) {
      final telegramChanged =
          previousConfig?.telegramToken != config.telegramToken ||
          previousConfig?.telegramChatId != config.telegramChatId;
      if (telegramChanged) {
        _telegramPollGeneration++;
        if (config.telegramToken != null && config.telegramChatId != null) {
          unawaited(_pollTelegram(_telegramPollGeneration));
        }
      }
      unawaited(_profiles.refreshNetworkStatus().catchError((Object _) {}));
      return;
    }
    _running = true;
    _networkSubscription = _profiles.networkUpdates.listen(
      _onNetworkStatus,
      onError: (Object _) {},
    );
    unawaited(_profiles.refreshNetworkStatus().catchError((Object _) {}));
    await _restoreFallback();
    await _refreshHttpServer();
    _serverRefreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_refreshHttpServer());
      unawaited(_runPeriodicMaintenance());
    });
    _telegramPollGeneration++;
    if (config.telegramToken != null && config.telegramChatId != null) {
      unawaited(_pollTelegram(_telegramPollGeneration));
    }
  }

  /// The owner chat receives announcements even when it has not written to
  /// the bot since the registry was introduced.
  Future<void> _seedOwnerSubscriber(String? chatId) async {
    if (chatId == null || chatId.isEmpty) return;
    try {
      await TelegramRegistry.instance.record(chatId, 'Owner');
    } catch (_) {}
  }

  Future<void> resumeIfEnabled() async {
    final sms = await _smsRelay.loadConfiguration();
    final config = await _smsRelay.loadGatewayConfiguration();
    final session = await _loadSession();
    final hasTelegram = (config.telegramToken != null || sms.telegramTokenConfigured) &&
        (config.telegramChatId != null || sms.telegramChatId != null);
    if (!config.enabled && !sms.enabled && session == null && !hasTelegram) return;
    try {
      await start();
    } catch (error) {
      _log.warning('Remote gateway could not resume (${_errorCode(error)})');
    }
  }

  Future<void> stop() async {
    if (!_running && _session == null) {
      await _smsRelay.stopGateway();
      return;
    }
    if (_session != null) {
      try {
        await _serialize(() => _revert(auto: false));
      } catch (error) {
        _log.warning('Gateway stop could not revert active session (${_errorCode(error)})');
      }
    }
    _running = false;
    _telegramPollGeneration++;
    _revertTimer?.cancel();
    _revertTimer = null;
    _basebandPollTimer?.cancel();
    _basebandPollTimer = null;
    _serverRefreshTimer?.cancel();
    _serverRefreshTimer = null;
    await _networkSubscription?.cancel();
    _networkSubscription = null;
    await _server?.close(force: true);
    _server = null;
    _serverAddress = null;
    _telegramHttpClient.close(force: true);
    _telegramHttpClient = _createTelegramHttpClient();
    await _smsRelay.stopGateway();
  }

  Future<List<Map<String, Object?>>> listProfiles() async {
    final profiles = await _profiles.listProfiles();
    return profiles.map(_profileJson).toList(growable: false);
  }

  Future<Map<String, Object?>> status() async {
    if (_running) {
      try {
        await _profiles.refreshNetworkStatus();
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    final session = _session ?? await _loadSession();
    final savedDefault = await _loadDefault();
    final subscriptions = _networkStatus?.subscriptions ?? const [];
    final active = _selectMatchingSubscription(subscriptions);
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    final remaining = session == null || session.deadlineEpochMillis == 0
        ? null
        : max(0, (session.deadlineEpochMillis - nowMillis) ~/ 1000);
    RemoteCardResourceInfo cardInfo = const RemoteCardResourceInfo();
    DeviceHealthStatus health = const DeviceHealthStatus();
    try {
      cardInfo = await _profiles.getCardResourceInfo();
    } catch (_) {}
    try {
      health = await _smsRelay.getDeviceHealth();
    } catch (_) {}
    final keepAliveRules = await listKeepAliveRules();
    int registeredChats = 0;
    try {
      registeredChats = await TelegramRegistry.instance.subscriberCount();
    } catch (_) {}
    return {
      'gateway': _running ? 'running' : 'stopped',
      'apiUrl': apiUrl,
      'selectedReader': _profiles.selectedReaderId,
      'defaultProfile': savedDefault?.alias,
      'registeredChats': registeredChats,
      'card': cardInfo.toJson(),
      'device': health.toJson(),
      'keepAliveCount': keepAliveRules.length,
      'session': session == null
          ? null
          : {
              'state': session.state,
              'target': session.targetAlias,
              'returnTo': session.defaultAlias,
              'deadlineEpochMillis': session.deadlineEpochMillis,
              'remainingSeconds': remaining,
            },
      'network': active == null
          ? null
          : {
              'slot': active.slotIndex + 1,
              'carrier': active.carrierName ?? active.displayName,
              'registration': active.voiceRegistrationState.name,
              'roaming': active.roaming,
              'signalDbm': active.signalDbm,
              'error': active.error,
            },
      'proxy': {
        'enabled': AppSettings().proxyLinkageEnabled,
        'controllerUrl': AppSettings().proxyControllerUrl,
        'targetGroup': AppSettings().proxyTargetGroup,
        'currentNode': _lastLinkedProxyNode ?? _proxySnapshot?.node,
        'lastLinkedNode': _lastLinkedProxyNode,
        'snapshotNode': _proxySnapshot?.node,
      },
      'dataGuard': {
        'enabled': AppSettings().dataGuardEnabled,
        'restoreOnRevert': AppSettings().dataGuardRestoreOnRevert,
        'enforced': session?.guardEnforced ?? false,
        'subscriptionId': session?.guardSubscriptionId,
        'restoredDataEnabled': session?.guardDataEnabledBefore,
        'restoredRoamingEnabled': session?.guardRoamingEnabledBefore,
        'lastResult': _lastGuardResult?.toJson(),
      },
      'lastTelegramError': _lastTelegramError,
      'lastSwitchEpochMillis': prefs.getInt(_lastSwitchKey),
    };
  }

  Future<Map<String, Object?>> setDefaultProfile() => _serialize(() async {
    final profiles = await _profiles.listProfiles();
    final active = profiles.where((profile) => profile.enabled).toList();
    if (active.length != 1) {
      throw const RemoteGatewayException('exactly_one_profile_must_be_enabled');
    }
    final profile = active.single;
    final readerId = _profiles.selectedReaderId;
    if (readerId == null) throw const RemoteGatewayException('reader_not_selected');
    await _saveDefault(_RemoteDefault(
      iccid: profile.iccid,
      alias: profile.alias,
      readerId: readerId,
    ));
    if (_session != null) {
      if (_session!.targetIccid == profile.iccid &&
          _session!.state != 'waiting_for_service') {
        _basebandPollTimer?.cancel();
        _basebandPollTimer = null;
        _revertTimer?.cancel();
        _revertTimer = null;
        _session = null;
        _readyNotificationSent = false;
        await _saveSession(null);
      } else {
        _session = _session!.copyWith(
          defaultIccid: profile.iccid,
          defaultAlias: profile.alias,
        );
        await _saveSession(_session);
      }
    }
    return {'defaultProfile': profile.alias, 'iccidSuffix': _suffix(profile.iccid)};
  });

  Future<Map<String, Object?>> switchProfile(
    String selector, {
    Duration? duration,
  }) => _serialize(() => _switchProfile(selector, duration: duration));

  Future<Map<String, Object?>> revertProfile({bool auto = false}) =>
      _serialize(() => _revert(auto: auto));

  Future<Map<String, Object?>> renameProfile(
    String selector,
    String newAlias,
  ) => _serialize(() async {
    if (!_running) throw const RemoteGatewayException('gateway_stopped');
    final cleanAlias = newAlias.trim();
    if (cleanAlias.isEmpty) throw const RemoteGatewayException('alias_required');
    final profiles = await _profiles.listProfiles();
    final target = _resolveProfileSelector(profiles, selector);
    await _profiles.renameProfile(target.iccid, cleanAlias);
    final savedDefault = await _loadDefault();
    if (savedDefault != null && savedDefault.iccid == target.iccid) {
      await _saveDefault(
        _RemoteDefault(
          iccid: savedDefault.iccid,
          alias: cleanAlias,
          readerId: savedDefault.readerId,
        ),
      );
    }
    if (_session != null) {
      var updated = _session!;
      if (updated.targetIccid == target.iccid) {
        updated = updated.copyWith(targetAlias: cleanAlias);
      }
      if (updated.defaultIccid == target.iccid) {
        updated = updated.copyWith(defaultAlias: cleanAlias);
      }
      _session = updated;
      await _saveSession(_session);
    }
    final rules = await _loadKeepAliveRules();
    final ruleIdx = rules.indexWhere((r) => r.iccid == target.iccid);
    if (ruleIdx >= 0) {
      rules[ruleIdx] = rules[ruleIdx].copyWith(alias: cleanAlias);
      await _saveKeepAliveRules(rules);
    }
    return {
      'state': 'renamed',
      'iccid': target.iccid,
      'oldAlias': target.alias,
      'newAlias': cleanAlias,
    };
  });

  Future<List<Map<String, Object?>>> listReaders() async {
    final readers = await _profiles.listReaders();
    return readers.map((r) => r.toJson()).toList(growable: false);
  }

  Future<Map<String, Object?>> selectReader(String selector) =>
      _serialize(() async {
        if (!_running) throw const RemoteGatewayException('gateway_stopped');
        try {
          final selected = await _profiles.selectReader(selector);
          return {
            'state': 'reader_selected',
            'id': selected.id,
            'name': selected.name,
          };
        } on StateError catch (e) {
          throw RemoteGatewayException(e.message);
        }
      });

  Future<List<Map<String, Object?>>> listKeepAliveRules() async {
    final rules = await _loadKeepAliveRules();
    return rules.map((r) => r.toJson()).toList(growable: false);
  }

  Future<Map<String, Object?>> setKeepAliveRule(
    String selector, {
    required int intervalDays,
  }) => _serialize(() async {
    if (!_running) throw const RemoteGatewayException('gateway_stopped');
    final profiles = await _profiles.listProfiles();
    final target = _resolveProfileSelector(profiles, selector);
    final rules = await _loadKeepAliveRules();
    rules.removeWhere((r) => r.iccid == target.iccid);
    if (intervalDays <= 0) {
      await _saveKeepAliveRules(rules);
      return {
        'state': 'keepalive_removed',
        'target': target.alias,
        'iccid': target.iccid,
      };
    }
    final clampedDays = intervalDays.clamp(1, 365);
    final rule = _KeepAliveRule(
      iccid: target.iccid,
      alias: target.alias,
      intervalDays: clampedDays,
      dwellSeconds: 180,
      lastRunEpochMillis: DateTime.now().millisecondsSinceEpoch,
    );
    rules.add(rule);
    await _saveKeepAliveRules(rules);
    return {
      'state': 'keepalive_set',
      'target': target.alias,
      'iccid': target.iccid,
      'intervalDays': clampedDays,
      'nextRunEpochMillis': rule.nextRunEpochMillis,
    };
  });

  Future<Map<String, Object?>> runKeepAliveNow(String selector) =>
      _serialize(() async {
        if (!_running) throw const RemoteGatewayException('gateway_stopped');
        final profiles = await _profiles.listProfiles();
        final target = _resolveProfileSelector(profiles, selector);
        final rules = await _loadKeepAliveRules();
        final idx = rules.indexWhere((r) => r.iccid == target.iccid);
        final dwell = idx >= 0 ? rules[idx].dwellSeconds : 180;
        final res = await _switchProfile(
          target.iccid,
          duration: Duration(seconds: dwell),
        );
        // Only stamp the run once the switch actually landed: a cooldown
        // rejection or a card error must leave the rule due, otherwise a failed
        // 保号 pass silently postpones the next attempt by a whole interval.
        if (idx >= 0) {
          rules[idx] = rules[idx].copyWith(
            alias: target.alias,
            lastRunEpochMillis: DateTime.now().millisecondsSinceEpoch,
          );
          await _saveKeepAliveRules(rules);
        }
        return {
          ...res,
          'keepAlive': true,
          'dwellSeconds': dwell,
        };
      });

  Future<Map<String, Object?>> downloadProfile(
    String activationCode, {
    String? confirmationCode,
    void Function(String message)? onStatus,
  }) => _serialize(() async {
    if (!_running) throw const RemoteGatewayException('gateway_stopped');
    final code = activationCode.trim();
    if (code.isEmpty) throw const RemoteGatewayException('activation_code_required');
    if (_session != null && _session!.state == 'waiting_for_service') {
      throw const RemoteGatewayException('waiting_for_baseband');
    }
    final iccid = await _profiles.downloadProfile(
      code,
      confirmationCode: confirmationCode,
      onStatus: onStatus,
    );
    return {
      'state': 'downloaded',
      'iccid': iccid,
    };
  });

  Future<Map<String, Object?>> requestDeleteProfile(String selector) =>
      _serialize(() async {
    if (!_running) throw const RemoteGatewayException('gateway_stopped');
    final normalizedSelector = selector.trim().toLowerCase();
    if (normalizedSelector.isEmpty) throw const RemoteGatewayException('profile_required');

    final profiles = await _profiles.listProfiles();
    if (profiles.isEmpty) throw const RemoteGatewayException('no_profiles');

    final candidates = profiles.where((profile) {
      return profile.iccid.toLowerCase() == normalizedSelector ||
          profile.alias.trim().toLowerCase() == normalizedSelector;
    }).toList();
    if (candidates.isEmpty) throw const RemoteGatewayException('profile_not_found');
    if (candidates.length > 1) throw const RemoteGatewayException('profile_alias_ambiguous_use_iccid');
    final target = candidates.single;

    if (target.enabled) {
      throw const RemoteGatewayException('cannot_delete_active_profile');
    }

    final savedDefault = await _loadDefault();
    final effectiveDefaultIccid = savedDefault?.iccid ?? _session?.defaultIccid;
    if (effectiveDefaultIccid == target.iccid) {
      throw const RemoteGatewayException('cannot_delete_default_profile');
    }

    final token = (1000 + Random().nextInt(9000)).toString();
    _pendingDeletion = _PendingDeletion(
      token: token,
      iccid: target.iccid,
      alias: target.alias,
      expiresAt: DateTime.now().add(const Duration(minutes: 2)),
    );

    return {
      'state': 'confirm_required',
      'token': token,
      'target': target.alias,
      'iccid': target.iccid,
    };
  });

  Future<Map<String, Object?>> confirmDeleteProfile(String token) =>
      _serialize(() async {
    if (!_running) throw const RemoteGatewayException('gateway_stopped');
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) throw const RemoteGatewayException('token_required');

    final pending = _pendingDeletion;
    if (pending == null || pending.isExpired) {
      _pendingDeletion = null;
      throw const RemoteGatewayException('delete_token_expired');
    }

    if (pending.token != cleanToken) {
      throw const RemoteGatewayException('invalid_delete_token');
    }

    _pendingDeletion = null;

    final profiles = await _profiles.listProfiles();
    final target = profiles.where((p) => p.iccid == pending.iccid).firstOrNull;
    if (target == null) throw const RemoteGatewayException('profile_not_found');
    if (target.enabled) throw const RemoteGatewayException('cannot_delete_active_profile');
    final savedDefault = await _loadDefault();
    final effectiveDefaultIccid = savedDefault?.iccid ?? _session?.defaultIccid;
    if (effectiveDefaultIccid == target.iccid) {
      throw const RemoteGatewayException('cannot_delete_default_profile');
    }
    await _profiles.deleteProfile(pending.iccid);
    return {
      'state': 'deleted',
      'target': pending.alias,
      'iccid': pending.iccid,
    };
  });
  RemoteProfileEntry _resolveProfileSelector(
    List<RemoteProfileEntry> profiles,
    String selector,
  ) {
    final normalizedSelector = selector.trim().toLowerCase();
    if (normalizedSelector.isEmpty) {
      throw const RemoteGatewayException('profile_required');
    }
    if (profiles.isEmpty) throw const RemoteGatewayException('no_profiles');
    final slotIdx = int.tryParse(normalizedSelector);
    if (slotIdx != null && slotIdx >= 1 && slotIdx <= profiles.length) {
      return profiles[slotIdx - 1];
    }
    final candidates = profiles.where((profile) {
      return profile.iccid.toLowerCase() == normalizedSelector ||
          profile.alias.trim().toLowerCase() == normalizedSelector;
    }).toList();
    if (candidates.isEmpty) {
      throw const RemoteGatewayException('profile_not_found');
    }
    if (candidates.length > 1) {
      throw const RemoteGatewayException('profile_alias_ambiguous_use_iccid');
    }
    return candidates.single;
  }

  Future<Map<String, Object?>> _switchProfile(
    String selector, {
    Duration? duration,
  }) async {
    if (!_running) throw const RemoteGatewayException('gateway_stopped');
    final profiles = await _profiles.listProfiles();
    if (profiles.isEmpty) throw const RemoteGatewayException('no_profiles');
    final readerId = _profiles.selectedReaderId;
    if (readerId == null) throw const RemoteGatewayException('reader_not_selected');

    final active = profiles.where((profile) => profile.enabled).toList();
    if (active.length != 1) {
      throw const RemoteGatewayException('exactly_one_profile_must_be_enabled');
    }

    var savedDefault = await _loadDefault();
    if (savedDefault == null) {
      final current = active.single;
      savedDefault = _RemoteDefault(
        iccid: current.iccid,
        alias: current.alias,
        readerId: readerId,
      );
      await _saveDefault(savedDefault);
    }
    if (savedDefault.readerId != readerId) {
      throw const RemoteGatewayException('default_profile_reader_mismatch');
    }

    final target = _resolveProfileSelector(profiles, selector);
    if (target.enabled) {
      return {'state': 'already_active', 'target': target.alias};
    }
    if (_session != null && _session!.state == 'switching') {
      throw const RemoteGatewayException('switch_in_progress');
    }
    await _checkCooldown();
    final currentSub = _selectMatchingSubscription(
      _networkStatus?.subscriptions ?? const <NetworkStatusSubscription>[],
    );
    final wasInService =
        currentSub?.voiceRegistrationState == VoiceRegistrationState.inService;
    final previousSession = _session;
    final previousReady = _readyNotificationSent;
    final deadline = duration == null ? null : DateTime.now().add(duration);
    final deadlineMillis = deadline?.millisecondsSinceEpoch ?? 0;
    _session = _RemoteSession(
      state: 'switching',
      targetIccid: target.iccid,
      targetAlias: target.alias,
      defaultIccid: savedDefault.iccid,
      defaultAlias: savedDefault.alias,
      readerId: readerId,
      deadlineEpochMillis: deadlineMillis,
    );
    _readyNotificationSent = false;
    _wasInServiceBeforeSwitch = wasInService;
    _sawDisconnectAfterSwitch = false;
    await _saveSession(_session);
    _lastLinkedProxyNode = null;
    if (AppSettings().proxyLinkageEnabled) {
      unawaited(_triggerProxySwitch(target).catchError((Object e) {
        _log.warning('Proxy linkage switch failed: $e');
      }));
    }

    try {
      // Best effort before the card even resets: if the slot already has a
      // subscription, its data is off before the new profile can attach.
      await _applyDataGuard(preferredSlot: _profiles.networkSlotIndex);
      await _profiles.enableProfile(target.iccid);
    } catch (error) {
      // The guard may already have switched data off for the target slot; a
      // failed switch must not leave the phone with data disabled and no
      // session to restore it later.
      final failed = _session;
      if (failed != null && failed.guardEnforced) {
        await _restoreDataGuard(
          subscriptionId: failed.guardSubscriptionId,
          dataEnabled: failed.guardDataEnabledBefore,
          roamingEnabled: failed.guardRoamingEnabledBefore,
        ).catchError((Object _) {});
      }
      _lastGuardResult = null;
      _session = previousSession;
      _readyNotificationSent = previousReady;
      await _saveSession(previousSession);
      rethrow;
    }
    // Authoritative pass: the SIM reset can restore the ROM's default data
    // state, so the guard is re-asserted once the new subscription exists.
    await _applyDataGuard(preferredSlot: _profiles.networkSlotIndex);
    _switchCompletedAtMillis = DateTime.now().millisecondsSinceEpoch;
    await _recordSwitchTime();
    _session = _session!.copyWith(state: 'waiting_for_service');
    await _saveSession(_session);
    if (deadline != null) {
      _scheduleLocalFallback(deadline);
      unawaited(
        _smsRelay.scheduleGatewayRevert(deadline).catchError((Object _) {}),
      );
    } else {
      _revertTimer?.cancel();
      _revertTimer = null;
      unawaited(_smsRelay.cancelGatewayRevert().catchError((Object _) {}));
    }
    _startBasebandPolling();
    return {
      'state': 'waiting_for_service',
      'target': target.alias,
      if (deadlineMillis > 0) 'deadlineEpochMillis': deadlineMillis,
      if (duration != null) 'remainingSeconds': duration.inSeconds,
    };
  }

  Future<Map<String, Object?>> _revert({required bool auto}) async {
    final session = _session ?? await _loadSession();
    final savedDefault = await _loadDefault();
    final targetDefaultIccid = savedDefault?.iccid ?? session?.defaultIccid;
    final targetDefaultAlias =
        savedDefault?.alias ?? session?.defaultAlias ?? '默认主卡';
    if (targetDefaultIccid == null) {
      return {'state': 'reverted', 'profile': targetDefaultAlias};
    }
    if (session == null) {
      final profiles = await _profiles.listProfiles();
      final alreadyEnabled = profiles.any(
        (p) => p.iccid == targetDefaultIccid && p.enabled,
      );
      if (!alreadyEnabled) {
        await _profiles.enableProfile(targetDefaultIccid);
        await _recordSwitchTime();
        unawaited(
          Future<void>.delayed(const Duration(seconds: 12), () async {
            await _profiles.purgeSwitchNotifications();
          }).catchError((Object _) {}),
        );
        if (AppSettings().mockLocationAutoRestore) {
          await stopMockLocation().catchError((Object _) => false);
        }
      }
      return {'state': 'reverted', 'profile': targetDefaultAlias};
    }
    final previousSession = session;
    _session = session.copyWith(state: 'reverting');
    await _saveSession(_session);
    try {
      await _profiles.enableProfile(targetDefaultIccid);
    } catch (error) {
      _session = previousSession;
      await _saveSession(previousSession);
      rethrow;
    }
    await _recordSwitchTime();
    await _restoreDataGuard(
      subscriptionId: session.guardSubscriptionId,
      dataEnabled: session.guardDataEnabledBefore,
      roamingEnabled: session.guardRoamingEnabledBefore,
    );
    _lastGuardResult = null;
    _basebandPollTimer?.cancel();
    _basebandPollTimer = null;
    _revertTimer?.cancel();
    _revertTimer = null;
    unawaited(_smsRelay.cancelGatewayRevert().catchError((Object _) {}));
    _session = null;
    _readyNotificationSent = false;
    await _saveSession(null);
    final restoredProxy = await _triggerProxyRestore(
      targetDefaultIccid: targetDefaultIccid,
      targetDefaultAlias: targetDefaultAlias,
    ).catchError((Object _) => null);
    if (AppSettings().mockLocationAutoRestore) {
      await stopMockLocation().catchError((Object _) => false);
    }
    if (auto) {
      final proxyText = restoredProxy != null ? '\n🌐 代理节点已自动恢复为：【$restoredProxy】' : '';
      final guardText = AppSettings().dataGuardRestoreOnRevert &&
              (session.guardDataEnabledBefore != null ||
                  session.guardRoamingEnabledBefore != null)
          ? '\n🛡️ 流量卫士：已恢复切卡前的移动数据开关状态'
          : '';
      final locText = AppSettings().mockLocationAutoRestore
          ? '\n📍 虚拟定位：已恢复真实系统 GPS 定位'
          : '';
      unawaited(
        _sendTelegramReply(
          _TelegramReply(
            '🏠 临时接码/保号驻网时间已到，已自动为您切回默认主卡：【$targetDefaultAlias】。$guardText$proxyText$locText',
            keyboard: const [
              [
                _TelegramButton('📡 查看基带状态', 'cmd:status'),
                _TelegramButton('📋 卡内列表', 'cmd:list'),
              ],
            ],
          ),
        ).catchError((Object _) {}),
      );
    }
    unawaited(
      Future<void>.delayed(const Duration(seconds: 12), () async {
        await _profiles.purgeSwitchNotifications();
      }).catchError((Object _) {}),
    );
    final result = {'state': 'reverted', 'profile': targetDefaultAlias};
    return result;
  }
  Future<void> _triggerProxySwitch(RemoteProfileEntry target) async {
    final settings = AppSettings();
    if (settings.proxyLinkageEnabled) {
      final group = settings.proxyTargetGroup;
      _proxyLinkage.updateConfig(
        controllerUrl: settings.proxyControllerUrl,
        secret: settings.proxySecret,
      );
      try {
        // Keep the pre-switch node so _revert can put it back.
        _proxySnapshot ??= await _proxyLinkage.snapshot(group);
        await applyProxyForProfile(iccid: target.iccid, alias: target.alias);
      } catch (e) {
        _log.warning('Proxy linkage switch failed: $e');
      }
    }
    if (settings.mockLocationLinkageEnabled) {
      try {
        await applyLocationForProfile(iccid: target.iccid, alias: target.alias);
      } catch (e) {
        _log.warning('Mock location switch failed: $e');
      }
    }
  }

  /// Selects the proxy node for one eSIM profile.
  ///
  /// An explicit per-profile binding (set from the profile list) wins over the
  /// country resolver. Also called by the local LPA page after a profile is
  /// enabled directly in the UI, so remote and local switches honour the same
  /// binding.
  Future<ProxySwitchResult?> applyProxyForProfile({
    required String iccid,
    String? alias,
  }) async {
    final settings = AppSettings();
    if (!settings.proxyLinkageEnabled) return null;
    final group = settings.proxyTargetGroup;
    _proxyLinkage.updateConfig(
      controllerUrl: settings.proxyControllerUrl,
      secret: settings.proxySecret,
    );
    try {
      final groupInfo = await _proxyLinkage.getGroup(group);
      if (groupInfo == null) {
        _log.warning('Proxy linkage: Group "$group" not found');
        return null;
      }
      final bound = settings.proxyCustomRules[iccid]?.trim();
      final ProxyMatchResult match;
      if (bound != null && bound.isNotEmpty && groupInfo.all.contains(bound)) {
        match = ProxyMatchResult(
          matched: true,
          nodeName: bound,
          confidence: 'custom_rule',
          reason: 'Per-profile binding from the profile list',
        );
      } else {
        match = _proxyResolver.resolveNode(
          candidates: groupInfo.all,
          iccid: iccid,
          alias: alias,
          customRules: settings.proxyCustomRules,
        );
      }
      if (!match.matched || match.nodeName == null) {
        _log.info('Proxy linkage: no node for $iccid: ${match.reason}');
        return null;
      }
      final result = await _proxyLinkage.selectNode(group, match.nodeName!);
      if (result.success) {
        _lastLinkedProxyNode = match.nodeName;
        _log.info(
          'Proxy linkage: switched to [${match.nodeName}] for $iccid '
          '(${match.reason})',
        );
      }
      return result;
    } catch (e) {
      _log.warning('Proxy linkage switch exception: $e');
      return null;
    }
  }

  /// Injects rootless mock location for one eSIM profile.
  Future<bool> applyLocationForProfile({
    required String iccid,
    String? alias,
    String? mcc,
  }) async {
    final settings = AppSettings();
    if (!settings.mockLocationLinkageEnabled) return false;
    try {
      final match = _locationResolver.resolveLocation(
        iccid: iccid,
        alias: alias,
        mcc: mcc,
        customRules: settings.mockLocationCustomRules,
      );
      if (!match.matched || match.coordinate == null) {
        _log.info('Mock location: no coordinate matched for $iccid');
        return false;
      }
      final coord = match.coordinate!;
      final success = await _mockLocationService.startMockLocation(
        latitude: coord.latitude,
        longitude: coord.longitude,
        mode: settings.mockLocationMode,
      );
      if (success) {
        _lastMockLocation = coord;
        _log.info(
          'Mock location: injected [${coord.cityName}] (${coord.latitude}, ${coord.longitude}) '
          'for $iccid (mode=${settings.mockLocationMode}, confidence=${match.confidence})',
        );
      }
      return success;
    } catch (e) {
      _log.warning('Mock location linkage failed: $e');
      return false;
    }
  }

  Future<bool> stopMockLocation() async {
    try {
      final res = await _mockLocationService.stopMockLocation();
      _lastMockLocation = null;
      _log.info('Mock location stopped');
      return res;
    } catch (e) {
      _log.warning('Stop mock location failed: $e');
      return false;
    }
  }

  Future<String?> _triggerProxyRestore({
    String? targetDefaultIccid,
    String? targetDefaultAlias,
  }) async {
    final settings = AppSettings();
    if (!settings.proxyLinkageEnabled || !settings.proxyAutoRestore) return null;
    final group = settings.proxyTargetGroup;
    _proxyLinkage.updateConfig(
      controllerUrl: settings.proxyControllerUrl,
      secret: settings.proxySecret,
    );
    String? restoredName;
    try {
      if (_proxySnapshot != null) {
        final res = await _proxyLinkage.restore(_proxySnapshot!);
        if (res.success) {
          restoredName = _proxySnapshot!.node;
          _log.info('Proxy Linkage: Restored original node to [$restoredName]');
        }
        _proxySnapshot = null;
      } else if (targetDefaultAlias != null) {
        final groupInfo = await _proxyLinkage.getGroup(group);
        if (groupInfo != null) {
          final match = _proxyResolver.resolveNode(
            candidates: groupInfo.all,
            iccid: targetDefaultIccid,
            alias: targetDefaultAlias,
            customRules: settings.proxyCustomRules,
          );
          if (match.matched && match.nodeName != null) {
            final res = await _proxyLinkage.selectNode(group, match.nodeName!);
            if (res.success) restoredName = match.nodeName;
          }
        }
      }
    } catch (e) {
      _log.warning('Proxy linkage restore exception: $e');
    }
    _lastLinkedProxyNode = null;
    return restoredName;
  }

  /// Turns mobile data (and data roaming) off for the subscription the switch
  /// targets, persisting the pre-switch state on the session so a revert can put
  /// it back. Best effort by design: a device without MODIFY_PHONE_STATE and
  /// without root logs the miss and still performs the card switch.
  Future<void> _applyDataGuard({required int? preferredSlot}) async {
    final settings = AppSettings();
    if (!settings.dataGuardEnabled) return;
    final session = _session;
    if (session == null) return;
    if (session.guardEnforced) {
      // Already enforced for this session; only re-assert if the platform says
      // data came back after the card reset.
      final subId = session.guardSubscriptionId;
      if (subId == null || subId < 0) return;
      final states = await _dataGuard.status();
      final state = states.where((s) => s.subscriptionId == subId).firstOrNull;
      if (state == null || state.dataEnabled != true) return;
      final again = await _dataGuard.lockdown(subId);
      if (again.enforced) {
        _lastGuardResult = again;
        _log.info('Data guard re-asserted on sub=$subId after card reset');
      }
      return;
    }

    final subscriptions = _networkStatus?.subscriptions ?? const <NetworkStatusSubscription>[];
    NetworkStatusSubscription? target;
    if (preferredSlot != null) {
      target = subscriptions.where((s) => s.slotIndex == preferredSlot).firstOrNull;
    }
    target ??= subscriptions.length == 1 ? subscriptions.single : null;
    target ??= _selectMatchingSubscription(subscriptions);
    if (target == null || target.subscriptionId < 0) {
      _log.fine('Data guard skipped: no subscription for slot $preferredSlot yet');
      _lastGuardResult = DataGuardResult.skipped(-1);
      await _saveSession(session.copyWith(guardEnforced: false));
      return;
    }

    final result = await _dataGuard.lockdown(target.subscriptionId);
    _lastGuardResult = result;
    _session = session.copyWith(
      guardSubscriptionId: target.subscriptionId,
      guardDataEnabledBefore: result.before?.dataEnabled,
      guardRoamingEnabledBefore: result.before?.roamingEnabled,
      guardEnforced: result.enforced,
    );
    await _saveSession(_session);
    if (result.enforced) {
      _log.info(
        'Data guard ON for sub=${target.subscriptionId} '
        '(slot ${target.slotIndex + 1}, viaApi=${result.viaApi}, viaShell=${result.viaShell})',
      );
    } else {
      _log.warning(
        'Data guard could not disable data for sub=${target.subscriptionId}: '
        '${result.error ?? 'no enforcement path'}',
      );
    }
  }

  /// Puts data/roaming back the way they were before the switch.
  Future<void> _restoreDataGuard({
    required int? subscriptionId,
    required bool? dataEnabled,
    required bool? roamingEnabled,
  }) async {
    if (!AppSettings().dataGuardRestoreOnRevert) return;
    if (subscriptionId == null || subscriptionId < 0) return;
    if (dataEnabled == null && roamingEnabled == null) return;
    final result = await _dataGuard.restore(
      subscriptionId: subscriptionId,
      dataEnabled: dataEnabled,
      roamingEnabled: roamingEnabled,
    );
    _log.info(
      'Data guard restore sub=$subscriptionId '
      '(data=$dataEnabled, roaming=$roamingEnabled) ok=${result.enforced}',
    );
  }

  void _startBasebandPolling() {
    _basebandPollTimer?.cancel();
    _basebandPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_running || _session == null || _session!.state != 'waiting_for_service') {
        _basebandPollTimer?.cancel();
        _basebandPollTimer = null;
        return;
      }
      unawaited(_profiles.refreshNetworkStatus().catchError((Object _) {}));
    });
  }

  NetworkStatusSubscription? _selectMatchingSubscription(
    List<NetworkStatusSubscription> subscriptions,
  ) {
    if (subscriptions.isEmpty) return null;
    final slotIndex = _profiles.networkSlotIndex;
    if (slotIndex != null) {
      final exact = subscriptions
          .where((item) => item.slotIndex == slotIndex)
          .firstOrNull;
      if (exact != null) return exact;
    }
    if (subscriptions.length == 1) return subscriptions.single;
    final slot2InService = subscriptions
        .where((item) => item.slotIndex == 1 && item.voiceRegistrationState == VoiceRegistrationState.inService)
        .firstOrNull;
    if (slot2InService != null) return slot2InService;
    final anyInService = subscriptions
        .where((item) => item.voiceRegistrationState == VoiceRegistrationState.inService)
        .firstOrNull;
    if (anyInService != null) return anyInService;
    return subscriptions.where((item) => item.slotIndex == 1).firstOrNull ??
        subscriptions.first;
  }

  static bool _isPlaceholderCarrier(String? carrier) {
    if (carrier == null || carrier.trim().isEmpty) return false;
    final lower = carrier.trim().toLowerCase();
    return lower.contains('紧急') ||
        lower.contains('emergency') ||
        lower.contains('无服务') ||
        lower.contains('no service') ||
        lower.contains('仅限') ||
        lower.contains('searching') ||
        lower.contains('正在搜索');
  }

  void _onNetworkStatus(NetworkStatusUpdate update) {
    _networkStatus = update;
    final session = _session;
    if (!_running || session == null || session.state != 'waiting_for_service') return;
    final subscription = _selectMatchingSubscription(update.subscriptions);
    if (subscription == null ||
        subscription.voiceRegistrationState != VoiceRegistrationState.inService ||
        _isPlaceholderCarrier(subscription.carrierName)) {
      _sawDisconnectAfterSwitch = true;
      return;
    }
    if (_readyNotificationSent) return;
    if (_wasInServiceBeforeSwitch && !_sawDisconnectAfterSwitch) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - _switchCompletedAtMillis;
      if (elapsed < 6000) {
        return;
      }
    }
    _readyNotificationSent = true;
    _basebandPollTimer?.cancel();
    _basebandPollTimer = null;
    _session = session.copyWith(state: 'ready');
    unawaited(_saveSession(_session));
    if (AppSettings().dataGuardEnabled) {
      // The SIM reset can hand data back to the ROM default; make sure the
      // guard still holds before the user starts receiving codes.
      unawaited(
        _applyDataGuard(preferredSlot: _profiles.networkSlotIndex)
            .catchError((Object _) {}),
      );
    }
    final roaming = subscription.roaming == true ? ' (漫游中)' : '';
    final signal = subscription.signalDbm == null ? '' : '，信号 ${subscription.signalDbm} dBm';
    final carrier = subscription.carrierName == null ? '' : '【${subscription.carrierName}】';
    final guardText = AppSettings().dataGuardEnabled
        ? '\n🛡️ 流量卫士：${session.guardEnforced ? '移动数据已锁定关闭（防漫游天价流量）' : '未能关闭移动数据，请手动检查'}'
        : '';
    final proxyStatusText = AppSettings().proxyLinkageEnabled
        ? (_lastLinkedProxyNode != null
            ? '\n🌐 代理联动：已切换至【$_lastLinkedProxyNode】'
            : '\n🌐 代理联动：已就绪')
        : '';
    unawaited(
      _sendTelegramReply(
        _TelegramReply(
          '📡 搜网就绪！\n已成功连接到基站$carrier$roaming$signal。$guardText$proxyStatusText\n\n'
          '👉 卡片切换成功并已持久生效，现在可以前往目标平台接收验证码了！',
          keyboard: const [
            [
              _TelegramButton('🏠 接码完成，切回默认主卡', 'cmd:back'),
            ],
            [
              _TelegramButton('📡 刷新信号状态', 'cmd:status'),
              _TelegramButton('📋 卡内 eSIM 列表', 'cmd:list'),
            ],
          ],
        ),
      ).catchError((Object _) {}),
    );
    unawaited(
      Future<void>.delayed(const Duration(seconds: 3), () async {
        await _profiles.purgeSwitchNotifications();
      }).catchError((Object _) {}),
    );
  }

  Future<void> _restoreFallback() async {
    _session = await _loadSession();
    final savedDefault = await _loadDefault();
    if (_session != null &&
        savedDefault != null &&
        _session!.defaultIccid != savedDefault.iccid) {
      if (_session!.targetIccid == savedDefault.iccid &&
          _session!.state != 'waiting_for_service') {
        _session = null;
        await _saveSession(null);
      } else {
        _session = _session!.copyWith(
          defaultIccid: savedDefault.iccid,
          defaultAlias: savedDefault.alias,
        );
        await _saveSession(_session);
      }
    }
    final session = _session;
    _readyNotificationSent = session?.state == 'ready';
    if (session != null && session.state == 'waiting_for_service') {
      _startBasebandPolling();
    }
    if (session == null || session.deadlineEpochMillis == 0) {
      await _smsRelay.cancelGatewayRevert();
      return;
    }
    final deadline = DateTime.fromMillisecondsSinceEpoch(session.deadlineEpochMillis);
    if (!deadline.isAfter(DateTime.now())) {
      await _smsRelay.cancelGatewayRevert();
      _scheduleLocalFallback(deadline);
      return;
    }
    try {
      await _smsRelay.scheduleGatewayRevert(deadline);
    } catch (_) {
      _log.warning('Exact fallback alarm could not be restored');
    }
    _scheduleLocalFallback(deadline);
  }

  void _scheduleLocalFallback(DateTime deadline) {
    _revertTimer?.cancel();
    final delay = deadline.difference(DateTime.now());
    _revertTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      unawaited(_serialize(() async {
        try {
          await _revert(auto: true);
        } catch (error) {
          _log.warning('Automatic profile fallback failed (${_errorCode(error)})');
        }
      }));
    });
  }

  Future<void> _checkCooldown() async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getInt(_lastSwitchKey);
    if (previous == null) return;
    final elapsed = DateTime.now().millisecondsSinceEpoch - previous;
    if (elapsed < switchCooldown.inMilliseconds) {
      throw const RemoteGatewayException('profile_switch_cooldown');
    }
  }

  Future<void> _recordSwitchTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastSwitchKey, DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> _saveDefault(_RemoteDefault? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove(_defaultKey);
    } else {
      await prefs.setString(_defaultKey, jsonEncode(value.toJson()));
    }
  }

  Future<_RemoteDefault?> _loadDefault() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_defaultKey);
    if (raw == null) return null;
    try {
      return _RemoteDefault.fromJson(jsonDecode(raw));
    } catch (_) {
      await prefs.remove(_defaultKey);
      return null;
    }
  }

  Future<void> _saveSession(_RemoteSession? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null) {
      await prefs.remove(_sessionKey);
    } else {
      await prefs.setString(_sessionKey, jsonEncode(value.toJson()));
    }
  }

  Future<_RemoteSession?> _loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sessionKey);
    if (raw == null) return null;
    try {
      return _RemoteSession.fromJson(jsonDecode(raw));
    } catch (_) {
      await prefs.remove(_sessionKey);
      return null;
    }
  }

  Future<List<_KeepAliveRule>> _loadKeepAliveRules() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keepAliveKey);
    if (raw == null || raw.isEmpty) return <_KeepAliveRule>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <_KeepAliveRule>[];
      return decoded
          .whereType<Map>()
          .map((m) => _KeepAliveRule.fromJson(m))
          .toList();
    } catch (_) {
      await prefs.remove(_keepAliveKey);
      return <_KeepAliveRule>[];
    }
  }

  Future<void> _saveKeepAliveRules(List<_KeepAliveRule> rules) async {
    final prefs = await SharedPreferences.getInstance();
    if (rules.isEmpty) {
      await prefs.remove(_keepAliveKey);
    } else {
      await prefs.setString(
        _keepAliveKey,
        jsonEncode(rules.map((r) => r.toJson()).toList()),
      );
    }
  }

  Future<void> _runPeriodicMaintenance() async {
    if (!_running) return;
    // The 20-second timer must not start a second run while the first is still
    // working, or the two drift into each other.
    if (_maintenanceInFlight) return;
    _maintenanceInFlight = true;
    try {
      _maintenanceTickCount++;
      await _checkDeviceHealthAlerts();
      if (_maintenanceTickCount % 3 == 0) {
        // The retry is deliberately not awaited: one batch can take minutes
        // when the endpoint is unreachable, and keep-alive checks must not
        // wait for it.
        unawaited(_retryFailedSms(automatic: true));
        await _checkScheduledKeepAlive();
      }
      // The gateway runs headless, so an update the operator never hears
      // about is an update that never gets installed. The notifier keeps this
      // to one feed read per day.
      unawaited(_checkForUpdateRelease());
    } finally {
      _maintenanceInFlight = false;
    }
  }

  /// Tells the operator over Telegram that a newer release exists.
  Future<void> _checkForUpdateRelease() async {
    final UpdateInfo? update;
    try {
      update = await UpdateNotifier.check();
    } catch (_) {
      return;
    }
    if (update == null) return;
    if (!UpdateNotifier.shouldNotify(update)) return;

    final config = _configuration;
    final canReach =
        config?.telegramToken != null && config?.telegramChatId != null;
    if (canReach) {
      // The notice goes to every chat that talks to the bot, not only to the
      // owner: a release note that only reaches one chat leaves the other
      // users on a build without the fixes.
      try {
        await _announceToEveryone(_formatReleaseNotice(update));
      } catch (e) {
        _log.warning('Update announcement failed: $e');
      }
    }
    await UpdateNotifier.markNotified(update);
  }

  /// Resends the SMS that never made it out.
  ///
  /// Only one batch may be outstanding at a time. Two overlapping batches
  /// deliver the same verification code twice, and each one queues behind the
  /// other on the platform side, so the queue only ever grows.
  Future<int> _retryFailedSms({required bool automatic, String? id}) async {
    if (_smsRetryInFlight) return 0;
    final now = DateTime.now();
    if (automatic) {
      if (!shouldRunAutomaticSmsRetry(
        lastAttempt: _lastAutomaticSmsRetry,
        now: now,
        interval: _automaticSmsRetryInterval,
      )) {
        return 0;
      }
      _lastAutomaticSmsRetry = now;
    }
    _smsRetryInFlight = true;
    try {
      return await _smsRelay.retryFailedHistory(id: id);
    } catch (_) {
      return 0;
    } finally {
      _smsRetryInFlight = false;
    }
  }

  Future<void> _checkDeviceHealthAlerts() async {
    try {
      final health = await _smsRelay.getDeviceHealth();
      final now = DateTime.now().millisecondsSinceEpoch;
      final prevCharging = _wasCharging;
      if (health.batteryPercent != null) {
        _wasCharging = health.charging;
      }
      if (prevCharging == true && !health.charging && health.batteryPercent != null) {
        _lastHealthAlertMillis = now;
        await _sendTelegramReply(
          _TelegramReply(
            '⚠️ 【备用机断电告警】\n检测到手机外部充电电源已断开！\n'
            '• 当前电量：${health.batteryPercent}%\n'
            '• 网络状态：${health.networkType ?? "未知"}\n\n'
            '请及时检查插座或充电线，防止电量耗尽失联。',
            keyboard: const [
              [_TelegramButton('📡 查看设备与基带状态', 'cmd:status')],
            ],
          ),
        );
        return;
      }
      if (now - _lastHealthAlertMillis < 30 * 60 * 1000) return;
      if (!health.charging &&
          health.batteryPercent != null &&
          health.batteryPercent! <= 20) {
        _lastHealthAlertMillis = now;
        await _sendTelegramReply(
          _TelegramReply(
            '🚨 【备用机低电量告警】\n当前电量仅剩 ${health.batteryPercent}% 且未处于充电状态，即将面临关机失联！',
            keyboard: const [
              [_TelegramButton('📡 查看设备状态', 'cmd:status')],
            ],
          ),
        );
      } else if (health.temperatureCelsius != null &&
          health.temperatureCelsius! >= 45.0) {
        _lastHealthAlertMillis = now;
        await _sendTelegramReply(
          _TelegramReply(
            '🔥 【备用机高温告警】\n当前电池温度达 ${health.temperatureCelsius!.toStringAsFixed(1)}°C，请注意备用机散热环境！',
            keyboard: const [
              [_TelegramButton('📡 查看设备状态', 'cmd:status')],
            ],
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _checkScheduledKeepAlive() async {
    if (!_running || _session != null) return;
    try {
      final rules = await _loadKeepAliveRules();
      if (rules.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final rule in rules) {
        if (now < rule.nextRunEpochMillis) continue;
        final Map<String, Object?> res;
        try {
          res = await runKeepAliveNow(rule.iccid);
        } catch (error) {
          // A deleted profile or a card error leaves the rule due forever. Keep
          // scanning so one broken rule cannot starve every later one, and log
          // instead of swallowing the reason.
          _log.warning(
            'Scheduled keep-alive for ${rule.alias.isNotEmpty ? rule.alias : rule.iccid} '
            'failed (${_errorCode(error)})',
          );
          continue;
        }
        unawaited(
          _sendTelegramReply(
            _TelegramReply(
              '🛡️ 【定时保号任务自动触发】\n'
              '已按计划（每 ${rule.intervalDays} 天）自动切换至：【${res['target']}】。\n'
              '将在漫游基站驻留 ${rule.dwellSeconds ~/ 60} 分钟后自动切回默认主卡。',
              keyboard: const [
                [
                  _TelegramButton('📡 查看搜网状态', 'cmd:status'),
                  _TelegramButton('🏠 立即切回主卡', 'cmd:back'),
                ],
              ],
            ),
          ).catchError((Object _) {}),
        );
        // Only one switch can be in flight; the rest wait for the next tick.
        break;
      }
    } catch (_) {}
  }

  Future<void> _refreshHttpServer() async {
    if (!_running) return;
    final address = _bindAddressOverride ?? await _findTailscaleAddress();
    // _serverAddress holds the textual form; comparing an InternetAddress to it
    // never matched, so the listener was torn down and rebound every refresh.
    if (address?.address == _serverAddress && _server != null) return;
    await _server?.close(force: true);
    _server = null;
    _serverAddress = null;
    if (address == null) return;
    try {
      final server = await HttpServer.bind(address, port, shared: false);
      _server = server;
      _serverAddress = address.address;
      server.listen(
        (request) => unawaited(_handleHttpRequest(request)),
        onError: (Object _) {},
      );
    } catch (_) {
      _log.warning('REST listener could not bind to a Tailscale address');
    }
  }

  Future<InternetAddress?> _findTailscaleAddress() async {
    try {
      final interfaces = await NetworkInterface.list(includeLoopback: false);
      return pickTailnetAddress(
        interfaces.map(
          (interface) => (name: interface.name, addresses: interface.addresses),
        ),
      );
    } catch (_) {
      // A missing VPN interface is normal until Tailscale connects.
      return null;
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..headers.set(HttpHeaders.serverHeader, 'eSIM-Matrix Gateway')
          ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
          ..write(_dashboardHtml);
        await request.response.close();
        return;
      }
      if (!_authorized(request)) {
        await _writeJson(request.response, HttpStatus.unauthorized, {'error': 'unauthorized'});
        return;
      }
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/api/v1/status') {
        await _writeJson(request.response, HttpStatus.ok, await status());
      } else if (request.method == 'GET' && path == '/api/v1/profiles') {
        await _writeJson(request.response, HttpStatus.ok, {'profiles': await listProfiles()});
      } else if (request.method == 'POST' && path == '/api/v1/default') {
        await _writeJson(request.response, HttpStatus.ok, await setDefaultProfile());
      } else if (request.method == 'POST' && path == '/api/v1/switch') {
        final body = await _readJsonBody(request);
        final profile = body['profile'];
        if (profile is! String) throw const RemoteGatewayException('profile_required');
        final tempMin = body['temporaryMinutes'];
        final duration = tempMin is num && tempMin > 0
            ? Duration(minutes: tempMin.toInt().clamp(1, 120))
            : null;
        await _writeJson(
          request.response,
          HttpStatus.ok,
          await switchProfile(profile, duration: duration),
        );
      } else if (request.method == 'POST' && path == '/api/v1/rename') {
        final body = await _readJsonBody(request);
        final profile = body['profile'];
        final alias = body['alias'];
        if (profile is! String) throw const RemoteGatewayException('profile_required');
        if (alias is! String) throw const RemoteGatewayException('alias_required');
        await _writeJson(
          request.response,
          HttpStatus.ok,
          await renameProfile(profile, alias),
        );
      } else if (request.method == 'GET' && path == '/api/v1/readers') {
        await _writeJson(
          request.response,
          HttpStatus.ok,
          {'readers': await listReaders()},
        );
      } else if (request.method == 'POST' && path == '/api/v1/reader') {
        final body = await _readJsonBody(request);
        final reader = body['reader'];
        if (reader is! String) throw const RemoteGatewayException('reader_not_found');
        await _writeJson(
          request.response,
          HttpStatus.ok,
          await selectReader(reader),
        );
      } else if (request.method == 'GET' && path == '/api/v1/keepalive') {
        await _writeJson(
          request.response,
          HttpStatus.ok,
          {'rules': await listKeepAliveRules()},
        );
      } else if (request.method == 'POST' && path == '/api/v1/keepalive') {
        final body = await _readJsonBody(request);
        final profile = body['profile'];
        if (profile is! String) throw const RemoteGatewayException('profile_required');
        if (body['runNow'] == true) {
          await _writeJson(
            request.response,
            HttpStatus.ok,
            await runKeepAliveNow(profile),
          );
        } else {
          final days = (body['intervalDays'] as num?)?.toInt() ?? 90;
          await _writeJson(
            request.response,
            HttpStatus.ok,
            await setKeepAliveRule(profile, intervalDays: days),
          );
        }
      } else if (request.method == 'POST' && path == '/api/v1/sms/retry') {
        final delivered = await _retryFailedSms(automatic: false);
        await _writeJson(
          request.response,
          HttpStatus.ok,
          {'deliveredCount': delivered},
        );
      } else if (request.method == 'POST' && path == '/api/v1/download') {
        final body = await _readJsonBody(request);
        final code = body['activationCode'];
        if (code is! String) throw const RemoteGatewayException('activation_code_required');
        final cc = body['confirmationCode'] as String?;
        await _writeJson(request.response, HttpStatus.ok, await downloadProfile(code, confirmationCode: cc));
      } else if (request.method == 'POST' && path == '/api/v1/delete/request') {
        final body = await _readJsonBody(request);
        final profile = body['profile'];
        if (profile is! String) throw const RemoteGatewayException('profile_required');
        await _writeJson(request.response, HttpStatus.ok, await requestDeleteProfile(profile));
      } else if (request.method == 'POST' && path == '/api/v1/delete/confirm') {
        final body = await _readJsonBody(request);
        final token = body['token'];
        if (token is! String) throw const RemoteGatewayException('token_required');
        await _writeJson(request.response, HttpStatus.ok, await confirmDeleteProfile(token));
      } else if (request.method == 'POST' && path == '/api/v1/back') {
        await _writeJson(request.response, HttpStatus.ok, await revertProfile());
      } else if (request.method == 'GET' && path == '/api/v1/proxy') {
        final settings = AppSettings();
        _proxyLinkage.updateConfig(
          controllerUrl: settings.proxyControllerUrl,
          secret: settings.proxySecret,
        );
        final currentNode = await _proxyLinkage.getCurrentNode(settings.proxyTargetGroup);
        final groups = await _proxyLinkage.getSelectorGroups();
        await _writeJson(request.response, HttpStatus.ok, {
          'enabled': settings.proxyLinkageEnabled,
          'controllerUrl': settings.proxyControllerUrl,
          'targetGroup': settings.proxyTargetGroup,
          'autoRestore': settings.proxyAutoRestore,
          'currentNode': currentNode,
          'lastLinkedNode': _lastLinkedProxyNode,
          'snapshotNode': _proxySnapshot?.node,
          'selectorGroups': groups.map((g) => g.name).toList(),
          'customRules': settings.proxyCustomRules,
        });
      } else if (request.method == 'POST' && path == '/api/v1/proxy/test') {
        final body = await _readJsonBody(request).catchError((_) => <String, Object?>{});
        final testUrl = body['controllerUrl'] as String? ?? AppSettings().proxyControllerUrl;
        final testSecret = body['secret'] as String? ?? AppSettings().proxySecret;
        final testService = ProxyLinkageService(controllerUrl: testUrl, secret: testSecret);
        final conn = await testService.testConnection();
        final groups = conn.alive ? await testService.getSelectorGroups() : const <ProxyGroupInfo>[];
        await _writeJson(request.response, HttpStatus.ok, {
          'alive': conn.alive,
          'version': conn.version,
          'error': conn.error,
          'groups': groups.map((g) => {'name': g.name, 'now': g.now, 'all': g.all}).toList(),
        });
      } else if (request.method == 'POST' && path == '/api/v1/proxy/config') {
        final body = await _readJsonBody(request);
        final settings = AppSettings();
        if (body.containsKey('enabled')) {
          await settings.setProxyLinkageEnabled(body['enabled'] == true);
        }
        if (body['controllerUrl'] is String) {
          await settings.setProxyControllerUrl(body['controllerUrl'] as String);
        }
        if (body.containsKey('secret')) {
          await settings.setProxySecret(body['secret'] as String?);
        }
        if (body['targetGroup'] is String) {
          await settings.setProxyTargetGroup(body['targetGroup'] as String);
        }
        if (body.containsKey('autoRestore')) {
          await settings.setProxyAutoRestore(body['autoRestore'] == true);
        }
        if (body['customRules'] is Map) {
          final map = (body['customRules'] as Map).map((k, v) => MapEntry(k.toString(), v.toString()));
          await settings.setProxyCustomRules(map);
        }
        _proxyLinkage.updateConfig(
          controllerUrl: settings.proxyControllerUrl,
          secret: settings.proxySecret,
        );
        await _writeJson(request.response, HttpStatus.ok, {'status': 'saved'});
      } else if (request.method == 'POST' && path == '/api/v1/proxy/switch') {
        final body = await _readJsonBody(request);
        final group = (body['group'] as String?) ?? AppSettings().proxyTargetGroup;
        final node = body['node'];
        if (node is! String) throw const RemoteGatewayException('node_required');
        final res = await _proxyLinkage.selectNode(group, node);
        await _writeJson(request.response, HttpStatus.ok, res.toJson());
      } else if (request.method == 'GET' && path == '/api/v1/dashboard') {
        await _writeJson(request.response, HttpStatus.ok, await _dashboardPayload());
      } else if (request.method == 'GET' && path == '/api/v1/sms/history') {
        final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 50;
        final entries = await _smsRelay.loadHistory().catchError(
          (Object _) => const <SmsHistoryEntry>[],
        );
        final sorted = entries.toList()
          ..sort((a, b) => b.receivedAtMillis.compareTo(a.receivedAtMillis));
        await _writeJson(request.response, HttpStatus.ok, {
          'messages': sorted.take(limit.clamp(1, 200)).map((entry) => {
                'id': entry.id,
                'sender': entry.sender,
                'body': entry.body,
                if (entry.otp != null) 'otp': entry.otp,
                'slotIndex': entry.slotIndex,
                'carrierName': entry.carrierName,
                'receivedAtMillis': entry.receivedAtMillis,
                'mode': entry.mode,
                'delivered': entry.delivered,
                if (entry.errorCode != null) 'errorCode': entry.errorCode,
              }).toList(growable: false),
        });
      } else if (request.method == 'POST' && path == '/api/v1/dataguard') {
        final body = await _readJsonBody(request);
        final settings = AppSettings();
        if (body.containsKey('enabled')) {
          await settings.setDataGuardEnabled(body['enabled'] == true);
        }
        if (body.containsKey('restoreOnRevert')) {
          await settings.setDataGuardRestoreOnRevert(body['restoreOnRevert'] == true);
        }
        final capabilities = await _dataGuard.capabilities();
        await _writeJson(request.response, HttpStatus.ok, {
          'enabled': settings.dataGuardEnabled,
          'restoreOnRevert': settings.dataGuardRestoreOnRevert,
          'capabilities': capabilities.toJson(),
        });
      } else if (request.method == 'POST' && path == '/api/v1/dataguard/apply') {
        final body = await _readJsonBody(request);
        final requested = (body['subscriptionId'] as num?)?.toInt();
        final subId = requested ?? _session?.guardSubscriptionId ??
            (_networkStatus?.subscriptions ?? const <NetworkStatusSubscription>[])
                .map((s) => s.subscriptionId)
                .firstWhere((id) => id >= 0, orElse: () => -1);
        if (subId < 0) {
          throw const RemoteGatewayException('subscription_not_found');
        }
        final result = await _dataGuard.lockdown(subId);
        _lastGuardResult = result;
        await _writeJson(request.response, HttpStatus.ok, result.toJson());
      } else {
        await _writeJson(request.response, HttpStatus.notFound, {'error': 'not_found'});
      }
    } catch (error) {
      final code = _errorCode(error);
      final statusCode = error is RemoteGatewayException ? HttpStatus.conflict : HttpStatus.internalServerError;
      try {
        await _writeJson(request.response, statusCode, {'error': code});
      } catch (_) {
        await request.response.close();
      }
    }
  }

  bool _authorized(HttpRequest request) {
    final token = _configuration?.apiToken;
    if (token == null) return false;
    final authorization = request.headers.value(HttpHeaders.authorizationHeader);
    if (authorization == null || !authorization.startsWith('Bearer ')) return false;
    return _constantTimeEquals(authorization.substring(7), token);
  }

  bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }

  Future<Map<String, Object?>> _readJsonBody(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      if (bytes.length + chunk.length > 8192) {
        throw const RemoteGatewayException('request_too_large');
      }
      bytes.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) throw const RemoteGatewayException('invalid_json');
    return Map<String, Object?>.from(decoded);
  }

  Future<void> _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> payload,
  ) async {
    response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..headers.set(HttpHeaders.serverHeader, 'eSIM-Matrix Gateway')
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..write(jsonEncode(payload));
    await response.close();
  }

  Future<void> _pollTelegram(int generation) async {
    final config = _configuration;
    final token = config?.telegramToken;
    final allowedChat = config?.telegramChatId;
    if (token == null || allowedChat == null) return;
    unawaited(_registerTelegramBotCommands(token).catchError((Object _) {}));
    final prefs = await SharedPreferences.getInstance();
    var offset = prefs.getInt(_telegramOffsetKey) ?? 0;
    while (_running && _telegramPollGeneration == generation) {
      try {
        final updates = await _telegramGetUpdates(token, offset);
        if (!_running || _telegramPollGeneration != generation) return;
        _lastTelegramError = null;
        for (final update in updates) {
          if (!_running || _telegramPollGeneration != generation) return;
          final updateId = update['update_id'];
          if (updateId is! int) continue;
          offset = updateId + 1;
          await prefs.setInt(_telegramOffsetKey, offset);
          try {
            final reply = await _dispatchTelegramUpdate(update, allowedChat, token: token);
            if (reply != null) {
              await _sendTelegramReply(reply);
              if (_session != null &&
                  _session!.state == 'waiting_for_service' &&
                  _networkStatus != null) {
                _onNetworkStatus(_networkStatus!);
              }
            }
          } catch (e) {
            _log.warning('Error handling telegram update: $e');
            try {
              await _sendTelegramReply(
                _TelegramReply(
                  '❌ 操作失败：$e',
                  keyboard: _mainMenuKeyboard(),
                ),
              );
            } catch (_) {}
          }
        }
      } catch (error) {
        if (!_running || _telegramPollGeneration != generation) return;
        _lastTelegramError = _errorCode(error);
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
  }

  Future<void> _registerTelegramBotCommands(String token) async {
    final uri = Uri.https('api.telegram.org', '/bot$token/setMyCommands');
    final request = await _telegramHttpClient.postUrl(uri).timeout(const Duration(seconds: 10));
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'commands': [
          {'command': 'list', 'description': '📋 卡内 eSIM 列表与快捷按钮面板'},
          {'command': 'status', 'description': '📡 基带漫游、电量温度与芯片空间状态'},
          {'command': 'keepalive', 'description': '🛡️ 定时自动切卡保号管理'},
          {'command': 'readers', 'description': '🔀 切换物理卡槽 / 读卡器 (SIM 1 / SIM 2)'},
          {'command': 'rename', 'description': '✏️ 修改卡片备注名 (例: /rename 2 英国卡)'},
          {'command': 'use', 'description': '🔄 持久切换卡位 (例: /use 2)'},
          {'command': 'use_temp', 'description': '⏱️ 临时接码5分钟后回主卡 (例: /use_temp 2)'},
          {'command': 'back', 'description': '🏠 立即切回默认常驻主卡'},
          {'command': 'default', 'description': '📌 将当前激活卡设为默认主卡'},
          {'command': 'download_test', 'description': '🚀 一键下载 Speedtest 公开测试 eSIM'},
          {'command': 'download', 'description': '📥 远程下卡或直接发送二维码图片'},
          {'command': 'delete', 'description': '🗑️ 安全二步删卡 (例: /delete 2)'},
          {'command': 'retry_sms', 'description': '🔄 一键补发未送达短信'},
          {'command': 'announce', 'description': '📣 向所有已登记会话发布公告'},
          {'command': 'help', 'description': '🤖 打开交互式主控台'},
        ],
      }),
    );
    final response = await request.close().timeout(const Duration(seconds: 10));
    await response.drain<void>().timeout(const Duration(seconds: 10));
  }

  Future<void> _answerTelegramCallbackQuery(
    String token,
    String callbackQueryId, {
    String? text,
  }) async {
    final uri = Uri.https('api.telegram.org', '/bot$token/answerCallbackQuery');
    final request = await _telegramHttpClient.postUrl(uri).timeout(const Duration(seconds: 8));
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'callback_query_id': callbackQueryId,
        if (text != null && text.isNotEmpty) 'text': text,
      }),
    );
    final response = await request.close().timeout(const Duration(seconds: 8));
    await response.drain<void>().timeout(const Duration(seconds: 8));
  }

  Future<List<Map<String, Object?>>> _telegramGetUpdates(
    String token,
    int offset,
  ) async {
    final uri = Uri.https('api.telegram.org', '/bot$token/getUpdates', {
      'offset': '$offset',
      'limit': '50',
      'timeout': '25',
      'allowed_updates': '["message","callback_query"]',
    });
    final request = await _telegramHttpClient.getUrl(uri).timeout(const Duration(seconds: 10));
    final response = await request.close().timeout(const Duration(seconds: 35));
    final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 35));
    if (body.length > 65536) throw const RemoteGatewayException('telegram_response_too_large');
    final decoded = jsonDecode(body);
    if (response.statusCode < 200 || response.statusCode >= 300 ||
        decoded is! Map || decoded['ok'] != true || decoded['result'] is! List) {
      throw const RemoteGatewayException('telegram_api_error');
    }
    return (decoded['result'] as List)
        .whereType<Map>()
        .map((value) => Map<String, Object?>.from(value))
        .toList(growable: false);
  }

  @visibleForTesting
  Future<Map<String, Object?>?> handleTelegramUpdateForTesting(
    Map<String, Object?> update,
    String allowedChat,
  ) async {
    final reply = await _dispatchTelegramUpdate(update, allowedChat);
    return reply?.toPayload(allowedChat);
  }

  Future<_TelegramReply?> _dispatchTelegramUpdate(
    Map update,
    String allowedChat, {
    String? token,
  }) async {
    final callbackQuery = update['callback_query'];
    if (callbackQuery is Map) {
      return _handleTelegramCallbackQuery(callbackQuery, allowedChat, token: token);
    }
    final message = update['message'];
    if (message is Map) {
      return _handleTelegramMessage(message, allowedChat, token: token);
    }
    return null;
  }

  Future<_TelegramReply?> _handleTelegramCallbackQuery(
    Map callbackQuery,
    String allowedChat, {
    String? token,
  }) async {
    final from = callbackQuery['from'];
    final message = callbackQuery['message'];
    final chat = message is Map ? message['chat'] : null;
    if (from is! Map ||
        chat is! Map ||
        chat['type'] != 'private' ||
        '${chat['id']}' != allowedChat ||
        '${from['id']}' != allowedChat ||
        from['is_bot'] == true) {
      return null;
    }
    final callbackId = callbackQuery['id'];
    final data = callbackQuery['data'];
    if (data is! String || data.isEmpty) return null;

    String toast = '⚡ 正在执行...';
    if (data == 'cmd:list') toast = '📋 正在读取卡内 eSIM 列表...';
    if (data == 'cmd:status') toast = '📡 正在刷新设备与基带状态...';
    if (data == 'cmd:keepalive') toast = '🛡️ 正在加载定时保号计划...';
    if (data == 'cmd:readers') toast = '🔀 正在读取可用卡槽与读卡器...';
    if (data == 'cmd:retry_sms') toast = '🔄 正在补发未送达短信...';
    if (data == 'cmd:download_test') toast = '🚀 开始下载 Speedtest 公开测试 eSIM...';
    if (data == 'cmd:back') toast = '🏠 正在切回默认主卡...';
    if (data == 'cmd:default') toast = '📌 正在绑定默认主卡...';
    if (data.startsWith('use:')) toast = '🔄 正在下发持久切卡指令...';
    if (data.startsWith('use_temp:')) toast = '⏱️ 正在切换为 5 分钟临时接码模式...';
    if (data.startsWith('ka_set:')) toast = '🛡️ 正在保存定时保号规则...';
    if (data.startsWith('ka_now:')) toast = '⚡ 正在启动 3 分钟自动驻网保号...';
    if (data.startsWith('ka_off:')) toast = '✅ 正在关闭该卡定时保号...';
    if (data.startsWith('reader:')) toast = '🔀 正在切换目标卡槽/读卡器...';
    if (data.startsWith('del:')) toast = '⚠️ 正在生成删卡安全确认码...';
    if (data.startsWith('del_ok:')) toast = '🗑️ 正在从芯片抹除卡片...';
    if (data == 'del_cancel') toast = '✅ 已取消删除';

    if (token != null && callbackId is String && callbackId.isNotEmpty) {
      unawaited(
        _answerTelegramCallbackQuery(token, callbackId, text: toast)
            .catchError((Object _) {}),
      );
    }

    if (data.startsWith('cmd:')) {
      return _executeTelegramCommand(data.substring(4), '');
    }
    if (data.startsWith('use:')) {
      return _executeTelegramCommand('use', data.substring(4));
    }
    if (data.startsWith('use_temp:')) {
      return _executeTelegramCommand('use_temp', data.substring(9));
    }
    if (data.startsWith('ka_set:')) {
      final parts = data.substring(7).split(':');
      if (parts.length == 2) {
        return _executeTelegramCommand('keepalive', '${parts[0]} ${parts[1]}');
      }
    }
    if (data.startsWith('ka_now:')) {
      return _executeTelegramCommand('keepalive_now', data.substring(7));
    }
    if (data.startsWith('ka_off:')) {
      return _executeTelegramCommand('keepalive', '${data.substring(7)} off');
    }
    if (data.startsWith('reader:')) {
      return _executeTelegramCommand('reader', data.substring(7));
    }
    if (data.startsWith('ren_hint:')) {
      final slot = data.substring(9);
      return _TelegramReply(
        '✏️ 修改 #$slot 号卡片备注名：\n'
        '请直接在聊天框发送：\n'
        '/rename $slot 新卡片名称\n\n'
        '例如：/rename $slot 英国主力 +44',
        keyboard: const [
          [_TelegramButton('📋 返回卡列表', 'cmd:list')],
        ],
      );
    }
    if (data.startsWith('del:')) {
      return _executeTelegramCommand('delete', data.substring(4));
    }
    if (data.startsWith('del_ok:')) {
      return _executeTelegramCommand('delete_confirm', data.substring(7));
    }
    if (data == 'del_cancel') {
      return _executeTelegramCommand('delete_cancel', '');
    }
    return null;
  }

  Future<_TelegramReply?> _handleTelegramMessage(
    Map message,
    String allowedChat, {
    String? token,
  }) async {
    final chat = message['chat'];
    final sender = message['from'];
    if (chat is! Map || sender is! Map) return null;
    // Every private chat that writes to the bot is remembered so that release
    // announcements can reach all of them. Registering grants no control
    // rights: the command filter below still only accepts the owner chat.
    if (chat['type'] == 'private' && sender['is_bot'] != true) {
      unawaited(
        TelegramRegistry.instance
            .record('${chat['id']}', _telegramDisplayName(sender))
            .catchError((Object _) {}),
      );
    }
    if (chat['type'] != 'private' ||
        '${chat['id']}' != allowedChat ||
        '${sender['id']}' != allowedChat ||
        sender['is_bot'] == true) {
      return null;
    }
    final fileId = _extractImageFileId(message);
    if (fileId != null) {
      return _handleTelegramQrImage(fileId, token: token ?? _configuration?.telegramToken);
    }
    final text = (message['text'] as String?) ?? (message['caption'] as String?);
    if (text is! String) return null;
    final trimmedText = text.trim();
    final lpaMatch = RegExp(
      r'(LPA:1\$[^\s]+)',
      caseSensitive: false,
    ).firstMatch(trimmedText);
    if (lpaMatch != null && !trimmedText.startsWith('/')) {
      return _executeTelegramCommand('download', lpaMatch.group(1)!);
    }
    final firstNewline = trimmedText.indexOf('\n');
    final commandLine = firstNewline == -1
        ? trimmedText
        : trimmedText.substring(0, firstNewline).trim();
    final restLines = firstNewline == -1
        ? ''
        : trimmedText.substring(firstNewline + 1).trim();
    final command = RegExp(
      r'^/(start|help|menu|list|status|use|use_temp|back|default|rename|keepalive|keepalive_now|readers|reader|retry_sms|download|download_test|delete|delete_confirm|delete_cancel|announce|guard|guard_toggle|guard_now|proxy|proxy_toggle|proxy_group|proxy_node|tunnel)(?:@[A-Za-z0-9_]+)?(?:\s+(.*))?$',
      caseSensitive: false,
    ).firstMatch(commandLine);
    if (command == null) return null;
    final name = command.group(1)!.toLowerCase();
    final firstArg = command.group(2)?.trim() ?? '';
    final argument = restLines.isEmpty
        ? firstArg
        : (firstArg.isEmpty ? restLines : '$firstArg $restLines');
    return _executeTelegramCommand(name, argument);
  }

  String? _extractImageFileId(Map message) {
    final photo = message['photo'];
    if (photo is List && photo.isNotEmpty) {
      final largest = photo.last;
      if (largest is Map && largest['file_id'] is String) {
        return largest['file_id'] as String;
      }
    }
    final doc = message['document'];
    if (doc is Map && doc['file_id'] is String) {
      final mime = '${doc['mime_type'] ?? ''}'.toLowerCase();
      final fileName = '${doc['file_name'] ?? ''}'.toLowerCase();
      if (mime.startsWith('image/') ||
          fileName.endsWith('.png') ||
          fileName.endsWith('.jpg') ||
          fileName.endsWith('.jpeg') ||
          fileName.endsWith('.webp')) {
        return doc['file_id'] as String;
      }
    }
    return null;
  }

  Future<_TelegramReply> _handleTelegramQrImage(
    String fileId, {
    String? token,
  }) async {
    if (token == null || token.isEmpty) {
      return const _TelegramReply('❌ 未配置 Telegram Bot Token，无法拉取二维码图片。');
    }
    unawaited(
      _sendTelegramText('🔍 已收到图片，正在为您自动识别解析 eSIM 二维码...')
          .catchError((Object _) {}),
    );
    try {
      final bytes = await _downloadTelegramFileBytes(token, fileId);
      final decoded = await decodeQrBytesWithZxing(bytes);
      if (decoded == null || decoded.trim().isEmpty) {
        return const _TelegramReply(
          '⚠️ 未能在该图片中识别到清晰的二维码。\n'
          '请尝试裁剪放大二维码区域后重发，或直接粘贴发送 LPA:1\$... 文本激活码。',
          keyboard: [
            [_TelegramButton('📋 查看卡内列表', 'cmd:list')],
          ],
        );
      }
      final clean = decoded.trim();
      final lpaMatch = RegExp(
        r'(LPA:1\$[^\s]+)',
        caseSensitive: false,
      ).firstMatch(clean);
      final ac = lpaMatch?.group(1) ?? (clean.toUpperCase().startsWith('LPA:') ? clean : null);
      if (ac == null) {
        return _TelegramReply(
          '⚠️ 二维码识别结果不是有效的 eSIM 激活码（内容：$clean）。',
          keyboard: const [
            [_TelegramButton('📋 查看卡内列表', 'cmd:list')],
          ],
        );
      }
      unawaited(
        _sendTelegramText('🎯 二维码识别成功：$ac\n正在连接 SM-DP+ 服务器写入芯片...')
            .catchError((Object _) {}),
      );
      return await _runTelegramDownload(ac, isSpeedtest: ac == speedtestActivationCode);
    } catch (e) {
      return _TelegramReply(
        '❌ 解析二维码图片失败：$e',
        keyboard: const [
          [_TelegramButton('📋 查看卡内列表', 'cmd:list')],
        ],
      );
    }
  }

  Future<Uint8List> _downloadTelegramFileBytes(String token, String fileId) async {
    final getFileUri = Uri.https('api.telegram.org', '/bot$token/getFile', {
      'file_id': fileId,
    });
    final req = await _telegramHttpClient.getUrl(getFileUri).timeout(const Duration(seconds: 10));
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
    final decoded = jsonDecode(body);
    if (resp.statusCode < 200 ||
        resp.statusCode >= 300 ||
        decoded is! Map ||
        decoded['ok'] != true ||
        decoded['result'] is! Map) {
      throw const RemoteGatewayException('telegram_get_file_failed');
    }
    final filePath = (decoded['result'] as Map)['file_path'];
    if (filePath is! String || filePath.isEmpty) {
      throw const RemoteGatewayException('telegram_file_path_missing');
    }
    final fileUri = Uri.https('api.telegram.org', '/file/bot$token/$filePath');
    final fileReq = await _telegramHttpClient.getUrl(fileUri).timeout(const Duration(seconds: 10));
    final fileResp = await fileReq.close().timeout(const Duration(seconds: 25));
    if (fileResp.statusCode < 200 || fileResp.statusCode >= 300) {
      throw const RemoteGatewayException('telegram_file_download_failed');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in fileResp) {
      if (builder.length + chunk.length > 10 * 1024 * 1024) {
        throw const RemoteGatewayException('image_too_large');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static List<List<_TelegramButton>> _mainMenuKeyboard() => const [
    [
      _TelegramButton('📋 卡内 eSIM 列表', 'cmd:list'),
      _TelegramButton('📡 设备与基带状态', 'cmd:status'),
    ],
    [
      _TelegramButton('🛡️ 定时保号管理', 'cmd:keepalive'),
      _TelegramButton('🔀 切换读卡器/卡槽', 'cmd:readers'),
    ],
    [
      _TelegramButton('🚀 下载 Speedtest 测试卡', 'cmd:download_test'),
      _TelegramButton('🏠 切回默认主卡', 'cmd:back'),
    ],
    [
      _TelegramButton('📌 设当前卡为主卡', 'cmd:default'),
      _TelegramButton('🔄 补发未送达短信', 'cmd:retry_sms'),
    ],
    [
      _TelegramButton('🛡️ 流量卫士', 'cmd:guard'),
      _TelegramButton('🌐 代理联动', 'cmd:proxy'),
    ],
    [
      _TelegramButton('📡 接码通道状态', 'cmd:tunnel'),
    ],
  ];

  static String _shortAlias(String raw, {int maxLen = 12}) {
    final clean = raw.trim();
    if (clean.length <= maxLen) return clean;
    return '${clean.substring(0, maxLen - 1)}…';
  }

  Future<_TelegramReply> _buildListReply({String? prefixHeader}) async {
    final rawProfiles = await _profiles.listProfiles();
    final profiles = rawProfiles.map(_profileJson).toList(growable: false);
    final savedDefault = await _loadDefault();
    final rules = await _loadKeepAliveRules();
    RemoteCardResourceInfo cardInfo = const RemoteCardResourceInfo();
    try {
      cardInfo = await _profiles.getCardResourceInfo();
    } catch (_) {}
    if (profiles.isEmpty) {
      return _TelegramReply(
        '${prefixHeader != null ? "$prefixHeader\n\n" : ""}⚠️ 未在当前卡槽发现任何 Profile。\n可点击下方按钮下载测试 eSIM 或切换读卡器卡槽。',
        keyboard: const [
          [
            _TelegramButton('🚀 一键下载 Speedtest 测试 eSIM', 'cmd:download_test'),
          ],
          [
            _TelegramButton('🔀 切换读卡器/卡槽', 'cmd:readers'),
            _TelegramButton('📡 基带状态', 'cmd:status'),
          ],
        ],
      );
    }
    final buffer = StringBuffer();
    if (prefixHeader != null && prefixHeader.isNotEmpty) {
      buffer.writeln(prefixHeader);
      buffer.writeln();
    }
    buffer.writeln('📋 卡内所有 eSIM Profile 列表（共 ${profiles.length} 张）：');
    if (_profiles.selectedReaderId != null) {
      buffer.writeln('💳 当前读卡器：${_profiles.selectedReaderId}');
    }
    if (savedDefault != null) {
      buffer.writeln('🏠 默认回滚主卡：【${savedDefault.alias}】');
    }
    if (cardInfo.freeNonVolatileMemoryBytes != null) {
      final kb = (cardInfo.freeNonVolatileMemoryBytes! / 1024.0).toStringAsFixed(1);
      buffer.writeln('💾 芯片剩余空间：$kb KB');
    }
    if (cardInfo.eid != null && cardInfo.eid!.isNotEmpty) {
      buffer.writeln('🆔 EID：${cardInfo.eid}');
    }
    buffer.writeln();

    final rows = <List<_TelegramButton>>[];
    for (var i = 0; i < profiles.length; i++) {
      final p = profiles[i];
      final raw = rawProfiles[i];
      final active = p['enabled'] == true;
      final alias = '${p['alias'] ?? ''}';
      final suffix = '${p['iccidSuffix'] ?? ''}';
      final isDefault = savedDefault != null &&
          (raw.iccid == savedDefault.iccid || alias == savedDefault.alias);
      final kaRule = rules.where((r) => r.iccid == raw.iccid).firstOrNull;
      final icon = active ? '🟢 [当前激活]' : '⚪';
      final defBadge = isDefault ? ' 🏠[主卡]' : '';
      final kaBadge = kaRule != null ? ' 🛡️[每${kaRule.intervalDays}天保号]' : '';
      buffer.writeln('[${i + 1}] $icon $alias (尾号 $suffix)$defBadge$kaBadge');

      final shortName = _shortAlias(alias);
      if (active) {
        rows.add([
          _TelegramButton('📌 设 #${i + 1} $shortName 为主卡', 'cmd:default'),
          _TelegramButton('✏️ 改名 #${i + 1}', 'ren_hint:${i + 1}'),
        ]);
      } else {
        rows.add([
          _TelegramButton('🔄 启用 #${i + 1} $shortName', 'use:${i + 1}'),
          _TelegramButton('⏱️ 5分接码 #${i + 1}', 'use_temp:${i + 1}'),
          _TelegramButton('🗑️ 删 #${i + 1}', 'del:${i + 1}'),
        ]);
      }
    }
    buffer.writeln('\n💡 支持直接发送 eSIM 二维码图片或粘贴 LPA:1\$... 远程下卡；点击「⏱️ 5分接码」切卡后将在 5 分钟后自动切回默认主卡：');
    rows.add(const [
      _TelegramButton('🛡️ 定时保号管理', 'cmd:keepalive'),
      _TelegramButton('🔀 切换卡槽/读卡器', 'cmd:readers'),
    ]);
    rows.add(const [
      _TelegramButton('🚀 下载 Speedtest 测试卡', 'cmd:download_test'),
      _TelegramButton('📡 设备与基带状态', 'cmd:status'),
    ]);
    rows.add(const [
      _TelegramButton('🏠 切回默认主卡', 'cmd:back'),
      _TelegramButton('🔄 刷新列表', 'cmd:list'),
    ]);
    return _TelegramReply(buffer.toString().trimRight(), keyboard: rows);
  }

  Future<_TelegramReply> _buildKeepAliveReply({String? prefixHeader}) async {
    final rawProfiles = await _profiles.listProfiles();
    final rules = await _loadKeepAliveRules();
    final buffer = StringBuffer();
    if (prefixHeader != null && prefixHeader.isNotEmpty) {
      buffer.writeln(prefixHeader);
      buffer.writeln();
    }
    buffer.writeln('🛡️ 定时自动切卡保号管理（Cron Keep-Alive）');
    buffer.writeln('到期后将自动切到目标卡漫游驻网 3 分钟并汇报信号，随后自动切回默认主卡。\n');
    final rows = <List<_TelegramButton>>[];
    for (var i = 0; i < rawProfiles.length; i++) {
      final p = rawProfiles[i];
      final rule = rules.where((r) => r.iccid == p.iccid).firstOrNull;
      final shortName = _shortAlias(p.alias, maxLen: 10);
      if (rule != null) {
        final nextDate = DateTime.fromMillisecondsSinceEpoch(rule.nextRunEpochMillis)
            .toIso8601String()
            .substring(0, 10);
        buffer.writeln('[${i + 1}] 🟢 ${p.alias}：每 ${rule.intervalDays} 天保号（下次：$nextDate）');
        rows.add([
          _TelegramButton('⚡ 立即保号 #${i + 1} $shortName', 'ka_now:${i + 1}'),
          _TelegramButton('❌ 关闭 #${i + 1} 保号', 'ka_off:${i + 1}'),
        ]);
      } else {
        buffer.writeln('[${i + 1}] ⚪ ${p.alias}：未开启定时保号');
        rows.add([
          _TelegramButton('🛡️ 设 #${i + 1} 每90天保号', 'ka_set:${i + 1}:90'),
          _TelegramButton('⚡ 立即保号 #${i + 1}', 'ka_now:${i + 1}'),
        ]);
      }
    }
    buffer.writeln('\n💡 也可发送 `/keepalive <序号> <天数>` 自定义周期（如 `/keepalive 2 30`）。');
    rows.add(const [
      _TelegramButton('📋 返回卡列表', 'cmd:list'),
      _TelegramButton('📡 查看状态', 'cmd:status'),
    ]);
    return _TelegramReply(buffer.toString().trimRight(), keyboard: rows);
  }

  Future<_TelegramReply> _buildReadersReply({String? prefixHeader}) async {
    final readers = await _profiles.listReaders();
    final buffer = StringBuffer();
    if (prefixHeader != null && prefixHeader.isNotEmpty) {
      buffer.writeln(prefixHeader);
      buffer.writeln();
    }
    buffer.writeln('🔀 可用物理卡槽 / eUICC 读卡器列表：');
    final rows = <List<_TelegramButton>>[];
    if (readers.isEmpty) {
      buffer.writeln('⚠️ 当前未检测到可用读卡器。');
    } else {
      for (var i = 0; i < readers.length; i++) {
        final r = readers[i];
        final icon = r.selected ? '🟢 [当前选中]' : '⚪';
        buffer.writeln('[${i + 1}] $icon ${r.name} (${r.id})');
        if (!r.selected) {
          rows.add([
            _TelegramButton('🔀 切换至 [${i + 1}] ${r.name}', 'reader:${i + 1}'),
          ]);
        }
      }
    }
    rows.add(const [
      _TelegramButton('📋 查看当前卡槽列表', 'cmd:list'),
      _TelegramButton('🔄 刷新读卡器', 'cmd:readers'),
    ]);
    return _TelegramReply(buffer.toString().trimRight(), keyboard: rows);
  }
  Future<_TelegramReply> _buildGuardReply({String? header}) async {
    final settings = AppSettings();
    final session = _session ?? await _loadSession();
    final caps = await _dataGuard.capabilities();
    final capabilityText = caps.canEnforce
        ? '✔ 可用${[
            if (caps.telephonyApis) '特权 API',
            if (caps.root) 'root',
          ].map((e) => '（$e）').join()}'
        : '✘ 不可用（需特权构建或 root，否则只能手动关闭数据漫游）';
    final lines = <String>[
      if (header != null && header.isNotEmpty) ...[header, ''],
      '🛡️ 流量卫士（切到国外卡时自动关闭移动数据）',
      '',
      '开关：${settings.dataGuardEnabled ? '🟢 已启用' : '⚪ 已关闭'}',
      '回滚恢复：${settings.dataGuardRestoreOnRevert ? '是（按切卡前状态还原）' : '否'}',
      if (session == null)
        '本次会话：无常驻会话'
      else
        '本次会话：${session.guardEnforced ? '🟢 已锁定订阅 ${session.guardSubscriptionId}' : '⚪ 未锁定'}',
      '强制能力：$capabilityText',
      if (_lastGuardResult != null)
        '最近一次：${_lastGuardResult!.enforced ? '已关闭数据（${_lastGuardResult!.viaApi ? '特权 API' : 'root'}）' : '未强制${_lastGuardResult!.error == null ? '' : '（${_lastGuardResult!.error}）'}'}',
    ];
    return _TelegramReply(
      lines.join('\n'),
      keyboard: [
        [
          _TelegramButton(
            settings.dataGuardEnabled ? '⚪ 关闭流量卫士' : '🛡️ 启用流量卫士',
            'cmd:guard_toggle',
          ),
          _TelegramButton('⚡ 立即锁定当前卡', 'cmd:guard_now'),
        ],
        const [
          _TelegramButton('🌐 代理联动', 'cmd:proxy'),
          _TelegramButton('📡 查看状态', 'cmd:status'),
        ],
      ],
    );
  }

  /// Turns mobile data off right now, for the session's subscription when one is
  /// known, otherwise for the only active subscription.
  Future<String> _applyGuardNow() async {
    final session = _session ?? await _loadSession();
    var subId = session?.guardSubscriptionId ?? -1;
    if (subId < 0) {
      subId = (_networkStatus?.subscriptions ?? const <NetworkStatusSubscription>[])
          .map((s) => s.subscriptionId)
          .firstWhere((id) => id >= 0, orElse: () => -1);
    }
    if (subId < 0) {
      return '⚠️ 未找到可用订阅（无 SIM 或基带未上报），无法锁定移动数据。';
    }
    final result = await _dataGuard.lockdown(subId);
    _lastGuardResult = result;
    if (result.enforced) {
      return '✅ 已关闭订阅 $subId 的移动数据'
          '（${result.viaApi ? '特权 API' : 'root'}）。'
          '${result.before?.roamingEnabled == true ? '数据漫游也一并关闭。' : ''}';
    }
    return '⚠️ 未能关闭数据：'
        '${result.error ?? '当前构建没有强制能力，请手动在系统设置里关闭数据漫游'}。';
  }

  Future<_TelegramReply> _buildProxyReply({String? header}) async {
    final settings = AppSettings();
    _proxyLinkage.updateConfig(
      controllerUrl: settings.proxyControllerUrl,
      secret: settings.proxySecret,
    );
    final conn = await _proxyLinkage.testConnection();
    final groups = conn.alive
        ? await _proxyLinkage.getSelectorGroups()
        : const <ProxyGroupInfo>[];
    final group = groups
        .where((g) => g.name == settings.proxyTargetGroup)
        .firstOrNull;
    final current = group?.now ??
        (conn.alive
            ? await _proxyLinkage.getCurrentNode(settings.proxyTargetGroup)
            : null);
    final connectionText = conn.alive
        ? '🟢 ${conn.version ?? '已连接'}'
        : (conn.error?.contains('unauthorized') == true
            ? '⚪ 未连接（Secret 错误）'
            : '⚪ 未连接（请检查 FlClash / Mihomo 的外部控制是否已开启）');
    final lines = <String>[
      if (header != null && header.isNotEmpty) ...[header, ''],
      '🌐 代理联动（FlClash / Mihomo / sing-box）',
      '',
      '开关：${settings.proxyLinkageEnabled ? '🟢 已启用' : '⚪ 已关闭'}',
      '控制器：${settings.proxyControllerUrl}（$connectionText）',
      '策略组：${settings.proxyTargetGroup}'
          '${conn.alive && group == null ? '（该组不存在）' : ''}',
      if (current != null && current.isNotEmpty) '当前节点：$current',
      if (_lastLinkedProxyNode != null) '本次会话已切至：$_lastLinkedProxyNode',
      '回滚还原：${settings.proxyAutoRestore ? '是' : '否'}',
      '',
      '配置入口：App「短信转发」页 → 切卡自动化卡片；'
      'FlClash 侧需开启「外部控制」。',
    ];
    if (group != null && group.all.isNotEmpty) {
      final shown = group.all.take(8).toList();
      lines
        ..add('')
        ..add('可用节点（发 /proxy_node 序号或名称切换）：');
      for (var i = 0; i < shown.length; i++) {
        lines.add('${i + 1}. ${shown[i]}');
      }
      if (group.all.length > shown.length) {
        lines.add('…共 ${group.all.length} 个');
      }
    }
    final bindings = settings.proxyCustomRules;
    if (bindings.isNotEmpty) {
      lines
        ..add('')
        ..add('已定向绑定的卡（主页长按卡片 → 指定代理节点）：');
      bindings.forEach((key, node) {
        final shown = key.length > 12
            ? '${key.substring(0, 6)}…${key.substring(key.length - 4)}'
            : key;
        lines.add('· $shown → $node');
      });
    }
    return _TelegramReply(
      lines.join('\n'),
      keyboard: [
        [
          _TelegramButton(
            settings.proxyLinkageEnabled ? '⚪ 关闭代理联动' : '🌐 启用代理联动',
            'cmd:proxy_toggle',
          ),
          const _TelegramButton('🔄 刷新节点', 'cmd:proxy'),
        ],
        const [
          _TelegramButton('🛡️ 流量卫士', 'cmd:guard'),
          _TelegramButton('📡 查看状态', 'cmd:status'),
        ],
      ],
    );
  }

  Future<_TelegramReply> _switchProxyNode(String rawArgument) async {
    final settings = AppSettings();
    _proxyLinkage.updateConfig(
      controllerUrl: settings.proxyControllerUrl,
      secret: settings.proxySecret,
    );
    final group = settings.proxyTargetGroup;
    if (!settings.proxyLinkageEnabled) {
      return _TelegramReply(
        '⚪ 代理联动当前是关闭状态，切换节点不会生效。\n先发 /proxy 启用。',
        keyboard: const [
          [_TelegramButton('🌐 代理联动设置', 'cmd:proxy')],
        ],
      );
    }
    if (rawArgument.isEmpty) {
      return await _buildProxyReply(header: '💡 用法：/proxy_node <序号或名称>');
    }
    final info = await _proxyLinkage.getGroup(group);
    if (info == null) {
      return _TelegramReply(
        '⚠️ 未找到策略组【$group】。发 /proxy 查看控制器与分组状态，'
        '或用 /proxy_group <名称> 指定。',
        keyboard: const [
          [_TelegramButton('🌐 代理联动设置', 'cmd:proxy')],
        ],
      );
    }
    String? node = info.all.where((n) => n == rawArgument).firstOrNull;
    final index = int.tryParse(rawArgument);
    if (node == null && index != null && index >= 1 && index <= info.all.length) {
      node = info.all[index - 1];
    }
    node ??= info.all
        .where((n) => n.toLowerCase().contains(rawArgument.toLowerCase()))
        .firstOrNull;
    if (node == null) {
      final listed = info.all.take(8).toList();
      return _TelegramReply(
        '⚠️ 在【$group】里找不到「$rawArgument」。\n'
        '${listed.map((n) => '· $n').join('\n')}',
        keyboard: const [
          [_TelegramButton('🌐 代理联动设置', 'cmd:proxy')],
        ],
      );
    }
    final result = await _proxyLinkage.selectNode(group, node);
    return _TelegramReply(
      result.success
          ? '✅ 已把【$group】切到节点：【$node】'
          : '⚠️ 切换失败：${result.error ?? 'unknown'}',
      keyboard: const [
        [
          _TelegramButton('🌐 代理联动设置', 'cmd:proxy'),
          _TelegramButton('📡 查看状态', 'cmd:status'),
        ],
      ],
    );
  }

  /// Where the SMS path actually goes: this answers "my CF tunnel is configured
  /// where?" from the bot, instead of leaving it to the app UI only.
  Future<_TelegramReply> _buildTunnelReply() async {
    final config = await _smsRelay.loadConfiguration();
    final history = await _smsRelay.loadHistory().catchError(
      (_) => const <SmsHistoryEntry>[],
    );
    final delivered = history.where((h) => h.delivered).length;
    final failed = history.length - delivered;
    final modeLabel = switch (config.mode) {
      SmsRelayMode.cfWorker => 'Cloudflare 加密隧道（Web 接码）',
      SmsRelayMode.telegram => 'Telegram Bot',
      _ => 'Webhook',
    };
    String mask(String? value) {
      if (value == null || value.isEmpty) return '未配置';
      if (value.length <= 8) return value;
      return '${value.substring(0, 6)}…${value.substring(value.length - 4)}';
    }

    final lines = <String>[
      '📡 接码通道状态',
      '',
      '模式：$modeLabel（${config.enabled ? '🟢 已启用' : '⚪ 未启用'}）',
    ];
    if (config.mode == SmsRelayMode.cfWorker) {
      lines
        ..add('Worker 地址：${config.endpoint ?? '未配置'}')
        ..add('通道 ID：${mask(config.cfChannelId)}')
        ..add('通道密钥：${config.cfTokenConfigured ? '🟢 已配置（加密存储）' : '⚪ 未配置'}');
    } else if (config.mode == SmsRelayMode.telegram) {
      lines.add('目标 Chat：${mask(config.telegramChatId)}');
    } else {
      lines
        ..add('回调地址：${config.endpoint ?? '未配置'}')
        ..add('签名密钥：${config.webhookTokenConfigured ? '🟢 已配置' : '⚪ 未配置'}');
    }
    if (config.lastDeliveryAtMillis != null) {
      final at = DateTime.fromMillisecondsSinceEpoch(
        config.lastDeliveryAtMillis!,
      );
      lines.add(
        '最近投递：${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')} '
        '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}',
      );
    }
    if (config.lastDeliveryError != null) {
      lines.add('最近错误：${config.lastDeliveryError}');
    }
    lines
      ..add('历史记录：已转发 $delivered 条，待补发 $failed 条')
      ..add('')
      ..add('配置位置：App「短信转发」页 → 目标通道 → Cloudflare 加密隧道');
    return _TelegramReply(
      lines.join('\n'),
      keyboard: const [
        [
          _TelegramButton('🔄 补发未送达', 'cmd:retry_sms'),
          _TelegramButton('📡 查看状态', 'cmd:status'),
        ],
      ],
    );
  }

  Future<_TelegramReply> _executeTelegramCommand(
    String name,
    String argument,
  ) async {
    try {
      switch (name) {
        case 'start':
        case 'help':
        case 'menu':
          final st = await status();
          return _TelegramReply(
            '🤖 eSIM-Matrix 远程控制主控台\n\n'
            '${_formatStatus(st)}\n\n'
            '👇 请点击下方按钮直接操作，或直接发送 LPA:1\$... 激活码远程下卡：',
            keyboard: _mainMenuKeyboard(),
          );
        case 'list':
          return await _buildListReply();
        case 'status':
          return _TelegramReply(
            _formatStatus(await status()),
            keyboard: const [
              [
                _TelegramButton('🔄 刷新信号与电量状态', 'cmd:status'),
                _TelegramButton('📋 卡内 eSIM 列表', 'cmd:list'),
              ],
              [
                _TelegramButton('🛡️ 定时保号管理', 'cmd:keepalive'),
                _TelegramButton('🔀 切换卡槽/读卡器', 'cmd:readers'),
              ],
              [
                _TelegramButton('🏠 切回默认主卡', 'cmd:back'),
                _TelegramButton('🔄 补发未送达短信', 'cmd:retry_sms'),
              ],
            ],
          );
        case 'default':
          final result = await setDefaultProfile();
          return _TelegramReply(
            '✅ 默认回滚主卡已设定为：【${result['defaultProfile']}】（尾号 ${result['iccidSuffix']}）。',
            keyboard: const [
              [
                _TelegramButton('📋 查看卡内列表', 'cmd:list'),
                _TelegramButton('📡 查看基带状态', 'cmd:status'),
              ],
            ],
          );
        case 'use':
        case 'use_temp':
          final isTemp = name == 'use_temp';
          if (argument.isEmpty) {
            return await _buildListReply(
              prefixHeader: '💡 请点击下方按钮选择要启用切换的 eSIM 卡位：',
            );
          }
          final slotIndex = int.tryParse(argument);
          String targetSelector = argument;
          if (slotIndex != null) {
            final rawProfiles = await _profiles.listProfiles();
            if (slotIndex < 1 || slotIndex > rawProfiles.length) {
              return _TelegramReply(
                '⚠️ 卡位序号 #$slotIndex 无效！当前共有 ${rawProfiles.length} 个卡位，请从下方列表点击切换：',
                keyboard: const [
                  [_TelegramButton('📋 打开卡内列表', 'cmd:list')],
                ],
              );
            }
            targetSelector = rawProfiles[slotIndex - 1].iccid;
          }
          try {
            unawaited(
              _sendTelegramText(
                isTemp
                    ? '⏱️ 已收到临时接码切卡指令（5 分钟后将自动切回默认主卡），正在切换芯片...'
                    : '⚡ 已收到切卡指令，正在向 eUICC 芯片下发切换指令...',
              ).catchError((Object _) {}),
            );
            final result = await switchProfile(
              targetSelector,
              duration: isTemp ? sessionDuration : null,
            );
            if (result['state'] == 'already_active') {
              return _TelegramReply(
                'ℹ️ 【${result['target']}】当前已处于激活状态，无需重复切换。',
                keyboard: const [
                  [
                    _TelegramButton('📡 查看基带状态', 'cmd:status'),
                    _TelegramButton('📋 卡内列表', 'cmd:list'),
                  ],
                ],
              );
            }
            return _TelegramReply(
              isTemp
                  ? '⏱️ 正在临时切换至：【${result['target']}】（5 分钟后将自动切回默认主卡）...\n正在等待基带漫游搜网驻留，挂上基站后会自动通知您。'
                  : '🔄 正在切换至：【${result['target']}】...\n卡片已切换，正在等待基带漫游搜网驻留，挂上基站后会自动通知您。',
              keyboard: const [
                [
                  _TelegramButton('📡 查看搜网进度', 'cmd:status'),
                  _TelegramButton('🏠 立即切回主卡', 'cmd:back'),
                ],
              ],
            );
          } on RemoteGatewayException catch (e) {
            if (e.code == 'waiting_for_baseband') {
              return _TelegramReply(
                '⏳ 上一次切卡还在等待基带漫游驻网（通常需 15~60 秒），卡片正在与基站建立连接，请稍候...',
                keyboard: const [
                  [
                    _TelegramButton('📡 查看当前基带状态', 'cmd:status'),
                    _TelegramButton('🏠 强制切回主卡', 'cmd:back'),
                  ],
                ],
              );
            }
            if (e.code == 'switch_in_progress') {
              return const _TelegramReply('⏳ 当前已有切卡操作正在执行中，请稍候...');
            }
            if (e.code == 'profile_switch_cooldown') {
              return _TelegramReply(
                '⏳ 芯片正在完成硬件复位，请稍候约 5 秒再点击切换...',
                keyboard: [
                  [
                    _TelegramButton(
                      '🔄 重试切换 ($argument)',
                      '${isTemp ? "use_temp" : "use"}:$argument',
                    ),
                  ],
                ],
              );
            }
            rethrow;
          }
        case 'rename':
          final parts = argument.trim().split(RegExp(r'\s+'));
          if (parts.length < 2) {
            return const _TelegramReply(
              '✏️ 修改卡片备注名用法：\n'
              '发送 `/rename <序号或原名称> <新名称>`\n'
              '例如：`/rename 2 英国主力 +44`',
              keyboard: [
                [_TelegramButton('📋 查看卡内列表', 'cmd:list')],
              ],
            );
          }
          final selector = parts.first;
          final newName = argument.trim().substring(selector.length).trim();
          final renamed = await renameProfile(selector, newName);
          return await _buildListReply(
            prefixHeader: '✅ 卡片【${renamed['oldAlias']}】已成功重命名为：【${renamed['newAlias']}】！',
          );
        case 'keepalive':
          if (argument.trim().isEmpty) {
            return await _buildKeepAliveReply();
          }
          final kaParts = argument.trim().split(RegExp(r'\s+'));
          final kaSelector = kaParts.first;
          final kaArg = kaParts.length > 1 ? kaParts[1].toLowerCase() : '90';
          final days = (kaArg == 'off' || kaArg == '0' || kaArg == 'stop')
              ? 0
              : (int.tryParse(kaArg) ?? 90);
          final res = await setKeepAliveRule(kaSelector, intervalDays: days);
          final msg = days <= 0
              ? '✅ 已关闭【${res['target']}】的定时保号规则。'
              : '🛡️ 已为【${res['target']}】设置每 ${res['intervalDays']} 天自动切卡驻网保号！';
          return await _buildKeepAliveReply(prefixHeader: msg);
        case 'keepalive_now':
          if (argument.trim().isEmpty) {
            return await _buildKeepAliveReply();
          }
          unawaited(
            _sendTelegramText('🛡️ 正在启动立即保号：切换至目标卡并驻留基站 3 分钟，随后将自动切回默认主卡...')
                .catchError((Object _) {}),
          );
          final kaNow = await runKeepAliveNow(argument.trim());
          return _TelegramReply(
            '🛡️ 保号驻网已启动：【${kaNow['target']}】\n'
            '系统正在等待漫游基站注册，并将在 3 分钟后自动为您切回默认主卡。',
            keyboard: const [
              [
                _TelegramButton('📡 查看搜网进度', 'cmd:status'),
                _TelegramButton('🏠 立即切回主卡', 'cmd:back'),
              ],
            ],
          );
        case 'readers':
          return await _buildReadersReply();
        case 'reader':
          if (argument.trim().isEmpty) {
            return await _buildReadersReply();
          }
          final sel = await selectReader(argument.trim());
          return await _buildListReply(
            prefixHeader: '🔀 已切换当前活动读卡器为：【${sel['name']}】(${sel['id']})',
          );
        case 'retry_sms':
          final count = await _retryFailedSms(automatic: false);
          return _TelegramReply(
            count > 0
                ? '✅ 已成功补发 $count 条之前未送达的短信！'
                : 'ℹ️ 当前没有待补发的失败短信记录。',
            keyboard: const [
              [
                _TelegramButton('📡 查看状态', 'cmd:status'),
                _TelegramButton('📋 卡内列表', 'cmd:list'),
              ],
            ],
          );
        case 'guard':
          return await _buildGuardReply();
        case 'guard_toggle':
          final guardSettings = AppSettings();
          await guardSettings.setDataGuardEnabled(!guardSettings.dataGuardEnabled);
          return await _buildGuardReply(
            header: guardSettings.dataGuardEnabled ? '✅ 流量卫士已启用' : '⚪ 流量卫士已关闭',
          );
        case 'guard_now':
          final applied = await _applyGuardNow();
          return _TelegramReply(
            applied,
            keyboard: const [
              [
                _TelegramButton('🛡️ 流量卫士设置', 'cmd:guard'),
                _TelegramButton('📡 查看状态', 'cmd:status'),
              ],
            ],
          );
        case 'proxy':
          return await _buildProxyReply();
        case 'proxy_toggle':
          final proxySettings = AppSettings();
          await proxySettings.setProxyLinkageEnabled(
            !proxySettings.proxyLinkageEnabled,
          );
          return await _buildProxyReply(
            header: proxySettings.proxyLinkageEnabled
                ? '✅ 代理联动已启用'
                : '⚪ 代理联动已关闭',
          );
        case 'proxy_group':
          if (argument.trim().isEmpty) {
            return await _buildProxyReply(
              header: '💡 用法：/proxy_group <策略组名>，例如 /proxy_group PROXY',
            );
          }
          await AppSettings().setProxyTargetGroup(argument.trim());
          return await _buildProxyReply(
            header: '✅ 目标策略组已设为【${argument.trim()}】',
          );
        case 'proxy_node':
          return await _switchProxyNode(argument.trim());
        case 'tunnel':
          return await _buildTunnelReply();
        case 'announce':
          return await _executeTelegramAnnouncement(argument);
        case 'back':
          final result = await revertProfile();
          return _TelegramReply(
            '✅ 已成功切回默认主卡：【${result['profile']}】。',
            keyboard: const [
              [
                _TelegramButton('📡 查看基带状态', 'cmd:status'),
                _TelegramButton('📋 卡内 eSIM 列表', 'cmd:list'),
              ],
            ],
          );
        case 'download':
          if (argument.isEmpty) {
            return const _TelegramReply(
              '📥 远程下卡用法：\n'
              '• 直接在聊天框粘贴发送 LPA:1\$smdp地址\$匹配码\n'
              '• 或发送 /download LPA:1\$rsp.truphone.com\$QRF-SPEEDTEST\n'
              '• 或直接点击下方按钮一键下载 Speedtest 公开测试 eSIM：',
              keyboard: [
                [
                  _TelegramButton('🚀 一键下载 Speedtest 公开测试 eSIM', 'cmd:download_test'),
                ],
                [
                  _TelegramButton('📋 返回卡内列表', 'cmd:list'),
                ],
              ],
            );
          }
          return await _runTelegramDownload(argument, isSpeedtest: argument == speedtestActivationCode);
        case 'download_test':
          return await _runTelegramDownload(speedtestActivationCode, isSpeedtest: true);
        case 'delete':
          if (argument.isEmpty) {
            return await _buildListReply(
              prefixHeader: '🗑️ 请在下方列表点击对应未激活卡片右侧的「🗑️ 删 #序号」发起安全二步删卡：',
            );
          }
          final slotIndex = int.tryParse(argument);
          String targetSelector = argument;
          if (slotIndex != null) {
            final rawProfiles = await _profiles.listProfiles();
            if (slotIndex < 1 || slotIndex > rawProfiles.length) {
              return _TelegramReply(
                '⚠️ 卡位序号 #$slotIndex 无效！当前共有 ${rawProfiles.length} 个卡位。',
                keyboard: const [
                  [_TelegramButton('📋 查看卡内列表', 'cmd:list')],
                ],
              );
            }
            targetSelector = rawProfiles[slotIndex - 1].iccid;
          }
          try {
            final result = await requestDeleteProfile(targetSelector);
            final token = '${result['token']}';
            final targetName = '${result['target']}';
            return _TelegramReply(
              '⚠️【高危操作警告：永久删除 eSIM 卡片】⚠️\n\n'
              '即将从物理 eUICC 芯片中彻底抹除以下卡片：\n'
              '• 卡片名称：【$targetName】\n'
              '• ICCID：${result['iccid']}\n'
              '• 安全确认码：$token（2 分钟内有效）\n\n'
              '🚨 删除后该 Profile 将从芯片中擦除并自动向服务器发送释放通知。\n'
              '请点击下方按钮确认或取消（也可发送 /delete_confirm $token）：',
              keyboard: [
                [
                  _TelegramButton('⚠️ 确认永久删除【${_shortAlias(targetName, maxLen: 10)}】', 'del_ok:$token'),
                ],
                [
                  const _TelegramButton('❌ 取消删除', 'del_cancel'),
                ],
              ],
            );
          } on RemoteGatewayException catch (e) {
            if (e.code == 'cannot_delete_active_profile') {
              return const _TelegramReply(
                '⚠️ 无法删除当前正在激活使用的卡片！请先切换至其他卡或切回主卡后再删除。',
                keyboard: [
                  [
                    _TelegramButton('🏠 切回默认主卡', 'cmd:back'),
                    _TelegramButton('📋 查看卡列表', 'cmd:list'),
                  ],
                ],
              );
            }
            if (e.code == 'cannot_delete_default_profile') {
              return const _TelegramReply(
                '⚠️ 该卡片当前被设为默认回滚主卡！请先启用其他卡并设为主卡后再删除。',
                keyboard: [
                  [_TelegramButton('📋 查看卡列表', 'cmd:list')],
                ],
              );
            }
            rethrow;
          }
        case 'delete_confirm':
          if (argument.isEmpty) {
            return const _TelegramReply('💡 用法提示：发送 /delete_confirm <4位确认码>，或直接在删卡警告消息下点击「⚠️ 确认永久删除」按钮。');
          }
          try {
            unawaited(
              _sendTelegramText('⏳ 正在从 eUICC 芯片抹除卡片并向服务器同步释放通知...')
                  .catchError((Object _) {}),
            );
            final result = await confirmDeleteProfile(argument);
            return _TelegramReply(
              '🗑️ 卡片【${result['target']}】(ICCID: ${result['iccid']}) 已成功从物理 eUICC 芯片中彻底删除！',
              keyboard: const [
                [
                  _TelegramButton('📋 查看最新卡列表', 'cmd:list'),
                  _TelegramButton('🚀 下载 Speedtest 测试卡', 'cmd:download_test'),
                ],
              ],
            );
          } on RemoteGatewayException catch (e) {
            if (e.code == 'delete_token_expired') {
              return const _TelegramReply(
                '❌ 确认码已过期（有效期 2 分钟），删除操作已安全取消。',
                keyboard: [
                  [_TelegramButton('📋 返回卡内列表', 'cmd:list')],
                ],
              );
            }
            if (e.code == 'invalid_delete_token') {
              return const _TelegramReply(
                '❌ 确认码错误，删除操作未执行。',
                keyboard: [
                  [_TelegramButton('📋 返回卡内列表', 'cmd:list')],
                ],
              );
            }
            rethrow;
          }
        case 'delete_cancel':
          _pendingDeletion = null;
          return const _TelegramReply(
            '✅ 已安全取消删卡操作，卡片保留。',
            keyboard: [
              [_TelegramButton('📋 返回卡内 eSIM 列表', 'cmd:list')],
            ],
          );
      }
    } catch (error) {
      _log.warning('Telegram command error: $error');
      return _TelegramReply(
        '❌ 操作失败：$error',
        keyboard: _mainMenuKeyboard(),
      );
    }
    return const _TelegramReply('❓ 未识别的指令，请使用下方菜单：', keyboard: []);
  }

  Future<_TelegramReply> _runTelegramDownload(
    String activationCode, {
    required bool isSpeedtest,
  }) async {
    try {
      unawaited(
        _sendTelegramText(
          isSpeedtest
              ? '⏳ [Speedtest 公开测试 eSIM]\n正在连接 Truphone SM-DP+ 服务器 (rsp.truphone.com) 下载并写入 eUICC 芯片（通常需 15~45 秒），请稍候...'
              : '⏳ 已收到远程下卡指令，正在连接 SM-DP+ 服务器下载并写入 eUICC 芯片（通常需 15~45 秒），请稍候...',
        ).catchError((Object _) {}),
      );
      final result = await downloadProfile(activationCode);
      final installedIccid = '${result['iccid'] ?? ''}';
      int? newSlot;
      try {
        final all = await _profiles.listProfiles();
        for (var i = 0; i < all.length; i++) {
          if (all[i].iccid == installedIccid) {
            newSlot = i + 1;
            break;
          }
        }
      } catch (_) {}
      final title = isSpeedtest
          ? '🚀 Speedtest 公开测试 eSIM 下载并安装成功！'
          : '✅ eSIM Profile 下载并安装成功！';
      final slotLine = newSlot != null ? '\n• 卡位序号：#$newSlot' : '';
      return _TelegramReply(
        '$title\n• ICCID：$installedIccid$slotLine\n\n👇 可直接点击下方按钮测试启用或测试删除该卡片：',
        keyboard: [
          if (newSlot != null)
            [
              _TelegramButton('🔄 立即启用 (#$newSlot)', 'use:$newSlot'),
              _TelegramButton('🗑️ 测试删除此卡 (#$newSlot)', 'del:$newSlot'),
            ],
          const [
            _TelegramButton('📋 查看最新卡内列表', 'cmd:list'),
          ],
        ],
      );
    } catch (e) {
      return _TelegramReply(
        '❌ ${isSpeedtest ? "Speedtest 测试卡" : "eSIM"}下载失败：$e',
        keyboard: const [
          [
            _TelegramButton('🔄 重试下载 Speedtest 测试卡', 'cmd:download_test'),
            _TelegramButton('📋 查看卡内列表', 'cmd:list'),
          ],
        ],
      );
    }
  }

  String _formatStatus(Map<String, Object?> value) {
    final session = value['session'];
    final network = value['network'];
    final card = value['card'];
    final device = value['device'];
    final lines = <String>[];
    lines.add('📱 网关状态：${value['gateway'] == 'running' ? '🟢 正在运行' : '⚪ 已停止'}');
    if (value['selectedReader'] != null) {
      lines.add('💳 当前卡槽/读卡器：${value['selectedReader']}');
    }
    if (value['defaultProfile'] != null) {
      lines.add('🏠 默认主卡：${value['defaultProfile']}');
    }
    if (card is Map) {
      final freeBytes = card['freeNonVolatileMemoryBytes'];
      final eid = card['eid'];
      if (freeBytes is int) {
        lines.add('💾 芯片剩余空间：${(freeBytes / 1024.0).toStringAsFixed(1)} KB');
      }
      if (eid is String && eid.isNotEmpty) {
        lines.add('🆔 EID：$eid');
      }
    }
    final registeredChats = value['registeredChats'];
    if (registeredChats is int && registeredChats > 0) {
      lines.add('📣 已登记公告会话：$registeredChats 个');
    }
    if (device is Map && device['batteryPercent'] != null) {
      final pct = device['batteryPercent'];
      final charging = device['charging'] == true;
      final source = device['powerSource'] ?? (charging ? '充电中' : '电池');
      final temp = device['temperatureCelsius'];
      final net = device['networkType'];
      final tempStr = temp is num ? ' · 🌡️ ${temp.toStringAsFixed(1)}°C' : '';
      final netStr = net is String && net.isNotEmpty ? ' · 🌐 $net' : '';
      lines.add('🔋 宿主机电量：$pct% (${charging ? "⚡ $source" : "⚠️ 未充电"})$tempStr$netStr');
    }
    if (session is Map) {
      final rem = session['remainingSeconds'];
      final modeStr = rem is int && rem > 0 ? '⏱️ 剩余 ${rem}s 自动回主卡' : '长驻生效中';
      final stateStr = session['state'] == 'waiting_for_service'
          ? '⏳ 基带搜网握手中 ($modeStr)'
          : '🟢 已就绪 ($modeStr)';
      lines.add('\n📌 当前卡片：【${session['target']}】（$stateStr）');
    }
    if (network is Map) {
      lines.add('\n📡 SIM ${network['slot']} 基带状态：');
      lines.add('• 注册：${network['registration']}${network['roaming'] == true ? ' (漫游中)' : ''}');
      if (network['carrier'] != null) lines.add('• 运营商：${network['carrier']}');
      if (network['signalDbm'] != null) lines.add('• 信号强度：${network['signalDbm']} dBm');
    } else {
      lines.add('\n📡 基带网络状态：暂无活动订阅或正在搜网');
    }
    if (value['proxy'] is Map) {
      final proxy = value['proxy'] as Map;
      if (proxy['enabled'] == true) {
        final node = proxy['currentNode'] ?? proxy['lastLinkedNode'];
        final nodeStr = node != null && node.toString().isNotEmpty ? '【$node】' : '已就绪';
        lines.add('\n🌐 代理联动 (FlClash / Mihomo)：🟢 $nodeStr (策略组: ${proxy['targetGroup']})');
      } else {
        lines.add('\n🌐 代理联动：⚪ 未启用');
      }
    }
    if (value['dataGuard'] is Map) {
      final guard = value['dataGuard'] as Map;
      if (guard['enabled'] == true) {
        final enforced = guard['enforced'] == true;
        lines.add(
          '\n🛡️ 流量卫士：${enforced ? '🟢 移动数据已锁定关闭' : '⚪ 未锁定（切卡后自动生效）'}',
        );
      } else {
        lines.add('\n🛡️ 流量卫士：⚪ 未启用');
      }
    }
    return lines.join('\n');
  }

  Future<void> _sendTelegramText(String text) =>
      _sendTelegramReply(_TelegramReply(text));

  /// The name a chat is shown with in the subscriber list.
  static String _telegramDisplayName(Map sender) {
    final first = '${sender['first_name'] ?? ''}'.trim();
    final last = '${sender['last_name'] ?? ''}'.trim();
    final username = '${sender['username'] ?? ''}'.trim();
    final full = '$first $last'.trim();
    if (full.isNotEmpty) return full;
    if (username.isNotEmpty) return '@$username';
    return 'Chat ${sender['id']}';
  }

  /// Sends a plain message to one specific chat.
  ///
  /// Returns false when Telegram rejected the message, so a broadcast can
  /// count what actually got through.
  Future<bool> _sendTelegramTextTo(
    String token,
    String chatId,
    String text,
  ) async {
    final uri = Uri.https('api.telegram.org', '/bot$token/sendMessage');
    final request = await _telegramHttpClient
        .postUrl(uri)
        .timeout(const Duration(seconds: 10));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'chat_id': chatId, 'text': text}));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) return false;
    final decoded = jsonDecode(body);
    return decoded is Map && decoded['ok'] == true;
  }

  /// The text of a release notice, used by the automatic update notification
  /// and by the `/announce` command.
  static String _formatReleaseNotice(UpdateInfo update) {
    final changelog = update.changelog ?? '';
    return '🆕 eSIM-Matrix 有新版本：${update.version} (build ${update.build})\n'
        '${changelog.isEmpty ? '' : '$changelog\n'}'
        '下载地址：${update.downloadUrl ?? update.url}';
  }

  /// Announces a message to every chat the bot knows about.
  ///
  /// The owner chat is left out of the broadcast because the caller delivers
  /// the announcement there itself.
  Future<int> _broadcastTelegramText(
    String text, {
    String? excludeChatId,
  }) async {
    final token = _configuration?.telegramToken;
    if (token == null || token.isEmpty) return 0;
    final targets = await TelegramRegistry.instance.announcementTargets(
      excludeChatId: excludeChatId,
    );
    var delivered = 0;
    for (final chatId in targets) {
      try {
        if (await _sendTelegramTextTo(token, chatId, text)) delivered++;
      } catch (e) {
        _log.warning('Broadcast to chat $chatId failed: $e');
      }
    }
    return delivered;
  }

  /// Sends a notice to the owner chat and to every other registered chat.
  Future<void> _announceToEveryone(String notice) async {
    final owner = _configuration?.telegramChatId;
    final delivered = await _broadcastTelegramText(notice, excludeChatId: owner);
    await _sendTelegramReply(_TelegramReply(notice));
    _log.info('Announcement delivered to $delivered registered chats');
  }

  /// Runs the `/announce` command.
  ///
  /// Without an argument the newest release from the update feed is
  /// announced, so one command tells every registered chat about a new
  /// version.
  Future<_TelegramReply> _executeTelegramAnnouncement(String argument) async {
    final text = argument.trim();
    String notice;
    if (text.isEmpty) {
      final update = await UpdateNotifier.check(manual: true);
      if (update == null) {
        return const _TelegramReply(
          'ℹ️ 更新源里没有更新的发布，暂时无法生成升级公告。\n'
          '也可以直接发送：/announce <公告内容>',
        );
      }
      notice = _formatReleaseNotice(update);
    } else {
      notice = text;
    }
    final owner = _configuration?.telegramChatId;
    final delivered = await _broadcastTelegramText(notice, excludeChatId: owner);
    return _TelegramReply(
      '$notice\n\n📣 已同时推送给另外 $delivered 个已登记会话。',
    );
  }

  Future<void> _sendTelegramReply(_TelegramReply reply) async {
    final config = _configuration;
    final token = config?.telegramToken;
    final chatId = config?.telegramChatId;
    if (token == null || chatId == null) return;
    final uri = Uri.https('api.telegram.org', '/bot$token/sendMessage');
    final request = await _telegramHttpClient.postUrl(uri).timeout(const Duration(seconds: 10));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(reply.toPayload(chatId)));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const RemoteGatewayException('telegram_send_failed');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['ok'] != true) {
      throw const RemoteGatewayException('telegram_send_failed');
    }
  }

  Map<String, Object?> _profileJson(RemoteProfileEntry profile) => {
    'alias': profile.alias,
    'enabled': profile.enabled,
    'iccidSuffix': _suffix(profile.iccid),
    'iccidPrefix': profile.iccid.length >= 6
        ? profile.iccid.substring(0, 6)
        : profile.iccid,
  };

  /// One round trip for the web console: everything a dashboard repaint needs,
  /// ordered so a slow subsystem (Clash, SMS store) cannot fail the whole call.
  Future<Map<String, Object?>> _dashboardPayload() async {
    final statusMap = await status();
    final profiles = await listProfiles().catchError(
      (Object _) => const <Map<String, Object?>>[],
    );
    final history = await _smsRelay.loadHistory().catchError(
      (Object _) => const <SmsHistoryEntry>[],
    );
    final sortedHistory = history.toList()
      ..sort((a, b) => b.receivedAtMillis.compareTo(a.receivedAtMillis));
    final guardCapabilities = await _dataGuard.capabilities();
    final guardStates = await _dataGuard.status();
    return {
      'status': statusMap,
      'profiles': profiles,
      'messages': sortedHistory.take(20).map((entry) => {
            'sender': entry.sender,
            'body': entry.body,
            if (entry.otp != null) 'otp': entry.otp,
            'receivedAtMillis': entry.receivedAtMillis,
            'delivered': entry.delivered,
            if (entry.errorCode != null) 'errorCode': entry.errorCode,
          }).toList(growable: false),
      'dataGuard': {
        'capabilities': guardCapabilities.toJson(),
        'subscriptions': guardStates.map((s) => s.toJson()).toList(growable: false),
      },
      'generatedAtMillis': DateTime.now().millisecondsSinceEpoch,
    };
  }

  static String _suffix(String iccid) =>
      iccid.length <= 4 ? iccid : iccid.substring(iccid.length - 4);

  static String _errorCode(Object error) =>
      error is RemoteGatewayException ? error.code : 'control_error';

  Future<T> _serialize<T>(Future<T> Function() action) {
    final previous = _operationTail;
    final done = Completer<void>();
    _operationTail = done.future;
    return () async {
      try {
        await previous;
      } catch (_) {}
      try {
        return await action();
      } finally {
        done.complete();
      }
    }();
  }


  static const String _dashboardHtml = r'''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0f1216">
<title>eSIM-Matrix Web Console</title>
<style>
:root{color-scheme:dark;--bg:#0f1216;--panel:#171b22;--panel2:#1e232c;--fg:#e9eef7;--muted:#98a2b3;--border:#2a303b;--accent:#7aa2ff;--ok:#3ddc97;--warn:#ffb84d;--err:#ff6b6b;--radius:16px}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(120% 90% at 50% -10%,#1b2230 0%,var(--bg) 55%) no-repeat;background-color:var(--bg);color:var(--fg);font:15px/1.55 system-ui,-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:1080px;margin:0 auto;padding:20px 16px 64px}
header{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:18px}
.logo{font-size:1.2rem;font-weight:650;letter-spacing:.4px}
.logo i{color:var(--accent);font-style:normal}
.pill{font-size:.72rem;padding:4px 10px;border-radius:999px;border:1px solid var(--border);background:var(--panel);color:var(--muted);white-space:nowrap}
.pill.ok{color:var(--ok);border-color:rgba(61,220,151,.35);background:rgba(61,220,151,.08)}
.pill.bad{color:var(--err);border-color:rgba(255,107,107,.32);background:rgba(255,107,107,.08)}
.pill.warn{color:var(--warn);border-color:rgba(255,184,77,.32);background:rgba(255,184,77,.08)}
.grid{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(300px,1fr))}
.card{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--border);border-radius:var(--radius);padding:16px}
.card h2{margin:0 0 12px;font-size:.76rem;font-weight:600;letter-spacing:.09em;text-transform:uppercase;color:var(--muted)}
.kv{display:flex;justify-content:space-between;gap:12px;padding:7px 0;border-bottom:1px dashed rgba(255,255,255,.06);font-size:.9rem}
.kv:last-child{border-bottom:0}
.kv span:first-child{color:var(--muted)}
.kv b{font-weight:600;text-align:right}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.8rem}
button{font:inherit;font-size:.84rem;border-radius:10px;border:1px solid var(--border);background:var(--panel2);color:var(--fg);padding:8px 12px;cursor:pointer;transition:border-color .15s,color .15s}
button:hover:not(:disabled){border-color:var(--accent);color:#cddcff}
button.primary{background:rgba(122,162,255,.14);border-color:rgba(122,162,255,.45);color:#cddcff}
button.danger{background:rgba(255,107,107,.1);border-color:rgba(255,107,107,.32);color:#ffc7c7}
button:disabled{opacity:.45;cursor:not-allowed}
input,select{font:inherit;font-size:.9rem;width:100%;border-radius:10px;border:1px solid var(--border);background:#12161c;color:var(--fg);padding:9px 11px}
label{display:block;font-size:.76rem;color:var(--muted);margin:10px 0 6px}
.row{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}
.signal{display:inline-flex;align-items:flex-end;gap:2px;height:13px}
.signal i{width:3px;border-radius:1px;background:var(--border)}
.signal i.on{background:var(--ok)}
.big{font-size:1.45rem;font-weight:650;letter-spacing:.3px}
.profile{display:flex;align-items:center;gap:12px;padding:12px;border:1px solid var(--border);border-radius:13px;background:#12161c;margin-bottom:10px}
.profile:last-child{margin-bottom:0}
.profile.active{border-color:rgba(61,220,151,.45);box-shadow:inset 0 0 0 1px rgba(61,220,151,.14)}
.profile .flag{font-size:1.5rem;line-height:1}
.profile .meta{flex:1;min-width:0}
.profile .meta div{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.profile .meta small{color:var(--muted);font-size:.74rem}
.profile .acts{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}
.msg{padding:11px;border-radius:11px;background:#12161c;border:1px solid var(--border);margin-bottom:9px}
.msg .top{display:flex;justify-content:space-between;gap:8px;font-size:.74rem;color:var(--muted);margin-bottom:5px}
.msg .body{font-size:.87rem;overflow-wrap:anywhere;white-space:pre-wrap}
.otp{display:inline-block;font-family:ui-monospace,monospace;font-size:.98rem;letter-spacing:.14em;color:#c8f7dd;background:rgba(61,220,151,.12);border:1px solid rgba(61,220,151,.35);border-radius:8px;padding:1px 8px;cursor:pointer}
.toast{position:fixed;left:50%;bottom:22px;transform:translate(-50%,20px);background:#20262f;border:1px solid var(--border);border-radius:12px;padding:10px 16px;font-size:.84rem;opacity:0;pointer-events:none;transition:.25s;z-index:9;max-width:92vw}
.toast.show{opacity:1;transform:translate(-50%,0)}
.toast.err{border-color:rgba(255,107,107,.5);color:#ffd2d2}
.hide{display:none!important}
.muted{color:var(--muted);font-size:.82rem}
</style>
</head>
<body>
<main>
<header>
  <div class="logo">eSIM<i>·</i>Matrix</div>
  <span id="gwPill" class="pill">连接中…</span>
  <span id="guardPill" class="pill hide">流量卫士</span>
  <span id="proxyPill" class="pill hide">代理</span>
  <span style="flex:1"></span>
  <button id="refresh">刷新</button>
</header>

<div id="login" class="card">
  <h2>API Token</h2>
  <input id="token" type="password" placeholder="Bearer token" autocomplete="off">
  <div class="row"><button class="primary" id="loginBtn">进入控制台</button></div>
  <p class="muted" style="margin:10px 0 0">令牌仅保存在当前标签页的 sessionStorage 中。</p>
</div>

<div id="app" class="hide">
  <div class="grid">
    <div class="card"><h2>当前会话</h2><div id="sessionBox"></div></div>
    <div class="card"><h2>基带与设备</h2><div id="deviceBox"></div></div>
    <div class="card"><h2>流量卫士</h2><div id="guardBox"></div></div>
    <div class="card"><h2>代理联动</h2><div id="proxyBox"></div></div>
  </div>

  <div class="card" style="margin-top:14px">
    <h2>Profile 矩阵</h2>
    <div id="profilesBox"></div>
  </div>

  <div class="grid" style="margin-top:14px">
    <div class="card"><h2>短信与验证码</h2><div id="smsBox"></div></div>
    <div class="card"><h2>高级操作</h2><div id="advancedBox"></div></div>
  </div>
</div>
<div id="toast" class="toast"></div>
</main>
<script>
const $=(s,r=document)=>r.querySelector(s);
const FLAG={US:'🇺🇸',HK:'🇭🇰',TW:'🇹🇼',JP:'🇯🇵',SG:'🇸🇬',GB:'🇬🇧',EE:'🇪🇪',DE:'🇩🇪',CA:'🇨🇦',AU:'🇦🇺',FR:'🇫🇷',KR:'🇰🇷',NL:'🇳🇱',TH:'🇹🇭',MY:'🇲🇾',PH:'🇵🇭',VN:'🇻🇳',CN:'🇨🇳',IN:'🇮🇳',TR:'🇹🇷',BR:'🇧🇷',RU:'🇷🇺'};
const KEYWORDS=[[/(?:^|[^a-z])(us|usa|america)(?:[^a-z]|$)|美国|美卡|saily|t-mobile|verizon|at&t|洛杉矶|硅谷|纽约/i,'US'],[/hong\s*kong|香港|港卡|csl|clubsim|(?<![a-z])hk(?![a-z])/i,'HK'],[/taiwan|台湾|中華|中华|(?<![a-z])tw(?![a-z])/i,'TW'],[/japan|日本|docomo|softbank|(?<![a-z])jp(?![a-z])/i,'JP'],[/singapore|新加坡|(?<![a-z])sg(?![a-z])/i,'SG'],[/estonia|爱沙尼亚|elisa|(?<![a-z])ee(?![a-z])/i,'EE'],[/united\s*kingdom|britain|英国|giffgaff|vodafone|(?<![a-z])(uk|gb)(?![a-z])/i,'GB'],[/germany|德国|telekom|(?<![a-z])de(?![a-z])/i,'DE'],[/canada|加拿大|(?<![a-z])ca(?![a-z])/i,'CA'],[/australia|澳洲|澳大利亚|(?<![a-z])au(?![a-z])/i,'AU'],[/france|法国|(?<![a-z])fr(?![a-z])/i,'FR'],[/korea|韩国|(?<![a-z])kr(?![a-z])/i,'KR'],[/netherlands|荷兰|(?<![a-z])nl(?![a-z])/i,'NL'],[/thailand|泰国|(?<![a-z])th(?![a-z])/i,'TH'],[/malaysia|马来|(?<![a-z])my(?![a-z])/i,'MY'],[/philippines|菲律宾|(?<![a-z])ph(?![a-z])/i,'PH'],[/vietnam|越南|(?<![a-z])vn(?![a-z])/i,'VN'],[/中国|china|(?<![a-z])cn(?![a-z])/i,'CN']];
const PREFIX={'204':'NL','208':'FR','214':'ES','222':'IT','228':'CH','232':'AT','234':'GB','235':'GB','238':'DK','240':'SE','242':'NO','244':'FI','248':'EE','250':'RU','255':'UA','262':'DE','268':'PT','272':'IE','274':'IS','276':'AL','278':'MT','280':'CY','282':'GE','286':'TR','302':'CA','310':'US','311':'US','312':'US','313':'US','314':'US','315':'US','316':'US','334':'MX','404':'IN','405':'IN','406':'IN','410':'PK','413':'LK','414':'MM','415':'LB','416':'JO','417':'SY','418':'IQ','419':'KW','420':'SA','421':'YE','422':'OM','424':'AE','425':'IL','426':'BH','427':'QA','428':'MN','429':'NP','430':'AE','431':'AE','432':'IR','440':'JP','441':'JP','450':'KR','452':'VN','454':'HK','455':'MO','456':'KH','457':'LA','460':'CN','461':'CN','466':'TW','467':'KP','470':'BD','472':'MV','502':'MY','505':'AU','510':'ID','514':'TL','515':'PH','520':'TH','525':'SG','528':'BN','530':'NZ','536':'NR','537':'PG','539':'TO','540':'SB','541':'VU','542':'FJ','544':'AS','546':'NC','547':'PF','548':'CK','549':'WS','550':'FM','551':'MH','552':'PW','553':'TV','555':'NU','602':'EG','603':'DZ','604':'MA','605':'TN','606':'LY','607':'GM','608':'SN','609':'MR','610':'ML','611':'GN','612':'CI','613':'BF','614':'NE','615':'TG','616':'BJ','617':'MU','618':'LR','619':'SL','620':'GH','621':'NG','622':'TD','623':'CF','624':'CM','625':'CV','626':'ST','627':'GQ','628':'GA','629':'CG','630':'CD','631':'AO','632':'GW','633':'SC','634':'SD','635':'RW','636':'ET','637':'SO','638':'DJ','639':'KE','640':'TZ','641':'UG','642':'BI','643':'MZ','645':'ZM','646':'MG','647':'RE','648':'ZW','649':'NA','650':'MW','651':'LS','652':'BW','653':'SZ','654':'KM','655':'ZA','657':'ER','659':'SS','702':'BZ','704':'GT','706':'SV','708':'HN','710':'NI','712':'CR','714':'PA','716':'PE','722':'AR','724':'BR','730':'CL','732':'CO','734':'VE','736':'BO','738':'GY','740':'EC','742':'GF','744':'PY','746':'SR','748':'UY','750':'FK'};
const S={token:sessionStorage.getItem('matrix_token')||sessionStorage.getItem('nexus_token')||'',data:null,timer:null,busy:false,proxyCfg:null};
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function toast(msg,isErr){const t=$('#toast');t.textContent=msg;t.className='toast show'+(isErr?' err':'');clearTimeout(t._h);t._h=setTimeout(()=>t.className='toast',2600)}
async function api(path,method='GET',body){
  const res=await fetch(path,{method,headers:{Authorization:'Bearer '+S.token,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
  const text=await res.text();
  let data={};try{data=text?JSON.parse(text):{}}catch(_){data={raw:text}}
  if(!res.ok)throw new Error(data.error||('HTTP '+res.status));
  return data;
}
function decodeFlag(s){const m=String(s||'').match(/[\u{1F1E6}-\u{1F1FF}]{2}/u);if(!m)return null;return[...m[0]].map(c=>String.fromCharCode(c.codePointAt(0)-0x1F1E6+65)).join('')}
function countryOf(alias,prefix){
  const flag=decodeFlag(alias);if(flag&&FLAG[flag])return flag;
  if(prefix&&PREFIX[prefix])return PREFIX[prefix];
  for(const[re,code]of KEYWORDS)if(re.test(alias||''))return code;
  return null;
}
function flagOf(alias,prefix){const c=countryOf(alias,prefix);return c?(FLAG[c]||'🌐'):'🌐'}
function signalBars(dbm){const n=dbm==null?0:dbm>=-70?4:dbm>=-85?3:dbm>=-100?2:dbm>=-110?1:0;return '<span class="signal">'+[3,6,9,12].map((h,i)=>'<i class="'+(i<n?'on':'')+'" style="height:'+h+'px"></i>').join('')+'</span>'}
function fmtEpoch(ms){if(!ms)return '—';const d=new Date(ms);const p=n=>String(n).padStart(2,'0');return p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes())}
function fmtRemain(sec){if(sec==null)return null;const s=Math.max(0,sec|0);const m=Math.floor(s/60);return m+'分'+String(s%60).padStart(2,'0')+'秒'}

function render(){
  const d=S.data||{},st=d.status||{},session=st.session,network=st.network,device=st.device,card=st.card,proxy=st.proxy,guard=st.dataGuard;
  $('#gwPill').textContent=st.gateway==='running'?'网关运行中':'网关已停止';
  $('#gwPill').className='pill '+(st.gateway==='running'?'ok':'bad');
  if(guard){$('#guardPill').classList.remove('hide');$('#guardPill').textContent=guard.enabled?(guard.enforced?'流量卫士 · 已锁定':'流量卫士 · 待触发'):'流量卫士 · 关闭';$('#guardPill').className='pill '+(guard.enabled?(guard.enforced?'ok':'warn'):'')}
  if(proxy){$('#proxyPill').classList.remove('hide');$('#proxyPill').textContent='代理 · '+(proxy.enabled?(proxy.currentNode||'已启用'):'关闭');$('#proxyPill').className='pill '+(proxy.enabled?'ok':'')}

  // session
  const sb=[];
  if(session){
    const stateText=session.state==='waiting_for_service'?'⏳ 基带搜网握手中':session.state==='ready'?'🟢 已就绪':'🔄 切换中';
    sb.push('<div class="big">'+esc(session.target||'—')+'</div>');
    sb.push('<div class="kv"><span>状态</span><b>'+stateText+'</b></div>');
    if(session.returnTo)sb.push('<div class="kv"><span>回滚目标</span><b>'+esc(session.returnTo)+'</b></div>');
    const rem=fmtRemain(session.remainingSeconds);
    if(rem)sb.push('<div class="kv"><span>剩余时间</span><b>'+rem+' 后自动回主卡</b></div>');
    else sb.push('<div class="kv"><span>会话模式</span><b>长驻生效</b></div>');
  }else{
    sb.push('<div class="big">常驻待机</div>');
    sb.push('<div class="muted" style="margin-top:6px">当前无临时接码会话。</div>');
  }
  if(st.defaultProfile)sb.push('<div class="kv"><span>默认主卡</span><b>'+esc(st.defaultProfile)+'</b></div>');
  if(st.keepAliveCount!=null)sb.push('<div class="kv"><span>保号任务</span><b>'+st.keepAliveCount+' 条</b></div>');
  sb.push('<div class="row"><button data-act="back" class="primary">🏠 切回默认主卡</button><button data-act="default">📌 设当前为默认</button><button data-act="retry">🔄 补发未送达</button></div>');
  $('#sessionBox').innerHTML=sb.join('');

  // device
  const db=[];
  if(device&&device.batteryPercent!=null){
    db.push('<div class="kv"><span>电量</span><b>'+device.batteryPercent+'% '+(device.charging?'⚡ 充电中':'⚠️ 未充电')+'</b></div>');
    if(device.temperatureCelsius!=null)db.push('<div class="kv"><span>温度</span><b>'+Number(device.temperatureCelsius).toFixed(1)+' °C</b></div>');
    if(device.networkType)db.push('<div class="kv"><span>网络类型</span><b>'+esc(device.networkType)+'</b></div>');
  }
  if(network){
    db.push('<div class="kv"><span>SIM 槽位</span><b>SIM '+(network.slot||'?')+'</b></div>');
    db.push('<div class="kv"><span>注册状态</span><b>'+esc(network.registration||'—')+(network.roaming?' · 漫游':'')+'</b></div>');
    if(network.carrier)db.push('<div class="kv"><span>运营商</span><b>'+esc(network.carrier)+'</b></div>');
    if(network.signalDbm!=null)db.push('<div class="kv"><span>信号</span><b>'+signalBars(network.signalDbm)+' '+network.signalDbm+' dBm</b></div>');
  }else{
    db.push('<div class="muted">暂无活动订阅或正在搜网。</div>');
  }
  if(card&&card.eid)db.push('<div class="kv"><span>EID</span><b class="mono">'+esc(card.eid)+'</b></div>');
  if(card&&card.freeNonVolatileMemoryBytes!=null)db.push('<div class="kv"><span>芯片剩余空间</span><b>'+(card.freeNonVolatileMemoryBytes/1024).toFixed(1)+' KB</b></div>');
  if(st.selectedReader)db.push('<div class="kv"><span>读卡器</span><b>'+esc(st.selectedReader)+'</b></div>');
  $('#deviceBox').innerHTML=db.join('')||'<div class="muted">无数据</div>';

  // guard
  const gb=[];const caps=(d.dataGuard&&d.dataGuard.capabilities)||{};
  if(guard){
    gb.push('<div class="kv"><span>开关</span><b>'+(guard.enabled?'🟢 已启用':'⚪ 已关闭')+'</b></div>');
    gb.push('<div class="kv"><span>本次会话强制</span><b>'+(guard.enforced?'🟢 移动数据已关闭':'⚪ 未强制')+'</b></div>');
    gb.push('<div class="kv"><span>回滚时恢复</span><b>'+(guard.restoreOnRevert?'是':'否')+'</b></div>');
  }
  gb.push('<div class="kv"><span>MODIFY_PHONE_STATE</span><b>'+(caps.modifyPhoneState?'✔ 可用':'✘ 不可用')+'</b></div>');
  gb.push('<div class="kv"><span>Root su</span><b>'+(caps.root?'✔ 可用':'✘ 不可用')+'</b></div>');
  if(!caps.canEnforce)gb.push('<div class="muted" style="margin-top:8px;color:var(--warn)">当前构建无法自动关闭移动数据，请手动在系统设置中关闭数据漫游。</div>');
  const subs=(d.dataGuard&&d.dataGuard.subscriptions)||[];
  subs.forEach(s=>{gb.push('<div class="kv"><span>SIM '+(s.slotIndex+1)+' 数据</span><b>'+(s.dataEnabled==null?'未知':(s.dataEnabled?'🟢 开启':'⚪ 关闭'))+(s.roamingEnabled?' · 漫游开启':'')+'</b></div>')});
  gb.push('<div class="row"><button data-act="guardToggle" class="'+(guard&&guard.enabled?'':'primary')+'">'+(guard&&guard.enabled?'关闭流量卫士':'启用流量卫士')+'</button><button data-act="guardApply" '+(caps.canEnforce?'':'disabled')+'>立即锁定当前卡</button></div>');
  $('#guardBox').innerHTML=gb.join('');

  // proxy
  const pb=[];
  if(proxy){
    pb.push('<div class="kv"><span>联动状态</span><b>'+(proxy.enabled?'🟢 已启用':'⚪ 未启用')+'</b></div>');
    pb.push('<div class="kv"><span>策略组</span><b>'+esc(proxy.targetGroup||'—')+'</b></div>');
    pb.push('<div class="kv"><span>当前节点</span><b>'+esc(proxy.currentNode||'—')+'</b></div>');
    if(proxy.snapshotNode)pb.push('<div class="kv"><span>切卡前快照</span><b>'+esc(proxy.snapshotNode)+'</b></div>');
  }
  const cfg=S.proxyCfg||{};
  pb.push('<label for="pUrl">External Controller</label><input id="pUrl" value="'+esc(cfg.controllerUrl||proxy&&proxy.controllerUrl||'http://127.0.0.1:9090')+'">');
  pb.push('<label for="pSecret">Secret（留空则不修改）</label><input id="pSecret" type="password" placeholder="••••••">');
  pb.push('<label for="pGroup">Selector Group</label><input id="pGroup" value="'+esc(cfg.targetGroup||proxy&&proxy.targetGroup||'PROXY')+'">');
  pb.push('<div class="row"><button data-act="proxySave" class="primary">保存并启用</button><button data-act="proxyTest">测试连接</button></div>');
  $('#proxyBox').innerHTML=pb.join('');

  // profiles
  const profiles=d.profiles||[];
  $('#profilesBox').innerHTML=profiles.length?profiles.map((p,i)=>{
    const flag=flagOf(p.alias,p.iccidPrefix);
    return '<div class="profile'+(p.enabled?' active':'')+'"><div class="flag">'+flag+'</div><div class="meta"><div>'+esc(p.alias||('Profile '+(i+1)))+'</div><small class="mono">'+(p.iccidSuffix?('尾号 '+esc(p.iccidSuffix)):'')+(p.enabled?' · 当前激活':'')+'</small></div><div class="acts">'+
      (p.enabled?'<button disabled>已激活</button>':'<button data-act="switch5" data-idx="'+(i+1)+'" class="primary">⏱️ 5分钟接码</button><button data-act="switchPerm" data-idx="'+(i+1)+'">常驻</button>')+
      '<button data-act="kaNow" data-idx="'+(i+1)+'">⚡保号</button></div></div>';
  }).join(''):'<div class="muted">卡内暂无 Profile。</div>';

  // sms
  const messages=d.messages||[];
  $('#smsBox').innerHTML=messages.length?messages.map(m=>{
    let body=esc(m.body);
    if(m.otp)body=body.split(esc(m.otp)).join('<span class="otp" data-act="copyOtp" data-otp="'+esc(m.otp)+'">'+esc(m.otp)+'</span>');
    return '<div class="msg"><div class="top"><span>'+esc(m.sender)+'</span><span>'+fmtEpoch(m.receivedAtMillis)+(m.delivered?' · 已转发':' · 待重试')+'</span></div><div class="body">'+body+'</div></div>';
  }).join(''):'<div class="muted">暂无短信记录。</div>';

  // advanced
  const opts=profiles.map((p,i)=>'<option value="'+(i+1)+'">'+esc((p.alias||('Profile '+(i+1)))+' (尾号 '+(p.iccidSuffix||'?'))+'</option>').join('');
  $('#advancedBox').innerHTML=
    '<label for="aProfile">目标 Profile</label><select id="aProfile">'+opts+'</select>'+
    '<label for="aAlias">新备注名（重命名）</label><input id="aAlias" placeholder="例如 Saily US">'+
    '<div class="row"><button data-act="rename">✏️ 重命名</button><button data-act="kaSet">🛡️ 每90天保号</button><button data-act="deleteReq" class="danger">🗑️ 申请删除</button></div>'+
    '<label for="aToken">删除确认令牌</label><input id="aToken" placeholder="由“申请删除”返回">'+
    '<div class="row"><button data-act="deleteConfirm" class="danger">确认删除</button></div>'+
    '<label for="aAc">激活码 LPA:1$…</label><input id="aAc" placeholder="LPA:1$smdp$matching-id">'+
    '<label for="aCc">确认码（可选）</label><input id="aCc">'+
    '<div class="row"><button data-act="download" class="primary">⬇️ 下载并启用</button><button data-act="reader">🔀 切换读卡器</button></div>';
}

async function refresh(quiet){
  if(S.busy)return;S.busy=true;
  try{
    S.data=await api('/api/v1/dashboard');
    $('#login').classList.add('hide');$('#app').classList.remove('hide');
    render();
  }catch(e){
    if(!quiet)toast('刷新失败：'+e.message,true);
    if(/401|unauthorized|invalid_token/i.test(e.message)){$('#login').classList.remove('hide');$('#app').classList.add('hide')}
  }finally{S.busy=false}
}

document.addEventListener('click',async ev=>{
  const btn=ev.target.closest('[data-act]');if(!btn)return;
  const act=btn.dataset.act;
  const idx=btn.dataset.idx;
  const run=async(fn,okMsg)=>{btn.disabled=true;try{const r=await fn();toast(okMsg||'完成');await refresh(true);return r}catch(e){toast(e.message,true)}finally{btn.disabled=false}};
  if(act==='back')return run(()=>api('/api/v1/back','POST',{}),'已切回默认主卡');
  if(act==='default')return run(()=>api('/api/v1/default','POST',{}),'已设为默认主卡');
  if(act==='retry')return run(()=>api('/api/v1/sms/retry','POST',{}),'已触发补发');
  if(act==='switch5')return run(()=>api('/api/v1/switch','POST',{profile:String(idx),temporaryMinutes:5}),'已开始切卡（5分钟后回滚）');
  if(act==='switchPerm')return run(()=>api('/api/v1/switch','POST',{profile:String(idx)}),'已开始常驻切卡');
  if(act==='kaNow')return run(()=>api('/api/v1/keepalive','POST',{profile:String(idx),runNow:true}),'保号任务已启动');
  if(act==='kaSet')return run(()=>api('/api/v1/keepalive','POST',{profile:$('#aProfile').value,intervalDays:90}),'已设定 90 天保号');
  if(act==='rename')return run(()=>api('/api/v1/rename','POST',{profile:$('#aProfile').value,alias:$('#aAlias').value}),'已重命名');
  if(act==='deleteReq')return run(async()=>{const r=await api('/api/v1/delete/request','POST',{profile:$('#aProfile').value});$('#aToken').value=r.token||'';return r},'删除令牌已生成');
  if(act==='deleteConfirm')return run(()=>api('/api/v1/delete/confirm','POST',{token:$('#aToken').value}),'已删除');
  if(act==='download')return run(()=>api('/api/v1/download','POST',{activationCode:$('#aAc').value,confirmationCode:$('#aCc').value||undefined}),'下载已开始');
  if(act==='reader')return run(()=>api('/api/v1/reader','POST',{reader:'2'}),'已切换读卡器');
  if(act==='guardToggle')return run(()=>api('/api/v1/dataguard','POST',{enabled:!(S.data&&S.data.status&&S.data.status.dataGuard&&S.data.status.dataGuard.enabled)}),'流量卫士已更新');
  if(act==='guardApply')return run(()=>api('/api/v1/dataguard/apply','POST',{}),'已锁定当前卡数据');
  if(act==='proxyTest')return run(async()=>{const r=await api('/api/v1/proxy/test','POST',{controllerUrl:$('#pUrl').value,secret:$('#pSecret').value||undefined});toast(r.alive?('连接成功 · '+(r.version||'ok')):('连接失败 · '+(r.error||'')),!r.alive);return r});
  if(act==='proxySave')return run(async()=>{
    const body={enabled:true,controllerUrl:$('#pUrl').value,targetGroup:$('#pGroup').value};
    if($('#pSecret').value)body.secret=$('#pSecret').value;
    await api('/api/v1/proxy/config','POST',body);S.proxyCfg=body;return body;
  },'代理联动已保存并启用');
  if(act==='copyOtp'){
    const otp=btn.dataset.otp||'';
    try{await navigator.clipboard.writeText(otp);toast('验证码 '+otp+' 已复制')}catch(_){toast('验证码：'+otp)}
    return;
  }
});

$('#loginBtn').onclick=async()=>{
  S.token=$('#token').value.trim();sessionStorage.setItem('matrix_token',S.token);
  await refresh();
  if(!$('#app').classList.contains('hide')){startTimer();toast('已连接')}
};
$('#token').addEventListener('keydown',e=>{if(e.key==='Enter')$('#loginBtn').click()});
$('#refresh').onclick=()=>refresh();

function startTimer(){
  if(S.timer)clearInterval(S.timer);
  S.timer=setInterval(()=>{if(!document.hidden)refresh(true)},8000);
}
(async()=>{
  if(!S.token){$('#login').classList.remove('hide');return}
  await refresh();
  if(!$('#app').classList.contains('hide'))startTimer();
})();
</script>
</body></html>''';
}

class _RemoteDefault {
  const _RemoteDefault({required this.iccid, required this.alias, required this.readerId});

  final String iccid;
  final String alias;
  final String readerId;

  Map<String, Object?> toJson() => {'iccid': iccid, 'alias': alias, 'readerId': readerId};

  factory _RemoteDefault.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('invalid default profile');
    final map = Map<String, Object?>.from(value);
    if (map['iccid'] is! String || map['alias'] is! String || map['readerId'] is! String) {
      throw const FormatException('invalid default profile');
    }
    return _RemoteDefault(
      iccid: map['iccid']! as String,
      alias: map['alias']! as String,
      readerId: map['readerId']! as String,
    );
  }
}

class _RemoteSession {
  const _RemoteSession({
    required this.state,
    required this.targetIccid,
    required this.targetAlias,
    required this.defaultIccid,
    required this.defaultAlias,
    required this.readerId,
    required this.deadlineEpochMillis,
    this.guardSubscriptionId,
    this.guardDataEnabledBefore,
    this.guardRoamingEnabledBefore,
    this.guardEnforced = false,
  });

  final String state;
  final String targetIccid;
  final String targetAlias;
  final String defaultIccid;
  final String defaultAlias;
  final String readerId;
  final int deadlineEpochMillis;

  /// Subscription the data safeguard locked down for this session, and the
  /// state it found first, so a revert restores the phone exactly as it was.
  final int? guardSubscriptionId;
  final bool? guardDataEnabledBefore;
  final bool? guardRoamingEnabledBefore;
  final bool guardEnforced;

  _RemoteSession copyWith({
    String? state,
    String? targetAlias,
    String? defaultIccid,
    String? defaultAlias,
    Object? guardSubscriptionId = _absent,
    Object? guardDataEnabledBefore = _absent,
    Object? guardRoamingEnabledBefore = _absent,
    bool? guardEnforced,
  }) => _RemoteSession(
    state: state ?? this.state,
    targetIccid: targetIccid,
    targetAlias: targetAlias ?? this.targetAlias,
    defaultIccid: defaultIccid ?? this.defaultIccid,
    defaultAlias: defaultAlias ?? this.defaultAlias,
    readerId: readerId,
    deadlineEpochMillis: deadlineEpochMillis,
    guardSubscriptionId: guardSubscriptionId == _absent
        ? this.guardSubscriptionId
        : guardSubscriptionId as int?,
    guardDataEnabledBefore: guardDataEnabledBefore == _absent
        ? this.guardDataEnabledBefore
        : guardDataEnabledBefore as bool?,
    guardRoamingEnabledBefore: guardRoamingEnabledBefore == _absent
        ? this.guardRoamingEnabledBefore
        : guardRoamingEnabledBefore as bool?,
    guardEnforced: guardEnforced ?? this.guardEnforced,
  );

  Map<String, Object?> toJson() => {
    'state': state,
    'targetIccid': targetIccid,
    'targetAlias': targetAlias,
    'defaultIccid': defaultIccid,
    'defaultAlias': defaultAlias,
    'readerId': readerId,
    'deadlineEpochMillis': deadlineEpochMillis,
    'guardSubscriptionId': guardSubscriptionId,
    'guardDataEnabledBefore': guardDataEnabledBefore,
    'guardRoamingEnabledBefore': guardRoamingEnabledBefore,
    'guardEnforced': guardEnforced,
  };

  factory _RemoteSession.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('invalid session');
    final map = Map<String, Object?>.from(value);
    if (map['state'] is! String ||
        map['targetIccid'] is! String ||
        map['targetAlias'] is! String ||
        map['defaultIccid'] is! String ||
        map['defaultAlias'] is! String ||
        map['readerId'] is! String ||
        map['deadlineEpochMillis'] is! int) {
      throw const FormatException('invalid session');
    }
    return _RemoteSession(
      state: map['state']! as String,
      targetIccid: map['targetIccid']! as String,
      targetAlias: map['targetAlias']! as String,
      defaultIccid: map['defaultIccid']! as String,
      defaultAlias: map['defaultAlias']! as String,
      readerId: map['readerId']! as String,
      deadlineEpochMillis: map['deadlineEpochMillis']! as int,
      guardSubscriptionId: map['guardSubscriptionId'] is int
          ? map['guardSubscriptionId'] as int
          : null,
      guardDataEnabledBefore: map['guardDataEnabledBefore'] is bool
          ? map['guardDataEnabledBefore'] as bool
          : null,
      guardRoamingEnabledBefore: map['guardRoamingEnabledBefore'] is bool
          ? map['guardRoamingEnabledBefore'] as bool
          : null,
      guardEnforced: map['guardEnforced'] == true,
    );
  }
}

class _PendingDeletion {
  const _PendingDeletion({
    required this.token,
    required this.iccid,
    required this.alias,
    required this.expiresAt,
  });

  final String token;
  final String iccid;
  final String alias;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class _TelegramButton {
  const _TelegramButton(this.text, this.callbackData);

  final String text;
  final String callbackData;

  Map<String, String> toJson() => {
    'text': text,
    'callback_data': callbackData,
  };
}

class _TelegramReply {
  const _TelegramReply(
    this.text, {
    this.keyboard = const <List<_TelegramButton>>[],
  });

  final String text;
  final List<List<_TelegramButton>> keyboard;

  Map<String, Object?> toPayload(String chatId) => {
    'chat_id': chatId,
    'text': text,
    if (keyboard.isNotEmpty)
      'reply_markup': {
        'inline_keyboard': keyboard
            .map((row) => row.map((btn) => btn.toJson()).toList())
            .toList(),
      },
  };
}

class _KeepAliveRule {
  const _KeepAliveRule({
    required this.iccid,
    required this.alias,
    required this.intervalDays,
    required this.dwellSeconds,
    required this.lastRunEpochMillis,
  });

  final String iccid;
  final String alias;
  final int intervalDays;
  final int dwellSeconds;
  final int lastRunEpochMillis;

  int get nextRunEpochMillis =>
      lastRunEpochMillis + intervalDays * 24 * 60 * 60 * 1000;

  _KeepAliveRule copyWith({
    String? alias,
    int? intervalDays,
    int? dwellSeconds,
    int? lastRunEpochMillis,
  }) => _KeepAliveRule(
    iccid: iccid,
    alias: alias ?? this.alias,
    intervalDays: intervalDays ?? this.intervalDays,
    dwellSeconds: dwellSeconds ?? this.dwellSeconds,
    lastRunEpochMillis: lastRunEpochMillis ?? this.lastRunEpochMillis,
  );

  Map<String, Object?> toJson() => {
    'iccid': iccid,
    'alias': alias,
    'intervalDays': intervalDays,
    'dwellSeconds': dwellSeconds,
    'lastRunEpochMillis': lastRunEpochMillis,
    'nextRunEpochMillis': nextRunEpochMillis,
  };

  factory _KeepAliveRule.fromJson(Map value) {
    final map = Map<Object?, Object?>.from(value);
    return _KeepAliveRule(
      iccid: '${map['iccid'] ?? ''}',
      alias: '${map['alias'] ?? ''}',
      intervalDays: (map['intervalDays'] as num?)?.toInt() ?? 90,
      dwellSeconds: (map['dwellSeconds'] as num?)?.toInt() ?? 180,
      lastRunEpochMillis: (map['lastRunEpochMillis'] as num?)?.toInt() ?? 0,
    );
  }
}
