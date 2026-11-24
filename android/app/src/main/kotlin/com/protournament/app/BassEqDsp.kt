package com.protournament.app

import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.util.Log

/**
 * DSP CORE — Group 5 (ARENA HUB #10 AUDIO). Bass boost + EQ for the
 * music player (playback path), Android first.
 *
 * *** THIS FILE IS THE DSP CORE. ***
 * It is the ONLY place that touches the actual audio-effect
 * implementation. Everything else — MethodChannel routing, argument
 * parsing, audio-session selection — lives in BassEqEffect.kt and
 * talks to this class only through its public API below. Nothing in
 * this file imports anything from Flutter.
 *
 * CURRENT IMPLEMENTATION: Android's AudioEffect framework
 * (BassBoost + Equalizer) attached to the given audio session. The
 * platform effect engine processes the audio internally, so this
 * implementation does not handle raw PCM buffers itself.
 *
 * REPLACEMENT CONTRACT (external DSP handover — e.g. ChatGPT /
 * developer-written Kotlin+C++ reverb/echo/bass code):
 *   - Format: 16-bit PCM, 48 kHz sample rate.
 *   - To swap in: replace this file's internals (or this whole file)
 *     with the external DSP core, keeping the public API below
 *     unchanged — [setBass], [setEqBand], [bandCount], [release] —
 *     and BassEqEffect.kt + the Dart side keep working with no
 *     rewiring. The external core receives the audio session id via
 *     the constructor; if it processes PCM buffers directly it must
 *     accept 16-bit PCM @ 48 kHz.
 *
 * Effects are created lazily on first use. On devices/emulators
 * without an effect engine, creation throws and the public methods
 * throw [IllegalStateException] (mapped to error code
 * "effect_unavailable" by BassEqEffect) instead of crashing.
 *
 * @param audioSession the Android audio session to attach to.
 *   0 = the global output mix (current wiring: audioplayers does not
 *   expose its player session id to Dart).
 */
class BassEqDsp(private val audioSession: Int = OUTPUT_MIX_SESSION) {

    companion object {
        private const val TAG = "BassEqDsp"

        /** Audio session 0 = the global output mix. */
        const val OUTPUT_MIX_SESSION = 0
    }

    private var bassBoost: BassBoost? = null
    private var equalizer: Equalizer? = null

    /**
     * Number of EQ bands the device exposes. Creates the Equalizer
     * lazily; throws [IllegalStateException] if no effect engine is
     * available.
     */
    val bandCount: Int
        get() = equalizerOrThrow().numberOfBands.toInt()

    /**
     * Sets the bass-boost strength. [amount] is 0.0 (off) to 1.0
     * (max); out-of-range values are clamped.
     * Throws [IllegalStateException] if BassBoost is unavailable.
     */
    fun setBass(amount: Double) {
        val clamped = amount.coerceIn(0.0, 1.0)
        try {
            val effect = bassBoost
                ?: BassBoost(0, audioSession).also { bassBoost = it }
            effect.enabled = true
            // BassBoost strength is 0-1000 (milli-strength).
            effect.setStrength((clamped * 1000).toInt().toShort())
        } catch (e: Exception) {
            Log.w(TAG, "BassBoost unavailable on this device", e)
            throw IllegalStateException(
                "BassBoost could not be created on this device",
                e,
            )
        }
    }

    /**
     * Sets the gain of EQ [band] (0-based) to [gainDb] decibels.
     * Gain is clamped to the device's real band-level range.
     * Throws [IllegalArgumentException] for an out-of-range band and
     * [IllegalStateException] if the Equalizer is unavailable.
     */
    fun setEqBand(band: Int, gainDb: Double) {
        val effect = equalizerOrThrow()
        val count = effect.numberOfBands.toInt()
        require(band in 0 until count) {
            "Band $band out of range (0..${count - 1})"
        }
        effect.enabled = true
        // Band levels are millibels; clamp to the device's real range.
        val range = effect.getBandLevelRange()
        val levelMb = (gainDb * 100).toInt()
            .coerceIn(range[0].toInt(), range[1].toInt())
            .toShort()
        effect.setBandLevel(band.toShort(), levelMb)
    }

    /**
     * Releases the native effects. Safe to call more than once.
     * After release the next set call re-creates the effects.
     */
    fun release() {
        try {
            bassBoost?.release()
        } catch (_: Exception) {
            // Best-effort release; never crash teardown.
        }
        try {
            equalizer?.release()
        } catch (_: Exception) {
            // Best-effort release; never crash teardown.
        }
        bassBoost = null
        equalizer = null
    }

    private fun equalizerOrThrow(): Equalizer {
        return try {
            equalizer ?: Equalizer(0, audioSession).also { equalizer = it }
        } catch (e: Exception) {
            Log.w(TAG, "Equalizer unavailable on this device", e)
            throw IllegalStateException(
                "Equalizer could not be created on this device",
                e,
            )
        }
    }
}
