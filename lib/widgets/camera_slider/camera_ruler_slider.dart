/// A production-style camera ruler dial with:
/// - center-locked indicator
/// - infinite scroll illusion
/// - optional min/max clamp
/// - velocity fling inertia
/// - magnetic tick snapping
/// - haptic feedback
/// - edge fading + tick glow
/// - logarithmic value mapping support
/// - GPU-cheap painter
///
/// Usage:
/// ```dart
/// import 'widgets/camera_slider/camera_ruler_slider.dart';
/// import 'widgets/camera_slider/camera_dial_config.dart';
///
/// CameraRulerSlider(
///   config: CameraDialConfig(
///     min: 1,
///     max: 10,
///     ticks: 120,
///     logarithmic: true,
///     clamp: false,
///   ),
///   initialValue: 1,
///   onChanged: (zoom) {},
/// )
/// ```

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'camera_dial_config.dart';

class CameraRulerSlider extends StatefulWidget {
  final CameraDialConfig config;
  final double initialValue;
  final ValueChanged<double> onChanged;

  const CameraRulerSlider({
    super.key,
    required this.config,
    required this.initialValue,
    required this.onChanged,
  });

  @override
  State<CameraRulerSlider> createState() => _CameraRulerSliderState();
}

class _CameraRulerSliderState extends State<CameraRulerSlider> {
  double percent = 0;
  double lastTick = -1;

  double velocity = 0;
  DateTime? lastTime;

  Timer? inertiaTimer;

  static const double tickSpacing = 18;

  @override
  void initState() {
    super.initState();
    percent = widget.config.valueToPercent(widget.initialValue);
  }

  void updateDrag(double delta) {
    final percentPerPixel = 1 / (widget.config.ticks * tickSpacing);

    percent -= delta * percentPerPixel;

    if (widget.config.clamp) {
      percent = percent.clamp(0.0, 1.0);
    } else {
      percent = percent % 1;
      if (percent < 0) percent += 1;
    }

    percent = snapPercent(percent);

    triggerHaptic(percent);

    setState(() {});

    widget.onChanged(widget.config.percentToValue(percent));
  }

  void triggerHaptic(double p) {
    final tick = (p * widget.config.ticks).roundToDouble();

    if (tick != lastTick) {
      lastTick = tick;
      HapticFeedback.selectionClick();
    }
  }

  double snapPercent(double p) {
    final step = 1 / widget.config.ticks;
    return (p / step).round() * step;
  }

  void trackVelocity(double delta) {
    final now = DateTime.now();

    if (lastTime != null) {
      final dt = now.difference(lastTime!).inMilliseconds / 1000;
      velocity = delta / dt;
    }

    lastTime = now;
  }

  void startInertia() {
    const friction = 0.92;

    inertiaTimer?.cancel();

    inertiaTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      velocity *= friction;

      if (velocity.abs() < 0.5) {
        inertiaTimer?.cancel();
        return;
      }

      updateDrag(velocity * 0.016);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 100,
      child: GestureDetector(
        onHorizontalDragUpdate: (d) {
          trackVelocity(d.delta.dx);
          updateDrag(d.delta.dx);
        },
        onHorizontalDragEnd: (_) => startInertia(),
        child: CustomPaint(
          painter: _RulerPainter(percent: percent, config: widget.config),
          child: const Center(child: _Indicator()),
        ),
      ),
    );
  }
}

class _Indicator extends StatelessWidget {
  const _Indicator();

  @override
  Widget build(BuildContext context) {
    return Container(width: 2, height: 60, color: Colors.orange);
  }
}

class _RulerPainter extends CustomPainter {
  final double percent;
  final CameraDialConfig config;

  static const double tickSpacing = 18;

  _RulerPainter({required this.percent, required this.config});

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final tickIndex = percent * config.ticks;

    final minorPaint = Paint()
      ..strokeWidth = 2
      ..color = Colors.white54;

    final majorPaint = Paint()
      ..strokeWidth = 3
      ..color = Colors.white;

    for (int i = -config.ticks; i <= config.ticks * 2; i++) {
      final dx = centerX + (i - tickIndex) * tickSpacing;

      if (dx < -40 || dx > size.width + 40) continue;

      final logicalTick = i % config.ticks;
      final tick = logicalTick < 0 ? logicalTick + config.ticks : logicalTick;

      final isMajor = tick % config.majorTickEvery == 0;

      final height = isMajor ? 34 : 18;

      final distance = ((dx - centerX).abs() / size.width);

      final double fade = max(0.0, 1.0 - distance * 1.6);

      final paint = isMajor ? majorPaint : minorPaint;
      paint.color = paint.color.withOpacity(fade);

      canvas.drawLine(
        Offset(dx, size.height / 2),
        Offset(dx, size.height / 2 - height),
        paint,
      );

      if (isMajor && fade > 0.25) {
        final percentValue = tick / config.ticks;
        final value = config.percentToValue(percentValue);
        final label = config.formatValue?.call(value) ?? _formatValue(value);

        final textPainter = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: Colors.white.withOpacity(fade),
              fontSize: 12,
            ),
          ),
          textDirection: TextDirection.ltr,
        );

        textPainter.layout();

        textPainter.paint(
          canvas,
          Offset(dx - textPainter.width / 2, size.height / 2 - height - 22),
        );
      }
    }
  }

  static String _formatValue(double v) {
    if (v == 0) return '0';
    if (v >= 1) {
      return v.toStringAsFixed(0);
    }

    return "1/${(1 / v).round()}";
  }

  @override
  bool shouldRepaint(covariant _RulerPainter oldDelegate) {
    return oldDelegate.percent != percent;
  }
}
