import 'dart:convert';
import 'dart:typed_data';
import 'package:meta/meta.dart';

@immutable
class FourByteString {
  FourByteString(String string)
      : bytes = (string.length == 4) ? utf8.encode(string) : <int>[0, 0, 0, 0];
  final List<int> bytes;

  @override
  bool operator ==(Object other) =>
      other is FourByteString && bytes.toString() == other.bytes.toString();

  @override
  int get hashCode => bytes.hashCode;

  Uint8List encode() {
    return Uint8List.fromList(bytes);
  }
}

class ChunkTypes {
  static final FourByteString audioDescription = FourByteString('desc');
  static final FourByteString channelLayout = FourByteString('chan');
  static final FourByteString information = FourByteString('info');
  static final FourByteString audioData = FourByteString('data');
  static final FourByteString packetTable = FourByteString('pakt');
  static final FourByteString midi = FourByteString('midi');
}

class CafFile {
  CafFile({required this.fileHeader, required this.chunks});
  final FileHeader fileHeader;
  final List<Chunk> chunks;

  Uint8List encode() {
    final Uint8List encodedFileHeader = fileHeader.encode();
    final List<Uint8List> encodedChunks =
        chunks.map((Chunk chunk) => chunk.encode()).toList();

    int totalLength = encodedFileHeader.length;
    for (final Uint8List encodedChunk in encodedChunks) {
      totalLength += encodedChunk.length;
    }

    final Uint8List data = Uint8List(totalLength);

    int offset = 0;
    data.setRange(offset, offset + encodedFileHeader.length, encodedFileHeader);
    offset += encodedFileHeader.length;

    for (final Uint8List encodedChunk in encodedChunks) {
      data.setRange(offset, offset + encodedChunk.length, encodedChunk);
      offset += encodedChunk.length;
    }

    return data;
  }
}

class ChunkHeader {
  ChunkHeader({required this.chunkType, required this.chunkSize});
  final FourByteString chunkType;
  final int chunkSize;

  Uint8List encode() {
    final ByteData data = ByteData(12);

    final Uint8List encodedChunkType = chunkType.encode();
    for (int i = 0; i < encodedChunkType.length; i++) {
      data.setUint8(i, encodedChunkType[i]);
    }

    data.setInt64(4, chunkSize);

    return data.buffer.asUint8List();
  }

  static ChunkHeader? decode(Uint8List data) {
    if (data.length < 12) {
      return null;
    }

    final Uint8List chunkTypeData = data.sublist(0, 4);
    final String chunkTypeString = utf8.decode(chunkTypeData);

    final FourByteString chunkType = FourByteString(chunkTypeString);
    final int chunkSize = ByteData.sublistView(data, 4, 12).getInt64(0);

    return ChunkHeader(chunkType: chunkType, chunkSize: chunkSize);
  }
}

class ChannelDescription {
  ChannelDescription({
    required this.channelLabel,
    required this.channelFlags,
    required this.coordinates,
  });
  final int channelLabel;
  final int channelFlags;
  final List<double> coordinates;

  Uint8List encode() {
    final ByteData data = ByteData(20);
    data.setInt32(0, channelLabel);
    data.setInt32(4, channelFlags);
    data.setFloat32(8, coordinates[0]);
    data.setFloat32(12, coordinates[1]);
    data.setFloat32(16, coordinates[2]);
    return data.buffer.asUint8List();
  }
}

class UnknownContents {
  UnknownContents(this.data);
  final Uint8List data;

  Uint8List encode() {
    return data;
  }
}

typedef Midi = Uint8List;

class Information {
  Information({required this.key, required this.value});
  final String key;
  final String value;

  Uint8List encode() {
    final Uint8List encodedKey = utf8.encode(key);
    final Uint8List encodedValue = utf8.encode(value);

    final int totalLength = encodedKey.length + encodedValue.length;

    final Uint8List data = Uint8List(totalLength);

    data.setRange(0, encodedKey.length, encodedKey);
    data.setRange(encodedKey.length, totalLength, encodedValue);

    return data;
  }
}

class PacketTableHeader {
  PacketTableHeader({
    required this.numberPackets,
    required this.numberValidFrames,
    required this.primingFrames,
    required this.remainderFrames,
  });
  final int numberPackets;
  final int numberValidFrames;
  final int primingFrames;
  final int remainderFrames;
}

class CAFStringsChunk {
  CAFStringsChunk({required this.numEntries, required this.strings});
  final int numEntries;
  final List<Information> strings;

  Uint8List encode() {
    int totalSize = 4;

    final List<Uint8List> encodedStrings = <Uint8List>[];
    for (final Information stringInfo in strings) {
      final Uint8List encoded = stringInfo.encode();
      encodedStrings.add(encoded);
      totalSize += encoded.length;
    }

    final ByteData data = ByteData(totalSize);

    data.setUint32(0, numEntries);

    int offset = 4;
    for (final Uint8List encodedString in encodedStrings) {
      for (int i = 0; i < encodedString.length; i++) {
        data.setUint8(offset, encodedString[i]);
        offset++;
      }
    }

    return data.buffer.asUint8List();
  }
}

class PacketTable {
  PacketTable({required this.header, required this.entries});
  final PacketTableHeader header;
  final List<int> entries;

  Uint8List encode() {
    final List<List<int>> encodedVarintEntriesChunks =
        entries.map((int entry) => encodeVarint(entry)).toList();

    int totalLength = 24;
    for (final List<int> encodedChunk in encodedVarintEntriesChunks) {
      totalLength += encodedChunk.length;
    }

    final ByteData data = ByteData(totalLength);
    data.setInt64(0, header.numberPackets);
    data.setInt64(8, header.numberValidFrames);
    data.setInt32(16, header.primingFrames);
    data.setInt32(20, header.remainderFrames);

    int offset = 24;
    for (final List<int> entry in encodedVarintEntriesChunks) {
      for (int i = 0; i < entry.length; i++) {
        data.setUint8(offset + i, entry[i]);
      }
      offset += entry.length;
    }
    return data.buffer.asUint8List();
  }

  /// Encodes an integer to `data` using variable-length encoding technique (varint) format
  List<int> encodeVarint(int value) {
    final List<int> byts = <int>[];
    int cur = value;
    while (cur != 0) {
      byts.add(cur & 127);
      cur >>= 7;
    }

    int i = byts.length - 1;
    if (i == 0) {
      return byts;
    }

    final List<int> modifiedBytes = <int>[];

    while (i >= 0) {
      int val = byts[i];
      if (i > 0) {
        val = val | 0x80;
      }
      modifiedBytes.add(val);
      i--;
    }

    return modifiedBytes;
  }
}

class ChannelLayout {
  ChannelLayout({
    required this.channelLayoutTag,
    required this.channelBitmap,
    required this.numberChannelDescriptions,
    required this.channels,
  });
  final int channelLayoutTag;
  final int channelBitmap;
  final int numberChannelDescriptions;
  final List<ChannelDescription> channels;

  Uint8List encode() {
    final int dataSize = 12 + 20 * channels.length;
    final ByteData data = ByteData(dataSize);
    data.setInt32(0, channelLayoutTag);
    data.setInt32(4, channelBitmap);
    data.setInt32(8, numberChannelDescriptions);

    int offset = 12;
    for (final ChannelDescription channel in channels) {
      final Uint8List channelData = channel.encode();
      for (int i = 0; i < 20; i++) {
        data.setUint8(offset + i, channelData[i]);
      }
      offset += 20;
    }

    return data.buffer.asUint8List();
  }
}

class AudioData {
  AudioData({required this.editCount, required this.data});
  final int editCount;
  final List<int> data;

  Uint8List encode() {
    final ByteData result = ByteData(4 + data.length);
    result.setUint32(0, editCount);
    final Uint8List uint8ListView = result.buffer.asUint8List();
    uint8ListView.setRange(4, 4 + data.length, data);

    return uint8ListView;
  }
}

class AudioFormat {
  AudioFormat({
    required this.sampleRate,
    required this.formatID,
    required this.formatFlags,
    required this.bytesPerPacket,
    required this.framesPerPacket,
    required this.channelsPerPacket,
    required this.bitsPerChannel,
  });
  final double sampleRate;
  final FourByteString formatID;
  final int formatFlags;
  final int bytesPerPacket;
  final int framesPerPacket;
  final int channelsPerPacket;
  final int bitsPerChannel;

  Uint8List encode() {
    final ByteData data = ByteData(32);
    data.setFloat64(0, sampleRate);
    data.buffer.asUint8List().setRange(8, 12, formatID.encode());
    data.setInt32(12, formatFlags);
    data.setInt32(16, bytesPerPacket);
    data.setInt32(20, framesPerPacket);
    data.setInt32(24, channelsPerPacket);
    data.setInt32(28, bitsPerChannel);
    return data.buffer.asUint8List();
  }
}

class Chunk {
  Chunk({required this.header, required this.contents});
  final ChunkHeader header;
  final dynamic contents;

  Uint8List encode() {
    // First, encode the header and temporarily store the result
    final Uint8List encodedHeader = header.encode();

    Uint8List encodedContents;

    if (header.chunkType == ChunkTypes.audioDescription) {
      final AudioFormat audioFormat = contents as AudioFormat;
      encodedContents = audioFormat.encode();
    } else if (header.chunkType == ChunkTypes.channelLayout) {
      final ChannelLayout channelLayout = contents as ChannelLayout;
      encodedContents = channelLayout.encode();
    } else if (header.chunkType == ChunkTypes.information) {
      final CAFStringsChunk cafStringsChunk = contents as CAFStringsChunk;
      encodedContents = cafStringsChunk.encode();
    } else if (header.chunkType == ChunkTypes.audioData) {
      final AudioData dataX = contents as AudioData;
      encodedContents = dataX.encode();
    } else if (header.chunkType == ChunkTypes.packetTable) {
      final PacketTable packetTable = contents as PacketTable;
      encodedContents = packetTable.encode();
    } else if (header.chunkType == ChunkTypes.midi) {
      final Midi midi = contents as Midi;
      encodedContents = midi;
    } else {
      final UnknownContents unknownContents = contents as UnknownContents;
      encodedContents = unknownContents.encode();
    }

    final int totalLength = encodedHeader.length + encodedContents.length;

    final Uint8List data = Uint8List(totalLength);

    data.setRange(0, encodedHeader.length, encodedHeader);
    data.setRange(encodedHeader.length, totalLength, encodedContents);

    return data;
  }
}

class FileHeader {
  FileHeader({
    required this.fileType,
    required this.fileVersion,
    required this.fileFlags,
  });

  FourByteString fileType;
  int fileVersion;
  int fileFlags;

  void decode(Uint8List reader) {
    final ByteData data = ByteData.sublistView(reader);
    fileType =
        FourByteString(utf8.decode(data.buffer.asUint8List().sublist(0, 4)));
    fileVersion = data.getInt16(4);
    fileFlags = data.getInt16(6);
  }

  Uint8List encode() {
    final ByteData writer = ByteData(8);
    writer.buffer.asUint8List().setRange(0, 4, fileType.encode());
    writer.setInt16(4, fileVersion);
    writer.setInt16(6, fileFlags);
    return writer.buffer.asUint8List();
  }
}
