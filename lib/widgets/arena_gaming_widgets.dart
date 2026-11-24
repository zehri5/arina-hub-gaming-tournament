import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/arena_theme.dart';

enum ArenaFrameVariant { blue, purple, google, error }

Path buildChamferPath(Size size, {double cut = 13, double inset = 0}) {
  final left = inset;
  final top = inset;
  final right = (size.width - inset).clamp(left + 4, double.infinity);
  final bottom = (size.height - inset).clamp(top + 4, double.infinity);
  final c = cut.clamp(0.0, (bottom - top) * 0.42);

  return Path()
    ..moveTo(left + c, top)
    ..lineTo(right - c, top)
    ..lineTo(right, top + c)
    ..lineTo(right, bottom - c)
    ..lineTo(right - c, bottom)
    ..lineTo(left + c, bottom)
    ..lineTo(left, bottom - c)
    ..lineTo(left, top + c)
    ..close();
}

class ChamferClipper extends CustomClipper<Path> {
  final double cut;
  ChamferClipper({this.cut = 13});

  @override
  Path getClip(Size size) => buildChamferPath(size, cut: cut);

  @override
  bool shouldReclip(covariant ChamferClipper oldClipper) => oldClipper.cut != cut;
}

class ChamferNeonBorderPainter extends CustomPainter {
  final ArenaFrameVariant variant;
  final double cut;
  final bool focused;

  ChamferNeonBorderPainter({
    required this.variant,
    this.cut = 13,
    this.focused = false,
  });

  List<Color> get _gradientColors {
    switch (variant) {
      case ArenaFrameVariant.blue:
        return [ArenaTheme.cyanNeon, ArenaTheme.electricBlue, ArenaTheme.purpleNeon];
      case ArenaFrameVariant.purple:
        return [ArenaTheme.magentaNeon, const Color(0xFF7C3AED), const Color(0xFF2563EB)];
      case ArenaFrameVariant.google:
        return [const Color(0xFFFFB800), const Color(0xFF8B5CF6), ArenaTheme.cyanNeon];
      case ArenaFrameVariant.error:
        return [const Color(0xFFFB7185), const Color(0xFFEF4444), const Color(0xFFF97316)];
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = buildChamferPath(size, cut: cut, inset: 1.2);
    final shader = LinearGradient(colors: _gradientColors).createShader(rect);

    // Outer neon glow
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = focused ? 4.5 : 3.2
      ..strokeJoin = StrokeJoin.round
      ..shader = shader
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.5);
    canvas.drawPath(path, glowPaint);

    // Crisp neon stroke
    final strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = focused ? 2.1 : 1.65
      ..strokeJoin = StrokeJoin.round
      ..shader = shader;
    canvas.drawPath(path, strokePaint);

    // Top/Bottom specular neon bar accent
    if (variant == ArenaFrameVariant.blue) {
      final accent = Paint()
        ..color = const Color(0xFF7DD3FC)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(cut + 10, 1.4),
        Offset((cut + 74).clamp(cut + 12, size.width - cut - 10), 1.4),
        accent,
      );
    } else if (variant == ArenaFrameVariant.purple) {
      final accent = Paint()
        ..color = const Color(0xFFF0ABFC)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(cut + 10, size.height - 1.4),
        Offset((cut + 80).clamp(cut + 12, size.width - cut - 10), size.height - 1.4),
        accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ChamferNeonBorderPainter oldDelegate) =>
      oldDelegate.variant != variant || oldDelegate.focused != focused || oldDelegate.cut != cut;
}

class HexIconBadge extends StatelessWidget {
  final IconData icon;
  final bool isPurple;

  const HexIconBadge({
    super.key,
    required this.icon,
    this.isPurple = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: CustomPaint(
        painter: _HexPainter(isPurple: isPurple),
        child: Center(
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      ),
    );
  }
}

class _HexPainter extends CustomPainter {
  final bool isPurple;
  _HexPainter({required this.isPurple});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.50, h * 0.04)
      ..lineTo(w * 0.92, h * 0.27)
      ..lineTo(w * 0.92, h * 0.73)
      ..lineTo(w * 0.50, h * 0.96)
      ..lineTo(w * 0.08, h * 0.73)
      ..lineTo(w * 0.08, h * 0.27)
      ..close();

    final rect = Offset.zero & size;
    final colors = isPurple
        ? [const Color(0xFFE879F9), const Color(0xFF6366F1)]
        : [ArenaTheme.cyanNeon, const Color(0xFF6366F1)];

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..color = const Color(0xEB0C112B),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeJoin = StrokeJoin.round
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _HexPainter oldDelegate) => oldDelegate.isPurple != isPurple;
}

class ArenaGamingTextField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final IconData icon;
  final ArenaFrameVariant variant;
  final bool isPassword;
  final bool showDividerBar;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final String? errorText;
  final ValueChanged<String>? onChanged;

  const ArenaGamingTextField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.icon,
    this.variant = ArenaFrameVariant.blue,
    this.isPassword = false,
    this.showDividerBar = false,
    this.keyboardType = TextInputType.text,
    this.textInputAction = TextInputAction.next,
    this.errorText,
    this.onChanged,
  });

  @override
  State<ArenaGamingTextField> createState() => _ArenaGamingTextFieldState();
}

class _ArenaGamingTextFieldState extends State<ArenaGamingTextField> {
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;
  bool _obscureText = true;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (mounted) setState(() => _focused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;
    final activeVariant = hasError ? ArenaFrameVariant.error : widget.variant;
    final isPurple = widget.variant == ArenaFrameVariant.purple;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 55,
          child: CustomPaint(
            foregroundPainter: ChamferNeonBorderPainter(
              variant: activeVariant,
              cut: 13,
              focused: _focused,
            ),
            child: ClipPath(
              clipper: ChamferClipper(cut: 13),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  color: ArenaTheme.glassFill,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      HexIconBadge(icon: widget.icon, isPurple: isPurple),
                      if (widget.showDividerBar) ...[
                        const SizedBox(width: 10),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 2,
                          height: 20,
                          decoration: BoxDecoration(
                            color: _focused ? ArenaTheme.cyanNeon : ArenaTheme.magentaNeon,
                            borderRadius: BorderRadius.circular(2),
                            boxShadow: _focused
                                ? const [BoxShadow(color: ArenaTheme.cyanNeon, blurRadius: 6)]
                                : null,
                          ),
                        ),
                      ],
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: widget.controller,
                          focusNode: _focusNode,
                          obscureText: widget.isPassword && _obscureText,
                          keyboardType: widget.keyboardType,
                          textInputAction: widget.textInputAction,
                          onChanged: widget.onChanged,
                          style: ArenaTheme.bodyStyle(fontSize: 15, color: Colors.white),
                          cursorColor: ArenaTheme.cyanNeon,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            isCollapsed: true,
                            hintText: widget.hintText,
                            hintStyle: ArenaTheme.bodyStyle(
                              fontSize: 15,
                              color: ArenaTheme.hintColor,
                            ),
                          ),
                        ),
                      ),
                      if (widget.isPassword)
                        IconButton(
                          onPressed: () => setState(() => _obscureText = !_obscureText),
                          splashRadius: 20,
                          icon: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xE6101538),
                              border: Border.all(
                                color: const Color(0x66818CF8),
                                width: 1.2,
                              ),
                            ),
                            child: Icon(
                              _obscureText ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                              color: const Color(0xFFE2E8F0),
                              size: 16,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 6),
            child: Row(
              children: [
                const Icon(Icons.error_outline, size: 14, color: ArenaTheme.errorRed),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.errorText!,
                    style: ArenaTheme.bodyStyle(
                      fontSize: 12,
                      color: const Color(0xFFFDA4AF),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class ArenaGoldenButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  const ArenaGoldenButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  @override
  State<ArenaGoldenButton> createState() => _ArenaGoldenButtonState();
}

class _ArenaGoldenButtonState extends State<ArenaGoldenButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.loading ? null : widget.onPressed,
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: Container(
          height: 55,
          decoration: const BoxDecoration(
            boxShadow: [
              BoxShadow(
                color: Color(0x8CFFBF00),
                blurRadius: 18,
                spreadRadius: 1,
              ),
              BoxShadow(
                color: Color(0x55A855F7),
                blurRadius: 24,
                spreadRadius: 2,
              ),
            ],
          ),
          child: CustomPaint(
            foregroundPainter: _GoldenButtonRimPainter(),
            child: ClipPath(
              clipper: ChamferClipper(cut: 15),
              child: Stack(
                children: [
                  // Main bright gold gradient
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFFF37A), Color(0xFFFFD029), ArenaTheme.goldOrange],
                      ),
                    ),
                  ),
                  // Diagonal dark bronze/obsidian left wing
                  Positioned.fill(
                    child: CustomPaint(painter: _LeftWingFacetPainter()),
                  ),
                  // Content row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const SizedBox(
                          width: 34,
                          child: Icon(
                            Icons.double_arrow_rounded,
                            color: Color(0xFFFCD34D),
                            size: 24,
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: widget.loading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.6,
                                      valueColor: AlwaysStoppedAnimation(Color(0xFF0B0C14)),
                                    ),
                                  )
                                : Text(
                                    widget.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ArenaTheme.displayStyle(
                                      fontSize: 24,
                                      color: const Color(0xFF0B0C14),
                                      letterSpacing: 1.0,
                                    ),
                                  ),
                          ),
                        ),
                        Container(
                          width: 32,
                          height: 32,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF0C0E17),
                          ),
                          child: const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFFFBBF24),
                            size: 22,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LeftWingFacetPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width * 0.26, 0)
      ..lineTo(size.width * 0.19, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xEB17120A), Color(0xD92E210A), Color(0xB84A320C)],
        ).createShader(Rect.fromLTWH(0, 0, size.width * 0.26, size.height)),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _GoldenButtonRimPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = buildChamferPath(size, cut: 15, inset: 1.0);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeJoin = StrokeJoin.round
        ..shader = const LinearGradient(
          colors: [Color(0xFFFFFDE7), Color(0xFFFFD54F), Color(0xFFFFF8E1)],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class ArenaOrDivider extends StatelessWidget {
  const ArenaOrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 1,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, Color(0x80A855F7), Color(0xCCFCD34D)],
              ),
            ),
          ),
        ),
        _glowDot(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'OR',
            style: ArenaTheme.displayStyle(fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 2),
          ),
        ),
        _glowDot(),
        Expanded(
          child: Container(
            height: 1,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xCCFCD34D), Color(0x80A855F7), Colors.transparent],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _glowDot() => Container(
        width: 5,
        height: 5,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFFCD34D),
          boxShadow: [BoxShadow(color: Color(0xFFFCD34D), blurRadius: 8)],
        ),
      );
}

class ArenaGoogleButton extends StatelessWidget {
  final VoidCallback? onPressed;
  const ArenaGoogleButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 50,
      child: CustomPaint(
        foregroundPainter: ChamferNeonBorderPainter(
          variant: ArenaFrameVariant.google,
          cut: 14,
        ),
        child: ClipPath(
          clipper: ChamferClipper(cut: 14),
          child: Material(
            color: const Color(0xD1080B20),
            child: InkWell(
              onTap: onPressed,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CustomPaint(painter: _GoogleLogoPainter()),
                    ),
                    Text(
                      'Continue with Google',
                      style: ArenaTheme.bodyStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 22),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.45;
    final stroke = size.width * 0.19;
    final rect = Rect.fromCircle(center: center, radius: radius);

    Paint arcPaint(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    canvas.drawArc(rect, -0.55, 1.45, false, arcPaint(const Color(0xFF4285F4)));
    canvas.drawArc(rect, 0.90, 1.25, false, arcPaint(const Color(0xFF34A853)));
    canvas.drawArc(rect, 2.15, 1.40, false, arcPaint(const Color(0xFFFBBC05)));
    canvas.drawArc(rect, 3.55, 1.95, false, arcPaint(const Color(0xFFEA4335)));

    canvas.drawLine(
      Offset(center.dx, center.dy),
      Offset(center.dx + radius + stroke * 0.35, center.dy),
      Paint()
        ..color = const Color(0xFF4285F4)
        ..strokeWidth = stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}