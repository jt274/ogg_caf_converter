<h1 style="text-align: center;">OPUS Audio OGG/CAF Converter</h1>
<p style="text-align: center;">
    <a href="https://github.com/jt274/ogg_caf_converter/actions">
        <img src="https://github.com/jt274/ogg_caf_converter/actions/workflows/run_tests.yml/badge.svg?branch=main" alt="Build Status" />
    </a>
    <a href='https://coveralls.io/github/jt274/ogg_caf_converter?branch=main'>
        <img src='https://coveralls.io/repos/github/jt274/ogg_caf_converter/badge.svg?branch=dev' alt='Coverage Status' />
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
- Converts OPUS audio files from OGG (standard spec) to CAF (Apple) container format.
- Converts OPUS audio files from CAF (Apple) to OGG (standard spec) container format.
- Lightweight, pure dart implementation.

## Platform Support

| Android | iOS | Web | Windows | Linux | MacOS |
| :-----: | :-: |:---:|:-------:| :---: |:-----:|
|   ✅    | ✅  |  ❓  |    ❓    |  ❓   |   ❓   |

Testing on unknown platforms is welcome! Please file a GitHub issue if you determine how the 
package functions on another platform.

## Getting started

Add the package to your `pubspec.yaml` file:

`dart pub add ogg_caf_converter`

or

`flutter pub add ogg_caf_converter`

## Usage

To convert an OPUS audio file from a standard OGG container format to an Apple CAF container format,
use the `convertOggToCaf()` method.

To convert an OPUS audio file from an Apple CAF container format to a standard OGG container format,
use the `convertCafToOgg()` method.

Both functions take the same input parameters:
- `input`: The path to the input file.
- `output`: The path to the output file (must have write access to this file path).
- `deleteInput`: Whether to delete the input file after successful conversion. Defaults to `false`.

## Example

Make sure to place the function call inside of a try-catch block to handle any exceptions, and await
the function call to ensure the conversion is complete before continuing.

```dart
import 'package:ogg_caf_converter/ogg_caf_converter.dart';

final inputFilePath = 'path/to/input/file.opus'; // Input file location
final outputFilePath = 'path/to/output/file.opus'; // Output file location

void main() async {
    // Convert from OGG to CAF
    try {
        await OggCafConverter.convertOggToCaf({
            input: inputFilePath,
            output: outputFilePath,
            deleteInput: true,
        });
    } catch (String e) {
        print(e);
    }
    
    // Convert from CAF to OGG
    try {
        await OggCafConverter.convertCafToOgg({
            input: filePath,
            output: outputFilePath,
            deleteInput: true,
        });
    } catch (String e) {
        print(e);
    }
}
```

## Issues

Please file any bugs or feature requests on the GitHub repository.