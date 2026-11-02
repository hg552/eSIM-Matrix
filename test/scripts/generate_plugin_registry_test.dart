import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'public registry excludes private overlay plugins but includes staged additions',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nlpa2_registry_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final script = File(
        'scripts/generate_plugin_registry.dart',
      ).absolute.path;
      final plugins = Directory('${directory.path}/lib/plugins');
      await plugins.create(recursive: true);

      Future<ProcessResult> run(String executable, List<String> arguments) {
        return Process.run(
          executable,
          arguments,
          workingDirectory: directory.path,
        );
      }

      final init = await run('git', ['init', '--initial-branch=master']);
      expect(init.exitCode, 0, reason: init.stderr.toString());
      await File(
        '${plugins.path}/public_reader.dart',
      ).writeAsString('class PublicReaderPlugin extends ProfilePlugin {}');
      final add = await run('git', ['add', 'lib/plugins/public_reader.dart']);
      expect(add.exitCode, 0, reason: add.stderr.toString());
      // A copied overlay file is a regular file too: symlink filtering alone
      // would still publish it. The public mode must use the repository index.
      await File(
        '${plugins.path}/private_vendor.dart',
      ).writeAsString('class PrivateVendorPlugin extends ProfilePlugin {}');
      final dart = Platform.isWindows ? 'dart.exe' : 'dart';

      final public = await run(dart, [script, '--public']);
      expect(public.exitCode, 0, reason: public.stderr.toString());
      final registry = File('${plugins.path}/build_plugin_registry.dart');
      final publicSource = await registry.readAsString();
      expect(publicSource, contains("import 'public_reader.dart';"));
      expect(publicSource, contains('PublicReaderPlugin.new'));
      expect(publicSource, isNot(contains('PrivateVendorPlugin')));
      expect(publicSource, isNot(contains('private_vendor.dart')));

      final overlay = await run(dart, [script]);
      expect(overlay.exitCode, 0, reason: overlay.stderr.toString());
      final overlaySource = await registry.readAsString();
      expect(overlaySource, contains('PublicReaderPlugin.new'));
      expect(overlaySource, contains('PrivateVendorPlugin.new'));
    },
  );
}
