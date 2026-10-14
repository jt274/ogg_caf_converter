import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('compiles to JavaScript with dart compile js without literal errors',
      () async {
    final Directory tempDir =
        await Directory.systemTemp.createTemp('ogg_caf_web_test_');
    try {
      final File entrypoint = File('${tempDir.path}/main.dart');
      await entrypoint.writeAsString('''
import 'package:ogg_caf_converter/ogg_caf_converter.dart';

void main() {
  // Reference top-level class to ensure compiler processes package AST
  print(OggCafConverter);
}
''');

      final File outFile = File('${tempDir.path}/out.js');
      final ProcessResult result = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'compile',
          'js',
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          '-o',
          outFile.path,
          entrypoint.path,
        ],
      );

      expect(
        result.exitCode,
        equals(0),
        reason:
            'dart compile js failed with code ${result.exitCode}:\nSTDOUT:\n${result.stdout}\nSTDERR:\n${result.stderr}',
      );
      expect(
        result.stdout.toString(),
        isNot(contains("can't be represented exactly in JavaScript")),
      );
      expect(
        result.stderr.toString(),
        isNot(contains("can't be represented exactly in JavaScript")),
      );
    } finally {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    }
  });
}
