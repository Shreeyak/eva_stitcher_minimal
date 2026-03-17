#include "engine.h"

#include <android/log.h>
#include <chrono>
#include <cstring>

#include <opencv2/imgproc.hpp>

#include "navigation.h"
#include "canvas.h"

#define TAG "EvaEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── Helpers ────────────────────────────────────────────────────────────────

static inline int64_t nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

// ── Engine public API ──────────────────────────────────────────────────────

void Engine::init(int analysisW, int analysisH) {
    _analysisW = analysisW;
    _analysisH = analysisH;

    _cropW = roundEven(static_cast<int>(analysisW * CROP_RATIO));
    _cropH = roundEven(static_cast<int>(analysisH * CROP_RATIO));

    _nav    = std::make_unique<Navigation>();
    _canvas = std::make_unique<Canvas>();

    _nav->init(CANVAS_FRAME_W, CANVAS_FRAME_H, _cropW, _cropH);
    _canvas->init(CANVAS_FRAME_W, CANVAS_FRAME_H);

    _scanningActive    = false;
    _captureInProgress = false;
    _initialized       = true;

    LOGI("initEngine: analysis=%dx%d crop=%dx%d navScale=%.3f",
         analysisW, analysisH, _cropW, _cropH,
         static_cast<float>(CANVAS_FRAME_W) / _cropW);
}

void Engine::processAnalysisFrame(
    uint8_t* yPtr, uint8_t* uPtr, uint8_t* vPtr,
    int w, int h,
    int yStride, int uvStride, int uvPixelStride,
    int rotation, int64_t timestampNs)
{
    if (!_initialized) return;

    const int64_t t0 = nowMs();

    // ── Step 1: Crop Y plane → nav frame ──────────────────────────────────
    cv::Mat navFrame = cropY(yPtr, w, h, yStride, _cropW, _cropH);

    // TODO(phase2-rotation): apply rotation if needed before nav
    (void)rotation;

    // ── Step 2: Navigation (phase correlation, velocity, gating) ──────────
    const bool triggerCommit = _nav->processFrame(navFrame, timestampNs, _scanningActive, _canvas.get());

    // ── Step 3: Pack NavigationState under mutex ───────────────────────────
    {
        std::lock_guard<std::mutex> lock(_stateMutex);
        _navState = _nav->getState();
        _navState.analysisTimeMs = static_cast<float>(nowMs() - t0);
    }

    // ── Step 4: Inline stitch commit when gating passes ───────────────────
    if (triggerCommit && !_captureInProgress) {
        _captureInProgress = true;

        const int64_t tCommit0 = nowMs();

        // Crop + convert analysis YUV → BGR
        cv::Mat bgrCrop = cropYuvToBgr(
            yPtr, uPtr, vPtr,
            w, h, yStride, uvStride, uvPixelStride,
            _cropW, _cropH);

        // Resize → 800×600 canvas frame
        cv::Mat canvasFrame;
        cv::resize(bgrCrop, canvasFrame, cv::Size(CANVAS_FRAME_W, CANVAS_FRAME_H));

        // Read pose from navigation
        Pose pose = _nav->getCurrentPose();

        // Composite onto canvas
        _canvas->compositeFrame(canvasFrame, pose);

        // Increment frame count
        _nav->onFrameCommitted();
        _captureInProgress = false;

        const int64_t commitMs = nowMs() - tCommit0;
        LOGI("processAnalysisFrame commit: totalMs=%lld", (long long)commitMs);

        // Update compositeTimeMs in state
        std::lock_guard<std::mutex> lock(_stateMutex);
        _navState.compositeTimeMs = static_cast<float>(commitMs);
        _navState.framesCaptured  = _nav->getState().framesCaptured;
    }
}

void Engine::getNavigationState(float* out) {
    std::lock_guard<std::mutex> lock(_stateMutex);
    _navState.toFloatArray(out);
}

std::vector<uint8_t> Engine::getCanvasPreview(int maxDim) {
    if (!_initialized) return {};
    return _canvas->renderPreview(maxDim);
}

void Engine::reset() {
    if (!_initialized) return;
    _nav->reset();
    _canvas->reset();
    _captureInProgress = false;
    _scanningActive    = false;
    std::lock_guard<std::mutex> lock(_stateMutex);
    _navState = NavigationState{};
}

void Engine::startScanning() {
    _scanningActive = true;
    LOGI("startScanning");
}

void Engine::stopScanning() {
    _scanningActive = false;
    LOGI("stopScanning");
}

// ── Crop helpers ───────────────────────────────────────────────────────────

cv::Mat Engine::cropY(
    const uint8_t* yPtr, int sensorW, int sensorH,
    int yStride, int cropW, int cropH)
{
    const int offsetX = (sensorW - cropW) / 2;
    const int offsetY = (sensorH - cropH) / 2;

    cv::Mat out(cropH, cropW, CV_8UC1);
    for (int row = 0; row < cropH; ++row) {
        const uint8_t* src = yPtr + (offsetY + row) * yStride + offsetX;
        std::memcpy(out.ptr(row), src, static_cast<size_t>(cropW));
    }
    return out;
}

cv::Mat Engine::cropYuvToBgr(
    const uint8_t* yPtr, const uint8_t* uPtr, const uint8_t* vPtr,
    int sensorW, int sensorH,
    int yStride, int uvStride, int uvPixelStride,
    int cropW, int cropH)
{
    const int offsetX = (sensorW - cropW) / 2;
    const int offsetY = (sensorH - cropH) / 2;

    // Build NV21 buffer for the cropped region: [Y rows][UV interleaved rows]
    const int uvCropH = cropH / 2;
    const int uvCropW = cropW / 2;

    cv::Mat nv21(cropH + uvCropH, cropW, CV_8UC1);

    // Copy Y rows
    for (int row = 0; row < cropH; ++row) {
        const uint8_t* src = yPtr + (offsetY + row) * yStride + offsetX;
        std::memcpy(nv21.ptr(row), src, static_cast<size_t>(cropW));
    }

    // Interleave V, U (NV21: V first) from UV planes
    uint8_t* uvDst = nv21.ptr(cropH);
    const int uvOffsetX = offsetX / 2;
    const int uvOffsetY = offsetY / 2;
    for (int row = 0; row < uvCropH; ++row) {
        for (int col = 0; col < uvCropW; ++col) {
            const int uvIdx = (uvOffsetY + row) * uvStride + (uvOffsetX + col) * uvPixelStride;
            *uvDst++ = vPtr[uvIdx]; // V
            *uvDst++ = uPtr[uvIdx]; // U
        }
    }

    cv::Mat bgr;
    cv::cvtColor(nv21, bgr, cv::COLOR_YUV2BGR_NV21);
    return bgr;
}
