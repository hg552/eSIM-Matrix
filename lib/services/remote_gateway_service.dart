import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_profile_controller.dart';
import 'sms_relay_service.dart';
import 'network_status_service.dart';

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
    });
    _telegramPollGeneration++;
    if (config.telegramToken != null && config.telegramChatId != null) {
      unawaited(_pollTelegram(_telegramPollGeneration));
    }
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
    return {
      'gateway': _running ? 'running' : 'stopped',
      'apiUrl': apiUrl,
      'selectedReader': _profiles.selectedReaderId,
      'defaultProfile': savedDefault?.alias,
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

  Future<Map<String, Object?>> switchProfile(String selector) =>
      _serialize(() => _switchProfile(selector));

  Future<Map<String, Object?>> revertProfile({bool auto = false}) =>
      _serialize(() => _revert(auto: auto));

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
  Future<Map<String, Object?>> _switchProfile(String selector) async {
    if (!_running) throw const RemoteGatewayException('gateway_stopped');
    final normalizedSelector = selector.trim().toLowerCase();
    if (normalizedSelector.isEmpty) throw const RemoteGatewayException('profile_required');

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

    final candidates = profiles.where((profile) {
      return profile.iccid.toLowerCase() == normalizedSelector ||
          profile.alias.trim().toLowerCase() == normalizedSelector;
    }).toList();
    if (candidates.isEmpty) throw const RemoteGatewayException('profile_not_found');
    if (candidates.length > 1) throw const RemoteGatewayException('profile_alias_ambiguous_use_iccid');
    final target = candidates.single;
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
    _session = _RemoteSession(
      state: 'switching',
      targetIccid: target.iccid,
      targetAlias: target.alias,
      defaultIccid: savedDefault.iccid,
      defaultAlias: savedDefault.alias,
      readerId: readerId,
      deadlineEpochMillis: 0,
    );
    _readyNotificationSent = false;
    _wasInServiceBeforeSwitch = wasInService;
    _sawDisconnectAfterSwitch = false;
    await _saveSession(_session);

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
    _startBasebandPolling();
    return {
      'state': 'waiting_for_service',
      'target': target.alias,
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
    _session = null;
    _readyNotificationSent = false;
    await _saveSession(null);
    unawaited(
      Future<void>.delayed(const Duration(seconds: 12), () async {
        await _profiles.purgeSwitchNotifications();
      }).catchError((Object _) {}),
    );
    final result = {'state': 'reverted', 'profile': targetDefaultAlias};
    return result;
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
    unawaited(
      _sendTelegramReply(
        _TelegramReply(
          '📡 搜网就绪！\n已成功连接到基站$carrier$roaming$signal。\n\n'
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

  Future<void> _refreshHttpServer() async {
    if (!_running) return;
    final address = await _findTailscaleAddress();
    if (address == _serverAddress && _server != null) return;
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
    for (final type in [InternetAddressType.IPv4, InternetAddressType.IPv6]) {
      try {
        final interfaces = await NetworkInterface.list(
          includeLoopback: false,
          type: type,
        );
        for (final interface in interfaces) {
          for (final address in interface.addresses) {
            if (_isTailscaleAddress(address)) return address;
          }
        }
      } catch (_) {
        // A missing VPN interface is normal until Tailscale connects.
      }
    }
    return null;
  }

  bool _isTailscaleAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return bytes.length == 4 &&
          bytes[0] == 100 &&
          bytes[1] >= 64 &&
          bytes[1] <= 127;
    }
    return bytes.length == 16 &&
        bytes[0] == 0xfd &&
        bytes[1] == 0x7a &&
        bytes[2] == 0x11 &&
        bytes[3] == 0x5c &&
        bytes[4] == 0xa1 &&
        bytes[5] == 0xe0;
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
        await _writeJson(request.response, HttpStatus.ok, await switchProfile(profile));
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
          {'command': 'status', 'description': '📡 查看基带漫游、运营商与信号状态'},
          {'command': 'download_test', 'description': '🚀 一键下载 Speedtest 公开测试 eSIM'},
          {'command': 'use', 'description': '🔄 切换激活卡位 (例: /use 2)'},
          {'command': 'back', 'description': '🏠 立即切回默认常驻主卡'},
          {'command': 'default', 'description': '📌 将当前激活卡设为默认主卡'},
          {'command': 'download', 'description': '📥 远程下卡 (例: /download LPA:1\$...)'},
          {'command': 'delete', 'description': '🗑️ 安全二步删卡 (例: /delete 2)'},
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
      return _handleTelegramMessage(message, allowedChat);
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
    if (data == 'cmd:status') toast = '📡 正在刷新基带与信号状态...';
    if (data == 'cmd:download_test') toast = '🚀 开始下载 Speedtest 公开测试 eSIM...';
    if (data == 'cmd:back') toast = '🏠 正在切回默认主卡...';
    if (data == 'cmd:default') toast = '📌 正在绑定默认主卡...';
    if (data.startsWith('use:')) toast = '🔄 正在下发切卡指令...';
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
    String allowedChat,
  ) async {
    final chat = message['chat'];
    final sender = message['from'];
    if (chat is! Map || sender is! Map ||
        chat['type'] != 'private' ||
        '${chat['id']}' != allowedChat ||
        '${sender['id']}' != allowedChat ||
        sender['is_bot'] == true) {
      return null;
    }
    final text = message['text'];
    if (text is! String) return null;
    final trimmedText = text.trim();
    if (trimmedText.toUpperCase().startsWith('LPA:1\$')) {
      return _executeTelegramCommand('download', trimmedText);
    }
    final firstNewline = trimmedText.indexOf('\n');
    final commandLine = firstNewline == -1
        ? trimmedText
        : trimmedText.substring(0, firstNewline).trim();
    final restLines = firstNewline == -1
        ? ''
        : trimmedText.substring(firstNewline + 1).trim();
    final command = RegExp(
      r'^/(start|help|menu|list|status|use|back|default|download|download_test|delete|delete_confirm|delete_cancel)(?:@[A-Za-z0-9_]+)?(?:\s+(.*))?$',
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

  static List<List<_TelegramButton>> _mainMenuKeyboard() => const [
    [
      _TelegramButton('📋 卡内 eSIM 列表', 'cmd:list'),
      _TelegramButton('📡 基带与信号状态', 'cmd:status'),
    ],
    [
      _TelegramButton('🚀 下载 Speedtest 测试 eSIM', 'cmd:download_test'),
      _TelegramButton('🏠 切回默认主卡', 'cmd:back'),
    ],
    [
      _TelegramButton('📌 将当前卡设为默认主卡', 'cmd:default'),
    ],
  ];

  static String _shortAlias(String raw, {int maxLen = 14}) {
    final clean = raw.trim();
    if (clean.length <= maxLen) return clean;
    return '${clean.substring(0, maxLen - 1)}…';
  }

  Future<_TelegramReply> _buildListReply({String? prefixHeader}) async {
    final profiles = await listProfiles();
    final savedDefault = await _loadDefault();
    if (profiles.isEmpty) {
      return _TelegramReply(
        '${prefixHeader != null ? "$prefixHeader\n\n" : ""}⚠️ 未在卡片中发现任何 Profile。\n可点击下方按钮一键下载 Speedtest 公开测试 eSIM。',
        keyboard: const [
          [
            _TelegramButton('🚀 一键下载 Speedtest 测试 eSIM', 'cmd:download_test'),
          ],
          [
            _TelegramButton('📡 基带状态', 'cmd:status'),
            _TelegramButton('🔄 刷新列表', 'cmd:list'),
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
    if (savedDefault != null) {
      buffer.writeln('🏠 默认回滚主卡：【${savedDefault.alias}】');
    }
    buffer.writeln();

    final rows = <List<_TelegramButton>>[];
    for (var i = 0; i < profiles.length; i++) {
      final p = profiles[i];
      final active = p['enabled'] == true;
      final alias = '${p['alias'] ?? ''}';
      final suffix = '${p['iccidSuffix'] ?? ''}';
      final isDefault = savedDefault != null && alias == savedDefault.alias;
      final icon = active ? '🟢 [当前激活]' : '⚪';
      final defBadge = isDefault ? ' 🏠[主卡]' : '';
      buffer.writeln('[${i + 1}] $icon $alias (尾号 $suffix)$defBadge');

      final shortName = _shortAlias(alias);
      if (active) {
        rows.add([
          _TelegramButton('📌 将 #${i + 1} $shortName 设为主卡', 'cmd:default'),
        ]);
      } else {
        rows.add([
          _TelegramButton('🔄 启用 #${i + 1} $shortName', 'use:${i + 1}'),
          _TelegramButton('🗑️ 删 #${i + 1}', 'del:${i + 1}'),
        ]);
      }
    }
    buffer.writeln('\n💡 直接点击下方按钮即可切卡、删卡或下载测试 eSIM（也支持直接粘贴发送 LPA:1\$... 激活码快速下卡）：');
    rows.add(const [
      _TelegramButton('🚀 下载 Speedtest 测试卡', 'cmd:download_test'),
      _TelegramButton('📡 基带状态', 'cmd:status'),
    ]);
    rows.add(const [
      _TelegramButton('🏠 切回默认主卡', 'cmd:back'),
      _TelegramButton('🔄 刷新列表', 'cmd:list'),
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
                _TelegramButton('🔄 刷新信号状态', 'cmd:status'),
                _TelegramButton('📋 卡内 eSIM 列表', 'cmd:list'),
              ],
              [
                _TelegramButton('🏠 切回默认主卡', 'cmd:back'),
                _TelegramButton('🚀 下载 Speedtest 测试卡', 'cmd:download_test'),
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
          if (argument.isEmpty) {
            return await _buildListReply(
              prefixHeader: '💡 请点击下方按钮选择要启用切换的 eSIM 卡位（或发送 /use <序号>）：',
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
              _sendTelegramText('⚡ 已收到切卡指令，正在向 eUICC 芯片下发切换指令...')
                  .catchError((Object _) {}),
            );
            final result = await switchProfile(targetSelector);
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
              '🔄 正在切换至：【${result['target']}】...\n'
              '卡片已切换，正在等待基带漫游搜网驻留，挂上基站后会自动通知您。',
              keyboard: const [
                [
                  _TelegramButton('📡 查看搜网进度', 'cmd:status'),
                  _TelegramButton('🏠 切回默认主卡', 'cmd:back'),
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
                  [_TelegramButton('🔄 重试切换 ($argument)', 'use:$argument')],
                ],
              );
            }
            rethrow;
          }
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
    final lines = <String>[];
    lines.add('📱 网关状态：${value['gateway'] == 'running' ? '🟢 正在运行' : '⚪ 已停止'}');
    if (value['defaultProfile'] != null) {
      lines.add('🏠 默认主卡：${value['defaultProfile']}');
    }
    if (session is Map) {
      final stateStr = session['state'] == 'waiting_for_service'
          ? '⏳ 基带搜网握手中...'
          : '🟢 已就绪（长驻生效中）';
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
    return lines.join('\n');
  }

  Future<void> _sendTelegramText(String text) =>
      _sendTelegramReply(_TelegramReply(text));

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
<section><label for="token">API bearer token (kept in this tab only)</label><input id="token" type="password" autocomplete="off"><p><button id="status">Status</button><button id="list">List profiles</button><button id="default">Set current profile as default</button><button id="back">Return to default</button></p><pre id="output">Enter the API token to control this device.</pre></section>
<section><label for="profile">Profile alias or ICCID</label><input id="profile" autocomplete="off"><p><button id="switch">Switch profile</button><button id="deleteReq">Request delete</button></p><small>Profile selections stay active until you click “Return to default” or send /back.</small></section>
<section><label for="deleteToken">Delete confirmation token</label><input id="deleteToken" autocomplete="off"><p><button id="deleteConfirm">Confirm delete</button></p></section>
<section><label for="ac">Activation code (LPA:1$...)</label><input id="ac" autocomplete="off"><label for="cc">Confirmation code (optional)</label><input id="cc" autocomplete="off"><p><button id="download">Download profile</button><button id="downloadTest">🚀 Download Speedtest Test eSIM</button></p></section>
<script>
const token=document.querySelector('#token'),output=document.querySelector('#output');
async function api(path,method='GET',body){const response=await fetch(path,{method,headers:{Authorization:'Bearer '+token.value,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});const data=await response.json();if(!response.ok)throw new Error(data.error||('HTTP '+response.status));return data}
async function show(path,method='GET',body){try{output.textContent=JSON.stringify(await api(path,method,body),null,2)}catch(error){output.textContent='Request failed: '+error.message}}
document.querySelector('#status').onclick=()=>show('/api/v1/status');
document.querySelector('#list').onclick=()=>show('/api/v1/profiles');
document.querySelector('#default').onclick=()=>show('/api/v1/default','POST',{});
document.querySelector('#back').onclick=()=>show('/api/v1/back','POST',{});
document.querySelector('#switch').onclick=()=>show('/api/v1/switch','POST',{profile:document.querySelector('#profile').value});
document.querySelector('#deleteReq').onclick=()=>show('/api/v1/delete/request','POST',{profile:document.querySelector('#profile').value});
document.querySelector('#deleteConfirm').onclick=()=>show('/api/v1/delete/confirm','POST',{token:document.querySelector('#deleteToken').value});
document.querySelector('#download').onclick=()=>show('/api/v1/download','POST',{activationCode:document.querySelector('#ac').value,confirmationCode:document.querySelector('#cc').value||undefined});
document.querySelector('#downloadTest').onclick=()=>{document.querySelector('#ac').value='LPA:1$rsp.truphone.com$QRF-SPEEDTEST';show('/api/v1/download','POST',{activationCode:'LPA:1$rsp.truphone.com$QRF-SPEEDTEST'})};
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
    String? defaultIccid,
    String? defaultAlias,
  }) => _RemoteSession(
    state: state ?? this.state,
    targetIccid: targetIccid,
    targetAlias: targetAlias,
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
