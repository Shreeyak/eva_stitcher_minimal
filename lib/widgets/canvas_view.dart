import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Infinite scrollable canvas showing the stitched image on top of a grid
/// background.  Layers (bottom to top): plain surface → stitched image → grid.
///
/// Starts centered on the image.  [InteractiveViewer] provides pan and zoom.
class CanvasView extends StatefulWidget {
  static const double kCanvasWidth = 6000;
  static const double kCanvasHeight = 6000;

  const CanvasView({super.key, this.previewBytes});

  /// Live JPEG preview from the stitching engine.  Replaces the placeholder
  /// asset once available.
  final Uint8List? previewBytes;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView> {
  final TransformationController _tc = TransformationController();
  bool _initialized = false;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _maybeInit(Size viewportSize) {
    if (_initialized || !viewportSize.isFinite) return;
    _initialized = true;
    // Translate so the canvas center aligns with the viewport center.
    final tx = viewportSize.width / 2 - CanvasView.kCanvasWidth / 2;
    final ty = viewportSize.height / 2 - CanvasView.kCanvasHeight / 2;
    _tc.value = Matrix4.translationValues(tx, ty, 0);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        _maybeInit(constraints.biggest);
        return InteractiveViewer(
          transformationController: _tc,
          boundaryMargin: EdgeInsets.all(double.infinity),
          minScale: 0.05,
          maxScale: 12.0,
          constrained: false,
          child: SizedBox(
            width: CanvasView.kCanvasWidth,
            height: CanvasView.kCanvasHeight,
            child: Stack(
              children: [
                // 1. Plain background (lighter shade of surface)
                Positioned.fill(
                  child: ColoredBox(color: cs.surfaceContainerLow),
                ),

                // 2. Stitched image, centered in the canvas
                Center(
                  child: widget.previewBytes != null
                      ? Image.memory(
                          widget.previewBytes!,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        )
                      : Image.asset(
                          'assets/r04_c04.png',
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                ),

                // 3. Grid pattern overlaid on top of the stitched image
                Positioned.fill(
                  child: CustomPaint(
                    painter: _GridPainter(
                      minorColor: cs.surfaceContainerHigh,
                      majorColor: cs.surfaceContainerHighest,
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

// ── Painter ───────────────────────────────────────────────────────────────────

class _GridPainter extends CustomPainter {
  final Color minorColor;
  final Color majorColor;

  const _GridPainter({required this.minorColor, required this.majorColor});

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 48.0;

    final minorPaint = Paint()
      ..color = minorColor
      ..strokeWidth = 0.5;

    final majorPaint = Paint()
      ..color = majorColor
      ..strokeWidth = 1.0;

    // Vertical lines
    var x = 0.0;
    var idx = 0;
    while (x <= size.width) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        idx % 4 == 0 ? majorPaint : minorPaint,
      );
      x += spacing;
      idx++;
    }

    // Horizontal lines
    var y = 0.0;
    idx = 0;
    while (y <= size.height) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        idx % 4 == 0 ? majorPaint : minorPaint,
      );
      y += spacing;
      idx++;
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.minorColor != minorColor || old.majorColor != majorColor;
}
