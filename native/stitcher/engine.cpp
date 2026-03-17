#include "engine.h"

#include <android/log.h>
#include <chrono>

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

Engine::Engine()  = default;
Engine::~Engine() = default;

void Engine::init(int analysisW, int analysisH, const std::string& cacheDir) {
    _analysisW = analysisW;
    _analysisH = analysisH;

    _nav    = std::make_unique<Navigation>();
    _canvas = std::make_unique<Canvas>();

    _nav->init(CANVAS_FRAME_W, CANVAS_FRAME_H, NAV_FRAME_W, NAV_FRAME_H);
    _canvas->init(CANVAS_FRAME_W, CANVAS_FRAME_H, cacheDir);

    _scanningActive    = false;
    _captureInProgress = false;
    _initialized       = true;

    LOGI("initEngine: analysis=%dx%d navFrame=%dx%d navScale=%.3f cacheDir=%s",
         analysisW, analysisH, NAV_FRAME_W, NAV_FRAME_H,
         static_cast<float>(CANVAS_FRAME_W) / NAV_FRAME_W,
         cacheDir.c_str());
}

void Engine::processAnalysisFrame(
    const uint8_t* framePtr,
    int w, int h, int stride,
    int rotation, int64_t timestampNs)
{
    if (!_initialized) return;

    const int64_t t0 = nowMs();

    // ── Step 1: Extract G channel + downscale → 640×480 nav frame ─────────
    cv::Mat navFrame = extractGreenDownscale(framePtr, w, h, stride);

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

        // Downscale RGBA → 800×600 BGR canvas frame
        cv::Mat canvasFrame = downscaleFrame(framePtr, w, h, stride);

        Pose pose = _nav->getCurrentPose();
        _canvas->compositeFrame(canvasFrame, pose);
        _nav->onFrameCommitted();
        _captureInProgress = false;

        const int64_t commitMs = nowMs() - tCommit0;
        LOGI("processAnalysisFrame commit: totalMs=%lld", (long long)commitMs);

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

// ── RGBA frame helpers ─────────────────────────────────────────────────────

cv::Mat Engine::extractGreenDownscale(
    const uint8_t* framePtr, int w, int h, int stride)
{
    // Wrap RGBA data as a cv::Mat — zero copy (stride may exceed w*4 due to row padding)
    cv::Mat rgba(h, w, CV_8UC4, const_cast<uint8_t*>(framePtr), static_cast<size_t>(stride));

    // Extract G channel (index 1 in RGBA layout)
    cv::Mat green;
    cv::extractChannel(rgba, green, 1);

    // Downscale to fixed nav frame dimensions
    cv::Mat navFrame;
    cv::resize(green, navFrame, cv::Size(NAV_FRAME_W, NAV_FRAME_H), 0, 0, cv::INTER_LINEAR);
    return navFrame;
}

cv::Mat Engine::downscaleFrame(
    const uint8_t* framePtr, int w, int h, int stride)
{
    // Wrap RGBA data as a cv::Mat — zero copy
    cv::Mat rgba(h, w, CV_8UC4, const_cast<uint8_t*>(framePtr), static_cast<size_t>(stride));

    // Downscale to canvas frame size
    cv::Mat resized;
    cv::resize(rgba, resized, cv::Size(CANVAS_FRAME_W, CANVAS_FRAME_H), 0, 0, cv::INTER_LINEAR);

    // Convert RGBA → BGR for canvas tile format
    cv::Mat bgr;
    cv::cvtColor(resized, bgr, cv::COLOR_RGBA2BGR);
    return bgr;
}
