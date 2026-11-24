import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'arena_artwork_layers.dart';

/// Renders Scene 3 (Soldier artwork with subtle parallax, rim light, and helmet
/// reflection), Scene 4 (ARENA HUB logo metallic scale-in, crown glow, and
/// golden sparkles), and Scene 5 (Tagline upward reveal & golden light sweep)
/// using Stack, Positioned, AnimatedBuilder, ShaderMask, and CustomPainter.
class ArenaHeroAndLogoLayers extends StatelessWidget {
  const ArenaHeroAndLogoLayers({
    super.key,
    required this.layers,
    required this.artRect,
    required this.elapsedSeconds,
    required this.ambientListenable,
  });

  final ArenaArtworkLayers? layers;
  final Rect artRect;
  final double elapsedSeconds;
  final Listenable ambientListenable;

  static double _smoothstep(double edge0, double edge1, double x) {
    final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  static double _easeOutCubic(double t) {
    final c = t.clamp(0.0, 1.0);
    return 1.0 - math.pow(1.0 - c, 3).toDouble();
  }

  static double _easeInOutCubic(double t) {
    final c = t.clamp(0.0, 1.0);
    return c < 0.5 ? 4 * c * c * c : 1 - math.pow(-2 * c + 2, 3) / 2.0;
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  Widget build(BuildContext context) {
    if (layers == null) return const SizedBox.shrink();

    final t = elapsedSeconds;

    // Scene 3 (1.8s - 2.8s): Soldier Artwork + Parallax + Helmet Reflection
    final soldierAppear = _smoothstep(1.8, 2.75, t);
    final parallaxX = math.sin(t * 0.65) * 3.5;
    final parallaxY = math.cos(t * 0.5) * 2.5 + _lerp(14.0, 0.0, _easeOutCubic(soldierAppear));
    final soldierScale = _lerp(1.035, 1.0, _easeOutCubic(soldierAppear));

    double helmetSweep = -1.0;
    if (t >= 2.1 && t <= 2.95) {
      helmetSweep = (t - 2.1) / 0.85;
    } else if (t > 5.0) {
      final cyc = (t - 5.0) % 5.5;
      if (cyc < 0.9) helmetSweep = cyc / 0.9;
    }

    // Scene 4 (2.8s - 3.8s): ARENA HUB + Crown Metallic Scale-In & Sweep
    final logoAppear = _smoothstep(2.8, 3.65, t);
    final easedLogo = _easeOutCubic(logoAppear);
    final logoScale = logoAppear < 0.72
        ? _lerp(0.80, 1.022, _easeOutCubic(logoAppear / 0.72))
        : _lerp(1.022, 1.0, _easeInOutCubic((logoAppear - 0.72) / 0.28));

    double goldSweep = -1.0;
    if (t >= 3.1 && t <= 3.75) {
      goldSweep = (t - 3.1) / 0.65;
    } else if (t >= 3.85 && t <= 4.55) {
      goldSweep = (t - 3.85) / 0.70;
    } else if (t > 5.4) {
      final cyc = (t - 5.4) % 4.4;
      if (cyc < 0.95) goldSweep = cyc / 0.95;
    }

    // Scene 5 (3.8s - 4.5s): Tagline Fade + Upward Motion
    final tagAppear = _smoothstep(3.8, 4.35, t);
    final easedTag = _easeOutCubic(tagAppear);
    final tagYOffset = _lerp(12.0, 0.0, easedTag);

    final crownPulse = 0.58 + 0.42 * math.sin(t * 2.4);

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. Soldier Layer (with subtle parallax & helmet/armor reflection ShaderMask)
        if (soldierAppear > 0.005)
          Positioned(
            left: artRect.left + parallaxX,
            top: artRect.top + parallaxY,
            width: artRect.width,
            height: artRect.height,
            child: Opacity(
              opacity: _easeOutCubic(soldierAppear),
              child: Transform.scale(
                scale: soldierScale,
                alignment: const Alignment(0, -0.35),
                child: ShaderMask(
                  blendMode: BlendMode.srcATop,
                  shaderCallback: (bounds) => _buildSweepShader(
                    bounds,
                    helmetSweep,
                    isGold: false,
                  ),
                  child: RawImage(
                    image: layers!.soldier,
                    width: artRect.width,
                    height: artRect.height,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
            ),
          ),

        // 2. Royal Crown Warm Golden Radiance
        if (logoAppear > 0.005)
          Positioned(
            left: artRect.left + artRect.width * 0.28,
            top: artRect.top + artRect.height * 0.36,
            width: artRect.width * 0.44,
            height: artRect.height * 0.16,
            child: IgnorePointer(
              child: Opacity(
                opacity: (easedLogo * crownPulse * 0.75).clamp(0.0, 1.0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        const Color(0xFFFFEC8C).withValues(alpha: 0.72),
                        const Color(0xFFF59E0B).withValues(alpha: 0.32),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.48, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ),

        // 3. ARENA HUB + Crown Logo Layer with Scale-In & Golden Light Sweep
        if (logoAppear > 0.005)
          Positioned(
            left: artRect.left,
            top: artRect.top,
            width: artRect.width,
            height: artRect.height,
            child: Opacity(
              opacity: easedLogo,
              child: Transform.scale(
                scale: logoScale,
                alignment: const Alignment(0, 0.06),
                child: ShaderMask(
                  blendMode: BlendMode.srcATop,
                  shaderCallback: (bounds) => _buildSweepShader(
                    bounds,
                    goldSweep,
                    isGold: true,
                  ),
                  child: RawImage(
                    image: layers!.logo,
                    width: artRect.width,
                    height: artRect.height,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
            ),
          ),

        // 4. Occasional Tiny Golden Sparkles on the Crown
        if (t >= 3.2)
          Positioned(
            left: artRect.left,
            top: artRect.top,
            width: artRect.width,
            height: artRect.height,
            child: IgnorePointer(
              child: CustomPaint(
                painter: _CrownSparklePainter(
                  elapsedSeconds: t,
                  alphaMaster: easedLogo,
                  repaint: ambientListenable,
                ),
              ),
            ),
          ),

        // 5. PLAY • COMPETE • WIN Tagline Layer (3.8s - 4.5s)
        if (tagAppear > 0.005)
          Positioned(
            left: artRect.left,
            top: artRect.top + tagYOffset,
            width: artRect.width,
            height: artRect.height,
            child: Opacity(
              opacity: easedTag,
              child: RawImage(
                image: layers!.tagline,
                width: artRect.width,
                height: artRect.height,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
      ],
    );
  }

  static Shader _buildSweepShader(
    Rect bounds,
    double sweepPhase, {
    required bool isGold,
  }) {
    if (sweepPhase < 0.0 || sweepPhase > 1.0) {
      return const LinearGradient(
        colors: [Colors.transparent, Colors.transparent],
      ).createShader(bounds);
    }

    final eased = _easeInOutCubic(sweepPhase);
    final pos = -0.6 + eased * 2.2;

    if (isGold) {
      return LinearGradient(
        begin: Alignment(pos - 0.35, -1.0),
        end: Alignment(pos + 0.35, 1.0),
        colors: [
          Colors.transparent,
          const Color(0xFFFDE047).withValues(alpha: 0.30),
          const Color(0xFFFFFCE1).withValues(alpha: 0.85),
          const Color(0xFFF59E0B).withValues(alpha: 0.30),
          Colors.transparent,
        ],
        stops: const [0.0, 0.36, 0.5, 0.64, 1.0],
      ).createShader(bounds);
    }

    return LinearGradient(
      begin: Alignment(pos - 0.30, -1.0),
      end: Alignment(pos + 0.30, 1.0),
      colors: [
        Colors.transparent,
        const Color(0xFFE0F2FE).withValues(alpha: 0.22),
        Colors.white.withValues(alpha: 0.55),
        const Color(0xFFE9D5FF).withValues(alpha: 0.22),
        Colors.transparent,
      ],
      stops: const [0.0, 0.40, 0.50, 0.60, 1.0],
    ).createShader(bounds);
  }
}

class _CrownSparklePainter extends CustomPainter {
  _CrownSparklePainter({
    required this.elapsedSeconds,
    required this.alphaMaster,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final double elapsedSeconds;
  final double alphaMaster;

  static const _anchors = [
    Offset(0.37, 0.43),
    Offset(0.43, 0.415),
    Offset(0.50, 0.398),
    Offset(0.57, 0.415),
    Offset(0.63, 0.43),
    Offset(0.46, 0.452),
    Offset(0.54, 0.452),
    Offset(0.50, 0.435),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < _anchors.length; i++) {
      final period = 2.2 + (i % 4) * 0.52;
      final offset = i * 0.48;
      final cyc = ((elapsedSeconds + offset) % period) / period;
      if (cyc >= 0.28) continue;

      final alpha = math.sin((cyc / 0.28) * math.pi) * alphaMaster;
      if (alpha <= 0.02) continue;

      final maxSize = 5.0 + (i % 3) * 2.0;
      final r = maxSize * (0.55 + 0.45 * alpha);
      final center = Offset(_anchors[i].dx * size.width, _anchors[i].dy * size.height);

      final glowPaint = Paint()
        ..blendMode = BlendMode.screen
        ..shader = RadialGradient(
          colors: [
            Color.fromRGBO(255, 250, 220, 0.95 * alpha),
            Color.fromRGBO(253, 224, 71, 0.45 * alpha),
            const Color.fromRGBO(245, 158, 11, 0),
          ],
          stops: const [0.0, 0.4, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: r * 1.8));
      canvas.drawCircle(center, r * 1.8, glowPaint);

      final starPath = Path()
        ..moveTo(center.dx, center.dy - r)
        ..quadraticBezierTo(center.dx + r * 0.14, center.dy - r * 0.14, center.dx + r, center.dy)
        ..quadraticBezierTo(center.dx + r * 0.14, center.dy + r * 0.14, center.dx, center.dy + r)
        ..quadraticBezierTo(center.dx - r * 0.14, center.dy + r * 0.14, center.dx - r, center.dy)
        ..quadraticBezierTo(center.dx - r * 0.14, center.dy - r * 0.14, center.dx, center.dy - r);

      canvas.drawPath(
        starPath,
        Paint()
          ..blendMode = BlendMode.screen
          ..color = Color.fromRGBO(255, 252, 235, alpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CrownSparklePainter oldDelegate) => true;
}
