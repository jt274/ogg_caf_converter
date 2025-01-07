import 'package:ogg_caf_converter/models/ogg_models.dart';
import 'package:test/test.dart';

void main() {
  group('OggReader', () {
    test('reads headers successfully', () async {
      final OggReader reader = OggReader('test_resources/test.ogg');
      final OggHeader headers = await reader.readHeaders();
      expect(headers.version, isNotNull);
      expect(headers.channels, isNotNull);
      await reader.close();
    });

    test('reads Opus data successfully', () async {
      final OggReader reader = OggReader('test_resources/test.ogg');
      final OpusData opusData = await reader.readOpusData(sampleRate: 48000);
      expect(opusData.audioData, isNotEmpty);
      expect(opusData.frameSize, isNotNull);
      await reader.close();
    });

    test('parses next page successfully', () async {
      final OggReader reader = OggReader('test_resources/test.ogg');
      final OggPageResult result = await reader.parseNextPage();
      expect(result.segments, isNotEmpty);
      expect(result.pageHeader, isNotNull);
      await reader.close();
    });

    test('throws exception for short page header', () async {
      final OggReader reader =
          OggReader('test_resources/short_page_header.ogg');
      final OggPageResult result = await reader.parseNextPage();
      expect(result.error, OggReaderError.shortPageHeader);
      await reader.close();
    });
  });
}
