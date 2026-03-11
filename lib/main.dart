import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import 'theme/material_theme_salmon.dart';
import 'theme/theme_util.dart';
import 'camera/camera_control.dart';
import 'camera/camera_settings_queue.dart';
import 'camera/camera_state.dart';
import 'widgets/bottom_info_bar.dart';
import 'widgets/interactive_bottom_bar.dart';
import 'widgets/canvas_view.dart';
import 'widgets/camera_control_overlay.dart';
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
  StreamSubscription<Map<dynamic, dynamic>>? _eventSub;

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
      onLockWb: _lockWb,
      onUnlockWb: _unlockWb,
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
      sendWbLock: (locked) async {
        if (locked) {
          await CameraControl.lockWhiteBalance();
        } else {
          await CameraControl.unlockWhiteBalance();
        }
      },
      initialAfEnabled: _values.afEnabled,
      onError: (key, error) {
        if (!mounted) return;
        switch (key) {
          case CameraSettingKey.af:
            _showError('AF update failed: $error');
            break;
          case CameraSettingKey.focus:
            _showError('Focus update failed: $error');
            break;
          case CameraSettingKey.iso:
            _showWarning('ISO update failed: $error');
            break;
          case CameraSettingKey.shutter:
            _showWarning('Shutter update failed: $error');
            break;
          case CameraSettingKey.zoom:
            _showWarning('Zoom update failed: $error');
            break;
          case CameraSettingKey.wb:
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

      final cw = info['captureWidth'] ?? '--';
      final ch = info['captureHeight'] ?? '--';
      final aw = info['analysisWidth'] ?? '--';
      final ah = info['analysisHeight'] ?? '--';

      setState(() {
        _cameraStarted = true;
        _info = _info.copyWith(
          captureResolution: '${cw}x$ch',
          analysisResolution: '${aw}x$ah',
        );
      });

      // Fetch device capability ranges — all read-only, safe to parallelize.
      final results = await Future.wait([
        CameraControl.getMinFocusDistance(),
        CameraControl.getMinZoomRatio(),
        CameraControl.getMaxZoomRatio(),
        CameraControl.getExposureTimeRangeNs(),
        CameraControl.getIsoRange(),
      ]);

      if (!mounted) return;

      final ranges = CameraRanges(
        minFocusDistance: results[0] as double,
        minZoomRatio: results[1] as double,
        maxZoomRatio: results[2] as double,
        exposureTimeRangeNs: results[3] as List<int>,
        isoRange: results[4] as List<int>,
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
    _eventSub = CameraControl.eventStream.listen((event) {
      if (!mounted) return;
      final type = event['type'] as String? ?? 'status';
      final tag = event['tag'] as String? ?? '';
      final message = event['message'] as String? ?? '';
      final data = event['data'] as Map? ?? {};

      if (tag == 'fps') {
        setState(() {
          _info = _info.copyWith(
            frameCount:
                (data['frameCount'] as num?)?.toInt() ?? _info.frameCount,
            fps: (data['fps'] as num?)?.toDouble() ?? _info.fps,
          );
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
    _afFocusSyncTimer?.cancel();
    _settingsQueue.cancel();
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

  Future<void> _lockWb() async {
    if (!mounted) return;
    // Save pre-optimistic state so the error handler can revert correctly.
    _committedWbLocked = _values.wbLocked;
    setState(() => _values = _values.copyWith(wbLocked: true));
    _settingsQueue.updateWbLock(true);
  }

  Future<void> _unlockWb() async {
    if (!mounted) return;
    // Save pre-optimistic state so the error handler can revert correctly.
    _committedWbLocked = _values.wbLocked;
    setState(() => _values = _values.copyWith(wbLocked: false));
    _settingsQueue.updateWbLock(false);
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

  /// Called by [CameraSettingsDrawer] when the user taps a chip in the strip.
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
              // Camera preview (always rendered behind everything)
              if (_permissionGranted)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _cameraStarted ? _lockWb : null,
                    child: _buildCameraPreview(),
                  ),
                )
              else
                Center(
                  child: Text(
                    'Camera permission required',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 16),
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

              // Canvas overlay (toggled by toolbar)
              if (_showCanvas) const Positioned.fill(child: CanvasView()),

              // MiniMap — top right
              Positioned(
                top: 44, // Shifted down to accommodate the top status bar
                right: 8,
                child: MiniMap(frameCount: _info.frameCount),
              ),

              // All bottom controls pinned to the bottom of the screen
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Floating ruler slider
                    // Only visible when the drawer is open and a chip is active.
                    if (_activeSetting != null &&
                        _settingsDrawerOpen &&
                        _cameraStarted) ...[
                      SizedBox(
                        height: 44, // Matches the ruler's totalHeight precisely
                        child: CameraControlOverlay(
                          activeSetting: _activeSetting,
                          values: _values,
                          ranges: _ranges,
                          callbacks: _callbacks,
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
                              isSettingsOpen: _settingsDrawerOpen,
                              onToggleScan: _toggleScan,
                              onToggleSettings: _toggleSettingsDrawer,
                              onReset: _onReset,
                              onExport: _onExport,
                              activeSetting: _activeSetting,
                              onSettingChipTap: _onSettingChipTap,
                              values: _values,
                              callbacks: _callbacks,
                              showCanvas: _showCanvas,
                              canExport: false,
                              onToggleCanvas: () =>
                                  setState(() => _showCanvas = !_showCanvas),
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
