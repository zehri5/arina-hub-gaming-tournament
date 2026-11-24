import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/supabase_db.dart';
import '../theme.dart';
import '../widgets/arena_ui.dart';
import 'cached_image.dart';

/// ARENA HUB shared component library (Phase 1 — §7.3).
/// ONE version of each component — no duplicates. Every component is
/// presentational: it takes pre-formatted strings and callbacks, never
/// reads a table, never calls a service, never invents data. Screens
/// in Phases 2–3 compose these; the legacy helpers in utils.dart
/// (`goldButton`, `field`) delegate to GoldButton / ArenaFormField here so
/// there is exactly one implementation of each.
///
/// Colours come only from theme.dart. Radii (§7.1): cards 16–20,
/// pills full, buttons 12–14. Gold glow on primary CTAs only.

// ---------------------------------------------------------------- logo

/// Branding from app_settings (Round 5/6 — admin branding applies):
/// the admin-saved `app_name` + `logo_url` (Admin Settings → General)
/// are read once per app run through the existing
/// [SupaDb.getAppSettings] path and cached in memory, so every
/// ArenaLogo on screen shares the single fetch and a fresh app
/// launch re-reads the latest saved values. Fail-safe:
/// getAppSettings returns {} on any error, so a failed or missing
/// read falls back to the built-in crown asset + ARENA/HUB wordmark.
class _Branding {
  static Map<String, dynamic>? _cached;
  static Future<Map<String, dynamic>>? _pending;

  static Map<String, dynamic>? get cached => _cached;

  static Future<Map<String, dynamic>> load() {
    final c = _cached;
    if (c != null) return Future.value(c);
    final p = _pending;
    if (p != null) return p;
    final f = SupaDb.getAppSettings().then<Map<String, dynamic>>((s) {
      _cached = s;
      return s;
    }, onError: (_) {
      _cached = const <String, dynamic>{};
      return const <String, dynamic>{};
    });
    _pending = f;
    return f;
  }
}

/// Gold crown emblem + "ARENA" white / "HUB" gold italic wordmark
/// (§7.1 logo spec). DYNAMIC branding (Round 5/6): when the admin
/// has saved an app name / logo in Admin Settings → General
/// (app_settings `app_name` / `logo_url`), the wordmark and crown
/// follow it — FIRST word white, REST gold (e.g. "ARENA HUB" →
/// ARENA white + HUB gold); a one-word name renders as a single
/// white line; an empty/unset name keeps ARENA/HUB. A saved logo
/// URL is shown with CachedNetworkImage (disk-cached, Batch 3A) and falls back to the built-in
/// crown asset (assets/images/arena_logo.png) on any load error; if
/// that asset ever fails too, a gold crown icon is shown instead —
/// never a broken-image box.
///
/// NOTE: this is the ONE deliberate exception to the "components
/// never call a service" rule above — the logo must follow admin
/// settings, and every call site (auth, home, more, pro) already
/// uses this widget, so the central fix covers them all. The
/// settings read is cached per app run ([_Branding]) and refreshes
/// on the next launch. The phone's home-screen launcher icon is NOT
/// affected — it can only change with a new APK build.
class ArenaLogo extends StatefulWidget {
  const ArenaLogo({super.key, this.crownSize = 40, this.fontSize = 22, this.showWordmark = true});
  final double crownSize;
  final double fontSize;
  final bool showWordmark;

  @override
  State<ArenaLogo> createState() => _ArenaLogoState();
}

class _ArenaLogoState extends State<ArenaLogo> {
  @override
  void initState() {
    super.initState();
    // First logo on screen triggers the single shared settings
    // fetch; later instances read the populated cache synchronously.
    if (_Branding.cached == null) {
      _Branding.load().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// Built-in crown asset (its own errorBuilder → gold crown icon).
  Widget _builtinCrown() => Image.asset(
        'assets/images/arena_logo.png',
        width: widget.crownSize,
        height: widget.crownSize,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Icon(Icons.emoji_events, color: kGold, size: widget.crownSize),
      );

  Widget _crown(String logoUrl) {
    if (logoUrl.isEmpty) return _builtinCrown();
    // Batch 3A: disk-cached (no bare re-download on every screen
    // open) — same sizing/fit, same fallback to the built-in crown
    // on error; the built-in crown is also the placeholder so the
    // logo never flashes blank or a broken-image box while loading.
    return CachedNetworkImage(
      imageUrl: logoUrl,
      width: widget.crownSize,
      height: widget.crownSize,
      fit: BoxFit.contain,
      placeholder: (_, __) => _builtinCrown(),
      errorWidget: (_, __, ___) => _builtinCrown(),
    );
  }

  /// Wordmark lines from the admin-saved app name (shared split —
  /// see [_brandingWordmarkLines]).
  List<String> _wordmarkLines(String appName) => _brandingWordmarkLines(appName);

  @override
  Widget build(BuildContext context) {
    final settings = _Branding.cached;
    // getAppSettings returns the snake_case columns; read the
    // camelCase alias too (a config-jsonb row may store either).
    final logoUrl = settings == null ? '' : SupaDb.strOf(settings['logo_url'] ?? settings['logoUrl']).trim();
    final appName = settings == null ? '' : SupaDb.strOf(settings['app_name'] ?? settings['appName']);
    final crown = _crown(logoUrl);
    if (!widget.showWordmark) return crown;
    final lines = _wordmarkLines(appName);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        crown,
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(lines[0], style: TextStyle(color: kText, fontSize: widget.fontSize, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.0, letterSpacing: 0.5)),
            if (lines.length > 1)
              Text(lines[1], style: TextStyle(color: kGold, fontSize: widget.fontSize, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.0, letterSpacing: 0.5)),
          ],
        ),
      ],
    );
  }
}

/// FIX 23 item 25 — the NEW Arena Hub logo image (Sameer 2026-11-23
/// 23:50): helmet soldier + crown + ARENA HUB + PLAY • COMPETE • WIN
/// in blue-purple smoke. Used on the splash, the Home header and the
/// sign-in/sign-up screens. The launcher icon is UNCHANGED.
///
/// The artwork is a square JPEG with WHITE corners (the smoke fades
/// to white at the edges), so it is NEVER pasted raw on dark: it is
/// cropped to a circle — which cuts the white corners off, since the
/// design itself is already circular — inside a gold ring + glow.
/// On load failure a gold crown icon shows instead — never a broken
/// box.
///
/// NOTE: unlike [ArenaLogo] this does NOT read the admin logo URL —
/// Sameer ordered this artwork as the logo on these three surfaces.
/// Everywhere else still uses [ArenaLogo] (admin override intact).
class ArenaHubLogoImage extends StatelessWidget {
  static const String asset = 'assets/images/arena_hub_logo.png';

  /// Diameter of the circle.
  final double size;

  /// Gold ring width (0 = no ring).
  final double ringWidth;

  const ArenaHubLogoImage(
      {super.key, this.size = 44, this.ringWidth = 2});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border:
            ringWidth > 0 ? Border.all(color: kGold, width: ringWidth) : null,
        boxShadow: [
          BoxShadow(
            color: kGold.withValues(alpha: 0.35),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipOval(
        child: Image.asset(
          asset,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: const Color(0xFF100829),
            child: Icon(Icons.emoji_events,
                color: kGold, size: size * 0.55),
          ),
        ),
      ),
    );
  }
}

/// Shared wordmark split: FIRST word white, REST gold; a one-word
/// name is a single white line. Empty or whitespace-only → the
/// default ARENA/HUB. Uppercased to match the wordmark style; never
/// crashes on empty/whitespace input.
List<String> _brandingWordmarkLines(String appName) {
  final words = appName.trim().toUpperCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const ['ARENA', 'HUB'];
  if (words.length == 1) return [words.first];
  return [words.first, words.sublist(1).join(' ')];
}

/// Wordmark ONLY (no crown) from the admin-saved app name — for
/// screens that already show their own crown/crest artwork (the
/// splash + gate screens) or pair the wordmark with a separate
/// ArenaLogo crown (Home header, _arenaWordmark). Same rules as
/// ArenaLogo (see [_brandingWordmarkLines]); the second line is
/// always kGold. [firstColor] overrides the first line's color —
/// the Home header is dark in both modes, so it passes white
/// (kText would vanish there in light mode). Settings are read
/// from the same per-run [_Branding] cache as ArenaLogo.
class ArenaWordmark extends StatefulWidget {
  const ArenaWordmark({super.key, this.fontSize = 22, this.letterSpacing = 1.0, this.textAlign = TextAlign.left, this.firstColor});
  final double fontSize;
  final double letterSpacing;
  final TextAlign textAlign;
  final Color? firstColor;
  @override
  State<ArenaWordmark> createState() => _ArenaWordmarkState();
}

class _ArenaWordmarkState extends State<ArenaWordmark> {
  @override
  void initState() {
    super.initState();
    if (_Branding.cached == null) {
      _Branding.load().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _Branding.cached;
    final appName = settings == null ? '' : SupaDb.strOf(settings['app_name'] ?? settings['appName']);
    final lines = _brandingWordmarkLines(appName);
    return Column(
      crossAxisAlignment: widget.textAlign == TextAlign.center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(lines[0], textAlign: widget.textAlign, style: TextStyle(color: widget.firstColor ?? kText, fontSize: widget.fontSize, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.0, letterSpacing: widget.letterSpacing)),
        if (lines.length > 1)
          Text(lines[1], textAlign: widget.textAlign, style: TextStyle(color: kGold, fontSize: widget.fontSize, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.0, letterSpacing: widget.letterSpacing)),
      ],
    );
  }
}

/// HOME #37 FIX (2026-11-19) — crossed swords icon for the
/// bottom nav's "My Matches" tab (mockup #37). Material has no
/// crossed-swords icon, so this draws two diagonal blades with
/// guards in the current IconTheme colour (gold when selected,
/// muted when not) — the same way BottomNavigationBar tints the
/// other tab icons. Pure vector, no asset.
class CrossedSwordsIcon extends StatelessWidget {
  const CrossedSwordsIcon({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Colors.white;
    return CustomPaint(size: Size(size, size), painter: _CrossedSwordsPainter(color));
  }
}

class _CrossedSwordsPainter extends CustomPainter {
  _CrossedSwordsPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()
      ..color = color
      ..strokeWidth = w * 0.09
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    // Blade 1: top-left hilt -> bottom-right tip.
    canvas.drawLine(Offset(w * 0.17, h * 0.17), Offset(w * 0.83, h * 0.83), paint);
    // Blade 2: top-right hilt -> bottom-left tip.
    canvas.drawLine(Offset(w * 0.83, h * 0.17), Offset(w * 0.17, h * 0.83), paint);
    // Guards: short ticks perpendicular to each blade, near the hilts.
    canvas.drawLine(Offset(w * 0.17, h * 0.33), Offset(w * 0.33, h * 0.17), paint);
    canvas.drawLine(Offset(w * 0.67, h * 0.17), Offset(w * 0.83, h * 0.33), paint);
  }

  @override
  bool shouldRepaint(covariant _CrossedSwordsPainter old) => old.color != color;
}

/// Home header (§6.1 #37): logo left, bell with unread badge +
/// avatar with gold ring right.
class AppHeader extends StatelessWidget {
  const AppHeader({super.key, this.unreadCount = 0, this.avatarUrl, this.onBell, this.onAvatarTap, this.onLogoTap});
  final int unreadCount;
  final String? avatarUrl;
  final VoidCallback? onBell;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onLogoTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GestureDetector(onTap: onLogoTap, child: const ArenaLogo(crownSize: 44, fontSize: 24)),
        const Spacer(),
        Stack(
          children: [
            IconButton(icon: Icon(Icons.notifications_outlined, color: kText, size: 28), onPressed: onBell),
            if (unreadCount > 0)
              Positioned(
                right: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: kLiveRed, borderRadius: BorderRadius.circular(10)),
                  child: Text(unreadCount > 9 ? '9+' : '$unreadCount', style: const TextStyle(color: Color(0xFF0A0A0F), fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ),
          ],
        ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: onAvatarTap,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kGold, width: 2)),
            child: ArenaCachedAvatar(
              photoUrl: avatarUrl ?? '',
              radius: 20,
              backgroundColor: kSurface,
              fallback: Icon(Icons.person, color: kGold, size: 22),
            ),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- buttons

/// Gold filled primary button (§7.1): gold fill, dark bold text.
/// MISC (2026-11-20, mockup style): the mockups' primary CTA is a
/// FULL PILL with a soft gold glow beneath it (LOGIN, SUBMIT TICKET,
/// CONFIRM SQUAD, RETRY CONNECTION) — radius 30 + glow, bold 16px
/// label. Same constructor as before, so every call site keeps
/// working; only the rendering changed to the mockup look. The
/// canonical primary button — utils.dart `goldButton` delegates here.
class GoldButton extends StatelessWidget {
  const GoldButton({super.key, required this.label, required this.onPressed, this.busy = false, this.fullWidth = true, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final bool fullWidth;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final child = busy
        ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A0A0F)))
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // CUT-OFF FIX (2026-11-22, user screenshot): the old
              // two-word create label rendered as "Create Team /
              // Cla" in a half-width slot — the 16px w900 label
              // overflowed the button and clipped. FittedBox
              // scaleDown shrinks the
              // label to fit instead of clipping; full-width buttons
              // are unaffected (the text fits, so no scaling).
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: 0.5)),
                ),
              ),
              if (icon != null) ...[const SizedBox(width: 6), Icon(icon, size: 18)],
            ],
          );
    final btn = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        // Mockup primary-CTA glow: soft gold halo under the pill.
        boxShadow: goldGlow(alpha: 0.35, blur: 20, spread: 2, offset: const Offset(0, 6)),
      ),
      child: ElevatedButton(
        onPressed: busy ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: kGold,
          foregroundColor: const Color(0xFF0A0A0F),
          disabledBackgroundColor: kGold.withValues(alpha: 0.45),
          disabledForegroundColor: const Color(0xFF0A0A0F),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
          elevation: 0,
        ),
        child: child,
      ),
    );
    if (!fullWidth) return btn;
    return SizedBox(width: double.infinity, child: btn);
  }
}

/// Dark secondary button (§7.1): card fill, gold border, white bold
/// text (gold text when [goldText] is true).
/// PHASE E (E24): the fill is the shared card token now (was the
/// opaque kCard) — secondary buttons read as cards, like every
/// other pill/tab/secondary surface.
/// MISC (2026-11-20, mockup style): the mockups' secondary CTA is a
/// FULL PILL like the primary (MATCH DETAILS, BACK TO HOME) — radius
/// 30, no glow. Same constructor as before.
class OutlineButton extends StatelessWidget {
  const OutlineButton({super.key, required this.label, required this.onPressed, this.fullWidth = true, this.icon, this.goldText = false});
  final String label;
  final VoidCallback? onPressed;
  final bool fullWidth;
  final IconData? icon;
  final bool goldText;

  @override
  Widget build(BuildContext context) {
    final btn = OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: goldText ? kGold : kText,
        side: BorderSide(color: kGold, width: 1.5),
        backgroundColor: kCardFillColor,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // OVERFLOW FIX (2026-11-22): long labels ('Full History,
          // Withdrawals & Referral Board') overflowed the Row on
          // 360px phones — same Flexible + FittedBox pattern as
          // GoldButton: the label shrinks instead of clipping.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
          ),
          if (icon != null) ...[const SizedBox(width: 6), Icon(icon, size: 18)],
        ],
      ),
    );
    if (!fullWidth) return btn;
    return SizedBox(width: double.infinity, child: btn);
  }
}

// --------------------------------------------------------------- badges

/// Status pill colours (§7.1).
enum StatusKind { registrationOpen, confirmed, ready, live, upcoming, completed, verified, pending }

Color _statusBg(StatusKind kind) {
  switch (kind) {
    case StatusKind.registrationOpen:
    case StatusKind.confirmed:
    case StatusKind.ready:
      return kGreen;
    case StatusKind.live:
      return kLiveRed;
    case StatusKind.upcoming:
      return kGold;
    case StatusKind.completed:
    case StatusKind.pending:
      return kMuted;
    case StatusKind.verified:
      return Colors.transparent;
  }
}

Color _statusFg(StatusKind kind) {
  switch (kind) {
    case StatusKind.registrationOpen:
    case StatusKind.confirmed:
    case StatusKind.ready:
      return const Color(0xFF0A0A0F);
    case StatusKind.live:
      // DETAIL-SPEC §37(e): LIVE pill is bright-red filled with WHITE
      // bold text + white dot. (Was dark 0xFF0A0A0F text/dot — the
      // skeleton mockup's dark-red/red-text rendering is its dimmed
      // skeleton variant, not the real pill.)
      return const Color(0xFFFFFFFF);
    case StatusKind.upcoming:
      return const Color(0xFF0A0A0F);
    case StatusKind.completed:
    case StatusKind.pending:
      return const Color(0xFF0A0A0F);
    case StatusKind.verified:
      return kGreen;
  }
}

/// Status pill (§7.1): green REGISTRATION OPEN / CONFIRMED / READY,
/// red LIVE, gold UPCOMING, grey COMPLETED, green-outline VERIFIED.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label, required this.kind, this.dot = false});
  final String label;
  final StatusKind kind;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final outlined = kind == StatusKind.verified;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: outlined ? Colors.transparent : _statusBg(kind),
        borderRadius: BorderRadius.circular(20),
        border: outlined ? Border.all(color: kGreen, width: 1.5) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: _statusFg(kind))),
            const SizedBox(width: 5),
          ],
          Text(label, style: TextStyle(color: _statusFg(kind), fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.5)),
        ],
      ),
    );
  }
}

/// Gold progress bar (§7.1): gold fill on a dark track.
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.value, this.height = 6});
  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: LinearProgressIndicator(
        value: value.clamp(0.0, 1.0),
        minHeight: height,
        backgroundColor: kBorder,
        valueColor: AlwaysStoppedAnimation<Color>(kGold),
      ),
    );
  }
}

/// Countdown label (§6.1 #1): pre-formatted by the caller via
/// `countdownText`; LIVE renders as a red pill.
class CountdownTimer extends StatelessWidget {
  const CountdownTimer({super.key, required this.label, this.isLive = false});
  final String label;
  final bool isLive;

  @override
  Widget build(BuildContext context) {
    if (isLive) return const StatusBadge(label: 'LIVE', kind: StatusKind.live, dot: true);
    return Text(label, style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13));
  }
}

// ---------------------------------------------------------------- cards

/// Gold card shell shared by the cards below: the global mockup card
/// ([MockupCard]) with STATIC shines (no ticker per list row —
/// featured cards animate). Radius 16, no full border.
class _ArenaCard extends StatelessWidget {
  const _ArenaCard({required this.child, this.padding = const EdgeInsets.all(14), this.featured = false, this.onTap});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool featured;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = MockupCard(padding: padding, radius: 16, animate: featured, child: child);
    if (onTap == null) return box;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(16), child: box);
  }
}

/// Tournament card (§6.1 #37): banner thumb left, status pill, title,
/// date • mode, players + gold progress, Details + primary action.
class TournamentCard extends StatelessWidget {
  const TournamentCard({
    super.key,
    required this.title,
    required this.dateText,
    required this.modeText,
    required this.playersText,
    required this.progress,
    required this.statusLabel,
    required this.statusKind,
    required this.primaryLabel,
    this.imageUrl,
    this.onDetails,
    this.onPrimary,
    this.onTap,
    this.featured = false,
  });
  final String title;
  final String dateText;
  final String modeText;
  final String playersText;
  final double progress;
  final String statusLabel;
  final StatusKind statusKind;
  final String primaryLabel;
  final String? imageUrl;
  final VoidCallback? onDetails;
  final VoidCallback? onPrimary;
  final VoidCallback? onTap;
  final bool featured;

  @override
  Widget build(BuildContext context) {
    return _ArenaCard(
      featured: featured,
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ArenaCachedImage(
            imageUrl: imageUrl ?? '',
            width: 96,
            height: 118,
            fit: BoxFit.cover,
            borderRadius: BorderRadius.circular(12),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusBadge(label: statusLabel, kind: statusKind, dot: statusKind == StatusKind.live),
                const SizedBox(height: 6),
                Text(title, style: TextStyle(color: kText, fontSize: 17, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.calendar_today, color: kMuted, size: 13),
                    const SizedBox(width: 4),
                    Expanded(child: Text(dateText, style: TextStyle(color: kMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Icon(Icons.group, color: kMuted, size: 14),
                    const SizedBox(width: 4),
                    Text(modeText, style: TextStyle(color: kMuted, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(playersText, style: TextStyle(color: kMuted, fontSize: 12)),
                const SizedBox(height: 4),
                ProgressBar(value: progress),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: OutlineButton(label: 'Details', onPressed: onDetails, fullWidth: false)),
                    const SizedBox(width: 8),
                    Expanded(child: GoldButton(label: primaryLabel, onPressed: onPrimary, fullWidth: false)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Your Next Match" card (§6.1 #37): trophy, teams, VS, time pill.
class MatchCard extends StatelessWidget {
  const MatchCard({super.key, required this.teamA, required this.teamB, required this.timeText, this.onTap, this.onDetails});
  final String teamA;
  final String teamB;
  final String timeText;
  final VoidCallback? onTap;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    return _ArenaCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(shape: BoxShape.circle, color: kGold.withValues(alpha: 0.15)),
                child: Icon(Icons.emoji_events, color: kGold, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('Your Next Match', style: TextStyle(color: kText, fontSize: 16, fontWeight: FontWeight.bold))),
              if (onDetails != null)
                GestureDetector(
                  onTap: onDetails,
                  child: Text('See Details →', style: TextStyle(color: kGold, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: Text(teamA, textAlign: TextAlign.center, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('VS', style: TextStyle(color: kGold, fontSize: 20, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
              ),
              Expanded(child: Text(teamB, textAlign: TextAlign.center, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ),
          const SizedBox(height: 10),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(color: kCardFillColor, borderRadius: BorderRadius.circular(20), border: Border.all(color: kBorder)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.access_time, color: kGold, size: 14),
                  const SizedBox(width: 5),
                  Text(timeText, style: TextStyle(color: kText, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Player row: avatar (gold ring for current user / captain), name,
/// subtitle line (level / stats).
class PlayerCard extends StatelessWidget {
  const PlayerCard({super.key, required this.name, this.subtitle, this.avatarUrl, this.isCurrentUser = false, this.trailing, this.onTap});
  final String name;
  final String? subtitle;
  final String? avatarUrl;
  final bool isCurrentUser;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _ArenaCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: isCurrentUser ? kGold : kBorder, width: 2)),
            child: ArenaCachedAvatar(
              photoUrl: avatarUrl ?? '',
              radius: 20,
              backgroundColor: kSurface,
              fallback: Icon(Icons.person, color: kGold, size: 20),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null) Text(subtitle!, style: TextStyle(color: kMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Team row: shield/avatar, team name, member line, trailing action.
class TeamCard extends StatelessWidget {
  const TeamCard({super.key, required this.teamName, this.memberText, this.avatarUrl, this.trailing, this.onTap});
  final String teamName;
  final String? memberText;
  final String? avatarUrl;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _ArenaCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kGold, width: 2)),
            child: ArenaCachedAvatar(
              photoUrl: avatarUrl ?? '',
              radius: 20,
              backgroundColor: kSurface,
              fallback: Icon(Icons.shield, color: kGold, size: 20),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(teamName, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (memberText != null) Text(memberText!, style: TextStyle(color: kMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Wallet card (preserved wallet, gold style): label, balance, tap.
class WalletCard extends StatelessWidget {
  const WalletCard({super.key, required this.label, required this.balanceText, this.onTap, this.icon = Icons.account_balance_wallet});
  final String label;
  final String balanceText;
  final VoidCallback? onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return _ArenaCard(
      featured: true,
      onTap: onTap,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(shape: BoxShape.circle, color: kGold.withValues(alpha: 0.15)),
            child: Icon(icon, color: kGold, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: kMuted, fontSize: 12)),
                const SizedBox(height: 2),
                Text(balanceText, style: TextStyle(color: kGold, fontSize: 20, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: kMuted),
        ],
      ),
    );
  }
}

/// Transaction row: icon, title, subtitle/date, amount (green/red),
/// optional status line.
class TransactionCard extends StatelessWidget {
  const TransactionCard({super.key, required this.title, this.subtitle, required this.amountText, this.isCredit = true, this.icon = Icons.receipt, this.statusText});
  final String title;
  final String? subtitle;
  final String amountText;
  final bool isCredit;
  final IconData icon;
  final String? statusText;

  @override
  Widget build(BuildContext context) {
    return _ArenaCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(shape: BoxShape.circle, color: kSurface),
            child: Icon(icon, color: kGold, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null) Text(subtitle!, style: TextStyle(color: kMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (statusText != null) Text(statusText!, style: TextStyle(color: kMuted, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Text(amountText, style: TextStyle(color: isCredit ? kGreen : kRed, fontWeight: FontWeight.bold, fontSize: 14)),
        ],
      ),
    );
  }
}

/// Notification row: gold-tinted icon, title, body, time, unread dot.
class NotificationCard extends StatelessWidget {
  const NotificationCard({super.key, required this.title, this.body, required this.timeText, this.isUnread = false, this.icon = Icons.notifications, this.onTap});
  final String title;
  final String? body;
  final String timeText;
  final bool isUnread;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _ArenaCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(shape: BoxShape.circle, color: kGold.withValues(alpha: 0.15)),
            child: Icon(icon, color: kGold, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (body != null) ...[
                  const SizedBox(height: 2),
                  Text(body!, style: TextStyle(color: kMuted, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 4),
                Text(timeText, style: TextStyle(color: kMuted, fontSize: 11)),
              ],
            ),
          ),
          if (isUnread) Container(width: 9, height: 9, margin: const EdgeInsets.only(top: 5), decoration: BoxDecoration(shape: BoxShape.circle, color: kGold)),
        ],
      ),
    );
  }
}

/// Leaderboard row: rank, avatar, name, points; gold highlight for
/// the current user; gold rank for places 1–3.
class LeaderboardItem extends StatelessWidget {
  const LeaderboardItem({super.key, required this.rank, required this.name, required this.pointsText, this.avatarUrl, this.isMe = false, this.subtitle, this.onTap});
  final int rank;
  final String name;
  final String pointsText;
  final String? avatarUrl;
  final bool isMe;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final rankColor = rank <= 3 ? kGold : kMuted;
    return _ArenaCard(
      featured: isMe,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('$rank', textAlign: TextAlign.center, style: TextStyle(color: rankColor, fontWeight: FontWeight.w900, fontSize: 16)),
          ),
          const SizedBox(width: 8),
          ArenaCachedAvatar(
            photoUrl: avatarUrl ?? '',
            radius: 18,
            backgroundColor: kSurface,
            fallback: Icon(Icons.person, color: kGold, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: TextStyle(color: kText, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null) Text(subtitle!, style: TextStyle(color: kMuted, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Text(pointsText, style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 14)),
        ],
      ),
    );
  }
}

/// Profile header: big avatar with gold ring, name, level pill,
/// stats row (label + value pairs).
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({super.key, required this.name, this.levelText, this.avatarUrl, this.stats = const [], this.onAvatarTap});
  final String name;
  final String? levelText;
  final String? avatarUrl;
  final List<({String label, String value})> stats;
  final VoidCallback? onAvatarTap;

  @override
  Widget build(BuildContext context) {
    return _ArenaCard(
      child: Column(
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: onAvatarTap,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kGold, width: 2.5)),
                  child: ArenaCachedAvatar(
                    photoUrl: avatarUrl ?? '',
                    radius: 34,
                    backgroundColor: kSurface,
                    fallback: Icon(Icons.person, color: kGold, size: 34),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: TextStyle(color: kText, fontSize: 20, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (levelText != null) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: kGold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20), border: Border.all(color: kGold)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.star, color: kGold, size: 14),
                            const SizedBox(width: 4),
                            Text(levelText!, style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: stats
                  .map((s) => Column(
                        children: [
                          Text(s.value, style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 2),
                          Text(s.label, style: TextStyle(color: kMuted, fontSize: 11)),
                        ],
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

// --------------------------------------------------------- modal/dialog

/// Bottom-sheet card: handle bar + title + child.
class ArenaModal extends StatelessWidget {
  const ArenaModal({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      // FIX 23 item 29 Part C: the card look (full-opacity gradient —
      // modal surfaces stay solid over the dimmed barrier, unlike
      // in-flow cards which are translucent + blurred).
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [kCardPurpleTop, kCardPurpleMid, kCardPurpleBottom],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        border: Border.fromBorderSide(
            BorderSide(color: kCardPurpleBorder, width: 1.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: kMuted, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 12),
          Text(title, style: TextStyle(color: kGold, fontWeight: FontWeight.w900, fontSize: 18)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

Future<T?> showArenaModal<T>(BuildContext context, {required String title, required Widget child}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => ArenaModal(title: title, child: child),
  );
}

/// Confirm / cancel dialog: gold card, gold confirm, outline cancel.
class ConfirmationDialog extends StatelessWidget {
  const ConfirmationDialog({super.key, required this.title, required this.body, this.confirmLabel = 'Confirm', this.cancelLabel = 'Cancel', this.isDestructive = false});
  final String title;
  final String body;
  final String confirmLabel;
  final String cancelLabel;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kCardPurpleMid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22), side: const BorderSide(color: kCardPurpleBorder, width: 1.5)),
      title: Text(title, style: TextStyle(color: kText, fontWeight: FontWeight.bold)),
      content: Text(body, style: TextStyle(color: kMuted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancelLabel, style: TextStyle(color: kMuted, fontWeight: FontWeight.bold))),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: isDestructive ? kRed : kGold,
            foregroundColor: isDestructive ? Colors.white : const Color(0xFF0A0A0F),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(confirmLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}

Future<bool> showArenaConfirm(BuildContext context, {required String title, required String body, String confirmLabel = 'Confirm', String cancelLabel = 'Cancel', bool isDestructive = false}) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (_) => ConfirmationDialog(title: title, body: body, confirmLabel: confirmLabel, cancelLabel: cancelLabel, isDestructive: isDestructive),
  );
  return res ?? false;
}

// ------------------------------------------------------------ form/misc

/// Labelled text field — the canonical form field (utils.dart `field`
/// delegates here). Label above, filled dark field, gold focus border.
/// MISC (2026-11-20, mockup style): mockup fields have a VISIBLE thin
/// grey border when unfocused (the old borderSide.none made them
/// borderless), radius 12, and 16px vertical padding — same as the
/// Login screen's fields. Same constructor as before.
class ArenaFormField extends StatelessWidget {
  const ArenaFormField({super.key, required this.controller, required this.label, this.hint, this.obscure = false, this.keyboardType, this.maxLines = 1});
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    // v2015: min-sized — a max Column inside an AlertDialog's
    // content expands the dialog to full screen height (the Join
    // by Code dialog showed a huge empty gap before). A form field
    // must size to its content everywhere.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: kMuted, fontSize: 14)),
        const SizedBox(height: 6),
        // FIX 23 item 29: card look via CardFieldShell (the field
        // itself is borderless — a decoration cannot paint a
        // gradient). Behaviour unchanged.
        CardFieldShell(
          child: TextField(
            controller: controller,
            obscureText: obscure,
            keyboardType: keyboardType,
            maxLines: maxLines,
            style: TextStyle(color: kText, fontSize: 15),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: kMuted, fontSize: 15),
              contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
              border: const OutlineInputBorder(borderSide: BorderSide.none),
              enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
              focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// Empty state (§6.1 #7): icon, title, body, optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.actionLabel, this.onAction});
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: kGold, size: 48),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: TextStyle(color: kText, fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(body, textAlign: TextAlign.center, style: TextStyle(color: kMuted, fontSize: 13)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            GoldButton(label: actionLabel!, onPressed: onAction, fullWidth: false),
          ],
        ],
      ),
    );
  }
}

/// Gold glow helper (§6.1 glow restores, J-detail-fix1): a soft
/// gold halo under a pill/button, used where the mockup shows one —
/// every primary CTA pill (GoldButton), Offline RETRY, Rewards Claim.
/// The mockup is the authority on glow — everything else stays flat.
List<BoxShadow> goldGlow({double alpha = 0.45, double blur = 18, double spread = 1, Offset offset = const Offset(0, 4)}) => [
      BoxShadow(color: kGold.withValues(alpha: alpha), blurRadius: blur, spreadRadius: spread, offset: offset),
    ];

// ------------------------------------------------- drawn art (J-detail-fix1)
//
// The mockups' emblem art (crowns, winged shields, medallions) has
// no asset source, so the closest honest equivalents are drawn here
// with CustomPaint — never a copied game image. All painters are
// static (no animation, no per-frame allocation).

/// 3-point gold crown (mockup #11/#17/#25/#35 crown + badge art).
/// Drawn, not an asset — the crest/winged-crest assets themselves
/// are still blocked (no replacement asset exists).
class ArenaCrownIcon extends StatelessWidget {
  const ArenaCrownIcon({super.key, this.size = 28, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size(size, size * 0.72), painter: _CrownPainter(color ?? kGold));
  }
}

class _CrownPainter extends CustomPainter {
  final Color color;
  const _CrownPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final crown = Path()
      ..moveTo(0, h * 0.85)
      ..lineTo(0, h * 0.35)
      ..lineTo(w * 0.22, h * 0.62)
      ..lineTo(w * 0.5, h * 0.05)
      ..lineTo(w * 0.78, h * 0.62)
      ..lineTo(w, h * 0.35)
      ..lineTo(w, h * 0.85)
      ..close();
    canvas.drawPath(
      crown,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [const Color(0xFFFDC903), color, const Color(0xFFFDC903)],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Offset.zero & size),
    );
    // Base band + tip dots (kept inside the canvas bounds).
    canvas.drawRect(Rect.fromLTWH(0, h * 0.85, w, h * 0.15), Paint()..color = color);
    final dot = Paint()..color = const Color(0xFFFDC903);
    canvas.drawCircle(Offset(w * 0.05, h * 0.30), w * 0.04, dot);
    canvas.drawCircle(Offset(w * 0.5, h * 0.08), w * 0.04, dot);
    canvas.drawCircle(Offset(w * 0.95, h * 0.30), w * 0.04, dot);
  }

  @override
  bool shouldRepaint(covariant _CrownPainter old) => old.color != color;
}

/// Winged hexagonal shield badge (mockup #35 milestone emblems:
/// unlocked = gold shield + crown, in-progress = gold shield +
/// people, locked = silver/grey shield + padlock). The mockup's
/// detailed winged badge is an asset gap — this is the closest
/// honest drawn badge (hexagon + wing fans + centre glyph).
enum ArenaBadgeKind { crown, people, lock }

class ArenaWingedBadge extends StatelessWidget {
  const ArenaWingedBadge({super.key, this.size = 72, required this.kind, this.locked = false, this.pct, this.glow = false});
  final double size;
  final ArenaBadgeKind kind;
  final bool locked;
  final int? pct; // In-progress % — shown at the shield's bottom point, like mockup #35.
  final bool glow; // Soft gold halo on the unlocked badge (mockup #35).

  @override
  Widget build(BuildContext context) {
    final gold = locked ? kMuted : kGold;
    // Extra room around the badge only when it glows, so the halo
    // is not clipped at the widget edge (wings already fit inside
    // the badge box by construction).
    final padW = glow ? 24.0 : 0.0;
    final padH = glow ? 16.0 : 0.0;
    // D3 PREMIUM BADGES (user order 2026-11-20 ~18:13 PKT): the
    // badge base is the user's OWN premium crest art
    // (assets/images/splash_crest.png — gold winged shield + crown,
    // dark shield centre, metallic gold), NOT the flat drawn
    // hexagon. The kind glyph sits on the crest's dark centre; the
    // drawn painter survives only as the errorBuilder fallback if
    // the asset ever fails to load. Locked badges render the same
    // crest desaturated (honest locked state, same art).
    final crest = Image.asset(
      'assets/images/splash_crest.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => CustomPaint(size: Size(size, size), painter: _WingedShieldPainter(locked: locked)),
    );
    return SizedBox(
      width: size + padW,
      height: size + padH,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (glow)
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: goldGlow(alpha: 0.45, blur: 16, spread: 0, offset: Offset.zero)),
            ),
          locked
              ? Opacity(
                  opacity: 0.75,
                  child: ColorFiltered(
                    colorFilter: const ColorFilter.matrix(<double>[
                      0.2126, 0.7152, 0.0722, 0, 0, //
                      0.2126, 0.7152, 0.0722, 0, 0, //
                      0.2126, 0.7152, 0.0722, 0, 0, //
                      0, 0, 0, 1, 0,
                    ]),
                    child: crest,
                  ),
                )
              : crest,
          if (kind == ArenaBadgeKind.crown)
            ArenaCrownIcon(size: size * 0.30, color: gold)
          else if (kind == ArenaBadgeKind.people)
            Icon(Icons.group, color: gold, size: size * 0.34)
          else
            Icon(Icons.lock, color: locked ? kMuted : kGold, size: size * 0.30),
          if (pct != null)
            Positioned(
              bottom: padH / 2 + size * 0.02,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(color: const Color(0xFF0A0A0F).withValues(alpha: 0.75), borderRadius: BorderRadius.circular(6)),
                child: Text('$pct%', style: TextStyle(color: kGold, fontSize: 9, fontWeight: FontWeight.w900)),
              ),
            ),
        ],
      ),
    );
  }
}

class _WingedShieldPainter extends CustomPainter {
  final bool locked;
  const _WingedShieldPainter({required this.locked});

  Path _shieldPath(double x, double y, double w, double h) {
    return Path()
      ..moveTo(x + w * 0.08, y + h * 0.12)
      ..lineTo(x + w * 0.92, y + h * 0.12)
      ..lineTo(x + w, y + h * 0.30)
      ..lineTo(x + w * 0.78, y + h * 0.72)
      ..lineTo(x + w * 0.5, y + h)
      ..lineTo(x + w * 0.22, y + h * 0.72)
      ..lineTo(x, y + h * 0.30)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final sw = size.width * 0.56, sh = size.height * 0.82;
    final sx = cx - sw / 2, sy = size.height * 0.06;
    final midY = sy + sh * 0.42;
    // Wing fans: three short strokes fanning out on each side.
    // Reach is sized so the tips stay inside the canvas (the
    // painter is clipped to its box).
    final wing = Paint()
      ..color = locked ? kMuted.withValues(alpha: 0.85) : kGold.withValues(alpha: 0.9)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final reach = size.width * 0.18;
    for (var i = 0; i < 3; i++) {
      final dy = i * size.height * 0.07;
      final extra = i * size.width * 0.015;
      canvas.drawLine(Offset(sx + 3, midY + dy), Offset(sx - reach - extra, midY - size.height * 0.10 + dy), wing);
      canvas.drawLine(Offset(sx + sw - 3, midY + dy), Offset(sx + sw + reach + extra, midY - size.height * 0.10 + dy), wing);
    }
    // Shield body: metallic gold (or flat grey when locked).
    final shield = _shieldPath(sx, sy, sw, sh);
    canvas.drawPath(
      shield,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: locked
              ? [const Color(0xFF9AA0AE), const Color(0xFF5A5F6B)]
              : [const Color(0xFFFDC903), kGold, const Color(0xFFFDC903)],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromLTWH(sx, sy, sw, sh)),
    );
    // Inner rim.
    final rim = _shieldPath(sx + sw * 0.07, sy + sh * 0.05, sw * 0.86, sh * 0.86);
    canvas.drawPath(
      rim,
      Paint()
        ..color = locked ? const Color(0xFFC8CCD6).withValues(alpha: 0.7) : const Color(0xFFFDC903).withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _WingedShieldPainter old) => old.locked != locked;
}

/// Winged gold-ring medallion (mockup #25 achievements: gold rings
/// with small wings flaring left/right + a soft gold glow inside
/// the ring). The mockup's winged/laurel frames are an asset gap —
/// this is the closest honest drawn medallion.
class ArenaWingedMedallion extends StatelessWidget {
  const ArenaWingedMedallion({super.key, this.size = 56, required this.icon, this.glow = true});
  final double size;
  final IconData icon;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    // Extra room on the sides (wings) and top/bottom (glow halo) so
    // neither is clipped at the widget edge.
    return SizedBox(
      width: size + 28,
      height: size + 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(size: Size(size + 28, size), painter: _MedallionWingsPainter()),
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: kGold.withValues(alpha: 0.15),
              border: Border.all(color: kGold, width: 2),
              boxShadow: glow ? goldGlow(alpha: 0.35, blur: 12, spread: 0, offset: Offset.zero) : null,
            ),
            child: Icon(icon, color: kGold, size: size * 0.46),
          ),
        ],
      ),
    );
  }
}

class _MedallionWingsPainter extends CustomPainter {
  const _MedallionWingsPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    final r = size.height / 2;
    final wing = Paint()
      ..color = kGold.withValues(alpha: 0.9)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final dy = i * 6.0 - 6.0;
      canvas.drawLine(Offset(cx - r + 2, cy + dy), Offset(cx - r - 11 - i * 2, cy - 8 + dy), wing);
      canvas.drawLine(Offset(cx + r - 2, cy + dy), Offset(cx + r + 11 + i * 2, cy - 8 + dy), wing);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Diagonal brushed-metal sheen (mockup #10: diagonal light stripes
/// running top-left to bottom-right across the hero + image blocks).
/// Static paint — no animation; the shimmer pulse on the bars stays
/// the existing subtle 1500 ms pulse.
class _BrushedMetalPainter extends CustomPainter {
  const _BrushedMetalPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // One wide soft diagonal light band.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.07),
            Colors.white.withValues(alpha: 0.02),
            Colors.white.withValues(alpha: 0.09),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
        ).createShader(Offset.zero & size),
    );
    // Fine diagonal hairlines, top-left to bottom-right.
    final line = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1.0;
    for (var x = -size.height; x < size.width; x += 14) {
      canvas.drawLine(Offset(x.toDouble(), 0), Offset(x + size.height, size.height), line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Small gold dashed-ring spinner (mockup #10: the hero spinner is
/// a dashed gold ring, not a solid arc). One slow rotation.
class _GoldDashedSpinner extends StatefulWidget {
  const _GoldDashedSpinner({this.size = 20});
  final double size;

  @override
  State<_GoldDashedSpinner> createState() => _GoldDashedSpinnerState();
}

class _GoldDashedSpinnerState extends State<_GoldDashedSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(size: Size(widget.size, widget.size), painter: _DashedRingPainter(_ctrl.value)),
    );
  }
}

class _DashedRingPainter extends CustomPainter {
  final double t;
  const _DashedRingPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 1.5;
    final paint = Paint()
      ..color = kGold
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 8; i++) {
      final a0 = t * 2 * pi + i * (2 * pi / 8);
      canvas.drawArc(Rect.fromCircle(center: center, radius: r), a0, 0.35, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRingPainter old) => old.t != t;
}

/// Broken-WiFi illustration (mockup #11): gold neon double-line
/// arcs with a crack through the top two, a dot at the bottom, a
/// large 3D metallic gold shield overlapping the bottom-right, gold
/// sparkles + short radiating dashes, all inside a soft gold halo.
/// Drawn art — no new asset. Static (the mockup is a still).
class _OfflineIllustrationPainter extends CustomPainter {
  const _OfflineIllustrationPainter();

  double _rad(double deg) => deg * pi / 180;

  void _arc(Canvas canvas, Offset c, double r, double startDeg, double sweepDeg) {
    // Neon tube: wide faint stroke under a thin bright one.
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      _rad(startDeg),
      _rad(sweepDeg),
      false,
      Paint()
        ..color = kGold.withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      _rad(startDeg),
      _rad(sweepDeg),
      false,
      Paint()
        ..color = kGold.withValues(alpha: 0.95)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    // Soft gold halo behind the whole illustration.
    canvas.drawCircle(
      Offset(cx, size.height * 0.48),
      size.width * 0.48,
      Paint()
        ..shader = RadialGradient(
          colors: [kGold.withValues(alpha: 0.22), kGold.withValues(alpha: 0.0)],
        ).createShader(Rect.fromCircle(center: Offset(cx, size.height * 0.48), radius: size.width * 0.48)),
    );
    final dotC = Offset(cx, size.height * 0.74);
    // Arcs centred on the dot; top arc + middle arc are cracked
    // near the top centre (mockup #11).
    _arc(canvas, dotC, size.width * 0.20, -160, 140);
    _arc(canvas, dotC, size.width * 0.31, -160, 64);
    _arc(canvas, dotC, size.width * 0.31, -84, 64);
    _arc(canvas, dotC, size.width * 0.42, -160, 60);
    _arc(canvas, dotC, size.width * 0.42, -80, 60);
    // Dot at the bottom of the arcs.
    canvas.drawCircle(dotC, 7, Paint()..color = kGold);
    canvas.drawCircle(dotC, 7, Paint()
      ..color = kGold.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);
    // Short radiating dashes (top-left of the arcs).
    final dash = Paint()
      ..color = kGold.withValues(alpha: 0.85)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(38, 52), const Offset(30, 40), dash);
    canvas.drawLine(const Offset(52, 38), const Offset(46, 24), dash);
    canvas.drawLine(const Offset(70, 30), const Offset(68, 16), dash);
    canvas.drawLine(const Offset(24, 78), const Offset(12, 74), dash);
    // Sparkles: small 4-point stars at fixed spots.
    void sparkle(double x, double y, double s, double a) {
      final p = Paint()
        ..color = kGold.withValues(alpha: a)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(x - s, y), Offset(x + s, y), p);
      canvas.drawLine(Offset(x, y - s), Offset(x, y + s), p);
    }

    sparkle(28, 108, 4, 0.9);
    sparkle(172, 44, 4, 0.9);
    sparkle(182, 118, 3, 0.7);
    sparkle(150, 22, 3, 0.7);
    sparkle(56, 148, 3, 0.6);
    // 3D metallic gold shield, bottom-right, overlapping the arcs.
    final scx = size.width * 0.70, stop = size.height * 0.52, sw = 64.0, sh = 76.0;
    final shield = Path()
      ..moveTo(scx - sw / 2, stop + 10)
      ..quadraticBezierTo(scx, stop - 2, scx + sw / 2, stop + 10)
      ..lineTo(scx + sw / 2 - 2, stop + 42)
      ..quadraticBezierTo(scx + sw / 2 - 4, stop + 62, scx, stop + sh)
      ..quadraticBezierTo(scx - sw / 2 + 4, stop + 62, scx - sw / 2 + 2, stop + 42)
      ..close();
    // Drop shadow, then the metallic fill.
    canvas.drawPath(shield.shift(const Offset(2, 3)), Paint()..color = Colors.black.withValues(alpha: 0.35));
    canvas.drawPath(
      shield,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [const Color(0xFFFDC903), kGold, const Color(0xFF9A6B00)],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromLTWH(scx - sw / 2, stop, sw, sh)),
    );
    // Inner rim + top-left highlight facet.
    final rim = Path()
      ..moveTo(scx - sw / 2 + 6, stop + 14)
      ..quadraticBezierTo(scx, stop + 5, scx + sw / 2 - 6, stop + 14)
      ..lineTo(scx + sw / 2 - 8, stop + 40)
      ..quadraticBezierTo(scx + sw / 2 - 9, stop + 56, scx, stop + sh - 7)
      ..quadraticBezierTo(scx - sw / 2 + 9, stop + 56, scx - sw / 2 + 8, stop + 40)
      ..close();
    canvas.drawPath(
      rim,
      Paint()
        ..color = const Color(0xFFFDC903).withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawLine(
      Offset(scx - sw / 2 + 8, stop + 16),
      Offset(scx - sw / 2 + 8, stop + 44),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.35)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Loading skeleton block (§6.1 #10): dark placeholder bar with a
/// flat gold pulse (no gradient — flat design tokens). Callers
/// compose rows of these while data loads. No shimmer dependency.
class LoadingSkeleton extends StatefulWidget {
  const LoadingSkeleton({super.key, this.height = 16, this.width, this.radius = 8});
  final double height;
  final double? width;
  final double radius;

  @override
  State<LoadingSkeleton> createState() => _LoadingSkeletonState();
}

class _LoadingSkeletonState extends State<LoadingSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        // Mockup #10: the bars are a metallic gold→grey gradient,
        // gently pulsing (1500 ms, reverse) — subtle, never flashing.
        final t = _controller.value;
        return Container(
          height: widget.height,
          width: widget.width,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                kGold.withValues(alpha: 0.22 + 0.16 * t),
                kGold.withValues(alpha: 0.10 + 0.08 * t),
                kSurface,
              ],
              stops: const [0.0, 0.55, 1.0],
            ),
          ),
        );
      },
    );
  }
}

/// Home loading skeleton (§6.1 #10): the mockup's home layout with
/// shimmer bars — real header (logo + bell + avatar ring), "Welcome
/// back," + name pills, hero card with spinner + VIEW EVENT pill,
/// TOURNAMENTS heading + filter pills, two tournament card skeletons
/// and a Your Next Match skeleton. Body content only — the bottom
/// nav comes from HomeShell.
///
/// J-detail-fix1: the mockup's hero + image blocks + next-match card
/// carry the diagonal brushed-metal sheen (drawn, static), the hero
/// has 4 shimmer bars with a dashed gold ring spinner between them,
/// and the VIEW EVENT pill + selected "All" pill carry the soft gold
/// glow the mockup shows. Shimmer stays subtle (existing pulse).
class HomeLoadingSkeleton extends StatelessWidget {
  const HomeLoadingSkeleton({super.key});

  /// A skeleton block with the mockup #10 diagonal brushed-metal
  /// sheen painted over it (clipped to the block's radius).
  Widget _sheenBlock({required double height, required double width, double radius = 12}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        children: [
          LoadingSkeleton(height: height, width: width, radius: radius),
          const Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _BrushedMetalPainter()))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        // Header: real logo + bell, skeleton avatar circle.
        Row(
          children: [
            const ArenaLogo(crownSize: 40, fontSize: 22),
            const Spacer(),
            Icon(Icons.notifications_outlined, color: kMuted, size: 26),
            const SizedBox(width: 10),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kGold, width: 2), color: kSurface),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text('Welcome back,', style: TextStyle(color: kText, fontSize: 15)),
        const SizedBox(height: 8),
        const Row(
          children: [
            LoadingSkeleton(height: 22, width: 120, radius: 11),
            SizedBox(width: 8),
            LoadingSkeleton(height: 22, width: 150, radius: 11),
          ],
        ),
        const SizedBox(height: 16),
        // Hero card skeleton — diagonal brushed-metal sheen over the
        // whole card (mockup #10), 4 shimmer bars, dashed gold ring
        // spinner, VIEW EVENT pill with its soft gold glow.
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(
            height: 190,
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(20), border: Border.all(color: kBorder)),
            child: Stack(
              children: [
                const Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _BrushedMetalPainter()))),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const LoadingSkeleton(height: 18, width: 180, radius: 9),
                      const SizedBox(height: 10),
                      const LoadingSkeleton(height: 14, width: double.infinity, radius: 7),
                      const SizedBox(height: 8),
                      const LoadingSkeleton(height: 14, width: 220, radius: 7),
                      const SizedBox(height: 10),
                      const Center(child: _GoldDashedSpinner(size: 20)),
                      const SizedBox(height: 10),
                      const LoadingSkeleton(height: 14, width: double.infinity, radius: 7),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: kGold, width: 1.5),
                          // Mockup #10: soft gold glow under the pill.
                          boxShadow: goldGlow(alpha: 0.35, blur: 10, spread: 0, offset: const Offset(0, 3)),
                        ),
                        child: Text('VIEW EVENT', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 0.5)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Container(width: 4, height: 22, decoration: BoxDecoration(color: kGold, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 8),
            // Mockup #10: the TOURNAMENTS heading is italic.
            // FIX 6 (2026-11-21): Flexible + scaleDown — at a wide
            // font / large text scale the bare Text overflowed the
            // row (39px at 360dp in the FIX 6 render test).
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('TOURNAMENTS', style: TextStyle(color: kText, fontSize: 20, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic)),
              ),
            ),
            const Spacer(),
            Text('View All →', style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 13)),
          ],
        ),
        const SizedBox(height: 12),
        // FIX 6 (2026-11-21): pills share the row via Expanded
        // (like Home's real _filterPill) — the old fixed-width
        // pills overflowed by 138px at 360dp with a wide font.
        Row(
          children: [
            Expanded(child: _filterPill('All', selected: true)),
            const SizedBox(width: 8),
            Expanded(child: _filterPill('Live')),
            const SizedBox(width: 8),
            Expanded(child: _filterPill('Upcoming')),
            const SizedBox(width: 8),
            Expanded(child: _filterPill('My Games')),
          ],
        ),
        const SizedBox(height: 14),
        _tournamentCardSkeleton(statusLabel: 'UPCOMING', statusKind: StatusKind.upcoming, primaryLabel: 'Join Event'),
        const SizedBox(height: 12),
        _tournamentCardSkeleton(statusLabel: 'LIVE', statusKind: StatusKind.live, primaryLabel: 'Watch', primaryIcon: Icons.play_arrow),
        const SizedBox(height: 14),
        // Your Next Match skeleton (mockup #10 shows the heading
        // above the VS-card skeleton) — same brushed-metal sheen.
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: kBorder)),
            child: Stack(
              children: [
                const Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _BrushedMetalPainter()))),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Your Next Match', style: TextStyle(color: kText, fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Container(width: 38, height: 38, decoration: BoxDecoration(shape: BoxShape.circle, color: kSurface)),
                          const SizedBox(width: 10),
                          const LoadingSkeleton(height: 16, width: 140, radius: 8),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Row(
                        children: [
                          LoadingSkeleton(height: 34, width: 34, radius: 17),
                          SizedBox(width: 10),
                          Expanded(child: LoadingSkeleton(height: 14, radius: 7)),
                          SizedBox(width: 10),
                          Expanded(child: LoadingSkeleton(height: 14, radius: 7)),
                          SizedBox(width: 10),
                          LoadingSkeleton(height: 34, width: 34, radius: 17),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Filter pill skeleton (#10): the mockup shows real pill outlines
  /// with muted labels (Live / Upcoming / My Games) — only the "All"
  /// pill is gold-outlined with gold text on dark, never a solid
  /// gold fill.
  Widget _filterPill(String label, {bool selected = false}) {
    return Container(
      // FIX 6 (2026-11-21): centred + scaleDown — the pill now
      // lives in an Expanded (row shares width), so a long label
      // shrinks instead of overflowing.
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: selected ? kGold : kBorder, width: selected ? 1.5 : 1),
        // Mockup #10: the selected "All" pill carries a soft gold glow.
        boxShadow: selected ? goldGlow(alpha: 0.30, blur: 8, spread: 0, offset: const Offset(0, 2)) : null,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label, style: TextStyle(color: selected ? kGold : kMuted, fontWeight: FontWeight.bold, fontSize: 13)),
      ),
    );
  }

  /// One tournament card skeleton (#10): image block left, status
  /// pill, title/date lines, muted Details + dimmed gold action.
  /// [primaryIcon] renders before the action label (mockup #10:
  /// the Watch button carries a play-triangle icon).
  Widget _tournamentCardSkeleton({required String statusLabel, required StatusKind statusKind, required String primaryLabel, IconData? primaryIcon}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16), border: Border.all(color: kBorder)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(12), child: _sheenBlock(height: 118, width: 96, radius: 12)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusBadge(label: statusLabel, kind: statusKind, dot: statusKind == StatusKind.live),
                const SizedBox(height: 8),
                const LoadingSkeleton(height: 15, width: 200, radius: 7),
                const SizedBox(height: 8),
                const LoadingSkeleton(height: 12, width: 150, radius: 6),
                const SizedBox(height: 10),
                const LoadingSkeleton(height: 6, width: double.infinity, radius: 3),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: kBorder)),
                        child: Text('Details', style: TextStyle(color: kMuted, fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: kGold.withValues(alpha: 0.45)),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (primaryIcon != null) ...[
                              Icon(primaryIcon, size: 16, color: const Color(0xFF0A0A0F)),
                              const SizedBox(width: 4),
                            ],
                            // FIX 6 (2026-11-21): Flexible +
                            // scaleDown — the bare label overflowed
                            // the half-width button by 40px with a
                            // wide font / large text scale.
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(primaryLabel, style: const TextStyle(color: Color(0xFF0A0A0F), fontWeight: FontWeight.bold, fontSize: 13)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Error state: icon, message, retry button.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry, this.retryLabel = 'Retry'});
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: kRed, size: 48),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center, style: TextStyle(color: kText, fontSize: 15)),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            GoldButton(label: retryLabel, onPressed: onRetry, fullWidth: false),
          ],
        ],
      ),
    );
  }
}

/// Offline state (§6.1 #11): gold ARENA HUB emblem, broken-wifi +
/// shield illustration (drawn, never a photo), "YOU'RE OFFLINE"
/// (white + gold), message, "Connection Unavailable" pill, gold
/// RETRY CONNECTION pill and a GO BACK outline pill. Batch 3A #11:
/// the default `message` is the #11 mockup subtitle ("Check your
/// internet connection and try again.") — full-screen call sites
/// already passed it explicitly, inline usages showed the old
/// default. GO BACK always renders (mockup #11): an explicit
/// `onGoBack` runs that; with none, it pops this route when
/// possible, else exits the app (full-screen use, e.g. SplashGate —
/// the same action as the system back button from the root route).
///
/// J-detail-fix1: the illustration is now the mockup's drawn art
/// (neon arcs with a crack + 3D gold shield + sparkles + halo,
/// `_OfflineIllustrationPainter`) instead of a flat wifi_off glyph;
/// the RETRY pill carries the soft gold glow the mockup shows under
/// it (viewed in 12_youre_offline.jpg — the glow sits under RETRY,
/// the GO BACK pill is flat). GO BACK is a dark kCard fill like the
/// mockup (2026-11-22: transparent vanished into the backdrop).
/// Spacing re-measured against mockup #11 (2026-11-22): 16/24/48
/// gaps heading→subtitle→pill→RETRY; heading in a scaleDown
/// FittedBox so it can never clip on narrow screens.
/// NOTE: the default `message` is the #11 mockup subtitle (Batch
/// 3A #11); the #11 mockup subtitle ("Check your internet
/// connection and try again.") used to be passed explicitly by call
/// sites that show the full-screen state, and is now the default —
/// the existing component test (`arena_components_test.dart`) that
/// asserts the old default will need its expectation updated.
class OfflineState extends StatelessWidget {
  const OfflineState({super.key, this.message = 'Check your internet connection and try again.', this.onRetry, this.retryLabel = 'RETRY CONNECTION', this.onGoBack, this.goBackLabel = 'GO BACK', this.useNewLogo = false, this.showGoBack = true});
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final VoidCallback? onGoBack;
  final String goBackLabel;
  // PHASE E (E21): the full-screen OfflineScreen uses the NEW logo
  // badge (E18 style — full emblem, no ClipOval); inline usages
  // keep the admin-branded ArenaLogo (default false).
  final bool useNewLogo;
  // PHASE E (E22): the mid-session overlay hides GO BACK.
  final bool showGoBack;

  @override
  Widget build(BuildContext context) {
    // GO BACK default (mockup #11: always rendered): an explicit
    // callback wins; otherwise pop this route when possible, else
    // exit the app (full-screen use, e.g. SplashGate).
    final goBack = onGoBack ??
        () {
          if (Navigator.canPop(context)) {
            Navigator.pop(context);
          } else {
            SystemNavigator.pop();
          }
        };
    // REDESIGN S16 (guide §6 Screen 16): logo + illustration stay
    // centre-aligned (Column default cross-axis), heading is now
    // prominent ALL-WHITE per the guide (was: "YOU'RE " white +
    // "OFFLINE" gold), spacing/buttons/badges use the F1/F2 contract
    // tokens + components. Behaviour unchanged: same callbacks,
    // same go-back default, same 600px fit cap.
    return Padding(
      padding: const EdgeInsets.all(kSpace24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // PHASE E (E21): full-screen use shows the NEW logo
          // badge (E18 style); inline usages keep ArenaLogo.
          if (useNewLogo)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset(
                'assets/images/arena_hub_logo.png',
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    const ArenaLogo(crownSize: 56, fontSize: 26),
              ),
            )
          else
            const ArenaLogo(crownSize: 56, fontSize: 26),
          const SizedBox(height: kSpace24),
          // Mockup #11 illustration, drawn (arcs + crack + 3D gold
          // shield + sparkles + halo) — no asset, no photo. The
          // painter's soft gold halo IS the guide's "subtle glow";
          // the illustration itself is unchanged.
          const SizedBox(
            key: ValueKey('offline-illustration'),
            width: 172,
            height: 172,
            child: CustomPaint(painter: _OfflineIllustrationPainter()),
          ),
          const SizedBox(height: kSpace24),
          // Heading: FittedBox scaleDown is the overflow safety —
          // 36px fits "YOU'RE OFFLINE" on one line at 360dp, but
          // on narrower screens it shrinks instead of clipping
          // (nothing may be cut, per the standing rule).
          FittedBox(
            fit: BoxFit.scaleDown,
            child: RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                // Large display title (36 px — the largest size
                // that still fits "YOU'RE OFFLINE" on one line at
                // 360 dp). REDESIGN S16: prominent WHITE per guide
                // §6 Screen 16 (was white + gold "OFFLINE").
                style: TextStyle(fontSize: 36, fontWeight: FontWeight.w900, fontStyle: FontStyle.italic, height: 1.1, color: kText),
                children: [
                  TextSpan(text: "YOU'RE ", style: TextStyle(color: kText)),
                  TextSpan(text: 'OFFLINE', style: TextStyle(color: kText)),
                ],
              ),
            ),
          ),
          // Spacing re-measured against mockup #11 (2026-11-22):
          // heading→subtitle ~16, subtitle→pill ~24, pill→RETRY
          // ~40 (the buttons sit low, with a large gap under the
          // pill — the old 10/16/28 clumped the block together).
          // CAP (2026-11-22): the block must fit a 600px viewport
          // (offline_screen_test taps both buttons without
          // scrolling) — the 48 gap + 200 illustration pushed GO
          // BACK to y=628, off-screen. 40/172 keeps the mockup
          // proportions on tall phones and fits short ones.
          const SizedBox(height: kSpace16),
          Text(message, textAlign: TextAlign.center, style: kStyleBody.copyWith(color: kMuted)),
          const SizedBox(height: kSpace24),
          // REDESIGN S16: small OUTLINED status badge per guide §6
          // Screen 16 — transparent fill so the gold outline reads,
          // kWarning dot (contract amber token; was hardcoded
          // 0xFFFF9800 orange).
          Container(
            key: const ValueKey('offline-status-badge'),
            padding: const EdgeInsets.symmetric(horizontal: kSpace12, vertical: kSpace8),
            decoration: BoxDecoration(color: Colors.transparent, borderRadius: BorderRadius.circular(20), border: Border.all(color: kGold.withValues(alpha: 0.6))),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 8, height: 8, decoration: const BoxDecoration(shape: BoxShape.circle, color: kWarning)),
                const SizedBox(width: kSpace8),
                Text('Connection Unavailable', style: kStyleMeta.copyWith(color: kText, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 40),
            // REDESIGN S16: primary yellow button = contract
            // ArenaPrimaryButton (kGoldGradient fill, dark text,
            // warm shadow built into the component). Same onRetry
            // callback, same full-width, same label.
            SizedBox(
              width: double.infinity,
              child: ArenaPrimaryButton(
                onPressed: onRetry,
                child: Text(retryLabel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 0.5, color: Color(0xFF0A0A0F))),
              ),
            ),
          ],
          // Mockup #11: GO BACK always renders (except the E22
          // mid-session overlay, where showGoBack is false).
          // Explicit `onGoBack` runs that; otherwise pop this
          // route when possible, else exit the app (full-screen
          // use — same as the system back button from the root
          // route).
          if (showGoBack) ...[
            const SizedBox(height: kSpace12),
            // REDESIGN S16: secondary dark button = contract
            // ArenaSecondaryButton (dark surface, thin grey border,
            // white text). Same goBack behaviour, same label.
            SizedBox(
              width: double.infinity,
              child: ArenaSecondaryButton(
                onPressed: goBack,
                child: Text(goBackLabel, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 0.5, color: kText)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Search field: search icon, gold focus border, rounded 12.
/// [focusNode] lets a caller focus this exact field from elsewhere —
/// e.g. a header search icon that focuses the real in-body search
/// (mockup #22) instead of being a decorative dead icon.
/// [iconAtEnd] puts the magnifier at the RIGHT inside the field and
/// [borderRadius] makes it a full pill — mockup #5 leaderboard
/// (search icon right, radius ~24). Defaults keep every other caller
/// (FAQs, team search, admin) byte-identical.
class ArenaSearchBar extends StatelessWidget {
  const ArenaSearchBar({super.key, required this.controller, this.hint = 'Search', this.onChanged, this.focusNode, this.iconAtEnd = false, this.borderRadius = 12});
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final bool iconAtEnd;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      style: TextStyle(color: kText),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: kMuted),
        prefixIcon: iconAtEnd ? null : Icon(Icons.search, color: kMuted),
        suffixIcon: iconAtEnd ? Icon(Icons.search, color: kMuted) : null,
        filled: true,
        fillColor: kField,
        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(borderRadius), borderSide: BorderSide(color: kBorder)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(borderRadius), borderSide: BorderSide(color: kGold, width: 1.5)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(borderRadius), borderSide: BorderSide(color: kBorder)),
      ),
    );
  }
}

/// Filter tabs: active = gold pill with dark text; inactive = dark
/// outline pill. Used for All / Live / Upcoming / My Games (§6.1 #37).
/// [expanded] renders the labels as EQUAL shares of the available
/// width in one Row (no scroll, no gaps) — mockup #5 leaderboard:
/// Global / Weekly / Friends as three equal thirds inside one dark
/// rounded box, the active pill gold-filled across its whole third,
/// inactive segments transparent with grey text. Default false keeps
/// the old content-width scroll row for every other caller.
class FilterTabs extends StatelessWidget {
  const FilterTabs({super.key, required this.labels, required this.selectedIndex, required this.onSelected, this.expanded = false, this.segmented = false});
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool expanded;

  /// Segmented-bar mode (mockup #5 leaderboard tabs): the pills sit
  /// inside ONE outer container border — no per-pill outline. The
  /// default (false) keeps the Batch 3A #21 per-pill grey outline
  /// (mockup #21 notifications pills). Only the leaderboard's
  /// expanded segmented bar passes segmented:true.
  final bool segmented;

  Widget _pill(int i) {
    final active = i == selectedIndex;
    // PHASE E (E24, CORRECTED 2026-11-24): selected = solid gold
    // fill (Sameer: "click pe yellow hona chahiye"); rest = card
    // fill (shared token) — never black. Segmented pills sit
    // inside a card strip already, so the rest segments stay
    // transparent (the strip's fill shows through) and only the
    // selected one wears the gold fill.
    final BoxDecoration decoration;
    if (segmented) {
      decoration = BoxDecoration(
        color: active ? kGold : null,
        borderRadius: BorderRadius.circular(20),
      );
    } else {
      decoration = active
          ? BoxDecoration(
              color: kGold,
              borderRadius: BorderRadius.circular(20),
            )
          : cardFillDecoration(radius: 20).copyWith(
              border: Border.all(color: kBorder, width: 1),
            );
    }
    return GestureDetector(
      onTap: () => onSelected(i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        alignment: Alignment.center,
        decoration: decoration,
        child: Text(labels[i],
            style: TextStyle(
                color: active
                    ? const Color(0xFF0A0A0F)
                    : (expanded ? kMuted : kText),
                fontWeight: FontWeight.bold,
                fontSize: expanded ? 15 : 13)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (expanded) {
      return Row(
        children: [for (var i = 0; i < labels.length; i++) Expanded(child: _pill(i))],
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            _pill(i),
            if (i < labels.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------- dashed border

/// Dashed rounded-rect border painter (Wave 4b #8/#23). Flutter core
/// has no `BorderStyle.dashed`, so the mockups' dashed upload / empty
/// boxes are drawn with this painter — no new package. Same dash/gap
/// as the private painter in pro_features.dart (#2/#4 upload boxes);
/// this public version lives here so every screen can share it.
/// The border is painted as a FOREGROUND painter, so a
/// [ArenaDashedBorder.backgroundColor] fill never covers the dashes.
class ArenaDashedBorderPainter extends CustomPainter {
  const ArenaDashedBorderPainter({required this.color, this.radius = 12, this.dash = 8, this.gap = 6, this.strokeWidth = 1.5});
  final Color color;
  final double radius;
  final double dash;
  final double gap;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      // Round caps: square-cut dash ends looked jagged at small
      // sizes (Fix 2 HD sweep, 2026-11-21). Dashes are intentional
      // here (mockup upload/empty boxes) — only the ends are
      // softened; dash/gap lengths are unchanged.
      ..strokeCap = StrokeCap.round;
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        canvas.drawPath(metric.extractPath(dist, min(dist + dash, metric.length)), paint);
        dist += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant ArenaDashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius || oldDelegate.dash != dash || oldDelegate.gap != gap || oldDelegate.strokeWidth != strokeWidth;
}

/// Dashed-border box (Wave 4b #8/#23): a rounded rect with a gold
/// dashed outline around [child]. [onTap] makes the whole box
/// tappable (upload boxes); [backgroundColor] fills the box without
/// covering the dashes. No data is invented here — callers pass the
/// real content and the real tap handler.
class ArenaDashedBorder extends StatelessWidget {
  const ArenaDashedBorder({super.key, required this.child, this.color, this.radius = 12, this.backgroundColor, this.padding = const EdgeInsets.all(14), this.onTap, this.dash = 8, this.gap = 6, this.strokeWidth = 1.5});
  final Widget child;
  final Color? color;
  final double radius;
  final Color? backgroundColor;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final double dash;
  final double gap;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final box = CustomPaint(
      foregroundPainter: ArenaDashedBorderPainter(color: color ?? kGold, radius: radius, dash: dash, gap: gap, strokeWidth: strokeWidth),
      child: Container(
        width: double.infinity,
        padding: padding,
        decoration: backgroundColor == null ? null : BoxDecoration(color: backgroundColor, borderRadius: BorderRadius.circular(radius)),
        child: child,
      ),
    );
    if (onTap == null) return box;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(radius), child: box);
  }
}

// ---------------------------------------------------------------- embers

/// Animated golden ember dots drifting upward behind content, like
/// flying sparks (mockup background motif — Leaderboard plan #5 first,
/// ported here from the L round as the shared implementation).
/// Lightweight by design: one CustomPaint, 16 dots from a fixed table
/// (no per-frame allocation), a single repeating controller;
/// RepaintBoundary isolates the repaint. Use inside a Stack behind the
/// content with IgnorePointer so taps pass through. Dots fade in near
/// the bottom and out near the top so nothing pops.
class ArenaEmberDots extends StatefulWidget {
  const ArenaEmberDots({super.key, this.duration = const Duration(seconds: 16), this.dotColor});
  final Duration duration;
  final Color? dotColor;

  @override
  State<ArenaEmberDots> createState() => _ArenaEmberDotsState();
}

class _ArenaEmberDotsState extends State<ArenaEmberDots> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration)..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => CustomPaint(
          painter: _ArenaEmberDotsPainter(_ctrl.value, widget.dotColor ?? kGold),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _ArenaEmberDotsPainter extends CustomPainter {
  // x, startY, radius, rise per cycle, sway phase, base alpha.
  static const _dots = <List<double>>[
    [0.05, 0.95, 2.6, 0.45, 0.00, 0.50],
    [0.12, 0.70, 1.6, 0.60, 0.30, 0.35],
    [0.18, 0.35, 2.2, 0.50, 0.55, 0.42],
    [0.25, 0.85, 1.4, 0.70, 0.15, 0.30],
    [0.32, 0.55, 3.0, 0.40, 0.70, 0.48],
    [0.40, 0.20, 1.8, 0.65, 0.45, 0.38],
    [0.47, 0.98, 2.4, 0.48, 0.85, 0.44],
    [0.55, 0.60, 1.5, 0.58, 0.20, 0.32],
    [0.62, 0.30, 2.8, 0.42, 0.60, 0.50],
    [0.68, 0.88, 1.7, 0.66, 0.05, 0.36],
    [0.75, 0.45, 2.3, 0.52, 0.40, 0.46],
    [0.82, 0.15, 1.6, 0.72, 0.75, 0.34],
    [0.88, 0.75, 2.9, 0.44, 0.25, 0.48],
    [0.93, 0.50, 1.5, 0.62, 0.50, 0.33],
    [0.97, 0.90, 2.1, 0.46, 0.65, 0.40],
    [0.08, 0.45, 1.9, 0.56, 0.90, 0.37],
  ];
  final double t;
  final Color dotColor;
  const _ArenaEmberDotsPainter(this.t, this.dotColor);

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in _dots) {
      final y = (d[1] - t * d[3]) % 1.0;
      // Gentle sideways sway (triangle wave, continuous — no pops).
      final sway = (t + d[4]) % 1.0;
      final sx = (sway < 0.5 ? sway * 2 : 2 - sway * 2) * 8 - 4;
      final x = d[0] * size.width + sx;
      // Fade in at the bottom edge, out at the top edge.
      var edge = 1.0;
      if (y > 0.85) edge = (1.0 - y) / 0.15;
      if (y < 0.15) edge = y / 0.15;
      final a = d[5] * edge;
      if (a <= 0.01) continue;
      final halo = Paint()..color = dotColor.withValues(alpha: a * 0.16);
      canvas.drawCircle(Offset(x, y * size.height), d[2] * 3, halo);
      final core = Paint()..color = dotColor.withValues(alpha: a);
      canvas.drawCircle(Offset(x, y * size.height), d[2], core);
    }
  }

  @override
  bool shouldRepaint(covariant _ArenaEmberDotsPainter old) => old.t != t || old.dotColor != dotColor;
}
