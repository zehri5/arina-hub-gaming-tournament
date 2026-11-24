import 'package:flutter/material.dart';

/// Bottom golden loading bar connected to real app initialization progress,
/// paired with the golden parachute emblem divider and moving highlight sweep.
class GoldenLoadingBarDock extends StatelessWidget {
  const GoldenLoadingBarDock({
    super.key,
    required this.dockVisibility,
    required this.progress,
    required this.shimmerProgress,
    required this.statusText,
  });

  final Animation<double> dockVisibility;
  final Animation<double> progress;
  final Animation<double> shimmerProgress;
  final String statusText;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final barWidth = (width * 0.82).clamp(225.0, 340.0);

    return AnimatedBuilder(
      animation: Listenable.merge([dockVisibility, progress, shimmerProgress]),
      builder: (context, _) {
        final fade = dockVisibility.value.clamp(0.0, 1.0);
        if (fade <= 0.005) return const SizedBox.shrink();

        final clampedProgress = progress.value.clamp(0.0, 1.0);
        final pct = (clampedProgress * 100).round();

        return Opacity(
          opacity: fade,
          child: Transform.translate(
            offset: Offset(0, 14 * (1.0 - fade)),
            child: SizedBox(
              width: barWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(child: _GoldenHairline(reverse: false)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: CustomPaint(
                          size: const Size(28, 30),
                          painter: _GoldenParachutePainter(),
                        ),
                      ),
                      const Expanded(child: _GoldenHairline(reverse: true)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          statusText,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                            color: Color(0xFFF8FAFC),
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 8),
                            ],
                          ),
                        ),
                        Text(
                          '$pct%',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            fontFeatures: [FontFeature.tabularFigures()],
                            color: Color(0xFFFDE047),
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 8),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 7),
                  Container(
                    height: 13,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: const Color(0xFF05070F).withValues(alpha: 0.94),
                      border: Border.all(
                        color: const Color(0xFFFBBF24).withValues(alpha: 0.72),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                          blurRadius: 20,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: clampedProgress,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(999),
                                  gradient: const LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0xFFFFFBEB),
                                      Color(0xFFFDE047),
                                      Color(0xFFF59E0B),
                                      Color(0xFFB45309),
                                    ],
                                    stops: [0.0, 0.26, 0.68, 1.0],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFFFBBF24).withValues(alpha: 0.92),
                                      blurRadius: 16,
                                    ),
                                  ],
                                ),
                              ),
                              FractionalTranslation(
                                translation: Offset(-1.2 + shimmerProgress.value * 2.4, 0),
                                child: Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        Colors.transparent,
                                        Colors.white.withValues(alpha: 0.85),
                                        Colors.transparent,
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GoldenHairline extends StatelessWidget {
  const _GoldenHairline({required this.reverse});

  final bool reverse;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1.2,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: reverse ? Alignment.centerRight : Alignment.centerLeft,
          end: reverse ? Alignment.centerLeft : Alignment.centerRight,
          colors: [
            Colors.transparent,
            const Color(0xFFFBBF24).withValues(alpha: 0.85),
          ],
        ),
      ),
    );
  }
}

class _GoldenParachutePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final canopyPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFFBEB), Color(0xFFFDE047), Color(0xFFD97706)],
      ).createShader(Rect.fromLTWH(0, 0, w, h));

    final canopy = Path()
      ..moveTo(w * 0.08, h * 0.36)
      ..cubicTo(w * 0.12, h * 0.05, w * 0.88, h * 0.05, w * 0.92, h * 0.36)
      ..quadraticBezierTo(w * 0.70, h * 0.30, w * 0.50, h * 0.34)
      ..quadraticBezierTo(w * 0.30, h * 0.30, w * 0.08, h * 0.36)
      ..close();
    canvas.drawPath(canopy, canopyPaint);

    final cordPaint = Paint()
      ..color = const Color(0xFFFCD34D)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    canvas.drawLine(Offset(w * 0.14, h * 0.36), Offset(w * 0.46, h * 0.68), cordPaint);
    canvas.drawLine(Offset(w * 0.34, h * 0.33), Offset(w * 0.48, h * 0.68), cordPaint);
    canvas.drawLine(Offset(w * 0.66, h * 0.33), Offset(w * 0.52, h * 0.68), cordPaint);
    canvas.drawLine(Offset(w * 0.86, h * 0.36), Offset(w * 0.54, h * 0.68), cordPaint);

    final figurePaint = Paint()..color = const Color(0xFFFDE047);
    canvas.drawCircle(Offset(w * 0.50, h * 0.72), w * 0.06, figurePaint);
    final body = Path()
      ..moveTo(w * 0.43, h * 0.78)
      ..lineTo(w * 0.57, h * 0.78)
      ..lineTo(w * 0.54, h * 0.90)
      ..lineTo(w * 0.59, h * 0.98)
      ..lineTo(w * 0.52, h * 0.98)
      ..lineTo(w * 0.50, h * 0.90)
      ..lineTo(w * 0.48, h * 0.98)
      ..lineTo(w * 0.41, h * 0.98)
      ..lineTo(w * 0.46, h * 0.90)
      ..close();
    canvas.drawPath(body, figurePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
