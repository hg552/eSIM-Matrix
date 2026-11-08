import '../adapter/composite_adapter.dart';
import '../adapter/euicc_adapter.dart';
import '../adapter/omapi/omapi_safety.dart';
import '../adapter/se_hal_adapter.dart';
import '../logic/profile_manager.dart';
import '../models/euicc_profile.dart';
import '../plugins/build_plugin_registry.dart';
import '../services/network_status_service.dart';
import '../services/notification_service.dart';
import '../services/profile_metadata_service.dart';
import '../settings/app_settings.dart';
import '../utils/apdu_exception.dart';
import '../utils/error_codes.dart';
import '../utils/foreground_card_session.dart';
import '../utils/profile_tag_utils.dart';
import 'transfer_downloader.dart';
class RemoteProfileEntry {
  const RemoteProfileEntry({
    required this.iccid,
    required this.rawIccid,
    required this.alias,
    required this.enabled,
  });

  final String iccid;
  final String rawIccid;
  final String alias;
  final bool enabled;
}

class RemoteCardResourceInfo {
  const RemoteCardResourceInfo({
    this.eid,
    this.freeNonVolatileMemoryBytes,
    this.freeVolatileMemoryBytes,
  });

  final String? eid;
  final int? freeNonVolatileMemoryBytes;
  final int? freeVolatileMemoryBytes;

  Map<String, Object?> toJson() => {
    'eid': eid,
    'freeNonVolatileMemoryBytes': freeNonVolatileMemoryBytes,
    'freeVolatileMemoryBytes': freeVolatileMemoryBytes,
  };
}

class RemoteReaderEntry {
  const RemoteReaderEntry({
    required this.id,
    required this.name,
    required this.selected,
  });

  final String id;
  final String name;
  final bool selected;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'selected': selected,
  };
}

abstract interface class RemoteProfileControl {
  String? get selectedReaderId;
  int? get networkSlotIndex;
  Stream<NetworkStatusUpdate> get networkUpdates;
  Future<void> refreshNetworkStatus();
  Future<List<RemoteProfileEntry>> listProfiles();
  Future<void> enableProfile(String iccid);
  Future<String> downloadProfile(
    String activationCode, {
    String? confirmationCode,
    void Function(String message)? onStatus,
  });
  Future<void> deleteProfile(String iccid);
  Future<void> purgeSwitchNotifications();
  Future<RemoteCardResourceInfo> getCardResourceInfo() async =>
      const RemoteCardResourceInfo();
  Future<void> renameProfile(String iccid, String nickname) async =>
      throw UnsupportedError('renameProfile');
  Future<List<RemoteReaderEntry>> listReaders() async =>
      const <RemoteReaderEntry>[];
  Future<RemoteReaderEntry> selectReader(String selector) async =>
      throw UnsupportedError('selectReader');
  Future<bool> accelerateNetworkSearch() async => false;
}
class LpaRemoteProfileControl implements RemoteProfileControl {
  LpaRemoteProfileControl({
    CompositeAdapter? adapter,
    Duration verificationDelay = const Duration(milliseconds: 1500),
  }) : _adapter = adapter ?? CompositeAdapter(),
       _verificationDelay = verificationDelay {
    _manager = ProfileManager(_adapter);
    for (final plugin in BuildPluginRegistry.createSessionPlugins()) {
      _manager.addSessionPlugin(plugin);
    }
  }

  final CompositeAdapter _adapter;
  late final ProfileManager _manager;
  final NetworkStatusService _networkStatus = const NetworkStatusService();
  final Duration _verificationDelay;
  List<RemoteProfileEntry>? _cachedProfiles;
  RemoteCardResourceInfo? _cachedResourceInfo;
  String? _cachedReaderId;
  DateTime? _profilesCachedAt;
  DateTime? _resourceCachedAt;
  @override
  String? get selectedReaderId => AppSettings().lastSelectedReader;

  @override
  int? get networkSlotIndex => _slotIndex(selectedReaderId);

  @override
  Stream<NetworkStatusUpdate> get networkUpdates => _networkStatus.updates;

  @override
  Future<void> refreshNetworkStatus() => _networkStatus.refresh();

  @override
  Future<bool> accelerateNetworkSearch() =>
      _networkStatus.accelerateNetworkSearch();

  @override
  Future<List<RemoteProfileEntry>> listProfiles() async {
    final reader = await _selectedReader();
    final profiles = await _readProfiles(reader);
    _cachedProfiles = profiles;
    _cachedReaderId = reader.id;
    _profilesCachedAt = DateTime.now();
    return profiles;
  }
  @override
  Future<void> enableProfile(String iccid) async {
    ForegroundCardSession.begin();
    try {
      final reader = await _selectedReader();
      final now = DateTime.now();
      final profiles = (_cachedProfiles != null &&
              _cachedReaderId == reader.id &&
              _profilesCachedAt != null &&
              now.difference(_profilesCachedAt!) < const Duration(seconds: 10))
          ? _cachedProfiles!
          : await _readProfiles(reader);
      final candidates = profiles.where((profile) => profile.iccid == iccid).toList();
      final target = candidates.isEmpty ? null : candidates.first;
      if (target == null) throw StateError('profile_not_found');
      if (target.enabled) return;

      if (reader.source is SeHalAdapter) {
        await _adapter.runExclusive(() async {
          await _adapter.connect(reader);
          final updated = await _manager.switchHalProfileAndVerify(target.iccid, true);
          if (!updated.any((profile) => profile.iccid == target.iccid && profile.enabled)) {
            throw StateError('profile_enable_not_verified');
          }
        });
        _cachedProfiles = null;
        return;
      }

      Future<void> submitEnable() async {
        var refreshRequested = false;
        await _adapter.runExclusive(() async {
          await _adapter.connect(reader);
          var switchMarkerSet = false;
          try {
            await _adapter.setProfileSwitchInProgress(true);
            switchMarkerSet = true;
            final channel = await _manager.openSession();
            try {
              final isRefresh = await _manager.enableProfile(
                target.rawIccid,
                useChannel: channel,
              );
              if (isRefresh) {
                refreshRequested = true;
              }
            } finally {
              try {
                await channel.close();
              } catch (closeError) {
                if (isOmapiSessionCorruptedError(closeError)) rethrow;
              }
            }
          } finally {
            if (switchMarkerSet) {
              await _adapter.setProfileSwitchInProgress(false);
            }
          }
        });
        if (refreshRequested) {
          await _adapter.proactiveRefresh();
        }
      }

      try {
        await submitEnable();
        _cachedProfiles = null;
        return;
      } catch (error) {
        if (!_isTransientSwitchError(error)) rethrow;
        await Future<void>.delayed(_verificationDelay);
        try {
          await _adapter.reconnect();
        } catch (reconnectError) {
          if (!_isTransientSwitchError(reconnectError)) rethrow;
        }
        try {
          final current = await _readProfiles(reader);
          if (current.where((p) => p.iccid == target.iccid).firstOrNull?.enabled == true) {
            _cachedProfiles = null;
            return;
          }
        } catch (readError) {
          if (!_isTransientSwitchError(readError)) rethrow;
        }
        await submitEnable();
        _cachedProfiles = null;
      }
    } finally {
      ForegroundCardSession.end();
    }
  }

  @override
  Future<String> downloadProfile(
    String activationCode, {
    String? confirmationCode,
    void Function(String message)? onStatus,
  }) async {
    ForegroundCardSession.begin();
    try {
      final reader = await _selectedReader();
      final downloader = TransferDownloader(
        manager: _manager,
        adapter: _adapter,
        reader: reader,
      );
      final result = await downloader.downloadInstallEnable(
        activationCode: activationCode,
        confirmationCode: confirmationCode,
        enableAfterInstall: false,
        onStatus: onStatus,
      );
      _cachedProfiles = null;
      return result.iccid ?? '';
    } finally {
      ForegroundCardSession.end();
    }
  }

  @override
  Future<void> deleteProfile(String iccid) async {
    ForegroundCardSession.begin();
    try {
      final reader = await _selectedReader();
      final profiles = await _readProfiles(reader);
      final target = profiles.where((p) => p.iccid == iccid).firstOrNull;
      if (target == null) throw StateError('profile_not_found');
      if (target.enabled) {
        throw StateError('cannot_delete_active_profile');
      }

      await _adapter.runExclusive(() async {
        await _adapter.connect(reader);
        final channel = await _manager.openSession();
        try {
          await _manager.deleteProfile(target.rawIccid, useChannel: channel);
          final settings = AppSettings();
          if (settings.notifProcessAfterDeletion &&
              settings.isAnyNotificationProcessingEnabled) {
            try {
              await NotificationService().processPendingNotifications(
                _manager,
                channel,
                readerName: reader.id,
                autoSendInstall: settings.notifAutoSendInstall,
                autoRemoveInstall: settings.notifAutoRemoveInstall,
                autoSendEnable: settings.notifAutoSendEnable,
                autoRemoveEnable: settings.notifAutoRemoveEnable,
                deleteWithoutSendingEnable: settings.notifDeleteWithoutSendingEnable,
                autoSendDisable: settings.notifAutoSendDisable,
                autoRemoveDisable: settings.notifAutoRemoveDisable,
                deleteWithoutSendingDisable: settings.notifDeleteWithoutSendingDisable,
                autoSendDelete: settings.notifAutoSendDelete,
                autoRemoveDelete: settings.notifAutoRemoveDelete,
              );
            } catch (_) {}
          }
        } finally {
          try {
            await channel.close();
          } catch (_) {}
        }
      });
      _cachedProfiles = null;
    } finally {
      ForegroundCardSession.end();
    }
  }

  @override
  Future<void> purgeSwitchNotifications() async {
    final settings = AppSettings();
    if (!settings.notifProcessAfterSwitch ||
        !settings.isAnyNotificationProcessingEnabled ||
        ForegroundCardSession.isOpen) {
      return;
    }
    try {
      final reader = await _selectedReader();
      await _adapter.runExclusive(() async {
        if (ForegroundCardSession.isOpen) return;
        await _adapter.connect(reader);
        final channel = await _manager.openSession();
        try {
          await NotificationService().processPendingNotifications(
            _manager,
            channel,
            readerName: reader.id,
            autoSendInstall: settings.notifAutoSendInstall,
            autoRemoveInstall: settings.notifAutoRemoveInstall,
            autoSendEnable: settings.notifAutoSendEnable,
            autoRemoveEnable: settings.notifAutoRemoveEnable,
            deleteWithoutSendingEnable: settings.notifDeleteWithoutSendingEnable,
            autoSendDisable: settings.notifAutoSendDisable,
            autoRemoveDisable: settings.notifAutoRemoveDisable,
            deleteWithoutSendingDisable: settings.notifDeleteWithoutSendingDisable,
            autoSendDelete: settings.notifAutoSendDelete,
            autoRemoveDelete: settings.notifAutoRemoveDelete,
          );
        } finally {
          try {
            await channel.close();
          } catch (_) {}
        }
      });
    } catch (_) {}
  }

  @override
  Future<RemoteCardResourceInfo> getCardResourceInfo() async {
    try {
      final reader = await _selectedReader();
      final now = DateTime.now();
      if (_cachedResourceInfo != null &&
          _cachedReaderId == reader.id &&
          _resourceCachedAt != null &&
          now.difference(_resourceCachedAt!) < const Duration(seconds: 30)) {
        return _cachedResourceInfo!;
      }
      return await _adapter.runExclusive(() async {
        await _adapter.connect(reader);
        final channel = await _manager.openSession();
        try {
          final info = await _readResourceInfoOnChannel(channel);
          _cachedResourceInfo = info;
          _cachedReaderId = reader.id;
          _resourceCachedAt = DateTime.now();
          return info;
        } finally {
          try {
            await channel.close();
          } catch (_) {}
        }
      });
    } catch (_) {
      return _cachedResourceInfo ?? const RemoteCardResourceInfo();
    }
  }

  @override
  Future<void> renameProfile(String iccid, String nickname) async {
    final trimmed = nickname.trim();
    if (trimmed.isEmpty) throw StateError('invalid_nickname');
    ForegroundCardSession.begin();
    try {
      final reader = await _selectedReader();
      await _adapter.runExclusive(() async {
        await _adapter.connect(reader);
        final channel = await _manager.openSession();
        try {
          final rawProfiles = await _manager.listProfiles(
            useChannel: channel,
            requireKnownState: true,
          );
          final target = rawProfiles.where((p) => p.iccid == iccid).firstOrNull;
          if (target == null) throw StateError('profile_not_found');
          final parsed = ProfileTagUtils.parse(target.nickname);
          final fullNickname = ProfileTagUtils.format(trimmed, parsed.tags);
          await _manager.renameProfile(
            target.iccid,
            fullNickname,
            useChannel: channel,
          );
          try {
            final metaService = await ProfileMetadataService.getInstance();
            final existing = await metaService.getProfile(target.iccid);
            if (existing != null) {
              await metaService.saveProfile(
                iccid: target.iccid,
                nickname: fullNickname,
                name: existing.name,
                providerName: existing.providerName,
                mcc: existing.mcc,
                mnc: existing.mnc,
                enabled: existing.enabled,
                profileClass: existing.profileClass,
                profileSize: existing.profileSize,
                gid1: existing.gid1,
                gid2: existing.gid2,
                tags: parsed.tags.map((t) => t.raw).toList(),
                eid: existing.eid,
              );
            }
          } catch (_) {}
        } finally {
          try {
            await channel.close();
          } catch (_) {}
        }
      });
      _cachedProfiles = null;
    } finally {
      ForegroundCardSession.end();
    }
  }

  static const String _estkAidSe0 = 'A06573746B6D65FFFF4953442D522030';
  static const String _estkAidSe1 = 'A06573746B6D65FFFF4953442D522031';

  @override
  Future<List<RemoteReaderEntry>> listReaders() async {
    final readers = await _adapter.listReaders(force: true);
    String? selectedId = AppSettings().lastSelectedReader;
    if ((selectedId == null || !readers.any((r) => r.id == selectedId)) &&
        readers.isNotEmpty) {
      try {
        final current = await _selectedReader();
        selectedId = current.id;
      } catch (_) {}
    }
    final entries = readers
        .map(
          (r) => RemoteReaderEntry(
            id: r.id,
            name: r.name,
            selected: r.id == selectedId,
          ),
        )
        .toList();
    final atr = (_adapter.lastAtr ?? '').toUpperCase();
    if (atr.contains('6573746B6D65') && selectedId != null) {
      final workingAid =
          (_manager.getWorkingAid(selectedId) ??
                  AppSettings().getPreferredEstkAid(selectedId, atr) ??
                  _estkAidSe0)
              .toUpperCase();
      entries.add(
        RemoteReaderEntry(
          id: 'estk:SE0',
          name: 'ESTK Max SE0 (主芯片)',
          selected: workingAid == _estkAidSe0,
        ),
      );
      entries.add(
        RemoteReaderEntry(
          id: 'estk:SE1',
          name: 'ESTK Max SE1 (副芯片)',
          selected: workingAid == _estkAidSe1,
        ),
      );
    }
    return entries;
  }

  @override
  Future<RemoteReaderEntry> selectReader(String selector) async {
    final normalized = selector.trim();
    if (normalized.isEmpty) throw StateError('reader_not_found');
    final lower = normalized.toLowerCase();
    if (lower == 'estk:se0' ||
        lower == 'se0' ||
        lower == 'estk:se1' ||
        lower == 'se1') {
      final isSe1 = lower.endsWith('se1');
      final targetAid = isSe1 ? _estkAidSe1 : _estkAidSe0;
      final current = await _selectedReader();
      _manager.setWorkingAid(current.id, targetAid);
      final atr = _adapter.lastAtr;
      if (atr != null && atr.isNotEmpty) {
        await AppSettings().setPreferredEstkAid(current.id, atr, targetAid);
      }
      _cachedProfiles = null;
      _cachedResourceInfo = null;
      return RemoteReaderEntry(
        id: isSe1 ? 'estk:SE1' : 'estk:SE0',
        name: isSe1 ? 'ESTK Max SE1 (副芯片)' : 'ESTK Max SE0 (主芯片)',
        selected: true,
      );
    }
    final readers = await _adapter.listReaders(force: true);
    if (readers.isEmpty) throw StateError('selected_reader_unavailable');
    Reader? matched;
    final index = int.tryParse(normalized);
    if (index != null && index >= 1 && index <= readers.length) {
      matched = readers[index - 1];
    }
    matched ??= readers
        .where((r) => r.id.toLowerCase() == normalized.toLowerCase())
        .firstOrNull;
    matched ??= readers
        .where(
          (r) =>
              r.id.toLowerCase().contains(normalized.toLowerCase()) ||
              r.name.toLowerCase().contains(normalized.toLowerCase()),
        )
        .firstOrNull;
    if (matched == null) throw StateError('reader_not_found');
    await AppSettings().setLastSelectedReader(matched.id);
    _cachedProfiles = null;
    _cachedResourceInfo = null;
    _cachedReaderId = null;
    try {
      await _networkStatus.refresh();
    } catch (_) {}
    return RemoteReaderEntry(
      id: matched.id,
      name: matched.name,
      selected: true,
    );
  }

  Future<Reader> _selectedReader() async {
    final readerId = AppSettings().lastSelectedReader;
    final readers = await _adapter.listReaders(force: true);
    if (readerId != null && readerId.isNotEmpty) {
      final matches = readers.where((reader) => reader.id == readerId).toList();
      if (matches.length == 1) return matches.single;
    }
    final sim2 = readers.where((r) => r.id.toLowerCase().contains('sim2') || r.name.toLowerCase().contains('sim 2')).toList();
    if (sim2.isNotEmpty) {
      final r = sim2.first;
      await AppSettings().setLastSelectedReader(r.id);
      return r;
    }
    if (readers.isNotEmpty) {
      final r = readers.first;
      await AppSettings().setLastSelectedReader(r.id);
      return r;
    }
    throw StateError('selected_reader_unavailable');
  }

  Future<RemoteCardResourceInfo> _readResourceInfoOnChannel(Channel channel) async {
    String? eid;
    int? freeNvm;
    int? freeRam;
    try {
      eid = await _manager.getEid(useChannel: channel);
    } catch (_) {}
    try {
      final info2 = await _manager.getEuiccInfo2(useChannel: channel);
      freeNvm = info2.extCardResource?.freeNonVolatileMemory;
      freeRam = info2.extCardResource?.freeVolatileMemory;
    } catch (_) {}
    return RemoteCardResourceInfo(
      eid: eid,
      freeNonVolatileMemoryBytes: freeNvm,
      freeVolatileMemoryBytes: freeRam,
    );
  }

  Future<List<RemoteProfileEntry>> _readProfiles(Reader reader) async {
    return _adapter.runExclusive(() async {
      await _adapter.connect(reader);
      final channel = await _manager.openSession();
      try {
        final profiles = await _manager.listProfiles(
          useChannel: channel,
          requireKnownState: true,
        );
        _cachedResourceInfo = await _readResourceInfoOnChannel(channel);
        _resourceCachedAt = DateTime.now();
        return profiles
            .map(_toRemoteProfile)
            .toList(growable: false);
      } finally {
        await channel.close();
      }
    });
  }

  RemoteProfileEntry _toRemoteProfile(EuiccProfile profile) => RemoteProfileEntry(
    iccid: profile.iccid,
    rawIccid: profile.rawIccid,
    alias: profile.displayName,
    enabled: profile.enabled,
  );

  bool _isTransientSwitchError(Object error) {
    if (isOmapiSessionCorruptedError(error)) return false;
    final errorStr = error.toString();
    if (errorStr.contains('ENABLE_FAILED:') ||
        errorStr.contains('DISABLE_FAILED:')) {
      return false;
    }
    if (error is CardBusyException ||
        error is ConditionOfUseNotSatisfiedException ||
        error is ProactiveRefreshException) {
      return true;
    }
    if (error is! AppException) return false;
    return error.code == AppErrorCode.ERROR_BLUETOOTH_TIMEOUT ||
        error.code == AppErrorCode.ERROR_BLUETOOTH_NOT_CONNECTED ||
        error.code == AppErrorCode.ERROR_BLUETOOTH_CONNECT_FAILED ||
        error.code == AppErrorCode.ERROR_BLUETOOTH_DISABLED ||
        error.code == AppErrorCode.ERROR_OMAPI_READER_NOT_AVAILABLE ||
        error.code == AppErrorCode.ERROR_OMAPI_CHANNEL_OPEN_FAILED ||
        error.code == AppErrorCode.ERROR_OMAPI_TRANSMIT_FAILED;
  }
  static int? _slotIndex(String? readerId) {
    if (readerId == null) return null;
    final match = RegExp(r'(?:SIM|slot)[^0-9]*([1-9][0-9]*)', caseSensitive: false)
        .firstMatch(readerId);
    final slot = int.tryParse(match?.group(1) ?? '');
    return slot == null ? null : slot - 1;
  }
}
