import 'package:flutter/material.dart';

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

    final cs = Theme.of(context).colorScheme;
    // Blend surface at 82% opacity over the black camera preview to get a
    // single opaque composite. Both the pill background and the dial fade
    // gradient use this colour so their edges match exactly.
    final overlayBg = Color.alphaBlend(
      cs.surface.withValues(alpha: 0.82),
      Colors.black,
    );
    final config = model.config;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(100),
          child: ColoredBox(
            color: overlayBg,
            child: CameraRulerDial(
              key: ValueKey(param),
              config: config,
              initialValue: model.initialValue,
              onChanged: model.onChanged,
              fadeColor: overlayBg,
              leftIcon: Icon(
                config.leftIcon,
                size: config.iconSize,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
              rightIcon: Icon(
                config.rightIcon,
                size: config.iconSize,
                color: cs.onSurface.withValues(alpha: 0.5),
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
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainer.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // M3 SegmentedButton — selected segment is automatically filled.
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(
                value: false,
                label: Text('Auto AWB'),
                icon: Icon(Icons.wb_auto),
              ),
              ButtonSegment<bool>(
                value: true,
                label: Text('Lock WB'),
                icon: Icon(Icons.lock),
              ),
            ],
            selected: {wbLocked},
            onSelectionChanged: (Set<bool> selection) {
              final locked = selection.first;
              if (locked && !wbLocked) onLockWb();
              if (!locked && wbLocked) onUnlockWb();
            },
          ),
        ],
      ),
    );
  }
}
