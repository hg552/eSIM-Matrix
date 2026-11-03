/// Outcome of asking one reader source (OMAPI, CCID, BLE, ...) for readers.
enum DiscoveryStatus { ok, skipped, error }

class DiscoverySourceResult {
  const DiscoverySourceResult({
    required this.source,
    required this.status,
    this.readerNames = const [],
    this.detail,
    this.elapsed = Duration.zero,
  });

  final String source;
  final DiscoveryStatus status;
  final List<String> readerNames;

  /// Skip reason, error text, or extra context (e.g. the raw OMAPI list).
  final String? detail;
  final Duration elapsed;

  int get count => readerNames.length;
}

/// What the last reader scan asked, and what every source answered.
///
/// Built by `CompositeAdapter` so that an empty reader list can be explained
/// source by source instead of as a blank screen.
class ReaderDiscoveryReport {
  const ReaderDiscoveryReport({
    required this.at,
    required this.forced,
    required this.sources,
    required this.totalReaders,
    this.failure,
  });

  final DateTime at;
  final bool forced;
  final List<DiscoverySourceResult> sources;
  final int totalReaders;

  /// Set when the scan itself threw instead of returning a list.
  final String? failure;
}
