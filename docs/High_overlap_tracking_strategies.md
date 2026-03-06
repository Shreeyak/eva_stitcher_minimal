# High Overlap Strategies

### Restrict matching region

Since motion is small:
Only search in predicted location
Use transform from previous frame
Use epipolar / homography guidance
Massive speed boost

Reduce feature count to 300-500

### Guided Matching Idea

If you already have an approximate transform:
Then instead of searching entire image B:
You:
Warp feature location using predicted H
Only search in small radius around predicted position

#### Idea

Randomly take a small set of features. Apply transform. Search nearby. If features close by, then transform good, otherwise estimate bad.

### Alternatives to RANSAC if estimated transform available

ECC (already applied as phase 2)

Gauss-Newton optimization
LM
Initialized with H₀

### Local temporary KLT optical flow

After ransac match, suppose you get 200 inliers. Use KLT to track to next frame. Keep tracking till tracked features drop below a threshold. Then do RANSAC again.

KLT is much faster [O(N) vs O(N^2)] and does local search.

Only re-detect features when:
Tracked count drops below threshold
Large motion
Tracking confidence low
This is how: Visual odometry, SLAM and Real-time AR systems work.

### Multi-Scale processing

Detect features at different scales. Example 0.5x resolution. They'll be different.

### (Optional) Correlation Filter-Based Tracking

(Classical and Still Widely Used)
Correlation Filters (CF) / Discriminative Correlation Filters (DCF)
These methods operate by learning a discriminative filter that, when correlated over a search region in the image, produces a peak response at the estimated object location. MOSSE / KCF often runs comfortably > 30–60 FPS on desktop CPUs .
