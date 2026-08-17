import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/update_info.dart';
import '../theme/app_theme.dart';

class UpdateAvailableDialog extends StatelessWidget {
  final UpdateInfo updateInfo;
  final VoidCallback onUpdate;
  final VoidCallback onLater;

  const UpdateAvailableDialog({
    super.key,
    required this.updateInfo,
    required this.onUpdate,
    required this.onLater,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text('Update Available', style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sandesh v${updateInfo.versionName} is now available.',
              style: GoogleFonts.inter()),
          if (updateInfo.formattedSize != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.sd_storage_outlined,
                    size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text('Download size: ${updateInfo.formattedSize}',
                    style: GoogleFonts.inter(
                        fontSize: 13, color: cs.onSurfaceVariant)),
              ],
            ),
          ],
          if (updateInfo.releaseNotes.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('What\'s new:',
                style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(updateInfo.releaseNotes, style: GoogleFonts.inter(fontSize: 14)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: onLater,
          child: Text('Later', style: GoogleFonts.inter()),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary, foregroundColor: cs.onPrimary),
          onPressed: onUpdate,
          child: Text('Update now', style: GoogleFonts.inter()),
        ),
      ],
    );
  }
}

class InstallPermissionDialog extends StatelessWidget {
  const InstallPermissionDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text('Allow Updates', style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
      content: Text(
        'To install the update, Sandesh needs permission to install unknown apps. You will be redirected to settings to allow this.',
        style: GoogleFonts.inter(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Not now', style: GoogleFonts.inter()),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary, foregroundColor: cs.onPrimary),
          onPressed: () => Navigator.pop(context, true),
          child: Text('Allow updates', style: GoogleFonts.inter()),
        ),
      ],
    );
  }
}

/// Shown when the user taps "Download" while "Wi-Fi only" is on but the device
/// is on mobile data. Warns about data usage and shows the total update size,
/// then lets the user proceed over mobile data or cancel.
class NoWifiWarningDialog extends StatelessWidget {
  final UpdateInfo updateInfo;

  const NoWifiWarningDialog({super.key, required this.updateInfo});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = updateInfo.formattedSize;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Row(
        children: [
          Icon(Icons.signal_cellular_alt, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text("You're not on Wi-Fi",
                style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            size != null
                ? 'This update is $size and will be downloaded using your mobile data, which may incur charges.'
                : 'This update will be downloaded using your mobile data, which may incur charges.',
            style: GoogleFonts.inter(),
          ),
          const SizedBox(height: 12),
          Text('Do you want to install without Wi-Fi?',
              style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Cancel', style: GoogleFonts.inter()),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary, foregroundColor: cs.onPrimary),
          onPressed: () => Navigator.pop(context, true),
          child: Text('Install without Wi-Fi', style: GoogleFonts.inter()),
        ),
      ],
    );
  }
}

class UpdateReadyDialog extends StatelessWidget {
  final String version;
  final VoidCallback onInstall;

  const UpdateReadyDialog({
    super.key,
    required this.version,
    required this.onInstall,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text('Update Ready', style: GoogleFonts.inter(fontWeight: FontWeight.bold)),
      content: Text('Sandesh v$version is ready to install.', style: GoogleFonts.inter()),
      actions: [
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: cs.primary, foregroundColor: cs.onPrimary),
          onPressed: onInstall,
          child: Text('Install now', style: GoogleFonts.inter()),
        ),
      ],
    );
  }
}

class MandatoryUpdateBanner extends StatelessWidget {
  final VoidCallback onUpdate;

  const MandatoryUpdateBanner({super.key, required this.onUpdate});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      color: AppTheme.danger,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 36),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Mandatory Update',
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.bold,
                          color: Colors.white)),
                  const SizedBox(height: 4),
                  Text('A critical update is required to continue using Sandesh.',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: Colors.white)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppTheme.danger),
              onPressed: onUpdate,
              child: Text('Update', style: GoogleFonts.inter()),
            ),
          ],
        ),
      ),
    );
  }
}
