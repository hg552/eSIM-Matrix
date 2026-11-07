import 'dart:async';
import 'dart:typed_data';
import '../utils/platform_adapter.dart';
import 'euicc_adapter.dart';
import 'discovery_report.dart';
import 'ccid/ccid_adapter.dart';
import 'webcard/web_card_adapter.dart';
import 'ble/red_ble_adapter.dart';
import 'ble/red_ble2_adapter.dart';

import 'ble/ble_adapter.dart';
import 'ble/sim_link_adapter.dart';
import 'ble/nble_sim_adapter.dart';
import 'ble/bee_sim_adapter.dart';
import 'ble/ble_manager.dart';
import 'nbridge/nbridge_adapter.dart';
import 'adb_bridge/adb_bridge_adapter.dart';
import 'omapi/omapi_adapter.dart';
import 'omapi/omapi_safety.dart';
import 'telephony/telephony_adapter.dart';
import 'scrp/scrp_adapter.dart';
import 'qrtr/qrtr_reader_adapter.dart';
import 'qrtr/qrtr_host.dart';
import 'se_hal_adapter.dart';

import 'remote/remocard_adapter.dart';
import '../settings/app_settings.dart';
import '../config.dart';
import '../logic/profile_manager.dart';
import 'package:logging/logging.dart';
import '../utils/error_codes.dart';
import '../utils/foreground_card_session.dart';

class CompositeAdapter extends BaseAdapter {
  static final CompositeAdapter _instance = CompositeAdapter._internal();
  factory CompositeAdapter() => _instance;
  CompositeAdapter._internal() : super(Logger('CompositeAdapter')) {
    _setupSimChangeListeners();
  }

  final StreamController<Map<String, dynamic>> _simChangeEventController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get simChangeEventStream =>
      _simChangeEventController.stream;

  final CcidAdapter _ccidAdapter = CcidAdapter();
  final WebCardAdapter _webCardAdapter = WebCardAdapter();
  final NBridgeAdapter _nbridgeAdapter = NBridgeAdapter();
  final AdbBridgeAdapter _adbBridgeAdapter = AdbBridgeAdapter();
  final OmapiAdapter _omapiAdapter = OmapiAdapter();
  final TelephonyAdapter _telephonyAdapter = TelephonyAdapter();
  final ScrpAdapter _scrpAdapter = ScrpAdapter();
  final QrtrReaderAdapter _qrtrAdapter = QrtrReaderAdapter();
  final SeHalAdapter _seHalAdapter = SeHalAdapter();
  final Logger _log = Logger('CompositeAdapter');

  Future<Reader?> scanScrp() => _scrpAdapter.scanScrp();

  Future<void> setAppInBackground(bool value) async {
    if (PlatformX.isAndroid) await _omapiAdapter.setAppInBackground(value);
  }

  final Map<String, RemoCardAdapter> _remoteAdapters = {};
  final Set<String> _remoteInitTried = {};

  // Debouncing for SIM change events
  Timer? _simChangeDebounceTimer;
  DateTime? _lastSimChangeEvent;
  String? _lastSimState; // Track last state to avoid duplicate processing
  static const Duration _simChangeDebounceDelay = Duration(seconds: 2);
  Future<List<Reader>>? _listReadersFuture;

  Adapter? _connectedAdapter;
  Reader? _currentReader;

  BaseAdapter _createBleAdapter(BleAdapterType type) => switch (type) {
    BleAdapterType.redBle => RedBleAdapter(),
    BleAdapterType.redBle2 => RedBle2Adapter(),
    BleAdapterType.glocalMe || BleAdapterType.nineEsim => NBLESimAdapter(),
    BleAdapterType.beeSim => BeeSimAdapter(),
    BleAdapterType.simLink => SimLinkAdapter(),
    _ => BleAdapterType.kindOf(type)?.createAdapter() ?? RedBleAdapter(),
  };

  final StreamController<EuiccPortState> _stateController =
      StreamController<EuiccPortState>.broadcast();

  @override
  Stream<EuiccPortState> get stateStream => _stateController.stream;

  @override
  bool get requiresRefresh => _connectedAdapter?.requiresRefresh ?? false;

  @override
  String? get lastAtr => _connectedAdapter?.lastAtr;

  @override
  ReaderStrategy get readerStrategy =>
      _connectedAdapter?.readerStrategy ?? ReaderStrategy.fast;

  @override
  NotificationStrategy get notificationStrategy =>
      _connectedAdapter?.notificationStrategy ?? NotificationStrategy.combined;

  @override
  String? get simIccid => _connectedAdapter?.simIccid;

  @override
  Reader? get connectedReader => _currentReader;

  @override
  List<AdapterAction> get extraActions =>
      connectedReader?.source.extraActions ?? [];

  // Cache available readers to help bridging old generic UI calls if needed,
  // or simply because we might want to lookup by ID.
  final Map<String, Reader> _readerCache = {};
  final Set<String> _hiddenDuplicateAndroidReaderIds = {};

  @override
  Future<List<Reader>> listReaders({bool force = false}) async {
    if (!force && _listReadersFuture != null) return await _listReadersFuture!;

    _listReadersFuture = _doListReaders(force: force);
    try {
      return await _listReadersFuture!;
    } finally {
      _listReadersFuture = null;
    }
  }

  ReaderDiscoveryReport? _lastDiscoveryReport;

  /// What the most recent reader scan asked each source and what each answered.
  ReaderDiscoveryReport? get lastDiscoveryReport => _lastDiscoveryReport;

  String _describeReader(Reader r) => '${r.id} -> ${r.name}';

  /// Why SE HAL listed no slot, in the terms the handset actually answered.
  String _seHalDetail({
    required bool authorised,
    required ReaderPlatformInfo platform,
  }) {
    if (!authorised) {
      return 'Shizuku is running but this app is not authorised yet; '
          'tapping an SE HAL reader asks for the permission '
          '(SoC: ${platform.socLabel})';
    }
    if (!platform.secureElementFeature) {
      return 'Shizuku is authorised, but this ROM does not publish '
          'android.hardware.secure_element, so the HAL has no SIM slot to '
          'offer (SoC: ${platform.socLabel})';
    }
    return 'Shizuku is authorised and the HAL is published, but no SIM slot '
        'was listed: check that the card seats in the slot, or that the slot '
        'is not disabled by the ROM (SoC: ${platform.socLabel})';
  }

  Future<List<Reader>> _doListReaders({bool force = false}) async {
    Object? omapiDiscoveryFailure;
    if (force) {
      _remoteInitTried.clear();
    }
    final Map<String, Reader> uniqueReaders = {};
    final sources = <DiscoverySourceResult>[];
    final scanStart = DateTime.now();
    _log.info('Reader discovery started (force=$force)');

    void addReaders(List<Reader> list) {
      _log.info("Adding ${list.length} readers to uniqueReaders");
      for (final r in list) {
        uniqueReaders[r.id] = r;
      }
    }

    void skipped(String source, String reason) {
      _log.info('Discovery [$source]: skipped ($reason)');
      sources.add(
        DiscoverySourceResult(
          source: source,
          status: DiscoveryStatus.skipped,
          detail: reason,
        ),
      );
    }

    /// Runs one reader source. Never throws: a failing source is recorded and
    /// the scan carries on with the others, as it always did.
    ///
    /// [softError] covers adapters that swallow their own failure and answer
    /// an empty list; [detail] adds context to a source that did answer.
    Future<void> probe(
      String source,
      Future<List<Reader>> Function() list, {
      required String failureLog,
      void Function(Object error)? onError,
      String? Function()? softError,
      String? Function()? detail,
    }) async {
      final timer = Stopwatch()..start();
      try {
        final found = await list();
        addReaders(found);
        final soft = softError?.call();
        _log.info(
          'Discovery [$source]: ${found.length} reader(s) in '
          '${timer.elapsedMilliseconds} ms${soft == null ? '' : ' (error: $soft)'}',
        );
        sources.add(
          DiscoverySourceResult(
            source: source,
            status: soft == null ? DiscoveryStatus.ok : DiscoveryStatus.error,
            readerNames: found.map(_describeReader).toList(),
            detail: soft ?? (found.isEmpty ? detail?.call() : null),
            elapsed: timer.elapsed,
          ),
        );
      } catch (e) {
        _log.warning('$failureLog: $e');
        onError?.call(e);
        sources.add(
          DiscoverySourceResult(
            source: source,
            status: DiscoveryStatus.error,
            detail: e.toString(),
            elapsed: timer.elapsed,
          ),
        );
      }
    }
    // TODO: cache is now removed

    // 1. Identify existing non-transient readers to preserve from cache
    final preserved = <String>[];
    for (final r in _readerCache.values) {
      if (r.source is RemoCardAdapter) {
        uniqueReaders[r.id] = r;
        preserved.add(_describeReader(r));
      } else if (r.source is BleAdapter) {
        if (AppSettings().enableBleConnector) {
          uniqueReaders[r.id] = r;
          preserved.add(_describeReader(r));
        }
      }
    }
    if (preserved.isNotEmpty) {
      sources.add(
        DiscoverySourceResult(
          source: 'Kept from previous scan (remote/BLE)',
          status: DiscoveryStatus.ok,
          readerNames: preserved,
        ),
      );
    }

    // 2. Load session BLE readers from BleManager
    if (AppSettings().enableBleConnector) {
      final added = <String>[];
      for (final info in BleManager().sessionReaders) {
        final id = info.readerName;
        if (!uniqueReaders.containsKey(id)) {
          final source = _createBleAdapter(info.type);
          final reader = Reader(id: id, name: info.name, source: source);
          uniqueReaders[id] = reader;
          added.add(_describeReader(reader));
        }
      }
      _log.info('Discovery [BLE session]: ${added.length} reader(s)');
      sources.add(
        DiscoverySourceResult(
          source: 'BLE session readers',
          status: DiscoveryStatus.ok,
          readerNames: added,
        ),
      );
    } else {
      skipped('BLE session readers', 'BLE connector is off in settings');
    }

    // 3. Load Remote slots if auto-load is enabled
    if (AppSettings().autoLoadRemoteDevices) {
      final remoteErrors = <String>[];
      final remoteNames = <String>[];
      final List<Future<List<Reader>>> futures = [];
      for (final url in AppSettings().remoCardUrls) {
        // Only trigger auto-load discovery ONCE per URL per session
        if (!_remoteInitTried.contains(url)) {
          final adapter = _remoteAdapters.putIfAbsent(
            url,
            () => RemoCardAdapter(url),
          );
          futures.add(
            adapter
                .listReaders()
                .timeout(const Duration(seconds: 3))
                .then((list) {
                  _remoteInitTried.add(url);
                  return list;
                })
                .catchError((e) {
                  _log.warning("Failed to auto-load from $url: $e");
                  _remoteInitTried.add(url); // Don't try again if it failed
                  remoteErrors.add('$url: $e');
                  return <Reader>[];
                }),
          );
        }
      }

      if (futures.isNotEmpty) {
        try {
          final results = await Future.wait(futures);
          for (final list in results) {
            addReaders(list);
            remoteNames.addAll(list.map(_describeReader));
          }
        } catch (e) {
          _log.warning("Auto-load remote failed: $e");
          remoteErrors.add(e.toString());
        }
      }
      sources.add(
        DiscoverySourceResult(
          source: 'Remote auto-load',
          status: remoteErrors.isEmpty
              ? DiscoveryStatus.ok
              : DiscoveryStatus.error,
          readerNames: remoteNames,
          detail: remoteErrors.isNotEmpty
              ? remoteErrors.join('; ')
              : (futures.isEmpty
                    ? 'no URL left to try (each is tried once per session)'
                    : null),
        ),
      );
    } else {
      skipped('Remote auto-load', 'auto-load is off in settings');
    }

    // The modem's own bus, which needs no cable at all: the card is the
    // handset's, reached through the process Shizuku runs.
    if (PlatformX.isAndroid) {
      // Both of these answer an empty list when they cannot run at all, which
      // the report would otherwise show as "ran and found nothing".
      final platform = await QrtrHost.platformInfo();
      final shizukuRunning = await QrtrHost.isAvailable();
      final authorised = shizukuRunning && await QrtrHost.hasPermission();

      if (!AppSettings().enableQrtrConnector) {
        skipped('QRTR modem', 'QRTR connector is off in settings');
      } else if (!platform.isQualcomm) {
        skipped(
          'QRTR modem',
          'no QRTR bus on ${platform.socLabel}: QRTR is a Qualcomm-only modem '
              'bus, so this transport cannot work on this handset — use '
              'Built-in OMAPI, SE HAL, OTBridge (root) or a BLE/USB reader',
        );
      } else if (!shizukuRunning) {
        skipped(
          'QRTR modem',
          'Shizuku is not installed or not running; the bus socket can only '
              'be opened by the shell user',
        );
      } else if (!authorised) {
        skipped(
          'QRTR modem',
          'Shizuku is running but this app is not authorised in Shizuku',
        );
      } else {
        await probe(
          'QRTR modem',
          () => _qrtrAdapter.listReaders(force: force),
          failureLog: 'QRTR modem list failed',
          detail: () => 'Qualcomm QRTR bus is reachable but listed no card slot',
        );
      }

      if (!AppSettings().enableSeHalConnector) {
        skipped('SE HAL', 'SE HAL connector is off in settings');
      } else if (!shizukuRunning) {
        skipped(
          'SE HAL',
          'Shizuku is not installed or not running; the Secure Element HAL '
              'answers only to the shell user',
        );
      } else {
        await probe(
          'SE HAL',
          () => _seHalAdapter.listReaders(force: force),
          failureLog: 'SE HAL reader list failed',
          detail: () => _seHalDetail(
            authorised: authorised,
            platform: platform,
          ),
        );
      }
    }

    // 4. CCID
    if (AppSettings().enableCcidConnector) {
      await probe(
        'CCID (USB)',
        () => _ccidAdapter.listReaders(),
        failureLog: 'CCID list failed',
      );
    } else {
      skipped('CCID (USB)', 'CCID connector is off in settings');
    }

    // 5. NBridge-backed Android secure element access
    if (PlatformX.isAndroid) {
      final useNBridge = await _nbridgeAdapter.isAvailable(
        forceRefresh: force,
      );
      if (useNBridge) {
        await probe(
          'OTBridge',
          () => _nbridgeAdapter.listReaders(force: force),
          failureLog: 'Failed to list NBridge readers',
        );
      } else {
        skipped('OTBridge', 'provider not installed or not reachable');
      }

      // 5b. ADB-bridge-backed access, when a shell helper is connected
      if (await _adbBridgeAdapter.isAvailable()) {
        await probe(
          'ADB bridge',
          () => _adbBridgeAdapter.listReaders(force: force),
          failureLog: 'Failed to list ADB bridge readers',
        );
      } else {
        skipped('ADB bridge', 'no shell helper connected');
      }

      // 6. Built-in OMAPI
      if (AppSettings().enableOmapiConnector) {
        await probe(
          'Built-in OMAPI',
          () => _omapiAdapter.listReaders(force: force),
          failureLog: 'Failed to list OMAPI readers',
          onError: (e) {
            if (isOmapiSessionCorruptedError(e)) omapiDiscoveryFailure = e;
          },
          softError: () => _omapiAdapter.lastListError,
          detail: () {
            final raw = _omapiAdapter.lastRawReaders;
            return 'native readers: $raw — the ROM exposes no SIM slot to app '
                'OMAPI; use SE HAL via Shizuku, OTBridge (root) or a BLE/USB '
                'reader instead';
          },
        );
      } else {
        skipped('Built-in OMAPI', 'OMAPI connector is off in settings');
      }

      // 7. Built-in Telephony
      if (kIsPrivileged && AppSettings().enableTmapiConnector) {
        await probe(
          'Telephony (TMAPI)',
          () => _telephonyAdapter.listReaders(),
          failureLog: 'Failed to list Telephony readers',
        );
      } else {
        skipped(
          'Telephony (TMAPI)',
          kIsPrivileged
              ? 'TMAPI connector is off in settings'
              : 'needs the privileged (system) build',
        );
      }
    }

    // 8. Scrp WebUSB (Web only)
    if (PlatformX.isWeb) {
      await probe(
        'WebUSB (SCRP)',
        () => _scrpAdapter.listReaders(),
        failureLog: 'Failed to list Scrp readers',
      );

      // 9. WebCard (Web only)
      if (AppSettings().enableCcidConnector) {
        await probe(
          'WebCard',
          () => _webCardAdapter.listReaders(),
          failureLog: 'Failed to list WebCard readers',
        );
      }
    }

    if (PlatformX.isAndroid) {
      await _deduplicateAndroidEuiccReaders(uniqueReaders);
    }

    // 7. Update cache and return
    _readerCache.clear();
    for (final r in uniqueReaders.values) {
      _readerCache[r.id] = r;
    }

    final corruption = omapiDiscoveryFailure;
    final fatal = uniqueReaders.isEmpty && corruption != null;
    _log.info(
      'Reader discovery finished: ${uniqueReaders.length} reader(s)'
      '${fatal ? ' (OMAPI session corrupted)' : ''}',
    );
    _lastDiscoveryReport = ReaderDiscoveryReport(
      at: scanStart,
      forced: force,
      sources: List.unmodifiable(sources),
      totalReaders: uniqueReaders.length,
      failure: fatal ? corruption.toString() : null,
    );

    if (fatal) {
      // Show the reboot-required error instead of the unrelated Bluetooth/empty-reader prompt.
      throw corruption;
    }
    return uniqueReaders.values.toList();
  }

  Future<void> _deduplicateAndroidEuiccReaders(
    Map<String, Reader> readers,
  ) async {
    if (readers.length < 2) return;

    final candidates = readers.values
        .where(_isLocalAndroidEuiccReader)
        .toList(growable: false);
    if (candidates.length < 2) return;

    final probes = <_ReaderEidProbe>[];
    for (final reader in candidates) {
      var eid = reader.eid;
      if ((eid == null || eid.isEmpty) && _connectedAdapter == null) {
        eid = await _probeReaderEid(reader);
      }
      if (eid == null || eid.isEmpty) continue;
      probes.add(_ReaderEidProbe(reader, eid));
    }

    if (probes.length < 2) {
      if (_connectedAdapter != null) {
        readers.removeWhere(
          (id, reader) =>
              id != _currentReader?.id &&
              _isLocalAndroidEuiccReader(reader) &&
              _hiddenDuplicateAndroidReaderIds.contains(id),
        );
      }
      return;
    }

    final bestByEid = <String, _ReaderEidProbe>{};
    for (final probe in probes) {
      final existing = bestByEid[probe.eid];
      if (existing == null ||
          probe.reader.id == _currentReader?.id ||
          existing.reader.id != _currentReader?.id &&
              _androidReaderPriority(probe.reader) >
                  _androidReaderPriority(existing.reader)) {
        bestByEid[probe.eid] = probe;
      }
    }

    for (final probe in probes) {
      if (bestByEid[probe.eid]?.reader.id != probe.reader.id) {
        readers.remove(probe.reader.id);
        _hiddenDuplicateAndroidReaderIds.add(probe.reader.id);
        _log.info(
          'Hiding duplicate Android reader ${probe.reader.id}; same EID as ${bestByEid[probe.eid]!.reader.id}',
        );
      } else {
        _hiddenDuplicateAndroidReaderIds.remove(probe.reader.id);
      }
    }
  }

  bool _isLocalAndroidEuiccReader(Reader reader) {
    return reader.source is NBridgeAdapter ||
        reader.source is AdbBridgeAdapter ||
        reader.source is OmapiAdapter ||
        reader.source is TelephonyAdapter;
  }

  int _androidReaderPriority(Reader reader) {
    if (reader.source is NBridgeAdapter && reader.id.startsWith('tmapi:')) {
      return 40;
    }
    if (reader.source is NBridgeAdapter && reader.id.startsWith('omapi:')) {
      return 35;
    }
    if (reader.source is TelephonyAdapter) return 30;
    if (reader.source is OmapiAdapter) return 20;
    if (reader.source is NBridgeAdapter) return 10;
    return 0;
  }

  Future<String?> _probeReaderEid(Reader reader) async {
    // Opening a session here alongside a download would give two sessions on
    // one adapter, and the first to finish closes the shared logical channel
    // under the other (6881). The probe only labels a reader for
    // disambiguation, so it is safe to give up instead.
    if (ForegroundCardSession.isOpen) {
      _log.info('EID probe skipped for ${reader.id}: the card is in use');
      return null;
    }
    final adapter = reader.source as BaseAdapter;
    try {
      await adapter.connect(reader);
      final manager = ProfileManager(adapter);
      final channel = await manager.openSession();
      try {
        final eid = await manager.getEid(useChannel: channel);
        reader.eid = eid;
        return eid;
      } finally {
        await channel.close();
      }
    } catch (e) {
      _log.info('EID probe failed for ${reader.id}: $e');
      return null;
    } finally {
      try {
        await adapter.disconnect();
      } catch (_) {}
    }
  }

  /// Manually load remote RemoCard readers
  Future<List<Reader>> loadRemoteReaders() async {
    final List<Reader> remoteReaders = [];
    Object? lastError;

    for (final url in AppSettings().remoCardUrls) {
      try {
        final adapter = RemoCardAdapter(url);
        remoteReaders.addAll(await adapter.listReaders());
      } catch (e) {
        _log.warning('Failed to list RemoCard readers at $url: $e');
        if (e is RemoCardInvalidPasswordException) {
          lastError = e;
        }
      }
    }

    if (remoteReaders.isEmpty && lastError != null) {
      if (lastError is Exception) throw lastError;
      throw AppException(
        AppErrorCode.ERROR_REMOTE_CONNECTION_FAILED,
        originalError: lastError,
      );
    }

    // Update cache and internal list
    for (final r in remoteReaders) {
      _readerCache[r.id] = r;
    }

    return remoteReaders;
  }

  void removeReader(String readerId) {
    if (_readerCache.containsKey(readerId)) {
      final reader = _readerCache[readerId]!;
      _readerCache.remove(readerId);

      // Also remove from persistence
      if (reader.source is RemoCardAdapter) {
        final url = (reader.source as RemoCardAdapter).baseUrl;
        if (url != null) {
          AppSettings().removeRemoCardUrl(url);
        }
      } else if (reader.source is BleAdapter) {
        // Extract ID from name "type: name|ID"
        final parts = readerId.split('|');
        if (parts.length > 1) {
          BleManager().removeReader(parts.last);
        }
      }

      _log.info("Manually removed reader: $readerId");
    }
  }

  @override
  String? get currentEid => _connectedAdapter?.currentEid;
  @override
  set currentEid(String? value) {
    if (_connectedAdapter != null) {
      _connectedAdapter!.currentEid = value;
    }
  }

  @override
  Future<void> connect(Reader reader) async {
    // Check if connector is enabled
    if (reader.source is BleAdapter) {
      if (!AppSettings().enableBleConnector) {
        throw AppException(
          AppErrorCode.ERROR_BLUETOOTH_PERMISSION_DENIED,
          message: "Bluetooth connector is disabled",
        );
      }
    } else if (reader.source is CcidAdapter ||
        reader.source is WebCardAdapter) {
      if (!AppSettings().enableCcidConnector) {
        throw AppException(
          AppErrorCode.ERROR_OMAPI_PERMISSION_DENIED,
          message: "CCID connector is disabled",
        );
      }
    } else if (reader.source is OmapiAdapter) {
      if (!AppSettings().enableOmapiConnector) {
        throw AppException(
          AppErrorCode.ERROR_OMAPI_NOT_SUPPORTED,
          message: "OMAPI connector is disabled",
        );
      }
    } else if (reader.source is TelephonyAdapter) {
      if (!AppSettings().enableTmapiConnector) {
        throw AppException(
          AppErrorCode.ERROR_OMAPI_NOT_SUPPORTED,
          message: "Telephony connector is disabled",
        );
      }
    } else if (reader.source is ScrpAdapter) {
      // Always enabled for now or check setting if desired
    } else if (reader.source is QrtrReaderAdapter) {
      if (!AppSettings().enableQrtrConnector) {
        throw AppException(
          AppErrorCode.ERROR_OMAPI_PERMISSION_DENIED,
          message: "QRTR connector is disabled",
        );
      }
    }

    return await runExclusive(() async {
      if (reader.source is SeHalAdapter) {
        if (!AppSettings().enableSeHalConnector) {
          throw AppException(
            AppErrorCode.ERROR_OMAPI_PERMISSION_DENIED,
            message: "SE HAL connector is disabled",
          );
        }
        (reader.source as SeHalAdapter).validateReaderSettings(reader);
      }
      if (_connectedAdapter != null &&
          identical(_connectedAdapter, reader.source) &&
          _currentReader?.id == reader.id &&
          _connectedAdapter!.connectedReader?.id == reader.id) {
        _log.info("Already connected to ${reader.name}, skipping reconnect.");
        return;
      }

      await disconnect();

      _currentReader = reader;
      final delegate = reader.source as BaseAdapter;
      _connectedAdapter = delegate;

      // Relay the delegate's steps while this connect runs: the UI listens
      // here, not to the reader's own adapter.
      void relayProgress() =>
          connectProgress.value = delegate.connectProgress.value;
      delegate.connectProgress.addListener(relayProgress);
      try {
        await delegate.runExclusive(() => delegate.connect(reader));
        _stateController.add(EuiccPortState.open);
      } catch (e) {
        // A failed or interrupted delegate connect can still own a partially
        // established transport. Keep it as the cleanup owner while clearing
        // the reader fast path; a later disconnect/connect will tear it down.
        _currentReader = null;
        _stateController.add(EuiccPortState.closed);
        rethrow;
      } finally {
        delegate.connectProgress.removeListener(relayProgress);
        connectProgress.value = null;
      }
    });
  }

  @override
  Future<void> disconnect() async {
    return await runExclusive(() async {
      if (_connectedAdapter != null) {
        final delegate = _connectedAdapter!;
        await delegate.runExclusive(delegate.disconnect);
        _connectedAdapter = null;
        _currentReader = null;
      }
      _stateController.add(EuiccPortState.closed);
    });
  }

  @override
  void interruptPendingOperation() {
    // Deliberately bypass this adapter's exclusive lock: an interrupt must be
    // able to wake the operation that currently owns that lock.
    final interruptedAdapter = _connectedAdapter;
    interruptedAdapter?.interruptPendingOperation();
    // Do not let a later ordinary connect mistake the interrupted transport
    // for a healthy connection merely because the reader ID still matches.
    // Retain the delegate as the cleanup owner: its interrupt is deliberately
    // synchronous and cannot tear down GATT listeners while its operation owns
    // the delegate lock. The next disconnect/connect can then cleanly dispose
    // that interrupted transport.
    _currentReader = null;
    _stateController.add(EuiccPortState.closed);
  }

  @override
  Future<void> reconnect() async {
    return await runExclusive(() async {
      final adapter = _connectedAdapter;
      if (adapter == null) return;
      if (adapter is SeHalAdapter) {
        // Keep both connection states in sync, including failed reopen attempts.
        await super.reconnect();
        return;
      }
      try {
        await adapter.runExclusive(() async {
          // The selected reader survives a link drop; its transport does not.
          final reader = _currentReader;
          if (reader != null && adapter.connectedReader?.id != reader.id) {
            await disconnect();
            await connect(reader);
          } else {
            await adapter.reconnect();
          }
        });
      } catch (_) {
        // The delegate may already have disconnected before its reconnect
        // failed. Invalidate the reader fast path while retaining the delegate
        // as the cleanup owner for the next disconnect/connect attempt.
        _currentReader = null;
        _stateController.add(EuiccPortState.closed);
        rethrow;
      }
    });
  }

  @override
  Future<void> cleanupChannels() async {
    if (_connectedAdapter != null) {
      await _connectedAdapter!.cleanupChannels();
    }
  }

  @override
  Future<void> setProfileSwitchInProgress(bool value) async {
    if (_connectedAdapter != null) {
      await _connectedAdapter!.setProfileSwitchInProgress(value);
    }
  }

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) async {
    if (_connectedAdapter == null) {
      throw AppException(AppErrorCode.ERROR_UNKNOWN, message: "Not connected");
    }
    return await _connectedAdapter!.sendRawApdu(apdu);
  }

  @override
  Future<void> proactiveRefresh() async {
    if (_connectedAdapter != null) {
      log.info(
        "Delegating proactiveRefresh to ${_connectedAdapter.runtimeType}...",
      );
      await _connectedAdapter!.proactiveRefresh();
    }
  }

  @override
  Future<bool?> isCatBusy() async => _connectedAdapter?.isCatBusy();

  @override
  Future<bool?> isServingProfile() async =>
      _connectedAdapter?.isServingProfile();

  @override
  Future<void> resetAfterProfileSwitch() async {
    if (_connectedAdapter != null) {
      log.info(
        "Delegating resetAfterProfileSwitch to "
        "${_connectedAdapter.runtimeType}...",
      );
      await _connectedAdapter!.resetAfterProfileSwitch();
    }
  }

  @override
  Future<Channel> openChannel({List<String>? aids}) async {
    return await runExclusive(() async {
      if (_connectedAdapter == null) {
        throw AppException(
          AppErrorCode.ERROR_UNKNOWN,
          message: "Not connected",
        );
      }
      return await _connectedAdapter!.openChannel(aids: aids);
    });
  }

  void _setupSimChangeListeners() {
    if (PlatformX.isAndroid) {
      _omapiAdapter.simStateStream.listen((event) => _handleSimEvent(event));
      _telephonyAdapter.simStateStream.listen(
        (event) => _handleSimEvent(event),
      );
    }
  }

  void _handleSimEvent(Map<String, dynamic> event) {
    final now = DateTime.now();

    // Log the event but don't process it immediately
    _log.info('SIM change event detected: $event');

    final type = event['type'];

    if (type == 'se_service_connected') {
      // Availability changed after asynchronous binding. Refresh discovery without treating it as
      // a SIM reset, which would reconnect an active card operation.
      _omapiAdapter.invalidateReaderCache();
      _readerCache.clear();
      _simChangeEventController.add(event);
      return;
    }

    // Only process actual SIM state change events
    if (type == 'sim_state_changed') {
      final state = event['state'] ?? 'N/A';
      _log.info('SIM/SE event: $type, state: $state');

      // Cancel any existing debounce timer
      _simChangeDebounceTimer?.cancel();

      // Check if we should ignore this event (too soon after last one)
      if (_lastSimChangeEvent != null) {
        final timeSinceLastEvent = now.difference(_lastSimChangeEvent!);
        if (timeSinceLastEvent < const Duration(milliseconds: 500)) {
          _log.info(
            'Ignoring rapid SIM event (${timeSinceLastEvent.inMilliseconds}ms since last)',
          );
          // Still update the timer but don't log as much
          _lastSimChangeEvent = now;

          // Set a new debounce timer
          _simChangeDebounceTimer = Timer(_simChangeDebounceDelay, () {
            _processSimChangeEvent(type, state);
          });
          return;
        }
      }

      _lastSimChangeEvent = now;

      // Set a debounce timer - only process if no new events come in
      _simChangeDebounceTimer = Timer(_simChangeDebounceDelay, () {
        _processSimChangeEvent(type, state);
      });
    }
  }

  void _processSimChangeEvent(String type, String state) {
    _log.info('Processing debounced SIM event: $type, state: $state');

    // Check if this is actually a new state
    final stateKey = '$type:$state';
    if (_lastSimState == stateKey) {
      _log.info('SIM state unchanged ($stateKey), skipping processing');
      return;
    }

    _log.info('SIM state changed from $_lastSimState to $stateKey');
    _lastSimState = stateKey;

    // ACTION_SIM_STATE_CHANGED values: ABSENT, PIN_REQUIRED, PUK_REQUIRED, NETWORK_LOCKED, READY, NOT_READY, PERM_DISABLED, CARD_IO_ERROR, CARD_RESTRICTED, LOADED, UNKNOWN.
    // We are mostly interested in cases where a card might have been swapped or initialized.

    // 1. Reload currently connected OMAPI and TMAPI devices
    if (_connectedAdapter == _omapiAdapter ||
        _connectedAdapter == _telephonyAdapter) {
      _log.info('SIM change while connected, requesting reconnect...');
      // Small delay to let system stabilize
      Future.delayed(const Duration(milliseconds: 1500), () {
        reconnect().catchError(
          (e) => _log.warning('Auto-reconnect after SIM change failed: $e'),
        );
      });
    }

    // 2. Clear cache and inform listeners (like ProfilesScreen) so they can refresh reader list
    _readerCache.clear();
    _simChangeEventController.add({'type': type, 'state': state});
  }
}

class _ReaderEidProbe {
  final Reader reader;
  final String eid;

  const _ReaderEidProbe(this.reader, this.eid);
}
