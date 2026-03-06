import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

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
        colorScheme: ColorScheme.dark(
          primary: Colors.blueAccent,
          surface: Colors.black,
        ),
      ),
      home: const CameraScreen(),
    );
  }
}

// ── Platform channel helper ─────────────────────────────────────────────

class CameraControl {
  static const _method = MethodChannel('com.example.eva/control');
  static const _events = EventChannel('com.example.eva/events');

  static Future<bool> requestPermission() async {
    final granted = await _method.invokeMethod<bool>('requestPermission');
    return granted ?? false;
  }

  static Future<Map<String, dynamic>> startCamera() async {
    final result = await _method.invokeMethod<Map>('startCamera');
    return Map<String, dynamic>.from(result ?? {});
  }

  static Future<void> stopCamera() => _method.invokeMethod('stopCamera');

  static Future<String> saveFrame() async {
    final path = await _method.invokeMethod<String>('saveFrame');
    return path ?? '';
  }

  static Future<bool> lockWhiteBalance() async {
    final ok = await _method.invokeMethod<bool>('lockWhiteBalance');
    return ok ?? false;
  }

  static Future<bool> unlockWhiteBalance() async {
    final ok = await _method.invokeMethod<bool>('unlockWhiteBalance');
    return ok ?? false;
  }

  static Future<bool> isWbLocked() async {
    final locked = await _method.invokeMethod<bool>('isWbLocked');
    return locked ?? false;
  }

  static Future<void> setAfEnabled(bool enabled) =>
      _method.invokeMethod('setAfEnabled', {'enabled': enabled});

  static Future<void> setAeEnabled(bool enabled) =>
      _method.invokeMethod('setAeEnabled', {'enabled': enabled});

  static Future<double> getMinFocusDistance() async {
    final result = await _method.invokeMethod<double>('getMinFocusDistance');
    return result ?? 0.0;
  }

  static Future<double> getCurrentFocusDistance() async {
    final result = await _method.invokeMethod<double>(
      'getCurrentFocusDistance',
    );
    return result ?? 0.0;
  }

  static Future<void> setFocusDistance(double distance) =>
      _method.invokeMethod('setFocusDistance', {'distance': distance});

  static Future<double> getExposureOffsetStep() async {
    final result = await _method.invokeMethod<double>('getExposureOffsetStep');
    return result ?? 0.0;
  }

  static Future<List<int>> getExposureOffsetRange() async {
    final result = await _method.invokeMethod<List>('getExposureOffsetRange');
    return result?.cast<int>() ?? [0, 0];
  }

  static Future<void> setExposureOffset(int index) =>
      _method.invokeMethod('setExposureOffset', {'index': index});

  static Future<List<int>> getExposureTimeRangeNs() async {
    final result = await _method.invokeMethod<List>('getExposureTimeRangeNs');
    return result?.map((e) => (e as num).toInt()).toList() ??
        [1000000, 1000000000];
  }

  static Future<void> setExposureTimeNs(int ns) =>
      _method.invokeMethod('setExposureTimeNs', {'ns': ns});

  static Future<List<int>> getIsoRange() async {
    final result = await _method.invokeMethod<List>('getIsoRange');
    return result?.map((e) => (e as num).toInt()).toList() ?? [100, 3200];
  }

  static Future<void> setIso(int iso) =>
      _method.invokeMethod('setIso', {'iso': iso});

  static Future<double> getMinZoomRatio() async {
    final result = await _method.invokeMethod<double>('getMinZoomRatio');
    return result ?? 1.0;
  }

  static Future<double> getMaxZoomRatio() async {
    final result = await _method.invokeMethod<double>('getMaxZoomRatio');
    return result ?? 1.0;
  }

  static Future<void> setZoomRatio(double ratio) =>
      _method.invokeMethod('setZoomRatio', {'ratio': ratio});

  static Future<Map<String, dynamic>> getResolution() async {
    final result = await _method.invokeMethod<Map>('getResolution');
    return Map<String, dynamic>.from(result ?? {});
  }

  /// Stream of status events from Kotlin.
  static Stream<Map<dynamic, dynamic>> get eventStream =>
      _events.receiveBroadcastStream().map((e) => e as Map<dynamic, dynamic>);
}

// ── Camera screen ───────────────────────────────────────────────────────

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  bool _permissionGranted = false;
  bool _cameraStarted = false;
  bool _saving = false;

  // Camera controls state
  bool _afEnabled = true;
  bool _aeEnabled = true;
  bool _wbLocked = false;

  // Focus
  double _minFocusDistance = 0.0;
  double _currentFocusDistance = 0.0;
  bool _showFocusSlider = false;
  Timer? _focusSliderTimer;

  // Exposure (EV offset, shown when AE is on)
  int _exposureOffsetIndex = 0;
  List<int> _exposureOffsetRange = [0, 0];
  double _exposureOffsetStep = 0.0;
  bool _showExposureSlider = false;
  Timer? _exposureSliderTimer;

  // Manual sensor exposure + ISO (shown when AE is off)
  int _exposureTimeNs = 1000000; // 1 ms default
  List<int> _exposureTimeRangeNs = [1000000, 1000000000];
  int _isoValue = 200;
  List<int> _isoRange = [100, 3200];

  // Zoom
  double _minZoomRatio = 1.0;
  double _maxZoomRatio = 1.0;
  double _currentZoomRatio = 1.0;
  bool _showZoomSlider = false;
  Timer? _zoomSliderTimer;

  // Resolution info
  String _captureResolution = '--';
  String _analysisResolution = '--';

  // Status / diagnostics
  String _statusText = 'Initializing...';
  int _frameCount = 0;
  double _fps = 0.0;

  // Settings tray
  bool _settingsOpen = false;

  StreamSubscription<Map<dynamic, dynamic>>? _eventSub;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final granted = await CameraControl.requestPermission();
    if (!mounted) return;
    setState(() {
      _permissionGranted = granted;
      _statusText = granted ? 'Permission granted' : 'Permission denied';
    });
    if (!granted) return;
    await _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      setState(() => _statusText = 'Starting camera...');
      final info = await CameraControl.startCamera();
      if (!mounted) return;

      setState(() {
        _cameraStarted = true;
        final cw = info['captureWidth'] ?? '--';
        final ch = info['captureHeight'] ?? '--';
        final aw = info['analysisWidth'] ?? '--';
        final ah = info['analysisHeight'] ?? '--';
        _captureResolution = '${cw}x$ch';
        _analysisResolution = '${aw}x$ah';
        _statusText = 'AF: ON | AE: ON | WB: Auto';
      });

      // Fetch device capabilities
      final minFocus = await CameraControl.getMinFocusDistance();
      final exposureRange = await CameraControl.getExposureOffsetRange();
      final exposureStep = await CameraControl.getExposureOffsetStep();
      final expTimeRange = await CameraControl.getExposureTimeRangeNs();
      final isoRange = await CameraControl.getIsoRange();
      final minZoom = await CameraControl.getMinZoomRatio();
      final maxZoom = await CameraControl.getMaxZoomRatio();

      if (mounted) {
        setState(() {
          _minFocusDistance = minFocus;
          _currentFocusDistance = minFocus / 2;
          _exposureOffsetRange = exposureRange;
          _exposureOffsetStep = exposureStep;
          _exposureOffsetIndex = 0;
          _exposureTimeRangeNs = expTimeRange;
          _exposureTimeNs = expTimeRange[0].clamp(1000000, expTimeRange[1]);
          _isoRange = isoRange;
          _isoValue = isoRange[0].clamp(200, isoRange[1]);
          _minZoomRatio = minZoom;
          _maxZoomRatio = maxZoom;
          _currentZoomRatio = minZoom;
        });
      }

      _listenToEvents();
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusText = 'Camera error: $e');
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
        setState(() => _statusText = message);
      } else if (type == 'warning') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.orange[800],
            duration: const Duration(seconds: 3),
          ),
        );
      } else if (type == 'error') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }, onError: (e) => debugPrint('Event stream error: $e'));
  }

  @override
  void dispose() {
    _focusSliderTimer?.cancel();
    _exposureSliderTimer?.cancel();
    _zoomSliderTimer?.cancel();
    _eventSub?.cancel();
    CameraControl.stopCamera();
    super.dispose();
  }

  // ── Actions ───────────────────────────────────────────────────────────

  Future<void> _saveFrame() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final path = await CameraControl.saveFrame();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved: $path'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleAf() async {
    final prev = _afEnabled;
    double nextFocus = _currentFocusDistance;
    if (_afEnabled) {
      nextFocus = await CameraControl.getCurrentFocusDistance();
    }
    setState(() {
      _afEnabled = !_afEnabled;
      if (!_afEnabled && _minFocusDistance > 0) {
        _currentFocusDistance = nextFocus;
        _showFocusSlider = true;
        _hideOtherSliders('focus');
        _resetFocusSliderTimer();
      } else {
        _showFocusSlider = false;
        _focusSliderTimer?.cancel();
      }
    });
    try {
      await CameraControl.setAfEnabled(_afEnabled);
    } catch (e) {
      if (!mounted) return;
      setState(() => _afEnabled = prev);
    }
  }

  Future<void> _toggleAe() async {
    final prev = _aeEnabled;
    setState(() {
      _aeEnabled = !_aeEnabled;
      _showExposureSlider = !_aeEnabled;
      _hideOtherSliders('exposure');
      if (_showExposureSlider) _resetExposureSliderTimer();
    });
    try {
      await CameraControl.setAeEnabled(_aeEnabled);
    } catch (e) {
      if (!mounted) return;
      setState(() => _aeEnabled = prev);
    }
  }

  Future<void> _tapToLockWb() async {
    try {
      await CameraControl.lockWhiteBalance();
      if (mounted) setState(() => _wbLocked = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('WB lock failed: $e'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Future<void> _unlockWb() async {
    try {
      await CameraControl.unlockWhiteBalance();
      if (mounted) setState(() => _wbLocked = false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('WB unlock failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _onFocusChanged(double value) {
    setState(() {
      _currentFocusDistance = value;
      _showFocusSlider = true;
      _hideOtherSliders('focus');
    });
    _resetFocusSliderTimer();
    CameraControl.setFocusDistance(value);
  }

  void _onExposureChanged(double value) {
    final rounded = value.round();
    setState(() {
      _exposureOffsetIndex = rounded;
      _showExposureSlider = true;
      _hideOtherSliders('exposure');
    });
    _resetExposureSliderTimer();
    CameraControl.setExposureOffset(rounded);
  }

  void _onExposureTimeChanged(double value) {
    setState(() {
      _exposureTimeNs = value.toInt();
      _showExposureSlider = true;
      _hideOtherSliders('exposure');
    });
    _resetExposureSliderTimer();
    CameraControl.setExposureTimeNs(_exposureTimeNs);
  }

  void _onIsoChanged(double value) {
    setState(() {
      _isoValue = value.toInt();
      _showExposureSlider = true;
      _hideOtherSliders('exposure');
    });
    _resetExposureSliderTimer();
    CameraControl.setIso(_isoValue);
  }

  void _onZoomChanged(double value) {
    setState(() {
      _currentZoomRatio = value;
      _showZoomSlider = true;
      _hideOtherSliders('zoom');
    });
    _resetZoomSliderTimer();
    CameraControl.setZoomRatio(value);
  }

  void _toggleZoomSlider() {
    setState(() {
      _showZoomSlider = !_showZoomSlider;
      if (_showZoomSlider) {
        _hideOtherSliders('zoom');
        _resetZoomSliderTimer();
      }
    });
  }

  void _hideOtherSliders(String keep) {
    if (keep != 'focus') {
      _showFocusSlider = false;
      _focusSliderTimer?.cancel();
    }
    if (keep != 'exposure') {
      _showExposureSlider = false;
      _exposureSliderTimer?.cancel();
    }
    if (keep != 'zoom') {
      _showZoomSlider = false;
      _zoomSliderTimer?.cancel();
    }
  }

  void _resetFocusSliderTimer() {
    _focusSliderTimer?.cancel();
    _focusSliderTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showFocusSlider = false);
    });
  }

  void _resetExposureSliderTimer() {
    _exposureSliderTimer?.cancel();
    _exposureSliderTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showExposureSlider = false);
    });
  }

  void _resetZoomSliderTimer() {
    _zoomSliderTimer?.cancel();
    _zoomSliderTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showZoomSlider = false);
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Camera preview (tap to lock WB) ──
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
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),

          // ── Settings button ──
          if (_cameraStarted)
            Positioned(
              left: 8,
              top: MediaQuery.of(context).padding.top + 8,
              child: _buildSettingsButton(),
            ),

          // ── Background tap to close settings ──
          if (_settingsOpen)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => setState(() => _settingsOpen = false),
              ),
            ),

          // ── Settings tray ──
          if (_settingsOpen) _buildSettingsTray(),

          // ── Sliders ──
          if (_showFocusSlider && !_afEnabled && _minFocusDistance > 0)
            _buildVerticalSlider(
              value: _currentFocusDistance,
              min: 0.0,
              max: _minFocusDistance,
              color: Colors.greenAccent,
              label: '${_currentFocusDistance.toStringAsFixed(1)} D',
              onChanged: _onFocusChanged,
              onChangeEnd: (_) => _resetFocusSliderTimer(),
            ),

          if (_showExposureSlider &&
              !_aeEnabled &&
              _exposureTimeRangeNs[1] > _exposureTimeRangeNs[0])
            _buildVerticalSlider(
              value: _exposureTimeNs.toDouble().clamp(
                _exposureTimeRangeNs[0].toDouble(),
                _exposureTimeRangeNs[1].toDouble(),
              ),
              min: _exposureTimeRangeNs[0].toDouble(),
              max: _exposureTimeRangeNs[1].toDouble(),
              color: Colors.amberAccent,
              label: '${(_exposureTimeNs / 1000).round()} µs',
              onChanged: _onExposureTimeChanged,
              onChangeEnd: (_) => _resetExposureSliderTimer(),
            ),

          if (_showExposureSlider && !_aeEnabled && _isoRange[1] > _isoRange[0])
            _buildVerticalSlider(
              left: 134,
              value: _isoValue.toDouble().clamp(
                _isoRange[0].toDouble(),
                _isoRange[1].toDouble(),
              ),
              min: _isoRange[0].toDouble(),
              max: _isoRange[1].toDouble(),
              color: Colors.orangeAccent,
              label: 'ISO $_isoValue',
              onChanged: _onIsoChanged,
              onChangeEnd: (_) => _resetExposureSliderTimer(),
            ),

          if (_showExposureSlider &&
              _aeEnabled &&
              _exposureOffsetRange.length == 2 &&
              _exposureOffsetRange[1] > _exposureOffsetRange[0])
            _buildVerticalSlider(
              value: _exposureOffsetIndex.toDouble(),
              min: _exposureOffsetRange[0].toDouble(),
              max: _exposureOffsetRange[1].toDouble(),
              divisions: (_exposureOffsetRange[1] - _exposureOffsetRange[0])
                  .toInt(),
              color: Colors.amberAccent,
              label:
                  '${(_exposureOffsetIndex * _exposureOffsetStep).toStringAsFixed(1)} EV',
              onChanged: _onExposureChanged,
              onChangeEnd: (_) => _resetExposureSliderTimer(),
            ),

          if (_showZoomSlider)
            _buildVerticalSlider(
              value: _currentZoomRatio,
              min: _minZoomRatio,
              max: _maxZoomRatio,
              color: Colors.blueAccent,
              label: '${_currentZoomRatio.toStringAsFixed(1)}x',
              onChanged: _onZoomChanged,
              onChangeEnd: (_) => _resetZoomSliderTimer(),
            ),

          // ── Bottom status bar ──
          Positioned(left: 0, right: 0, bottom: 0, child: _buildBottomBar()),
        ],
      ),
    );
  }

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

  Widget _buildSettingsButton() {
    return GestureDetector(
      onTap: () => setState(() => _settingsOpen = !_settingsOpen),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(
          _settingsOpen ? Icons.close : Icons.settings,
          color: Colors.white,
          size: 22,
        ),
      ),
    );
  }

  Widget _buildSettingsTray() {
    return Positioned(
      left: 8,
      top: MediaQuery.of(context).padding.top + 60,
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // AF toggle
            _SettingsRow(
              icon: _afEnabled
                  ? Icons.center_focus_strong
                  : Icons.center_focus_weak,
              label: _afEnabled ? 'AF: ON' : 'AF: OFF',
              color: _afEnabled ? Colors.greenAccent : Colors.white54,
              onTap: _toggleAf,
            ),
            const SizedBox(height: 8),

            // AE toggle
            _SettingsRow(
              icon: _aeEnabled ? Icons.exposure : Icons.exposure_outlined,
              label: _aeEnabled ? 'AE: ON' : 'AE: OFF',
              color: _aeEnabled ? Colors.amberAccent : Colors.white54,
              onTap: _toggleAe,
            ),
            const SizedBox(height: 8),

            // Zoom
            _SettingsRow(
              icon: Icons.zoom_in,
              label: 'Zoom: ${_currentZoomRatio.toStringAsFixed(1)}x',
              color: Colors.blueAccent,
              onTap: _toggleZoomSlider,
            ),
            const SizedBox(height: 8),

            // WB status / unlock
            _SettingsRow(
              icon: _wbLocked ? Icons.lock : Icons.wb_auto,
              label: _wbLocked ? 'WB: Locked' : 'WB: Auto',
              color: _wbLocked ? Colors.orange : Colors.white54,
              onTap: _wbLocked ? _unlockWb : null,
              subtitle: _wbLocked ? 'Tap to unlock' : 'Tap preview to lock',
            ),
            const SizedBox(height: 8),

            // Resolution info
            const Divider(color: Colors.white24, height: 1),
            const SizedBox(height: 8),
            Text(
              'Capture: $_captureResolution',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
            Text(
              'Analysis: $_analysisResolution',
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerticalSlider({
    required double value,
    required double min,
    required double max,
    required Color color,
    required String label,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
    int? divisions,
    double left = 60,
  }) {
    return Positioned(
      left: left,
      top: MediaQuery.of(context).size.height / 2 - 150,
      child: Container(
        height: 300,
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(30),
        ),
        child: RotatedBox(
          quarterTurns: 3,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: color,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: color,
                    overlayColor: color.withValues(alpha: 0.2),
                    trackHeight: 4.0,
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                  ),
                  child: Slider(
                    value: value,
                    min: min,
                    max: max,
                    divisions: divisions,
                    onChanged: onChanged,
                    onChangeEnd: onChangeEnd,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7)),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Status info
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _statusText,
                    style: const TextStyle(color: Colors.amber, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Frames: $_frameCount  |  ${_fps.toStringAsFixed(1)} FPS',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),

            // Save button
            SizedBox(
              height: 40,
              child: ElevatedButton.icon(
                onPressed: _cameraStarted && !_saving ? _saveFrame : null,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.save, size: 18),
                label: Text(_saving ? 'Saving...' : 'Save'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Settings row widget ─────────────────────────────────────────────────

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
