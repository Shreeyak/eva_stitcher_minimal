import 'dart:typed_data';

import 'package:flutter/services.dart';

// ── NavigationState ────────────────────────────────────────────────────────

class NavigationState {
  const NavigationState({
    required this.trackingState,
    required this.poseX,
    required this.poseY,
    required this.velocityX,
    required this.velocityY,
    required this.speed,
    required this.lastConfidence,
    required this.overlapRatio,
    required this.frameCount,
    required this.framesCaptured,
    required this.captureReady,
    required this.canvasMinX,
    required this.canvasMinY,
    required this.canvasMaxX,
    required this.canvasMaxY,
    required this.sharpness,
    required this.analysisTimeMs,
    required this.compositeTimeMs,
    required this.quality,
  });

  /// 0=INIT, 1=TRACKING, 2=UNCERTAIN, 3=LOST
  final int trackingState;
  final double poseX;
  final double poseY;
  final double velocityX;
  final double velocityY;
  final double speed;
  final double lastConfidence;
  final double overlapRatio;
  final int frameCount;
  final int framesCaptured;
  final bool captureReady;
  final double canvasMinX;
  final double canvasMinY;
  final double canvasMaxX;
  final double canvasMaxY;
  final double sharpness;
  final double analysisTimeMs;
  final double compositeTimeMs;
  final double quality;

  static const NavigationState empty = NavigationState(
    trackingState: 0,
    poseX: 0, poseY: 0,
    velocityX: 0, velocityY: 0, speed: 0,
    lastConfidence: 0, overlapRatio: 0,
    frameCount: 0, framesCaptured: 0,
    captureReady: false,
    canvasMinX: 0, canvasMinY: 0, canvasMaxX: -1, canvasMaxY: -1,
    sharpness: 0, analysisTimeMs: 0, compositeTimeMs: 0, quality: 0,
  );

  factory NavigationState.fromFloat32List(Float32List data) {
    assert(data.length == 19, 'NavigationState requires 19 floats, got ${data.length}');
    return NavigationState(
      trackingState:  data[0].toInt(),
      poseX:          data[1].toDouble(),
      poseY:          data[2].toDouble(),
      velocityX:      data[3].toDouble(),
      velocityY:      data[4].toDouble(),
      speed:          data[5].toDouble(),
      lastConfidence: data[6].toDouble(),
      overlapRatio:   data[7].toDouble(),
      frameCount:     data[8].toInt(),
      framesCaptured: data[9].toInt(),
      captureReady:   data[10] > 0.5,
      canvasMinX:     data[11].toDouble(),
      canvasMinY:     data[12].toDouble(),
      canvasMaxX:     data[13].toDouble(),
      canvasMaxY:     data[14].toDouble(),
      sharpness:      data[15].toDouble(),
      analysisTimeMs: data[16].toDouble(),
      compositeTimeMs:data[17].toDouble(),
      quality:        data[18].toDouble(),
    );
  }

  /// True when canvasMinX <= canvasMaxX (at least one frame committed).
  bool get canvasHasData => canvasMinX <= canvasMaxX;

  String get trackingStateName {
    switch (trackingState) {
      case 0: return 'INIT';
      case 1: return 'TRACKING';
      case 2: return 'UNCERTAIN';
      case 3: return 'LOST';
      default: return 'UNKNOWN';
    }
  }
}

// ── StitchControl ─────────────────────────────────────────────────────────

class StitchControl {
  static const MethodChannel _channel = MethodChannel('com.example.eva/stitch');

  static Future<void> initEngine({
    required int analysisW,
    required int analysisH,
  }) async {
    await _channel.invokeMethod<void>('initEngine', {
      'analysisW': analysisW,
      'analysisH': analysisH,
    });
  }

  /// Returns a snapshot of the navigation state, or null on error.
  static Future<NavigationState?> getNavigationState() async {
    final raw = await _channel.invokeMethod<Object>('getNavigationState');
    if (raw == null) return null;

    // Platform channel returns Float32List on Android
    if (raw is Float32List) {
      return NavigationState.fromFloat32List(raw);
    }
    // Fallback: may arrive as List<dynamic>
    if (raw is List) {
      final f = Float32List(raw.length);
      for (int i = 0; i < raw.length; i++) {
        f[i] = (raw[i] as num).toDouble();
      }
      return NavigationState.fromFloat32List(f);
    }
    return null;
  }

  /// Returns JPEG bytes of the canvas preview, or null if empty.
  static Future<Uint8List?> getCanvasPreview({int maxDim = 1024}) async {
    final bytes = await _channel.invokeMethod<Uint8List>('getCanvasPreview', {
      'maxDim': maxDim,
    });
    return bytes;
  }

  static Future<void> resetEngine() async {
    await _channel.invokeMethod<void>('resetEngine');
  }

  static Future<void> startScanning() async {
    await _channel.invokeMethod<void>('startScanning');
  }

  static Future<void> stopScanning() async {
    await _channel.invokeMethod<void>('stopScanning');
  }
}
