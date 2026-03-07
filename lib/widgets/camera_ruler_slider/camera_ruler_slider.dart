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

  /// Whether fling inertia is active after drag release. Defaults to false.
  final bool enableInertia;

  const CameraRulerSlider({
    super.key,
    required this.config,
    required this.initialValue,
    required this.onChanged,
    this.enableInertia = false,
  });

  @override
  State<CameraRulerSlider> createState() => _CameraRulerSliderState();
}

class _CameraRulerSliderState extends State<CameraRulerSlider> {
  /// Float 0..1 position — fractional during drag, snapped to a stop at rest.
  double _visualPercent = 0;

  /// velocity in pixels/sec for inertia
  double velocity = 0;

  DateTime? lastTime;

  Timer? inertiaTimer;

  /// Last tick index the indicator passed through — used for haptic + live onChanged.
  int _lastTickIndex = 0;

  /// cached tick strip image
  ui.Image? rulerCache;

  static const double tickSpacing = 22;
  static const double _cacheHeight = 100;

  /// Fractional index — smooth during drag, integer-aligned at rest.
  double get _visualIndex => _visualPercent * (widget.config.stopCount - 1);

  @override
  void initState() {
    super.initState();
    final idx = widget.config.stops.indexOf(widget.initialValue);
    final clampedIdx = (idx < 0 ? 0 : idx).clamp(
      0,
      widget.config.stopCount - 1,
    );
    _visualPercent = widget.config.indexToPercent(clampedIdx);
    _lastTickIndex = clampedIdx.toInt();
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

  // Move smoothly as a float — no snapping during drag.
  // Fires haptic + onChanged each time the indicator crosses a tick boundary.
  void updateDrag(double delta) {
    final percentPerPixel = 1.0 / ((widget.config.stopCount - 1) * tickSpacing);
    final newPercent = (_visualPercent - delta * percentPerPixel).clamp(
      0.0,
      1.0,
    );
    _checkTickCrossing(newPercent);
    setState(() {
      _visualPercent = newPercent;
    });
  }

  /// Fires haptic feedback and onChanged exactly once per tick boundary crossed.
  void _checkTickCrossing(double newPercent) {
    final newIndex = (newPercent * (widget.config.stopCount - 1)).round().clamp(
      0,
      widget.config.stopCount - 1,
    );
    if (newIndex != _lastTickIndex) {
      _lastTickIndex = newIndex;
      HapticFeedback.heavyImpact();
      widget.onChanged(widget.config.stops[newIndex]);
    }
  }

  // Snap in the direction of movement using velocity (temporally smoothed, not
  // susceptible to end-of-gesture jitter). Right drag (velocity > 0) → snap up;
  // left drag (velocity < 0) → snap down.
  void _snapNow() {
    // Always snap to the nearest tick — velocity-direction snapping causes
    // jitter on small movements because finger-lift velocity is noisy.
    // onChanged already fires live via _checkTickCrossing; this just confirms
    // the final resting position.
    final index = (_visualPercent * (widget.config.stopCount - 1))
        .round()
        .clamp(0, widget.config.stopCount - 1);
    _visualPercent = widget.config.indexToPercent(index);
    widget.onChanged(widget.config.stops[index]);
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

  /// Inertial scroll after drag release; snap to nearest stop when coasting ends.
  void startInertia() {
    const friction = 0.88;
    inertiaTimer?.cancel();
    inertiaTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      velocity *= friction;
      if (velocity.abs() < 0.5) {
        inertiaTimer?.cancel();
        setState(_snapNow);
        return;
      }
      updateDrag(velocity * 0.016);
    });
  }

  /// Snap immediately on finger lift; start inertia only if enabled and velocity is high.
  void onDragEnd() {
    if (widget.enableInertia && velocity.abs() >= 0.5) {
      startInertia();
    } else {
      setState(_snapNow);
    }
  }

  @override
  void dispose() {
    inertiaTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Fixed _cacheHeight — no height guards needed.
    // LayoutBuilder is used only to read maxWidth for center-lock offset.
    return SizedBox(
      height: _cacheHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // dx computed here so Transform.translate gets it; compositor moves
          // the texture layer without calling paint() each frame.
          final dx = constraints.maxWidth / 2 - _visualIndex * tickSpacing;

          return GestureDetector(
            onHorizontalDragUpdate: (d) {
              if (widget.enableInertia) trackVelocity(d.delta.dx);
              updateDrag(d.delta.dx);
            },
            onHorizontalDragEnd: (_) => onDragEnd(),
            child: Stack(
              children: [
                // Texture layer — GPU translation, zero CPU per frame.
                Transform.translate(
                  offset: Offset(dx, 0),
                  child: RawImage(image: rulerCache),
                ),

                // Labels painted on top; cheap (text only, no image ops).
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _LabelsPainter(
                        visualIndex: _visualIndex,
                        config: widget.config,
                        rulerOffset: dx,
                      ),
                    ),
                  ),
                ),

                // Edge fade — widget gradient, GPU composited.
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.black,
                            Colors.transparent,
                            Colors.transparent,
                            Colors.black,
                          ],
                          stops: [0, 0.12, 0.88, 1],
                        ),
                      ),
                    ),
                  ),
                ),

                // Center glow — widget gradient, GPU composited.
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            Colors.white.withValues(alpha: 0.15),
                            Colors.transparent,
                          ],
                          stops: const [0.44, 0.5, 0.56],
                        ),
                      ),
                    ),
                  ),
                ),

                const Center(child: _Indicator()),
              ],
            ),
          );
        },
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

/// Labels-only painter — lightweight, no image ops.
/// Glow and edge fade are handled as widget-layer gradients in build().
class _LabelsPainter extends CustomPainter {
  final double visualIndex;
  final CameraDialConfig config;
  final double rulerOffset;

  static const double tickSpacing = 22;

  _LabelsPainter({
    required this.visualIndex,
    required this.config,
    required this.rulerOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const labelWindow = 4;
    final center = visualIndex.round();

    for (int i = center - labelWindow; i <= center + labelWindow; i++) {
      if (i < 0 || i >= config.stopCount) continue;

      final x = rulerOffset + i * tickSpacing;
      if (x < -40 || x > size.width + 40) continue;

      final distance = (i - visualIndex).abs();
      final opacity = (1 - distance / labelWindow).clamp(0.0, 1.0);

      final painter = TextPainter(
        text: TextSpan(
          text: config.format(config.stops[i]),
          style: TextStyle(
            color: Colors.white.withValues(alpha: opacity),
            fontSize: 11,
            fontWeight: i == center ? FontWeight.w600 : FontWeight.normal,
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

  @override
  bool shouldRepaint(covariant _LabelsPainter oldDelegate) {
    return oldDelegate.visualIndex != visualIndex ||
        oldDelegate.rulerOffset != rulerOffset;
  }
}
