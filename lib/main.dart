import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import 'theme/material_theme_salmon.dart';
import 'theme/theme_util.dart';
import 'package:eva_camera/eva_camera.dart';
import 'widgets/bottom_info_bar.dart';
import 'widgets/interactive_bottom_bar.dart';
import 'widgets/canvas_view.dart';
import 'widgets/camera_control_overlay.dart';
import 'widgets/mini_map.dart';
import 'widgets/bottom_bar_buttons.dart';

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
    final materialTheme = MaterialTheme(createTextTheme('Roboto', 'Noto Sans'));
    return MaterialApp(
      title: 'EVA - Whole Slide Imaging',
      debugShowCheckedModeBanner: false,
      darkTheme: materialTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const CameraScreen(),
    );
  }
}

// CameraControl and camera state live in lib/camera/.

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

  // ── Camera state (grouped) ─────────────────────────────────────────
  CameraValues _values = const CameraValues();
  CameraRanges _ranges = const CameraRanges();
  CameraInfo _info = const CameraInfo();
  late final CameraCallbacks _callbacks;

  // ── EventChannel ──────────────────────────────────────────────────
  StreamSubscription<CameraInfo>? _eventSub;

  // ── Camera command sequencing ─────────────────────────────────────
  late final CameraSettingsQueue _settingsQueue;
  Timer? _afFocusSyncTimer;
  bool _afFocusSyncInFlight = false;

  // ── UI state ──────────────────────────────────────────────────────
  bool _isScanning = false;
  bool _showCanvas = false;
  bool _settingsDrawerOpen = false;

  /// Last WB-lock value that was *confirmed* by native (before any pending
  /// optimistic flip). Used to revert the UI if the native call fails.
  bool _committedWbLocked = false;

  /// Which setting chip is currently active, showing its [CameraRulerDial]
  /// overlay above the camera preview.  Null = no overlay visible.
  /// Set by [_onSettingChipTap]; cleared when the drawer is closed.
  CameraSettingType? _activeSetting;

  // ── Session timer ─────────────────────────────────────────────────
  int _sessionSeconds = 0;
  int _stitchedCount = 0;
  Timer? _sessionTimer;

  @override
  void initState() {
    super.initState();
    _initSettingsQueue();
    _callbacks = CameraCallbacks(
      onIsoChanged: _onIsoChanged,
      onExposureTimeNsChanged: _onExposureTimeNsChanged,
      onFocusChanged: _onFocusChanged,
      onZoomChanged: _onZoomChanged,
      onWbLockChanged: _setWbLocked,
      onToggleAf: _toggleAf,
    );
    _initCamera();
  }

  /// Initializes a unified latest-wins queue for camera-setting writes.
  ///
  /// UI state still updates immediately in callbacks. The queue only serializes
  /// native writes so rapid scrubs don't pile up or interleave.
  void _initSettingsQueue() {
    _settingsQueue = CameraSettingsQueue(
      sendAf: CameraControl.setAfEnabled,
      sendFocus: CameraControl.setFocusDistance,
      sendIso: CameraControl.setIso,
      sendShutter: CameraControl.setExposureTimeNs,
      sendZoom: CameraControl.setZoomRatio,
      sendWbLock: CameraControl.setWbLocked,
      initialAfEnabled: _values.afEnabled,
      onError: (key, error) {
        if (!mounted) return;
        switch (key) {
          case CameraSettingType.af:
            _showError('AF update failed: $error');
            break;
          case CameraSettingType.focus:
            _showError('Focus update failed: $error');
            break;
          case CameraSettingType.iso:
            _showWarning('ISO update failed: $error');
            break;
          case CameraSettingType.shutter:
            _showWarning('Shutter update failed: $error');
            break;
          case CameraSettingType.zoom:
            _showWarning('Zoom update failed: $error');
            break;
          case CameraSettingType.wb:
            _showWarning('WB update failed: $error');
            // Revert to the last confirmed native WB state.
            // Using _committedWbLocked (captured before the optimistic flip)
            // is safer than !_values.wbLocked, which can be wrong if the user
            // tapped lock→unlock quickly and the two flips crossed in flight.
            if (mounted) {
              setState(
                () => _values = _values.copyWith(wbLocked: _committedWbLocked),
              );
            }
            break;
        }
      },
    );
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

      final cw = info.captureWidth?.toString() ?? '--';
      final ch = info.captureHeight?.toString() ?? '--';
      final aw = info.analysisWidth?.toString() ?? '--';
      final ah = info.analysisHeight?.toString() ?? '--';

      setState(() {
        _cameraStarted = true;
        _info = _info.copyWith(
          captureResolution: '${cw}x$ch',
          analysisResolution: '${aw}x$ah',
        );
      });

      final ranges = CameraRanges(
        minFocusDistance: info.minFocusDistance,
        minZoomRatio: info.minZoomRatio,
        maxZoomRatio: info.maxZoomRatio,
        exposureTimeRangeNs: info.exposureTimeRangeNs,
        isoRange: info.isoRange,
      );
      final initial = CameraValues.initialFromRanges(ranges);

      setState(() {
        _ranges = ranges;
        _values = initial;
      });

      // Sync computed initial values to the native camera.
      //
      // IMPORTANT: setIso, setExposureTimeNs, and setFocusDistance all call
      // applyAllCaptureOptions → Camera2CameraControl.setCaptureRequestOptions.
      // Camera2 cancels any pending setCaptureRequestOptions future when a new
      // one is submitted, throwing CancellationException on the earlier calls.
      // Running them in parallel via Future.wait causes every call except the
      // last to fail with ISO_SET_FAILED / similar errors.  Must be sequential.
      await CameraControl.setAfEnabled(initial.afEnabled);
      await CameraControl.setIso(initial.isoValue);
      await CameraControl.setExposureTimeNs(initial.exposureTimeNs);
      await CameraControl.setFocusDistance(initial.focusDistance);
      await CameraControl.setZoomRatio(initial.zoomRatio);
      _settingsQueue.seedAppliedState(afEnabled: initial.afEnabled);

      if (!mounted) return;
      _listenToEvents();
    } catch (e) {
      if (!mounted) return;
      _showError('Camera error: $e');
    }
  }

  void _listenToEvents() {
    _eventSub = CameraControl.eventStream.listen((info) {
      if (!mounted) return;
      setState(() {
        _info = _info.copyWith(frameCount: info.frameCount, fps: info.fps);
      });
    }, onError: (e) => debugPrint('Event stream error: $e'));
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _sessionTimer?.cancel();
    _afFocusSyncTimer?.cancel();
    _settingsQueue.cancel();
    CameraControl.stopCamera();
    super.dispose();
  }

  // ── Snackbar helpers ──────────────────────────────────────────────

  void _showError(String msg) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final double hMargin = screenWidth >= 600 ? screenWidth * 0.2 : 16.0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: cs.errorContainer.withAlpha(217), // 0.85 alpha
        elevation: 4,
        margin: EdgeInsets.only(left: hMargin, right: hMargin, bottom: 92),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cs.error.withAlpha(50)),
        ),
        content: Row(
          children: [
            Icon(Icons.error_outline, color: cs.error, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                msg,
                style: TextStyle(
                  color: cs.onErrorContainer,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 5),
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
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(left: 16, right: 16, bottom: 92),
      ),
    );
  }

  // ── Camera actions ────────────────────────────────────────────────

  Future<void> _setWbLocked(bool locked) async {
    if (!mounted) return;
    // Save pre-optimistic state so the error handler can revert correctly.
    _committedWbLocked = _values.wbLocked;
    setState(() => _values = _values.copyWith(wbLocked: locked));
    _settingsQueue.updateWbLocked(locked);
  }

  Future<void> _toggleAf() async {
    final prev = _values.afEnabled;
    final newAf = !prev;
    if (prev) {
      // Capture the live focus distance before disabling AF so the slider
      // shows the correct starting position.
      try {
        final dist = await CameraControl.getCurrentFocusDistance();
        if (mounted) {
          setState(() => _values = _values.copyWith(focusDistance: dist));
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _values = _values.copyWith(afEnabled: newAf));
    _settingsQueue.updateAf(newAf);
    _updateAfFocusSync();
  }

  /// Called by [CameraSettingsBar] when the user taps a chip
  /// Tapping the same chip a second time collapses the floating overlay.
  void _onSettingChipTap(CameraSettingType? p) {
    setState(() => _activeSetting = p);
    _updateAfFocusSync();
  }

  void _toggleSettingsDrawer() {
    setState(() {
      _settingsDrawerOpen = !_settingsDrawerOpen;
      // Collapse the floating slider when the whole drawer is closed.
      if (!_settingsDrawerOpen) _activeSetting = null;
    });
    _updateAfFocusSync();
  }

  void _onIsoChanged(int iso) {
    setState(() => _values = _values.copyWith(isoValue: iso));
    _settingsQueue.updateIso(iso);
  }

  void _onExposureTimeNsChanged(int ns) {
    setState(() => _values = _values.copyWith(exposureTimeNs: ns));
    _settingsQueue.updateShutter(ns);
  }

  void _onFocusChanged(double dist) {
    if (mounted) {
      setState(() {
        _values = _values.copyWith(focusDistance: dist, afEnabled: false);
      });
    }

    _updateAfFocusSync();
    _settingsQueue.updateFocus(dist);
  }

  bool get _shouldSyncAfFocusDistance =>
      _cameraStarted &&
      _settingsDrawerOpen &&
      _activeSetting == CameraSettingType.focus &&
      _values.afEnabled;

  void _updateAfFocusSync() {
    if (!_shouldSyncAfFocusDistance) {
      _afFocusSyncTimer?.cancel();
      _afFocusSyncTimer = null;
      return;
    }

    if (_afFocusSyncTimer != null) return;

    _syncCurrentAfFocusDistance();
    _afFocusSyncTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _syncCurrentAfFocusDistance(),
    );
  }

  Future<void> _syncCurrentAfFocusDistance() async {
    if (_afFocusSyncInFlight || !_shouldSyncAfFocusDistance) return;
    _afFocusSyncInFlight = true;
    try {
      final dist = await CameraControl.getCurrentFocusDistance();
      if (!mounted || !_shouldSyncAfFocusDistance) return;
      if ((dist - _values.focusDistance).abs() < 0.001) return;
      setState(() => _values = _values.copyWith(focusDistance: dist));
    } catch (_) {
      // Best-effort UI sync only — ignore transient read failures.
    } finally {
      _afFocusSyncInFlight = false;
    }
  }

  void _onZoomChanged(double ratio) {
    setState(() => _values = _values.copyWith(zoomRatio: ratio));
    _settingsQueue.updateZoom(ratio);
  }

  bool _hasAutoMode(CameraSettingType? param) {
    if (param == null) return false;
    switch (param) {
      case CameraSettingType.focus:
      case CameraSettingType.wb:
        return true;
      default:
        return false;
    }
  }

  bool _isAutoMode(CameraSettingType? param) {
    if (param == null) return false;
    switch (param) {
      case CameraSettingType.focus:
        return _values.afEnabled;
      case CameraSettingType.wb:
        return !_values.wbLocked;
      default:
        return false;
    }
  }

  void _onAutoToggleTap(CameraSettingType? param) {
    if (param == null) return;
    switch (param) {
      case CameraSettingType.focus:
        _toggleAf();
        break;
      case CameraSettingType.wb:
        _setWbLocked(!_values.wbLocked);
        break;
      case CameraSettingType.af:
      default:
        break;
    }
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
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_settingsDrawerOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_settingsDrawerOpen) {
          _toggleSettingsDrawer();
        }
      },
      child: Scaffold(
        backgroundColor: cs.surface,
        body: SafeArea(
          top: true,
          bottom: false,
          left: false,
          right: false,
          child: Stack(
            children: [
              // Canvas — always the base layer (scrollable infinite plane)
              const Positioned.fill(child: CanvasView()),

              // Camera preview window — centered, 60 % of screen width.
              // Keep in tree with Visibility to maintain camera stream persistence.
              if (_permissionGranted)
                Positioned(
                  top: 44,
                  bottom: 80,
                  left: 0,
                  right: 0,
                  child: AnimatedOpacity(
                    opacity: _showCanvas ? 0 : 1,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    child: Visibility(
                      visible: !_showCanvas,
                      maintainState: true,
                      maintainAnimation: true,
                      maintainSize: true,
                      child: Center(
                        child: FractionallySizedBox(
                          widthFactor: 0.6,
                          child: AspectRatio(
                            aspectRatio: 4 / 3,
                            child: GestureDetector(
                              onTap: _cameraStarted
                                  ? () => _setWbLocked(true)
                                  : null,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: cs.primary.withValues(alpha: 0.8),
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: _buildCameraPreview(),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              else if (!_showCanvas)
                Positioned(
                  top: 44,
                  bottom: 80,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Text(
                      'Camera permission required',
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),

              // Status bar at top
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: BottomInfoBar(
                  isScanning: _isScanning,
                  frameCount: _info.frameCount,
                  stitchedCount: _stitchedCount,
                  totalTarget: 0,
                  coveragePct: 0.0,
                  sessionSeconds: _sessionSeconds,
                ),
              ),

              // MiniMap — top right, hidden in canvas-only mode
              Positioned(
                top: 44,
                right: 8,
                child: AnimatedOpacity(
                  opacity: _showCanvas ? 0 : 1,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: IgnorePointer(
                    ignoring: _showCanvas,
                    child: MiniMap(frameCount: _info.frameCount),
                  ),
                ),
              ),

              // All bottom controls pinned to the bottom of the screen
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Floating ruler slider + auto toggle
                    // Only visible when the drawer is open and a chip is active.
                    if (_activeSetting != null &&
                        _settingsDrawerOpen &&
                        _cameraStarted) ...[
                      SizedBox(
                        height: 48,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Ruler overlay (centered)
                            CameraControlOverlay(
                              activeSetting: _activeSetting,
                              values: _values,
                              ranges: _ranges,
                              callbacks: _callbacks,
                            ),

                            // Auto/Manual toggle button (positioned relative to center)
                            if (_hasAutoMode(_activeSetting))
                              Positioned(
                                right:
                                    (MediaQuery.of(context).size.width / 2) +
                                    200 +
                                    32,
                                child: CameraAutoToggleButton(
                                  isAuto: _isAutoMode(_activeSetting),
                                  onTap: () => _onAutoToggleTap(_activeSetting),
                                ),
                              ),
                          ],
                        ),
                      ),
                      // The relative gap between the overlay and the bar below it
                      const SizedBox(height: 12),
                    ],

                    // ColoredBox ensures any sub-pixel gap between the animated
                    // settings strip and the info bar is covered.
                    ColoredBox(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerLowest,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_cameraStarted)
                            InteractiveBottomBar(
                              isScanning: _isScanning,
                              showCanvas: _showCanvas,
                              isSettingsOpen: _settingsDrawerOpen,
                              onToggleScan: _toggleScan,
                              onToggleCanvas: () =>
                                  setState(() => _showCanvas = !_showCanvas),
                              onToggleSettings: _toggleSettingsDrawer,
                              onReset: _onReset,
                              onExport: _onExport,
                              activeSetting: _activeSetting,
                              onSettingChipTap: _onSettingChipTap,
                              values: _values,
                              callbacks: _callbacks,
                              canExport: false,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Resolution debug badge (top-left, subtle)
              if (_cameraStarted)
                Positioned(top: 44, left: 8, child: _buildResolutionBadge()),
            ],
          ),
        ),
      ),
    );
  }

  // ── Helper widgets ────────────────────────────────────────────────

  Widget _buildCameraPreview() {
    return PlatformViewLink(
      viewType: CameraControl.previewViewType,
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
            viewType: CameraControl.previewViewType,
            layoutDirection: TextDirection.ltr,
            creationParamsCodec: const StandardMessageCodec(),
          )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
    );
  }

  Widget _buildResolutionBadge() {
    final cs = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: cs.surfaceContainer.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Text(
          'Cap: ${_info.captureResolution}  |  Ana: ${_info.analysisResolution}'
          '  |  ${_info.fps.toStringAsFixed(1)} fps',
          style: TextStyle(
            color: cs.outline,
            fontSize: 9,
            fontFamily: 'monospace',
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
