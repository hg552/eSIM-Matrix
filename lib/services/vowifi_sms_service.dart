import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:nlpa2/vowifi_sms/vowifi_sms_plugin.dart';

import '../adapter/euicc_adapter.dart';
import '../models/euicc_profile.dart';
import 'operator_icon_service.dart';
import 'vowifi_sim_service.dart';
import '../settings/app_settings.dart';
import '../utils/imei_codec.dart';
import '../utils/vowifi_reader_support.dart';

typedef VowifiSmsClientFactory =
    VowifiSmsClient Function({
      required Adapter adapter,
      required Reader reader,
      required VowifiCardInfo info,
      required VowifiSmsConfig config,
      void Function(String line)? onLog,
    });

class _VowifiOperationCancelled extends UnsupportedError {
  _VowifiOperationCancelled()
    : super('VoWiFi was disabled during this operation.');
}

class VowifiSessionInfo {
  VowifiSessionInfo({
    required this.id,
    required this.adapter,
    required this.reader,
    required this.readerId,
    required this.readerName,
    required this.iccid,
    required this.profileName,
    this.profileIcon,
    this.profileCustomIcon = '',
    this.profileResolvedIcon = '',
    required this.client,
  });

  final String id;
  final Adapter adapter;
  final Reader reader;
  final String readerId;
  final String readerName;
  final String iccid;
  final String profileName;
  final Uint8List? profileIcon;
  final String profileCustomIcon;
  final String profileResolvedIcon;
  VowifiSmsClient client;
  final List<VowifiSmsMessage> messages = <VowifiSmsMessage>[];
  StreamSubscription<VowifiSmsEvent>? subscription;
  VowifiSmsConnectionState state = VowifiSmsConnectionState.connecting;
  String? lastInfo;
  String? lastError;
  String associatedIdentity = '';
  List<String> associatedIdentities = <String>[];
  String selectedIdentity = '';
  DateTime? expiresAt;

  Duration get remaining {
    final expiresAt = this.expiresAt;
    if (expiresAt == null) {
      return Duration.zero;
    }
    final diff = expiresAt.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  Future<void> dispose() async {
    await subscription?.cancel();
    await client.disconnect();
  }
}

class VowifiSmsService extends ChangeNotifier {
  VowifiSmsService._()
    : _simService = VowifiSimService(),
      _clientFactory = null;

  @visibleForTesting
  VowifiSmsService.forTesting({
    required VowifiSimService simService,
    VowifiSmsClientFactory? clientFactory,
  }) : _simService = simService,
       _clientFactory = clientFactory;

  static final VowifiSmsService _instance = VowifiSmsService._();
  factory VowifiSmsService() => _instance;

  static final Logger _log = Logger('VowifiSmsService');

  final VowifiSimService _simService;
  final VowifiSmsClientFactory? _clientFactory;
  final Map<String, VowifiSessionInfo> _sessions =
      <String, VowifiSessionInfo>{};
  bool _busy = false;
  int _operationEpoch = 0;
  String? _lastInfo;
  String? _lastError;

  bool get busy => _busy;
  String? get lastInfo => _lastInfo;
  String? get lastError => _lastError;
  List<VowifiSessionInfo> get sessions =>
      _sessions.values.toList(growable: false)
        ..sort((left, right) => left.readerName.compareTo(right.readerName));

  Future<VowifiSessionInfo> connectCurrentCard({
    required Adapter adapter,
    required Reader reader,
    EuiccProfile? activeProfile,
    String sipServerOverride = '',
    void Function(String line)? onLog,
  }) async {
    final operationEpoch = _beginOperation();
    requireVowifiReader(adapter, reader);
    return _runBusy(() async {
      onLog?.call('Loading current SIM from ${reader.name}');
      _log.info('Loading current SIM to VoWiFi reader=${reader.name}');
      final info = await _simService.probe(adapter, reader, onLog: onLog);
      _ensureOperationActive(operationEpoch);
      _log.info(
        'VoWiFi SIM data reader=${reader.name} iccid=${info.iccid} imsi=${info.imsi} smsc=${info.smsc}',
      );
      onLog?.call(
        'Derived SIM info: iccid=${info.iccid} imsi=${info.imsi} smsc=${info.smsc}',
      );
      final config = await _deriveSmsConfig(
        info,
        transport: VowifiTransport.udp,
        tlsSkipVerify: false,
        sipServerOverride: sipServerOverride,
      );
      _ensureOperationActive(operationEpoch);
      onLog?.call(
        'Built IMS config: domain=${config.domain} epdg=${config.epdgServer} sip=${config.sipServer}',
      );
      final sessionId = '${reader.id}:${info.iccid}';
      final existing = _sessions.remove(sessionId);
      if (existing != null) {
        onLog?.call('Replacing existing session for ${info.iccid}');
        await existing.dispose();
        _ensureOperationActive(operationEpoch);
      }

      if (AppSettings().variant != 'qitta' && _sessions.length >= 3) {
        throw StateError(
          'VoWiFi limit: Only 3 active sessions are allowed in this version.',
        );
      }

      final profileResolvedIcon = await _resolveDisplayIcon(
        activeProfile,
        info: info,
      );
      _ensureOperationActive(operationEpoch);

      final client = _buildClient(
        adapter: adapter,
        reader: reader,
        info: info,
        config: config,
        onLog: onLog,
      );

      final session = VowifiSessionInfo(
        id: sessionId,
        adapter: adapter,
        reader: reader,
        readerId: reader.id,
        readerName: reader.name,
        iccid: info.iccid,
        profileName: _displayProfileName(activeProfile, info.iccid),
        profileIcon: activeProfile?.icon,
        profileCustomIcon: activeProfile?.customIcon ?? '',
        profileResolvedIcon: profileResolvedIcon,
        client: client,
      );
      session.subscription = client.events.listen(
        (event) => _handleEvent(session, event),
      );
      _sessions[sessionId] = session;

      _lastError = null;
      _lastInfo = 'Loading ${reader.name} (${info.iccid})';
      onLog?.call('Starting VoWiFi register');
      notifyListeners();

      try {
        _ensureOperationActive(operationEpoch);
        await client.connectAndRegister();
        _ensureOperationActive(operationEpoch);
      } catch (_) {
        await _discardSession(sessionId, session);
        rethrow;
      }
      session.state = VowifiSmsConnectionState.registered;
      session.expiresAt = client.registeredUntil;
      session.associatedIdentity = client.publicIdentity;
      session.associatedIdentities = client.associatedIdentities;
      session.selectedIdentity = client.preferredIdentity;
      session.lastInfo = 'Registered';
      _lastInfo = 'VoWiFi loaded from ${reader.name}';
      onLog?.call('REGISTER succeeded, session added');
      notifyListeners();
      return session;
    });
  }

  Future<void> refreshSession(String sessionId) async {
    final operationEpoch = _beginOperation();
    final session = _sessions[sessionId];
    if (session == null) {
      return;
    }
    try {
      await _runBusy(() async {
        final adapter = session.adapter;
        final reader = session.reader;
        await adapter.connect(reader);
        _ensureOperationActive(operationEpoch);
        await adapter.cleanupChannels();
        _ensureOperationActive(operationEpoch);
        var info = await _simService.probe(adapter, reader);
        _ensureOperationActive(operationEpoch);
        var switchedProfile = false;
        if (info.iccid != session.iccid) {
          _lastInfo =
              'Switching ${reader.name} to ${session.iccid} before refresh';
          notifyListeners();
          await _simService.enableProfileBasic(
            adapter,
            reader,
            iccid: session.iccid,
          );
          _ensureOperationActive(operationEpoch);
          await adapter.reconnect();
          _ensureOperationActive(operationEpoch);
          await adapter.cleanupChannels();
          _ensureOperationActive(operationEpoch);
          info = await _simService.probe(adapter, reader);
          _ensureOperationActive(operationEpoch);
          switchedProfile = true;
          if (info.iccid != session.iccid) {
            throw StateError(
              'Current ICCID ${info.iccid} does not match session ${session.iccid}',
            );
          }
        }
        if (!switchedProfile &&
            session.state == VowifiSmsConnectionState.registered) {
          try {
            await session.client.refreshRegistration();
            _ensureOperationActive(operationEpoch);
            session.expiresAt = session.client.registeredUntil;
            session.lastInfo = 'Registration refreshed';
            notifyListeners();
            return;
          } catch (_) {
            _ensureOperationActive(operationEpoch);
          }
        }
        await session.subscription?.cancel();
        _ensureOperationActive(operationEpoch);
        await session.client.disconnect();
        _ensureOperationActive(operationEpoch);
        final config = await _deriveSmsConfig(
          info,
          transport: VowifiTransport.udp,
          tlsSkipVerify: false,
        );
        _ensureOperationActive(operationEpoch);
        session.client = _buildClient(
          adapter: adapter,
          reader: reader,
          info: info,
          config: config,
        );
        session.subscription = session.client.events.listen(
          (event) => _handleEvent(session, event),
        );
        session.lastInfo = switchedProfile
            ? 'Profile switched, re-authenticating'
            : 'Re-authenticating';
        notifyListeners();
        await session.client.connectAndRegister();
        _ensureOperationActive(operationEpoch);
        session.state = VowifiSmsConnectionState.registered;
        session.expiresAt = session.client.registeredUntil;
        session.associatedIdentity = session.client.publicIdentity;
        session.associatedIdentities = session.client.associatedIdentities;
        session.selectedIdentity = session.client.preferredIdentity;
        session.lastInfo = switchedProfile
            ? 'Profile switched and registration refreshed'
            : 'Registration refreshed';
        notifyListeners();
      });
    } on _VowifiOperationCancelled {
      await _discardSession(sessionId, session);
      rethrow;
    }
  }

  Future<void> disconnectSession(String sessionId) async {
    final session = _sessions.remove(sessionId);
    if (session == null) {
      return;
    }
    await session.dispose();
    _lastInfo = 'Disconnected ${session.profileName}';
    notifyListeners();
  }

  Future<void> disconnectAll() async {
    final ids = _sessions.keys.toList(growable: false);
    for (final id in ids) {
      await disconnectSession(id);
    }
  }

  Future<void> disableAndDisconnect() async {
    _operationEpoch++;
    final sessions = _sessions.values.toList(growable: false);
    _sessions.clear();
    if (sessions.isNotEmpty) notifyListeners();
    for (final session in sessions) {
      try {
        await session.dispose();
      } catch (error, stackTrace) {
        _log.warning(
          'Failed to disconnect VoWiFi session ${session.id} while disabling: $error',
          error,
          stackTrace,
        );
      }
    }
  }

  Future<void> sendTextSms(
    String sessionId, {
    required String to,
    required String text,
  }) async {
    final operationEpoch = _beginOperation();
    final session = _sessions[sessionId];
    if (session == null) {
      throw StateError('Unknown VoWiFi session');
    }
    await _runBusy(() async {
      await session.client.sendTextSms(to, text);
      _ensureOperationActive(operationEpoch);
      session.expiresAt = session.client.registeredUntil;
      notifyListeners();
    });
  }

  void _ensureAvailable() {
    if (!AppSettings().vowifiEnabled) {
      throw UnsupportedError(
        'VoWiFi is disabled or unavailable on this platform or build.',
      );
    }
  }

  int _beginOperation() {
    _ensureAvailable();
    return _operationEpoch;
  }

  void _ensureOperationActive(int operationEpoch) {
    if (!AppSettings().vowifiEnabled || operationEpoch != _operationEpoch) {
      throw _VowifiOperationCancelled();
    }
  }

  Future<void> _discardSession(
    String sessionId,
    VowifiSessionInfo session,
  ) async {
    if (identical(_sessions[sessionId], session)) {
      _sessions.remove(sessionId);
    }
    try {
      await session.dispose();
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to dispose aborted VoWiFi session $sessionId: $error',
        error,
        stackTrace,
      );
    }
  }

  void selectSessionIdentity(String sessionId, String identity) {
    final session = _sessions[sessionId];
    if (session == null) {
      return;
    }
    session.client.setPreferredIdentity(identity);
    session.selectedIdentity = session.client.preferredIdentity;
    if (session.selectedIdentity.isNotEmpty) {
      session.associatedIdentity = session.selectedIdentity;
    }
    notifyListeners();
  }

  void _handleEvent(VowifiSessionInfo session, VowifiSmsEvent event) {
    if (event.state != null) {
      session.state = event.state!;
      if (event.state == VowifiSmsConnectionState.registered) {
        session.expiresAt = session.client.registeredUntil;
        session.associatedIdentity = session.client.publicIdentity;
        session.associatedIdentities = session.client.associatedIdentities;
        session.selectedIdentity = session.client.preferredIdentity;
      }
      if (event.state == VowifiSmsConnectionState.error) {
        session.expiresAt = null;
      }
    }
    if (event.info != null && event.info!.isNotEmpty) {
      session.lastInfo = event.info;
      _lastInfo = event.info;
      _log.info(event.info!);
    }
    if (event.error != null && event.error!.isNotEmpty) {
      session.lastError = event.error;
      _lastError = event.error;
      _log.warning(event.error!);
    }
    if (event.message != null) {
      session.messages.add(event.message!);
    }
    notifyListeners();
  }

  Future<T> _runBusy<T>(Future<T> Function() action) async {
    _busy = true;
    notifyListeners();
    try {
      return await action();
    } catch (error) {
      _lastError = error.toString();
      _log.severe('VoWiFi action failed: $error');
      notifyListeners();
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  String _displayProfileName(EuiccProfile? profile, String iccid) {
    return profile?.nickname ??
        profile?.name ??
        profile?.serviceProviderName ??
        iccid;
  }

  VowifiSmsClient _buildClient({
    required Adapter adapter,
    required Reader reader,
    required VowifiCardInfo info,
    required VowifiSmsConfig config,
    void Function(String line)? onLog,
  }) {
    final clientFactory = _clientFactory;
    if (clientFactory != null) {
      return clientFactory(
        adapter: adapter,
        reader: reader,
        info: info,
        config: config,
        onLog: onLog,
      );
    }

    Future<VowifiAkaResponse> runDigestAka(
      VowifiDigestChallenge challenge,
    ) async {
      onLog?.call('SIP digest AKA challenge received');
      return _simService.authenticateDigestChallenge(
        adapter,
        reader,
        challenge: challenge,
        onLog: onLog,
      );
    }

    return VowifiSmsClient(
      config: config,
      onLog: onLog,
      akaProvider: (challenge) async {
        onLog?.call('IKE/EAP AKA challenge received');
        final aka = await _simService.authenticateIms(
          adapter,
          reader,
          rand: challenge.rand,
          autn: challenge.autn,
          onLog: onLog,
        );
        return VowifiAkaResponse(
          res: aka.res,
          ck: aka.ck,
          ik: aka.ik,
          auts: aka.auts,
        );
      },
      digestAkaProvider: runDigestAka,
      authSecretProvider: (challenge) async {
        final digestAka = await runDigestAka(challenge);
        onLog?.call('Derived AKA RES for SIP digest');
        return _hex(digestAka.res);
      },
    );
  }

  Future<VowifiSmsConfig> _deriveSmsConfig(
    VowifiCardInfo info, {
    required VowifiTransport transport,
    required bool tlsSkipVerify,
    String sipServerOverride = '',
  }) async {
    final imei = imeiDigitsFromStoredBytes(await AppSettings().getImei());
    final imeisv = '${imei.substring(0, 14)}00';
    return _simService.deriveSmsConfig(
      info,
      transport: transport,
      tlsSkipVerify: tlsSkipVerify,
      sipServerOverride: sipServerOverride,
      deviceIdentity: imeisv,
    );
  }

  Future<String> _resolveDisplayIcon(
    EuiccProfile? profile, {
    required VowifiCardInfo info,
  }) async {
    final custom = profile?.customIcon?.trim() ?? '';
    if (custom.isNotEmpty) {
      return custom;
    }
    String mcc = profile?.mcc?.trim() ?? '';
    String mnc = profile?.mnc?.trim() ?? '';
    if ((mcc.isEmpty || mnc.isEmpty) && info.imsi.length >= 5) {
      final mncLength = info.mncLength == 3 ? 3 : 2;
      mcc = info.imsi.substring(0, 3);
      mnc = info.imsi.substring(3, 3 + mncLength);
    }
    if (mcc.isNotEmpty && mnc.isNotEmpty) {
      final resolved = await OperatorIconService().getIcon(
        mcc: mcc,
        mnc: mnc,
        gid1: profile?.gid1,
        gid2: profile?.gid2,
      );
      if ((resolved ?? '').trim().isNotEmpty) {
        return resolved!.trim();
      }
    }
    return '';
  }

  String _hex(List<int> bytes) =>
      bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}
