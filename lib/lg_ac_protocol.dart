/// LG air conditioner IR protocol for the LG K05NSA.
///
/// Two frame families are implemented — cross-checked against three
/// independent open-source implementations that agree to the bit:
///
///   1. IRremoteESP8266 `ir_LG.h`/`ir_LG.cpp` (crankyoldgit)
///   2. Arduino-IRremote `ac_LG.h` (Armin Joachimsmeyer)
///   3. ESPHome `climate_ir_lg.cpp`
///
/// Both carry the 0x88 signature and run on a 38 kHz carrier. The 16 bits
/// after the signature (frame bits [19..4]) are either a full A/C state or
/// a standalone special-function command — same wire format, different
/// meaning, distinguished by the header nibble in bits [19..16].
///
/// ## State frame (power / mode / temperature / fan)
///
///   bits [27..20] signature 0x88
///   bits [19..18] power     0b00 = On, 0b11 = Off (also = sys header 0xC)
///   bits [17..16] mode high bits
///   bits [14..12] mode      Cool 0 / Dry 1 / Fan 2 / Auto 3 / Heat 4
///   bits [11..8]  temperature (setTemp - 15, i.e. 16C..30C -> 1..15)
///   bits [7..4]   fan       Lowest 0 / Low 1 / Medium 2 / Max 4 / Auto 5
///   bits [3..0]   checksum  mod-16 sum of nibbles [1..4]
///
/// ## Command frame (special functions)
///
///   bits [27..20] signature 0x88
///   bits [19..16] header (command group):
///     0x1  -> Basic  (Jet/Turbo, swing toggle, Energy Save)
///     0xC  -> System (Off, Auto Clean, Quiet, Display, Light, Unit, ...)
///     0x13 -> Advanced Swing (vertical + horizontal incl. left/right)
///   bits [15..4]   command data
///   bits [3..0]    checksum (identical rule)
///
/// Build rule, identical in all three libraries:
///   frame = (0x88 << 20) | (cmd16 << 4) | checksum(frame & ~0xF)
///
/// Verified reproductions (see test/lg_ac_protocol_test.dart):
///   specialCommand(0xC00A) == 0x88C00A6  (kLgAcLightToggle)
///   specialCommand(0xC005) == 0x88C0051  (kLgAcOffCommand)
///   specialCommand(0x1000) == 0x8810001  (kLgAcSwingVToggle)
///   specialCommand(0x1314) == 0x8813149  (kLgAcSwingVSwing)
///   specialCommand(0x1315) == 0x881315A  (kLgAcSwingVOff)
///   specialCommand(0x1316) == 0x881316B  (kLgAcSwingHAuto)
///   specialCommand(0x1317) == 0x881317C  (kLgAcSwingHOff)
///
/// LG ships two physical wire formats carrying either frame:
///   * LG  - header 8500/4250 us, bit mark 550 us (6711A20083V / GE 6711AR2853M)
///   * LG2 - header 3200/9900 us, bit mark 480 us (AKB74395308)
/// Both are implemented; the UI lets the user pick which one their unit
/// answers to. 38 kHz carrier throughout.
library;

/// Bit-level message builder for the LG 28-bit AC state frame.
class LgAcCode {
  LgAcCode._();

  static const int signature = 0x88;
  static const int minTemp = 16;
  static const int maxTemp = 30;
  static const int tempAdjust = 15;

  /// Minimum setpoint enforced while Energy Save is active (K05NSA manual:
  /// "the target temperature can be set between 26 C and 30 C").
  static const int energySaveMinTemp = 26;

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
  /// message (`kLgAcOffCommand`).
  static const int offCommand = 0x88C0051;

  /// Vertical swing toggle (`kLgAcSwingVToggle`).
  static const int swingVToggle = 0x8810001;
  static const int swingVSwing = 0x8813149; // continuous vertical swing
  static const int swingVOff = 0x881315A; // stop vertical swing
  static const int lightToggle = 0x88C00A6;

  /// Builds the 28-bit payload for a power-on state message.
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
  /// Mirrors `IRLgAc::calcChecksum` / `LgIrClimate::calc_checksum_`:
  /// sum of the nibbles occupying bits [4..19], reduced modulo 16.
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

/// Builds the 28-bit LG command-frame message for a 16-bit special command,
/// mirroring Arduino-IRremote `sendIRCommand` and ESPHome `transmit_`:
///   `(0x88 << 20) | (cmd16 << 4) | checksum`
///
/// [cmd16] is header (high nibble) + data (low 12 bits), e.g. `0xC005`,
/// `0x1008`, `0x1316`. The checksum rule is the same as for state frames,
/// which is why the same constants satisfy all three libraries.
int specialCommand(int cmd16) {
  final data = (LgAcCode.signature << 20) | ((cmd16 & 0xFFFF) << 4);
  return data | LgAcCode.checksum(data);
}

/// Left-right (Dual Swing) louver position, matching the K05NSA remote's
/// Dual Swing button: "Adjusts the airflow direction both left and right,
/// left only or right only."
enum DualSwingMode {
  /// Louver fixed, no swing.
  off,

  /// Swing across the full left-right range.
  both,

  /// Swing across the left half only.
  left,

  /// Swing across the right half only.
  right,
}

/// Special-function codes for Energy Save, Ultra Turbo and Dual Swing.
///
/// Sources: Arduino-IRremote `ac_LG.h` (`LG_ENERGY_SAVING_ON/OFF`,
/// `LG_JET_ON`, `LG_SWING_ON/OFF`) and ESPHome `climate_ir_lg.cpp`
/// (`BASIC_JET`, `CommandAdvSwing::HORI_*`). The codes that appear in both
/// libraries are byte-identical, which is what makes the rest of the set
/// trustworthy:
///
///   * Turbo  `0x1008` -> 0x8810089  == ESPHome `BASIC_JET` (0x080)
///   * Swing  `0x1316` -> 0x881316B  == IRremoteESP8266 `kLgAcSwingHAuto`
///   * Stop   `0x1317` -> 0x881317C  == IRremoteESP8266 `kLgAcSwingHOff`
///
/// The horizontal left/right variants (`0x1310`/`0x1311`) come from
/// ESPHome alone but share the header of the two verified codes above.
class LgSpecial {
  LgSpecial._();

  // -- Energy Save ---------------------------------------------------------
  // Arduino-IRremote `LG_ENERGY_SAVING_ON` / `LG_ENERGY_SAVING_OFF`.
  // K05NSA manual: active in Cooling, pins the setpoint to 26..30 C.
  static final int energySaveOn = specialCommand(0x1004); // 0x8810045
  static final int energySaveOff = specialCommand(0x1005); // 0x8810056

  // -- Ultra Turbo (Jet) ---------------------------------------------------
  // Arduino-IRremote `LG_JET_ON`, ESPHome `BASIC_JET`. Per the K05NSA manual
  // the unit blows strong cool air for 30 minutes then reverts by itself,
  // so only the trigger code is sent - no state is mutated locally.
  static final int turboOn = specialCommand(0x1008); // 0x8810089

  // -- Dual Swing (left-right louver) --------------------------------------
  // ESPHome `CommandAdvSwing`, header 0x13.
  static final int dualSwingBoth = specialCommand(0x1316); // 0x881316B
  static final int dualSwingLeft = specialCommand(0x1310); // 0x8813105
  static final int dualSwingRight = specialCommand(0x1311); // 0x8813116
  static final int dualSwingOff = specialCommand(0x1317); // 0x881317C

  /// Maps a [DualSwingMode] to its IR code.
  static int dualSwing(DualSwingMode mode) => switch (mode) {
        DualSwingMode.both => dualSwingBoth,
        DualSwingMode.left => dualSwingLeft,
        DualSwingMode.right => dualSwingRight,
        DualSwingMode.off => dualSwingOff,
      };

  /// Fixed left-right louver positions (ESPHome `HORI_FIX_*`), for units
  /// that park the louver instead of swinging it.
  static final int louverLeft = specialCommand(0x130B); // 0x88130BF
  static final int louverMid = specialCommand(0x130D); // 0x88130D1
  static final int louverRight = specialCommand(0x130F); // 0x88130F3

  // -- Vertical swing (Advanced Swing header, same 0x13 group) -------------
  static final int swingVOn = specialCommand(0x1314); // 0x8813149
  static final int swingVStop = specialCommand(0x1315); // 0x881315A
}

/// Physical wire formats for the LG 28-bit frames.
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
