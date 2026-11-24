// GROUP 7 DSP — AUDIO #10: JNI-free mic bridge for the external DspEngine.
//
// Architecture mirrors Group 2's proven rnnoise_bridge (same hook, different
// engine): all the logic lives here, JNI-free, so it is host-testable; the
// JNI wrapper (dsp_mic_jni.cpp) is a thin pass-through, and the Kotlin side
// (DspMicProcessor.kt) is a close copy of G2's RnnoiseProcessor.kt.
//
// WHAT IT DOES — RJ STUDIO EVOLUTION (2026-11-22)
// ------------------------------------------------
// WebRTC's APM hands the capture post-processing hook SPLIT-BAND audio —
// 1-3 bands x N samples, planar, band-major; each band is 10 ms. The
// primary contract (taken from Group 2's proven bridge, which takes it from
// the WebRTC ExternalAudioProcessing contract and the Krisp plugin's
// identical usage) is float32. Because that layout is NOT proven on-device
// here, processBuffer() also accepts the int16 layout as a FALLBACK,
// chosen by capacity (see processBuffer). The float sanity check (below)
// is a second line of defence against misrouting.
//
// SPLIT-BAND vs FULL-BAND — the design decision (evidence, not a guess):
//   * WebRTC's AudioBuffer splits by capture rate: 8/16 kHz -> 1 band,
//     32 kHz -> 2 bands, 48 kHz -> 3 bands (kMaxNumBands = 3, each band
//     160 samples = 10 ms at an effective 16 kHz). The common Android
//     capture rate is 48 kHz, so the COMMON mic case is numBands == 3
//     (split-band), NOT numBands == 1. G2's rnnoise_bridge.h states the
//     same contract and processes every band for exactly this reason.
//   * numBands == 1 (16 kHz capture) IS full-band: one engine at the full
//     capture rate runs the whole chain on the whole frame via a single
//     processPcm16() call — the simplest case, and the one the RJ panel
//     would see on a 16 kHz device.
//   * numBands > 1 CANNOT be run through one engine as a single stream:
//     the bands are decimated subband signals, and re-merging them needs
//     WebRTC's QMF synthesis filterbank, which is not reachable from the
//     hook. Re-implementing analysis+synthesis ourselves would add a
//     second lossy pass through a filterbank — G2 explicitly rejected
//     that for RNNoise ("avoids a second pass through WebRTC's lossy
//     analysis/synthesis filterbank"), and the same reasoning holds here.
//   * So split-band frames run PER-BAND FULL-CHAIN: ONE DspEngine per
//     band (state — echo delay lines, reverb combs, EQ biquads, gate
//     envelope — must never be shared across bands), each configured at
//     the band's effective 16 kHz rate. The engine is rate-parameterised,
//     so the same TIME parameters (delayMs, roomSize, attack/release)
//     give the same temporal behaviour in every band.
//   * Echo and reverb are delay networks (LTI-ish): with the same time
//     delay in every band, the per-band tails sum through QMF synthesis
//     to (approximately) the full-band echo/reverb. That is what makes
//     per-band processing SOUND RIGHT for these two stages — and it is
//     also what WebRTC's own noise suppressor does (it operates on the
//     split bands, per G2's notes).
//   * EQ stays BAND-0-ONLY, deliberately: EQ is frequency-selective, and
//     its coefficients would land at the wrong frequencies in a decimated
//     band (the 1 kHz peaking filter would not peak at 1 kHz in band 1).
//     All four EQ bands (80 Hz low-shelf, 200 Hz low-shelf, 1000 Hz
//     peaking, 4000 Hz high-shelf) live inside 0-8 kHz anyway, so bands
//     1-2 run with EQ disabled (true bypass — the engine memcpys when
//     every stage is off, so a flat-EQ band costs nothing).
//   * Noise gate runs PER BAND on its own level (each band's engine has
//     its own gate). Honest caveat: the bands can open/close at slightly
//     different instants on HF-only transients. In practice speech opens
//     band 0 and silence closes all bands together; gating band 0 alone
//     would leak HF noise during silence, which is worse. A single shared
//     gate decision would need engine changes (out of scope — the engine
//     is untouched).
//
// Mic preset, applied at init: EQ on (with the pending preset Dart sent,
// flat until then), echo, reverb, noise gate and compressor OFF — the host
// enables them LIVE from the RJ panel (setEcho/setReverb/setNoiseGate/
// setCompressor), never by re-publish. Disabled stages are TRUE BYPASS
// in dsp_engine.cpp (gate, compressor, reverb, echo, EQ each return before
// touching the buffer; all-stages-disabled is a memcpy passthrough) —
// verified by host execution, see MIC_DSP_ROUTING.md.
//
// LIVE PARAM CONTRACT (RJ Studio): setEq/setEcho/setReverb/setNoiseGate/
// setCompressor only STORE a pending preset (platform thread); process() applies it on
// the audio thread. Param changes NEVER touch the TrackProcessor or the
// mic track — no re-publish, no voice restart. Only install/remove
// (setProcessor) and NC on/off re-publish (see mic_audio_pipeline.dart).
//
// FLOAT SANITY CHECK
// ------------------
// On the float path, until the format is confirmed, each frame's band-0
// samples are scanned: real float32 audio lives in [-1, 1]; int16 bytes
// misread as float are almost always huge, NaN, or denormal (~1e-41).
// Any |x| > 4 or NaN, or denormals OUTNUMBERING plausible samples,
// latches kBridgeBadFormat and the bridge stops processing (fail open)
// until re-init. Real mic audio is never denormal — even room noise is
// ~1e-5 — so this cannot false-trigger on a genuine float buffer, and
// a lone denormal among real speech does not fail the check.
// Silence (all exact 0.0) is inconclusive and passes through untouched
// either way, so it neither confirms nor fails the check.
//
// THREADING
// ---------
// processBuffer() runs on WebRTC's real-time audio thread; the setters
// run on the platform thread. Each engine serializes itself with its own
// mutex; the bridge guards its own small state (pending params, bypass,
// format flags) with mutex_ and only holds it briefly — never across
// processPcm16(). The setters only STORE a pending preset; process()
// applies it on the audio thread, which is what makes setEq-before-init
// (Dart sends the preset at initialize(), the engine is created lazily
// on the first frame) work.

#ifndef ARENA_HUB_DSP_MIC_BRIDGE_H
#define ARENA_HUB_DSP_MIC_BRIDGE_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include "dsp_engine.h"

namespace arena_dsp {

// Error codes surfaced to Dart via lastError(). 0 = ok. Mirror of G2's
// RnnoiseBridge codes, extended with kBridgeBadFormat (6).
enum DspMicBridgeError {
    kDspMicOk = 0,
    kDspMicNotInitialized = 1,
    kDspMicBadFrameSize = 2,
    kDspMicBadBandCount = 3,
    kDspMicUnsupportedChannels = 4,
    kDspMicBadBuffer = 5,
    kDspMicBadFormat = 6,
};

class DspMicBridge {
public:
    static constexpr int kMaxBands = 3;
    static constexpr int kMaxFrames = 1024;

    DspMicBridge() = default;
    ~DspMicBridge();

    // Non-copyable (owns the engines).
    DspMicBridge(const DspMicBridge&) = delete;
    DspMicBridge& operator=(const DspMicBridge&) = delete;

    // Creates ONE mono engine per band (kMaxBands engines; engine 0 at
    // the full capture rate, engines 1-2 at 16 kHz — the split-band
    // effective rate). Accepts mono only and rates 16/32/48 kHz only
    // (same validation as G2's bridge). Applies the mic preset: EQ on
    // (pending preset, flat if none sent yet), echo/reverb/gate OFF.
    // Safe to call twice: releases the previous engines first.
    bool init(int sampleRateHz, int numChannels);

    // Releases all engines. Safe to call when not initialized.
    void release();

    bool isInitialized() const { return engines_[0] != nullptr; }

    // Routes ONE 10 ms APM frame through the engines, in place.
    // `data` is the direct ByteBuffer's address, `capacityBytes` its
    // capacity; the layout is chosen by capacity:
    //   capacity >= numBands*numFrames*4  -> float32 (primary, G2 contract)
    //   capacity >= numBands*numFrames*2  -> int16   (fallback)
    //   otherwise                         -> fail open, kDspMicBadBuffer
    // numBands == 1: engine 0 runs the FULL chain on the whole frame.
    // numBands > 1: each band runs through its own engine (band 0 with
    // EQ, bands 1-2 with EQ disabled — see the header design note).
    // Returns false (and touches nothing) on any anomaly.
    bool processBuffer(uint8_t* data, size_t capacityBytes,
                       int numBands, int numFrames);

    // Direct entry points (used by processBuffer; exposed for host tests).
    bool processFloat(float* bands, int numBands, int numFrames);
    bool processPcm16(uint8_t* bytes, int numBands, int numFrames);

    // Parameter setters. Stored as a pending preset and applied on the
    // audio thread inside process(), so they work before init() too
    // (Dart sends the voice preset at initialize(); the engines are
    // created lazily on the first frame) AND live while speaking
    // (the RJ panel sliders — no re-publish, no restart).
    void setEq(bool enabled, float bassBoostDb, float lowGainDb,
               float midGainDb, float highGainDb);
    void setEcho(bool enabled, float delayMs, float feedback, float mix);
    void setReverb(bool enabled, float wetDryMix, float roomSize,
                   float damping);
    void setNoiseGate(bool enabled, float thresholdDb, float attackMs,
                      float releaseMs);
    void setCompressor(bool enabled, float thresholdDb, float ratio,
                       float attackMs, float releaseMs,
                       float makeupGainDb);

    // Bypass: frames pass through untouched (and are NOT counted as
    // processed — same convention as G2, so framesProcessed() growing
    // proves frames are actually being processed).
    void setBypass(bool bypass);
    bool bypass() const { return bypass_; }

    // SOUNDBOARD (route A — native-side mixing, 2026-11-22). The live
    // mic path is native-only (Dart never sees mic frames), so the
    // soundboard clip is mixed HERE, after the DSP chain — not in
    // Dart's Soundboard.mixInto (which stays as the Dart-side/test
    // API). Full design + evidence: SOUNDBOARD_INTEGRATION.md §3.
    //
    // WHY BAND 0 ONLY: the common 48 kHz case hands the hook SPLIT
    // bands (3 x 160 @ 16 kHz effective). A full-band 48 kHz clip
    // cannot be mixed into decimated subbands without WebRTC's QMF
    // analysis filterbank (not reachable from the hook). The clip is
    // therefore decimated to 16 kHz at load (anti-alias FIR) and
    // mixed into band 0 (0-8 kHz) — correct for band 0's content,
    // the clip's 8-24 kHz content is lost (it sounds slightly
    // duller, like a phone call). In the numBands == 1 full-band
    // case the clip variant matches the band-0 rate: 16 kHz capture
    // uses the 16 kHz clip, 48 kHz uses the 48 kHz original. A
    // 1-band 32 kHz frame (synthetic only — real 32 kHz capture is
    // always split into 2 bands) gets no mix that frame.
    //
    // The mix runs AFTER the DSP chain (the SFX stays dry: no EQ /
    // echo / reverb / gate on it). Bypassed frames do NOT get the
    // clip: Kotlin short-circuits process() before nativeProcess is
    // ever called while bypassed, so a playing clip PAUSES while
    // bypass is on (its playhead does not advance) and RESUMES when
    // bypass lifts — the clip is never lost to a bypass toggle.
    // (The bridge-level bypass branch likewise returns before the
    // mix; see SOUNDBOARD_INTEGRATION.md §3 for the alternative.)
    //
    // THREADING: loadClip/playClip/stopClip/setClipGain run on the
    // platform thread (via JNI); the mix runs on WebRTC's audio
    // thread. The clip buffer is a shared_ptr swapped under mutex_;
    // the audio thread snapshots it when a play request is applied
    // and mixes lock-free from the snapshot. Play/stop/gain requests
    // cross via pending flags under mutex_ (same pattern as the
    // pending param preset); the playhead and the active flag live
    // ONLY on the audio thread, so a play/stop lands within one
    // 10 ms frame.

    // Loads a soundboard clip for later playback. `samples48k` is mono
    // float32 at 48 kHz (the decoder's output); the bridge keeps the
    // 48 kHz original AND a 16 kHz decimated copy (anti-alias FIR).
    // Only 48 kHz input is accepted (false otherwise); empty clips
    // are rejected. Implicitly stops any clip currently playing.
    // Safe to call before init() (the clip waits; mixing starts on
    // the first frame after init).
    bool loadClip(const float* samples48k, size_t numSamples,
                  int sampleRateHz);

    // Starts playing the loaded clip from the beginning into the live
    // mix (band 0, after DSP). `gain` is 0..1 (pad x master volume,
    // computed in Dart). No-op when no clip is loaded. Restarts the
    // playhead when a clip is already playing.
    void playClip(float gain);

    // Stops the currently playing clip immediately (the mic passes
    // through untouched from the next frame). No-op when idle.
    void stopClip();

    // Live gain for the playing clip (0..1). Applies on the next
    // frame; no-op when idle.
    void setClipGain(float gain);

    // True while a clip is being mixed. Audio-thread state: lags a
    // play/stop request by at most one 10 ms frame.
    bool isClipPlaying() const { return clipActiveFlag_; }

    // Samples in the loaded 16 kHz clip (0 when none loaded). The
    // 48 kHz original is ~3x this. Non-const: locks mutex_.
    size_t clipLength16k();

    long framesProcessed() const { return framesProcessed_; }
    int lastError() const { return lastError_; }

    // Which layout the last processBuffer() call took (0 = none yet,
    // 4 = float32, 2 = int16). Exposed for host tests + diagnostics.
    int lastFormatBytesPerSample() const { return lastFormatBytes_; }

    // Sample rate engine 0 is currently configured at (16 kHz for
    // band 0 when split, full rate when numBands == 1). Host tests.
    int engineSampleRate() const { return engineRate_; }

    // Sample rate the engine for `band` is configured at (band 0:
    // engineSampleRate(); bands 1-2: always 16 kHz when initialized).
    // Returns 0 when not initialized or for an out-of-range band.
    int engineSampleRateForBand(int band) const {
        if (!isInitialized() || band < 0 || band >= kMaxBands) return 0;
        return band == 0 ? engineRate_ : 16000;
    }

private:
    // Reconfigures engine 0 for band 0's effective rate when the band
    // layout changes (split <-> full-band). No-op when unchanged.
    // Engines 1-2 are always 16 kHz (they only run when split).
    void ensureEngineRates(int numBands);

    // Applies the pending EQ/echo/reverb/gate/compressor preset to ALL engines
    // (audio thread only, called from process). EQ goes to engine 0
    // only — engines 1-2 get EQ disabled (see the header design note).
    // Also recomputes bandBypass_[] (below). No-op when nothing is
    // pending.
    void applyPendingParams();

    // Float sanity check (see header comment). Returns false and latches
    // kDspMicBadFormat when band 0 cannot be float32 audio. Once the
    // format is confirmed, returns true immediately.
    bool checkFloatSanity(const float* band0, int numFrames);

    // Soundboard clip (route A). The two clip variants live in one
    // immutable struct behind a shared_ptr so the audio thread can
    // snapshot it once per play request and mix lock-free.
    struct ClipData {
        std::vector<float> samples48k;  // original, as loaded
        std::vector<float> samples16k;  // decimated 3:1, anti-alias FIR
    };

    // Applies pending clip requests (platform thread -> audio thread).
    // Called at the top of every mix step.
    void applyPendingClipRequests();

    // Mixes the active clip into band 0 AFTER the DSP chain.
    // `band0RateHz` is band 0's effective rate for this frame
    // (16000 when split, the full capture rate when numBands == 1);
    // it selects the clip variant (16 kHz / 48 kHz). A rate with no
    // variant (1-band 32 kHz, synthetic only — real 32 kHz capture
    // is always split into 2 bands) mixes nothing and the playhead
    // does not advance that frame. When the clip ends mid-frame, the
    // remaining band-0 samples pass through untouched. Gain 0
    // advances the playhead without touching the buffer.
    void mixClipIntoBand0Float(float* band0, int numFrames,
                               int band0RateHz);
    void mixClipIntoBand0Pcm16(uint8_t* band0Bytes, int numFrames,
                               int band0RateHz);

    // Resolves the clip variant + mix window for one frame (shared by
    // the float and int16 mixers). Applies pending requests first.
    // Returns false when there is nothing to mix (idle, no variant
    // for this rate, or the clip already ended — the finished state
    // is applied here). On true, `*clipOut` is the variant to mix,
    // `*posOut` its start sample, `*mixCountOut` how many samples to
    // mix (<= numFrames), and `*rateRatioOut` is 3 (16 kHz variant)
    // or 1 (48 kHz variant) — needed to advance the playhead in
    // 48k-sample units.
    bool clipMixWindow(int band0RateHz, int numFrames,
                       const std::vector<float>** clipOut, size_t* posOut,
                       size_t* mixCountOut, int* rateRatioOut);

    // Advances the 48k-unit playhead after a mix step and finishes
    // the clip when the window reached its end.
    void advanceClipPlayhead(size_t pos, size_t mixCount, size_t clipLen,
                             int rateRatio);

    // Clears the audio-thread clip state (clip finished or stopped).
    void finishClip() {
        clipActiveFlag_ = false;
        clipActive_.reset();
        clipPlayhead48k_ = 0;
    }

    // Band 0's effective rate for a frame layout: 16 kHz when split
    // (each band is decimated), the full capture rate when not.
    int band0RateFor(int numBands) const {
        return numBands > 1 ? 16000 : sampleRateHz_;
    }

    // One engine per band — state (echo delay lines, reverb combs, EQ
    // biquads, gate envelope) must never be shared across bands.
    arena_dsp::DspEngine* engines_[kMaxBands] = {nullptr, nullptr, nullptr};

    int sampleRateHz_ = 0;
    int engineRate_ = 0;  // rate engine 0 is configured at

    // Pending parameter preset (set from the platform thread, applied
    // on the audio thread).
    std::mutex mutex_;
    bool eqEnabled_ = true;
    float eqBassDb_ = 0.0f;
    float eqLowDb_ = 0.0f;
    float eqMidDb_ = 0.0f;
    float eqHighDb_ = 0.0f;
    bool echoEnabled_ = false;
    float echoDelayMs_ = 250.0f;
    float echoFeedback_ = 0.35f;
    float echoMix_ = 0.35f;
    bool reverbEnabled_ = false;
    float reverbMix_ = 0.3f;
    float reverbRoom_ = 0.5f;
    float reverbDamping_ = 0.5f;
    bool gateEnabled_ = false;
    float gateThresholdDb_ = -40.0f;
    float gateAttackMs_ = 5.0f;
    float gateReleaseMs_ = 120.0f;
    bool compEnabled_ = false;
    float compThresholdDb_ = -18.0f;
    float compRatio_ = 4.0f;
    float compAttackMs_ = 10.0f;
    float compReleaseMs_ = 100.0f;
    float compMakeupDb_ = 0.0f;
    bool paramsDirty_ = true;  // apply the mic preset on first frame

    // Per-band skip flags, recomputed by applyPendingParams() from the
    // preset (audio thread only — no mutex needed). A band whose every
    // stage is disabled is SKIPPED outright: on the float path that
    // keeps it BIT-IDENTICAL (no int16 round-trip — the round-trip
    // alone costs up to ~2 LSB), and on both paths it saves the engine
    // call. Defaults match the default preset (EQ on, rest off):
    // band 0 processes, bands 1-2 skip.
    bool bandBypass_[kMaxBands] = {false, true, true};

    bool bypass_ = false;
    bool formatConfirmed_ = false;
    bool formatBad_ = false;
    int lastFormatBytes_ = 0;

    // Soundboard clip state (route A). clipData_ is swapped under
    // mutex_ by loadClip(); the request flags cross under mutex_;
    // the snapshot, playhead, gain and active flag live ONLY on the
    // audio thread (applied by applyPendingClipRequests()).
    std::shared_ptr<const ClipData> clipData_;  // guarded by mutex_
    bool clipPlayRequested_ = false;            // guarded by mutex_
    bool clipStopRequested_ = false;            // guarded by mutex_
    bool clipGainPending_ = false;              // guarded by mutex_
    float clipPendingGain_ = 0.0f;              // guarded by mutex_
    std::shared_ptr<const ClipData> clipActive_;  // audio thread only
    size_t clipPlayhead48k_ = 0;  // audio thread only, 48k-sample units
    float clipGain_ = 0.0f;       // audio thread only
    bool clipActiveFlag_ = false;  // audio thread only

    long framesProcessed_ = 0;
    int lastError_ = kDspMicOk;

    // Scratch for the float path: one band as int16 (engine input/output).
    std::vector<int16_t> pcm16Scratch_;
};

}  // namespace arena_dsp

#endif  // ARENA_HUB_DSP_MIC_BRIDGE_H
