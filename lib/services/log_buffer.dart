import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

class LogBuffer {
  static final LogBuffer _instance = LogBuffer._internal();
  factory LogBuffer() => _instance;
  LogBuffer._internal() {
    Logger.root.onRecord.listen((record) {
      _logs.add(record);
      if (_logs.length > _maxLogs) {
        _logs.removeFirst();
      }
      _appendToFile(record);
    });
  }

  final int _maxLogs = 1000;
  final Queue<LogRecord> _logs = Queue<LogRecord>();

  List<LogRecord> get logs => _logs.toList();

  IOSink? _sink;
  String? _filePath;

  /// Where this run's log is being written, once [startFileLogging] has run.
  String? get filePath => _filePath;

  void init() {
    // Just to trigger the singleton initialization
  }

  /// Mirrors every record to a file for the current run.
  ///
  /// The in-memory buffer holds only the last [_maxLogs] records, which a retry
  /// storm can flush in seconds -- exactly when the interesting lines are being
  /// produced. A file keeps the whole run instead.
  ///
  /// Debug builds only. Records carry APDUs, EIDs and ICCIDs, so a shipped
  /// build must not leave them on disk for every run; the log console this
  /// exists to support is developer-gated for the same reason.
  Future<void> startFileLogging() async {
    if (!kDebugMode || kIsWeb || _sink != null) return;
    try {
      final file = await _resolveLogFile();
      _sink = file.openWrite(mode: FileMode.write);
      _filePath = file.path;
      _sink!.writeln('=== session started ${DateTime.now().toIso8601String()}');
      Logger('LogBuffer').info('Writing this session log to ${file.path}');
    } catch (_) {
      // Logging must never take the app down.
      _sink = null;
      _filePath = null;
    }
  }

  /// On macOS the log goes to /private/tmp, which the sandbox is granted in
  /// DebugProfile.entitlements. The container is unreadable to any other
  /// process, so a log left there could not be collected afterwards.
  Future<File> _resolveLogFile() async {
    if (!kIsWeb && Platform.isMacOS) {
      final shared = File('/private/tmp/nlpa-session.log');
      try {
        shared.writeAsStringSync('', mode: FileMode.write);
        return shared;
      } catch (_) {
        // Fall through to the sandboxed location.
      }
    }
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/nlpa-session.log');
  }

  void _appendToFile(LogRecord record) {
    final sink = _sink;
    if (sink == null) return;
    try {
      sink.writeln(
        '${record.time.toIso8601String()} ${record.level.name.padRight(7)} '
        '${record.loggerName}: ${record.message}',
      );
    } catch (_) {
      // Ignore: a broken sink must not break logging.
    }
  }
}
