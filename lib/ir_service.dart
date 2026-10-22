import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin wrapper over the app's own IR method channel, with error handling and
/// a guard so we never hammer the blaster faster than the hardware (and the
/// AC) can take.
///
/// Native side lives in `MainActivity.kt`, channel `lg_ac_remote/ir`.
class IrService {
  IrService._();
  static final IrService instance = IrService._();

  static const MethodChannel _channel = MethodChannel('lg_ac_remote/ir');

  /// ConsumerIrManager's default carrier; LG remotes measure at ~38 kHz.
  static const int carrierHz = 38028;

  /// LG units ignore rapid-fire repeats, and some Xiaomi blasters drop pulses
  /// when transmits overlap, so enforce a small cooldown.
  static const Duration _cooldown = Duration(milliseconds: 300);

  DateTime _lastTransmit = DateTime.fromMillisecondsSinceEpoch(0);
  bool _hasEmitter = false;
  bool _initialized = false;

  bool get hasEmitter => _hasEmitter;

  /// Probe the hardware once. Returns true when an IR emitter is present.
  Future<bool> init() async {
    if (_initialized) return _hasEmitter;
    try {
      _hasEmitter = await _channel.invokeMethod<bool>('hasIrEmitter') ?? false;
    } on PlatformException catch (e) {
      debugPrint('IrService.init: ${e.code} ${e.message}');
      _hasEmitter = false;
    } on MissingPluginException catch (e) {
      debugPrint('IrService.init: native side missing -> $e');
      _hasEmitter = false;
    }
    _initialized = true;
    return _hasEmitter;
  }

  /// Carrier frequency ranges reported by the OS, as "min-max" lines.
  /// Returns an empty list when the device reports none.
  Future<List<String>> carrierFrequencies() async {
    try {
      final flat =
          await _channel.invokeMethod<List<Object?>>('carrierFrequencies') ??
              const <Object?>[];
      final ranges = <String>[];
      for (var i = 0; i + 1 < flat.length; i += 2) {
        ranges.add('${flat[i]}-${flat[i + 1]}');
      }
      return ranges;
    } on PlatformException catch (e) {
      debugPrint('IrService.carrierFrequencies: ${e.code} ${e.message}');
      return const [];
    }
  }

  /// Transmit a microsecond pulse pattern. Returns null on success or a
  /// short error message the UI can show.
  Future<String?> transmit(List<int> pattern) async {
    if (!_hasEmitter) return 'Perangkat ini tidak punya IR blaster.';
    if (pattern.isEmpty) return 'Pola IR kosong.';

    final sinceLast = DateTime.now().difference(_lastTransmit);
    if (sinceLast < _cooldown) {
      await Future<void>.delayed(_cooldown - sinceLast);
    }

    try {
      await _channel.invokeMethod<String>('transmit', <String, Object?>{
        'frequency': carrierHz,
        'pattern': pattern,
      });
      _lastTransmit = DateTime.now();
      return null;
    } on PlatformException catch (e) {
      debugPrint('IrService.transmit: ${e.code} ${e.message}');
      return switch (e.code) {
        'NO_IR_HARDWARE' => 'Perangkat ini tidak punya IR blaster.',
        'NO_IR_EMITTER' => 'IR blaster tidak aktif di perangkat ini.',
        'NO_PERMISSION' => 'Izin TRANSMIT_IR ditolak.',
        'BAD_PATTERN' => 'Pola IR ditolak perangkat: ${e.message}',
        _ => 'Gagal mengirim sinyal IR: ${e.message ?? e.code}',
      };
    }
  }
}