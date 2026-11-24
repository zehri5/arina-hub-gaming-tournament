import 'package:flutter/material.dart';
import '../components/arena_components.dart';
import '../widgets/arena_ui.dart';

/// v2003 FIX 14a — full-screen offline page (mockup #11).
///
/// The content is the shared [OfflineState] (new logo badge, gold
/// wifi+shield illustration, "YOU'RE OFFLINE", "Connection
/// Unavailable" pill, RETRY CONNECTION + GO BACK).
/// PHASE E (E21): the old ember-texture backdrop is gone — the
/// screen uses the app-wide poster background (AppBackgroundLayer,
/// same as every other screen) + the NEW logo badge, so the
/// offline page looks like the rest of the app.
/// PHASE E (E22): mid-session connectivity loss shows this screen
/// as an overlay above the Navigator (HomeShell's listener) — the
/// boot gate (SplashGate) still renders it as a full route.
///
/// WIRED (P2 #11, 2026-11-21): SplashGate's no-internet branch
/// renders this screen — onRetry re-runs the boot/connectivity
/// check, onGoBack exits the app (the boot gate has no previous
/// route; same action as the system back button from the root
/// route). Per-screen inline OfflineState usages are untouched —
/// this screen is the full-screen route only.
class OfflineScreen extends StatelessWidget {
  const OfflineScreen({
    super.key,
    this.message = 'Check your internet connection and try again.',
    this.onRetry,
    this.onGoBack,
    this.showGoBack = true,
  });

  final String message;
  final VoidCallback? onRetry;
  final VoidCallback? onGoBack;
  // PHASE E (E22): the mid-session overlay hides GO BACK — there
  // is nowhere to go back to (the app sits frozen underneath).
  final bool showGoBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // PHASE E (E21): app poster, not the old ember texture.
          const AppBackgroundLayer(respectLightMode: false),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                child: OfflineState(
                  message: message,
                  onRetry: onRetry,
                  onGoBack: onGoBack,
                  useNewLogo: true,
                  showGoBack: showGoBack,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
