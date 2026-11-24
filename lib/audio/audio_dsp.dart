import 'package:flutter/services.dart';

class AudioDsp {
  static const MethodChannel _channel = MethodChannel('com.arenahub.app/audio_dsp');

  int? _handle;
  bool _disposed = false;
  int _sampleRate = 48000;
  int _channels = 2;

  bool get isInitialized => _handle != null && !_disposed;
  int get sampleRate => _sampleRate;
  int get channels => _channels;

  Future<void> init({
    int sampleRate = 48000,
    int channels = 2,
  }) async {
    if (_disposed) {
      throw StateError('AudioDsp instance has already been disposed.');
    }
    _validateFormat(sampleRate, channels);

    if (_handle != null) {
      await configure(sampleRate: sampleRate, channels: channels);
      return;
    }

    final int? handle = await _channel.invokeMethod<int>('create', <String, Object>{
      'sampleRate': sampleRate,
      'channels': channels,
    });
    if (handle == null || handle == 0) {
      throw PlatformException(
        code: 'INIT_FAILED',
        message: 'Native AudioDsp engine returned null handle.',
      );
    }

    _handle = handle;
    _sampleRate = sampleRate;
    _channels = channels;
  }

  /// Adopts the plugin's SHARED stereo playback engine — the same
  /// native engine the ExoPlayer `DspAudioProcessor` routes live
  /// playback frames through — instead of creating a private engine.
  ///
  /// GROUP 8 DSP addition (2026-11-22). `init()` creates a private
  /// engine that only [process] can reach; live playback frames never
  /// go through it, so parameters set on a privately-initialized
  /// instance can never colour live music. This method calls the
  /// native `attachPlaybackEngine` channel method, which returns the
  /// shared playback handle (creating the engine on first use), and
  /// adopts it as this instance's handle. Afterwards [setReverb] /
  /// [setEcho] / [setEq] / [reset] control the engine the live
  /// playback path feeds, and [dispose] only drops this Dart-side
  /// handle — the native plugin keeps the shared engine alive for
  /// the audio processor until the player releases it.
  ///
  /// Use this for MUSIC playback (stereo). The LiveKit voice path
  /// keeps using [init] with its own private mono engine.
  ///
  /// Like [init], calling this on an already-initialized instance
  /// just reconfigures the existing engine instead of adopting the
  /// shared one — call it on a fresh instance.
  Future<void> initPlayback({
    int sampleRate = 48000,
    int channels = 2,
  }) async {
    if (_disposed) {
      throw StateError('AudioDsp instance has already been disposed.');
    }
    _validateFormat(sampleRate, channels);

    if (_handle != null) {
      await configure(sampleRate: sampleRate, channels: channels);
      return;
    }

    final int? handle = await _channel.invokeMethod<int>(
      'attachPlaybackEngine',
      <String, Object>{
        'sampleRate': sampleRate,
        'channels': channels,
      },
    );
    if (handle == null || handle == 0) {
      throw PlatformException(
        code: 'INIT_FAILED',
        message: 'Native AudioDsp plugin returned no playback engine handle.',
      );
    }

    _handle = handle;
    _sampleRate = sampleRate;
    _channels = channels;
  }

  Future<void> configure({
    int sampleRate = 48000,
    int channels = 2,
  }) async {
    final int handle = _requireHandle();
    _validateFormat(sampleRate, channels);

    await _channel.invokeMethod<void>('configure', <String, Object>{
      'handle': handle,
      'sampleRate': sampleRate,
      'channels': channels,
    });
    _sampleRate = sampleRate;
    _channels = channels;
  }

  Future<void> setNoiseGate({
    bool enabled = true,
    double thresholdDb = -40.0,
    double attackMs = 5.0,
    double releaseMs = 120.0,
  }) async {
    final int handle = _requireHandle();
    // double.clamp passes NaN straight through (NaN comparisons are
    // false), and NaN would pin the native threshold at 0 dB (mic
    // muted) via clampFloat. Sanitize to the defaults first; the C++
    // layer also guards, but never send a bad value down the channel.
    await _channel.invokeMethod<void>('setNoiseGate', <String, Object>{
      'handle': handle,
      'enabled': enabled,
      'thresholdDb': _finiteOr(thresholdDb, -40.0).clamp(-90.0, 0.0).toDouble(),
      'attackMs': _finiteOr(attackMs, 5.0).clamp(0.1, 500.0).toDouble(),
      'releaseMs': _finiteOr(releaseMs, 120.0).clamp(5.0, 2000.0).toDouble(),
    });
  }

  Future<void> setCompressor({
    bool enabled = true,
    double thresholdDb = -18.0,
    double ratio = 4.0,
    double attackMs = 10.0,
    double releaseMs = 100.0,
    double makeupGainDb = 0.0,
  }) async {
    final int handle = _requireHandle();
    // NaN guard (v3 adoption fix): double.clamp passes NaN straight
    // through (all comparisons false), and the C++ clamp would then map
    // it to the HIGH end (NaN makeup -> +24 dB). Non-finite params fall
    // back to defaults before clamping.
    await _channel.invokeMethod<void>('setCompressor', <String, Object>{
      'handle': handle,
      'enabled': enabled,
      'thresholdDb': (thresholdDb.isFinite ? thresholdDb : -18.0).clamp(-60.0, 0.0).toDouble(),
      'ratio': (ratio.isFinite ? ratio : 4.0).clamp(1.0, 20.0).toDouble(),
      'attackMs': (attackMs.isFinite ? attackMs : 10.0).clamp(0.1, 200.0).toDouble(),
      'releaseMs': (releaseMs.isFinite ? releaseMs : 100.0).clamp(5.0, 2000.0).toDouble(),
      'makeupGainDb': (makeupGainDb.isFinite ? makeupGainDb : 0.0).clamp(0.0, 24.0).toDouble(),
    });
  }

  Future<void> setReverb({
    bool enabled = true,
    double wetDryMix = 0.3,
    double roomSize = 0.5,
    double damping = 0.5,
  }) async {
    final int handle = _requireHandle();
    // NaN degrades to dry (0.0): num.clamp() passes NaN through
    // unchanged, and the native clamp would map it to 1.0 (full wet).
    await _channel.invokeMethod<void>('setReverb', <String, Object>{
      'handle': handle,
      'enabled': enabled,
      'wetDryMix': wetDryMix.isNaN ? 0.0 : wetDryMix.clamp(0.0, 1.0).toDouble(),
      'roomSize': roomSize.isNaN ? 0.0 : roomSize.clamp(0.0, 1.0).toDouble(),
      'damping': damping.isNaN ? 0.0 : damping.clamp(0.0, 1.0).toDouble(),
    });
  }

  Future<void> setEcho({
    bool enabled = true,
    double delayMs = 250.0,
    double feedback = 0.35,
    double mix = 0.35,
  }) async {
    final int handle = _requireHandle();
    // NB: num.clamp() passes NaN straight through (both comparisons are
    // false), and the native clamp turns NaN into the MAXIMUM value, so
    // a NaN here would silently become 2000 ms / 0.95 feedback / full
    // wet. Sanitise NaN to safe values first (delay -> default, feedback
    // and mix -> 0 = silent and safe).
    await _channel.invokeMethod<void>('setEcho', <String, Object>{
      'handle': handle,
      'enabled': enabled,
      'delayMs': delayMs.isNaN ? 250.0 : delayMs.clamp(1.0, 2000.0).toDouble(),
      'feedback': feedback.isNaN ? 0.0 : feedback.clamp(0.0, 0.95).toDouble(),
      'mix': mix.isNaN ? 0.0 : mix.clamp(0.0, 1.0).toDouble(),
    });
  }

  Future<void> setEq({
    bool enabled = true,
    double bassBoostDb = 0.0,
    double lowGainDb = 0.0,
    double midGainDb = 0.0,
    double highGainDb = 0.0,
  }) async {
    final int handle = _requireHandle();
    await _channel.invokeMethod<void>('setEq', <String, Object>{
      'handle': handle,
      'enabled': enabled,
      'bassBoostDb': _finiteDb(bassBoostDb).clamp(0.0, 12.0).toDouble(),
      'lowGainDb': _finiteDb(lowGainDb).clamp(-12.0, 12.0).toDouble(),
      'midGainDb': _finiteDb(midGainDb).clamp(-12.0, 12.0).toDouble(),
      'highGainDb': _finiteDb(highGainDb).clamp(-12.0, 12.0).toDouble(),
    });
  }

  Future<Uint8List> process(Uint8List pcm16Bytes) async {
    final int handle = _requireHandle();
    if (pcm16Bytes.isEmpty) {
      return Uint8List(0);
    }

    final Uint8List? output = await _channel.invokeMethod<Uint8List>(
      'process',
      <String, Object>{
        'handle': handle,
        'pcmBytes': pcm16Bytes,
      },
    );
    return output ?? Uint8List(0);
  }

  Future<void> reset() async {
    final int handle = _requireHandle();
    await _channel.invokeMethod<void>('reset', <String, Object>{
      'handle': handle,
    });
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final int? handle = _handle;
    _handle = null;

    if (handle != null) {
      await _channel.invokeMethod<void>('destroy', <String, Object>{
        'handle': handle,
      });
    }
  }

  int _requireHandle() {
    if (_disposed) {
      throw StateError('AudioDsp instance has been disposed.');
    }
    final int? handle = _handle;
    if (handle == null) {
      throw StateError('AudioDsp is not initialized. Call init() first.');
    }
    return handle;
  }

  void _validateFormat(int sampleRate, int channels) {
    if (sampleRate < 8000 || sampleRate > 192000) {
      throw ArgumentError.value(sampleRate, 'sampleRate', 'Must be between 8000 and 192000 Hz.');
    }
    if (channels != 1 && channels != 2) {
      throw ArgumentError.value(channels, 'channels', 'Only mono (1) and stereo (2) are supported.');
    }
  }

  /// Non-finite (NaN/infinite) doubles fall back to [fallback]: Dart's
  /// `clamp` returns NaN unchanged, so it cannot sanitize on its own.
  static double _finiteOr(double value, double fallback) =>
      value.isFinite ? value : fallback;

  // NaN survives clamp() unchanged, and native clampFloat(NaN) maps to
  // the upper bound — an unsanitized NaN would silently become +12 dB
  // on every band. Treat it as 0 dB. (Group 5 fix, 2026-11-22.)
  static double _finiteDb(double value) => value.isNaN ? 0.0 : value;
}
