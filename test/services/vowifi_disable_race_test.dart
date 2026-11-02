import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:nlpa2/adapter/euicc_adapter.dart';
import 'package:nlpa2/models/euicc_profile.dart';
import 'package:nlpa2/services/vowifi_sim_service.dart';
import 'package:nlpa2/services/vowifi_sms_service.dart';
import 'package:nlpa2/settings/app_settings.dart';
import 'package:nlpa2/vowifi_sms/vowifi_sms_plugin.dart';

void main() {
  test(
    'disabling cancels an in-flight VoWiFi connection',
    () async {
      final settings = AppSettings();
      await settings.setVowifiEnabled(true, disclaimerAccepted: true);
      expect(settings.vowifiEnabled, isTrue);

      final simService = _DeferredVowifiSimService();
      final service = VowifiSmsService.forTesting(simService: simService);
      final adapter = _FakeAdapter();
      final reader = Reader(id: 'test', name: 'Test reader', source: adapter);

      final connection = service.connectCurrentCard(
        adapter: adapter,
        reader: reader,
      );
      final connectionFailure = expectLater(
        connection,
        throwsA(isA<UnsupportedError>()),
      );

      await simService.started.future;
      await settings.setVowifiEnabled(false);
      await service.disableAndDisconnect();
      simService.completeProbe();

      await connectionFailure;
      expect(service.sessions, isEmpty);
      expect(settings.vowifiEnabled, isFalse);
    },
    skip: !AppSettings().vowifiAvailable,
  );

  test(
    'late registration is disconnected again after disabling',
    () async {
      final settings = AppSettings();
      await settings.setVowifiEnabled(true, disclaimerAccepted: true);

      final simService = _ImmediateVowifiSimService();
      final clientCreated = Completer<_DeferredVowifiSmsClient>();
      final service = VowifiSmsService.forTesting(
        simService: simService,
        clientFactory:
            ({
              required adapter,
              required reader,
              required info,
              required config,
              onLog,
            }) {
              final client = _DeferredVowifiSmsClient(config: config);
              clientCreated.complete(client);
              return client;
            },
      );
      final adapter = _FakeAdapter();
      final reader = Reader(id: 'test', name: 'Test reader', source: adapter);
      final profile = EuiccProfile(
        iccid: '8901000000000000000',
        enabled: true,
        customIcon: 'test-icon',
      );

      final connection = service.connectCurrentCard(
        adapter: adapter,
        reader: reader,
        activeProfile: profile,
      );
      final connectionFailure = expectLater(
        connection,
        throwsA(isA<UnsupportedError>()),
      );

      final client = await clientCreated.future;
      await client.started.future;
      await settings.setVowifiEnabled(false);
      await service.disableAndDisconnect();
      expect(client.disconnectCount, 1);
      expect(service.sessions, isEmpty);

      client.completeRegistration();
      await connectionFailure;

      expect(client.disconnectCount, 2);
      expect(service.sessions, isEmpty);
    },
    skip: !AppSettings().vowifiAvailable,
  );
}

class _DeferredVowifiSimService extends VowifiSimService {
  final Completer<void> started = Completer<void>();
  final Completer<VowifiCardInfo> _probe = Completer<VowifiCardInfo>();

  @override
  Future<VowifiCardInfo> probe(
    Adapter adapter,
    Reader reader, {
    void Function(String line)? onLog,
  }) {
    if (!started.isCompleted) started.complete();
    return _probe.future;
  }

  void completeProbe() {
    _probe.complete(const VowifiCardInfo(iccid: '8901000000000000000'));
  }
}

class _ImmediateVowifiSimService extends VowifiSimService {
  @override
  Future<VowifiCardInfo> probe(
    Adapter adapter,
    Reader reader, {
    void Function(String line)? onLog,
  }) async {
    return const VowifiCardInfo(
      iccid: '8901000000000000000',
      imsi: '310260123456789',
      mncLength: 3,
      smsc: '+12025550123',
    );
  }
}

class _DeferredVowifiSmsClient extends VowifiSmsClient {
  _DeferredVowifiSmsClient({required super.config});

  final Completer<void> started = Completer<void>();
  final Completer<void> _registration = Completer<void>();
  int disconnectCount = 0;

  @override
  Future<void> connectAndRegister() {
    if (!started.isCompleted) started.complete();
    return _registration.future;
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
  }

  void completeRegistration() {
    _registration.complete();
  }
}

class _FakeAdapter extends BaseAdapter {
  _FakeAdapter() : super(Logger('_FakeAdapter'));

  @override
  Future<List<Reader>> listReaders({bool force = false}) async => <Reader>[];

  @override
  Future<void> connect(Reader reader) async {
    updateConnectedReader(reader);
  }

  @override
  Future<void> disconnect() async {
    updateConnectedReader(null);
  }

  @override
  Future<Channel> openChannel({List<String>? aids}) {
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) async => Uint8List(0);

  @override
  Stream<EuiccPortState> get stateStream => const Stream.empty();

  @override
  bool get requiresRefresh => false;

  @override
  String? get lastAtr => null;
}
