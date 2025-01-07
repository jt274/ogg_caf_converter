import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int pageHeaderTypeBeginningOfStream = 0x02;
const String pageHeaderSignature = 'OggS';
const String idPageSignature = 'OpusHead';

const int pageHeaderLen = 27;
const int idPagePayloadLength = 19;

enum OggReaderError {
  nilStream,
  badIDPageSignature,
  badIDPageType,
  badIDPageLength,
  badIDPagePayloadSignature,
  shortPageHeader,
}

class OggPageResult {
  OggPageResult({required this.segments, this.pageHeader, this.error});
  final List<List<int>> segments;
  final OggPageHeader? pageHeader;
  final OggReaderError? error;
}

class OpusData {
  OpusData(
      {required this.audioData,
      required this.trailingData,
      required this.frameSize});
  final List<int> audioData;
  final List<int> trailingData;
  final int frameSize;
}

// OggHeader is the metadata from the first two pages
// in the file (ID and Comment)
class OggHeader {
  OggHeader({
    required this.channelMap,
    required this.channels,
    required this.outputGain,
    required this.preSkip,
    required this.sampleRate,
    required this.version,
  });

  late int channelMap;
  late int channels;
  late int outputGain;
  late int preSkip;
  late int sampleRate;
  late int version;
}

// OggPageHeader is the metadata for a Page
// Pages are the fundamental unit of multiplexing in an Ogg stream
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

  late int granulePosition;
  late List<int> sig;
  late int version;
  late int headerType;
  late int serial;
  late int index;
  late int segmentsCount;
}

class OggReader {
  OggReader(String filePath) {
    final File file = File(filePath);
    raFile = file.openSync();
  }

  late String filePath;

  late RandomAccessFile? raFile;

  Future<void> close() async {
    await raFile?.close();
  }

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