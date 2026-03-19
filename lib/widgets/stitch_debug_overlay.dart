import 'package:flutter/material.dart';

import '../stitcher/stitch_state.dart';

/// Compact debug card showing all 19 NavigationState fields.
/// Positioned below the MiniMap; width matches MiniMap (190 px).
class StitchDebugOverlay extends StatelessWidget {
  final NavigationState navState;
  final int pollTicks;
  final String? pollError;

  const StitchDebugOverlay({
    super.key,
    required this.navState,
    required this.pollTicks,
    this.pollError,
  });

  static const double kWidth = 190.0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = navState;

    return Container(
      width: kWidth,
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        border: Border.all(color: cs.outlineVariant, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: DefaultTextStyle(
        style: TextStyle(
          fontSize: 9.5,
          fontFamily: 'monospace',
          color: cs.onSurfaceVariant,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SectionHeader('NAV DEBUG', cs),
            _Row('poll', '#$pollTicks',
                 pollTicks > 0 ? cs.primary : cs.outline, cs),
            if (pollError != null)
              _Row('error', pollError!, cs.error, cs),
            _Row('state',   n.trackingStateName, _trackingColor(n.trackingState, cs), cs),
            _Row('frames',  '${n.frameCount}  stitched ${n.framesCaptured}', null, cs),
            _Row('ready',   n.captureReady ? 'YES' : 'no',
                 n.captureReady ? cs.primary : cs.outline, cs),

            _Divider(cs),
            _SectionHeader('POSE & MOTION', cs),
            _Row('pose',    '(${n.poseX.toStringAsFixed(1)}, ${n.poseY.toStringAsFixed(1)})', null, cs),
            _Row('vel',     '(${n.velocityX.toStringAsFixed(1)}, ${n.velocityY.toStringAsFixed(1)})', null, cs),
            _Row('speed',   '${n.speed.toStringAsFixed(1)} px/s', null, cs),

            _Divider(cs),
            _SectionHeader('QUALITY', cs),
            _Row('conf',    n.lastConfidence.toStringAsFixed(3), null, cs),
            _Row('sharp',   n.sharpness.toStringAsFixed(3), null, cs),
            _Row('quality', n.quality.toStringAsFixed(3), null, cs),
            _Row('overlap', n.overlapRatio.toStringAsFixed(3), null, cs),

            _Divider(cs),
            _SectionHeader('TIMING', cs),
            _Row('anal',    '${n.analysisTimeMs.toStringAsFixed(1)} ms', null, cs),
            _Row('comp',    '${n.compositeTimeMs.toStringAsFixed(1)} ms', null, cs),

            _Divider(cs),
            _SectionHeader('CANVAS', cs),
            if (n.canvasHasData) ...[
              _Row('min', '(${n.canvasMinX.toStringAsFixed(0)}, ${n.canvasMinY.toStringAsFixed(0)})', null, cs),
              _Row('max', '(${n.canvasMaxX.toStringAsFixed(0)}, ${n.canvasMaxY.toStringAsFixed(0)})', null, cs),
              _Row('size',
                '${(n.canvasMaxX - n.canvasMinX).toStringAsFixed(0)}'
                ' × '
                '${(n.canvasMaxY - n.canvasMinY).toStringAsFixed(0)}',
                null, cs),
            ] else
              _Row('canvas', 'empty', cs.outline, cs),
          ],
        ),
      ),
    );
  }

  Color _trackingColor(int state, ColorScheme cs) {
    switch (state) {
      case 1: return cs.primary;    // TRACKING
      case 2: return cs.tertiary;   // UNCERTAIN
      case 3: return cs.error;      // LOST
      default: return cs.outline;   // INIT
    }
  }
}

// ── Private helpers ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String text;
  final ColorScheme cs;
  const _SectionHeader(this.text, this.cs);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2, top: 1),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.w700,
          color: cs.primary,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final ColorScheme cs;
  const _Row(this.label, this.value, this.valueColor, this.cs);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0.5),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(label, style: TextStyle(color: cs.outline, fontSize: 9)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor, fontSize: 9.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  final ColorScheme cs;
  const _Divider(this.cs);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      height: 1,
      color: cs.outlineVariant,
    );
  }
}
