import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lg_ac_remote/lg_ac_protocol.dart';
import 'package:lg_ac_remote/main.dart';
import 'package:lg_ac_remote/remote_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RemotePreferences', () {
    test('save and load preserves all fields', () async {
      await RemotePreferences.save(
        power: true,
        tempC: 22,
        mode: LgAcCode.modeDry,
        fan: LgAcCode.fanLow,
        protocol: LgProtocol.lg,
        energySave: false,
        dualSwing: DualSwingMode.both,
      );

      final loaded = await RemotePreferences.load();
      expect(loaded[RemotePreferences.keyPower], isTrue);
      expect(loaded[RemotePreferences.keyTemp], equals(22));
      expect(loaded[RemotePreferences.keyMode], equals(LgAcCode.modeDry));
      expect(loaded[RemotePreferences.keyFan], equals(LgAcCode.fanLow));
      expect(loaded[RemotePreferences.keyProtocol], equals('lg'));
      expect(loaded[RemotePreferences.keyEnergySave], isFalse);
      expect(loaded[RemotePreferences.keyDualSwing], equals('both'));
    });

    test('clear removes all saved values', () async {
      await RemotePreferences.save(
        power: true,
        tempC: 20,
        mode: LgAcCode.modeCool,
        fan: LgAcCode.fanMax,
        protocol: LgProtocol.lg2,
        energySave: true,
        dualSwing: DualSwingMode.left,
      );

      await RemotePreferences.clear();
      final loaded = await RemotePreferences.load();
      expect(loaded[RemotePreferences.keyPower], isNull);
      expect(loaded[RemotePreferences.keyTemp], isNull);
    });
  });

  group('AcState persistence', () {
    test('applyPreferences restores state correctly', () {
      final state = AcState();
      state.applyPreferences({
        RemotePreferences.keyPower: true,
        RemotePreferences.keyTemp: 19,
        RemotePreferences.keyMode: LgAcCode.modeHeat,
        RemotePreferences.keyFan: LgAcCode.fanMedium,
        RemotePreferences.keyProtocol: 'lg',
        RemotePreferences.keyEnergySave: false,
        RemotePreferences.keyDualSwing: 'right',
      });

      expect(state.power, isTrue);
      expect(state.tempC, equals(19));
      expect(state.mode, equals(LgAcCode.modeHeat));
      expect(state.fan, equals(LgAcCode.fanMedium));
      expect(state.protocol, equals(LgProtocol.lg));
      expect(state.energySave, isFalse);
      expect(state.dualSwing, equals(DualSwingMode.right));
    });

    test('applyPreferences safely clamps out-of-range temperatures', () {
      final stateLow = AcState();
      stateLow.applyPreferences({RemotePreferences.keyTemp: 10});
      expect(stateLow.tempC, equals(16));

      final stateHigh = AcState();
      stateHigh.applyPreferences({RemotePreferences.keyTemp: 40});
      expect(stateHigh.tempC, equals(30));
    });

    test('applyPreferences enforces energy save min temperature clamp', () {
      final state = AcState();
      state.applyPreferences({
        RemotePreferences.keyTemp: 18,
        RemotePreferences.keyEnergySave: true,
      });

      expect(state.energySave, isTrue);
      expect(state.tempC, equals(26));
    });

    test('state round-trip across new instance', () async {
      final original = AcState()
        ..power = true
        ..tempC = 27
        ..mode = LgAcCode.modeFan
        ..fan = LgAcCode.fanLowest
        ..protocol = LgProtocol.lg
        ..energySave = false
        ..dualSwing = DualSwingMode.both;

      await original.save();

      final restored = AcState();
      final loadedData = await RemotePreferences.load();
      restored.applyPreferences(loadedData);

      expect(restored.power, equals(original.power));
      expect(restored.tempC, equals(original.tempC));
      expect(restored.mode, equals(original.mode));
      expect(restored.fan, equals(original.fan));
      expect(restored.protocol, equals(original.protocol));
      expect(restored.energySave, equals(original.energySave));
      expect(restored.dualSwing, equals(original.dualSwing));
    });
  });
}
