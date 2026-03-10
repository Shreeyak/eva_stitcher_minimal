import 'package:flutter/material.dart';

/// Mock canvas view — a dark grid placeholder for the tile stitcher output.
/// Will be replaced with the real tile renderer in Phase 2.
class CanvasView extends StatelessWidget {
  /// Viewport center offset in canvas units (for future pan/zoom support).
  final Offset viewportCenter;

  const CanvasView({super.key, this.viewportCenter = Offset.zero});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surface,
      child: CustomPaint(
        painter: _GridPainter(
          viewportCenter: viewportCenter,
          minorColor: cs.surfaceContainer,
          majorColor: cs.surfaceContainerHighest,
          crosshairColor: cs.outlineVariant,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

// ── Painter ───────────────────────────────────────────────────────────────────

class _GridPainter extends CustomPainter {
  final Offset viewportCenter;
  final Color minorColor;
  final Color majorColor;
  final Color crosshairColor;

  const _GridPainter({
    required this.viewportCenter,
    required this.minorColor,
    required this.majorColor,
    required this.crosshairColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const gridSpacing = 48.0;

    final minorPaint = Paint()
      ..color = minorColor
      ..strokeWidth = 0.5;

    final majorPaint = Paint()
      ..color = majorColor
      ..strokeWidth = 1.0;

    // Offset so grid scrolls with viewport (for future pan)
    final dx = viewportCenter.dx % gridSpacing;
    final dy = viewportCenter.dy % gridSpacing;

    // Vertical lines
    var x = -dx;
    var idx = 0;
    while (x <= size.width + gridSpacing) {
      final paint = (idx % 4 == 0) ? majorPaint : minorPaint;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      x += gridSpacing;
      idx++;
    }

    // Horizontal lines
    var y = -dy;
    idx = 0;
    while (y <= size.height + gridSpacing) {
      final paint = (idx % 4 == 0) ? majorPaint : minorPaint;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      y += gridSpacing;
      idx++;
    }

    // Center crosshair
    final crossPaint = Paint()
      ..color = crosshairColor
      ..strokeWidth = 1.0;
    final cx = size.width / 2;
    final cy = size.height / 2;
    canvas.drawLine(Offset(cx - 12, cy), Offset(cx + 12, cy), crossPaint);
    canvas.drawLine(Offset(cx, cy - 12), Offset(cx, cy + 12), crossPaint);

    // "No canvas data" label
    final tp = TextPainter(
      text: TextSpan(
        text: 'NO CANVAS DATA',
        style: TextStyle(
          color: crosshairColor,
          fontSize: 13,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w300,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy + 20));
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.viewportCenter != viewportCenter ||
      old.minorColor != minorColor ||
      old.majorColor != majorColor ||
      old.crosshairColor != crosshairColor;
}
