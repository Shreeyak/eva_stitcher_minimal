/// Horizontal camera ruler slider — ISO / shutter / zoom / focus style.
///
/// Features: tick snapping, haptic feedback, edge fade, optional inertia,
/// logarithmic value mapping, end icons.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_dial_config.dart';

// ── Layout constants ──────────────────────────────────────────────────────────

/// Spacing between adjacent tick marks in logical pixels.
const double _kTickSpacing = 18.0;

/// Total widget height — gesture-sensitive area.
const double _kTotalHeight = 44.0;

/// Y offset from widget top where the tick strip begins.
/// The label area lives above this line.
const double _kTickTop = 24.0;

/// Horizontal padding reserved on each side for end icons.
/// Ticks and labels are clipped to [_kIconPad, width − _kIconPad].
const double _kIconPad = 52.0;

/// Width of the fade zone on each edge of the inner viewport.
const double _kFadeZone = 60.0;

// ── Shared helpers ────────────────────────────────────────────────────────────

/// Smoothstep alpha: 1 in the centre, 0 at the viewport edge.
/// Applied per-tick rather than via ShaderMask so fading is correct at
/// min/max scroll positions (ShaderMask bounds shift with scrolling content).
double _edgeFade(double x, double viewportWidth) {
  double t = 1.0;
  if (x < _kFadeZone) t = (x / _kFadeZone).clamp(0.0, 1.0);
  if (x > viewportWidth - _kFadeZone) {
    t = ((viewportWidth - x) / _kFadeZone).clamp(0.0, 1.0);
  }
  return t * t * (3.0 - 2.0 * t);
}

// ── Widget ────────────────────────────────────────────────────────────────────

/// Horizontal ruler slider styled after iOS camera controls.
class CameraRulerSlider extends StatefulWidget {
  final CameraDialConfig config;
  final double initialValue;
  final ValueChanged<double> onChanged;

  /// Enables fling inertia after drag release.
  final bool enableInertia;

  // fadeColor is kept for API compatibility but not used in rendering —
  // fading is handled per-tick in _TicksPainter.
  final Color fadeColor;

  /// Icons shown at the left (min) and right (max) ends.
  final Widget? leftIcon;
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
  /// Scroll position as 0..1 fraction. Fractional during drag, snapped at rest.
  double _visualPercent = 0;

  double _velocity = 0;
  DateTime? _lastDragTime;
  Timer? _inertiaTimer;

  /// Last snapped tick index — used to fire haptic + onChanged exactly once per
  /// tick boundary crossed, not once per pixel.
  int _lastTickIndex = 0;

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

  // ── Drag ───────────────────────────────────────────────────────────────────

  void _updateDrag(double delta) {
    final pxPerPercent = 1.0 / ((widget.config.stopCount - 1) * _kTickSpacing);
    final newPercent = (_visualPercent - delta * pxPerPercent).clamp(0.0, 1.0);
    _crossTick(newPercent);
    setState(() => _visualPercent = newPercent);
  }

  /// Fires haptic + onChanged once each time the indicator crosses a tick.
  void _crossTick(double newPercent) {
    final idx = (newPercent * (widget.config.stopCount - 1)).round().clamp(
      0,
      widget.config.stopCount - 1,
    );
    if (idx != _lastTickIndex) {
      _lastTickIndex = idx;
      HapticFeedback.heavyImpact();
      widget.onChanged(widget.config.stops[idx]);
    }
  }

  void _trackVelocity(double delta) {
    final now = DateTime.now();
    if (_lastDragTime != null) {
      final dt = now.difference(_lastDragTime!).inMilliseconds / 1000;
      if (dt > 0) _velocity = delta / dt;
    }
    _lastDragTime = now;
  }

  void _onDragEnd() {
    if (widget.enableInertia && _velocity.abs() >= 0.5) {
      _startInertia();
    } else {
      setState(_snapToNearest);
    }
  }

  // ── Snap ───────────────────────────────────────────────────────────────────

  /// Snaps to nearest tick. Always nearest — velocity-direction snapping is
  /// unreliable because finger-lift velocity is noisy.
  void _snapToNearest() {
    final idx = (_visualPercent * (widget.config.stopCount - 1)).round().clamp(
      0,
      widget.config.stopCount - 1,
    );
    _visualPercent = widget.config.indexToPercent(idx);
    widget.onChanged(widget.config.stops[idx]);
  }

  // ── Inertia ────────────────────────────────────────────────────────────────

  void _startInertia() {
    const friction = 0.88;
    _inertiaTimer?.cancel();
    _inertiaTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _velocity *= friction;
      if (_velocity.abs() < 0.5) {
        _inertiaTimer?.cancel();
        setState(_snapToNearest);
        return;
      }
      _updateDrag(_velocity * 0.016);
    });
  }

  @override
  void dispose() {
    _inertiaTimer?.cancel();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _kTotalHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Tick index 0 position in inner-zone local coordinates.
          // Pixel-aligned so each tick falls on a whole physical pixel —
          // prevents sub-pixel AA blur on vertical lines.
          final dpr = MediaQuery.of(context).devicePixelRatio;
          final rawOffset =
              constraints.maxWidth / 2 -
              _visualIndex * _kTickSpacing -
              _kIconPad;
          final rulerOffset = (rawOffset * dpr).roundToDouble() / dpr;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) {
              if (widget.enableInertia) _trackVelocity(d.delta.dx);
              _updateDrag(d.delta.dx);
            },
            onHorizontalDragEnd: (_) => _onDragEnd(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Ruler zone — clipped so ticks never render over end icons.
                Positioned(
                  left: _kIconPad,
                  right: _kIconPad,
                  top: 0,
                  bottom: 0,
                  child: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _TicksPainter(
                              config: widget.config,
                              rulerOffset: rulerOffset,
                              dpr: dpr,
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _LabelsPainter(
                                config: widget.config,
                                visualIndex: _visualIndex,
                                rulerOffset: rulerOffset,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Centre indicator — bottom: 3 creates a small gap beneath ticks.
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

// ── Painters ──────────────────────────────────────────────────────────────────

/// Draws tick marks for all stops visible in the current viewport.
/// Per-tick alpha fade via [_edgeFade] keeps fading correct at min/max positions.
class _TicksPainter extends CustomPainter {
  final CameraDialConfig config;

  /// X position of tick index 0 in the inner-zone local coordinate space.
  final double rulerOffset;

  /// Device pixel ratio — snaps each tick x to a whole physical pixel.
  final double dpr;

  static const Color _tickColor = Color(0xFFD4847A);

  const _TicksPainter({
    required this.config,
    required this.rulerOffset,
    required this.dpr,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final n = config.stopCount;
    if (n < 2) return;

    // Tick strip bottom at _kTickTop + 16. Painting to size.height would clip
    // against the outer ClipRect at the widget's bottom edge.
    const double bottom = _kTickTop + 16.0;

    final int iFirst = ((-_kTickSpacing - rulerOffset) / _kTickSpacing)
        .floor()
        .clamp(0, n - 1);
    final int iLast =
        ((size.width + _kTickSpacing - rulerOffset) / _kTickSpacing)
            .ceil()
            .clamp(0, n - 1);

    final paint = Paint()..strokeCap = StrokeCap.round;

    for (int i = iFirst; i <= iLast; i++) {
      // Snap to whole physical pixel — integer columns, no AA blur.
      final double x =
          ((rulerOffset + i * _kTickSpacing) * dpr).roundToDouble() / dpr;

      final double fade = _edgeFade(x, size.width);
      if (fade <= 0) continue;

      final bool isMajor = i % config.majorTickEvery == 0;
      paint
        ..strokeWidth = isMajor ? 2.0 : 1.0
        ..color = _tickColor.withValues(alpha: (isMajor ? 0.85 : 0.45) * fade);

      canvas.drawLine(
        Offset(x, bottom),
        Offset(x, bottom - (isMajor ? 14.0 : 7.0)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TicksPainter old) =>
      old.rulerOffset != rulerOffset ||
      old.config.stopCount != config.stopCount ||
      old.config.majorTickEvery != config.majorTickEvery;
}

/// Capsule indicator anchored at the ruler's centre — marks the current value.
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

/// Draws the centre value label (large, bold) and up to 2 neighbouring major
/// tick labels on each side. Labels share the same edge fade as _TicksPainter.
class _LabelsPainter extends CustomPainter {
  final CameraDialConfig config;
  final double visualIndex;
  final double rulerOffset;

  // -6 px baseline offset so tall bold glyphs don't clip against the top
  // of the inner ClipRect.
  static const double _baselineOffset = -6.0;
  static const double _minGap = 18.0;
  static const int _maxPerSide = 2;

  const _LabelsPainter({
    required this.config,
    required this.visualIndex,
    required this.rulerOffset,
  });

  TextPainter _makeLabel(
    int idx,
    double x,
    double viewportWidth, {
    required bool isCenter,
  }) {
    final double fade = _edgeFade(x, viewportWidth);
    return TextPainter(
      text: TextSpan(
        text: config.format(config.stops[idx]),
        style: TextStyle(
          color: Colors.white.withValues(alpha: isCenter ? fade : 0.45 * fade),
          fontSize: isCenter ? 18.0 : 10.0,
          fontWeight: isCenter ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void _paint(Canvas canvas, TextPainter tp, double x) {
    tp.paint(
      canvas,
      Offset(x - tp.width / 2, _kTickTop + _baselineOffset - tp.height),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final int step = config.majorTickEvery;
    final int centerIdx = visualIndex.round().clamp(0, config.stopCount - 1);
    final double centerX = rulerOffset + visualIndex * _kTickSpacing;

    // Centre label — always rendered.
    final center = _makeLabel(centerIdx, centerX, size.width, isCenter: true);
    _paint(canvas, center, centerX);
    double rightBound = centerX + center.width / 2;
    double leftBound = centerX - center.width / 2;

    // Walk right — up to _maxPerSide labels.
    int drawnR = 0;
    for (
      int i = ((visualIndex / step).ceil() * step);
      i < config.stopCount && drawnR < _maxPerSide;
      i += step
    ) {
      final double x = rulerOffset + i * _kTickSpacing;
      if (x > size.width + 60) break;
      final tp = _makeLabel(i, x, size.width, isCenter: false);
      if (x - tp.width / 2 - rightBound >= _minGap) {
        _paint(canvas, tp, x);
        rightBound = x + tp.width / 2;
        drawnR++;
      }
    }

    // Walk left — up to _maxPerSide labels.
    int drawnL = 0;
    for (
      int i = ((visualIndex / step).floor() * step);
      i >= 0 && drawnL < _maxPerSide;
      i -= step
    ) {
      if (i == centerIdx) continue;
      final double x = rulerOffset + i * _kTickSpacing;
      if (x < -60) break;
      final tp = _makeLabel(i, x, size.width, isCenter: false);
      if (leftBound - (x + tp.width / 2) >= _minGap) {
        _paint(canvas, tp, x);
        leftBound = x - tp.width / 2;
        drawnL++;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LabelsPainter old) =>
      old.visualIndex != visualIndex || old.rulerOffset != rulerOffset;
}
