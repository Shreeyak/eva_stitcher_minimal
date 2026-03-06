# CameraX 1.5 — What's New

**Version used:** `1.5.3` (latest stable, January 28 2026)
**Minimum SDK raised:** API 21 → **API 23**

Source: [AndroidX CameraX Releases](https://developer.android.com/jetpack/androidx/releases/camera)

---

## Major New Features (vs 1.4.0)

### 1. SessionConfig & FeatureGroup API
A new `SessionConfig` API lets you configure the camera session and safely enable multiple features together — HLG (HDR), UltraHDR, 60 FPS, preview stabilization. You can mark feature groups as **required** or **preferred** with priority, and CameraX picks the best supported combination.

Key APIs:
- `SessionConfig.Builder#setPreferredFeatureGroup`
- `SessionConfig.Builder#setRequiredFeatureGroup`
- `CameraInfo#isFeatureGroupSupported(SessionConfig)`

### 2. Deterministic Frame Rate
Replaces the old `setTargetFrameRate` with precise, guaranteed frame rates:
- `CameraInfo.getSupportedFrameRateRanges(sessionConfig)` — query what's actually supported
- `SessionConfig.setExpectedFrameRateRange` — set an exact range

### 3. High-Speed / Slow-Motion Recording
Record at 120/240 fps with minimal code:
- `Recorder#getHighSpeedVideoCapabilities(CameraInfo)`
- `HighSpeedVideoSessionConfig`

### 4. Low Light Boost
On Android 15+ devices, enable `CONTROL_AE_MODE_ON_LOW_LIGHT_BOOST_BRIGHTNESS_PRIORITY` to automatically brighten preview / video / analysis in dark conditions:
- `CameraInfo#isLowLightBoostSupported`
- `CameraControl#enableLowLightBoostAsync`
- `CameraInfo#getLowLightBoostState`

### 5. Torch Strength Control
Adjust torch brightness level instead of just on/off:
- `CameraControl#setTorchStrengthLevel`
- `CameraInfo#getTorchStrengthLevel` / `getMaxTorchStrengthLevel`

### 6. RAW (DNG) Image Capture
`ImageCapture` now supports DNG and simultaneous JPEG + DNG output:
- Check `ImageCaptureCapabilities(CameraInfo).getSupportedOutputFormats()` for RAW support
- Overloaded `takePicture` APIs accept multiple `OutputFileOptions` for RAW + JPEG

### 7. NV21 Format for ImageAnalysis
`ImageAnalysis.Builder.setOutputImageFormat(OUTPUT_IMAGE_FORMAT_NV21)` — useful for ML pipelines that expect NV21 instead of YUV_420_888.

### 8. UltraHDR with Extensions
UltraHDR format is now available when camera Extensions are enabled. Zoom ratio and preview stabilization capabilities are correctly reflected under Extensions.

### 9. Video Capture Improvements
- `VideoRecordEvent.Finalize.ERROR_INSUFFICIENT_STORAGE` — proper notification for disk-full
- `PendingRecording.withAudioEnabled(boolean initialMuted)` — control initial mute state

### 10. LifecycleCameraProvider
`LifecycleCameraProvider` can be instantiated with custom configurations, including virtual-device camera access.

### 11. Compose Viewfinder
New `camera-compose` artifact with `CameraXViewfinder` composable for displaying `SurfaceRequest` preview in Jetpack Compose, with `ContentScale` and `Alignment` support.

---

## Bug Fixes Relevant to This Project

| Fix | Patch |
|-----|-------|
| ExifInterface JPEG parsing crash | 1.5.3 |
| `DynamicRange` crash on Android 17+ | 1.5.2 |
| `PreviewView` memory leak | 1.5.1 |
| YUV_420_888 size exclusion (Nokia 7 Plus) | 1.5.1 |
| Target rotation lost on UseCase recreation | 1.5.1 |
| Preview freeze with ImageAnalysis + TEMPLATE_RECORD (Samsung) | 1.5.0-beta01 |

---

## Impact on Our Project

- **ImageAnalysis NV21** — potential simplification if C++ JNI side prefers NV21 over YUV_420_888
- **Low Light Boost** — useful for microscope scanning in poor lighting; we target API 35 so this is available
- **SessionConfig** — cleaner way to bind Preview + ImageCapture + ImageAnalysis together with explicit feature requirements
- **Torch Strength** — could help with consistent illumination during slide scanning
- **minSdk 23** — no impact, we target API 35
