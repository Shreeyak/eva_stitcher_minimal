#pragma once

#include <jni.h>
#include <cstdint>
#include <mutex>
#include <string>
#include <opencv2/core.hpp>

#include "types.h"

class Navigation;
class Canvas;

class Engine {
public:
    Engine();
    ~Engine();

    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    // Called once after camera starts with the actual analysis resolution.
    // cacheDir: writable directory used for evicted canvas tile PNGs.
    void init(int analysisW, int analysisH, const std::string& cacheDir);

    // Called every analysis frame (~30fps) on the CameraX executor thread.
    // framePtr is valid only during this call; do not hold a reference.
    // Returns true when the capture gate fires — Kotlin should call captureStitchFrame().
    bool processAnalysisFrame(
        const uint8_t* framePtr,
        int w, int h, int stride,
        int rotation, int64_t timestampNs);

    // Called once per stitch capture, on the CameraX executor thread.
    // framePtr is an RGBA8888 buffer from ImageCapture (same format as analysis).
    // Uses the pose stored when processAnalysisFrame last returned true.
    void processStitchFrame(
        const uint8_t* framePtr,
        int w, int h, int stride,
        int rotation, int64_t timestampNs);

    // Returns a snapshot of navigation state packed as float[19].
    void getNavigationState(float* out);

    // Returns JPEG-encoded canvas preview, up to maxDim×maxDim.
    // Returns empty vector if canvas is empty.
    std::vector<uint8_t> getCanvasPreview(int maxDim);

    // Saves the full-resolution canvas to Pictures/EvaWSI directory as a tiled PNG set.
    // Returns 0 on success, -1 on error (e.g., invalid directory, write failure).
    int saveCanvasToDisk(const std::string& outputDir);

    // Composites all tiles into a single PNG at outputPath, cropped to written bounds.
    // Returns 0 on success, -1 on error.
    int saveCanvasAsImage(const std::string& outputPath);

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
    bool _initialized = false;

    Pose _pendingCapturePose;   // pose at the moment the capture gate last fired

    NavigationState _navState;

    std::unique_ptr<Navigation> _nav;
    std::unique_ptr<Canvas>     _canvas;

    std::mutex _stateMutex;   // protects _navState (write: analysis thread; read: Dart poll)
};
