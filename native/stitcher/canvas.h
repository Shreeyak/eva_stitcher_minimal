#pragma once

#include <cstdint>
#include <memory>
#include <shared_mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <opencv2/core.hpp>

#include "types.h"

// ── Tile key ───────────────────────────────────────────────────────────────

struct TileKey {
    int col = 0;
    int row = 0;
    bool operator==(const TileKey& o) const noexcept { return col == o.col && row == o.row; }
};

struct TileKeyHash {
    size_t operator()(const TileKey& k) const noexcept {
        // Knuth multiplicative mix — handles negative indices correctly
        return std::hash<int>()(k.col) ^ (std::hash<int>()(k.row) * 2654435761u);
    }
};

// ── Tile ───────────────────────────────────────────────────────────────────

struct Tile {
    cv::Mat  pixels;            // CV_8UC3 BGR, TILE_SIZE × TILE_SIZE
    cv::Mat  mask;              // CV_8UC1, 0 = unwritten, 255 = written
    bool     dirty      = false;
    int64_t  lastAccess = 0;
};

// ── Canvas ─────────────────────────────────────────────────────────────────

class Canvas {
public:
    Canvas()  = default;
    ~Canvas() = default;

    Canvas(const Canvas&)            = delete;
    Canvas& operator=(const Canvas&) = delete;

    // cacheDir: writable directory for evicted tile PNGs (created if absent).
    void init(int frameW, int frameH, const std::string& cacheDir);

    // Composite one CANVAS_FRAME_W × CANVAS_FRAME_H BGR frame at the given canvas pose.
    // Interior pixels (w = 1) are directly overwritten; the feather band (w < 1) is blended.
    // Exclusive lock — called on the analysis thread.
    void compositeFrame(const cv::Mat& frame, Pose pose);

    // JPEG preview assembled from in-memory tiles, scaled to fit maxDim × maxDim.
    // Shared lock — safe to call from any thread.
    std::vector<uint8_t> renderPreview(int maxDim) const;

    // Fraction [0, 1] of already-written canvas pixels within the frame footprint at pose.
    // No lock — called only on the analysis thread (same thread as compositeFrame).
    float getOverlapRatio(Pose pose) const;

    // Canvas bounding box in canvas px. minX > maxX signals no frame committed yet.
    void getBounds(float& minX, float& minY, float& maxX, float& maxY) const;

    void reset();

    // Save all in-memory tiles to PNG files in the specified output directory.
    // Returns 0 on success, non-zero on error.
    int saveAllTilesToDisk(const std::string& outputDir);

private:
    int         _frameW   = 0;
    int         _frameH   = 0;
    std::string _cacheDir;

    // Pre-computed linear feather weights — CV_32FC1, _frameH rows × _frameW cols.
    // weight(x,y) = clamp(min(min(x,W-1-x), min(y,H-1-y)) / FEATHER_WIDTH, 0, 1)
    cv::Mat _weightMap;

    mutable std::shared_mutex _canvasMutex;
    std::unordered_map<TileKey, std::unique_ptr<Tile>, TileKeyHash> _tiles;

    bool  _empty = true;
    float _minX  = 0.f, _minY = 0.f, _maxX = -1.f, _maxY = -1.f;

    // Blend one feather-band sub-region onto a tile.
    // Written pixels: weighted blend with _weightMap. Empty pixels: direct copy + mark written.
    // fSub is in frame-local coords; tSub is the corresponding tile-local rect.
    void blendRegion(const cv::Mat& frame, Tile* tile,
                     const cv::Rect& fSub, const cv::Rect& tSub);

    // Returns an existing tile, or loads it from disk / creates a fresh one.
    // Must be called under exclusive lock.
    Tile* getTile(int col, int row);

    // Evicts the LRU tile, flushing to disk if dirty. Must be under exclusive lock.
    void evictLRU();

    std::string tilePath(int col, int row) const;
    std::string maskPath(int col, int row) const;
};
