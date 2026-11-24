import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // ARENA HUB #10 AUDIO (G6): retained so the iOS `arena_audio/effects`
  // method channel stays alive for the app's lifetime.
  private var audioEffectsPlugin: AudioEffectsPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // ARENA HUB #10 AUDIO (G6): iOS side of the `arena_audio/effects`
    // channel (same methods as Android: setReverb / setEcho / setDelay /
    // setBass / setEq). UNVERIFIED — needs a Mac/Xcode build.
    audioEffectsPlugin = AudioEffectsPlugin(messenger: engineBridge.applicationRegistrar.messenger())
  }
}
