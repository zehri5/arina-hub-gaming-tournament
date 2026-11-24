// Bass boost + EQ for the music player (playback path), Android first.
//
// Group 5 (ARENA HUB #10 AUDIO). Platform approach: Android's AudioEffect
// framework (BassBoost + Equalizer) via the shared `arena_audio/effects`
// channel — see android/.../BassEqEffect.kt (channel wiring) and
// android/.../BassEqDsp.kt (the DSP core; the external DSP handover
// replaces that file, 16-bit PCM @ 48 kHz). No custom DSP: the platform
// path delivers user-adjustable bass/EQ, so there is no reason to ship
// our own DSP. Prototype quality is acceptable for day one; correct
// wiring + tests matter more than algorithmic novelty.
//
// Contract (shared with Groups 3/4/6/8): channel `arena_audio/effects`;
// this group owns methods `setBass` and `setEq` only. There is no
// dispose method on the shared channel, so [dispose] resets the effect
// to neutral through the existing methods instead.
//
// Native note: the effects attach to audio session 0 (the global output
// mix) because audioplayers does not expose its player audio-session id
// to Dart. That makes bass/EQ apply to all app playback, including the
// music player — good enough for day one.
import 'package:flutter/services.dart';

/// Bass boost + equalizer for music playback, backed by Android's
/// AudioEffect framework (BassBoost + Equalizer).
class BassEqEffect {
  /// Creates the effect. [channel] is injectable for tests; production
  /// code uses the shared `arena_audio/effects` channel.
  BassEqEffect({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('arena_audio/effects');

  /// Maximum EQ gain in dB (Android Equalizer bands are typically ±15 dB;
  /// the native side clamps to the device's real range as well).
  static const double maxGainDb = 15.0;

  /// Minimum EQ gain in dB.
  static const double minGainDb = -15.0;

  final MethodChannel _channel;

  /// Bands touched by [setEqBand], so [dispose] can flatten them again.
  final Set<int> _touchedBands = <int>{};

  bool _disposed = false;

  /// Sets the bass-boost strength. [amount] is 0.0 (off) to 1.0 (max);
  /// out-of-range values are clamped, not rejected.
  Future<void> setBass(double amount) async {
    _checkNotDisposed();
    final double clamped = amount.clamp(0.0, 1.0).toDouble();
    await _channel.invokeMethod<void>(
      'setBass',
      <String, Object>{'amount': clamped},
    );
  }

  /// Sets the gain of EQ [band] (0-based) to [gainDb] decibels.
  /// Gain is clamped to ±15 dB; a negative [band] throws [ArgumentError].
  Future<void> setEqBand(int band, double gainDb) async {
    _checkNotDisposed();
    if (band < 0) {
      throw ArgumentError.value(band, 'band', 'Band index must be >= 0.');
    }
    final double clamped = gainDb.clamp(minGainDb, maxGainDb).toDouble();
    _touchedBands.add(band);
    await _channel.invokeMethod<void>(
      'setEq',
      <String, Object>{'band': band, 'gainDb': clamped},
    );
  }

  /// Resets bass to off and every touched EQ band to flat, then marks
  /// this instance unusable. Best-effort: a dead native side must not
  /// make dispose throw. Idempotent — a second call is a no-op.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    try {
      await _channel.invokeMethod<void>(
        'setBass',
        <String, Object>{'amount': 0.0},
      );
      for (final int band in _touchedBands) {
        await _channel.invokeMethod<void>(
          'setEq',
          <String, Object>{'band': band, 'gainDb': 0.0},
        );
      }
    } catch (_) {
      // Best-effort reset; dispose must never throw.
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('BassEqEffect used after dispose().');
    }
  }
}
