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
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_dial_config.dart';

/// Camera ruler slider
///
/// Designed for ISO / shutter style camera controls.
/// Uses cached tick strip for high performance.
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
  /// Snapped stop index — advances one step per tick during drag.
  int _currentIndex = 0;

  /// Sub-tick pixel accumulator — controls *when* the index advances, not used for visuals.
  double _dragAccum = 0;

  /// velocity in pixels/sec for inertia
  double velocity = 0;

  DateTime? lastTime;

  Timer? inertiaTimer;

  /// cached tick strip image
  ui.Image? rulerCache;

  static const double tickSpacing = 22;
  static const double _cacheHeight = 100;

  /// Always the snapped integer position — visual and haptic snap happen together, no glide-between-ticks.
  double get _visualIndex => _currentIndex.toDouble();

  @override
  void initState() {
    super.initState();
    final idx = widget.config.stops.indexOf(widget.initialValue);
    _currentIndex = (idx < 0 ? 0 : idx).clamp(0, widget.config.stopCount - 1);
    _buildCache();
  }

  @override
  void didUpdateWidget(CameraRulerSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only rebuild the cache when the stops themselves change.
    // Do NOT null out rulerCache first — keep the old image visible
    // during the async gap to prevent flicker on every parent setState.
    final oldCfg = oldWidget.config;
    final newCfg = widget.config;
    if (oldCfg.stopCount != newCfg.stopCount ||
        oldCfg.majorTickEvery != newCfg.majorTickEvery) {
      _buildCache();
    }
  }

  /// Builds the GPU-cached tick strip with a fixed height.
  Future<void> _buildCache() async {
    final n = widget.config.stopCount;
    if (n < 2) return;

    // Fixed height avoids double.infinity from Column(mainAxisSize: min), which makes toImage() fail silently.
    final double width = n * tickSpacing;
    const double height = _cacheHeight;

    final recorder = ui.PictureRecorder();
    // Canvas bounding rect is required — omitting it clips lines outside the image origin.
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));

    final minor = Paint()
      ..strokeWidth = 2
      ..color = Colors.white54;

    final major = Paint()
      ..strokeWidth = 3
      ..color = Colors.white;

    for (int i = 0; i < n; i++) {
      final dx = i * tickSpacing;
      final isMajor = i % widget.config.majorTickEvery == 0;
      final tickH = isMajor ? 34.0 : 18.0;
      canvas.drawLine(
        Offset(dx, height / 2),
        Offset(dx, height / 2 - tickH),
        isMajor ? major : minor,
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width.ceil(), height.ceil());
    if (mounted) {
      setState(() => rulerCache = image);
    }
  }

  // Accumulate raw pixels; advance index by 1 stop per tickSpacing px so snap and haptic fire together.
  void updateDrag(double delta) {
    _dragAccum += delta;
    final steps = (_dragAccum / tickSpacing).truncate();
    if (steps != 0) {
      _dragAccum -= steps * tickSpacing;
      final newIndex =
          (_currentIndex - steps).clamp(0, widget.config.stopCount - 1);
      if (newIndex != _currentIndex) {
        _currentIndex = newIndex;
        HapticFeedback.selectionClick();
        widget.onChanged(widget.config.stops[_currentIndex]);
      }
    }
    setState(() {});
  }

  /// Track drag velocity
  void trackVelocity(double delta) {
    final now = DateTime.now();
    if (lastTime != null) {
      final dt = now.difference(lastTime!).inMilliseconds / 1000;
      if (dt > 0) velocity = delta / dt;
    }
    lastTime = now;
  }

  /// Inertial scrolling after drag release, then flush residual accumulator.
  void startInertia() {
    const friction = 0.88;
    inertiaTimer?.cancel();
    inertiaTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      velocity *= friction;
      if (velocity.abs() < 0.5) {
        inertiaTimer?.cancel();
        setState(() => _dragAccum = 0);
        return;
      }
      updateDrag(velocity * 0.016);
    });
  }

  /// Flush accumulator on finger lift.
  void onDragEnd() {
    if (velocity.abs() < 0.5) {
      setState(() => _dragAccum = 0);
    } else {
      startInertia();
    }
  }

  @override
  void dispose() {
    inertiaTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _CameraRulerSliderState._cacheHeight,
      child: GestureDetector(
        onHorizontalDragUpdate: (d) {
          trackVelocity(d.delta.dx);
          updateDrag(d.delta.dx);
        },
        onHorizontalDragEnd: (_) => onDragEnd(),
        child: CustomPaint(
          painter: _RulerPainter(
            visualIndex: _visualIndex,
            config: widget.config,
            cache: rulerCache,
          ),
          child: const Center(child: _Indicator()),
        ),
      ),
    );
  }
}

/// Center indicator line
class _Indicator extends StatelessWidget {
  const _Indicator();

  @override
  Widget build(BuildContext context) {
    return Container(width: 2, height: 60, color: Colors.orange);
  }
}

/// Painter responsible for drawing ruler ticks and labels.
/// Uses a pre-built cached image for the tick strip, translated so the active
/// tick always sits under the center indicator.
class _RulerPainter extends CustomPainter {
  final double visualIndex;
  final CameraDialConfig config;
  final ui.Image? cache;

  static const double tickSpacing = 22;

  _RulerPainter({
    required this.visualIndex,
    required this.config,
    required this.cache,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (cache == null) return;

    // canvas.translate (not Offset in drawImage) keeps dx in the GPU matrix for true subpixel rendering.
    final dx = size.width / 2 - visualIndex * tickSpacing;
    canvas.save();
    canvas.translate(dx, 0);
    canvas.drawImage(cache!, Offset.zero, Paint());
    canvas.restore();

    _drawLabels(canvas, size, visualIndex, dx);
    _drawCenterGlow(canvas, size);
    _drawEdgeFade(canvas, size);
  }

  void _drawLabels(
    Canvas canvas,
    Size size,
    double centerIndex,
    double rulerOffset,
  ) {
    const labelWindow = 4; // labels within ±4 stops of center
    final center = centerIndex.round();

    for (int i = center - labelWindow; i <= center + labelWindow; i++) {
      if (i < 0 || i >= config.stopCount) continue;

      final x = rulerOffset + i * tickSpacing;
      if (x < -40 || x > size.width + 40) continue;

      final distance = (i - centerIndex).abs();
      final opacity = (1 - distance / labelWindow).clamp(0.0, 1.0);

      final text = config.format(config.stops[i]);
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: Colors.white.withOpacity(opacity),
            fontSize: 11,
            fontWeight:
                i == center ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      painter.paint(
        canvas,
        Offset(x - painter.width / 2, size.height / 2 - 52),
      );
    }
  }

  void _drawCenterGlow(Canvas canvas, Size size) {
    final glow = Paint()
      ..shader = LinearGradient(
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

  void _drawEdgeFade(Canvas canvas, Size size) {
    final fade = Paint()
      ..shader = LinearGradient(
        colors: [Colors.black, Colors.transparent],
      ).createShader(Rect.fromLTWH(0, 0, 80, size.height));

    canvas.drawRect(Rect.fromLTWH(0, 0, 80, size.height), fade);

    canvas.save();
    canvas.translate(size.width - 80, 0);
    canvas.scale(-1, 1);
    canvas.drawRect(Rect.fromLTWH(0, 0, 80, size.height), fade);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RulerPainter oldDelegate) {
    return oldDelegate.visualIndex != visualIndex ||
        oldDelegate.cache != cache ||
        oldDelegate.config != config;
  }
}
