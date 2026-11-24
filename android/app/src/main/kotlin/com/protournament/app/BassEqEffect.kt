package com.protournament.app

import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Group 5 (ARENA HUB #10 AUDIO) — MethodChannel + audio-session
 * WIRING for bass boost + EQ. This file owns NO audio processing:
 * it parses method calls on the shared `arena_audio/effects` channel
 * and delegates to the DSP core, [BassEqDsp].
 *
 * DSP CORE LOCATION (for the external DSP handover):
 *   android/app/src/main/kotlin/com/protournament/app/BassEqDsp.kt
 *   — class BassEqDsp. Replace that file's internals with the
 *   external DSP core (16-bit PCM, 48 kHz) keeping its public API
 *   (setBass / setEqBand / bandCount / release), and this wiring
 *   file + the Dart side keep working with no rewiring.
 *
 * Audio session: the DSP core attaches to session 0 (the global
 * output mix) because audioplayers does not expose its player
 * audio-session id to Dart, and the shared channel contract has no
 * session-id method. Session 0 makes bass/EQ apply to all app
 * playback, including the music player — good enough for day-one
 * prototype quality. If the real player session ever becomes
 * available, pass it to the [BassEqDsp] constructor here; the DSP
 * core itself does not change.
 *
 * Wiring (coordinator — MainActivity, one shared channel handler for
 * all effect groups on "arena_audio/effects"):
 * ```
 * private val bassEqEffect = BassEqEffect()
 * MethodChannel(messenger, "arena_audio/effects").setMethodCallHandler { call, result ->
 *     if (bassEqEffect.handle(call, result)) return@setMethodCallHandler
 *     // ... route to the other groups' handlers ...
 *     result.notImplemented()
 * }
 * // and on engine destroy: bassEqEffect.release()
 * ```
 * This class deliberately does NOT register its own channel handler:
 * five groups share one channel, so MainActivity owns the single
 * handler and [handle] returns false for methods it does not own.
 *
 * @param dsp the DSP core; injectable so the external core can be
 *   dropped in without touching this file.
 */
class BassEqEffect(private val dsp: BassEqDsp = BassEqDsp()) {

    companion object {
        private const val TAG = "BassEqEffect"
    }

    /**
     * Handles one method call on the shared `arena_audio/effects`
     * channel. Returns true if this group owns the method ("setBass" /
     * "setEq") and answered [result]; false otherwise, so the caller
     * can route the call to another effect group.
     */
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        return when (call.method) {
            "setBass" -> {
                setBass(call, result)
                true
            }
            "setEq" -> {
                setEq(call, result)
                true
            }
            else -> false
        }
    }

    /** "setBass": args `amount` (Double, 0.0-1.0, clamped). */
    private fun setBass(call: MethodCall, result: MethodChannel.Result) {
        val amount = call.argument<Double>("amount")
            ?: call.argument<Int>("amount")?.toDouble()
        if (amount == null) {
            result.error("invalid_args", "setBass requires a numeric 'amount'", null)
            return
        }
        try {
            dsp.setBass(amount)
            result.success(null)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "BassBoost unavailable on this device", e)
            result.error("effect_unavailable", e.message, null)
        }
    }

    /** "setEq": args `band` (Int, 0-based) and `gainDb` (Double). */
    private fun setEq(call: MethodCall, result: MethodChannel.Result) {
        val band = call.argument<Int>("band")
        val gainDb = call.argument<Double>("gainDb")
            ?: call.argument<Int>("gainDb")?.toDouble()
        if (band == null || gainDb == null) {
            result.error(
                "invalid_args",
                "setEq requires 'band' (int) and 'gainDb' (number)",
                null,
            )
            return
        }
        try {
            dsp.setEqBand(band, gainDb)
            result.success(null)
        } catch (e: IllegalArgumentException) {
            result.error("invalid_band", e.message, null)
        } catch (e: IllegalStateException) {
            Log.w(TAG, "Equalizer unavailable on this device", e)
            result.error("effect_unavailable", e.message, null)
        }
    }

    /**
     * Releases the DSP core's native effects. Call from MainActivity
     * when the engine is destroyed; safe to call more than once.
     */
    fun release() {
        dsp.release()
    }
}
