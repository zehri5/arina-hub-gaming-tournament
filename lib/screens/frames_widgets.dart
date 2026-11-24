import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../components/cached_image.dart';
import '../services/supabase_db.dart';
import '../utils.dart';

/// AVATAR FRAMES — original Flutter-drawn borders, NO downloaded art,
/// NO copied game assets. Presets are colour/gradient rings (+ a crown
/// badge for the crown preset). An admin-pasted image_url, when set,
/// is used as the outer ring image only.
///
/// Degrade gracefully: frame == null/empty => plain avatar, always.
///
/// Cache: equipped frames are cached per uid for a session (chat lists
/// would otherwise query per message). The shop clears the cache on
/// buy/equip/unequip, so a change reflects on the next screen open.
class FrameCache {
  static final Map<String, Map<String, dynamic>?> _cache = {};
  static Future<Map<String, dynamic>?> equipped(String uid) async {
    if (uid.isEmpty) return null;
    if (_cache.containsKey(uid)) return _cache[uid];
    final f = await SupaDb.getEquippedFrame(uid);
    // Never cache a null: a user who equips a frame later (shop, or
    // another device) must see it on the next build, not a stale
    // session-long "no frame". Only real frames are cached; the shop
    // invalidates on buy/equip/unequip, and the room refreshes on
    // return from the shop (see room_screen.dart).
    if (f.isEmpty) return null;
    _cache[uid] = f;
    return f;
  }

  static void invalidate([String? uid]) {
    if (uid == null) {
      _cache.clear();
    } else {
      _cache.remove(uid);
    }
  }
}

/// ROUND 11 — profile-photo cache. Root cause of the mic-photo bug:
/// Profile writes `profiles.photo_url` (frames_screen _changePhoto),
/// and the Profile page passes it explicitly, but the room seat
/// avatar, member strip, chat avatar, Status sheet and leaderboard
/// all called CachedFramedAvatar WITHOUT photoUrl, so they always
/// fell back to the initial letter. This cache lets
/// CachedFramedAvatar resolve the photo itself from `profiles`,
/// with a short 30 s TTL so a photo changed mid-session appears in
/// the current room (room rebuilds on the peer poll) without a
/// network fetch on every build, and without a peer-table migration
/// (voice_signaling_peers carries no photo column).
class PhotoCache {
  static final Map<String, String> _photos = {};
  static final Map<String, DateTime> _at = {};
  static const _ttl = Duration(seconds: 30);

  static Future<String> photo(String uid) async {
    if (uid.isEmpty) return '';
    final t = _at[uid];
    if (t != null && DateTime.now().difference(t) < _ttl && _photos.containsKey(uid)) {
      return _photos[uid]!;
    }
    try {
      final p = await SupaDb.getProfile(uid);
      final url = SupaDb.strOf(p['photoURL']);
      _photos[uid] = url;
      _at[uid] = DateTime.now();
      return url;
    } catch (_) {
      return _photos[uid] ?? '';
    }
  }

  static void invalidate([String? uid]) {
    if (uid == null) {
      _photos.clear();
      _at.clear();
    } else {
      _photos.remove(uid);
      _at.remove(uid);
    }
  }
}

class FrameStyle {
  final String label;
  final List<Color> gradient;
  final IconData icon;
  const FrameStyle(this.label, this.gradient, this.icon);
}

/// Built-in preset metadata (labels shown in shop + admin picker).
FrameStyle frameStyleOf(String preset) {
  switch (preset) {
    case 'diamond':
      return FrameStyle('Diamond', [Color(0xFF67E8F9), Color(0xFF3B82F6)], Icons.diamond);
    case 'fire':
      return FrameStyle('Fire', [Color(0xFFF97316), Color(0xFFEF4444)], Icons.local_fire_department);
    case 'neon':
      return FrameStyle('Neon', [Color(0xFF4ADE80), Color(0xFFA855F7)], Icons.bolt);
    case 'crown':
      return FrameStyle('Crown', [kGold, Color(0xFFF59E0B)], Icons.workspace_premium);
    case 'laurel_gold':
      return FrameStyle('Laurel Gold', [kGold, Color(0xFFFDC903)], Icons.eco);
    case 'wings_silver':
      return FrameStyle('Silver Wings', [Color(0xFFE2E8F0), Color(0xFF64748B)], Icons.air);
    case 'gem_ruby':
      return FrameStyle('Ruby Gems', [Color(0xFFF43F5E), Color(0xFF9F1239)], Icons.diamond);
    case 'starburst':
      return FrameStyle('Starburst', [kGold, Color(0xFFF97316)], Icons.star);
    case 'emerald_royal':
      return FrameStyle('Emerald Royal', [Color(0xFF34D399), Color(0xFFFDC903)], Icons.stars);
    case 'blaze':
      return FrameStyle('Blaze', [Color(0xFFF97316), Color(0xFFB91C1C)], Icons.local_fire_department);
    case 'moonlight':
      return FrameStyle('Moonlight', [Color(0xFF93C5FD), Color(0xFF4338CA)], Icons.nightlight_round);
    // ADMIN PREMIUM FRAMES — DEMO-STYLE REDESIGN (2026-10-30):
    // the previous 10 designs are DELETED and replaced by these 10
    // ornate crown frames in the user's demo style: big gold crown
    // on top, gold filigree ring, pearls, gem colours, glowing
    // energy, all animated. Original Flutter-painted geometry only
    // (no demo image, artwork, or photo is copied or embedded).
    // Admin-only, free, from the admin-only picker; storage is the
    // fixed-uuid user_frames row (see SupaDb.adminFrameUuids).
    case 'admin_royal_gold':
      return FrameStyle('Crown Royale Blue-Gold', [Color(0xFFFDC903), Color(0xFF2563EB), Color(0xFFFDC903)], Icons.workspace_premium);
    case 'admin_diamond_crown':
      return FrameStyle('Diamond Crown Ice', [Color(0xFF67E8F9), Color(0xFFFFFFFF), Color(0xFF0EA5E9)], Icons.workspace_premium);
    case 'admin_emerald_royal':
      return FrameStyle('Emerald Crown Royal', [Color(0xFF34D399), Color(0xFFFDC903), Color(0xFF065F46)], Icons.stars);
    case 'admin_ruby_regal':
      return FrameStyle('Ruby Fire Crown', [Color(0xFFF43F5E), Color(0xFFFDC903), Color(0xFF881337)], Icons.local_fire_department);
    case 'admin_sapphire_elite':
      return FrameStyle('Sapphire Ocean Crown', [Color(0xFF1D4ED8), Color(0xFF60A5FA), Color(0xFFDBEAFE)], Icons.waves);
    case 'admin_obsidian_gold':
      return FrameStyle('Obsidian Gold Crown', [Color(0xFFFDC903), Color(0xFF1F2937), Color(0xFF000000)], Icons.emoji_events);
    case 'admin_crimson_flame':
      return FrameStyle('Crimson Flame Crown', [Color(0xFFEF4444), Color(0xFFF97316), Color(0xFFFDC903)], Icons.local_fire_department);
    case 'admin_violet_majesty':
      return FrameStyle('Violet Majesty Crown', [Color(0xFFA855F7), Color(0xFFF0ABFC), Color(0xFF581C87)], Icons.bolt);
    case 'admin_arctic_aurora':
      return FrameStyle('Arctic Aurora Crown', [Color(0xFFA5F3FC), Color(0xFFFFFFFF), Color(0xFF0E7490)], Icons.nightlight_round);
    case 'admin_solar_eclipse':
      return FrameStyle('Solar Fire Crown', [Color(0xFFFB923C), Color(0xFFFDC903), Color(0xFF7C2D12)], Icons.wb_sunny);
    case 'gold_royal':
    default:
      return FrameStyle('Gold Royal', [kGold, Color(0xFFFDC903)], Icons.emoji_events);
  }
}

/// ADMIN PREMIUM FRAME CATALOGUE (2026-10-30, storage FIXED
/// 2026-10-30): the 10 admin-only frames. `id` is the style_preset
/// (rendered by FramedAvatar); user_frames stores the preset's FIXED
/// uuid (see SupaDb.adminFrameUuids) because frame_id is uuid.
/// Nothing here touches the shop: the matching frames rows are
/// inactive, so the shop never lists them.
bool isAdminFrameId(String id) => id.startsWith('admin_');

const List<Map<String, String>> kAdminFramePresets = [
  {'id': 'admin_royal_gold', 'label': 'Crown Royale Blue-Gold', 'desc': 'Big gold crown, royal blue gems, blue-gold glowing energy.'},
  {'id': 'admin_diamond_crown', 'label': 'Diamond Crown Ice', 'desc': 'Gold crown, icy diamond twinkles, cold white-blue glow.'},
  {'id': 'admin_emerald_royal', 'label': 'Emerald Crown Royal', 'desc': 'Gold crown, emerald gems, gold starburst rays, royal glow.'},
  {'id': 'admin_ruby_regal', 'label': 'Ruby Fire Crown', 'desc': 'Gold crown, ruby gems, flickering fire tongues, hot glow.'},
  {'id': 'admin_sapphire_elite', 'label': 'Sapphire Ocean Crown', 'desc': 'Gold crown, sapphire gems, ocean wave shimmer, deep blue glow.'},
  {'id': 'admin_obsidian_gold', 'label': 'Obsidian Gold Crown', 'desc': 'Gold crown on black-gold filigree, white-gold sparkles.'},
  {'id': 'admin_crimson_flame', 'label': 'Crimson Flame Crown', 'desc': 'Gold crown ringed in full crimson fire, blazing glow.'},
  {'id': 'admin_violet_majesty', 'label': 'Violet Majesty Crown', 'desc': 'Gold crown, violet neon pulse, purple gem glow.'},
  {'id': 'admin_arctic_aurora', 'label': 'Arctic Aurora Crown', 'desc': 'Gold crown, ice twinkles + moon crescent, frosty glow.'},
  {'id': 'admin_solar_eclipse', 'label': 'Solar Fire Crown', 'desc': 'Gold crown, solar rays + flame tongues, blazing sun glow.'},
];

/// Ornate frame decorations, drawn with ORIGINAL Flutter geometry
/// (laurel leaves, wing feathers, gem dots, starburst rays, flame
/// tongues, a moon crescent, crown spikes — all computed from circles
/// and paths, no images, no copied artwork). `t` is the animation
/// phase 0..1; flame heights and sparkles move with it.
class _OrnatePainter extends CustomPainter {
  final String preset;
  final double t;
  const _OrnatePainter(this.preset, this.t);

  Offset _pt(Offset c, double r, double deg) {
    final a = deg * math.pi / 180;
    return Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a));
  }

  void _leaf(Canvas canvas, Offset c, double r, double deg, double len, double wid, Color color) {
    final p = _pt(c, r, deg);
    final tangent = deg + 90;
    final a = tangent * math.pi / 180;
    final dx = math.cos(a);
    final dy = math.sin(a);
    final path = Path()
      ..moveTo(p.dx - dx * len / 2, p.dy - dy * len / 2)
      ..quadraticBezierTo(p.dx + -dy * wid, p.dy + dx * wid, p.dx + dx * len / 2, p.dy + dy * len / 2)
      ..quadraticBezierTo(p.dx + dy * wid, p.dy - dx * wid, p.dx - dx * len / 2, p.dy - dy * len / 2)
      ..close();
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
  }

  void _dot(Canvas canvas, Offset p, double r, Color color, {Color? hi}) {
    canvas.drawCircle(p, r, Paint()..color = color);
    if (hi != null) canvas.drawCircle(Offset(p.dx - r * 0.3, p.dy - r * 0.3), r * 0.35, Paint()..color = hi);
  }

  void _star4(Canvas canvas, Offset p, double r, Color color) {
    final path = Path()
      ..moveTo(p.dx, p.dy - r)
      ..quadraticBezierTo(p.dx, p.dy, p.dx + r, p.dy)
      ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy + r)
      ..quadraticBezierTo(p.dx, p.dy, p.dx - r, p.dy)
      ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy - r)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 1;
    // ADMIN PREMIUM FRAMES — DEMO-STYLE REDESIGN (2026-10-30):
    // every admin frame shares the demo's ornate language, drawn
    // with original Flutter geometry only (no image, no copied
    // artwork): a BIG gold crown across the top, a gold filigree
    // ring, pearl dots, gem dots in the family's colour, and
    // rotating glowing sparkles — plus one family motif each
    // (flames / rays / waves / twinkles / moon). The glow halo
    // itself lives in FramedAvatar (pulsing, strongest in the app).
    if (preset.startsWith('admin_')) {
      final accent = preset == 'admin_royal_gold'
          ? const Color(0xFF2563EB)
          : preset == 'admin_diamond_crown'
              ? const Color(0xFF67E8F9)
              : preset == 'admin_emerald_royal'
                  ? const Color(0xFF34D399)
                  : preset == 'admin_ruby_regal'
                      ? const Color(0xFFF43F5E)
                      : preset == 'admin_sapphire_elite'
                          ? const Color(0xFF1D4ED8)
                          : preset == 'admin_violet_majesty'
                              ? const Color(0xFFA855F7)
                              : preset == 'admin_arctic_aurora'
                                  ? const Color(0xFFA5F3FC)
                                  : preset == 'admin_crimson_flame'
                                      ? const Color(0xFFEF4444)
                                      : preset == 'admin_solar_eclipse'
                                          ? const Color(0xFFFB923C)
                                          : kGold;
      // Filigree ring: alternating gold leaves + gem dots.
      for (var i = 0; i < 16; i++) {
        final deg = i * 22.5;
        if (i.isEven) {
          _dot(canvas, _pt(c, r + 2, deg.toDouble()), r * 0.07, accent, hi: Colors.white);
        } else {
          _leaf(canvas, c, r + 1, deg.toDouble(), r * 0.22, r * 0.09, kGold);
        }
      }
      // Pearls: small white dots offset from the gems.
      for (var i = 0; i < 8; i++) {
        final deg = i * 45 + 22;
        _dot(canvas, _pt(c, r + 2, deg.toDouble()), r * 0.05, Colors.white, hi: Colors.white);
      }
      // Rotating glowing sparkles (the "energy" around the ring).
      for (var i = 0; i < 4; i++) {
        final deg = i * 90 + t * 30;
        _star4(canvas, _pt(c, r + 2, deg), r * 0.12, i.isEven ? Colors.white : const Color(0xFFFDC903));
      }
      // BIG GOLD CROWN across the top (the demo's signature): a
      // band along the top arc + 5 spikes, centre spike tallest,
      // with a gem at the band's centre. Drawn in gold with an
      // accent gem so it reads at every avatar size.
      final crownBand = Path();
      crownBand.moveTo(_pt(c, r + 1, -150).dx, _pt(c, r + 1, -150).dy);
      for (var deg = -150; deg <= -30; deg += 6) {
        final p = _pt(c, r + 1, deg.toDouble());
        crownBand.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
          crownBand,
          Paint()
            ..color = kGold
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 0.14);
      for (var i = -2; i <= 2; i++) {
        final deg = -90 + i * 26;
        final tall = i == 0 ? 0.34 : (i.abs() == 1 ? 0.28 : 0.22);
        final tip = _pt(c, r + r * tall, deg.toDouble());
        final left = _pt(c, r + 1, deg - 9);
        final right = _pt(c, r + 1, deg + 9);
        final path = Path()
          ..moveTo(left.dx, left.dy)
          ..lineTo(tip.dx, tip.dy)
          ..lineTo(right.dx, right.dy)
          ..close();
        canvas.drawPath(path, Paint()..color = kGold);
        _dot(canvas, tip, r * 0.06, i == 0 ? accent : Colors.white, hi: Colors.white);
      }
      _dot(canvas, _pt(c, r + 1, -90), r * 0.1, accent, hi: Colors.white);
      // Family motif.
      if (preset == 'admin_ruby_regal' || preset == 'admin_crimson_flame' || preset == 'admin_solar_eclipse') {
        // Fire: flickering flame tongues around the lower ring.
        for (var i = 0; i < 8; i++) {
          final deg = 20 + i * 45;
          if (deg > 160 && deg < 200) continue; // keep the crown clear
          final flick = 0.7 + 0.3 * math.sin(2 * math.pi * t * 2 + i * 1.3);
          final tip = _pt(c, r + r * 0.26 * flick, deg.toDouble());
          final left = _pt(c, r + 1, deg - 9);
          final right = _pt(c, r + 1, deg + 9);
          final path = Path()
            ..moveTo(left.dx, left.dy)
            ..quadraticBezierTo(tip.dx, tip.dy, right.dx, right.dy)
            ..close();
          canvas.drawPath(path, Paint()..color = i.isEven ? const Color(0xFFF97316) : const Color(0xFFEF4444));
        }
      } else if (preset == 'admin_emerald_royal' || preset == 'admin_solar_eclipse') {
        // Starburst rays (emerald; solar already has flames above,
        // so this branch is emerald-only in practice).
        for (var i = 0; i < 12; i++) {
          final deg = i * 30 + t * 12;
          final tip = _pt(c, r + r * 0.22, deg.toDouble());
          final left = _pt(c, r + 1, deg - 7);
          final right = _pt(c, r + 1, deg + 7);
          final path = Path()
            ..moveTo(left.dx, left.dy)
            ..lineTo(tip.dx, tip.dy)
            ..lineTo(right.dx, right.dy)
            ..close();
          canvas.drawPath(path, Paint()..color = i.isEven ? kGold : accent);
        }
      } else if (preset == 'admin_sapphire_elite') {
        // Ocean waves: three shimmering arcs along the lower ring.
        for (var k = 0; k < 3; k++) {
          final wave = Path();
          for (var deg = 30; deg <= 150; deg += 6) {
            final wob = math.sin(2 * math.pi * t + deg * 0.12 + k) * r * 0.05;
            final p = _pt(c, r + 2 + k * r * 0.08 + wob, deg.toDouble());
            if (deg == 30) {
              wave.moveTo(p.dx, p.dy);
            } else {
              wave.lineTo(p.dx, p.dy);
            }
          }
          canvas.drawPath(
              wave,
              Paint()
                ..color = k == 1 ? const Color(0xFF60A5FA) : accent
                ..style = PaintingStyle.stroke
                ..strokeWidth = r * 0.07);
        }
      } else if (preset == 'admin_arctic_aurora' || preset == 'admin_diamond_crown') {
        // Ice twinkles + moon crescent (top right, clear of crown).
        final moon = Offset(c.dx + r * 0.62, c.dy - r * 0.62);
        final crescent = Path()
          ..addOval(Rect.fromCircle(center: moon, radius: r * 0.22))
          ..addOval(Rect.fromCircle(center: Offset(moon.dx + r * 0.09, moon.dy - r * 0.06), radius: r * 0.18))
          ..fillType = PathFillType.evenOdd;
        canvas.drawPath(crescent, Paint()..color = const Color(0xFFDBEAFE));
        for (var i = 0; i < 4; i++) {
          final deg = 200 + i * 18 + t * 8;
          _star4(canvas, _pt(c, r + 2, deg), r * 0.09, i.isEven ? Colors.white : accent);
        }
      }
      return;
    }
    switch (preset) {
      case 'laurel_gold':
        // Laurel wreath: leaves up both sides, gap at the top centre.
        for (var i = 0; i < 7; i++) {
          final deg = 115 + i * 20;
          _leaf(canvas, c, r + 1, deg.toDouble(), r * 0.34, r * 0.13, i.isEven ? kGold : const Color(0xFFFDC903));
          _leaf(canvas, c, r + 1, (-deg).toDouble(), r * 0.34, r * 0.13, i.isEven ? kGold : const Color(0xFFFDC903));
        }
        break;
      case 'wings_silver':
        // Wing feathers: three tapered arcs fanning from each side.
        for (final side in [-1, 1]) {
          for (var i = 0; i < 3; i++) {
            final base = Offset(c.dx + side * (r - 2), c.dy - 6 + i * 7);
            final tip = Offset(c.dx + side * (r + 12 + i * 4), c.dy - 14 + i * 9);
            final path = Path()
              ..moveTo(base.dx, base.dy)
              ..quadraticBezierTo(c.dx + side * (r + 6), c.dy - 10 + i * 7, tip.dx, tip.dy)
              ..quadraticBezierTo(c.dx + side * (r + 2), c.dy - 2 + i * 7, base.dx, base.dy + 4)
              ..close();
            canvas.drawPath(path, Paint()..color = i == 1 ? const Color(0xFFE2E8F0) : const Color(0xFF94A3B8));
          }
        }
        break;
      case 'gem_ruby':
      case 'diamond':
      case 'emerald_royal':
        // Gem dots around the ring (colour per preset).
        final gem = preset == 'gem_ruby'
            ? const Color(0xFFF43F5E)
            : preset == 'emerald_royal'
                ? const Color(0xFF34D399)
                : const Color(0xFF67E8F9);
        for (var i = 0; i < 8; i++) {
          final deg = i * 45 + 22;
          _dot(canvas, _pt(c, r + 2, deg.toDouble()), r * 0.09, gem, hi: Colors.white);
        }
        break;
      case 'starburst':
        // Starburst rays radiating out from the ring.
        for (var i = 0; i < 12; i++) {
          final deg = i * 30 + t * 12;
          final tip = _pt(c, r + r * 0.22, deg.toDouble());
          final left = _pt(c, r + 1, deg - 7);
          final right = _pt(c, r + 1, deg + 7);
          final path = Path()
            ..moveTo(left.dx, left.dy)
            ..lineTo(tip.dx, tip.dy)
            ..lineTo(right.dx, right.dy)
            ..close();
          canvas.drawPath(path, Paint()..color = i.isEven ? kGold : const Color(0xFFF97316));
        }
        break;
      case 'fire':
      case 'blaze':
        // Flame tongues around the ring, heights flickering with t.
        for (var i = 0; i < 8; i++) {
          final deg = i * 45;
          final flick = 0.7 + 0.3 * math.sin(2 * math.pi * t * 2 + i * 1.3);
          final tip = _pt(c, r + r * 0.24 * flick, deg.toDouble());
          final left = _pt(c, r + 1, deg - 9);
          final right = _pt(c, r + 1, deg + 9);
          final path = Path()
            ..moveTo(left.dx, left.dy)
            ..quadraticBezierTo(tip.dx, tip.dy, right.dx, right.dy)
            ..close();
          canvas.drawPath(path, Paint()..color = i.isEven ? const Color(0xFFF97316) : const Color(0xFFEF4444));
        }
        break;
      case 'moonlight':
        // Moon crescent (top right) + small stars.
        final moon = Offset(c.dx + r * 0.62, c.dy - r * 0.62);
        final crescent = Path()
          ..addOval(Rect.fromCircle(center: moon, radius: r * 0.22))
          ..addOval(Rect.fromCircle(center: Offset(moon.dx + r * 0.09, moon.dy - r * 0.06), radius: r * 0.18))
          ..fillType = PathFillType.evenOdd;
        canvas.drawPath(crescent, Paint()..color = const Color(0xFFDBEAFE));
        _star4(canvas, _pt(c, r + 2, 200), r * 0.09, Colors.white);
        _star4(canvas, _pt(c, r + 2, 250), r * 0.07, const Color(0xFF93C5FD));
        break;
      case 'crown':
        // Crown spikes across the top arc.
        for (var i = -1; i <= 1; i++) {
          final deg = -90 + i * 28;
          final tip = _pt(c, r + r * 0.24, deg.toDouble());
          final left = _pt(c, r + 1, deg - 10);
          final right = _pt(c, r + 1, deg + 10);
          final path = Path()
            ..moveTo(left.dx, left.dy)
            ..lineTo(tip.dx, tip.dy)
            ..lineTo(right.dx, right.dy)
            ..close();
          canvas.drawPath(path, Paint()..color = kGold);
        }
        break;
      case 'neon':
        for (var i = 0; i < 8; i++) {
          final deg = i * 45;
          _dot(canvas, _pt(c, r + 2, deg.toDouble()), r * 0.07, i.isEven ? const Color(0xFF4ADE80) : const Color(0xFFA855F7), hi: Colors.white);
        }
        break;
      case 'gold_royal':
      default:
        for (var i = 0; i < 8; i++) {
          final deg = i * 45;
          _dot(canvas, _pt(c, r + 2, deg.toDouble()), r * 0.06, kGold);
        }
        break;
    }
  }

  @override
  bool shouldRepaint(_OrnatePainter old) => old.preset != preset || old.t != t;
}

/// Avatar wrapped in a frame ring. `frame` is a frames-table row (or
/// null/empty for no frame). `dotColor` adds the voice/status dot.
///
/// ANIMATED FRAMES (round 4): every preset animates with ORIGINAL
/// Flutter animation only — no downloaded art, no copied assets, no
/// DB change (the same 5 style_preset values are rendered, just
/// animated). One short controller per FRAMED avatar only (plain
/// avatars create no controller, so long chat lists stay cheap), and
/// the controller stops when the frame is removed:
///   gold_royal — slow rotating gold sparkle orbiting the ring + glow.
///   diamond    — twinkling sparkle dots around the ring.
///   fire       — flickering glow + slight ring flicker (orange/red).
///   neon       — strong pulsing glow.
///   crown      — shimmering glow + gently bobbing crown badge.
/// This is frame animation, NOT speaking detection: it runs whenever
/// the frame is equipped, mic on or off.
class FramedAvatar extends StatefulWidget {
  final String name;
  final Map<String, dynamic>? frame;
  final double radius;
  final Color avatarColor;
  final String photoUrl;
  final Color? dotColor;
  const FramedAvatar({super.key, required this.name, this.frame, required this.radius, this.avatarColor = const Color(0xFFFDC903), this.photoUrl = '', this.dotColor});

  @override
  State<FramedAvatar> createState() => _FramedAvatarState();
}

class _FramedAvatarState extends State<FramedAvatar> with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;
  // ROUND 11: a dead photo URL must fall back to the initial letter,
  // not a blank circle (CircleAvatar shows no child once a
  // backgroundImage is set, even when it fails to load).
  bool _imgFailed = false;

  bool get _hasFrame => widget.frame != null && widget.frame!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_hasFrame) _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
  }

  @override
  void didUpdateWidget(FramedAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photoUrl != widget.photoUrl) _imgFailed = false;
    if (_hasFrame && _ctrl == null) {
      _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
    } else if (!_hasFrame && _ctrl != null) {
      _ctrl!.dispose();
      _ctrl = null;
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.name.isNotEmpty ? widget.name[0].toUpperCase() : 'P';
    final showPhoto = widget.photoUrl.isNotEmpty && !_imgFailed;
    // Wave 4 item B: disk-cached photo via ArenaCachedAvatar. The
    // fallback contract is unchanged — a dead URL shows the initial
    // letter, never a blank circle. onError keeps the ROUND 11
    // _imgFailed flag in sync (post-frame, so no setState-during-build).
    final inner = ArenaCachedAvatar(
      photoUrl: showPhoto ? widget.photoUrl : '',
      radius: widget.radius,
      backgroundColor: widget.avatarColor,
      fallback: Text(initial, style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: widget.radius * 0.8)),
      onError: showPhoto
          ? () {
              if (!_imgFailed && mounted) setState(() => _imgFailed = true);
            }
          : null,
    );
    Widget framed;
    if (!_hasFrame) {
      framed = inner;
    } else {
      final preset = strVal(widget.frame!['style_preset'], 'gold_royal');
      final style = frameStyleOf(preset);
      final imageUrl = strVal(widget.frame!['image_url']);
      final ring = Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: imageUrl.isEmpty ? LinearGradient(colors: style.gradient) : null,
          image: imageUrl.isNotEmpty ? DecorationImage(image: CachedNetworkImageProvider(imageUrl), fit: BoxFit.cover) : null,
        ),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(shape: BoxShape.circle, color: kBg),
          child: inner,
        ),
      );
      final base = Stack(
        clipBehavior: Clip.none,
        children: [
          ring,
          if (preset == 'crown' || preset.startsWith('admin_'))
            Positioned(
              top: -4,
              right: -2,
              child: Icon(Icons.workspace_premium, color: kGold, size: 16),
            ),
        ],
      );
      if (_ctrl == null) {
        framed = base;
      } else {
        framed = AnimatedBuilder(
          animation: _ctrl!,
          builder: (context, _) {
            final t = _ctrl!.value;
            final s1 = math.sin(2 * math.pi * t);
            final s2 = math.sin(2 * math.pi * t + 2.1);
            final s3 = math.sin(2 * math.pi * t + 4.2);
            double glowAlpha;
            double glowBlur;
            double flickerScale = 1.0;
            switch (preset) {
              // ADMIN PREMIUM FRAMES: the strongest glow in the app
              // (bright pulsing halo + gentle breathing scale) for
              // all 10, except Crimson Flame which flickers like
              // fire. Unmistakably more luxurious than shop frames.
              case 'admin_crimson_flame':
              case 'admin_ruby_regal':
              case 'admin_solar_eclipse':
                glowAlpha = 0.5 + 0.4 * (s1 * s1);
                glowBlur = 12 + 12 * (s2 * s2);
                flickerScale = 1.0 + 0.025 * math.sin(6 * math.pi * t);
                break;
              case 'admin_royal_gold':
              case 'admin_diamond_crown':
              case 'admin_emerald_royal':
              case 'admin_sapphire_elite':
              case 'admin_obsidian_gold':
              case 'admin_violet_majesty':
              case 'admin_arctic_aurora':
                glowAlpha = 0.6 + 0.35 * (0.5 + 0.5 * s1);
                glowBlur = 14 + 14 * (0.5 + 0.5 * s1);
                flickerScale = 1.0 + 0.03 * math.sin(4 * math.pi * t);
                break;
              case 'fire':
              case 'blaze':
                glowAlpha = 0.45 + 0.4 * (s1 * s1);
                glowBlur = 10 + 10 * (s2 * s2);
                flickerScale = 1.0 + 0.025 * math.sin(6 * math.pi * t);
                break;
              case 'neon':
              case 'wings_silver':
                glowAlpha = 0.35 + 0.45 * (0.5 + 0.5 * s1);
                glowBlur = 12 + 14 * (0.5 + 0.5 * s1);
                break;
              case 'diamond':
              case 'gem_ruby':
              case 'moonlight':
                glowAlpha = 0.55;
                glowBlur = 10;
                break;
              case 'starburst':
              case 'emerald_royal':
                glowAlpha = 0.4 + 0.35 * (0.5 + 0.5 * s1);
                glowBlur = 10 + 8 * (0.5 + 0.5 * s1);
                break;
              case 'crown':
              case 'gold_royal':
              default:
                glowAlpha = 0.45 + 0.3 * (0.5 + 0.5 * s1);
                glowBlur = 9 + 6 * (0.5 + 0.5 * s1);
                break;
            }
            final size = (widget.radius + 5) * 2;
            return Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: style.gradient.first.withValues(alpha: glowAlpha), blurRadius: glowBlur, spreadRadius: 1)],
                  ),
                ),
                Transform.scale(scale: flickerScale, child: base),
                // Ornate vector decoration for this preset, drawn
                // over the ring at the ring's own size.
                SizedBox(
                  width: size,
                  height: size,
                  child: CustomPaint(painter: _OrnatePainter(preset, t)),
                ),
                // Orbiting sparkle (gold_royal + crown): a small star
                // rotating around the ring — the "animated frame" read
                // at a glance, drawn by Flutter, not an image.
                if (preset == 'gold_royal' || preset == 'crown' || preset == 'laurel_gold' || preset.startsWith('admin_'))
                  SizedBox(
                    width: size,
                    height: size,
                    child: Transform.rotate(
                      angle: 2 * math.pi * t,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Icon(Icons.star, color: kGold, size: 10),
                      ),
                    ),
                  ),
                // Twinkling sparkles (diamond): three dots fading in
                // and out out of phase around the ring.
                if (preset == 'diamond' || preset == 'gem_ruby' || preset == 'moonlight') ...[
                  Positioned(
                    top: -2,
                    right: 6,
                    child: Opacity(opacity: 0.3 + 0.7 * (0.5 + 0.5 * s1), child: const Icon(Icons.star, color: Colors.white, size: 9)),
                  ),
                  Positioned(
                    bottom: 2,
                    left: 0,
                    child: Opacity(opacity: 0.3 + 0.7 * (0.5 + 0.5 * s2), child: const Icon(Icons.star, color: Colors.white, size: 8)),
                  ),
                  Positioned(
                    bottom: -2,
                    right: 2,
                    child: Opacity(opacity: 0.3 + 0.7 * (0.5 + 0.5 * s3), child: const Icon(Icons.star, color: Colors.cyanAccent, size: 9)),
                  ),
                ],
                // Pulsing gold sparkles (admin frames): two stars
                // fading in and out of phase around the ring.
                if (preset.startsWith('admin_')) ...[
                  Positioned(
                    top: -2,
                    right: 6,
                    child: Opacity(opacity: 0.3 + 0.7 * (0.5 + 0.5 * s1), child: const Icon(Icons.star, color: Color(0xFFFDC903), size: 10)),
                  ),
                  Positioned(
                    bottom: -2,
                    left: 2,
                    child: Opacity(opacity: 0.3 + 0.7 * (0.5 + 0.5 * s2), child: const Icon(Icons.star, color: Colors.white, size: 9)),
                  ),
                ],
                // Bobbing crown badge (crown): the badge itself moves
                // gently, on top of the static badge in `base` it
                // reads as a shimmering crown.
                if (preset == 'crown')
                  Positioned(
                    top: -4 + 1.5 * s1,
                    right: -2,
                    child: const Icon(Icons.workspace_premium, color: Colors.white, size: 14),
                  ),
              ],
            );
          },
        );
      }
    }
    if (widget.dotColor == null) return framed;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        framed,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: widget.dotColor, shape: BoxShape.circle, border: Border.all(color: kCard, width: 1.5)),
          ),
        ),
      ],
    );
  }
}

/// Framed avatar for a uid, loading that user's equipped frame (cached).
/// ROUND 11: stateful so the photo resolves from `profiles` when the
/// caller did not pass one explicitly (room seats/strip, chat,
/// Status sheet, leaderboard). An explicitly passed photoUrl still
/// wins. Reloads on every parent rebuild, but the underlying caches
/// (frame: session, photo: 30 s TTL) make that cheap, and setState
/// fires only when the resolved frame/photo actually changed — so a
/// photo updated mid-session appears in the current room within
/// ~30 s, and immediately on re-entering the room.
class CachedFramedAvatar extends StatefulWidget {
  final String uid;
  final String name;
  final double radius;
  final Color avatarColor;
  final String photoUrl;
  final Color? dotColor;
  const CachedFramedAvatar({super.key, required this.uid, required this.name, required this.radius, this.avatarColor = const Color(0xFFFDC903), this.photoUrl = '', this.dotColor});

  @override
  State<CachedFramedAvatar> createState() => _CachedFramedAvatarState();
}

class _CachedFramedAvatarState extends State<CachedFramedAvatar> {
  Map<String, dynamic>? _frame;
  String _photo = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CachedFramedAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _load();
  }

  Future<void> _load() async {
    // Admin frames flow through the SAME equipped path: an admin's
    // chosen admin_* frame is their equipped user_frames row (see
    // SupaDb.getEquippedFrame), so it renders here on every phone
    // with no special-casing — and a non-admin can never hold one
    // (equip is admin-gated, lookup refuses non-admin admin rows).
    final frame = await FrameCache.equipped(widget.uid);
    final photo = widget.photoUrl.isNotEmpty ? widget.photoUrl : await PhotoCache.photo(widget.uid);
    if (!mounted) return;
    if (_frame != frame || _photo != photo) {
      setState(() {
        _frame = frame;
        _photo = photo;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return FramedAvatar(name: widget.name, frame: _frame, radius: widget.radius, avatarColor: widget.avatarColor, photoUrl: _photo, dotColor: widget.dotColor);
  }
}
