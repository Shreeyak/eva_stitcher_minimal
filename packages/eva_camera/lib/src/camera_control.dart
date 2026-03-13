import 'package:flutter/services.dart';

import 'camera_state.dart'
    show
        CameraResolutionInfo,
        CameraSettingsDumpInfo,
        CameraStartInfo,
        CaptureFormat,
        CaptureIntent;

// ── Platform channel helper ─────────────────────────────────────────────

class CameraControl {
  static const _method = MethodChannel('com.example.eva/control');
  static const _events = EventChannel('com.example.eva/events');

  static Future<bool> requestPermission() async {
    final granted = await _method.invokeMethod<bool>('requestPermission');
    return granted ?? false;
  }

  static Future<CameraStartInfo> startCamera({
    int? captureWidth,
    int? captureHeight,
    int? analysisWidth,
    int? analysisHeight,
  }) async {
    final hasCaptureWidth = captureWidth != null;
    final hasCaptureHeight = captureHeight != null;
    if (hasCaptureWidth != hasCaptureHeight) {
      throw ArgumentError(
        'captureWidth and captureHeight must be provided together.',
      );
    }

    final hasAnalysisWidth = analysisWidth != null;
    final hasAnalysisHeight = analysisHeight != null;
    if (hasAnalysisWidth != hasAnalysisHeight) {
      throw ArgumentError(
        'analysisWidth and analysisHeight must be provided together.',
      );
    }

    final args = <String, Object>{
      if (captureWidth != null) 'captureWidth': captureWidth,
      if (captureHeight != null) 'captureHeight': captureHeight,
      if (analysisWidth != null) 'analysisWidth': analysisWidth,
      if (analysisHeight != null) 'analysisHeight': analysisHeight,
    };

    final result = args.isEmpty
        ? await _method.invokeMethod<Map>('startCamera')
        : await _method.invokeMethod<Map>('startCamera', args);
    return CameraStartInfo.fromMap(result ?? const {});
  }

  static Future<void> stopCamera() => _method.invokeMethod('stopCamera');

  /// Trigger a full-resolution still capture. The frame is delivered directly to the
  /// native StillCaptureProcessor — no image data crosses the MethodChannel.
  ///
  /// [save] signals the native layer to persist the frame to disk (photo mode).
  /// When false, the processor handles the frame for stitching without saving.
  static Future<void> captureImage({bool save = false}) =>
      _method.invokeMethod('captureImage', {'save': save});

  /// Switch ImageCapture output format (triggers camera rebind).
  /// Returns updated resolution info.
  static Future<CameraResolutionInfo> setCaptureFormat(
    CaptureFormat format,
  ) async {
    final result = await _method.invokeMethod<Map>('setCaptureFormat', {
      'format': format.name,
    });
    return CameraResolutionInfo.fromMap(result ?? const {});
  }

  static Future<CameraSettingsDumpInfo> dumpActiveCameraSettings() async {
    final result = await _method.invokeMethod<Map>('dumpActiveCameraSettings');
    return CameraSettingsDumpInfo.fromMap(result ?? const {});
  }

  // ── White balance ──────────────────────────────────────────────────

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

  // ── Auto exposure ─────────────────────────────────────────────────

  static Future<void> setAeEnabled(bool enabled) =>
      _method.invokeMethod('setAeEnabled', {'enabled': enabled});

  static Future<double> getExposureOffsetStep() async {
    final result = await _method.invokeMethod<double>('getExposureOffsetStep');
    return result ?? 0.0;
  }

  static Future<List<int>> getExposureOffsetRange() async {
    final result = await _method.invokeMethod<List>('getExposureOffsetRange');
    return result?.map((e) => (e as num).toInt()).toList() ?? [0, 0];
  }

  static Future<void> setExposureOffset(int index) =>
      _method.invokeMethod('setExposureOffset', {'index': index});

  // ── Auto focus ────────────────────────────────────────────────────

  static Future<void> setAfEnabled(bool enabled) =>
      _method.invokeMethod('setAfEnabled', {'enabled': enabled});

  static Future<double> getCurrentFocusDistance() async {
    final result = await _method.invokeMethod<double>(
      'getCurrentFocusDistance',
    );
    return result ?? 0.0;
  }

  static Future<void> setFocusDistance(double distance) =>
      _method.invokeMethod('setFocusDistance', {'distance': distance});

  // ── Manual sensor (ISO + shutter) ────────────────────────────────

  static Future<void> setExposureTimeNs(int ns) =>
      _method.invokeMethod('setExposureTimeNs', {'ns': ns});

  static Future<void> setIso(int iso) =>
      _method.invokeMethod('setIso', {'iso': iso});

  // ── Capture intent ────────────────────────────────────────────────

  static Future<void> setCaptureIntent(CaptureIntent intent) =>
      _method.invokeMethod('setCaptureIntent', {'intent': intent.name});

  // ── Zoom ──────────────────────────────────────────────────────────

  static Future<void> setZoomRatio(double ratio) =>
      _method.invokeMethod('setZoomRatio', {'ratio': ratio});

  // ── Info ──────────────────────────────────────────────────────────

  static Future<CameraResolutionInfo> getResolution() async {
    final result = await _method.invokeMethod<Map>('getResolution');
    return CameraResolutionInfo.fromMap(result ?? const {});
  }

  /// Broadcast stream of status events pushed from Kotlin every ~500 ms.
  static Stream<Map<dynamic, dynamic>> get eventStream =>
      _events.receiveBroadcastStream().map((e) => e as Map<dynamic, dynamic>);
}
