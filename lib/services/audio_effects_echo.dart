// ARENA HUB #10 AUDIO — Group 4: echo/delay for the music player
// (playback path), Android first.
//
// Android has NO built-in echo effect, so the native side is a custom
// delay-line DSP (android/.../EchoDelayEffect.kt). This file is the
// Dart half: it only validates parameters and forwards them over the
// shared effects channel.
//
// Contract (shared with Groups 3/5/6/8):
//   channel: arena_audio/effects
//   methods: setReverb / setEcho / setDelay / setBass / setEq
// This group owns setEcho + setDelay ONLY — never add another group's
// methods here. Each group owns its own Dart file + native file.
//
// NOTE: only ONE MethodChannel handler can be registered per channel
// on the native side, so the coordinator merges the groups' native
// handlers into a single dispatcher in MainActivity (each native
// effect class exposes an onMethodCall that returns false for methods
// it does not own). This Dart file needs no merging — the channel name
// and method names are the shared contract.
import 'package:flutter/services.dart';

/// Dart-side control for the native echo/delay effect.
///
/// All values are validated (and clamped) here so the native delay
/// line never sees an out-of-range parameter. [setEcho] / [setDelayMs]
/// propagate [PlatformException]s to the caller — the music player
/// decides whether an effect failure is fatal. [dispose] is
/// best-effort and never throws.
class EchoDelayEffect {
  EchoDelayEffect();

  static const MethodChannel _channel =
      MethodChannel('arena_audio/effects');

  /// Maximum delay the native delay line supports, in milliseconds.
  /// Must match `MAX_DELAY_MS` in EchoDelayEffect.kt.
  static const double maxDelayMs = 2000.0;

  /// Default delay used by the native delay line before [setDelayMs]
  /// is ever called. Must match `DEFAULT_DELAY_MS` in
  /// EchoDelayEffect.kt.
  static const double defaultDelayMs = 250.0;

  double _amount = 0.0;
  double _delayMs = defaultDelayMs;

  /// Last echo amount set via [setEcho] (0.0 = dry, 1.0 = full wet).
  double get amount => _amount;

  /// Last delay set via [setDelayMs], in milliseconds.
  double get delayMs => _delayMs;

  /// Sets the echo wet-mix amount.
  ///
  /// [amount] is clamped to 0.0–1.0 (NaN becomes 0.0). 0.0 is dry
  /// passthrough — the native side copies input to output untouched.
  Future<void> setEcho(double amount) async {
    final double clamped = _clamp01(amount);
    _amount = clamped;
    await _channel.invokeMethod<void>(
      'setEcho',
      <String, double>{'amount': clamped},
    );
  }

  /// Sets the echo delay time in milliseconds.
  ///
  /// [ms] is clamped to 0–[maxDelayMs] (NaN becomes 0.0). The native
  /// side treats 0 as a 1-sample delay so the delay line never reads
  /// stale buffer content.
  Future<void> setDelayMs(double ms) async {
    final double clamped =
        ms.isNaN ? 0.0 : ms.clamp(0.0, maxDelayMs).toDouble();
    _delayMs = clamped;
    await _channel.invokeMethod<void>(
      'setDelay',
      <String, double>{'ms': clamped},
    );
  }

  /// Silences the effect (echo amount back to 0.0). Best-effort:
  /// never throws, even if the platform side is unavailable.
  Future<void> dispose() async {
    _amount = 0.0;
    try {
      await _channel.invokeMethod<void>(
        'setEcho',
        <String, double>{'amount': 0.0},
      );
    } on Exception {
      // Dispose must never throw — the effect is already off
      // from Dart's point of view.
    }
  }

  static double _clamp01(double value) =>
      value.isNaN ? 0.0 : value.clamp(0.0, 1.0).toDouble();
}
