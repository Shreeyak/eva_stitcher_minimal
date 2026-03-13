import 'package:flutter/material.dart';
import 'package:eva_camera/eva_camera.dart';

/// Service to handle dumping and formatting camera settings to disk.
class CameraSettingsDumper {
  /// Invokes the native dump and shows a SnackBar with the result.
  static Future<void> dumpAndNotify(BuildContext context) async {
    try {
      final result = await CameraControl.dumpActiveCameraSettings();
      final filePath = result['filePath'] as String? ?? '';
      final keyCount = (result['keyCount'] as num?)?.toInt() ?? 0;
      final supportedKeyCount =
          (result['supportedKeyCount'] as num?)?.toInt() ?? 0;

      debugPrint('=== Camera settings dumped ===');
      debugPrint('Key count: $keyCount (supported: $supportedKeyCount)');
      debugPrint('Saved file: $filePath');

      if (!context.mounted) return;

      _showSuccessSnackBar(context, filePath, supportedKeyCount);
    } catch (e) {
      debugPrint('Dump settings failed: $e');
      if (!context.mounted) return;
      _showErrorSnackBar(context, e.toString());
    }
  }

  static void _showSuccessSnackBar(
    BuildContext context,
    String filePath,
    int supportedKeyCount,
  ) {
    final cs = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final double hMargin = screenWidth >= 600 ? screenWidth * 0.15 : 16.0;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: cs.surfaceContainerHigh.withAlpha(217),
        elevation: 4,
        margin: EdgeInsets.only(left: hMargin, right: hMargin, bottom: 60),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        content: Row(
          children: [
            Icon(Icons.save_as_outlined, color: cs.primary, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Settings Dumped Successfully',
                    style: TextStyle(
                      color: cs.onSurface,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Saved to: $filePath',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'DISMISS',
          textColor: cs.primary,
          onPressed: () {},
        ),
      ),
    );
  }

  static void _showErrorSnackBar(BuildContext context, String error) {
    final cs = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final double hMargin = screenWidth >= 600 ? screenWidth * 0.2 : 16.0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Dump settings failed: $error',
          style: TextStyle(color: cs.onErrorContainer),
        ),
        backgroundColor: cs.errorContainer,
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(left: hMargin, right: hMargin, bottom: 60),
      ),
    );
  }
}
