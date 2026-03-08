import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'camera_ruler_slider/camera_dial_presets.dart';
import 'camera_ruler_slider/camera_ruler_slider.dart';
import 'camera_settings_drawer.dart';

/// Floating camera-control overlay shown above the bottom settings strip.
///
/// Renders either a [CameraRulerSlider] for numeric parameters or a compact
/// WB action panel for white-balance lock/unlock.
class FloatingHoverSlider extends StatelessWidget {
  const FloatingHoverSlider({
    super.key,
    required this.activeParam,
    required this.wbLocked,
    required this.isoRange,
    required this.isoValue,
    required this.onIsoChanged,
    required this.exposureTimeRangeNs,
    required this.exposureTimeNs,
    required this.onExposureTimeNsChanged,
    required this.minZoomRatio,
    required this.maxZoomRatio,
    required this.currentZoomRatio,
    required this.onZoomChanged,
    required this.minFocusDistance,
    required this.currentFocusDistance,
    required this.onFocusChanged,
    required this.onLockWb,
    required this.onUnlockWb,
  });

  final CameraParam? activeParam;
  final bool wbLocked;

  final List<int> isoRange;
  final int isoValue;
  final ValueChanged<int> onIsoChanged;

  final List<int> exposureTimeRangeNs;
  final int exposureTimeNs;
  final ValueChanged<int> onExposureTimeNsChanged;

  final double minZoomRatio;
  final double maxZoomRatio;
  final double currentZoomRatio;
  final ValueChanged<double> onZoomChanged;

  final double minFocusDistance;
  final double currentFocusDistance;
  final ValueChanged<double> onFocusChanged;

  final VoidCallback onLockWb;
  final VoidCallback onUnlockWb;

  @override
  Widget build(BuildContext context) {
    final param = activeParam;
    if (param == null) return const SizedBox.shrink();
    if (param == CameraParam.wb) {
      return _HoverWbPanel(
        wbLocked: wbLocked,
        onLockWb: onLockWb,
        onUnlockWb: onUnlockWb,
      );
    }

    final CameraDialModel model;
    switch (param) {
      case CameraParam.iso:
        model = IsoDialPreset(
          isoRange: isoRange,
          isoValue: isoValue,
          onIsoChanged: onIsoChanged,
        ).toModel();
        break;
      case CameraParam.shutter:
        model = ShutterDialPreset(
          exposureTimeRangeNs: exposureTimeRangeNs,
          exposureTimeNs: exposureTimeNs,
          onExposureTimeNsChanged: onExposureTimeNsChanged,
        ).toModel();
        break;
      case CameraParam.zoom:
        model = ZoomDialPreset(
          minZoomRatio: minZoomRatio,
          maxZoomRatio: maxZoomRatio,
          currentZoomRatio: currentZoomRatio,
          onZoomChanged: onZoomChanged,
        ).toModel();
        break;
      case CameraParam.focus:
        model = FocusDialPreset(
          minFocusDistance: minFocusDistance,
          currentFocusDistance: currentFocusDistance,
          onFocusChanged: onFocusChanged,
        ).toModel();
        break;
      case CameraParam.wb:
        return _HoverWbPanel(
          wbLocked: wbLocked,
          onLockWb: onLockWb,
          onUnlockWb: onUnlockWb,
        );
    }

    final config = model.config;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(100),
          child: ColoredBox(
            color: const Color(0xFF1A1A1A).withValues(alpha: 0.82),
            child: CameraRulerSlider(
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

class _HoverWbPanel extends StatelessWidget {
  const _HoverWbPanel({
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
          _HoverWbButton(
            label: 'Auto AWB',
            icon: Icons.wb_auto,
            isActive: !wbLocked,
            onTap: wbLocked ? onUnlockWb : null,
          ),
          const SizedBox(width: 16),
          _HoverWbButton(
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

class _HoverWbButton extends StatelessWidget {
  const _HoverWbButton({
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
