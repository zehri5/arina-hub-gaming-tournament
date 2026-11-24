import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// GROUP 8 — music-playback DSP effects aggregator (ARENA HUB #10 AUDIO).
///
/// Applies the effect groups' DSP to MUSIC PLAYBACK (the host's music,
/// played through audioplayers in the room screen). This class owns no
/// DSP of its own: it calls the effect groups' Dart APIs and exposes
/// one preset/enable surface to the room screen.
///
/// ## Effect wiring (merge wiring for the coordinator)
///
/// Groups 3/4/5 run in parallel and their files are NOT in this copy,
/// so their APIs are injected as tear-offs — the aggregator calls
/// exactly the contracted methods, and the merge wiring is one line
/// per effect:
///
/// ```dart
/// final reverb = ReverbEffect(); // Group 3, audio_effects_reverb.dart
/// final echo = EchoDelayEffect(); // Group 4, audio_effects_echo.dart
/// final bass = BassEqEffect(); // Group 5, audio_effects_bass.dart
/// final playback = PlaybackEffects(
///   setReverbAmount: reverb.setAmount,
///   setEchoAmount: echo.setEcho,
///   setEchoDelayMs: echo.setDelayMs,
///   setBassAmount: bass.setBass,
///   setEqBand: bass.setEqBand,
///   disposeEffects: () async {
///     await reverb.dispose();
///     await echo.dispose();
///     await bass.dispose();
///   },
/// );
/// await playback.attachToPlayer(musicPlayer);
/// await playback.applyPreset('Room');
/// ```
///
/// Contracted signatures (verified against the groups' files):
/// * Group 3 `ReverbEffect.setAmount(double value)` — 0.0 dry .. 1.0 wet.
/// * Group 4 `EchoDelayEffect.setEcho(double amount)` and
///   `setDelayMs(double ms)` — note: delay is a **double** in ms.
/// * Group 5 `BassEqEffect.setBass(double amount)` and
///   `setEqBand(int band, double gainDb)` — band 0 is the lowest band.
///
/// ## Audio-session routing (the key finding)
///
/// Android `AudioEffect`s attach to an audio session ID, but
/// **audioplayers 6.8.1 exposes no session ID anywhere**: there is no
/// `audioSessionId` in the Dart package, in
/// `audioplayers_platform_interface`, or in `audioplayers_android`
/// 5.3.0 — the `MediaPlayer` is private inside `MediaPlayerWrapper`
/// and the players map is private inside `AudioplayersPlugin`. So
/// per-player attachment is impossible without forking audioplayers.
///
/// The routing actually used (shared by Groups 3/4/5 and this bridge)
/// is **audio session 0 — the global output mix**: the native effects
/// attach to session 0, which colours all device audio output while
/// enabled (including the music player — and, while enabled, other
/// audio too). `MODIFY_AUDIO_SETTINGS`, required for session 0, is
/// already in AndroidManifest.xml. The native half of this bridge
/// (`android/.../PlaybackEffectsBridge.kt`) owns the `attachPlayback` /
/// `detachPlayback` / `getSessionInfo` methods on the shared
/// `arena_audio/effects` channel and documents the routing in full;
/// [sessionInfo] exposes what it reports.
///
/// ## Presets
///
/// * `Off` — everything flat/dry (reverb 0, echo 0, bass 0, EQ band 0
///   at 0 dB, delay back to the 250 ms default).
/// * `Room` — small-room colour (reverb 0.35, echo 0.15, 180 ms
///   delay, bass 0.30, EQ band 0 +3 dB).
/// * `Hall` — large-hall colour (reverb 0.70, echo 0.25, 350 ms
///   delay, bass 0.40, EQ band 0 +4.5 dB).
///
/// Preset values are day-one choices, not tuned measurements.
///
/// ## Failure behaviour
///
/// Effect calls are best-effort at the UI layer, like the groups'
/// own APIs: [applyPreset] / [setEnabled] run every setter even if
/// one fails, then rethrow the first error. [attachToPlayer] never
/// throws for a missing/unreachable native bridge — check
/// [bridgeAvailable] / [sessionInfo] instead. [dispose] never throws.
class PlaybackEffects {
  /// Creates the aggregator.
  ///
  /// The five `set*` callbacks are tear-offs of the effect groups'
  /// Dart APIs (see the class doc for the merge wiring). [disposeEffects]
  /// is called from [dispose] so the effect instances release their
  /// native effects; if omitted, [dispose] only zeroes the effects
  /// through the setters. [bridgeChannel] is injectable for tests;
  /// production uses the shared `arena_audio/effects` channel.
  PlaybackEffects({
    required Future<void> Function(double amount) setReverbAmount,
    required Future<void> Function(double amount) setEchoAmount,
    required Future<void> Function(double ms) setEchoDelayMs,
    required Future<void> Function(double amount) setBassAmount,
    required Future<void> Function(int band, double gainDb) setEqBand,
    Future<void> Function()? disposeEffects,
    MethodChannel? bridgeChannel,
  })  : _setReverbAmount = setReverbAmount,
        _setEchoAmount = setEchoAmount,
        _setEchoDelayMs = setEchoDelayMs,
        _setBassAmount = setBassAmount,
        _setEqBand = setEqBand,
        _disposeEffects = disposeEffects,
        _bridgeChannel =
            bridgeChannel ?? const MethodChannel('arena_audio/effects');

  final Future<void> Function(double amount) _setReverbAmount;
  final Future<void> Function(double amount) _setEchoAmount;
  final Future<void> Function(double ms) _setEchoDelayMs;
  final Future<void> Function(double amount) _setBassAmount;
  final Future<void> Function(int band, double gainDb) _setEqBand;
  final Future<void> Function()? _disposeEffects;
  final MethodChannel _bridgeChannel;

  /// The available presets, keyed by canonical name.
  static const Map<String, PlaybackPreset> presets = <String, PlaybackPreset>{
    'Off': PlaybackPreset(
      reverb: 0.0,
      echo: 0.0,
      delayMs: 250.0,
      bass: 0.0,
      eqBand0GainDb: 0.0,
    ),
    'Room': PlaybackPreset(
      reverb: 0.35,
      echo: 0.15,
      delayMs: 180.0,
      bass: 0.30,
      eqBand0GainDb: 3.0,
    ),
    'Hall': PlaybackPreset(
      reverb: 0.70,
      echo: 0.25,
      delayMs: 350.0,
      bass: 0.40,
      eqBand0GainDb: 4.5,
    ),
  };

  AudioPlayer? _player;
  String _preset = 'Off';
  bool _enabled = true;
  bool _disposed = false;

  /// Last routing report from the native bridge (`attachPlayback` /
  /// `getSessionInfo`), or null if the bridge was never reached.
  /// Keys include `sessionId` (0), `routing` ('global-mix'),
  /// `perPlayerSession` (false) and `effectsAvailable`.
  Map<String, Object?>? _sessionInfo;

  /// Whether the native bridge answered the last bridge call.
  bool _bridgeAvailable = false;

  /// Whether [attachToPlayer] has been called (and not disposed).
  bool get isAttached => _player != null && !_disposed;

  /// The attached player's audioplayers player ID, or null if none.
  /// NOTE: this is a Dart-side UUID, NOT an Android audio session ID
  /// — it cannot be used to attach native effects (see class doc).
  String? get attachedPlayerId => _player?.playerId;

  /// Whether effects are currently enabled (audible).
  bool get isEnabled => _enabled && !_disposed;

  /// The current preset name ('Off', 'Room' or 'Hall').
  String get currentPreset => _preset;

  /// Last routing report from the native bridge, or null if the
  /// bridge was never reached.
  Map<String, Object?>? get sessionInfo => _sessionInfo;

  /// Whether the native bridge answered the last bridge call.
  bool get bridgeAvailable => _bridgeAvailable;

  /// Associates this aggregator with the room's music [player] and
  /// asks the native bridge to attach the playback effects.
  ///
  /// The player's Android audio session is NOT available (audioplayers
  /// does not expose it), so the bridge attaches to session 0, the
  /// global output mix — see [sessionInfo] for what the bridge
  /// reports. Never throws for a missing/unreachable bridge: in that
  /// case [bridgeAvailable] stays false and [sessionInfo] stays null.
  /// Throws [StateError] after [dispose].
  Future<void> attachToPlayer(AudioPlayer player) async {
    _checkNotDisposed();
    _player = player;
    try {
      final Map<Object?, Object?>? info = await _bridgeChannel
          .invokeMethod<Map<Object?, Object?>>('attachPlayback');
      _bridgeAvailable = true;
      _sessionInfo = info?.map(
        (Object? key, Object? value) => MapEntry(key.toString(), value),
      );
    } on Exception {
      // Best-effort: the effects' own channels may still work, and a
      // missing bridge must never break attaching the player.
      _bridgeAvailable = false;
      _sessionInfo = null;
    }
    // Re-apply the audible state now that a player is attached, so a
    // preset chosen before attach takes effect. Errors propagate like
    // any other preset application.
    if (_enabled) {
      await _pushPreset(presets[_preset]!);
    }
  }

  /// Applies a preset by name: 'Off', 'Room' or 'Hall'
  /// (case-insensitive, surrounding whitespace ignored).
  ///
  /// When disabled, the preset is recorded but nothing is pushed to
  /// the effects until [setEnabled](true). Throws [ArgumentError] for
  /// an unknown name and [StateError] after [dispose]. If a setter
  /// fails, the remaining setters still run and the first error is
  /// rethrown afterwards.
  Future<void> applyPreset(String name) async {
    _checkNotDisposed();
    final String canonical = _canonicalPresetName(name);
    _preset = canonical;
    if (!_enabled) return;
    await _pushPreset(presets[canonical]!);
  }

  /// Enables or disables the effects.
  ///
  /// Disabling pushes the Off values (all flat/dry); enabling
  /// re-applies the current preset. A no-op when the value is
  /// unchanged. Throws [StateError] after [dispose].
  Future<void> setEnabled(bool value) async {
    _checkNotDisposed();
    if (_enabled == value) return;
    _enabled = value;
    await _pushPreset(presets[value ? _preset : 'Off']!);
  }

  /// Turns everything off, detaches from the native bridge and
  /// disposes the effect instances (via [disposeEffects] when given).
  ///
  /// Best-effort and idempotent: never throws. Calls after [dispose]
  /// throw [StateError].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _player = null;
    try {
      await _pushPresetQuietly(presets['Off']!);
    } on Exception {
      // Dispose must never throw.
    }
    try {
      await _bridgeChannel.invokeMethod<void>('detachPlayback');
    } on Exception {
      // Best-effort detach.
    }
    final Future<void> Function()? disposeEffects = _disposeEffects;
    if (disposeEffects != null) {
      try {
        await disposeEffects();
      } on Exception {
        // The groups' dispose() methods are best-effort by contract;
        // never let teardown throw.
      }
    }
  }

  /// Pushes [preset] to the five effect setters, running every setter
  /// even if one fails, then rethrows the first error (if any).
  Future<void> _pushPreset(PlaybackPreset preset) async {
    Object? firstError;
    StackTrace? firstStack;
    final List<Future<void> Function()> setters = <Future<void> Function()>[
      () => _setReverbAmount(preset.reverb),
      () => _setEchoAmount(preset.echo),
      () => _setEchoDelayMs(preset.delayMs),
      () => _setBassAmount(preset.bass),
      () => _setEqBand(0, preset.eqBand0GainDb),
    ];
    for (final Future<void> Function() setter in setters) {
      try {
        await setter();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) {
      final Object error = firstError;
      final StackTrace stack = firstStack ?? StackTrace.current;
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Like [_pushPreset] but swallows all errors (teardown path).
  Future<void> _pushPresetQuietly(PlaybackPreset preset) async {
    try {
      await _pushPreset(preset);
    } catch (_) {
      // Swallowed: teardown must never throw.
    }
  }

  String _canonicalPresetName(String name) {
    final String lower = name.trim().toLowerCase();
    for (final String key in presets.keys) {
      if (key.toLowerCase() == lower) return key;
    }
    throw ArgumentError.value(
      name,
      'name',
      'Unknown preset. Expected one of: ${presets.keys.join(', ')}.',
    );
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('PlaybackEffects used after dispose()');
    }
  }
}

/// One preset's parameter values, as exposed by
/// [PlaybackEffects.presets]. Band 0 is the lowest EQ band.
class PlaybackPreset {
  const PlaybackPreset({
    required this.reverb,
    required this.echo,
    required this.delayMs,
    required this.bass,
    required this.eqBand0GainDb,
  });

  /// Reverb wetness, 0.0 (dry) .. 1.0 (full wet).
  final double reverb;

  /// Echo wet-mix amount, 0.0 (dry) .. 1.0 (full wet).
  final double echo;

  /// Echo delay time in milliseconds.
  final double delayMs;

  /// Bass-boost strength, 0.0 (off) .. 1.0 (max).
  final double bass;

  /// EQ band 0 (lowest band) gain in dB.
  final double eqBand0GainDb;
}
