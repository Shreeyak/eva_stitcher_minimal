import 'package:flutter/material.dart';

/// Vertical bar showing current scan velocity.
///
/// Green at low speed, yellow approaching the gating threshold, red above it.
/// Full fill corresponds to [_kMaxSpeed] canvas px/sec (2× gating threshold).
class VelocityBar extends StatelessWidget {
  final double speed;

  // 2× gating threshold (VELOCITY_THRESHOLD = 150 canvas px/sec in types.h).
  static const double _kMaxSpeed = 300.0;

  const VelocityBar({super.key, required this.speed});

  @override
  Widget build(BuildContext context) {
    final fraction = (speed / _kMaxSpeed).clamp(0.0, 1.0);
    final barColor = _colorForFraction(fraction);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 120.0;
        final fillHeight = totalHeight * fraction;

        return Stack(
          alignment: Alignment.bottomCenter,
          children: [
            // Track
            Container(
              width: double.infinity,
              height: totalHeight,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            // Fill
            if (fillHeight > 0)
              Container(
                width: double.infinity,
                height: fillHeight,
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [
                    BoxShadow(
                      color: barColor.withValues(alpha: 0.5),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  static Color _colorForFraction(double f) {
    // Green → yellow at 0–0.5, yellow → red at 0.5–1.0
    if (f <= 0.5) {
      return Color.lerp(Colors.green, Colors.yellow, f / 0.5)!;
    } else {
      return Color.lerp(Colors.yellow, Colors.red, (f - 0.5) / 0.5)!;
    }
  }
}
