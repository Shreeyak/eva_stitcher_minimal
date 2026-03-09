import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../camera/camera_state.dart';
import 'camera_ruler_dial/camera_dial_presets.dart';
import 'camera_ruler_dial/camera_ruler_dial.dart';

/// Floating camera-control overlay shown above the bottom settings strip.
///
/// Renders either a [CameraRulerDial] for numeric parameters or a compact
/// WB action panel for white-balance lock/unlock.
class CameraControlOverlay extends StatelessWidget {
  const CameraControlOverlay({
    super.key,
    required this.activeSetting,
    required this.values,
    required this.ranges,
    required this.callbacks,
  });

  final CameraSettingType? activeSetting;
  final CameraValues values;
  final CameraRanges ranges;
  final CameraCallbacks callbacks;

  @override
  Widget build(BuildContext context) {
    final param = activeSetting;
    if (param == null) return const SizedBox.shrink();
    if (param == CameraSettingType.wb) {
      return _WbControlPanel(
        wbLocked: values.wbLocked,
        onLockWb: callbacks.onLockWb,
        onUnlockWb: callbacks.onUnlockWb,
      );
    }

    // WB is handled above; remaining params all map to a dial slider.
    final CameraDialModel model;
    switch (param) {
      case CameraSettingType.iso:
        model = IsoDialPreset(
          isoRange: ranges.isoRange,
          isoValue: values.isoValue,
          onIsoChanged: callbacks.onIsoChanged,
        ).toModel();
        break;
      case CameraSettingType.shutter:
        model = ShutterDialPreset(
          exposureTimeRangeNs: ranges.exposureTimeRangeNs,
          exposureTimeNs: values.exposureTimeNs,
          onExposureTimeNsChanged: callbacks.onExposureTimeNsChanged,
        ).toModel();
        break;
      case CameraSettingType.zoom:
        model = ZoomDialPreset(
          minZoomRatio: ranges.minZoomRatio,
          maxZoomRatio: ranges.maxZoomRatio,
          currentZoomRatio: values.zoomRatio,
          onZoomChanged: callbacks.onZoomChanged,
        ).toModel();
        break;
      case CameraSettingType.focus:
        model = FocusDialPreset(
          minFocusDistance: ranges.minFocusDistance,
          currentFocusDistance: values.focusDistance,
          onFocusChanged: callbacks.onFocusChanged,
        ).toModel();
        break;
      case CameraSettingType.wb:
        // Unreachable — WB is handled by the guard at the top of build().
        return const SizedBox.shrink();
    }

    final config = model.config;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(100),
          child: ColoredBox(
            color: const Color(0xFF1A1A1A).withValues(alpha: 0.82),
            child: CameraRulerDial(
              key: ValueKey(param),
              config: config,
              initialValue: model.initialValue,
              onChanged: model.onChanged,
              fadeColor: Colors.black,
              leftIcon: Icon(
                config.leftIcon,
                size: config.iconSize,
                color: Colors.white.withValues(alpha: 0.5),
              ),
              rightIcon: Icon(
                config.rightIcon,
                size: config.iconSize,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WbControlPanel extends StatelessWidget {
  const _WbControlPanel({
    required this.wbLocked,
    required this.onLockWb,
    required this.onUnlockWb,
  });

  final bool wbLocked;
  final VoidCallback onLockWb;
  final VoidCallback onUnlockWb;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: kPanelColor.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorderColor),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _WbActionButton(
            label: 'Auto AWB',
            icon: Icons.wb_auto,
            isActive: !wbLocked,
            onTap: wbLocked ? onUnlockWb : null,
          ),
          const SizedBox(width: 16),
          _WbActionButton(
            label: 'Lock WB',
            icon: Icons.lock,
            isActive: wbLocked,
            onTap: !wbLocked ? onLockWb : null,
          ),
        ],
      ),
    );
  }
}

class _WbActionButton extends StatelessWidget {
  const _WbActionButton({
    required this.label,
    required this.icon,
    required this.isActive,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? kAccent : kBorderColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: isActive ? Colors.white : kTextMuted),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isActive ? Colors.white : kTextMuted,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
