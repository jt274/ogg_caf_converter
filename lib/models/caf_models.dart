import 'dart:convert';
import 'dart:typed_data';
import 'package:meta/meta.dart';

/// A class representing a four-byte string.
@immutable
class FourByteString {
  /// Creates a FourByteString from a given string.
  /// If the string length is not 4, it defaults to [0, 0, 0, 0].
  FourByteString(String string)
      : bytes = (string.length == 4) ? utf8.encode(string) : <int>[0, 0, 0, 0];

  /// The bytes representing the four-byte string.
  final List<int> bytes;

  @override
  bool operator ==(Object other) =>
      other is FourByteString && bytes.toString() == other.bytes.toString();

  @override
  int get hashCode => bytes.hashCode;

  /// Encodes the four-byte string to a Uint8List.
  Uint8List encode() {
    return Uint8List.fromList(bytes);
  }
}

/// A class containing predefined FourByteString types for different chunk types.
class ChunkTypes {
  /// Chunk type for audio description.
  static final FourByteString audioDescription = FourByteString('desc');

  /// Chunk type for channel layout.
  static final FourByteString channelLayout = FourByteString('chan');

  /// Chunk type for information.
  static final FourByteString information = FourByteString('info');

  /// Chunk type for audio data.
  static final FourByteString audioData = FourByteString('data');

  /// Chunk type for packet table.
  static final FourByteString packetTable = FourByteString('pakt');

  /// Chunk type for MIDI.
  static final FourByteString midi = FourByteString('midi');
}

/// A class representing a CAF file.
class CafFile {
  CafFile({required this.fileHeader, required this.chunks});

  /// The file header of the CAF file.
  final FileHeader fileHeader;

  /// The list of chunks in the CAF file.
  final List<Chunk> chunks;

  /// Encodes the CAF file to a Uint8List.
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

/// A class representing the header of a chunk in a CAF file.
class ChunkHeader {
  ChunkHeader({required this.chunkType, required this.chunkSize});

  /// The type of the chunk.
  final FourByteString chunkType;

  /// The size of the chunk.
  final int chunkSize;

  /// Encodes the chunk header to a Uint8List.
  Uint8List encode() {
    final ByteData data = ByteData(12);

    final Uint8List encodedChunkType = chunkType.encode();
    for (int i = 0; i < encodedChunkType.length; i++) {
      data.setUint8(i, encodedChunkType[i]);
    }

    data.setInt64(4, chunkSize);

    return data.buffer.asUint8List();
  }

  /// Decodes a chunk header from a Uint8List.
  /// Returns null if the data length is less than 12 bytes.
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

/// A class representing the description of a channel in a CAF file.
class ChannelDescription {
  ChannelDescription({
    required this.channelLabel,
    required this.channelFlags,
    required this.coordinates,
  });

  /// The label of the channel.
  final int channelLabel;

  /// The flags of the channel.
  final int channelFlags;

  /// The coordinates of the channel.
  final List<double> coordinates;

  /// Encodes the channel description to a Uint8List.
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

/// A class representing unknown contents in a CAF file.
class UnknownContents {
  UnknownContents(this.data);

  /// The data of the unknown contents.
  final Uint8List data;

  /// Encodes the unknown contents to a Uint8List.
  Uint8List encode() {
    return data;
  }
}

/// MIDI data in a CAF file.
typedef Midi = Uint8List;

/// A class representing information in a CAF file.
class Information {
  Information({required this.key, required this.value});

  /// The key of the information.
  final String key;

  /// The value of the information.
  final String value;

  /// Encodes the information to a Uint8List.
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

/// A class representing the header of a packet table in a CAF file.
class PacketTableHeader {
  PacketTableHeader({
    required this.numberPackets,
    required this.numberValidFrames,
    required this.primingFrames,
    required this.remainderFrames,
  });

  /// The number of packets in the packet table.
  final int numberPackets;

  /// The number of valid frames in the packet table.
  final int numberValidFrames;

  /// The number of priming frames in the packet table.
  final int primingFrames;

  /// The number of remainder frames in the packet table.
  final int remainderFrames;
}

/// A class representing a strings chunk in a CAF file.
class CAFStringsChunk {
  CAFStringsChunk({required this.numEntries, required this.strings});

  /// The number of entries in the strings chunk.
  final int numEntries;

  /// The list of information strings in the strings chunk.
  final List<Information> strings;

  /// Encodes the strings chunk to a Uint8List.
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

/// A class representing a packet table in a CAF file.
class PacketTable {
  PacketTable({required this.header, required this.entries});

  /// The header of the packet table.
  final PacketTableHeader header;

  /// The list of entries in the packet table.
  final Uint8List entries;

  /// Encodes the packet table to a Uint8List.
  Uint8List encode() {
    final List<Uint8List> encodedVarintEntriesChunks =
        entries.map((int entry) => encodeVarint(entry)).toList();

    int totalLength = 24;
    for (final Uint8List encodedChunk in encodedVarintEntriesChunks) {
      totalLength += encodedChunk.length;
    }

    final ByteData data = ByteData(totalLength);
    data.setInt64(0, header.numberPackets);
    data.setInt64(8, header.numberValidFrames);
    data.setInt32(16, header.primingFrames);
    data.setInt32(20, header.remainderFrames);

    int offset = 24;
    for (final Uint8List entry in encodedVarintEntriesChunks) {
      for (int i = 0; i < entry.length; i++) {
        data.setUint8(offset + i, entry[i]);
      }
      offset += entry.length;
    }
    return data.buffer.asUint8List();
  }

  /// Encodes an integer to `data` using variable-length encoding technique (varint) format.
  Uint8List encodeVarint(int value) {
    final List<int> bytes = <int>[];
    int cur = value;
    while (cur != 0) {
      bytes.add(cur & 127);
      cur >>= 7;
    }

    int i = bytes.length - 1;
    if (i == 0) {
      return Uint8List.fromList(bytes);
    }

    final List<int> modifiedBytes = <int>[];

    while (i >= 0) {
      int val = bytes[i];
      if (i > 0) {
        val = val | 0x80;
      }
      modifiedBytes.add(val);
      i--;
    }

    return Uint8List.fromList(modifiedBytes);
  }
}

/// A class representing the layout of channels in a CAF file.
class ChannelLayout {
  ChannelLayout({
    required this.channelLayoutTag,
    required this.channelBitmap,
    required this.numberChannelDescriptions,
    required this.channels,
  });

  /// The tag of the channel layout.
  final int channelLayoutTag;

  /// The bitmap of the channel layout.
  final int channelBitmap;

  /// The number of channel descriptions in the channel layout.
  final int numberChannelDescriptions;

  /// The list of channel descriptions in the channel layout.
  final List<ChannelDescription> channels;

  /// Encodes the channel layout to a Uint8List.
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

/// A class representing audio data in a CAF file.
class AudioData {
  AudioData({required this.editCount, required this.data});

  /// The edit count of the audio data.
  final int editCount;

  /// The list of audio data bytes.
  final Uint8List data;

  /// Encodes the audio data to a Uint8List.
  Uint8List encode() {
    final ByteData result = ByteData(4 + data.length);
    result.setUint32(0, editCount);
    final Uint8List uint8ListView = result.buffer.asUint8List();
    uint8ListView.setRange(4, 4 + data.length, data);

    return uint8ListView;
  }
}

/// A class representing the format of audio in a CAF file.
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

  /// The sample rate of the audio.
  final double sampleRate;

  /// The format ID of the audio.
  final FourByteString formatID;

  /// The format flags of the audio.
  final int formatFlags;

  /// The number of bytes per packet.
  final int bytesPerPacket;

  /// The number of frames per packet.
  final int framesPerPacket;

  /// The number of channels per packet.
  final int channelsPerPacket;

  /// The number of bits per channel.
  final int bitsPerChannel;

  /// Encodes the audio format to a Uint8List.
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

/// A class representing a chunk in a CAF file.
class Chunk {
  Chunk({required this.header, required this.contents});

  /// The header of the chunk.
  final ChunkHeader header;

  /// The contents of the chunk.
  final dynamic contents;

  /// Encodes the chunk to a Uint8List.
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

/// A class representing the header of a CAF file.
class FileHeader {
  FileHeader({
    required this.fileType,
    required this.fileVersion,
    required this.fileFlags,
  });

  /// The type of the file.
  FourByteString fileType;

  /// The version of the file.
  int fileVersion;

  /// The flags of the file.
  int fileFlags;

  /// Encodes the file header to a Uint8List.
  Uint8List encode() {
    final ByteData writer = ByteData(8);
    writer.buffer.asUint8List().setRange(0, 4, fileType.encode());
    writer.setInt16(4, fileVersion);
    writer.setInt16(6, fileFlags);
    return writer.buffer.asUint8List();
  }
}
