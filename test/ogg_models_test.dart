import 'dart:io';
import 'dart:typed_data';

import 'package:ogg_caf_converter/models/ogg_models.dart';
import 'package:test/test.dart';

void main() {
  group('OggReader', () {
    test('reads headers successfully', () async {
      final OggReader reader = OggReader('test_resources/test.ogg');
      try {
        final OggHeader headers = await reader.readHeaders();
        expect(headers.version, equals(1));
        expect(headers.channels, equals(1));
        expect(headers.preSkip, equals(312));
        expect(headers.sampleRate, equals(24000));
        expect(headers.channelMap, equals(0));
      } finally {
        await reader.close();
      }
    });

    test('reads Opus data successfully', () async {
      final OggReader reader = OggReader('test_resources/test.ogg');
      try {
        await reader.readHeaders();
        final OpusData opusData = await reader.readOpusData();
        expect(opusData.audioData, isNotEmpty);
        expect(opusData.frameSize, equals(960));
        expect(opusData.packetSampleCounts, hasLength(151));
        expect(opusData.packetSampleCounts, everyElement(960));
        expect(opusData.totalSamples, equals(151 * 960));
      } finally {
        await reader.close();
      }
    });

    test('parses next page successfully', () async {
      final OggReader reader = OggReader('test_resources/test.ogg');
      try {
        final OggPageResult result = await reader.parseNextPage();
        expect(result.error, isNull);
        expect(result.segments, hasLength(1));
        expect(result.pageHeader, isNotNull);
        expect(String.fromCharCodes(result.pageHeader!.sig), equals('OggS'));
        expect(result.pageHeader!.headerType, equals(0x02));
        expect(
          String.fromCharCodes(result.segments.single.take(8).toList()),
          equals('OpusHead'),
        );
      } finally {
        await reader.close();
      }
    });

    test('throws exception for short page header', () async {
      final OggReader reader =
          OggReader('test_resources/short_page_header.ogg');
      try {
        final OggPageResult result = await reader.parseNextPage();
        expect(result.error, OggReaderError.shortPageHeader);
        expect(result.pageHeader, isNull);
        expect(result.segments, isEmpty);
      } finally {
        await reader.close();
      }
    });

    test('initializes filePath correctly for file reader and fromBytes',
        () async {
      final OggReader fileReader = OggReader('test_resources/test.ogg');
      try {
        expect(fileReader.filePath, equals('test_resources/test.ogg'));
      } finally {
        await fileReader.close();
      }

      final OggReader bytesReader = OggReader.fromBytes(Uint8List(0));
      try {
        expect(bytesReader.filePath, equals(''));
      } finally {
        await bytesReader.close();
      }
    });

    test('OggReader.fromBytes reads headers and Opus data from memory',
        () async {
      final Uint8List fileBytes =
          await File('test_resources/test.ogg').readAsBytes();
      final OggReader memoryReader = OggReader.fromBytes(fileBytes);
      try {
        final OggHeader headers = await memoryReader.readHeaders();
        expect(headers.version, equals(1));
        expect(headers.channels, equals(1));
        expect(headers.preSkip, equals(312));
        expect(headers.sampleRate, equals(24000));

        final OpusData opusData = await memoryReader.readOpusData();
        expect(opusData.audioData, isNotEmpty);
        expect(opusData.frameSize, equals(960));
        expect(opusData.packetSampleCounts, hasLength(151));
      } finally {
        await memoryReader.close();
      }
    });

    test('returns shortPageHeader when segment table is truncated', () async {
      // 27-byte header with segment count = 10, but only 2 segment size bytes
      final Uint8List bytes = Uint8List(27 + 2);
      bytes.setRange(0, 4, 'OggS'.codeUnits);
      bytes[26] = 10; // declares 10 segments, but only 2 bytes exist
      final OggReader reader = OggReader.fromBytes(bytes);
      try {
        final OggPageResult result = await reader.parseNextPage();
        expect(result.error, equals(OggReaderError.shortPageHeader));
      } finally {
        await reader.close();
      }
    });

    test('returns shortPageHeader when segment body data is truncated',
        () async {
      // 27-byte header with 1 segment of size 50, but only 10 bytes of body data exist
      final Uint8List bytes = Uint8List(27 + 1 + 10);
      bytes.setRange(0, 4, 'OggS'.codeUnits);
      bytes[26] = 1; // 1 segment
      bytes[27] = 50; // segment size 50, but only 10 bytes of body follow
      final OggReader reader = OggReader.fromBytes(bytes);
      try {
        final OggPageResult result = await reader.parseNextPage();
        expect(result.error, equals(OggReaderError.shortPageHeader));
      } finally {
        await reader.close();
      }
    });

    test('parses granule position with all bits set (0xFF) as -1', () async {
      final Uint8List page = Uint8List(27 + 1 + 4);
      page.setRange(0, 4, 'OggS'.codeUnits);
      page[4] = 0; // version
      page[5] = 0; // header type
      // Set 8 bytes of granule position to 0xFF (-1 in two's complement)
      page.fillRange(6, 14, 0xFF);
      page[26] = 1; // 1 segment
      page[27] = 4; // segment length 4
      page.fillRange(28, 32, 0x00);

      final OggReader reader = OggReader.fromBytes(page);
      try {
        final OggPageResult result = await reader.parseNextPage();
        expect(result.error, isNull);
        expect(result.pageHeader, isNotNull);
        expect(result.pageHeader!.granulePosition, equals(-1));
      } finally {
        await reader.close();
      }
    });

    test(
        'readOpusData ignores pages with granule position -1 when setting finalGranulePosition',
        () async {
      Uint8List makePage({
        required int granulePos,
        required int seq,
        required Uint8List packet,
      }) {
        final Uint8List page = Uint8List(27 + 1 + packet.length);
        page.setRange(0, 4, 'OggS'.codeUnits);
        page[4] = 0;
        page[5] = 0;
        if (granulePos == -1) {
          page.fillRange(6, 14, 0xFF);
        } else {
          ByteData.sublistView(page, 6, 14)
              .setInt64(0, granulePos, Endian.little);
        }
        ByteData.sublistView(page, 18, 22).setUint32(0, seq, Endian.little);
        page[26] = 1;
        page[27] = packet.length;
        page.setRange(28, 28 + packet.length, packet);
        return page;
      }

      final Uint8List packet = Uint8List(4)..[0] = 0x80;
      final Uint8List page1 = makePage(granulePos: 960, seq: 0, packet: packet);
      final Uint8List page2 = makePage(granulePos: -1, seq: 1, packet: packet);
      final Uint8List stream = Uint8List.fromList(<int>[...page1, ...page2]);

      final OggReader reader = OggReader.fromBytes(stream);
      try {
        final OpusData data = await reader.readOpusData();
        expect(data.finalGranulePosition, equals(960));
      } finally {
        await reader.close();
      }
    });
  });
}
