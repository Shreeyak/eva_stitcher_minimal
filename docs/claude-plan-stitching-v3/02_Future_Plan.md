# Future Improvements Plan

**Date**: 2025-07-10
**Prerequisite**: MVP Stitching Pipeline v3 complete (8 phases)

---

## Overview

Features deferred from MVP to keep scope lean. Each is independent unless noted. Prioritized by expected impact vs effort.

---

## Priority 1: Vignetting Correction

**Why**: Phone cameras exhibit brightness falloff toward edges. Creates visible seams at stitch boundaries even with perfect registration and feathering.

**Design**:

- **Calibration frame**: At app startup or once (saved to disk), capture a flat-field image (uniform white surface through microscope). `gain_map = mean(flat) / flat`. Clamp to [0.8, 1.5].
- **Application**: Before compositing each capture frame: `corrected = frame × gain_map`.
- **Parametric fallback**: If no calibration, use radial model `gain(r) = 1 + k × r²` with k ≈ 0.15.
- Since MVP uses 800×600 canvas frames, the gain map is 800×600 (pre-compute by cropping + resizing just like canvas frames).

**Expected cost**: ~5ms per frame.

**Files**:

- New: `native/stitcher/vignetting.h/cpp`
- Modified: `native/stitcher/engine.cpp` (apply before compositing)
- Modified: MethodChannel for calibration capture trigger

**Dependencies**: None (standalone after MVP).

---

## Priority 2: Exposure / White Balance Normalization

**Why**: Over a long scan, AWB/AE may shift slightly, causing color inconsistency between frames. Creates visible color seams.

**Design**:

- Compute mean brightness and color per channel of the overlap region for both incoming frame and canvas content.
- Apply per-frame gain: `corrected = frame × (canvasMean / frameMean)` per BGR channel.
- Clamp scale to [0.7, 1.4] to prevent overcompensation.

**Expected cost**: ~5ms (mean computation + multiply on 800×600).

**Files**: `native/stitcher/canvas.cpp` only.

**Dependencies**: None.

---

## Priority 3: Laplacian Pyramid Blending

**Why**: Linear feathering handles brightness but produces ghosting with sub-pixel misregistration. Multi-band blending merges frequencies independently for seamless composites.

**Design**:

- Build 3–4 level Laplacian pyramids for frame and canvas overlap region.
- Build Gaussian pyramid of weight mask.
- Blend each level independently.
- Reconstruct.

**Expected cost**: ~30–50ms on 800×600.

**Files**:

- New: `native/stitcher/blending.h/cpp`
- Modified: `native/stitcher/canvas.cpp` (swap blend step)

**Dependencies**: Exposure normalization (P2) recommended first.

---

## Priority 4: Coverage Tracking

**Why**: User needs to see which parts of the slide have been scanned and where gaps exist.

**Design**:

- Low-resolution grid (32×32 canvas px per cell).
- Track fraction of pixels with alpha > 0 per cell.
- Expose to Dart as byte array via MethodChannel.
- Render in CanvasView as color overlay (green = covered, empty = uncovered).

**Expected cost**: Negligible.

**Files**:

- Modified: `native/stitcher/canvas.h/cpp`
- New JNI method + Kotlin + MethodChannel
- Modified: `lib/widgets/canvas_view.dart` (overlay painter)

**Dependencies**: None.

---

## Priority 5: Re-localization After Tracking Loss

**Why**: When tracking is lost, MVP freezes pose. If user moves far, system is stuck. Re-localization searches the canvas to find current position.

**Design**:

- When LOST and device appears stationary: every 5th analysis frame, attempt template matching.
- Build low-res grayscale canvas (~2000×1500) from cached tiles.
- `cv::matchTemplate(canvasLowRes, currentNavFrame, TM_CCOEFF_NORMED)`.
- If best score > 0.6: re-anchor pose, transition to TRACKING.

**Expected cost**: ~100–200ms per attempt (only when LOST).

**Files**:

- Modified: `native/stitcher/navigation.h/cpp`
- Modified: `native/stitcher/canvas.h/cpp` (low-res render method)
- Modified: `native/stitcher/engine.cpp`

**Dependencies**: None beyond MVP.

---

## Priority 6: Rotation Support

**Why**: Small rotations from phone-on-eyepiece setup cause curved/skewed mosaics over many frames.

**Design Options**:

1. **ECC MOTION_EUCLIDEAN**: Change from `MOTION_TRANSLATION` to `MOTION_EUCLIDEAN` in `findTransformECC()`. Nearly free. Handles sub-degree rotations.
2. **Log-polar PCR**: Convert frames to log-polar, run phase correlation for rotation angle. ~50ms. Handles up to ~5°.
3. **ORB + RANSAC**: Keypoint detection + matching + similarity transform estimation. ~100ms. Most robust.

**Recommended**: Start with option 1 (trivial code change). Upgrade to option 2 if rotation >1–2° observed.

**Dependencies**: ECC already in MVP (Phase 5).

---

## Priority 7: Export (DeepZoom / TIFF)

**Why**: Canvas needs to be viewable in standard WSI viewers.

**Formats**:

- **DeepZoom (.dzi)**: Multi-resolution tile pyramid for web viewers (OpenSeadragon).
- **Pyramid TIFF**: Standard microscopy format via libtiff.
- **Single PNG/JPEG**: For small scans.

**Design**:

- New MethodChannel: `exportCanvas(format, outputPath)`.
- Walk all tiles (memory + disk) in scanline order.
- Build pyramid levels (downsample 2× per level).
- Background thread, ~5–30 seconds.

**Files**:

- New: `native/stitcher/export.h/cpp`
- New JNI + Kotlin + MethodChannel
- Modified: `lib/stitcher/stitch_state.dart` (export method)

**Dependencies**: None beyond MVP.

---

## Priority 8: Incremental Weighted Average Compositing

**Why**: Linear feathering handles pairwise overlaps but doesn't converge to a "true" pixel value with 3+ overlapping frames. Weighted averaging reduces noise and handles high-overlap scenarios better.

**Design**:

- Per-tile: store float sum (CV_32FC3) + float weight (CV_32F) instead of uint8 BGRA.
- Display = sum / weight.
- Quality-scaled weights: `weight × quality_scale` based on ECC score.
- Two-pass: active tiles use float accumulators; finalized tiles convert to uint8.

**Memory**: ~16 bytes/pixel vs ~4 bytes. Mitigate with two-pass approach (only active tiles as float).

**When preferred**: High overlap (>60%), many overlapping frames, noise reduction needed.

**Dependencies**: None, but test after ECC and Laplacian blending.

---

## Priority 9: Drift Correction

**Why**: Frame-to-frame dead-reckoning accumulates error. After 100+ frames, pose may be off by 20–50+ pixels.

**Design**:

- Every 10th analysis frame, run phase correlation against a low-res canvas.
- Apply correction with blend factor to avoid jitter.
- Requires maintaining a low-res canvas copy.

**Dependencies**: None beyond MVP.

---

## Priority 10: Rolling Shutter De-skewing

**Why**: Rolling shutter causes shear distortion during motion. Even with capture-when-still, residual motion creates sub-pixel errors.

**Design**: Per-row de-skew using velocity at capture time + sensor readout time.

**Dependencies**: None beyond MVP. Low priority — effect is minimal with velocity gating.

---

## Recommended Implementation Order

```
P1 (Vignetting) → P2 (Exposure) → P3 (Laplacian) → P4 (Coverage) → P5 (Re-loc) → P6 (Rotation) → P7 (Export) → P8 (Weighted Avg) → P9 (Drift) → P10 (Rolling Shutter)
```
