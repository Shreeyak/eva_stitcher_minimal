#pragma once

#include <vector>
#include <opencv2/core.hpp>

#include "types.h"

// Stub Canvas for Phase 1/2.
// Full implementation with tile cache and compositing is Phase 3.
class Canvas {
public:
    Canvas() = default;
    ~Canvas() = default;

    void init(int frameW, int frameH);

    // Composite one 800×600 BGR frame at the given canvas pose.
    void compositeFrame(const cv::Mat& frame, Pose pose);

    // Returns JPEG preview bytes, or empty if no frames committed.
    std::vector<uint8_t> renderPreview(int maxDim);

    // Returns ratio [0,1] of already-filled canvas area within the frame
    // footprint at the given pose. Returns 0.0 if canvas is empty.
    float getOverlapRatio(Pose pose) const;

    // Returns canvas bounding box. minX > maxX means empty.
    void getBounds(float& minX, float& minY, float& maxX, float& maxY) const;

    void reset();

private:
    int _frameW = 0;
    int _frameH = 0;

    // Very simple single-image accumulator for Phase 1/2.
    // Phase 3 replaces this with a tile-based LRU cache.
    cv::Mat _canvas;    // CV_8UC3, BGR
    cv::Mat _alpha;     // CV_8UC1, 0 = empty
    bool    _empty = true;

    float _minX = 0.0f, _minY = 0.0f, _maxX = -1.0f, _maxY = -1.0f;
};
