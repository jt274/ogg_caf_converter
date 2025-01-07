import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Beginning of stream type for the Ogg page header.
const int pageHeaderTypeBeginningOfStream = 0x02;

/// Signature of the Ogg page header.
const String pageHeaderSignature = 'OggS';

/// Signature of the ID page.
const String idPageSignature = 'OpusHead';

/// Length of the Ogg page header.
const int pageHeaderLen = 27;

/// Length of the ID page payload.
const int idPagePayloadLength = 19;

/// Enum representing possible errors that can occur while reading an Ogg file.
enum OggReaderError {
  nilStream,
  badIDPageSignature,
  badIDPageType,
  badIDPageLength,
  badIDPagePayloadSignature,
  shortPageHeader,
}

/// Class representing the result of parsing an Ogg page.
class OggPageResult {
  OggPageResult({required this.segments, this.pageHeader, this.error});

  /// List of segments in the Ogg page.
  final List<List<int>> segments;

  /// Header of the Ogg page.
  final OggPageHeader? pageHeader;

  /// Error encountered while parsing the Ogg page, if any.
  final OggReaderError? error;
}

/// Class representing Opus data extracted from an Ogg file.
class OpusData {
  OpusData(
      {required this.audioData,
      required this.trailingData,
      required this.frameSize});

  /// List of audio data bytes.
  final List<int> audioData;

  /// List of trailing data bytes.
  final List<int> trailingData;

  /// Size of the audio frame.
  final int frameSize;
}

/// Class representing the header data from the Ogg file.
class OggHeader {
  OggHeader({
    required this.channelMap,
    required this.channels,
    required this.outputGain,
    required this.preSkip,
    required this.sampleRate,
    required this.version,
  });

  /// Channel map.
  late int channelMap;

  /// Number of channels.
  late int channels;

  /// Output gain.
  late int outputGain;

  /// Pre-skip.
  late int preSkip;

  /// Sample rate.
  late int sampleRate;

  /// Version.
  late int version;
}

/// Class representing the metadata for an Ogg page.
/// Pages are the fundamental unit of multiplexing in an Ogg stream.
class OggPageHeader {
  OggPageHeader({
    required this.granulePosition,
    required this.sig,
    required this.version,
    required this.headerType,
    required this.serial,
    required this.index,
    required this.segmentsCount,
  });

  /// Granule position.
  late int granulePosition;

  /// Signature.
  late List<int> sig;

  /// Version.
  late int version;

  /// Header type.
  late int headerType;

  /// Serial.
  late int serial;

  /// Index.
  late int index;

  /// Number of segments.
  late int segmentsCount;
}

/// Class for reading and parsing Ogg files.
class OggReader {
  OggReader(String filePath) {
    final File file = File(filePath);
    raFile = file.openSync();
  }

  /// Path to the Ogg file.
  late String filePath;

  /// Random access file for the Ogg file.
  late RandomAccessFile? raFile;

  /// Closes the Ogg file.
  Future<void> close() async {
    await raFile?.close();
  }

  /// Reads the headers from the Ogg file.
  /// Throws an exception if an error occurs while reading the headers.
  Future<OggHeader> readHeaders() async {
    final OggPageResult result = await parseNextPage();
    final List<List<int>> segments = result.segments;
    final OggPageHeader? pageHeader = result.pageHeader;
    final OggReaderError? err = result.error;

    if (err != null) {
      throw Exception(err);
    }

    if (pageHeader == null) {
      throw Exception(err);
    }

    if (utf8.decode(pageHeader.sig) != pageHeaderSignature) {
      throw Exception(OggReaderError.badIDPageSignature);
    }

    if (pageHeader.headerType != pageHeaderTypeBeginningOfStream) {
      throw Exception(OggReaderError.badIDPageType);
    }

    final OggHeader header = OggHeader(
        channelMap: 0,
        channels: 0,
        outputGain: 0,
        preSkip: 0,
        sampleRate: 0,
        version: 0);

    if (segments[0].length != idPagePayloadLength) {
      throw Exception(OggReaderError.badIDPageLength);
    }

    if (utf8.decode(segments[0].sublist(0, 8)) != idPageSignature) {
      throw Exception(OggReaderError.badIDPagePayloadSignature);
    }

    header
      ..version = segments[0][8]
      ..channels = segments[0][9]
      ..preSkip = ByteData.sublistView(Uint8List.fromList(segments[0]), 10, 12)
          .getUint16(0, Endian.little)
      ..sampleRate =
          ByteData.sublistView(Uint8List.fromList(segments[0]), 12, 16)
              .getUint32(0, Endian.little)
      ..outputGain =
          ByteData.sublistView(Uint8List.fromList(segments[0]), 16, 18)
              .getUint16(0, Endian.little)
      ..channelMap = segments[0][18];

    return header;
  }

  /// Reads Opus data from the Ogg file.
  /// Throws an exception if an error occurs while reading the Opus data.
  Future<OpusData> readOpusData({required int sampleRate}) async {
    final List<int> audioData = <int>[];
    int frameSize = 0;
    final List<int> trailingData = <int>[];

    while (true) {
      final OggPageResult result = await parseNextPage();
      final List<List<int>> segments = result.segments;
      final OggPageHeader? header = result.pageHeader;
      final OggReaderError? err = result.error;

      if (err == OggReaderError.nilStream ||
          err == OggReaderError.shortPageHeader) {
        break;
      } else if (err != null) {
        throw Exception('Unexpected error: $err');
      }

      if (segments.isNotEmpty &&
          utf8.decode(segments.first.take(8).toList(), allowMalformed: true) ==
              'OpusTags') {
        continue;
      }

      for (final List<int> segment in segments) {
        trailingData.add(segment.length);
        audioData.addAll(segment);
      }

      if (header?.index == 2) {
        final List<int> tmpPacket = segments[0];
        if (tmpPacket.isNotEmpty) {
          final int tmptoc = tmpPacket[0] & 255;
          final int tocConfig = tmptoc >> 3;
          final int frameCode = tocConfig & 0x03;

          if (tocConfig < 12) {
            // SILK mode
            frameSize = <int>[10, 20, 40, 60][frameCode] * sampleRate ~/ 1000;
          } else if (tocConfig < 16) {
            // Hybrid mode
            frameSize = <int>[10, 20, 40, 60][frameCode] * sampleRate ~/ 1000;
          } else {
            // CELT mode
            frameSize = <num>[2.5, 5, 10, 20][frameCode] * sampleRate ~/ 1000;
          }
        }
      }
    }

    return OpusData(
        audioData: audioData, trailingData: trailingData, frameSize: frameSize);
  }

  /// Parses the next page in the Ogg file.
  /// Returns an [OggPageResult] containing the parsed segments and page header.
  Future<OggPageResult> parseNextPage() async {
    final Uint8List h = Uint8List(pageHeaderLen);

    final int bytesRead = await raFile?.readInto(h) ?? 0;
    if (bytesRead < pageHeaderLen) {
      return OggPageResult(
          segments: <List<int>>[], error: OggReaderError.shortPageHeader);
    }

    final OggPageHeader pageHeader = OggPageHeader(
      granulePosition: 0,
      sig: <int>[],
      version: 0,
      headerType: 0,
      serial: 0,
      index: 0,
      segmentsCount: 0,
    );

    pageHeader
      ..sig = h.sublist(0, 4)
      ..version = h[4]
      ..headerType = h[5]
      ..granulePosition =
          ByteData.sublistView(h, 6, 14).getUint64(0, Endian.little)
      ..serial = ByteData.sublistView(h, 14, 18).getUint32(0, Endian.little)
      ..index = ByteData.sublistView(h, 18, 22).getUint32(0, Endian.little)
      ..segmentsCount = h[26];

    final List<int> sizeBuffer = List<int>.filled(pageHeader.segmentsCount, 0);
    await raFile?.readInto(sizeBuffer);

    final List<int> newArr = <int>[];
    int i = 0;
    while (i < sizeBuffer.length) {
      if (sizeBuffer[i] == 255) {
        int sum = sizeBuffer[i];
        i++;
        while (i < sizeBuffer.length && sizeBuffer[i] == 255) {
          sum += sizeBuffer[i];
          i++;
        }
        if (i < sizeBuffer.length) {
          sum += sizeBuffer[i];
        }
        newArr.add(sum);
      } else {
        newArr.add(sizeBuffer[i]);
      }
      i++;
    }

    final List<Uint8List> segments = <Uint8List>[];

    for (final int s in newArr) {
      final List<int> segment = List<int>.filled(s, 0);
      await raFile?.readInto(segment);
      segments.add(Uint8List.fromList(segment));
    }

    return OggPageResult(segments: segments, pageHeader: pageHeader);
  }
}
