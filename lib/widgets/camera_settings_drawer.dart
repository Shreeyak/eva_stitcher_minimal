import 'package:flutter/material.dart';
import '../app_theme.dart';
import 'ruler_picker.dart';

// ── Tab definitions ──────────────────────────────────────────────────────

enum _ParamTab { iso, shutter, ev, focus, wb, zoom }

const _tabLabels = {
  _ParamTab.iso: 'ISO',
  _ParamTab.shutter: 'Shutter',
  _ParamTab.ev: 'EV',
  _ParamTab.focus: 'Focus',
  _ParamTab.wb: 'WB',
  _ParamTab.zoom: 'Zoom',
};

const _tabIcons = {
  _ParamTab.iso: Icons.iso,
  _ParamTab.shutter: Icons.shutter_speed,
  _ParamTab.ev: Icons.exposure,
  _ParamTab.focus: Icons.center_focus_strong,
  _ParamTab.wb: Icons.wb_auto,
  _ParamTab.zoom: Icons.zoom_in,
};

// ── Widget ───────────────────────────────────────────────────────────────

/// Animated bottom drawer for camera parameter control.
/// Height animates between 0 and [_kDrawerHeight] based on [isOpen].
class CameraSettingsDrawer extends StatefulWidget {
  final bool isOpen;

  // Camera state
  final bool aeEnabled;
  final bool afEnabled;
  final bool wbLocked;
  final int isoValue;
  final List<int> isoRange;
  final int exposureTimeNs;
  final List<int> exposureTimeRangeNs;
  final int exposureOffsetIndex;
  final List<int> exposureOffsetRange;
  final double exposureOffsetStep;
  final double focusDistance;
  final double minFocusDistance;
  final double zoomRatio;
  final double minZoomRatio;
  final double maxZoomRatio;

  // Callbacks
  final VoidCallback onToggleAe;
  final VoidCallback onToggleAf;
  final VoidCallback onLockWb;
  final VoidCallback onUnlockWb;
  final ValueChanged<int> onIsoChanged;
  final ValueChanged<int> onExposureTimeNsChanged;
  final ValueChanged<int> onEvIndexChanged;
  final ValueChanged<double> onFocusChanged;
  final ValueChanged<double> onZoomChanged;

  const CameraSettingsDrawer({
    super.key,
    required this.isOpen,
    required this.aeEnabled,
    required this.afEnabled,
    required this.wbLocked,
    required this.isoValue,
    required this.isoRange,
    required this.exposureTimeNs,
    required this.exposureTimeRangeNs,
    required this.exposureOffsetIndex,
    required this.exposureOffsetRange,
    required this.exposureOffsetStep,
    required this.focusDistance,
    required this.minFocusDistance,
    required this.zoomRatio,
    required this.minZoomRatio,
    required this.maxZoomRatio,
    required this.onToggleAe,
    required this.onToggleAf,
    required this.onLockWb,
    required this.onUnlockWb,
    required this.onIsoChanged,
    required this.onExposureTimeNsChanged,
    required this.onEvIndexChanged,
    required this.onFocusChanged,
    required this.onZoomChanged,
  });

  @override
  State<CameraSettingsDrawer> createState() => _CameraSettingsDrawerState();
}

class _CameraSettingsDrawerState extends State<CameraSettingsDrawer> {
  _ParamTab _selectedTab = _ParamTab.iso;

  static const double _kDrawerHeight = 138.0;
  static const double _kTabBarHeight = 40.0;
  static const double _kControlHeight = 98.0;

  // ── Auto mode helpers ────────────────────────────────────────────

  bool get _isAuto {
    switch (_selectedTab) {
      case _ParamTab.iso:
      case _ParamTab.shutter:
        return widget.aeEnabled;
      case _ParamTab.ev:
        return false; // "Auto" for EV means reset to 0
      case _ParamTab.focus:
        return widget.afEnabled;
      case _ParamTab.wb:
        return !widget.wbLocked; // "Auto" = unlocked AWB
      case _ParamTab.zoom:
        return false; // no auto for zoom
    }
  }

  String get _autoLabel {
    switch (_selectedTab) {
      case _ParamTab.iso:
      case _ParamTab.shutter:
        return widget.aeEnabled ? 'A' : 'A';
      case _ParamTab.ev:
        return '0';
      case _ParamTab.focus:
        return 'A';
      case _ParamTab.wb:
        return widget.wbLocked ? 'A' : 'A';
      case _ParamTab.zoom:
        return '1x';
    }
  }

  void _onAutoTap() {
    switch (_selectedTab) {
      case _ParamTab.iso:
      case _ParamTab.shutter:
        widget.onToggleAe();
        break;
      case _ParamTab.ev:
        widget.onEvIndexChanged(0);
        break;
      case _ParamTab.focus:
        widget.onToggleAf();
        break;
      case _ParamTab.wb:
        widget.wbLocked ? widget.onUnlockWb() : widget.onLockWb();
        break;
      case _ParamTab.zoom:
        widget.onZoomChanged(widget.minZoomRatio);
        break;
    }
  }

  // ── Ruler configuration per tab ──────────────────────────────────

  double get _rulerMin {
    switch (_selectedTab) {
      case _ParamTab.iso:
        return widget.isoRange[0].toDouble();
      case _ParamTab.shutter:
        return widget.exposureTimeRangeNs[0] / 1e6; // ms
      case _ParamTab.ev:
        return widget.exposureOffsetRange.isNotEmpty
            ? widget.exposureOffsetRange[0].toDouble()
            : -4.0;
      case _ParamTab.focus:
        return 0.0;
      case _ParamTab.wb:
        return 0.0;
      case _ParamTab.zoom:
        return widget.minZoomRatio;
    }
  }

  double get _rulerMax {
    switch (_selectedTab) {
      case _ParamTab.iso:
        return widget.isoRange[1].toDouble();
      case _ParamTab.shutter:
        return (widget.exposureTimeRangeNs[1] / 1e6).clamp(10.0, 2000.0);
      case _ParamTab.ev:
        return widget.exposureOffsetRange.length >= 2
            ? widget.exposureOffsetRange[1].toDouble()
            : 4.0;
      case _ParamTab.focus:
        return widget.minFocusDistance > 0 ? widget.minFocusDistance : 10.0;
      case _ParamTab.wb:
        return 1.0;
      case _ParamTab.zoom:
        return widget.maxZoomRatio;
    }
  }

  double get _rulerStep {
    switch (_selectedTab) {
      case _ParamTab.iso:
        return 100.0;
      case _ParamTab.shutter:
        final rangeMs = _rulerMax - _rulerMin;
        if (rangeMs <= 50) return 2.0;
        if (rangeMs <= 200) return 10.0;
        return 50.0;
      case _ParamTab.ev:
        return 1.0;
      case _ParamTab.focus:
        final range = _rulerMax - _rulerMin;
        return (range / 8).clamp(0.5, 5.0);
      case _ParamTab.wb:
        return 1.0;
      case _ParamTab.zoom:
        final range = _rulerMax - _rulerMin;
        return (range / 6).clamp(0.1, 2.0);
    }
  }

  double get _rulerValue {
    switch (_selectedTab) {
      case _ParamTab.iso:
        return widget.isoValue.toDouble().clamp(_rulerMin, _rulerMax);
      case _ParamTab.shutter:
        return (widget.exposureTimeNs / 1e6).clamp(_rulerMin, _rulerMax);
      case _ParamTab.ev:
        return widget.exposureOffsetIndex.toDouble().clamp(
          _rulerMin,
          _rulerMax,
        );
      case _ParamTab.focus:
        return widget.focusDistance.clamp(_rulerMin, _rulerMax);
      case _ParamTab.wb:
        return 0.0;
      case _ParamTab.zoom:
        return widget.zoomRatio.clamp(_rulerMin, _rulerMax);
    }
  }

  String _rulerLabel(double v) {
    switch (_selectedTab) {
      case _ParamTab.iso:
        return v.toInt().toString();
      case _ParamTab.shutter:
        final ms = v;
        if (ms < 10) return '${ms.toStringAsFixed(1)}ms';
        return '${ms.toStringAsFixed(0)}ms';
      case _ParamTab.ev:
        final stops = v * widget.exposureOffsetStep;
        return stops >= 0
            ? '+${stops.toStringAsFixed(1)}'
            : stops.toStringAsFixed(1);
      case _ParamTab.focus:
        return '${v.toStringAsFixed(1)}D';
      case _ParamTab.wb:
        return '';
      case _ParamTab.zoom:
        return '${v.toStringAsFixed(1)}x';
    }
  }

  void _onRulerChanged(double v) {
    switch (_selectedTab) {
      case _ParamTab.iso:
        widget.onIsoChanged(v.round());
        break;
      case _ParamTab.shutter:
        widget.onExposureTimeNsChanged((v * 1e6).round());
        break;
      case _ParamTab.ev:
        widget.onEvIndexChanged(v.round());
        break;
      case _ParamTab.focus:
        widget.onFocusChanged(v);
        break;
      case _ParamTab.wb:
        break;
      case _ParamTab.zoom:
        widget.onZoomChanged(v);
        break;
    }
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      height: widget.isOpen ? _kDrawerHeight : 0,
      child: widget.isOpen
          ? Container(
              color: kPanelColor,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Divider(height: 1, thickness: 1, color: kBorderColor),
                  _buildTabRow(),
                  const Divider(height: 1, thickness: 1, color: kBorderColor),
                  SizedBox(height: _kControlHeight, child: _buildControlRow()),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildTabRow() {
    return SizedBox(
      height: _kTabBarHeight,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: _ParamTab.values.map((tab) {
            final isActive = tab == _selectedTab;
            return GestureDetector(
              onTap: () => setState(() => _selectedTab = tab),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
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
                    Icon(
                      _tabIcons[tab],
                      size: 13,
                      color: isActive ? Colors.white : kTextMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _tabLabels[tab]!,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: isActive
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: isActive ? Colors.white : kTextMuted,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildControlRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildAutoButton(),
        const VerticalDivider(width: 1, thickness: 1, color: kBorderColor),
        Expanded(child: _buildParamControl()),
      ],
    );
  }

  Widget _buildAutoButton() {
    final isActiveAuto = _isAuto;
    return GestureDetector(
      onTap: _onAutoTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 56,
        decoration: BoxDecoration(
          color: isActiveAuto ? kAccentActive : Colors.transparent,
          border: isActiveAuto
              ? const Border(right: BorderSide(color: kAccent, width: 1))
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActiveAuto ? kAccent : kBorderColor,
              ),
              child: Center(
                child: Text(
                  _autoLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isActiveAuto ? Colors.white : kTextMuted,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              isActiveAuto ? 'Auto' : 'Manual',
              style: TextStyle(
                fontSize: 9,
                color: isActiveAuto ? kAccent : kTextMuted,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildParamControl() {
    // WB tab: special lock/unlock UI
    if (_selectedTab == _ParamTab.wb) {
      return _buildWbControl();
    }

    // Show note when in auto mode (ISO/Shutter tabs with AE on)
    final showAutoNote =
        (_selectedTab == _ParamTab.iso || _selectedTab == _ParamTab.shutter) &&
        widget.aeEnabled;

    if (showAutoNote) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_mode, color: kAccent, size: 22),
            const SizedBox(height: 4),
            Text(
              'Auto Exposure Active',
              style: TextStyle(color: kTextSecondary, fontSize: 11),
            ),
            Text(
              'Press A to switch to manual',
              style: TextStyle(color: kTextMuted, fontSize: 10),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: RulerPicker(
        value: _rulerValue,
        min: _rulerMin,
        max: _rulerMax,
        step: _rulerStep,
        labelBuilder: _rulerLabel,
        onChanged: _onRulerChanged,
      ),
    );
  }

  Widget _buildWbControl() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _WbButton(
            label: 'Auto AWB',
            icon: Icons.wb_auto,
            isActive: !widget.wbLocked,
            onTap: widget.wbLocked ? widget.onUnlockWb : null,
          ),
          const SizedBox(width: 16),
          _WbButton(
            label: 'Lock WB',
            icon: Icons.lock,
            isActive: widget.wbLocked,
            onTap: !widget.wbLocked ? widget.onLockWb : null,
          ),
        ],
      ),
    );
  }
}

// ── WB button ────────────────────────────────────────────────────────────

class _WbButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback? onTap;

  const _WbButton({
    required this.label,
    required this.icon,
    required this.isActive,
    this.onTap,
  });

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
