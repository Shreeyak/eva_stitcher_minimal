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
                             ├─ ImageCapture (3120×4208 YUV or JPEG)
                             └─ ImageAnalysis (960×1280 YUV, ~30 fps)
                                    │                       │
                                    ▼                       ▼
                             FrameProcessor         StillCaptureProcessor
```

Three CameraX use cases run simultaneously:

- Preview — device default, output to `PreviewView` PlatformView.
- ImageCapture — 4208×3120, delivered to `StillCaptureProcessor`.
- ImageAnalysis — 1280×960, delivered to `FrameProcessor` (YUV, ~30 fps).

---

## Setup

### 1. Register processors in `configureFlutterEngine`

Implement the native interfaces and register them **before** `startCamera` is called from Dart.

```kotlin
// MainActivity.kt
import com.example.eva_camera.EvaCameraPlugin
import com.example.eva_camera.FrameProcessor
import com.example.eva_camera.StillCaptureProcessor
import com.example.eva_camera.StillFrameSaver

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)

        EvaCameraPlugin.setFrameProcessor(object : FrameProcessor {
            override fun processFrame(
                width: Int, height: Int,
                yPlane: ByteArray, uPlane: ByteArray, vPlane: ByteArray,
                yRowStride: Int, uvRowStride: Int, uvPixelStride: Int,
                captureResult: TotalCaptureResult?,
            ): Float {
                // TODO: pass to NativeStitcher via JNI
                return 0f
            }
        })

        EvaCameraPlugin.setStillCaptureProcessor(object : StillCaptureProcessor {
            override fun onStillCapture(
                imageProxy: ImageProxy,
                captureResult: TotalCaptureResult?,
                save: Boolean,
            ) {
                if (save) {
                    // photo mode: persist to gallery
                    StillFrameSaver.saveToMediaStore(applicationContext, imageProxy)
                } else {
                    // stitcher mode: extract planes for registration + blend
                    val yBuf  = imageProxy.planes[0].buffer  // luma, zero-copy ByteBuffer
                    val uBuf  = imageProxy.planes[1].buffer
                    val vBuf  = imageProxy.planes[2].buffer
                    // NativeStitcher.addFrame(yBuf, uBuf, vBuf, ...)
                }
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
  viewType: 'camerax-preview',
  creationParamsCodec: const StandardMessageCodec(),
)
```

---

## Still Capture

### Signal flow — photo save (triggered from Dart)

```text
Dart: CameraControl.captureImage(save: true)
  → MethodChannel: {method: captureImage, save: true}
  → CameraManager.captureImage(save=true, callback)
  → StillCaptureProcessor.onStillCapture(imageProxy, captureResult, save=true)
  → StillFrameSaver.saveToMediaStore(context, imageProxy)
  → callback(null)  [main thread]
```

```dart
// Dart — photo button handler
await CameraControl.captureImage(save: true);
```

### Signal flow — stitcher capture (triggered from native Kotlin)

```text
NativeStitcher (Kotlin): cameraManager.captureImage(save=false, callback)
  → StillCaptureProcessor.onStillCapture(imageProxy, captureResult, save=false)
  → extract Y/RGB planes → NativeStitcher.addFrame(...)
  → callback(null)  [main thread]
```

The native stitcher has a reference to `CameraManager` and calls `captureImage` directly — no
MethodChannel round-trip to Dart.

### `ImageProxy` lifetime

`CameraManager` always calls `imageProxy.close()` in a `finally` block after `onStillCapture`
returns. **Do not call `close()` in your processor.** Complete all buffer access before returning;
copy any `ByteBuffer` data that must survive beyond the call before returning.

---

## Camera Control (Dart API)

All methods are static on `CameraControl`. Returns are `Future<void>` unless noted.

### Capture

- `captureImage({save: false})` — Trigger full-resolution still capture.
- `setCaptureFormat(CaptureFormat)` — Switch between `yuv` and `jpeg` (triggers rebind).
- `setCaptureIntent(CaptureIntent)` — `preview` or `stillCapture` hint to camera pipeline.

### Exposure

| Method                     | Returns     | Description                  |
| -------------------------- | ----------- | ---------------------------- |
| `setAeEnabled(bool)`       | —           | Enable/disable auto-exposure |
| `getExposureOffsetRange()` | `List<int>` | AE compensation index range  |
| `getExposureOffsetStep()`  | `double`    | EV per index step            |
| `setExposureOffset(int)`   | —           | Set AE compensation index    |
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

Subscribe to `CameraControl.events` to receive frame stats every 500 ms:

```dart
CameraControl.events.receiveBroadcastStream().listen((data) {
  final map = Map<String, dynamic>.from(data as Map);
  final fps = map['fps'] as double;
  final frames = map['frameCount'] as int;
});
```

---

## `imageProxy.close()` contract

- `StillCaptureProcessor.onStillCapture` → **`CameraManager`** (finally block)
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
