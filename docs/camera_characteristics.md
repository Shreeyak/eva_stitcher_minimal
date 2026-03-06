# Camera Characteristics — OnePlus OPD2403

**Generated from device dump: 2026-03-06 · Android API 36**
Dump file: `/sdcard/Android/data/com.example.eva_minimal_demo/files/camera_dump.txt`

---

## Device Overview

| Property | Value |
|---|---|
| Device | OnePlus OPD2403 |
| Android API | 36 |
| Hardware Level | `INFO_SUPPORTED_HARDWARE_LEVEL_3` — maximum tier; full manual sensor control available |
| Partial results | 2 (enables fast AF/AE metadata before full result) |
| Pipeline depth | 8 frames |

---

## Sensor Geometry

| Property | Value | Notes |
|---|---|---|
| Pixel array | 4208 × 3120 | Full sensor |
| Active array | 4208 × 3120 | No crop from pixel array |
| Physical size | 4.713 × 3.494 mm | |
| Pixel pitch | ≈ 1.12 µm | 4.713 mm / 4208 px |
| Color filter | `3` = RGGB Bayer | Standard pattern |
| Black level | 64 (all channels) | 10-bit sensor (`WHITE_LEVEL = 1023`) |

**WSI relevance:** At 1× zoom the ImageCapture use case delivers up to ~13 MP (4208×3120). The analysis crop is 640×480 (one frame = ~130 µm² of slide area at typical magnification; exact scale depends on optics).

---

## Exposure & Sensitivity

| Property | Value | WSI target |
|---|---|---|
| Exposure time range | 20.8 µs → 260 ms | **≤ 500 µs** to freeze slide motion |
| ISO range | 100 → 1600 | **ISO 100–200** for minimal noise |
| Max analog ISO | 1600 | All ISO is analog here — no digital gain |
| Max frame duration | 260.5 ms (≈ 3.8 fps minimum) | |
| AE compensation range | −18 → +18 EV (step 1/6 EV) | Irrelevant when AE is OFF |
| Available AE modes | 0=OFF, 1=ON, 2=ON_AUTO_FLASH, 3=ON_ALWAYS_FLASH | Use `OFF` for manual |
| AE target FPS ranges | [15,15], [15,20], [20,20], [10,30], **[30,30]** | Use `[30,30]` to lock FPS |

**Recommended settings for WSI scanning:**

```
SENSOR_EXPOSURE_TIME  = 500_000 ns  (0.5 ms)   — adjust up if underexposed
SENSOR_SENSITIVITY    = 100                     — lowest noise floor
CONTROL_AE_MODE       = OFF
```

Minimum exposure (20.8 µs) limits motion blur to < 0.1 µm at 5 mm/s slide speed. At 500 µs a 5 mm/s motion blurs ≈ 2.5 µm — acceptable for most WSI.

---

## Lens Optics

| Property | Value |
|---|---|
| Focal length | 3.39 mm (fixed) |
| Aperture | f/2.2 (fixed) |
| OIS | **Not available** (`OPTICAL_STABILIZATION = 0`) |
| Focus distance calibration | `1` = APPROXIMATE |
| Hyperfocal distance | ≈ 2.33 m (1 / 0.4288) |
| Min focus distance | 10 diopters = 0.1 m = **10 cm** |
| Intrinsic calibration | fx = fy = 3026.79 px (square pixels), cx = cy = 0 (principal point at sensor origin — likely in sensor coordinates, not image coordinates) |
| Distortion | All zeros (manufacturer reports no distortion — use with caution for stitching) |

**WSI relevance:** No OIS means the camera must be held stable or on a stand. Focus must be set manually with `CONTROL_AF_MODE = OFF` + `LENS_FOCUS_DISTANCE` once locked. AF modes 0–4 (OFF, AUTO, MACRO, CONTINUOUS_VIDEO, CONTINUOUS_PICTURE) are all available.

---

## White Balance / Colour

| Property | Value |
|---|---|
| AWB modes | OFF, AUTO, INCANDESCENT, FLUORESCENT, WARM_FLUORESCENT, DAYLIGHT, CLOUDY, TWILIGHT, SHADE |
| AWB lock available | ✓ |
| Reference illuminant 1 | 21 = D65 (daylight 6500 K) |
| Reference illuminant 2 | 17 = Standard illuminant A (tungsten 2856 K) |
| Sensor black level | 64 / 64 / 64 / 64 |
| White level | 1023 (10-bit) |

**CCM values (for CCM1 at D65):**

```
[ 197/128  -93/128  -15/64 ]   ≈ [ 1.539  -0.727  -0.234 ]
[ -31/32    15/8     5/128 ]   ≈ [-0.969   1.875   0.039 ]
[   5/128 -19/128   49/64 ]   ≈ [ 0.039  -0.148   0.766 ]
```

**WSI relevance:** Lock AWB immediately after camera settles on slide. The WB lock pattern in `CameraManager` captures live CCM+gains then switches `AWB_MODE_OFF` — verified working on this device.

---

## ISP / Post-processing Modes

| Feature | Available modes | WSI setting | Code constant |
|---|---|---|---|
| Edge enhancement | OFF(0), FAST(1), HIGH_QUALITY(2), ZERO_SHUTTER_LAG(3) | **OFF** | `EDGE_MODE_OFF` |
| Noise reduction | OFF(0), FAST(1), HIGH_QUALITY(2), MINIMAL(3), ZSL(4) | **FAST** | `NOISE_REDUCTION_MODE_FAST` |
| Hot pixel correction | OFF(0), FAST(1), HIGH_QUALITY(2) | **FAST** | `HOT_PIXEL_MODE_FAST` |
| Aberration correction | OFF(0), FAST(1), HIGH_QUALITY(2) | **FAST** | `COLOR_CORRECTION_ABERRATION_MODE_FAST` |
| Lens shading correction | OFF(0), FAST(1) | FAST | `SHADING_MODE_FAST` |
| Video stabilisation | OFF(0), ON(1), PREVIEW_STABILIZATION(2) | **OFF** | `CONTROL_VIDEO_STABILIZATION_MODE_OFF` |
| Tonemap modes | CONTRAST_CURVE(0), FAST(1), HIGH_QUALITY(2) | — (not set) | |

All WSI settings are applied unconditionally in `applyAllCaptureOptions()`.

---

## Capabilities

| Capability code | Meaning |
|---|---|
| 0 | BACKWARD_COMPATIBLE |
| 1 | MANUAL_SENSOR ✓ |
| 2 | MANUAL_POST_PROCESSING ✓ |
| 3 | RAW ✓ |
| 4 | PRIVATE_REPROCESSING |
| 5 | READ_SENSOR_SETTINGS |
| 6 | BURST_CAPTURE |
| 7 | YUV_REPROCESSING |
| 18 | LOGICAL_MULTI_CAMERA |
| 19 | ULTRA_HIGH_RESOLUTION_SENSOR |
| 20 | REMOSAIC_REPROCESSING |

`MANUAL_SENSOR` (1) and `MANUAL_POST_PROCESSING` (2) confirm full manual control is supported. `RAW` (3) confirms `SENSOR_INFO_EXPOSURE_TIME_RANGE` / `SENSOR_INFO_SENSITIVITY_RANGE` are populated and valid.

---

## Zoom

| Property | Value |
|---|---|
| Digital zoom range | 1× → 10× |
| Cropping type | `0` = CENTER_ONLY |

For WSI, keep zoom at **1×** — optical resolution is highest and the full pixel array is used.

---

## Flash

| Property | Value |
|---|---|
| Flash available | ✓ |
| Strength levels | 1–4 (default 2) |

Not relevant for WSI (slides are lit by transmitted light).

---

## AF Regions / Metering

| Property | Value |
|---|---|
| AF regions | 1 |
| AE regions | 1 |
| AWB regions | 0 (not supported) |
| Sync max latency | 0 = per-frame (changes take effect immediately) |

---

## Summary: Recommended WSI Capture Settings

```kotlin
// Applied via CameraManager.applyAllCaptureOptions()
CONTROL_AE_MODE                    = OFF
SENSOR_EXPOSURE_TIME               = 500_000L        // 0.5 ms — adjust per brightness
SENSOR_SENSITIVITY                 = 100             // ISO 100
CONTROL_AF_MODE                    = OFF
LENS_FOCUS_DISTANCE                = <captured from AF settle>
CONTROL_AWB_MODE                   = OFF             // after locking
COLOR_CORRECTION_TRANSFORM         = <captured CCM>
COLOR_CORRECTION_GAINS             = <captured RGGB gains>
EDGE_MODE                          = OFF
NOISE_REDUCTION_MODE               = FAST
COLOR_CORRECTION_ABERRATION_MODE   = FAST
HOT_PIXEL_MODE                     = FAST
SHADING_MODE                       = FAST
CONTROL_VIDEO_STABILIZATION_MODE   = OFF
```


## Reference: Raw dump

```
# Camera2 Characteristics Dump
# Generated: 2026-03-06 21:30:09
# Device: OnePlus OPD2403 (API 36)


# ── SENSOR GEOMETRY ─────────────────────────────────────────────
SENSOR_INFO_ACTIVE_ARRAY_SIZE                           (0,0)-(4208,3120)
SENSOR_INFO_PIXEL_ARRAY_SIZE                            4208x3120
SENSOR_INFO_PHYSICAL_SIZE                               4.71296x3.4944
SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE            (0,0)-(4208,3120)

# ── EXPOSURE & SENSITIVITY ──────────────────────────────────────
SENSOR_INFO_EXPOSURE_TIME_RANGE                         [20834, 260425000]
SENSOR_INFO_SENSITIVITY_RANGE                           [100, 1600]
SENSOR_MAX_ANALOG_SENSITIVITY                           1600
SENSOR_INFO_MAX_FRAME_DURATION                          260477085
CONTROL_AE_COMPENSATION_RANGE                           [-18, 18]
CONTROL_AE_COMPENSATION_STEP                            1/6
CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES                  [15, 15], [15, 20], [20, 20], [10, 30], [30, 30]
CONTROL_AE_AVAILABLE_MODES                              0, 1, 2, 3
CONTROL_AE_LOCK_AVAILABLE                               true

# ── LENS OPTICS ─────────────────────────────────────────────────
LENS_INFO_AVAILABLE_FOCAL_LENGTHS                       3.390000
LENS_INFO_AVAILABLE_APERTURES                           2.200000
LENS_INFO_AVAILABLE_FILTER_DENSITIES                    0.000000
LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION               0
LENS_INFO_FOCUS_DISTANCE_CALIBRATION                    1
LENS_INFO_HYPERFOCAL_DISTANCE                           0.4288163
LENS_INFO_MINIMUM_FOCUS_DISTANCE                        10.0
LENS_FACING                                             1
LENS_POSE_REFERENCE                                     0
LENS_INTRINSIC_CALIBRATION                              3026.785645, 3026.785645, 0.000000, 0.000000, 0.000000
LENS_DISTORTION                                         0.000000, 0.000000, 0.000000, 0.000000, 0.000000
LENS_RADIAL_DISTORTION (deprecated)                     <not supported>

# ── FOCUS / AF ──────────────────────────────────────────────────
CONTROL_AF_AVAILABLE_MODES                              0, 1, 2, 3, 4

# ── AWB / COLOUR ────────────────────────────────────────────────
CONTROL_AWB_AVAILABLE_MODES                             1, 2, 3, 4, 5, 6, 7, 8, 0
CONTROL_AWB_LOCK_AVAILABLE                              true
SENSOR_COLOR_TRANSFORM1                                 [197/128, -93/128, -15/64, -31/32, 15/8, 5/128, 5/128, -19/128, 49/64]
SENSOR_COLOR_TRANSFORM2                                 [157/64, -217/128, -55/128, -137/128, 279/128, -1/128, 1/16, -9/64, 5/4]
SENSOR_FORWARD_MATRIX1                                  [7/16, 49/128, 9/64, 7/32, 23/32, 1/16, 1/64, 3/32, 91/128]
SENSOR_FORWARD_MATRIX2                                  [7/16, 49/128, 9/64, 7/32, 23/32, 1/16, 1/64, 3/32, 91/128]
SENSOR_CALIBRATION_TRANSFORM1                           [131/128, 0/1, 0/1, 0/1, 1/1, 0/1, 0/1, 0/1, 129/128]
SENSOR_CALIBRATION_TRANSFORM2                           [131/128, 0/1, 0/1, 0/1, 1/1, 0/1, 0/1, 0/1, 129/128]
SENSOR_REFERENCE_ILLUMINANT1                            21
SENSOR_REFERENCE_ILLUMINANT2                            17
SENSOR_BLACK_LEVEL_PATTERN                              [64, 64, 64, 64]
SENSOR_INFO_COLOR_FILTER_ARRANGEMENT                    3
SENSOR_INFO_WHITE_LEVEL                                 1023

# ── NOISE REDUCTION / EDGE / ISP ────────────────────────────────
NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES         0, 1, 2, 3, 4
EDGE_AVAILABLE_EDGE_MODES                               1, 2, 0, 3
HOT_PIXEL_AVAILABLE_HOT_PIXEL_MODES                     0, 1, 2
COLOR_CORRECTION_AVAILABLE_ABERRATION_MODES             0, 1, 2
SHADING_AVAILABLE_MODES                                 0, 1, 2
TONEMAP_AVAILABLE_TONE_MAP_MODES                        0, 1, 2
TONEMAP_MAX_CURVE_POINTS                                64

# ── FLASH / TORCH ───────────────────────────────────────────────
FLASH_INFO_AVAILABLE                                    true
FLASH_INFO_STRENGTH_MAXIMUM_LEVEL                       4
FLASH_INFO_STRENGTH_DEFAULT_LEVEL                       2

# ── ZOOM / CROP ─────────────────────────────────────────────────
SCALER_AVAILABLE_MAX_DIGITAL_ZOOM                       10.0
SCALER_CROPPING_TYPE                                    0
CONTROL_ZOOM_RATIO_RANGE                                [1.0, 10.0]

# ── STABILISATION ───────────────────────────────────────────────
CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES             0, 1, 2

# ── CAPABILITIES ────────────────────────────────────────────────
INFO_SUPPORTED_HARDWARE_LEVEL                           3
REQUEST_AVAILABLE_CAPABILITIES                          0, 3, 7, 4, 5, 1, 6, 2, 19, 20, 18
REQUEST_MAX_NUM_OUTPUT_RAW                              1
REQUEST_MAX_NUM_OUTPUT_PROC                             3
REQUEST_MAX_NUM_OUTPUT_PROC_STALLING                    2
REQUEST_PARTIAL_RESULT_COUNT                            2
REQUEST_PIPELINE_MAX_DEPTH                              8

# ── SCENE / EFFECT MODES ────────────────────────────────────────
CONTROL_AVAILABLE_SCENE_MODES                           0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14, 15, 18
CONTROL_AVAILABLE_EFFECTS                               0, 2, 3, 4, 5, 8, 7, 6
CONTROL_MAX_REGIONS_AF                                  1
CONTROL_MAX_REGIONS_AE                                  1
CONTROL_MAX_REGIONS_AWB                                 0

# ── SYNC / LATENCY ──────────────────────────────────────────────
SYNC_MAX_LATENCY                                        0

# ── JPEG ────────────────────────────────────────────────────────
JPEG_AVAILABLE_THUMBNAIL_SIZES                          0x0, 176x144, 240x120, 213x160, 240x144, 256x144, 240x160, 256x154, 246x184, 250x188, 352x160, 240x240, 320x180, 400x180, 320x240, 360x240, 374x282

# ── STATISTICS ──────────────────────────────────────────────────
STATISTICS_INFO_AVAILABLE_FACE_DETECT_MODES             0, 1
STATISTICS_INFO_MAX_FACE_COUNT                          10
STATISTICS_INFO_AVAILABLE_HOT_PIXEL_MAP_MODES           [Z@c805537
STATISTICS_INFO_AVAILABLE_LENS_SHADING_MAP_MODES        0, 1

# --- END OF DUMP ---
```
