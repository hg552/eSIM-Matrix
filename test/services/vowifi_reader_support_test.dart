import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:nlpa2/adapter/ccid/ccid_adapter.dart';
import 'package:nlpa2/vowifi/vowifi_service.dart';
import 'package:logging/logging.dart';
import 'package:nlpa2/adapter/euicc_adapter.dart';
import 'package:nlpa2/adapter/omapi/omapi_adapter.dart';
import 'package:nlpa2/services/vowifi_sim_service.dart';
import 'package:nlpa2/services/vowifi_sms_service.dart';
import 'package:nlpa2/settings/app_settings.dart';
import 'package:nlpa2/settings/build_capabilities.dart';
import 'package:nlpa2/utils/vowifi_reader_support.dart';
import 'package:nlpa2/vowifi_sms/vowifi_sms_plugin.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Android and OMAPI are always excluded from VoWiFi reader eligibility',
    () {
      for (final android in [false, true]) {
        for (final omapi in [false, true]) {
          for (final raw in [false, true]) {
            expect(
              BuildCapabilities.isVowifiReaderAvailable(
                isAndroid: android,
                isOmapi: omapi,
                supportsRawApdu: raw,
              ),
              !android && !omapi && raw,
            );
          }
        }
      }
    },
  );

  test(
    'rejects direct, wrapped and capability-spoofed OMAPI readers',
    () async {
      final adapter = _RawAdapter();
      final omapi = _RawOmapi();
      final reader = Reader(id: 'omapi:test', name: 'OMAPI', source: omapi);
      expect(supportsVowifiReader(reader), isFalse);
      expect(
        () => requireVowifiReader(adapter, reader),
        throwsUnsupportedError,
      );
      final external = Reader(
        id: 'external',
        name: 'External',
        source: adapter,
      );
      expect(
        () => requireVowifiReader(omapi, external),
        throwsUnsupportedError,
      );
      adapter.updateConnectedReader(
        Reader(id: external.id, name: 'Wrapped OMAPI', source: omapi),
      );
      expect(supportsVowifiReader(external, adapter: adapter), isFalse);
      adapter.updateConnectedReader(null);
      final sim = _AkaSim();
      await AppSettings().setVowifiEnabled(true, disclaimerAccepted: true);
      addTearDown(() => AppSettings().setVowifiEnabled(false));
      final service = VowifiSmsService.forTesting(simService: sim);
      await expectLater(
        service.connectCurrentCard(adapter: adapter, reader: reader),
        throwsUnsupportedError,
      );
      expect(sim.calls, 0);
    },
  );

  test(
    'iOS calling service rejects an OMAPI execution adapter before native I/O',
    () async {
      final adapter = _RawOmapi();
      final reader = Reader(
        id: 'ccid:test',
        name: 'External',
        source: CcidAdapter(),
      );
      const channel = MethodChannel('test/vowifi-reader-policy');
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls++;
            return null;
          });
      final service = VoWifiService(
        adapter: adapter,
        reader: reader,
        channel: channel,
      );
      addTearDown(service.dispose);
      expect(
        VoWifiService.supports(
          Reader(id: 'omapi', name: 'OMAPI', source: adapter),
        ),
        isFalse,
      );
      await expectLater(service.start({}), throwsUnsupportedError);
      expect(calls, 0);
    },
  );

  for (final hex in [false, true]) {
    test(
      'Digest AKA ${hex ? 'hex' : 'base64'} nonce preserves AUTS for resynchronization',
      () async {
        final sim = _AkaSim();
        final adapter = _RawAdapter();
        final reader = Reader(
          id: 'external',
          name: 'External',
          source: adapter,
        );
        final bytes = List<int>.generate(32, (i) => i);
        final nonce = hex
            ? bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()
            : base64.encode(bytes);
        final result = await sim.authenticateDigestChallenge(
          adapter,
          reader,
          challenge: VowifiDigestChallenge(
            method: 'REGISTER',
            uri: 'sip:ims.example',
            rawHeader: '',
            fields: {'nonce': nonce},
          ),
        );
        expect(sim.rand, bytes.sublist(0, 16));
        expect(sim.autn, bytes.sublist(16));
        expect(result.auts, List<int>.filled(14, 7));
      },
    );
  }
  test('invalid AKA nonce is rejected before contacting the SIM', () async {
    final sim = _AkaSim();
    final adapter = _RawAdapter();
    await expectLater(
      sim.authenticateDigestChallenge(
        adapter,
        Reader(id: 'external', name: 'External', source: adapter),
        challenge: VowifiDigestChallenge(
          method: 'REGISTER',
          uri: 'sip:ims.example',
          rawHeader: '',
          fields: {'nonce': 'AAAA'},
        ),
      ),
      throwsFormatException,
    );
    expect(sim.calls, 0);
  });
}

class _AkaSim extends VowifiSimService {
  int calls = 0;
  Uint8List? rand;
  Uint8List? autn;
  @override
  Future<VowifiAkaResult> authenticateIms(
    Adapter adapter,
    Reader reader, {
    required Uint8List rand,
    required Uint8List autn,
    void Function(String)? onLog,
  }) async {
    calls++;
    this.rand = rand;
    this.autn = autn;
    return VowifiAkaResult(
      res: Uint8List(0),
      ck: Uint8List(0),
      ik: Uint8List(0),
      auts: Uint8List.fromList(List.filled(14, 7)),
    );
  }
}

class _RawOmapi extends OmapiAdapter {
  @override
  bool get supportsRawApdu => true;
}

class _RawAdapter extends BaseAdapter {
  _RawAdapter() : super(Logger('TestRawAdapter'));
  @override
  Future<List<Reader>> listReaders({bool force = false}) async => [];
  @override
  Future<void> connect(Reader reader) async => updateConnectedReader(reader);
  @override
  Future<void> disconnect() async => updateConnectedReader(null);
  @override
  Future<Channel> openChannel({List<String>? aids}) =>
      throw UnimplementedError();
  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) => throw UnimplementedError();
  @override
  Stream<EuiccPortState> get stateStream => const Stream.empty();
  @override
  bool get requiresRefresh => false;
  @override
  String? get lastAtr => null;
}
