import 'package:flutter/material.dart';
import 'side_button.dart';

/// 70 px wide vertical toolbar docked at the left edge.
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
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 70,
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        border: Border(right: BorderSide(color: cs.outlineVariant, width: 1)),
      ),
      child: Column(
        children: [
          // App logo / home icon at top
          Container(
            width: 70,
            height: 56,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              border: Border(
                bottom: BorderSide(color: cs.outlineVariant, width: 1),
              ),
            ),
            child: Icon(Icons.view_in_ar, color: cs.primary, size: 28),
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
                  color: isScanning ? cs.tertiary : null,
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

          // Bottom: Settings + Export
          const Divider(height: 1, thickness: 1),
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
