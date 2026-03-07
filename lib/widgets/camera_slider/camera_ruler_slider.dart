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
library;

import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

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

  double velocity = 0;
  DateTime? lastTime;

  Timer? inertiaTimer;

  double lastTick = -1;

  ui.Image? rulerCache;
  Size? cacheSize;

  static const double tickSpacing = 18;

  @override
  void initState() {
    super.initState();
    percent = widget.config.valueToPercent(widget.initialValue);
  }

  @override
  void didUpdateWidget(covariant CameraRulerSlider oldWidget) {
    super.didUpdateWidget(oldWidget);

    final geometryChanged =
        oldWidget.config.ticks != widget.config.ticks ||
        oldWidget.config.majorTickEvery != widget.config.majorTickEvery;

    if (geometryChanged) {
      rulerCache = null;
      cacheSize = null;
    }
  }

  Future<void> buildCache(Size size) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final cycleWidth = widget.config.ticks * tickSpacing;
    final horizontalPadding = size.width / 2 + 40;
    final width = cycleWidth * 3 + horizontalPadding * 2;
    final height = size.height;

    final minor = Paint()
      ..strokeWidth = 2
      ..color = Colors.white54;

    final major = Paint()
      ..strokeWidth = 3
      ..color = Colors.white;

    for (int i = 0; i <= widget.config.ticks * 3; i++) {
      final dx = horizontalPadding + i * tickSpacing;

      final isMajor = i % widget.config.majorTickEvery == 0;

      final h = isMajor ? 34 : 18;

      canvas.drawLine(
        Offset(dx, height / 2),
        Offset(dx, height / 2 - h),
        isMajor ? major : minor,
      );
    }

    final picture = recorder.endRecording();

    rulerCache = await picture.toImage(width.toInt(), height.toInt());

    cacheSize = size;

    setState(() {});
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

    percent = snap(percent);

    triggerHaptic(percent);

    setState(() {});

    widget.onChanged(widget.config.percentToValue(percent));
  }

  double snap(double p) {
    if (widget.config.isDiscrete) {
      final steps = widget.config.stops!.length - 1;
      final step = 1 / steps;

      return (p / step).round() * step;
    }

    final step = 1 / widget.config.ticks;

    return (p / step).round() * step;
  }

  void triggerHaptic(double p) {
    final tick = (p * widget.config.ticks).roundToDouble();

    if (tick != lastTick) {
      lastTick = tick;
      HapticFeedback.selectionClick();
    }
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);

        if (rulerCache == null || cacheSize != size) {
          buildCache(size);
        }

        return SizedBox(
          height: 100,
          child: GestureDetector(
            onHorizontalDragUpdate: (d) {
              trackVelocity(d.delta.dx);
              updateDrag(d.delta.dx);
            },
            onHorizontalDragEnd: (_) => startInertia(),
            child: CustomPaint(
              painter: _RulerPainter(
                percent: percent,
                config: widget.config,
                cache: rulerCache,
              ),
              child: const Center(child: _Indicator()),
            ),
          ),
        );
      },
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
  final ui.Image? cache;

  static const double tickSpacing = 18;

  _RulerPainter({
    required this.percent,
    required this.config,
    required this.cache,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final cycleWidth = config.ticks * tickSpacing;
    final horizontalPadding = size.width / 2 + 40;
    final offset = percent * cycleWidth;

    if (cache != null) {
      final sourceLeft = horizontalPadding + cycleWidth + offset - centerX;
      canvas.drawImageRect(
        cache!,
        Rect.fromLTWH(sourceLeft, 0, size.width, size.height),
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint(),
      );
    }

    final tickIndex = percent * config.ticks;
    for (int i = -config.ticks; i <= config.ticks * 2; i++) {
      final logicalTick = i % config.ticks;
      final tick = logicalTick < 0 ? logicalTick + config.ticks : logicalTick;
      if (tick % config.majorTickEvery != 0) continue;

      final dx = centerX + (i - tickIndex) * tickSpacing;
      if (dx < -60 || dx > size.width + 60) continue;

      final distance = ((dx - centerX).abs() / size.width);
      final fade = max(0.0, 1.0 - distance * 1.6);
      if (fade <= 0.25) continue;

      final value = config.percentToValue(tick / config.ticks);
      final textPainter = TextPainter(
        text: TextSpan(
          text: config.format(value),
          style: TextStyle(
            color: Colors.white.withOpacity(fade),
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(dx - textPainter.width / 2, size.height / 2 - 56),
      );
    }

    final glow = Paint()
      ..shader =
          LinearGradient(
            colors: [
              Colors.transparent,
              Colors.white.withOpacity(0.15),
              Colors.transparent,
            ],
          ).createShader(
            Rect.fromCenter(
              center: Offset(size.width / 2, size.height / 2),
              width: 120,
              height: size.height,
            ),
          );

    canvas.drawRect(
      Rect.fromLTWH(size.width / 2 - 60, 0, 120, size.height),
      glow,
    );
  }

  @override
  bool shouldRepaint(covariant _RulerPainter oldDelegate) {
    return oldDelegate.percent != percent ||
        oldDelegate.config.ticks != config.ticks ||
        oldDelegate.config.majorTickEvery != config.majorTickEvery ||
        oldDelegate.cache != cache;
  }
}
