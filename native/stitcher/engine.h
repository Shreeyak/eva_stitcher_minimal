#pragma once

#include <jni.h>
#include <cstdint>
#include <mutex>
#include <opencv2/core.hpp>

#include "types.h"

class Navigation;
class Canvas;

class Engine {
public:
    Engine() = default;
    ~Engine() = default;

    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    // Called once after camera starts with the actual analysis resolution.
    void init(int analysisW, int analysisH);

    // Called every analysis frame (~30fps) on the CameraX executor thread.
    // framePtr is valid only during this call; do not hold a reference.
    void processAnalysisFrame(
        const uint8_t* framePtr,
        int w, int h, int stride,
        int rotation, int64_t timestampNs);

    // Returns a snapshot of navigation state packed as float[19].
    void getNavigationState(float* out);

    // Returns JPEG-encoded canvas preview, up to maxDim×maxDim.
    // Returns empty vector if canvas is empty.
    std::vector<uint8_t> getCanvasPreview(int maxDim);

    void reset();
    void startScanning();
    void stopScanning();

    // ── RGBA frame helpers ─────────────────────────────────────────────────

    // Extracts the G channel from RGBA8888 and downscales to NAV_FRAME_W×NAV_FRAME_H.
    // Returns a CV_8UC1 Mat suitable for phase-correlation navigation.
    static cv::Mat extractGreenDownscale(
        const uint8_t* framePtr, int w, int h, int stride);

    // Downscales RGBA8888 to CANVAS_FRAME_W×CANVAS_FRAME_H and converts to BGR.
    // Returns a CV_8UC3 Mat suitable for canvas compositing.
    static cv::Mat downscaleFrame(
        const uint8_t* framePtr, int w, int h, int stride);

private:
    int _analysisW = 0;
    int _analysisH = 0;

    bool _scanningActive = false;
    bool _captureInProgress = false;
    bool _initialized = false;

    NavigationState _navState;

    std::unique_ptr<Navigation> _nav;
    std::unique_ptr<Canvas>     _canvas;

    std::mutex _stateMutex;   // protects _navState (write: analysis thread; read: Dart poll)
};
