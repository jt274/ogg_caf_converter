import 'dart:io';

import 'package:ogg_caf_converter/ogg_caf_converter.dart';
import 'package:test/test.dart';

void main() {
  group('OpusCaf', () {
    final OpusCaf opusCaf = OpusCaf();

    test('converts OGG to CAF successfully', () async {
      const String inputFile = 'test_resources/test.ogg';
      const String outputFile = 'test_resources/test_output.caf';
      // Convert OGG to CAF
      await opusCaf.convertOggToCaf(input: inputFile, output: outputFile);
      // Check if the output file exists
      expect(File(outputFile).existsSync(), isTrue);
      // Check if input file still exists
      expect(File(inputFile).existsSync(), isTrue);
      // Delete the output file after completing test
      File(outputFile).deleteSync();
    });

    test('converts CAF to OGG successfully', () async {
      const String inputFile = 'test_resources/test.caf';
      const String outputFile = 'test_resources/test_output.ogg';
      // Convert CAF to OGG
      await opusCaf.convertCafToOgg(input: inputFile, output: outputFile);
      // Check if the output file exists
      expect(File(outputFile).existsSync(), isTrue);
      // Check if input file still exists
      expect(File(inputFile).existsSync(), isTrue);
      // Delete the output file after completing test
      File(outputFile).deleteSync();
    });

    test('deletes input file after converting OGG to CAF', () async {
      const String inputFile = 'test_resources/test_temp.ogg';
      const String outputFile = 'test_resources/test_temp.caf';
      // Create temporary input file for test
      File('test_resources/test.ogg').copySync(inputFile);
      // Convert OGG to CAF
      await opusCaf.convertOggToCaf(
        input: inputFile,
        output: outputFile,
        deleteInput: true,
      );
      // Check if the input file has been deleted
      expect(File(inputFile).existsSync(), isFalse);
      // Delete the output file after completing test
      File(outputFile).deleteSync();
    });

    test('deletes input file after converting CAF to OGG', () async {
      const String inputFile = 'test_resources/test_temp.caf';
      const String outputFile = 'test_resources/test_temp.ogg';
      // Create temporary input file for test
      File('test_resources/test.caf').copySync(inputFile);
      // Convert CAF to OGG
      await opusCaf.convertCafToOgg(
        input: inputFile,
        output: outputFile,
        deleteInput: true,
      );
      // Check if the input file has been deleted
      expect(File(inputFile).existsSync(), isFalse);
      // Delete the output file after completing test
      File(outputFile).deleteSync();
    });

    test('throws exception for invalid OGG input file', () {
      const String inputFile = 'test_resources/invalid_ogg.opus';
      const String outputFile = 'test_resources/test_temp.opus';
      expect(
          () => opusCaf.convertOggToCaf(input: inputFile, output: outputFile),
          throwsException);
    });

    test('throws exception for invalid CAF input file', () {
      const String inputFile = 'test_resources/invalid_caf.opus';
      const String outputFile = 'test_resources/test_temp.opus';
      expect(
          () => opusCaf.convertOggToCaf(input: inputFile, output: outputFile),
          throwsException);
    });

    test('throws exception for non-existent OGG file', () {
      const String inputFile = 'test_resources/non_existent.opus';
      const String outputFile = 'test_resources/test_temp.opus';
      expect(
          () => opusCaf.convertOggToCaf(input: inputFile, output: outputFile),
          throwsException);
    });

    test('throws exception for non-existent CAF file', () {
      const String inputFile = 'test_resources/non_existent.opus';
      const String outputFile = 'test_resources/test_temp.opus';
      expect(
          () => opusCaf.convertCafToOgg(input: inputFile, output: outputFile),
          throwsException);
    });
  });
}