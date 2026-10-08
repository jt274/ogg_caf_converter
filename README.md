<h1 style="text-align: center;">OPUS Audio OGG/CAF Converter</h1>
<p style="text-align: center;">
    <a href="https://github.com/jt274/ogg_caf_converter/actions">
        <img src="https://github.com/jt274/ogg_caf_converter/actions/workflows/run_tests.yml/badge.svg?branch=main" alt="Build Status" />
    </a>
    <a href='https://coveralls.io/github/jt274/ogg_caf_converter?branch=main'>
        <img src='https://coveralls.io/repos/github/jt274/ogg_caf_converter/badge.svg?branch=main' alt='Coverage Status' />
    </a>
    <a href="https://www.paypal.com/ncp/payment/HFAXZ7CTFQC6L">
        <img src="https://img.shields.io/badge/Donate-PayPal-00457C?logo=paypal" alt="Donate" />
    </a>
</p>

Convert OPUS audio files between OGG (standard) and CAF (Apple) container formats using pure dart.

OPUS is a modern, leading audio codec that is widely used for audio streaming and storage due to its
smaller file size without loss of quality. However, Apple does not conform to the standard OGG container 
spec for OPUS files, so it is difficult to use the OPUS codec when building cross-platform apps in
Flutter/Dart. For example, iOS devices cannot play OPUS audio files in OGG format, and Android devices
cannot play OPUS audio files in CAF format.

This package provides a simple way to convert OPUS audio files between OGG and CAF container formats
(in either direction) using pure dart, without any external libraries or encoders.

Conversion is fast since the audio itself is not being re-encoded, but simply repackaged into a 
different container format. This means that the audio quality is not affected by the conversion, and
speed is primarily limited by the file system I/O speed.

## Features
- **CAF ↔ OGG Container Conversion**: Converts OPUS audio files between standard OGG and Apple CAF container formats in either direction.
- **Variable & Constant Duration Support**: Supports both constant-duration and variable-duration Opus packets (SILK, CELT, and Hybrid modes).
- **In-Memory & File Operations**: Convert and repackage files directly on disk or in-memory (`Uint8List`).
- **OGG Stream Repackaging & Repair**: Sanitizes OGG Opus containers, rebuilds canonical `OpusHead` and `OpusTags` headers, recalculates sequential 48 kHz granule positions per RFC 7845, verifies CRC-32 checksums, and normalizes packet lacing and page framing.
- **Accurate Trim Metadata**: Accurately maps pre-skip priming frames (`preSkip` ↔ `primingFrames`) and end trim (`remainderFrames` ↔ final granule position) between CAF and OGG.
- **Pure Dart**: Zero external dependencies, no native binaries, and no FFmpeg required.

## Platform Support

| Android | iOS | Web | Windows | Linux | MacOS |
| :-----: | :-: |:---:|:-------:| :---: |:-----:|
|   ✅    | ✅  |  ❌  |    ✅     |  ✅   |   ✅    |

- **Web**: Currently unsupported because the package relies directly on `dart:io` (`File`, `RandomAccessFile`) and uses 64-bit integer bitmasks incompatible with Dart2JS/web compilation.

## Getting started

Add the package to your `pubspec.yaml` file:

```bash
dart pub add ogg_caf_converter
```

or

```bash
flutter pub add ogg_caf_converter
```

## Usage

### Converting Between OGG and CAF

To convert an OPUS audio file from a standard OGG container format to an Apple CAF container format,
use the `convertOggToCaf()` method.

To convert an OPUS audio file from an Apple CAF container format to a standard OGG container format,
use the `convertCafToOgg()` method.

Both conversion functions take the following parameters:
- `input`: The path to the input file (must have read access to this file path).
- `output`: The path to the output file (must have write access to this file path).
- `deleteInput`: Whether to delete the input file after successful conversion. Defaults to `false`.

For in-memory conversion from a file path without creating a new file, use `convertOggToCafInMemory()` and 
`convertCafToOggInMemory()`. Both return a `Uint8List` of the converted audio file bytes.

If you already have audio bytes in memory (e.g. from network or audio record buffers), you can convert bytes directly without any filesystem operations:
- `convertOggBytesToCaf(Uint8List bytes)`: Converts OGG Opus bytes to CAF bytes.
- `convertCafBytesToOgg(Uint8List bytes)`: Converts CAF Opus bytes to standard OGG Opus bytes.

### Repackaging OGG Files

Many mobile audio recording packages produce raw OGG Opus recordings with non-standard page framing,
missing or non-linear granule positions, or malformed metadata headers. These issues often prevent audio 
players from seeking accurately or calculating stream duration correctly.

To repair and repackage an OGG file without re-encoding audio:
- `repackageOgg()`: Reads the input OGG Opus file, strips non-standard framing, recalculates accurate 48 kHz granule positions for every packet, writes canonical `OpusHead` and `OpusTags` pages with valid CRC-32 checksums, and saves to `output`. In-place repackaging (`input == output`) is supported safely.
- `repackageOggInMemory()`: Performs the same container sanitization on a file and returns the resulting OGG bytes as a `Uint8List`.
- `repackageOggBytes(Uint8List bytes)`: Performs container sanitization directly on in-memory OGG bytes without any filesystem operations.

## Example

Make sure to place function calls inside of a try-catch block to handle exceptions, and await
the call to ensure processing is complete before continuing.

```dart
import 'dart:typed_data';

import 'package:ogg_caf_converter/ogg_caf_converter.dart';

const String inputOgg = 'path/to/input.ogg';
const String outputCaf = 'path/to/output.caf';
const String repackagedOgg = 'path/to/repackaged.ogg';

void main() async {
  final OggCafConverter converter = OggCafConverter();

  // Convert from OGG to CAF
  try {
    await converter.convertOggToCaf(
      input: inputOgg,
      output: outputCaf,
      deleteInput: false,
    );
  } catch (e) {
    // Handle error
  }

  // Convert from CAF to OGG
  try {
    await converter.convertCafToOgg(
      input: outputCaf,
      output: inputOgg,
      deleteInput: false,
    );
  } catch (e) {
    // Handle error
  }

  // Convert in memory
  try {
    final Uint8List cafBytes = await converter.convertOggToCafInMemory(
      input: inputOgg,
    );
    final Uint8List oggBytes = await converter.convertCafToOggInMemory(
      input: outputCaf,
    );
  } catch (e) {
    // Handle error
  }

  // Repackage / repair OGG file
  try {
    await converter.repackageOgg(
      input: inputOgg,
      output: repackagedOgg,
      deleteInput: false,
    );
  } catch (e) {
    // Handle error
  }

  // Repackage OGG in memory
  try {
    final Uint8List sanitizedBytes = await converter.repackageOggInMemory(
      input: inputOgg,
    );
  } catch (e) {
    // Handle error
  }

  // Pure in-memory byte conversions (no filesystem access)
  try {
    final Uint8List rawOggBytes = Uint8List(0); // your OGG bytes
    final Uint8List convertedCaf = await converter.convertOggBytesToCaf(rawOggBytes);
    final Uint8List convertedOgg = converter.convertCafBytesToOgg(convertedCaf);
    final Uint8List repackagedBytes = await converter.repackageOggBytes(rawOggBytes);
  } catch (e) {
    // Handle error
  }
}
```

## Issues

Please file any bugs or feature requests on the GitHub repository.