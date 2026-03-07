// lib/widgets/camera_dial/dial_painter.dart
//
// DialPainter draws the half-arc dial onto a CustomPainter canvas.
//
// Arc geometry (matches Flutter canvas coordinate system):
//   • startAngle = π  →  3 o'clock is 0, so π = 9 o'clock (left side).
//   • sweepAngle = π  →  clockwise 180° sweep, ending at 2π = right side.
//   • The arc therefore sweeps through the BOTTOM of the circle.
//   • Arc center is placed at the top of the widget (y = arcTopPad), so the
//     visible half is the bottom semicircle that drops into the widget.
//
// What gets drawn, bottom to top in z-order:
//   1. Faint arc groove  — reference line of the arc
//   2. Active arc fill   — brighter segment from left end to the indicator
//   3. Tick marks        — minor (short) and major (taller) marks
//   4. Tick glow         — color interpolation creates a warm "halo" around
//                          the current indicator position
//   5. Major tick labels — value text at every [majorTickEvery]-th tick
//   6. Indicator knob    — filled circle on the arc at the current position

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'dial_config.dart';

// ── Layout constants ─────────────────────────────────────────────────────────

/// Top padding: space between the widget's top edge and the arc center.
/// A small pad (not zero) lets the indicator circle at the extreme left/right
/// positions appear fully instead of half-clipped.
const double _kArcTopPad = 10.0;

/// Horizontal padding on each side of the widget, around the arc endpoints.
/// Must accommodate outer tick length + label gap + widest label text.
const double _kHorizPad = 44.0;

/// Vertical padding below the arc center (i.e., below the lowest point of the
/// arc). Must fit the tick protrusion plus label text.
/// bottom_edge = arcTopPad + radius + kVertPad
const double _kVertPad = 44.0;

// ── Tick geometry ─────────────────────────────────────────────────────────────

/// Minor ticks are drawn as short exterior marks on the arc.
const double _kMinorTickLen = 7.0;

/// Major ticks (every [DialConfig.majorTickEvery]-th tick) are drawn taller.
const double _kMajorTickLen = 13.0;

/// Gap between the outer end of a major tick and its label text.
const double _kLabelGap = 5.0;

/// Font size for major-tick value labels.
const double _kLabelFontSize = 9.5;

// ── Indicator knob ───────────────────────────────────────────────────────────

/// Radius of the filled circle sitting on the arc at the current position.
const double _kKnobRadius = 5.5;

// ── Glow parameters ──────────────────────────────────────────────────────────

/// Decay exponent for the tick-glow falloff.
/// glow = exp(−|currentTick − thisTick| × kGlowDecay)
///
/// Interpretation: at this value (0.4), one tick away from the indicator
/// has glow ≈ 0.67, five ticks away ≈ 0.14, ten ticks away ≈ 0.02.
/// The result is a soft halo of ±5–8 ticks around the indicator position.
const double _kGlowDecay = 0.4;

/// Color of a tick at the exact indicator position (full glow).
const Color _kGlowColor = Color(0xFFFF6D00); // kOrange

/// Color of a completely un-glowing tick.
const Color _kTickColor = Color(0xFF37474F); // dim blue-grey

/// Color used for major tick labels (slightly brighter than tick color).
const Color _kLabelColor = Color(0xFF78909C);

// ─── DialPainter ─────────────────────────────────────────────────────────────

/// Paints the visual representation of a [CameraDial].
///
/// [percent]   — current indicator position in [0, 1] along the arc.
/// [config]    — dial configuration (tick count, log/linear, value formatter).
///
/// Lifecycle: a new instance is created on every widget rebuild, but
/// [shouldRepaint] ensures the canvas is only re-rasterised when [percent]
/// actually changes.
class DialPainter extends CustomPainter {
  const DialPainter({required this.percent, required this.config});

  final double percent;
  final DialConfig config;

  // ── shouldRepaint ──────────────────────────────────────────────────────────

  /// Re-paint only when the indicator position changes.
  /// Config changes never happen at runtime (a new Dial is created instead).
  @override
  bool shouldRepaint(DialPainter old) => old.percent != percent;

  // ── paint ─────────────────────────────────────────────────────────────────

  @override
  void paint(Canvas canvas, Size size) {
    // Arc geometry
    const startAngle = math.pi; // left endpoint  (9 o'clock)
    const sweepAngle = math.pi; // sweep clockwise to right endpoint (3 o'clock)
    final cx = size.width / 2;
    const cy = _kArcTopPad;

    // Radius derived from widget size (see CameraDial._dialWidth / _dialHeight)
    final radius = size.width / 2 - _kHorizPad;

    // Current indicator angle
    final indicatorAngle = startAngle + percent * sweepAngle;

    // ── 1. Arc groove ─────────────────────────────────────────────────────────
    final groovePaint = Paint()
      ..color =
          const Color(0xFF1A2A4A) // kBorderColor — subtle groove
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..isAntiAlias = true;

    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      startAngle,
      sweepAngle,
      false,
      groovePaint,
    );

    // ── 2. Active arc (from left to indicator) ───────────────────────────────
    final activePaint = Paint()
      ..color =
          const Color(0xFF1565C0) // deep blue highlight
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..isAntiAlias = true;

    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      startAngle,
      percent * sweepAngle,
      false,
      activePaint,
    );

    // ── 3 & 4. Tick marks with glow ───────────────────────────────────────────
    // currentTickIndex = fractional position in 0..ticks space
    final currentTickPos = percent * config.ticks;

    final tickPaint = Paint()
      ..strokeWidth = 1.0
      ..isAntiAlias = true;

    for (int i = 0; i <= config.ticks; i++) {
      final tickPercent = i / config.ticks;
      final theta = startAngle + tickPercent * sweepAngle;
      final isMajor = i % config.majorTickEvery == 0;

      // Glow: decays exponentially with tick distance from the indicator.
      // Unit: ticks (fractional). See _kGlowDecay for tuning notes.
      final distanceTicks = (currentTickPos - i).abs();
      final glow = math.exp(-distanceTicks * _kGlowDecay);

      final tickLen = isMajor ? _kMajorTickLen : _kMinorTickLen;
      final tickColor = Color.lerp(_kTickColor, _kGlowColor, glow)!;

      final cosT = math.cos(theta);
      final sinT = math.sin(theta);

      // Tick start: on the arc
      final x0 = cx + radius * cosT;
      final y0 = cy + radius * sinT;
      // Tick end: beyond the arc (exterior protrusion)
      final x1 = cx + (radius + tickLen) * cosT;
      final y1 = cy + (radius + tickLen) * sinT;

      tickPaint.color = tickColor;
      canvas.drawLine(Offset(x0, y0), Offset(x1, y1), tickPaint);

      // ── 5. Major tick labels ───────────────────────────────────────────────
      if (isMajor) {
        final rawValue = config.percentToValue(tickPercent);
        final labelText = config.formatValue != null
            ? config.formatValue!(rawValue)
            : _defaultFormat(rawValue);

        // Fade the label to match the tick glow (subtly, so all labels stay
        // legible but labels near the indicator pop slightly).
        final labelAlpha = (0.5 + 0.5 * glow).clamp(0.0, 1.0);
        final labelColor = _kLabelColor.withValues(alpha: labelAlpha);

        _drawLabel(
          canvas: canvas,
          text: labelText,
          color: labelColor,
          // Label center position: beyond the tick end by _kLabelGap
          cx: cx + (radius + tickLen + _kLabelGap) * cosT,
          cy: cy + (radius + tickLen + _kLabelGap) * sinT,
        );
      }
    }

    // ── 6. Indicator knob ─────────────────────────────────────────────────────
    final kx = cx + radius * math.cos(indicatorAngle);
    final ky = cy + radius * math.sin(indicatorAngle);

    // Soft glow shadow around the knob
    final shadowPaint = Paint()
      ..color = _kGlowColor.withValues(alpha: 0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);
    canvas.drawCircle(Offset(kx, ky), _kKnobRadius + 3, shadowPaint);

    // Filled accent knob
    final knobPaint = Paint()
      ..color = _kGlowColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(kx, ky), _kKnobRadius, knobPaint);

    // White outline edge — improves visibility against any background color
    final outlinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(Offset(kx, ky), _kKnobRadius, outlinePaint);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Fallback value formatter when [DialConfig.formatValue] is null.
  String _defaultFormat(double v) {
    if (v.abs() >= 1000) return v.round().toString();
    if (v.abs() >= 10) return v.toStringAsFixed(1);
    return v.toStringAsFixed(2);
  }

  /// Draws [text] centered at ([cx], [cy]).
  void _drawLabel({
    required Canvas canvas,
    required String text,
    required Color color,
    required double cx,
    required double cy,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: _kLabelFontSize,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.3,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    // Paint centered on the target point
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
  }
}

// ── Exterior size helpers (used by CameraDial to size its SizedBox) ───────────

/// Computes the total widget width for a dial with [radius].
double dialWidthForRadius(double radius) => 2 * (radius + _kHorizPad);

/// Computes the total widget height for a dial with [radius].
double dialHeightForRadius(double radius) => _kArcTopPad + radius + _kVertPad;
