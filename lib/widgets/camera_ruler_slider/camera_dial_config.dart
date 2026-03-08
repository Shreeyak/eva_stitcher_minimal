import 'package:flutter/material.dart';

/// Formatter for label rendering.
typedef DialFormatter = String Function(double value);

/// Configuration for a camera dial (ISO / shutter / zoom / focus).
///
/// Use the named factory constructors ([iso], [shutter], [zoom], [focus]) to
/// build a preconfigured dial from device capability ranges. Stop arrays and
/// formatters live here, not in the caller.
class CameraDialConfig {
  /// Discrete stops used by the dial.
  final List<double> stops;

  /// Index interval for major ticks.
  final int majorTickEvery;

  /// Optional label formatter. Falls back to [format]'s default when null.
  final DialFormatter? formatter;

  /// Left (minimum) and right (maximum) icons for the slider ends.
  final IconData leftIcon;
  final IconData rightIcon;

  /// Shared icon size for both ends (kept equal intentionally).
  final double iconSize;

  const CameraDialConfig({
    required this.stops,
    this.majorTickEvery = 1,
    this.formatter,
    this.leftIcon = Icons.remove,
    this.rightIcon = Icons.add,
    this.iconSize = 20,
  });

  // ── Named constructors ────────────────────────────────────────────────────

  /// ISO dial: ~1/6-stop spacing (geometric mean between each 1/3-stop pair).
  /// Full stops (50, 100, … 6400) land every 6 indices → [majorTickEvery] = 6.
  factory CameraDialConfig.iso({
    required double minIso,
    required double maxIso,
  }) {
    const all = <double>[
      50,
      57,
      64,
      72,
      80,
      90,
      100,
      112,
      125,
      141,
      160,
      179,
      200,
      224,
      250,
      283,
      320,
      358,
      400,
      447,
      500,
      566,
      640,
      716,
      800,
      894,
      1000,
      1118,
      1250,
      1414,
      1600,
      1789,
      2000,
      2236,
      2500,
      2828,
      3200,
      3578,
      4000,
      4472,
      5000,
      5657,
      6400,
    ];
    final stops = all.where((v) => v >= minIso && v <= maxIso).toList();
    return CameraDialConfig(
      stops: stops.isEmpty ? [minIso, maxIso] : stops,
      majorTickEvery: 6,
      formatter: (v) => v.round().toString(),
      leftIcon: Icons.brightness_5,
      rightIcon: Icons.brightness_7,
      iconSize: 20,
    );
  }

  /// Shutter dial: standard 1/3-stop values in nanoseconds, filtered to
  /// [minNs]..[maxNs]. [majorTickEvery] = 3 → major ticks on full stops.
  factory CameraDialConfig.shutter({
    required double minNs,
    required double maxNs,
  }) {
    const shutterSeconds = <double>[
      1 / 8000,
      1 / 6400,
      1 / 5000,
      1 / 4000,
      1 / 3200,
      1 / 2500,
      1 / 2000,
      1 / 1600,
      1 / 1250,
      1 / 1000,
      1 / 800,
      1 / 640,
      1 / 500,
      1 / 400,
      1 / 320,
      1 / 250,
      1 / 200,
      1 / 160,
      1 / 125,
      1 / 100,
      1 / 80,
      1 / 60,
      1 / 50,
      1 / 40,
      1 / 30,
      1 / 25,
      1 / 20,
      1 / 15,
    ];
    final allNs = shutterSeconds.map((s) => s * 1e9).toList();
    final stops = allNs.where((v) => v >= minNs && v <= maxNs).toList();
    return CameraDialConfig(
      stops: stops.isEmpty ? [minNs, maxNs] : stops,
      majorTickEvery: 3,
      formatter: (v) {
        final secs = v / 1e9;
        if (secs < 1.0) return '1/${(1.0 / secs).round()}';
        return '${secs.toStringAsFixed(1)}s';
      },
      leftIcon: Icons.shutter_speed,
      rightIcon: Icons.shutter_speed,
      iconSize: 20,
    );
  }

  /// Zoom dial: integer-anchored stops (1×, 2×, …) with one 0.5× intermediate.
  /// [majorTickEvery] = 2 → major ticks on integer zoom values.
  factory CameraDialConfig.zoom({
    required double zoomMin,
    required double zoomMax,
  }) {
    final double max = zoomMax > zoomMin + 0.05 ? zoomMax : zoomMin + 1.0;
    final int firstInt = zoomMin.ceil();
    final int lastInt = max.floor();
    final List<double> stops = [];
    if (zoomMin < firstInt - 0.02) stops.add(zoomMin);
    for (int z = firstInt; z <= lastInt; z++) {
      stops.add(z.toDouble());
      if (z < lastInt) stops.add(z + 0.5);
    }
    if (max > lastInt + 0.02) stops.add(max);
    if (stops.length < 2) stops.add(max);
    return CameraDialConfig(
      stops: stops,
      majorTickEvery: 2,
      formatter: (v) {
        if ((v - v.roundToDouble()).abs() < 0.05) return '${v.round()}×';
        return '${v.toStringAsFixed(1)}×';
      },
      leftIcon: Icons.zoom_out,
      rightIcon: Icons.zoom_in,
      iconSize: 20,
    );
  }

  /// Focus dial: perceptually-spaced diopter anchors with 2 linear
  /// intermediates between each. [majorTickEvery] = 3 → major ticks on anchors.
  ///
  /// [maxDiopter] is the device minimum focus distance in diopters. 0 = ∞.
  factory CameraDialConfig.focus({required double maxDiopter}) {
    final double max = maxDiopter > 0.05 ? maxDiopter : 10.0;
    const anchors = <double>[0.0, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 7.0, 10.0];
    final valid = anchors.where((d) => d <= max + 0.05).toList();
    if ((valid.last - max).abs() > 0.05) valid.add(max);
    final List<double> stops = [];
    for (int i = 0; i < valid.length; i++) {
      stops.add(valid[i]);
      if (i < valid.length - 1) {
        final a = valid[i], b = valid[i + 1];
        stops.add(a + (b - a) / 3.0);
        stops.add(a + (b - a) * 2.0 / 3.0);
      }
    }
    return CameraDialConfig(
      stops: stops,
      majorTickEvery: 3,
      formatter: (v) {
        if (v < 0.01) return '∞';
        final metres = 1.0 / v;
        if (metres >= 100) return '∞';
        if (metres >= 1.0) return '${metres.toStringAsFixed(1)}m';
        return '${(metres * 100).round()}cm';
      },
      leftIcon: Icons.center_focus_weak,
      rightIcon: Icons.center_focus_strong,
      iconSize: 20,
    );
  }

  // ── Instance methods ──────────────────────────────────────────────────────

  int get stopCount => stops.length;

  /// Convert stop index → percent.
  double indexToPercent(int index) => index / (stopCount - 1);

  /// Convert percent → stop index.
  int percentToIndex(double percent) => (percent * (stopCount - 1)).round();

  double percentToValue(double percent) => stops[percentToIndex(percent)];

  /// Returns the stop value closest to [value].
  double closestTo(double value) =>
      stops.reduce((a, b) => (a - value).abs() < (b - value).abs() ? a : b);

  /// Default label formatting (used when [formatter] is null).
  String format(double value) {
    if (formatter != null) return formatter!(value);
    if (value >= 1) return value.toStringAsFixed(0);
    final inv = 1 / value;
    if (inv > 100000) return '1/${(inv / 1000).round()}k';
    return '1/${inv.round()}';
  }
}
