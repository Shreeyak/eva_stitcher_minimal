# V2 → V3 Stitching Plan: Change Summary

**Date**: 2025-07-10

---

## Scope Changes

| Feature | v2 | v3 | Reason |
|---------|----|----|--------|
| ECC Refinement | Future Priority 1 | MVP Phase 5 | Sub-pixel registration from day one |
| Vignetting Correction | MVP Phase 6c | Future Priority 1 | Focus on correctness over image quality first |
| Gating Logging | Phase 4 | Phase 2 (Step 2.7) | Logging established before capture wiring |

---

## Technical Design Changes

### Crop Ratio

- **v2**: 1600/4160 ≈ 0.385 (hardcoded assumption about sensor size)
- **v3**: CameraX `SCALAR_CROP` parameter crops sensor from 4K (~4160×3120) to 1600×1200 at ISP level. No software center crop.
- **Why**: Hardware-level crop is zero-cost; eliminates software crop code and per-frame copy overhead

### Navigation Frame

- **v2**: Analysis ~1280×960 → crop ~492×369 → resize to fixed **400×300** → navScale = 2.0
- **v3**: Request 4K sensor → SCALAR_CROP to 1600×1200 → extract G channel → downscale to **640×480** grayscale → navScale = 800/640 = 1.25
- **Why**: Higher nav resolution; G channel provides high contrast for H&E stained slides; no wasted crop step

### Capture Trigger

- **v2**: Unspecified (atomic flags or JNI callback implied)
- **v3 original**: `processAnalysisFrame()` returns `jboolean` — Kotlin checks return value directly
- **v3 revision**: `processAnalysisFrame()` returns `void`; stitch commit is inline in C++ (no Kotlin trigger)
- **Why**: ImageCapture callback ~300ms latency even in MINIMIZE_LATENCY/ZSL mode; inline analysis commit achieves ~98ms

### Stitch Frame Source

- **v2/v3 original**: ImageCapture full-res (~4160×3120) for stitching; ImageAnalysis Y-only for navigation
- **v3 revision**: ImageAnalysis RGBA8888 for both navigation (G channel downscale to 640×480) and stitch commit (RGBA downscale to 800×600 inline); ImageCapture retained only for the debug capture button
- **Why**: Eliminates ~300ms CameraX capture callback overhead; simplifies pipeline to two active streams; `processAnalysisFrame` receives single RGBA ByteBuffer
- **Trade-off**: Stitch frame source is analysis (1600×1200 post-SCALAR_CROP); canvas frame requires downscale (2×) to 800×600

### First-Frame Gating

- **v2**: Implicit — first frame at origin when gating passes
- **v3**: Explicit — first frame (`_framesCaptured == 0`) bypasses distance/overlap checks, still requires sharpness + velocity stability + tracking
- **Why**: Prevents ambiguity about what checks apply to first capture

### Canvas Bounds Initialization

- **v2**: Implied empty state
- **v3**: Explicit: `minX > maxX` signals empty; `getOverlapRatio()` returns 0.0 when empty; after first frame → `(0, 0, 800, 600)`

---

## New in V3 (Not in V2)

1. **Stream Alignment section** — documents CameraX SCALAR_CROP strategy for cropping 4K sensor to 1600×1200 at ISP level
2. **Analysis Resolution Strategy** — request 4K sensor, SCALAR_CROP to 1600×1200, with fallback to direct 1600×1200 request
3. **All constants defined with values** — `types.h` section with constants including NAV_FRAME_W/H, tuning guidance in Phase 8.4
4. **Gating reason codes**: added `"overlap_too_high"`, `"distance_too_large"`, `"ok"`
5. **NavigationState contract**: explicit 19-field table with indices, types, and units
6. **CMakeLists.txt + Gradle integration**: full build scaffold specification
7. **ECC failure handling**: try-catch, sparse canvas skip (>50% alpha==0), confidence fallback rules
8. **LRU eviction safety**: must hold exclusive `_canvasMutex`, synchronous PNG flush
9. **Canvas preview maxDim**: default 1024 pixels
10. **Strict acceptance checklist**: 7 categories (A–G) with checkboxes
11. **ImageAnalysis-only stitch path**: `processAnalysisFrame` receives single RGBA8888 ByteBuffer; G channel extracted for nav; RGBA downscaled for stitch commit; `processCaptureFrame` and `StitchFrameProcessor` removed; `initEngine` no longer takes capture dimensions

---

## Removed from V2

1. **Vignetting gain map** (v2 Phase 6c) — deferred to future plan
2. **Fixed 400×300 nav frame resize** — replaced with adaptive nav frame size
3. **Full-res phase correlation removal** (v2 Phase 3a) — not needed since ECC is in MVP from start

---

## Phase Structure

| v2 Phase | v3 Equivalent |
|----------|--------------|
| 1: ByteBuffer + Crop | 1: JNI Zero-Copy + Build Scaffold |
| 2: Navigation rework | 2: Navigation Pipeline |
| 3: Canvas rework | 3: Canvas + First Frame |
| 4: Quality + Gating logs | 6: Quality Metric + Enhanced Gating |
| 5: Dart UI sync | 4: Capture Pipeline Wiring + 7: UI Integration |
| 6: Integration + Polish | 5: ECC Refinement + 8: Integration |

v3 has 8 phases (vs v2's 6) — more granular, each independently verifiable. ECC and Quality are separate phases rather than mixed into Integration.

## 6) What changed from older plans

### Compared to v1 plan (`claude-plan-stitching/`)

| Area | v1 (claude-plan-stitching) | v3 |
|------|----------------------------|-----|
| **Analysis resolution** | 640×480 YUV (navigation only) | Request 4K sensor, SCALAR_CROP to 1600×1200, RGBA8888 format |
| **Capture resolution** | 3120×2160 full-res for stitching | Analysis 1600×1200 RGBA → downscale 800×600 for stitch commit |
| **Crop policy** | No center crop; full-frame processing | CameraX SCALAR_CROP from 4K to 1600×1200 at ISP level |
| **Scale bridge** | capture/analysis = 3120/640 ≈ 4.875 | Computed from actual resolutions; not hardcoded |
| **Stitch registration** | Phase correlation on full-res capture (13MP FFT) | Phase correlation on 800×600 stitch frame; ECC refinement in MVP |
| **ECC** | Deferred to Phase 2 | Included in MVP Phase 5 with runtime guardrails |
| **Quality formula** | Phase correlation confidence only (peak/mean ≈ 0.15 threshold) | Cubic-root: ∛(confidence × sharpness × overlapRatio) |
| **Gating** | Velocity + distance + stability + tracking + cooldown | Adds sharpness, overlap, reason codes, structured log schema |
| **First frame** | Special case: pose=(0,0), no registration, direct write | Full gating required; overlap deadlock prevented via canvasEmpty state machine |
| **Coordinate system** | World coords at first frame center; tiles 1024×1024 | Canvas-only coords; no world layer in MVP |
| **Vignetting** | In MVP scope (radial gain model) | Deferred to future plan |
| **Blending** | Linear feathering (scalar loops) | Linear feathering (OpenCV mat ops; no scalar loops) |
| **Zero-copy** | Y-channel zero-cost extraction; capture requires YUV→RGB copy | ByteBuffer JNI zero-copy for analysis stream (single RGBA plane); G channel extracted for nav; ByteArray copies forbidden |
| **Two-stream alignment** | Implicit two-stream (analysis + capture) | Two-stream (Preview + Analysis); SCALAR_CROP delivers 1600×1200 from 4K sensor; stitch commit uses analysis RGBA inline; ImageCapture debug-only |
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

1. Two-stream alignment (Preview + Analysis) is elevated to a hard contract.
2. Explicit resolution contract: request 4K sensor, SCALAR_CROP to 1600×1200, downscale to 800×600 for stitch; with fallback policy for devices without SCALAR_CROP support.
3. CameraX SCALAR_CROP replaces software center crop; frames arrive pre-cropped at 1600×1200 RGBA8888.
4. CameraX-first transform ownership is explicit; no contradictory transform duplication allowed.
5. First committed frame after Start must pass full gating (tightened behavior).
6. ECC full-resolution refinement moved into MVP (not deferred).
7. ByteBuffer minimal-copy and latency-focused constraints are explicit from capture-delay investigation findings.
8. Quality formula and overlap-zero behavior are strict and testable.
9. UI contract now explicitly mandates subtle border pulse, FRAMES correctness, velocity/quality bars, and InfoBar confidence display.
10. MVP explicitly excludes image corrections.
11. ImageCapture removed from stitch path; stitching uses ImageAnalysis RGBA8888 frames inline (latency: ~300ms → ~93ms).
