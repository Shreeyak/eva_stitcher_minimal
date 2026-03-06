import 'package:flutter/material.dart';
import '../app_theme.dart';

/// Small thumbnail map shown in the top-right corner.
/// Shows a downscaled view of the stitched canvas (mock grid for now)
/// with an orange rectangle representing the current camera viewport.
class MiniMap extends StatelessWidget {
  final int frameCount;

  // Viewport rect as a fraction of the total canvas [0..1]
  final Rect viewportFraction;

  const MiniMap({
    super.key,
    this.frameCount = 0,
    this.viewportFraction = const Rect.fromLTWH(0.3, 0.3, 0.4, 0.4),
  });

  static const double _kWidth = 190.0;
  static const double _kHeight = 130.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _kWidth,
      height: _kHeight,
      decoration: BoxDecoration(
        color: kBgColor,
        border: Border.all(color: kAccent, width: 1.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Stack(
          children: [
            // Grid background
            CustomPaint(
              painter: _MiniMapPainter(viewportFraction: viewportFraction),
              child: const SizedBox.expand(),
            ),

            // Top label
            Positioned(
              top: 4,
              left: 6,
              child: Text(
                'MOSAIC PREVIEW',
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w600,
                  color: kAccent,
                  letterSpacing: 1.4,
                ),
              ),
            ),

            // Frame count badge
            Positioned(
              bottom: 4,
              right: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: kPanelColor,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '$frameCount frames',
                  style: const TextStyle(
                    fontSize: 8,
                    color: kTextMuted,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Painter ──────────────────────────────────────────────────────────────

class _MiniMapPainter extends CustomPainter {
  final Rect viewportFraction;

  const _MiniMapPainter({required this.viewportFraction});

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 16.0;

    final gridPaint = Paint()
      ..color = const Color(0xFF141E38)
      ..strokeWidth = 0.5;

    // Vertical lines
    var x = 0.0;
    while (x <= size.width) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
      x += spacing;
    }

    // Horizontal lines
    var y = 0.0;
    while (y <= size.height) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      y += spacing;
    }

    // Viewport rect (orange)
    final vpRect = Rect.fromLTWH(
      viewportFraction.left * size.width,
      viewportFraction.top * size.height,
      viewportFraction.width * size.width,
      viewportFraction.height * size.height,
    );

    canvas.drawRect(
      vpRect,
      Paint()
        ..color = kOrange.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      vpRect,
      Paint()
        ..color = kOrange
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    // Center dot in viewport
    canvas.drawCircle(vpRect.center, 2.0, Paint()..color = kOrange);
  }

  @override
  bool shouldRepaint(_MiniMapPainter old) =>
      old.viewportFraction != viewportFraction;
}
