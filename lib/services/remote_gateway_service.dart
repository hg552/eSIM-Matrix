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
import 'proxy_linkage_service.dart';
import 'proxy_mapping_resolver.dart';

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
  }) : _smsRelay = smsRelay,
       _profiles = profiles ?? LpaRemoteProfileControl();

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
  ProxySnapshot? _proxySnapshot;
  String? _lastLinkedProxyNode;

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
        'targetGroup': AppSettings().proxyTargetGroup,
        'currentNode': _lastLinkedProxyNode ?? _proxySnapshot?.node,
        'lastLinkedNode': _lastLinkedProxyNode,
        'snapshotNode': _proxySnapshot?.node,
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
        final now = DateTime.now().millisecondsSinceEpoch;
        final idx = rules.indexWhere((r) => r.iccid == target.iccid);
        final dwell = idx >= 0 ? rules[idx].dwellSeconds : 180;
        if (idx >= 0) {
          rules[idx] = rules[idx].copyWith(
            alias: target.alias,
            lastRunEpochMillis: now,
          );
          await _saveKeepAliveRules(rules);
        }
        final res = await _switchProfile(
          target.iccid,
          duration: Duration(seconds: dwell),
        );
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
      await _profiles.enableProfile(target.iccid);
    } catch (error) {
      _session = previousSession;
      _readyNotificationSent = previousReady;
      await _saveSession(previousSession);
      rethrow;
    }
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
    if (auto) {
      final proxyText = restoredProxy != null ? '\n🌐 代理节点已自动恢复为：【$restoredProxy】' : '';
      unawaited(
        _sendTelegramReply(
          _TelegramReply(
            '🏠 临时接码/保号驻网时间已到，已自动为您切回默认主卡：【$targetDefaultAlias】。$proxyText',
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
    if (!settings.proxyLinkageEnabled) return;
    final group = settings.proxyTargetGroup;
    _proxyLinkage.updateConfig(
      controllerUrl: settings.proxyControllerUrl,
      secret: settings.proxySecret,
    );
    try {
      if (_proxySnapshot == null) {
        _proxySnapshot = await _proxyLinkage.snapshot(group);
      }
      final groupInfo = await _proxyLinkage.getGroup(group);
      if (groupInfo == null) {
        _log.warning('Proxy linkage: Group "$group" not found');
        return;
      }
      final match = _proxyResolver.resolveNode(
        candidates: groupInfo.all,
        iccid: target.iccid,
        alias: target.alias,
        customRules: settings.proxyCustomRules,
      );
      if (match.matched && match.nodeName != null) {
        final res = await _proxyLinkage.selectNode(group, match.nodeName!);
        if (res.success) {
          _lastLinkedProxyNode = match.nodeName;
          _log.info('Proxy Linkage: Switched to [${match.nodeName}] for ${target.alias} (${match.reason})');
        }
      } else {
        _log.info('Proxy Linkage: No matching node for ${target.alias}: ${match.reason}');
      }
    } catch (e) {
      _log.warning('Proxy linkage switch exception: $e');
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
    final roaming = subscription.roaming == true ? ' (漫游中)' : '';
    final signal = subscription.signalDbm == null ? '' : '，信号 ${subscription.signalDbm} dBm';
    final carrier = subscription.carrierName == null ? '' : '【${subscription.carrierName}】';
    final proxyStatusText = AppSettings().proxyLinkageEnabled
        ? (_lastLinkedProxyNode != null
            ? '\n🌐 代理联动：已切换至【$_lastLinkedProxyNode】'
            : '\n🌐 代理联动：已就绪')
        : '';
    unawaited(
      _sendTelegramReply(
        _TelegramReply(
          '📡 搜网就绪！\n已成功连接到基站$carrier$roaming$signal。$proxyStatusText\n\n'
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
        if (now >= rule.nextRunEpochMillis) {
          final res = await runKeepAliveNow(rule.iccid);
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
          break;
        }
      }
    } catch (_) {}
  }

  Future<void> _refreshHttpServer() async {
    if (!_running) return;
    final address = await _findTailscaleAddress();
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
      r'^/(start|help|menu|list|status|use|use_temp|back|default|rename|keepalive|keepalive_now|readers|reader|retry_sms|download|download_test|delete|delete_confirm|delete_cancel|announce)(?:@[A-Za-z0-9_]+)?(?:\s+(.*))?$',
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
            '🤖 eUICC-Nexus 远程控制主控台\n\n'
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
    return '🆕 eUICC-Nexus 有新版本：${update.version} (build ${update.build})\n'
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
  };

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
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>eUICC-Nexus</title>
<style>
:root{color-scheme:dark;font:16px system-ui,sans-serif;--surface:#171a20;--panel:#20242c;--fg:#edf0f6;--muted:#aab1bf;--accent:#8ab4f8;--border:#343a46}*{box-sizing:border-box}body{margin:0;background:var(--surface);color:var(--fg)}main{max-width:760px;margin:auto;padding:24px}h1{font-size:1.35rem}section{background:var(--panel);border:1px solid var(--border);border-radius:14px;padding:16px;margin:14px 0}label{display:block;color:var(--muted);margin:10px 0 6px}input,button{font:inherit;border-radius:9px;border:1px solid var(--border);padding:10px;background:var(--surface);color:var(--fg)}input{width:100%}button{cursor:pointer;color:var(--accent);margin:5px 5px 5px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere;color:var(--muted)}small{color:var(--muted)}
</style></head>
<body><main><h1>eUICC-Nexus remote gateway</h1>
<section><label for="token">API bearer token (kept in this tab only)</label><input id="token" type="password" autocomplete="off"><p><button id="status">Status (Signal / NVRAM / Battery)</button><button id="list">List profiles</button><button id="readers">List readers</button><button id="keepalive">Keep-Alive rules</button><button id="default">Set current as default</button><button id="back">Return to default</button><button id="retrySms">Retry failed SMS</button><button id="proxy">🌐 Proxy Linkage</button></p><pre id="output">Enter the API token to control this device.</pre></section>
<section><h2>🌐 代理软件联动 (FlClash / Mihomo / sing-box)</h2>
<label for="proxyUrl">External Controller URL</label><input id="proxyUrl" value="http://127.0.0.1:9090" autocomplete="off">
<label for="proxySecret">Secret (Optional)</label><input id="proxySecret" type="password" autocomplete="off">
<label for="proxyGroup">Target Selector Group</label><input id="proxyGroup" value="PROXY" autocomplete="off">
<p><label><input id="proxyEnabled" type="checkbox" style="width:auto"> 启用切卡自动联动代理节点</label></p>
<p><label><input id="proxyAutoRestore" type="checkbox" style="width:auto" checked> 临时接码结束回滚时还原原节点</label></p>
<p><button id="proxyTest">⚡ 测试连接并列出节点</button><button id="proxySave">💾 保存配置</button><button id="proxyQuery">🔍 当前状态</button></p>
</section>
<section><label for="profile">Profile index, alias, or ICCID</label><input id="profile" autocomplete="off"><label for="newAlias">New nickname (for Rename)</label><input id="newAlias" autocomplete="off"><p><button id="switch">Switch (Permanent)</button><button id="switchTemp">⏱️ Switch (5-Min OTP)</button><button id="rename">✏️ Rename</button><button id="kaSet">🛡️ Keep-Alive (90d)</button><button id="kaNow">⚡ Keep-Alive Now (3m)</button><button id="deleteReq">🗑️ Request delete</button></p></section>
<section><label for="readerInput">Reader selector (e.g. 1, 2, SIM2)</label><input id="readerInput" autocomplete="off"><p><button id="selectReader">🔀 Switch Reader</button></p></section>
<section><label for="deleteToken">Delete confirmation token</label><input id="deleteToken" autocomplete="off"><p><button id="deleteConfirm">Confirm delete</button></p></section>
<section><label for="ac">Activation code (LPA:1$...)</label><input id="ac" autocomplete="off"><label for="cc">Confirmation code (optional)</label><input id="cc" autocomplete="off"><p><button id="download">Download profile</button><button id="downloadTest">🚀 Download Speedtest Test eSIM</button></p></section>
<script>
const token=document.querySelector('#token'),output=document.querySelector('#output');
async function api(path,method='GET',body){const response=await fetch(path,{method,headers:{Authorization:'Bearer '+token.value,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});const data=await response.json();if(!response.ok)throw new Error(data.error||('HTTP '+response.status));return data}
async function show(path,method='GET',body){try{output.textContent=JSON.stringify(await api(path,method,body),null,2)}catch(error){output.textContent='Request failed: '+error.message}}
document.querySelector('#status').onclick=()=>show('/api/v1/status');
document.querySelector('#list').onclick=()=>show('/api/v1/profiles');
document.querySelector('#readers').onclick=()=>show('/api/v1/readers');
document.querySelector('#keepalive').onclick=()=>show('/api/v1/keepalive');
document.querySelector('#default').onclick=()=>show('/api/v1/default','POST',{});
document.querySelector('#back').onclick=()=>show('/api/v1/back','POST',{});
document.querySelector('#retrySms').onclick=()=>show('/api/v1/sms/retry','POST',{});
document.querySelector('#switch').onclick=()=>show('/api/v1/switch','POST',{profile:document.querySelector('#profile').value});
document.querySelector('#switchTemp').onclick=()=>show('/api/v1/switch','POST',{profile:document.querySelector('#profile').value,temporaryMinutes:5});
document.querySelector('#rename').onclick=()=>show('/api/v1/rename','POST',{profile:document.querySelector('#profile').value,alias:document.querySelector('#newAlias').value});
document.querySelector('#kaSet').onclick=()=>show('/api/v1/keepalive','POST',{profile:document.querySelector('#profile').value,intervalDays:90});
document.querySelector('#kaNow').onclick=()=>show('/api/v1/keepalive','POST',{profile:document.querySelector('#profile').value,runNow:true});
document.querySelector('#selectReader').onclick=()=>show('/api/v1/reader','POST',{reader:document.querySelector('#readerInput').value});
document.querySelector('#deleteReq').onclick=()=>show('/api/v1/delete/request','POST',{profile:document.querySelector('#profile').value});
document.querySelector('#deleteConfirm').onclick=()=>show('/api/v1/delete/confirm','POST',{token:document.querySelector('#deleteToken').value});
document.querySelector('#download').onclick=()=>show('/api/v1/download','POST',{activationCode:document.querySelector('#ac').value,confirmationCode:document.querySelector('#cc').value||undefined});
document.querySelector('#downloadTest').onclick=()=>{document.querySelector('#ac').value='LPA:1$rsp.truphone.com$QRF-SPEEDTEST';show('/api/v1/download','POST',{activationCode:'LPA:1$rsp.truphone.com$QRF-SPEEDTEST'})};
document.querySelector('#proxy').onclick=()=>show('/api/v1/proxy');
document.querySelector('#proxyQuery').onclick=()=>show('/api/v1/proxy');
document.querySelector('#proxyTest').onclick=()=>show('/api/v1/proxy/test','POST',{controllerUrl:document.querySelector('#proxyUrl').value,secret:document.querySelector('#proxySecret').value});
document.querySelector('#proxySave').onclick=()=>show('/api/v1/proxy/config','POST',{enabled:document.querySelector('#proxyEnabled').checked,controllerUrl:document.querySelector('#proxyUrl').value,secret:document.querySelector('#proxySecret').value,targetGroup:document.querySelector('#proxyGroup').value,autoRestore:document.querySelector('#proxyAutoRestore').checked});
</script></main></body></html>''';
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
  });

  final String state;
  final String targetIccid;
  final String targetAlias;
  final String defaultIccid;
  final String defaultAlias;
  final String readerId;
  final int deadlineEpochMillis;

  _RemoteSession copyWith({
    String? state,
    String? targetAlias,
    String? defaultIccid,
    String? defaultAlias,
  }) => _RemoteSession(
    state: state ?? this.state,
    targetIccid: targetIccid,
    targetAlias: targetAlias ?? this.targetAlias,
    defaultIccid: defaultIccid ?? this.defaultIccid,
    defaultAlias: defaultAlias ?? this.defaultAlias,
    readerId: readerId,
    deadlineEpochMillis: deadlineEpochMillis,
  );

  Map<String, Object?> toJson() => {
    'state': state,
    'targetIccid': targetIccid,
    'targetAlias': targetAlias,
    'defaultIccid': defaultIccid,
    'defaultAlias': defaultAlias,
    'readerId': readerId,
    'deadlineEpochMillis': deadlineEpochMillis,
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
