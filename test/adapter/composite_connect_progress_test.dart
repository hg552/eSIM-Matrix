import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:nlpa2/adapter/composite_adapter.dart';
import 'package:nlpa2/adapter/euicc_adapter.dart';

void main() {
  late CompositeAdapter composite;
  late _SteppingAdapter source;
  late Reader reader;

  setUp(() async {
    composite = CompositeAdapter();
    await composite.disconnect();
    source = _SteppingAdapter();
    reader = Reader(
      id: 'progress-test-reader',
      name: 'Progress test reader',
      source: source,
    );
  });

  tearDown(() => composite.disconnect());

  List<ReaderConnectProgress?> recordProgress() {
    final seen = <ReaderConnectProgress?>[];
    void record() => seen.add(composite.connectProgress.value);
    composite.connectProgress.addListener(record);
    addTearDown(() => composite.connectProgress.removeListener(record));
    return seen;
  }

  test('relays each step the reader reports, then clears', () async {
    final seen = recordProgress();

    await composite.connect(reader);

    expect(seen.map((progress) => progress?.step), [
      ReaderConnectStep.connectingBluetooth,
      ReaderConnectStep.connectingBluetooth,
      ReaderConnectStep.discoveringServices,
      ReaderConnectStep.initializing,
      null,
    ]);
    expect(seen[1]!.attempt, 2);
    expect(seen[1]!.attempts, 3);
  });

  test('clears the step when the connect fails', () async {
    source.failAfterSteps = true;
    final seen = recordProgress();

    await expectLater(composite.connect(reader), throwsStateError);

    expect(seen.last, isNull);
    expect(composite.connectProgress.value, isNull);
  });

  test('stops relaying once its connect has finished', () async {
    await composite.connect(reader);
    final seen = recordProgress();

    // A reader that reconnects on its own mid-transfer is not this connect.
    source.reportLateStep();

    expect(seen, isEmpty);
    expect(composite.connectProgress.value, isNull);
  });
}

class _SteppingAdapter extends BaseAdapter {
  _SteppingAdapter() : super(Logger('CompositeConnectProgressTest'));

  var failAfterSteps = false;

  void reportLateStep() => reportConnectStep(ReaderConnectStep.authenticating);

  @override
  Stream<EuiccPortState> get stateStream => const Stream.empty();

  @override
  bool get requiresRefresh => false;

  @override
  String? get lastAtr => null;

  @override
  Future<List<Reader>> listReaders({bool force = false}) async => const [];

  @override
  Future<void> connect(Reader reader) async {
    reportConnectStep(
      ReaderConnectStep.connectingBluetooth,
      attempt: 1,
      attempts: 3,
    );
    reportConnectStep(
      ReaderConnectStep.connectingBluetooth,
      attempt: 2,
      attempts: 3,
    );
    reportConnectStep(ReaderConnectStep.discoveringServices);
    if (failAfterSteps) throw StateError('simulated link failure');
    reportConnectStep(ReaderConnectStep.initializing);
    updateConnectedReader(reader);
  }

  @override
  Future<void> disconnect() async => updateConnectedReader(null);

  @override
  Future<Channel> openChannel({List<String>? aids}) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) => throw UnimplementedError();
}
