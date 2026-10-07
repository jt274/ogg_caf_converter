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
  });
}
