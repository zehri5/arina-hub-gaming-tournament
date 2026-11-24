import 'dart:async';
import 'package:flutter/services.dart';

import 'audio_dsp.dart';

class MusicDspException implements Exception {
  MusicDspException(this.message, [this.code]);

  final String message;
  final String? code;

  @override
  String toString() => code == null
      ? 'MusicDspException: $message'
      : 'MusicDspException($code): $message';
}

class MusicDspPlayer {
  MusicDspPlayer({AudioDsp? dsp})
      : _dsp = dsp ?? AudioDsp(),
        _ownsDsp = dsp == null {
    _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
      _handlePlatformEvent,
      onError: (Object error) {
        final msg = error is PlatformException
            ? (error.message ?? error.code)
            : error.toString();
        _errorController.add(MusicDspException(msg));
      },
    );
  }

  static const MethodChannel _channel = MethodChannel('com.arenahub.app/music_dsp');
  static const EventChannel _eventChannel = EventChannel('com.arenahub.app/music_dsp_events');

  final AudioDsp _dsp;
  final bool _ownsDsp;

  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController = StreamController<Duration>.broadcast();
  final StreamController<bool> _isPlayingController = StreamController<bool>.broadcast();
  final StreamController<MusicDspException> _errorController = StreamController<MusicDspException>.broadcast();
  // MUSIC DSP SWAP (2026-11-22): natural-completion signal. The
  // player has no release mode, so loop (repeat) is mount-side:
  // the mount listens here and re-plays when repeat is on.
  final StreamController<void> _completedController = StreamController<void>.broadcast();

  StreamSubscription<dynamic>? _eventSubscription;

  bool _disposed = false;
  bool _loaded = false;
  bool _isPlaying = false;
  bool _isPaused = false;
  bool _isPumping = false;
  // True after a natural end-of-stream ('completed' event) until the
  // next load/seek/play — play() rewinds to 0 from this state (§5.1).
  bool _completed = false;
  int _pumpSessionId = 0;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  Uint8List? _pendingProcessedChunk;

  // FIX 24 — radio mixer feed. The room sets these while GO LIVE
  // is on: every processed chunk the pump writes to playback is
  // ALSO forwarded to the native mixer (same bytes, already
  // decoded + FX'd — the mixer feeds from the pump, it never
  // decodes twice). onPumpReset fires on seek/stop/load so the
  // mixer drops stale buffered audio. Both are best-effort and
  // must never break playback: the pump wraps every call in
  // try/catch, and the callbacks are null when not live.
  void Function(Uint8List chunk)? onProcessedChunk;
  void Function()? onPumpReset;

  AudioDsp get dsp => _dsp;

  // FIX 24: tells the mixer the pump reset (seek/stop/load) so it
  // drops stale buffered audio. Guarded — never throws.
  void _notifyPumpReset() {
    final reset = onPumpReset;
    if (reset != null) {
      try {
        reset();
      } catch (_) {}
    }
  }

  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration> get durationStream => _durationController.stream;
  Stream<bool> get isPlayingStream => _isPlayingController.stream;
  Stream<MusicDspException> get errorStream => _errorController.stream;
  Stream<void> get completedStream => _completedController.stream;

  Duration get position => _position;
  Duration get duration => _duration;
  bool get isPlaying => _isPlaying;
  bool get isLoaded => _loaded;
  double get volume => _volume;

  Future<Duration> load(String filePath) async {
    _ensureNotDisposed();
    if (filePath.trim().isEmpty) {
      throw MusicDspException('File path cannot be empty.', 'INVALID_ARGS');
    }

    await stop();
    await _ensureDspInitialized();
    await _dsp.reset();

    try {
      final Map<dynamic, dynamic>? response = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'load',
        <String, Object>{'filePath': filePath},
      );
      final int durationMs = (response?['durationMs'] as num?)?.toInt() ?? 0;
      _loaded = true;
      _isPaused = false;
      _completed = false;
      _pendingProcessedChunk = null;
      _duration = Duration(milliseconds: durationMs);
      _position = Duration.zero;

      if (!_durationController.isClosed) {
        _durationController.add(_duration);
      }
      if (!_positionController.isClosed) {
        _positionController.add(Duration.zero);
      }
      return _duration;
    } on PlatformException catch (e) {
      _loaded = false;
      throw MusicDspException(e.message ?? 'Failed to load audio file.', e.code);
    }
  }

  Future<void> play() async {
    _ensureNotDisposed();
    if (!_loaded) {
      throw MusicDspException('No audio file loaded. Call load() first.', 'NOT_LOADED');
    }
    // D2 fix (2026-11-22): play-while-playing restarted the native
    // track and relaunched the pump, churning the queue and opening
    // a 40 ms chunk-ordering window between the old and new loops.
    // A redundant play() is a no-op; use pause()/resume() or seek().
    if (_isPlaying) return;

    await _ensureDspInitialized();

    // §5.1 decision (MUSIC DSP SWAP, 2026-11-22): play() after a
    // natural end-of-stream rewinds to 0 first — without this the
    // decoder sits at EOS and play() re-completes immediately.
    if (_completed) {
      await seek(Duration.zero);
    }

    try {
      await _channel.invokeMethod<void>('start');
      await _channel.invokeMethod<void>('setVolume', <String, Object>{'volume': _volume});
      _isPaused = false;
      _setPlaying(true);
      _startPumpLoop();
    } on PlatformException catch (e) {
      _setPlaying(false);
      throw MusicDspException(e.message ?? 'Failed to start playback.', e.code);
    }
  }

  Future<void> pause() async {
    _ensureNotDisposed();
    if (!_isPlaying) return;

    _pumpSessionId++;
    _isPaused = true;
    _setPlaying(false);

    try {
      await _channel.invokeMethod<void>('pause');
    } on PlatformException catch (e) {
      throw MusicDspException(e.message ?? 'Failed to pause playback.', e.code);
    }
  }

  Future<void> resume() async {
    _ensureNotDisposed();
    if (!_loaded) {
      throw MusicDspException('No audio file loaded. Call load() first.', 'NOT_LOADED');
    }
    if (_isPlaying) return;

    try {
      await _channel.invokeMethod<void>('resume');
      _isPaused = false;
      _setPlaying(true);
      _startPumpLoop();
    } on PlatformException catch (e) {
      _setPlaying(false);
      throw MusicDspException(e.message ?? 'Failed to resume playback.', e.code);
    }
  }

  Future<void> stop() async {
    if (_disposed) return;

    _pumpSessionId++;
    _isPaused = false;
    _completed = false;
    _pendingProcessedChunk = null;
    _notifyPumpReset();
    _setPlaying(false);

    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      throw MusicDspException(e.message ?? 'Failed to stop playback.', e.code);
    }

    if (_dsp.isInitialized) {
      await _dsp.reset();
    }

    _position = Duration.zero;
    if (!_positionController.isClosed) {
      _positionController.add(Duration.zero);
    }
  }

  Future<void> seek(Duration target) async {
    _ensureNotDisposed();
    if (!_loaded) {
      throw MusicDspException('No audio file loaded. Call load() first.', 'NOT_LOADED');
    }

    final bool shouldResumePump = _isPlaying && !_isPaused;
    _pumpSessionId++;
    _completed = false;
    _pendingProcessedChunk = null;
    _notifyPumpReset();

    if (_dsp.isInitialized) {
      await _dsp.reset();
    }

    final int targetMs = target.inMilliseconds.clamp(
      0,
      _duration.inMilliseconds > 0 ? _duration.inMilliseconds : target.inMilliseconds,
    );

    try {
      final int? actualMs = await _channel.invokeMethod<int>(
        'seek',
        <String, Object>{'positionMs': targetMs},
      );
      _position = Duration(milliseconds: actualMs ?? targetMs);
      if (!_positionController.isClosed) {
        _positionController.add(_position);
      }

      if (shouldResumePump) {
        _startPumpLoop();
      }
    } on PlatformException catch (e) {
      throw MusicDspException(e.message ?? 'Failed to seek audio.', e.code);
    }
  }

  Future<void> setVolume(double volume) async {
    _ensureNotDisposed();
    _volume = volume.clamp(0.0, 1.0).toDouble();
    try {
      await _channel.invokeMethod<void>('setVolume', <String, Object>{'volume': _volume});
    } on PlatformException catch (e) {
      throw MusicDspException(e.message ?? 'Failed to set volume.', e.code);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pumpSessionId++;
    _pendingProcessedChunk = null;
    // D4 fix (2026-11-22): leave the getters in a consistent
    // post-dispose state instead of reporting a stale isPlaying.
    _isPlaying = false;
    _isPaused = false;
    _completed = false;
    _loaded = false;
    _isPumping = false;

    await _eventSubscription?.cancel();
    _eventSubscription = null;

    try {
      await _channel.invokeMethod<void>('dispose');
    } catch (_) {
      // Ignore errors during teardown
    }

    if (_ownsDsp) {
      await _dsp.dispose();
    }

    await _positionController.close();
    await _durationController.close();
    await _isPlayingController.close();
    await _errorController.close();
    await _completedController.close();
  }

  Future<void> _ensureDspInitialized() async {
    try {
      if (!_dsp.isInitialized) {
        await _dsp.init(sampleRate: 48000, channels: 2);
      } else if (_dsp.sampleRate != 48000 || _dsp.channels != 2) {
        await _dsp.configure(sampleRate: 48000, channels: 2);
      }
    } on PlatformException catch (e) {
      // D5 fix (2026-11-22): a DSP init failure (e.g.
      // NATIVE_UNAVAILABLE when the .so is missing) surfaces as
      // MusicDspException like every other player failure, not a raw
      // PlatformException escaping load()/play().
      throw MusicDspException(
        e.message ?? 'Failed to initialize audio DSP.',
        e.code,
      );
    }
  }

  void _startPumpLoop() {
    final int sessionId = ++_pumpSessionId;
    if (_isPumping) {
      // Previous loop will exit on mismatched sessionId; launch next microtask
      Future<void>.microtask(() => _runPumpLoop(sessionId));
      return;
    }
    unawaited(_runPumpLoop(sessionId));
  }

  Future<void> _runPumpLoop(int sessionId) async {
    _isPumping = true;
    try {
      while (!_disposed && sessionId == _pumpSessionId && _isPlaying && !_isPaused) {
        Uint8List? chunkToWrite = _pendingProcessedChunk;

        if (chunkToWrite == null) {
          final Uint8List? rawPcm = await _channel.invokeMethod<Uint8List>('nextChunk');
          if (_disposed || sessionId != _pumpSessionId) {
            return;
          }
          if (rawPcm == null) {
            await _channel.invokeMethod<void>('finishStream');
            return;
          }
          if (rawPcm.isEmpty) {
            continue;
          }

          chunkToWrite = await _dsp.process(rawPcm);
          if (_disposed || sessionId != _pumpSessionId) {
            _pendingProcessedChunk = chunkToWrite;
            return;
          }
        }

        _pendingProcessedChunk = chunkToWrite;
        final bool? accepted = await _channel.invokeMethod<bool>(
          'writeChunk',
          <String, Object>{'pcmBytes': chunkToWrite},
        );

        if (accepted == true) {
          _pendingProcessedChunk = null;
          // FIX 24 — radio mixer feed: the chunk just accepted for
          // playback is also the mixer's music feed (same bytes,
          // already decoded + FX'd). Fire-and-forget, guarded: a
          // mixer failure must never break playback.
          final feed = onProcessedChunk;
          if (feed != null) {
            try {
              feed(chunkToWrite);
            } catch (_) {}
          }
        } else {
          // Paused, stopped, or seeked while waiting for buffer space
          return;
        }
      }
    } on PlatformException catch (e) {
      if (!_disposed && sessionId == _pumpSessionId) {
        _setPlaying(false);
        if (!_errorController.isClosed) {
          _errorController.add(MusicDspException(e.message ?? 'Playback failed.', e.code));
        }
      }
    } catch (e) {
      if (!_disposed && sessionId == _pumpSessionId) {
        _setPlaying(false);
        if (!_errorController.isClosed) {
          _errorController.add(MusicDspException(e.toString()));
        }
      }
    } finally {
      // D1 fix (2026-11-22): only the CURRENT session clears the
      // flag. The old code let a stale loop (exiting on a session
      // mismatch) clear _isPumping while the newer loop was still
      // running, which could launch a second concurrent pump.
      if (sessionId == _pumpSessionId) {
        _isPumping = false;
      }
    }
  }

  void _handlePlatformEvent(dynamic event) {
    if (_disposed || event is! Map) return;
    final String? type = event['type'] as String?;
    switch (type) {
      case 'position':
        final int posMs = (event['positionMs'] as num?)?.toInt() ?? 0;
        final int durMs = (event['durationMs'] as num?)?.toInt() ?? _duration.inMilliseconds;
        _position = Duration(milliseconds: posMs);
        _duration = Duration(milliseconds: durMs);
        if (!_positionController.isClosed) {
          _positionController.add(_position);
        }
        break;
      case 'state':
        final bool playing = event['isPlaying'] as bool? ?? false;
        _setPlaying(playing);
        break;
      case 'completed':
        _pendingProcessedChunk = null;
        _isPaused = false;
        _completed = true;
        _setPlaying(false);
        if (!_completedController.isClosed) {
          _completedController.add(null);
        }
        break;
      case 'error':
        final String msg = event['message'] as String? ?? 'Unknown native audio error.';
        _setPlaying(false);
        if (!_errorController.isClosed) {
          _errorController.add(MusicDspException(msg));
        }
        break;
    }
  }

  void _setPlaying(bool playing) {
    if (_isPlaying == playing) return;
    _isPlaying = playing;
    if (!_isPlayingController.isClosed) {
      _isPlayingController.add(playing);
    }
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('MusicDspPlayer has been disposed.');
    }
  }
}
