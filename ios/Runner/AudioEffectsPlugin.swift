// AudioEffectsPlugin.swift
//
// ARENA HUB #10 AUDIO — Group 6: iOS native audio path.
//
// iOS side of the `arena_audio/effects` platform channel — the SAME channel
// name and the SAME five methods as the Android DSP bridge (Groups 3/4/5),
// so the Dart audio-effects services work unchanged on iOS:
//
//   Channel:  arena_audio/effects
//   setReverb  {"amount": Double 0.0-1.0}          (also accepts a bare number)
//   setEcho    {"amount": Double 0.0-1.0}          (also accepts a bare number)
//   setDelay   {"delayMs": Double, milliseconds}   (also accepts a bare number,
//                                                  or {"ms": ...} / {"delay": ...})
//   setBass    {"amount": Double 0.0-1.0}          (also accepts a bare number)
//   setEq      {"band": Int 0-4, "gain": Double dB} (also accepts [band, gain])
//
// The bare-number / alternate-key fallbacks exist because the Dart callers
// (Groups 3/4/5) were written in parallel; the map form above is the
// canonical contract. Out-of-range numbers are clamped, never rejected;
// a completely wrong argument type returns FlutterError INVALID_ARGUMENT.
//
// Native graph (AVAudioEngine, built lazily on first method call):
//
//   input -> AVAudioUnitEQ (5 bands) -> AVAudioUnitDelay (echo)
//         -> AVAudioUnitDelay (delay) -> AVAudioUnitReverb -> mixer -> output
//
// EQ band layout (indices used by setEq):
//   band 0: low shelf,  100 Hz — the bass band (setBass drives this one)
//   band 1: parametric, 400 Hz
//   band 2: parametric, 1600 Hz
//   band 3: parametric, 6400 Hz
//   band 4: high shelf, 12000 Hz
//
// setBass(amount) sets band 0 gain to amount * 12 dB. setEq(band, gain)
// sets that band's gain directly (clamped to +/-24 dB).
// setEcho(amount) uses a fixed 0.25 s echo with feedback scaled by amount.
// setDelay(delayMs) is a single clean repeat (feedback 0) at 50% wet mix.
//
// IMPORTANT — engine is built, NOT started: this plugin applies effect
// parameters to the nodes but deliberately does NOT start the AVAudioEngine
// or touch the audio session. The live voice path is owned by LiveKit
// (Group 7 mic wiring) and playback by Group 8; starting a second engine
// here would fight LiveKit's audio session. The graph is ready for those
// groups to start/route when their wiring lands.
//
// *** UNVERIFIED ON iOS *** — this Linux VM has no Xcode, so this file has
// NEVER been compiled, run, or tested. It needs a Mac build
// (`flutter build ios`) to verify. Do not claim iOS audio works until then.

import AVFoundation
import Flutter

/// iOS host side of the `arena_audio/effects` channel. Keep one instance
/// alive for the app's lifetime (AppDelegate holds a strong reference).
final class AudioEffectsPlugin: NSObject {
  static let channelName = "arena_audio/effects"

  /// Maximum delay time the delay node supports (AVAudioUnitDelay caps at 2 s).
  private static let maxDelayMs: Double = 2000
  /// Bass boost range: amount 0.0-1.0 maps to 0-12 dB on the low-shelf band.
  private static let maxBassGainDb: Float = 12
  /// Sane per-band EQ range (AVAudioUnitEQ allows -96...+24 dB).
  private static let maxEqGainDb: Float = 24
  /// Echo repeat spacing (fixed; only the amount is Dart-controlled).
  private static let echoDelaySeconds: TimeInterval = 0.25
  /// Delay wet/dry mix when a delay time is set (single repeat, 50% wet).
  private static let delayWetDryMix: Float = 50

  private let channel: FlutterMethodChannel
  private let engine = AVAudioEngine()
  private let eq = AVAudioUnitEQ(numberOfBands: 5)
  private let echoDelay = AVAudioUnitDelay()
  private let delayNode = AVAudioUnitDelay()
  private let reverb = AVAudioUnitReverb()
  private var graphSetup = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    // Method-call handlers run on the main thread; AVAudioUnit parameter
    // writes are thread-safe, so no extra dispatch is needed.
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  // MARK: - Method handling

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setReverb":
      guard let amount = doubleArgument(call.arguments, keys: ["amount"]) else {
        return result(invalidArgument(call.method, expected: "amount (number 0.0-1.0)"))
      }
      ensureGraph()
      reverb.wetDryMix = Float(clamp(amount, min: 0, max: 1)) * 100
      result(nil)

    case "setEcho":
      guard let amount = doubleArgument(call.arguments, keys: ["amount"]) else {
        return result(invalidArgument(call.method, expected: "amount (number 0.0-1.0)"))
      }
      ensureGraph()
      let clamped = Float(clamp(amount, min: 0, max: 1))
      echoDelay.delayTime = Self.echoDelaySeconds
      echoDelay.feedback = 60 * clamped
      echoDelay.wetDryMix = 100 * clamped
      result(nil)

    case "setDelay":
      guard let delayMs = doubleArgument(call.arguments, keys: ["delayMs", "ms", "delay"]) else {
        return result(invalidArgument(call.method, expected: "delayMs (number, milliseconds)"))
      }
      ensureGraph()
      let clampedMs = clamp(delayMs, min: 0, max: Self.maxDelayMs)
      delayNode.delayTime = clampedMs / 1000
      delayNode.feedback = 0
      delayNode.wetDryMix = clampedMs > 0 ? Self.delayWetDryMix : 0
      result(nil)

    case "setBass":
      guard let amount = doubleArgument(call.arguments, keys: ["amount"]) else {
        return result(invalidArgument(call.method, expected: "amount (number 0.0-1.0)"))
      }
      ensureGraph()
      eq.bands[0].gain = Float(clamp(amount, min: 0, max: 1)) * Self.maxBassGainDb
      result(nil)

    case "setEq":
      guard let (band, gain) = eqArguments(call.arguments) else {
        return result(
          invalidArgument(call.method, expected: "{\"band\": Int 0-4, \"gain\": Double dB}"))
      }
      guard (0..<eq.bands.count).contains(band) else {
        return result(
          FlutterError(
            code: "INVALID_ARGUMENT",
            message: "setEq band out of range: \(band) (valid 0-\(eq.bands.count - 1))",
            details: nil))
      }
      ensureGraph()
      eq.bands[band].gain = clamp(gain, min: -Self.maxEqGainDb, max: Self.maxEqGainDb)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Engine graph (built lazily, never started here)

  private func ensureGraph() {
    guard !graphSetup else { return }
    graphSetup = true

    engine.attach(eq)
    engine.attach(echoDelay)
    engine.attach(delayNode)
    engine.attach(reverb)

    // EQ band layout (see header comment). All gains start at 0 dB.
    let bandSpecs: [(type: AVAudioUnitEQFilterType, frequency: Float)] = [
      (.lowShelf, 100),
      (.parametric, 400),
      (.parametric, 1600),
      (.parametric, 6400),
      (.highShelf, 12000),
    ]
    for (index, spec) in bandSpecs.enumerated() {
      eq.bands[index].filterType = spec.type
      eq.bands[index].frequency = spec.frequency
      eq.bands[index].bandwidth = 1.0
      eq.bands[index].gain = 0
      eq.bands[index].bypass = false
    }

    // Effects start dry (wetDryMix 0 = unprocessed passthrough).
    echoDelay.delayTime = Self.echoDelaySeconds
    echoDelay.feedback = 0
    echoDelay.wetDryMix = 0
    delayNode.delayTime = 0
    delayNode.feedback = 0
    delayNode.wetDryMix = 0
    reverb.loadFactoryPreset(.mediumHall)
    reverb.wetDryMix = 0

    let format = engine.inputNode.outputFormat(forBus: 0)
    engine.connect(engine.inputNode, to: eq, format: format)
    engine.connect(eq, to: echoDelay, format: format)
    engine.connect(echoDelay, to: delayNode, format: format)
    engine.connect(delayNode, to: reverb, format: format)
    engine.connect(reverb, to: engine.mainMixerNode, format: format)
    // NOTE: engine.start() is intentionally NOT called here — see header.
  }

  // MARK: - Argument parsing

  /// Reads a Double from either a bare number argument or a map containing
  /// one of `keys` (first match wins). Returns nil for anything else.
  private func doubleArgument(_ arguments: Any?, keys: [String]) -> Double? {
    if let number = arguments as? NSNumber {
      return number.doubleValue
    }
    guard let map = arguments as? [String: Any] else { return nil }
    for key in keys {
      if let number = map[key] as? NSNumber {
        return number.doubleValue
      }
    }
    return nil
  }

  /// Reads (band, gain) from a {"band": Int, "gain": Double} map or a
  /// two-element [band, gain] list. Returns nil for anything else.
  /// MERGE NOTE (coordinator, 2026-11-22): also accepts "gainDb" as the
  /// gain key — the Dart services send {"band", "gainDb"} (matching
  /// Android's BassEqEffect.kt), so iOS must accept that shape too.
  private func eqArguments(_ arguments: Any?) -> (band: Int, gain: Float)? {
    if let map = arguments as? [String: Any],
      let bandNumber = map["band"] as? NSNumber,
      let gainNumber = (map["gain"] as? NSNumber) ?? (map["gainDb"] as? NSNumber)
    {
      return (bandNumber.intValue, gainNumber.floatValue)
    }
    if let list = arguments as? [Any], list.count == 2,
      let bandNumber = list[0] as? NSNumber,
      let gainNumber = list[1] as? NSNumber
    {
      return (bandNumber.intValue, gainNumber.floatValue)
    }
    return nil
  }

  private func invalidArgument(_ method: String, expected: String) -> FlutterError {
    FlutterError(
      code: "INVALID_ARGUMENT",
      message: "\(method) expects \(expected)",
      details: nil)
  }

  private func clamp<T: Comparable>(_ value: T, min lower: T, max upper: T) -> T {
    Swift.min(Swift.max(value, lower), upper)
  }
}
