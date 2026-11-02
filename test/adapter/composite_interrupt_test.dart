import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:nlpa2/adapter/composite_adapter.dart';
import 'package:nlpa2/adapter/euicc_adapter.dart';

void main() {
  test(
    'interrupt invalidates cached reader so ordinary connect recovers',
    () async {
      final composite = CompositeAdapter();
      await composite.disconnect();
      final source = _InterruptibleTestAdapter();
      final reader = Reader(
        id: 'interrupt-test-reader',
        name: 'Interrupt test reader',
        source: source,
      );

      await composite.connect(reader);
      expect(source.connectCount, 1);
      expect(composite.connectedReader, reader);

      composite.interruptPendingOperation();
      expect(source.interruptCount, 1);
      expect(composite.connectedReader, isNull);

      await composite.connect(reader);
      expect(source.connectCount, 2);
      expect(source.disconnectCount, 1);
      expect(composite.connectedReader, reader);

      await composite.disconnect();
      expect(source.disconnectCount, 2);
    },
  );

  test('interrupt retains delegate for an explicit cleanup', () async {
    final composite = CompositeAdapter();
    await composite.disconnect();
    final source = _InterruptibleTestAdapter();
    final reader = Reader(
      id: 'interrupt-disconnect-test-reader',
      name: 'Interrupt disconnect test reader',
      source: source,
    );

    await composite.connect(reader);
    composite.interruptPendingOperation();

    await composite.disconnect();
    expect(source.disconnectCount, 1);
    expect(composite.connectedReader, isNull);
  });

  test(
    'interrupt cleans old delegate before connecting another reader',
    () async {
      final composite = CompositeAdapter();
      await composite.disconnect();
      final oldSource = _InterruptibleTestAdapter();
      final nextSource = _InterruptibleTestAdapter();
      final oldReader = Reader(
        id: 'interrupt-old-test-reader',
        name: 'Interrupt old test reader',
        source: oldSource,
      );
      final nextReader = Reader(
        id: 'interrupt-next-test-reader',
        name: 'Interrupt next test reader',
        source: nextSource,
      );

      await composite.connect(oldReader);
      composite.interruptPendingOperation();
      await composite.connect(nextReader);

      expect(oldSource.disconnectCount, 1);
      expect(nextSource.connectCount, 1);
      expect(composite.connectedReader, nextReader);

      await composite.disconnect();
    },
  );

  test('failed connect retains delegate for explicit cleanup', () async {
    final composite = CompositeAdapter();
    await composite.disconnect();
    final source = _InterruptibleTestAdapter()..failNextConnect = true;
    final reader = Reader(
      id: 'failed-connect-cleanup-test-reader',
      name: 'Failed connect cleanup test reader',
      source: source,
    );

    await expectLater(composite.connect(reader), throwsStateError);
    expect(composite.connectedReader, isNull);
    expect(source.disconnectCount, 0);

    await composite.disconnect();
    expect(source.disconnectCount, 1);
  });

  test('failed reconnect invalidates cached reader for retry', () async {
    final composite = CompositeAdapter();
    await composite.disconnect();
    final source = _InterruptibleTestAdapter();
    final reader = Reader(
      id: 'failed-reconnect-test-reader',
      name: 'Failed reconnect test reader',
      source: source,
    );

    await composite.connect(reader);
    expect(source.connectCount, 1);

    source.failNextConnect = true;
    await expectLater(composite.reconnect(), throwsStateError);
    expect(source.connectCount, 2);
    expect(source.disconnectCount, 1);
    expect(composite.connectedReader, isNull);

    await composite.connect(reader);
    expect(source.connectCount, 3);
    expect(source.disconnectCount, 2);
    expect(composite.connectedReader, reader);

    await composite.disconnect();
    expect(source.disconnectCount, 3);
  });
}

class _InterruptibleTestAdapter extends BaseAdapter {
  _InterruptibleTestAdapter() : super(Logger('CompositeInterruptTest'));

  var connectCount = 0;
  var disconnectCount = 0;
  var interruptCount = 0;
  var failNextConnect = false;

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
    connectCount++;
    if (failNextConnect) {
      failNextConnect = false;
      throw StateError('simulated reconnect failure');
    }
    updateConnectedReader(reader);
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    updateConnectedReader(null);
  }

  @override
  void interruptPendingOperation() {
    interruptCount++;
  }

  @override
  Future<Channel> openChannel({List<String>? aids}) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) => throw UnimplementedError();
}
