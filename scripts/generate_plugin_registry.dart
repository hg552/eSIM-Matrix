import 'dart:io';

void main(List<String> arguments) {
  if (arguments.any((argument) => argument != '--public')) {
    stderr.writeln(
      'Usage: dart run scripts/generate_plugin_registry.dart [--public]',
    );
    exit(2);
  }

  final directory = Directory('lib/plugins');
  if (!directory.existsSync()) {
    stderr.writeln(
      'Error: Run this script from the nlpa2 project root (where lib/ is located).',
    );
    exit(1);
  }

  Iterable<File> files;
  if (arguments.contains('--public')) {
    // An overlay checkout also contains private plugins. Only publish the
    // plugins tracked (including staged additions) by this repository.
    final result = Process.runSync('git', [
      'ls-files',
      '-z',
      '--',
      'lib/plugins/*.dart',
    ]);
    if (result.exitCode != 0) {
      stderr.write(result.stderr);
      exit(result.exitCode);
    }
    files = (result.stdout as String)
        .split('\u0000')
        .where((path) => path.isNotEmpty)
        .map(File.new);
  } else {
    files = directory.listSync().whereType<File>().where(
      (file) => file.path.endsWith('.dart'),
    );
  }

  List<String> imports = [];
  List<String> profilePlugins = [];
  List<String> sessionPlugins = [];

  final profileRegex = RegExp(
    r'class\s+([A-Za-z0-9_]+)\s+(?:extends|implements)[^{]*ProfilePlugin',
  );
  final sessionRegex = RegExp(
    r'class\s+([A-Za-z0-9_]+)\s+(?:extends|implements)[^{]*SessionPlugin',
  );

  for (var file in files) {
    final filename = file.uri.pathSegments.last;
    if (filename == 'plugin_base.dart' ||
        filename == 'session_plugin.dart' ||
        filename == 'plugin_manager.dart' ||
        filename == 'build_plugin_registry.dart') {
      continue;
    }

    final content = file.readAsStringSync();
    final profileMatch = profileRegex.firstMatch(content);
    final sessionMatch = sessionRegex.firstMatch(content);

    if (profileMatch != null || sessionMatch != null) {
      imports.add("import '$filename';");

      if (profileMatch != null) {
        profilePlugins.add(
          "        '${profileMatch.group(1)}': ${profileMatch.group(1)}.new,",
        );
      }
      if (sessionMatch != null) {
        sessionPlugins.add(
          "        '${sessionMatch.group(1)}': ${sessionMatch.group(1)}.new,",
        );
      }
    }
  }

  imports.sort();

  final generatedCode =
      '''
// GENERATED FILE - DO NOT EDIT
// Run `dart run scripts/generate_plugin_registry.dart` to update.

${imports.join('\n')}
import 'plugin_base.dart';
import 'session_plugin.dart';

typedef ProfilePluginFactory = ProfilePlugin Function();
typedef SessionPluginFactory = SessionPlugin Function();

class BuildPluginRegistry {
  BuildPluginRegistry._();

  static final Map<String, ProfilePluginFactory> _profileFactories =
      <String, ProfilePluginFactory>{
${profilePlugins.join('\n')}
      };

  static final Map<String, SessionPluginFactory> _sessionFactories =
      <String, SessionPluginFactory>{
${sessionPlugins.join('\n')}
      };

  static List<ProfilePlugin> createPlugins() {
    return _profileFactories.values
        .map((factory) => factory())
        .toList(growable: false);
  }

  static List<SessionPlugin> createSessionPlugins() {
    return _sessionFactories.values
        .map((factory) => factory())
        .toList(growable: false);
  }
}
''';

  File(
    'lib/plugins/build_plugin_registry.dart',
  ).writeAsStringSync(generatedCode);
  stdout.writeln('Generated lib/plugins/build_plugin_registry.dart');
}
