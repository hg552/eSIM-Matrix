import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:nlpa2/adapter/euicc_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Case 3 payload that ends in 0x00 is not truncated', () async {
    final adapter = _Adapter();
    // STORE DATA (80 E2) with Lc=3 and a payload whose last byte is 0x00.
    await adapter.sendApdu(
      Uint8List.fromList(<int>[0x80, 0xE2, 0x91, 0x00, 0x03, 0x11, 0x22, 0x00]),
    );

    expect(
      adapter.commands.single,
      <int>[0x80, 0xE2, 0x91, 0x00, 0x03, 0x11, 0x22, 0x00],
    );
  });

  test('Case 4 Le byte stays out of the transmitted payload', () async {
    final adapter = _Adapter();
    // Header + Lc=4 + DE AD BE EF + Le=0x10.
    await adapter.sendApdu(
      Uint8List.fromList(
        <int>[0x00, 0x2C, 0x04, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF, 0x10],
      ),
    );

    expect(
      adapter.commands.single,
      <int>[0x00, 0x2C, 0x04, 0x00, 0x04, 0xDE, 0xAD, 0xBE, 0xEF, 0x10],
    );
  });

  test('Case 2 keeps the caller Le instead of forcing 0x00', () async {
    final adapter = _Adapter();
    // MANAGE CHANNEL open with Le=1.
    await adapter.sendApdu(
      Uint8List.fromList(<int>[0x00, 0x70, 0x00, 0x00, 0x01]),
    );

    expect(adapter.commands.single, <int>[0x00, 0x70, 0x00, 0x00, 0x01]);
  });
}

class _Adapter extends BaseAdapter {
  _Adapter() : super(Logger('RawApduCaseTest'));

  final commands = <Uint8List>[];

  @override
  Stream<EuiccPortState> get stateStream => const Stream.empty();

  @override
  bool get requiresRefresh => false;

  @override
  String? get lastAtr => null;

  @override
  Future<List<Reader>> listReaders({bool force = false}) async => [];

  @override
  Future<void> connect(Reader reader) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<Channel> openChannel({List<String>? aids}) => openLogicalChannel(aids: aids);

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) async {
    commands.add(Uint8List.fromList(apdu));
    return Uint8List.fromList(<int>[0x90, 0x00]);
  }
}
