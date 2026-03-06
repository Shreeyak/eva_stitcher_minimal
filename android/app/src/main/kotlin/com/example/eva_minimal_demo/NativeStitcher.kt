package com.example.eva_minimal_demo

import android.util.Log

/**
 * JNI bridge to the native stitching library (libeva_stitcher.so).
 *
 * All methods are called on the camera analysis executor thread — no UI thread. Phase 2 will add
 * more entry points (e.g. getCanvasTile, reset, finalize).
 */
object NativeStitcher {

    private const val TAG = "NativeStitcher"

    init {
        try {
            System.loadLibrary("eva_stitcher")
            Log.i(TAG, "libeva_stitcher.so loaded")
        } catch (e: UnsatisfiedLinkError) {
            Log.e(TAG, "Failed to load libeva_stitcher.so: ${e.message}")
        }
    }

    /**
     * Process a single YUV_420_888 frame from CameraX ImageAnalysis.
     *
     * @param width frame width (e.g. 640)
     * @param height frame height (e.g. 480)
     * @param yPlane Y plane bytes
     * @param uPlane U plane bytes
     * @param vPlane V plane bytes
     * @param yRowStride row stride for the Y plane
     * @param uvRowStride row stride for the UV planes
     * @param uvPixelStride pixel stride for the UV planes
     * @return mean Y luminance [0, 255] sampled at 1/16 density — used for custom AE
     */
    @JvmStatic
    external fun processFrame(
            width: Int,
            height: Int,
            yPlane: ByteArray,
            uPlane: ByteArray,
            vPlane: ByteArray,
            yRowStride: Int,
            uvRowStride: Int,
            uvPixelStride: Int,
    ): Float
}
