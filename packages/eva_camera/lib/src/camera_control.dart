import 'package:flutter/services.dart';

import 'camera_state.dart' show CaptureFormat, CaptureIntent;

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

  /// Trigger a full-resolution still capture. The frame is delivered directly to the
  /// native StillCaptureProcessor — no image data crosses the MethodChannel.
  static Future<void> captureImage() => _method.invokeMethod('captureImage');

  /// Switch ImageCapture output format (triggers camera rebind).
  /// Returns updated resolution info.
  static Future<Map<String, dynamic>> setCaptureFormat(
    CaptureFormat format,
  ) async {
    final result = await _method.invokeMethod<Map>('setCaptureFormat', {
      'format': format.name,
    });
    return Map<String, dynamic>.from(result ?? {});
  }

  static Future<Map<String, dynamic>> dumpActiveCameraSettings() async {
    final result = await _method.invokeMethod<Map>('dumpActiveCameraSettings');
    return Map<String, dynamic>.from(result ?? {});
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

  // ── Manual sensor (ISO + shutter) ────────────────────────────────

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

  // ── Capture intent ────────────────────────────────────────────────

  static Future<void> setCaptureIntent(CaptureIntent intent) =>
      _method.invokeMethod('setCaptureIntent', {'intent': intent.name});

  // ── Zoom ──────────────────────────────────────────────────────────

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

  // ── Info ──────────────────────────────────────────────────────────

  static Future<Map<String, dynamic>> getResolution() async {
    final result = await _method.invokeMethod<Map>('getResolution');
    return Map<String, dynamic>.from(result ?? {});
  }

  /// Broadcast stream of status events pushed from Kotlin every ~500 ms.
  static Stream<Map<dynamic, dynamic>> get eventStream =>
      _events.receiveBroadcastStream().map((e) => e as Map<dynamic, dynamic>);
}
