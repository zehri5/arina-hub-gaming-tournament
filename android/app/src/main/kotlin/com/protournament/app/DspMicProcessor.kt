package com.protournament.app

import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import com.cloudwebrtc.webrtc.audio.LocalAudioTrack
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

// DSP mic EQ for Arena Hub voice rooms (Group 7, #10 audio).
//
// RJ STUDIO EVOLUTION (2026-11-22): the host mic chain is now the full
// live DSP chain — Gate -> Compressor -> EQ -> Echo -> Reverb —
// running per band (one DspEngine per band; EQ on band 0 only, see
// dsp_mic_bridge.h). The RJ panel's sliders drive it LIVE through the
// setEq/setEcho/setReverb/setNoiseGate/setCompressor channel methods:
// param changes only store a pending preset in the bridge and NEVER
// touch the TrackProcessor or the mic track (no re-publish, no voice
// restart). Only install/remove and NC on/off re-publish.
//
// This file is a close adaptation of Group 2's proven RnnoiseProcessor.kt:
// the SAME capturePostProcessing hook, the SAME registration / fail-open
// patterns — only the engine differs (the external DspEngine's EQ instead
// of RNNoise). What was taken from G2 verbatim in structure:
//  - loadLibrary try/catch -> nativeLoaded flag (a missing .so never
//    crashes startup; Dart fails open);
//  - lazy nativeInit inside process() (AudioProcessingAdapter.addProcessor
//    does NOT replay initialize() when the processor is registered after
//    the APM already initialized, so relying on initialize() alone would
//    leave the engine uncreated);
//  - single shared processor + `registered` flag (re-adding would EQ
//    every frame twice);
//  - null/exception guards around FlutterWebRTCPlugin.sharedSingleton,
//    audioProcessingController and getLocalTrack;
//  - framesProcessed / lastError diagnostics for the on-device proof.
//
// What is different (DSP-specific):
//  - the native side is DspMicBridge (dsp_mic_bridge.cpp) wrapping the
//    external DspEngine: one mono instance PER BAND (v3 engine: Gate ->
//    Compressor -> EQ -> Echo -> Reverb), EQ on band 0 only;
//  - `setEq`/`setEcho`/`setReverb`/`setNoiseGate`/`setCompressor`
//    channel methods so the RJ panel can retune the voice live;
//  - the bridge accepts BOTH float32 (primary, G2's contract) and int16
//    buffer layouts, chosen by capacity, with a float sanity check —
//    because the layout is not proven on-device yet (see
//    dsp_mic_bridge.h). The first-frame log below (bands/frames/
//    capacity) is the on-device evidence that settles it.
//  - the external engine's own plugin (com.arenahub.app.dsp.AudioDspPlugin,
//    channel com.arenahub.app/audio_dsp) is untouched: it stays the
//    control-plane API for the music (stereo) instance. This class is
//    the MIC path only.

/** The WebRTC APM frame hook. One instance, shared across init/destroy. */
internal class DspMicAudioProcessor : AudioProcessingAdapter.ExternalAudioFrameProcessing {
    companion object {
        private const val TAG = "DspMic"
    }

    @Volatile
    private var bypass = false

    // Last format the APM reported; used for the lazy init below.
    // Defaults are the common case (48 kHz mono), so lazy init works
    // even if initialize() never fires at all.
    @Volatile
    private var lastSampleRateHz = 48000

    @Volatile
    private var lastNumChannels = 1

    @Volatile
    private var nativeInitDone = false

    // One-time layout log: the on-device evidence for the buffer format.
    @Volatile
    private var layoutLogged = false

    fun setBypass(bypass: Boolean) {
        this.bypass = bypass
    }

    fun isBypassed(): Boolean = bypass

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        lastSampleRateHz = sampleRateHz
        lastNumChannels = numChannels
        if (DspMicProcessor.nativeLoaded) {
            try {
                nativeInitDone =
                    DspMicProcessor.nativeInit(sampleRateHz, numChannels)
            } catch (_: Throwable) {
                nativeInitDone = false
            }
            Log.i(TAG, "initialize rate=$sampleRateHz ch=$numChannels ok=$nativeInitDone")
        }
    }

    override fun reset(newRate: Int) {
        lastSampleRateHz = newRate
        if (DspMicProcessor.nativeLoaded) {
            try {
                nativeInitDone =
                    DspMicProcessor.nativeInit(newRate, lastNumChannels)
            } catch (_: Throwable) {
                nativeInitDone = false
            }
        }
    }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer?) {
        if (buffer == null || bypass) return
        if (!DspMicProcessor.nativeLoaded) return
        if (!nativeInitDone) {
            // initialize() was never called — this happens when the
            // processor is registered after the APM already initialized
            // (AudioProcessingAdapter.addProcessor does not replay
            // initialize()). Lazy-init with the last known format (G2's
            // pattern — without this the engine would silently never
            // exist).
            try {
                nativeInitDone = DspMicProcessor.nativeInit(
                    lastSampleRateHz,
                    lastNumChannels,
                )
            } catch (_: Throwable) {
                nativeInitDone = false
            }
            if (!nativeInitDone) return
        }
        if (!layoutLogged) {
            layoutLogged = true
            // Capacity settles the float32-vs-int16 question on-device:
            // float32 = numBands*numFrames*4, int16 = numBands*numFrames*2
            // (at 48 kHz mono: 1920 vs 960 bytes for 3 bands x 160).
            Log.i(
                TAG,
                "first frame: bands=$numBands frames=$numFrames " +
                    "capacity=${buffer.capacity()} remaining=${buffer.remaining()} " +
                    "rate=$lastSampleRateHz ch=$lastNumChannels"
            )
        }
        try {
            DspMicProcessor.nativeProcess(buffer, numBands, numFrames)
        } catch (_: Throwable) {
            // Never let a processing failure break the call: the frame
            // just passes through unprocessed.
        }
    }
}

/** MethodChannel handler for `arena_hub_dsp_mic`. Registered once from MainActivity. */
class DspMicProcessor private constructor() : MethodChannel.MethodCallHandler {
    companion object {
        private const val TAG = "DspMic"
        const val CHANNEL_NAME = "arena_hub_dsp_mic"

        /**
         * True when libaudio_dsp.so loaded. False on builds without the
         * native lib (e.g. an APK built before the CMake wiring) — the
         * Dart side then fails open to unprocessed mic audio.
         */
        @JvmStatic
        var nativeLoaded = false
            private set

        /**
         * FIX 22 item 8 — the native load failure, when
         * System.loadLibrary threw (e.g. UnsatisfiedLinkError with
         * the missing symbol). Null when the .so loaded. Dart reads
         * it via the `nativeLoadError` channel method for Voice
         * diagnostics — the user never needs logcat to see why DSP
         * is unavailable.
         */
        @JvmStatic
        var nativeLoadError: String? = null
            private set

        init {
            try {
                System.loadLibrary("audio_dsp")
                nativeLoaded = true
            } catch (e: Throwable) {
                // A missing native lib must never crash app startup.
                Log.w(TAG, "libaudio_dsp.so not available; DSP mic disabled", e)
                nativeLoaded = false
                nativeLoadError = e.message ?: e.toString()
            }
        }

        @Volatile
        private var instance: DspMicProcessor? = null

        /**
         * The messenger the channel is currently bound to. The
         * singleton instance SURVIVES a normal app relaunch (the
         * process stays alive — only a force-stop kills it), but
         * the FlutterEngine — and its messenger — is recreated.
         * Comparing by identity tells a re-attach to the SAME
         * engine (no-op) from a NEW engine (must re-bind).
         */
        @Volatile
        private var boundMessenger: BinaryMessenger? = null

        /**
         * Registers the channel. Idempotent for the same engine;
         * RE-BINDS when the engine is recreated.
         *
         * FIX 22 item 6 — the "RJ panel opens once per
         * force-stop" bug: this used to be a one-shot singleton
         * — once `instance` existed, register() did nothing. On
         * a normal relaunch in the surviving process the channel
         * stayed bound to the DEAD engine's messenger, so the new
         * isolate's `isAvailable` pings hit an unregistered
         * channel (MissingPluginException), the Dart probe
         * returned false, voiceDsp stayed null, and the RJ panel
         * never opened. Only a force-stop (process death) reset
         * the singleton. Now every new engine gets its channel
         * bound, and the stale WebRTC hook flag is reset — the
         * old controller died with the old engine, so the next
         * init() must re-hook (otherwise init() early-returns
         * success without processing a single frame).
         */
        @JvmStatic
        fun register(messenger: BinaryMessenger) {
            val existing = instance
            if (existing == null) {
                synchronized(this) {
                    if (instance == null) {
                        val created = DspMicProcessor()
                        MethodChannel(messenger, CHANNEL_NAME)
                            .setMethodCallHandler(created)
                        instance = created
                        boundMessenger = messenger
                        Log.i(TAG, "registered (nativeLoaded=$nativeLoaded)")
                    }
                }
            } else if (boundMessenger !== messenger) {
                // New engine in the same process: re-bind the
                // channel to the new messenger and drop the stale
                // hook state (the old WebRTC controller is gone).
                MethodChannel(messenger, CHANNEL_NAME)
                    .setMethodCallHandler(existing)
                boundMessenger = messenger
                existing.onEngineRebound()
                Log.i(TAG, "re-bound channel to new engine messenger")
            }
            // Same engine re-attaching: nothing to do.
        }

        // ---- JNI (dsp_mic_jni.cpp). Guarded by nativeLoaded at every call site. ----
        @JvmStatic
        external fun nativeInit(sampleRateHz: Int, numChannels: Int): Boolean

        @JvmStatic
        external fun nativeProcess(
            buffer: ByteBuffer,
            numBands: Int,
            numFrames: Int
        ): Boolean

        @JvmStatic
        external fun nativeSetEq(
            enabled: Boolean,
            bassDb: Float,
            lowDb: Float,
            midDb: Float,
            highDb: Float
        )

        @JvmStatic
        external fun nativeSetEcho(
            enabled: Boolean,
            delayMs: Float,
            feedback: Float,
            mix: Float
        )

        @JvmStatic
        external fun nativeSetReverb(
            enabled: Boolean,
            wetDryMix: Float,
            roomSize: Float,
            damping: Float
        )

        @JvmStatic
        external fun nativeSetNoiseGate(
            enabled: Boolean,
            thresholdDb: Float,
            attackMs: Float,
            releaseMs: Float
        )

        @JvmStatic
        external fun nativeSetCompressor(
            enabled: Boolean,
            thresholdDb: Float,
            ratio: Float,
            attackMs: Float,
            releaseMs: Float,
            makeupGainDb: Float
        )

        @JvmStatic
        external fun nativeSetBypass(bypass: Boolean)

        @JvmStatic
        external fun nativeRelease()

        @JvmStatic
        external fun nativeGetFramesProcessed(): Long

        @JvmStatic
        external fun nativeGetLastError(): Int

        // ---- Soundboard (route A, SOUNDBOARD_INTEGRATION.md §3) ----
        @JvmStatic
        external fun nativeLoadSoundboardClip(samples: FloatArray, sampleRate: Int): Boolean

        @JvmStatic
        external fun nativePlaySoundboardClip(gain: Float)

        @JvmStatic
        external fun nativeStopSoundboardClip()

        @JvmStatic
        external fun nativeSetSoundboardClipGain(gain: Float)
    }

    private val audioProcessor = DspMicAudioProcessor()

    @Volatile
    private var registered = false

    /**
     * Called when the channel is re-bound to a new engine's
     * messenger (FIX 22 item 6): the old WebRTC controller died
     * with the old engine, so the hook flag must reset —
     * otherwise the next init() early-returns `success(true)`
     * without hooking the processor to the new controller, and
     * the DSP chain silently processes nothing. The native engine
     * itself needs no reset: initialize()/reset()/lazy-init
     * always call nativeInit again on the new track.
     */
    private fun onEngineRebound() {
        registered = false
        Log.i(TAG, "engine rebound: hook state reset")
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(nativeLoaded)
            // FIX 22 item 8: the native load error (null when the
            // .so loaded) — surfaced in Voice diagnostics.
            "nativeLoadError" -> result.success(nativeLoadError)
            "init" -> {
                val trackId = call.argument<String>("trackId")
                if (trackId == null) {
                    result.error("INVALID_ARGUMENT", "trackId is required", null)
                } else {
                    init(trackId, result)
                }
            }
            "restart" -> {
                val trackId = call.argument<String>("trackId")
                if (trackId == null) {
                    result.error("INVALID_ARGUMENT", "trackId is required", null)
                } else {
                    destroy()
                    init(trackId, result)
                }
            }
            "destroy" -> {
                destroy()
                result.success(null)
            }
            "onPublish" -> result.success(null) // DSP needs no auth / room context.
            "onUnpublish" -> result.success(null)
            "setBypass" -> {
                val bypass = call.argument<Boolean>("bypass")
                if (bypass == null) {
                    result.error("INVALID_ARGUMENT", "bypass is required", null)
                } else {
                    audioProcessor.setBypass(bypass)
                    if (nativeLoaded) {
                        try {
                            nativeSetBypass(bypass)
                        } catch (_: Throwable) {
                        }
                    }
                    result.success(true)
                }
            }
            "setEq" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val bass = (call.argument<Double>("bassDb") ?: 0.0).toFloat()
                val low = (call.argument<Double>("lowDb") ?: 0.0).toFloat()
                val mid = (call.argument<Double>("midDb") ?: 0.0).toFloat()
                val high = (call.argument<Double>("highDb") ?: 0.0).toFloat()
                // Works before init too: the bridge stores the preset
                // and applies it when the engine is created.
                if (nativeLoaded) {
                    try {
                        nativeSetEq(enabled, bass, low, mid, high)
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            // RJ STUDIO live setters: same fail-open pattern as setEq.
            // Each one only stores a pending preset in the bridge — the
            // next mic frame applies it, so the host hears the change
            // while speaking, with no re-publish and no voice restart.
            // Arg keys mirror the AudioDsp plugin (minus `handle`: the
            // mic path owns its engines, Dart holds no handle).
            "setEcho" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val delay = (call.argument<Double>("delayMs") ?: 250.0).toFloat()
                val feedback = (call.argument<Double>("feedback") ?: 0.35).toFloat()
                val mix = (call.argument<Double>("mix") ?: 0.35).toFloat()
                if (nativeLoaded) {
                    try {
                        nativeSetEcho(enabled, delay, feedback, mix)
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            "setReverb" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val mix = (call.argument<Double>("wetDryMix") ?: 0.3).toFloat()
                val room = (call.argument<Double>("roomSize") ?: 0.5).toFloat()
                val damping = (call.argument<Double>("damping") ?: 0.5).toFloat()
                if (nativeLoaded) {
                    try {
                        nativeSetReverb(enabled, mix, room, damping)
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            "setNoiseGate" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val threshold = (call.argument<Double>("thresholdDb") ?: -40.0).toFloat()
                val attack = (call.argument<Double>("attackMs") ?: 5.0).toFloat()
                val release = (call.argument<Double>("releaseMs") ?: 120.0).toFloat()
                if (nativeLoaded) {
                    try {
                        nativeSetNoiseGate(enabled, threshold, attack, release)
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            "setCompressor" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val threshold = (call.argument<Double>("thresholdDb") ?: -18.0).toFloat()
                val ratio = (call.argument<Double>("ratio") ?: 4.0).toFloat()
                val attack = (call.argument<Double>("attackMs") ?: 10.0).toFloat()
                val release = (call.argument<Double>("releaseMs") ?: 100.0).toFloat()
                val makeup = (call.argument<Double>("makeupGainDb") ?: 0.0).toFloat()
                if (nativeLoaded) {
                    try {
                        nativeSetCompressor(enabled, threshold, ratio, attack, release, makeup)
                    } catch (_: Throwable) {
                    }
                }
                result.success(null)
            }
            // ---- Soundboard (route A, SOUNDBOARD_INTEGRATION.md §3) ----
            "loadSoundboardClip" -> {
                val samples = call.argument<FloatArray>("samples")
                val rate = call.argument<Int>("sampleRate") ?: 48000
                if (samples == null) {
                    result.error("INVALID_ARGUMENT", "samples is required", null)
                } else if (!nativeLoaded) {
                    result.success(false)
                } else {
                    try {
                        result.success(nativeLoadSoundboardClip(samples, rate))
                    } catch (_: Throwable) {
                        result.success(false)
                    }
                }
            }
            "playSoundboardClip" -> {
                val gain = (call.argument<Double>("gain") ?: 1.0).toFloat()
                if (nativeLoaded) {
                    try { nativePlaySoundboardClip(gain) } catch (_: Throwable) {}
                }
                result.success(null)
            }
            "stopSoundboardClip" -> {
                if (nativeLoaded) {
                    try { nativeStopSoundboardClip() } catch (_: Throwable) {}
                }
                result.success(null)
            }
            "setSoundboardClipGain" -> {
                val gain = (call.argument<Double>("gain") ?: 1.0).toFloat()
                if (nativeLoaded) {
                    try { nativeSetSoundboardClipGain(gain) } catch (_: Throwable) {}
                }
                result.success(null)
            }
            "lastError" -> {
                result.success(if (nativeLoaded) nativeGetLastError() else -1)
            }
            "framesProcessed" -> {
                result.success(if (nativeLoaded) nativeGetFramesProcessed() else -1L)
            }
            else -> result.notImplemented()
        }
    }

    private fun init(trackId: String, result: MethodChannel.Result) {
        if (registered) {
            // Already hooked; re-adding the same instance would process
            // every frame twice.
            result.success(true)
            return
        }
        val plugin = FlutterWebRTCPlugin.sharedSingleton
        if (plugin == null) {
            result.error("WEBRTC_NOT_READY", "FlutterWebRTCPlugin not initialized", null)
            return
        }
        val track = try {
            plugin.getLocalTrack(trackId)
        } catch (_: Exception) {
            null
        }
        if (track == null || track !is LocalAudioTrack) {
            result.error("INVALID_ARGUMENT", "track is not a LocalAudioTrack", null)
            return
        }
        // The controller is created when the first PeerConnectionFactory
        // is built; it can still be null if init races factory setup.
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
            controller.capturePostProcessing.addProcessor(audioProcessor)
        } catch (e: Throwable) {
            Log.w(TAG, "addProcessor failed", e)
            result.error("ATTACH_FAILED", "capturePostProcessing.addProcessor failed", null)
            return
        }
        registered = true
        Log.i(TAG, "init: hooked track=$trackId")
        result.success(true)
    }

    private fun destroy() {
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
        if (nativeLoaded) {
            try {
                nativeRelease()
            } catch (_: Throwable) {
            }
        }
        Log.i(TAG, "destroy: unhooked")
    }
}
