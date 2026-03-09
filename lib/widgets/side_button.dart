import 'package:flutter/material.dart';
import '../app_theme.dart';

/// A vertical icon+label button for the left toolbar.
/// Active state is highlighted with the blue accent color.
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
    final baseColor = color ?? kTextSecondary;
    final effectiveColor = isDisabled
        ? kTextMuted
        : (isActive ? kAccent : baseColor);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isDisabled ? null : onTap,
        splashColor: kAccent.withValues(alpha: 0.15),
        highlightColor: kAccent.withValues(alpha: 0.08),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: isActive
              ? BoxDecoration(
                  color: kAccentActive,
                  border: const Border(
                    left: BorderSide(color: kAccent, width: 3),
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
