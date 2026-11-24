// ARENA HUB — shared redesign components (Phase 2, group F2).
// Implements the 9 contract components in CONTRACT.md exactly
// (names + signatures) per guide §5 (buttons / chips / inputs /
// navigation), §3 (background + glow + shadows) and §9 (motion).
// Cards are NOT here — screens use the existing MockupCard
// (global card rule). GOLD RULE: #FDC903 only.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/supabase_db.dart';
import 'smoke_canvas_painter.dart';
import '../theme.dart';

/// Dark text on gold fills (primary buttons, selected chips).
const Color _darkOnGold = Color(0xFF14161F);

/// Shared button frame: rounded container + Material ripple.
/// [radius] must match the decoration's border radius so the
/// ripple clips to the same shape.
Widget _buttonFrame({
  required BoxDecoration decoration,
  required double radius,
  required VoidCallback? onPressed,
  required Widget child,
}) {
  return Container(
    decoration: decoration,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(radius),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: kSpace20, vertical: 14),
          child: Center(child: child),
        ),
      ),
    ),
  );
}

/// Primary CTA: gold gradient fill, dark text, warm shadow
/// (guide §5 + §3). Disabled (onPressed null) = muted surface +
/// muted text, no shadow, no tap.
class ArenaPrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;
  const ArenaPrimaryButton(
      {super.key, required this.onPressed, required this.child});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return _buttonFrame(
      radius: kRadiusInput,
      onPressed: onPressed,
      decoration: BoxDecoration(
        gradient: enabled ? kGoldGradient : null,
        color: enabled ? null : kSurfaceElevated,
        borderRadius: BorderRadius.circular(kRadiusInput),
        boxShadow: enabled
            ? [
                BoxShadow(
                  color: kGold.withValues(alpha: 0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          color: enabled ? _darkOnGold : kTextMuted,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        child: child,
      ),
    );
  }
}

/// Secondary action: dark surface, thin grey border, white text
/// (guide §5). Disabled = muted surface + muted text, no border.
class ArenaSecondaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;
  const ArenaSecondaryButton(
      {super.key, required this.onPressed, required this.child});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return _buttonFrame(
      radius: kRadiusInput,
      onPressed: onPressed,
      decoration: BoxDecoration(
        color: enabled ? kSurface : kSurfaceElevated,
        borderRadius: BorderRadius.circular(kRadiusInput),
        border: enabled ? Border.all(color: kBorder) : null,
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          color: enabled ? kText : kTextMuted,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        child: child,
      ),
    );
  }
}

/// Card-style action: the item-23 card look (purple gradient, purple
/// border + glow) as a button. FIX 23 item 29 Part C: the auth
/// "Continue with Google" button wears the card look. Disabled
/// (onPressed null) = muted surface + muted text, no border/glow.
class ArenaCardButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;
  const ArenaCardButton(
      {super.key, required this.onPressed, required this.child});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return _buttonFrame(
      radius: 22,
      onPressed: onPressed,
      decoration: enabled
          ? cardDecoration(radius: 22)
          : BoxDecoration(
              color: kSurfaceElevated,
              borderRadius: BorderRadius.circular(22),
            ),
      child: DefaultTextStyle(
        style: TextStyle(
          color: enabled ? kText : kTextMuted,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        child: child,
      ),
    );
  }
}

/// Outlined action: transparent fill, yellow border, yellow text
/// (guide §5). Disabled = muted border + muted text.
class ArenaOutlinedButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;
  const ArenaOutlinedButton(
      {super.key, required this.onPressed, required this.child});

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return _buttonFrame(
      radius: kRadiusInput,
      onPressed: onPressed,
      // PHASE E (E24): secondary buttons are card-styled now —
      // the card fill (shared token) instead of transparent, so
      // they read as cards, not holes in the poster.
      decoration: cardFillDecoration(radius: kRadiusInput).copyWith(
        border: Border.all(
          color: enabled ? kGold : kTextMuted,
          width: 1.5,
        ),
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          color: enabled ? kGold : kTextMuted,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        child: child,
      ),
    );
  }
}

/// Filter chip (guide §5). PHASE E (E24, CORRECTED 2026-11-24):
/// selected is gold-filled (Sameer: "click pe yellow hona
/// chahiye"); the REST are the card fill (shared token) — never
/// black. No yellow/black mix anywhere.
class ArenaFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const ArenaFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: selected
          ? BoxDecoration(
              color: kGold,
              borderRadius: BorderRadius.circular(kRadiusChip),
            )
          : cardFillDecoration(radius: kRadiusChip).copyWith(
              border: Border.all(color: kBorder, width: 1),
            ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(kRadiusChip),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.black : kText,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Red LIVE badge (guide §5).
class ArenaLiveBadge extends StatelessWidget {
  const ArenaLiveBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: kLiveRed,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'LIVE',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Dark filled input (guide §5): subtle border, yellow focus
/// border, red error border + readable error message. Existing
/// validation behaviour is preserved via [validator].
class ArenaTextField extends StatelessWidget {
  final TextEditingController? controller;
  final String? labelText;
  final String? hintText;
  final bool obscureText;
  final Widget? suffixIcon;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final TextInputType? keyboardType;
  final int? maxLines;
  final String? errorText;
  const ArenaTextField({
    super.key,
    this.controller,
    this.labelText,
    this.hintText,
    this.obscureText = false,
    this.suffixIcon,
    this.validator,
    this.onChanged,
    this.keyboardType,
    this.maxLines,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    // FIX 23 item 29: the field wears the card look — the gradient
    // + purple border + glow come from the CardFieldShell (an
    // InputDecoration cannot paint a gradient), so the field itself
    // is borderless and unfilled. Focus turns the shell's border
    // gold, an explicit error turns it red. Behaviour (validator,
    // onChanged, obscure, keyboard) is unchanged. (An error message
    // renders inside the shell, below the input — same text, same
    // colour, just inside the card frame instead of below a border.)
    return CardFieldShell(
      error: errorText != null,
      child: TextFormField(
        controller: controller,
        obscureText: obscureText,
        validator: validator,
        onChanged: onChanged,
        keyboardType: keyboardType,
        // TextField requires maxLines == 1 when obscured.
        maxLines: obscureText ? 1 : maxLines,
        style: TextStyle(color: kText, fontSize: 15),
        decoration: InputDecoration(
          labelText: labelText,
          hintText: hintText,
          errorText: errorText,
          suffixIcon: suffixIcon,
          labelStyle: TextStyle(color: kMuted),
          hintStyle: TextStyle(color: kTextMuted),
          errorStyle: const TextStyle(color: kError),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: kSpace16, vertical: 14),
          border: const OutlineInputBorder(borderSide: BorderSide.none),
          enabledBorder: const OutlineInputBorder(borderSide: BorderSide.none),
          focusedBorder: const OutlineInputBorder(borderSide: BorderSide.none),
          errorBorder: const OutlineInputBorder(borderSide: BorderSide.none),
          focusedErrorBorder: const OutlineInputBorder(borderSide: BorderSide.none),
        ),
      ),
    );
  }
}

/// FIX 23 items 21+22+24 — the app-wide background layer (user orders
/// 2026-11-23). Fallback chain in dark mode: admin remote URL (item 22,
/// when set and loads) -> bundled default artwork
/// [defaultAsset] (item 21, Sameer's final-locked background artwork)
/// -> solid dark colour. A dark scrim sits over the image so text stays
/// legible on the busy artwork; the artwork itself is never altered.
/// Light mode keeps the plain light scaffold colour (the artwork is dark
/// and only replaces the DARK background) unless [respectLightMode] is
/// false — surfaces that are dark in both modes (voice room, community
/// detail) pass false. Must be a direct child of a Stack (it is a
/// Positioned.fill). Blue+purple smoke (item 24) + gold ember sparks
/// (items 24+27) animate above the image, below all content.
///
/// Remote fallback: the remote Image has an errorBuilder (fires if the
/// provider errors), AND a precache-with-timeout check (fires when the
/// load stalls silently — flutter_cache_manager swallows download errors
/// instead of emitting them, so the errorBuilder alone never fires for
/// a bad URL; verified in widget tests). Either path shows the bundled
/// default — never a broken or blank background.
class AppBackgroundLayer extends StatefulWidget {
  /// Bundled default background (FIX 23 item 21 — FINAL-LOCKED
  /// ChatGPT design 2026-11-23 23:35: no PUBG text, no crown;
  /// supersedes both the original PNG and the cleaned webp).
  static const String defaultAsset =
      'assets/images/app_background.png';

  /// Dark scrim over the image, so text stays legible. One constant
  /// so the strength is tunable in one place. Phase E (E3): 0.55
  /// -> 0.35 — the 0.55 black sat over an already-dark poster and
  /// dimmed it to near-black on Sameer's v2023 phone.
  static const double scrimOpacity = 0.35;

  /// Phase E (E1): precache the bundled background asset so it is
  /// in the image cache BEFORE Home builds — the first paint after
  /// the splash must show the poster, not the near-black base.
  /// One-shot per app lifetime (the splash gate calls it during
  /// its ~4.5s cinematic; this layer calls it again on mount as a
  /// backstop — the guard makes the second call a no-op).
  static bool _defaultPrecached = false;

  static void precacheDefaultBackground(BuildContext context) {
    if (_defaultPrecached) return;
    _defaultPrecached = true;
    // Fire-and-forget: a missing asset must never crash startup.
    precacheImage(const AssetImage(defaultAsset), context)
        .then((_) {}, onError: (_) {});
  }

  /// FIX 23 items 24+27 — ember sparks app-wide (gold FireSparks
  /// rising over the background image, together with the smoke).
  /// One-line kill switch: false removes the sparks app-wide (the
  /// smoke has its own switch on [SmokeLayer]).
  static const bool sparksEnabled = true;

  /// App-wide spark density — subtle (gate screens use 28).
  static const int sparkCount = 12;

  /// How long a remote background gets to load before the bundled
  /// default takes over.
  static const Duration remoteTimeout = Duration(seconds: 8);

  final bool respectLightMode;
  const AppBackgroundLayer({super.key, this.respectLightMode = true});

  @override
  State<AppBackgroundLayer> createState() => _AppBackgroundLayerState();
}

class _AppBackgroundLayerState extends State<AppBackgroundLayer> {
  String _url = SupaDb.appBackgroundUrl.value;
  String _attemptedUrl = '';
  bool _remoteFailed = false;
  // Own the timeout Timer (instead of Future.timeout) so dispose
  // can cancel it — a pending timer at widget disposal fails widget
  // tests, and the precache Future may never settle when the cache
  // manager swallows a download error.
  Timer? _remoteTimer;
  bool _remoteSettled = false;

  @override
  void initState() {
    super.initState();
    SupaDb.appBackgroundUrl.addListener(_onUrlChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Phase E (E1 backstop): the bundled asset is precached at the
    // splash gate; this mount-time call covers any path that
    // reaches the layer without the gate (the helper is one-shot,
    // so the normal path pays nothing here).
    AppBackgroundLayer.precacheDefaultBackground(context);
    _maybeAttempt(_url);
  }

  @override
  void dispose() {
    _remoteTimer?.cancel();
    SupaDb.appBackgroundUrl.removeListener(_onUrlChanged);
    super.dispose();
  }

  void _onUrlChanged() {
    final url = SupaDb.appBackgroundUrl.value;
    if (url == _url) return;
    setState(() {
      _url = url;
      _remoteFailed = false;
    });
    _maybeAttempt(url);
  }

  /// Proves the remote URL actually loads (precache + timeout).
  /// A stalled/failed load flips [_remoteFailed] so the bundled
  /// default shows instead. Runs once per URL.
  void _maybeAttempt(String url) {
    if (url.isEmpty || url == _attemptedUrl) return;
    if (widget.respectLightMode && appLightMode) return;
    _attemptedUrl = url;
    _remoteSettled = false;
    _remoteTimer?.cancel();
    _remoteTimer = Timer(AppBackgroundLayer.remoteTimeout, () {
      if (!mounted || _remoteSettled) return;
      _remoteSettled = true;
      if (_attemptedUrl == url) {
        setState(() => _remoteFailed = true);
      }
    });
    precacheImage(CachedNetworkImageProvider(url), context).then(
      (_) {
        _remoteSettled = true;
        _remoteTimer?.cancel();
      },
      onError: (_, __) {
        _remoteSettled = true;
        _remoteTimer?.cancel();
        if (mounted && _attemptedUrl == url) {
          setState(() => _remoteFailed = true);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.respectLightMode && appLightMode) {
      return Positioned.fill(child: Container(color: kBg));
    }
    final remoteUrl = _url;
    final showRemote = remoteUrl.isNotEmpty && !_remoteFailed;
    return Positioned.fill(
      child: Stack(
        children: [
          // Base: shows only if the image fails to load — never a
          // blank/broken background.
          Container(color: const Color(0xFF070A10)),
          if (showRemote)
            Image(
              image: CachedNetworkImageProvider(remoteUrl),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              // Remote failed/unreachable -> bundled default.
              errorBuilder: (_, __, ___) => const _DefaultBackgroundImage(),
            )
          else
            const _DefaultBackgroundImage(),
          Container(
            key: const ValueKey('app_bg_scrim'),
            color: Colors.black
                .withValues(alpha: AppBackgroundLayer.scrimOpacity),
          ),
          // FIX 23 item 24 — blue+purple smoke above the scrim,
          // below all content (the layer itself is the bottom of
          // every screen's Stack).
          const SmokeLayer(),
          // FIX 23 items 24+27 — gold ember sparks above the
          // smoke, still below all content. Same shared effect
          // as the splash + gate screens (no new particle
          // system).
          if (AppBackgroundLayer.sparksEnabled)
            const Positioned.fill(
              child: IgnorePointer(
                  child: FireSparks(count: AppBackgroundLayer.sparkCount)),
            ),
        ],
      ),
    );
  }
}

/// FIX 23 item 24 — blue + purple smoke (Sameer 2026-11-23 23:47:
/// "Lagao phir, agar nahi pasand aaye to hata denge baad mein").
/// The ONE place smoke lives: it sits inside [AppBackgroundLayer],
/// above the background image + scrim and below all content, so
/// cards and text are never covered by it.
///
/// PHASE E (E26+E27, 2026-11-24): the smoke is PROCEDURAL now —
/// [SmokeBackgroundPainter] draws domain-warped FBM smoke sprites
/// (the same [ProceduralSmokeTextures] as the splash), slow and
/// soft, with no hard edge anywhere. The old 1920x1080 landscape
/// Lottie is GONE from the render path: its fog came from FINITE
/// matte blobs (7 shapes per band), and BoxFit.cover on a
/// portrait phone cropped to the middle ~25% slice, so a matte's
/// edge landed mid-screen as a visible SEAM line and dense
/// overlaps read as foggy patches (Sameer's 06:50 screenshot).
/// The procedural layer has no crop and no loop — positions are
/// normalized, the motion is continuous in time, and every cloud
/// fades in/out at its travel ends — so the seam cannot occur.
///
/// The original Lottie asset (free "Fog / Smoke" by Ladon
/// Sklyarov, LottieFiles, Lottie Simple License — commercial use
/// allowed, attribution not required) stays bundled + declared
/// in pubspec as the license trail; source + license notes:
/// `~/workspace/arena-hub-background/smoke-lottie/README.md`.
///
/// Removal is one line: set [enabled] to false.
///
/// Battery: repaints at ~15 fps via a timer (smoke is slow —
/// 15 fps looks identical to 60), pauses when the app is
/// backgrounded, one RepaintBoundary. The 5 FBM textures are
/// generated ONCE per app launch (shared static future) and
/// reused by every SmokeLayer instance.
class SmokeLayer extends StatefulWidget {
  /// One-line kill switch — false removes the smoke app-wide.
  static const bool enabled = true;

  /// Smoke opacity — 0.20 sits in Sameer's 15–25% band.
  static const double smokeOpacity = 0.20;

  /// The original Lottie source (kept bundled as the license
  /// trail — the layer renders procedural smoke since E27, not
  /// this asset).
  static const String asset = 'assets/lottie/smoke_blue_purple.json';

  const SmokeLayer({super.key});

  @override
  State<SmokeLayer> createState() => _SmokeLayerState();
}

class _SmokeLayerState extends State<SmokeLayer>
    with WidgetsBindingObserver {
  // One generation per app launch, shared by every instance.
  static Future<ProceduralSmokeTextures>? _texturesFuture;
  static ProceduralSmokeTextures? _textures;

  // ~15 fps: smoke drifts slowly, 15 fps looks identical to 60
  // and costs a third of the repaints the old 30 fps Lottie did.
  static const _tick = Duration(milliseconds: 66);

  Timer? _timer;
  double _elapsed = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _texturesFuture ??= ProceduralSmokeTextures.generate();
    _texturesFuture!.then((tex) {
      _textures = tex;
      if (mounted) setState(() {});
    });
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      setState(() => _elapsed += _tick.inMilliseconds / 1000.0);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause the smoke when the app is hidden/backgrounded; resume
    // when it comes back (battery — never animate in background).
    if (state == AppLifecycleState.resumed) {
      _startTimer();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!SmokeLayer.enabled) return const SizedBox.shrink();
    return Positioned.fill(
      child: RepaintBoundary(
        child: Opacity(
          opacity: SmokeLayer.smokeOpacity,
          child: CustomPaint(
            painter: SmokeBackgroundPainter(
              textures: _textures,
              elapsedSeconds: _elapsed,
            ),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

/// The bundled default artwork (FIX 23 item 21), full-bleed. Invisible
/// on error (the dark base behind shows) — never a broken-image box.
class _DefaultBackgroundImage extends StatelessWidget {
  const _DefaultBackgroundImage();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      AppBackgroundLayer.defaultAsset,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}

/// Screen background (guide §3): deep black gradient; when
/// [showGoldenGlow] is true a subtle radial golden light sits
/// behind the content (decorative layer only — never over text).
class ArenaBackground extends StatelessWidget {
  final Widget child;
  final bool showGoldenGlow;
  const ArenaBackground({
    super.key,
    required this.child,
    this.showGoldenGlow = false,
  });

  @override
  Widget build(BuildContext context) {
    // FIX 23 items 21+22: the app-wide background image (admin remote
    // URL when set, else the bundled default artwork) sits behind the
    // content; the golden glow stays on top of it. The old flat dark
    // gradient is gone — the layer's dark base covers the
    // image-failed case.
    return Stack(
      children: [
        const AppBackgroundLayer(),
        if (showGoldenGlow)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.topCenter,
                    radius: 1.4,
                    colors: [
                      kGold.withValues(alpha: 0.12),
                      kGold.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        child,
      ],
    );
  }
}

/// Subtle scale/opacity press feedback (guide §9). Respects
/// reduced-motion settings: with animations disabled the child
/// renders at full scale/opacity with no press animation.
class ArenaPressable extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const ArenaPressable({super.key, required this.child, required this.onTap});

  @override
  State<ArenaPressable> createState() => _ArenaPressableState();
}

class _ArenaPressableState extends State<ArenaPressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final active = _pressed && !reduceMotion;
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: AnimatedScale(
        scale: active ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedOpacity(
          opacity: active ? 0.85 : 1.0,
          duration: const Duration(milliseconds: 120),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Loading indicator in the app gold (guide §9).
class ArenaLoadingIndicator extends StatelessWidget {
  const ArenaLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return CircularProgressIndicator(color: kGold);
  }
}
