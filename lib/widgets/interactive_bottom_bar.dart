import 'package:flutter/material.dart';

import 'package:eva_camera/eva_camera.dart';
import '../camera/camera_callbacks.dart';
import 'bottom_bar_buttons.dart';
import 'camera_settings_bar.dart';

/// The bottom interactive area that hosts both the Main Action Bar
/// and the Camera Settings Bar, animating between them.
class InteractiveBottomBar extends StatelessWidget {
  final bool cameraReady;
  final bool isScanning;
  final bool showCanvas;
  final bool isSettingsOpen;
  final bool canExport;
  final bool showDebugOverlay;
  final VoidCallback onToggleDebugOverlay;

  // Settings bar specifics
  final CameraSettingType? activeSetting;
  final CameraValues values;
  final CameraCallbacks callbacks;

  // Callbacks
  final VoidCallback onToggleScan;
  final VoidCallback onToggleCanvas;
  final VoidCallback onToggleSettings;
  final VoidCallback onReset;
  final VoidCallback onSaveCanvas;
  final ValueChanged<CameraSettingType?> onSettingChipTap;

  const InteractiveBottomBar({
    super.key,
    required this.cameraReady,
    required this.isScanning,
    required this.showCanvas,
    required this.isSettingsOpen,
    required this.canExport,
    required this.showDebugOverlay,
    required this.onToggleDebugOverlay,
    required this.activeSetting,
    required this.values,
    required this.callbacks,
    required this.onToggleScan,
    required this.onToggleCanvas,
    required this.onToggleSettings,
    required this.onReset,
    required this.onSaveCanvas,
    required this.onSettingChipTap,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: isSettingsOpen ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 400),
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
                    cameraReady: cameraReady,
                    isScanning: isScanning,
                    showCanvas: showCanvas,
                    canExport: canExport,
                    showDebugOverlay: showDebugOverlay,
                    onToggleScan: onToggleScan,
                    onToggleCanvas: onToggleCanvas,
                    onToggleSettings: onToggleSettings,
                    onReset: onReset,
                    onSaveCanvas: onSaveCanvas,
                    onToggleDebugOverlay: onToggleDebugOverlay,
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
  final bool cameraReady;
  final bool isScanning;
  final bool showCanvas;
  final bool canExport;
  final bool showDebugOverlay;
  final VoidCallback onToggleScan;
  final VoidCallback onToggleCanvas;
  final VoidCallback onToggleSettings;
  final VoidCallback onReset;
  final VoidCallback onSaveCanvas;
  final VoidCallback onToggleDebugOverlay;

  const _MainActionBar({
    required this.cameraReady,
    required this.isScanning,
    required this.showCanvas,
    required this.canExport,
    required this.showDebugOverlay,
    required this.onToggleScan,
    required this.onToggleCanvas,
    required this.onToggleSettings,
    required this.onReset,
    required this.onSaveCanvas,
    required this.onToggleDebugOverlay,
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
             icon: Icons.save_outlined,
             label: 'SAVE CANVAS',
             isDisabled: !canExport,
             onTap: canExport ? onSaveCanvas : null,
           ),
           const SizedBox(width: 32),
           BottomBarActionButton(
             icon: Icons.bug_report_outlined,
             label: 'DEBUG',
             isActive: showDebugOverlay,
             onTap: onToggleDebugOverlay,
           ),

          const Spacer(),

          // FAB on the right
          SizedBox(
            height: 38,
            child: FloatingActionButton.extended(
              elevation: 0,
              onPressed: cameraReady ? onToggleScan : null,
              backgroundColor: !cameraReady
                  ? cs.surfaceContainerHighest
                  : isScanning
                      ? cs.tertiary
                      : cs.primaryContainer,
              foregroundColor: !cameraReady
                  ? cs.onSurfaceVariant
                  : isScanning
                      ? cs.onTertiary
                      : cs.onPrimaryContainer,
              icon: Icon(
                isScanning
                    ? Icons.stop_circle_outlined
                    : Icons.play_circle_outline,
              ),
              label: Text(
                cameraReady
                    ? (isScanning ? 'STOP' : 'START')
                    : 'NO CAMERA',
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
