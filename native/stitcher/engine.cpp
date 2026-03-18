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
    _initialized       = true;

    LOGI("initEngine: analysis=%dx%d navFrame=%dx%d navScale=%.3f cacheDir=%s",
         analysisW, analysisH, NAV_FRAME_W, NAV_FRAME_H,
         static_cast<float>(CANVAS_FRAME_W) / NAV_FRAME_W,
         cacheDir.c_str());
}

bool Engine::processAnalysisFrame(
    const uint8_t* framePtr,
    int w, int h, int stride,
    int rotation, int64_t timestampNs)
{
    if (!_initialized) return false;

    const int64_t t0 = nowMs();

    // ── Step 1: Extract G channel + downscale → 640×480 nav frame ─────────
    cv::Mat navFrame = extractGreenDownscale(framePtr, w, h, stride);

    // Apply 180° rotation to align with canvas/preview orientation
    cv::Mat navFrameRotated;
    cv::rotate(navFrame, navFrameRotated, cv::ROTATE_180);

    // ── Step 2: Navigation (phase correlation, velocity, gating) ──────────
    const bool triggerCommit = _nav->processFrame(navFrameRotated, timestampNs, _scanningActive, _canvas.get());

    // ── Step 3: Pack NavigationState ──────────────────────────────────────
    // getBounds() acquires _canvasMutex (shared). We must NOT hold _stateMutex
    // at that point: the main thread may hold _canvasMutex (renderPreview) and
    // then call getNavigationState() which acquires _stateMutex — deadlock.
    // Safe order: query canvas bounds first, then lock _stateMutex to write.
    NavigationState snap = _nav->getState();
    snap.analysisTimeMs = static_cast<float>(nowMs() - t0);
    _canvas->getBounds(snap.canvasMinX, snap.canvasMinY,
                       snap.canvasMaxX, snap.canvasMaxY);
    {
        std::lock_guard<std::mutex> lock(_stateMutex);
        _navState = snap;
    }

    // ── Step 4: Gate fired — store pose and signal Kotlin to capture ───────
    if (triggerCommit) {
        _pendingCapturePose = _nav->getCurrentPose();
        LOGI("processAnalysisFrame gate fired: pose=(%.1f,%.1f) — awaiting capture",
             _pendingCapturePose.x, _pendingCapturePose.y);
        return true;
    }
    return false;
}

void Engine::processStitchFrame(
    const uint8_t* framePtr,
    int w, int h, int stride,
    int /*rotation*/, int64_t /*timestampNs*/)
{
    if (!_initialized) return;

    const int64_t t0 = nowMs();

    // Downscale 4K RGBA → 800×600 BGR, rotate 180° — same path as analysis stitch.
    cv::Mat canvasFrame = downscaleFrame(framePtr, w, h, stride);

    _canvas->compositeFrame(canvasFrame, _pendingCapturePose);
    _nav->onFrameCommitted();

    const int64_t compositeMs = nowMs() - t0;
    LOGI("processStitchFrame commit: src=%dx%d compositeMs=%lld",
         w, h, (long long)compositeMs);

    NavigationState snap = _nav->getState();
    snap.compositeTimeMs = static_cast<float>(compositeMs);
    _canvas->getBounds(snap.canvasMinX, snap.canvasMinY,
                       snap.canvasMaxX, snap.canvasMaxY);
    {
        std::lock_guard<std::mutex> lock(_stateMutex);
        _navState = snap;
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
    _pendingCapturePose = {};
    _scanningActive     = false;
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

    // Apply 180° clockwise rotation to match preview orientation
    cv::Mat rotated;
    cv::rotate(bgr, rotated, cv::ROTATE_180);
    return rotated;
}

int Engine::saveCanvasToDisk(const std::string& outputDir) {
    if (!_initialized || !_canvas) {
        LOGE("saveCanvasToDisk: engine not initialized");
        return -1;
    }

    return _canvas->saveAllTilesToDisk(outputDir);
}

int Engine::saveCanvasAsImage(const std::string& outputPath) {
    if (!_initialized || !_canvas) {
        LOGE("saveCanvasAsImage: engine not initialized");
        return -1;
    }

    return _canvas->saveCanvasAsImage(outputPath);
}
