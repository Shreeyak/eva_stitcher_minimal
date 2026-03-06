To make tiled incremental stitching work with OpenCV multiband blending, the key idea is:

Each tile stores its own Laplacian pyramid buffers + weight pyramids, and new warped frames update only the tiles they overlap.

You’re essentially turning the panorama into a sparse grid of local multiband blenders.

Below is a practical architecture that works well with OpenCV-style data structures.

1️⃣ Tile Layout in the Panorama

Assume:

Tile size: 256×256

Padding: 32 px margin

Effective tile buffer: 320×320

Padding ensures pyramid kernels don’t cause seams.

Panorama grid

+-------+-------+-------+
| Tile  | Tile  | Tile  |
| 0,0   | 1,0   | 2,0   |
+-------+-------+-------+
| Tile  | Tile  | Tile  |
| 0,1   | 1,1   | 2,1   |
+-------+-------+-------+

Tiles only exist when needed → sparse grid.

2️⃣ Tile Data Structure

Concrete C++ structure compatible with OpenCV.

struct Tile
{
    static const int TILE_SIZE = 256;
    static const int PADDING = 32;
    static const int BUFFER = TILE_SIZE + 2 * PADDING;

    int tile_x;
    int tile_y;

    bool initialized = false;

    // multiband pyramid buffers
    std::vector<cv::Mat> laplacian_sum;
    std::vector<cv::Mat> weight_sum;

    int pyramid_levels;

    std::mutex mutex;
};

Explanation:

Field	Purpose
laplacian_sum	accumulated Laplacian pyramid
weight_sum	blending weights
pyramid_levels	number of pyramid levels
mutex	thread-safe updates

Each tile independently stores its multiband accumulator.

3️⃣ Tile Grid Container

Sparse tile map.

class TileGrid
{
public:
    std::unordered_map<long long, std::shared_ptr<Tile>> tiles;

    std::shared_ptr<Tile> getTile(int tx, int ty)
    {
        long long key = ((long long)tx << 32) | ty;

        auto it = tiles.find(key);
        if (it != tiles.end())
            return it->second;

        auto tile = std::make_shared<Tile>();
        tile->tile_x = tx;
        tile->tile_y = ty;

        tiles[key] = tile;

        return tile;
    }
};

Sparse allocation means:

A 50k×50k panorama does not allocate full memory.

Only tiles containing pixels exist.

Huge memory win.

4️⃣ Warping a New Frame

After computing homography:

cv::warpPerspective(frame, warped, H, pano_size);

But we don’t write into the full pano.

Instead:

1️⃣ Compute warped frame bounding box
2️⃣ Determine intersecting tiles

tile_x0 = floor(bbox.x / TILE_SIZE)
tile_x1 = floor((bbox.x + bbox.w) / TILE_SIZE)
tile_y0 = floor(bbox.y / TILE_SIZE)
tile_y1 = floor((bbox.y + bbox.h) / TILE_SIZE)

Now we update only those tiles.

5️⃣ Extract Tile Patch From Warped Frame

For each tile:

tile_origin_x = tx * TILE_SIZE - PADDING
tile_origin_y = ty * TILE_SIZE - PADDING

Extract region:

cv::Rect roi(tile_origin_x, tile_origin_y,
             Tile::BUFFER, Tile::BUFFER);

cv::Mat patch = warped(roi);

This patch includes context margin.

6️⃣ Compute Multiband Pyramid

Use standard OpenCV Laplacian pyramid.

void buildPyramid(
    const cv::Mat& img,
    std::vector<cv::Mat>& laplacian,
    int levels)
{
    std::vector<cv::Mat> gaussian(levels + 1);

    gaussian[0] = img;

    for (int i = 1; i <= levels; i++)
        cv::pyrDown(gaussian[i-1], gaussian[i]);

    for (int i = 0; i < levels; i++)
    {
        cv::Mat up;
        cv::pyrUp(gaussian[i+1], up, gaussian[i].size());

        laplacian.push_back(gaussian[i] - up);
    }

    laplacian.push_back(gaussian[levels]);
}

Also compute weight pyramid from mask.

7️⃣ Update Tile Accumulator

Inside the tile:

void accumulateTile(
    Tile& tile,
    const std::vector<cv::Mat>& lap,
    const std::vector<cv::Mat>& weight)
{
    std::lock_guard<std::mutex> lock(tile.mutex);

    if (!tile.initialized)
    {
        tile.laplacian_sum = lap;
        tile.weight_sum = weight;
        tile.initialized = true;
        return;
    }

    for (int i = 0; i < tile.pyramid_levels; i++)
    {
        tile.laplacian_sum[i] += lap[i].mul(weight[i]);
        tile.weight_sum[i] += weight[i];
    }
}

We accumulate weighted Laplacians.

8️⃣ Reconstruct Tile When Needed

To render final panorama:

cv::Mat reconstructTile(Tile& tile)
{
    std::vector<cv::Mat> normalized(tile.pyramid_levels);

    for (int i = 0; i < tile.pyramid_levels; i++)
    {
        normalized[i] = tile.laplacian_sum[i] /
                        (tile.weight_sum[i] + 1e-6);
    }

    cv::Mat img = normalized.back();

    for (int i = tile.pyramid_levels - 1; i >= 0; i--)
    {
        cv::pyrUp(img, img, normalized[i].size());
        img += normalized[i];
    }

    return img;
}

Then crop padding and place into final canvas.

9️⃣ Parallel Tile Updates

Because tiles are independent:

#pragma omp parallel for
for (int i = 0; i < affected_tiles.size(); i++)
{
    processTile(affected_tiles[i]);
}

Each thread works on separate tile memory.

Very cache friendly.

🔟 Why This Works Without Seams

Three protections prevent seams:

1️⃣ Tile padding
tile = 256
padding = 32
buffer = 320

Pyramid kernels stay inside buffer.

2️⃣ Weight normalization

Final pixel:

output = sum / weight

Ensures continuity across tiles.

3️⃣ Pyramid blending

High-frequency seams disappear naturally.

11️⃣ Performance Characteristics

This design scales extremely well.

Example incremental stitch:

Frame: 1280×720
Overlap: 80%
Tiles touched: ~12

Only ~12 tiles update.

Instead of touching entire panorama.

Huge savings.

12️⃣ Real Systems That Use Similar Designs

Conceptually similar to:

OpenDroneMap mosaicing

SLAM map tiling

GPU virtual textures

Google Maps tile pyramids

✅ Key takeaway

Tiles don't replace multiband blending.

They simply make the blender localized, sparse, and parallelizable.

If you'd like, I can also show something extremely useful for your use case:

How to make multiband blending 5–10× faster for incremental stitching by reusing pyramid levels from previous frames.

This trick is used in some modern stitching systems and is surprisingly simple.

Yes please. How can we reuse pyramid levels from older frames

Reusing pyramid levels is one of the biggest speedups for incremental stitching, especially when frames have 80–90% overlap like you mentioned earlier.

The key observation is simple:

Most of the panorama does not change when a new frame arrives. Only the overlap region changes.

So rebuilding pyramids everywhere is wasteful.

Let’s go step-by-step.

1️⃣ Where the Cost in Multiband Blending Comes From

For every new frame you normally:

Warp frame

Build Gaussian pyramid

Build Laplacian pyramid

Build weight pyramid

Blend with panorama pyramid

Reconstruct image

The expensive parts are:

pyrDown

pyrUp

Laplacian creation

Each pyramid level processes the whole image.

For large panoramas this dominates runtime.

2️⃣ Core Insight

A new frame only affects a local region of the panorama.

Example:

Panorama:   20000 x 4000
New frame:   1200 x 800

Overlap might touch ~1% of pixels.

So instead of rebuilding the entire pyramid:

✔ Update pyramids only in affected tiles

3️⃣ Tile-Level Pyramid Persistence

Each tile stores its existing multiband pyramid.

struct Tile
{
    int pyramid_levels;

    std::vector<cv::Mat> laplacian_sum;
    std::vector<cv::Mat> weight_sum;

    bool initialized;
};

These pyramids persist for the entire stitching session.

They represent the accumulated panorama content.

When a new frame arrives:

We only add its pyramid contribution.

We never rebuild the panorama pyramid.

4️⃣ Build Pyramid Only for the New Frame

For the new warped patch:

frame_patch (320x320)

We compute its pyramid:

Level 0: 320x320
Level 1: 160x160
Level 2: 80x80
Level 3: 40x40
Level 4: 20x20

This is cheap because the patch is small.

Then we add these levels to the tile accumulators.

5️⃣ Incremental Laplacian Accumulation

Instead of recomputing panorama Laplacians:

We accumulate weighted contributions.

tile_laplacian_sum += frame_laplacian * weight
tile_weight_sum += weight

This works because multiband blending is linear.

Final reconstruction simply divides by weights.

6️⃣ Why This Reuses Previous Pyramid Work

The panorama tile pyramid already contains:

previous_frames_contribution

When a new frame arrives:

We add:

new_frame_contribution

So the tile pyramid evolves like:

P0 = frame1 pyramid
P1 = P0 + frame2 pyramid
P2 = P1 + frame3 pyramid

No recomputation.

7️⃣ Even Better Optimization (Overlap Cropping)

If overlap is high (e.g. 80%):

Most of the new frame overlaps existing content.

You can restrict pyramid construction to the overlap region only.

Example:

Frame size: 1280x720
Overlap: 80%

Effective update region ≈ 256 px strip

So pyramid generation happens only there.

Huge savings.

8️⃣ Pyramid Level Reuse Trick

Another subtle optimization:

Lower pyramid levels represent large spatial areas.

Example:

Level 0: 256 px
Level 4: 16 px

A tiny update affects only small areas at coarse levels.

So you can update only the affected regions per level.

Example:

Level 0: update 200x200
Level 1: update 100x100
Level 2: update 50x50
Level 3: update 25x25

Instead of recomputing full levels.

9️⃣ Reconstruction Also Becomes Local

You don’t reconstruct the full panorama.

Only reconstruct tiles that changed.

changed_tiles → reconstruct
unchanged_tiles → reuse previous result

This keeps rendering fast.
