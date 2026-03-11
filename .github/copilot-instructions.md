# Copilot Instructions — eva_minimal_demo

## Project Overview

Flutter Android app for **whole slide imaging (WSI)**: incremental camera stitching that warps and blends live camera frames onto a growing panoramic canvas. Target use case — scanning a microscope slide by moving the phone slowly.

## Architecture: Three Layers

```
Flutter / Dart  ←→  Kotlin (CameraX + Camera2)  ←→  C++ / OpenCV (Phase 2, JNI)
```

| Layer           | Location                                                     | Status                  |
| --------------- | ------------------------------------------------------------ | ----------------------- |
| Flutter UI      | `lib/`                                                       | in progress             |
| Flutter widgets | `lib/widgets/`                                               | in progress             |
| Camera state    | `lib/camera/`                                                | done                    |
| Kotlin camera   | `android/app/src/main/kotlin/com/example/eva_minimal_demo/`  | done                    |
| C++ stitching   | JNI placeholder in `CameraManager.kt` ImageAnalysis callback | **not yet implemented** |

## Flutter ↔ Android Communication

Three fixed channels defined in `MainActivity.kt`:

- **`PlatformView "camerax-preview"`** — embeds native `PreviewView` directly into Flutter widget tree via `CameraPreviewFactory`
- **`MethodChannel "com.example.eva/control"`** — camera commands: `startCamera`, `stopCamera`, `saveFrame`, `lockWhiteBalance`, `unlockWhiteBalance`, `setAfEnabled`, `setAeEnabled`, `setExposureOffset`, `setFocusDistance`, `setZoomRatio`, `setIso`, `setExposureTimeNs`, etc.
- **`EventChannel "com.example.eva/events"`** — pushes `{frameCount, fps}` map to Dart every 500 ms

## CameraX Configuration (Critical Details)

All CameraX logic lives in `CameraManager.kt`. Three simultaneous use cases:

- **Preview** → `PreviewView.surfaceProvider` (never lags — separate surface pipeline)
- **ImageCapture** → 3120×2160, `CAPTURE_MODE_MINIMIZE_LATENCY`, JPEG saved to `Pictures/EvaWSI/` via MediaStore
- **ImageAnalysis** → 640×480, `YUV_420_888`, `STRATEGY_KEEP_ONLY_LATEST` — the JNI entry point for Phase 2

Camera2 low-level features via `@ExperimentalCamera2Interop`:

- Live `TotalCaptureResult` used to snoop `COLOR_CORRECTION_TRANSFORM`, `COLOR_CORRECTION_GAINS`, `LENS_FOCUS_DISTANCE`
- All manual overrides (AF/AE/WB/focus/exposure) written atomically through `applyAllCaptureOptions()` — **never set capture options individually, always go through this method**

**White balance lock pattern**: while AWB is auto, continuously capture live CCM + RGGB gains; on lock, switch to `CONTROL_AWB_MODE_OFF` and replay those captured values. Fallback chain: live captured → `SENSOR_COLOR_TRANSFORM1/2` characteristics → identity matrix.

## Stitching / Canvas Architecture (Phase 2 Target)

Two conceptual layers (see `docs/`):

1. **Global Pose Graph** — sparse optical flow (Lucas-Kanade KLT) → RANSAC → two-stage pyramidal ECC refinement → similarity transform (translation + rotation only, planar assumption)
2. **Chunked Tile Renderer** — sparse `TileGrid` with `unordered_map<long long, Tile>`. Each tile: 256×256 logical + 32 px padding → 320×320 buffer. Tiles store Laplacian pyramid accumulators (`laplacian_sum`, `weight_sum`). Only tiles intersecting the warped frame's bounding box are updated per frame.

Key stitching decisions from the docs:

- Crop **768 px center** from each captured frame — only this region is stitched
- Seam-free tiling: warp into padded buffer, blend with Laplacian pyramid, crop center on render
- Blending weights computed in **global panorama coordinates** (not tile-local) to prevent seams at tile boundaries
- Blur rejection: gradient energy on downsampled frame (~0.1 ms) → FAST feature count gate → optical flow residual check

## Camera State Layer (`lib/camera/`)

- **`camera_state.dart`** — immutable data classes: `CameraValues` (user-controlled settings), `CameraRanges` (device capability limits), `CameraInfo` (live telemetry), `CameraCallbacks` (bundled action callbacks). `CameraSettingType` enum (`iso`, `shutter`, `focus`, `wb`, `zoom`). `CameraValues.initialFromRanges()` provides startup defaults.
- **`camera_settings_queue.dart`** — latest-wins queue that serializes native Camera2 writes. Prevents rapid slider scrubs from piling up and causing `CancellationException`. AF-disable-before-manual-focus is enforced in queue order. **Camera2 `setCaptureRequestOptions` cancels prior pending futures — settings must be sent sequentially, never via `Future.wait`.**
- **`camera_control.dart`** — MethodChannel wrappers for camera commands.

## Flutter UI Structure

`lib/main.dart` is the entry point. UI is split into focused stateless/stateful widgets under `lib/widgets/`. No state management framework — plain `StatefulWidget` + `setState` or `ValueNotifier` as needed. Material 3 dark color theme — colors via `Theme.of(context).colorScheme` (not hardcoded constants).

Key widgets:

- **`SideButton`** (`lib/widgets/side_button.dart`) — icon + label button with `isActive` (left-border highlight), `isDisabled`, `isLarge`, and optional `color` props. Default color is white (overlaid on camera preview).
- **`LeftToolbar`** (`lib/widgets/left_toolbar.dart`) — left-side panel with scan/finalize/reset/AF/AE controls.
- **`CameraControlOverlay`** (`lib/widgets/camera_control_overlay.dart`) — floating dial/slider overlays for ISO, shutter, focus, WB, zoom.
- **`CameraRulerDial`** (`lib/widgets/camera_ruler_dial/`) — ruler-style dial for precise camera setting adjustment.
- **`BottomInfoBar`** (`lib/widgets/bottom_info_bar.dart`) — status bar with FPS, frame count, and live telemetry.
- **`MiniMap`** (`lib/widgets/mini_map.dart`) — small preview of the stitched canvas.
- **`CanvasView`** (`lib/widgets/canvas_view.dart`) — large canvas preview for stitched output.

The main screen overlays these widgets on top of the native camera `PlatformView`.

## OpenCV Integration

OpenCV is included as a local Android library module at `android/opencv/`. A stub CMakeLists lives at `android/opencv/sdk/libcxx_helper/CMakeLists.txt` to bring `libc++_shared.so` into the APK. No project-owned JNI `.cpp` files exist yet — add them under `android/app/src/main/cpp/` and wire up `externalNativeBuild` in `android/app/build.gradle.kts`.

Expected Phase 2 data flow:

```
ImageAnalysis (YUV_420_888) → JNI → C++ OpenCV (BGR Mat) → KLT → ECC → warpAffine → TileGrid → JNI → Dart → CustomPainter
```

## Build & Run

```bash
flutter run                          # run on connected Android device
flutter build apk                    # build release APK
```

Target and minimum Android API: **34**. CameraX `1.5.3` requires API 21+; Camera2 interop metadata (`TotalCaptureResult` color/focus fields) requires API 28+ in practice.

Gradle **8.12**, AGP **8.9.x**, NDK **27.0.12077973**, C++17.

## Key Files

| File                                             | Purpose                                                |
| ------------------------------------------------ | ------------------------------------------------------ |
| `android/app/src/main/kotlin/…/CameraManager.kt` | All camera logic, WB lock, FPS events, JNI placeholder |
| `android/app/src/main/kotlin/…/MainActivity.kt`  | Channel wiring, permission handling                    |
| `lib/camera/camera_state.dart`                   | Immutable camera data classes and enums                |
| `lib/camera/camera_settings_queue.dart`          | Latest-wins queue for serialized Camera2 writes        |
| `docs/PLAN_ARCH.md`                              | Full requirements and algorithm design                 |
| `docs/Chunked_canvas_implementation_details.md`  | C++ tile data structures and pyramid blending          |
| `docs/Tiny_chunks_canvas.md`                     | Stitching pipeline flow diagram                        |
| `docs/ARCore_blur_rejection.md`                  | Blur rejection strategy reference                      |
| `docs/Avoid_seams_with_tiling.md`                | Seam-free blending strategies                          |

## Rules and Conventions

### Design Philosophy

> **CONSTRAINT**: Prefer the simplest solution that works. Do not add abstractions, layers, or dependencies unless clearly necessary. Ask the user for preference before adding depth to design.

> **CONSTRAINT**: If a question is asked, do not start implementing until the question is answered. If you don't know the answer, say so and suggest how to find it (search terms, MCP servers, documentation sections). Do not guess.

> **CONSTRAINT**: Use Context7 MCP (`io.github.stash/context7`) to fetch documentation when unsure about API usage, best practices, or when implementing new features. See `.github/instructions/context7.instructions.md`.

### Flutter / Dart

- **State management**: Plain `StatefulWidget` + `setState`. No frameworks (Provider, Riverpod, etc.). Use `ValueNotifier` only for cross-widget state that can't share a parent.
- **Widget location**: All widgets in `lib/widgets/`. Entry point is `lib/main.dart`.
- **Widget preference**: `StatelessWidget` by default; `StatefulWidget` only when local mutable state is genuinely needed.
- **File size**: One widget per file. Target ≤ 300 lines. Split or extract logic if larger.
- **Data flow**: Pass callbacks down explicitly. No global state, no `InheritedWidget` unless tree depth makes it painful.
- **Compositing**: UI overlays native camera `PlatformView` — keep widget trees shallow to avoid compositing overhead.
- **Theme**: Material 3 dark color theme. Use `Theme.of(context).colorScheme` — never hardcode color constants.

- **Material 3 Components** - use Material 3 components and theming. For example, use `ElevatedButton`, `FilterChip`, and `ThemeData.colorScheme` for colors instead of hardcoded values.

### Kotlin / Android

- **Camera logic**: All camera logic stays in `CameraManager.kt`. Do **not** scatter camera state into `MainActivity.kt`.
- **New commands**: New MethodChannel commands → add to `MainActivity.kt`'s `when` block, implement logic in `CameraManager.kt`.
- **Settings writes**: Always go through `applyAllCaptureOptions()`. Never set capture options individually.

### C++ / OpenCV (Phase 2)

- **Source location**: New JNI source files → `android/app/src/main/cpp/`. Wire via `externalNativeBuild` in `android/app/build.gradle.kts`.
- **API choice**: Use OpenCV C++ API, not Java bindings — native library is at `android/opencv/`.
- **Memory**: Prefer in-place operations and pre-allocated buffers to minimize per-frame allocations.
- **GPU forbidden**: No `cv::cuda::`, `cv::ocl::`, or OpenCL calls. OpenCV is CPU-only in this project.

### Build

- **ABI**: **Only `arm64-v8a`** — no x86/armeabi-v7a support.
- **Java**: **Java 17 required** — Java 25+ breaks Gradle/AGP 8.9.x.

### Terminal / Tooling

> **DO NOT**: Pipe or redirect terminal output to suppress or truncate it. No `| tail`, `| head`, `2>&1 | tail`, `> /dev/null`, or any output suppression. Always let commands print full output.

> **DO NOT**: Use heredoc syntax in terminal commands — they fail in this environment.

> **DO**: Create all tmp files in `scripts/tmp_files/` and delete them after use.

> **DO**: If editing fails or a file appears corrupted, write intended contents to a new file, delete the original, then rename the new file to the original path.

### Changelog

> **ALWAYS**: Update `CHANGELOG.md` when a feature, algorithm, or implementation is added, modified, deleted, or reverted. Include date + brief description. Maximum three lines per entry.
