import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nlpa2/adapter/euicc_adapter.dart';
import 'package:nlpa2/adapter/ble/nble_sim_adapter.dart';
import 'package:nlpa2/logic/profile_manager.dart';
import 'package:nlpa2/models/asn1/rsp_definitions.g.dart';
import 'package:nlpa2/utils/apdu_exception.dart';
import 'package:nlpa2/utils/hex_utils.dart';

void main() {
  test('web NBLE frames preserve protocol boundaries at 20 bytes', () {
    final apdu = HexUtils.hexToBytes(
      '01a4040010a0000005591010ffffffff890000010000',
    );

    final webFrames = NBLESimAdapter.encodeFramesForTransport(
      4,
      apdu,
      maxWriteSize: 20,
    );
    expect(webFrames.map(HexUtils.bytesToHex), <String>[
      '000401a4040010a0000005591010ffffffff8900',
      '21000100000661',
    ]);
    expect(webFrames.every((frame) => frame.length <= 20), isTrue);

    final nativeFrames = NBLESimAdapter.encodeFramesForTransport(
      4,
      apdu,
      maxWriteSize: 101,
    );
    expect(nativeFrames.map(HexUtils.bytesToHex), <String>[
      '200401a4040010a0000005591010ffffffff8900000100000661',
    ]);
  });

  test('NBLE profile state changes do request a proactive refresh', () {
    // The card sits in a handset, so the modem is the terminal: it performs
    // the UICC reset that makes the newly enabled profile live. Nothing
    // reachable over Bluetooth can do that, so the refresh must be asked for.
    final adapter = NBLESimAdapter();

    expect(adapter.requiresRefresh, isTrue);
  });

  test('waiting for an idle window does not answer the modem', () async {
    // 91xx here is ordinary card-to-modem traffic that clears on its own.
    final adapter = _ScriptedNbleAdapter({
      '80F2000000': ['910B', '910B', '9000'],
    });

    expect(await adapter.waitForIdleWindow(), isTrue);
    expect(
      adapter.sent.where((apdu) => !apdu.startsWith('80F2')),
      isEmpty,
      reason: 'no FETCH or TERMINAL RESPONSE may be sent while waiting',
    );
  });

  test('an unsupported STATUS means a live, idle card', () async {
    // 6D00 means the card processed the command and does not implement it.
    // Reading that as "busy" made the pre-switch guard refuse a healthy card,
    // and reading it as "not back" made the adapter wait out a full timeout.
    final adapter = _ScriptedNbleAdapter({'80F2000000': '6D00'});

    expect(await adapter.isCatBusy(), isFalse);
    expect(adapter.sent, ['80F2000000']);
  });

  test('a card mid state change is reported busy', () async {
    expect(
      await _ScriptedNbleAdapter({'80F2000000': '6985'}).isCatBusy(),
      isTrue,
    );
    expect(
      await _ScriptedNbleAdapter({'80F2000000': '6999'}).isCatBusy(),
      isTrue,
    );
  });

  test('an unrecognised status is unknown, not busy', () async {
    // Unknown must not read as busy: the guard would refuse the switch on a
    // reader whose card simply answers something we have not catalogued.
    expect(
      await _ScriptedNbleAdapter({'80F2000000': '6F00'}).isCatBusy(),
      isNull,
    );
  });

  test('waiting gives up on a status that will not clear', () async {
    final adapter = _ScriptedNbleAdapter({'80F2000000': '6985'});

    expect(await adapter.waitForIdleWindow(), isFalse);
    expect(adapter.sent, ['80F2000000']);
  });

  test('stale logical-channel close never auto-reconnects', () {
    expect(
      NBLESimAdapter.allowsReconnectForApdu(
        Uint8List.fromList([0x01, 0x70, 0x80, 0x01, 0x00]),
      ),
      isFalse,
    );
    expect(
      NBLESimAdapter.allowsReconnectForApdu(
        Uint8List.fromList([0x81, 0xE2, 0x91, 0x00]),
      ),
      isTrue,
    );
  });

  test('six hex digits are used verbatim and never hashed', () {
    // The writer authenticates with these six characters as-is. Hashing them
    // would silently produce a different key than the one the card was
    // programmed with.
    expect(NBLESimAdapter.calculatePasswordHex('778899'), '778899');
    expect(NBLESimAdapter.calculatePasswordHex(' 778899 '), '778899');
    expect(NBLESimAdapter.calculatePasswordHex('abcdef'), 'ABCDEF');
    expect(NBLESimAdapter.calculatePasswordHex('000000'), '000000');
  });

  test('anything that is not six hex digits is reduced with CRC24', () {
    // Wrong length, or six characters that are not all hex.
    expect(NBLESimAdapter.calculatePasswordHex('77889'), isNot('77889'));
    expect(NBLESimAdapter.calculatePasswordHex('7788990'), isNot('7788990'));
    expect(NBLESimAdapter.calculatePasswordHex('ZZ1234'), isNot('ZZ1234'));
    for (final value in <String>['hunter2', 'ZZ1234', '77889']) {
      expect(
        NBLESimAdapter.calculatePasswordHex(value),
        matches(RegExp(r'^[0-9A-F]{6}$')),
      );
    }
  });

  test('recognises a default password through the same reduction', () {
    // An all-digit suffix is already hex, so the default is used verbatim.
    expect(
      NBLESimAdapter.isDefaultPasswordFor('9eSIM949844', '448949'),
      isTrue,
    );
    expect(
      NBLESimAdapter.isDefaultPasswordFor('9eSIM949844', '778899'),
      isFalse,
    );

    // A suffix carrying non-hex characters derives a default that is itself
    // hashed; comparing against the raw default would never match.
    final name = '9eSIMZZ1234';
    final defaultPassword = NBLESimAdapter.defaultPasswordForDeviceName(name);
    expect(defaultPassword, '4321ZZ');
    expect(NBLESimAdapter.isDefaultPasswordFor(name, defaultPassword), isTrue);
    expect(
      NBLESimAdapter.isDefaultPasswordFor(
        name,
        NBLESimAdapter.calculatePasswordHex(defaultPassword),
      ),
      isTrue,
    );
  });

  test('derives the default password from the final six device-name chars', () {
    expect(
      NBLESimAdapter.defaultPasswordForDeviceName('9eSIM250113'),
      '311052',
    );
    expect(NBLESimAdapter.defaultPasswordForDeviceName('A1B2C3'), '3C2B1A');
  });

  test('saves default passwords and migrates records after a rename', () async {
    SharedPreferences.setMockInitialValues({
      NBLESimAdapter.storedPasswordKey('9eSIM250113'): '311052',
    });

    await NBLESimAdapter.savePasswordForDevice(
      previousDeviceName: '9eSIM250113',
      deviceName: '9eSIMA1B2C3',
      password: '3C2B1A',
    );

    final records = await NBLESimAdapter.loadStoredPasswords();
    expect(records, hasLength(1));
    expect(records.single.deviceName, '9eSIMA1B2C3');
    expect(records.single.password, '3C2B1A');
  });

  test('NBLE enable commits without proactive refresh, then resets', () async {
    final response = EnableProfileResponse(
      enableResult: EnableProfileResponse_enableResult.ok,
    ).encode();
    final adapter = _TestNbleAdapter(response);

    final sessionInvalidated = await ProfileManager(
      adapter,
    ).enableProfile('8901000000000000000', useChannel: adapter.channel);

    final request = EnableProfileRequest.decode(adapter.channel.firstRequest);
    // The card must never be asked to defer the switch to a REFRESH this
    // reader cannot answer; it is reset after the commit instead.
    expect(request.refreshFlag, isFalse);
    expect(adapter.resetCalls, 1);
    // The reset invalidates the session, so the caller has to verify the new
    // state on a fresh logical channel.
    expect(sessionInvalidated, isTrue);
    expect(adapter.channel.requestCount, 1);
  });

  test('NBLE disable commits without proactive refresh, then resets', () async {
    final response = DisableProfileResponse(
      disableResult: DisableProfileResponse_disableResult.ok,
    ).encode();
    final adapter = _TestNbleAdapter(response);

    final sessionInvalidated = await ProfileManager(
      adapter,
    ).disableProfile('8901000000000000000', useChannel: adapter.channel);

    final request = DisableProfileRequest.decode(adapter.channel.firstRequest);
    expect(request.refreshFlag, isFalse);
    expect(adapter.resetCalls, 1);
    expect(sessionInvalidated, isTrue);
    expect(adapter.channel.requestCount, 1);
  });

  test(
    'a failed reset does not turn a committed switch into a failure',
    () async {
      final adapter = _TestNbleAdapter(
        EnableProfileResponse(
          enableResult: EnableProfileResponse_enableResult.ok,
        ).encode(),
        resetError: StateError('writer never came back'),
      );

      final sessionInvalidated = await ProfileManager(
        adapter,
      ).enableProfile('8901000000000000000', useChannel: adapter.channel);

      expect(adapter.resetCalls, 1);
      expect(sessionInvalidated, isTrue);
    },
  );

  test('a refresh-flagged switch is refused if no idle window comes', () async {
    ProfileManager.idleWindowTimeout = const Duration(milliseconds: 200);
    addTearDown(
      () => ProfileManager.idleWindowTimeout = const Duration(seconds: 45),
    );
    final adapter = _TestNbleAdapter(
      EnableProfileResponse(
        enableResult: EnableProfileResponse_enableResult.ok,
      ).encode(),
      requiresRefreshOverride: true,
      catBusy: true,
    );

    await expectLater(
      ProfileManager(
        adapter,
      ).enableProfile('8901000000000000000', useChannel: adapter.channel),
      throwsA(isA<CatBusyException>()),
    );

    // The card must not have been touched: refusing early is the whole point.
    expect(adapter.channel.requestCount, 0);
    expect(adapter.resetCalls, 0);
    // Waiting must never answer a command or drop the link.
    expect(adapter.proactiveRefreshCalls, 0);
  });

  test('a reader left serving nothing after a switch is reported', () async {
    final adapter = _TestNbleAdapter(
      EnableProfileResponse(
        enableResult: EnableProfileResponse_enableResult.ok,
      ).encode(),
      servingProfile: false,
    );
    final records = <String>[];
    final subscription = Logger.root.onRecord
        .where((record) => record.level >= Level.SEVERE)
        .listen((record) => records.add(record.message));

    await ProfileManager(
      adapter,
    ).enableProfile('8901000000000000000', useChannel: adapter.channel);
    await subscription.cancel();

    expect(adapter.servingChecks, 1);
    // The profile list would look correct here; only the reader's own mode
    // reveals that the host has nothing to use.
    expect(
      records.any((message) => message.contains('not serving any profile')),
      isTrue,
    );
  });

  test('a reader serving a profile reports nothing', () async {
    final adapter = _TestNbleAdapter(
      EnableProfileResponse(
        enableResult: EnableProfileResponse_enableResult.ok,
      ).encode(),
      servingProfile: true,
    );

    await ProfileManager(
      adapter,
    ).enableProfile('8901000000000000000', useChannel: adapter.channel);

    expect(adapter.servingChecks, 1);
  });

  test('a busy card is waited out, never answered', () async {
    // The modem clears its own commands within seconds. Waiting for that gap
    // is the whole behaviour: answering one would take it from the modem, and
    // dropping the link here would abort a switch that has not been sent yet.
    ProfileManager.idleWindowTimeout = const Duration(seconds: 5);
    addTearDown(
      () => ProfileManager.idleWindowTimeout = const Duration(seconds: 45),
    );
    final adapter = _TestNbleAdapter(
      EnableProfileResponse(
        enableResult: EnableProfileResponse_enableResult.ok,
      ).encode(),
      catBusy: true,
      busyChecks: 2,
    );

    await ProfileManager(
      adapter,
    ).enableProfile('8901000000000000000', useChannel: adapter.channel);

    expect(adapter.catBusyChecks, greaterThan(2), reason: 'it polled');
    expect(adapter.proactiveRefreshCalls, 0, reason: 'nothing was answered');
    expect(adapter.channel.requestCount, 1, reason: 'the switch still happens');
  });

  test('a reader that cannot tell does not block the switch', () async {
    final adapter = _TestNbleAdapter(
      EnableProfileResponse(
        enableResult: EnableProfileResponse_enableResult.ok,
      ).encode(),
      requiresRefreshOverride: true,
      catBusy: null,
    );

    Object? error;
    try {
      await ProfileManager(
        adapter,
      ).enableProfile('8901000000000000000', useChannel: adapter.channel);
    } catch (e) {
      // The refresh path that follows needs a live card; only the guard's
      // decision matters here.
      error = e;
    }

    expect(adapter.catBusyChecks, 1);
    expect(error, isNot(isA<CatBusyException>()));
    // The command reached the card instead of being refused up front.
    expect(adapter.channel.requestCount, 1);
  });

  test('STATUS decides whether the card counts as CAT busy', () async {
    expect(
      await _ScriptedNbleAdapter({'80F2000000': '9000'}).isCatBusy(),
      isFalse,
    );
    expect(
      await _ScriptedNbleAdapter({'80F2000000': '910D'}).isCatBusy(),
      isTrue,
    );
    // A card mid state change cannot be relied on to finish a REFRESH.
    expect(
      await _ScriptedNbleAdapter({'80F2000000': '6985'}).isCatBusy(),
      isTrue,
    );
    // 6D00 is an answer, not a refusal: the card is alive and idle.
    expect(
      await _ScriptedNbleAdapter({'80F2000000': '6D00'}).isCatBusy(),
      isFalse,
    );
  });

  test('a card with nothing pending needs no reset', () async {
    final adapter = _ScriptedNbleAdapter({'80F2000000': '9000'});

    expect(await adapter.completePendingProactiveCommands(), isFalse);
    expect(adapter.sent, ['80F2000000']);
  });

  test('a pending profile state change REFRESH is acknowledged', () async {
    final adapter = _ScriptedNbleAdapter({
      // First STATUS advertises a waiting command, the second reports a
      // settled card once the terminal response has been sent.
      '80F2000000': ['910D', '9000'],
      '801200000D': 'D009810301010982028182 9000',
      '801400000C810301010982028281830100': '9000',
    });

    expect(await adapter.completePendingProactiveCommands(), isFalse);
    expect(
      adapter.sent,
      containsAllInOrder([
        '80F2000000',
        '801200000D',
        // Command details echoed back with "command performed successfully".
        '801400000C810301010982028281830100',
        '80F2000000',
      ]),
    );
  });

  test('a card that blocks STATUS still gets its command fetched', () async {
    final adapter = _ScriptedNbleAdapter({
      '80F2000000': ['6985', '9000'],
      // A blocked STATUS carries no length, so FETCH asks for everything.
      '8012000000': 'D009810301010982028182 9000',
      '801400000C810301010982028281830100': '9000',
    });

    expect(await adapter.completePendingProactiveCommands(), isFalse);
    expect(adapter.sent, contains('8012000000'));
  });

  test('a REFRESH demanding a real reset is declined, not ignored', () async {
    final adapter = _ScriptedNbleAdapter({
      '80F2000000': ['910D', '9000'],
      // REFRESH with the UICC reset qualifier.
      '801200000D': 'D009810301010482028182 9000',
      '801400000C810301010482028281830120': '9000',
    });

    expect(await adapter.completePendingProactiveCommands(), isTrue);

    final terminalResponses = adapter.sent
        .where((apdu) => apdu.startsWith('8014'))
        .toList();
    // Measured on hardware: leaving this command unanswered wedges the card
    // and takes the writer off the air, so it must still be answered.
    expect(terminalResponses, hasLength(1));
    // ...but never as "command performed successfully".
    expect(terminalResponses.single.endsWith('20'), isTrue);
    expect(terminalResponses.single.endsWith('00'), isFalse);
  });

  test('a command this reader cannot perform is declined', () async {
    final adapter = _ScriptedNbleAdapter({
      '80F2000000': ['910D', '9000'],
      // DISPLAY TEXT, which an APDU tunnel has no way of showing.
      '801200000D': 'D009810301218082028182 9000',
      '801400000C810301218082028281830120': '9000',
    });

    expect(await adapter.completePendingProactiveCommands(), isFalse);
    expect(
      adapter.sent,
      contains('801400000C810301218082028281830120'),
      reason: 'terminal currently unable to process command',
    );
  });

  test('an unexpected status word escalates to a reset', () async {
    final adapter = _ScriptedNbleAdapter({'80F2000000': '6F00'});

    expect(await adapter.completePendingProactiveCommands(), isTrue);
    expect(adapter.sent, ['80F2000000']);
  });

  test('a NAA session reset is performed, then reported as done', () async {
    // The REFRESH a card raises after a profile switch. Declining it strands
    // the modem on the previous profile, so the session is really dropped and
    // then acknowledged.
    final adapter = _ScriptedNbleAdapter({
      '80F2000000': ['912C', '9000'],
      '801200002C': 'D009810301010682028182 9000',
      // cleanupChannels drops every logical channel first.
      '0070800100': '9000',
      '0070800200': '9000',
      '0070800300': '9000',
      '801400000C810301010682028281830100': '9000',
    });

    expect(await adapter.completePendingProactiveCommands(), isFalse);
    expect(
      adapter.sent,
      containsAllInOrder([
        '801200002C',
        '0070800100',
        // Reported as performed only after the session was actually dropped.
        '801400000C810301010682028281830100',
      ]),
    );
  });

  test('draining continues past a command that demanded a reset', () async {
    // A UICC reset cannot be performed here, but a TIMER MANAGEMENT command is
    // queued behind it. Stopping at the first strands the second, which takes
    // the writer off the air.
    final adapter = _ScriptedNbleAdapter({
      '80F2000000': ['912C', '9113', '9000'],
      '801200002C': 'D009810301010482028182 9000',
      '801400000C810301010482028281830120': '9113',
      '8012000013': 'D009810301270082028182 9000',
      '801400000C810301270082028281830120': '9000',
    });

    expect(await adapter.completePendingProactiveCommands(), isTrue);
    expect(
      adapter.sent.where((apdu) => apdu.startsWith('8014')),
      hasLength(2),
      reason: 'both queued commands must be answered',
    );
  });

  test('a card that keeps queueing commands escalates to a reset', () async {
    final adapter = _ScriptedNbleAdapter({
      '80F2000000': '910D',
      '801200000D': 'D009810301010982028182 9000',
      // 91xx again: another command is waiting immediately.
      '801400000C810301010982028281830100': '910D',
    });

    expect(await adapter.completePendingProactiveCommands(), isTrue);
  });

  test('caller-owned channel never retries card busy', () async {
    final adapter = _BusyNbleAdapter();

    await expectLater(
      ProfileManager(
        adapter,
      ).enableProfile('8901000000000000000', useChannel: adapter.channel),
      throwsA(isA<CardBusyException>()),
    );

    expect(adapter.channel.requestCount, 1);
  });

  test('missing enable result is not accepted as success', () async {
    final adapter = _TestNbleAdapter(EnableProfileResponse().encode());

    await expectLater(
      ProfileManager(
        adapter,
      ).enableProfile('8901000000000000000', useChannel: adapter.channel),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('ENABLE_FAILED:missingResult'),
        ),
      ),
    );

    expect(adapter.channel.requestCount, 1);
  });

  group('settling after a refresh-flagged switch', () {
    late Duration floor;
    late Duration maxWait;
    late Duration probeGap;
    late Duration maxProbeGap;

    setUp(() {
      floor = NBLESimAdapter.settleQuietFloor;
      maxWait = NBLESimAdapter.settleMaxWait;
      probeGap = NBLESimAdapter.settleProbeGap;
      maxProbeGap = NBLESimAdapter.settleMaxProbeGap;

      NBLESimAdapter.settleQuietFloor = Duration.zero;
      NBLESimAdapter.settleProbeGap = Duration.zero;
      NBLESimAdapter.settleMaxProbeGap = Duration.zero;
      NBLESimAdapter.settleMaxWait = const Duration(milliseconds: 200);
    });

    tearDown(() {
      NBLESimAdapter.settleQuietFloor = floor;
      NBLESimAdapter.settleMaxWait = maxWait;
      NBLESimAdapter.settleProbeGap = probeGap;
      NBLESimAdapter.settleMaxProbeGap = maxProbeGap;
    });

    test('stops as soon as the card reports itself idle', () async {
      // A card that is still mid-reset refuses, then comes back. The wait ends
      // on the card's own signal rather than on a fixed duration.
      final adapter = _ScriptedNbleAdapter({
        '80F2000000': ['6985', '6985', '9000'],
      });

      await adapter.proactiveRefresh();

      expect(adapter.sent, ['80F2000000', '80F2000000', '80F2000000']);
    });

    test('waits longer for a card that takes longer', () async {
      final quick = _ScriptedNbleAdapter({
        '80F2000000': ['9000'],
      });
      final slow = _ScriptedNbleAdapter({
        '80F2000000': ['6985', '6985', '6985', '6985', '9000'],
      });

      await quick.proactiveRefresh();
      await slow.proactiveRefresh();

      expect(quick.sent.length, 1);
      expect(slow.sent.length, greaterThan(quick.sent.length));
    });

    test('probes with STATUS alone, never by re-opening a session', () async {
      // Re-opening a session is what wedged the card: TERMINAL CAPABILITY,
      // MANAGE CHANNEL and SELECT must never be sent while a reset is pending.
      final adapter = _ScriptedNbleAdapter({'80F2000000': '6985'});

      await adapter.proactiveRefresh();

      expect(adapter.sent, isNotEmpty);
      expect(adapter.sent.toSet(), {'80F2000000'});
    });

    test('gives up after the maximum rather than waiting forever', () async {
      final adapter = _ScriptedNbleAdapter({'80F2000000': '6999'});

      await adapter.proactiveRefresh().timeout(const Duration(seconds: 5));

      expect(adapter.sent, isNotEmpty);
    });
  });
}

class _TestNbleAdapter extends NBLESimAdapter {
  _TestNbleAdapter(
    Uint8List response, {
    this.resetError,
    this.requiresRefreshOverride = false,
    this.catBusy,
    this.servingProfile,
    this.busyChecks = 1 << 30,
  }) {
    channel = _PolicyChannel(this, response);
  }

  late final _PolicyChannel channel;
  final Object? resetError;
  final bool requiresRefreshOverride;
  final bool? catBusy;
  final bool? servingProfile;
  var resetCalls = 0;
  var catBusyChecks = 0;
  var proactiveRefreshCalls = 0;
  var servingChecks = 0;

  @override
  Future<bool?> isServingProfile() async {
    servingChecks++;
    return servingProfile;
  }

  @override
  bool get requiresRefresh => requiresRefreshOverride;

  @override
  Future<Channel> openChannel({List<String>? aids}) async => channel;

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) => throw UnimplementedError();

  /// How many checks report busy before the card goes idle, mirroring a modem
  /// that answers its own commands after a few seconds.
  final int busyChecks;

  @override
  Future<bool?> isCatBusy() async {
    catBusyChecks++;
    if (catBusy == true && catBusyChecks > busyChecks) return false;
    return catBusy;
  }

  @override
  Future<void> resetAfterProfileSwitch() async {
    resetCalls++;
    if (resetError != null) throw resetError!;
  }

  @override
  Future<void> proactiveRefresh() async {
    proactiveRefreshCalls++;
  }
}

/// Replays scripted card responses so the proactive-command exchange can be
/// exercised without a writer.
class _ScriptedNbleAdapter extends NBLESimAdapter {
  _ScriptedNbleAdapter(Map<String, Object> script)
    : _script = script.map(
        (request, responses) => MapEntry(_normalize(request), <String>[
          if (responses is List<String>)
            for (final response in responses) _normalize(response)
          else
            _normalize(responses as String),
        ]),
      );

  final Map<String, List<String>> _script;
  final List<String> sent = <String>[];

  static String _normalize(String hex) => hex.replaceAll(' ', '').toUpperCase();

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) async {
    final request = _normalize(HexUtils.bytesToHex(apdu));
    sent.add(request);

    final responses = _script[request];
    if (responses == null || responses.isEmpty) {
      fail('the card received an unscripted APDU: $request');
    }
    // A single scripted response is returned for every repeat of the request.
    final response = responses.length == 1
        ? responses.first
        : responses.removeAt(0);
    return HexUtils.hexToBytes(response);
  }
}

class _PolicyChannel implements Channel {
  _PolicyChannel(this.adapter, Uint8List response)
    : _response = Uint8List.fromList([...response, 0x90, 0x00]);

  @override
  final Adapter adapter;
  final Uint8List _response;
  Uint8List? _request;
  var _responded = false;
  var requestCount = 0;

  Uint8List get firstRequest => _request!;

  @override
  String? get aid => null;

  @override
  int get channelNumber => 1;

  @override
  Future<void> close() async {}

  @override
  Future<Uint8List> transmit(
    int cla,
    int ins,
    int p1,
    int p2, [
    Uint8List? data,
    int? le,
  ]) async {
    requestCount++;
    if (_responded) {
      throw StateError('Soft-refresh probe intentionally unavailable');
    }
    _responded = true;
    _request = Uint8List.fromList(data!);
    return _response;
  }
}

class _BusyNbleAdapter extends NBLESimAdapter {
  _BusyNbleAdapter() {
    channel = _BusyChannel(this);
  }

  late final _BusyChannel channel;

  @override
  Future<Channel> openChannel({List<String>? aids}) async => channel;

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) => throw UnimplementedError();
}

class _BusyChannel implements Channel {
  _BusyChannel(this.adapter);

  @override
  final Adapter adapter;
  var requestCount = 0;

  @override
  String? get aid => null;

  @override
  int get channelNumber => 1;

  @override
  Future<void> close() async {}

  @override
  Future<Uint8List> transmit(
    int cla,
    int ins,
    int p1,
    int p2, [
    Uint8List? data,
    int? le,
  ]) async {
    requestCount++;
    throw CardBusyException('busy');
  }
}
