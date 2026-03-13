# eva_camera

Flutter plugin wrapping CameraX + Camera2 Interop for whole-slide imaging. Provides a native preview
surface, full manual camera control (ISO, shutter, focus, WB), and a zero-copy frame pipeline for
in-process image stitching.

**Android only.** Targets API 34+, `arm64-v8a`, NDK 27.

---

## Architecture

```text
Flutter (Dart)          Kotlin                       C++ / JNI
──────────────          ──────────────────────────   ──────────────────────
CameraControl  ──────►  EvaCameraPlugin              NativeStitcher
  MethodChannel          └─ CameraManager
  EventChannel               ├─ Preview (PreviewView PlatformView)
                 ├─ ImageCapture (4208×3120 YUV or JPEG)
                 └─ ImageAnalysis (1280×960 YUV, ~30 fps)
                                    │                       │
                                    ▼                       ▼
                             FrameProcessor      PhotoCapture/StitchFrame processors
```

Three CameraX use cases run simultaneously:

- Preview — device default, output to `PreviewView` PlatformView.
- ImageCapture — 4208×3120, delivered to either `PhotoCaptureProcessor` or
    `StitchFrameProcessor` based on capture entrypoint.
- ImageAnalysis — 1280×960, delivered to `FrameProcessor` (YUV, ~30 fps).

---

## Setup

### 1. Register processors in `configureFlutterEngine`

Implement the native interfaces and register them **before** `startCamera` is called from Dart.

```kotlin
// MainActivity.kt
import com.example.eva_camera.EvaCameraPlugin
import com.example.eva_camera.FrameProcessor
import com.example.eva_camera.PhotoCaptureProcessor
import com.example.eva_camera.StitchFrameProcessor
import com.example.eva_camera.StillFrameSaver

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {

        EvaCameraPlugin.setFrameProcessor(object : FrameProcessor {
            override fun processFrame(
                imageProxy: ImageProxy,
                captureResult: TotalCaptureResult?,
            ): Float {
                // ImageProxy gives full access to planes/strides/metadata.
                // You can consume buffers directly in this callback for a zero-copy path.
                val yBuf = imageProxy.planes[0].buffer
                val uBuf = imageProxy.planes[1].buffer
                val vBuf = imageProxy.planes[2].buffer
                // TODO: pass to NativeStitcher via JNI
                // ⚠ DO NOT call imageProxy.close() — CameraManager handles it in a finally block.
                return 0f
            }
        })

        EvaCameraPlugin.setPhotoCaptureProcessor(object : PhotoCaptureProcessor {
            override fun onPhotoCapture(
                imageProxy: ImageProxy,
                captureResult: TotalCaptureResult?,
            ) {
                // photo mode: persist to gallery
                StillFrameSaver.saveToMediaStore(applicationContext, imageProxy)
                // ⚠ DO NOT call imageProxy.close() — CameraManager handles it in a finally block.
            }
        })

        EvaCameraPlugin.setStitchFrameProcessor(object : StitchFrameProcessor {
            override fun onStitchFrame(
                imageProxy: ImageProxy,
                captureResult: TotalCaptureResult?,
            ) {
                // stitcher mode: extract planes for registration + blend
                val yBuf  = imageProxy.planes[0].buffer  // luma, zero-copy ByteBuffer
                val uBuf  = imageProxy.planes[1].buffer
                val vBuf  = imageProxy.planes[2].buffer
                // NativeStitcher.addFrame(yBuf, uBuf, vBuf, ...)
                // ⚠ DO NOT call imageProxy.close() — CameraManager handles it in a finally block.
            }
        })
    }
}
```

### 2. Request permission + start camera from Dart

```dart
final granted = await CameraControl.requestPermission();
if (!granted) return;

final info = await CameraControl.startCamera(
    captureWidth: 4208,
    captureHeight: 3120,
    analysisWidth: 1280,
    analysisHeight: 960,
);
// CameraStartInfo fields:
// captureWidth, captureHeight, analysisWidth, analysisHeight,
// minFocusDistance, minZoomRatio, maxZoomRatio,
// exposureTimeRangeNs [min,max], isoRange [min,max]

// Any or all resolution pairs are optional.
// Omit them to keep plugin defaults.
```

### 3. Embed the preview surface

```dart
AndroidView(
    viewType: CameraControl.previewViewType,
  creationParamsCodec: const StandardMessageCodec(),
)
```

### 4. Full Flutter integration example (preview + lifecycle)

```dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:eva_camera/eva_camera.dart';

class CameraPreviewPane extends StatefulWidget {
    const CameraPreviewPane({super.key});

    @override
    State<CameraPreviewPane> createState() => _CameraPreviewPaneState();
}

class _CameraPreviewPaneState extends State<CameraPreviewPane> {
    bool _permissionDenied = false;
    String? _error;

    @override
    void initState() {
        super.initState();
        _initCamera();
    }

    Future<void> _initCamera() async {
        try {
            final granted = await CameraControl.requestPermission();
            if (!mounted) return;
            if (!granted) {
                setState(() => _permissionDenied = true);
                return;
            }

            await CameraControl.startCamera(
                captureWidth: 4208,
                captureHeight: 3120,
                analysisWidth: 1280,
                analysisHeight: 960,
            );
        } catch (e) {
            if (!mounted) return;
            setState(() => _error = e.toString());
        }
    }

    @override
    void dispose() {
        CameraControl.stopCamera();
        super.dispose();
    }

    @override
    Widget build(BuildContext context) {
        if (defaultTargetPlatform != TargetPlatform.android || !Platform.isAndroid) {
            return const Center(child: Text('eva_camera preview is Android-only.'));
        }
        if (_permissionDenied) {
            return const Center(child: Text('Camera permission denied.'));
        }
        if (_error != null) {
            return Center(child: Text('Camera init failed: $_error'));
        }

        return ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: const AndroidView(
                viewType: CameraControl.previewViewType,
                creationParamsCodec: StandardMessageCodec(),
            ),
        );
    }
}
```

This widget gives you:

- permission request on mount,
- camera start once granted,
- preview embedding via the native PlatformView, and
- camera stop on dispose to release resources.

---

## Still Capture

### Signal flow — photo save (triggered from Dart)

```text
Dart: CameraControl.capturePhoto()
    → MethodChannel: {method: capturePhoto}
    → CameraManager.capturePhoto(callback)
    → PhotoCaptureProcessor.onPhotoCapture(imageProxy, captureResult)
  → StillFrameSaver.saveToMediaStore(context, imageProxy)
  → callback(null)  [main thread]
```

```dart
// Dart — photo button handler
await CameraControl.capturePhoto();
```

### Signal flow — stitcher capture (triggered from native Kotlin)

```text
NativeStitcher (Kotlin): cameraManager.captureStitchFrame(callback)
    → StitchFrameProcessor.onStitchFrame(imageProxy, captureResult)
  → extract Y/RGB planes → NativeStitcher.addFrame(...)
  → callback(null)  [main thread]
```

The native stitcher has a reference to `CameraManager` and calls `captureStitchFrame` directly — no
MethodChannel round-trip to Dart.

### `ImageProxy` lifetime

`CameraManager` always calls `imageProxy.close()` in a `finally` block after your processor callback
returns. **Do not call `close()` in your processor.** Complete all buffer access before returning;
copy any `ByteBuffer` data that must survive beyond the call before returning.

---

## Camera Control (Dart API)

All methods are static on `CameraControl`. Returns are `Future<void>` unless noted.

### Capture

- `capturePhoto()` — Trigger full-resolution still capture for photo-save flows.
- `captureStitchFrame()` — Trigger full-resolution still capture for stitching flows.
- `setCaptureFormat(CaptureFormat)` — Switch between `yuv` and `jpeg` (triggers rebind).
- `setCaptureIntent(CaptureIntent)` — `preview` or `stillCapture` hint to camera pipeline.

### Exposure

| Method                     | Returns     | Description                  |
| -------------------------- | ----------- | ---------------------------- |
| `setAeEnabled(bool)`       | —           | Enable/disable auto-exposure |
| `setExposureTimeNs(int)`   | —           | Set manual shutter speed     |
| `setIso(int)`              | —           | Set manual ISO               |

### Focus

| Method                      | Returns  | Description               |
| --------------------------- | -------- | ------------------------- |
| `setAfEnabled(bool)`        | —        | Enable/disable auto-focus |
| `getCurrentFocusDistance()` | `double` | Current lens position     |
| `setFocusDistance(double)`  | —        | Set manual focus distance |

### White Balance

| Method              | Returns | Description                         |
| ------------------- | ------- | ----------------------------------- |
| `setWbLocked(bool)` | —       | Toggle between AWB auto and WB lock |

### Zoom

| Method                 | Returns | Description |
| ---------------------- | ------- | ----------- |
| `setZoomRatio(double)` | —       | Set zoom    |

### Diagnostics

- `startCamera()` → `CameraStartInfo`: starts camera and returns resolution + capability ranges in one payload.
- `startCamera(captureWidth?, captureHeight?, analysisWidth?, analysisHeight?)`: optional init-time target resolutions for ImageCapture and ImageAnalysis (width/height must be provided as pairs).
- `getResolution()` → `CameraResolutionInfo`: current capture + analysis resolutions.
- `setCaptureFormat(CaptureFormat)` → `CameraResolutionInfo`: switches capture format and returns updated resolutions.
- `dumpActiveCameraSettings()` → `CameraSettingsDumpInfo`: dump path + key counts for the generated settings file.

---

## Events (EventChannel)

Subscribe to `CameraControl.eventStream` to receive frame stats every 500 ms:

```dart
CameraControl.eventStream.listen((info) {
  final fps = info.fps;
  final frames = info.frameCount;
});
```

---

## `imageProxy.close()` contract

- `PhotoCaptureProcessor.onPhotoCapture` → **`CameraManager`** (finally block)
- `StitchFrameProcessor.onStitchFrame` → **`CameraManager`** (finally block)
- `FrameProcessor.processFrame` → **`CameraManager`** (finally block in `processFrame`)
- No processor registered → **`CameraManager`** (immediate close + warning log)

Processors must not call `close()`. All buffer access must complete before the callback returns.

---

## Build

```bash
flutter run            # debug on connected device
flutter build apk      # release APK
```

Requires: Java 17 · NDK 27.0.12077973 · Gradle 8.12 · AGP 8.9.x
