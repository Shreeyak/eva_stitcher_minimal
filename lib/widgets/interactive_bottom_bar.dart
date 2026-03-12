import 'package:flutter/material.dart';

import '../camera/camera_state.dart';
import 'bottom_bar_buttons.dart';
import 'camera_settings_bar.dart';

/// The bottom interactive area that hosts both the Main Action Bar
/// and the Camera Settings Bar, animating between them with a clipped slide.
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
                  child: CameraSettingsBar(
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
          BottomBarActionButton(
            icon: Icons.tune,
            label: 'SETTINGS',
            onTap: onToggleSettings,
          ),

          const SizedBox(width: 32),
          BottomBarActionButton(
            icon: showCanvas ? Icons.grid_view : Icons.grid_view_outlined,
            label: 'CANVAS',
            isActive: showCanvas,
            onTap: onToggleCanvas,
          ),
          const SizedBox(width: 32),
          BottomBarActionButton(
            icon: Icons.refresh,
            label: 'RESET',
            onTap: onReset,
          ),
          const SizedBox(width: 32),
          BottomBarActionButton(
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
