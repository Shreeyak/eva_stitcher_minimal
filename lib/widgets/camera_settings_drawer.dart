// lib/widgets/camera_settings_drawer.dart
//
// CameraSettingsDrawer — a slim icon strip pinned to the bottom of the screen.
//
// Visual layout:
//
//   ┌─ Icon strip (52 px, shown when isOpen=true) ──────────────────────────┐
//   │  [ISO 400] [1/400] [FOC 2.5D] [WB auto] [1.0×]              [A/M]   │
//   └───────────────────────────────────────────────────────────────────────┘
//
// This widget contains NO slider or dial.
//
// Tapping any chip calls [onSettingChipTap] so the parent (main.dart) can
// position a floating [CameraRulerDial] overlay above the camera preview.
// Tapping the same chip again passes null → collapses the overlay.
//
// The [activeSetting] field (owned by the parent) is passed back in to highlight
// the active chip and to show/hide the A/M toggle for that setting.

import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../camera/camera_state.dart';

// ── Layout constants ──────────────────────────────────────────────────────────

/// Height of the icon-strip row.
const double _kStripHeight = 52.0;

// CameraSettingType enum lives in lib/camera/camera_state.dart.

// ── Icon map ──────────────────────────────────────────────────────────────────

/// Maps each [CameraSettingType] to a representative Material icon.
const _paramIcons = {
  CameraSettingType.iso: Icons.iso,
  CameraSettingType.shutter: Icons.shutter_speed,
  CameraSettingType.focus: Icons.center_focus_strong,
  CameraSettingType.wb: Icons.wb_auto,
  CameraSettingType.zoom: Icons.zoom_in,
};

/// Short labels shown in the chip row.
const _paramLabels = {
  CameraSettingType.iso: 'ISO',
  CameraSettingType.shutter: 'SHUTTER',
  CameraSettingType.focus: 'FOCUS',
  CameraSettingType.wb: 'WB',
  CameraSettingType.zoom: 'ZOOM',
};

// ─── CameraSettingsDrawer ─────────────────────────────────────────────────────

/// Slim icon-strip drawer for camera parameter selection.
///
/// This widget owns NO slider, dial, or expansion panel.  It only renders the
/// 52-px chip row and an A/M toggle.  All floating overlay logic lives in
/// main.dart's Stack.
///
/// ### Data flow
/// - Parent passes current values → used for chip sub-labels.
/// - Parent passes [activeSetting] → used to highlight the active chip.
/// - User taps chip → [onSettingChipTap] fires → parent updates [activeSetting].
class CameraSettingsDrawer extends StatelessWidget {
  const CameraSettingsDrawer({
    super.key,
    required this.isOpen,
    this.activeSetting,
    required this.onSettingChipTap,
    required this.values,
    required this.callbacks,
  });

  /// Whether the strip is shown at all (animates to height 0 when false).
  final bool isOpen;

  /// The currently active setting chip, or null if the overlay is closed.
  ///
  /// Controlled entirely by the parent. Used here only to highlight the
  /// corresponding chip and show/hide the A/M toggle button.
  final CameraSettingType? activeSetting;

  /// Called when the user taps a chip.
  ///
  /// Passes the tapped [CameraSettingType], or null if the same chip was tapped
  /// again (toggle-off).  The parent must call `setState` to update
  /// [activeSetting] in response.
  final ValueChanged<CameraSettingType?> onSettingChipTap;

  /// Current camera values — used for chip sub-labels and auto/manual state.
  final CameraValues values;

  /// Bundled action callbacks for AF toggle and WB lock/unlock.
  final CameraCallbacks callbacks;

  // ── Auto helpers ──────────────────────────────────────────────────────────

  /// True when [param] is currently controlled automatically by the camera.
  bool _isAuto(CameraSettingType param) {
    switch (param) {
      case CameraSettingType.focus:
        return values.afEnabled;
      case CameraSettingType.wb:
        return !values.wbLocked; // "auto" = AWB running (not locked)
      case CameraSettingType.iso:
      case CameraSettingType.shutter:
      case CameraSettingType.zoom:
        return false; // no auto mode for these
    }
  }

  /// Fires the correct toggle callback for [param].
  void _onAutoTap(CameraSettingType param) {
    switch (param) {
      case CameraSettingType.focus:
        callbacks.onToggleAf();
        break;
      case CameraSettingType.wb:
        values.wbLocked ? callbacks.onUnlockWb() : callbacks.onLockWb();
        break;
      case CameraSettingType.iso:
      case CameraSettingType.shutter:
      case CameraSettingType.zoom:
        break; // no-op
    }
  }

  /// True when [param] exposes an Auto / Manual toggle in the strip.
  bool _hasAutoMode(CameraSettingType param) {
    switch (param) {
      case CameraSettingType.focus:
      case CameraSettingType.wb:
        return true;
      case CameraSettingType.iso:
      case CameraSettingType.shutter:
      case CameraSettingType.zoom:
        return false;
    }
  }

  // ── Chip sub-label ────────────────────────────────────────────────────────

  /// Short value string shown beneath the chip icon.
  String _chipLabel(CameraSettingType param) {
    switch (param) {
      case CameraSettingType.iso:
        return values.isoValue.toString();

      case CameraSettingType.shutter:
        final secs = values.exposureTimeNs / 1e9;
        if (secs < 1.0) return '1/${(1.0 / secs).round()}';
        return '${secs.toStringAsFixed(1)}s';

      case CameraSettingType.focus:
        if (values.afEnabled) return 'AUTO';
        return '${values.focusDistance.toStringAsFixed(1)}D';

      case CameraSettingType.wb:
        return values.wbLocked ? 'LOCK' : 'AUTO';

      case CameraSettingType.zoom:
        return '${values.zoomRatio.toStringAsFixed(1)}×';
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: isOpen ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      child: SizedBox(height: _kStripHeight, child: _buildStrip()),
      builder: (context, factor, child) {
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: factor,
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildStrip() {
    return Container(
      color: kPanelColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1, thickness: 1, color: kBorderColor),
          Expanded(
            child: Row(
              children: [
                // ── Parameter chips (horizontally scrollable) ─────────────
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      children: CameraSettingType.values.map((p) {
                        return _ParamChip(
                          param: p,
                          icon: _paramIcons[p]!,
                          valueLabel: _chipLabel(p),
                          isActive: p == activeSetting,
                          isAuto: _isAuto(p),
                          onTap: () {
                            // Toggle: same chip → collapse overlay; other → open it.
                            onSettingChipTap(p == activeSetting ? null : p);
                          },
                        );
                      }).toList(),
                    ),
                  ),
                ),

                // ── Vertical separator ─────────────────────────────────────
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: kBorderColor,
                  indent: 8,
                  endIndent: 8,
                ),

                // ── Auto/Manual toggle ─────────────────────────────────────
                // Only shown when activeSetting has an auto mode.
                // SizedBox placeholder keeps the strip height stable otherwise.
                if (activeSetting != null && _hasAutoMode(activeSetting!))
                  _AutoButton(
                    isAuto: _isAuto(activeSetting!),
                    onTap: () => _onAutoTap(activeSetting!),
                  )
                else
                  const SizedBox(width: 56),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── _ParamChip ───────────────────────────────────────────────────────────────

/// One tappable icon chip in the settings strip.
///
/// Shows the parameter icon + name + current value.
/// Highlighted in accent colour when [isActive].
/// Value label is tinted green when [isAuto] (camera is in automatic control).
class _ParamChip extends StatelessWidget {
  const _ParamChip({
    required this.param,
    required this.icon,
    required this.valueLabel,
    required this.isActive,
    required this.isAuto,
    required this.onTap,
  });

  final CameraSettingType param;
  final IconData icon;
  final String valueLabel;
  final bool isActive;
  final bool isAuto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? kAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? kAccent : kBorderColor,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: isActive ? Colors.white : kTextMuted),
            const SizedBox(width: 4),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _paramLabels[param]!,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                    color: isActive ? Colors.white : kTextMuted,
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  valueLabel,
                  style: TextStyle(
                    fontSize: 9,
                    color: isAuto
                        ? kGreen // green = camera is in automatic control
                        : isActive
                        ? Colors.white70
                        : kTextMuted,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── _AutoButton ──────────────────────────────────────────────────────────────

/// A / M toggle at the right edge of the strip.
///
/// Pressing switches the hovered parameter between automatic and manual mode.
/// Only rendered when the hovered param supports auto/manual switching.
class _AutoButton extends StatelessWidget {
  const _AutoButton({required this.isAuto, required this.onTap});

  final bool isAuto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 56,
        decoration: BoxDecoration(
          // Subtle accent background reinforces "auto is on" state.
          color: isAuto ? kAccentActive : Colors.transparent,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isAuto ? kAccent : kBorderColor,
              ),
              child: Center(
                child: Text(
                  isAuto ? 'A' : 'M',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              isAuto ? 'Auto' : 'Manual',
              style: TextStyle(
                fontSize: 8,
                color: isAuto ? kAccent : kTextMuted,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
