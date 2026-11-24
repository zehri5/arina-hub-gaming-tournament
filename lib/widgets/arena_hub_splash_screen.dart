import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'arena_artwork_layers.dart';
import 'golden_loading_bar.dart';
import 'logo_reveal_layer.dart';
import 'smoke_canvas_painter.dart';

typedef ArenaProgressReporter = void Function(double progress, {String? status});

/// Drop-in, independent reusable AAA splash screen widget for your existing
/// ARENA HUB Flutter application.
///
/// Timeline:
/// - 0.0–0.8s: Volumetric L->R blue & R->L purple smoke emergence
/// - 0.8–1.8s: Large circular energy ring, rotating light streaks & particles
/// - 1.8–2.8s: Soldier artwork reveal with parallax & helmet reflection
/// - 2.8–3.8s: ARENA HUB & crown metallic scale-in with golden glow
/// - 3.8–4.5s: PLAY • COMPETE • WIN tagline & golden light sweep
/// - 4.5s+   : Continuous smoke, ring, and sparkles while [onInitialize] completes
class ArenaHubSplashScreen extends StatefulWidget {
  const ArenaHubSplashScreen({
    super.key,
    this.splashArtworkAsset = 'assets/images/arena_hub_splash_art.png',
    this.minimumCinematicDuration = const Duration(milliseconds: 4500),
    this.onInitialize,
    required this.onCompleted,
  });

  final String splashArtworkAsset;
  final Duration minimumCinematicDuration;

  /// Connect your real startup initialization (Firebase Auth, tournament API,
  /// local storage, asset precache) and report actual progress (0.0 .. 1.0).
  final Future<void> Function(ArenaProgressReporter reportProgress)? onInitialize;

  /// Invoked when BOTH the 4.5s cinematic timeline and [onInitialize] reach 100%.
  final void Function(BuildContext context) onCompleted;

  @override
  State<ArenaHubSplashScreen> createState() => _ArenaHubSplashScreenState();
}

class _ArenaHubSplashScreenState extends State<ArenaHubSplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _introController;
  late final AnimationController _ambientController;
  late final AnimationController _progressController;
  late final AnimationController _shimmerController;

  late final Animation<double> _dockVisibilityAnim;

  ProceduralSmokeTextures? _smokeTextures;
  ArenaArtworkLayers? _artworkLayers;

  String _statusLabel = 'Initializing Arena...';
  bool _introFinished = false;
  bool _initFinished = false;
  bool _hasCompleted = false;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFF010206),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    _introController = AnimationController(
      vsync: this,
      duration: widget.minimumCinematicDuration,
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _introFinished = true;
          _tryComplete();
        }
      });

    // Continuous 60fps driver for smoke advection, rotating ring streaks & sparkles
    _ambientController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 180),
    )..repeat();

    // Smoothly interpolates toward real initialization progress (0.0 -> 1.0)
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: 0.0,
    );

    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat();

    _dockVisibilityAnim = CurvedAnimation(
      parent: _introController,
      curve: const Interval(0.84, 0.98, curve: Curves.easeOutCubic),
    );

    _bootstrap();
  }

  void _reportProgress(double progress, {String? status}) {
    if (!mounted) return;
    final clamped = progress.clamp(0.0, 1.0);
    if (status != null && status != _statusLabel) {
      setState(() {
        _statusLabel = status;
      });
    }
    _progressController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _bootstrap() async {
    _reportProgress(0.12, status: 'Loading Assets...');

    final results = await Future.wait([
      ProceduralSmokeTextures.generate(size: 160),
      ArenaArtworkLayers.loadFromAsset(widget.splashArtworkAsset, targetWidth: 640),
    ]);

    final textures = results[0] as ProceduralSmokeTextures;
    final layers = results[1] as ArenaArtworkLayers;

    if (!mounted) {
      textures.dispose();
      layers.dispose();
      return;
    }

    setState(() {
      _smokeTextures = textures;
      _artworkLayers = layers;
    });

    final reduceMotion =
        WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    if (reduceMotion) {
      _introController.value = 1.0;
      _introFinished = true;
    } else {
      _introController.forward();
    }

    if (widget.onInitialize != null) {
      _reportProgress(0.35, status: 'Connecting Services...');
      try {
        await widget.onInitialize!((value, {String? status}) {
          // Map app init 0..1 into 0.35..1.0 so real progress stays smooth & accurate
          _reportProgress(0.35 + value.clamp(0.0, 1.0) * 0.65, status: status);
        });
      } finally {
        _reportProgress(1.0, status: 'Arena Ready');
        _initFinished = true;
        _tryComplete();
      }
    } else {
      _reportProgress(1.0, status: 'Arena Ready');
      _initFinished = true;
      _tryComplete();
    }
  }

  void _tryComplete() {
    if (!mounted || _hasCompleted) return;
    if (_introFinished && _initFinished && _progressController.value >= 0.99) {
      _hasCompleted = true;
      widget.onCompleted(context);
    } else if (_introFinished && _initFinished) {
      _progressController
          .animateTo(1.0, duration: const Duration(milliseconds: 220))
          .whenComplete(() {
        if (mounted && !_hasCompleted) {
          _hasCompleted = true;
          widget.onCompleted(context);
        }
      });
    }
  }

  Rect _computeArtRect(Size size) {
    const artW = 841.0;
    const artH = 1870.0;
    final aspect = size.width / math.max(size.height, 1.0);
    const artAspect = artW / artH;

    if (aspect <= 0.65) {
      final scale = math.max(size.width / artW, size.height / artH);
      final drawW = artW * scale;
      final drawH = artH * scale;
      return Rect.fromLTWH(
        (size.width - drawW) * 0.5,
        (size.height - drawH) * 0.45,
        drawW,
        drawH,
      );
    }

    final drawH = size.height;
    final drawW = drawH * artAspect;
    return Rect.fromLTWH((size.width - drawW) * 0.5, 0, drawW, drawH);
  }

  @override
  void dispose() {
    _introController.dispose();
    _ambientController.dispose();
    _progressController.dispose();
    _shimmerController.dispose();
    _smokeTextures?.dispose();
    _artworkLayers?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF010206),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final artRect = _computeArtRect(size);

          return AnimatedBuilder(
            animation: _ambientController,
            builder: (context, _) {
              final reduceMotion = WidgetsBinding
                  .instance.platformDispatcher.accessibilityFeatures.disableAnimations;
              final elapsedSec = reduceMotion ? 5.0 : _ambientController.value * 180.0;

              return Stack(
                fit: StackFit.expand,
                children: [
                  // Base obsidian-navy gradient
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment(0.0, -0.2),
                        radius: 1.05,
                        colors: [
                          Color(0xFF0A122E),
                          Color(0xFF040611),
                          Color(0xFF010206),
                        ],
                        stops: [0.0, 0.55, 1.0],
                      ),
                    ),
                  ),

                  // Scenes 1 & 2: Volumetric L->R / R->L Smoke, Backdrop, Ring & Embers
                  RepaintBoundary(
                    child: CustomPaint(
                      size: size,
                      painter: ArenaAtmospherePainter(
                        textures: _smokeTextures,
                        layers: _artworkLayers,
                        artRect: artRect,
                        elapsedSeconds: elapsedSec,
                        repaint: _ambientController,
                      ),
                    ),
                  ),

                  // Scenes 3, 4 & 5: Soldier Parallax, Crown Glow/Sparkles, ARENA HUB & Tagline
                  ArenaHeroAndLogoLayers(
                    layers: _artworkLayers,
                    artRect: artRect,
                    elapsedSeconds: elapsedSec,
                    ambientListenable: _ambientController,
                  ),

                  // Bottom SafeArea Real-Progress Golden Loading Dock
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: EdgeInsets.only(
                          bottom: (size.height * 0.045).clamp(20.0, 48.0),
                        ),
                        child: Center(
                          child: GoldenLoadingBarDock(
                            dockVisibility: _dockVisibilityAnim,
                            progress: _progressController,
                            shimmerProgress: _shimmerController,
                            statusText: _statusLabel,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
