#pragma once

#include <cstdint>
#include <opencv2/core.hpp>

#include "types.h"

class Canvas;

struct GatingResult {
    bool captureReady;
    const char* reason; // string literal — no allocation
};

class Navigation {
public:
    Navigation() = default;
    ~Navigation() = default;

    // Call once before processing frames.
    void init(int canvasFrameW, int canvasFrameH, int navFrameW, int navFrameH);

    // Process one nav frame. Returns true when capture gating passes.
    // canvas is used only for overlap ratio query.
    bool processFrame(const cv::Mat& navFrame, int64_t timestampNs,
                      bool scanningActive, Canvas* canvas);

    // Call after a stitch commit completes.
    void onFrameCommitted();

    // Returns a copy of the last packed state.
    NavigationState getState() const;

    // Returns current predicted pose (thread-safe snapshot).
    Pose getCurrentPose() const;

    void reset();

private:
    // ── Config ────────────────────────────────────────────────────────────
    float _scale    = 1.0f; // navScale = canvasFrameW / navFrameW
    int   _navW     = 0;
    int   _navH     = 0;

    // ── Per-frame state ───────────────────────────────────────────────────
    cv::Mat  _prevFrame;
    cv::Mat  _hanning;
    bool     _hanningReady  = false;

    Pose     _pose;
    Pose     _lastCapturePose;
    float    _velocityX     = 0.0f;
    float    _velocityY     = 0.0f;
    float    _speed         = 0.0f;

    TrackingState _trackingState = TrackingState::INIT;
    int  _uncertainCount    = 0;
    int  _frameCount        = 0;
    int  _framesCaptured    = 0;

    float   _lastConfidence  = 0.0f;
    float   _sharpness       = 0.0f;
    float   _quality         = 0.0f;
    float   _overlapRatio    = 0.0f;
    bool    _captureInProgress = false;

    // ── Timing / gating ───────────────────────────────────────────────────
    int64_t _lastCaptureTimeNs  = 0;
    int64_t _stableStartTimeNs  = 0;
    bool    _wasMoving          = true; // start in "moving" state for stability timer

    // ── Phase correlation ──────────────────────────────────────────────────
    void computePhaseCorr(const cv::Mat& prev, const cv::Mat& curr,
                          double& outDx, double& outDy, double& outConf);

    // ── Velocity / sharpness ──────────────────────────────────────────────
    float computeSharpness(const cv::Mat& frame);
    void  updateVelocity(double dx, double dy, int64_t timestampNs);

    // ── Tracking FSM ──────────────────────────────────────────────────────
    void updateTrackingState(double confidence);

    // ── Gating ────────────────────────────────────────────────────────────
    GatingResult evaluateGating(int64_t timestampNs, float overlapRatio, bool scanningActive) const;

    // ── Internal helpers ───────────────────────────────────────────────────
    bool isVelocityStable(int64_t timestampNs) const;

    int64_t _lastTimestampNs = 0; // for dt computation
};
