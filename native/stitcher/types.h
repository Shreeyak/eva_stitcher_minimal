#pragma once

#include <cstdint>
#include <cmath>

// ── Build constants ────────────────────────────────────────────────────────

constexpr int   NAV_FRAME_W           = 640;
constexpr int   NAV_FRAME_H           = 480;
constexpr int   CANVAS_FRAME_W        = 800;
constexpr int   CANVAS_FRAME_H        = 600;
constexpr int   TILE_SIZE             = 512;
constexpr int   MAX_CACHED_TILES      = 100;
constexpr int   FEATHER_WIDTH         = 80;      // 10% of CANVAS_FRAME_W
constexpr int   NAV_STATE_SIZE        = 19;

// ── Capture gating ─────────────────────────────────────────────────────────

constexpr int     MIN_CAPTURE_DISTANCE    = 160;           // canvas px (20% of frame width)
constexpr int64_t COOLDOWN_NS             = 200'000'000LL; // 200 ms
constexpr int64_t STABILITY_DURATION_NS   = 150'000'000LL; // 150 ms
constexpr float   VELOCITY_THRESHOLD      = 150.0f;        // canvas px/sec
constexpr float   SHARPNESS_THRESHOLD     = 0.15f;
constexpr float   SHARPNESS_NORMALIZER    = 1000.0f;
constexpr float   MIN_CONFIDENCE          = 0.08f;
constexpr float   DEADBAND_THRESHOLD      = 5.0f;          // canvas px/sec
constexpr float   ECC_MIN_SCORE           = 0.70f;
constexpr float   OVERLAP_REJECT_THRESHOLD = 0.99f;
constexpr float   VELOCITY_EMA_ALPHA      = 0.3f;
constexpr int     CANVAS_PREVIEW_MAX_DIM  = 1024;

// ── Enums ──────────────────────────────────────────────────────────────────

enum class TrackingState : int {
    INIT       = 0,
    TRACKING   = 1,
    UNCERTAIN  = 2,
    LOST       = 3,
};

// ── Core structs ───────────────────────────────────────────────────────────

struct Pose {
    float x = 0.0f;
    float y = 0.0f;
};

struct NavigationState {
    TrackingState trackingState = TrackingState::INIT;
    float poseX         = 0.0f;
    float poseY         = 0.0f;
    float velocityX     = 0.0f;
    float velocityY     = 0.0f;
    float speed         = 0.0f;
    float lastConfidence = 0.0f;
    float overlapRatio  = 0.0f;
    int   frameCount    = 0;
    int   framesCaptured = 0;
    bool  captureReady  = false;
    float canvasMinX    = 0.0f;
    float canvasMinY    = 0.0f;
    float canvasMaxX    = -1.0f; // minX > maxX signals empty canvas
    float canvasMaxY    = -1.0f;
    float sharpness     = 0.0f;
    float analysisTimeMs  = 0.0f;
    float compositeTimeMs = 0.0f;
    float quality       = 0.0f;

    void toFloatArray(float* out) const {
        out[0]  = static_cast<float>(static_cast<int>(trackingState));
        out[1]  = poseX;
        out[2]  = poseY;
        out[3]  = velocityX;
        out[4]  = velocityY;
        out[5]  = speed;
        out[6]  = lastConfidence;
        out[7]  = overlapRatio;
        out[8]  = static_cast<float>(frameCount);
        out[9]  = static_cast<float>(framesCaptured);
        out[10] = captureReady ? 1.0f : 0.0f;
        out[11] = canvasMinX;
        out[12] = canvasMinY;
        out[13] = canvasMaxX;
        out[14] = canvasMaxY;
        out[15] = sharpness;
        out[16] = analysisTimeMs;
        out[17] = compositeTimeMs;
        out[18] = quality;
    }
};
