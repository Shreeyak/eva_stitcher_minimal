package com.example.eva_camera

import android.hardware.camera2.TotalCaptureResult
import androidx.camera.core.ImageProxy

/**
 * Callback interface for processing YUV_420_888 analysis frames from CameraX.
 *
 * Register an implementation via [EvaCameraPlugin.setFrameProcessor] to receive
 * every analysis frame. The plugin calls [processFrame] on the camera executor
 * thread — never on the main/UI thread.
 */
interface FrameProcessor {
    /**
     * Process a single ImageAnalysis frame.
     *
     * [imageProxy] is valid only during this callback. The plugin closes it in
     * [CameraManager.processFrame] after this method returns.
     *
     * @param captureResult The latest TotalCaptureResult from the capture pipeline,
     *        or null if not yet available. Useful for reading per-frame sensor metadata
     *        (exposure, ISO, focus distance, etc.).
     * @return a float value for the caller (e.g. mean luminance). The return
     *         value is currently unused by the plugin, but available for
     *         future expansion.
     */
    fun processFrame(
        imageProxy: ImageProxy,
        captureResult: TotalCaptureResult? = null,
    ): Float
}
