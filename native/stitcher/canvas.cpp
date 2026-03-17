#include "canvas.h"

#include <android/log.h>
#include <algorithm>

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#define TAG "EvaCanvas"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)

// Phase 1/2 stub canvas: 4096×4096 BGR backing store, origin at (2048,2048).
// Phase 3 will replace this with a proper tiled LRU cache.
static constexpr int CANVAS_SIZE = 4096;
static constexpr int ORIGIN      = 2048;

void Canvas::init(int frameW, int frameH) {
    _frameW = frameW;
    _frameH = frameH;
    _canvas = cv::Mat::zeros(CANVAS_SIZE, CANVAS_SIZE, CV_8UC3);
    _alpha  = cv::Mat::zeros(CANVAS_SIZE, CANVAS_SIZE, CV_8UC1);
    _empty  = true;
    _minX   = 0.0f; _minY = 0.0f; _maxX = -1.0f; _maxY = -1.0f;
    LOGI("Canvas::init frameSize=%dx%d", frameW, frameH);
}

void Canvas::compositeFrame(const cv::Mat& frame, Pose pose) {
    // Map canvas coords to backing store: pixel (cx,cy) → mat (cx+ORIGIN, cy+ORIGIN)
    const int x0 = static_cast<int>(pose.x) + ORIGIN;
    const int y0 = static_cast<int>(pose.y) + ORIGIN;

    const cv::Rect roi(x0, y0, _frameW, _frameH);
    const cv::Rect bounds(0, 0, CANVAS_SIZE, CANVAS_SIZE);
    const cv::Rect clipped = roi & bounds;
    if (clipped.empty()) return;

    // Sub-ROI of the frame that lands within canvas bounds
    const int fx = clipped.x - roi.x;
    const int fy = clipped.y - roi.y;
    const cv::Rect frameRoi(fx, fy, clipped.width, clipped.height);

    cv::Mat canvasPatch = _canvas(clipped);
    cv::Mat alphaPatch  = _alpha(clipped);
    const cv::Mat framePatch = frame(frameRoi);

    // Simple linear feather blend (direct write on first visit)
    for (int row = 0; row < clipped.height; ++row) {
        const uchar* fPtr = framePatch.ptr<uchar>(row);
        uchar* cPtr       = canvasPatch.ptr<uchar>(row);
        uchar* aPtr       = alphaPatch.ptr<uchar>(row);
        for (int col = 0; col < clipped.width; ++col) {
            if (aPtr[col] == 0) {
                // Empty pixel: direct write
                cPtr[col * 3 + 0] = fPtr[col * 3 + 0];
                cPtr[col * 3 + 1] = fPtr[col * 3 + 1];
                cPtr[col * 3 + 2] = fPtr[col * 3 + 2];
                aPtr[col] = 255;
            } else {
                // Blend with uniform 0.5 weight for Phase 1/2
                cPtr[col * 3 + 0] = static_cast<uchar>((cPtr[col * 3 + 0] + fPtr[col * 3 + 0]) / 2);
                cPtr[col * 3 + 1] = static_cast<uchar>((cPtr[col * 3 + 1] + fPtr[col * 3 + 1]) / 2);
                cPtr[col * 3 + 2] = static_cast<uchar>((cPtr[col * 3 + 2] + fPtr[col * 3 + 2]) / 2);
            }
        }
    }

    // Update bounding box in canvas coords
    const float fx0 = pose.x;
    const float fy0 = pose.y;
    const float fx1 = pose.x + _frameW;
    const float fy1 = pose.y + _frameH;
    if (_empty) {
        _minX = fx0; _minY = fy0; _maxX = fx1; _maxY = fy1;
        _empty = false;
    } else {
        _minX = std::min(_minX, fx0);
        _minY = std::min(_minY, fy0);
        _maxX = std::max(_maxX, fx1);
        _maxY = std::max(_maxY, fy1);
    }

    LOGI("compositeFrame pose=(%.0f,%.0f) bounds=(%.0f,%.0f,%.0f,%.0f)",
         pose.x, pose.y, _minX, _minY, _maxX, _maxY);
}

std::vector<uint8_t> Canvas::renderPreview(int maxDim) {
    if (_empty) return {};

    const int x0 = static_cast<int>(_minX) + ORIGIN;
    const int y0 = static_cast<int>(_minY) + ORIGIN;
    const int x1 = static_cast<int>(_maxX) + ORIGIN;
    const int y1 = static_cast<int>(_maxY) + ORIGIN;

    const cv::Rect roi(
        std::max(0, x0), std::max(0, y0),
        std::min(x1, CANVAS_SIZE) - std::max(0, x0),
        std::min(y1, CANVAS_SIZE) - std::max(0, y0));
    if (roi.empty()) return {};

    cv::Mat region = _canvas(roi);

    // Scale to fit within maxDim
    const int w = region.cols;
    const int h = region.rows;
    cv::Mat preview;
    if (w <= maxDim && h <= maxDim) {
        preview = region;
    } else {
        const float scale = static_cast<float>(maxDim) / std::max(w, h);
        cv::resize(region, preview, cv::Size(), scale, scale, cv::INTER_LINEAR);
    }

    std::vector<uint8_t> jpeg;
    cv::imencode(".jpg", preview, jpeg, {cv::IMWRITE_JPEG_QUALITY, 85});
    return jpeg;
}

float Canvas::getOverlapRatio(Pose pose) const {
    if (_empty) return 0.0f;

    const int x0 = static_cast<int>(pose.x) + ORIGIN;
    const int y0 = static_cast<int>(pose.y) + ORIGIN;
    const cv::Rect roi(x0, y0, _frameW, _frameH);
    const cv::Rect bounds(0, 0, CANVAS_SIZE, CANVAS_SIZE);
    const cv::Rect clipped = roi & bounds;
    if (clipped.empty()) return 0.0f;

    const cv::Mat alphaPatch = _alpha(clipped);
    const int total    = _frameW * _frameH;
    const int covered  = cv::countNonZero(alphaPatch);
    return static_cast<float>(covered) / static_cast<float>(total);
}

void Canvas::getBounds(float& minX, float& minY, float& maxX, float& maxY) const {
    minX = _minX; minY = _minY; maxX = _maxX; maxY = _maxY;
}

void Canvas::reset() {
    if (!_canvas.empty()) {
        _canvas.setTo(cv::Scalar::all(0));
        _alpha.setTo(cv::Scalar::all(0));
    }
    _empty = true;
    _minX = 0.0f; _minY = 0.0f; _maxX = -1.0f; _maxY = -1.0f;
}
