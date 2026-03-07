import 'package:flutter/material.dart';
import '../app_theme.dart';
import 'side_button.dart';

/// 70 px wide vertical toolbar docked at the left edge.
/// Solid [kPanelColor] background with deep blue accent highlights.
class LeftToolbar extends StatelessWidget {
  final bool isScanning;
  final bool showCanvas;
  final bool settingsOpen;
  final bool canExport;

  final VoidCallback onToggleScan;
  final VoidCallback onToggleCanvas;
  final VoidCallback onToggleSettings;
  final VoidCallback onReset;
  final VoidCallback onExport;

  const LeftToolbar({
    super.key,
    required this.isScanning,
    required this.showCanvas,
    required this.settingsOpen,
    required this.canExport,
    required this.onToggleScan,
    required this.onToggleCanvas,
    required this.onToggleSettings,
    required this.onReset,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 70,
      decoration: BoxDecoration(
        color: kPanelColor,
        border: const Border(right: BorderSide(color: kBorderColor, width: 1)),
      ),
      child: Column(
        children: [
          // App logo / home icon at top
          Container(
            width: 70,
            height: 56,
            decoration: const BoxDecoration(
              color: kAccentActive,
              border: Border(bottom: BorderSide(color: kBorderColor, width: 1)),
            ),
            child: const Icon(Icons.view_in_ar, color: kAccent, size: 28),
          ),

          // Main actions
          Expanded(
            child: Column(
              children: [
                const SizedBox(height: 4),
                SideButton(
                  icon: isScanning
                      ? Icons.stop_circle_outlined
                      : Icons.play_circle_outline,
                  label: isScanning ? 'Stop' : 'Start\nScan',
                  isActive: isScanning,
                  color: isScanning ? kOrange : null,
                  onTap: onToggleScan,
                ),
                SideButton(
                  icon: Icons.grid_view_outlined,
                  label: 'Canvas',
                  isActive: showCanvas,
                  onTap: onToggleCanvas,
                ),
                SideButton(icon: Icons.refresh, label: 'Reset', onTap: onReset),
              ],
            ),
          ),

          // Bottom: Export
          const Divider(height: 1, thickness: 1, color: kBorderColor),
          // Settings moved to bottom above Export
          SideButton(
            icon: Icons.tune,
            label: 'Settings',
            isActive: settingsOpen,
            onTap: onToggleSettings,
          ),
          SideButton(
            icon: Icons.download_outlined,
            label: 'Export',
            isDisabled: !canExport,
            onTap: canExport ? onExport : null,
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
