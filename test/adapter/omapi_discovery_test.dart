import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/adapter/omapi/omapi_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ee.nekoko.omapi_plugin');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('forced refresh bypasses an empty discovery cache', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => ++calls == 1 ? <String>[] : ['SIM1'],
    );
    final adapter = OmapiAdapter();
    expect(await adapter.listReaders(), isEmpty);
    expect(await adapter.listReaders(), isEmpty);
    expect(calls, 1);
    expect((await adapter.listReaders(force: true)).single.id, 'omapi:SIM1');
    expect(calls, 2);
  });

  test('service connection invalidates an earlier empty result', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => ++calls == 1 ? <String>[] : ['SIM1'],
    );
    final adapter = OmapiAdapter();
    expect(await adapter.listReaders(), isEmpty);
    adapter.invalidateReaderCache();
    expect((await adapter.listReaders()).single.id, 'omapi:SIM1');
    expect(calls, 2);
  });
}
