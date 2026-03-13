package com.example.eva_camera

import android.hardware.camera2.TotalCaptureResult

/**
 * Callback interface for processing YUV_420_888 analysis frames from CameraX.
 *
 * Register an implementation via [EvaCameraPlugin.setFrameProcessor] to receive
 * every analysis frame. The plugin calls [processFrame] on the camera executor
 * thread — never on the main/UI thread.
 */
interface FrameProcessor {
    /**
     * Process a single YUV_420_888 frame.
     *
     * @param captureResult The latest TotalCaptureResult from the capture pipeline,
     *        or null if not yet available. Useful for reading per-frame sensor metadata
     *        (exposure, ISO, focus distance, etc.).
     * @return a float value for the caller (e.g. mean luminance). The return
     *         value is currently unused by the plugin, but available for
     *         future expansion.
     */
    fun processFrame(
        width: Int,
        height: Int,
        yPlane: ByteArray,
        uPlane: ByteArray,
        vPlane: ByteArray,
        yRowStride: Int,
        uvRowStride: Int,
        uvPixelStride: Int,
        captureResult: TotalCaptureResult? = null,
    ): Float
}
