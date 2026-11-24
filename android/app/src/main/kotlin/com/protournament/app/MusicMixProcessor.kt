package com.protournament.app

import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import com.cloudwebrtc.webrtc.audio.LocalAudioTrack
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min

// FIX 24 — RADIO MUSIC MIXER (2026-11-23, user voice-call order).
//
// The host's background music goes DIRECTLY into the live mic stream
// (Shoutcast/radio model): listeners hear exactly what the host hears,
// no upload, no wait, seek works live. The mixer is a THIRD processor
// on the SAME capturePostProcessing hook the voice DSP (DspMicProcessor)
// and RNNoise already use — after mic capture, before encoding — so it
// needs no flutter_webrtc fork and no second LiveKit track.
//
// HOW IT WORKS
//  - Dart's music pump (MusicDspPlayer) already decodes the song to
//    48 kHz stereo int16 PCM and runs it through the music FX chain.
//    The pump ALSO pushes each processed chunk here (pushChunk) into
//    a native ring buffer. No per-frame channel calls: process()
//    runs on the audio thread ~100fps and never touches Dart.
//  - process() reads 10 ms of music (160 mono samples @ 16 kHz,
//    decimated from the 48 kHz stereo feed with a 3-tap box filter),
//    applies the mic gain to the mic bands and ADDS the music into
//    band 0, in place, before the frame is encoded.
//  - Gains come from Dart via one setGains call per change
//    (mic + music together) — cheap, no audio-thread involvement.
//
// BAND-0 MIX (honest limit, v1): the APM frame is SPLIT-BAND
// (numBands x numFrames planar samples; each band is 10 ms at an
// effective 16 kHz). A full-band mix would need WebRTC's exact QMF
// analysis filterbank to split the music into the same bands — its
// coefficients are not verifiable on this VM, and a wrong filterbank
// would distort the music. So v1 mixes into BAND 0 only:
//   - numBands == 1 (16 kHz APM): band 0 IS the whole signal —
//     full-band 16 kHz music, the best case.
//   - numBands == 3 (48 kHz APM): band 0 covers 0-8 kHz — the
//     music is telephone/AM-radio quality (clear, not hi-fi).
// The mic gain applies to ALL bands (mic mute = gain 0 silences
// the mic everywhere). The first-frame log (bands/frames/capacity)
// is the on-device evidence for which case a phone is in; a QMF
// split is the v2 upgrade if the phone test shows 3 bands AND the
// music sounds dull.
//
// REGISTRATION ORDER: register the mixer AFTER the voice DSP
// processor (it is — the voice processor installs at voice join,
// the mixer on GO LIVE), so the music bypasses voice echo/reverb.
// The adapter runs processors in registration order.
//
// BUFFER LAYOUT: same detection as DspMicProcessor — capacity
// settles float32 (bands*frames*4) vs int16 (bands*frames*2),
// with a one-time float sanity check. Both layouts are mixed.
//
// SPEAKER USE (user order: no headphones): when the mic is ON the
// music is ducked low by the inverse link, so acoustic pickup of
// the speaker is quiet; when the mic is OFF the mic gain is 0, so
// there is no pickup at all. Phone test decides if that is clean
// enough — this file cannot prove it on a VM.

/** The WebRTC APM frame hook for the radio mix. One instance, shared. */
internal class MusicMixAudioProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
    companion object {
        private const val TAG = "RadioMix"

        // Ring capacity: 2 s of 48 kHz stereo int16
        // (48000 frames/s x 2 ch x 2 bytes = 192000 B/s).
        private const val RING_BYTES = 384000
        // One APM frame = 10 ms = 160 samples @ 16 kHz mono.
        private const val FRAME_SAMPLES_16K = 160
        // 10 ms of 48 kHz stereo = 480 frames = 1920 bytes.
        private const val FRAME_BYTES_48K_STEREO = 1920
    }

    // ---- Mix gains (set from Dart, read on the audio thread). ----
    @Volatile
    private var micGain = 1.0f

    @Volatile
    private var musicGain = 1.0f

    fun setGains(music: Float, mic: Float) {
        musicGain = music.coerceIn(0f, 1f)
        micGain = mic.coerceIn(0f, 1f)
    }

    // ---- Music ring buffer (48 kHz stereo int16, little-endian). ----
    // Producer: pushChunk (platform thread). Consumer: process()
    // (audio thread). One lock, short critical sections (a push
    // copies <= 7680 B; a read copies 1920 B) — the audio thread
    // never blocks on Dart.
    private val ringLock = Any()
    private val ring = ByteArray(RING_BYTES)
    private var ringRead = 0
    private var ringWrite = 0
    private var ringSize = 0

    // ---- Diagnostics (read via the `diagnostics` channel method). ----
    @Volatile
    private var framesMixed = 0L

    @Volatile
    private var underrunFrames = 0L

    @Volatile
    private var droppedBytes = 0L

    @Volatile
    private var lastNumBands = 0

    @Volatile
    private var lastNumFrames = 0

    @Volatile
    private var lastLayout = "unknown"

    @Volatile
    private var layoutLogged = false

    @Volatile
    private var lastSampleRateHz = 48000

    @Volatile
    private var lastNumChannels = 1

    fun pushChunk(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        synchronized(ringLock) {
            val src = bytes
            // Overrun: drop the OLDEST bytes to make room — the
            // ring is a live feed, never a backlog (bounded
            // latency; stale music is worse than no music).
            val free = RING_BYTES - ringSize
            if (src.size > free) {
                val drop = src.size - free
                ringRead = (ringRead + drop) % RING_BYTES
                ringSize -= drop
                droppedBytes += drop
            }
            var off = 0
            var remaining = src.size
            while (remaining > 0) {
                val chunk = min(remaining, RING_BYTES - ringWrite)
                System.arraycopy(src, off, ring, ringWrite, chunk)
                ringWrite = (ringWrite + chunk) % RING_BYTES
                off += chunk
                remaining -= chunk
            }
            ringSize += src.size
        }
    }

    fun flush() {
        synchronized(ringLock) {
            ringRead = 0
            ringWrite = 0
            ringSize = 0
        }
    }

    fun bufferedMs(): Int {
        synchronized(ringLock) {
            // 192 bytes per ms at 48 kHz stereo int16.
            return ringSize / 192
        }
    }

    fun framesMixed(): Long = framesMixed

    fun diagnostics(): Map<String, Any> {
        return mapOf(
            "framesMixed" to framesMixed,
            "underrunFrames" to underrunFrames,
            "droppedBytes" to droppedBytes,
            "bufferedMs" to bufferedMs(),
            "lastBands" to lastNumBands,
            "lastFrames" to lastNumFrames,
            "layout" to lastLayout,
            "micGain" to micGain.toDouble(),
            "musicGain" to musicGain.toDouble(),
        )
    }

    /**
     * Reads [count] mono samples at 16 kHz from the ring into [out]
     * (decimate 48 kHz stereo -> 16 kHz mono: average each 3-frame
     * window, (L+R)/2). Returns the number of samples actually
     * read; the rest of [out] is zero-filled by the caller.
     */
    private fun readMono16k(out: ShortArray, count: Int): Int {
        synchronized(ringLock) {
            // Each 16 kHz sample needs 3 stereo frames (12 bytes).
            val availSamples = ringSize / 12
            val n = min(count, availSamples)
            for (i in 0 until n) {
                // 3 stereo frames = 6 int16 values (L R L R L R).
                var sum = 0
                for (f in 0 until 3) {
                    val base = (ringRead + (i * 3 + f) * 4) % RING_BYTES
                    val l = readInt16LE(base)
                    val r = readInt16LE((base + 2) % RING_BYTES)
                    sum += (l + r) / 2
                }
                out[i] = (sum / 3).coerceIn(-32768, 32767).toShort()
            }
            ringRead = (ringRead + n * 12) % RING_BYTES
            ringSize -= n * 12
            return n
        }
    }

    private fun readInt16LE(pos: Int): Int {
        val lo = ring[pos % RING_BYTES].toInt() and 0xFF
        val hi = ring[(pos + 1) % RING_BYTES].toInt()
        return (hi shl 8) or lo
    }

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        lastSampleRateHz = sampleRateHz
        lastNumChannels = numChannels
        Log.i(TAG, "initialize rate=$sampleRateHz ch=$numChannels")
    }

    override fun reset(newRate: Int) {
        lastSampleRateHz = newRate
    }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer?) {
        if (buffer == null || numBands < 1 || numFrames < 1) return
        lastNumBands = numBands
        lastNumFrames = numFrames
        val mic = micGain
        val music = musicGain

        // Layout: capacity settles float32 vs int16 (DspMic pattern).
        val floatBytes = numBands * numFrames * 4
        val shortBytes = numBands * numFrames * 2
        val isFloat = buffer.capacity() >= floatBytes
        if (!layoutLogged) {
            layoutLogged = true
            lastLayout = if (isFloat) "float32" else "int16"
            Log.i(
                TAG,
                "first frame: bands=$numBands frames=$numFrames " +
                    "capacity=${buffer.capacity()} layout=$lastLayout " +
                    "rate=$lastSampleRateHz ch=$lastNumChannels"
            )
        }
        if (!isFloat && buffer.capacity() < shortBytes) {
            // Unknown layout — pass the frame through untouched.
            return
        }
        // Count only frames that actually reach the mix (the
        // pass-through above must not inflate the counter).
        framesMixed++

        // 10 ms of music, mono @ 16 kHz. The frame is 10 ms at
        // 16 kHz per band, so numFrames samples is exactly one
        // frame's worth (160 in the normal case).
        val musicBuf = ShortArray(numFrames)
        val got = readMono16k(musicBuf, numFrames)
        if (got < numFrames) {
            underrunFrames++
            for (i in got until numFrames) musicBuf[i] = 0
        }

        try {
            if (isFloat) {
                // Planar float32: band b starts at sample b*numFrames.
                for (b in 0 until numBands) {
                    val base = b * numFrames
                    if (b == 0) {
                        for (i in 0 until numFrames) {
                            val idx = base + i
                            val m = buffer.getFloat(idx * 4) * mic
                            // Music sample: int16 -> [-1, 1).
                            val s = musicBuf[i] / 32768.0f * music
                            buffer.putFloat(idx * 4, (m + s).coerceIn(-1.0f, 1.0f))
                        }
                    } else {
                        for (i in 0 until numFrames) {
                            val idx = base + i
                            buffer.putFloat(idx * 4, buffer.getFloat(idx * 4) * mic)
                        }
                    }
                }
            } else {
                // Planar int16: band b starts at sample b*numFrames.
                for (b in 0 until numBands) {
                    val base = b * numFrames
                    if (b == 0) {
                        for (i in 0 until numFrames) {
                            val idx = base + i
                            val m = (buffer.getShort(idx * 2) * mic).toInt()
                            val s = (musicBuf[i] * music).toInt()
                            buffer.putShort(
                                idx * 2,
                                (m + s).coerceIn(-32768, 32767).toShort()
                            )
                        }
                    } else {
                        for (i in 0 until numFrames) {
                            val idx = base + i
                            buffer.putShort(
                                idx * 2,
                                (buffer.getShort(idx * 2) * mic).toInt()
                                    .coerceIn(-32768, 32767).toShort()
                            )
                        }
                    }
                }
            }
        } catch (_: Throwable) {
            // Never let a mixing failure break the call: the frame
            // passes through (possibly partially mixed — the next
            // frame is clean).
        }
    }
}

/** MethodChannel handler for `arena_hub_radio_mixer`. Registered once from MainActivity. */
class MusicMixProcessor private constructor() : MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "RadioMix"
        const val CHANNEL_NAME = "arena_hub_radio_mixer"

        @Volatile
        private var instance: MusicMixProcessor? = null

        /**
         * The messenger the channel is currently bound to. Same
         * FIX 22 item 6 lesson as DspMicProcessor: the singleton
         * survives a normal relaunch in the same process, but the
         * engine's messenger is recreated — re-bind on a new
         * engine, and drop the stale hook state (the old WebRTC
         * controller died with the old engine).
         */
        @Volatile
        private var boundMessenger: BinaryMessenger? = null

        @JvmStatic
        fun register(messenger: BinaryMessenger) {
            val existing = instance
            if (existing == null) {
                synchronized(this) {
                    if (instance == null) {
                        val created = MusicMixProcessor()
                        MethodChannel(messenger, CHANNEL_NAME)
                            .setMethodCallHandler(created)
                        instance = created
                        boundMessenger = messenger
                        Log.i(TAG, "registered")
                    }
                }
            } else if (boundMessenger !== messenger) {
                MethodChannel(messenger, CHANNEL_NAME)
                    .setMethodCallHandler(existing)
                boundMessenger = messenger
                existing.onEngineRebound()
                Log.i(TAG, "re-bound channel to new engine messenger")
            }
            // Same engine re-attaching: nothing to do.
        }
    }

    private val audioProcessor = MusicMixAudioProcessor()

    @Volatile
    private var registered = false

    private fun onEngineRebound() {
        registered = false
        audioProcessor.flush()
        Log.i(TAG, "engine rebound: hook state reset")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> {
                // The APM controller exists once flutter_webrtc has
                // built its first PeerConnectionFactory (i.e. once
                // voice has been used). No track needed for this.
                val ok = try {
                    FlutterWebRTCPlugin.sharedSingleton
                        ?.audioProcessingController != null
                } catch (_: Throwable) {
                    false
                }
                result.success(ok)
            }
            "register" -> {
                // trackId is optional: when given, the track is
                // validated (must be a live LocalAudioTrack — the
                // same sanity check DspMicProcessor does); when
                // null the hook is added on the controller alone
                // (best-effort — the hook is global to the
                // capture stream, not per-track).
                val trackId = call.argument<String>("trackId")
                register(trackId, result)
            }
            "unregister" -> {
                unregister()
                result.success(null)
            }
            "pushChunk" -> {
                val bytes = call.arguments as? ByteArray
                if (bytes == null) {
                    result.error("INVALID_ARGUMENT", "chunk bytes required", null)
                } else {
                    try {
                        audioProcessor.pushChunk(bytes)
                    } catch (_: Throwable) {
                        // A failed push must never break playback.
                    }
                    result.success(null)
                }
            }
            "flush" -> {
                audioProcessor.flush()
                result.success(null)
            }
            "setGains" -> {
                val music = (call.argument<Double>("music") ?: 1.0).toFloat()
                val mic = (call.argument<Double>("mic") ?: 1.0).toFloat()
                audioProcessor.setGains(music, mic)
                result.success(null)
            }
            "framesMixed" -> result.success(audioProcessor.framesMixed())
            "bufferedMs" -> result.success(audioProcessor.bufferedMs())
            "diagnostics" -> result.success(audioProcessor.diagnostics())
            else -> result.notImplemented()
        }
    }

    private fun register(trackId: String?, result: MethodChannel.Result) {
        if (registered) {
            // Already hooked; re-adding the same instance would mix
            // the music into every frame twice.
            result.success(true)
            return
        }
        val plugin = FlutterWebRTCPlugin.sharedSingleton
        if (plugin == null) {
            result.error("WEBRTC_NOT_READY", "FlutterWebRTCPlugin not initialized", null)
            return
        }
        if (trackId != null) {
            val track = try {
                plugin.getLocalTrack(trackId)
            } catch (_: Exception) {
                null
            }
            if (track == null || track !is LocalAudioTrack) {
                result.error("INVALID_ARGUMENT", "track is not a LocalAudioTrack", null)
                return
            }
        }
        val controller = try {
            plugin.audioProcessingController
        } catch (_: Exception) {
            null
        }
        if (controller == null) {
            result.error(
                "WEBRTC_NOT_READY",
                "AudioProcessingController not created yet",
                null,
            )
            return
        }
        try {
            // Registration order is the processing order: the voice
            // DSP processor (installed at voice join) runs first,
            // the mixer runs after it — so the music bypasses voice
            // echo/reverb and lands clean in the encoded frame.
            controller.capturePostProcessing.addProcessor(audioProcessor)
        } catch (e: Throwable) {
            Log.w(TAG, "addProcessor failed", e)
            result.error("ATTACH_FAILED", "capturePostProcessing.addProcessor failed", null)
            return
        }
        registered = true
        Log.i(TAG, "register: hooked track=$trackId")
        result.success(true)
    }

    private fun unregister() {
        if (!registered) return
        registered = false
        try {
            FlutterWebRTCPlugin.sharedSingleton
                ?.audioProcessingController
                ?.capturePostProcessing
                ?.removeProcessor(audioProcessor)
        } catch (_: Exception) {
            // Plugin gone; nothing to remove.
        }
        audioProcessor.flush()
        audioProcessor.setGains(1.0f, 1.0f)
        Log.i(TAG, "unregister: unhooked")
    }
}
