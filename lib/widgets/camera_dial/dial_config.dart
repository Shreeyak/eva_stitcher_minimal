// lib/widgets/camera_dial/dial_config.dart
//
// DialConfig defines the value mapping for a CameraDial — it knows nothing
// about drawing or gestures. Its only job is to translate between the dial's
// internal [0..1] "percent" space and the physical camera unit (ISO, ns, etc.).
//
// Two value‐mapping modes are supported:
//
//   Linear   — value = min + percent * (max − min)
//   Logarithmic — value = min * (max/min)^percent
//               The log mode is essential for camera quantities that span
//               several orders of magnitude (ISO 100→6400, shutter 1/8000→1s).
//               Equal "arc distance" = equal *ratio* of values, which matches
//               how photographers perceive exposure steps.

import 'dart:math' as math;

// ─── CameraParam enum ────────────────────────────────────────────────────────

/// The set of adjustable camera parameters shown in the settings drawer.
/// Each variant corresponds to one icon tab and one [DialConfig] preset.
enum CameraParam {
  iso,
  shutter,
  focus,
  wb,
  zoom;

  /// Short label shown above the dial and in the icon tab.
  String get label {
    switch (this) {
      case CameraParam.iso:
        return 'ISO';
      case CameraParam.shutter:
        return 'SHUTTER';
      case CameraParam.focus:
        return 'FOCUS';
      case CameraParam.wb:
        return 'WB';
      case CameraParam.zoom:
        return 'ZOOM';
    }
  }

  /// True when this parameter has an "Auto / Manual" toggle.
  bool get hasAutoMode {
    switch (this) {
      case CameraParam.focus:
        return true; // AF on/off
      case CameraParam.wb:
        return true; // AWB lock
      case CameraParam.iso:
      case CameraParam.shutter:
      case CameraParam.zoom:
        return false;
    }
  }
}

// ─── DialConfig ──────────────────────────────────────────────────────────────

/// Immutable configuration for one CameraDial instance.
///
/// [min] / [max] — physical value range (e.g. 100–6400 for ISO).
/// [ticks]       — total number of tick marks around the arc.
///                 More ticks = finer granularity, more draw calls.
/// [majorTickEvery] — every Nth tick is drawn as a "major" tick (taller,
///                 labeled). E.g. majorTickEvery=10 means every 10th tick is
///                 labeled (so 60 ticks / 10 = 6 labels visible).
/// [logarithmic] — when true, equal arc distance = equal *ratio* of values.
/// [formatValue] — converts a raw value to a display string.
class DialConfig {
  const DialConfig({
    required this.min,
    required this.max,
    required this.ticks,
    required this.majorTickEvery,
    this.logarithmic = false,
    this.formatValue,
  }) : assert(min < max, 'min must be less than max'),
       assert(ticks > 0, 'ticks must be positive'),
       assert(majorTickEvery > 0 && majorTickEvery <= ticks);

  final double min;
  final double max;
  final int ticks;
  final int majorTickEvery;
  final bool logarithmic;

  /// Optional custom formatter. If null, a sensible default is used by the
  /// painter based on the value magnitude.
  final String Function(double value)? formatValue;

  // ── Value ↔ Percent conversions ─────────────────────────────────────────

  /// Maps [percent] ∈ [0, 1] → physical value in [min, max].
  ///
  /// Linear:  value = min + p * (max − min)
  /// Log:     value = min * (max/min)^p
  ///          Equivalent to exp(log(min) + p * log(max/min))
  double percentToValue(double percent) {
    final p = percent.clamp(0.0, 1.0);
    if (!logarithmic) {
      return min + p * (max - min);
    }
    // Avoids division-by-zero: both min and max must be > 0 for log mode.
    return min * math.pow(max / min, p);
  }

  /// Maps a physical [value] → percent ∈ [0, 1].
  ///
  /// Inverse of [percentToValue].
  double valueToPercent(double value) {
    final v = value.clamp(min, max);
    if (!logarithmic) {
      return (v - min) / (max - min);
    }
    return math.log(v / min) / math.log(max / min);
  }

  // ── Named presets ────────────────────────────────────────────────────────

  /// ISO sensitivity: logarithmic 100–6400, 60 ticks (every 10th labeled).
  /// Log scale because photographers think in stops (×2): 100→200→400→800→…
  static DialConfig iso({double min = 100, double max = 6400}) {
    return DialConfig(
      min: min,
      max: max,
      ticks: 60,
      majorTickEvery: 10,
      logarithmic: true,
      formatValue: (v) => v.round().toString(),
    );
  }

  /// Shutter speed in nanoseconds: logarithmic 1/8000s (125 000 ns) → 1s.
  /// Log scale because exposure stops are multiplicative.
  /// Default range covers most camera sensors; pass device range at runtime.
  static DialConfig shutter({
    double minNs = 125000, // ≈ 1/8000 s
    double maxNs = 1000000000, // 1 s
  }) {
    return DialConfig(
      min: minNs,
      max: maxNs,
      ticks: 100,
      majorTickEvery: 10,
      logarithmic: true,
      formatValue: (v) {
        // Display as "1/N" for short exposures, "N.Ns" for long ones.
        final secs = v / 1e9;
        if (secs < 1.0) {
          final denom = (1.0 / secs).round();
          return '1/$denom';
        }
        return '${secs.toStringAsFixed(1)}s';
      },
    );
  }

  /// EV / exposure compensation: linear −4 → +4, 80 ticks (every 8th labeled).
  /// Linear because EV offsets are additive in log-exposure space.
  static DialConfig ev({double min = -4.0, double max = 4.0}) {
    return DialConfig(
      min: min,
      max: max,
      ticks: 80,
      majorTickEvery: 8,
      logarithmic: false,
      formatValue: (v) {
        final sign = v >= 0 ? '+' : '';
        return '$sign${v.toStringAsFixed(1)}';
      },
    );
  }

  /// Focus distance in diopters (1/m): logarithmic from macro to infinity.
  /// [minDiopters] is the reciprocal of the camera's minimum focus distance
  /// in metres (a higher diopter = closer focus). A value of 0.1 corresponds
  /// to ~10m away, near enough to "infinity" for most WSI use cases.
  static DialConfig focus({
    double minDiopters = 0.1,
    double maxDiopters = 10.0,
  }) {
    return DialConfig(
      min: minDiopters,
      max: maxDiopters,
      ticks: 150,
      majorTickEvery: 15,
      logarithmic: true,
      formatValue: (v) {
        final metres = 1.0 / v;
        if (metres >= 100) return '∞';
        if (metres >= 1.0) return '${metres.toStringAsFixed(1)}m';
        return '${(metres * 100).round()}cm';
      },
    );
  }

  /// Optical zoom ratio: logarithmic 1× → maxZoom.
  static DialConfig zoom({double min = 1.0, double max = 10.0}) {
    return DialConfig(
      min: min,
      max: max,
      ticks: 120,
      majorTickEvery: 10,
      logarithmic: true,
      formatValue: (v) => '${v.toStringAsFixed(1)}×',
    );
  }

  /// White-balance color temperature in Kelvin: linear 2000K–8000K.
  /// (Used only as a reference; WB is typically locked from live CCM capture,
  /// so this dial shows approximate Kelvin for display purposes.)
  static DialConfig wb({double min = 2000, double max = 8000}) {
    return DialConfig(
      min: min,
      max: max,
      ticks: 60,
      majorTickEvery: 6,
      logarithmic: false,
      formatValue: (v) => '${v.round()}K',
    );
  }
}
