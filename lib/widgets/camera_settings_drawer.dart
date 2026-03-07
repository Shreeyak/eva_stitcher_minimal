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
// Tapping any chip calls [onHoverParamTap] so the parent (main.dart) can
// position a floating [CameraRulerSlider] overlay above the camera preview.
// Tapping the same chip again passes null → collapses the overlay.
//
// The [hoverParam] field (owned by the parent) is passed back in to highlight
// the active chip and to show/hide the A/M toggle for that param.

import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'camera_dial/dial_config.dart'; // CameraParam enum

// ── Layout constants ──────────────────────────────────────────────────────────

/// Height of the icon-strip row.
const double _kStripHeight = 52.0;

// ── Icon map ──────────────────────────────────────────────────────────────────

/// Maps each [CameraParam] to a representative Material icon.
const _paramIcons = {
  CameraParam.iso: Icons.iso,
  CameraParam.shutter: Icons.shutter_speed,
  CameraParam.focus: Icons.center_focus_strong,
  CameraParam.wb: Icons.wb_auto,
  CameraParam.zoom: Icons.zoom_in,
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
/// - Parent passes [hoverParam] → used to highlight the active chip.
/// - User taps chip → [onHoverParamTap] fires → parent updates [hoverParam].
class CameraSettingsDrawer extends StatelessWidget {
  const CameraSettingsDrawer({
    super.key,
    required this.isOpen,
    this.hoverParam,
    required this.onHoverParamTap,
    required this.afEnabled,
    required this.wbLocked,
    required this.onToggleAf,
    required this.onLockWb,
    required this.onUnlockWb,
    // ── Current values (for chip sub-labels) ──
    required this.isoValue,
    required this.exposureTimeNs,
    required this.focusDistance,
    required this.zoomRatio,
  });

  /// Whether the strip is shown at all (animates to height 0 when false).
  final bool isOpen;

  /// The currently active "floating" param, or null if the overlay is closed.
  ///
  /// Controlled entirely by the parent. Used here only to highlight the
  /// corresponding chip and show/hide the A/M toggle button.
  final CameraParam? hoverParam;

  /// Called when the user taps a chip.
  ///
  /// Passes the tapped [CameraParam], or null if the same chip was tapped
  /// again (toggle-off).  The parent must call `setState` to update
  /// [hoverParam] in response.
  final ValueChanged<CameraParam?> onHoverParamTap;

  // ── Auto-mode flags ───────────────────────────────────────────────────────

  /// AF (auto-focus) on.
  final bool afEnabled;

  /// WB locked — AWB is overridden with the captured colour-correction matrix.
  final bool wbLocked;

  final VoidCallback onToggleAf;
  final VoidCallback onLockWb;
  final VoidCallback onUnlockWb;

  // ── Current camera values (chip sub-labels only) ──────────────────────────

  final int isoValue;
  final int exposureTimeNs; // nanoseconds
  final double focusDistance; // diopters
  final double zoomRatio;

  // ── Auto helpers ──────────────────────────────────────────────────────────

  /// True when [param] is currently controlled automatically by the camera.
  bool _isAuto(CameraParam param) {
    switch (param) {
      case CameraParam.focus:
        return afEnabled;
      case CameraParam.wb:
        return !wbLocked; // "auto" = AWB running (not locked)
      case CameraParam.iso:
      case CameraParam.shutter:
      case CameraParam.zoom:
        return false; // no auto mode for these
    }
  }

  /// Fires the correct toggle callback for [param].
  void _onAutoTap(CameraParam param) {
    switch (param) {
      case CameraParam.focus:
        onToggleAf();
        break;
      case CameraParam.wb:
        wbLocked ? onUnlockWb() : onLockWb();
        break;
      case CameraParam.iso:
      case CameraParam.shutter:
      case CameraParam.zoom:
        break; // no-op
    }
  }

  // ── Chip sub-label ────────────────────────────────────────────────────────

  /// Short value string shown beneath the chip icon.
  String _chipLabel(CameraParam param) {
    switch (param) {
      case CameraParam.iso:
        return isoValue.toString();

      case CameraParam.shutter:
        final secs = exposureTimeNs / 1e9;
        if (secs < 1.0) return '1/${(1.0 / secs).round()}';
        return '${secs.toStringAsFixed(1)}s';

      case CameraParam.focus:
        if (afEnabled) return 'AUTO';
        return '${focusDistance.toStringAsFixed(1)}D';

      case CameraParam.wb:
        return wbLocked ? 'LOCK' : 'AUTO';

      case CameraParam.zoom:
        return '${zoomRatio.toStringAsFixed(1)}×';
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      height: isOpen ? _kStripHeight : 0.0,
      child: ClipRect(child: _buildStrip()),
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
                      children: CameraParam.values.map((p) {
                        return _ParamChip(
                          param: p,
                          icon: _paramIcons[p]!,
                          valueLabel: _chipLabel(p),
                          isActive: p == hoverParam,
                          isAuto: _isAuto(p),
                          onTap: () {
                            // Toggle: same chip → collapse overlay; other → open it.
                            onHoverParamTap(p == hoverParam ? null : p);
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
                // Only shown when hoverParam has an auto mode.
                // SizedBox placeholder keeps the strip height stable otherwise.
                if (hoverParam != null && hoverParam!.hasAutoMode)
                  _AutoButton(
                    isAuto: _isAuto(hoverParam!),
                    onTap: () => _onAutoTap(hoverParam!),
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

  final CameraParam param;
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
                  param.label,
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
/// Only rendered when the hovered param has an auto mode (see
/// [CameraParam.hasAutoMode]).
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
