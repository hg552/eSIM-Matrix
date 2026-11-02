/// Headless BeeSIM-over-BLE download harness.
///
/// Drives the same path the download page does -- scan, connect, ES10/ES9+
/// authenticate, then STORE DATA the bound profile package -- with no UI to
/// click, so a transfer can be repeated and its failure point compared across
/// runs. Build it as a debug macOS app and launch it through LaunchServices,
/// which is what resolves CoreBluetooth's TCC grant:
///
///     flutter build macos --debug -t lib/main_bletest.dart
///     open build/macos/Build/Products/Debug/NekokoLPA.app
///
/// Reads /private/tmp/nlpa-bletest.json:
///     {"code": "LPA:1$smdp$matchingId", "runs": 3, "scanOnly": false}
/// and writes a transcript to /private/tmp/nlpa-bletest.log plus a machine
/// readable summary to /private/tmp/nlpa-bletest-result.json. Those live in
/// /private/tmp because DebugProfile.entitlements grants it; the sandbox
/// container is unreadable to anything collecting the results afterwards.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:ble/ble.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import 'adapter/ble/bee_sim_adapter.dart';
import 'adapter/ble/ble_adapter.dart';
import 'adapter/euicc_adapter.dart';
import 'l10n/app_localizations.dart';
import 'logic/profile_download_session.dart';
import 'logic/profile_manager.dart';
import 'models/activation_code.dart';
import 'models/asn1/rsp_definitions.g.dart';
import 'services/db_init_native.dart';
import 'services/es9plus_service.dart';
import 'services/log_buffer.dart';
import 'settings/app_settings.dart';
import 'utils/crypto_utils.dart';
import 'utils/hex_utils.dart';
import 'widgets/profiles_screen/connect_step_message.dart';

const String _configPath = '/private/tmp/nlpa-bletest.json';
const String _transcriptPath = '/private/tmp/nlpa-bletest.log';
const String _resultPath = '/private/tmp/nlpa-bletest-result.json';

final Logger _log = Logger('BleTest');
final ValueNotifier<String> _status = ValueNotifier<String>('starting');

io.IOSink? _transcript;

void _say(String message) {
  final line = '${DateTime.now().toIso8601String()} $message';
  _transcript?.writeln(line);
  _log.info(message);
  _status.value = message;
}

Uint8List _b64(dynamic value, String field) {
  if (value is! String || value.isEmpty) {
    throw Exception('Missing $field in SM-DP+ response');
  }
  return base64Decode(value.replaceAll(RegExp(r'\s+'), ''));
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Logger.root.level = Level.ALL;
  LogBuffer().init();
  await LogBuffer().startFileLogging();
  Logger.root.onRecord.listen((record) {
    io.stdout.writeln(
      '${record.level.name}: ${record.time}: ${record.loggerName}: '
      '${record.message}',
    );
  });

  _transcript = io.File(_transcriptPath).openWrite(mode: io.FileMode.write);

  await initDb();
  await AppSettings().init();

  runApp(const _HarnessApp());

  unawaited(_runAll());
}

class _HarnessApp extends StatelessWidget {
  const _HarnessApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ValueListenableBuilder<String>(
              valueListenable: _status,
              builder: (context, value, _) =>
                  Text(value, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _runAll() async {
  final results = <Map<String, dynamic>>[];
  try {
    final config =
        jsonDecode(io.File(_configPath).readAsStringSync())
            as Map<String, dynamic>;
    final runs = (config['runs'] as num?)?.toInt() ?? 1;
    final scanOnly = config['scanOnly'] == true;
    final mss = (config['mss'] as num?)?.toInt();
    if (mss != null) {
      await AppSettings().setMss(mss);
      _say('mss overridden to $mss');
    }
    _say('config: runs=$runs scanOnly=$scanOnly mss=${AppSettings().mss}');

    for (var run = 1; run <= runs; run++) {
      _say('=== run $run/$runs ===');
      final started = DateTime.now();
      try {
        final outcome = await _runOnce(config, scanOnly: scanOnly);
        outcome['run'] = run;
        outcome['ok'] = true;
        outcome['seconds'] =
            DateTime.now().difference(started).inMilliseconds / 1000.0;
        results.add(outcome);
        _say('run $run OK: ${jsonEncode(outcome)}');
      } catch (e, st) {
        final failure = <String, dynamic>{
          'run': run,
          'ok': false,
          'error': e.toString(),
          'seconds': DateTime.now().difference(started).inMilliseconds / 1000.0,
          'lastProgress': _lastProgress,
        };
        results.add(failure);
        _say('run $run FAILED: $e');
        _transcript?.writeln(st.toString());
      }
      io.File(_resultPath).writeAsStringSync(jsonEncode(results));
      await _transcript?.flush();
      if (run < runs) await Future.delayed(const Duration(seconds: 3));
    }
  } catch (e, st) {
    _say('harness aborted: $e');
    _transcript?.writeln(st.toString());
    results.add({'ok': false, 'error': e.toString()});
  }

  io.File(_resultPath).writeAsStringSync(jsonEncode(results));
  _say('harness finished');
  await _transcript?.flush();
  await _transcript?.close();
}

Map<String, dynamic>? _lastProgress;

Future<Map<String, dynamic>> _runOnce(
  Map<String, dynamic> config, {
  required bool scanOnly,
}) async {
  _lastProgress = null;

  // --- Scan -------------------------------------------------------------
  _say('waiting for the Bluetooth adapter');
  final state = await Ble.adapterState
      .where((s) => s == BluetoothAdapterState.on)
      .first
      .timeout(const Duration(seconds: 15));
  _say('adapter state: $state');

  final seen = <String, ScanResult>{};
  final sub = Ble.scanResults.listen((results) {
    for (final r in results) {
      final advName = r.advertisementData.advName;
      final platformName = r.device.platformName;
      final displayName = platformName.isEmpty ? advName : platformName;
      final id = r.device.remoteId.toString();
      if (!seen.containsKey(id)) {
        _say(
          'found "$displayName" ($id) rssi=${r.rssi} '
          'connectable=${r.advertisementData.connectable} '
          'services=${r.advertisementData.serviceUuids}',
        );
      }
      seen[id] = r;
    }
  });

  _say('scanning');
  await Ble.startScan(
    withServices: const [],
    withKeywords: const [
      'ESTKme',
      'eSIM_Writer',
      'BeeSIM',
      'GlocalMe',
      '9eSIM',
    ],
    continuousUpdates: true,
    timeout: const Duration(seconds: 12),
  );
  await Future.delayed(const Duration(seconds: 13));
  await Ble.stopScan();
  await sub.cancel();

  ScanResult? picked;
  for (final r in seen.values) {
    final advName = r.advertisementData.advName;
    final platformName = r.device.platformName;
    final displayName = platformName.isEmpty ? advName : platformName;
    final type = BleAdapterType.fromDeviceNames(
      displayName: displayName,
      advertisedName: advName,
    );
    if (type == BleAdapterType.beeSim) {
      picked = r;
      break;
    }
  }

  if (scanOnly) {
    return {
      'devices': seen.values
          .map(
            (r) => {
              'id': r.device.remoteId.toString(),
              'platformName': r.device.platformName,
              'advName': r.advertisementData.advName,
              'rssi': r.rssi,
              'connectable': r.advertisementData.connectable.toString(),
            },
          )
          .toList(),
      'beeSimFound': picked != null,
    };
  }

  if (picked == null) {
    throw Exception(
      'No BeeSIM advertised. Saw: '
      '${seen.values.map((r) => r.device.platformName.isEmpty ? r.advertisementData.advName : r.device.platformName).toList()}',
    );
  }

  final deviceId = picked.device.remoteId.toString();
  final advName = picked.advertisementData.advName;
  final displayName = picked.device.platformName.isEmpty
      ? advName
      : picked.device.platformName;
  _say('using BeeSIM "$displayName" ($deviceId)');

  // --- Connect ----------------------------------------------------------
  final adapter = BeeSimAdapter();
  final reader = Reader(
    id: '${BleAdapterType.beeSim.id}: $displayName|$deviceId',
    name: displayName,
    source: adapter,
  );
  // Record each step as the profiles screen would show it, so a connect that
  // stalls names the step it stalled on.
  final l10n = lookupAppLocalizations(const Locale('en'));
  void sayConnectStep() {
    final progress = adapter.connectProgress.value;
    if (progress != null) {
      _say('connect step: ${connectStepMessage(l10n, progress)}');
    }
  }

  adapter.connectProgress.addListener(sayConnectStep);
  try {
    await adapter.connect(reader);
  } finally {
    adapter.connectProgress.removeListener(sayConnectStep);
  }
  _say('connected; atr=${adapter.lastAtr}');

  final pm = ProfileManager(adapter);
  final channel = await pm.openSession();
  _say('logical channel open');

  try {
    if (config['inspect'] == true) {
      return await _inspect(pm, channel);
    }
    if (config['notification'] == true) {
      return await _notification(pm, channel);
    }
    final deleteIccids = (config['deleteIccids'] as List?)?.cast<String>();
    if (deleteIccids != null && deleteIccids.isNotEmpty) {
      return await _delete(pm, channel, deleteIccids);
    }
    return await _download(config, pm, channel);
  } finally {
    try {
      await channel.close();
    } catch (e) {
      _say('channel close failed: $e');
    }
    try {
      await adapter.disconnect();
    } catch (e) {
      _say('disconnect failed: $e');
    }
  }
}

/// Read-only look at what the card already holds, so a one-shot activation
/// code is not spent on a card that has no room for the profile.
Future<Map<String, dynamic>> _inspect(
  ProfileManager pm,
  Channel channel,
) async {
  final info2 = await pm.getEuiccInfo2(useChannel: channel);
  final free = info2.extCardResource?.freeNonVolatileMemory;
  _say('free non-volatile memory: $free bytes');

  final profiles = await pm.listProfiles(useChannel: channel);
  for (final p in profiles) {
    _say(
      'profile iccid=${p.iccid} enabled=${p.enabled} '
      'spn=${p.serviceProviderName} name=${p.name} class=${p.profileClass}',
    );
  }

  return {
    'freeNonVolatileMemory': free,
    'profiles': profiles
        .map(
          (p) => {
            'iccid': p.iccid,
            'enabled': p.enabled,
            'serviceProviderName': p.serviceProviderName,
            'name': p.name,
            'profileClass': p.profileClass,
          },
        )
        .toList(),
  };
}

/// Deletes exactly the profiles named in [iccids] and nothing else.
///
/// Only an explicit display-ICCID match is removed, and an enabled profile is
/// always skipped: this exists to undo profiles a test loop installed, not to
/// clear a card.
Future<Map<String, dynamic>> _delete(
  ProfileManager pm,
  Channel channel,
  List<String> iccids,
) async {
  final before = await pm.getEuiccInfo2(useChannel: channel);
  _say('free before: ${before.extCardResource?.freeNonVolatileMemory} bytes');

  final profiles = await pm.listProfiles(useChannel: channel);
  final deleted = <String>[];
  final skipped = <String>[];

  for (final wanted in iccids) {
    final match = profiles.where((p) => p.iccid == wanted).firstOrNull;
    if (match == null) {
      _say('skip $wanted: not on the card');
      skipped.add(wanted);
      continue;
    }
    if (match.enabled) {
      _say('skip $wanted: profile is enabled');
      skipped.add(wanted);
      continue;
    }
    _say(
      'deleting $wanted (raw ${match.rawIccid}, spn=${match.serviceProviderName})',
    );
    await pm.deleteProfile(match.rawIccid, useChannel: channel);
    deleted.add(wanted);
  }

  final after = await pm.getEuiccInfo2(useChannel: channel);
  final freeAfter = after.extCardResource?.freeNonVolatileMemory;
  _say('free after: $freeAfter bytes');

  return {
    'deleted': deleted,
    'skipped': skipped,
    'freeBefore': before.extCardResource?.freeNonVolatileMemory,
    'freeAfter': freeAfter,
  };
}

/// Exercises the install-failure diagnostic against a real card.
Future<Map<String, dynamic>> _notification(
  ProfileManager pm,
  Channel channel,
) async {
  final metadata = await pm.listNotifications(useChannel: channel);
  _say('card holds ${metadata.length} notifications');

  final started = DateTime.now();
  final notification = await pm.getLatestInstallNotification(
    useChannel: channel,
  );
  final elapsed = DateTime.now().difference(started).inMilliseconds;

  _say('raw notification: $notification');

  final data =
      notification?.profileInstallationResult?.profileInstallationResultData;
  final finalResult = data?.finalResult;
  _say(
    'latest install notification in ${elapsed}ms: '
    'seq=${data?.notificationMetadata?.seqNumber} '
    'error=${finalResult?.errorResult?.errorReason?.name} '
    'cmd=${finalResult?.errorResult?.bppCommandId?.name} '
    'success=${finalResult?.successResult != null}',
  );

  return {
    'notificationCount': metadata.length,
    'retrievedSeq': data?.notificationMetadata?.seqNumber,
    'errorReason': finalResult?.errorResult?.errorReason?.name,
    'elapsedMs': elapsed,
  };
}

Future<Map<String, dynamic>> _download(
  Map<String, dynamic> config,
  ProfileManager pm,
  Channel channel,
) async {
  final ac = ActivationCode.parse((config['code'] as String).trim());
  if (ac == null) throw Exception('Unparsable activation code');
  _say('smdp=${ac.smdpAddress} matchingIdLength=${ac.matchingId.length}');

  final challenge = await pm.getEuiccChallenge(useChannel: channel);
  final info1 = await pm.getEuiccInfo1(useChannel: channel);
  final eid = await pm.getEid(useChannel: channel);
  _say('eid=$eid');

  final confirmationCode = config['confirmationCode'] as String?;
  final session = ProfileDownloadSession(
    smdpAddress: ac.smdpAddress,
    matchingId: ac.matchingId,
    confirmationCode: confirmationCode,
  );
  session.processEuiccInfo1(info1);
  session.processEuiccChallenge(challenge);

  _say('ES9+ initiateAuthentication');
  final initAuthReq = session.getInitiateAuthenticationRequest();
  final initAuthResp = await Es9PlusService().initiateAuthentication(
    smdpAddress: ac.smdpAddress,
    euiccChallenge: base64Encode(initAuthReq.euiccChallenge!),
    euiccInfo1: base64Encode(initAuthReq.euiccInfo1!.encode()),
    clientTransactionId: '0',
  );
  final serverSigned1 = _b64(initAuthResp['serverSigned1'], 'serverSigned1');
  final serverSignature1 = _b64(
    initAuthResp['serverSignature1'],
    'serverSignature1',
  );
  final euiccCiPKId = _b64(
    initAuthResp['euiccCiPKIdToBeUsed'],
    'euiccCiPKIdToBeUsed',
  );
  final serverCert = _b64(
    initAuthResp['serverCertificate'],
    'serverCertificate',
  );
  final txnId = initAuthResp['transactionId'] as String;
  session.processInitiateAuthenticationResponse(
    'Executed-Success',
    txnId,
    serverCert,
  );
  _say('transactionId=$txnId');

  _say('ES10 authenticateServer');
  final authServerResp = await pm.authenticateServer(
    serverSigned1: serverSigned1,
    serverSignature1: serverSignature1,
    euiccCiPKIdToBeUsed: euiccCiPKId,
    serverCertificate: serverCert,
    matchingId: ac.matchingId,
    useChannel: channel,
  );
  session.processAuthenticateServerResponse(authServerResp);

  _say('ES9+ authenticateClient');
  final authClientReq = session.getAuthenticateClientRequest();
  final clientResp = await Es9PlusService().authenticateClient(
    smdpAddress: ac.smdpAddress,
    transactionId: txnId,
    authenticateServerResponse: base64Encode(
      authClientReq.authenticateServerResponse!.encode(),
    ),
  );
  final metadataBytes = _b64(clientResp['profileMetadata'], 'profileMetadata');
  final metadata = StoreMetadataRequest.decode(metadataBytes);
  _say(
    'metadata: iccid=${metadata.iccid != null ? HexUtils.bytesToHex(metadata.iccid!) : 'null'} '
    'provider=${metadata.serviceProviderName} '
    'estimatedSize=${metadata.estimatedProfileSize}',
  );

  session.processAuthenticateClientResponse(
    'Executed-Success',
    AuthenticateClientResponseEs9(
      authenticateClientOk: AuthenticateClientOk(
        transactionId: session.getTransactionId(),
        profileMetadata: metadata,
        smdpSigned2: SmdpSigned2.decode(
          _b64(clientResp['smdpSigned2'], 'smdpSigned2'),
        ),
        smdpSignature2: _b64(clientResp['smdpSignature2'], 'smdpSignature2'),
        smdpCertificate: Certificate.decode(
          _b64(clientResp['smdpCertificate'], 'smdpCertificate'),
        ),
      ),
    ),
  );
  if (!session.isClientAuthenticatedSuccessfully()) {
    throw Exception('Client authentication failed');
  }

  Uint8List? hashCc;
  if (session.confirmationCode != null) {
    hashCc = CryptoUtils.computeHashCc(
      session.confirmationCode!,
      session.getTransactionId()!,
    );
  }

  _say('ES10 prepareDownload');
  final prepareResp = await pm.prepareDownload(
    smdpSigned2: session.getSmdpSigned2()!.encode(),
    smdpSignature2: session.getSmdpSignature2()!,
    smdpCertificate: session.getServerCertificate()!,
    hashCc: hashCc,
    useChannel: channel,
  );

  _say('ES9+ getBoundProfilePackage');
  final bppResp = await Es9PlusService().getBoundProfilePackage(
    smdpAddress: ac.smdpAddress,
    transactionId: txnId,
    prepareDownloadResponse: base64Encode(prepareResp.encode()),
  );
  final bpp = _b64(bppResp['boundProfilePackage'], 'boundProfilePackage');
  _say('bound profile package: ${bpp.length} bytes');

  final loadStarted = DateTime.now();
  var lastLoggedPercent = -1;
  await pm.loadBoundProfilePackage(
    bpp,
    useChannel: channel,
    onProgress: (sent, total) {
      _lastProgress = {
        'sent': sent,
        'total': total,
        'percent': total == 0 ? 0 : (sent * 100 / total).round(),
        'elapsed':
            DateTime.now().difference(loadStarted).inMilliseconds / 1000.0,
      };
      final percent = total == 0 ? 0 : (sent * 100 ~/ total);
      if (percent != lastLoggedPercent && percent % 5 == 0) {
        lastLoggedPercent = percent;
        _say(
          'install $percent% ($sent/$total) '
          't=${DateTime.now().difference(loadStarted).inMilliseconds}ms',
        );
      }
    },
    onStatusMessage: (msg) => _say('install status: $msg'),
  );

  _say(
    'install complete in '
    '${DateTime.now().difference(loadStarted).inMilliseconds}ms',
  );

  // Repeat runs would otherwise fill the card: each profile costs ~65 KB of
  // non-volatile memory whatever the BPP size, so the run after next would
  // fail on space rather than on anything the transport did. Only the profile
  // this run just installed is removed.
  if (config['deleteAfterEach'] == true) {
    final rawIccid = HexUtils.swapNibbles(HexUtils.bytesToHex(metadata.iccid!));
    await pm.deleteProfile(rawIccid, useChannel: channel);
    _say('deleted the profile this run installed (raw $rawIccid)');
  }

  return {
    'eid': eid,
    'iccid': metadata.iccid != null
        ? HexUtils.bytesToHex(metadata.iccid!)
        : null,
    'provider': metadata.serviceProviderName,
    'bppBytes': bpp.length,
    'installMs': DateTime.now().difference(loadStarted).inMilliseconds,
  };
}
