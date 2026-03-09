import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../app_theme.dart';

bool _isNearInteger(double value, {double epsilon = 0.05}) {
  return (value - value.roundToDouble()).abs() < epsilon;
}

/// A horizontally scrollable ruler-style value picker.
///
/// Drag left/right to change [value] within [[min], [max]].
/// A fixed orange center marker shows the selected position.
/// Major ticks are drawn at every [step]; 4 minor ticks between each major.
class RulerPicker extends StatefulWidget {
  final double value;
  final double min;
  final double max;

  /// Snap interval — also the spacing between major ticks.
  final double step;

  /// Pixels per one [step] unit. Controls how "wide" the ruler feels.
  final double pixelsPerStep;

  final ValueChanged<double> onChanged;

  /// Formats a major-tick value for the label below it.
  final String Function(double) labelBuilder;

  const RulerPicker({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.labelBuilder,
    this.pixelsPerStep = 56.0,
  });

  @override
  State<RulerPicker> createState() => _RulerPickerState();
}

class _RulerPickerState extends State<RulerPicker> {
  late double _current;

  @override
  void initState() {
    super.initState();
    _current = widget.value;
  }

  @override
  void didUpdateWidget(RulerPicker old) {
    super.didUpdateWidget(old);
    // Accept external value changes (e.g. when auto mode writes a new value)
    if ((old.value - widget.value).abs() > 1e-9) {
      _current = widget.value;
    }
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final delta = -d.delta.dx / widget.pixelsPerStep * widget.step;
    final next = (_current + delta).clamp(widget.min, widget.max);
    setState(() => _current = next);
    widget.onChanged(next);
  }

  void _onDragEnd(DragEndDetails _) {
    // Snap to nearest step
    final steps = ((_current - widget.min) / widget.step).round();
    final snapped = (widget.min + steps * widget.step).clamp(
      widget.min,
      widget.max,
    );
    setState(() => _current = snapped);
    widget.onChanged(snapped);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      child: ClipRect(
        child: CustomPaint(
          painter: _RulerPainter(
            value: _current,
            min: widget.min,
            max: widget.max,
            step: widget.step,
            pixelsPerStep: widget.pixelsPerStep,
            labelBuilder: widget.labelBuilder,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

// ── Painter ─────────────────────────────────────────────────────────────

class _RulerPainter extends CustomPainter {
  final double value;
  final double min;
  final double max;
  final double step;
  final double pixelsPerStep;
  final String Function(double) labelBuilder;

  const _RulerPainter({
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.pixelsPerStep,
    required this.labelBuilder,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;

    // Paint definitions
    final majorTickPaint = Paint()
      ..color = kTextSecondary
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    final minorTickPaint = Paint()
      ..color = kTextMuted
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;

    final centerPaint = Paint()
      ..color = kOrange
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    const labelStyle = TextStyle(
      color: kTextSecondary,
      fontSize: 10,
      fontFamily: 'monospace',
    );

    // How many steps fit on screen
    final visibleSteps = (size.width / 2 / pixelsPerStep) + 2;

    // Range of major ticks to draw
    final firstMajor = ((value - visibleSteps * step) / step).floor() * step;
    final lastMajor = ((value + visibleSteps * step) / step).ceil() * step;

    // Minor ticks per major interval
    const minorCount = 4;
    final minorStep = step / (minorCount + 1);

    // Draw minor ticks
    var mt = firstMajor;
    while (mt <= lastMajor + minorStep * 0.5) {
      final x = cx + (mt - value) * (pixelsPerStep / step);
      if (x >= 0 && x <= size.width) {
        // skip positions that coincide with a major tick
        final tickIndex = (mt - min) / step;
        final isMajor = _isNearInteger(tickIndex);
        if (!isMajor) {
          canvas.drawLine(
            Offset(x, size.height * 0.15),
            Offset(x, size.height * 0.45),
            minorTickPaint,
          );
        }
      }
      mt += minorStep;
    }

    // Draw major ticks + labels
    var t = firstMajor;
    while (t <= lastMajor + step * 0.01) {
      if (t >= min - step * 0.5 && t <= max + step * 0.5) {
        final x = cx + (t - value) * (pixelsPerStep / step);
        if (x >= -pixelsPerStep && x <= size.width + pixelsPerStep) {
          // Tick
          canvas.drawLine(
            Offset(x, size.height * 0.08),
            Offset(x, size.height * 0.55),
            majorTickPaint,
          );

          // Label
          final label = labelBuilder(t.clamp(min, max));
          final tp = TextPainter(
            text: TextSpan(text: label, style: labelStyle),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: pixelsPerStep * 1.2);
          tp.paint(canvas, Offset(x - tp.width / 2, size.height * 0.60));
        }
      }
      t += step;
    }

    // Center marker (orange) — drawn on top
    final markerTop = 0.0;
    final markerBot = size.height * 0.58;
    canvas.drawLine(Offset(cx, markerTop), Offset(cx, markerBot), centerPaint);

    // Small orange triangle pointing down at center
    final tri = Path()
      ..moveTo(cx - 5, markerTop)
      ..lineTo(cx + 5, markerTop)
      ..lineTo(cx, markerTop + 8)
      ..close();
    canvas.drawPath(tri, Paint()..color = kOrange);

    // Current value label centered above ruler
    final currentLabel = labelBuilder(math.min(math.max(value, min), max));
    final tp = TextPainter(
      text: TextSpan(
        text: currentLabel,
        style: const TextStyle(
          color: kOrange,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // drawn at bottom center so it doesn't overlap ticks
    tp.paint(canvas, Offset(cx - tp.width / 2, size.height - tp.height - 2));
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.value != value ||
      old.min != min ||
      old.max != max ||
      old.step != step ||
      old.pixelsPerStep != pixelsPerStep ||
      old.labelBuilder != labelBuilder;
}
