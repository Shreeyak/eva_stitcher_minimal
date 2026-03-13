package com.example.eva_camera

import android.hardware.camera2.TotalCaptureResult
import androidx.camera.core.ImageProxy

/**
 * Callback interface for handling stitch-frame captures.
 *
 * Register via [EvaCameraPlugin.setStitchFrameProcessor]. Called on the camera
 * executor thread.
 *
 * DO NOT call [ImageProxy.close] — [CameraManager] closes the proxy in a finally
 * block after [onStitchFrame] returns.
 */
interface StitchFrameProcessor {
    /**
     * Called when a still image has been captured for stitching flows.
     *
     * @param imageProxy Captured frame. Valid only during this call.
     * @param captureResult Camera2 metadata for this frame, or null if unavailable.
     */
    fun onStitchFrame(
        imageProxy: ImageProxy,
        captureResult: TotalCaptureResult?,
    )
}
