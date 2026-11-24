import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'wav_decoder.dart';

enum SoundPad {
  applause,
  airHorn,
  laugh,
  drumRoll,
}

extension SoundPadAsset on SoundPad {
  String get assetPath {
    switch (this) {
      case SoundPad.applause:
        return 'assets/sounds/applause.wav';
      case SoundPad.airHorn:
        return 'assets/sounds/air_horn.wav';
      case SoundPad.laugh:
        return 'assets/sounds/laugh.wav';
      case SoundPad.drumRoll:
        return 'assets/sounds/drum_roll.wav';
    }
  }

  String get _audioPlayersRelativePath {
    const String prefix = 'assets/';
    return assetPath.startsWith(prefix)
        ? assetPath.substring(prefix.length)
        : assetPath;
  }
}

/// Live-on-air soundboard that pre-decodes bundled WAV clips to 48 kHz mono
/// and mixes them directly into the host's outgoing PCM16 mic frames.
class Soundboard extends ChangeNotifier {
  static const double defaultPadVolume = 0.8;
  static const double _softLimitThreshold = 0.9;
  static const double _softLimitHeadroom = 1.0 - _softLimitThreshold;

  Soundboard({
    this.playLocally = true,
    double masterVolume = 1.0,
  })  : _masterVolume = masterVolume.clamp(0.0, 1.0),
        _localPlayer = AudioPlayer();

  /// Whether playing a pad also plays locally on the host's phone speaker
  /// via `audioplayers` so the host can monitor what went live on air.
  bool playLocally;

  final AudioPlayer _localPlayer;
  final Map<SoundPad, Float32List?> _clips = <SoundPad, Float32List?>{};
  final Map<SoundPad, double> _padVolumes = <SoundPad, double>{
    for (final SoundPad pad in SoundPad.values) pad: defaultPadVolume,
  };

  double _masterVolume;
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _initFuture;

  // Hot-path state read by mixInto() on every audio frame.
  bool _isPlaying = false;
  SoundPad? _activePad;
  Float32List? _activeSamples;
  int _playhead = 0;
  double _activeGain = defaultPadVolume;

  // Route-A completion timer (see play()): mixInto() is the only thing
  // that used to finish a playback, and in route A the live mix runs
  // natively, so mixInto() is never called — without this timer the
  // pad would stay "playing" (and its underline lit) forever.
  Timer? _finishTimer;

  double get masterVolume => _masterVolume;
  bool get isPlaying => _isPlaying;
  SoundPad? get activePad => _isPlaying ? _activePad : null;

  double getPadVolume(SoundPad pad) => _padVolumes[pad] ?? defaultPadVolume;

  /// Combined pad × master gain for [pad] (0..1) — the gain the mount
  /// pushes live to the native bridge when the pad plays (route A).
  double gainFor(SoundPad pad) => _computeGain(pad);

  bool isPadAvailable(SoundPad pad) {
    final Float32List? clip = _clips[pad];
    // An empty clip is unplayable (play() refuses it), so it must not
    // report available — otherwise a pad renders enabled and does
    // nothing on tap. (Unreachable from decodeToMono48k after the D2
    // fix, which never returns empty; this is defence in depth.)
    return clip != null && clip.isNotEmpty;
  }

  /// Length of [pad]'s decoded clip, or null when the pad is unavailable.
  /// The mount uses it to time the active-pad underline while the clip
  /// plays natively (the native bridge owns the playhead — see
  /// SOUNDBOARD_INTEGRATION.md §5).
  Duration? clipDuration(SoundPad pad) {
    final Float32List? clip = _clips[pad];
    if (clip == null || clip.isEmpty) return null;
    return Duration(
      microseconds:
          (clip.length * 1000000 / WavDecoder.targetSampleRate).round(),
    );
  }

  /// The decoded 48 kHz mono clip for [pad], or null when unavailable.
  /// The mount passes it to the native bridge (route A) at load time —
  /// see SOUNDBOARD_INTEGRATION.md §3. The list is owned by this
  /// Soundboard: callers must treat it as read-only.
  Float32List? decodedClip(SoundPad pad) => _clips[pad];

  /// Test-only seam: installs an already-decoded clip for [pad] without
  /// touching the asset bundle. Used by soundboard_test.dart with
  /// generated test tones (never a real asset).
  @visibleForTesting
  void debugInjectClip(SoundPad pad, Float32List samples) {
    if (_disposed) return;
    _clips[pad] = samples;
    notifyListeners();
  }

  /// Loads and pre-decodes all 4 soundboard WAV clips into memory.
  ///
  /// Missing or malformed clips are logged and marked unavailable without
  /// failing initialization for the remaining pads. Concurrent calls share
  /// one decode pass (a second call while the first is in flight awaits
  /// the same future instead of decoding all 4 clips twice).
  Future<void> init() {
    if (_disposed || _initialized) return Future<void>.value();
    final Future<void>? inFlight = _initFuture;
    if (inFlight != null) return inFlight;
    final Future<void> future = _init();
    _initFuture = future;
    return future;
  }

  Future<void> _init() async {

    try {
      await _localPlayer.setReleaseMode(ReleaseMode.stop);
    } catch (e, st) {
      _logError('Failed to configure local AudioPlayer release mode', e, st);
    }

    for (final SoundPad pad in SoundPad.values) {
      if (_disposed) return;
      try {
        final ByteData data = await rootBundle.load(pad.assetPath);
        final Uint8List bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        final Float32List decoded = WavDecoder.decodeToMono48k(bytes);
        _clips[pad] = decoded;
      } catch (e, st) {
        _clips[pad] = null;
        _logError(
          'Soundboard failed to load ${pad.assetPath}; pad marked unavailable',
          e,
          st,
        );
      }
    }

    if (!_disposed) {
      _initialized = true;
      notifyListeners();
    }
  }

  /// Starts playing [pad] from the beginning into the live mix (and locally if
  /// [playLocally] is true). Restarts if already playing, or replaces any other
  /// currently playing pad.
  void play(SoundPad pad) {
    if (_disposed) return;
    final Float32List? clip = _clips[pad];
    if (clip == null || clip.isEmpty) return;

    final double gain = _computeGain(pad);
    _activePad = pad;
    _activeSamples = clip;
    _playhead = 0;
    _activeGain = gain;
    _isPlaying = true;

    // FINISH TIMER (route-A fix, review 2026-11-22): finish the
    // playback when the clip's duration elapses, whether or not
    // mixInto() is driving the playhead. In route A the live mix
    // runs natively and mixInto() is never called, so without this
    // the pad would stay "playing" forever. When mixInto() IS
    // running, it finishes first (same instant, within one frame)
    // and cancels this timer — the two paths agree, never fight.
    _finishTimer?.cancel();
    _finishTimer = Timer(
      clipDuration(pad) ?? Duration.zero,
      () {
        if (_isPlaying && _activePad == pad) {
          _finishPlayback();
        }
      },
    );

    notifyListeners();

    if (playLocally) {
      unawaited(_playLocalClip(pad, gain));
    } else {
      unawaited(_stopLocalClip());
    }
  }

  /// Stops any currently playing pad immediately.
  void stop() {
    if (_disposed) return;
    final bool wasPlaying = _isPlaying;
    _isPlaying = false;
    _activePad = null;
    _activeSamples = null;
    _playhead = 0;
    _finishTimer?.cancel();
    _finishTimer = null;

    if (wasPlaying) {
      notifyListeners();
    }
    unawaited(_stopLocalClip());
  }

  /// Sets the per-pad volume in [0.0, 1.0].
  void setPadVolume(SoundPad pad, double volume) {
    if (_disposed) return;
    final double clamped = volume.clamp(0.0, 1.0);
    _padVolumes[pad] = clamped;

    if (_isPlaying && _activePad == pad) {
      _activeGain = _computeGain(pad);
      if (playLocally) {
        unawaited(_setLocalVolume(_activeGain));
      }
    }
  }

  /// Sets the master soundboard volume in [0.0, 1.0].
  void setMasterVolume(double volume) {
    if (_disposed) return;
    _masterVolume = volume.clamp(0.0, 1.0);

    final SoundPad? pad = _activePad;
    if (_isPlaying && pad != null) {
      _activeGain = _computeGain(pad);
      if (playLocally) {
        unawaited(_setLocalVolume(_activeGain));
      }
    }
  }

  /// Mixes the active soundboard clip in place into a 48 kHz mono 16-bit
  /// little-endian PCM frame.
  ///
  /// When idle, returns immediately after a single boolean check with zero
  /// allocations.
  void mixInto(Uint8List pcm16MonoFrame) {
    if (!_isPlaying) return;

    final Float32List? clip = _activeSamples;
    if (clip == null) {
      _isPlaying = false;
      return;
    }

    final int byteLength = pcm16MonoFrame.lengthInBytes;
    final int frameSamples = byteLength >> 1;
    if (frameSamples <= 0) return;

    final int clipLength = clip.length;
    int pos = _playhead;
    if (pos >= clipLength) {
      _finishPlayback();
      return;
    }

    final double gain = _activeGain;
    final int remaining = clipLength - pos;
    final int mixCount = remaining < frameSamples ? remaining : frameSamples;

    if (gain <= 0.0) {
      // SILENT CLIP FIX (review 2026-11-22): with the volume at 0 the
      // mix adds nothing, but the loop below still ran the mic through
      // int16 -> float -> soft-limit -> int16, altering loud mic peaks
      // by a few LSB (the soft limiter compresses anything above 0.9
      // even with no sound playing). Advance the playhead without
      // touching the frame, so a muted soundboard leaves the mic
      // bit-identical while the clip still finishes on time.
      _playhead = pos + mixCount;
      if (_playhead >= clipLength) {
        _finishPlayback();
      }
      return;
    }

    int byteOffset = 0;
    for (int i = 0; i < mixCount; i++) {
      final int lo = pcm16MonoFrame[byteOffset];
      final int hi = pcm16MonoFrame[byteOffset + 1];
      int rawMic = lo | (hi << 8);
      if (rawMic >= 0x8000) rawMic -= 0x10000;

      final double mic = rawMic / 32768.0;
      final double sfx = clip[pos] * gain;
      final double mixed = _softLimit(mic + sfx);

      int outSample = (mixed * 32767.0).round();
      if (outSample > 32767) {
        outSample = 32767;
      } else if (outSample < -32768) {
        outSample = -32768;
      }

      pcm16MonoFrame[byteOffset] = outSample & 0xFF;
      pcm16MonoFrame[byteOffset + 1] = (outSample >> 8) & 0xFF;

      byteOffset += 2;
      pos++;
    }

    _playhead = pos;
    if (pos >= clipLength) {
      _finishPlayback();
    }
  }

  void _finishPlayback() {
    _isPlaying = false;
    _activePad = null;
    _activeSamples = null;
    _playhead = 0;
    _finishTimer?.cancel();
    _finishTimer = null;
    if (!_disposed) {
      scheduleMicrotask(() {
        if (!_disposed) {
          notifyListeners();
        }
      });
    }
  }

  double _computeGain(SoundPad pad) {
    final double padVol = _padVolumes[pad] ?? defaultPadVolume;
    return (padVol * _masterVolume).clamp(0.0, 1.0);
  }

  /// Soft-limits samples above +/- 0.9 using a smooth tanh knee so peaks
  /// asymptotically approach +/- 1.0 without hard-clipping int16 overflow.
  static double _softLimit(double x) {
    if (x > _softLimitThreshold) {
      final double over = (x - _softLimitThreshold) / _softLimitHeadroom;
      return _softLimitThreshold + _softLimitHeadroom * _tanh(over);
    }
    if (x < -_softLimitThreshold) {
      final double over = (-x - _softLimitThreshold) / _softLimitHeadroom;
      return -_softLimitThreshold - _softLimitHeadroom * _tanh(over);
    }
    return x;
  }

  static double _tanh(double x) {
    if (x > 10.0) return 1.0;
    if (x < -10.0) return -1.0;
    final double e2x = math.exp(2.0 * x);
    return (e2x - 1.0) / (e2x + 1.0);
  }

  Future<void> _playLocalClip(SoundPad pad, double volume) async {
    if (_disposed) return;
    try {
      await _localPlayer.stop();
      if (_disposed) return;
      await _localPlayer.play(
        AssetSource(pad._audioPlayersRelativePath),
        volume: volume,
      );
    } catch (e, st) {
      _logError('Local monitor playback failed for ${pad.assetPath}', e, st);
    }
  }

  Future<void> _stopLocalClip() async {
    if (_disposed) return;
    try {
      await _localPlayer.stop();
    } catch (e, st) {
      _logError('Failed to stop local monitor AudioPlayer', e, st);
    }
  }

  Future<void> _setLocalVolume(double volume) async {
    if (_disposed) return;
    try {
      await _localPlayer.setVolume(volume);
    } catch (e, st) {
      _logError('Failed to update local monitor volume', e, st);
    }
  }

  void _logError(String message, Object error, StackTrace stackTrace) {
    developer.log(
      message,
      name: 'ArenaHub.Soundboard',
      error: error,
      stackTrace: stackTrace,
    );
    if (kDebugMode) {
      debugPrint('[Soundboard] $message: $error');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isPlaying = false;
    _activePad = null;
    _activeSamples = null;
    _playhead = 0;
    _finishTimer?.cancel();
    _finishTimer = null;
    _clips.clear();
    unawaited(_localPlayer.dispose());
    super.dispose();
  }
}
