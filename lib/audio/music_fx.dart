import 'audio_dsp.dart';

/// Music-FX application onto the MusicDspPlayer's OWN [AudioDsp]
/// instance (Group 2, MusicDspPlayer swap, 2026-11-22).
///
/// The music sheet's panel (MusicPlayerPanel) drives these through
/// the mount's callbacks in room_screen.dart (`_musicDsp()` resolves
/// the player's instance — `MusicDspPlayer.dsp`, the private engine
/// its pump calls `process()` on). NEVER the voice-chain instance:
/// one [AudioDsp] instance = one isolated C++ engine, and the panel
/// would otherwise drive music effects into the mic chain.
///
/// Every method is fail-open: when the DSP is not initialized
/// (`isInitialized` false — player absent, not loaded yet, or the
/// `.so` missing) it returns silently instead of throwing. The
/// mount mirrors the state regardless, so the panel always shows
/// the values the user picked; the engine call is best-effort.
///
/// BASS MAPPING (documented, deliberate — same deviation as the
/// voice chain, see the BASS DEVIATION note in
/// test/rj_voice_mount_test.dart): the brief asked for the old
/// mount's (dB+12)/24 mapping, but that mapping fed
/// `BassEqEffect.setBass`, a 0..1 amount. This engine's `setEq`
/// takes absolute dB (`bassBoostDb` 0..12, `lowGainDb` -12..+12),
/// and applying (dB+12)/24 here would make the 0 dB knob send +6 dB
/// of bass boost (and the Off preset non-flat). Instead — exactly
/// like `rjBassEqPreset` on the voice chain — positive dB becomes
/// bass boost, negative dB cuts the low band, and 0 dB stays flat.
/// The preset bass values (0/+3/+4.5 dB) are therefore the old
/// PlaybackEffects eqBand0 gains, and Off stays flat.
class MusicFx {
  MusicFx._();

  /// Knob dB (-12..+12) -> engine `bassBoostDb` (0..12 dB):
  /// positive dB only; 0 dB and below give 0.
  static double bassBoostDb(double bassDb) {
    final double db = bassDb.isNaN ? 0.0 : bassDb.clamp(-12.0, 12.0).toDouble();
    return db > 0 ? db : 0.0;
  }

  /// Knob dB (-12..+12) -> engine `lowGainDb` (-12..0 dB):
  /// negative dB only (a low-band cut); 0 dB and above give 0.
  static double bassLowGainDb(double bassDb) {
    final double db = bassDb.isNaN ? 0.0 : bassDb.clamp(-12.0, 12.0).toDouble();
    return db < 0 ? db : 0.0;
  }

  /// Reverb knob 0..1 -> `setReverb(wetDryMix)`. Disabled at 0.
  static Future<void> applyReverb(AudioDsp dsp, double amount) async {
    if (!dsp.isInitialized) return;
    await dsp.setReverb(enabled: amount > 0, wetDryMix: amount);
  }

  /// Echo knob 0..1 + delay ms -> `setEcho(mix, delayMs)`.
  /// Disabled at 0 (the delay value is still pushed, so turning
  /// echo back up resumes with the delay the user picked).
  static Future<void> applyEcho(
    AudioDsp dsp,
    double amount,
    double delayMs,
  ) async {
    if (!dsp.isInitialized) return;
    await dsp.setEcho(enabled: amount > 0, delayMs: delayMs, mix: amount);
  }

  /// Bass knob dB (-12..+12) -> `setEq` (boost + low-band cut).
  /// Disabled (flat) at exactly 0 dB.
  static Future<void> applyBass(AudioDsp dsp, double bassDb) async {
    if (!dsp.isInitialized) return;
    await dsp.setEq(
      enabled: bassDb != 0,
      bassBoostDb: bassBoostDb(bassDb),
      lowGainDb: bassLowGainDb(bassDb),
    );
  }

  /// Applies a preset's values (`AudioEffectsPanel.presetValues` —
  /// the ONE preset definition) to the music DSP: reverb + echo
  /// from the 0..1 amounts, delay from `delayMs`, bass dB as the
  /// low-band gain (see the bass mapping note above — Off stays
  /// flat). All setters run even if one fails; the first error is
  /// rethrown (same contract as the old
  /// `PlaybackEffects._pushPreset`).
  static Future<void> applyPreset(
    AudioDsp dsp,
    Map<String, double> values,
  ) async {
    if (!dsp.isInitialized) return;
    Object? firstError;
    StackTrace? firstStack;
    for (final Future<void> Function() setter in <Future<void> Function()>[
      () => applyReverb(dsp, values['reverb'] ?? 0.0),
      () => applyEcho(dsp, values['echo'] ?? 0.0, values['delayMs'] ?? 250.0),
      () => applyBass(dsp, values['bass'] ?? 0.0),
    ]) {
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
}
