package com.protournament.app

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/**
 * ARENA HUB #10 AUDIO — Group 4: echo/delay for the music player
 * (playback path), Android first.
 *
 * Android has NO built-in echo effect (unlike reverb/eq/bass, which
 * have AudioEffect subclasses), so this is a CUSTOM delay-line DSP
 * written in Kotlin. Prototype quality is fine for day one — the
 * wiring and the contract matter more than algorithmic novelty.
 *
 * How the delay line works (single circular buffer, stereo
 * interleaved):
 * - `buffer` holds MAX_DELAY_MS of audio (48 kHz stereo = 192,000
 *   floats). A write index advances one sample at a time and wraps.
 * - The read index trails the write index by `delaySamples` (the
 *   delay time in samples). For each sample:
 *     out = dry + wet * delayed        (wet = echo amount 0..1)
 *     buffer[write] = dry + FEEDBACK * delayed
 *   Feeding the delayed sample back into the buffer at 0.35 gain is
 *   what makes the echo repeat and decay instead of sounding once.
 * - Echo off (amount == 0) is a plain dry copy — no buffer writes,
 *   so enabling echo later starts from silence, not stale audio.
 * - Delay is clamped to >= 1 sample: a 0-sample delay would read the
 *   buffer slot from one full buffer ago (2 s of stale audio).
 * - Output is clamped to [-1, 1] so a loud wet mix can clip at worst
 *   instead of wrapping around when converted back to 16-bit PCM.
 *
 * Channel contract (shared with Groups 3/5/6/8):
 *   channel: arena_audio/effects
 *   methods: setReverb / setEcho / setDelay / setBass / setEq
 * This class owns setEcho + setDelay ONLY.
 *
 * MERGE NOTE FOR THE COORDINATOR: only ONE MethodChannel handler can
 * be registered per channel, so do NOT call [register] once per
 * effect group — the last registration would win and the other
 * effects would stop working. Instead, register ONE handler in
 * MainActivity and dispatch through each group's `onMethodCall`
 * (it returns false for methods the group does not own):
 *
 *     val echo = EchoDelayEffect()
 *     // ... reverb, bass, eq instances ...
 *     MethodChannel(messenger, "arena_audio/effects")
 *         .setMethodCallHandler { call, result ->
 *             if (echo.onMethodCall(call, result)) return@setMethodCallHandler
 *             // ... other groups ...
 *             result.notImplemented()
 *         }
 *
 * [register] exists only for single-group standalone testing.
 *
 * INTEGRATION NOTE (day-one scope): this class processes raw PCM
 * float buffers. Tapping it into the music player's actual output
 * stream (audioplayers drives its own ExoPlayer/MediaPlayer pipeline)
 * needs a follow-up step — e.g. an ExoPlayer AudioProcessor or a
 * custom AudioTrack-based playback path — and is NOT part of this
 * file. The DSP core + channel wiring here are the day-one
 * deliverable; the native code cannot be unit-tested on this VM
 * (no Android emulator / Robolectric run here), so the Dart-side
 * tests cover the contract and the Kotlin is kept deliberately
 * small and reviewable.
 */
class EchoDelayEffect(
    private val sampleRate: Int = DEFAULT_SAMPLE_RATE,
    private val channels: Int = DEFAULT_CHANNELS,
) {
    companion object {
        /** Shared effects channel — same name on every group. */
        const val CHANNEL = "arena_audio/effects"

        const val DEFAULT_SAMPLE_RATE = 48000
        const val DEFAULT_CHANNELS = 2

        /** Largest delay the buffer can hold, in milliseconds. */
        const val MAX_DELAY_MS = 2000

        /** Delay before Dart ever calls setDelay. */
        const val DEFAULT_DELAY_MS = 250

        /**
         * Feedback gain: how much of the delayed sample is written
         * back into the buffer. 0.35 gives ~3 audible repeats
         * before the echo fades out. Must stay < 1.0 or the
         * feedback loop runs away (howling / clipping).
         */
        private const val FEEDBACK = 0.35f

        @Volatile
        private var sharedInstance: EchoDelayEffect? = null

        /**
         * Standalone registration (single-group testing only).
         * See the class KDoc — the merged app must use ONE handler
         * dispatching to every group's onMethodCall instead.
         */
        @JvmStatic
        fun register(messenger: BinaryMessenger): EchoDelayEffect {
            val effect = sharedInstance ?: EchoDelayEffect().also {
                sharedInstance = it
            }
            MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
                if (!effect.onMethodCall(call, result)) {
                    result.notImplemented()
                }
            }
            return effect
        }
    }

    private val maxDelaySamples: Int = (MAX_DELAY_MS * sampleRate) / 1000

    /** Circular delay buffer, interleaved per channel. */
    private val buffer = FloatArray(maxDelaySamples * channels)

    private var writeIndex = 0

    /** Wet-mix amount, 0.0 (dry) .. 1.0 (full wet). */
    @Volatile
    var amount: Float = 0f
        private set

    /** Current delay in samples per channel (>= 1, see class KDoc). */
    @Volatile
    private var delaySamples: Int = delayMsToSamples(DEFAULT_DELAY_MS)

    /** Sets the echo wet-mix amount; clamped to 0.0–1.0. */
    fun setEcho(amount: Float) {
        this.amount = when {
            amount.isNaN() -> 0f
            else -> amount.coerceIn(0f, 1f)
        }
    }

    /** Sets the delay time in milliseconds; clamped to 0–MAX_DELAY_MS. */
    fun setDelayMs(ms: Float) {
        val clamped = when {
            ms.isNaN() -> 0f
            else -> ms.coerceIn(0f, MAX_DELAY_MS.toFloat())
        }
        delaySamples = delayMsToSamples(clamped.roundToInt())
    }

    /**
     * Processes [frames] frames of interleaved float PCM.
     * [input] and [output] must each hold at least `frames * channels`
     * samples; they may be the same array (in-place is safe: each
     * sample is read before its slot is written).
     */
    fun process(input: FloatArray, output: FloatArray, frames: Int) {
        require(input.size >= frames * channels) { "input too small" }
        require(output.size >= frames * channels) { "output too small" }
        val wet = amount
        val total = frames * channels
        if (wet <= 0f) {
            // Echo off: dry passthrough, buffer untouched.
            input.copyInto(output, destinationOffset = 0, startIndex = 0, endIndex = total)
            return
        }
        val delay = delaySamples * channels
        val size = buffer.size
        var w = writeIndex
        for (i in 0 until total) {
            var r = w - delay
            if (r < 0) r += size
            val delayed = buffer[r]
            val dry = input[i]
            output[i] = (dry + wet * delayed).coerceIn(-1f, 1f)
            buffer[w] = dry + FEEDBACK * delayed
            w++
            if (w >= size) w = 0
        }
        writeIndex = w
    }

    /** Clears the delay line (e.g. when a new track starts). */
    fun reset() {
        buffer.fill(0f)
        writeIndex = 0
    }

    /**
     * Handles this group's methods on the shared effects channel.
     * Returns true if [call] was handled, false otherwise (the
     * dispatcher then tries the next group's effect).
     */
    fun onMethodCall(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "setEcho" -> {
                val amount = (call.argument<Number>("amount")?.toFloat())
                if (amount == null) {
                    result.error("INVALID_ARGS", "setEcho needs a numeric 'amount'", null)
                } else {
                    setEcho(amount)
                    result.success(null)
                }
                return true
            }
            "setDelay" -> {
                val ms = (call.argument<Number>("ms")?.toFloat())
                if (ms == null) {
                    result.error("INVALID_ARGS", "setDelay needs a numeric 'ms'", null)
                } else {
                    setDelayMs(ms)
                    result.success(null)
                }
                return true
            }
            else -> return false
        }
    }

    /** Delay in samples per channel, clamped to [1, maxDelaySamples]. */
    private fun delayMsToSamples(ms: Int): Int =
        ((ms * sampleRate) / 1000).coerceIn(1, maxDelaySamples)
}
