/// LG air conditioner IR protocol (28-bit message) for the LG K05NSA.
///
/// Message content follows IRremoteESP8266 (`ir_LG.h` / `ir_LG.cpp`):
/// https://github.com/crankyoldgit/IRremoteESP8266
///
/// The 28-bit payload is (bit 27 = MSB, transmitted MSB first):
///   bits [27..20] signature 0x88
///   bits [19..18] power     0b00 = On, 0b11 = Off
///   bits [17..15] padding   0
///   bits [14..12] mode      Cool 0 / Dry 1 / Fan 2 / Auto 3 / Heat 4
///   bits [11..8]  temperature (setTemp - 15, i.e. 16C..30C -> 1..15)
///   bits [7..4]   fan       Lowest 0 / Low 1 / Medium 2 / Max 4 / Auto 5
///   bits [3..0]   checksum  sum of nibbles [4..7][8..11][12..15][16..19] mod 16
///
/// LG ships two physical wire formats carrying this same payload:
///   * LG  - header 8500/4250 us, bit mark 550 us (remote 6711A20083V)
///   * LG2 - header 3200/9900 us, bit mark 480 us (remote AKB74395308)
/// Both are implemented; the UI lets the user pick which one their unit
/// answers to. 38 kHz carrier throughout.
library;

/// Bit-level message builder for the LG 28-bit AC payload.
class LgAcCode {
  LgAcCode._();

  static const int signature = 0x88;
  static const int minTemp = 16;
  static const int maxTemp = 30;
  static const int tempAdjust = 15;

  // Mode (3-bit field).
  static const int modeCool = 0;
  static const int modeDry = 1;
  static const int modeFan = 2;
  static const int modeAuto = 3;
  static const int modeHeat = 4;

  // Fan (4-bit field).
  static const int fanLowest = 0;
  static const int fanLow = 1;
  static const int fanMedium = 2;
  static const int fanMax = 4;
  static const int fanAuto = 5;

  // Power (2-bit field).
  static const int powerOn = 0; // 0b00
  static const int powerOff = 3; // 0b11

  /// Dedicated Off command used by the original remote instead of a state
  /// message (`kLgAcOffCommand`). It is a special single-purpose code that
  /// does not pass the normal checksum, so it is hardcoded here.
  static const int offCommand = 0x88C0051;

  /// Vertical swing toggle (`kLgAcSwingVToggle`).
  static const int swingVToggle = 0x8810001;
  static const int swingVSwing = 0x8813149; // continuous swing
  static const int lightToggle = 0x88C00A6;

  /// Builds the 28-bit payload for a power-on state.
  ///
  /// [tempC] is clamped to [minTemp]..[maxTemp]; [fan] and [mode] should be
  /// one of the constants above. The result is always < 2^28.
  static int buildMessage({
    required int mode,
    required int tempC,
    required int fan,
  }) {
    final t = tempC.clamp(minTemp, maxTemp) - tempAdjust;
    int data = 0;
    data |= (signature & 0xFF) << 20;
    data |= (powerOn & 0x3) << 18;
    data |= (mode & 0x7) << 12;
    data |= (t & 0xF) << 8;
    data |= (fan & 0xF) << 4;
    data |= checksum(data);
    return data & 0x0FFFFFFF;
  }

  /// Checksum nibble for a payload whose low nibble is still zero.
  ///
  /// Mirrors `IRLgAc::calcChecksum`: sum of the nibbles occupying bits
  /// [4..7], [8..11], [12..15], [16..19], reduced modulo 16.
  static int checksum(int state) {
    int sum = 0;
    for (int i = 1; i <= 4; i++) {
      sum += (state >> (4 * i)) & 0xF;
    }
    return sum & 0xF;
  }

  /// True when the low nibble of [state] matches [checksum] over bits [4..19].
  static bool validChecksum(int state) =>
      (state & 0xF) == checksum(state & ~0xF);
}

/// Physical wire formats for the LG 28-bit payload.
enum LgProtocol {
  /// Header 8500/4250 us, bit mark 550 us. Remote 6711A20083V / GE 6711AR2853M.
  lg(hdrMark: 8500, hdrSpace: 4250, bitMark: 550),

  /// Header 3200/9900 us, bit mark 480 us. Remote AKB74395308 (LG2).
  lg2(hdrMark: 3200, hdrSpace: 9900, bitMark: 480);

  const LgProtocol({
    required this.hdrMark,
    required this.hdrSpace,
    required this.bitMark,
  });

  final int hdrMark;
  final int hdrSpace;
  final int bitMark;

  String get label => this == LgProtocol.lg ? 'LG (8500)' : 'LG2 (3200)';
}

/// Turns a 28-bit LG code into the `ConsumerIrManager` pulse pattern.
class LgIrEncoder {
  LgIrEncoder._();

  static const int oneSpace = 1600;
  static const int zeroSpace = 550;
  static const int minGap = 39750;
  static const int repeatSpace = 2250;

  /// Encodes [code] as a single on/off pulse pattern in microseconds.
  ///
  /// The pattern starts with an "on" duration and alternates on/off, exactly
  /// as `ConsumerIrManager.transmit` expects. The trailing [minGap] closes
  /// the frame so the receiver stops looking for more bits.
  static List<int> encodeFrame(int code, LgProtocol protocol) {
    final out = <int>[];
    final bitMark = protocol.bitMark;

    // Header.
    out.add(protocol.hdrMark);
    out.add(protocol.hdrSpace);

    // 28 data bits, MSB first.
    for (int i = 27; i >= 0; i--) {
      final bit = (code >> i) & 1;
      out.add(bitMark);
      out.add(bit == 1 ? oneSpace : zeroSpace);
    }

    // Trailing mark closes the message.
    out.add(bitMark);
    out.add(minGap);
    return out;
  }

  /// Full transmission for [code]: the message frame plus the LG mandatory
  /// repeat frame (header mark, short space, one trailing mark), as the real
  /// remote sends after every command. Some units ignore commands that are
  /// not followed by this repeat.
  ///
  /// The result always has even length and ends on a gap, which is what
  /// `ConsumerIrManager.transmit` expects.
  static List<int> encode(int code, LgProtocol protocol) {
    final out = encodeFrame(code, protocol);
    out
      ..add(protocol.hdrMark)
      ..add(repeatSpace)
      ..add(protocol.bitMark)
      ..add(minGap);
    return out;
  }

  /// Convenience: format a pattern as the space-separated hex string some
  /// IR plugins accept (each value zero-padded to 4 hex digits).
  static String toHexString(List<int> pattern) =>
      pattern.map((v) => v.toRadixString(16).padLeft(4, '0')).join(' ');
}
