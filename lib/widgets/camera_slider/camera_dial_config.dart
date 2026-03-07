import 'dart:math';

typedef DialFormatter = String Function(double value);

class CameraDialConfig {
  final double min;
  final double max;

  final int ticks;
  final int majorTickEvery;

  final bool logarithmic;
  final bool clamp;

  final List<double>? stops;

  final DialFormatter? formatter;

  const CameraDialConfig({
    required this.min,
    required this.max,
    this.ticks = 120,
    this.majorTickEvery = 10,
    this.logarithmic = false,
    this.clamp = true,
    this.stops,
    this.formatter,
  });

  bool get isDiscrete => stops != null && stops!.isNotEmpty;

  double percentToValue(double p) {
    if (isDiscrete) {
      final index = (p * (stops!.length - 1)).round();
      return stops![index];
    }

    if (!logarithmic) {
      return min + p * (max - min);
    }

    return min * pow(max / min, p);
  }

  double valueToPercent(double v) {
    if (isDiscrete) {
      int closest = 0;
      double best = double.infinity;

      for (int i = 0; i < stops!.length; i++) {
        final d = (stops![i] - v).abs();
        if (d < best) {
          best = d;
          closest = i;
        }
      }

      return closest / (stops!.length - 1);
    }

    if (!logarithmic) {
      return (v - min) / (max - min);
    }

    return log(v / min) / log(max / min);
  }

  String format(double v) {
    if (formatter != null) {
      return formatter!(v);
    }

    if (v >= 1) {
      return v.toStringAsFixed(0);
    }

    return "1/${(1 / v).round()}";
  }
}
