import 'package:flutter/material.dart';

/// Small thumbnail map shown in the top-right corner.
/// Shows a downscaled view of the stitched canvas (mock grid for now)
/// with a viewport rectangle representing the current camera view.
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
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: _kWidth,
      height: _kHeight,
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border.all(color: cs.primary, width: 1.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Stack(
          children: [
            // Downsampled stitched image background
            Positioned.fill(
              child: Image.asset(
                'scripts/tmp_files/r04_c04.png',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => ColoredBox(
                  color: cs.surfaceContainer,
                  child: const SizedBox.expand(),
                ),
              ),
            ),

            // Viewport rect overlay
            Positioned.fill(
              child: CustomPaint(
                painter: _ViewportPainter(
                  viewportFraction: viewportFraction,
                  viewportColor: cs.tertiary,
                ),
              ),
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
                  color: cs.primary,
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
                  color: cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '$frameCount frames',
                  style: TextStyle(
                    fontSize: 8,
                    color: cs.outline,
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

// ── Painter ───────────────────────────────────────────────────────────────────

class _ViewportPainter extends CustomPainter {
  final Rect viewportFraction;
  final Color viewportColor;

  const _ViewportPainter({
    required this.viewportFraction,
    required this.viewportColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Viewport rect
    final vpRect = Rect.fromLTWH(
      viewportFraction.left * size.width,
      viewportFraction.top * size.height,
      viewportFraction.width * size.width,
      viewportFraction.height * size.height,
    );

    canvas.drawRect(
      vpRect,
      Paint()
        ..color = viewportColor.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      vpRect,
      Paint()
        ..color = viewportColor
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    // Center dot in viewport
    canvas.drawCircle(vpRect.center, 2.0, Paint()..color = viewportColor);
  }

  @override
  bool shouldRepaint(_ViewportPainter old) =>
      old.viewportFraction != viewportFraction ||
      old.viewportColor != viewportColor;
}
