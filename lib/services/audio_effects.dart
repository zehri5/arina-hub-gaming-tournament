/// Audio effects barrel (Arena Hub #10 audio).
///
/// Single import for the music-playback effects stack: the three effect
/// services (Groups 3/4/5) plus the playback coordinator (Group 8).
/// Created by the coordinator at the G8 merge (2026-11-22); the G10
/// harness tests import this barrel.
///
/// Mic-side processors live elsewhere on purpose and are NOT exported here:
/// `krisp_noise_filter.dart` (Group 1), `rnnoise_processor.dart` (Group 2),
/// `mic_audio_pipeline.dart` (Group 7).
library;

export 'audio_effects_reverb.dart';
export 'audio_effects_echo.dart';
export 'audio_effects_bass.dart';
export 'playback_effects.dart';
