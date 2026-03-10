import 'package:flutter/material.dart';

/// A vertical icon+label button for the left toolbar.
/// Active state is highlighted with the theme's primary colour.
class SideButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool isActive;
  final bool isDisabled;
  final bool isLarge;
  final Color? color;

  const SideButton({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.isActive = false,
    this.isDisabled = false,
    this.isLarge = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final baseColor = color ?? cs.onSurfaceVariant;
    // When active, honour explicit `color` prop (e.g. tertiary for scanning)
    // before falling back to the theme primary.
    final effectiveColor = isDisabled
        ? cs.outline
        : (isActive ? (color ?? cs.primary) : baseColor);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isDisabled ? null : onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: isActive
              ? BoxDecoration(
                  color: cs.primaryContainer,
                  border: Border(
                    left: BorderSide(color: effectiveColor, width: 3),
                  ),
                )
              : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: effectiveColor, size: isLarge ? 34 : 24),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: effectiveColor,
                  fontSize: 10,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                  letterSpacing: 0.3,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
