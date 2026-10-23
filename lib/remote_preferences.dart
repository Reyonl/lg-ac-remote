import 'package:shared_preferences/shared_preferences.dart';

import 'lg_ac_protocol.dart';

/// Storage helper to persist and restore the user's last selected AC remote
/// state across app restarts.
class RemotePreferences {
  static const String keyPower = 'ac_power';
  static const String keyTemp = 'ac_temp';
  static const String keyMode = 'ac_mode';
  static const String keyFan = 'ac_fan';
  static const String keyProtocol = 'ac_protocol';
  static const String keyEnergySave = 'ac_energy_save';
  static const String keyDualSwing = 'ac_dual_swing';
  static const String keyTheme = 'ac_theme';

  /// Saves the full remote state to SharedPreferences.
  static Future<void> save({
    required bool power,
    required int tempC,
    required int mode,
    required int fan,
    required LgProtocol protocol,
    required bool energySave,
    required DualSwingMode dualSwing,
    String? theme,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final futures = <Future<bool>>[
      prefs.setBool(keyPower, power),
      prefs.setInt(keyTemp, tempC),
      prefs.setInt(keyMode, mode),
      prefs.setInt(keyFan, fan),
      prefs.setString(keyProtocol, protocol.name),
      prefs.setBool(keyEnergySave, energySave),
      prefs.setString(keyDualSwing, dualSwing.name),
    ];
    if (theme != null) {
      futures.add(prefs.setString(keyTheme, theme));
    }
    await Future.wait(futures);
  }

  /// Loads saved remote state values from SharedPreferences. Returns raw map.
  static Future<Map<String, dynamic>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      keyPower: prefs.getBool(keyPower),
      keyTemp: prefs.getInt(keyTemp),
      keyMode: prefs.getInt(keyMode),
      keyFan: prefs.getInt(keyFan),
      keyProtocol: prefs.getString(keyProtocol),
      keyEnergySave: prefs.getBool(keyEnergySave),
      keyDualSwing: prefs.getString(keyDualSwing),
      keyTheme: prefs.getString(keyTheme),
    };
  }

  /// Clears stored remote state (useful for testing or full reset).
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}
