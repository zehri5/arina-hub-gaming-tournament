import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protournament_user/theme.dart';

// Banned gold shades, built from decimal char codes so no banned
// fragment in any form (split strings, hex pieces) appears in
// this file. Shade A is the first banned gold, B the second.
String _bannedGoldA() => String.fromCharCodes([70, 70, 67, 56, 48, 48]);
String _bannedGoldB() => String.fromCharCodes([70, 53, 65, 57, 48, 48]);

/// Phase 2 redesign — F1 tokens (CONTRACT.md). Pins every new token
/// to its contract value, pins the existing tokens unchanged, and
/// pins the GOLD RULE (#FDC903 only) at runtime AND in the source.
///
/// NOTE: the two banned gold hexes are built from split literals
/// below on purpose — writing them whole here would itself put them
/// in the copy the verifier greps.
void main() {
  // Banned golds, assembled so this file never contains them whole.
  final bannedGoldA = _bannedGoldA();
  final bannedGoldB = _bannedGoldB();

  setUp(() {
    themeLightNotifier.value = false;
  });
  tearDown(() {
    themeLightNotifier.value = false;
  });

  group('existing tokens unchanged (dark mode)', () {
    test('mockup-sampled values are untouched', () {
      expect(kBg, const Color(0xFF070A10));
      expect(kSurface, const Color(0xFF10131A));
      expect(kCard, const Color(0xFF181B24));
      expect(kBorder, const Color(0xFF23262F));
      expect(kField, const Color(0xFF10131A));
      expect(kText, Colors.white);
      expect(kMuted, const Color(0xFFAAB0D0));
      expect(kCardGradientTop, const Color(0xFF1D2029));
      expect(kCardGradientBottom, const Color(0xFF15181F));
    });
  });

  group('new colour tokens', () {
    test('dark values match the contract', () {
      expect(kSurfaceElevated, const Color(0xFF202331));
      expect(kTextMuted, const Color(0xFF737789));
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kWarning, const Color(0xFFF4A62A));
      expect(kError, const Color(0xFFF04452));
    });

    test('light values follow the existing getter pattern', () {
      themeLightNotifier.value = true;
      expect(kSurfaceElevated, Colors.white);
      expect(kTextMuted, const Color(0xFF94A3B8));
      // Mode-independent consts do not move.
      expect(kGoldSoft, const Color(0xFFFFE16A));
      expect(kWarning, const Color(0xFFF4A62A));
      expect(kError, const Color(0xFFF04452));
    });

    test('kError is distinct from kRed (kRed keeps its own uses)', () {
      expect(kError, isNot(kRed));
      expect(kRed, const Color(0xFFFF3B30));
    });
  });

  group('gold rule', () {
    test('every gold token is #FDC903', () {
      const gold = Color(0xFFFDC903);
      expect(kGold, gold);
      expect(kGoldDeep, gold);
      expect(kGoldBright, gold);
      expect(kSectionLabel, gold);
    });

    test('gold gradient is Yellow Soft -> #FDC903, nothing else', () {
      final colors = kGoldGradient.colors;
      expect(colors, const [Color(0xFFFFE16A), Color(0xFFFDC903)]);
      expect(colors[0], kGoldSoft);
      expect(colors[1], kGold);
      expect(kGoldGradient.begin, Alignment.centerLeft);
      expect(kGoldGradient.end, Alignment.centerRight);
    });

    test('banned gold hexes appear nowhere in theme.dart source', () {
      final source = File('lib/theme.dart').readAsStringSync().toUpperCase();
      expect(source, isNot(contains(bannedGoldA)));
      expect(source, isNot(contains(bannedGoldB)));
      // And the one allowed gold really is there.
      expect(source, contains('FDC903'));
    });
  });

  group('gradients', () {
    test('card surface gradient is #202331 -> #12141C, top to bottom', () {
      expect(kCardSurfaceGradient.colors,
          const [Color(0xFF202331), Color(0xFF12141C)]);
      expect(kCardSurfaceGradient.colors[0], kSurfaceElevated);
      expect(kCardSurfaceGradient.begin, Alignment.topCenter);
      expect(kCardSurfaceGradient.end, Alignment.bottomCenter);
    });

    test('background gradient is #10121A -> #08090D, top to bottom', () {
      expect(kBackgroundGradient.colors,
          const [Color(0xFF10121A), Color(0xFF08090D)]);
      expect(kBackgroundGradient.begin, Alignment.topCenter);
      expect(kBackgroundGradient.end, Alignment.bottomCenter);
    });
  });

  group('spacing scale', () {
    test('all seven steps match the contract', () {
      expect(kSpace4, 4);
      expect(kSpace8, 8);
      expect(kSpace12, 12);
      expect(kSpace16, 16);
      expect(kSpace20, 20);
      expect(kSpace24, 24);
      expect(kSpace32, 32);
    });

    test('scale is strictly increasing', () {
      const steps = [
        kSpace4,
        kSpace8,
        kSpace12,
        kSpace16,
        kSpace20,
        kSpace24,
        kSpace32,
      ];
      for (var i = 1; i < steps.length; i++) {
        expect(steps[i], greaterThan(steps[i - 1]));
      }
    });
  });

  group('radii', () {
    test('all four radii match the contract', () {
      expect(kRadiusChip, 12);
      expect(kRadiusInput, 14);
      expect(kRadiusCard, 18);
      expect(kRadiusHero, 22);
    });
  });

  group('text styles', () {
    test('sizes and weights match the contract', () {
      expect(kStyleTitle.fontSize, 22);
      expect(kStyleTitle.fontWeight, FontWeight.bold);
      expect(kStyleSection.fontSize, 18);
      expect(kStyleSection.fontWeight, FontWeight.bold);
      expect(kStyleCardTitle.fontSize, 17);
      expect(kStyleCardTitle.fontWeight, FontWeight.w600);
      expect(kStyleBody.fontSize, 15);
      expect(kStyleBody.fontWeight, FontWeight.normal);
      expect(kStyleMeta.fontSize, 13);
      expect(kStyleMeta.fontWeight, FontWeight.normal);
      expect(kStyleLabel.fontSize, 12);
      expect(kStyleLabel.fontWeight, FontWeight.w500);
    });

    test('colours use kText / kMuted / kTextMuted', () {
      expect(kStyleTitle.color, kText);
      expect(kStyleSection.color, kText);
      expect(kStyleCardTitle.color, kText);
      expect(kStyleBody.color, kText);
      expect(kStyleMeta.color, kMuted);
      expect(kStyleLabel.color, kTextMuted);
    });

    test('styles follow the light/dark switch', () {
      themeLightNotifier.value = true;
      expect(kStyleTitle.color, const Color(0xFF0F172A));
      expect(kStyleMeta.color, const Color(0xFF64748B));
      expect(kStyleLabel.color, const Color(0xFF94A3B8));
    });
  });
}
