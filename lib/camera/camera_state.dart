// lib/camera/camera_state.dart
//
// Immutable data classes that group camera-related models into coherent objects:
//
//   CameraValues  — user-controllable current values (changes on every slider drag)
//   CameraRanges  — device capabilities (set once at startup, immutable after)
//   CameraInfo    — read-only telemetry from the EventChannel
//   CameraCallbacks — bundled action callbacks for widgets
//   CameraSettingType — shared identifier for adjustable camera controls

import 'package:flutter/foundation.dart' show VoidCallback;

// ─── CameraSettingType enum ────────────────────────────────────────────────────────

/// Shared identifier for the adjustable camera controls used by the UI.
///
/// Keep this enum lightweight: presentation metadata such as labels, icons,
/// and auto/manual affordances belongs in the widgets that render the control.
enum CameraSettingType { iso, shutter, focus, wb, zoom }

// ─── CameraValues ─────────────────────────────────────────────────────────────

/// Current user-controlled camera values.
///
/// Immutable — use [copyWith] inside `setState` to update.
class CameraValues {
  const CameraValues({
    this.isoValue = 200,
    this.exposureTimeNs = 1000000,
    this.focusDistance = 0.0,
    this.zoomRatio = 1.0,
    this.afEnabled = true,
    this.wbLocked = false,
  });

  final int isoValue;
  final int exposureTimeNs; // nanoseconds
  final double focusDistance; // diopters
  final double zoomRatio;
  final bool afEnabled;
  final bool wbLocked;

  /// Compute sensible initial values from device-reported [ranges].
  ///
  /// This is the **single source of truth** for what the camera starts with.
  /// Edit defaults here — not scattered across `_startCamera()`.
  factory CameraValues.initialFromRanges(CameraRanges ranges) {
    return CameraValues(
      isoValue: 800.clamp(ranges.isoRange[0], ranges.isoRange[1]),
      exposureTimeNs: 20000000.clamp(
        ranges.exposureTimeRangeNs[0],
        ranges.exposureTimeRangeNs[1],
      ),
      // Focus starts near infinity (0.0 diopters). AF is enabled at startup so this
      // value is unused until the user disables AF. Starting near ∞ avoids any
      // abrupt lens movement when AF is first toggled off.
      focusDistance: 0.1,
      zoomRatio: ranges.minZoomRatio,
      afEnabled: true,
      wbLocked: false,
    );
  }

  CameraValues copyWith({
    int? isoValue,
    int? exposureTimeNs,
    double? focusDistance,
    double? zoomRatio,
    bool? afEnabled,
    bool? wbLocked,
  }) {
    return CameraValues(
      isoValue: isoValue ?? this.isoValue,
      exposureTimeNs: exposureTimeNs ?? this.exposureTimeNs,
      focusDistance: focusDistance ?? this.focusDistance,
      zoomRatio: zoomRatio ?? this.zoomRatio,
      afEnabled: afEnabled ?? this.afEnabled,
      wbLocked: wbLocked ?? this.wbLocked,
    );
  }
}

// ─── CameraRanges ─────────────────────────────────────────────────────────────

/// Device capability ranges — set once after camera start, never mutated.
class CameraRanges {
  const CameraRanges({
    this.isoRange = const [100, 3200],
    this.exposureTimeRangeNs = const [1000000, 1000000000],
    this.minFocusDistance = 0.0,
    this.minZoomRatio = 1.0,
    this.maxZoomRatio = 1.0,
  });

  final List<int> isoRange; // [min, max]
  final List<int> exposureTimeRangeNs; // [min, max] in nanoseconds
  // Camera2's LENS_INFO_MINIMUM_FOCUS_DISTANCE: the closest focus the lens
  // can achieve, in diopters (= 1/metres). Higher value = closer focus.
  // 0.0 = fixed-focus at infinity. Valid focus range is [0.0, minFocusDistance].
  final double minFocusDistance;
  final double minZoomRatio;
  final double maxZoomRatio;
}

// ─── CameraInfo ───────────────────────────────────────────────────────────────

/// Read-only camera telemetry updated by the EventChannel.
class CameraInfo {
  const CameraInfo({
    this.frameCount = 0,
    this.fps = 0.0,
    this.captureResolution = '--',
    this.analysisResolution = '--',
  });

  final int frameCount;
  final double fps;
  final String captureResolution;
  final String analysisResolution;

  CameraInfo copyWith({
    int? frameCount,
    double? fps,
    String? captureResolution,
    String? analysisResolution,
  }) {
    return CameraInfo(
      frameCount: frameCount ?? this.frameCount,
      fps: fps ?? this.fps,
      captureResolution: captureResolution ?? this.captureResolution,
      analysisResolution: analysisResolution ?? this.analysisResolution,
    );
  }
}

// ─── CameraCallbacks ──────────────────────────────────────────────────────────

/// Bundled camera-action callbacks passed to child widgets.
///
/// Grouping them here keeps widget constructors slim — widgets accept a single
/// [CameraCallbacks] instead of 7+ individual function parameters.
class CameraCallbacks {
  const CameraCallbacks({
    required this.onIsoChanged,
    required this.onExposureTimeNsChanged,
    required this.onFocusChanged,
    required this.onZoomChanged,
    required this.onLockWb,
    required this.onUnlockWb,
    required this.onToggleAf,
  });

  final void Function(int iso) onIsoChanged;
  final void Function(int ns) onExposureTimeNsChanged;
  final void Function(double dist) onFocusChanged;
  final void Function(double ratio) onZoomChanged;
  final VoidCallback onLockWb;
  final VoidCallback onUnlockWb;
  final VoidCallback onToggleAf;
}
