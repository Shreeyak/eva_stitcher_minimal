#include <jni.h>
#include <android/log.h>
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

#define TAG "EvaStitcher"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Convert a CameraX YUV_420_888 ImageProxy to a BGR cv::Mat.
 *
 * YUV_420_888 planes may have non-contiguous strides, so we copy row-by-row.
 * The UV planes are assembled into a NV21-style interleaved buffer for
 * cv::cvtColor(COLOR_YUV2BGR_NV21).
 */
static cv::Mat yuv420ToBgr(
    const uint8_t *yBuf, int yRowStride,
    const uint8_t *uBuf,
    const uint8_t *vBuf, int uvRowStride, int uvPixelStride,
    int width, int height)
{
    // Y plane (row-by-row copy to handle stride padding)
    cv::Mat yMat(height, width, CV_8UC1);
    for (int row = 0; row < height; ++row)
    {
        memcpy(yMat.ptr(row), yBuf + row * yRowStride, width);
    }

    // Build interleaved NV21 UV plane (V first, then U)
    const int uvHeight = height / 2;
    const int uvWidth = width / 2;
    cv::Mat uvMat(uvHeight, uvWidth, CV_8UC2);
    for (int row = 0; row < uvHeight; ++row)
    {
        for (int col = 0; col < uvWidth; ++col)
        {
            int offset = row * uvRowStride + col * uvPixelStride;
            uvMat.at<cv::Vec2b>(row, col) = {
                vBuf[offset], // V (NV21 order)
                uBuf[offset]  // U
            };
        }
    }

    // Assemble full NV21 buffer: [Y rows][UV interleaved rows]
    cv::Mat nv21(height + uvHeight, width, CV_8UC1);
    yMat.copyTo(nv21.rowRange(0, height));
    cv::Mat uvFlat = uvMat.reshape(1, uvHeight);
    uvFlat.copyTo(nv21.rowRange(height, height + uvHeight));

    cv::Mat bgr;
    cv::cvtColor(nv21, bgr, cv::COLOR_YUV2BGR_NV21);
    return bgr;
}

// ── JNI entry points ─────────────────────────────────────────────────────────

extern "C"
{

    /**
     * Process one YUV_420_888 analysis frame.
     *
     * Called from NativeStitcher.processFrame() on the camera analysis thread.
     * Phase 2 will replace the LOGI stub with the actual stitching pipeline.
     *
     * @param width          frame width  (e.g. 640)
     * @param height         frame height (e.g. 480)
     * @param yPlane         Y  plane ByteArray
     * @param uPlane         U  plane ByteArray
     * @param vPlane         V  plane ByteArray
     * @param yRowStride     row stride of the Y plane (bytes)
     * @param uvRowStride    row stride of the UV planes (bytes)
     * @param uvPixelStride  pixel stride of the UV planes (1 = planar, 2 = semi-planar)
     */
    /**
     * Returns mean Y luminance [0, 255] sampled at 1/16 density (every 4th row + col).
     * This is used by CameraManager for the custom auto-exposure PI controller.
     * The full stitching pipeline will be added in Phase 2.
     */
    JNIEXPORT jfloat JNICALL
    Java_com_example_eva_1minimal_1demo_NativeStitcher_processFrame(
        JNIEnv *env,
        jclass /*clazz*/,
        jint width,
        jint height,
        jbyteArray yPlane,
        jbyteArray uPlane,
        jbyteArray vPlane,
        jint yRowStride,
        jint uvRowStride,
        jint uvPixelStride)
    {
        // Pin Java byte arrays (no copy)
        jbyte *yBuf = env->GetByteArrayElements(yPlane, nullptr);
        jbyte *uBuf = env->GetByteArrayElements(uPlane, nullptr);
        jbyte *vBuf = env->GetByteArrayElements(vPlane, nullptr);

        // ── Mean Y luminance (sampled every 4th row + col for speed ~0.05ms) ─────
        long sum = 0;
        int count = 0;
        constexpr int kSampleStride = 4;
        for (int row = 0; row < height; row += kSampleStride)
        {
            for (int col = 0; col < width; col += kSampleStride)
            {
                sum += static_cast<uint8_t>(yBuf[row * yRowStride + col]);
                count++;
            }
        }
        const float meanY = (count > 0) ? static_cast<float>(sum) / count : 128.0f;

        // ── YUV → BGR ────────────────────────────────────────────────────────────
        cv::Mat bgr = yuv420ToBgr(
            reinterpret_cast<uint8_t *>(yBuf), yRowStride,
            reinterpret_cast<uint8_t *>(uBuf),
            reinterpret_cast<uint8_t *>(vBuf), uvRowStride, uvPixelStride,
            static_cast<int>(width), static_cast<int>(height));

        // Release without copying back (read-only access)
        env->ReleaseByteArrayElements(yPlane, yBuf, JNI_ABORT);
        env->ReleaseByteArrayElements(uPlane, uBuf, JNI_ABORT);
        env->ReleaseByteArrayElements(vPlane, vBuf, JNI_ABORT);

        // ── TODO (Phase 2): pass bgr Mat into the stitching pipeline ─────────────
        //   1. Blur / motion rejection gate
        //   2. KLT sparse optical flow → RANSAC → similarity transform
        //   3. Two-stage pyramidal ECC refinement
        //   4. warpAffine onto TileGrid (256×256 + 32 px padding)
        //   5. Laplacian pyramid blend per tile
        //   6. Return rendered canvas region to Dart via MethodChannel / shared buf

        return static_cast<jfloat>(meanY);
    }

} // extern "C"
