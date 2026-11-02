import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:nlpa2/adapter/euicc_adapter.dart';
import 'package:nlpa2/utils/apdu_exception.dart';
import 'package:nlpa2/utils/error_codes.dart';

void main() {
  test('selectAid preserves typed Bluetooth transport failures', () async {
    final timeout = AppException(AppErrorCode.ERROR_BLUETOOTH_TIMEOUT);
    final adapter = _SelectAidAdapter();
    final channel = _SelectAidChannel(adapter, [timeout]);

    await expectLater(
      adapter.selectAid(channel, const ['A00001', 'A00002']),
      throwsA(same(timeout)),
    );
    expect(channel.requestCount, 1);
  });

  test('selectAid preserves 6985 recovery state', () async {
    final adapter = _SelectAidAdapter();
    final channel = _SelectAidChannel(adapter, [
      Uint8List.fromList([0x69, 0x85]),
    ]);

    await expectLater(
      adapter.selectAid(channel, const ['A00001', 'A00002']),
      throwsA(isA<ConditionOfUseNotSatisfiedException>()),
    );
    expect(channel.requestCount, 1);
  });

  test('selectAid still tries the next AID for an ordinary miss', () async {
    final adapter = _SelectAidAdapter();
    final channel = _SelectAidChannel(adapter, [
      Uint8List.fromList([0x6A, 0x82]),
      Uint8List.fromList([0x90, 0x00]),
    ]);

    final selected = await adapter.selectAid(channel, const [
      'A00001',
      'A00002',
    ]);

    expect(selected, 'A00002');
    expect(channel.requestCount, 2);
  });
}

class _SelectAidAdapter extends BaseAdapter {
  _SelectAidAdapter() : super(Logger('SelectAidTest'));

  @override
  Stream<EuiccPortState> get stateStream => const Stream.empty();

  @override
  bool get requiresRefresh => false;

  @override
  String? get lastAtr => null;

  @override
  Future<List<Reader>> listReaders({bool force = false}) async => const [];

  @override
  Future<void> connect(Reader reader) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<Channel> openChannel({List<String>? aids}) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) => throw UnimplementedError();
}

class _SelectAidChannel implements Channel {
  _SelectAidChannel(this.adapter, this._outcomes);

  @override
  final Adapter adapter;
  final List<Object> _outcomes;
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
    if (requestCount >= _outcomes.length) {
      throw StateError('Unexpected SELECT request');
    }
    final outcome = _outcomes[requestCount++];
    if (outcome is Uint8List) return outcome;
    throw outcome;
  }
}
