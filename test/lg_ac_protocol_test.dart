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
}
