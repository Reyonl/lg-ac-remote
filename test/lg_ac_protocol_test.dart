import 'package:flutter_test/flutter_test.dart';

import 'package:lg_ac_remote/lg_ac_protocol.dart';

void main() {
  group('LgAcCode.checksum', () {
    test('agrees with the reference Off command from IRremoteESP8266', () {
      // kLgAcOffCommand = 0x88C0051, whose low nibble (1) is the checksum
      // over bits [4..19] of the surrounding payload.
      expect(LgAcCode.validChecksum(LgAcCode.offCommand), isTrue);
    });

    test('agrees with the reference Light toggle command', () {
      expect(LgAcCode.validChecksum(LgAcCode.lightToggle), isTrue);
    });

    test('agrees with the reference Swing V commands', () {
      expect(LgAcCode.validChecksum(LgAcCode.swingVToggle), isTrue);
      expect(LgAcCode.validChecksum(LgAcCode.swingVSwing), isTrue);
    });
  });

  group('LgAcCode.buildMessage', () {
    test('cool 24C auto-fan packs the documented bit fields', () {
      final code = LgAcCode.buildMessage(
        mode: LgAcCode.modeCool,
        tempC: 24,
        fan: LgAcCode.fanAuto,
      );

      expect(code, lessThan(1 << 28));
      expect((code >> 20) & 0xFF, LgAcCode.signature); // 0x88
      expect((code >> 18) & 0x3, LgAcCode.powerOn); // 0b00
      expect((code >> 12) & 0x7, LgAcCode.modeCool);
      expect((code >> 8) & 0xF, 24 - LgAcCode.tempAdjust);
      expect((code >> 4) & 0xF, LgAcCode.fanAuto);
      expect(LgAcCode.validChecksum(code), isTrue);
    });

    test('heat 30C max-fan packs the documented bit fields', () {
      final code = LgAcCode.buildMessage(
        mode: LgAcCode.modeHeat,
        tempC: 30,
        fan: LgAcCode.fanMax,
      );

      expect((code >> 12) & 0x7, LgAcCode.modeHeat);
      expect((code >> 8) & 0xF, 30 - LgAcCode.tempAdjust);
      expect((code >> 4) & 0xF, LgAcCode.fanMax);
      expect(LgAcCode.validChecksum(code), isTrue);
    });

    test('clamps temperature to the 16..30 supported range', () {
      final low = LgAcCode.buildMessage(
        mode: LgAcCode.modeCool,
        tempC: 5,
        fan: LgAcCode.fanAuto,
      );
      final high = LgAcCode.buildMessage(
        mode: LgAcCode.modeCool,
        tempC: 99,
        fan: LgAcCode.fanAuto,
      );

      expect((low >> 8) & 0xF, LgAcCode.minTemp - LgAcCode.tempAdjust);
      expect((high >> 8) & 0xF, LgAcCode.maxTemp - LgAcCode.tempAdjust);
    });

    test('is deterministic for identical inputs', () {
      int build() => LgAcCode.buildMessage(
            mode: LgAcCode.modeDry,
            tempC: 20,
            fan: LgAcCode.fanLow,
          );

      expect(build(), build());
    });
  });

  group('LgIrEncoder', () {
    final code = LgAcCode.buildMessage(
      mode: LgAcCode.modeCool,
      tempC: 24,
      fan: LgAcCode.fanAuto,
    );

    test('frame starts with the protocol header and is even length', () {
      final frame = LgIrEncoder.encodeFrame(code, LgProtocol.lg);
      expect(frame.first, LgProtocol.lg.hdrMark);
      expect(frame[1], LgProtocol.lg.hdrSpace);
      expect(frame.length.isEven, isTrue);
    });

    test('LG2 uses its own header timings', () {
      final frame = LgIrEncoder.encodeFrame(code, LgProtocol.lg2);
      expect(frame.first, LgProtocol.lg2.hdrMark);
      expect(frame[1], LgProtocol.lg2.hdrSpace);
    });

    test('encode always yields even length and ends on a gap', () {
      for (final p in LgProtocol.values) {
        final pattern = LgIrEncoder.encode(code, p);
        expect(pattern.length.isEven, isTrue, reason: '${p.name} length');
        expect(pattern.length, 64); // 2 + 56 data + 2 close + 4 repeat
      }
    });

    test('every duration is a positive microsecond count', () {
      for (final p in LgProtocol.values) {
        for (final v in LgIrEncoder.encode(code, p)) {
          expect(v, greaterThan(0));
        }
      }
    });
  });

  // --- Special commands (Energy Save / Ultra Turbo / Dual Swing) -----------
  //
  // These reproduce the reference frames used by the cross-library
  // implementations that inspired this protocol file:
  //   * IRremoteESP8266 `ir_LG.h`  (crankyoldgit)
  //   * Arduino-IRremote `ac_LG.h`  (Armin Joachimsmeyer)
  //   * ESPHome `climate_ir_lg.cpp`
  group('LgSpecial', () {
    test('reproduces the reference Energy Save frames', () {
      expect(LgSpecial.energySaveOn, 0x8810045);
      expect(LgSpecial.energySaveOff, 0x8810056);
    });

    test('reproduces the reference Ultra Turbo frame', () {
      expect(LgSpecial.turboOn, 0x8810089);
    });

    test('reproduces the reference Dual Swing frames', () {
      expect(LgSpecial.dualSwingBoth, 0x881316B); // == kLgAcSwingHAuto
      expect(LgSpecial.dualSwingLeft, 0x8813105);
      expect(LgSpecial.dualSwingRight, 0x8813116);
      expect(LgSpecial.dualSwingOff, 0x881317C); // == kLgAcSwingHOff
    });

    test('reproduces the reference Advanced Swing V frames', () {
      expect(LgSpecial.swingVOn, 0x8813149);
      expect(LgSpecial.swingVStop, 0x881315A);
    });

    test('every special frame is checksum-valid and carries the 0x88 '
        'signature', () {
      final codes = [
        LgSpecial.energySaveOn,
        LgSpecial.energySaveOff,
        LgSpecial.turboOn,
        LgSpecial.dualSwingBoth,
        LgSpecial.dualSwingLeft,
        LgSpecial.dualSwingRight,
        LgSpecial.dualSwingOff,
        LgSpecial.swingVOn,
        LgSpecial.swingVStop,
        LgSpecial.louverLeft,
        LgSpecial.louverMid,
        LgSpecial.louverRight,
      ];

      for (final c in codes) {
        expect(LgAcCode.validChecksum(c), isTrue,
            reason: '0x${c.toRadixString(16)}');
        expect((c >> 20) & 0xFF, LgAcCode.signature,
            reason: '0x${c.toRadixString(16)}');
        expect(c, lessThan(1 << 28));
      }
    });

    test('dualSwing maps every mode to a distinct code', () {
      final codes = DualSwingMode.values.map(LgSpecial.dualSwing).toList();
      expect(codes.toSet().length, DualSwingMode.values.length);
    });

    test('dualSwing(off) is the stop frame, not a swing frame', () {
      expect(LgSpecial.dualSwing(DualSwingMode.off), LgSpecial.dualSwingOff);
      expect(LgSpecial.dualSwing(DualSwingMode.both), LgSpecial.dualSwingBoth);
      expect(LgSpecial.dualSwing(DualSwingMode.left), LgSpecial.dualSwingLeft);
      expect(
          LgSpecial.dualSwing(DualSwingMode.right), LgSpecial.dualSwingRight);
    });

    test('special frames encode cleanly for both wire formats', () {
      for (final p in LgProtocol.values) {
        for (final c in [LgSpecial.turboOn, LgSpecial.dualSwingBoth]) {
          final pattern = LgIrEncoder.encode(c, p);
          expect(pattern.length.isEven, isTrue);
          expect(pattern.length, 64);
          for (final v in pattern) {
            expect(v, greaterThan(0));
          }
        }
      }
    });
  });
}