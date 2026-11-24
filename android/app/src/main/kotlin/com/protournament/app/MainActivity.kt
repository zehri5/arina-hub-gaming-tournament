package com.protournament.app

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // ARENA HUB #10 AUDIO (Groups 4/5/8): one instance per effect
    // group, shared by the single `arena_audio/effects` dispatcher
    // below. ReverbEffect (Group 3) is an object, so it needs no
    // instance. EchoDelayEffect holds no native resources, so it has
    // no release() — only the three below are released on destroy.
    private val echoDelayEffect = EchoDelayEffect()
    private val bassEqEffect = BassEqEffect()
    private val playbackEffectsBridge = PlaybackEffectsBridge()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // BACKGROUND VOICE FIX (2026-10-30): Dart starts/stops the
        // voice foreground service when joining/leaving voice, so
        // the WebRTC session survives the app going to background.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pro_tournament/voice_foreground")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        // Never let a service-start failure (e.g.
                        // Android 12+ background-start rules, or a
                        // missing service type) crash voice join:
                        // Dart already treats this call as
                        // best-effort, and the service itself also
                        // guards its own startForeground call.
                        try {
                            val intent = Intent(this, VoiceForegroundService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                        } catch (_: Exception) {}
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, VoiceForegroundService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // RNNoise mic noise suppression (Arena Hub #10 audio, Group 2):
        // registers the arena_hub_rnnoise MethodChannel. The native side
        // answers only when libarena_rnnoise.so built (see
        // cpp/CMakeLists.txt); otherwise the Dart side fails open to
        // unprocessed mic audio.
        RnnoiseProcessor.register(flutterEngine.dartExecutor.binaryMessenger)
        // DSP mic chain (Arena Hub #10 audio, Group 7 RJ Studio):
        // registers the arena_hub_dsp_mic MethodChannel — the host's
        // live mic chain (Gate -> Compressor -> EQ -> Echo -> Reverb).
        // Different channel from RnnoiseProcessor above; both lines
        // coexist. The native side answers only when libaudio_dsp.so
        // is built (see cpp/CMakeLists.txt); otherwise the Dart side
        // fails open to unprocessed mic audio.
        DspMicProcessor.register(flutterEngine.dartExecutor.binaryMessenger)
        // FIX 24 radio mixer: registers the arena_hub_radio_mixer
        // MethodChannel — the host's background music mixed directly
        // into the live mic stream (capturePostProcessing hook, same
        // pattern as DspMicProcessor above). Pure Kotlin, no native
        // .so — the channel always answers; register() fails open
        // when WebRTC is not ready yet.
        MusicMixProcessor.register(flutterEngine.dartExecutor.binaryMessenger)
        // AudioDspPlugin (Arena Hub #10 audio, v3 DSP engine — the
        // `com.arenahub.app/audio_dsp` channel the playback DSP API
        // uses). An in-app plugin, so the generated registrant does
        // NOT list it — it is registered here, next to the
        // RnnoiseProcessor/DspMicProcessor register() calls.
        // try/catch Throwable (NOT Exception): class-init failures
        // are Errors, and registration must never crash startup —
        // with the DSP_FOLD_NOTES.md §5 fail-soft fix the add()
        // itself no longer throws when the .so is missing (the
        // plugin just answers NATIVE_UNAVAILABLE); this catch is
        // belt-and-braces for any other class-load failure.
        try {
            flutterEngine.plugins.add(com.arenahub.app.dsp.AudioDspPlugin())
        } catch (_: Throwable) {
            // No native DSP on this build (or the plugin class failed to
            // load): the audio_dsp channel stays unregistered and Dart fails
            // open. Never let plugin registration crash app startup.
            android.util.Log.w("MainActivity",
                "AudioDspPlugin unavailable; DSP effects disabled")
        }
        // MusicDspPlugin (Arena Hub #10 audio, music player — the
        // decode -> DSP -> AudioTrack route that replaces
        // audioplayers for music; see MUSIC_PLAYER_INTEGRATION.md).
        // Same in-app-plugin pattern as AudioDspPlugin above: the
        // generated registrant does NOT list it, so it is
        // registered here. try/catch Throwable for the same
        // belt-and-braces reason (this plugin loads no .so itself
        // — it relies on AudioDspPlugin's load via the Dart-side
        // pump — but registration must never crash startup).
        try {
            flutterEngine.plugins.add(com.arenahub.app.dsp.MusicDspPlugin())
        } catch (_: Throwable) {
            android.util.Log.w("MainActivity",
                "MusicDspPlugin unavailable; DSP music player disabled")
        }

        // ARENA HUB #10 AUDIO (Groups 3/4/5/8, merged by Group 9):
        // the SINGLE handler for the shared `arena_audio/effects`
        // channel. A second setMethodCallHandler on the same channel
        // REPLACES the first, so the groups must NOT register their
        // own handlers — this dispatcher routes each method to the
        // group that owns it, following each file's header/KDoc
        // snippet:
        //   setReverb  -> ReverbEffect (object, Group 3)
        //   setEcho / setDelay -> EchoDelayEffect.onMethodCall (G4)
        //   setBass / setEq -> BassEqEffect.handle (Group 5)
        //   attachPlayback / detachPlayback / getSessionInfo ->
        //       PlaybackEffectsBridge.onMethodCall (Group 8)
        // Each group's handler returns false for methods it does not
        // own, so the dispatcher falls through to the next group and
        // answers notImplemented only when nobody owns the method.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arena_audio/effects")
            .setMethodCallHandler { call, result ->
                // Group 3 (ReverbEffect is an object with no
                // onMethodCall — handle setReverb inline, exactly as
                // its KDoc snippet shows).
                if (call.method == "setReverb") {
                    val amount = call.argument<Number>("amount")?.toDouble()
                        ?: (call.arguments as? Number)?.toDouble()
                    if (amount == null) {
                        result.error(
                            "invalid_args",
                            "setReverb expects {'amount': <0.0-1.0>}",
                            null,
                        )
                    } else if (ReverbEffect.setReverb(amount)) {
                        result.success(null)
                    } else {
                        result.error(
                            "reverb_unavailable",
                            "Reverb engine could not run on this device",
                            null,
                        )
                    }
                    return@setMethodCallHandler
                }
                if (echoDelayEffect.onMethodCall(call, result)) {
                    return@setMethodCallHandler
                }
                if (bassEqEffect.handle(call, result)) {
                    return@setMethodCallHandler
                }
                if (playbackEffectsBridge.onMethodCall(call, result)) {
                    return@setMethodCallHandler
                }
                result.notImplemented()
            }
    }

    override fun onDestroy() {
        // ARENA HUB #10 AUDIO: release the native effects when the
        // engine/activity is destroyed. All three release() calls are
        // idempotent and never throw. (EchoDelayEffect is pure Kotlin
        // DSP with no native resources, so it has nothing to release.)
        ReverbEffect.release()
        bassEqEffect.release()
        playbackEffectsBridge.release()
        super.onDestroy()
    }
}
