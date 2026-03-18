#include "navigation.h"

#include <android/log.h>
#include <cmath>

#include <opencv2/imgproc.hpp>
#include <opencv2/video/tracking.hpp>

#include "canvas.h"

#define TAG "EvaNav"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── Init / reset ───────────────────────────────────────────────────────────

void Navigation::init(int canvasFrameW, int canvasFrameH, int navFrameW, int navFrameH) {
    _scale = static_cast<float>(canvasFrameW) / static_cast<float>(navFrameW);
    _navW  = navFrameW;
    _navH  = navFrameH;
    (void)canvasFrameH;
    LOGI("Navigation::init navFrame=%dx%d navScale=%.4f", navFrameW, navFrameH, _scale);
}

void Navigation::reset() {
    _prevFrame.release();
    _hanningReady   = false;
    _pose           = {};
    _lastCapturePose = {};
    _velocityX      = 0.0f;
    _velocityY      = 0.0f;
    _speed          = 0.0f;
    _trackingState  = TrackingState::INIT;
    _uncertainCount = 0;
    _frameCount     = 0;
    _framesCaptured = 0;
    _lastConfidence = 0.0f;
    _sharpness      = 0.0f;
    _quality        = 0.0f;
    _overlapRatio   = 0.0f;
    _captureInProgress = false;
    _lastCaptureTimeNs = 0;
    _stableStartTimeNs = 0;
    _wasMoving      = true;
    _lastTimestampNs = 0;
}

// ── Main processing ────────────────────────────────────────────────────────

bool Navigation::processFrame(const cv::Mat& navFrame, int64_t timestampNs,
                               bool scanningActive, Canvas* canvas)
{
    ++_frameCount;

    // ── Phase correlation ──────────────────────────────────────────────────
    double dx = 0.0, dy = 0.0, confidence = 0.0;
    if (!_prevFrame.empty()) {
        computePhaseCorr(_prevFrame, navFrame, dx, dy, confidence);
    }

    // Scale nav-frame pixels → canvas pixels
    const float cdx = static_cast<float>(dx) * _scale;
    const float cdy = static_cast<float>(dy) * _scale;

    // Accumulate pose (first frame: pose stays at 0,0; first correlation updates it)
    if (!_prevFrame.empty()) {
        _pose.x += cdx;
        _pose.y += cdy;
    }

    // Store current as previous for next frame
    navFrame.copyTo(_prevFrame);

    // ── Velocity EMA ──────────────────────────────────────────────────────
    updateVelocity(cdx, cdy, timestampNs);
    _lastTimestampNs = timestampNs;

    // ── Sharpness ─────────────────────────────────────────────────────────
    _sharpness = computeSharpness(navFrame);

    // ── Tracking FSM ──────────────────────────────────────────────────────
    updateTrackingState(confidence);
    _lastConfidence = static_cast<float>(confidence);

    // ── Overlap ratio from canvas ──────────────────────────────────────────
    _overlapRatio = canvas ? canvas->getOverlapRatio(_pose) : 0.0f;

    // ── Quality metric ────────────────────────────────────────────────────
    _quality = (_overlapRatio > 0.0f)
        ? std::cbrt(_lastConfidence * _sharpness * _overlapRatio)
        : 0.0f;

    // ── Capture gating ────────────────────────────────────────────────────
    GatingResult gate = evaluateGating(timestampNs, _overlapRatio, scanningActive);

    // Periodic debug log (every 30 frames)
    if (_frameCount % 30 == 0) {
        LOGI("frame=%d conf=%.3f speed=%.1f pose=(%.1f,%.1f) sharp=%.3f tracking=%d",
             _frameCount, _lastConfidence, _speed, _pose.x, _pose.y,
             _sharpness, static_cast<int>(_trackingState));
    }

    if (gate.captureReady) {
        const float dist = std::hypot(_pose.x - _lastCapturePose.x,
                                      _pose.y - _lastCapturePose.y);
        LOGI("captureGated TRIGGER quality=%.2f conf=%.3f sharp=%.3f overlap=%.3f speed=%.1f dist=%.1f/%d frames=%d",
             _quality, _lastConfidence, _sharpness, _overlapRatio,
             _speed, dist, MIN_CAPTURE_DISTANCE, _framesCaptured);
        _lastCaptureTimeNs = timestampNs;
        _lastCapturePose   = _pose;
        return true;
    }

    // Log blocked reason (throttled: every 10 frames)
    if (_frameCount % 10 == 0) {
        const float dist = std::hypot(_pose.x - _lastCapturePose.x,
                                      _pose.y - _lastCapturePose.y);
        LOGI("captureGated BLOCKED reason=%s conf=%.3f sharp=%.3f overlap=%.3f speed=%.1f dist=%.1f/%d frames=%d",
             gate.reason, _lastConfidence, _sharpness, _overlapRatio,
             _speed, dist, MIN_CAPTURE_DISTANCE, _framesCaptured);
    }

    return false;
}

void Navigation::onFrameCommitted() {
    ++_framesCaptured;
}

// ── State accessors ────────────────────────────────────────────────────────

NavigationState Navigation::getState() const {
    NavigationState s;
    s.trackingState   = _trackingState;
    s.poseX           = _pose.x;
    s.poseY           = _pose.y;
    s.velocityX       = _velocityX;
    s.velocityY       = _velocityY;
    s.speed           = _speed;
    s.lastConfidence  = _lastConfidence;
    s.overlapRatio    = _overlapRatio;
    s.frameCount      = _frameCount;
    s.framesCaptured  = _framesCaptured;
    s.captureReady    = false; // momentary signal, not stored
    s.sharpness       = _sharpness;
    s.quality         = _quality;
    // canvas bounds filled in by Engine after compositeFrame
    return s;
}

Pose Navigation::getCurrentPose() const {
    return _pose;
}

// ── Phase correlation ──────────────────────────────────────────────────────

void Navigation::computePhaseCorr(const cv::Mat& prev, const cv::Mat& curr,
                                   double& outDx, double& outDy, double& outConf)
{
    // Build Hanning window once (reuse across frames)
    if (!_hanningReady || _hanning.rows != prev.rows || _hanning.cols != prev.cols) {
        cv::createHanningWindow(_hanning, prev.size(), CV_64F);
        _hanningReady = true;
    }

    cv::Mat p, c;
    prev.convertTo(p, CV_64F);
    curr.convertTo(c, CV_64F);

    double conf = 0.0;
    cv::Point2d shift = cv::phaseCorrelate(p, c, _hanning, &conf);
    outDx   = -shift.x; // phaseCorrelate returns motion of curr relative to prev
    outDy   = -shift.y;
    outConf = conf;
}

// ── Sharpness ─────────────────────────────────────────────────────────────

float Navigation::computeSharpness(const cv::Mat& frame) {
    cv::Mat laplacian;
    cv::Laplacian(frame, laplacian, CV_16S);

    cv::Scalar mean, stddev;
    cv::meanStdDev(laplacian, mean, stddev);
    const double variance = stddev[0] * stddev[0];

    return std::min(1.0f, static_cast<float>(variance / SHARPNESS_NORMALIZER));
}

// ── Velocity EMA ──────────────────────────────────────────────────────────

void Navigation::updateVelocity(double dx, double dy, int64_t timestampNs) {
    float instVx = 0.0f, instVy = 0.0f;
    if (_lastTimestampNs > 0) {
        const double dtSec = static_cast<double>(timestampNs - _lastTimestampNs) * 1e-9;
        if (dtSec > 0.0) {
            instVx = static_cast<float>(dx / dtSec);
            instVy = static_cast<float>(dy / dtSec);
        }
    }

    // EMA filter
    _velocityX = VELOCITY_EMA_ALPHA * instVx + (1.0f - VELOCITY_EMA_ALPHA) * _velocityX;
    _velocityY = VELOCITY_EMA_ALPHA * instVy + (1.0f - VELOCITY_EMA_ALPHA) * _velocityY;

    _speed = std::hypot(_velocityX, _velocityY);

    // Deadband: snap to zero if below threshold
    if (_speed < DEADBAND_THRESHOLD) {
        _velocityX = 0.0f;
        _velocityY = 0.0f;
        _speed     = 0.0f;
    }

    // Update stable-start timer
    const bool moving = (_speed > 0.0f);
    if (moving && !_wasMoving) {
        _stableStartTimeNs = 0; // reset
    } else if (!moving && _wasMoving) {
        _stableStartTimeNs = timestampNs;
    }
    _wasMoving = moving;
}

// ── Tracking FSM ──────────────────────────────────────────────────────────

void Navigation::updateTrackingState(double confidence) {
    const bool good = (confidence > MIN_CONFIDENCE);

    switch (_trackingState) {
        case TrackingState::INIT:
            if (good) {
                _trackingState  = TrackingState::TRACKING;
                _uncertainCount = 0;
            }
            break;

        case TrackingState::TRACKING:
            if (!good) {
                _trackingState  = TrackingState::UNCERTAIN;
                _uncertainCount = 1;
            }
            break;

        case TrackingState::UNCERTAIN:
            if (good) {
                _trackingState  = TrackingState::TRACKING;
                _uncertainCount = 0;
            } else {
                ++_uncertainCount;
                if (_uncertainCount >= 5) {
                    _trackingState = TrackingState::LOST;
                }
            }
            break;

        case TrackingState::LOST:
            if (good) {
                _trackingState  = TrackingState::TRACKING;
                _uncertainCount = 0;
            }
            break;
    }
}

// ── Capture gating ────────────────────────────────────────────────────────

bool Navigation::isVelocityStable(int64_t timestampNs) const {
    if (_speed > 0.0f) return false;
    if (_stableStartTimeNs == 0) return false;
    return (timestampNs - _stableStartTimeNs) >= STABILITY_DURATION_NS;
}

GatingResult Navigation::evaluateGating(int64_t timestampNs,
                                          float overlapRatio,
                                          bool scanningActive) const
{
    if (!scanningActive)                              return {false, "not_scanning"};
    if (_trackingState != TrackingState::TRACKING)    return {false, "tracking_lost"};
    if (_captureInProgress) {
        // Auto-clear if the stitch frame never arrived (e.g. capture error).
        if (timestampNs - _lastCaptureTimeNs > 2'000'000'000LL) {
            _captureInProgress = false;
            LOGI("evaluateGating: captureInProgress timeout — resetting");
        } else {
            return {false, "in_progress"};
        }
    }
    if (_lastCaptureTimeNs > 0 &&
        (timestampNs - _lastCaptureTimeNs) < COOLDOWN_NS)
                                                      return {false, "cooldown"};
    if (!isVelocityStable(timestampNs))               return {false, "velocity_too_high"};
    if (_sharpness < SHARPNESS_THRESHOLD)             return {false, "sharpness_too_low"};

    if (_framesCaptured > 0) {
        const float dist = std::hypot(_pose.x - _lastCapturePose.x,
                                       _pose.y - _lastCapturePose.y);
        if (dist < MIN_CAPTURE_DISTANCE)              return {false, "distance_too_small"};
        if (overlapRatio > OVERLAP_REJECT_THRESHOLD)  return {false, "overlap_too_high"};
    }

    return {true, "ok"};
}
