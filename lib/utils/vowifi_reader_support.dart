import '../adapter/euicc_adapter.dart';
import '../adapter/omapi/omapi_adapter.dart';
import '../settings/build_capabilities.dart';
import 'platform_adapter.dart';

/// Checks both the selected reader and the adapter that will execute its APDUs.
bool supportsVowifiReader(Reader? reader, {Adapter? adapter}) {
  if (reader == null) return false;
  final source = reader.source;
  final connectedSource = adapter?.connectedReader?.id == reader.id
      ? adapter?.connectedReader?.source
      : null;
  return BuildCapabilities.isVowifiReaderAvailable(
    isAndroid: PlatformX.isAndroid,
    isOmapi:
        source is OmapiAdapter ||
        adapter is OmapiAdapter ||
        connectedSource is OmapiAdapter,
    supportsRawApdu:
        source.supportsRawApdu &&
        (adapter?.supportsRawApdu ?? true) &&
        (connectedSource?.supportsRawApdu ?? true),
  );
}

void requireVowifiReader(Adapter adapter, Reader reader) {
  if (!supportsVowifiReader(reader, adapter: adapter)) {
    throw UnsupportedError(
      'VoWiFi requires a raw basic-channel reader; Android and OMAPI adapters are not supported.',
    );
  }
}
