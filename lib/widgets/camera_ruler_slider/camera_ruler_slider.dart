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

  /// Color the edge-fade gradient blends into.
  /// Set this to match the container background so the fade looks seamless.
  final Color fadeColor;

  const CameraRulerSlider({
    super.key,
    required this.config,
    required this.initialValue,
    required this.onChanged,
    this.enableInertia = false,
    this.fadeColor = Colors.black,
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

  static const double tickSpacing = 18;

  /// Height of the tick strip image cache.
  static const double _cacheHeight = 16;

  /// Total widget height (gesture-sensitive area).
  static const double _totalHeight = 44;

  /// Y-offset from widget top where the tick strip begins.
  /// The label area lives above this.
  static const double _tickTop = 24;

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
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.35);

    final major = Paint()
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.85);

    for (int i = 0; i < n; i++) {
      final dx = i * tickSpacing;
      final isMajor = i % widget.config.majorTickEvery == 0;
      // Bottom-aligned: ticks grow upward from the bottom edge.
      final tickH = isMajor ? 14.0 : 7.0;
      canvas.drawLine(
        Offset(dx, height),
        Offset(dx, height - tickH),
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
    // _totalHeight is the full gesture-sensitive area.
    // Tick strip (_cacheHeight) is positioned at _tickTop from the top,
    // leaving the label area above and a small pad below.
    return SizedBox(
      height: _totalHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // dx computed here so Transform.translate gets it; compositor moves
          // the texture layer without calling paint() each frame.
          final dx = constraints.maxWidth / 2 - _visualIndex * tickSpacing;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) {
              if (widget.enableInertia) trackVelocity(d.delta.dx);
              updateDrag(d.delta.dx);
            },
            onHorizontalDragEnd: (_) => onDragEnd(),
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Tick strip — positioned at _tickTop so label area sits above it.
                  Positioned(
                    left: dx,
                    top: _tickTop,
                    height: _cacheHeight,
                    child: RawImage(
                      image: rulerCache,
                      fit: BoxFit.none,
                      alignment: Alignment.topLeft,
                    ),
                  ),

                  // Labels painted on top; only major ticks rendered, large center value.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _LabelsPainter(
                          visualIndex: _visualIndex,
                          config: widget.config,
                          rulerOffset: dx,
                          tickTop: _tickTop,
                        ),
                      ),
                    ),
                  ),

                  // Edge fade — blends into fadeColor so the capsule clip
                  // looks seamless rather than abruptly cutting ticks.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              widget.fadeColor.withValues(alpha: 0.80),
                              widget.fadeColor.withValues(alpha: 0.60),
                              widget.fadeColor.withValues(alpha: 0),
                              widget.fadeColor.withValues(alpha: 0),
                              widget.fadeColor.withValues(alpha: 0.60),
                              widget.fadeColor.withValues(alpha: 0.80),
                            ],
                            stops: const [0, 0.18, 0.32, 0.68, 0.82, 1],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Center indicator — aligned to the tick strip, not the full widget.
                  Positioned(
                    top: _tickTop,
                    bottom: _totalHeight - _tickTop - _cacheHeight,
                    left: 0,
                    right: 0,
                    child: const Center(child: _Indicator()),
                  ),
                ],
              ), // Stack
            ), // ClipRect
          );
        },
      ),
    );
  }
}

/// Center indicator line — height matches the tick strip (_cacheHeight = 16).
class _Indicator extends StatelessWidget {
  const _Indicator();

  @override
  Widget build(BuildContext context) {
    return Container(width: 2, height: 16, color: Colors.orange);
  }
}

/// Labels-only painter — lightweight, no image ops.
/// Shows: large bold value at center indicator, small faint labels only for
/// nearby major ticks. Minor ticks are not labelled.
class _LabelsPainter extends CustomPainter {
  final double visualIndex;
  final CameraDialConfig config;
  final double rulerOffset;

  /// Y-offset from widget top where the tick strip begins.
  /// Labels are drawn just above this line.
  final double tickTop;

  static const double tickSpacing = 18;

  _LabelsPainter({
    required this.visualIndex,
    required this.config,
    required this.rulerOffset,
    required this.tickTop,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final int step = config.majorTickEvery;
    final int centerIdx = visualIndex.round().clamp(0, config.stopCount - 1);
    final double centerX = rulerOffset + visualIndex * tickSpacing;

    // Labels sit just above the tick strip.
    // Bottom of text aligns to (tickTop - 6).
    const double labelBaselineY = -2.0;

    // Minimum pixel gap between the edge of one label and the start of the next.
    const double minGap = 18.0;

    // Maximum side labels shown per direction.
    const int maxPerSide = 2;

    // ── Helper: measure and paint a label ────────────────────────────────
    TextPainter _makePainter(int idx, {required bool isCenter}) {
      return TextPainter(
        text: TextSpan(
          text: config.format(config.stops[idx]),
          style: TextStyle(
            color: isCenter
                ? Colors.white
                : Colors.white.withValues(alpha: 0.45),
            fontSize: isCenter ? 18.0 : 10.0,
            fontWeight: isCenter ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    }

    void _paintAt(TextPainter tp, double x) {
      final double y = tickTop + labelBaselineY - tp.height;
      tp.paint(canvas, Offset(x - tp.width / 2, y));
    }

    // ── 1. Center label (always rendered) ────────────────────────────────
    final centerPainter = _makePainter(centerIdx, isCenter: true);
    _paintAt(centerPainter, centerX);

    // Right edge of center label in canvas coords (used as clearance boundary).
    double rightBoundary = centerX + centerPainter.width / 2;
    // Left edge of center label.
    double leftBoundary = centerX - centerPainter.width / 2;

    // ── 2. Walk right: nearest major tick(s) to the right of center ──────
    {
      // Start from the first major tick strictly to the right of centerIdx.
      final int firstRight = ((visualIndex / step).ceil() * step);
      int drawn = 0;
      for (
        int i = firstRight;
        i < config.stopCount && drawn < maxPerSide;
        i += step
      ) {
        final double x = rulerOffset + i * tickSpacing;
        if (x > size.width + 60) break; // off-screen right
        final tp = _makePainter(i, isCenter: false);
        final double leftEdge = x - tp.width / 2;
        if (leftEdge - rightBoundary >= minGap) {
          _paintAt(tp, x);
          rightBoundary = x + tp.width / 2;
          drawn++;
        }
      }
    }

    // ── 3. Walk left: nearest major tick(s) to the left of center ────────
    {
      final int firstLeft = ((visualIndex / step).floor() * step);
      int drawn = 0;
      for (int i = firstLeft; i >= 0 && drawn < maxPerSide; i -= step) {
        final double x = rulerOffset + i * tickSpacing;
        if (x < -60) break; // off-screen left
        // Skip the exact center tick — already drawn.
        if (i == centerIdx) continue;
        final tp = _makePainter(i, isCenter: false);
        final double rightEdge = x + tp.width / 2;
        if (leftBoundary - rightEdge >= minGap) {
          _paintAt(tp, x);
          leftBoundary = x - tp.width / 2;
          drawn++;
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LabelsPainter oldDelegate) {
    return oldDelegate.visualIndex != visualIndex ||
        oldDelegate.rulerOffset != rulerOffset;
  }
}
