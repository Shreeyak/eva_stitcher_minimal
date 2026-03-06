# Chunked Canvas

### Localized Updates (Incremental Stitching)

When adding a new frame:
Warp it
Find which tiles it overlaps
Only update those tiles
Instead of blending into a giant image.
This dramatically reduces:
Cache misses
Memory bandwidth
Copy cost

### Parallel Blending

Each tile can:
Compute blending weights independently
Run multiband blending locally
Be processed in parallel threads
Very CPU friendly.

Each tile given to a different thread

### 🔥 Correct Way To Avoid Seams

You need overlapping tile margins.
Instead of 128×128 tiles:
Internally store:
Copy code

Tile data size: 128×128
Actual buffer: 160×160  (16px padding)
Now:
Warp into padded region
Blend inside padded region
When rendering final panorama → crop central 128×128
This ensures continuity.

#### Better method:

Warp full frame into temporary buffer (small)
Compute overlapping tile indices
For each tile:
Compute local intersection
Blend only intersection region

Overlapping Tile Borders (Most Common)
Each tile stores a margin.
Example:

```jsx
Tile size: 128x128
Actual stored: 160x160
Margin: 16px on all sides
```

When blending:
Compute normally inside extended tile
After blending, crop center 128x128
Neighbor tiles overlap consistently
This removes seam artifacts.
Game engines use this everywhere.

```jsx
for each tile in affected_tiles:
  process(tile)
```

No locks needed

### Architecture

🧠 Layer 1 — Global Pose Graph
Homographies
RANSAC
ECC refinement
Drift correction
🎨 Layer 2 — Tile-Based Renderer
Sparse tile map
Accumulated sum + weight
Parallel blending
Only update touched tiles

### Even More Advanced Trick (Used in Some Research)

If frames come from video:
Consecutive frames are very similar.
Instead of rebuilding frame pyramids:
You can warp the previous frame pyramid.
Copy code

warp(previous_pyramid_level)
Then only update the small difference region.
This is called pyramid warping reuse.
It can make stitching almost real-time on CPU.

```jsx
capture frame
 ↓
feature tracking
 ↓estimate homography     ↓warp frame     ↓find affected tiles     ↓build pyramid of warped patches     ↓accumulate into tile pyramids     ↓reconstruct changed tiles
```

### Blending

With 768p img and 80% overlap, we get excellent registration.

So gain compensation+ feather blending works great.

We could also find seams with graphcut, and modify tiles with seam. Might be able to get away with zero blending of we get good seams
