import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protournament_user/components/arena_components.dart';
import 'package:protournament_user/theme.dart';
import 'package:protournament_user/widgets/arena_ui.dart';

/// Premium animated ARENA HUB splash screen.
///
/// Copy the provided image to:
///   assets/arena_hub_splash.png
///
/// Then register it in pubspec.yaml. No third-party package is required.
///
/// GOLD: app-wide gold is #FDC903 (user standing order) — the supplied
/// artwork file used a different gold shade in its code; corrected here.
class ArenaHubSplashScreen extends StatefulWidget {
  const ArenaHubSplashScreen({
    super.key,
    required this.homeBuilder,
    this.initializeApp,
    this.minimumDuration = const Duration(milliseconds: 3200),
  });

  /// The first screen to show after initialization is complete.
  final WidgetBuilder homeBuilder;

  /// Put your existing startup work here (for example, restoring a session).
  /// Do not move or rewrite your existing authentication/backend logic.
  final Future<void> Function()? initializeApp;

  /// Minimum time the splash remains visible, even if startup is very fast.
  final Duration minimumDuration;

  @override
  State<ArenaHubSplashScreen> createState() => _ArenaHubSplashScreenState();
}

class _ArenaHubSplashScreenState extends State<ArenaHubSplashScreen> {
  bool _navigated = false;

  @override
  void initState() {
    super.initState();

    // Immersive display lets the artwork fill the complete screen.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _startApp();
  }

  Future<void> _startApp() async {
    final startedAt = DateTime.now();

    try {
      await widget.initializeApp?.call();
    } catch (error, stackTrace) {
      // Keep your app's own error handling/logging here if required.
      debugPrint('ARENA HUB startup error: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    final elapsed = DateTime.now().difference(startedAt);
    final remaining = widget.minimumDuration - elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }

    if (!mounted || _navigated) return;
    _navigated = true;

    // Restore normal system bars for the rest of the application.
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        pageBuilder: (context, animation, secondaryAnimation) =>
            widget.homeBuilder(context),
        transitionDuration: const Duration(milliseconds: 550),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF050505),
      body: ArenaHubSplashArtwork(),
    );
  }
}

/// Visual-only splash artwork: the supplied ARENA HUB artwork with a
/// subtle animated zoom and golden ambience. No timer, no navigation,
/// no system-UI changes — so a host that already owns startup routing
/// (SplashGate in main.dart) can show this visual while its own state
/// machine decides where to go next. Single source of truth for the
/// splash look: [ArenaHubSplashScreen] renders this too.
class ArenaHubSplashArtwork extends StatefulWidget {
  const ArenaHubSplashArtwork({super.key});

  @override
  State<ArenaHubSplashArtwork> createState() => _ArenaHubSplashArtworkState();
}

class _ArenaHubSplashArtworkState extends State<ArenaHubSplashArtwork>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glowController;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    )..repeat(reverse: true);

    _glow = Tween<double>(begin: 0.10, end: 0.34).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _glowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // FIX 23 item 26 (splash rebuild, 2026-11-23 23:52): the
          // poster stays as the BACKGROUND until Sameer sends the
          // new splash background — but blurred + dimmed, so its
          // baked-in wordmark/loading bar melt into a golden-dark
          // backdrop instead of doubling the live logo below.
          AnimatedBuilder(
            animation: _glowController,
            builder: (context, child) {
              final scale = 1.0 + (_glowController.value * 0.012);
              return Transform.scale(
                scale: scale,
                child: child,
              );
            },
            child: Image.asset(
              'assets/arena_hub_splash.png',
              fit: BoxFit.cover,
              alignment: Alignment.center,
              filterQuality: FilterQuality.high,
              errorBuilder: (context, error, stackTrace) {
                return const ColoredBox(
                  color: Color(0xFF08090D),
                  child: Center(
                    child: Text(
                      'ARENA HUB',
                      style: TextStyle(
                        color: Color(0xFFFDC903),
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // Heavy blur + dark scrim: the poster becomes a premium
          // golden backdrop; its baked text is unreadable.
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              color: Colors.black.withValues(alpha: 0.55),
            ),
          ),

          // Blue+purple smoke (item 24) + gold ember sparks.
          const SmokeLayer(),
          const Positioned.fill(
            child: IgnorePointer(child: FireSparks(count: 28)),
          ),

          // A subtle animated golden ambience; it does not block touch or layout.
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _glow,
              builder: (context, child) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.15),
                      radius: 0.82,
                      colors: [
                        const Color(0x00FDC903),
                        Color.fromRGBO(253, 201, 3, _glow.value * 0.10),
                        const Color(0x00000000),
                      ],
                      stops: const [0.0, 0.62, 1.0],
                    ),
                  ),
                );
              },
            ),
          ),

          // The new logo (item 25) as the hero, breathing gently,
          // with a live loading indicator below it.
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedBuilder(
                  animation: _glowController,
                  builder: (context, child) {
                    final scale =
                        1.0 + (_glowController.value * 0.03);
                    return Transform.scale(scale: scale, child: child);
                  },
                  child: const ArenaHubLogoImage(
                      size: 200, ringWidth: 3),
                ),
                const SizedBox(height: 28),
                // Not const: kGold is a getter, not a const.
                SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    color: kGold,
                    strokeWidth: 3,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Loading Arena Hub...',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
