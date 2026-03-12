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

## Camera Invariants

- All CameraX logic in `CameraManager.kt`. Three use cases: Preview, ImageCapture (3120×2160), ImageAnalysis (640×480 YUV — JNI entry point for Phase 2).
- **All manual overrides go through `applyAllCaptureOptions()`** — never set capture options individually.
- **Camera2 `setCaptureRequestOptions` cancels prior pending futures** — settings must be sent sequentially, never `Future.wait`.
- WB lock: capture live CCM + gains while AWB auto → replay on lock. Fallback: sensor characteristics → identity.
- Camera state: `CameraValues`, `CameraRanges`, `CameraInfo`, `CameraCallbacks` in `camera_state.dart`; `CameraSettingsQueue` serializes native writes in `camera_settings_queue.dart`; `CameraControl` wraps MethodChannel in `camera_control.dart`.

## Stitching (Phase 2 — not yet implemented)

KLT optical flow → RANSAC → ECC refinement → similarity transform → chunked tile grid with Laplacian pyramid blending. See `docs/PLAN_ARCH.md` and `docs/Chunked_canvas_implementation_details.md` for full design.

## Flutter UI

Entry point: `lib/main.dart`. Widgets in `lib/widgets/`, one per file. Key widgets: `InteractiveBottomBar`, `CameraControlOverlay`, `CameraRulerDial` (subdirectory), `CameraSettingsBar`, `BottomInfoBar`, `BottomBarButtons`, `SideButton`, `MiniMap`, `CanvasView`. Main screen overlays these on the native camera PlatformView. OpenCV included as local Android module at `android/opencv/`; JNI sources will go in `android/app/src/main/cpp/`.

## Build & Run

```bash
flutter run            # debug on connected device
flutter build apk      # release APK
```

API 34 min+target · Gradle 8.12 · AGP 8.9.x · NDK 27.0.12077973 · C++17 · `arm64-v8a` only · Java 17 required

## Key Files

| File                                    | Purpose                                          |
| --------------------------------------- | ------------------------------------------------ |
| `android/…/CameraManager.kt`            | All camera logic, WB lock, FPS events            |
| `android/…/MainActivity.kt`             | Channel wiring, permissions                      |
| `lib/camera/camera_state.dart`          | Camera data classes, enums, defaults             |
| `lib/camera/camera_settings_queue.dart` | Latest-wins queue for serialized Camera2 writes  |
| `docs/PLAN_ARCH.md`                     | Full stitching requirements and algorithm design |

## Rules and Conventions

### Design Philosophy

- Prefer the simplest solution. No abstractions unless clearly necessary.
- Wait for answers before implementing. Don't guess.
- Use Context7 MCP to fetch docs when unsure about API usage.

### Flutter / Dart

- **State**: `StatefulWidget` + `setState`. No Provider/Riverpod. `ValueNotifier` only for cross-widget state.
- **Widgets**: `lib/widgets/`, one per file, ≤300 lines. `StatelessWidget` by default.
- **Data flow**: Pass callbacks down explicitly. No global state.
- **Theme**: Material 3 dark. `Theme.of(context).colorScheme` — never hardcode colors. Use M3 components (`FilterChip`, `SegmentedButton`, etc.).

### Kotlin / Android

- **Camera logic**: All camera logic stays in `CameraManager.kt`. Do **not** scatter camera state into `MainActivity.kt`.
- **New commands**: New MethodChannel commands → add to `MainActivity.kt`'s `when` block, implement logic in `CameraManager.kt`.
- **Settings writes**: Always go through `applyAllCaptureOptions()`. Never set capture options individually.

### C++ / OpenCV (Phase 2)

- **Source location**: New JNI source files → `android/app/src/main/cpp/`. Wire via `externalNativeBuild` in `android/app/build.gradle.kts`.
- **API choice**: Use OpenCV C++ API, not Java bindings — native library is at `android/opencv/`.
- **Memory**: Prefer in-place operations and pre-allocated buffers to minimize per-frame allocations.
- **GPU forbidden**: No `cv::cuda::`, `cv::ocl::`, or OpenCL calls. OpenCV is CPU-only in this project.

### Terminal

- Never use heredocs (`cat << EOF`) or `echo` for multi-line code — use `create_file`/`replace_string_in_file`.
- Temp files → `scripts/tmp_files/`, delete after use. No output suppression.
- See `.github/instructions/terminal-rules.instructions.md` for full policy.

### Changelog

> **ALWAYS**: Update `CHANGELOG.md` when a feature, algorithm, or implementation is added, modified, deleted, or reverted. Include date + brief description. Maximum three lines per entry.
