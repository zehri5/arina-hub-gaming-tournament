import 'package:flutter/material.dart';
import '../theme/arena_theme.dart';

/// Angled cyber trapezoid clippers for Voice Seats & Chat header tabs
class LeftCyberNotchClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width - 14, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class RightCyberNotchClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(14, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// 3D Glowing Neon Podium Platform underneath each member avatar
class PodiumDiscPainter extends CustomPainter {
  final Color outerColor;
  final bool active;

  PodiumDiscPainter({required this.outerColor, this.active = false});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.55);

    // Underglow
    final glowPaint = Paint()
      ..color = outerColor.withValues(alpha: active ? 0.45 : 0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawOval(
      Rect.fromCenter(center: center.translate(0, 3), width: size.width * 0.9, height: 18),
      glowPaint,
    );

    // Outer metallic ring
    final basePaint = Paint()..color = const Color(0xFF0D0922);
    final rimPaint = Paint()
      ..color = outerColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    final outerRect =
        Rect.fromCenter(center: center, width: size.width * 0.88, height: 18);
    canvas.drawOval(outerRect, basePaint);
    canvas.drawOval(outerRect, rimPaint);

    // Inner bright ring
    final innerRim = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;
    canvas.drawOval(
      Rect.fromCenter(center: center.translate(0, -1), width: size.width * 0.68, height: 11),
      innerRim,
    );
  }

  @override
  bool shouldRepaint(covariant PodiumDiscPainter oldDelegate) =>
      oldDelegate.outerColor != outerColor || oldDelegate.active != active;
}

/// Golden Cyber Wings flanking the central microphone orb
class MicWingPainter extends CustomPainter {
  final bool flipRight;
  final bool active;

  MicWingPainter({this.flipRight = false, this.active = true});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (flipRight) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }

    final goldGradient = const LinearGradient(
      colors: [Color(0xFFFFF5A8), ArenaColors.royalGold, Color(0xFFC96A00)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    ).createShader(Offset.zero & size);

    final bladePaint = Paint()
      ..shader = goldGradient
      ..style = PaintingStyle.fill;

    // Upper blade
    final p1 = Path()
      ..moveTo(size.width * 0.95, size.height * 0.34)
      ..quadraticBezierTo(size.width * 0.45, size.height * 0.20, size.width * 0.06, size.height * 0.05)
      ..quadraticBezierTo(size.width * 0.25, size.height * 0.30, size.width * 0.68, size.height * 0.42)
      ..close();
    canvas.drawPath(p1, bladePaint);

    // Middle blade
    final p2 = Path()
      ..moveTo(size.width * 0.90, size.height * 0.49)
      ..quadraticBezierTo(size.width * 0.42, size.height * 0.40, size.width * 0.04, size.height * 0.25)
      ..quadraticBezierTo(size.width * 0.26, size.height * 0.48, size.width * 0.66, size.height * 0.58)
      ..close();
    canvas.drawPath(p2, bladePaint);

    // Lower blade
    final p3 = Path()
      ..moveTo(size.width * 0.85, size.height * 0.64)
      ..quadraticBezierTo(size.width * 0.45, size.height * 0.59, size.width * 0.14, size.height * 0.48)
      ..quadraticBezierTo(size.width * 0.32, size.height * 0.67, size.width * 0.70, size.height * 0.73)
      ..close();
    canvas.drawPath(p3, bladePaint);

    // Cyan bottom energy feather
    final cyanPaint = Paint()
      ..color = ArenaColors.electricBlue.withValues(alpha: active ? 0.9 : 0.4);
    final p4 = Path()
      ..moveTo(size.width * 0.78, size.height * 0.78)
      ..quadraticBezierTo(size.width * 0.50, size.height * 0.78, size.width * 0.30, size.height * 0.72)
      ..quadraticBezierTo(size.width * 0.48, size.height * 0.88, size.width * 0.74, size.height * 0.88)
      ..close();
    canvas.drawPath(p4, cyanPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant MicWingPainter oldDelegate) =>
      oldDelegate.active != active || oldDelegate.flipRight != flipRight;
}