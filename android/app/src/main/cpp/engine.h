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
    // Receives direct ByteBuffer pointers valid only during this call.
    void processAnalysisFrame(
        uint8_t* yPtr, uint8_t* uPtr, uint8_t* vPtr,
        int w, int h,
        int yStride, int uvStride, int uvPixelStride,
        int rotation, int64_t timestampNs);

    // Returns a snapshot of navigation state packed as float[19].
    void getNavigationState(float* out);

    // Returns JPEG-encoded canvas preview, up to maxDim×maxDim.
    // Returns empty vector if canvas is empty.
    std::vector<uint8_t> getCanvasPreview(int maxDim);

    void reset();
    void startScanning();
    void stopScanning();

    // ── Crop helpers (used by processAnalysisFrame) ────────────────────────

    // Copies the center CROP_RATIO×CROP_RATIO region of the Y plane into a
    // new CV_8UC1 Mat. Only center rows/cols are read.
    static cv::Mat cropY(
        const uint8_t* yPtr, int sensorW, int sensorH,
        int yStride, int cropW, int cropH);

    // Converts the center crop region from YUV_420_888 to a BGR cv::Mat.
    static cv::Mat cropYuvToBgr(
        const uint8_t* yPtr, const uint8_t* uPtr, const uint8_t* vPtr,
        int sensorW, int sensorH,
        int yStride, int uvStride, int uvPixelStride,
        int cropW, int cropH);

private:
    int _analysisW = 0;
    int _analysisH = 0;
    int _cropW = 0;
    int _cropH = 0;

    bool _scanningActive = false;
    bool _captureInProgress = false;
    bool _initialized = false;

    NavigationState _navState;

    std::unique_ptr<Navigation> _nav;
    std::unique_ptr<Canvas>     _canvas;

    std::mutex _stateMutex;   // protects _navState (write: analysis thread; read: Dart poll)

    static int roundEven(int v) { return v & ~1; }
};
