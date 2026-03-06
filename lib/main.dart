import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'camera_control.dart';
import 'widgets/bottom_info_bar.dart';
import 'widgets/camera_settings_drawer.dart';
import 'widgets/canvas_view.dart';
import 'widgets/left_toolbar.dart';
import 'widgets/mini_map.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const EvaApp());
}

// ── App root ────────────────────────────────────────────────────────────

class EvaApp extends StatelessWidget {
  const EvaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EVA - Whole Slide Imaging',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kBgColor,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          surface: kPanelColor,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: kPanelColor,
          contentTextStyle: const TextStyle(color: kTextSecondary),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: kBorderColor),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
      home: const CameraScreen(),
    );
  }
}

// CameraControl moved to lib/camera_control.dart

// ── Camera screen ───────────────────────────────────────────────────────

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  // ── Permission / camera lifecycle ──────────────────────────────────
  bool _permissionGranted = false;
  bool _cameraStarted = false;

  // ── Camera controls ────────────────────────────────────────────────
  bool _afEnabled = true;
  bool _aeEnabled = true;
  bool _wbLocked = false;

  // Focus
  double _minFocusDistance = 0.0;
  double _currentFocusDistance = 0.0;

  // EV offset (AE-on path)
  int _exposureOffsetIndex = 0;
  List<int> _exposureOffsetRange = [0, 0];
  double _exposureOffsetStep = 0.0;

  // Manual sensor exposure + ISO (AE-off path)
  int _exposureTimeNs = 1000000; // 1 ms default
  List<int> _exposureTimeRangeNs = [1000000, 1000000000];
  int _isoValue = 200;
  List<int> _isoRange = [100, 3200];

  // Zoom
  double _minZoomRatio = 1.0;
  double _maxZoomRatio = 1.0;
  double _currentZoomRatio = 1.0;

  // Resolution info (display only)
  String _captureResolution = '--';
  String _analysisResolution = '--';

  // ── EventChannel state ────────────────────────────────────────────
  int _frameCount = 0;
  double _fps = 0.0;
  StreamSubscription<Map<dynamic, dynamic>>? _eventSub;

  // ── UI state ──────────────────────────────────────────────────────
  bool _isScanning = false;
  bool _showCanvas = false;
  bool _settingsDrawerOpen = false;

  // ── Session timer ─────────────────────────────────────────────────
  int _sessionSeconds = 0;
  int _stitchedCount = 0;
  Timer? _sessionTimer;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final granted = await CameraControl.requestPermission();
    if (!mounted) return;
    setState(() => _permissionGranted = granted);
    if (!granted) return;
    await _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      final info = await CameraControl.startCamera();
      if (!mounted) return;

      final cw = info['captureWidth'] ?? '--';
      final ch = info['captureHeight'] ?? '--';
      final aw = info['analysisWidth'] ?? '--';
      final ah = info['analysisHeight'] ?? '--';

      setState(() {
        _cameraStarted = true;
        _captureResolution = '${cw}x$ch';
        _analysisResolution = '${aw}x$ah';
      });

      // Fetch device capability ranges in parallel
      final results = await Future.wait([
        CameraControl.getMinFocusDistance(),
        CameraControl.getExposureOffsetStep().then((v) => v),
        CameraControl.getMinZoomRatio(),
        CameraControl.getMaxZoomRatio(),
      ]);
      final listResults = await Future.wait([
        CameraControl.getExposureOffsetRange(),
        CameraControl.getExposureTimeRangeNs(),
        CameraControl.getIsoRange(),
      ]);

      if (!mounted) return;
      setState(() {
        _minFocusDistance = results[0];
        _currentFocusDistance = (_minFocusDistance / 2).clamp(
          0.0,
          _minFocusDistance,
        );
        _exposureOffsetStep = results[1];
        _minZoomRatio = results[2];
        _maxZoomRatio = results[3];
        _currentZoomRatio = _minZoomRatio;

        _exposureOffsetRange = listResults[0];
        _exposureOffsetIndex = 0;
        _exposureTimeRangeNs = listResults[1];
        _exposureTimeNs = _exposureTimeRangeNs[0].clamp(
          1000000,
          _exposureTimeRangeNs[1],
        );
        _isoRange = listResults[2];
        _isoValue = _isoRange[0].clamp(200, _isoRange[1]);
      });

      _listenToEvents();
    } catch (e) {
      if (!mounted) return;
      _showError('Camera error: $e');
    }
  }

  void _listenToEvents() {
    _eventSub = CameraControl.eventStream.listen((event) {
      if (!mounted) return;
      final type = event['type'] as String? ?? 'status';
      final tag = event['tag'] as String? ?? '';
      final message = event['message'] as String? ?? '';
      final data = event['data'] as Map? ?? {};

      if (tag == 'fps') {
        setState(() {
          _frameCount = (data['frameCount'] as num?)?.toInt() ?? _frameCount;
          _fps = (data['fps'] as num?)?.toDouble() ?? _fps;
        });
      } else if (tag == 'cameraSettings') {
        debugPrint('cameraSettings: $message');
      } else if (type == 'warning') {
        _showWarning(message);
      } else if (type == 'error') {
        _showError(message);
      }
    }, onError: (e) => debugPrint('Event stream error: $e'));
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _sessionTimer?.cancel();
    CameraControl.stopCamera();
    super.dispose();
  }

  // ── Snackbar helpers ──────────────────────────────────────────────

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red[900],
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _showWarning(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.orange[900],
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ── Camera actions ────────────────────────────────────────────────

  Future<void> _tapToLockWb() async {
    try {
      await CameraControl.lockWhiteBalance();
      if (mounted) setState(() => _wbLocked = true);
    } catch (e) {
      _showWarning('WB lock failed: $e');
    }
  }

  Future<void> _toggleAe() async {
    final prev = _aeEnabled;
    setState(() => _aeEnabled = !_aeEnabled);
    try {
      await CameraControl.setAeEnabled(_aeEnabled);
    } catch (e) {
      if (!mounted) return;
      setState(() => _aeEnabled = prev);
      _showError('AE toggle failed: $e');
    }
  }

  Future<void> _toggleAf() async {
    final prev = _afEnabled;
    if (_afEnabled) {
      try {
        final dist = await CameraControl.getCurrentFocusDistance();
        if (mounted) setState(() => _currentFocusDistance = dist);
      } catch (_) {}
    }
    setState(() => _afEnabled = !_afEnabled);
    try {
      await CameraControl.setAfEnabled(_afEnabled);
    } catch (e) {
      if (!mounted) return;
      setState(() => _afEnabled = prev);
      _showError('AF toggle failed: $e');
    }
  }

  Future<void> _lockWb() async {
    try {
      await CameraControl.lockWhiteBalance();
      if (mounted) setState(() => _wbLocked = true);
    } catch (e) {
      _showWarning('WB lock failed: $e');
    }
  }

  Future<void> _unlockWb() async {
    try {
      await CameraControl.unlockWhiteBalance();
      if (mounted) setState(() => _wbLocked = false);
    } catch (e) {
      _showError('WB unlock failed: $e');
    }
  }

  void _onIsoChanged(int iso) {
    setState(() => _isoValue = iso);
    CameraControl.setIso(iso);
  }

  void _onExposureTimeNsChanged(int ns) {
    setState(() => _exposureTimeNs = ns);
    CameraControl.setExposureTimeNs(ns);
  }

  void _onEvIndexChanged(int index) {
    setState(() => _exposureOffsetIndex = index);
    CameraControl.setExposureOffset(index);
  }

  void _onFocusChanged(double dist) {
    setState(() => _currentFocusDistance = dist);
    CameraControl.setFocusDistance(dist);
  }

  void _onZoomChanged(double ratio) {
    setState(() => _currentZoomRatio = ratio);
    CameraControl.setZoomRatio(ratio);
  }

  // ── Scan / session ────────────────────────────────────────────────

  void _toggleScan() {
    setState(() => _isScanning = !_isScanning);
    if (_isScanning) {
      _sessionTimer?.cancel();
      _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _sessionSeconds++);
      });
    } else {
      _sessionTimer?.cancel();
    }
  }

  void _onReset() {
    setState(() {
      _isScanning = false;
      _stitchedCount = 0;
      _sessionSeconds = 0;
      _showCanvas = false;
    });
    _sessionTimer?.cancel();
  }

  void _onExport() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Export not yet implemented')));
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBgColor,
      body: Row(
        children: [
          // ── Left toolbar ──
          LeftToolbar(
            isScanning: _isScanning,
            showCanvas: _showCanvas,
            settingsOpen: _settingsDrawerOpen,
            canExport: false,
            onToggleScan: _toggleScan,
            onToggleCanvas: () => setState(() => _showCanvas = !_showCanvas),
            onToggleSettings: () =>
                setState(() => _settingsDrawerOpen = !_settingsDrawerOpen),
            onReset: _onReset,
            onExport: _onExport,
          ),

          // ── Main content area ──
          Expanded(
            child: Stack(
              children: [
                // Camera preview (always rendered behind everything)
                if (_permissionGranted)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _cameraStarted ? _tapToLockWb : null,
                      child: _buildCameraPreview(),
                    ),
                  )
                else
                  const Center(
                    child: Text(
                      'Camera permission required',
                      style: TextStyle(color: kTextSecondary, fontSize: 16),
                    ),
                  ),

                // Canvas overlay (toggled by toolbar)
                if (_showCanvas) const Positioned.fill(child: CanvasView()),

                // MiniMap — top right
                const Positioned(
                  top: 8,
                  right: 8,
                  child: MiniMap(frameCount: 0),
                ),

                // Settings drawer + info bar pinned to bottom
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_cameraStarted)
                        CameraSettingsDrawer(
                          isOpen: _settingsDrawerOpen,
                          aeEnabled: _aeEnabled,
                          afEnabled: _afEnabled,
                          wbLocked: _wbLocked,
                          isoValue: _isoValue,
                          isoRange: _isoRange,
                          exposureTimeNs: _exposureTimeNs,
                          exposureTimeRangeNs: _exposureTimeRangeNs,
                          exposureOffsetIndex: _exposureOffsetIndex,
                          exposureOffsetRange: _exposureOffsetRange,
                          exposureOffsetStep: _exposureOffsetStep,
                          focusDistance: _currentFocusDistance,
                          minFocusDistance: _minFocusDistance,
                          zoomRatio: _currentZoomRatio,
                          minZoomRatio: _minZoomRatio,
                          maxZoomRatio: _maxZoomRatio,
                          onToggleAe: _toggleAe,
                          onToggleAf: _toggleAf,
                          onLockWb: _lockWb,
                          onUnlockWb: _unlockWb,
                          onIsoChanged: _onIsoChanged,
                          onExposureTimeNsChanged: _onExposureTimeNsChanged,
                          onEvIndexChanged: _onEvIndexChanged,
                          onFocusChanged: _onFocusChanged,
                          onZoomChanged: _onZoomChanged,
                        ),
                      BottomInfoBar(
                        isScanning: _isScanning,
                        frameCount: _frameCount,
                        stitchedCount: _stitchedCount,
                        totalTarget: 0,
                        coveragePct: 0.0,
                        sessionSeconds: _sessionSeconds,
                      ),
                    ],
                  ),
                ),

                // Resolution debug badge (top-left, subtle)
                if (_cameraStarted)
                  Positioned(top: 8, left: 8, child: _buildResolutionBadge()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Helper widgets ────────────────────────────────────────────────

  Widget _buildCameraPreview() {
    return PlatformViewLink(
      viewType: 'camerax-preview',
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          gestureRecognizers: const {},
        );
      },
      onCreatePlatformView: (params) {
        return PlatformViewsService.initExpensiveAndroidView(
            id: params.id,
            viewType: 'camerax-preview',
            layoutDirection: TextDirection.ltr,
            creationParamsCodec: const StandardMessageCodec(),
          )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
    );
  }

  Widget _buildResolutionBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: kPanelColor.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: kBorderColor),
      ),
      child: Text(
        'Cap: $_captureResolution  |  Ana: $_analysisResolution'
        '  |  ${_fps.toStringAsFixed(1)} fps',
        style: const TextStyle(
          color: kTextMuted,
          fontSize: 9,
          fontFamily: 'monospace',
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
