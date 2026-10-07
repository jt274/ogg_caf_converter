import 'dart:io';
import 'dart:typed_data';

import 'package:ogg_caf_converter/models/caf_models.dart';
import 'package:ogg_caf_converter/models/ogg_models.dart';
import 'package:ogg_caf_converter/ogg_caf_converter.dart';
import 'package:test/test.dart';

Future<String?> _findExecutable(String name) async {
  final ProcessResult result = await Process.run('which', <String>[name]);
  if (result.exitCode != 0) {
    return null;
  }

  final String path = (result.stdout as String).trim();
  return path.isEmpty ? null : path;
}

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

Future<(AudioFormat, PacketTable, Uint8List)> _readCafContents(
    String path) async {
  final CafReader reader = CafReader(path);
  final Uint8List bytes = await File(path).readAsBytes();
  return (
    reader.readAudioFormat(bytes),
    reader.readPacketTable(bytes),
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
  while (offset + pageHeaderLen <= bytes.length) {
    final int segmentCount = bytes[offset + 26];
    final int headerLength = pageHeaderLen + segmentCount;
    int bodyLength = 0;
    for (int i = 0; i < segmentCount; i++) {
      bodyLength += bytes[offset + pageHeaderLen + i];
    }

    final int pageEnd = offset + headerLength + bodyLength;
    if (pageEnd > bytes.length) {
      break;
    }

    yield bytes.sublist(offset, pageEnd);
    offset = pageEnd;
  }
}

Uint8List _buildSyntheticOpusPacket(int length) {
  final Uint8List packet = Uint8List(length);
  packet[0] = 0x80;
  return packet;
}

void main() {
  group('convertOggToCaf', () {
    final OggCafConverter oggCafConverter = OggCafConverter();

    test('converts OGG to CAF successfully', () async {
      const String inputFile = 'test_resources/test.ogg';
      const String outputFile = 'test_resources/test_output.caf';
      // Convert OGG to CAF
      await oggCafConverter.convertOggToCaf(
          input: inputFile, output: outputFile);
      // Check if the output file exists
      expect(File(outputFile).existsSync(), isTrue);
      // Check if input file still exists
      expect(File(inputFile).existsSync(), isTrue);
      // Delete the output file after completing test
      File(outputFile).deleteSync();
    });

    test('preserves OGG trimming metadata in generated CAF', () async {
      const String inputFile = 'test_resources/test.ogg';
      const String outputFile = 'test_resources/test_output.caf';
      await oggCafConverter.convertOggToCaf(
          input: inputFile, output: outputFile);

      final (AudioFormat audioFormat, PacketTable packetTable, Uint8List _) =
          await _readCafContents(outputFile);

      expect(audioFormat.sampleRate, equals(48000));
      expect(audioFormat.framesPerPacket, equals(960));
      expect(audioFormat.channelsPerPacket, equals(1));
      expect(packetTable.header.numberPackets, equals(151));
      expect(packetTable.header.numberValidFrames, equals(144000));
      expect(packetTable.header.primingFrames, equals(312));
      expect(packetTable.header.remainderFrames, equals(648));

      File(outputFile).deleteSync();
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
      final String libraryOutput = '${tempDir.path}/library.caf';
      final String referenceOutput = '${tempDir.path}/reference.caf';

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

    test('deletes input file after converting OGG to CAF', () async {
      const String inputFile = 'test_resources/test_temp.ogg';
      const String outputFile = 'test_resources/test_temp.caf';
      // Create temporary input file for test
      File('test_resources/test.ogg').copySync(inputFile);
      // Convert OGG to CAF
      await oggCafConverter.convertOggToCaf(
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
          () => oggCafConverter.convertOggToCaf(
              input: inputFile, output: outputFile),
          throwsException);
    });

    test('throws exception for non-existent OGG file', () {
      const String inputFile = 'test_resources/non_existent.opus';
      const String outputFile = 'test_resources/test_temp.opus';
      expect(
          () => oggCafConverter.convertOggToCaf(
              input: inputFile, output: outputFile),
          throwsException);
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
      const String outputFile = 'test_resources/test_output.ogg';
      // Convert CAF to OGG
      await oggCafConverter.convertCafToOgg(
          input: inputFile, output: outputFile);
      // Check if the output file exists
      expect(File(outputFile).existsSync(), isTrue);
      // Check if input file still exists
      expect(File(inputFile).existsSync(), isTrue);
      // Delete the output file after completing test
      File(outputFile).deleteSync();
    });

    test('preserves CAF trimming metadata in generated OGG', () async {
      const String inputFile = 'test_resources/test.caf';
      const String outputFile = 'test_resources/test_output.ogg';
      await oggCafConverter.convertCafToOgg(
          input: inputFile, output: outputFile);

      final OggReader reader = OggReader(outputFile);
      final OggHeader headers = await reader.readHeaders();
      expect(headers.preSkip, equals(312));

      final OggPageResult tagsPage = await reader.parseNextPage();
      expect(tagsPage.pageHeader!.headerType, equals(0));

      final OggPageResult audioPage = await reader.parseNextPage();
      expect(audioPage.pageHeader!.headerType, equals(0x04));
      expect(audioPage.pageHeader!.granulePosition, equals(144312));

      await reader.close();
      File(outputFile).deleteSync();
    });

    test('writes valid OGG CRC checksums', () async {
      const String inputFile = 'test_resources/test.caf';
      const String outputFile = 'test_resources/test_output.ogg';
      await oggCafConverter.convertCafToOgg(
          input: inputFile, output: outputFile);

      final Uint8List bytes = await File(outputFile).readAsBytes();
      for (final Uint8List page in _iterateOggPages(bytes)) {
        final int storedChecksum =
            ByteData.sublistView(page, 22, 26).getUint32(0, Endian.little);
        expect(_computeOggPageCrc(page), equals(storedChecksum));
      }

      File(outputFile).deleteSync();
    });

    test('writes internally consistent OGG page metadata', () async {
      const String inputFile = 'test_resources/test.caf';
      const String outputFile = 'test_resources/test_output.ogg';
      await oggCafConverter.convertCafToOgg(
          input: inputFile, output: outputFile);

      final OggReader reader = OggReader(outputFile);
      await reader.readHeaders();

      int? serialNumber;
      int? previousSequence;
      int previousGranulePosition = 0;
      OggPageHeader? lastHeader;

      while (true) {
        final OggPageResult page = await reader.parseNextPage();
        if (page.error != null) {
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

      await reader.close();
      File(outputFile).deleteSync();
    });

    test('preserves CAF packets and trimmed audio with ffmpeg', () async {
      final String? ffmpegPath = await _findExecutable('ffmpeg');
      if (ffmpegPath == null) {
        markTestSkipped('ffmpeg is not available');
        return;
      }

      final Directory tempDir =
          await Directory.systemTemp.createTemp('ogg-caf-ffmpeg-');
      final String libraryOutput = '${tempDir.path}/library.ogg';
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
      const String inputFile = 'test_resources/test_temp.caf';
      const String outputFile = 'test_resources/test_temp.ogg';
      // Create temporary input file for test
      File('test_resources/test.caf').copySync(inputFile);
      // Convert CAF to OGG
      await oggCafConverter.convertCafToOgg(
        input: inputFile,
        output: outputFile,
        deleteInput: true,
      );
      // Check if the input file has been deleted
      expect(File(inputFile).existsSync(), isFalse);
      // Delete the output file after completing test
      File(outputFile).deleteSync();
    });

    test('throws exception for invalid CAF input file', () {
      const String inputFile = 'test_resources/invalid_caf.opus';
      const String outputFile = 'test_resources/test_temp.opus';
      expect(
          () => oggCafConverter.convertOggToCaf(
              input: inputFile, output: outputFile),
          throwsException);
    });

    test('throws exception for non-existent CAF file', () {
      const String inputFile = 'test_resources/non_existent.opus';
      const String outputFile = 'test_resources/test_temp.opus';
      expect(
          () => oggCafConverter.convertCafToOgg(
              input: inputFile, output: outputFile),
          throwsException);
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
      expect(
        () async => oggCafConverter.convertCafToOggInMemory(input: inputFile),
        throwsA(isA<Exception>()),
      );
    });

    test('throws exception for non-existent CAF file', () async {
      const String inputFile = 'test_resources/non_existent.caf';
      expect(
        () async => oggCafConverter.convertCafToOggInMemory(input: inputFile),
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
      expect(
        () async => oggCafConverter.convertOggToCafInMemory(input: inputFile),
        throwsA(isA<Exception>()),
      );
    });

    test('throws exception for non-existent OGG file', () async {
      const String inputFile = 'test_resources/non_existent.ogg';
      expect(
        () async => oggCafConverter.convertOggToCafInMemory(input: inputFile),
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
  });
}
