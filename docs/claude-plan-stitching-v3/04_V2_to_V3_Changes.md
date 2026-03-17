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
- **v3**: Constant `CROP_RATIO = 0.40`, applied to whatever CameraX actually returns
- **Why**: Device-adaptive; no dependency on specific sensor dimensions

### Navigation Frame

- **v2**: Analysis ~1280×960 → crop ~492×369 → resize to fixed **400×300** → navScale = 2.0
- **v3**: Request 1600×1200 → crop 40% → use **as-is** (~640×480) → navScale = 800/640 = 1.25
- **Why**: Higher analysis resolution; no wasted resize step; scale computed from actual dims

### Capture Trigger

- **v2**: Unspecified (atomic flags or JNI callback implied)
- **v3 original**: `processAnalysisFrame()` returns `jboolean` — Kotlin checks return value directly
- **v3 revision**: `processAnalysisFrame()` returns `void`; stitch commit is inline in C++ (no Kotlin trigger)
- **Why**: ImageCapture callback ~300ms latency even in MINIMIZE_LATENCY/ZSL mode; inline analysis commit achieves ~98ms

### Stitch Frame Source

- **v2/v3 original**: ImageCapture full-res (~4160×3120) for stitching; ImageAnalysis Y-only for navigation
- **v3 revision**: ImageAnalysis YUV for both navigation (Y-only) and stitch commit (YUV→BGR inline); ImageCapture retained only for the debug capture button
- **Why**: Eliminates ~300ms CameraX capture callback overhead; simplifies pipeline to two active streams; `processAnalysisFrame` now receives Y+U+V planes
- **Trade-off**: Stitch frame source is analysis sensor (~1600×1200 →40% crop → ~640×480) instead of capture sensor (~4160×3120); canvas frame requires slight upscale to 800×600 rather than downscale

### First-Frame Gating

- **v2**: Implicit — first frame at origin when gating passes
- **v3**: Explicit — first frame (`_framesCaptured == 0`) bypasses distance/overlap checks, still requires sharpness + velocity stability + tracking
- **Why**: Prevents ambiguity about what checks apply to first capture

### Canvas Bounds Initialization

- **v2**: Implied empty state
- **v3**: Explicit: `minX > maxX` signals empty; `getOverlapRatio()` returns 0.0 when empty; after first frame → `(0, 0, 800, 600)`

---

## New in V3 (Not in V2)

1. **Stream Alignment section** — documents why CameraX doesn't guarantee identical crops and why software center-crop is needed
2. **Analysis Resolution Strategy** — request 1600×1200, adapt gracefully to whatever CameraX returns, force 4:3 if needed
3. **All constants defined with values** — `types.h` section with 19 constants, tuning guidance in Phase 8.4
4. **Gating reason codes**: added `"overlap_too_high"`, `"distance_too_large"`, `"ok"`
5. **NavigationState contract**: explicit 19-field table with indices, types, and units
6. **CMakeLists.txt + Gradle integration**: full build scaffold specification
7. **ECC failure handling**: try-catch, sparse canvas skip (>50% alpha==0), confidence fallback rules
8. **LRU eviction safety**: must hold exclusive `_canvasMutex`, synchronous PNG flush
9. **Canvas preview maxDim**: default 1024 pixels
10. **Strict acceptance checklist**: 7 categories (A–G) with checkboxes
11. **ImageAnalysis-only stitch path**: `processAnalysisFrame` now accepts Y+U+V planes; stitch commit is inline; `processCaptureFrame` and `StitchFrameProcessor` removed; `initEngine` no longer takes capture dimensions

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
