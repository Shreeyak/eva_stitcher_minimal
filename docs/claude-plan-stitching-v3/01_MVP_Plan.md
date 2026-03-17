# MVP Stitching Pipeline v3

**Date**: 2025-07-10
**Prerequisite**: Current branch `stitch1` — `native/stitcher/` and `lib/stitcher/` are empty. Camera plugin (`eva_camera`) provides two-stream CameraX (Preview + ImageAnalysis) with configurable resolution via `startCamera()`. ImageCapture is retained only for the debug capture button and does not participate in stitching.

## 6) What changed from older plans

### Compared to v1 plan (`claude-plan-stitching/`)

| Area | v1 (claude-plan-stitching) | v3 |
|------|----------------------------|-----|
| **Analysis resolution** | 640×480 YUV (navigation only) | 1600×1200 target with fallback negotiation |
| **Capture resolution** | 3120×2160 full-res for stitching | Analysis YUV 40% center crop (~640×480) → resize 800×600 for stitch commit |
| **Crop policy** | No center crop; full-frame processing | 40% width × 40% height center crop for both streams |
| **Scale bridge** | capture/analysis = 3120/640 ≈ 4.875 | Computed from actual resolutions; not hardcoded |
| **Stitch registration** | Phase correlation on full-res capture (13MP FFT) | Phase correlation on 800×600 stitch frame; ECC refinement in MVP |
| **ECC** | Deferred to Phase 2 | Included in MVP Phase 5 with runtime guardrails |
| **Quality formula** | Phase correlation confidence only (peak/mean ≈ 0.15 threshold) | Cubic-root: ∛(confidence × sharpness × overlapRatio) |
| **Gating** | Velocity + distance + stability + tracking + cooldown | Adds sharpness, overlap, reason codes, structured log schema |
| **First frame** | Special case: pose=(0,0), no registration, direct write | Full gating required; overlap deadlock prevented via canvasEmpty state machine |
| **Coordinate system** | World coords at first frame center; tiles 1024×1024 | Canvas-only coords; no world layer in MVP |
| **Vignetting** | In MVP scope (radial gain model) | Deferred to future plan |
| **Blending** | Linear feathering (scalar loops) | Linear feathering (OpenCV mat ops; no scalar loops) |
| **Zero-copy** | Y-channel zero-cost extraction; capture requires YUV→RGB copy | ByteBuffer JNI zero-copy for analysis stream (Y for nav, Y+U+V for stitch commit); ByteArray copies forbidden |
| **Two-stream alignment** | Implicit two-stream (analysis + capture) | Two-stream (Preview + Analysis); stitch commit uses analysis YUV inline; ImageCapture debug-only |
| **Transform ownership** | Navigation owns dead-reckoning, stitch owns refinement | Explicit CameraX-first ownership table with no-duplicate rule and startup assertion |
| **Latency** | Full-res FFT on 13MP caused ~2.5s latency (identified in 07) | Crop-early strategy targets <300ms; full-res PCR removed |
| **UI** | Velocity border/bar, capture flash, mini-map, LOST warning | Adds quality bar, BLURRY indicator, preview border pulse (replaces full-screen flash), InfoBar confidence |
| **Phase structure** | Phase 1 MVP + Phase 2 deferred (2 large phases) | 8 small phases, each independently testable with verification steps |
| **Logging** | Ad-hoc confidence and state logs | Structured schema: STREAM_ALIGN, CAPTURE_GATE, POSE, COMMIT, UI_STATUS, LATENCY, ANALYSIS_RESOLUTION |

**Key v1 lessons incorporated into v3:**

1. Capture delay investigation (doc 07) showed full-res PCR was the primary bottleneck — v3 eliminates it by cropping to 800×600 before registration.
2. First-frame distance check bug (doc 06) — v3 handles first-frame semantics explicitly via the canvasEmpty state machine rather than a special-case bypass.
3. Phase correlation confidence alone was insufficient for quality gating — v3 adds sharpness and overlap to the formula.
4. Scalar per-pixel blending loops caused ~300-700ms overhead — v3 mandates OpenCV mat operations.

### Compared to v2 plans (`claude-plan-stitching-v2`)

1. Three-stream effective framing alignment is elevated to a hard contract.
2. Explicit crop/resize contract is fixed: capture `1600x1200 -> 800x600`; analysis target `1600x1200` with strict fallback policy.
3. 40% width/height crop policy is mandatory and documented for both capture and analysis.
4. CameraX-first transform ownership is explicit; no contradictory transform duplication allowed.
5. First committed frame after Start must pass full gating (tightened behavior).
6. ECC full-resolution refinement moved into MVP (not deferred).
7. ByteBuffer minimal-copy and latency-focused constraints are explicit from capture-delay investigation findings.
8. Quality formula and overlap-zero behavior are strict and testable.
9. UI contract now explicitly mandates subtle border pulse, FRAMES correctness, velocity/quality bars, and InfoBar confidence display.
10. MVP explicitly excludes image corrections.
11. ImageCapture removed from stitch path; stitching uses ImageAnalysis frames inline (latency: ~300ms → ~98ms).

## Core Design Decisions

### Stream Alignment — Two-Stream / ImageAnalysis-Only

Preview and ImageAnalysis represent the same effective scene region (same center crop and aspect framing). ImageCapture is bound only for the debug capture button and plays no role in stitching.

**CameraX behavior**: When use cases are bound together via `bindToLifecycle()`, CameraX negotiates a shared sensor region. Each use case may receive a differently-sized output depending on its resolution strategy. **CameraX does NOT guarantee identical crop rects** — different aspect ratios or resolutions may cause different sensor crop regions.

**Our strategy**: Software center-crop. Apply the same **proportional 40% width × 40% height** center crop to the analysis output. The analysis frame serves both navigation (Y channel only) and stitch commit (YUV→BGR, same crop region). Preview is display-only and does not need pixel-level alignment.

### Coordinate System — Canvas Only

Everything is in **canvas pixels** (800×600 frame scale). No world-coordinate layer.

- First committed frame defines origin `(0, 0)`.
- Before the first Start press, no committed frame exists. Tracking may run for motion/quality signals, but pose has no spatial meaning until first commit.
- Canvas tiles, bounding box, overlap, distance — all in canvas pixel coordinates.

### No Image Corrections in MVP

No vignetting correction, lens distortion correction, or other image corrections. These are deferred to the future plan.

### Frame Processing Pipeline

The analysis frame serves as the single source for both navigation (Y channel) and stitch commit (YUV→BGR, same crop region).

| Stage | Analysis (ImageAnalysis) |
|-------|-------------------------|
| Sensor raw | ~1600×1200 requested (actual varies by device) |
| Center crop 40% | 40%W × 40%H of actual |
| Nav frame | ~640×480 Y-only → phase correlation |
| Stitch frame | ~640×480 YUV→BGR → resize to 800×600 |
| Use | Nav: motion tracking; Commit: composited onto tiled canvas |

The crop ratio is **40% of the native frame** for the analysis stream.

**Crop dimensions computed at init** from actual CameraX-returned resolutions:

```
analysisCropW = round_even(analysisW × 0.40) // e.g. 1600 × 0.40 = 640
analysisCropH = round_even(analysisH × 0.40) // e.g. 1200 × 0.40 = 480
```

The final canvas frame is always resized to **800×600** (4:3). The nav frame is used at its post-crop size (varies by device, typically ~640×480).

**Navigation scale**: `navScale = CANVAS_FRAME_W / navFrameW = 800.0 / analysisCropW`.

### Analysis Resolution Strategy

Request **1600×1200** from CameraX via `startCamera(analysisWidth: 1600, analysisHeight: 1200)`. CameraX uses `FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER` — may return 1920×1440, 1600×1200, 1280×960, etc.

The plan adapts to whatever CameraX returns by computing crop dimensions from the actual resolution. The 40% crop ratio guarantees matching FoV regardless of the exact analysis resolution.

**Fallback guarantee**: If a device returns an unusual resolution, the only requirement is that it's 4:3 (or close). If the aspect ratio differs significantly, the crop dimensions are computed to produce 4:3 output:

```
cropH = round_even(analysisW × 0.40 × 3 / 4)  // force 4:3 from crop dimensions
```

### Minimizing Copies — ByteBuffer Zero-Copy

1. **Kotlin → JNI**: Pass `ImageProxy.planes[].buffer` (direct ByteBuffer) to JNI. Use `GetDirectBufferAddress()` for zero-copy pointer access. **No ByteArray allocations.**
2. **Crop before conversion**: Read only center 40% rows from Y/U/V planes. Skip outer rows entirely.
3. **YUV→BGR on cropped region only**: Convert the crop, not the full sensor frame.
4. **Single downscale**: Resize cropped BGR → 800×600. One resize operation.

### Quality Formula

$$quality = \sqrt[3]{lastConfidence \times sharpness \times overlapRatio}$$

- If `overlapRatio == 0`, quality is forced to `0.0`.
- Quality can never be above zero until the first frame is committed (no overlap possible without canvas data).

### Capture Gating

Checks (all must pass, in order):

1. **Tracking** state is TRACKING (not LOST or INIT)
2. **Capture** not already in progress
3. **Cooldown** period elapsed since last capture
4. **Velocity** below threshold for stability duration
5. **Sharpness** above threshold
6. **Distance** from last committed frame ≥ `MIN_CAPTURE_DISTANCE` (bypassed for first frame)
7. **Overlap** < 0.99 (reject redundant re-scans of fully covered area)
8. **First frame special case**: `_framesCaptured == 0` → bypass distance check (6) and overlap check (7), but still require checks 1–5.

Every gating decision is logged with reason code and all metrics.

**Reason codes**: `"ok"`, `"tracking_lost"`, `"in_progress"`, `"cooldown"`, `"velocity_too_high"`, `"sharpness_too_low"`, `"distance_too_small"`, `"distance_too_large"`, `"overlap_too_high"`

### Start Behavior

- Before first Start press: no committed frames, no canvas data, pose accumulates but has no spatial meaning.
- Tracking runs (computing motion, velocity, sharpness) — values are informational only, no captures fire.
- First frame commits only after Start is pressed.
- The first frame still passes capture gating (sharpness + velocity stability) — no special bypass for quality checks.

---

## Phase 1 — JNI Zero-Copy + Build Scaffold *(Kotlin + JNI + C++)*

**Goal**: Eliminate ByteArray copies. Build crop utilities. Wire ByteBuffer path end-to-end. Verify data reaches C++ correctly.

### Step 1.1 — C++ project scaffolding

Create `native/stitcher/` with:

**`CMakeLists.txt`**:

```cmake
cmake_minimum_required(VERSION 3.22)
project(eva_stitcher)

set(CMAKE_CXX_STANDARD 17)

find_package(OpenCV REQUIRED COMPONENTS core imgproc)

add_library(eva_stitcher SHARED
    jni_bridge.cpp
    engine.cpp
    navigation.cpp
    canvas.cpp
    registration.cpp
)

target_include_directories(eva_stitcher PRIVATE
    ${CMAKE_SOURCE_DIR}
    ${OpenCV_INCLUDE_DIRS}
)

target_link_libraries(eva_stitcher
    ${OpenCV_LIBS}
    log    # Android logging
)
```

**Gradle integration** — add to `android/app/build.gradle.kts`:

```kotlin
android {
    externalNativeBuild {
        cmake {
            path = file("../../native/stitcher/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    defaultConfig {
        externalNativeBuild {
            cmake {
                arguments += "-DOpenCV_DIR=${rootProject.projectDir}/../android/opencv/sdk/native/jni"
            }
        }
    }
}
```

**`types.h`** — constants, enums, core structs:

```cpp
constexpr float CROP_RATIO = 0.40f;
constexpr int CANVAS_FRAME_W = 800;
constexpr int CANVAS_FRAME_H = 600;
constexpr int TILE_SIZE = 512;
constexpr int MAX_CACHED_TILES = 100;
constexpr int FEATHER_WIDTH = 80;          // 10% of 800px
constexpr int NAV_STATE_SIZE = 19;

constexpr int MIN_CAPTURE_DISTANCE = 160;  // 20% of canvas frame width
constexpr int64_t COOLDOWN_NS = 200'000'000;       // 200ms
constexpr int64_t STABILITY_DURATION_NS = 150'000'000; // 150ms
constexpr float VELOCITY_THRESHOLD = 150.0f;       // canvas px/sec
constexpr float SHARPNESS_THRESHOLD = 0.15f;
constexpr float SHARPNESS_NORMALIZER = 1000.0f;
constexpr float MIN_CONFIDENCE = 0.08f;
constexpr float DEADBAND_THRESHOLD = 5.0f;         // canvas px/sec
constexpr float ECC_MIN_SCORE = 0.70f;
constexpr float OVERLAP_REJECT_THRESHOLD = 0.99f;  // reject redundant re-scans
constexpr float VELOCITY_EMA_ALPHA = 0.3f;
constexpr int CANVAS_PREVIEW_MAX_DIM = 1024;

enum class TrackingState : int { INIT = 0, TRACKING = 1, UNCERTAIN = 2, LOST = 3 };

struct Pose { float x = 0, y = 0; };

struct NavigationState {
    TrackingState trackingState = TrackingState::INIT;
    float poseX = 0, poseY = 0;
    float velocityX = 0, velocityY = 0;
    float speed = 0;
    float lastConfidence = 0;
    float overlapRatio = 0;
    int frameCount = 0;
    int framesCaptured = 0;
    bool captureReady = false;
    float canvasMinX = 0, canvasMinY = 0, canvasMaxX = 0, canvasMaxY = 0;
    float sharpness = 0;
    float analysisTimeMs = 0;
    float compositeTimeMs = 0;
    float quality = 0;

    // Pack into float[19] for JNI
    void toFloatArray(float* out) const;
};
```

**`jni_bridge.cpp`** — JNI entry points with `jobject` ByteBuffer params.

**`engine.h/cpp`** — top-level engine class, owns Navigation + Canvas.

### Step 1.2 — JNI signatures: ByteBuffer

`jni_bridge.cpp`:

- `processAnalysisFrame(jobject yBuf, jobject uBuf, jobject vBuf, jint w, jint h, jint yStride, jint uvStride, jint uvPixelStride, jint rotation, jlong timestampNs)` → `void`
- `getNavigationState()` → `jfloatArray`
- `initEngine(jint analysisW, jint analysisH)` → `void`
- `getCanvasPreview(jint maxDim)` → `jbyteArray` (JPEG)
- `resetEngine()` → `void`
- `startScanning()` → `void`
- `stopScanning()` → `void`

Note: `processAnalysisFrame` now accepts Y+U+V planes so the stitch commit path (YUV→BGR) can run inline when gating passes. Returns `void` — no Kotlin-side capture trigger needed.

### Step 1.3 — Crop helpers in `engine.cpp`

- `cropY(yPtr, sensorW, sensorH, yStride, cropW, cropH)` → `cv::Mat` (CV_8UC1). Copies only center rows. Used for nav frame every analysis frame.
- `cropYuvToBgr(yPtr, uPtr, vPtr, sensorW, sensorH, yStride, uvStride, uvPixelStride, cropW, cropH)` → `cv::Mat` (CV_8UC3). Crops center then converts. Used for stitch commit (inline in `processAnalysisFrame` when gating passes).

Both compute offset: `offsetX = (sensorW - cropW) / 2`, `offsetY = (sensorH - cropH) / 2`.

### Step 1.4 — Update NativeStitcher.kt

Replace `processFrame(ByteArray...)` with ByteBuffer-based signatures:

- `processAnalysisFrame(yBuf: ByteBuffer, uBuf: ByteBuffer, vBuf: ByteBuffer, w: Int, h: Int, yStride: Int, uvStride: Int, uvPixelStride: Int, rotation: Int, timestampNs: Long)`
- `getNavigationState(): FloatArray`
- `initEngine(analysisW: Int, analysisH: Int)`
- `getCanvasPreview(maxDim: Int): ByteArray?`
- `resetEngine()`
- `startScanning()` / `stopScanning()`

All declared as `external fun` with `@JvmStatic` in companion object.

### Step 1.5 — Update MainActivity.kt

**FrameProcessor**: Pass all three YUV plane ByteBuffers. The C++ side uses Y-only for nav every frame, and Y+U+V for stitch commit when gating passes:

```kotlin
EvaCameraPlugin.setFrameProcessor(object : FrameProcessor {
    override fun processFrame(imageProxy: ImageProxy, captureResult: TotalCaptureResult?): Float {
        NativeStitcher.processAnalysisFrame(
            imageProxy.planes[0].buffer,
            imageProxy.planes[1].buffer,
            imageProxy.planes[2].buffer,
            imageProxy.width, imageProxy.height,
            imageProxy.planes[0].rowStride,
            imageProxy.planes[1].rowStride,
            imageProxy.planes[1].pixelStride,
            imageProxy.imageInfo.rotationDegrees,
            imageProxy.imageInfo.timestamp
        )
        return 0f
    }
})
```

**MethodChannel handlers** — add to `when (call.method)` block:

- `"initEngine"` → extract analysisW/H from args → `NativeStitcher.initEngine()`
- `"getNavigationState"` → `result.success(NativeStitcher.getNavigationState())`
- `"getCanvasPreview"` → `result.success(NativeStitcher.getCanvasPreview(call.argument("maxDim") ?: 1024))`
- `"resetEngine"` → `NativeStitcher.resetEngine()` → `result.success(null)`
- `"startScanning"` → `NativeStitcher.startScanning()` → `result.success(null)`
- `"stopScanning"` → `NativeStitcher.stopScanning()` → `result.success(null)`

**InitEngine call**: After camera starts, call `initEngine` with actual capture/analysis resolutions (from `CameraStartInfo` returned by `startCamera()`).

### Step 1.6 — Request 1600×1200 analysis resolution

In `lib/main.dart`, change `CameraControl.startCamera()` to:

```dart
final info = await CameraControl.startCamera(analysisWidth: 1600, analysisHeight: 1200);
```

After receiving `info`, call `StitchControl.initEngine()` with actual analysis resolution:

```dart
await StitchControl.initEngine(
    analysisW: info.analysisWidth, analysisH: info.analysisHeight,
);
```

**Resolution verification**: Log the actual resolutions CameraX returns. If analysis resolution differs from 1600×1200, the system adapts gracefully because crop and scale are computed from actual values.

### Verification

- Logcat: "initEngine: capture=%dx%d analysis=%dx%d crop=%.0f%%" — shows actual resolutions and computed crop dimensions.
- Logcat: "processAnalysisFrame: sensor=%dx%d crop=%dx%d navFrame=%dx%d" on first frame.
- fallback path includes reason + closeness score when used,
- if selected resolution differs from requested, downstream crop dimensions and analysis-to-canvas scale bridge constants are recomputed from actual resolution (not hardcoded to 1600x1200 assumptions),
- `STREAM_ALIGN` snapshot reflects actual selected analysis size (not target size).
- **No** `NativeAlloc concurrent mark compact GC` entries from camera frame copies.
- `processAnalysisFrame` called at ~30fps (verify with frame counter log every 100 frames).
- Native library loads without linker errors (OpenCV symbols resolve).

---

## Phase 2 — Navigation Pipeline *(C++ only)*

**Goal**: Frame-to-frame phase correlation, velocity estimation, capture gating — all in canvas coordinates.

### Step 2.1 — `navigation.h/cpp`

Class `Navigation`:

- `init(canvasFrameW, canvasFrameH, navFrameW, navFrameH)` — compute `_scale = canvasFrameW / navFrameW`.
- `processFrame(navFrame: cv::Mat, rotation: int, timestampNs: int64_t)` → `NavigationResult`
- Internal state: `_prevFrame`, `_pose`, `_lastCapturePose`, `_velocity`, `_trackingState`, `_frameCount`, `_framesCaptured`, `_lastConfidence`, `_sharpness`, `_scanningActive`

### Step 2.2 — Phase correlation (frame-to-frame)

- Use `cv::phaseCorrelate(prevFrame, currFrame, hanningWindow, &confidence)`.
- Hanning window pre-computed once at init for nav frame size.
- Returns `(dx, dy)` in nav-pixel space, multiply by `_scale` → canvas pixels.

### Step 2.3 — Velocity estimation

- `speed = sqrt(vx² + vy²)` in canvas px/sec.
- EMA filter α = `VELOCITY_EMA_ALPHA` (0.3).
- Deadband: if `speed < DEADBAND_THRESHOLD` (5.0), snap to zero.
- Velocity is always computed (even before scanning starts) for UI feedback.

### Step 2.4 — Sharpness computation

- Laplacian variance on the nav frame: `cv::Laplacian(frame, laplacian, CV_16S)`.
- `sharpness = clamp(variance / SHARPNESS_NORMALIZER, 0.0, 1.0)`.
- Computed every frame.

### Step 2.5 — Tracking state machine

```
INITIALIZING → TRACKING  (first successful correlation with confidence > MIN_CONFIDENCE)
TRACKING → UNCERTAIN     (1 low-confidence frame)
UNCERTAIN → TRACKING     (next good frame)
UNCERTAIN → LOST         (5+ consecutive low-confidence frames)
LOST → TRACKING          (good frame with plausible displacement)
```

### Step 2.6 — Capture gating

Gating logic runs every frame when `_scanningActive == true`:

```cpp
struct GatingResult {
    bool ready;
    const char* reason;  // "ok", "tracking_lost", "in_progress", "cooldown",
                         // "velocity_too_high", "sharpness_too_low",
                         // "distance_too_small", "distance_too_large",
                         // "overlap_too_high"
};
```

Checks (in order):

1. `_trackingState == TRACKING` → else reason `"tracking_lost"`
2. `!_captureInProgress` → else reason `"in_progress"`
3. `timeSinceLastCapture >= COOLDOWN_NS` → else reason `"cooldown"`
4. `speed == 0 for >= STABILITY_DURATION_NS` → else reason `"velocity_too_high"`
5. `sharpness >= SHARPNESS_THRESHOLD` → else reason `"sharpness_too_low"`
6. If `_framesCaptured > 0`: `dist >= MIN_CAPTURE_DISTANCE` → else reason `"distance_too_small"`
7. If `_framesCaptured > 0`: `overlapRatio < OVERLAP_REJECT_THRESHOLD` → else reason `"overlap_too_high"`
8. First frame (`_framesCaptured == 0`): bypass checks 6 and 7. Still require checks 1–5.

**First-frame specifics**: When `_framesCaptured == 0`, there is no reference frame for distance or overlap. Canvas bounds are uninitialized (empty). No cooldown applies to first frame. First capture fires as soon as sharpness and velocity stability are met after Start is pressed.

### Step 2.7 — Detailed gating logs

Every gating decision logged (throttled to every 10th frame when blocked, every decision when triggering):

```
EvaNav: captureGated TRIGGER quality=0.72 conf=0.85 sharp=0.91 overlap=0.78 speed=0 dist=172/160 frames=5 elapsedMs=2.1
EvaNav: captureGated BLOCKED reason=velocity_too_high quality=0.00 conf=0.82 sharp=0.89 overlap=0.65 speed=325 dist=45/160 frames=5
EvaNav: captureGated BLOCKED reason=distance_too_small conf=0.80 sharp=0.88 overlap=0.92 speed=0 dist=45/160 frames=5
```

### Step 2.8 — NavigationState packing

State struct packed as `float[19]` for JNI:

| Index | Field | Unit |
|-------|-------|------|
| 0 | trackingState | enum (0=INIT, 1=TRACKING, 2=UNCERTAIN, 3=LOST) |
| 1 | poseX | canvas px |
| 2 | poseY | canvas px |
| 3 | velocityX | canvas px/sec |
| 4 | velocityY | canvas px/sec |
| 5 | speed | canvas px/sec |
| 6 | lastConfidence | 0–1 |
| 7 | overlapRatio | 0–1 |
| 8 | frameCount | int |
| 9 | framesCaptured | int |
| 10 | captureReady | bool (1.0/0.0) |
| 11 | canvasMinX | canvas px |
| 12 | canvasMinY | canvas px |
| 13 | canvasMaxX | canvas px |
| 14 | canvasMaxY | canvas px |
| 15 | sharpness | 0–1 |
| 16 | analysisTimeMs | ms |
| 17 | compositeTimeMs | ms |
| 18 | quality | 0–1 |

### Step 2.9 — Wire `processAnalysisFrame` in engine

`Engine::processAnalysisFrame()`:

1. `GetDirectBufferAddress(yBuf)` → `uint8_t* yPtr`
2. Apply rotation if needed (from `imageInfo.rotationDegrees`)
3. `cropY()` → center crop of analysis sensor → nav frame (~640×480)
4. Pass to `_nav.processFrame()` (motion + gating)
5. If `_nav.captureReady && _scanningActive`:
   a. `GetDirectBufferAddress()` on U and V ByteBuffers → `uint8_t* uPtr, vPtr`
   b. `cropYuvToBgr()` → center crop of analysis sensor → BGR mat (~640×480)
   c. `cv::resize()` → 800×600 canvas frame
   d. Read pose from `_nav.getCurrentPose()` (under `_stateMutex`)
   e. Call `_canvas.compositeFrame(frame800x600, pose)` (includes ECC)
   f. Increment `_nav._framesCaptured`, set `_captureInProgress = false`
   g. Log: `"processAnalysisFrame commit: cropMs=%d convertMs=%d resizeMs=%d compositeMs=%d totalMs=%d"`
6. Return `void`.

**Stitch commit contract**: The YUV→BGR crop, resize, ECC, and compositing all happen inline within `processAnalysisFrame`. No Kotlin-side capture trigger needed. Both U and V planes were passed from Kotlin along with Y, so all data is available. Commit frames are rare (~1 per stable position) so the extra per-commit cost does not affect steady-state ~30fps analysis throughput.

### Verification

- Logcat: `"EvaNav: frame=%d conf=%.3f speed=%.1f pose=(%.1f,%.1f) tracking=%d"` every 30th frame.
- Logcat: gating logs show reason codes cycling through `velocity_too_high` → `distance_too_small` → `TRIGGER`.
- Before Start pressed: no TRIGGER logs, only BLOCKED (no captures fire).
- After Start: first TRIGGER fires within seconds once device is stable and sharp.
- Pose values grow as device moves (magnitude ~hundreds of canvas px).

---

## Phase 3 — Canvas + First Frame *(C++)*

**Goal**: Tiled canvas with compositing. First frame commits at origin.

### Step 3.1 — `canvas.h/cpp`

Class `Canvas`:

- `init(canvasFrameW, canvasFrameH)` — store dimensions, pre-compute weight map, set bounds to empty state.
- `compositeFrame(frame: cv::Mat, pose: Pose)` — blend frame onto tiles at given position.
- `renderPreview(maxDim: int)` → `std::vector<uint8_t>` (JPEG bytes).
- `reset()` — clear all tiles, reset bounds to empty.
- `getBounds()` → `(minX, minY, maxX, maxY)` in canvas px.
- `getOverlapRatio(pose: Pose)` → `float` (0–1). Counts pixels with alpha > 0 in frame footprint.

**Canvas bounds initialization**: Before first frame, bounds are empty (indicated by `minX > maxX`). `getOverlapRatio()` returns 0.0 when bounds are empty. After first frame is composited at (0,0), bounds become `(0, 0, 800, 600)`.

### Step 3.2 — Tile data structure

```cpp
struct Tile {
    cv::Mat pixels;  // CV_8UC4 (BGRA), 512×512, alpha=0 for unwritten pixels
    bool dirty = false;
    int64_t lastAccess = 0;
};
```

- `std::unordered_map<TileKey, std::unique_ptr<Tile>>` with `TileKey = {col, row}`.
- LRU eviction at `MAX_CACHED_TILES` (100) tiles. Dirty tiles flushed to PNG before eviction.
- Negative tile indices valid.
- **LRU eviction runs only under exclusive `_canvasMutex` lock** (during `compositeFrame()`). Dirty tile PNG flush is synchronous and blocks until complete. This prevents data races with preview rendering (which uses shared lock).

### Step 3.3 — Cached weight map (linear feathering)

Pre-compute once at init (800×600, CV_32FC1):

1. Build horizontal ramp: `min(x, W-1-x)`.
2. Build vertical ramp: `min(y, H-1-y)`.
3. `dist = min(hRamp, vRamp)`.
4. `weight = clamp(dist / FEATHER_WIDTH, 0, 1)`.

Use OpenCV mat operations (no scalar loops).

### Step 3.4 — Compositing

For each pixel in the frame at `(pose.x + fx, pose.y + fy)`:

- Map to tile `(col, row)` and local `(lx, ly)`.
- If tile pixel alpha == 0 → direct write, set alpha = 255.
- If tile pixel has content (alpha > 0) → `blended = tile * (1 - w) + frame * w`, where `w` is from cached weight map.
- Use OpenCV mat arithmetic on tile subregions (vectorized, not scalar loops).

### Step 3.5 — First frame handling

First frame: `pose = (0, 0)`. Write directly to tiles. No registration needed. No ECC. With 800×600 frame, spans tiles covering (0,0) to (800,600) → tiles (0,0), (1,0), (0,1), (1,1).

After first frame composites: canvas bounds = `(0, 0, 800, 600)`, `framesCaptured = 1`. Subsequent frames compute overlap against these bounds + tile alpha data.

### Step 3.6 — Canvas preview

`renderPreview(maxDim)`:

1. Compute bounding box of all cached tiles.
2. Assemble visible tiles into one cv::Mat.
3. Resize to fit within maxDim × maxDim (preserving aspect). Default `maxDim = CANVAS_PREVIEW_MAX_DIM` (1024).
4. `cv::imencode(".jpg", ...)` → JPEG bytes.

### Step 3.7 — Overlap computation

Overlap is the ratio of already-filled canvas pixels within the incoming frame footprint:

- Frame footprint: Rect at predicted pose, 800×600.
- Iterate canvas tiles within this rect, count pixels with `alpha > 0`.
- `overlapRatio = coveredPixels / (800 × 600)`.
- Before first committed frame (bounds empty): `overlapRatio = 0.0`.
- Any pixel with alpha > 0 counts as covered (even partially blended pixels with low weight).

### Step 3.8 — Timing log

```
EvaCanvas: compositeFrame %dx%d tiles=%d blendMs=%d totalMs=%d
```

### Verification

- After first Start + stability: first capture fires, tiles created.
- `getCanvasPreview(1024)` returns non-empty JPEG.
- Logcat: `compositeFrame` timing < 100ms.
- CanvasView in Flutter shows actual stitched image (not placeholder asset).
- Negative tile indices work correctly when moving up-left from origin.
- LRU eviction doesn't lose data (compose 100+ frames, check preview completeness).

---

## Phase 4 — Stitch Commit Wiring *(Kotlin + C++ + Dart)*

**Goal**: Complete the inline stitch commit path (inside `processAnalysisFrame`) and connect state polling to the Dart UI. End-to-end flow from gating pass to canvas update.

### Step 4.1 — Stitch commit mechanism

**Approach**: When gating passes in `Engine::processAnalysisFrame()`, the stitch commit happens inline in the same call — no Kotlin-side capture trigger, no second ImageCapture use case.

Flow:

1. C++ `Engine::processAnalysisFrame()` runs navigation + gating.
2. If gating passes → set `_captureInProgress = true`.
3. `cropYuvToBgr()` on the analysis frame’s U/V planes (already available in same call).
4. `cv::resize()` → 800×600 canvas frame.
5. Read pose from `_nav.getCurrentPose()`.
6. `_canvas.compositeFrame()` (includes ECC refinement).
7. Increment `_nav._framesCaptured`, reset `_captureInProgress = false`.
8. Return `void` to Kotlin — no trigger needed.

**Guard against duplicate captures**: `_captureInProgress` is checked by gating (check 2). Set to `true` before entering commit path. Reset to `false` after compositing completes. This prevents re-entrancy (which cannot happen on a single-threaded analysis executor, but is documented for clarity).

### Step 4.2 — `Engine::processAnalysisFrame()` commit path

When commit path is active (gating passed):

1. `GetDirectBufferAddress()` on U and V ByteBuffers.
2. `cropYuvToBgr()` → center crop of analysis sensor → BGR mat (~640×480).
3. Apply rotation if needed.
4. `cv::resize()` → 800×600 (canvas frame).
5. Read pose from `_nav.getCurrentPose()` (under `_stateMutex`).
6. Call `_canvas.compositeFrame(frame800x600, pose)` — ECC + blend.
7. Increment `_nav._framesCaptured`.
8. Reset `_captureInProgress = false`.
9. Log timing: `processAnalysisFrame commit: cropMs=%d convertMs=%d resizeMs=%d eccMs=%d compositeMs=%d totalMs=%d`.

### Step 4.3 — Dart polling for NavigationState

In `lib/main.dart`:

- Add `Timer.periodic(Duration(milliseconds: 50))` → call `StitchControl.getNavigationState()` via MethodChannel.
- Parse float array into Dart `NavigationState` object.
- Update UI: stitchedCount, quality, velocity, tracking state.
- Timer starts when camera starts. Timer stops when camera stops.

### Step 4.4 — Dart `stitch_state.dart`

Create `lib/stitcher/stitch_state.dart`:

**`NavigationState`** data class with all 19 fields:

```dart
class NavigationState {
    final int trackingState;    // 0=INIT, 1=TRACKING, 2=UNCERTAIN, 3=LOST
    final double poseX, poseY;
    final double velocityX, velocityY, speed;
    final double lastConfidence;
    final double overlapRatio;
    final int frameCount, framesCaptured;
    final bool captureReady;
    final double canvasMinX, canvasMinY, canvasMaxX, canvasMaxY;
    final double sharpness;
    final double analysisTimeMs, compositeTimeMs;
    final double quality;

    factory NavigationState.fromFloatList(List<double> data) {
        assert(data.length == 19);
        return NavigationState(
            trackingState: data[0].toInt(),
            poseX: data[1], poseY: data[2],
            velocityX: data[3], velocityY: data[4], speed: data[5],
            lastConfidence: data[6],
            overlapRatio: data[7],
            frameCount: data[8].toInt(), framesCaptured: data[9].toInt(),
            captureReady: data[10] > 0.5,
            canvasMinX: data[11], canvasMinY: data[12],
            canvasMaxX: data[13], canvasMaxY: data[14],
            sharpness: data[15],
            analysisTimeMs: data[16], compositeTimeMs: data[17],
            quality: data[18],
        );
    }
}
```

**`StitchControl`** class wrapping MethodChannel calls:

- `initEngine(analysisW, analysisH)`
- `getNavigationState()` → `NavigationState?`
- `getCanvasPreview(maxDim)` → `Uint8List?`
- `resetEngine()`
- `startScanning()` / `stopScanning()`

MethodChannel name: `"com.example.eva/stitch"` (new channel, separate from camera control).

### Step 4.5 — Wire CanvasView to live data

Update `CanvasView`:

- Accept `previewBytes: Uint8List?` parameter.
- Replace placeholder `Image.asset` with `Image.memory(previewBytes!)` when available.
- Parent calls `_fetchCanvasPreview()` when `framesCaptured` changes (detect via `_navState.framesCaptured != _prevFramesCaptured`).

### Step 4.6 — Start/Stop scanning

- `_toggleScan()` calls `StitchControl.startScanning()` / `stopScanning()`.
- C++ `startScanning()` sets `_scanningActive = true`, allows capture gating triggers.
- C++ `stopScanning()` sets `_scanningActive = false`, suppresses all triggers.
- Before Start: navigation runs (velocity/sharpness computed), but no captures fire.
- After Start: captures fire when gating passes.

### Verification

- End-to-end: Start scan → device stable → capture fires → canvas updates.
- `STITCHED` count in info bar increments.
- Canvas preview shows new frame added.
- Logcat: complete pipeline trace from `processAnalysisFrame TRIGGER` → `commit cropMs=... eccMs=... compositeMs=... totalMs=XXX`.
- Target commit latency: < 130ms (inline, no separate CameraX round-trip).
- First capture fires within 3 seconds of Start when device is stable.
- No duplicate rapid captures (check `_captureInProgress` guard in logs).

---

## Phase 5 — ECC Refinement *(C++)*

**Goal**: Sub-pixel registration refinement using ECC on the 800×600 canvas frame.

### Step 5.1 — `registration.h/cpp`

Module containing registration utilities:

- `phaseCorrelateFrames(prev, curr, hanning)` → `(dx, dy, confidence)` — wrapper around `cv::phaseCorrelate`.
- `refineWithECC(canvasPatch, frame, initialPose)` → `(refinedPose, eccScore, converged)`.

### Step 5.2 — ECC in compositeFrame

After Phase 3's `finalPose = predictedPose`, add ECC refinement:

1. Extract canvas patch at predicted pose using tile data (800×600 region).
2. Check patch validity: if > 50% of pixels have alpha == 0, skip ECC (sparse canvas).
3. Convert both to grayscale.
4. Initialize `warpMatrix = cv::Mat::eye(2, 3, CV_32F)`.
5. Try/catch `cv::findTransformECC`:

   ```cpp
   try {
       double eccScore = cv::findTransformECC(
           canvasGray, frameGray, warpMatrix,
           cv::MOTION_TRANSLATION,
           cv::TermCriteria(cv::TermCriteria::COUNT + cv::TermCriteria::EPS, 30, 0.001)
       );
       if (eccScore > ECC_MIN_SCORE) {
           // Apply sub-pixel correction from warpMatrix
           finalPose.x += warpMatrix.at<float>(0, 2);
           finalPose.y += warpMatrix.at<float>(1, 2);
           lastConfidence = eccScore;
       } else {
           // ECC converged but score too low — use predicted pose, keep phaseCorrelate confidence
           LOGI("ECC low score %.4f; using phase correlation", eccScore);
       }
   } catch (const cv::Exception& e) {
       // ECC failed to converge — use predicted pose, keep phaseCorrelate confidence
       LOGI("ECC failed: %s", e.what());
   }
   ```

6. Log: `"ECC: converged=%d score=%.4f correction=(%.2f,%.2f) costMs=%d"`.

**Confidence rule**: `lastConfidence` = ECC score when ECC converges above threshold, else remains as phaseCorrelate confidence from navigation. This feeds into the quality formula.

### Step 5.3 — Handle first frame

First frame: no ECC (no canvas content to compare against). Just use `(0,0)`.

### Step 5.4 — Handle sparse canvas

When extracting canvas patch, check alpha channel:

- "Empty" pixel = `alpha == 0`.
- If > 50% of 800×600 patch has alpha == 0, skip ECC and use predicted pose unchanged.
- Log: `"ECC skipped: %.1f%% of patch empty"`.

### Verification

- Logcat: `"ECC: converged=1 score=0.95 correction=(0.32,-0.18) costMs=25"` on successive captures.
- ECC corrections typically 0.1–2.0 pixels.
- Canvas seams should be visibly smoother than without ECC.
- ECC cost < 50ms on 800×600.
- ECC gracefully handles sparse canvas (skip + log, no crash).

---

## Phase 6 — Quality Metric + Enhanced Gating *(C++)*

**Goal**: Complete quality metric, overlap computation, enhanced gating with all reason codes.

### Step 6.1 — Quality formula

```cpp
float quality = (overlapRatio > 0.0f)
    ? std::cbrt(lastConfidence * sharpness * overlapRatio)
    : 0.0f;
```

Quality is zero when:

- No canvas data exists (before first commit).
- Overlap with existing canvas is zero (moved to unscanned area).
- Confidence or sharpness is zero.

### Step 6.2 — Enhanced gating with all checks

Full gating check order (as specified in Core Design: Capture Gating):

```cpp
if (trackingState != TRACKING) return {"tracking_lost"};
if (captureInProgress) return {"in_progress"};
if (timeSinceLastCapture < COOLDOWN_NS) return {"cooldown"};
if (!velocityStable()) return {"velocity_too_high"};
if (sharpness < SHARPNESS_THRESHOLD) return {"sharpness_too_low"};
if (framesCaptured > 0) {
    if (dist < MIN_CAPTURE_DISTANCE) return {"distance_too_small"};
    if (overlapRatio > OVERLAP_REJECT_THRESHOLD) return {"overlap_too_high"};
}
return {"ok"};  // all checks pass
```

All gating logs include: `quality`, `conf`, `sharp`, `overlap`, `speed`, `dist`, `frames`, `reason`.

### Verification

- Logcat: quality values 0.0 before first frame, > 0 after.
- Quality decreases when moving to edges (less overlap).
- Quality = 0 when moved completely off canvas.
- Gating logs show sharpness rejection when out of focus.
- `overlap_too_high` reason fires when re-scanning same area.

---

## Phase 7 — UI Integration *(Dart)*

**Goal**: Velocity bar, quality bar, info bar updates, capture flash, lastConfidence display.

### Step 7.1 — Rename BottomInfoBar to InfoBar

Rename `lib/widgets/bottom_info_bar.dart` → `lib/widgets/info_bar.dart`, class `BottomInfoBar` → `InfoBar`. Remove placeholder `COVERAGE` chip and `totalTarget`/`coveragePct` fields. Add `lastConfidence` field. Update `main.dart` references.

### Step 7.2 — Velocity bar

Vertical bar next to camera preview (left side):

- Height proportional to velocity.
- Max height = 80% of cropped ImageAnalysis height (because velocity is computed from analysis frames).
- In canvas-pixel units: max displayable velocity = `0.80 × analysisCropH × navScale`.
- Color gradient: green at low speed, yellow at moderate, red at high.
- Data source: `NavigationState.speed`.

### Step 7.3 — Quality bar

Horizontal bar below camera preview:

- Width proportional to quality (0–1).
- Color logic:
  - White/blank if tracking lost (quality = 0).
  - Red if quality < 0.3.
  - Yellow if quality 0.3–0.6.
  - Green if quality ≥ 0.6.
- Data source: `NavigationState.quality`.

### Step 7.4 — Capture flash (subtle)

Preview-frame border pulse on capture:

- When `framesCaptured` increments: briefly change preview border to 3px `colorScheme.primary` with glow effect.
- Duration: 300ms fade-out.
- Use `AnimatedContainer` with border width/color transition.

### Step 7.5 — Info bar updates

- `FRAMES` chip: `_info.frameCount` (from EventChannel — camera frame count).
- `STITCHED` chip: `_navState.framesCaptured` (from navigation state polling).
- `lastConfidence`: displayed as a new chip, formatted to 2 decimal places.
- Session timer: continues from existing implementation.

### Step 7.6 — State polling wiring

In `main.dart`:

- Add `NavigationState? _navState` field.
- `Timer.periodic(Duration(milliseconds: 50))`: call `StitchControl.getNavigationState()`, parse, `setState()`.
- When `_navState.framesCaptured` increases: trigger `_fetchCanvasPreview()`.

### Verification

- Visual: Velocity bar fills/empties as device moves/stops.
- Visual: Quality bar turns green when stable over scanned area, white when on new area.
- Visual: Preview border pulses on capture (no full-screen flash).
- Visual: STITCHED count increments.
- Visual: lastConfidence updates in info bar.
- FRAMES count from EventChannel continues to tick independently.

---

## Phase 8 — Integration, Polish, Timing *(All layers)*

**Goal**: End-to-end verification, parameter tuning, edge cases.

### Step 8.1 — End-to-end timing log

In `Engine::processAnalysisFrame()` commit path:

```
EvaEngine: analysisFrame commit cropMs=%d convertMs=%d resizeMs=%d eccMs=%d compositeMs=%d totalMs=%d
```

Target budget (commit frame):

| Step | Target |
|------|--------|
| ByteBuffer access (3 planes) | ~0ms |
| CropY + phaseCorrelate + gating | ~8ms |
| CropYuvToBgr (~640×480 from analysis) | ~10ms |
| Rotation | ~2ms |
| Resize ~640×480 → 800×600 | ~3ms |
| ECC | ~25ms |
| compositeFrame (blend) | ~50ms |
| **Nav-only frame** | **~8ms** |
| **Commit frame total** | **~98ms** |

### Step 8.2 — Rotation handling

CameraX `setTargetRotation(ROTATION_0)` is set for all streams. The actual sensor orientation may require 0° or 180° rotation depending on device. Use `imageProxy.imageInfo.rotationDegrees` passed through JNI. Apply rotation in C++ before cropping.

**Why native rotation**: CameraX `setTargetRotation` affects JPEG EXIF orientation but not raw pixel layout for YUV. The actual Y/U/V plane data comes out in sensor orientation. Rotation must be applied in native code.

**MVP scope**: Support 0° and 180° rotation. 90°/270° (portrait mode) is documented but not required for MVP — app is landscape-only.

### Step 8.3 — Edge cases

- First capture after Start: passes gating (sharpness + velocity), commits at (0,0), canvas bounds = (0,0,800,600).
- Tracking lost: pose freezes, UI shows warning via tracking state, captures stop.
- Tracking recovered: pose resumes, captures restart.
- Very fast movement: speed exceeds threshold, captures suppressed.
- Device stationary on featureless area: low confidence → UNCERTAIN → LOST.
- Re-scanning same area: `overlap_too_high` gating rejects redundant captures.

### Step 8.4 — Parameter tuning

| Parameter | Default | Notes |
|-----------|---------|-------|
| `FEATHER_WIDTH` | 80 | 10% of 800px. Tune 60–100. |
| `MIN_CAPTURE_DISTANCE` | 160 | 20% of 800. Try 120 for denser overlap. |
| `COOLDOWN_NS` | 200ms | |
| `STABILITY_DURATION_NS` | 150ms | May need 200ms for microscopy. |
| `VELOCITY_THRESHOLD` | 150 | canvas px/sec |
| `SHARPNESS_THRESHOLD` | 0.15 | Tune per optics. |
| `MIN_CONFIDENCE` | 0.08 | phaseCorrelate threshold |
| `DEADBAND_THRESHOLD` | 5.0 | canvas px/sec |
| `ECC_MIN_SCORE` | 0.70 | Below this, reject ECC |
| `OVERLAP_REJECT_THRESHOLD` | 0.99 | Reject fully-covered re-scans |
| `VELOCITY_EMA_ALPHA` | 0.3 | Smoothing factor |

### Step 8.5 — Debugging logs

Extensive logging throughout:

- Every 30th analysis frame: nav state summary.
- Every capture: full pipeline timing breakdown.
- Every gating decision: reason + all metrics (throttled to every 10th frame when blocked).
- Canvas state changes: tile creates, evictions, disk flushes.
- Tracking state transitions: `INIT→TRACKING`, `TRACKING→LOST`, etc.

### Step 8.6 — CHANGELOG.md

Update with all v3 changes.

### Verification

- Full scan session: multiple captures, growing canvas, no crashes.
- Total capture-to-canvas latency < 300ms in logcat.
- No GC pressure from camera copies (verify absence of `NativeAlloc concurrent mark compact GC` in logcat).
- Canvas preview shows clean multi-frame mosaic.
- `flutter analyze` clean.

---

## Key Constants Summary (types.h)

| Constant | Value | Purpose |
|----------|-------|---------|
| `CROP_RATIO` | 0.40 | 40% center crop from both streams |
| `CANVAS_FRAME_W` | 800 | Canvas frame width |
| `CANVAS_FRAME_H` | 600 | Canvas frame height |
| `TILE_SIZE` | 512 | Canvas tile size |
| `MAX_CACHED_TILES` | 100 | LRU limit (~200MB) |
| `FEATHER_WIDTH` | 80 | Blend edge taper (canvas px) |
| `NAV_STATE_SIZE` | 19 | Float array for JNI |
| `MIN_CAPTURE_DISTANCE` | 160 | 20% of canvas frame width |
| `COOLDOWN_NS` | 200000000 | 200ms capture cooldown |
| `STABILITY_DURATION_NS` | 150000000 | 150ms velocity stability |
| `VELOCITY_THRESHOLD` | 150.0 | canvas px/sec |
| `SHARPNESS_THRESHOLD` | 0.15 | Laplacian variance normalized |
| `SHARPNESS_NORMALIZER` | 1000.0 | Normalization divisor |
| `MIN_CONFIDENCE` | 0.08 | phaseCorrelate confidence |
| `DEADBAND_THRESHOLD` | 5.0 | Velocity deadband (canvas px/sec) |
| `ECC_MIN_SCORE` | 0.70 | Minimum ECC return value |
| `OVERLAP_REJECT_THRESHOLD` | 0.99 | Redundant re-scan rejection |
| `VELOCITY_EMA_ALPHA` | 0.3 | Velocity smoothing |
| `CANVAS_PREVIEW_MAX_DIM` | 1024 | Preview JPEG max dimension |

## Files Changed (by Phase)

| File | Phase | Summary |
|------|-------|---------|
| `native/stitcher/CMakeLists.txt` | 1 | Build config, links OpenCV |
| `native/stitcher/types.h` | 1 | Constants, NavigationState, enums |
| `native/stitcher/jni_bridge.cpp` | 1 | ByteBuffer JNI entry points (7 methods) |
| `native/stitcher/engine.h/cpp` | 1,2,4 | Top-level coordinator, crop helpers |
| `native/stitcher/navigation.h/cpp` | 2,6 | Motion est, velocity, gating, quality |
| `native/stitcher/registration.h/cpp` | 2,5 | Phase correlate wrapper, ECC refine |
| `native/stitcher/canvas.h/cpp` | 3,5 | Tiles, compositing, weight map, preview |
| `android/app/build.gradle.kts` | 1 | externalNativeBuild CMake wiring |
| `android/app/.../NativeStitcher.kt` | 1 | ByteBuffer JNI declarations |
| `android/app/.../MainActivity.kt` | 1,4 | ByteBuffer pass-through, MethodChannel |
| `lib/stitcher/stitch_state.dart` | 4 | NavigationState model, StitchControl |
| `lib/widgets/info_bar.dart` | 7 | Renamed from bottom_info_bar, +confidence |
| `lib/widgets/canvas_view.dart` | 4,7 | Live preview bytes |
| `lib/main.dart` | 1,4,7 | Resolution, polling, UI bars |
| `CHANGELOG.md` | 8 | Update |

## Excluded from MVP (see Future Plan)

- Vignetting correction
- Lens distortion correction
- Laplacian pyramid blending
- Exposure / white balance normalization
- Re-localization after tracking loss
- Rotation estimation
- Coverage tracking
- Export (DeepZoom, TIFF)
- Loop closure / bundle adjustment
- Rolling shutter de-skewing
- Incremental weighted average compositing
- World coordinate system

---

## Strict Acceptance Checklist

### A) Stream alignment & camera behavior

- [x] Preview + ImageAnalysis alignment requirement explicitly stated (Core Design: Stream Alignment)
- [x] Same effective crop framing across both active streams documented (40% proportional crop; ImageCapture debug-only)
- [x] CameraX-first strategy for rotation documented (Phase 8.2: why native rotation)
- [x] No contradictory transform ownership (rotation done in native code, documented why)

### B) Resolution/crop decisions

- [x] Analysis stitch path: center crop → resize to 800×600 (Phase 1, Core Design)
- [x] Analysis target resolution 1600×1200 (Core Design, Phase 1.6)
- [x] 40% width/40% height proportional crop rule documented (Core Design)
- [x] 4:3 framing consistency documented (Core Design)
- [x] Fallback resolution includes rationale + FoV/crop consistency (Core Design: Analysis Resolution Strategy)
- [x] Verification step confirms actual resolution matches or adapts (Phase 1 Verification)

### C) Coordinate model

- [x] Canvas-only coordinate system documented (Core Design)
- [x] Origin anchored at first committed frame (Core Design)
- [x] No world-coordinate dependency in MVP (Core Design)
- [x] Pre-start tracking vs post-start semantics separated (Core Design: Start Behavior)
- [x] Canvas bounds initialization before first frame specified (Phase 3.1)

### D) Performance & copy minimization

- [x] ByteBuffer JNI zero-copy direction required (Core Design, Phase 1)
- [x] ByteArray copies explicitly forbidden (Phase 1.4, 1.5)
- [x] Crop-early/minimal-copy strategy described (Core Design, Phase 1.3)
- [x] Native/OpenCV acceleration focus in phase tasks (Phase 3.3, 3.4)
- [x] Verification includes latency logging targets (Phase 8.1)
- [x] CMakeLists.txt + Gradle wiring fully specified (Phase 1.1)

### E) Stitch quality/gating/UI

- [x] Quality formula matches cubic-root expression (Core Design)
- [x] Quality=0 when overlap=0 enforced (Core Design, Phase 6.1)
- [x] Gating logs include reason codes + metrics (Phase 2.7)
- [x] All gating reasons defined including `overlap_too_high` (Phase 2.6)
- [x] FRAMES status behavior defined (Phase 7.5)
- [x] Full-screen flash replaced with preview border pulse (Phase 7.4)
- [x] ECC failure handling: try-catch + confidence fallback (Phase 5.2)

### F) MVP scope and phase quality

- [x] ECC refinement included in MVP (Phase 5)
- [x] Phases are small, testable, independently verifiable (8 phases)
- [x] Every phase has log-based and visual validation criteria
- [x] Non-MVP features in separate future plan
- [x] All constants defined with default values + tuning guidance (types.h, Phase 8.4)

### G) Architecture

- [x] Capture trigger mechanism fully specified (Phase 1.2 void return, Phase 4.1 inline commit)
- [x] NavigationState struct + Dart class with identical field mapping (Phase 2.8, 4.4)
- [x] Threading model with mutex safety (Architecture doc)
- [x] LRU eviction safety under exclusive lock (Phase 3.2)
- [x] First-frame special case fully specified (Phase 2.6, 3.5)
