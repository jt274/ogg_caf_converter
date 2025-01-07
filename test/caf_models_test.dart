import 'dart:convert';
import 'dart:typed_data';

import 'package:ogg_caf_converter/models/caf_models.dart';
import 'package:test/test.dart';

void main() {
  group('FourByteString', () {
    test('creates valid FourByteString with 4 characters', () {
      final FourByteString fourByteString = FourByteString('test');
      expect(fourByteString.bytes, equals(<int>[116, 101, 115, 116]));
    });

    test('creates default FourByteString with less than 4 characters', () {
      final FourByteString fourByteString = FourByteString('te');
      expect(fourByteString.bytes, equals(<int>[0, 0, 0, 0]));
    });

    test('creates default FourByteString with more than 4 characters', () {
      final FourByteString fourByteString = FourByteString('testing');
      expect(fourByteString.bytes, equals(<int>[0, 0, 0, 0]));
    });

    test('compares equal FourByteStrings correctly', () {
      final FourByteString fourByteString1 = FourByteString('test');
      final FourByteString fourByteString2 = FourByteString('test');
      expect(fourByteString1, equals(fourByteString2));
    });

    test('compares different FourByteStrings correctly', () {
      final FourByteString fourByteString1 = FourByteString('test');
      final FourByteString fourByteString2 = FourByteString('diff');
      expect(fourByteString1, isNot(equals(fourByteString2)));
    });
  });

  group('ChunkHeader', () {
    test('encodes ChunkHeader correctly', () {
      final ChunkHeader chunkHeader =
          ChunkHeader(chunkType: FourByteString('test'), chunkSize: 12345);
      final Uint8List encoded = chunkHeader.encode();
      expect(encoded.length, equals(12));
      expect(encoded.sublist(0, 4), equals(<int>[116, 101, 115, 116]));
      expect(ByteData.sublistView(encoded, 4, 12).getInt64(0), equals(12345));
    });

    test('decodes valid ChunkHeader correctly', () {
      final Uint8List data = Uint8List(12);
      data.setRange(0, 4, <int>[116, 101, 115, 116]);
      ByteData.sublistView(data, 4, 12).setInt64(0, 12345);
      final ChunkHeader? chunkHeader = ChunkHeader.decode(data);
      expect(chunkHeader, isNotNull);
      expect(chunkHeader!.chunkType, equals(FourByteString('test')));
      expect(chunkHeader.chunkSize, equals(12345));
    });

    test('returns null for invalid ChunkHeader data', () {
      final Uint8List data = Uint8List(10); // Less than required 12 bytes
      final ChunkHeader? chunkHeader = ChunkHeader.decode(data);
      expect(chunkHeader, isNull);
    });
  });

  group('ChannelDescription', () {
    test('encodes ChannelDescription correctly', () {
      final ChannelDescription channelDescription = ChannelDescription(
        channelLabel: 1,
        channelFlags: 2,
        coordinates: <double>[0.1, 0.2, 0.3],
      );
      final Uint8List encoded = channelDescription.encode();
      expect(encoded.length, equals(20));
      expect(ByteData.sublistView(encoded).getInt32(0), equals(1));
      expect(ByteData.sublistView(encoded).getInt32(4), equals(2));
      expect(ByteData.sublistView(encoded).getFloat32(8), closeTo(0.1, 0.0001));
      expect(
          ByteData.sublistView(encoded).getFloat32(12), closeTo(0.2, 0.0001));
      expect(
          ByteData.sublistView(encoded).getFloat32(16), closeTo(0.3, 0.0001));
    });
  });

  group('Information', () {
    test('encodes Information correctly', () {
      final Information information = Information(key: 'key', value: 'value');
      final Uint8List encoded = information.encode();
      expect(encoded, equals(utf8.encode('keyvalue')));
    });
  });

  group('CAFStringsChunk', () {
    test('encodes CAFStringsChunk correctly', () {
      final CAFStringsChunk stringsChunk = CAFStringsChunk(
        numEntries: 2,
        strings: <Information>[
          Information(key: 'key1', value: 'value1'),
          Information(key: 'key2', value: 'value2')
        ],
      );
      final Uint8List encoded = stringsChunk.encode();
      expect(ByteData.sublistView(encoded).getUint32(0), equals(2));
      expect(utf8.decode(encoded.sublist(4)), equals('key1value1key2value2'));
    });
  });

  group('PacketTable', () {
    test('encodes PacketTable correctly', () {
      final PacketTable packetTable = PacketTable(
        header: PacketTableHeader(
          numberPackets: 1,
          numberValidFrames: 2,
          primingFrames: 3,
          remainderFrames: 4,
        ),
        entries: <int>[5, 6, 7],
      );
      final Uint8List encoded = packetTable.encode();
      expect(ByteData.sublistView(encoded).getInt64(0), equals(1));
      expect(ByteData.sublistView(encoded).getInt64(8), equals(2));
      expect(ByteData.sublistView(encoded).getInt32(16), equals(3));
      expect(ByteData.sublistView(encoded).getInt32(20), equals(4));
      expect(encoded.sublist(24), equals(<int>[5, 6, 7]));
    });
  });
}
