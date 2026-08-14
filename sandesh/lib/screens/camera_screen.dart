import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// A self-contained in-app camera capture screen.
///
/// Pushed by the chat screen's camera button. On a successful capture it pops
/// with the captured image's file path (`String`); if the user backs out it
/// pops with `null`. Live preview + capture + flip + flash are all handled here
/// so the camera works inside the app instead of delegating to the OS camera.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  FlashMode _flashMode = FlashMode.off;
  bool _initializing = true;
  bool _isCapturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupCameras();
  }

  Future<void> _setupCameras() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() {
          _error = 'No camera found on this device.';
          _initializing = false;
        });
        return;
      }
      // Prefer the back camera to start.
      _cameraIndex = _cameras.indexWhere(
          (c) => c.lensDirection == CameraLensDirection.back);
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _initController(_cameras[_cameraIndex]);
    } catch (e) {
      setState(() {
        _error = 'Failed to open camera: $e';
        _initializing = false;
      });
    }
  }

  Future<void> _initController(CameraDescription description) async {
    final previous = _controller;
    final controller = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: false,
    );
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setFlashMode(_flashMode);
      await previous?.dispose();
      if (mounted) setState(() => _initializing = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to initialise camera: $e';
          _initializing = false;
        });
      }
    }
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2) return;
    setState(() => _initializing = true);
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _initController(_cameras[_cameraIndex]);
  }

  Future<void> _toggleFlash() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    // Cycle: off -> auto -> torch -> off
    final next = _flashMode == FlashMode.off
        ? FlashMode.auto
        : _flashMode == FlashMode.auto
            ? FlashMode.torch
            : FlashMode.off;
    try {
      await controller.setFlashMode(next);
      if (mounted) setState(() => _flashMode = next);
    } catch (_) {}
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isCapturing ||
        controller.value.isTakingPicture) {
      return;
    }
    setState(() => _isCapturing = true);
    try {
      final XFile file = await controller.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } catch (e) {
      if (mounted) {
        setState(() => _isCapturing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initController(_cameras[_cameraIndex]);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  IconData get _flashIcon {
    switch (_flashMode) {
      case FlashMode.torch:
        return Icons.flash_on_rounded;
      case FlashMode.auto:
        return Icons.flash_auto_rounded;
      default:
        return Icons.flash_off_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _error != null
            ? _buildError()
            : _initializing || _controller == null
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.white))
                : _buildCamera(),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_rounded,
                color: Colors.white70, size: 56),
            const SizedBox(height: 16),
            Text(
              _error ?? 'Camera unavailable',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCamera() {
    final controller = _controller!;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Live preview, centered and covering the screen.
        Center(
          child: CameraPreview(controller),
        ),

        // Top bar: close + flash.
        Positioned(
          top: 8,
          left: 4,
          right: 4,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 30),
                onPressed: () => Navigator.of(context).pop(),
              ),
              IconButton(
                icon: Icon(_flashIcon, color: Colors.white, size: 28),
                onPressed: _toggleFlash,
              ),
            ],
          ),
        ),

        // Bottom controls: flip + shutter.
        Positioned(
          bottom: 32,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              const SizedBox(width: 56),
              // Shutter button
              GestureDetector(
                onTap: _isCapturing ? null : _capture,
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.25),
                    border: Border.all(color: Colors.white, width: 4),
                  ),
                  child: _isCapturing
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 3),
                        )
                      : const Center(
                          child: Icon(Icons.camera_alt_rounded,
                              color: Colors.white, size: 30),
                        ),
                ),
              ),
              // Flip camera
              SizedBox(
                width: 56,
                child: _cameras.length > 1
                    ? IconButton(
                        icon: const Icon(Icons.flip_camera_ios_rounded,
                            color: Colors.white, size: 32),
                        onPressed: _flipCamera,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
