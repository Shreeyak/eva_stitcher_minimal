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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_dial_config.dart';

/// Width (px) of the fade zone on each edge of the inner ruler viewport.
/// Used by both _TicksPainter and _LabelsPainter for consistent edge fading.
const double _kFadeZone = 60.0;

/// Smoothstep fade: 0 at the viewport edge, 1 at _kFadeZone inward.
double _edgeFade(double x, double viewportWidth) {
  double t = 1.0;
  if (x < _kFadeZone) t = (x / _kFadeZone).clamp(0.0, 1.0);
  if (x > viewportWidth - _kFadeZone) {
    t = ((viewportWidth - x) / _kFadeZone).clamp(0.0, 1.0);
  }
  return t * t * (3.0 - 2.0 * t);
}

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

  /// Optional icon shown at the left (min) end of the slider.
  final Widget? leftIcon;

  /// Optional icon shown at the right (max) end of the slider.
  final Widget? rightIcon;

  const CameraRulerSlider({
    super.key,
    required this.config,
    required this.initialValue,
    required this.onChanged,
    this.enableInertia = false,
    this.fadeColor = Colors.black,
    this.leftIcon,
    this.rightIcon,
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

  static const double tickSpacing = 18;

  /// Total widget height (gesture-sensitive area).
  static const double _totalHeight = 44;

  /// Y-offset from widget top where the tick strip begins.
  /// The label area lives above this.
  static const double _tickTop = 24;

  /// Horizontal padding reserved for the end icons on each side.
  /// Sized ~= total widget height (44 px) + a little breathing room.
  /// Ticks and labels are clipped to the inner [_kIconPad, width-_kIconPad] zone.
  static const double _kIconPad = 52.0;

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
  }

  @override
  void didUpdateWidget(CameraRulerSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Config changes are handled by _TicksPainter.shouldRepaint
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
          // Ruler center is the center of the inner (non-icon) area.
          // Since inner zone is symmetric, the center equals maxWidth/2.
          final innerDx = constraints.maxWidth / 2 - _visualIndex * tickSpacing;
          // Equivalent position in the local coordinate of the inner clip
          // (origin shifted right by _kIconPad).
          final localDx = innerDx - _kIconPad;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) {
              if (widget.enableInertia) trackVelocity(d.delta.dx);
              updateDrag(d.delta.dx);
            },
            onHorizontalDragEnd: (_) => onDragEnd(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ── Inner ruler zone (ticks + labels) ────────────────────
                // Clipped to [_kIconPad, width-_kIconPad] so ticks never
                // render under the end icons.
                // _TicksPainter draws only visible ticks and fades each tick
                // based on its distance from the viewport edges — no ShaderMask
                // needed, and fading is always correct at min/max positions.
                Positioned(
                  left: _kIconPad,
                  right: _kIconPad,
                  top: 0,
                  bottom: 0,
                  child: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Ticks — viewport-edge fade built into painter.
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _TicksPainter(
                              config: widget.config,
                              rulerOffset: localDx,
                              tickTop: _tickTop,
                            ),
                          ),
                        ),
                        // Labels — same local coordinate space.
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _LabelsPainter(
                                visualIndex: _visualIndex,
                                config: widget.config,
                                rulerOffset: localDx,
                                tickTop: _tickTop,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── Center indicator (capsule) ────────────────────────────
                // bottom:2 pins capsule ~2px lower than tick baseline,
                // creating a small gap below the label area.
                Positioned(
                  top: 0,
                  bottom: 3,
                  left: _kIconPad,
                  right: _kIconPad,
                  child: const Align(
                    alignment: Alignment.bottomCenter,
                    child: _Indicator(),
                  ),
                ),

                // ── End icons ────────────────────────────────────────────
                if (widget.leftIcon != null)
                  Positioned(
                    left: 12,
                    top: 0,
                    bottom: 0,
                    child: Center(child: widget.leftIcon!),
                  ),
                if (widget.rightIcon != null)
                  Positioned(
                    right: 12,
                    top: 0,
                    bottom: 0,
                    child: Center(child: widget.rightIcon!),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Tick strip painter.
///
/// Draws only the ticks that fall within the current viewport, with per-tick
/// alpha computed from the tick's distance from the left/right viewport edges.
/// This produces a correct soft fade at all scroll positions including min/max.
class _TicksPainter extends CustomPainter {
  final CameraDialConfig config;

  /// X position of tick index 0 in the local clip-zone coordinate space.
  final double rulerOffset;

  /// Y offset from widget top where ticks start (bottom of label area).
  final double tickTop;

  static const double tickSpacing = 18;

  const _TicksPainter({
    required this.config,
    required this.rulerOffset,
    required this.tickTop,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = config.stopCount;
    if (n < 2) return;

    const Color tickBase = Color(0xFFD4847A);
    // Ticks bottom at tickTop + 16 — matches the old cacheHeight positioning.
    // Painting to size.height (44) would clip against the ClipRect edge.
    final double bottom = tickTop + 16.0;

    // Only iterate ticks that could be visible on screen.
    // First possibly visible: x = rulerOffset + i*tickSpacing >= -tickSpacing
    final int iFirst = ((-tickSpacing - rulerOffset) / tickSpacing)
        .floor()
        .clamp(0, n - 1);
    // Last possibly visible: x <= size.width + tickSpacing
    final int iLast = ((size.width + tickSpacing - rulerOffset) / tickSpacing)
        .ceil()
        .clamp(0, n - 1);

    final paint = Paint()..strokeCap = StrokeCap.round;

    for (int i = iFirst; i <= iLast; i++) {
      final double x = rulerOffset + i * tickSpacing;

      final double edgeFade = _edgeFade(x, size.width);
      if (edgeFade <= 0) continue;

      final bool isMajor = i % config.majorTickEvery == 0;
      final double tickH = isMajor ? 14.0 : 7.0;
      final double baseAlpha = isMajor ? 0.85 : 0.45;

      paint
        ..strokeWidth = isMajor ? 2.0 : 1.5
        ..color = tickBase.withValues(alpha: baseAlpha * edgeFade);

      canvas.drawLine(Offset(x, bottom), Offset(x, bottom - tickH), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TicksPainter oldDelegate) {
    return oldDelegate.config.stopCount != config.stopCount ||
        oldDelegate.config.majorTickEvery != config.majorTickEvery ||
        oldDelegate.rulerOffset != rulerOffset;
  }
}

/// Center indicator — a rounded capsule pill, taller than the major ticks so
/// it visibly protrudes above them. Thicker width makes it immediately obvious.
class _Indicator extends StatelessWidget {
  const _Indicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 20,
      decoration: BoxDecoration(
        color: const Color(0xFFED9478),
        borderRadius: BorderRadius.circular(100),
      ),
    );
  }
}

/// Labels-only painter — lightweight, no image ops.
/// Shows: large bold value at center indicator, small faint labels only for
/// nearby major ticks. Minor ticks are not labelled.
class _LabelsPainter extends CustomPainter {
  final double visualIndex;
  final CameraDialConfig config;
  double rulerOffset;

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
    // labelBaselineY offsets the label bottom from tickTop.
    // Keep at -2 so the top of tall glyphs (18px bold ~22px rendered) just touches
    // y=0 without being clipped by the inner ClipRect.
    const double labelBaselineY = -6.0;

    // Minimum pixel gap between the edge of one label and the start of the next.
    const double minGap = 18.0;

    // Maximum side labels shown per direction.
    const int maxPerSide = 2;

    // ── Helper: build and paint a label with viewport-edge fade ──────────
    TextPainter _makePainter(
      int idx, {
      required bool isCenter,
      required double x,
    }) {
      final double fade = _edgeFade(x, size.width);
      return TextPainter(
        text: TextSpan(
          text: config.format(config.stops[idx]),
          style: TextStyle(
            color: isCenter
                ? Colors.white.withValues(alpha: fade)
                : Colors.white.withValues(alpha: 0.45 * fade),
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
    final centerPainter = _makePainter(centerIdx, isCenter: true, x: centerX);
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
        final tp = _makePainter(i, isCenter: false, x: x);
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
        final tp = _makePainter(i, isCenter: false, x: x);
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
