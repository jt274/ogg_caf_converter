# 0.2.0

## [0.2.0] - 2026-10-07

### Breaking Changes
- **API**: `PacketTable.entries` is now `List<int>` (was `Uint8List`)
- **API**: `OpusData` gained required field `packetSampleCounts: List<int>`
- **API**: `OggReader.readOpusData()` signature changed (removed `sampleRate` parameter)

### Added
- Support for variable-duration Opus packets in CAF packet tables
- Per-packet frame count tracking in `PacketTable.frameEntries`
- `OpusData.packetSampleCounts` to expose individual packet sample counts
- Intelligent CAF packet-table decoding based on `AudioFormat` flags
- Comprehensive test coverage for variable-duration streams, roundtrip conversions, and trim metadata

### Fixed
- CAF↔OGG trim metadata handling: `primingFrames` now correctly maps to Ogg `preSkip`
- CAF `remainderFrames` now applied as end trim in final Ogg granule position
- Ogg granule position computation from actual Opus packet durations (not assumed constant frame sizes)
- Ogg CRC generation (32-bit overflow in checksum calculation)
- Ogg continuation-page flags for pages starting mid-packet
- CAF packet-table varint decoding
- Corrected FourByteString handling of UTF-8 values that exceed four bytes and made its hash code consistent with value equality.
- Fixed a malformed-CAF test to exercise CAF-to-OGG conversion.
- Isolated conversion tests in temporary directories to avoid shared-file conflicts, and made external-tool discovery work on Windows.
- Strengthened OGG tests to verify header and packet values, reject incomplete page data, and reliably close readers.

### Changed
- `PacketTable.entries` type changed from `Uint8List` to `List<int>` for consistency
- `OpusData` constructor now requires `packetSampleCounts` parameter
- `OggReader.readOpusData()` no longer requires `sampleRate` parameter (Opus is always 48 kHz)
- `CafReader.readPacketTable()` now optionally accepts `AudioFormat` for intelligent entry decoding

### Credits
- Variable-duration packet support and CAF metadata fixes by @skylartaylor

# 0.1.4

* Release date: Jan 10, 2025
* Added `convertCafToOggInMemory` and `convertOggToCafInMemory` methods to return converted file bytes in memory without creating a new file.
* Fixed CAF test resource file.
* Increased conversion efficiency.
* Rewrote OGG file encoding.
* Documentation update.
* Restructured and added tests.

# 0.1.3

* Release date: Jan 8, 2025
* Relax `meta` version constraint.

# 0.1.2

* Release date: Jan 7, 2025
* Remove `path` as direct dependency.
* Relax dart SDK version constraint.

# 0.1.1

* Release date: Jan 7, 2025
* Update example and documentation.

# 0.1.0

* Release date: Jan 7, 2025
* Initial development release.
* Supports Android and iOS platforms.
