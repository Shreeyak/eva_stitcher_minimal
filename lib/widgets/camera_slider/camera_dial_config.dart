import 'dart:math';

/// Formatter for label rendering
typedef DialFormatter = String Function(double value);

/// Configuration for a camera dial (ISO / shutter / zoom / focus)
class CameraDialConfig {
  /// Discrete stops used by the dial.
  /// Example ISO: [100,200,400,800,1600]
  /// Example shutter: [1/10,1/20,1/40,...]
  final List<double> stops;

  /// Index interval for major ticks
  final int majorTickEvery;

  /// Optional label formatter
  final DialFormatter? formatter;

  const CameraDialConfig({
    required this.stops,
    this.majorTickEvery = 1,
    this.formatter,
  });

  int get stopCount => stops.length;

  /// Convert stop index → percent
  double indexToPercent(int index) {
    return index / (stopCount - 1);
  }

  /// Convert percent → stop index
  int percentToIndex(double percent) {
    return (percent * (stopCount - 1)).round();
  }

  double percentToValue(double percent) {
    return stops[percentToIndex(percent)];
  }

  /// Default label formatting
  String format(double value) {
    if (formatter != null) {
      return formatter!(value);
    }

    if (value >= 1) {
      return value.toStringAsFixed(0);
    }

    final inv = 1 / value;

    if (inv > 100000) {
      return "1/${(inv / 1000).round()}k";
    }

    return "1/${inv.round()}";
  }
}
