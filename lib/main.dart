import 'package:flutter/material.dart';

import 'ir_service.dart';
import 'lg_ac_protocol.dart';

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
          seedColor: const Color(0xFF0B5FA5),
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

  @override
  void initState() {
    super.initState();
    _probeIr();
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
    setState(() {
      _busy = true;
      _status = null;
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
    if (mounted) setState(() => _ac.power = on);
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

  // --- Special functions (Energy Save / Ultra Turbo / Dual Swing) ---------

  /// Energy Save toggle. Only Cooling supports it, and the unit clamps the
  /// setpoint to [LgAcCode.energySaveMinTemp]..max while it is active.
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
    if (mounted) setState(() => _ac.energySave = next);
    // The unit may have pushed the setpoint up on its own; resend state so
    // the app's temperature matches what the AC is actually doing.
    if (next) await _sendState();
  }

  /// Ultra Turbo / Jet. Fire-and-forget: the unit runs it for 30 minutes and
  /// then reverts to the previous settings by itself.
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

  /// Dual Swing: pick the left-right direction and send the matching code.
  Future<void> _setDualSwing(DualSwingMode mode) async {
    if (!_ac.power) {
      _showHint('Nyalakan AC dulu (tombol ON).');
      return;
    }
    await _send(LgSpecial.dualSwing(mode));
    if (mounted) setState(() => _ac.dualSwing = mode);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(scheme),
                  const SizedBox(height: 16),
                  _powerCard(scheme),
                  const SizedBox(height: 14),
                  _tempCard(scheme),
                  const SizedBox(height: 14),
                  _modeCard(scheme),
                  const SizedBox(height: 14),
                  _fanCard(scheme),
                  const SizedBox(height: 14),
                  _featuresCard(scheme),
                  const SizedBox(height: 14),
                  _protocolCard(scheme),
                  const SizedBox(height: 14),
                  _miscCard(scheme),
                  const SizedBox(height: 14),
                  _diagnosticsCard(scheme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'LG K05NSA',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          'Remote AC via IR blaster POCO F6',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
      ],
    );
  }

  Widget _card(Widget child) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF171B22),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF252B35)),
      ),
      child: child,
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _powerCard(ColorScheme scheme) {
    final on = _ac.power;
    return _card(Column(
      children: [
        _sectionTitle('Power'),
        SizedBox(
          height: 92,
          child: Row(
            children: [
              Expanded(
                child: _bigButton(
                  label: 'ON',
                  icon: Icons.power_settings_new,
                  active: on,
                  color: const Color(0xFF2ECC71),
                  onTap: _busy ? null : () => _sendPower(true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _bigButton(
                  label: 'OFF',
                  icon: Icons.power_off,
                  active: !on,
                  color: const Color(0xFFE74C3C),
                  onTap: _busy ? null : () => _sendPower(false),
                ),
              ),
            ],
          ),
        ),
      ],
    ));
  }

  Widget _bigButton({
    required String label,
    required IconData icon,
    required bool active,
    required Color color,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Material(
      color: active ? color.withValues(alpha: 0.20) : const Color(0xFF20252E),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? color : const Color(0xFF2C333F),
              width: active ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 30,
                color: enabled
                    ? (active ? color : Colors.white70)
                    : Colors.white24,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? (active ? color : Colors.white70)
                      : Colors.white24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tempCard(ColorScheme scheme) {
    final min = _ac.tempMin;
    return _card(Column(
      children: [
        _sectionTitle('Suhu'),
        Row(
          children: [
            _roundIconButton(
              icon: Icons.remove,
              onTap: _busy
                  ? null
                  : () => _change(() {
                        _ac.tempC =
                            (_ac.tempC - 1).clamp(min, LgAcCode.maxTemp);
                      }),
            ),
            Expanded(
              child: Column(
                children: [
                  Text(
                    '${_ac.tempC}',
                    style: TextStyle(
                      fontSize: 52,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                      height: 1,
                    ),
                  ),
                  Text(
                    '°C',
                    style:
                        TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
                  ),
                ],
              ),
            ),
            _roundIconButton(
              icon: Icons.add,
              onTap: _busy
                  ? null
                  : () => _change(() {
                        _ac.tempC =
                            (_ac.tempC + 1).clamp(min, LgAcCode.maxTemp);
                      }),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _ac.energySave
              ? 'Energy Save aktif: ${LgAcCode.energySaveMinTemp}°C – '
                  '${LgAcCode.maxTemp}°C'
              : '${LgAcCode.minTemp}°C – ${LgAcCode.maxTemp}°C',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
        ),
      ],
    ));
  }

  Widget _roundIconButton({required IconData icon, VoidCallback? onTap}) {
    final enabled = onTap != null;
    return SizedBox(
      width: 60,
      height: 60,
      child: Material(
        color: const Color(0xFF20252E),
        borderRadius: BorderRadius.circular(30),
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: onTap,
          child: Icon(
            icon,
            size: 30,
            color: enabled ? Colors.white : Colors.white24,
          ),
        ),
      ),
    );
  }

  /// Local state update + resync the AC with the new full-state code.
  void _change(void Function() mutate) {
    setState(mutate);
    _sendState();
  }

  /// Builds the full-state power-on code, respecting Energy Save's temp clamp.
  int _powerOnCode() => LgAcCode.buildMessage(
        mode: _ac.mode,
        tempC: _ac.tempC.clamp(_ac.tempMin, LgAcCode.maxTemp),
        fan: _ac.fan,
      );

  static const List<({int mode, String label, IconData icon})> _modes = [
    (mode: LgAcCode.modeCool, label: 'Cool', icon: Icons.ac_unit),
    (mode: LgAcCode.modeDry, label: 'Dry', icon: Icons.water_drop),
    (mode: LgAcCode.modeFan, label: 'Fan', icon: Icons.air),
    (mode: LgAcCode.modeAuto, label: 'Auto', icon: Icons.autorenew),
    (mode: LgAcCode.modeHeat, label: 'Heat', icon: Icons.local_fire_department),
  ];

  static const List<({int fan, String label})> _fans = [
    (fan: LgAcCode.fanAuto, label: 'Auto'),
    (fan: LgAcCode.fanLowest, label: '1'),
    (fan: LgAcCode.fanLow, label: '2'),
    (fan: LgAcCode.fanMedium, label: '3'),
    (fan: LgAcCode.fanMax, label: 'Max'),
  ];

  Widget _modeCard(ColorScheme scheme) {
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Mode'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _modes.map((m) {
            final active = _ac.mode == m.mode;
            return _chip(
              label: m.label,
              icon: m.icon,
              active: active,
              onTap: _busy ? null : () => _change(() => _ac.mode = m.mode),
            );
          }).toList(),
        ),
      ],
    ));
  }

  Widget _fanCard(ColorScheme scheme) {
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Kipas'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _fans.map((f) {
            final active = _ac.fan == f.fan;
            return _chip(
              label: f.label,
              active: active,
              onTap: _busy ? null : () => _change(() => _ac.fan = f.fan),
            );
          }).toList(),
        ),
      ],
    ));
  }

  Widget _chip({
    required String label,
    IconData? icon,
    required bool active,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Material(
      color: active
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.22)
          : const Color(0xFF20252E),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : const Color(0xFF2C333F),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 16,
                  color: enabled
                      ? (active ? Colors.white : Colors.white60)
                      : Colors.white24,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? (active ? Colors.white : Colors.white60)
                      : Colors.white24,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Energy Save / Ultra Turbo / Dual Swing — the special buttons that live
  /// on the real AKB74395308 remote next to the fan controls.
  Widget _featuresCard(ColorScheme scheme) {
    const dualSwingOptions = [
      (mode: DualSwingMode.off, label: 'Mati', icon: Icons.block),
      (mode: DualSwingMode.both, label: 'Kiri+Kanan', icon: Icons.swap_horiz),
      (mode: DualSwingMode.left, label: 'Kiri', icon: Icons.chevron_left),
      (mode: DualSwingMode.right, label: 'Kanan', icon: Icons.chevron_right),
    ];

    final energySaveActive = _ac.energySave;
    final canEnergySave = _ac.mode == LgAcCode.modeCool;

    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Fitur Khusus'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _chip(
              label: 'Energy Save',
              icon: Icons.eco_outlined,
              active: energySaveActive,
              onTap: _busy ? null : _toggleEnergySave,
            ),
            _chip(
              label: 'Ultra Turbo',
              icon: Icons.whatshot,
              active: false,
              onTap: _busy ? null : _triggerTurbo,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'Dual Swing (arah kipas kiri/kanan)',
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: dualSwingOptions.map((o) {
            final active = _ac.dualSwing == o.mode;
            return _chip(
              label: o.label,
              icon: o.icon,
              active: active,
              onTap: _busy ? null : () => _setDualSwing(o.mode),
            );
          }).toList(),
        ),
        const SizedBox(height: 10),
        Text(
          canEnergySave
              ? 'Energy Save mengunci suhu minimal ${LgAcCode.energySaveMinTemp}°C. '
                  'Ultra Turbo memberi hembusan maksimal ±30 menit lalu kembali '
                  'otomatis. Dual Swing mengatur arah sirip kiri/kanan.'
              : 'Energy Save hanya tersedia di mode Cool — ganti mode dulu.',
          style: TextStyle(
              color: scheme.onSurfaceVariant, fontSize: 12, height: 1.4),
        ),
      ],
    ));
  }

  Widget _protocolCard(ColorScheme scheme) {
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Protokol IR'),
        Row(
          children: LgProtocol.values.map((p) {
            final active = _ac.protocol == p;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _chip(
                  label: p.label,
                  active: active,
                  onTap: _busy ? null : () => setState(() => _ac.protocol = p),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 10),
        Text(
          'K05NSA umumnya menjawab LG2. Kalau unit tidak merespon, coba ganti '
          'ke LG. Kedua protokol membawa payload yang sama, bedanya hanya '
          'timing header.',
          style: TextStyle(
              color: scheme.onSurfaceVariant, fontSize: 12, height: 1.4),
        ),
      ],
    ));
  }

  Widget _miscCard(ColorScheme scheme) {
    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Lain-lain'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _chip(
              label: 'Swing',
              icon: Icons.swap_vert,
              active: false,
              onTap: _busy ? null : () => _send(LgAcCode.swingVToggle),
            ),
            _chip(
              label: 'Lampu',
              icon: Icons.lightbulb_outline,
              active: false,
              onTap: _busy ? null : () => _send(LgAcCode.lightToggle),
            ),
            _chip(
              label: 'Test kirim',
              icon: Icons.flash_on,
              active: false,
              onTap: _busy ? null : () => _sendState(),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Swing dan lampu memakai kode khusus dari remote asli; tidak semua '
          'unit K05NSA mendukung.',
          style: TextStyle(
              color: scheme.onSurfaceVariant, fontSize: 12, height: 1.4),
        ),
      ],
    ));
  }

  Widget _diagnosticsCard(ColorScheme scheme) {
    String emitterText;
    if (_probing) {
      emitterText = 'Memeriksa IR blaster…';
    } else if (_irReady) {
      emitterText = 'IR blaster terdeteksi ✓';
    } else {
      emitterText = 'IR blaster tidak ditemukan di perangkat ini.';
    }

    return _card(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('Status'),
        Row(
          children: [
            Icon(
              _probing
                  ? Icons.hourglass_top
                  : (_irReady ? Icons.check_circle : Icons.error),
              size: 18,
              color: _probing
                  ? Colors.amber
                  : (_irReady
                      ? const Color(0xFF2ECC71)
                      : const Color(0xFFE74C3C)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                emitterText,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ],
        ),
        if (_carrierInfo != null) ...[
          const SizedBox(height: 8),
          Text(
            'Carrier: $_carrierInfo Hz',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
        if (_status != null) ...[
          const SizedBox(height: 10),
          Text(
            _status!,
            style:
                TextStyle(color: scheme.primary, fontSize: 12.5, height: 1.4),
          ),
        ],
      ],
    ));
  }
}