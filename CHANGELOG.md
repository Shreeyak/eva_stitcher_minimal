# Changelog

## 2026-03-07

### Full UI redesign — Material dark + deep blue theme

- Replaced the overlay/glass UI with a structured layout: 70 px left toolbar (`LeftToolbar`), full-area camera preview/canvas (`CanvasView`), top-right minimap (`MiniMap`), and a 36 px bottom info bar (`BottomInfoBar`), all in a solid Material dark palette with deep blue accent (`kAccent = #2979FF`).
- Added bottom `CameraSettingsDrawer` that slides up with tabbed ruler pickers (ISO, Shutter, EV, Focus, WB, Zoom). Each tab has an "A" auto toggle: ISO/Shutter share AE on/off, Focus = AF, WB = lock/unlock, EV resets to 0, Zoom resets to min. Custom `RulerPicker` widget draws a horizontal tick-ruler with center orange marker + drag-to-scroll.
- Extracted `CameraControl` to `lib/camera_control.dart`; color palette to `lib/app_theme.dart`; all new widgets in `lib/widgets/`. Added scan toggle + session timer (`_sessionSeconds`, `_sessionTimer`) and scene-state fields (`_isScanning`, `_showCanvas`, `_settingsDrawerOpen`).


### Gradle settings fix

- Restored missing `:opencv` module registration in `android/settings.gradle.kts` before assigning its `projectDir`, fixing Gradle's `Project with path ':opencv' could not be found` failure.
- Repaired a corrupted `android/app/build.gradle.kts`: restored `dependencies {}`, `externalNativeBuild`, CameraX/OpenCV wiring, Java 17 toolchain settings, and `arm64-v8a` ABI filtering.

### OpenCV Gradle module alignment

- Aligned OpenCV setup with `eva_stitching_demo` reference project: `:opencv` Gradle module registered in `settings.gradle.kts`, linked via `implementation(project(":opencv"))`.
- `CMakeLists.txt` now uses `find_package(OpenCV REQUIRED COMPONENTS java)` + `${OpenCV_LIBS}` instead of a manual `IMPORTED` target; `OpenCV_DIR` passed from `build.gradle.kts`.
- `libc++_shared.so` packaging handled automatically by the module (removed explicit `-DANDROID_STL=c++_shared`); `ndkVersion` pinned to `27.0.12077973`, `jvmTarget` bumped to `17`.

### JNI / C++ scaffolding

- Created `android/app/src/main/cpp/CMakeLists.txt` + `stitcher_jni.cpp` with `processFrame()` stub: YUV→BGR, returns mean-Y luminance (1/16-sampled).
- Created `NativeStitcher.kt` JNI bridge (`System.loadLibrary`, `external fun processFrame → Float`).
- Fixed `build.gradle.kts` (missing `dependencies {}`, added `externalNativeBuild`, `ndk { abiFilters += "arm64-v8a" }`, `cameraxVersion = "1.5.3"`).

### Manual exposure / ISO control

- Removed custom AE P-controller (EV compensation index approach) from `CameraManager.kt` and `MainActivity.kt`.
- Added `SENSOR_EXPOSURE_TIME` + `SENSOR_SENSITIVITY` raw manual control: `setExposureTimeNs`, `setIso`, `getExposureTimeRangeNs`, `getIsoRange` in Kotlin and Dart.
- Device capability ranges (`exposureTimeRangeNs`, `sensitivityIsoRange`) now stored as class fields in `CameraManager` after camera start.

### ISP quality settings

- `applyAllCaptureOptions()` now always sets `EDGE_MODE_OFF`, `NOISE_REDUCTION_MODE_FAST`, `COLOR_CORRECTION_ABERRATION_MODE_FAST`, `CONTROL_VIDEO_STABILIZATION_MODE_OFF`, `HOT_PIXEL_MODE_FAST`, `SHADING_MODE_FAST` for WSI quality.

### CameraCharacteristics dump

- Added `dumpCameraCharacteristics()` to `CameraManager.kt`: writes all key characteristics to `camera_dump.txt` in app external files dir on first camera start.

### Flutter UI

- When AE is disabled, exposure slider replaced with two sliders: exposure time (µs) and ISO. EV offset slider shown only when AE is on.
- Added `_buildVerticalSlider` `left` parameter (default 60) for side-by-side slider layout.
