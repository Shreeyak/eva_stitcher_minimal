import 'package:flutter/material.dart';

/// Horizontal bar showing current stitch quality (0–1).
///
/// - Blank/transparent when tracking lost (quality = 0 or trackingState ≠ 1).
/// - Red when quality < 0.3.
/// - Yellow when quality 0.3–0.6.
/// - Green when quality ≥ 0.6.
class QualityBar extends StatelessWidget {
  final double quality;
  /// 0=INIT, 1=TRACKING, 2=UNCERTAIN, 3=LOST
  final int trackingState;

  const QualityBar({
    super.key,
    required this.quality,
    required this.trackingState,
  });

  @override
  Widget build(BuildContext context) {
    final isTracking = trackingState == 1 && quality > 0.0;
    final barColor = isTracking ? _colorForQuality(quality) : Colors.transparent;
    final fraction = quality.clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 200.0;
        final fillWidth = isTracking ? totalWidth * fraction : 0.0;

        return Stack(
          alignment: Alignment.centerLeft,
          children: [
            // Track
            Container(
              width: totalWidth,
              height: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Fill
            if (fillWidth > 0)
              Container(
                width: fillWidth,
                height: double.infinity,
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: [
                    BoxShadow(
                      color: barColor.withValues(alpha: 0.4),
                      blurRadius: 3,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  static Color _colorForQuality(double q) {
    if (q < 0.3) return Colors.red;
    if (q < 0.6) return Colors.yellow;
    return Colors.green;
  }
}
