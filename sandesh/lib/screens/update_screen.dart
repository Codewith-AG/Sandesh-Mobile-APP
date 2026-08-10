import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/update_service.dart';
import '../models/update_info.dart';
import '../widgets/update_dialog.dart';

class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  final UpdateService _updateService = UpdateService();
  String _currentVersion = 'Loading...';

  @override
  void initState() {
    super.initState();
    _loadVersion();
    // Force-check for updates when user opens this screen
    if (_updateService.state.value == UpdateState.idle ||
        _updateService.state.value == UpdateState.error ||
        _updateService.state.value == UpdateState.upToDate) {
      _updateService.checkForUpdate(forceCheck: true);
    }
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _currentVersion = '${info.version} (${info.buildNumber})';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('App Updates', style: GoogleFonts.outfit()),
        backgroundColor: Colors.transparent,
      ),
      body: ValueListenableBuilder<UpdateState>(
        valueListenable: _updateService.state,
        builder: (context, state, child) {
          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildVersionCard(cs),
                  const SizedBox(height: 16),
                  _buildStatusSection(cs, state),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildVersionCard(ColorScheme cs) {
    return Card(
      elevation: 0,
      color: cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            Icon(Icons.system_update, size: 48, color: cs.primary),
            const SizedBox(height: 16),
            Text('Sandesh',
                style: GoogleFonts.outfit(
                    fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('Current version: $_currentVersion',
                style: GoogleFonts.outfit(
                    fontSize: 14, color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusSection(ColorScheme cs, UpdateState state) {
    final updateInfo = _updateService.availableUpdate;

    if (state == UpdateState.checking) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: CircularProgressIndicator(),
        ),
      );
    } else if (state == UpdateState.upToDate) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            children: [
              Icon(Icons.check_circle_outline, size: 48, color: cs.primary),
              const SizedBox(height: 16),
              Text("You're up to date!",
                  style: GoogleFonts.outfit(fontSize: 16, color: cs.primary)),
            ],
          ),
        ),
      );
    } else if (state == UpdateState.error) {
      return Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            Icon(Icons.error_outline, color: cs.error, size: 48),
            const SizedBox(height: 16),
            Text(_updateService.lastError ?? 'Error checking for updates.',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(fontSize: 14, color: cs.error)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _updateService.checkForUpdate(forceCheck: true),
              child: Text('Retry', style: GoogleFonts.outfit()),
            )
          ],
        ),
      );
    } else if (state == UpdateState.updateAvailable ||
        state == UpdateState.downloading ||
        state == UpdateState.validating ||
        state == UpdateState.readyToInstall ||
        state == UpdateState.installing) {
      return _buildUpdateAvailable(cs, state, updateInfo);
    }

    // Idle state — show check button
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: ElevatedButton(
          onPressed: () => _updateService.checkForUpdate(forceCheck: true),
          child: Text('Check for updates', style: GoogleFonts.outfit()),
        ),
      ),
    );
  }

  Widget _buildUpdateAvailable(
      ColorScheme cs, UpdateState state, UpdateInfo? info) {
    if (info == null) return const SizedBox.shrink();

    return Card(
      elevation: 0,
      color: cs.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New Version Available',
                style: GoogleFonts.outfit(
                    fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Version: ${info.versionName} (${info.versionCode})',
                style: GoogleFonts.outfit(fontSize: 14)),
            if (info.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text("What's new:",
                  style: GoogleFonts.outfit(
                      fontSize: 16, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              Text(info.releaseNotes,
                  style: GoogleFonts.outfit(
                      fontSize: 14, color: cs.onSurfaceVariant)),
            ],
            const SizedBox(height: 24),
            _buildActionButtons(cs, state),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(ColorScheme cs, UpdateState state) {
    if (state == UpdateState.updateAvailable) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: cs.primary, foregroundColor: cs.onPrimary),
            onPressed: () => _startDownload(),
            child: Text('Download', style: GoogleFonts.outfit()),
          )
        ],
      );
    } else if (state == UpdateState.downloading) {
      return ValueListenableBuilder<double>(
          valueListenable: _updateService.downloadProgress,
          builder: (context, progress, child) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                    value: progress,
                    borderRadius: BorderRadius.circular(4)),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Downloading ${(progress * 100).toStringAsFixed(0)}%',
                        style: GoogleFonts.outfit()),
                    TextButton(
                      onPressed: () => _updateService.cancelDownload(),
                      child: Text('Cancel', style: GoogleFonts.outfit()),
                    )
                  ],
                )
              ],
            );
          });
    } else if (state == UpdateState.validating) {
      return Center(
          child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 8),
          Text('Validating update...', style: GoogleFonts.outfit()),
        ],
      ));
    } else if (state == UpdateState.readyToInstall) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: cs.primary, foregroundColor: cs.onPrimary),
            onPressed: () => _installUpdate(),
            child: Text('Install', style: GoogleFonts.outfit()),
          )
        ],
      );
    } else if (state == UpdateState.installing) {
      return Center(
          child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 8),
          Text('Installing...', style: GoogleFonts.outfit()),
        ],
      ));
    }
    return const SizedBox.shrink();
  }

  Future<void> _startDownload() async {
    await _updateService.downloadUpdate();
    // State transitions are handled by UpdateService via ValueNotifier
  }

  Future<void> _installUpdate() async {
    final canInstall = await _updateService.canRequestInstall();
    if (!canInstall) {
      if (!mounted) return;
      final allowResult = await showDialog<bool>(
        context: context,
        builder: (context) => const InstallPermissionDialog(),
      );
      if (allowResult == true) {
        await _updateService.openInstallPermissionSettings();
        // Wait a moment for user to return from settings
        await Future.delayed(const Duration(seconds: 1));
        // Re-check permission
        final nowCanInstall = await _updateService.canRequestInstall();
        if (!nowCanInstall) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Install permission not granted. You can enable it in Settings.',
                  style: GoogleFonts.outfit(),
                ),
              ),
            );
          }
          return;
        }
      } else {
        return;
      }
    }
    await _updateService.installUpdate();
  }
}
