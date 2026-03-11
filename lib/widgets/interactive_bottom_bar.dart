import 'package:flutter/material.dart';

import '../camera/camera_state.dart';

/// The bottom interactive area that hosts both the Main Action Bar
/// and the Camera Settings Bar, animating between them using a Stack + AnimatedSlide.
class InteractiveBottomBar extends StatelessWidget {
  final bool isScanning;
  final bool showCanvas;
  final bool isSettingsOpen;
  final bool canExport;

  // Settings bar specifics
  final CameraSettingType? activeSetting;
  final CameraValues values;
  final CameraCallbacks callbacks;

  // Callbacks
  final VoidCallback onToggleScan;
  final VoidCallback onToggleCanvas;
  final VoidCallback onToggleSettings;
  final VoidCallback onReset;
  final VoidCallback onExport;
  final ValueChanged<CameraSettingType?> onSettingChipTap;

  const InteractiveBottomBar({
    super.key,
    required this.isScanning,
    required this.showCanvas,
    required this.isSettingsOpen,
    required this.canExport,
    required this.activeSetting,
    required this.values,
    required this.callbacks,
    required this.onToggleScan,
    required this.onToggleCanvas,
    required this.onToggleSettings,
    required this.onReset,
    required this.onExport,
    required this.onSettingChipTap,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(
        begin: isSettingsOpen ? 1.0 : 0.0,
        end: isSettingsOpen ? 1.0 : 0.0,
      ),
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOutCubicEmphasized,
      builder: (context, t, child) {
        return Stack(
          alignment: Alignment.bottomCenter,
          children: [
            // 1. MAIN ACTION BAR
            ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: 1.0 - t,
                child: FractionalTranslation(
                  translation: Offset(0, t),
                  child: _MainActionBar(
                    isScanning: isScanning,
                    showCanvas: showCanvas,
                    canExport: canExport,
                    onToggleScan: onToggleScan,
                    onToggleCanvas: onToggleCanvas,
                    onToggleSettings: onToggleSettings,
                    onReset: onReset,
                    onExport: onExport,
                  ),
                ),
              ),
            ),

            // 2. CAMERA SETTINGS BAR
            ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: t,
                child: FractionalTranslation(
                  translation: Offset(0, 1.0 - t),
                  child: _CameraSettingsBar(
                    activeSetting: activeSetting,
                    values: values,
                    callbacks: callbacks,
                    onToggleSettings: onToggleSettings,
                    onSettingChipTap: onSettingChipTap,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MainActionBar extends StatelessWidget {
  final bool isScanning;
  final bool showCanvas;
  final bool canExport;
  final VoidCallback onToggleScan;
  final VoidCallback onToggleCanvas;
  final VoidCallback onToggleSettings;
  final VoidCallback onReset;
  final VoidCallback onExport;

  const _MainActionBar({
    required this.isScanning,
    required this.showCanvas,
    required this.canExport,
    required this.onToggleScan,
    required this.onToggleCanvas,
    required this.onToggleSettings,
    required this.onReset,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      color: cs.surfaceContainerLowest,
      // Main Action Bar Container Padding:
      // - Left/Right (48.0): Dead zone to prevent UI clipping/overlap from the physical tablet holder clamps.
      // - Top (8.0): Pushes the buttons slightly down from the upper edge of the container.
      // - Bottom (16.0): Pushes the buttons up from the very bottom edge of the screen.
      padding: const EdgeInsets.fromLTRB(48.0, 8.0, 48.0, 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Settings on the left
          _MainActionBtn(
            icon: Icons.tune,
            label: 'SETTINGS',
            onTap: onToggleSettings,
          ),

          const SizedBox(width: 32),
          // Other buttons to the right of settings
          _MainActionBtn(
            icon: showCanvas ? Icons.grid_view : Icons.grid_view_outlined,
            label: 'CANVAS',
            isActive: showCanvas,
            onTap: onToggleCanvas,
          ),
          const SizedBox(width: 32),
          _MainActionBtn(icon: Icons.refresh, label: 'RESET', onTap: onReset),
          const SizedBox(width: 32),
          _MainActionBtn(
            icon: Icons.download_outlined,
            label: 'EXPORT',
            isDisabled: !canExport,
            onTap: canExport ? onExport : null,
          ),

          const Spacer(),

          // FAB on the right
          SizedBox(
            height: 38,
            child: FloatingActionButton.extended(
              elevation: 0,
              onPressed: onToggleScan,
              backgroundColor: isScanning ? cs.tertiary : cs.primaryContainer,
              foregroundColor: isScanning
                  ? cs.onTertiary
                  : cs.onPrimaryContainer,
              icon: Icon(
                isScanning
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
              ),
              label: Text(
                isScanning ? 'STOP' : 'START',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraSettingsBar extends StatelessWidget {
  final CameraSettingType? activeSetting;
  final CameraValues values;
  final CameraCallbacks callbacks;
  final VoidCallback onToggleSettings;
  final ValueChanged<CameraSettingType?> onSettingChipTap;

  const _CameraSettingsBar({
    required this.activeSetting,
    required this.values,
    required this.callbacks,
    required this.onToggleSettings,
    required this.onSettingChipTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surfaceContainerLowest,
      // Camera Settings Bar Container Padding:
      // Matching the _MainActionBar padding exactly ensures both bars have the same overall height bounding box,
      // which is important for the transition stack animation to look seamless.
      // - Left/Right (48.0): Dead zone for physical tablet clamps.
      // - Top (8.0) / Bottom (16.0): Vertically aligns the content within the container to match the main bar.
      padding: const EdgeInsets.fromLTRB(48.0, 8.0, 48.0, 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Match the position of the settings button from MainActionBar
          _MainActionBtn(
            icon: Icons.keyboard_arrow_down,
            label: 'CLOSE',
            onTap: onToggleSettings,
          ),

          const SizedBox(width: 32),

          // Chips
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _CamSettingsChip(
                    param: CameraSettingType.iso,
                    icon: Icons.iso,
                    label: 'ISO',
                    valueLabel: values.isoValue.toString(),
                    isActive: activeSetting == CameraSettingType.iso,
                    onTap: () => onSettingChipTap(
                      activeSetting == CameraSettingType.iso
                          ? null
                          : CameraSettingType.iso,
                    ),
                  ),
                  _CamSettingsChip(
                    param: CameraSettingType.shutter,
                    icon: Icons.shutter_speed,
                    label: 'SHUTTER',
                    valueLabel: _formatShutter(values.exposureTimeNs),
                    isActive: activeSetting == CameraSettingType.shutter,
                    onTap: () => onSettingChipTap(
                      activeSetting == CameraSettingType.shutter
                          ? null
                          : CameraSettingType.shutter,
                    ),
                  ),
                  _CamSettingsChip(
                    param: CameraSettingType.focus,
                    icon: Icons.center_focus_strong,
                    label: 'FOCUS',
                    valueLabel: values.afEnabled
                        ? 'AUTO'
                        : '${values.focusDistance.toStringAsFixed(1)}D',
                    isActive: activeSetting == CameraSettingType.focus,
                    onTap: () => onSettingChipTap(
                      activeSetting == CameraSettingType.focus
                          ? null
                          : CameraSettingType.focus,
                    ),
                  ),
                  _CamSettingsChip(
                    param: CameraSettingType.wb,
                    icon: Icons.wb_auto,
                    label: 'WB',
                    valueLabel: values.wbLocked ? 'LOCK' : 'AUTO',
                    isActive: activeSetting == CameraSettingType.wb,
                    onTap: () => onSettingChipTap(
                      activeSetting == CameraSettingType.wb
                          ? null
                          : CameraSettingType.wb,
                    ),
                  ),
                  _CamSettingsChip(
                    param: CameraSettingType.zoom,
                    icon: Icons.zoom_in,
                    label: 'ZOOM',
                    valueLabel: '${values.zoomRatio.toStringAsFixed(1)}×',
                    isActive: activeSetting == CameraSettingType.zoom,
                    onTap: () => onSettingChipTap(
                      activeSetting == CameraSettingType.zoom
                          ? null
                          : CameraSettingType.zoom,
                    ),
                  ),
                  // spacer for auto/manual toggle button
                  const SizedBox(width: 16),
                  if (_hasAutoMode(activeSetting))
                    _AutoButton(
                      isAuto: _isAuto(activeSetting),
                      onTap: () => _onAutoTap(activeSetting),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatShutter(int ns) {
    final secs = ns / 1e9;
    if (secs < 1.0) return '1/${(1.0 / secs).round()}';
    return '${secs.toStringAsFixed(1)}s';
  }

  bool _isAuto(CameraSettingType? param) {
    if (param == null) return false;
    switch (param) {
      case CameraSettingType.focus:
        return values.afEnabled;
      case CameraSettingType.wb:
        return !values.wbLocked;
      default:
        return false;
    }
  }

  void _onAutoTap(CameraSettingType? param) {
    if (param == null) return;
    switch (param) {
      case CameraSettingType.focus:
        callbacks.onToggleAf();
        break;
      case CameraSettingType.wb:
        values.wbLocked ? callbacks.onUnlockWb() : callbacks.onLockWb();
        break;
      default:
        break;
    }
  }

  bool _hasAutoMode(CameraSettingType? param) {
    if (param == null) return false;
    switch (param) {
      case CameraSettingType.focus:
      case CameraSettingType.wb:
        return true;
      default:
        return false;
    }
  }
}

class _MainActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final bool isDisabled;
  final VoidCallback? onTap;

  const _MainActionBtn({
    required this.icon,
    required this.label,
    this.isActive = false,
    this.isDisabled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = isDisabled
        ? cs.onSurface.withValues(alpha: 0.38)
        : isActive
        ? cs.primary
        : cs.onSurfaceVariant;

    return InkWell(
      onTap: isDisabled ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        // Internal padding that expands the clickable area and ink splash size
        padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                color: color,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CamSettingsChip extends StatelessWidget {
  const _CamSettingsChip({
    required this.param,
    required this.icon,
    required this.label,
    required this.valueLabel,
    required this.isActive,
    required this.onTap,
  });

  final CameraSettingType param;
  final IconData icon;
  final String label;
  final String valueLabel;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      // Outer padding around each individual chip:
      // - Left/Right (10.0): Horizontal spacing between adjacent chips.
      // - Bottom (4.0): Shifts the chip slightly upwards relative to its neighbors or container center.
      padding: const EdgeInsets.fromLTRB(10.0, 0.0, 10.0, 4.0),
      child: Material(
        color: isActive ? cs.primary : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          splashColor: isActive
              ? cs.onPrimary.withValues(alpha: 0.2)
              : cs.primary.withValues(alpha: 0.1),
          child: Padding(
            // Inner padding of the chip defining its actual visual size:
            // - Horizontal (14.0): Spacing on the left and right of the content.
            // - Vertical (6.0): Defines the height of the chip. Increase/decrease this to make the chip taller/shorter.
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: isActive ? cs.onPrimary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 9,
                        letterSpacing: 0.5,
                        color: isActive
                            ? cs.onPrimary.withValues(alpha: 0.8)
                            : cs.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                    ),
                    Text(
                      valueLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isActive
                            ? FontWeight.bold
                            : FontWeight.w600,
                        fontFamily: 'monospace',
                        color: isActive ? cs.onPrimary : cs.onSurface,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AutoButton extends StatelessWidget {
  const _AutoButton({required this.isAuto, required this.onTap});

  final bool isAuto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        // Inner padding defining the tappable area and bounds of the auto/manual toggle button
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isAuto ? cs.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isAuto ? Colors.transparent : cs.outlineVariant,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isAuto ? Icons.auto_mode : Icons.pan_tool,
              size: 20,
              color: isAuto ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(height: 2),
            Text(
              isAuto ? 'Auto' : 'Manual',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: isAuto ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
