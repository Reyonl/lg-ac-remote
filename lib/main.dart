import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ir_service.dart';
import 'lg_ac_protocol.dart';
import 'remote_preferences.dart';

void main() {
  runApp(const LgAcRemoteApp());
}

class LgAcRemoteApp extends StatelessWidget {
  const LgAcRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LG K05NSA Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFC0392B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const RemoteScreen(),
    );
  }
}

/// AC state held by the screen. The LG protocol is stateless (every command
/// carries the full state), so this is all the model we need.
class AcState {
  bool power = false;
  int tempC = 24;
  int mode = LgAcCode.modeCool;
  int fan = LgAcCode.fanAuto;
  LgProtocol protocol = LgProtocol.lg2;

  /// Mirrors the Energy Save toggle on the original remote. Only valid in
  /// Cooling mode; the unit pins the setpoint to 26 C and above.
  bool energySave = false;

  /// Last Dual Swing direction the user picked. The unit reverts by itself
  /// after power cycling, so this is a UI convenience, not authoritative.
  DualSwingMode dualSwing = DualSwingMode.off;

  /// Minimum setpoint the protocol accepts right now. While Energy Save is
  /// on the K05NSA manual limits the target to 26 C and up.
  int get tempMin => energySave ? LgAcCode.energySaveMinTemp : LgAcCode.minTemp;

  /// Applies saved values from persistent preferences with safe bounds.
  void applyPreferences(Map<String, dynamic> data) {
    if (data[RemotePreferences.keyPower] is bool) {
      power = data[RemotePreferences.keyPower] as bool;
    }
    if (data[RemotePreferences.keyTemp] is int) {
      tempC = (data[RemotePreferences.keyTemp] as int).clamp(
        LgAcCode.minTemp,
        LgAcCode.maxTemp,
      );
    }
    if (data[RemotePreferences.keyMode] is int) {
      final m = data[RemotePreferences.keyMode] as int;
      if (m == LgAcCode.modeCool ||
          m == LgAcCode.modeDry ||
          m == LgAcCode.modeFan ||
          m == LgAcCode.modeAuto ||
          m == LgAcCode.modeHeat) {
        mode = m;
      }
    }
    if (data[RemotePreferences.keyFan] is int) {
      final f = data[RemotePreferences.keyFan] as int;
      if (f == LgAcCode.fanAuto ||
          f == LgAcCode.fanLowest ||
          f == LgAcCode.fanLow ||
          f == LgAcCode.fanMedium ||
          f == LgAcCode.fanMax) {
        fan = f;
      }
    }
    if (data[RemotePreferences.keyProtocol] is String) {
      final pStr = data[RemotePreferences.keyProtocol] as String;
      for (final p in LgProtocol.values) {
        if (p.name == pStr) {
          protocol = p;
          break;
        }
      }
    }
    if (data[RemotePreferences.keyEnergySave] is bool) {
      energySave = data[RemotePreferences.keyEnergySave] as bool;
      if (energySave && tempC < LgAcCode.energySaveMinTemp) {
        tempC = LgAcCode.energySaveMinTemp;
      }
    }
    if (data[RemotePreferences.keyDualSwing] is String) {
      final dsStr = data[RemotePreferences.keyDualSwing] as String;
      for (final ds in DualSwingMode.values) {
        if (ds.name == dsStr) {
          dualSwing = ds;
          break;
        }
      }
    }
  }

  /// Persists the current state to SharedPreferences.
  Future<void> save({String? theme}) => RemotePreferences.save(
        power: power,
        tempC: tempC,
        mode: mode,
        fan: fan,
        protocol: protocol,
        energySave: energySave,
        dualSwing: dualSwing,
        theme: theme,
      );
}

class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  final AcState _ac = AcState();
  final IrService _ir = IrService.instance;

  bool _irReady = false;
  bool _probing = true;
  String? _carrierInfo;
  String? _status;
  bool _busy = false;
  bool _transmitting = false;
  Timer? _transmitTimer;

  /// Visual theme of the remote control: 'classic' (authentic off-white) or 'stealth' (matte dark).
  String _remoteTheme = 'classic';
  bool _showDiagnostics = false;

  @override
  void initState() {
    super.initState();
    _loadSavedSettings();
    _probeIr();
  }

  @override
  void dispose() {
    _transmitTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSavedSettings() async {
    final data = await RemotePreferences.load();
    if (!mounted) return;
    setState(() {
      _ac.applyPreferences(data);
      if (data[RemotePreferences.keyTheme] is String) {
        _remoteTheme = data[RemotePreferences.keyTheme] as String;
      }
    });
  }

  void _saveSettings() {
    _ac.save(theme: _remoteTheme);
  }

  Future<void> _probeIr() async {
    final has = await _ir.init();
    if (!mounted) return;
    setState(() {
      _irReady = has;
      _probing = false;
    });
    if (has) {
      final ranges = await _ir.carrierFrequencies();
      if (!mounted) return;
      setState(() => _carrierInfo = ranges.isEmpty ? null : ranges.join(', '));
    }
  }

  Future<void> _send(int code) async {
    if (_busy) return;
    HapticFeedback.lightImpact();
    setState(() {
      _busy = true;
      _transmitting = true;
      _status = null;
    });

    _transmitTimer?.cancel();
    _transmitTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _transmitting = false);
    });

    final pattern = LgIrEncoder.encode(code, _ac.protocol);
    final err = await _ir.transmit(pattern);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = err ??
          'Terkirim: 0x${code.toRadixString(16).toUpperCase()} '
              '(${_ac.protocol.label}, ${pattern.length} slot)';
    });
  }

  Future<void> _sendPower(bool on) async {
    final code = on ? _powerOnCode() : LgAcCode.offCommand;
    await _send(code);
    if (mounted) {
      setState(() => _ac.power = on);
      _saveSettings();
    }
  }

  /// Send the current full state (used after temp/mode/fan change while on).
  Future<void> _sendState() async {
    if (!_ac.power) {
      _showHint('Nyalakan AC dulu (tombol ON).');
      return;
    }
    await _send(_powerOnCode());
  }

  void _showHint(String msg) {
    setState(() => _status = msg);
  }

  void _change(void Function() mutate) {
    setState(mutate);
    _saveSettings();
    _sendState();
  }

  void _changeTemp(int delta) {
    final min = _ac.tempMin;
    final next = (_ac.tempC + delta).clamp(min, LgAcCode.maxTemp);
    if (next != _ac.tempC) {
      _change(() => _ac.tempC = next);
    }
  }

  /// Cycle through modes: Cool -> Dry -> Fan -> Auto -> Heat.
  void _cycleMode() {
    const sequence = [
      LgAcCode.modeCool,
      LgAcCode.modeDry,
      LgAcCode.modeFan,
      LgAcCode.modeAuto,
      LgAcCode.modeHeat,
    ];
    final currentIndex = sequence.indexOf(_ac.mode);
    final nextIndex = (currentIndex + 1) % sequence.length;
    _change(() => _ac.mode = sequence[nextIndex]);
  }

  /// Cycle through fan speeds: Auto -> 1 -> 2 -> 3 -> Max.
  void _cycleFan() {
    const sequence = [
      LgAcCode.fanAuto,
      LgAcCode.fanLowest,
      LgAcCode.fanLow,
      LgAcCode.fanMedium,
      LgAcCode.fanMax,
    ];
    final currentIndex = sequence.indexOf(_ac.fan);
    final nextIndex = (currentIndex + 1) % sequence.length;
    _change(() => _ac.fan = sequence[nextIndex]);
  }

  /// Cycle through Dual Swing modes: Off -> Both -> Left -> Right.
  Future<void> _cycleDualSwing() async {
    const sequence = [
      DualSwingMode.off,
      DualSwingMode.both,
      DualSwingMode.left,
      DualSwingMode.right,
    ];
    final currentIndex = sequence.indexOf(_ac.dualSwing);
    final nextIndex = (currentIndex + 1) % sequence.length;
    await _setDualSwing(sequence[nextIndex]);
  }

  // --- Special functions (Energy Save / Ultra Turbo / Dual Swing) ---------

  Future<void> _toggleEnergySave() async {
    if (!_ac.power) {
      _showHint('Nyalakan AC dulu (tombol ON).');
      return;
    }
    if (_ac.mode != LgAcCode.modeCool) {
      _showHint('Energy Save hanya aktif di mode Cool.');
      return;
    }
    final next = !_ac.energySave;
    if (next && _ac.tempC < LgAcCode.energySaveMinTemp) {
      setState(() => _ac.tempC = LgAcCode.energySaveMinTemp);
    }
    await _send(next ? LgSpecial.energySaveOn : LgSpecial.energySaveOff);
    if (mounted) {
      setState(() => _ac.energySave = next);
      _saveSettings();
    }
    if (next) await _sendState();
  }

  Future<void> _triggerTurbo() async {
    if (!_ac.power) {
      _showHint('Nyalakan AC dulu (tombol ON).');
      return;
    }
    await _send(LgSpecial.turboOn);
    if (mounted) {
      _showHint('Ultra Turbo aktif ±30 menit, lalu AC kembali ke setelan '
          'semula otomatis.');
    }
  }

  Future<void> _setDualSwing(DualSwingMode mode) async {
    if (!_ac.power) {
      _showHint('Nyalakan AC dulu (tombol ON).');
      return;
    }
    await _send(LgSpecial.dualSwing(mode));
    if (mounted) {
      setState(() => _ac.dualSwing = mode);
      _saveSettings();
    }
  }

  Future<void> _toggleProtocol() async {
    final next = _ac.protocol == LgProtocol.lg2 ? LgProtocol.lg : LgProtocol.lg2;
    setState(() => _ac.protocol = next);
    _saveSettings();
    _showHint('Protokol diubah ke ${next.label}.');
  }

  int _powerOnCode() => LgAcCode.buildMessage(
        mode: _ac.mode,
        tempC: _ac.tempC.clamp(_ac.tempMin, LgAcCode.maxTemp),
        fan: _ac.fan,
      );

  @override
  Widget build(BuildContext context) {
    final isClassic = _remoteTheme == 'classic';

    // Theme color palettes.
    final deskBg = isClassic ? const Color(0xFF1E242B) : const Color(0xFF0C0E12);
    final chassisBg1 = isClassic ? const Color(0xFFF7F9FB) : const Color(0xFF222731);
    final chassisBg2 = isClassic ? const Color(0xFFE2E6EC) : const Color(0xFF171A21);
    final chassisBorder = isClassic ? const Color(0xFFCCD3DD) : const Color(0xFF2F3644);
    final buttonBase = isClassic ? const Color(0xFFE9EDF2) : const Color(0xFF272D39);
    final buttonBorder = isClassic ? const Color(0xFFD0D7E1) : const Color(0xFF384152);
    final buttonText = isClassic ? const Color(0xFF2D3748) : const Color(0xFFE2E8F0);

    return Scaffold(
      backgroundColor: deskBg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _topBar(),
                const SizedBox(height: 10),
                _physicalRemoteHandset(
                  isClassic: isClassic,
                  chassisBg1: chassisBg1,
                  chassisBg2: chassisBg2,
                  chassisBorder: chassisBorder,
                  buttonBase: buttonBase,
                  buttonBorder: buttonBorder,
                  buttonText: buttonText,
                ),
                const SizedBox(height: 14),
                _diagnosticsDrawer(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final isClassic = _remoteTheme == 'classic';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton.filledTonal(
          tooltip: isClassic ? 'Ganti ke Stealth Dark Remote' : 'Ganti ke Classic White Remote',
          onPressed: () {
            setState(() {
              _remoteTheme = isClassic ? 'stealth' : 'classic';
            });
            _saveSettings();
          },
          icon: Icon(
            isClassic ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
            size: 20,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          isClassic ? 'Classic White Remote' : 'Stealth Dark Remote',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  /// The entire realistic physical remote control casing.
  Widget _physicalRemoteHandset({
    required bool isClassic,
    required Color chassisBg1,
    required Color chassisBg2,
    required Color chassisBorder,
    required Color buttonBase,
    required Color buttonBorder,
    required Color buttonText,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(38),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [chassisBg1, chassisBg2],
          ),
          border: Border.all(color: chassisBorder, width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.65),
              blurRadius: 32,
              offset: const Offset(0, 16),
            ),
            BoxShadow(
              color: isClassic
                  ? Colors.white.withValues(alpha: 0.8)
                  : Colors.white.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            // Top IR Blaster Emitter Notch.
            _irEmitterDome(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  const SizedBox(height: 6),
                  // Realistic Backlit LCD Screen.
                  _lcdScreen(isClassic),
                  const SizedBox(height: 18),
                  // Keypad Buttons.
                  _keypad(
                    isClassic: isClassic,
                    buttonBase: buttonBase,
                    buttonBorder: buttonBorder,
                    buttonText: buttonText,
                  ),
                  const SizedBox(height: 20),
                  // LG Logo & Model Stamp.
                  _remoteBranding(isClassic),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The physical infrared emitter LED notch at the top tip of the remote casing.
  Widget _irEmitterDome() {
    return Container(
      width: 72,
      height: 14,
      decoration: BoxDecoration(
        color: _transmitting ? const Color(0xFFFF2222) : const Color(0xFF240A0D),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
        boxShadow: _transmitting
            ? [
                BoxShadow(
                  color: const Color(0xFFFF2222).withValues(alpha: 0.9),
                  blurRadius: 18,
                  spreadRadius: 4,
                ),
                BoxShadow(
                  color: Colors.amber.withValues(alpha: 0.8),
                  blurRadius: 8,
                ),
              ]
            : [
                const BoxShadow(
                  color: Colors.black45,
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
      ),
      child: Center(
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _transmitting ? Colors.white : const Color(0xFF63151D),
          ),
        ),
      ),
    );
  }

  /// Realistic backlit segmented LCD screen.
  Widget _lcdScreen(bool isClassic) {
    // LCD colors (emerald liquid crystal on dark glass).
    const lcdGlass = Color(0xFF10201C);
    const lcdBorder = Color(0xFF081210);
    const lcdGlow = Color(0xFF45F0B5);
    const lcdDim = Color(0xFF1D3E35);

    final modeLabel = _modeName(_ac.mode);
    final fanLabel = _fanName(_ac.fan);
    final dualSwingLabel = _dualSwingName(_ac.dualSwing);

    return Container(
      decoration: BoxDecoration(
        color: lcdGlass,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: lcdBorder, width: 3),
        boxShadow: [
          const BoxShadow(
            color: Colors.black54,
            blurRadius: 6,
            offset: Offset(0, 2),
            spreadRadius: -1,
          ),
          BoxShadow(
            color: lcdGlow.withValues(alpha: 0.08),
            blurRadius: 14,
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Column(
        children: [
          // Top line: Protocol badge, Signal transmit wave, Power state.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: lcdDim,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _ac.protocol.label,
                    style: const TextStyle(
                      color: lcdGlow,
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.sensors,
                      size: 15,
                      color: _transmitting ? Colors.amberAccent : lcdDim,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _transmitting ? 'TRANSMIT' : 'IR READY',
                      style: TextStyle(
                        color: _transmitting ? Colors.amberAccent : lcdDim,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _ac.power ? const Color(0xFF104F34) : const Color(0xFF4A181A),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _ac.power ? 'ON' : 'OFF',
                    style: TextStyle(
                      color: _ac.power ? const Color(0xFF38E588) : const Color(0xFFFF6B6B),
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Main Center: Massive Digital Temperature Display.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_ac.tempC}',
                style: const TextStyle(
                  color: lcdGlow,
                  fontSize: 62,
                  height: 1.0,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -2,
                  fontFamily: 'monospace',
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8, left: 4),
                child: Text(
                  '°C',
                  style: TextStyle(
                    color: lcdGlow,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),

          if (_ac.energySave) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF0A3C2A),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFF1BE48D), width: 0.8),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.eco, size: 12, color: Color(0xFF1BE48D)),
                  SizedBox(width: 4),
                  Text(
                    'ENERGY SAVE (≥26°C)',
                    style: TextStyle(
                      color: Color(0xFF1BE48D),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),

          // Bottom LCD Bar: Mode, Fan speed meter, Swing status.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(8),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Mode.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_modeIcon(_ac.mode), size: 14, color: lcdGlow),
                      const SizedBox(width: 4),
                      Text(
                        modeLabel.toUpperCase(),
                        style: const TextStyle(
                          color: lcdGlow,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  // Fan Level meter.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.air, size: 13, color: lcdGlow),
                      const SizedBox(width: 4),
                      _fanMeterGraphic(_ac.fan, lcdGlow, lcdDim),
                      const SizedBox(width: 4),
                      Text(
                        fanLabel.toUpperCase(),
                        style: const TextStyle(
                          color: lcdGlow,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  // Swing.
                  Text(
                    '↔ $dualSwingLabel',
                    style: const TextStyle(
                      color: lcdGlow,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fanMeterGraphic(int fan, Color activeColor, Color inactiveColor) {
    int level;
    switch (fan) {
      case LgAcCode.fanLowest:
        level = 1;
        break;
      case LgAcCode.fanLow:
        level = 2;
        break;
      case LgAcCode.fanMedium:
        level = 3;
        break;
      case LgAcCode.fanMax:
        level = 4;
        break;
      case LgAcCode.fanAuto:
      default:
        level = 2;
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (index) {
        final active = index < level;
        return Container(
          width: 3.5,
          height: 4.0 + (index * 3.0),
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: active ? activeColor : inactiveColor,
            borderRadius: BorderRadius.circular(1),
          ),
        );
      }),
    );
  }

  /// Tactile rubber keypad layout modeled after the physical LG remote.
  Widget _keypad({
    required bool isClassic,
    required Color buttonBase,
    required Color buttonBorder,
    required Color buttonText,
  }) {
    return Column(
      children: [
        // Row 1: Power ON, Power OFF, and Jet Mode.
        Row(
          children: [
            // Prominent Red Power ON button.
            Expanded(
              flex: 3,
              child: _tactileButton(
                label: 'ON',
                sublabel: 'POWER',
                icon: Icons.power_settings_new,
                bgColor: const Color(0xFFE53935),
                textColor: Colors.white,
                borderColor: const Color(0xFFC62828),
                height: 60,
                onTap: _busy ? null : () => _sendPower(true),
              ),
            ),
            const SizedBox(width: 8),
            // Power OFF button.
            Expanded(
              flex: 3,
              child: _tactileButton(
                label: 'OFF',
                sublabel: 'STOP',
                icon: Icons.power_off,
                bgColor: isClassic ? const Color(0xFF5A626F) : const Color(0xFF373E4A),
                textColor: Colors.white,
                borderColor: isClassic ? const Color(0xFF454B55) : const Color(0xFF2B313B),
                height: 60,
                onTap: _busy ? null : () => _sendPower(false),
              ),
            ),
            const SizedBox(width: 8),
            // Jet Mode / Turbo.
            Expanded(
              flex: 4,
              child: _tactileButton(
                label: 'JET COOL',
                sublabel: 'TURBO',
                icon: Icons.whatshot,
                bgColor: const Color(0xFFF39C12),
                textColor: const Color(0xFF1A1A1A),
                borderColor: const Color(0xFFD68910),
                height: 60,
                onTap: _busy ? null : _triggerTurbo,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Row 2: Large Temperature Rocker & Quick Energy Save.
        Row(
          children: [
            // Vertical Temperature Rocker.
            Expanded(
              flex: 5,
              child: _tempRocker(isClassic, buttonBase, buttonBorder, buttonText),
            ),
            const SizedBox(width: 12),
            // Core Function Column: Energy Save + Mode Cycle.
            Expanded(
              flex: 5,
              child: Column(
                children: [
                  _tactileButton(
                    label: 'ENERGY SAVE',
                    sublabel: 'ECO 26°C+',
                    icon: Icons.eco,
                    bgColor: _ac.energySave ? const Color(0xFF27AE60) : buttonBase,
                    textColor: _ac.energySave ? Colors.white : buttonText,
                    borderColor: _ac.energySave ? const Color(0xFF1E8449) : buttonBorder,
                    height: 52,
                    onTap: _busy ? null : _toggleEnergySave,
                  ),
                  const SizedBox(height: 8),
                  _tactileButton(
                    label: 'MODE',
                    sublabel: _modeName(_ac.mode),
                    icon: _modeIcon(_ac.mode),
                    bgColor: buttonBase,
                    textColor: buttonText,
                    borderColor: buttonBorder,
                    height: 52,
                    onTap: _busy ? null : _cycleMode,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Row 3: Fan Speed & Swing Controls.
        Row(
          children: [
            Expanded(
              child: _tactileButton(
                label: 'FAN SPEED',
                sublabel: _fanName(_ac.fan),
                icon: Icons.air,
                bgColor: buttonBase,
                textColor: buttonText,
                borderColor: buttonBorder,
                height: 54,
                onTap: _busy ? null : _cycleFan,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _tactileButton(
                label: 'V-SWING',
                sublabel: 'VERT',
                icon: Icons.swap_vert,
                bgColor: buttonBase,
                textColor: buttonText,
                borderColor: buttonBorder,
                height: 54,
                onTap: _busy ? null : () => _send(LgAcCode.swingVToggle),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _tactileButton(
                label: 'DUAL SWING',
                sublabel: _dualSwingName(_ac.dualSwing),
                icon: Icons.swap_horiz,
                bgColor: buttonBase,
                textColor: buttonText,
                borderColor: buttonBorder,
                height: 54,
                onTap: _busy ? null : _cycleDualSwing,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Row 4: Auxiliary System Controls (Light, Protocol, Test).
        Row(
          children: [
            Expanded(
              child: _tactileButton(
                label: 'LIGHT',
                sublabel: 'LED AC',
                icon: Icons.lightbulb_outline,
                bgColor: buttonBase,
                textColor: buttonText,
                borderColor: buttonBorder,
                height: 52,
                onTap: _busy ? null : () => _send(LgAcCode.lightToggle),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _tactileButton(
                label: 'PROTOCOL',
                sublabel: _ac.protocol.label,
                icon: Icons.tune,
                bgColor: buttonBase,
                textColor: buttonText,
                borderColor: buttonBorder,
                height: 52,
                onTap: _busy ? null : _toggleProtocol,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _tactileButton(
                label: 'TEST IR',
                sublabel: 'SEND',
                icon: Icons.flash_on,
                bgColor: buttonBase,
                textColor: buttonText,
                borderColor: buttonBorder,
                height: 52,
                onTap: _busy ? null : () => _sendState(),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Big vertical dual rocker for Temperature Up & Down.
  Widget _tempRocker(
    bool isClassic,
    Color buttonBase,
    Color buttonBorder,
    Color buttonText,
  ) {
    return Container(
      height: 112,
      decoration: BoxDecoration(
        color: buttonBase,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: buttonBorder, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isClassic ? 0.15 : 0.4),
            blurRadius: 6,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // TEMP UP
          Expanded(
            child: InkWell(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
              onTap: _busy ? null : () => _changeTemp(1),
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.arrow_drop_up, size: 28, color: buttonText),
                    Text(
                      'TEMP',
                      style: TextStyle(
                        color: buttonText,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Ribbed Separator Line.
          Container(
            height: 2,
            margin: const EdgeInsets.symmetric(horizontal: 14),
            color: buttonBorder,
          ),
          // TEMP DOWN
          Expanded(
            child: InkWell(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
              onTap: _busy ? null : () => _changeTemp(-1),
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.arrow_drop_down, size: 28, color: buttonText),
                    Text(
                      'TEMP',
                      style: TextStyle(
                        color: buttonText,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Authentic 3D rubber tactile push-button with physical bevel.
  Widget _tactileButton({
    required String label,
    required String sublabel,
    required IconData icon,
    required Color bgColor,
    required Color textColor,
    required Color borderColor,
    required double height,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled
            ? () {
                HapticFeedback.lightImpact();
                onTap();
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: enabled ? bgColor : bgColor.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: 1.6),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 4,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 17,
                    color: enabled ? textColor : textColor.withValues(alpha: 0.35),
                  ),
                  const SizedBox(height: 1.5),
                  Text(
                    label,
                    style: TextStyle(
                      color: enabled ? textColor : textColor.withValues(alpha: 0.35),
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                      height: 1.0,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (sublabel.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(
                      sublabel,
                      style: TextStyle(
                        color: enabled
                            ? textColor.withValues(alpha: 0.75)
                            : textColor.withValues(alpha: 0.25),
                        fontSize: 8.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                        height: 1.0,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Debossed LG Logo branding stamp at bottom of remote.
  Widget _remoteBranding(bool isClassic) {
    final brandColor = isClassic ? const Color(0xFF7A8494) : const Color(0xFF6B7586);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: brandColor, width: 1.5),
              ),
              alignment: Alignment.center,
              child: Text(
                'L',
                style: TextStyle(
                  color: brandColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'LG K05NSA',
              style: TextStyle(
                color: brandColor,
                fontSize: 12.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 2.0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          'AKB74395308 INFRARED',
          style: TextStyle(
            color: brandColor.withValues(alpha: 0.7),
            fontSize: 9,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }

  /// Expandable bottom tray for hardware sensor info & transmission log.
  Widget _diagnosticsDrawer() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        children: [
          TextButton.icon(
            onPressed: () {
              setState(() => _showDiagnostics = !_showDiagnostics);
            },
            icon: Icon(
              _showDiagnostics ? Icons.expand_less : Icons.info_outline,
              size: 16,
              color: Colors.white60,
            ),
            label: Text(
              _showDiagnostics ? 'Sembunyikan Info IR' : 'Info IR Blaster & Status Log',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          if (_showDiagnostics)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF28303D)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _probing
                            ? Icons.hourglass_top
                            : (_irReady ? Icons.check_circle : Icons.error),
                        size: 16,
                        color: _probing
                            ? Colors.amber
                            : (_irReady ? const Color(0xFF2ECC71) : const Color(0xFFE74C3C)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _probing
                              ? 'Memeriksa IR blaster…'
                              : (_irReady
                                  ? 'IR blaster POCO F6 aktif ✓'
                                  : 'IR blaster tidak ditemukan di perangkat ini.'),
                          style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                  if (_carrierInfo != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Carrier: $_carrierInfo Hz',
                      style: const TextStyle(color: Colors.white54, fontSize: 11.5),
                    ),
                  ],
                  if (_status != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _status!,
                        style: const TextStyle(
                          color: Color(0xFF58A6FF),
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  // --- Helper text/icon mappers ---

  String _modeName(int mode) {
    switch (mode) {
      case LgAcCode.modeCool:
        return 'Cool';
      case LgAcCode.modeDry:
        return 'Dry';
      case LgAcCode.modeFan:
        return 'Fan';
      case LgAcCode.modeAuto:
        return 'Auto';
      case LgAcCode.modeHeat:
        return 'Heat';
      default:
        return 'Cool';
    }
  }

  IconData _modeIcon(int mode) {
    switch (mode) {
      case LgAcCode.modeCool:
        return Icons.ac_unit;
      case LgAcCode.modeDry:
        return Icons.water_drop;
      case LgAcCode.modeFan:
        return Icons.air;
      case LgAcCode.modeAuto:
        return Icons.autorenew;
      case LgAcCode.modeHeat:
        return Icons.local_fire_department;
      default:
        return Icons.ac_unit;
    }
  }

  String _fanName(int fan) {
    switch (fan) {
      case LgAcCode.fanAuto:
        return 'Auto';
      case LgAcCode.fanLowest:
        return '1';
      case LgAcCode.fanLow:
        return '2';
      case LgAcCode.fanMedium:
        return '3';
      case LgAcCode.fanMax:
        return 'Max';
      default:
        return 'Auto';
    }
  }

  String _dualSwingName(DualSwingMode mode) {
    switch (mode) {
      case DualSwingMode.off:
        return 'Mati';
      case DualSwingMode.both:
        return 'Kiri+Kanan';
      case DualSwingMode.left:
        return 'Kiri';
      case DualSwingMode.right:
        return 'Kanan';
    }
  }
}
