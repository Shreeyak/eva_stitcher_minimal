// lib/widgets/camera_dial/camera_dial.dart
//
// CameraDial — a compact, reusable half-arc camera control.
//
// Layout:
//   The dial renders a fixed-size [SizedBox] whose dimensions are computed
//   from [radius] via [dialWidthForRadius] / [dialHeightForRadius].  The
//   default radius (90) produces a ~268 × 144 px widget — much smaller than
//   the full-screen width it would otherwise occupy.
//
// Interaction model:
//   • Pan left/right to move the indicator along the arc.
//   • Velocity on release launches an inertia scroll that decays with
//     friction (configurable via [kFriction]).
//   • Once the dial comes to rest it snaps to the nearest tick position.
//   • HapticFeedback.selectionClick() fires each time the indicator crosses
//     a tick boundary during drag or inertia.
//
// Value flow:
//   CameraDial holds its own [_percent] state for smooth animation, but
//   reports settled values upward via [onChanged].  The parent owns the
//   authoritative value: if it provides a new [value] while the dial is
//   idle, the dial animates to the new position.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dial_config.dart';
import 'dial_painter.dart';

export 'dial_config.dart';
export 'dial_painter.dart';

// ── Inertia constants ─────────────────────────────────────────────────────────

/// Friction multiplier applied every 16 ms frame during inertia scroll.
/// 0.92 ≈ the value referenced in the arc-dial design spec (slider-ticks.md).
/// Lower = more friction (stops faster). Higher = more coast.
const double kFriction = 0.92;

/// Inertia tick interval in milliseconds (approximately 60 fps).
const int _kInertiaIntervalMs = 16;

/// Stop inertia once velocity falls below this threshold (percent/second).
const double _kVelocityStopThreshold = 0.002;

// ── Snapping ─────────────────────────────────────────────────────────────────

/// Fractional tolerance for snapping: the dial snaps if within this many
/// tick-widths of a tick position.  1.0 means always snap to the nearest tick.
const double _kSnapTolerance = 1.0;

// ─── CameraDial ──────────────────────────────────────────────────────────────

/// A reusable half-arc dial for adjusting a single camera parameter.
///
/// Example usage (ISO control in a Stack):
/// ```dart
/// CameraDial(
///   config: DialConfig.iso(min: isoRange[0].toDouble(), max: isoRange[1].toDouble()),
///   value: _isoValue.toDouble(),
///   onChanged: (v) => _onIsoChanged(v.round()),
///   label: 'ISO',
///   radius: 90,
/// )
/// ```
class CameraDial extends StatefulWidget {
  const CameraDial({
    super.key,
    required this.config,
    required this.value,
    required this.onChanged,
    this.label = '',
    this.radius = 90.0,
  });

  /// Configuration: value range, tick count, log/linear, formatter.
  final DialConfig config;

  /// Current authoritative value (in physical units, e.g. ISO 400).
  /// When this changes externally while the dial is idle, the dial jumps
  /// to the new position.
  final double value;

  /// Called with the new physical value whenever the dial settles
  /// (on pan-end + snap, or when inertia stops + snaps).
  final ValueChanged<double> onChanged;

  /// Short label shown above the arc (e.g. "ISO", "SHUTTER").
  final String label;

  /// Arc radius in logical pixels.  Determines the overall size of the widget.
  /// Default 90.0 → widget ≈ 268 × 144 px.
  final double radius;

  @override
  State<CameraDial> createState() => _CameraDialState();
}

class _CameraDialState extends State<CameraDial> {
  // ── Dial state ────────────────────────────────────────────────────────────

  /// Current indicator position in [0, 1].
  late double _percent;

  /// Last tick index the indicator passed through.  Used to fire haptic
  /// feedback exactly once per tick boundary crossing.
  late int _lastTickIndex;

  // ── Drag state ────────────────────────────────────────────────────────────

  bool _isDragging = false;

  /// Angle (radians) from the arc center to the touch point at the previous
  /// pan event.  Used to compute angular delta each frame.
  double _lastPanAngle = 0.0;

  // ── Inertia state ─────────────────────────────────────────────────────────

  /// Current inertia velocity in percent/second.
  double _velocityPercent = 0.0;

  Timer? _inertiaTimer;

  // ── Geometry helpers ─────────────────────────────────────────────────────

  // Arc sweep angle — must match DialPainter.
  // startAngle=π (left / 9-o'clock), sweepAngle=π (clockwise to 3 o'clock).
  static const double _sweepAngle = math.pi;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _percent = widget.config.valueToPercent(widget.value).clamp(0.0, 1.0);
    _lastTickIndex = (_percent * widget.config.ticks).round();
  }

  /// Sync external value changes into the dial when the user is not dragging.
  @override
  void didUpdateWidget(CameraDial old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_isDragging) {
      final newPercent = widget.config
          .valueToPercent(widget.value)
          .clamp(0.0, 1.0);
      if ((newPercent - _percent).abs() > 1e-6) {
        setState(() {
          _percent = newPercent;
          _lastTickIndex = (_percent * widget.config.ticks).round();
        });
      }
    }
  }

  @override
  void dispose() {
    _inertiaTimer?.cancel();
    super.dispose();
  }

  // ── Gesture handlers ──────────────────────────────────────────────────────

  /// Compute the angle (radians, range [−π, π]) from the arc center to the
  /// given local touch position.
  double _angleFromTouch(Offset localPos, BoxConstraints constraints) {
    final cx = constraints.maxWidth / 2.0;
    const cy = 10.0; // must match _kArcTopPad in dial_painter.dart
    return math.atan2(localPos.dy - cy, localPos.dx - cx);
  }

  void _handlePanStart(DragStartDetails details, BoxConstraints constraints) {
    _inertiaTimer?.cancel();
    _inertiaTimer = null;
    _isDragging = true;
    _velocityPercent = 0.0;

    // Capture initial angle for delta computation on each update.
    final box = context.findRenderObject() as RenderBox;
    final local = box.globalToLocal(details.globalPosition);
    _lastPanAngle = _angleFromTouch(local, constraints);
  }

  void _handlePanUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (!_isDragging) return;

    final box = context.findRenderObject() as RenderBox;
    final local = box.globalToLocal(details.globalPosition);
    final angle = _angleFromTouch(local, constraints);

    // Compute angular delta, wrapping the atan2 discontinuity at ±π.
    //
    // Why: atan2 jumps from +π to −π (or vice-versa) when the touch crosses
    // the negative-x axis.  For the bottom-half arc this rarely happens
    // (only at the extreme left edge), but we guard anyway.
    double deltaAngle = angle - _lastPanAngle;
    if (deltaAngle > math.pi) deltaAngle -= 2 * math.pi;
    if (deltaAngle < -math.pi) deltaAngle += 2 * math.pi;

    // The sweep of our arc is π radians = 100% of the dial range.
    // Dragging the full arc width = deltaAngle=π → deltaPercent=1.0.
    //
    // Note: going clockwise (downward on touch) DECREASES atan2.
    // Our arc goes clockwise from left→bottom→right = 0%→100%.
    // So a clockwise drag (negative deltaAngle) should INCREASE percent.
    final deltaPercent = -deltaAngle / _sweepAngle;

    final newPercent = (_percent + deltaPercent).clamp(0.0, 1.0);

    // Haptic: fire once when crossing a tick boundary.
    _checkTickCrossing(newPercent);

    // Track velocity for inertia on release.
    // Simple 1-frame instantaneous velocity estimate (percent/second).
    // More accurate: accumulate over multiple frames, but this is sufficient.
    if (details.sourceTimeStamp != null) {
      final dtSec = details.sourceTimeStamp!.inMicroseconds / 1e6;
      if (dtSec > 0) {
        _velocityPercent = deltaPercent / (dtSec.clamp(0.001, 0.1));
      }
    }

    setState(() {
      _percent = newPercent;
      _lastPanAngle = angle;
    });
  }

  void _handlePanEnd(DragEndDetails details, BoxConstraints constraints) {
    _isDragging = false;

    // Convert Flutter's pixel velocity → percent velocity.
    // Arc length for full sweep = π × radius.  Dragging the full arc width
    // in pixels = sweeping the full percent range.
    final radius = constraints.maxWidth / 2.0 - 44.0; // matches _kHorizPad
    final arcLength = math.pi * radius;
    final pixelVx = details.velocity.pixelsPerSecond.dx;

    // Negative because rightward drag (positive x) decreases atan2 angle
    // (clockwise = increasing percent).
    _velocityPercent = -pixelVx / arcLength;

    _startInertia();
  }

  // ── Inertia ───────────────────────────────────────────────────────────────

  /// Launches a periodic timer that decays [_velocityPercent] by [kFriction]
  /// each frame (~60 fps) and moves [_percent] accordingly.
  ///
  /// When velocity falls below [_kVelocityStopThreshold] the timer stops and
  /// the dial is snapped to the nearest tick.
  void _startInertia() {
    _inertiaTimer?.cancel();
    _inertiaTimer = Timer.periodic(
      const Duration(milliseconds: _kInertiaIntervalMs),
      (timer) {
        // Apply friction
        _velocityPercent *= kFriction;

        if (_velocityPercent.abs() < _kVelocityStopThreshold) {
          timer.cancel();
          _inertiaTimer = null;
          _snapToNearestTick();
          return;
        }

        final dt = _kInertiaIntervalMs / 1000.0; // seconds per frame
        final newPercent = (_percent + _velocityPercent * dt).clamp(0.0, 1.0);

        _checkTickCrossing(newPercent);

        setState(() => _percent = newPercent);

        // If we've hit an endpoint, kill velocity and snap immediately.
        if (_percent == 0.0 || _percent == 1.0) {
          timer.cancel();
          _inertiaTimer = null;
          _snapToNearestTick();
        }
      },
    );
  }

  // ── Snapping ──────────────────────────────────────────────────────────────

  /// Snaps [_percent] to the nearest tick position if within [_kSnapTolerance]
  /// tick-widths, then calls [onChanged] with the resulting physical value.
  void _snapToNearestTick() {
    final tickStep = 1.0 / widget.config.ticks;
    final tickIndex = (_percent / tickStep).round();
    final snappedPercent = (tickIndex * tickStep).clamp(0.0, 1.0);

    if ((_percent - snappedPercent).abs() < tickStep * _kSnapTolerance) {
      setState(() => _percent = snappedPercent);
    }

    // Report the settled value to the parent.
    final settledValue = widget.config.percentToValue(_percent);
    widget.onChanged(settledValue);
  }

  // ── Haptic feedback ───────────────────────────────────────────────────────

  /// Fires [HapticFeedback.selectionClick] exactly once per tick boundary
  /// crossing.  [newPercent] is the about-to-be-applied position.
  void _checkTickCrossing(double newPercent) {
    final newTickIndex = (newPercent * widget.config.ticks).round();
    if (newTickIndex != _lastTickIndex) {
      _lastTickIndex = newTickIndex;
      HapticFeedback.selectionClick();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dialW = dialWidthForRadius(widget.radius);
        final dialH = dialHeightForRadius(widget.radius);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Current value read-out ───────────────────────────────────────
            _ValueReadout(
              config: widget.config,
              percent: _percent,
              label: widget.label,
            ),
            const SizedBox(height: 4),

            // ── Arc dial with gesture detection ────────────────────────────
            GestureDetector(
              onPanStart: (d) => _handlePanStart(d, constraints),
              onPanUpdate: (d) => _handlePanUpdate(d, constraints),
              onPanEnd: (d) => _handlePanEnd(d, constraints),
              child: SizedBox(
                width: dialW,
                height: dialH,
                child: CustomPaint(
                  painter: DialPainter(
                    percent: _percent,
                    config: widget.config,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── _ValueReadout ────────────────────────────────────────────────────────────

/// A small read-out bar above the dial showing the label and current value.
///
/// Kept separate so it can have its own repaint scope: when [percent] changes
/// only this widget and the CustomPaint repaint; nothing else in the tree does.
class _ValueReadout extends StatelessWidget {
  const _ValueReadout({
    required this.config,
    required this.percent,
    required this.label,
  });

  final DialConfig config;
  final double percent;
  final String label;

  @override
  Widget build(BuildContext context) {
    final rawValue = config.percentToValue(percent);
    final displayValue = config.formatValue != null
        ? config.formatValue!(rawValue)
        : rawValue.toStringAsFixed(1);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Parameter label
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF78909C), // kTextMuted
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(width: 8),
        // Current value — brighter, accent color
        Text(
          displayValue,
          style: const TextStyle(
            color: Color(0xFFFF6D00), // kOrange
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
