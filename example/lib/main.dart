import 'dart:typed_data';

import 'package:ogg_caf_converter/ogg_caf_converter.dart';

const String inputFilePath = 'path/to/input/file.opus'; // Input file location
const String outputFilePath =
    'path/to/output/file.opus'; // Output file location

void main() async {
  // Convert from OGG to CAF
  try {
    await OggCafConverter().convertOggToCaf(
      input: inputFilePath,
      output: outputFilePath,
      deleteInput: true,
    );
  } catch (e) {
    // Handle error
  }

  // Convert from CAF to OGG
  try {
    await OggCafConverter().convertCafToOgg(
      input: inputFilePath,
      output: outputFilePath,
      deleteInput: true,
    );
  } catch (e) {
    // Handle error
  }

  // Convert from OGG to CAF in memory
  try {
    final Uint8List bytes = await OggCafConverter().convertOggToCafInMemory(
      input: inputFilePath,
    );
  } catch (e) {
    // Handle error
  }

  // Convert from CAF to OGG in memory
  try {
    final Uint8List bytes = await OggCafConverter().convertCafToOggInMemory(
      input: inputFilePath,
    );
  } catch (e) {
    // Handle error
  }
}
