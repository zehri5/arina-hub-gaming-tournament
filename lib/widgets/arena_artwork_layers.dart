import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Decomposes the uploaded ARENA HUB vertical splash artwork into four aligned,
/// alpha-feathered depth layers so each element animates independently along
/// the 0-4.5s+ cinematic timeline without distorting the original art.
class ArenaArtworkLayers {
  ArenaArtworkLayers._({
    required this.backdrop,
    required this.soldier,
    required this.logo,
    required this.tagline,
    required this.artWidth,
    required this.artHeight,
  });

  final ui.Image backdrop;
  final ui.Image soldier;
  final ui.Image logo;
  final ui.Image tagline;
  final int artWidth;
  final int artHeight;

  static Future<ArenaArtworkLayers> loadFromAsset(
    String assetPath, {
    int targetWidth = 640,
  }) async {
    final data = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: targetWidth,
    );
    final frame = await codec.getNextFrame();
    final source = frame.image;
    final w = source.width;
    final h = source.height;
    final byteData = await source.toByteData(format: ui.ImageByteFormat.rawRgba);
    source.dispose();
    codec.dispose();

    if (byteData == null) {
      throw StateError('Failed to decode RGBA bytes from $assetPath');
    }

    final src = byteData.buffer.asUint8List();
    final total = w * h * 4;
    final bgBytes = Uint8List(total);
    final soldierBytes = Uint8List(total);
    final logoBytes = Uint8List(total);
    final taglineBytes = Uint8List(total);

    for (int y = 0; y < h; y++) {
      final ny = y / h;
      for (int x = 0; x < w; x++) {
        final nx = x / w;
        final p = (y * w + x) * 4;

        final r = src[p];
        final g = src[p + 1];
        final b = src[p + 2];
        final luma = 0.299 * r + 0.587 * g + 0.114 * b;

        // 1. Backdrop Layer (sky plane, parachuters, supply crate, watchtower)
        final rx = (nx - 0.50) / 0.42;
        final ry = (ny - 0.34) / 0.23;
        final coreDist = math.sqrt(rx * rx + ry * ry);
        final coreMask = _smoothstep(0.72, 1.15, coreDist);

        final logoBoxDist = math.max(
          (nx - 0.50).abs() / 0.49,
          (ny - 0.56).abs() / 0.175,
        );
        final logoMask = _smoothstep(0.76, 1.08, logoBoxDist);

        // Erase baked static loading bar at bottom so real progress bar renders cleanly
        final barBoxDist = math.max(
          (nx - 0.50).abs() / 0.41,
          (ny - 0.872).abs() / 0.068,
        );
        final barErase = _smoothstep(0.68, 1.05, barBoxDist);
        final sideEdge = _smoothstep(0.0, 0.06, math.min(nx, 1.0 - nx));
        final bgAlpha = (coreMask * logoMask * barErase * sideEdge).clamp(0.0, 1.0);

        bgBytes[p] = r;
        bgBytes[p + 1] = g;
        bgBytes[p + 2] = b;
        bgBytes[p + 3] = (bgAlpha * 255).round();

        // 2. Soldier Layer (ny ~ 0.135 .. 0.515)
        final sdx = (nx - 0.50) / 0.38;
        final sdy = (ny - 0.335) / 0.205;
        final sDist = math.sqrt(sdx * sdx + sdy * sdy);
        final soldierEnv =
            (1.0 - _smoothstep(0.78, 1.04, sDist)) * (1.0 - _smoothstep(0.455, 0.505, ny));
        final soldierLumWeight = _smoothstep(14, 48, luma);
        final soldierAlpha =
            (soldierEnv * (0.35 + 0.65 * soldierLumWeight)).clamp(0.0, 1.0);

        soldierBytes[p] = r;
        soldierBytes[p + 1] = g;
        soldierBytes[p + 2] = b;
        soldierBytes[p + 3] = (soldierAlpha * 255).round();

        // 3. ARENA HUB + Crown Logo Layer (ny ~ 0.398 .. 0.658)
        double logoAlpha = 0.0;
        if (ny >= 0.395 && ny <= 0.662) {
          final inCrownZone = ny < 0.485 && (nx - 0.50).abs() < 0.20;
          final wingWidth = ny < 0.56
              ? _lerp(0.42, 0.495, (ny - 0.470) / 0.09)
              : _lerp(0.495, 0.36, (ny - 0.56) / 0.102);
          final inCrestZone = ny >= 0.468 && (nx - 0.50).abs() <= wingWidth;

          if (inCrownZone || inCrestZone) {
            final edgeX = inCrownZone
                ? 1.0 - _smoothstep(0.15, 0.20, (nx - 0.50).abs())
                : 1.0 - _smoothstep(wingWidth - 0.035, wingWidth, (nx - 0.50).abs());
            final topFade = inCrownZone
                ? _smoothstep(0.395, 0.415, ny)
                : _smoothstep(0.468, 0.486, ny);
            final bottomFade = 1.0 - _smoothstep(0.635, 0.662, ny);
            final chroma = math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
            final lumOrChroma = _smoothstep(22, 62, luma + chroma * 0.65);

            logoAlpha = (edgeX * topFade * bottomFade * lumOrChroma).clamp(0.0, 1.0);
          }
        }
        logoBytes[p] = r;
        logoBytes[p + 1] = g;
        logoBytes[p + 2] = b;
        logoBytes[p + 3] = (logoAlpha * 255).round();

        // 4. Tagline PLAY • COMPETE • WIN + Golden Chevron
        double tagAlpha = 0.0;
        if (ny >= 0.658 && ny <= 0.728 && nx >= 0.15 && nx <= 0.85) {
          final txFade = (1.0 - _smoothstep(0.28, 0.35, (nx - 0.50).abs())) *
              _smoothstep(0.658, 0.668, ny) *
              (1.0 - _smoothstep(0.715, 0.728, ny));
          final brightText = _smoothstep(55, 130, luma);
          tagAlpha = (txFade * brightText).clamp(0.0, 1.0);
        }
        taglineBytes[p] = r;
        taglineBytes[p + 1] = g;
        taglineBytes[p + 2] = b;
        taglineBytes[p + 3] = (tagAlpha * 255).round();
      }
    }

    final decoded = await Future.wait([
      _decodeRgba(bgBytes, w, h),
      _decodeRgba(soldierBytes, w, h),
      _decodeRgba(logoBytes, w, h),
      _decodeRgba(taglineBytes, w, h),
    ]);

    return ArenaArtworkLayers._(
      backdrop: decoded[0],
      soldier: decoded[1],
      logo: decoded[2],
      tagline: decoded[3],
      artWidth: w,
      artHeight: h,
    );
  }

  void dispose() {
    backdrop.dispose();
    soldier.dispose();
    logo.dispose();
    tagline.dispose();
  }

  static Future<ui.Image> _decodeRgba(Uint8List bytes, int w, int h) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(bytes, w, h, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  static double _smoothstep(double edge0, double edge1, double x) {
    final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }
}
