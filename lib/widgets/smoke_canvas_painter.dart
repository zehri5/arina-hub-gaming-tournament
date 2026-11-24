import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'arena_artwork_layers.dart';

/// Generates multi-octave domain-warped FBM & ridged filament smoke textures
/// once via pure Dart + `dart:ui` (no blurred circle blobs, no external packages).
class ProceduralSmokeTextures {
  ProceduralSmokeTextures._({
    required this.blueVolumetric,
    required this.blueTendril,
    required this.purpleVolumetric,
    required this.purpleTendril,
    required this.smokeShadow,
  });

  final ui.Image blueVolumetric;
  final ui.Image blueTendril;
  final ui.Image purpleVolumetric;
  final ui.Image purpleTendril;
  final ui.Image smokeShadow;

  static Future<ProceduralSmokeTextures> generate({int size = 160}) async {
    final results = await Future.wait([
      _createSmokeImage(size, 11, const [0, 70, 200], const [0, 178, 255], false),
      _createSmokeImage(size, 29, const [0, 122, 255], const [112, 240, 255], true),
      _createSmokeImage(size, 47, const [88, 0, 198], const [168, 42, 255], false),
      _createSmokeImage(size, 73, const [140, 40, 232], const [238, 118, 255], true),
      _createSmokeImage(size, 103, const [2, 3, 10], const [7, 10, 26], false),
    ]);

    return ProceduralSmokeTextures._(
      blueVolumetric: results[0],
      blueTendril: results[1],
      purpleVolumetric: results[2],
      purpleTendril: results[3],
      smokeShadow: results[4],
    );
  }

  void dispose() {
    blueVolumetric.dispose();
    blueTendril.dispose();
    purpleVolumetric.dispose();
    purpleTendril.dispose();
    smokeShadow.dispose();
  }

  static Future<ui.Image> _createSmokeImage(
    int size,
    int seed,
    List<int> deepRgb,
    List<int> brightRgb,
    bool ridged,
  ) {
    final completer = Completer<ui.Image>();
    final pixels = Uint8List(size * size * 4);

    for (int y = 0; y < size; y++) {
      final ny = (y / size) * 2.0 - 1.0;
      for (int x = 0; x < size; x++) {
        final nx = (x / size) * 2.0 - 1.0;
        final r2 = nx * nx + ny * ny;
        final idx = (y * size + x) * 4;

        if (r2 >= 1.0) {
          pixels[idx + 3] = 0;
          continue;
        }

        final u = (x / size) * 3.6;
        final v = (y / size) * 3.1;
        final wx = _fbm(u + 0.6, v + 1.3, seed, 4);
        final wy = _fbm(u + 4.2, v + 2.5, seed + 17, 4);
        final n = _fbm(u + 2.4 * wx, v + 2.4 * wy, seed + 53, 4);
        final fine = _fbm(u * 2.6 - wy * 1.4, v * 2.6 + wx * 1.4, seed + 89, 3);

        final shaped = ridged
            ? math.pow(((1.0 - (n * 2.0 - 1.0).abs()) * 0.95 + n * 0.25 - 0.2).clamp(0.0, 1.0), 1.45).toDouble()
            : math.pow((n * 1.35 - 0.22).clamp(0.0, 1.0), 1.6).toDouble();

        final angleMask = 0.78 + 0.22 * wx;
        final envelope = math.pow((1.0 - r2 / angleMask).clamp(0.0, 1.0), 1.45).toDouble();
        final density = (shaped * (0.58 + 0.62 * fine) * envelope).clamp(0.0, 1.0);

        final mix = (shaped * 1.15 - 0.1).clamp(0.0, 1.0);
        pixels[idx] = _lerpInt(deepRgb[0], brightRgb[0], mix);
        pixels[idx + 1] = _lerpInt(deepRgb[1], brightRgb[1], mix);
        pixels[idx + 2] = _lerpInt(deepRgb[2], brightRgb[2], mix);
        pixels[idx + 3] = (density * 255).round();
      }
    }

    ui.decodeImageFromPixels(
      pixels,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  static int _lerpInt(int a, int b, double t) => (a + (b - a) * t).round().clamp(0, 255);

  static double _hash2D(int ix, int iy, int seed) {
    int n = (ix * 374761393 + iy * 668265263 + seed * 1442695041) & 0x7fffffff;
    n = ((n ^ (n >> 13)) * 1274126177) & 0x7fffffff;
    n = (n ^ (n >> 16)) & 0x7fffffff;
    return n / 2147483647.0;
  }

  static double _smoothNoise(double x, double y, int seed) {
    final ix = x.floor();
    final iy = y.floor();
    final fx = x - ix;
    final fy = y - iy;
    final ux = fx * fx * (3.0 - 2.0 * fx);
    final uy = fy * fy * (3.0 - 2.0 * fy);
    final a = _hash2D(ix, iy, seed);
    final b = _hash2D(ix + 1, iy, seed);
    final c = _hash2D(ix, iy + 1, seed);
    final d = _hash2D(ix + 1, iy + 1, seed);
    return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy;
  }

  static double _fbm(double x, double y, int seed, int octaves) {
    double val = 0.0;
    double amp = 0.5;
    double freq = 1.0;
    for (int i = 0; i < octaves; i++) {
      val += amp * _smoothNoise(x * freq, y * freq, seed + i * 31);
      freq *= 2.04;
      amp *= 0.5;
    }
    return val;
  }
}

class _SmokeCloud {
  const _SmokeCloud({
    required this.dir,
    required this.depthLayer,
    required this.isShadow,
    required this.phase,
    required this.yBase,
    required this.speedX,
    required this.swirlAmpY,
    required this.scale,
    required this.rotBase,
    required this.rotSpeed,
    required this.alpha,
  });

  final int dir; // +1 = L->R blue, -1 = R->L purple
  final int depthLayer;
  final bool isShadow;
  final double phase;
  final double yBase;
  final double speedX;
  final double swirlAmpY;
  final double scale;
  final double rotBase;
  final double rotSpeed;
  final double alpha;
}

class _SwirlPuff {
  const _SwirlPuff({
    required this.isBlue,
    required this.angle,
    required this.radiusFactor,
    required this.angularSpeed,
    required this.scale,
    required this.alpha,
  });

  final bool isBlue;
  final double angle;
  final double radiusFactor;
  final double angularSpeed;
  final double scale;
  final double alpha;
}

class _Ember {
  const _Ember({
    required this.zone,
    required this.x,
    required this.y,
    required this.vy,
    required this.vxDrift,
    required this.swirlAmp,
    required this.radius,
    required this.phase,
    required this.alpha,
  });

  final int zone;
  final double x;
  final double y;
  final double vy;
  final double vxDrift;
  final double swirlAmp;
  final double radius;
  final double phase;
  final double alpha;
}

/// Renders Scene 1 (L->R blue & R->L purple volumetric smoke + battlefield backdrop)
/// and Scene 2 (Large circular energy ring with rotating light streaks, electric
/// pulses, backlight glow, swirling smoke puffs, and rising embers).
class ArenaAtmospherePainter extends CustomPainter {
  ArenaAtmospherePainter({
    required this.textures,
    required this.layers,
    required this.artRect,
    required this.elapsedSeconds,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final ProceduralSmokeTextures? textures;
  final ArenaArtworkLayers? layers;
  final Rect artRect;
  final double elapsedSeconds;

  static final List<_SmokeCloud> _clouds = _buildClouds();
  static final List<_SwirlPuff> _swirls = _buildSwirls();
  static final List<_Ember> _embers = _buildEmbers();

  static List<_SmokeCloud> _buildClouds() {
    final list = <_SmokeCloud>[];
    for (int i = 0; i < 14; i++) {
      final depth = i % 3;
      final isShadow = i % 5 == 4;
      list.add(_SmokeCloud(
        dir: 1,
        depthLayer: depth,
        isShadow: isShadow,
        phase: i / 14.0,
        yBase: _lerp(0.12, 0.92, ((i * 7) % 14) / 13.0),
        speedX: depth == 0 ? 0.032 : depth == 1 ? 0.058 : 0.092,
        swirlAmpY: _lerp(0.03, 0.075, (i % 4) / 3.0),
        scale: depth == 0 ? 0.92 : depth == 1 ? 0.72 : 0.56,
        rotBase: i * 0.65,
        rotSpeed: (i.isEven ? 1.0 : -1.0) * _lerp(0.06, 0.18, depth / 2.0),
        alpha: isShadow ? 0.45 : depth == 0 ? 0.28 : depth == 1 ? 0.36 : 0.44,
      ));
    }
    for (int i = 0; i < 14; i++) {
      final depth = i % 3;
      final isShadow = i % 5 == 4;
      list.add(_SmokeCloud(
        dir: -1,
        depthLayer: depth,
        isShadow: isShadow,
        phase: i / 14.0,
        yBase: _lerp(0.12, 0.92, ((i * 11) % 14) / 13.0),
        speedX: depth == 0 ? 0.032 : depth == 1 ? 0.058 : 0.092,
        swirlAmpY: _lerp(0.03, 0.075, (i % 4) / 3.0),
        scale: depth == 0 ? 0.92 : depth == 1 ? 0.72 : 0.56,
        rotBase: i * 0.85,
        rotSpeed: (i.isEven ? -1.0 : 1.0) * _lerp(0.06, 0.18, depth / 2.0),
        alpha: isShadow ? 0.45 : depth == 0 ? 0.28 : depth == 1 ? 0.36 : 0.44,
      ));
    }
    return list;
  }

  static List<_SwirlPuff> _buildSwirls() {
    return List.generate(16, (i) {
      return _SwirlPuff(
        isBlue: i.isEven,
        angle: (i / 16.0) * math.pi * 2.0,
        radiusFactor: _lerp(0.28, 0.52, (i % 5) / 4.0),
        angularSpeed: (i.isEven ? 0.18 : -0.18) * _lerp(0.7, 1.3, (i % 3) / 2.0),
        scale: _lerp(0.24, 0.42, (i % 4) / 3.0),
        alpha: _lerp(0.16, 0.30, (i % 3) / 2.0),
      );
    });
  }

  static List<_Ember> _buildEmbers() {
    final rng = math.Random(9142);
    return List.generate(58, (i) {
      final zone = i % 3;
      return _Ember(
        zone: zone,
        x: zone == 0
            ? rng.nextDouble() * 0.48
            : zone == 1
                ? 0.52 + rng.nextDouble() * 0.48
                : 0.22 + rng.nextDouble() * 0.56,
        y: rng.nextDouble(),
        vy: _lerp(0.025, 0.085, rng.nextDouble()),
        vxDrift: (zone == 0 ? 0.015 : zone == 1 ? -0.015 : 0.0) +
            (rng.nextDouble() - 0.5) * 0.01,
        swirlAmp: _lerp(0.008, 0.025, rng.nextDouble()),
        radius: _lerp(1.0, 2.6, rng.nextDouble()),
        phase: rng.nextDouble() * math.pi * 2.0,
        alpha: _lerp(0.32, 0.92, rng.nextDouble()),
      );
    });
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static double _easeOutCubic(double t) {
    final c = t.clamp(0.0, 1.0);
    return 1.0 - math.pow(1.0 - c, 3).toDouble();
  }

  static double _smoothstep(double edge0, double edge1, double x) {
    final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = elapsedSeconds;
    final smokeMaster = _easeOutCubic(t / 0.85);

    // 1. Atmospheric left-blue & right-purple lighting
    if (smokeMaster > 0.01) {
      final leftWash = Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width * 0.05, size.height * 0.48),
          math.max(size.width, size.height) * 0.65,
          [
            Color.fromRGBO(0, 158, 255, 0.30 * smokeMaster),
            Color.fromRGBO(0, 82, 204, 0.12 * smokeMaster),
            const Color.fromRGBO(0, 40, 160, 0),
          ],
          const [0.0, 0.55, 1.0],
        );
      canvas.drawRect(Offset.zero & size, leftWash);

      final rightWash = Paint()
        ..shader = ui.Gradient.radial(
          Offset(size.width * 0.95, size.height * 0.48),
          math.max(size.width, size.height) * 0.65,
          [
            Color.fromRGBO(172, 65, 255, 0.32 * smokeMaster),
            Color.fromRGBO(110, 0, 210, 0.13 * smokeMaster),
            const Color.fromRGBO(70, 0, 160, 0),
          ],
          const [0.0, 0.55, 1.0],
        );
      canvas.drawRect(Offset.zero & size, rightWash);
    }

    // 2. Uploaded battlefield perimeter backdrop (plane, parachuters, crate, watchtower)
    final backdropFade = _smoothstep(0.35, 1.45, t);
    if (layers != null && backdropFade > 0.01) {
      final bgImg = layers!.backdrop;
      final src = Rect.fromLTWH(0, 0, bgImg.width.toDouble(), bgImg.height.toDouble());
      final paint = Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(255, 255, 255, (backdropFade * 0.92).clamp(0.0, 1.0));
      canvas.drawImageRect(bgImg, src, artRect, paint);
    }

    // 3. Multi-speed Volumetric Smoke: Blue (L->R) & Purple (R->L)
    if (textures != null && smokeMaster > 0.01) {
      final baseSize = math.max(size.width * 0.72, size.height * 0.46);
      for (final s in _clouds) {
        final progress = (s.phase + t * s.speedX) % 1.0;
        final xNorm = s.dir == 1
            ? _lerp(-0.14, 0.56, progress)
            : _lerp(1.14, 0.44, progress);
        final lifeAlpha = math.sin(progress * math.pi);
        final yNorm = s.yBase + math.sin(t * 0.55 + s.phase * 9.0) * s.swirlAmpY;
        final drawSize = baseSize * s.scale * _lerp(0.88, 1.18, progress);
        final rot = s.rotBase + t * s.rotSpeed;

        final ui.Image sprite;
        if (s.isShadow) {
          sprite = textures!.smokeShadow;
        } else if (s.dir == 1) {
          sprite = s.depthLayer == 2 ? textures!.blueTendril : textures!.blueVolumetric;
        } else {
          sprite = s.depthLayer == 2 ? textures!.purpleTendril : textures!.purpleVolumetric;
        }

        canvas.save();
        canvas.translate(xNorm * size.width, yNorm * size.height);
        canvas.rotate(rot);
        final paint = Paint()
          ..filterQuality = FilterQuality.low
          ..blendMode = s.isShadow ? BlendMode.srcOver : BlendMode.screen
          ..color = Color.fromRGBO(
            255,
            255,
            255,
            (s.alpha * smokeMaster * lifeAlpha).clamp(0.0, 1.0),
          );
        final src = Rect.fromLTWH(0, 0, sprite.width.toDouble(), sprite.height.toDouble());
        final dst = Rect.fromCenter(center: Offset.zero, width: drawSize, height: drawSize);
        canvas.drawImageRect(sprite, src, dst, paint);
        canvas.restore();
      }
    }

    // 4. Scene 2 (0.8s - 1.8s+): Large Circular Energy Ring + Swirling Puffs
    final ringAppear = ((t - 0.8) / 1.0).clamp(0.0, 1.0);
    if (ringAppear > 0.005) {
      _drawEnergyRing(canvas, t, _easeOutCubic(ringAppear));

      if (textures != null) {
        final ringCx = artRect.left + artRect.width * 0.50;
        final ringCy = artRect.top + artRect.height * 0.305;
        for (final p in _swirls) {
          final ang = p.angle + t * p.angularSpeed;
          final rad = artRect.width * p.radiusFactor;
          final px = ringCx + math.cos(ang) * rad;
          final py = ringCy + math.sin(ang) * rad;
          final sz = artRect.width * p.scale;
          final sprite = p.isBlue ? textures!.blueTendril : textures!.purpleTendril;

          canvas.save();
          canvas.translate(px, py);
          canvas.rotate(ang);
          final paint = Paint()
            ..blendMode = BlendMode.screen
            ..filterQuality = FilterQuality.low
            ..color = Color.fromRGBO(255, 255, 255, (p.alpha * ringAppear).clamp(0.0, 1.0));
          final src = Rect.fromLTWH(0, 0, sprite.width.toDouble(), sprite.height.toDouble());
          final dst = Rect.fromCenter(center: Offset.zero, width: sz, height: sz);
          canvas.drawImageRect(sprite, src, dst, paint);
          canvas.restore();
        }
      }
    }

    // 5. Floating glowing particles (0.85s+)
    final particleMaster = _smoothstep(0.85, 1.7, t);
    if (particleMaster > 0.01) {
      final dotPaint = Paint()..blendMode = BlendMode.screen;
      for (final pt in _embers) {
        final py = ((pt.y - t * pt.vy) % 1.0 + 1.0) % 1.0;
        final px = ((pt.x + t * pt.vxDrift + math.sin(t * 1.3 + pt.phase) * pt.swirlAmp) % 1.0 + 1.0) % 1.0;
        final twinkle = 0.55 + 0.45 * math.sin(t * 2.6 + pt.phase);
        final alpha = (pt.alpha * twinkle * particleMaster).clamp(0.0, 1.0);

        if (pt.zone == 0) {
          dotPaint.color = Color.fromRGBO(103, 232, 249, alpha);
        } else if (pt.zone == 1) {
          dotPaint.color = Color.fromRGBO(232, 121, 249, alpha);
        } else {
          dotPaint.color = Color.fromRGBO(253, 224, 71, alpha * 0.92);
        }
        canvas.drawCircle(Offset(px * size.width, py * size.height), pt.radius, dotPaint);
      }
    }
  }

  void _drawEnergyRing(Canvas canvas, double t, double alpha) {
    final cx = artRect.left + artRect.width * 0.50;
    final cy = artRect.top + artRect.height * 0.305;
    final baseRadius = artRect.width * 0.388;
    final pulse = 1.0 + 0.018 * math.sin(t * 2.8) + 0.008 * math.sin(t * 7.3);
    final r = baseRadius * _lerp(0.86, 1.0, alpha) * pulse;
    final electricPulse = 0.85 + 0.15 * math.sin(t * 4.5);
    final ringRect = Rect.fromCircle(center: Offset(cx, cy), radius: r);

    canvas.save();

    // Radial backlight glow illuminating the soldier from behind
    final leftBack = Paint()
      ..blendMode = BlendMode.screen
      ..shader = ui.Gradient.radial(
        Offset(cx - r * 0.45, cy),
        r * 1.35,
        [
          Color.fromRGBO(0, 175, 255, 0.30 * alpha * electricPulse),
          const Color.fromRGBO(0, 80, 220, 0),
        ],
      );
    canvas.drawCircle(Offset(cx, cy), r * 1.45, leftBack);

    final rightBack = Paint()
      ..blendMode = BlendMode.screen
      ..shader = ui.Gradient.radial(
        Offset(cx + r * 0.45, cy),
        r * 1.35,
        [
          Color.fromRGBO(185, 55, 255, 0.32 * alpha * electricPulse),
          const Color.fromRGBO(110, 0, 210, 0),
        ],
      );
    canvas.drawCircle(Offset(cx, cy), r * 1.45, rightBack);

    // Electric Blue Left Arc
    final blueHalo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22
      ..blendMode = BlendMode.screen
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16)
      ..color = Color.fromRGBO(0, 170, 255, 0.44 * alpha * electricPulse);
    canvas.drawArc(ringRect, math.pi * 0.5, math.pi, false, blueHalo);

    final blueCore = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..blendMode = BlendMode.screen
      ..shader = ui.Gradient.linear(
        Offset(cx - r, cy),
        Offset(cx + 8, cy),
        [
          Color.fromRGBO(110, 238, 255, 0.98 * alpha),
          Color.fromRGBO(0, 130, 255, 0.88 * alpha),
          Color.fromRGBO(210, 244, 255, 0.98 * alpha),
        ],
        const [0.0, 0.7, 1.0],
      );
    canvas.drawArc(ringRect, math.pi * 0.5, math.pi, false, blueCore);

    // Royal Purple Right Arc
    final purpleHalo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22
      ..blendMode = BlendMode.screen
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16)
      ..color = Color.fromRGBO(186, 62, 255, 0.44 * alpha * electricPulse);
    canvas.drawArc(ringRect, -math.pi * 0.5, math.pi, false, purpleHalo);

    final purpleCore = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..blendMode = BlendMode.screen
      ..shader = ui.Gradient.linear(
        Offset(cx - 8, cy),
        Offset(cx + r, cy),
        [
          Color.fromRGBO(245, 175, 255, 0.98 * alpha),
          Color.fromRGBO(192, 68, 252, 0.90 * alpha),
          Color.fromRGBO(147, 51, 234, 0.98 * alpha),
        ],
        const [0.0, 0.45, 1.0],
      );
    canvas.drawArc(ringRect, -math.pi * 0.5, math.pi, false, purpleCore);

    // Rotating Light Streaks orbiting the ring
    for (int k = 0; k < 4; k++) {
      final dir = k.isEven ? 1.0 : -1.0;
      final speed = k < 2 ? 1.15 : 0.72;
      final rot = t * dir * speed + k * (math.pi * 0.5);
      final arcLen = k < 2 ? 0.65 : 0.95;
      final streakR = r + (k.isEven ? 4.0 : -4.0);
      final isBlueSide = math.cos(rot + arcLen * 0.5) < 0;

      final streakPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = k < 2 ? 2.4 : 1.5
        ..blendMode = BlendMode.screen
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
        ..color = isBlueSide
            ? Color.fromRGBO(125, 240, 255, 0.65 * alpha)
            : Color.fromRGBO(240, 171, 252, 0.65 * alpha);
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: streakR),
        rot,
        arcLen,
        false,
        streakPaint,
      );
    }

    // Top Convergence Flare
    final flareCenter = Offset(cx, cy - r);
    final flareRadius = artRect.width * 0.095 * (0.9 + 0.16 * math.sin(t * 3.4));
    final flarePaint = Paint()
      ..blendMode = BlendMode.screen
      ..shader = ui.Gradient.radial(
        flareCenter,
        flareRadius,
        [
          Color.fromRGBO(255, 255, 255, 0.98 * alpha),
          Color.fromRGBO(186, 230, 253, 0.62 * alpha),
          Color.fromRGBO(192, 132, 252, 0.22 * alpha),
          const Color.fromRGBO(168, 85, 247, 0),
        ],
        const [0.0, 0.3, 0.65, 1.0],
      );
    canvas.drawCircle(flareCenter, flareRadius, flarePaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ArenaAtmospherePainter oldDelegate) => true;
}

/// App-wide background smoke (PHASE E E26+E27, 2026-11-24).
///
/// Replaces the 1920x1080 landscape Lottie that put a hard seam
/// mid-screen: the Lottie's fog comes from FINITE matte blobs
/// (7 shapes per band); BoxFit.cover on a portrait phone crops
/// to the middle ~25% horizontal slice, so a matte's edge lands
/// mid-screen as a line and dense overlaps read as foggy
/// patches. This painter has no such mechanism at all:
///
///  * the sprites are the same domain-warped FBM textures as the
///    splash ([ProceduralSmokeTextures]) — each sprite's alpha
///    fades to 0 at its circular edge (soft envelope, no hard
///    edge anywhere);
///  * every cloud fades in/out over its travel
///    (`lifeAlpha = sin(progress * pi)`), so nothing pops in or
///    out at a boundary;
///  * the motion is continuous in [elapsedSeconds] — there is no
///    looping clip, so no first/last-frame jump;
///  * positions are normalized, so any aspect ratio works — no
///    crop, no portrait/landscape mismatch.
///
/// Only the volumetric clouds (+ the two soft side washes) are
/// painted here: no energy ring, no embers, no backdrop — those
/// belong to the splash. Slow on purpose (a cloud takes ~20–50 s
/// to cross the screen) and subtle (the layer wraps this in
/// Opacity 0.20): smoke should breathe behind the poster, never
/// fight the UI.
class SmokeBackgroundPainter extends CustomPainter {
  SmokeBackgroundPainter({
    required this.textures,
    required this.elapsedSeconds,
  });

  final ProceduralSmokeTextures? textures;
  final double elapsedSeconds;

  static final List<_SmokeCloud> _clouds = _buildClouds();

  static List<_SmokeCloud> _buildClouds() {
    final list = <_SmokeCloud>[];
    // 8 blue (left -> right) + 8 purple (right -> left), spread
    // over the full height, three depths, two shadow clouds for
    // depth. Speeds are slow: a full crossing takes ~20-50 s.
    for (int i = 0; i < 8; i++) {
      final depth = i % 3;
      list.add(_SmokeCloud(
        dir: 1,
        depthLayer: depth,
        isShadow: i == 5,
        phase: i / 8.0,
        yBase: _lerp(0.08, 0.95, ((i * 5) % 8) / 7.0),
        speedX: depth == 0 ? 0.020 : depth == 1 ? 0.032 : 0.048,
        swirlAmpY: _lerp(0.02, 0.05, (i % 4) / 3.0),
        scale: depth == 0 ? 0.95 : depth == 1 ? 0.75 : 0.58,
        rotBase: i * 0.7,
        rotSpeed: (i.isEven ? 1.0 : -1.0) * _lerp(0.04, 0.12, depth / 2.0),
        alpha: depth == 0 ? 0.26 : depth == 1 ? 0.33 : 0.40,
      ));
    }
    for (int i = 0; i < 8; i++) {
      final depth = i % 3;
      list.add(_SmokeCloud(
        dir: -1,
        depthLayer: depth,
        isShadow: i == 2,
        phase: i / 8.0,
        yBase: _lerp(0.08, 0.95, ((i * 3) % 8) / 7.0),
        speedX: depth == 0 ? 0.022 : depth == 1 ? 0.035 : 0.052,
        swirlAmpY: _lerp(0.02, 0.05, (i % 4) / 3.0),
        scale: depth == 0 ? 0.95 : depth == 1 ? 0.75 : 0.58,
        rotBase: i * 0.9,
        rotSpeed: (i.isEven ? -1.0 : 1.0) * _lerp(0.04, 0.12, depth / 2.0),
        alpha: depth == 0 ? 0.26 : depth == 1 ? 0.33 : 0.40,
      ));
    }
    return list;
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static double _easeOutCubic(double t) {
    final c = t.clamp(0.0, 1.0);
    return 1.0 - math.pow(1.0 - c, 3).toDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final t = elapsedSeconds;
    // Fade the whole layer in over the first ~0.85 s after the
    // layer mounts (also covers the texture-generation delay —
    // the clouds appear while the master is still ramping).
    final master = _easeOutCubic(t / 0.85);
    if (master <= 0.01) return;

    // 1. Soft side washes (half the splash's alpha — background,
    // not a cinematic): blue left, purple right.
    final leftWash = Paint()
      ..shader = ui.Gradient.radial(
        Offset(size.width * 0.05, size.height * 0.48),
        math.max(size.width, size.height) * 0.65,
        [
          Color.fromRGBO(0, 158, 255, 0.15 * master),
          Color.fromRGBO(0, 82, 204, 0.06 * master),
          const Color.fromRGBO(0, 40, 160, 0),
        ],
        const [0.0, 0.55, 1.0],
      );
    canvas.drawRect(Offset.zero & size, leftWash);

    final rightWash = Paint()
      ..shader = ui.Gradient.radial(
        Offset(size.width * 0.95, size.height * 0.48),
        math.max(size.width, size.height) * 0.65,
        [
          Color.fromRGBO(172, 65, 255, 0.16 * master),
          Color.fromRGBO(110, 0, 210, 0.065 * master),
          const Color.fromRGBO(70, 0, 160, 0),
        ],
        const [0.0, 0.55, 1.0],
      );
    canvas.drawRect(Offset.zero & size, rightWash);

    // 2. Drifting volumetric clouds.
    final tex = textures;
    if (tex == null) return;
    final baseSize = math.max(size.width * 0.72, size.height * 0.46);
    for (final s in _clouds) {
      final progress = (s.phase + t * s.speedX) % 1.0;
      final xNorm =
          s.dir == 1 ? _lerp(-0.14, 0.56, progress) : _lerp(1.14, 0.44, progress);
      // Fade in/out at the ends of the travel — no popping.
      final lifeAlpha = math.sin(progress * math.pi);
      final yNorm = s.yBase + math.sin(t * 0.55 + s.phase * 9.0) * s.swirlAmpY;
      final drawSize = baseSize * s.scale * _lerp(0.88, 1.18, progress);
      final rot = s.rotBase + t * s.rotSpeed;

      final ui.Image sprite;
      if (s.isShadow) {
        sprite = tex.smokeShadow;
      } else if (s.dir == 1) {
        sprite = s.depthLayer == 2 ? tex.blueTendril : tex.blueVolumetric;
      } else {
        sprite = s.depthLayer == 2 ? tex.purpleTendril : tex.purpleVolumetric;
      }

      canvas.save();
      canvas.translate(xNorm * size.width, yNorm * size.height);
      canvas.rotate(rot);
      final paint = Paint()
        ..filterQuality = FilterQuality.low
        ..blendMode = s.isShadow ? BlendMode.srcOver : BlendMode.screen
        ..color = Color.fromRGBO(
          255,
          255,
          255,
          (s.alpha * master * lifeAlpha).clamp(0.0, 1.0),
        );
      final src =
          Rect.fromLTWH(0, 0, sprite.width.toDouble(), sprite.height.toDouble());
      final dst =
          Rect.fromCenter(center: Offset.zero, width: drawSize, height: drawSize);
      canvas.drawImageRect(sprite, src, dst, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant SmokeBackgroundPainter oldDelegate) =>
      oldDelegate.textures != textures ||
      oldDelegate.elapsedSeconds != elapsedSeconds;
}
