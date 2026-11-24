package com.protournament.app

import android.media.audiofx.EnvironmentalReverb

/**
 * GROUP 3 — DSP CORE for reverb. This file owns the actual reverb
 * engine and NOTHING else: no MethodChannel, no audio-session wiring
 * (those live in ReverbEffect.kt).
 *
 * DROP-IN CONTRACT (Sameer 2026-11-22: native DSP code is being
 * written externally — Kotlin + C++, 16-bit PCM @ 48 kHz — and will be
 * handed over for integration):
 *   - A replacement engine implements [ReverbDsp] (two methods:
 *     [ReverbDsp.setAmount] and [ReverbDsp.release]) and is installed
 *     with `ReverbEffect.setDspCore(...)`. No other file changes.
 *   - Any PCM-based engine MUST accept 16-bit PCM @ 48 kHz (mono or
 *     stereo interleaved — the format the external code targets).
 *     The wiring layer (ReverbEffect.kt) never touches samples; it
 *     only passes the 0.0-1.0 amount.
 *   - Both methods must never throw: return false / swallow instead,
 *     so a broken engine degrades to dry audio, never a crash.
 */

/**
 * The reverb engine interface. The wiring layer talks ONLY to this.
 */
interface ReverbDsp {
    /**
     * Applies [amount] (0.0 = dry / effect off, 1.0 = full wet).
     * Returns true if the requested state was applied, false if the
     * engine could not run (unsupported device, missing permission,
     * native init failure, ...). Never throws.
     */
    fun setAmount(amount: Double): Boolean

    /** Releases all native resources held by the engine. Never throws. */
    fun release()
}

/**
 * Platform implementation: Android's [EnvironmentalReverb] on the
 * global output mix (audio session 0). Chosen over a hand-rolled DSP
 * reverb because audioplayers exposes neither a PCM stream nor the
 * player's audio session ID to Dart — a custom DSP engine would
 * require replacing the player entirely. Attaching to session 0
 * needs MODIFY_AUDIO_SETTINGS, which is already in
 * AndroidManifest.xml.
 *
 * Prototype trade-off, stated plainly: session 0 is the device-wide
 * output mix, so while the effect is enabled it also colours other
 * apps' audio. The effect is released (not merely muted) at amount
 * 0.0, so it only exists while the user actually wants reverb. The
 * external PCM engine (when it lands, via [ReverbDsp]) can replace
 * this class without touching the wiring layer.
 */
class PlatformReverbDsp : ReverbDsp {

    private var reverb: EnvironmentalReverb? = null

    override fun setAmount(amount: Double): Boolean {
        // NaN (e.g. a bad value from another caller) degrades to dry
        // instead of flowing into the parameter math below.
        val clamped = if (amount.isNaN()) 0.0 else amount.coerceIn(0.0, 1.0)
        if (clamped <= 0.0) {
            release()
            return true
        }
        return try {
            val effect = reverb ?: EnvironmentalReverb(0, 0).also { reverb = it }
            applyAmount(effect, clamped)
            effect.enabled = true
            true
        } catch (_: Exception) {
            release()
            false
        }
    }

    override fun release() {
        try {
            reverb?.enabled = false
        } catch (_: Exception) {
            // Already released or never started; nothing to do.
        }
        try {
            reverb?.release()
        } catch (_: Exception) {
            // Already released; nothing to do.
        }
        reverb = null
    }

    /**
     * Maps the 0.0-1.0 slider to EnvironmentalReverb parameters.
     * Ranges follow the android.media.audiofx.EnvironmentalReverb docs;
     * every value is clamped because the setters throw
     * IllegalArgumentException outside their range.
     */
    private fun applyAmount(effect: EnvironmentalReverb, amount: Double) {
        // Wet level: -9000 mB (silent) .. 2000 mB (max). Amount 0
        // releases the effect instead, so the low end is never heard.
        effect.reverbLevel =
            // ARENA HUB FIX (2026-11-22): EnvironmentalReverb.reverbLevel
            // is a Short; the computed Int did not compile (kotlinc:
            // "assignment type mismatch: actual type is 'Int', but
            // 'Short' was expected"). The clamped range -9000..2000
            // fits in Short, so narrowing after coerceIn is exact.
            (-9000 + (amount * 11000.0)).toInt().coerceIn(-9000, 2000)
                .toShort()
        // Room level stays full; the slider drives the wet mix,
        // not the room itself.
        effect.roomLevel = 0
        // Decay: 100 ms (tight room) .. 5000 ms (large hall).
        effect.decayTime =
            (100 + (amount * 4900.0)).toInt().coerceIn(100, 20000)
        // Fixed room character: fairly diffuse, fairly dense,
        // neutral high-frequency decay.
        effect.diffusion = 700
        effect.density = 700
        effect.roomHFLevel = -1000
        effect.decayHFRatio = 800
        effect.reflectionsLevel = -1000
        effect.reflectionsDelay = 20
        effect.reverbDelay = 30
    }
}
