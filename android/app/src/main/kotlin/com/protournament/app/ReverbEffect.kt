package com.protournament.app

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * GROUP 3 — reverb for the music player (playback path), Android first.
 *
 * WIRING LAYER ONLY. This file owns the MethodChannel handling and
 * delegates every audio decision to the DSP core in ReverbDsp.kt
 * ([ReverbDsp] interface, default [PlatformReverbDsp] =
 * Android EnvironmentalReverb). It never touches audio parameters
 * or samples itself.
 *
 * DROP-IN: when Sameer's externally written DSP engine arrives
 * (Kotlin + C++, 16-bit PCM @ 48 kHz), it implements [ReverbDsp] and
 * is installed with [setDspCore] — this file, the Dart side, and the
 * channel contract need no changes at all.
 *
 * Contract (shared with Groups 4/5/6/8): channel `arena_audio/effects`;
 * this group owns ONLY the `setReverb` method, argument
 * `{'amount': <0.0-1.0>}` (a bare number is also accepted). Each
 * effect group owns its own Dart file + native file.
 *
 * MERGE WARNING (coordinator): a second `setMethodCallHandler` on the
 * same channel REPLACES the first, so in the merged app do NOT call
 * [register] from several effect classes. Register ONE handler for
 * `arena_audio/effects` (e.g. in MainActivity.configureFlutterEngine)
 * and route "setReverb" to [setReverb] directly:
 *
 *     "setReverb" -> {
 *         val amount = call.argument<Number>("amount")?.toDouble()
 *             ?: (call.arguments as? Number)?.toDouble()
 *         if (amount == null) {
 *             result.error("invalid_args",
 *                 "setReverb expects {'amount': <0.0-1.0>}", null)
 *         } else if (ReverbEffect.setReverb(amount)) {
 *             result.success(null)
 *         } else {
 *             result.error("reverb_unavailable",
 *                 "Reverb engine could not run on this device", null)
 *         }
 *     }
 *
 * [register] exists only for standalone / single-effect use.
 */
object ReverbEffect {

    private const val CHANNEL = "arena_audio/effects"

    /** The DSP core. Swappable via [setDspCore]; default is the platform effect. */
    private var dsp: ReverbDsp = PlatformReverbDsp()

    /**
     * Standalone registration: creates the channel handler for
     * `arena_audio/effects` and answers ONLY `setReverb` (every other
     * method gets `notImplemented`). See the merge warning above —
     * in the merged app, route to [setReverb] from the single shared
     * handler instead of calling this.
     */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "setReverb" -> {
                    val amount = extractAmount(call)
                    if (amount == null) {
                        result.error(
                            "invalid_args",
                            "setReverb expects {'amount': <0.0-1.0>}",
                            null,
                        )
                    } else if (setReverb(amount)) {
                        result.success(null)
                    } else {
                        result.error(
                            "reverb_unavailable",
                            "Reverb engine could not run on this device",
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Applies [amount] (0.0 = dry / effect off, 1.0 = full wet) through
     * the current DSP core. Returns true if the requested state was
     * applied, false if the engine could not run. Never throws.
     */
    @Synchronized
    fun setReverb(amount: Double): Boolean {
        return try {
            dsp.setAmount(amount.coerceIn(0.0, 1.0))
        } catch (_: Exception) {
            false
        }
    }

    /** Releases the current DSP core's native resources. Never throws. */
    @Synchronized
    fun release() {
        try {
            dsp.release()
        } catch (_: Exception) {
            // Release must never crash the caller.
        }
    }

    /**
     * Swaps the DSP core — the drop-in point for Sameer's externally
     * written engine (Kotlin + C++, 16-bit PCM @ 48 kHz). The previous
     * core is released. Thread-safe; takes effect on the next
     * [setReverb] call.
     */
    @Synchronized
    fun setDspCore(core: ReverbDsp) {
        val old = dsp
        dsp = core
        try {
            old.release()
        } catch (_: Exception) {
            // Old core cleanup must never break the swap.
        }
    }

    private fun extractAmount(call: MethodCall): Double? {
        val fromMap = call.argument<Number>("amount")
        if (fromMap != null) return fromMap.toDouble()
        return (call.arguments as? Number)?.toDouble()
    }
}
