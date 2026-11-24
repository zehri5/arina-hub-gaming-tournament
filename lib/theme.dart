import 'dart:ui';

import 'package:flutter/material.dart';

/// ARENA HUB GOLD DESIGN SYSTEM (Phase 1 — 2026-11-19).
/// Replaces the neon system (2026-11-01). Single source of truth for
/// every colour token in the user app.
///
/// DARK (default, = gold-on-black): bg #070A10, surface #10131A,
/// card #181B24, border #23262F, gold #FDC903 primary, goldDeep
/// #FDC903, white text, #AAB0D0 secondary text, green #00F5A0,
/// red #FF3B30. Gold glow (low-alpha gold) on featured cards and
/// primary CTAs only.
///
/// MOCKUP COLOURS (2026-11-20, user order "har jagah"): bg/card/
/// field/border re-sampled pixel-exact from the Account Security
/// mockup (1000048230) — the old values (#0A0D14 / #1B1D29 /
/// #14141C / #2A2E3A) were a touch too light and too blue. The
/// mockup's bg is near-pure black (#080B12), its card is a vertical
/// gradient (#1D2029 top -> #15181F bottom, mid #181B24) with a
/// yellow gradient border bright at the top/bottom edges. The flat
/// tokens below are the gradient mid-tones; [MockupCard] paints the
/// full gradient + border for section cards.
/// LIGHT (accessibility mode): white bg, goldDeep accents, dark text.
/// Derived from the gold system — the old light board palette
/// (light red/white) is retired.
///
/// NEON IS RETIRED for the user app — purple #8B2CFF, pink #FF16C8,
/// magenta #D500F9, blue #426BFF, bg #070817 must not appear anywhere
/// outside the live voice room. The live room keeps its OWN local
/// neon constants (nBg/nPurple/nPink/… in room_screen.dart) and its
/// layout exactly as-is; it does not read these tokens for its stage.
/// NOTE: room sheets/dialogs DO read the shared kCard token, so their
/// background follows kCard (#10132E -> #1B1D29) — a consequence of
/// the token swap the plan prescribes, not a room restyle. kGold,
/// kText and kMuted are byte-identical in both systems, so the rest
/// of the room is pixel-identical.
///
/// Implementation note: the palette is a runtime switch (not const)
/// so the Settings toggle rebuilds the whole app. `const` usages of
/// these colours were removed where the compiler required it; the
/// values below are the single source of truth.
final ValueNotifier<bool> themeLightNotifier = ValueNotifier<bool>(false);

/// True = light mode. Read at build time (never cached in a const).
bool get appLightMode => themeLightNotifier.value;

Color get kBg => appLightMode ? const Color(0xFFF1F5F9) : const Color(0xFF070A10);
Color get kSurface => appLightMode ? Colors.white : const Color(0xFF10131A);
Color get kCard => appLightMode ? Colors.white : const Color(0xFF181B24);
Color get kBorder => appLightMode ? const Color(0xFFE2E8F0) : const Color(0xFF23262F);
Color get kField => appLightMode ? const Color(0xFFE2E8F0) : const Color(0xFF10131A);
/// GOLD RULE (Sameer, 2026-11-22 05:28, pakka hukm): poori app mein
/// SIRF #FDC903. kGold, kGoldDeep, kGoldBright, kSectionLabel aur
/// har jagah ka hardcoded gold — sab #FDC903. Purane shades (purana
/// app gold, mockup gold, material amber/yellow, halke peele, glow
/// yellow, Google yellow) sab hata diye gaye hain (221 jagah,
/// 2026-11-22). Naya gold shade add MAT karo — hamesha kGold /
/// #FDC903 use karo. (Dark gold-brown tints #1A1208 waghera
/// backgrounds hain, peela nahi — wo rakhe hain; bronze rank color
/// #CD7F32 aur orange accents bhi alag rang hain, gold nahi.)
Color get kGold => appLightMode ? const Color(0xFFFDC903) : const Color(0xFFFDC903);
const Color kGoldDeep = Color(0xFFFDC903);
const Color kGoldBright = Color(0xFFFDC903);
Color get kText => appLightMode ? const Color(0xFF0F172A) : Colors.white;
Color get kMuted => appLightMode ? const Color(0xFF64748B) : const Color(0xFFAAB0D0);
/// Section-label gold — same #FDC903 as kGold now (GOLD RULE
/// 2026-11-22). It was a muted olive-gold sampled from the Account
/// Security mockup (1000048230, 2026-11-20); the gold rule
/// supersedes that sample.
const Color kSectionLabel = Color(0xFFFDC903);
const Color kGreen = Color(0xFF00F5A0);
const Color kRed = Color(0xFFFF3B30);
const Color kLiveRed = Color(0xFFFF2D2D);

/// Mockup card gradient stops, sampled pixel-exact from the Account
/// Security mockup (1000048230): the card fill runs #1D2029 at the
/// top to #15181F at the bottom.
///
/// FIX 23 item 23: cards no longer use this grey gradient (the
/// purple gradient below replaced it), but the tokens stay —
/// they are pinned by tests and kept for compatibility.
const Color kCardGradientTop = Color(0xFF1D2029);
const Color kCardGradientBottom = Color(0xFF15181F);

// ── FIX 23 item 23 card tokens (ChatGPT design, user order 2026-11-23) ──
/// Purple card gradient stops (ChatGPT's exact values).
const Color kCardPurpleTop = Color(0xFF211052);
const Color kCardPurpleMid = Color(0xFF100829);
const Color kCardPurpleBottom = Color(0xFF080817);

/// Purple card border (ChatGPT's exact value).
const Color kCardPurpleBorder = Color(0xFF922BFF);

/// Purple card glow (ChatGPT's exact value; used at 0.25 alpha).
const Color kCardPurpleGlow = Color(0xFF8A20FF);

/// Nav bar unselected item colour (ChatGPT's exact value).
const Color kNavUnselected = Color(0xFFB9A9D8);

/// Card fill opacity — the ChatGPT gradient hues at 30% so the
/// background POSTER's shapes (soldier, helmet, smoke) show
/// through the frosted glass, not just a purple tint, while
/// white text stays legible. ONE shared number for every card
/// surface (Sameer 2026-11-24 06:22, pakka hukm — "sab numbers
/// SAME"): MockupCard, _DarkMockupCard, CardFieldShell, the
/// profile + invite cards and the nav shell all read this token,
/// so lowering it keeps nav + cards equal automatically.
/// (FIX 23 item 23: 0.85 was too hard/dark, 0.60 was STILL not
/// transparent enough per Sameer 2026-11-23 23:52 — "abhi bhi
/// transparent nahi hai". Phase E: 0.48 -> 0.30 after his v2023
/// phone feedback — "color to hai lekin design nahi dikh raha".
/// He judges the final look in the app, not the demo.)
const double kCardFillOpacity = 0.30;

/// Frosted-glass blur strength for cards (sigma, logical pixels).
/// Phase E: 12 -> 6 — the 12px blur smeared the poster shapes
/// into a wash (the nav bar shares the fill token but has NO
/// blur, which is why it looked clearer); halving the blur lets
/// the shapes read through while the 0.30 fill keeps text
/// legible. One constant so the strength is tunable in one place.
const double kCardBlurSigma = 6.0;

/// PHASE E (E24): the card fill as a FLAT color (the middle card
/// hue at [kCardFillOpacity]) for widgets that take a Color, not a
/// decoration (OutlinedButton.styleFrom, ChoiceChip, circles).
/// Same number as the card gradient — one token, everywhere.
Color get kCardFillColor =>
    kCardPurpleMid.withValues(alpha: kCardFillOpacity);

/// FIX 23 item 23 — the card FILL only (diagonal purple gradient,
/// ChatGPT's hues at [kCardFillOpacity]). Pair with
/// [cardFrameDecoration] (border + glow) and a BackdropFilter —
/// see [MockupCard] for the layering.
BoxDecoration cardFillDecoration({double radius = 22}) => BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          kCardPurpleTop.withValues(alpha: kCardFillOpacity),
          kCardPurpleMid.withValues(alpha: kCardFillOpacity),
          kCardPurpleBottom.withValues(alpha: kCardFillOpacity),
        ],
      ),
    );

/// FIX 23 item 23 — the card FRAME only (purple border + purple
/// glow, ChatGPT's exact values). No fill — it wraps the frosted
/// fill so the shadow is never clipped (see [MockupCard]).
BoxDecoration cardFrameDecoration({double radius = 22}) => BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: kCardPurpleBorder, width: 1.5),
      boxShadow: [
        BoxShadow(
          color: kCardPurpleGlow.withValues(alpha: 0.25),
          blurRadius: 15,
          spreadRadius: 1,
        ),
      ],
    );

/// FIX 23 item 23 — the floating purple nav-bar shell (ChatGPT
/// reference): dark purple fill, purple border + glow, rounded 24,
/// inset 12px from the screen edges. Wraps a bottom nav's Stack;
/// the nav inside must position its selected-tab indicator with
/// [navBarTabCenter] (the shell's inner width, not the screen
/// width). The bar itself must be transparent (the shell paints
/// the fill).
Widget navBarShell({required Widget child}) => Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: cardDecoration(radius: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: child,
      ),
    );

/// FIX 23 item 23 — the centre x of tab [index] inside a
/// [navBarShell] (inner width = screen width minus the 12px side
/// margins on each side). Use for the selected-tab indicator.
double navBarTabCenter(BuildContext context, int index) =>
    ((MediaQuery.of(context).size.width - 24) / 6) * (index + 0.5);

/// FIX 23 item 23 — the full card decoration (fill + frame) for
/// surfaces that don't need the frosted-glass layering (bespoke
/// cards whose content overflows the card edge, e.g. the profile
/// card's straddling avatar; the pills containers; the nav shell).
/// Prefer [MockupCard] for new cards.
BoxDecoration cardDecoration({double radius = 22}) => BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          kCardPurpleTop.withValues(alpha: kCardFillOpacity),
          kCardPurpleMid.withValues(alpha: kCardFillOpacity),
          kCardPurpleBottom.withValues(alpha: kCardFillOpacity),
        ],
      ),
      border: Border.all(color: kCardPurpleBorder, width: 1.5),
      boxShadow: [
        BoxShadow(
          color: kCardPurpleGlow.withValues(alpha: 0.25),
          blurRadius: 15,
          spreadRadius: 1,
        ),
      ],
    );

/// FIX 23 item 29 — card-styled text-field shell: the same
/// [cardDecoration] as every card (purple gradient + purple border
/// + glow), wrapping a borderless text field. InputDecoration cannot
/// paint a gradient fill, so the field lives inside this Container
/// and its own borders are outline borders with [BorderSide.none]
/// (filled: false) — an outline border (even with no side) keeps
/// the floating label inside the field's height; [InputBorder.none]
/// would reserve +16px above the input for the label.
/// Focus turns the border gold (the old focused-border behaviour);
/// [error] turns it red; [goldBorder] keeps it gold at rest (the
/// tournament registration field's validated-IGN state).
/// The wrapping [Focus] only listens (canRequestFocus: false) so
/// keyboard traversal is unchanged.
/// Used by [ArenaTextField], [ArenaFormField] and the chat / search /
/// profile / admin fields.
class CardFieldShell extends StatefulWidget {
  const CardFieldShell(
      {super.key,
      required this.child,
      this.radius = 22,
      this.error = false,
      this.goldBorder = false});
  final Widget child;
  final double radius;
  final bool error;
  final bool goldBorder;

  @override
  State<CardFieldShell> createState() => _CardFieldShellState();
}

class _CardFieldShellState extends State<CardFieldShell> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final borderColor = widget.error
        ? kError
        : (widget.goldBorder || _focused ? kGold : kCardPurpleBorder);
    return Focus(
      canRequestFocus: false,
      onFocusChange: (focused) {
        if (focused != _focused) setState(() => _focused = focused);
      },
      child: Container(
        decoration: cardDecoration(radius: widget.radius).copyWith(
          border: Border.all(color: borderColor, width: 1.5),
        ),
        child: widget.child,
      ),
    );
  }
}

// ── Phase 2 redesign tokens (F1, 2026-11-22) ─────────────────────────────
// Guide §2 palette / §4 typography / §8 spacing-radii, per CONTRACT.md.
// The existing tokens above are untouched (mockup-sampled,
// user-approved). GOLD RULE: the only gold in this file is #FDC903 —
// the guide's two other gold shades are NOT used anywhere; the gold
// gradient below runs kGoldSoft (#FFE16A) -> kGold (#FDC903) instead.

/// Elevated surface (dialogs, raised cards): guide Surface Elevated.
Color get kSurfaceElevated => appLightMode ? Colors.white : const Color(0xFF202331);

/// Muted text (hints, disabled text): guide Text Muted.
Color get kTextMuted => appLightMode ? const Color(0xFF94A3B8) : const Color(0xFF737789);

/// Guide Yellow Soft — highlight end of the gold gradient.
const Color kGoldSoft = Color(0xFFFFE16A);

/// Guide Warning.
const Color kWarning = Color(0xFFF4A62A);

/// Guide Error. kRed stays for its existing uses.
const Color kError = Color(0xFFF04452);

/// Main-action gradient: Yellow Soft -> gold, left to right (CTA
/// buttons). Same in both modes — both endpoints are
/// mode-independent, exactly like kGold.
LinearGradient get kGoldGradient => LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [kGoldSoft, kGold],
    );

/// Card-surface gradient (guide §2), top to bottom. Same in both
/// modes — the light-mode card fallback stays plain white (see
/// MockupCard), exactly like kCardGradientTop / kCardGradientBottom.
LinearGradient get kCardSurfaceGradient => const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFF202331), Color(0xFF12141C)],
    );

/// Background gradient (guide §2), top to bottom. Same in both
/// modes, for the same reason as [kCardSurfaceGradient].
LinearGradient get kBackgroundGradient => const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFF10121A), Color(0xFF08090D)],
    );

/// Spacing scale (guide §8), dp.
const double kSpace4 = 4;
const double kSpace8 = 8;
const double kSpace12 = 12;
const double kSpace16 = 16;
const double kSpace20 = 20;
const double kSpace24 = 24;
const double kSpace32 = 32;

/// Corner radii (guide §8), dp.
const double kRadiusChip = 12;
const double kRadiusInput = 14;
const double kRadiusCard = 18;
const double kRadiusHero = 22;

/// Text styles (guide §4). Getters so the colours follow the
/// light/dark switch via kText / kMuted / kTextMuted.
TextStyle get kStyleTitle => TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: kText);
TextStyle get kStyleSection => TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: kText);
TextStyle get kStyleCardTitle => TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: kText);
TextStyle get kStyleBody => TextStyle(fontSize: 15, fontWeight: FontWeight.normal, color: kText);
TextStyle get kStyleMeta => TextStyle(fontSize: 13, fontWeight: FontWeight.normal, color: kMuted);
TextStyle get kStyleLabel => TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: kTextMuted);

/// MOCKUP CARD (FIX 23 item 23, ChatGPT design, user order
/// 2026-11-23) — the shared section-card look: diagonal purple
/// gradient fill (semi-transparent, frosted glass over the
/// background image) + purple border + purple glow. This
/// SUPERSEDES the 2026-11-20 two-shine-lines look: the rotating
/// gold shines and the in-card fire sparks are GONE from cards —
/// the purple border + glow replaces that whole treatment. The
/// shared paintFireSparks effect still serves the splash screen
/// and the profile card (see [FireSparks]); only MockupCard
/// stopped painting sparks. No animation, no ticker — the card is
/// a StatelessWidget now, which also removes the per-card
/// AnimationController cost (a win on old phones; the blur itself
/// still needs a phone test — see the fix23 report).
///
/// The [animate] and [sparks] parameters are kept for call-site
/// compatibility (257 call sites) and ignored. In light mode the
/// card falls back to a plain white card with a light border
/// (unchanged — item 23 restyles the dark theme only).
class MockupCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  /// Deprecated no-op (FIX 23 item 23): the shines are gone, so
  /// there is nothing to animate. Kept so existing call sites
  /// compile unchanged.
  final bool animate;
  /// Deprecated no-op (FIX 23 item 23): in-card sparks are gone.
  /// Kept for call-site compatibility.
  final bool sparks;
  const MockupCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.radius = 22, this.animate = true, this.sparks = true});

  @override
  Widget build(BuildContext context) {
    if (appLightMode) {
      return Container(
        padding: padding,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(radius), border: Border.all(color: const Color(0xFFE2E8F0))),
        child: child,
      );
    }
    // Layered: the purple border + glow live on the OUTER container
    // (unclipped — a ClipRRect would cut the shadow off), the
    // frosted fill lives inside the clip (BackdropFilter blurs the
    // background image behind the card; the semi-transparent
    // gradient lets it show through faintly). RepaintBoundary
    // bounds the blur's repaint cost.
    return RepaintBoundary(
      child: Container(
        decoration: cardFrameDecoration(radius: radius),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: kCardBlurSigma, sigmaY: kCardBlurSigma),
            child: Container(
              padding: padding,
              decoration: cardFillDecoration(radius: radius),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}


/// FIRE SPARKS (Fix 22 + Fix 23, 2026-11-21) — the ONE shared ember
/// effect, used by the splash screen, the profile card and every
/// MockupCard. Real fire sparks, like the splash screenshot: each
/// spark is an elongated tapered STREAK (pointed tip, wider belly,
/// rounded base), slightly tilted, some small some thick, in
/// #FDC903 with a warm orange tail tint — NEVER round dots and
/// NEVER round glow blobs. They rise upward and fade out near the
/// top, like embers off a fire.
///
/// Seeds are deterministic per index (golden-ratio spread — no
/// Random), so the pattern is stable across frames and devices.
/// Solid fills only, no shaders: 2 small paths per spark, so the
/// cost per card per frame is negligible next to the shine stroke.
/// `t` is the 0..1 loop phase; each spark has its own speed and
/// phase offset, so they never march in lockstep.
void paintFireSparks(Canvas canvas, Size size, double t, int count) {
  final w = size.width;
  final h = size.height;
  if (w <= 0 || h <= 0 || count <= 0) return;
  for (var i = 0; i < count; i++) {
    final xFrac = 0.06 + 0.88 * ((i * 0.6180339887) % 1.0);
    final speed = 0.7 + ((i * 0.37) % 1.0) * 0.6;
    final phase = (i * 0.29) % 1.0;
    final len = 7.0 + ((i * 0.53) % 1.0) * 9.0;
    final wid = 1.2 + ((i * 0.41) % 1.0) * 1.6;
    final tilt = (((i * 0.71) % 1.0) - 0.5) * 0.5;
    final warm = (i * 0.83) % 1.0;
    final p = (t * speed + phase) % 1.0;
    final x = xFrac * w;
    final y = (1.0 - p) * (h + 24) - 12;
    // Fade in at the bottom, fade out near the top.
    final alpha = (p < 0.12 ? p / 0.12 : (p > 0.75 ? (1.0 - p) / 0.25 : 1.0)) * 0.85;
    if (alpha <= 0.02) continue;
    // Warm tail tint: some sparks lean orange (fire needs the warm
    // gradient — the orange 0xFFF97316 was deliberately kept in the
    // Fix 4 palette pass for exactly this).
    final color = Color.lerp(kGold, const Color(0xFFF97316), warm * 0.7)!;
    canvas.save();
    canvas.translate(x, y);
    canvas.rotate(tilt);
    // Tapered streak: pointed tip, wider belly, rounded base — a
    // flame sliver, never a round dot.
    final streak = Path()
      ..moveTo(0, -len / 2)
      ..quadraticBezierTo(wid / 2, -len * 0.1, wid * 0.42, len * 0.22)
      ..quadraticBezierTo(wid * 0.3, len / 2, 0, len / 2)
      ..quadraticBezierTo(-wid * 0.3, len / 2, -wid * 0.42, len * 0.22)
      ..quadraticBezierTo(-wid / 2, -len * 0.1, 0, -len / 2)
      ..close();
    canvas.drawPath(streak, Paint()..color = color.withValues(alpha: alpha)..isAntiAlias = true);
    // Brighter core sliver (smaller, same shape) — the hot heart.
    final core = Path()
      ..moveTo(0, -len * 0.32)
      ..quadraticBezierTo(wid * 0.22, -len * 0.05, wid * 0.18, len * 0.16)
      ..quadraticBezierTo(wid * 0.12, len * 0.32, 0, len * 0.32)
      ..quadraticBezierTo(-wid * 0.12, len * 0.32, -wid * 0.18, len * 0.16)
      ..quadraticBezierTo(-wid * 0.22, -len * 0.05, 0, -len * 0.32)
      ..close();
    canvas.drawPath(core, Paint()..color = Color.lerp(kGold, Colors.white, 0.55)!.withValues(alpha: alpha)..isAntiAlias = true);
    canvas.restore();
  }
}

class _FireSparksPainter extends CustomPainter {
  final double t;
  final int count;
  const _FireSparksPainter({required this.t, this.count = 6});
  @override
  void paint(Canvas canvas, Size size) => paintFireSparks(canvas, size, t, count);
  @override
  bool shouldRepaint(covariant _FireSparksPainter old) => old.t != t || old.count != count;
}

/// Animated fire-spark layer with its own controller (6 s loop) —
/// for surfaces that are NOT a MockupCard: the splash / gate
/// screens (Fix 22, dense) and the profile card (Fix 23, which is
/// a custom Container, not a MockupCard). MockupCards no longer
/// paint sparks at all (FIX 23 item 23 — the purple border + glow
/// replaced the shines/sparks treatment). Size
/// comes from the parent (use inside Positioned.fill); taps pass
/// through only if the call site wraps it in IgnorePointer.
class FireSparks extends StatefulWidget {
  final int count;
  const FireSparks({super.key, this.count = 6});
  @override
  State<FireSparks> createState() => _FireSparksState();
}

class _FireSparksState extends State<FireSparks> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 6000))..repeat();
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
        builder: (context, _) => CustomPaint(painter: _FireSparksPainter(t: _ctrl.value, count: widget.count)),
      ),
    );
  }
}
