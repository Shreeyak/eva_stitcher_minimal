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
| Kotlin camera   | `android/app/src/main/kotlin/com/example/eva_minimal_demo/`  | done                    |
| C++ stitching   | JNI placeholder in `CameraManager.kt` ImageAnalysis callback | **not yet implemented** |

## Flutter ↔ Android Communication

Three fixed channels defined in `MainActivity.kt`:

- **`PlatformView "camerax-preview"`** — embeds native `PreviewView` directly into Flutter widget tree via `CameraPreviewFactory`
- **`MethodChannel "com.example.eva/control"`** — camera commands: `startCamera`, `stopCamera`, `saveFrame`, `lockWhiteBalance`, `setAfEnabled`, `setAeEnabled`, `setExposureOffset`, `setFocusDistance`, `setZoomRatio`, etc.
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

## Flutter UI Structure

`lib/main.dart` is the entry point. UI is split into focused stateless/stateful widgets under `lib/widgets/`. No state management framework — plain `StatefulWidget` + `setState` or `ValueNotifier` as needed.

Key widget patterns from staging files in `scripts/tmp_files/`:

- **`SideButton`** (`lib/side_button.dart`) — icon + label button with `isActive` (left-border highlight), `isDisabled`, `isLarge`, and optional `color` props. Default color is white (overlaid on camera preview).
- **`GlassToolbar`** (`lib/widgets/glass_toolbar.dart`) — 80 px wide right-side panel using `BackdropFilter` blur + semi-transparent black (`Colors.black.withOpacity(0.3)`). Contains scan start/stop, finalize, reset, AF lock, AE lock, and debug buttons as `SideButton` children.

The main screen overlays `GlassToolbar` on top of the native camera `PlatformView`.

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

Target and minimum Android API: **34**. CameraX `1.4.0` requires API 21+; Camera2 interop metadata (`TotalCaptureResult` color/focus fields) requires API 28+ in practice.

## Key Files

| File                                             | Purpose                                                |
| ------------------------------------------------ | ------------------------------------------------------ |
| `android/app/src/main/kotlin/…/CameraManager.kt` | All camera logic, WB lock, FPS events, JNI placeholder |
| `android/app/src/main/kotlin/…/MainActivity.kt`  | Channel wiring, permission handling                    |
| `docs/PLAN_ARCH.md`                              | Full requirements and algorithm design                 |
| `docs/Chunked_canvas_implementation_details.md`  | C++ tile data structures and pyramid blending          |
| `docs/Tiny_chunks_canvas.md`                     | Stitching pipeline flow diagram                        |
| `docs/ARCore_blur_rejection.md`                  | Blur rejection strategy reference                      |
| `docs/Avoid_seams_with_tiling.md`                | Seam-free blending strategies                          |

## Rules and Conventions

### General

- **Minimal and lightweight**: prefer the simplest solution that works. Do not add abstractions, layers, or dependencies unless clearly necessary. Ask the user for preference. Give suggestions and ask before adding depth to design.
- **No state management frameworks**: use plain `StatefulWidget` + `setState`. Use `ValueNotifier` only when sharing state across widgets that can't easily share a parent.
- One widget per file. Keep files short and focused. Try to keep the files 300 lines or less. If a file grows beyond that, consider if it can be split into multiple widgets or if some logic can be moved out.
- Use context7 MCP to fetch documentation when unsure about API usage or best practices or when implementing new features.
- If a question is asked, do not start implementing until the question is answered. Ask the user if they want to implement it. If you don't know the answer, say you don't know and suggest how to find the answer (e.g. search terms, MCP servers, documentation sections, etc). Do not make assumptions or guesses about things you are unsure of.
- Add to the changelog in `CHANGELOG.md` every time a feature, algorithm or implementation is added, modified, deleted or reverted, with a brief description and the date. Maximum three lines per implementation. This will help keep track of the history of changes and the rationale behind them.
- **NEVER pipe or redirect terminal output to suppress or truncate it** — do not append `2>&1 | tail -N`, `| tail -N`, `| head -N`, `> /dev/null`, or any other form of output suppression or truncation to any command. ALWAYS let commands print their full output directly to the terminal. If filtering is needed, redirect a copy of stdout/stderr to a file in `scripts/tmp_files/` and then read that file.
- Create all tmp files in `scripts/tmp_files/` and delete them after use. Do not use heredoc syntax for terminal commands.

### Flutter / Dart

- Widgets go in `lib/widgets/`. Entry point is `lib/main.dart`. Reusable single-file primitives (like `SideButton`) live directly in `lib/`.
- Prefer `StatelessWidget` by default; only use `StatefulWidget` when local mutable state is genuinely needed.
- Pass callbacks down explicitly (no global state, no `InheritedWidget` unless the tree depth makes it painful).
- UI overlays the native camera `PlatformView` — keep widget trees shallow to avoid compositing overhead.

### Kotlin / Android

- All camera logic stays in `CameraManager.kt`. Do not scatter camera state into `MainActivity.kt`.
- New MethodChannel commands go in `MainActivity.kt`'s `when` block; implement the logic in `CameraManager.kt`.

### C++ / OpenCV (Phase 2)

- New JNI source files go in `android/app/src/main/cpp/`. Wire them up via `externalNativeBuild` in `android/app/build.gradle.kts`.
- Use OpenCV C++ API, not Java bindings — the native library is already at `android/opencv/`.
- Prefer in-place operations and pre-allocated buffers to minimize allocations per frame.
- **OpenCV CPU-only** Do not use GPU methods or mats: no `cv::cuda::`, `cv::ocl::`, or OpenCL calls.

### Terminal / Tooling

- Never use heredoc syntax in terminal commands — they fail in this environment. Instead write to a file in `scripts/tmp_files/` using file tools, run it, then delete it.
- **NEVER truncate terminal output** — do not append `| head`, `| tail`, `2>&1 | tail`, or any output suppression to any command, including long-running ones like `flutter build apk`. Full output must always be visible.

### build

- **Only `arm64-v8a` ABI** is built — no x86/armeabi-v7a support
- **Java 17 required** — Java 25+ breaks Gradle/AGP 8.9.x
