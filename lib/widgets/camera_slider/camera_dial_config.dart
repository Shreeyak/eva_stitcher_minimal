import 'dart:math';

/// Example usage of CameraDialConfig:
/// ```dart
/// CameraRulerSlider(
///   config: CameraDialConfig(
///     min: 100,
///     max: 6400,
///     ticks: 60,
///     majorTickEvery: 6,
///     logarithmic: true,
///     clamp: true,
///   ),
///   initialValue: 400,
///   onChanged: (iso) {},
/// )
/// ```

/// Configuration for a camera dial widget.
///
/// Defines the range, scaling, and tick properties for a rotary dial control.
/// Supports both linear and logarithmic scaling modes.
class CameraDialConfig {
  /// Minimum value of the dial range.
  final double min;

  /// Maximum value of the dial range.
  final double max;

  /// Total number of tick marks on the dial.
  final int ticks;

  /// Interval at which major tick marks appear (every N ticks).
  final int majorTickEvery;

  /// If true: use logarithmic scaling; if false: use linear scaling.
  final bool logarithmic;

  /// If true: dial stops at min/max; if false: dial loops infinitely.
  final bool clamp;

  /// Optional custom formatter for major tick labels.
  final String Function(double value)? formatValue;

  /// Creates a [CameraDialConfig].
  ///
  /// The [min] and [max] parameters are required and define the value range.
  /// Other parameters have sensible defaults but can be customized.
  const CameraDialConfig({
    required this.min,
    required this.max,
    this.ticks = 120,
    this.majorTickEvery = 10,
    this.logarithmic = false,
    this.clamp = true,
    this.formatValue,
  });

  /// Converts a percentage (0.0 to 1.0) to a value in the configured range.
  ///
  /// Uses logarithmic or linear scaling based on the [logarithmic] flag.
  ///
  /// Parameters:
  ///   * [p]: A percentage value from 0.0 to 1.0.
  ///
  /// Returns: A value between [min] and [max].
  double percentToValue(double p) {
    if (!logarithmic) {
      return min + p * (max - min);
    }

    return min * pow(max / min, p).toDouble();
  }

  /// Converts a value in the configured range to a percentage (0.0 to 1.0).
  ///
  /// Uses logarithmic or linear scaling based on the [logarithmic] flag.
  ///
  /// Parameters:
  ///   * [v]: A value between [min] and [max].
  ///
  /// Returns: A percentage value from 0.0 to 1.0.
  double valueToPercent(double v) {
    if (!logarithmic) {
      return (v - min) / (max - min);
    }

    return log(v / min) / log(max / min);
  }
}
