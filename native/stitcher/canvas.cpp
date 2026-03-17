#include "canvas.h"

#include <algorithm>
#include <chrono>
#include <sys/stat.h>

#include <android/log.h>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#define TAG "EvaCanvas"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  TAG, __VA_ARGS__)

static inline int64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// ── Init ───────────────────────────────────────────────────────────────────

void Canvas::init(int frameW, int frameH, const std::string& cacheDir) {
    std::unique_lock lock(_canvasMutex);

    _frameW   = frameW;
    _frameH   = frameH;
    _cacheDir = cacheDir;
    _empty    = true;
    _minX = 0.f; _minY = 0.f; _maxX = -1.f; _maxY = -1.f;
    _tiles.clear();

    mkdir(cacheDir.c_str(), 0755);

    // Build weight map with OpenCV mat ops:
    // weight(x,y) = clamp(min(min(x, W-1-x), min(y, H-1-y)) / FEATHER_WIDTH, 0, 1)
    cv::Mat hRamp(1, frameW, CV_32FC1);
    for (int x = 0; x < frameW; ++x)
        hRamp.at<float>(0, x) = static_cast<float>(std::min(x, frameW - 1 - x));

    cv::Mat vRamp(frameH, 1, CV_32FC1);
    for (int y = 0; y < frameH; ++y)
        vRamp.at<float>(y, 0) = static_cast<float>(std::min(y, frameH - 1 - y));

    cv::Mat hMat, vMat;
    cv::repeat(hRamp, frameH, 1, hMat);
    cv::repeat(vRamp, 1, frameW, vMat);
    cv::min(hMat, vMat, _weightMap);
    _weightMap.convertTo(_weightMap, CV_32FC1, 1.0f / FEATHER_WIDTH);
    cv::threshold(_weightMap, _weightMap, 1.0f, 1.0f, cv::THRESH_TRUNC);

    LOGI("Canvas::init frame=%dx%d featherWidth=%d interior=%dx%d cacheDir=%s",
         frameW, frameH, FEATHER_WIDTH,
         frameW - 2 * FEATHER_WIDTH, frameH - 2 * FEATHER_WIDTH,
         cacheDir.c_str());
}

// ── Tile management ────────────────────────────────────────────────────────

Tile* Canvas::getTile(int col, int row) {
    const TileKey key{col, row};
    auto it = _tiles.find(key);
    if (it != _tiles.end()) return it->second.get();

    auto tile = std::make_unique<Tile>();

    // Try to reload a previously evicted tile from disk
    cv::Mat px  = cv::imread(tilePath(col, row), cv::IMREAD_COLOR);
    cv::Mat msk = cv::imread(maskPath(col, row), cv::IMREAD_GRAYSCALE);

    if (!px.empty() && px.rows == TILE_SIZE && px.cols == TILE_SIZE) {
        tile->pixels = px;
        tile->mask   = msk.empty()
                       ? cv::Mat(TILE_SIZE, TILE_SIZE, CV_8UC1, cv::Scalar(255))
                       : msk;
        LOGI("getTile: reloaded (%d,%d) from disk", col, row);
    } else {
        tile->pixels = cv::Mat::zeros(TILE_SIZE, TILE_SIZE, CV_8UC3);
        tile->mask   = cv::Mat::zeros(TILE_SIZE, TILE_SIZE, CV_8UC1);
    }

    tile->dirty      = false;
    tile->lastAccess = nowMs();

    while (_tiles.size() >= static_cast<size_t>(MAX_CACHED_TILES))
        evictLRU();

    Tile* ptr = tile.get();
    _tiles.emplace(key, std::move(tile));
    return ptr;
}

void Canvas::evictLRU() {
    if (_tiles.empty()) return;

    auto oldest = _tiles.begin();
    for (auto it = std::next(oldest); it != _tiles.end(); ++it)
        if (it->second->lastAccess < oldest->second->lastAccess)
            oldest = it;

    const auto& [key, tile] = *oldest;
    if (tile->dirty) {
        if (!cv::imwrite(tilePath(key.col, key.row), tile->pixels))
            LOGW("evictLRU: failed to write tile (%d,%d)", key.col, key.row);
        if (!cv::imwrite(maskPath(key.col, key.row), tile->mask))
            LOGW("evictLRU: failed to write mask (%d,%d)", key.col, key.row);
    }

    LOGI("evictLRU: evicted (%d,%d) dirty=%d remaining=%zu",
         key.col, key.row, (int)tile->dirty, _tiles.size() - 1);
    _tiles.erase(oldest);
}

std::string Canvas::tilePath(int col, int row) const {
    return _cacheDir + "/tile_" + std::to_string(col) + "_" + std::to_string(row) + ".png";
}

std::string Canvas::maskPath(int col, int row) const {
    return _cacheDir + "/mask_" + std::to_string(col) + "_" + std::to_string(row) + ".png";
}

// ── blendRegion ────────────────────────────────────────────────────────────
//
// Composites one feather-band sub-region (where 0 < w < 1):
//   written pixels → tile*(1-w) + frame*w  (blend only; no interior pixels reach here)
//   empty pixels   → direct copy from frame, mark written
//
// fSub: rect in frame-local coords  |  tSub: matching rect in tile-local coords

void Canvas::blendRegion(const cv::Mat& frame, Tile* tile,
                          const cv::Rect& fSub, const cv::Rect& tSub) {
    if (fSub.width <= 0 || fSub.height <= 0) return;

    cv::Mat fp = frame(fSub);         // BGR view into frame (read-only)
    cv::Mat tp = tile->pixels(tSub);  // BGR view into tile  (read-write)
    cv::Mat tm = tile->mask(tSub);    // mask view into tile (read-write)

    // Classify pixels before any writes
    cv::Mat emptyMask, writtenMask;
    cv::compare(tm, 0, emptyMask,   cv::CMP_EQ);   // 255 where unwritten
    cv::compare(tm, 0, writtenMask, cv::CMP_GT);   // 255 where written

    // Blend written pixels with the feather weight map (float arithmetic)
    if (cv::countNonZero(writtenMask) > 0) {
        const cv::Mat wp = _weightMap(fSub);  // CV_32FC1, per-pixel weights

        cv::Mat tileF, frameF;
        tp.convertTo(tileF, CV_32FC3);
        fp.convertTo(frameF, CV_32FC3);

        // Expand 1-channel weight to 3-channel for BGR multiply
        const cv::Mat wArr[3] = {wp, wp, wp};
        cv::Mat w3;
        cv::merge(wArr, 3, w3);

        cv::Mat inv;
        cv::subtract(cv::Scalar::all(1.0f), w3, inv);  // (1 - w) per pixel

        cv::Mat tw, fw, blended;
        cv::multiply(tileF,  inv, tw);
        cv::multiply(frameF, w3,  fw);
        cv::add(tw, fw, blended);

        cv::Mat result;
        blended.convertTo(result, CV_8UC3);
        result.copyTo(tp, writtenMask);  // apply blend only to written pixels
    }

    // Direct copy for empty pixels (overrides any stale zero values)
    fp.copyTo(tp, emptyMask);
    tm.setTo(255, emptyMask);  // mark newly written
}

// ── compositeFrame ─────────────────────────────────────────────────────────

void Canvas::compositeFrame(const cv::Mat& frame, Pose pose) {
    const int64_t t0 = nowMs();
    std::unique_lock lock(_canvasMutex);
    const int64_t tBlend = nowMs();

    const int fx0 = static_cast<int>(std::round(pose.x));
    const int fy0 = static_cast<int>(std::round(pose.y));
    const cv::Rect frameRect(fx0, fy0, _frameW, _frameH);

    // Interior region in frame-local coords: w = 1 everywhere, no blend needed.
    const cv::Rect frameInterior(
        FEATHER_WIDTH, FEATHER_WIDTH,
        _frameW - 2 * FEATHER_WIDTH,
        _frameH - 2 * FEATHER_WIDTH);

    const int colMin = static_cast<int>(std::floor(static_cast<float>(fx0) / TILE_SIZE));
    const int colMax = static_cast<int>(std::floor(static_cast<float>(fx0 + _frameW - 1) / TILE_SIZE));
    const int rowMin = static_cast<int>(std::floor(static_cast<float>(fy0) / TILE_SIZE));
    const int rowMax = static_cast<int>(std::floor(static_cast<float>(fy0 + _frameH - 1) / TILE_SIZE));

    for (int tRow = rowMin; tRow <= rowMax; ++tRow) {
        for (int tCol = colMin; tCol <= colMax; ++tCol) {
            const cv::Rect tileCanvas(tCol * TILE_SIZE, tRow * TILE_SIZE, TILE_SIZE, TILE_SIZE);
            const cv::Rect overlap = frameRect & tileCanvas;
            if (overlap.empty()) continue;

            // Sub-rects in frame-local and tile-local coords
            const cv::Rect fSub(overlap.x - fx0,             overlap.y - fy0,
                                overlap.width, overlap.height);
            const cv::Rect tSub(overlap.x - tCol * TILE_SIZE, overlap.y - tRow * TILE_SIZE,
                                overlap.width, overlap.height);

            Tile* tile = getTile(tCol, tRow);
            tile->lastAccess = nowMs();

            // Translate a frame-local rect to its tile-local equivalent
            const int offX = tSub.x - fSub.x;
            const int offY = tSub.y - fSub.y;
            auto toTile = [&](const cv::Rect& r) -> cv::Rect {
                return {r.x + offX, r.y + offY, r.width, r.height};
            };

            // ── Interior (w = 1): direct overwrite, no blend ──────────────
            const cv::Rect iFrame = fSub & frameInterior;
            if (!iFrame.empty()) {
                frame(iFrame).copyTo(tile->pixels(toTile(iFrame)));
                tile->mask(toTile(iFrame)).setTo(255);
            }

            // ── Feather band (w < 1): blend written, direct-copy empty ────
            if (iFrame.empty()) {
                // Entire sub-region falls within the feather band
                blendRegion(frame, tile, fSub, tSub);
            } else {
                // Top strip
                if (iFrame.y > fSub.y) {
                    cv::Rect s(fSub.x, fSub.y, fSub.width, iFrame.y - fSub.y);
                    blendRegion(frame, tile, s, toTile(s));
                }
                // Bottom strip
                const int fy2 = iFrame.y + iFrame.height;
                if (fy2 < fSub.y + fSub.height) {
                    cv::Rect s(fSub.x, fy2, fSub.width, fSub.y + fSub.height - fy2);
                    blendRegion(frame, tile, s, toTile(s));
                }
                // Left strip (interior rows only, avoids corner double-counting)
                if (iFrame.x > fSub.x) {
                    cv::Rect s(fSub.x, iFrame.y, iFrame.x - fSub.x, iFrame.height);
                    blendRegion(frame, tile, s, toTile(s));
                }
                // Right strip (interior rows only)
                const int fx2 = iFrame.x + iFrame.width;
                if (fx2 < fSub.x + fSub.width) {
                    cv::Rect s(fx2, iFrame.y, fSub.x + fSub.width - fx2, iFrame.height);
                    blendRegion(frame, tile, s, toTile(s));
                }
            }

            tile->dirty = true;
        }
    }

    // Update canvas bounding box
    const float bx1 = pose.x + _frameW;
    const float by1 = pose.y + _frameH;
    if (_empty) {
        _minX = pose.x; _minY = pose.y; _maxX = bx1; _maxY = by1;
        _empty = false;
    } else {
        _minX = std::min(_minX, pose.x);  _minY = std::min(_minY, pose.y);
        _maxX = std::max(_maxX, bx1);     _maxY = std::max(_maxY, by1);
    }

    LOGI("compositeFrame: pose=(%.0f,%.0f) tiles=%zu blendMs=%lld totalMs=%lld",
         pose.x, pose.y, _tiles.size(),
         (long long)(nowMs() - tBlend), (long long)(nowMs() - t0));
}

// ── renderPreview ──────────────────────────────────────────────────────────

std::vector<uint8_t> Canvas::renderPreview(int maxDim) const {
    std::shared_lock lock(_canvasMutex);
    if (_empty) return {};

    const int cx0 = static_cast<int>(_minX);
    const int cy0 = static_cast<int>(_minY);
    const int cw  = static_cast<int>(std::ceil(_maxX)) - cx0;
    const int ch  = static_cast<int>(std::ceil(_maxY)) - cy0;
    if (cw <= 0 || ch <= 0) return {};

    cv::Mat assembled = cv::Mat::zeros(ch, cw, CV_8UC3);

    const int colMin = static_cast<int>(std::floor(static_cast<float>(cx0) / TILE_SIZE));
    const int colMax = static_cast<int>(std::floor(static_cast<float>(cx0 + cw - 1) / TILE_SIZE));
    const int rowMin = static_cast<int>(std::floor(static_cast<float>(cy0) / TILE_SIZE));
    const int rowMax = static_cast<int>(std::floor(static_cast<float>(cy0 + ch - 1) / TILE_SIZE));

    for (int tRow = rowMin; tRow <= rowMax; ++tRow) {
        for (int tCol = colMin; tCol <= colMax; ++tCol) {
            auto it = _tiles.find({tCol, tRow});
            if (it == _tiles.end()) continue;

            const Tile* tile = it->second.get();
            const cv::Rect tileCanvas(tCol * TILE_SIZE, tRow * TILE_SIZE, TILE_SIZE, TILE_SIZE);

            // Map tile canvas rect to assembled image coords (origin at canvas min)
            const cv::Rect destRect(tileCanvas.x - cx0, tileCanvas.y - cy0, TILE_SIZE, TILE_SIZE);
            const cv::Rect destClipped = destRect & cv::Rect(0, 0, cw, ch);
            if (destClipped.empty()) continue;

            const cv::Rect tileSub(destClipped.x - destRect.x,
                                   destClipped.y - destRect.y,
                                   destClipped.width, destClipped.height);

            // Copy only written pixels into the assembled image
            tile->pixels(tileSub).copyTo(assembled(destClipped), tile->mask(tileSub));
        }
    }

    cv::Mat preview;
    if (cw <= maxDim && ch <= maxDim) {
        preview = assembled;
    } else {
        const float scale = static_cast<float>(maxDim) / static_cast<float>(std::max(cw, ch));
        cv::resize(assembled, preview, cv::Size(), scale, scale, cv::INTER_LINEAR);
    }

    std::vector<uint8_t> jpeg;
    cv::imencode(".jpg", preview, jpeg, {cv::IMWRITE_JPEG_QUALITY, 85});

    LOGI("renderPreview: canvas=(%d,%d,%d,%d) cachedTiles=%zu preview=%dx%d jpeg=%zuB",
         cx0, cy0, cx0 + cw, cy0 + ch, _tiles.size(),
         preview.cols, preview.rows, jpeg.size());
    return jpeg;
}

// ── getOverlapRatio ────────────────────────────────────────────────────────

float Canvas::getOverlapRatio(Pose pose) const {
    if (_empty) return 0.0f;

    const int fx0 = static_cast<int>(std::round(pose.x));
    const int fy0 = static_cast<int>(std::round(pose.y));
    const cv::Rect frameRect(fx0, fy0, _frameW, _frameH);

    const int colMin = static_cast<int>(std::floor(static_cast<float>(fx0) / TILE_SIZE));
    const int colMax = static_cast<int>(std::floor(static_cast<float>(fx0 + _frameW - 1) / TILE_SIZE));
    const int rowMin = static_cast<int>(std::floor(static_cast<float>(fy0) / TILE_SIZE));
    const int rowMax = static_cast<int>(std::floor(static_cast<float>(fy0 + _frameH - 1) / TILE_SIZE));

    int covered = 0;
    for (int tRow = rowMin; tRow <= rowMax; ++tRow) {
        for (int tCol = colMin; tCol <= colMax; ++tCol) {
            auto it = _tiles.find({tCol, tRow});
            if (it == _tiles.end()) continue;

            const cv::Rect tileCanvas(tCol * TILE_SIZE, tRow * TILE_SIZE, TILE_SIZE, TILE_SIZE);
            const cv::Rect overlap = frameRect & tileCanvas;
            if (overlap.empty()) continue;

            const cv::Rect tSub(overlap.x - tCol * TILE_SIZE,
                                overlap.y - tRow * TILE_SIZE,
                                overlap.width, overlap.height);
            covered += cv::countNonZero(it->second->mask(tSub));
        }
    }

    return static_cast<float>(covered) / static_cast<float>(_frameW * _frameH);
}

// ── getBounds / reset ──────────────────────────────────────────────────────

void Canvas::getBounds(float& minX, float& minY, float& maxX, float& maxY) const {
    std::shared_lock lock(_canvasMutex);
    minX = _minX; minY = _minY; maxX = _maxX; maxY = _maxY;
}

void Canvas::reset() {
    std::unique_lock lock(_canvasMutex);
    _tiles.clear();
    _empty = true;
    _minX = 0.f; _minY = 0.f; _maxX = -1.f; _maxY = -1.f;
    LOGI("Canvas::reset");
}
