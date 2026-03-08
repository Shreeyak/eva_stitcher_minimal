import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'camera_control.dart';
import 'widgets/bottom_info_bar.dart';
import 'widgets/camera_settings_drawer.dart';
import 'widgets/camera_ruler_slider/camera_dial_presets.dart';
import 'widgets/camera_ruler_slider/camera_ruler_slider.dart';
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
  bool _wbLocked = false;

  // Focus
  double _minFocusDistance = 0.0;
  double _currentFocusDistance = 0.0;

  // Manual sensor exposure + ISO
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

  /// Which "floating" param is currently showing its [CameraRulerSlider]
  /// overlay above the camera preview.  Null = no overlay visible.
  /// Set by [_onHoverParamTap]; cleared when the drawer is closed.
  CameraParam? _hoverParam;

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
        CameraControl.getMinZoomRatio(),
        CameraControl.getMaxZoomRatio(),
      ]);
      final listResults = await Future.wait([
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
        _minZoomRatio = results[1];
        _maxZoomRatio = results[2];
        _currentZoomRatio = _minZoomRatio;

        _exposureTimeRangeNs = listResults[0];
        _exposureTimeNs = _exposureTimeRangeNs[0].clamp(
          1000000,
          _exposureTimeRangeNs[1],
        );
        _isoRange = listResults[1];
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

  /// Called by [CameraSettingsDrawer] when the user taps a chip in the strip.
  /// Toggling the same chip collapses the floating overlay.
  void _onHoverParamTap(CameraParam? p) {
    setState(() => _hoverParam = p);
  }

  void _onIsoChanged(int iso) {
    setState(() => _isoValue = iso);
    CameraControl.setIso(iso);
  }

  void _onExposureTimeNsChanged(int ns) {
    setState(() => _exposureTimeNs = ns);
    CameraControl.setExposureTimeNs(ns);
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
      body: SafeArea(
        top: true,
        bottom: false,
        left: false,
        right: false,
        child: Row(
          children: [
            // ── Left toolbar ──
            LeftToolbar(
              isScanning: _isScanning,
              showCanvas: _showCanvas,
              settingsOpen: _settingsDrawerOpen,
              canExport: false,
              onToggleScan: _toggleScan,
              onToggleCanvas: () => setState(() => _showCanvas = !_showCanvas),
              onToggleSettings: () => setState(() {
                _settingsDrawerOpen = !_settingsDrawerOpen;
                // Collapse the floating slider when the whole drawer is closed.
                if (!_settingsDrawerOpen) _hoverParam = null;
              }),
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
                            hoverParam: _hoverParam,
                            onHoverParamTap: _onHoverParamTap,
                            afEnabled: _afEnabled,
                            wbLocked: _wbLocked,
                            onToggleAf: _toggleAf,
                            onLockWb: _lockWb,
                            onUnlockWb: _unlockWb,
                            isoValue: _isoValue,
                            exposureTimeNs: _exposureTimeNs,
                            focusDistance: _currentFocusDistance,
                            zoomRatio: _currentZoomRatio,
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

                  // Floating ruler slider — hovers above the icon strip.
                  // Only shown when the drawer is open and a chip is active.
                  //
                  // Vertical position: bottom of screen minus info bar (36 px) +
                  // settings strip (52 px) + 12 px breathing room = 100 px.
                  if (_hoverParam != null &&
                      _settingsDrawerOpen &&
                      _cameraStarted)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 100,
                      // Cap height so the panel can never grow tall enough to
                      // overlap with widgets pinned to the top of the screen.
                      height: 80,
                      child: _buildHoverSlider(),
                    ),

                  // Resolution debug badge (top-left, subtle)
                  if (_cameraStarted)
                    Positioned(top: 8, left: 8, child: _buildResolutionBadge()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Floating hover slider ─────────────────────────────────────────

  /// Builds the floating [CameraRulerSlider] (or WB action panel) that hovers
  /// above the camera preview when a floating-param chip is selected.
  ///
  /// The widget is positioned by the parent [Positioned] at `bottom: 100`,
  /// sitting above the icon strip (52 px) + info bar (36 px) + gap (12 px).
  Widget _buildHoverSlider() {
    final activeParam = _hoverParam;
    if (activeParam == null) return const SizedBox.shrink();
    if (activeParam == CameraParam.wb) return _buildHoverWb();

    final CameraDialModel model;
    switch (activeParam) {
      case CameraParam.iso:
        model = IsoDialPreset(
          isoRange: _isoRange,
          isoValue: _isoValue,
          onIsoChanged: _onIsoChanged,
        ).toModel();
        break;
      case CameraParam.shutter:
        model = ShutterDialPreset(
          exposureTimeRangeNs: _exposureTimeRangeNs,
          exposureTimeNs: _exposureTimeNs,
          onExposureTimeNsChanged: _onExposureTimeNsChanged,
        ).toModel();
        break;
      case CameraParam.zoom:
        model = ZoomDialPreset(
          minZoomRatio: _minZoomRatio,
          maxZoomRatio: _maxZoomRatio,
          currentZoomRatio: _currentZoomRatio,
          onZoomChanged: _onZoomChanged,
        ).toModel();
        break;
      case CameraParam.focus:
        model = FocusDialPreset(
          minFocusDistance: _minFocusDistance,
          currentFocusDistance: _currentFocusDistance,
          onFocusChanged: _onFocusChanged,
        ).toModel();
        break;
      case CameraParam.wb:
        return _buildHoverWb();
    }

    final config = model.config;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        // ClipRRect is the capsule clip boundary — no padding so ticks fill
        // edge-to-edge and are smoothly cut by the curve.
        child: ClipRRect(
          borderRadius: BorderRadius.circular(100),
          child: ColoredBox(
            color: const Color(0xFF1A1A1A).withValues(alpha: 0.82),
            child: CameraRulerSlider(
              key: ValueKey(activeParam),
              config: config,
              initialValue: model.initialValue,
              onChanged: model.onChanged,
              fadeColor: Colors.black,
              leftIcon: Icon(
                config.leftIcon,
                size: config.iconSize,
                color: Colors.white.withValues(alpha: 0.5),
              ),
              rightIcon: Icon(
                config.rightIcon,
                size: config.iconSize,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Floating WB panel — shown instead of a numeric slider since WB has no
  /// user-adjustable scalar; it is either running auto or locked to a captured
  /// colour-correction matrix.
  Widget _buildHoverWb() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: kPanelColor.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorderColor),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _hoverWbButton(
            label: 'Auto AWB',
            icon: Icons.wb_auto,
            isActive: !_wbLocked,
            // onTap is null when this state is already active
            onTap: _wbLocked ? _unlockWb : null,
          ),
          const SizedBox(width: 16),
          _hoverWbButton(
            label: 'Lock WB',
            icon: Icons.lock,
            isActive: _wbLocked,
            onTap: !_wbLocked ? _lockWb : null,
          ),
        ],
      ),
    );
  }

  /// A single action button used in the floating WB panel.
  Widget _hoverWbButton({
    required String label,
    required IconData icon,
    required bool isActive,
    VoidCallback? onTap,
  }) {
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
    return RepaintBoundary(
      child: Container(
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
      ),
    );
  }
}
