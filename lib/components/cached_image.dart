import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Wave 4 item B — FAST IMAGE LOADING (shared foundation).
///
/// Every remote image in the user app goes through this file so ImgBB
/// images are disk-cached (no bare re-download on every screen open),
/// show a gold-tinted placeholder while loading, and degrade to the
/// SAME flat gold-trophy fallback on error instead of crashing or
/// going blank. Slow network is the users' NORMAL condition —
/// cached-first rendering everywhere.
///
/// Two widgets, one cache (`CachedNetworkImage` / flutter_cache_manager):
///   [ArenaCachedImage]  — rectangular image (chat photos, covers, banners).
///   [ArenaCachedAvatar] — circular photo avatar with an initial-letter
///                         fallback (dead URL -> initial, never blank).
///
/// Screens must NOT use bare `NetworkImage` / `Image.network` for
/// remote images any more — use one of these two, or (inside a
/// `DecorationImage` / `CircleAvatar.backgroundImage`, where only an
/// `ImageProvider` fits) `CachedNetworkImageProvider` from the same
/// package, which shares the same disk cache.

/// Rectangular disk-cached remote image.
///
/// Placeholder: flat #0A0D14 card with a gold trophy icon.
/// Error: IDENTICAL to the placeholder — flat #0A0D14 + gold trophy,
/// no broken-image icon, no 'Image unavailable' text. (F-glow-cache-fix1:
/// the old error box covered the whole Home header on the user's phone.)
class ArenaCachedImage extends StatelessWidget {
  const ArenaCachedImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.placeholderIcon = Icons.emoji_events,
  });

  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// Rounded corners of the image itself. Defaults to square corners
  /// (callers that already clip, e.g. the chat-photo ClipRRect, may
  /// pass the same radius so the placeholder/error fill matches).
  final BorderRadius? borderRadius;

  /// Gold icon shown while loading (trophy by default; pass
  /// `Icons.sports_esports` for a gamepad).
  final IconData placeholderIcon;

  // Flat #0A0D14 (same as Home's _HomeCoverImage fallback) + gold
  // trophy — loading, error and empty URL all render this identical
  // fallback, never blank, same finite size.
  Widget _placeholder() => Container(
        width: width,
        height: height,
        color: const Color(0xFF0A0D14),
        alignment: Alignment.center,
        child: Icon(placeholderIcon, color: kGold, size: 40),
      );

  Widget _error() => _placeholder();

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.zero;
    if (imageUrl.isEmpty) return ClipRRect(borderRadius: radius, child: _error());
    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: imageUrl,
        width: width,
        height: height,
        fit: fit,
        placeholder: (_, __) => _placeholder(),
        errorWidget: (_, __, ___) => _error(),
      ),
    );
  }
}

/// Circular disk-cached photo avatar (profile photos, seats, member
/// strip, chat avatars).
///
/// Behaviour (matches the old `FramedAvatar` contract):
/// * empty URL -> [fallback] (usually the initial letter) immediately.
/// * loading -> [fallback] (no flash of a different shape).
/// * dead URL -> [fallback]; [onError] fires once, after the frame,
///   so the caller can also flip its own failed flag (as
///   `FramedAvatar._imgFailed` does). Never a blank circle.
class ArenaCachedAvatar extends StatelessWidget {
  const ArenaCachedAvatar({
    super.key,
    required this.photoUrl,
    required this.radius,
    this.backgroundColor = const Color(0xFFFDC903),
    this.fallback,
    this.onError,
  });

  final String photoUrl;
  final double radius;
  final Color backgroundColor;

  /// Shown while loading, on error, and when [photoUrl] is empty —
  /// typically `Text(initial)` in the caller's style.
  final Widget? fallback;

  /// Called (post-frame, once per failure) when the photo fails to
  /// load. Kept separate from the fallback rendering so the caller
  /// can keep its own `_imgFailed` state in sync.
  final VoidCallback? onError;

  Widget _fallbackAvatar() => CircleAvatar(
        radius: radius,
        backgroundColor: backgroundColor,
        child: fallback,
      );

  @override
  Widget build(BuildContext context) {
    if (photoUrl.isEmpty) return _fallbackAvatar();
    return CachedNetworkImage(
      imageUrl: photoUrl,
      imageBuilder: (_, imageProvider) => CircleAvatar(
        radius: radius,
        backgroundColor: backgroundColor,
        backgroundImage: imageProvider,
      ),
      placeholder: (_, __) => _fallbackAvatar(),
      errorWidget: (_, __, ___) {
        if (onError != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => onError!());
        }
        return _fallbackAvatar();
      },
    );
  }
}
