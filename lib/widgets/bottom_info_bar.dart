import 'package:flutter/material.dart';

/// Fixed-height bottom bar showing scan status, frame counts and session time.
class BottomInfoBar extends StatelessWidget {
  final bool isScanning;
  final int frameCount;
  final int stitchedCount;
  final int totalTarget;
  final double coveragePct;
  final int sessionSeconds;

  const BottomInfoBar({
    super.key,
    required this.isScanning,
    required this.frameCount,
    required this.stitchedCount,
    required this.totalTarget,
    required this.coveragePct,
    required this.sessionSeconds,
  });

  String get _sessionLabel {
    final h = sessionSeconds ~/ 3600;
    final m = (sessionSeconds % 3600) ~/ 60;
    final s = sessionSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:'
        '${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      decoration: BoxDecoration(color: cs.surfaceContainerLowest),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Status badge
          _StatusBadge(isScanning: isScanning),
          const SizedBox(width: 16),

          const _Divider(),

          // Frames
          _InfoChip(
            icon: Icons.image_outlined,
            label: 'FRAMES',
            value: '$frameCount',
          ),
          const _Divider(),

          // Stitched
          _InfoChip(
            icon: Icons.grid_view_outlined,
            label: 'STITCHED',
            value: '$stitchedCount / $totalTarget',
          ),
          const _Divider(),

          // Coverage
          _InfoChip(
            icon: Icons.area_chart_outlined,
            label: 'COVERAGE',
            value: '${coveragePct.toStringAsFixed(1)}%',
          ),
          const _Divider(),

          // Session timer
          _InfoChip(
            icon: Icons.timer_outlined,
            label: 'SESSION',
            value: _sessionLabel,
          ),

          const SizedBox(width: 12),
        ],
      ),
    );
  }
}

// ── Private helpers ───────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final bool isScanning;
  const _StatusBadge({required this.isScanning});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Scanning: primary (active accent). Idle: tertiary (warm gold = ready/ok).
    final color = isScanning ? cs.primary : cs.tertiary;
    final label = isScanning ? 'SCANNING' : 'IDLE';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 4),
            ],
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: cs.outline),
          const SizedBox(width: 4),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: '$label ',
                  style: TextStyle(
                    fontSize: 9,
                    color: cs.outline,
                    letterSpacing: 0.8,
                  ),
                ),
                TextSpan(
                  text: value,
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSurfaceVariant,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}
