import 'package:flutter/material.dart';

import '../utils.dart';
import 'cached_image.dart';

/// WHATSAPP-STYLE CHAT BUBBLE (Sameer 2026-11-21, FIX 8 — "jaise
/// WhatsApp mein hain, bubbles type").
///
/// ONE shared bubble for every chat surface — DM (community),
/// TeamChat (squad/tournament) and the room chat — so the design is
/// consistent everywhere:
///
/// * sender (mine): RIGHT-aligned, gold-tinted bubble (kGold 16% +
///   gold border), tail at the bottom-RIGHT corner.
/// * receiver: LEFT-aligned, card-grey bubble (kCard + kBorder),
///   tail at the bottom-LEFT corner.
/// * timestamp attached INSIDE the bubble, bottom-right, when
///   [timeLabel] is non-empty (callers that already show the time in
///   a header row above the bubble pass '' to avoid duplication).
/// * [senderName] (group chats) renders as a coloured name line at
///   the top of the bubble, WhatsApp-group style.
/// * [header] replaces the [senderName] line with a custom widget
///   when a surface shows pills next to the name (TeamChat's SQUAD
///   pill).
/// * [goldBorder] keeps the bubble's fill but swaps the border to
///   gold with a soft gold glow (TeamChat admin bubbles).
/// * [alignEnd] overrides the side the bubble sits on (default:
///   [isMine]). The room chat passes false: it keeps its avatar-left
///   group layout, so own messages stay left-aligned there and are
///   distinguished by the gold tint alone — the tail follows the
///   side, the fill follows [isMine].
/// * [imageUrl] renders a photo inside the bubble (FIX 4 DM
///   pictures); tap calls [onImageTap] — the caller opens the
///   full-size view via [showChatImageDialog].
/// * [highlight] is the room's shout style (gold fill + gold bold
///   text) — same colours as the old shout container, now in bubble
///   form. Behaviour is unchanged everywhere: this widget only
///   restyles the bubble shell.
class ChatBubble extends StatelessWidget {
  final bool isMine;
  final bool? alignEnd;
  final String text;
  final String imageUrl;
  final String timeLabel;
  final String senderName;
  final Color? senderNameColor;
  final Widget? header;
  final bool goldBorder;
  final bool highlight;
  final VoidCallback? onImageTap;

  const ChatBubble({
    super.key,
    required this.isMine,
    this.alignEnd,
    this.text = '',
    this.imageUrl = '',
    this.timeLabel = '',
    this.senderName = '',
    this.senderNameColor,
    this.header,
    this.goldBorder = false,
    this.highlight = false,
    this.onImageTap,
  });

  @override
  Widget build(BuildContext context) {
    // The SIDE follows alignEnd (default isMine); the FILL follows
    // isMine — so a left-aligned own bubble (room group layout) is
    // still gold-tinted, with its tail on the left like the rest.
    final end = alignEnd ?? isMine;
    final Color fill = highlight
        ? kGold.withValues(alpha: 0.22)
        : isMine
            ? kGold.withValues(alpha: 0.16)
            : kCard;
    final Color border = highlight || goldBorder
        ? kGold
        : isMine
            ? kGold.withValues(alpha: 0.65)
            : kBorder;
    final Color textColor = highlight ? kGold : kText;
    // WhatsApp tail corner: the tail side's bottom corner is nearly
    // square so the tail reads as part of the bubble.
    final radius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(end ? 16 : 4),
      bottomRight: Radius.circular(end ? 4 : 16),
    );
    // Max width is relative to the AVAILABLE width (LayoutBuilder),
    // not the screen: in TeamChat the bubble sits in an Expanded
    // beside an avatar + flag button, where 75% of the screen would
    // overflow. 85% of available ≈ 78% of the screen in a
    // full-width list — the WhatsApp proportion.
    return LayoutBuilder(
      builder: (context, constraints) {
        final avail = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        return Align(
          alignment: end ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: avail * 0.85),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: radius,
                    border: Border.all(color: border, width: highlight || goldBorder ? 1.5 : 1.2),
                    boxShadow: [
                      if (goldBorder)
                        BoxShadow(color: kGold.withValues(alpha: 0.28), blurRadius: 14, spreadRadius: 1)
                      else
                        BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 4, offset: const Offset(0, 1)),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (header != null) ...[
                        header!,
                        const SizedBox(height: 3),
                      ] else if (senderName.isNotEmpty) ...[
                        Text(
                          senderName,
                          style: TextStyle(
                            color: senderNameColor ?? kGold,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                      ],
                      if (imageUrl.isNotEmpty) ...[
                        GestureDetector(
                          onTap: onImageTap,
                          child: ArenaCachedImage(
                            imageUrl: imageUrl,
                            width: 220,
                            height: 160,
                            fit: BoxFit.cover,
                            borderRadius: BorderRadius.circular(10),
                            placeholderIcon: Icons.image,
                          ),
                        ),
                        if (text.isNotEmpty) const SizedBox(height: 6),
                      ],
                      if (text.isNotEmpty)
                        Text(
                          text,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 15,
                            height: 1.4,
                            fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      if (timeLabel.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              timeLabel,
                              style: TextStyle(
                                color: isMine || highlight
                                    ? Colors.white.withValues(alpha: 0.6)
                                    : kMuted,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                // The tail: a small triangle in the bubble's fill
                // colour, overlapping the flattened bottom corner on
                // the sender's side (right for mine, left for
                // others).
                Positioned(
                  bottom: 0,
                  right: end ? -5 : null,
                  left: end ? null : -5,
                  child: IgnorePointer(
                    child: CustomPaint(
                      size: const Size(10, 10),
                      painter: _BubbleTailPainter(color: fill, flip: end),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Small triangle tail for [ChatBubble]: a right triangle whose
/// vertical edge hugs the bubble's flattened corner. [flip] mirrors
/// it for sender (right-side) bubbles.
class _BubbleTailPainter extends CustomPainter {
  final Color color;
  final bool flip;
  const _BubbleTailPainter({required this.color, required this.flip});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (flip) {
      // Right-side tail: triangle pointing down-right.
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(0, size.height)
        ..close();
    } else {
      // Left-side tail: triangle pointing down-left.
      path
        ..moveTo(0, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width, size.height)
        ..close();
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _BubbleTailPainter old) =>
      old.color != color || old.flip != flip;
}

/// Full-size image view for chat pictures (FIX 4, tap-to-view —
/// REQUIRED). A simple dialog with the image large (70% of screen
/// height, contain fit so the whole photo shows), a close button,
/// and tap-outside to dismiss. No new packages: the image renders
/// through the app's shared [ArenaCachedImage] (disk-cached).
Future<void> showChatImageDialog(BuildContext context, String imageUrl) {
  final size = MediaQuery.of(context).size;
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.85),
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 28),
            tooltip: tr('Close', 'Band karein'),
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(height: 4),
          Flexible(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ArenaCachedImage(
                imageUrl: imageUrl,
                width: size.width - 32,
                height: size.height * 0.7,
                fit: BoxFit.contain,
                borderRadius: BorderRadius.circular(12),
                placeholderIcon: Icons.image,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
