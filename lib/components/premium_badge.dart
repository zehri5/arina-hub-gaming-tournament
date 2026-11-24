// Premium achievement badge (P-all-fixes, Worker F, 2026-11-20 ~18:13 PKT,
// user order on voice call: "is tarah ke premium badges app mein add
// karo, basic wale nahi" — reference crest
// ~/workspace/user/files/1000048989_13_gq9d.jpg: gold winged shield
// with a crown on top, dark/black shield centre, metallic gold wings,
// ornate gold frame).
//
// APPROACH — (b) in the task: the USER'S OWN crest art as the badge
// base, with the per-achievement emblem drawn over its dark shield
// centre. Chosen over (a) (fully drawn crest) because the main agent
// already isolated the crest cleanly (2026-11-20 ~18:16-18:17 PKT):
// `assets/images/splash_crest.png` in this copy IS the user's crest
// (732x783, transparent background, md5 0cca36d4... — corners verified
// alpha 0, no white background, no phone chrome; the agent-made crest
// md5 8a495755... is gone, never restore it). A 732px raster
// downscales crisply to 64dp AND 28dp, and nothing I could draw
// matches his actual crest as faithfully as the crest itself.
// The drawn alternative was considered and rejected for exactly that
// reason — the user's art beats any approximation of it.
//   - The white/silver jagged band across the lower third is part of
//     the user's crest (it is in his screenshot), kept as-is.
//   - The emblem sits inside the dark shield centre, measured from
//     the isolated PNG (centre ~x 0.36-0.63, y 0.44-0.78 of the
//     image; emblem box inset to x 0.405-0.595, y 0.47-0.65).
//   - At small sizes (< 40dp) the emblem would be an unreadable gold
//     blob, so it is omitted there — the crest alone is the badge and
//     the kind is carried by the adjacent label text.
//   - Locked (not yet earned): the whole badge is greyscaled with a
//     ColorFiltered matrix — silver shield, no glow.
// Labels stay the REAL earned achievements — this widget is art only;
// the name mapping below is the same closest-art mapping P already
// used for its badge_*.png files.
//
// Geometry: the widget is exactly `size` wide and size * 783/732
// tall (the crest image's own aspect), so the image fills it with no
// letterbox and no distortion, and the emblem fractions map 1:1.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The five achievement kinds — one emblem each, kept distinct.
/// MISC (2026-11-20): `squadLeader` added for the Profile screen's
/// three DISTINCT badges (mockup §18: FIRST BLOOD = target, SURVIVALIST
/// = shield, SQUAD LEADER = crown) — the old four kinds had no crown,
/// so Squad Leader had no honest emblem. Adding an enum value is
/// backward-compatible: the only switch on this enum is the painter
/// below (extended here), and all other call sites pass `kind`
/// through or iterate `.values`.
enum PremiumBadgeKind { mvp, slayer, survivor, deadshot, squadLeader }

/// Name -> kind. SAME mapping P already used for its badge_*.png files
/// (player_stats.dart `_achievementBadges`): First Win / Top Earner
/// share the MVP trophy, 10 Matches is the Slayer swords, Champion is
/// the Survivor shield, Veteran is the Deadshot target.
/// PROFILE NAMES (MISC 2026-11-20, mockup §18): First Blood is the
/// target/crosshair (NOT the trophy — the old default mapped it to
/// MVP), Survivalist is the shield, Squad Leader is the crown.
/// Unknown names fall back to MVP (trophy) — never a missing badge.
PremiumBadgeKind premiumBadgeKindFor(String achievementName) {
  switch (achievementName) {
    case '10 Matches':
      return PremiumBadgeKind.slayer;
    case 'Champion':
    case 'Survivalist':
      return PremiumBadgeKind.survivor;
    case 'Veteran':
    case 'First Blood':
      return PremiumBadgeKind.deadshot;
    case 'Squad Leader':
      return PremiumBadgeKind.squadLeader;
    case 'First Win':
    case 'Top Earner':
    default:
      return PremiumBadgeKind.mvp;
  }
}

/// Premium achievement badge: the user's own gold winged-shield crest
/// with a crown, plus a drawn gold emblem (trophy / crossed swords /
/// shield / target / crown) inside its dark shield centre.
///
/// PROFILE (MISC 2026-11-20 — for MORE's worker): the Profile
/// screen's three SEPARATE badges use this widget (or the large
/// [PremiumEmblemIcon] below) with:
///   First Blood  -> kind: PremiumBadgeKind.deadshot   (target)
///   Survivalist  -> kind: PremiumBadgeKind.survivor   (shield)
///   Squad Leader -> kind: PremiumBadgeKind.squadLeader (crown)
/// or simply `premiumBadgeKindFor(name)` — the mapping above already
/// resolves all three names. `accent` tints the emblem when a badge
/// needs its own colour (default = gold, exactly as before).
class PremiumAchievementBadge extends StatelessWidget {
  const PremiumAchievementBadge({
    super.key,
    required this.kind,
    this.size = 64,
    this.locked = false,
    this.glow = false,
    this.accent,
  });

  final PremiumBadgeKind kind;

  /// Badge width in dp; height follows the crest aspect (783/732).
  final double size;

  /// Locked (not yet earned): greyscaled crest + emblem, no glow.
  final bool locked;

  /// Soft gold halo behind the badge (Player Stats row, unlocked
  /// Profile tiles). The halo lives inside the box, never clipped.
  final bool glow;

  /// Per-badge emblem colour. Null (default) = the standard metallic
  /// gold — every existing caller renders byte-identically. When set,
  /// the emblem gradient is derived from this colour instead.
  final Color? accent;

  /// Crest image aspect (732x783) — widget height follows it.
  static const double _aspect = 783 / 732;

  /// Emblem box, as fractions of the crest image (measured from the
  /// isolated PNG's dark shield centre, inset so the emblem never
  /// touches the gold rim).
  static const double _emblemLeft = 0.405;
  static const double _emblemTop = 0.47;
  static const double _emblemWidth = 0.19;

  /// Below this width the emblem is an unreadable blob — crest only.
  static const double _minEmblemSize = 40;

  @override
  Widget build(BuildContext context) {
    final height = size * _aspect;
    final emblemSide = size * _emblemWidth;
    final badge = Stack(
      alignment: Alignment.center,
      children: [
        Image.asset(
          'assets/images/splash_crest.png',
          width: size,
          height: height,
          fit: BoxFit.contain,
        ),
        if (size >= _minEmblemSize)
          Positioned(
            left: size * _emblemLeft,
            top: height * _emblemTop,
            width: emblemSide,
            height: emblemSide,
            child: CustomPaint(
              size: Size(emblemSide, emblemSide),
              painter: _PremiumEmblemPainter(kind: kind, accent: accent),
            ),
          ),
      ],
    );
    return SizedBox(
      width: size,
      height: height,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (glow && !locked)
            Container(
              width: size * 0.72,
              height: size * 0.72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFDC903).withValues(alpha: 0.45),
                    blurRadius: size * 0.22,
                    spreadRadius: 0,
                  ),
                ],
              ),
            ),
          if (locked)
            ColorFiltered(
              colorFilter: const ColorFilter.matrix(<double>[
                0.2126, 0.7152, 0.0722, 0, 0,
                0.2126, 0.7152, 0.0722, 0, 0,
                0.2126, 0.7152, 0.0722, 0, 0,
                0, 0, 0, 1, 0,
              ]),
              child: badge,
            )
          else
            badge,
        ],
      ),
    );
  }
}

/// Large single emblem (no crest) for the Profile achievement preview
/// cards — MOCKUP FIX (2026-11-20, user order): the three preview
/// cards each showed the SAME crest (the kind emblem inside it is
/// ~8px at 44dp, invisible), so all three looked identical. The
/// mockup's three badges are three DIFFERENT big icons (target /
/// shield / crown), so the preview shows the kind emblem LARGE
/// instead — trophy / swords / shield / target / crown, gold with a
/// halo when unlocked, greyscaled + no glow when locked.
///
/// PROFILE (MISC 2026-11-20 — for MORE's worker): use
/// `kind: premiumBadgeKindFor(a.name)` as today — 'First Blood',
/// 'Survivalist' and 'Squad Leader' now resolve to the target, the
/// shield and the crown respectively. `accent` is optional per-badge
/// colour (default gold, as before).
class PremiumEmblemIcon extends StatelessWidget {
  const PremiumEmblemIcon({
    super.key,
    required this.kind,
    this.size = 44,
    this.locked = false,
    this.glow = false,
    this.accent,
  });

  final PremiumBadgeKind kind;
  final double size;
  final bool locked;
  final bool glow;

  /// Per-badge emblem colour (see [PremiumAchievementBadge.accent]).
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final emblem = CustomPaint(
      size: Size(size, size),
      painter: _PremiumEmblemPainter(kind: kind, accent: accent),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (glow && !locked)
            Container(
              width: size * 0.72,
              height: size * 0.72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFDC903).withValues(alpha: 0.45),
                    blurRadius: size * 0.22,
                    spreadRadius: 0,
                  ),
                ],
              ),
            ),
          if (locked)
            ColorFiltered(
              colorFilter: const ColorFilter.matrix(<double>[
                0.2126, 0.7152, 0.0722, 0, 0,
                0.2126, 0.7152, 0.0722, 0, 0,
                0.2126, 0.7152, 0.0722, 0, 0,
                0, 0, 0, 1, 0,
              ]),
              child: emblem,
            )
          else
            emblem,
        ],
      ),
    );
  }
}

/// The emblem inside the dark shield centre, drawn in metallic gold
/// (or the per-badge [accent] colour when one is given).
/// Same emblems as M's `_AchievementEmblemPainter` (trophy / crossed
/// swords / shield / target) plus the Squad Leader crown (MISC
/// 2026-11-20), re-centred into the crest's shield interior.
class _PremiumEmblemPainter extends CustomPainter {
  const _PremiumEmblemPainter({required this.kind, this.accent});
  final PremiumBadgeKind kind;

  /// Per-badge colour; null = the standard metallic gold family.
  final Color? accent;

  // Metallic gold family (#FDC903) — fixed consts, NOT theme kGold,
  // so the emblem looks identical in light/dark mode and in tests.
  static const _goldLight = Color(0xFFFDC903);
  static const _gold = Color(0xFFFDC903);
  static const _goldDeep = Color(0xFFFDC903);

  // Gradient tones: the gold family by default; derived from
  // [accent] (lightened / darkened) when a badge has its own colour.
  Color get _light => accent == null ? _goldLight : Color.lerp(accent!, Colors.white, 0.35)!;
  Color get _mid => accent ?? _gold;
  Color get _deep => accent == null ? _goldDeep : Color.lerp(accent!, Colors.black, 0.30)!;

  @override
  void paint(Canvas canvas, Size size) {
    switch (kind) {
      case PremiumBadgeKind.mvp:
        _trophy(canvas, size);
      case PremiumBadgeKind.survivor:
        _shield(canvas, size);
      case PremiumBadgeKind.slayer:
        _swords(canvas, size);
      case PremiumBadgeKind.deadshot:
        _target(canvas, size);
      case PremiumBadgeKind.squadLeader:
        _crown(canvas, size);
    }
  }

  void _trophy(Canvas canvas, Size size, {bool star = false}) {
    final s = size.width;
    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_light, _mid, _deep],
      ).createShader(Rect.fromLTWH(0, 0, s, s));
    final stroke = Paint()
      ..color = _mid
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.07
      ..strokeCap = StrokeCap.round;
    // With a star above the cup the whole trophy shifts down.
    final top = star ? 0.20 : 0.08;
    final bottom = star ? 0.92 : 0.90;
    final neckY = top + 0.36;
    // Bowl: wide top, tapering to a narrow neck.
    final bowl = Path()
      ..moveTo(s * 0.16, s * top)
      ..lineTo(s * 0.84, s * top)
      ..quadraticBezierTo(s * 0.84, s * (top + 0.34), s * 0.60, s * neckY)
      ..lineTo(s * 0.40, s * neckY)
      ..quadraticBezierTo(s * 0.16, s * (top + 0.34), s * 0.16, s * top)
      ..close();
    canvas.drawPath(bowl, fill);
    // Handles: open arcs on both sides of the bowl.
    canvas.drawPath(
      Path()
        ..moveTo(s * 0.17, s * (top + 0.05))
        ..quadraticBezierTo(0, s * (top + 0.14), s * 0.17, s * (top + 0.28)),
      stroke,
    );
    canvas.drawPath(
      Path()
        ..moveTo(s * 0.83, s * (top + 0.05))
        ..quadraticBezierTo(s, s * (top + 0.14), s * 0.83, s * (top + 0.28)),
      stroke,
    );
    // Stem + flared base.
    canvas.drawRect(Rect.fromLTWH(s * 0.45, s * neckY, s * 0.10, s * 0.16), fill);
    final base = Path()
      ..moveTo(s * 0.34, s * (neckY + 0.16))
      ..lineTo(s * 0.66, s * (neckY + 0.16))
      ..lineTo(s * 0.72, s * bottom)
      ..lineTo(s * 0.28, s * bottom)
      ..close();
    canvas.drawPath(base, fill);
    if (star) _star(canvas, Offset(s * 0.5, s * 0.09), s * 0.085);
  }

  // Survivor shield (MOCKUP FIX 2026-11-20): the old emblem
  // (trophy + star) looked identical to the MVP trophy at a
  // glance — the mockup's
  // Survivalist badge is a SHIELD, so the survivor emblem is a gold
  // shield with a dark star in its centre. Distinct from the trophy,
  // swords and target at any size.
  void _shield(Canvas canvas, Size size) {
    final s = size.width;
    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_light, _mid, _deep],
      ).createShader(Rect.fromLTWH(0, 0, s, s));
    final path = Path()
      ..moveTo(s * 0.16, s * 0.10)
      ..lineTo(s * 0.84, s * 0.10)
      ..quadraticBezierTo(s * 0.86, s * 0.52, s * 0.50, s * 0.92)
      ..quadraticBezierTo(s * 0.14, s * 0.52, s * 0.16, s * 0.10)
      ..close();
    canvas.drawPath(path, fill);
    _star(canvas, Offset(s * 0.5, s * 0.42), s * 0.13, accent == null ? const Color(0xFF6B4E0B) : Color.lerp(accent!, Colors.black, 0.55)!);
  }

  // Squad Leader crown (MISC 2026-11-20, mockup §18): a 3-point
  // crown with a base band and gems on the spike tips — distinct
  // from the trophy, swords, shield and target at any size.
  void _crown(Canvas canvas, Size size) {
    final s = size.width;
    final fill = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [_light, _mid, _deep],
      ).createShader(Rect.fromLTWH(0, 0, s, s));
    final crown = Path()
      ..moveTo(s * 0.12, s * 0.86)
      ..lineTo(s * 0.12, s * 0.42)
      ..lineTo(s * 0.30, s * 0.58)
      ..lineTo(s * 0.50, s * 0.14)
      ..lineTo(s * 0.70, s * 0.58)
      ..lineTo(s * 0.88, s * 0.42)
      ..lineTo(s * 0.88, s * 0.86)
      ..close();
    canvas.drawPath(crown, fill);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(s * 0.10, s * 0.80, s * 0.80, s * 0.10), Radius.circular(s * 0.05)),
      Paint()..color = _deep,
    );
    for (final tip in [const Offset(0.12, 0.42), const Offset(0.50, 0.14), const Offset(0.88, 0.42)]) {
      canvas.drawCircle(Offset(s * tip.dx, s * tip.dy), s * 0.05, Paint()..color = _light);
    }
  }

  void _star(Canvas canvas, Offset c, double r, [Color color = const Color(0xFFFDC903)]) {
    final path = Path();
    for (var i = 0; i < 5; i++) {
      final aOuter = -math.pi / 2 + i * 2 * math.pi / 5;
      final aInner = aOuter + math.pi / 5;
      final o = Offset(c.dx + r * math.cos(aOuter), c.dy + r * math.sin(aOuter));
      final n = Offset(c.dx + r * 0.45 * math.cos(aInner), c.dy + r * 0.45 * math.sin(aInner));
      if (i == 0) {
        path.moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
      path.lineTo(n.dx, n.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _swords(Canvas canvas, Size size) {
    final s = size.width;
    final paint = Paint()
      ..color = _mid
      ..strokeWidth = s * 0.09
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    // Blade 1: top-left hilt -> bottom-right tip.
    canvas.drawLine(Offset(s * 0.17, s * 0.17), Offset(s * 0.83, s * 0.83), paint);
    // Blade 2: top-right hilt -> bottom-left tip.
    canvas.drawLine(Offset(s * 0.83, s * 0.17), Offset(s * 0.17, s * 0.83), paint);
    // Guards: short ticks perpendicular to each blade, near the hilts.
    canvas.drawLine(Offset(s * 0.17, s * 0.33), Offset(s * 0.33, s * 0.17), paint);
    canvas.drawLine(Offset(s * 0.67, s * 0.17), Offset(s * 0.83, s * 0.33), paint);
  }

  void _target(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s / 2);
    final ring = Paint()
      ..color = _mid
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.07;
    canvas.drawCircle(c, s * 0.34, ring);
    canvas.drawCircle(
      c,
      s * 0.20,
      Paint()
        ..color = _mid
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.06,
    );
    canvas.drawCircle(c, s * 0.08, Paint()..color = _mid);
    // Crosshair ticks: from outside the ring, crossing its edge.
    final tick = Paint()
      ..color = _mid
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.06
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(c.dx, s * 0.02), Offset(c.dx, s * 0.20), tick);
    canvas.drawLine(Offset(c.dx, s * 0.80), Offset(c.dx, s * 0.98), tick);
    canvas.drawLine(Offset(s * 0.02, c.dy), Offset(s * 0.20, c.dy), tick);
    canvas.drawLine(Offset(s * 0.80, c.dy), Offset(s * 0.98, c.dy), tick);
  }

  @override
  bool shouldRepaint(covariant _PremiumEmblemPainter old) => old.kind != kind || old.accent != accent;
}
