import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models/caf_models.dart';
import 'models/ogg_models.dart';
import 'utils/logger.dart';

/// A class for converting OPUS audio data to and from OGG and CAF container formats.
class OpusCaf {
  /// Converts OPUS audio data from OGG to CAF container format and saves it to the specified output path.
  ///
  /// [inputFile] is the path to the OPUS audio file in OGG container to be converted.
  /// [outputPath] is the path where the resulting OPUS audio file in CAF container will be saved.
  Future<void> convertOggToCaf({
    required String input,
    required String output,
    bool deleteInput = false,
  }) async {
    try {
      await _convertOggToCaf(input, output, deleteInput);
    } catch (e) {
      throw Exception(e);
    }
  }

  Future<void> _convertOggToCaf(
      String inputFile, String outputPath, bool deleteInput) async {
    late final OggReader ogg;
    try {
      ogg = OggReader(inputFile);
      final OggHeader header = await ogg.readHeaders();
      final OpusData opusData =
          await ogg.readOpusData(sampleRate: header.sampleRate);

      log('frameSize: ${opusData.frameSize}');

      final CafFile cf = _buildCafFile(
        header: header,
        audioData: opusData.audioData,
        trailingData: opusData.trailingData,
        frameSize: opusData.frameSize,
      );
      final Uint8List encodedData = cf.encode();

      final File file = File(outputPath);

      if (!file.existsSync()) {
        await file.create();
      }

      // Write CAF file to output path
      await file.writeAsBytes(encodedData);

      // Close input file
      await ogg.close();

      if (deleteInput) {
        await File(inputFile).delete();
      }
    } catch (e, stackTrace) {
      log('Error converting OGG to CAF: $e');
      log(stackTrace.toString());

      // Close input file
      await ogg.close();

      throw Exception(e);
    }
  }

  /// Converts OPUS audio data from CAF to OGG container format and saves it to the specified output path.
  ///
  /// [inputFile] is the path to the OPUS audio file in CAF container to be converted.
  /// [outputPath] is the path where the resulting OPUS audio file in OGG container will be saved.
  Future<void> convertCafToOgg({
    required String input,
    required String output,
    bool deleteInput = false,
  }) async {
    try {
      await _convertCafToOgg(input, output, deleteInput);
    } catch (e) {
      throw Exception(e);
    }
  }

  Future<void> _convertCafToOgg(
      String inputFile, String outputPath, bool deleteInput) async {
    try {
      final CafReader caf = CafReader(inputFile);
      final Uint8List bytes = await File(inputFile).readAsBytes();
      final List<int> audioData = caf.readAudioData(bytes);
      final PacketTable packetTable = caf.readPacketTable(bytes);
      final AudioFormat audioFormat = caf.readAudioFormat(bytes);

      // Log lengths for debugging
      log('Audio data length: ${audioData.length}');
      log('Packet table length: ${packetTable.entries.length}');

      final OggFile ogg = buildOggFile(
        audioData: audioData,
        packetTable: packetTable.entries,
        channels: audioFormat.channelsPerPacket,
        preSkip: audioFormat.framesPerPacket,
        sampleRate: audioFormat.sampleRate.toInt(),
        //version: audioFormat.formatID.value == 'opus' ? 1 : 0,  // Example logic to set version
        version: 1,
        frameSize: audioFormat.framesPerPacket,
        repackage: false,
      );
      final List<int> encodedData = ogg.encode();

      final File file = File(outputPath);

      if (!file.existsSync()) {
        await file.create();
      }

      // Write OGG file to output path
      await file.writeAsBytes(encodedData);

      if (deleteInput) {
        await File(inputFile).delete();
      }
    } catch (e, stackTrace) {
      log('Error converting CAF to OGG: $e');
      log(stackTrace.toString());
      throw Exception(e);
    }
  }

  /// Builds an OGG file from provided data.
  OggFile buildOggFile({
    required List<int> audioData,
    required List<int> packetTable,
    required int channels,
    required int preSkip,
    required int sampleRate,
    required int version,
    required int frameSize,
    required bool repackage,
  }) {
    final OggFile oggFile = OggFile(pages: <OggPage>[]);

    int granulePosition = 0;
    int pageSequenceNumber = 0;
    final int serialNumber = DateTime.now().millisecondsSinceEpoch &
        0xFFFFFFFF; // Unique serial number
    int headerType = 0x02; // Begin of stream

    // Helper function to create a page header
    List<int> createPageHeader({
      required int granulePosition,
      required int serialNumber,
      required int pageSequenceNumber,
      required List<int> segments,
      required int headerType,
    }) {
      final List<int> header = <int>[];
      header.addAll(utf8.encode('OggS')); // Capture pattern
      header.add(0); // Stream structure version
      header.add(headerType); // Header type flag
      header.addAll(_encodeUint64(granulePosition)); // Granule position
      header.addAll(_encodeUint32(serialNumber)); // Stream serial number
      header.addAll(_encodeUint32(pageSequenceNumber)); // Page sequence number
      header.addAll(_encodeUint32(0)); // Placeholder for checksum
      header.add(segments.length); // Number of segments
      header.addAll(segments); // Segment table
      //log('PAGE HEADER: $header');
      return header;
    }

    // Helper function to calculate the checksum
    int calculateChecksum(List<int> header, List<int> body) {
      final List<int> page = header + body;
      int crc = 0;
      for (final int byte in page) {
        crc = (crc << 8) ^ _crcLookupTable[((crc >> 24) & 0xFF) ^ byte];
      }
      return crc & 0xFFFFFFFF;
    }

    // Create OPUS Head Packet
    List<int> createOpusHeadPacket() {
      final List<int> packet = <int>[];
      packet.addAll(utf8.encode('OpusHead')); // Signature
      packet.add(1); // Version
      packet.add(channels); // Channels
      packet.addAll(_encodeUint16(preSkip)); // Pre-skip
      packet.addAll(_encodeUint32(sampleRate)); // Sample rate
      packet.addAll(_encodeUint16(0)); // Output gain
      packet.add(0); // Channel mapping family
      return packet;
    }

    // Create OPUS Tags Packet
    List<int> createOpusTagsPacket() {
      final List<int> packet = <int>[];
      packet.addAll(utf8.encode('OpusTags')); // Signature
      packet.addAll(_encodeUint32(
          utf8.encode('Friend Time').length)); // Vendor string length
      packet.addAll(utf8.encode('Friend Time')); // Vendor string
      packet.addAll(_encodeUint32(0)); // User comment list length
      return packet;
    }

    // Split audio data into packets
    final List<List<int>> packets = <List<int>>[];
    int packetIndex = 0;
    for (final int packetSize in packetTable) {
      packets.add(audioData.sublist(packetIndex, packetIndex + packetSize));
      packetIndex += packetSize;
    }

    // Insert OPUS headers as the first two pages
    final List<int> opusHeadPacket = createOpusHeadPacket();
    List<int> header = createPageHeader(
      granulePosition: 0,
      serialNumber: serialNumber,
      pageSequenceNumber: pageSequenceNumber,
      segments: <int>[opusHeadPacket.length],
      headerType: 0x02,
    );
    int crc = calculateChecksum(header, opusHeadPacket);
    header.setRange(22, 26, _encodeUint32(crc)); // Insert checksum
    oggFile.pages.add(OggPage(header: header, body: opusHeadPacket));
    pageSequenceNumber++;

    final List<int> opusTagsPacket = createOpusTagsPacket();
    header = createPageHeader(
      granulePosition: 0,
      serialNumber: serialNumber,
      pageSequenceNumber: pageSequenceNumber,
      segments: <int>[opusTagsPacket.length],
      headerType: 0x00, // No continuation
    );
    crc = calculateChecksum(header, opusTagsPacket);
    header.setRange(22, 26, _encodeUint32(crc)); // Insert checksum
    oggFile.pages.add(OggPage(header: header, body: opusTagsPacket));
    pageSequenceNumber++;

    // Create pages from packets
    List<int> currentSegment = <int>[];
    List<int> currentSegmentsTable = <int>[];
    headerType = 0x01; // Continuation of packets

    for (final List<int> packet in packets) {
      final int packetSize = packet.length;
      final int segmentCount = (packetSize / 2000).ceil();
      for (int i = 0; i < segmentCount; i++) {
        final int segmentSize =
            (i == segmentCount - 1) ? packetSize % 2000 : 2000;
        if (currentSegment.length + segmentSize > 2000) {
          log('PAGE FLUSH');
          // Flush the current page
          header = createPageHeader(
            granulePosition: granulePosition,
            serialNumber: serialNumber,
            pageSequenceNumber: pageSequenceNumber,
            segments: currentSegmentsTable,
            headerType: headerType, // Continuation of packets
          );
          crc = calculateChecksum(header, currentSegment);
          header.setRange(22, 26, _encodeUint32(crc)); // Insert checksum
          oggFile.pages.add(OggPage(header: header, body: currentSegment));
          pageSequenceNumber++;
          currentSegment = <int>[];
          currentSegmentsTable = <int>[];
          headerType = 0x00; // Continuation of packets
        }
        currentSegment.addAll(packet.sublist(i * 2000, i * 2000 + segmentSize));
        currentSegmentsTable.add(segmentSize);
      }

      // Correctly increment the granule position
      if (repackage) {
        granulePosition += frameSize;
      } else {
        granulePosition += frameSize * (48000 ~/ sampleRate);
      }
    }

    // Add the remaining data as the last page
    if (currentSegment.isNotEmpty) {
      header = createPageHeader(
        granulePosition: granulePosition,
        serialNumber: serialNumber,
        pageSequenceNumber: pageSequenceNumber,
        segments: currentSegmentsTable,
        headerType: 0x04, // End of stream
      );
      crc = calculateChecksum(header, currentSegment);
      header.setRange(22, 26, _encodeUint32(crc)); // Insert checksum
      oggFile.pages.add(OggPage(header: header, body: currentSegment));
    }

    return oggFile;
  }

  List<int> _encodeUint64(int value) {
    return <int>[
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
      (value >> 32) & 0xFF,
      (value >> 40) & 0xFF,
      (value >> 48) & 0xFF,
      (value >> 56) & 0xFF,
    ];
  }

  List<int> _encodeUint32(int value) {
    return <int>[
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];
  }

  List<int> _encodeUint16(int value) {
    return <int>[
      value & 0xFF,
      (value >> 8) & 0xFF,
    ];
  }

  final List<int> _crcLookupTable = List<int>.generate(256, (int i) {
    int r = i << 24;
    for (int j = 0; j < 8; j++) {
      if (r & 0x80000000 != 0) {
        r = ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF;
      } else {
        r = (r << 1) & 0xFFFFFFFF;
      }
    }
    return r;
  });

  /// Calculates the length of the packet table based on trailing data.
  int _calculatePacketTableLength(List<int> trailingData) {
    int packetTableLength = 24;

    for (final int value in trailingData) {
      int numBytes = 0;
      if ((value & 0x7f) == value) {
        numBytes = 1;
      } else if ((value & 0x3fff) == value) {
        numBytes = 2;
      } else if ((value & 0x1fffff) == value) {
        numBytes = 3;
      } else if ((value & 0x0fffffff) == value) {
        numBytes = 4;
      } else {
        numBytes = 5;
      }
      packetTableLength += numBytes;
    }
    return packetTableLength;
  }

  /// Builds a CAF file from provided data.
  CafFile _buildCafFile({
    required OggHeader header,
    required List<int> audioData,
    required List<int> trailingData,
    required int frameSize,
  }) {
    final int lenAudio = audioData.length;
    final int packets = trailingData.length;
    final int frames = frameSize * packets;

    final int packetTableLength = _calculatePacketTableLength(trailingData);

    log('frameSize: $frameSize packetTableLength: $packetTableLength frames: $frames packets: $packets lenAudio: $lenAudio');

    final CafFile cf = CafFile(
        fileHeader: FileHeader(
            fileType: FourByteString('caff'), fileVersion: 1, fileFlags: 0),
        chunks: <Chunk>[]);

    final Chunk c = Chunk(
      header:
          ChunkHeader(chunkType: ChunkTypes.audioDescription, chunkSize: 32),
      contents: AudioFormat(
        sampleRate: header.sampleRate.toDouble(),
        formatID: FourByteString('opus'),
        formatFlags: 0x00000000,
        bytesPerPacket: 0,
        framesPerPacket: frameSize,
        channelsPerPacket: header.channels,
        bitsPerChannel: 0,
      ),
    );

    cf.chunks.add(c);

    final int channelLayoutTag = (header.channels == 2) ? 6619138 : 6553601;

    final Chunk c1 = Chunk(
      header: ChunkHeader(
        chunkType: ChunkTypes.channelLayout,
        chunkSize: 12,
      ),
      contents: ChannelLayout(
        channelLayoutTag: channelLayoutTag,
        channelBitmap: 0x0,
        numberChannelDescriptions: 0,
        channels: <ChannelDescription>[],
      ),
    );

    cf.chunks.add(c1);

    final Chunk c2 = Chunk(
      header: ChunkHeader(chunkType: ChunkTypes.information, chunkSize: 26),
      contents: CAFStringsChunk(
        numEntries: 1,
        strings: <Information>[
          Information(key: 'encoder\x00', value: 'Lavf59.27.100\x00')
        ],
      ),
    );

    cf.chunks.add(c2);

    final Chunk c3 = Chunk(
      header:
          ChunkHeader(chunkType: ChunkTypes.audioData, chunkSize: lenAudio + 4),
      contents: AudioData(editCount: 0, data: audioData),
    );

    cf.chunks.add(c3);

    final Chunk c4 = Chunk(
      header: ChunkHeader(
          chunkType: ChunkTypes.packetTable, chunkSize: packetTableLength),
      contents: PacketTable(
        header: PacketTableHeader(
          numberPackets: packets,
          numberValidFrames: frames,
          primingFrames: 0,
          remainderFrames: 0,
        ),
        entries: trailingData,
      ),
    );

    cf.chunks.add(c4);

    return cf;
  }
}

/// A class for reading CAF files.
class CafReader {
  CafReader(this.filePath);
  final String filePath;

  /// Reads the audio data from the CAF file.
  List<int> readAudioData(Uint8List bytes) {
    int offset = 0;

    // Read the CAF file header
    final String fileType = utf8.decode(bytes.sublist(offset, offset + 4));
    offset += 4;
    final int fileVersion =
        ByteData.sublistView(Uint8List.fromList(bytes), offset, offset + 2)
            .getUint16(0);
    offset += 2;
    final int fileFlags =
        ByteData.sublistView(Uint8List.fromList(bytes), offset, offset + 2)
            .getUint16(0);
    offset += 2;

    log('File type: $fileType, File version: $fileVersion, File flags: $fileFlags');

    while (offset < bytes.length) {
      // Read chunk header
      final String chunkType = utf8.decode(bytes.sublist(offset, offset + 4));
      final int chunkSize = ByteData.sublistView(
              Uint8List.fromList(bytes), offset + 4, offset + 12)
          .getUint64(0);
      offset += 12; // Move past the chunk header

      log('Chunk type: $chunkType, Chunk size: $chunkSize');

      if (chunkType == 'data') {
        // We found the audio data chunk
        final int editCount =
            ByteData.sublistView(Uint8List.fromList(bytes), offset, offset + 4)
                .getUint32(0);
        offset += 4;

        final Uint8List audioData = bytes.sublist(offset,
            offset + chunkSize - 4); // Subtract 4 bytes for the edit count
        log('Audio data chunk found at offset $offset with size $chunkSize, edit count: $editCount');
        return audioData;
      }

      // Move to the next chunk
      offset += chunkSize;
    }

    throw Exception('Audio data chunk not found');
  }

  /// Reads the packet table from the CAF file.
  PacketTable readPacketTable(Uint8List bytes) {
    int offset = 8;

    while (offset < bytes.length) {
      // Read chunk header
      final String chunkType = utf8.decode(bytes.sublist(offset, offset + 4));
      final int chunkSize = ByteData.sublistView(
              Uint8List.fromList(bytes), offset + 4, offset + 12)
          .getUint64(0);
      offset += 12; // Move past the chunk header

      if (chunkType == 'pakt') {
        // We found the packet table chunk
        final Uint8List packetTableBytes =
            bytes.sublist(offset, offset + chunkSize);

        final int numberPackets =
            ByteData.sublistView(Uint8List.fromList(packetTableBytes), 0, 8)
                .getUint64(0);
        final int numberValidFrames =
            ByteData.sublistView(Uint8List.fromList(packetTableBytes), 8, 16)
                .getUint64(0);
        final int primingFrames =
            ByteData.sublistView(Uint8List.fromList(packetTableBytes), 16, 20)
                .getUint32(0);
        final int remainderFrames =
            ByteData.sublistView(Uint8List.fromList(packetTableBytes), 20, 24)
                .getUint32(0);
        final Uint8List entries = packetTableBytes.sublist(24);

        log('Pakt numberPackets: $numberPackets numberValidFrames: $numberValidFrames primingFrames: $primingFrames remainderFrames: $remainderFrames');

        final PacketTableHeader header = PacketTableHeader(
          numberPackets: numberPackets,
          numberValidFrames: numberValidFrames,
          primingFrames: primingFrames,
          remainderFrames: remainderFrames,
        );

        log('Packet table chunk found at offset $offset with size $chunkSize');

        // Check for padding or extra bytes in the packet table
        if (entries.length != numberPackets) {
          log('Warning: Number of packets in header does not match the length of packet table entries (${entries.length} / $numberPackets)');
        }

        return PacketTable(header: header, entries: entries);
      }

      // Move to the next chunk
      offset += chunkSize;
    }

    throw Exception('Packet table chunk not found');
  }

  /// Reads the audio format from the CAF file.
  AudioFormat readAudioFormat(Uint8List bytes) {
    int offset = 8;

    while (offset < bytes.length) {
      // Read chunk header
      final String chunkType = utf8.decode(bytes.sublist(offset, offset + 4));
      final int chunkSize = ByteData.sublistView(
              Uint8List.fromList(bytes), offset + 4, offset + 12)
          .getUint64(0);
      offset += 12; // Move past the chunk header

      log('Chunk type: $chunkType, Chunk size: $chunkSize');

      if (chunkType == 'desc') {
        // We found the audio format chunk
        final Uint8List formatBytes = bytes.sublist(offset, offset + chunkSize);

        final double sampleRate =
            ByteData.sublistView(Uint8List.fromList(formatBytes), 0, 8)
                .getFloat64(0);
        final FourByteString formatID =
            FourByteString(utf8.decode(formatBytes.sublist(8, 12)));
        final int formatFlags =
            ByteData.sublistView(Uint8List.fromList(formatBytes), 12, 16)
                .getUint32(0);
        final int bytesPerPacket =
            ByteData.sublistView(Uint8List.fromList(formatBytes), 16, 20)
                .getUint32(0);
        final int framesPerPacket =
            ByteData.sublistView(Uint8List.fromList(formatBytes), 20, 24)
                .getUint32(0);
        final int channelsPerFrame =
            ByteData.sublistView(Uint8List.fromList(formatBytes), 24, 28)
                .getUint32(0);
        final int bitsPerChannel =
            ByteData.sublistView(Uint8List.fromList(formatBytes), 28, 32)
                .getUint32(0);

        log('Audio format chunk found at offset $offset with size $chunkSize');
        log('sampleRate: $sampleRate formatID: $formatID formatFlags: $formatFlags bytesPerPacket: $bytesPerPacket framesPerPacket: $framesPerPacket channelsPerFrame: $channelsPerFrame bitsPerChannel: $bitsPerChannel');

        return AudioFormat(
          sampleRate: sampleRate,
          formatID: formatID,
          formatFlags: formatFlags,
          bytesPerPacket: bytesPerPacket,
          framesPerPacket: framesPerPacket,
          channelsPerPacket: channelsPerFrame,
          bitsPerChannel: bitsPerChannel,
        );
      }

      // Move to the next chunk
      offset += chunkSize;
    }

    throw Exception('Audio format chunk not found');
  }
}

/// A class representing an OGG file.
class OggFile {
  OggFile({required this.pages});
  List<OggPage> pages;

  List<int> encode() {
    final List<int> fileData = <int>[];
    for (final OggPage page in pages) {
      fileData.addAll(page.header);
      fileData.addAll(page.body);
    }
    return fileData;
  }
}

class OggPage {
  OggPage({required this.header, required this.body});
  List<int> header;
  List<int> body;
}
