AR systems like **ARCore** must reject blurry frames **before feature extraction**, otherwise tracking becomes unstable. Since they run on mobile CPUs in real time, they avoid expensive operations (like full Laplacian on full-resolution frames).

Instead, AR pipelines typically combine **very cheap image statistics + feature feedback**. The exact implementation isn’t public, but from papers, ARCore talks, and reverse-engineering of similar SLAM pipelines, the process is roughly this.

---

# 1. Downsample → Gradient Energy Test (Primary Blur Detector)

The fastest blur detector is **image gradient energy**.

### Idea

Blur removes high-frequency edges.

So if the **sum of gradients is small**, the frame is blurry.

### Pipeline

1. Downsample frame (e.g., 640×480 → 160×120)
2. Compute gradients
3. Sum gradient magnitudes

This is extremely cheap.

### Example metric

```
score = Σ(|Ix| + |Iy|)
```

If:

```
score < threshold
→ frame rejected
```

### Why it works

Blur acts like a **low-pass filter**, reducing gradients.

### Why AR systems love it

| Method | Cost |
| --- | --- |
| Laplacian variance | medium |
| FFT blur detection | expensive |
| Gradient energy | **very cheap** |

Typical cost:

```
~0.1–0.3 ms per frame
```

---

# 2. Feature Count Gate (Tracking Health Check)

ARCore then extracts features (FAST/AGAST style).

If the frame produces **too few keypoints**, it gets rejected.

Example:

```
features = detectFAST()

if features < 80:
    reject frame
```

Blur dramatically reduces FAST corners.

This doubles as:

- blur detection
- low-texture detection
- motion blur detection

---

# 3. Optical Flow Residual Check

For tracked features:

```
prev_points → optical flow → current_points
```

Then evaluate reprojection error.

Blur causes:

- inconsistent feature motion
- large residuals

If residual error spikes:

```
reject frame
```

---

# 4. Exposure-Based Motion Blur Prediction

ARCore also reads camera metadata:

- `SENSOR_EXPOSURE_TIME`
- `SENSOR_SENSITIVITY`

If exposure time becomes too long:

```
if exposure > threshold:
    reduce tracking confidence
```

This predicts motion blur **before it happens**.

---

# 5. Tracking Score

Internally ARCore keeps a **tracking quality score** combining:

```
blur_score
feature_count
optical_flow_error
exposure_time
IMU consistency
```

If score drops → frame ignored for pose update.

---

# Simplified AR Pipeline

```
frame arrives
      ↓
downsample
      ↓
gradient energy test
      ↓
if pass → feature extraction
      ↓
if features > threshold
      ↓
optical flow tracking
      ↓
if reprojection error low
      ↓
update camera pose
```

Blurry frames usually fail **stage 1 or 2**.

---

# Minimal Implementation (Fast)

For a custom pipeline like your stitching/tracking system, the closest ARCore-style check is:

```
1. downsample frame to ~160×120
2. compute Sobel gradients
3. compute sum(|Ix| + |Iy|)
4. reject if below threshold
```

This runs **~10× faster than Laplacian** and works very well.

---

# Why This Works Better Than Laplacian

| Method | Pros | Cons |
| --- | --- | --- |
| Laplacian variance | accurate | slower |
| Gradient energy | **very fast** | slightly noisier |
| FFT | robust | very slow |

Real-time AR prefers **speed over perfect accuracy**.

---

# Advanced Trick Used in Some SLAM Systems

Instead of gradients, compute **patch variance** on a grid.

Example:

```
split image into 16×16 patches
compute variance per patch
count patches with high variance
```

If too few textured patches → reject frame.

This is even cheaper than Sobel.
