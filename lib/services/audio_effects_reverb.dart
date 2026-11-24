import 'package:flutter/services.dart';

/// GROUP 3 — reverb for the music player (playback path), Android first.
///
/// Dart side of the shared `arena_audio/effects` platform channel. The
/// native side (`android/.../ReverbEffect.kt`, wiring) drives the DSP
/// core in `android/.../ReverbDsp.kt` — currently Android's
/// `EnvironmentalReverb` on the global output mix (audio session 0),
/// because audioplayers does not expose the player's audio session ID
/// to Dart. `MODIFY_AUDIO_SETTINGS` (required for session 0) is already
/// in AndroidManifest.xml, so no manifest change is needed. The core is
/// a separate file/class on purpose: Sameer's externally written DSP
/// engine (Kotlin + C++, 16-bit PCM @ 48 kHz) drops in by implementing
/// the `ReverbDsp` interface, with no Dart or wiring changes.
///
/// Contract (shared with Groups 4/5/6/8): channel `arena_audio/effects`;
/// this group owns ONLY the `setReverb` method, sent as
/// `{'amount': <double 0.0-1.0>}`. Each effect group owns its own Dart
/// file + native file.
///
/// Wiring note for the coordinator: the merged app must register ONE
/// MethodChannel handler for `arena_audio/effects` (a second
/// `setMethodCallHandler` replaces the first) and route `setReverb` to
/// the native ReverbEffect. Do NOT call `ReverbEffect.register()` from
/// several effect classes.
class ReverbEffect {
  ReverbEffect({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('arena_audio/effects');

  final MethodChannel _channel;

  double? _lastAmount;
  bool _disposed = false;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// The last amount applied via [setAmount], or null if none yet.
  double? get lastAmount => _lastAmount;

  /// Sets the reverb wetness, 0.0 (dry — effect off) to 1.0 (full wet).
  ///
  /// Values outside 0.0–1.0 are clamped; NaN is treated as 0.0 (dry),
  /// so a bad slider value degrades to no effect instead of sending a
  /// non-finite amount over the channel. A call with the same amount as
  /// the last applied one is a no-op (no channel call). Throws
  /// [StateError] after [dispose]. A [PlatformException] from the
  /// native side (effect unavailable on this device) propagates to the
  /// caller, so UI code should treat reverb as best-effort.
  Future<void> setAmount(double value) async {
    if (_disposed) {
      throw StateError('ReverbEffect used after dispose()');
    }
    final amount = value.isNaN ? 0.0 : value.clamp(0.0, 1.0).toDouble();
    if (_lastAmount == amount) return;
    await _channel.invokeMethod<void>('setReverb', {'amount': amount});
    _lastAmount = amount;
  }

  /// Turns the effect off and marks this instance disposed. Sends
  /// `setReverb` with amount 0.0 (which releases the native effect)
  /// only if an effect may currently be active. Best-effort: native
  /// errors are swallowed — a missing effect must never crash
  /// teardown. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final hadEffect = _lastAmount != null && _lastAmount! > 0.0;
    _lastAmount = null;
    if (!hadEffect) return;
    try {
      await _channel.invokeMethod<void>('setReverb', {'amount': 0.0});
    } on Exception {
      // Best-effort cleanup: the native effect is released on its own
      // when the activity dies, and an unavailable effect must never
      // crash teardown.
      return;
    }
  }
}
