import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ogg_caf_converter/models/caf_models.dart';
import 'package:ogg_caf_converter/models/ogg_models.dart';
import 'package:ogg_caf_converter/ogg_caf_converter.dart';
import 'package:test/test.dart';

Future<String?> _findExecutable(String name) async {
  final String lookupCommand = Platform.isWindows ? 'where.exe' : 'which';
  final ProcessResult result;
  try {
    result = await Process.run(lookupCommand, <String>[name]);
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) {
    return null;
  }

  final List<String> paths = (result.stdout as String)
      .split(RegExp(r'\r?\n'))
      .map((String path) => path.trim())
      .where((String path) => path.isNotEmpty)
      .toList();
  return paths.isEmpty ? null : paths.first;
}

Future<T> _withTempDirectory<T>(
  String prefix,
  Future<T> Function(Directory directory) run,
) async {
  final Directory directory = await Directory.systemTemp.createTemp(prefix);
  try {
    return await run(directory);
  } finally {
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  }
}

String _tempPath(Directory directory, String filename) =>
    '${directory.path}${Platform.pathSeparator}$filename';

Future<bool> _afconvertSupportsOpus(String path) async {
  final ProcessResult result = await Process.run(path, <String>['-hf']);
  final String formats =
      '${result.stdout as String}\n${result.stderr as String}';
  return formats.contains("'Oggf'") &&
      formats.contains("'caff'") &&
      formats.contains("'opus'");
}

Future<List<String>> _readFfmpegPacketHashes(
    String ffmpegPath, String input) async {
  final ProcessResult result = await Process.run(ffmpegPath, <String>[
    '-v',
    'error',
    '-xerror',
    '-i',
    input,
    '-map',
    '0:a:0',
    '-c:a',
    'copy',
    '-f',
    'framehash',
    '-hash',
    'sha256',
    '-',
  ]);
  expect(result.exitCode, equals(0), reason: result.stderr.toString());

  final List<String> packets = <String>[];
  for (final String line in (result.stdout as String).split('\n')) {
    if (line.trim().isEmpty || line.startsWith('#')) {
      continue;
    }
    final List<String> fields = line.split(',');
    expect(fields.length, greaterThanOrEqualTo(6), reason: line);
    // CAF and OGG use different timestamps and trim side data. Compare only
    // the encoded packet size and hash, preserving packet boundaries/order.
    packets.add('${fields[4].trim()}:${fields[5].trim()}');
  }
  return packets;
}

Future<List<int>> _decodeFfmpegAudio(String ffmpegPath, String input,
    {String? filter, bool skipManual = false}) async {
  final ProcessResult result = await Process.run(
    ffmpegPath,
    <String>[
      '-v',
      'error',
      '-xerror',
      if (skipManual) ...<String>['-flags2', '+skip_manual'],
      '-i',
      input,
      '-map',
      '0:a:0',
      if (filter != null) ...<String>['-af', filter],
      '-c:a',
      'pcm_s16le',
      '-ar',
      '48000',
      '-f',
      's16le',
      '-',
    ],
    stdoutEncoding: null,
  );
  expect(result.exitCode, equals(0), reason: result.stderr.toString());
  return result.stdout as List<int>;
}

Future<List<Uint8List>> _readOggAudioPackets(String path) async {
  final List<Uint8List> rawPages =
      _iterateOggPages(await File(path).readAsBytes()).toList();
  expect(rawPages, isNotEmpty);
  final OggReader reader = OggReader(path);
  final List<Uint8List> packets = <Uint8List>[];
  try {
    await reader.readHeaders();

    while (true) {
      final OggPageResult page = await reader.parseNextPage();
      if (page.error != null) {
        expect(page.error, equals(OggReaderError.shortPageHeader));
        break;
      }

      packets.addAll(
        page.segments.where(
          (Uint8List segment) =>
              String.fromCharCodes(segment.take(8).toList()) != 'OpusTags',
        ),
      );
    }
  } finally {
    await reader.close();
  }
  return packets;
}

Future<(AudioFormat, PacketTable, Uint8List)> _readCafContents(
    String path) async {
  final CafReader reader = CafReader(path);
  final Uint8List bytes = await File(path).readAsBytes();
  final AudioFormat audioFormat = reader.readAudioFormat(bytes);
  return (
    audioFormat,
    reader.readPacketTable(bytes, audioFormat: audioFormat),
    reader.readAudioData(bytes),
  );
}

final List<int> _oggCrcLookupTable = List<int>.generate(256, (int i) {
  int r = i << 24;
  for (int j = 0; j < 8; j++) {
    if ((r & 0x80000000) != 0) {
      r = ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF;
    } else {
      r = (r << 1) & 0xFFFFFFFF;
    }
  }
  return r;
});

int _computeOggPageCrc(Uint8List page) {
  final Uint8List copy = Uint8List.fromList(page);
  copy.setRange(22, 26, <int>[0, 0, 0, 0]);

  int crc = 0;
  for (final int byte in copy) {
    crc = ((crc << 8) & 0xFFFFFFFF) ^
        _oggCrcLookupTable[((crc >> 24) & 0xFF) ^ byte];
  }
  return crc & 0xFFFFFFFF;
}

Iterable<Uint8List> _iterateOggPages(Uint8List bytes) sync* {
  int offset = 0;
  while (offset < bytes.length) {
    if (bytes.length - offset < pageHeaderLen) {
      throw const FormatException('Truncated Ogg page header');
    }
    if (String.fromCharCodes(bytes.sublist(offset, offset + 4)) !=
        pageHeaderSignature) {
      throw const FormatException('Invalid Ogg page capture pattern');
    }

    final int segmentCount = bytes[offset + 26];
    final int headerLength = pageHeaderLen + segmentCount;
    if (offset + headerLength > bytes.length) {
      throw const FormatException('Truncated Ogg page segment table');
    }

    int bodyLength = 0;
    for (int i = 0; i < segmentCount; i++) {
      bodyLength += bytes[offset + pageHeaderLen + i];
    }

    final int pageEnd = offset + headerLength + bodyLength;
    if (pageEnd > bytes.length) {
      throw const FormatException('Truncated Ogg page body');
    }

    yield bytes.sublist(offset, pageEnd);
    offset = pageEnd;
  }
}

Uint8List _buildSyntheticOpusPacket(int length, {int toc = 0x80}) {
  final Uint8List packet = Uint8List(length);
  packet[0] = toc;
  return packet;
}

OggFile _buildVariableDurationSyntheticOgg({
  int preSkip = 0,
  int remainderFrames = 0,
}) {
  final OggCafConverter syntheticConverter = OggCafConverter();
  final List<Uint8List> packets = <Uint8List>[
    _buildSyntheticOpusPacket(1, toc: 0x90),
    _buildSyntheticOpusPacket(1, toc: 0x98),
    _buildSyntheticOpusPacket(1, toc: 0x90),
  ];
  return syntheticConverter.buildOggFile(
    audioData: Uint8List.fromList(
      packets.expand((Uint8List packet) => packet).toList(),
    ),
    packetTable: packets.map((Uint8List packet) => packet.length).toList(),
    channels: 1,
    preSkip: preSkip,
    sampleRate: opusFixedSampleRate,
    version: 1,
    frameSize: 0,
    remainderFrames: remainderFrames,
    repackage: false,
  );
}

void main() {
  group('convertOggToCaf', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('converts OGG to CAF successfully', () async {
      const String inputFile = 'test_resources/test.ogg';
      await _withTempDirectory('ogg-caf-success-', (Directory directory) async {
        final String outputFile = _tempPath(directory, 'output.caf');
        await oggCafConverter.convertOggToCaf(
          input: inputFile,
          output: outputFile,
        );

        final (_, _, Uint8List audioData) = await _readCafContents(outputFile);
        expect(audioData, isNotEmpty);
        expect(File(inputFile).existsSync(), isTrue);
      });
    });

    test('preserves OGG trimming metadata in generated CAF', () async {
      const String inputFile = 'test_resources/test.ogg';
      await _withTempDirectory('ogg-caf-trim-metadata-',
          (Directory directory) async {
        final String outputFile = _tempPath(directory, 'output.caf');
        await oggCafConverter.convertOggToCaf(
          input: inputFile,
          output: outputFile,
        );

        final (AudioFormat audioFormat, PacketTable packetTable, _) =
            await _readCafContents(outputFile);

        expect(audioFormat.sampleRate, equals(48000));
        expect(audioFormat.framesPerPacket, equals(960));
        expect(audioFormat.channelsPerPacket, equals(1));
        expect(packetTable.header.numberPackets, equals(151));
        expect(packetTable.header.numberValidFrames, equals(144000));
        expect(packetTable.header.primingFrames, equals(312));
        expect(packetTable.header.remainderFrames, equals(648));
      });
    });

    test('matches afconvert output for OGG to CAF', () async {
      final String? afconvertPath = await _findExecutable('afconvert');
      if (afconvertPath == null) {
        markTestSkipped('afconvert is not available');
        return;
      }
      if (!await _afconvertSupportsOpus(afconvertPath)) {
        markTestSkipped('afconvert does not support Opus on this machine');
        return;
      }

      final Directory tempDir =
          await Directory.systemTemp.createTemp('ogg-caf-afconvert-');
      final String libraryOutput = _tempPath(tempDir, 'library.caf');
      final String referenceOutput = _tempPath(tempDir, 'reference.caf');

      try {
        await oggCafConverter.convertOggToCaf(
          input: 'test_resources/test.ogg',
          output: libraryOutput,
        );

        final ProcessResult afconvertResult =
            await Process.run(afconvertPath, <String>[
          '-f',
          'caff',
          '-d',
          'opus',
          'test_resources/test.ogg',
          referenceOutput,
        ]);
        expect(afconvertResult.exitCode, equals(0),
            reason: afconvertResult.stderr.toString());

        final (AudioFormat libFormat, PacketTable libTable, _) =
            await _readCafContents(libraryOutput);
        final (AudioFormat refFormat, PacketTable refTable, _) =
            await _readCafContents(referenceOutput);

        expect(libFormat.sampleRate, equals(refFormat.sampleRate));
        expect(libFormat.framesPerPacket, equals(refFormat.framesPerPacket));
        expect(
            libFormat.channelsPerPacket, equals(refFormat.channelsPerPacket));
        expect(libTable.header.numberPackets,
            equals(refTable.header.numberPackets));
        expect(libTable.header.numberValidFrames,
            equals(refTable.header.numberValidFrames));
        expect(libTable.header.primingFrames,
            equals(refTable.header.primingFrames));
        expect(libTable.header.remainderFrames,
            equals(refTable.header.remainderFrames));
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('writes packet frame entries for variable-duration OGG input',
        () async {
      final OggFile ogg = _buildVariableDurationSyntheticOgg();

      final Directory tempDir =
          await Directory.systemTemp.createTemp('ogg-caf-variable-frames-');
      final String inputFile = _tempPath(tempDir, 'input.ogg');
      final String outputFile = _tempPath(tempDir, 'output.caf');
      final String roundTripFile = _tempPath(tempDir, 'roundtrip.ogg');

      try {
        await File(inputFile).writeAsBytes(ogg.encode());

        await oggCafConverter.convertOggToCaf(
          input: inputFile,
          output: outputFile,
        );

        final (AudioFormat audioFormat, PacketTable packetTable, _) =
            await _readCafContents(outputFile);

        expect(audioFormat.sampleRate, equals(48000));
        expect(audioFormat.bytesPerPacket, equals(0));
        expect(audioFormat.framesPerPacket, equals(0));
        expect(packetTable.entries, equals(<int>[1, 1, 1]));
        expect(packetTable.frameEntries, equals(<int>[480, 960, 480]));
        expect(packetTable.header.numberValidFrames, equals(1920));

        await oggCafConverter.convertCafToOgg(
          input: outputFile,
          output: roundTripFile,
        );

        final List<Uint8List> originalPackets =
            await _readOggAudioPackets(inputFile);
        final List<Uint8List> roundTripPackets =
            await _readOggAudioPackets(roundTripFile);
        expect(roundTripPackets, equals(originalPackets));
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('preserves trim metadata for variable-duration OGG input', () async {
      final OggFile ogg = _buildVariableDurationSyntheticOgg(
        preSkip: 120,
        remainderFrames: 240,
      );
      final Directory tempDir =
          await Directory.systemTemp.createTemp('ogg-caf-variable-trim-');
      final String inputFile = _tempPath(tempDir, 'input.ogg');
      final String outputFile = _tempPath(tempDir, 'output.caf');

      try {
        await File(inputFile).writeAsBytes(ogg.encode());

        await oggCafConverter.convertOggToCaf(
          input: inputFile,
          output: outputFile,
        );

        final (AudioFormat audioFormat, PacketTable packetTable, _) =
            await _readCafContents(outputFile);

        expect(audioFormat.framesPerPacket, equals(0));
        expect(packetTable.frameEntries, equals(<int>[480, 960, 480]));
        expect(packetTable.header.primingFrames, equals(120));
        expect(packetTable.header.remainderFrames, equals(240));
        expect(packetTable.header.numberValidFrames, equals(1560));
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('deletes input file after converting OGG to CAF', () async {
      await _withTempDirectory('ogg-caf-delete-input-',
          (Directory directory) async {
        final String inputFile = _tempPath(directory, 'input.ogg');
        final String outputFile = _tempPath(directory, 'output.caf');
        await File('test_resources/test.ogg').copy(inputFile);
        await oggCafConverter.convertOggToCaf(
          input: inputFile,
          output: outputFile,
          deleteInput: true,
        );

        expect(File(inputFile).existsSync(), isFalse);
        expect(File(outputFile).existsSync(), isTrue);
      });
    });

    test('throws exception for invalid OGG input file', () async {
      const String inputFile = 'test_resources/invalid_ogg.opus';
      await _withTempDirectory('ogg-caf-invalid-input-',
          (Directory directory) async {
        await expectLater(
          oggCafConverter.convertOggToCaf(
            input: inputFile,
            output: _tempPath(directory, 'output.caf'),
          ),
          throwsA(isA<Exception>()),
        );
      });
    });

    test('throws exception for non-existent OGG file', () async {
      await _withTempDirectory('ogg-caf-missing-input-',
          (Directory directory) async {
        await expectLater(
          oggCafConverter.convertOggToCaf(
            input: _tempPath(directory, 'missing.ogg'),
            output: _tempPath(directory, 'output.caf'),
          ),
          throwsA(isA<Exception>()),
        );
      });
    });
  });

  group('convertCafToOgg', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('marks pages that begin with a continued packet', () {
      final List<Uint8List> packets = <Uint8List>[
        ...List<Uint8List>.generate(254, (_) => _buildSyntheticOpusPacket(1)),
        _buildSyntheticOpusPacket(400),
        ...List<Uint8List>.generate(3, (_) => _buildSyntheticOpusPacket(1)),
      ];

      final OggFile ogg = oggCafConverter.buildOggFile(
        audioData: Uint8List.fromList(
          packets.expand((Uint8List packet) => packet).toList(),
        ),
        packetTable: packets.map((Uint8List packet) => packet.length).toList(),
        channels: 1,
        preSkip: 0,
        sampleRate: opusFixedSampleRate,
        version: 1,
        frameSize: 960,
        repackage: false,
      );

      expect(ogg.pages.length, equals(4));
      expect(ogg.pages[2].header[5], equals(0x00));
      expect(ogg.pages[3].header[5], equals(0x05));
    });

    test('converts CAF to OGG successfully', () async {
      const String inputFile = 'test_resources/test.caf';
      await _withTempDirectory('caf-ogg-success-', (Directory directory) async {
        final String outputFile = _tempPath(directory, 'output.ogg');
        await oggCafConverter.convertCafToOgg(
          input: inputFile,
          output: outputFile,
        );

        expect(await _readOggAudioPackets(outputFile), isNotEmpty);
        expect(File(inputFile).existsSync(), isTrue);
      });
    });

    test('preserves CAF trimming metadata in generated OGG', () async {
      const String inputFile = 'test_resources/test.caf';
      await _withTempDirectory('caf-ogg-trim-metadata-',
          (Directory directory) async {
        final String outputFile = _tempPath(directory, 'output.ogg');
        await oggCafConverter.convertCafToOgg(
          input: inputFile,
          output: outputFile,
        );

        final OggReader reader = OggReader(outputFile);
        try {
          final OggHeader headers = await reader.readHeaders();
          expect(headers.preSkip, equals(312));

          final OggPageResult tagsPage = await reader.parseNextPage();
          expect(tagsPage.pageHeader!.headerType, equals(0));

          final OggPageResult audioPage = await reader.parseNextPage();
          expect(audioPage.pageHeader!.headerType, equals(0x04));
          expect(audioPage.pageHeader!.granulePosition, equals(144312));
        } finally {
          await reader.close();
        }
      });
    });

    test('writes valid OGG CRC checksums', () async {
      const String inputFile = 'test_resources/test.caf';
      await _withTempDirectory('caf-ogg-crc-', (Directory directory) async {
        final String outputFile = _tempPath(directory, 'output.ogg');
        await oggCafConverter.convertCafToOgg(
          input: inputFile,
          output: outputFile,
        );

        final Uint8List bytes = await File(outputFile).readAsBytes();
        final List<Uint8List> pages = _iterateOggPages(bytes).toList();
        expect(pages, isNotEmpty);
        for (final Uint8List page in pages) {
          final int storedChecksum =
              ByteData.sublistView(page, 22, 26).getUint32(0, Endian.little);
          expect(_computeOggPageCrc(page), equals(storedChecksum));
        }
      });
    });

    test('writes internally consistent OGG page metadata', () async {
      const String inputFile = 'test_resources/test.caf';
      await _withTempDirectory('caf-ogg-page-metadata-',
          (Directory directory) async {
        final String outputFile = _tempPath(directory, 'output.ogg');
        await oggCafConverter.convertCafToOgg(
          input: inputFile,
          output: outputFile,
        );
        _iterateOggPages(await File(outputFile).readAsBytes()).toList();

        final OggReader reader = OggReader(outputFile);
        try {
          await reader.readHeaders();

          int? serialNumber;
          int? previousSequence;
          int previousGranulePosition = 0;
          OggPageHeader? lastHeader;

          while (true) {
            final OggPageResult page = await reader.parseNextPage();
            if (page.error != null) {
              expect(page.error, equals(OggReaderError.shortPageHeader));
              break;
            }

            final OggPageHeader header = page.pageHeader!;
            serialNumber ??= header.serial;
            expect(header.serial, equals(serialNumber));

            if (previousSequence != null) {
              expect(header.index, equals(previousSequence + 1));
            }
            previousSequence = header.index;

            if (header.granulePosition != 0xFFFFFFFFFFFFFFFF) {
              expect(header.granulePosition,
                  greaterThanOrEqualTo(previousGranulePosition));
              previousGranulePosition = header.granulePosition;
            }

            lastHeader = header;
          }

          expect(lastHeader, isNotNull);
          expect((lastHeader!.headerType & 0x04) != 0, isTrue);
        } finally {
          await reader.close();
        }
      });
    });

    test('preserves CAF packets and trimmed audio with ffmpeg', () async {
      final String? ffmpegPath = await _findExecutable('ffmpeg');
      if (ffmpegPath == null) {
        markTestSkipped('ffmpeg is not available');
        return;
      }

      final Directory tempDir =
          await Directory.systemTemp.createTemp('ogg-caf-ffmpeg-');
      final String libraryOutput = _tempPath(tempDir, 'library.ogg');
      const String inputFile = 'test_resources/test.caf';

      try {
        await oggCafConverter.convertCafToOgg(
          input: inputFile,
          output: libraryOutput,
        );

        // Older FFmpeg CAF demuxers do not synthesize the OpusHead extradata
        // required by the OGG muxer for this Apple CAF fixture. The framehash
        // muxer can still independently read and hash the original packets.
        final List<String> expectedPackets =
            await _readFfmpegPacketHashes(ffmpegPath, inputFile);
        final List<String> actualPackets =
            await _readFfmpegPacketHashes(ffmpegPath, libraryOutput);
        expect(expectedPackets, hasLength(151));
        expect(actualPackets, equals(expectedPackets));

        // The fixture's CAF packet table is in 24 kHz frames: 156 priming,
        // 72000 valid, and 324 remainder. Opus decodes at 48 kHz. Disable
        // automatic trimming for the reference so this also works with newer
        // FFmpeg versions that support CAF trims, then apply them explicitly.
        // The OGG decoder must apply its trim metadata itself.
        final List<int> expectedAudio = await _decodeFfmpegAudio(
          ffmpegPath,
          inputFile,
          filter: 'atrim=start_sample=312:end_sample=144312',
          skipManual: true,
        );
        final List<int> actualAudio =
            await _decodeFfmpegAudio(ffmpegPath, libraryOutput);
        // Three seconds of mono, signed 16-bit PCM at 48 kHz.
        expect(expectedAudio, hasLength(144000 * 2));
        expect(actualAudio, equals(expectedAudio));
      } finally {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      }
    });

    test('deletes input file after converting CAF to OGG', () async {
      await _withTempDirectory('caf-ogg-delete-input-',
          (Directory directory) async {
        final String inputFile = _tempPath(directory, 'input.caf');
        final String outputFile = _tempPath(directory, 'output.ogg');
        await File('test_resources/test.caf').copy(inputFile);
        await oggCafConverter.convertCafToOgg(
          input: inputFile,
          output: outputFile,
          deleteInput: true,
        );

        expect(File(inputFile).existsSync(), isFalse);
        expect(File(outputFile).existsSync(), isTrue);
      });
    });

    test('throws exception for invalid CAF input file', () async {
      const String inputFile = 'test_resources/invalid_caf.opus';
      await _withTempDirectory('caf-ogg-invalid-input-',
          (Directory directory) async {
        await expectLater(
          oggCafConverter.convertCafToOgg(
            input: inputFile,
            output: _tempPath(directory, 'output.ogg'),
          ),
          throwsA(isA<Exception>()),
        );
      });
    });

    test('throws exception for non-existent CAF file', () async {
      await _withTempDirectory('caf-ogg-missing-input-',
          (Directory directory) async {
        await expectLater(
          oggCafConverter.convertCafToOgg(
            input: 'test_resources/non_existent.caf',
            output: _tempPath(directory, 'output.ogg'),
          ),
          throwsA(isA<Exception>()),
        );
      });
    });
  });

  group('convertCafToOggInMemory', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('converts CAF to OGG in memory successfully', () async {
      const String inputFile = 'test_resources/test.caf';
      final Uint8List result =
          await oggCafConverter.convertCafToOggInMemory(input: inputFile);
      expect(result, isNotNull);
      expect(result.length, greaterThan(0));
    });

    test('throws exception for invalid CAF input file', () async {
      const String inputFile = 'test_resources/invalid_caf.opus';
      await expectLater(
        oggCafConverter.convertCafToOggInMemory(input: inputFile),
        throwsA(isA<Exception>()),
      );
    });

    test('throws exception for non-existent CAF file', () async {
      const String inputFile = 'test_resources/non_existent.caf';
      await expectLater(
        oggCafConverter.convertCafToOggInMemory(input: inputFile),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('convertOggToCafInMemory', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('converts OGG to CAF in memory successfully', () async {
      const String inputFile = 'test_resources/test.ogg';
      final Uint8List result =
          await oggCafConverter.convertOggToCafInMemory(input: inputFile);
      expect(result, isNotNull);
      expect(result.length, greaterThan(0));
    });

    test('throws exception for invalid OGG input file', () async {
      const String inputFile = 'test_resources/invalid_ogg.opus';
      await expectLater(
        oggCafConverter.convertOggToCafInMemory(input: inputFile),
        throwsA(isA<Exception>()),
      );
    });

    test('throws exception for non-existent OGG file', () async {
      const String inputFile = 'test_resources/non_existent.ogg';
      await expectLater(
        oggCafConverter.convertOggToCafInMemory(input: inputFile),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('repackageOgg', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('repackages OGG successfully and preserves audio packets', () async {
      const String inputFile = 'test_resources/test.ogg';
      await _withTempDirectory('repackage-ogg-success-',
          (Directory directory) async {
        final String outputFile = _tempPath(directory, 'repackaged.ogg');
        await oggCafConverter.repackageOgg(
          input: inputFile,
          output: outputFile,
        );

        final List<Uint8List> originalPackets =
            await _readOggAudioPackets(inputFile);
        final List<Uint8List> repackagedPackets =
            await _readOggAudioPackets(outputFile);

        expect(repackagedPackets, hasLength(originalPackets.length));
        expect(repackagedPackets, equals(originalPackets));
        expect(File(inputFile).existsSync(), isTrue);
      });
    });

    test('writes valid OGG CRC checksums', () async {
      const String inputFile = 'test_resources/test.ogg';
      await _withTempDirectory('repackage-ogg-crc-',
          (Directory directory) async {
        final String outputFile = _tempPath(directory, 'repackaged.ogg');
        await oggCafConverter.repackageOgg(
          input: inputFile,
          output: outputFile,
        );

        final Uint8List bytes = await File(outputFile).readAsBytes();
        final List<Uint8List> pages = _iterateOggPages(bytes).toList();

        for (final Uint8List page in pages) {
          final int writtenCrc =
              ByteData.sublistView(page, 22, 26).getUint32(0, Endian.little);
          final int expectedCrc = _computeOggPageCrc(page);
          expect(writtenCrc, equals(expectedCrc));
        }
      });
    });

    test('writes internally consistent OGG page metadata and BOS/EOS flags',
        () async {
      const String inputFile = 'test_resources/test.ogg';
      await _withTempDirectory('repackage-ogg-metadata-',
          (Directory directory) async {
        final String outputFile = _tempPath(directory, 'repackaged.ogg');
        await oggCafConverter.repackageOgg(
          input: inputFile,
          output: outputFile,
        );

        final OggReader reader = OggReader(outputFile);
        try {
          final OggHeader header = await reader.readHeaders();
          expect(header.channels, equals(1));
          expect(header.sampleRate, equals(24000));
          expect(header.preSkip, equals(312));

          int expectedSequence = 1;
          int lastGranule = 0;
          OggPageHeader? lastHeader;

          while (true) {
            final OggPageResult page = await reader.parseNextPage();
            if (page.error != null) {
              expect(page.error, equals(OggReaderError.shortPageHeader));
              break;
            }

            final OggPageHeader pageHeader = page.pageHeader!;
            expect(pageHeader.index, equals(expectedSequence));
            expectedSequence++;
            lastHeader = pageHeader;

            if (pageHeader.granulePosition != 0xFFFFFFFFFFFFFFFF) {
              expect(pageHeader.granulePosition,
                  greaterThanOrEqualTo(lastGranule));
              lastGranule = pageHeader.granulePosition;
            }
          }

          expect(lastHeader, isNotNull);
          // End of Stream flag (0x04) set on the last page
          expect((lastHeader!.headerType & 0x04) != 0, isTrue);
          expect(lastHeader.granulePosition, equals(144312));
        } finally {
          await reader.close();
        }
      });
    });

    test('preserves trimming metadata in repackaged OGG', () async {
      const String inputFile = 'test_resources/test.ogg';
      await _withTempDirectory('repackage-ogg-trim-',
          (Directory directory) async {
        final String outputFile = _tempPath(directory, 'repackaged.ogg');
        await oggCafConverter.repackageOgg(
          input: inputFile,
          output: outputFile,
        );

        final OggReader origReader = OggReader(inputFile);
        final OggReader repkgReader = OggReader(outputFile);
        try {
          final OggHeader origHeader = await origReader.readHeaders();
          final OpusData origData = await origReader.readOpusData();

          final OggHeader repkgHeader = await repkgReader.readHeaders();
          final OpusData repkgData = await repkgReader.readOpusData();

          expect(repkgHeader.preSkip, equals(origHeader.preSkip));
          expect(repkgData.finalGranulePosition,
              equals(origData.finalGranulePosition));
          expect(repkgData.totalSamples, equals(origData.totalSamples));
        } finally {
          await origReader.close();
          await repkgReader.close();
        }
      });
    });

    test('repackages variable-duration synthetic OGG correctly', () async {
      final OggFile syntheticOgg = _buildVariableDurationSyntheticOgg(
        preSkip: 120,
        remainderFrames: 240,
      );

      await _withTempDirectory('repackage-ogg-variable-',
          (Directory directory) async {
        final String inputFile = _tempPath(directory, 'synthetic.ogg');
        final String outputFile = _tempPath(directory, 'repackaged.ogg');
        await File(inputFile).writeAsBytes(syntheticOgg.encode());

        await oggCafConverter.repackageOgg(
          input: inputFile,
          output: outputFile,
        );

        final List<Uint8List> origPackets =
            await _readOggAudioPackets(inputFile);
        final List<Uint8List> repkgPackets =
            await _readOggAudioPackets(outputFile);
        expect(repkgPackets, equals(origPackets));

        final OggReader reader = OggReader(outputFile);
        try {
          final OggHeader header = await reader.readHeaders();
          final OpusData data = await reader.readOpusData();
          expect(header.preSkip, equals(120));
          expect(data.packetSampleCounts, equals(<int>[480, 960, 480]));
          expect(data.totalSamples, equals(1920));
          expect(data.finalGranulePosition, equals(1920 - 240));
        } finally {
          await reader.close();
        }
      });
    });

    test('repackages in-place when input equals output', () async {
      await _withTempDirectory('repackage-ogg-inplace-',
          (Directory directory) async {
        final String file = _tempPath(directory, 'audio.ogg');
        await File('test_resources/test.ogg').copy(file);

        final List<Uint8List> originalPackets =
            await _readOggAudioPackets(file);

        await oggCafConverter.repackageOgg(
          input: file,
          output: file,
          deleteInput: true,
        );

        expect(File(file).existsSync(), isTrue);
        final List<Uint8List> repackagedPackets =
            await _readOggAudioPackets(file);
        expect(repackagedPackets, equals(originalPackets));
      });
    });

    test('deletes input file after repackaging', () async {
      await _withTempDirectory('repackage-ogg-delete-input-',
          (Directory directory) async {
        final String inputFile = _tempPath(directory, 'input.ogg');
        final String outputFile = _tempPath(directory, 'output.ogg');
        await File('test_resources/test.ogg').copy(inputFile);

        await oggCafConverter.repackageOgg(
          input: inputFile,
          output: outputFile,
          deleteInput: true,
        );

        expect(File(inputFile).existsSync(), isFalse);
        expect(File(outputFile).existsSync(), isTrue);
      });
    });

    test('throws exception for invalid OGG input file', () async {
      const String inputFile = 'test_resources/invalid_ogg.opus';
      await _withTempDirectory('repackage-ogg-invalid-input-',
          (Directory directory) async {
        await expectLater(
          oggCafConverter.repackageOgg(
            input: inputFile,
            output: _tempPath(directory, 'output.ogg'),
          ),
          throwsA(isA<Exception>()),
        );
      });
    });

    test('throws exception for non-existent OGG file', () async {
      await _withTempDirectory('repackage-ogg-missing-input-',
          (Directory directory) async {
        await expectLater(
          oggCafConverter.repackageOgg(
            input: _tempPath(directory, 'missing.ogg'),
            output: _tempPath(directory, 'output.ogg'),
          ),
          throwsA(isA<Exception>()),
        );
      });
    });
  });

  group('repackageOggInMemory', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('repackages OGG in memory successfully', () async {
      const String inputFile = 'test_resources/test.ogg';
      final Uint8List result =
          await oggCafConverter.repackageOggInMemory(input: inputFile);
      expect(result, isNotNull);
      expect(result.length, greaterThan(0));

      final List<Uint8List> inMemPages = _iterateOggPages(result).toList();
      expect(inMemPages, isNotEmpty);
    });

    test('throws exception for invalid OGG input file', () async {
      const String inputFile = 'test_resources/invalid_ogg.opus';
      await expectLater(
        oggCafConverter.repackageOggInMemory(input: inputFile),
        throwsA(isA<Exception>()),
      );
    });

    test('throws exception for non-existent OGG file', () async {
      const String inputFile = 'test_resources/non_existent.ogg';
      await expectLater(
        oggCafConverter.repackageOggInMemory(input: inputFile),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('CafReader', () {
    test('reads empty packet tables when the packet count is zero', () {
      final PacketTable packetTable = PacketTable(
        header: PacketTableHeader(
          numberPackets: 0,
          numberValidFrames: 0,
          primingFrames: 0,
          remainderFrames: 0,
        ),
        entries: const <int>[],
      );
      final CafFile cafFile = CafFile(
        fileHeader: FileHeader(
          fileType: FourByteString('caff'),
          fileVersion: 1,
          fileFlags: 0,
        ),
        chunks: <Chunk>[
          Chunk(
            header: ChunkHeader(
              chunkType: ChunkTypes.packetTable,
              chunkSize: 24,
            ),
            contents: packetTable,
          ),
        ],
      );

      final PacketTable decoded =
          CafReader('unused').readPacketTable(cafFile.encode());

      expect(decoded.header.numberPackets, equals(0));
      expect(decoded.entries, isEmpty);
    });

    test('reads packet size and frame-count pairs when frames vary', () {
      final AudioFormat audioFormat = AudioFormat(
        sampleRate: 48000,
        formatID: FourByteString('opus'),
        formatFlags: 0,
        bytesPerPacket: 0,
        framesPerPacket: 0,
        channelsPerPacket: 1,
        bitsPerChannel: 0,
      );
      final PacketTable packetTable = PacketTable(
        header: PacketTableHeader(
          numberPackets: 2,
          numberValidFrames: 1440,
          primingFrames: 0,
          remainderFrames: 0,
        ),
        entries: <int>[5, 128],
        frameEntries: <int>[480, 960],
      );
      final CafFile cafFile = CafFile(
        fileHeader: FileHeader(
          fileType: FourByteString('caff'),
          fileVersion: 1,
          fileFlags: 0,
        ),
        chunks: <Chunk>[
          Chunk(
            header: ChunkHeader(
              chunkType: ChunkTypes.audioDescription,
              chunkSize: 32,
            ),
            contents: audioFormat,
          ),
          Chunk(
            header: ChunkHeader(
              chunkType: ChunkTypes.packetTable,
              chunkSize: packetTable.encode().length,
            ),
            contents: packetTable,
          ),
        ],
      );

      final Uint8List bytes = cafFile.encode();
      final PacketTable decoded = CafReader('unused').readPacketTable(bytes);

      expect(decoded.entries, equals(packetTable.entries));
      expect(decoded.frameEntries, equals(packetTable.frameEntries));
    });

    test('reads frame-count-only packet tables when packet sizes are constant',
        () {
      final AudioFormat audioFormat = AudioFormat(
        sampleRate: 48000,
        formatID: FourByteString('opus'),
        formatFlags: 0,
        bytesPerPacket: 3,
        framesPerPacket: 0,
        channelsPerPacket: 1,
        bitsPerChannel: 0,
      );
      final PacketTable packetTable = PacketTable(
        header: PacketTableHeader(
          numberPackets: 2,
          numberValidFrames: 1440,
          primingFrames: 0,
          remainderFrames: 0,
        ),
        entries: const <int>[],
        frameEntries: <int>[480, 960],
      );
      final CafFile cafFile = CafFile(
        fileHeader: FileHeader(
          fileType: FourByteString('caff'),
          fileVersion: 1,
          fileFlags: 0,
        ),
        chunks: <Chunk>[
          Chunk(
            header: ChunkHeader(
              chunkType: ChunkTypes.audioDescription,
              chunkSize: 32,
            ),
            contents: audioFormat,
          ),
          Chunk(
            header: ChunkHeader(
              chunkType: ChunkTypes.packetTable,
              chunkSize: packetTable.encode().length,
            ),
            contents: packetTable,
          ),
        ],
      );

      final Uint8List bytes = cafFile.encode();
      final PacketTable decoded = CafReader('unused').readPacketTable(bytes);

      expect(decoded.entries, isEmpty);
      expect(decoded.frameEntries, equals(packetTable.frameEntries));
    });

    test('throws for malformed packet size and frame-count pairs', () {
      final AudioFormat audioFormat = AudioFormat(
        sampleRate: 48000,
        formatID: FourByteString('opus'),
        formatFlags: 0,
        bytesPerPacket: 0,
        framesPerPacket: 0,
        channelsPerPacket: 1,
        bitsPerChannel: 0,
      );
      final Uint8List validPacketTable = PacketTable(
        header: PacketTableHeader(
          numberPackets: 2,
          numberValidFrames: 1440,
          primingFrames: 0,
          remainderFrames: 0,
        ),
        entries: <int>[5, 128],
        frameEntries: <int>[480, 960],
      ).encode();
      final CafFile cafFile = CafFile(
        fileHeader: FileHeader(
          fileType: FourByteString('caff'),
          fileVersion: 1,
          fileFlags: 0,
        ),
        chunks: <Chunk>[
          Chunk(
            header: ChunkHeader(
              chunkType: ChunkTypes.audioDescription,
              chunkSize: 32,
            ),
            contents: audioFormat,
          ),
          Chunk(
            header: ChunkHeader(
              chunkType: ChunkTypes.packetTable,
              chunkSize: validPacketTable.length,
            ),
            contents: PacketTable(
              header: PacketTableHeader(
                numberPackets: 2,
                numberValidFrames: 1440,
                primingFrames: 0,
                remainderFrames: 0,
              ),
              entries: <int>[5, 128],
              frameEntries: <int>[480, 960],
            ),
          ),
        ],
      );
      final Uint8List bytes = cafFile.encode();
      final Uint8List malformedBytes = bytes.sublist(0, bytes.length - 1);
      ByteData.sublistView(malformedBytes, 56, 64)
          .setInt64(0, validPacketTable.length - 1);

      expect(
        () => CafReader('unused').readPacketTable(malformedBytes),
        throwsException,
      );
    });
  });

  group('Byte-level converters', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('convertCafBytesToOgg converts CAF bytes in memory', () async {
      final Uint8List cafBytes =
          await File('test_resources/test.caf').readAsBytes();
      final Uint8List oggBytes = oggCafConverter.convertCafBytesToOgg(cafBytes);
      expect(oggBytes, isNotEmpty);

      final OggReader reader = OggReader.fromBytes(oggBytes);
      try {
        final OggHeader header = await reader.readHeaders();
        expect(header.channels, equals(1));
        expect(header.preSkip, equals(312));
        final OpusData opusData = await reader.readOpusData();
        expect(opusData.audioData, isNotEmpty);
      } finally {
        await reader.close();
      }
    });

    test('convertOggBytesToCaf converts OGG bytes in memory', () async {
      final Uint8List oggBytes =
          await File('test_resources/test.ogg').readAsBytes();
      final Uint8List cafBytes =
          await oggCafConverter.convertOggBytesToCaf(oggBytes);
      expect(cafBytes, isNotEmpty);

      final CafReader reader = CafReader();
      final AudioFormat format = reader.readAudioFormat(cafBytes);
      expect(format.channelsPerPacket, equals(1));
      expect(format.formatID, equals(FourByteString('opus')));
      final Uint8List audioData = reader.readAudioData(cafBytes);
      expect(audioData, isNotEmpty);
    });

    test('repackageOggBytes repackages OGG bytes in memory', () async {
      final Uint8List oggBytes =
          await File('test_resources/test.ogg').readAsBytes();
      final Uint8List repackagedBytes =
          await oggCafConverter.repackageOggBytes(oggBytes);
      expect(repackagedBytes, isNotEmpty);

      final OggReader reader = OggReader.fromBytes(repackagedBytes);
      try {
        final OggHeader header = await reader.readHeaders();
        expect(header.channels, equals(1));
        final OpusData opusData = await reader.readOpusData();
        expect(opusData.audioData, isNotEmpty);
      } finally {
        await reader.close();
      }
    });
  });

  group('OpusTags vendor string', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test(
        'writes vendor string "Revival Apps ogg_caf_converter" when building OGG',
        () async {
      final Uint8List cafBytes =
          await File('test_resources/test.caf').readAsBytes();
      final Uint8List oggBytes = oggCafConverter.convertCafBytesToOgg(cafBytes);

      final OggReader reader = OggReader.fromBytes(oggBytes);
      try {
        await reader.readHeaders(); // page 0
        final OggPageResult tagsPage = await reader.parseNextPage(); // page 1
        expect(tagsPage.segments, isNotEmpty);
        final Uint8List payload = tagsPage.segments.first;
        expect(utf8.decode(payload.sublist(0, 8)), equals('OpusTags'));
        final int vendorLength =
            ByteData.sublistView(payload, 8, 12).getUint32(0, Endian.little);
        final String vendor =
            utf8.decode(payload.sublist(12, 12 + vendorLength));
        expect(vendor, equals('Revival Apps ogg_caf_converter'));
      } finally {
        await reader.close();
      }
    });
  });

  group('Recursive output directory creation', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('convertOggToCaf creates nested output directories', () async {
      await _withTempDirectory('nested-ogg-caf-', (Directory directory) async {
        final String nestedOut =
            '${directory.path}/deep/nested/path/output.caf';
        await oggCafConverter.convertOggToCaf(
          input: 'test_resources/test.ogg',
          output: nestedOut,
        );
        expect(File(nestedOut).existsSync(), isTrue);
      });
    });

    test('convertCafToOgg creates nested output directories', () async {
      await _withTempDirectory('nested-caf-ogg-', (Directory directory) async {
        final String nestedOut =
            '${directory.path}/deep/nested/path/output.ogg';
        await oggCafConverter.convertCafToOgg(
          input: 'test_resources/test.caf',
          output: nestedOut,
        );
        expect(File(nestedOut).existsSync(), isTrue);
      });
    });

    test('repackageOgg creates nested output directories', () async {
      await _withTempDirectory('nested-repackage-',
          (Directory directory) async {
        final String nestedOut =
            '${directory.path}/deep/nested/path/output.ogg';
        await oggCafConverter.repackageOgg(
          input: 'test_resources/test.ogg',
          output: nestedOut,
        );
        expect(File(nestedOut).existsSync(), isTrue);
      });
    });
  });

  group('Safe in-place deleteInput', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('convertOggToCaf does not delete output when input equals output',
        () async {
      await _withTempDirectory('inplace-ogg-caf-', (Directory directory) async {
        final String filePath = _tempPath(directory, 'audio.caf');
        await File('test_resources/test.ogg').copy(filePath);
        await oggCafConverter.convertOggToCaf(
          input: filePath,
          output: filePath,
          deleteInput: true,
        );
        expect(File(filePath).existsSync(), isTrue);
      });
    });

    test('convertCafToOgg does not delete output when input equals output',
        () async {
      await _withTempDirectory('inplace-caf-ogg-', (Directory directory) async {
        final String filePath = _tempPath(directory, 'audio.ogg');
        await File('test_resources/test.caf').copy(filePath);
        await oggCafConverter.convertCafToOgg(
          input: filePath,
          output: filePath,
          deleteInput: true,
        );
        expect(File(filePath).existsSync(), isTrue);
      });
    });
  });

  group('Empty stream handling', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('sets EOS flag on OpusTags page when packet table is empty', () {
      final OggFile ogg = oggCafConverter.buildOggFile(
        audioData: Uint8List(0),
        packetTable: <int>[],
        channels: 1,
        preSkip: 0,
        sampleRate: 48000,
        version: 1,
        frameSize: 960,
        repackage: false,
      );

      expect(ogg.pages.length, equals(2));
      // Page 0 is OpusHead (headerType 0x02 BOS)
      expect(ogg.pages[0].header[5], equals(0x02));
      // Page 1 is OpusTags (headerType 0x04 EOS because packets.isEmpty)
      expect(ogg.pages[1].header[5], equals(0x04));
    });
  });

  group('Sample rate scaling', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('scales priming frames from non-48kHz sample rate such as 44.1kHz',
        () {
      // 44100 Hz CAF with 441 priming frames -> 480 pre-skip at 48000 Hz
      final AudioFormat audioFormat = AudioFormat(
        sampleRate: 44100,
        formatID: FourByteString('opus'),
        formatFlags: 0,
        bytesPerPacket: 0,
        framesPerPacket: 882,
        channelsPerPacket: 1,
        bitsPerChannel: 0,
      );
      final Uint8List dummyAudioData =
          Uint8List.fromList(<int>[0x01, 0x02, 0x03]);
      final PacketTable packetTable = PacketTable(
        header: PacketTableHeader(
          numberPackets: 1,
          numberValidFrames: 882,
          primingFrames: 441,
          remainderFrames: 441,
        ),
        entries: <int>[3],
        frameEntries: <int>[882],
      );
      final int packetTableSize = packetTable.encode().length;

      final CafFile cafFile = CafFile(
        fileHeader: FileHeader(
          fileType: FourByteString('caff'),
          fileVersion: 1,
          fileFlags: 0,
        ),
        chunks: <Chunk>[
          Chunk(
            header: ChunkHeader(
              chunkType: ChunkTypes.audioDescription,
              chunkSize: 32,
            ),
            contents: audioFormat,
          ),
          Chunk(
            header: ChunkHeader(
              chunkType: ChunkTypes.packetTable,
              chunkSize: packetTableSize,
            ),
            contents: packetTable,
          ),
          Chunk(
            header: ChunkHeader(
              chunkType: ChunkTypes.audioData,
              chunkSize: 7,
            ),
            contents: AudioData(
              editCount: 0,
              data: dummyAudioData,
            ),
          ),
        ],
      );

      final Uint8List cafBytes = cafFile.encode();
      final Uint8List oggBytes = oggCafConverter.convertCafBytesToOgg(cafBytes);
      expect(oggBytes, isNotEmpty);

      // Verify preSkip in OpusHead is 480
      // In Ogg, page 0 header is 28 bytes (27 + 1 segment byte),
      // then OpusHead payload:
      // 'OpusHead' (8 bytes), version (1 byte), channels (1 byte), preSkip (2 bytes uint16 LE)
      // So offset is 28 + 8 + 1 + 1 = 38
      final int preSkip =
          ByteData.sublistView(oggBytes, 38, 40).getUint16(0, Endian.little);
      expect(preSkip, equals(480));
    });
  });
}
