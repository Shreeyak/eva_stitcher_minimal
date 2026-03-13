package com.example.eva_camera

import android.hardware.camera2.TotalCaptureResult
import androidx.camera.core.ImageProxy

/**
 * Callback interface for processing still-capture images from CameraX [ImageCapture].
 *
 * Register an implementation via [EvaCameraPlugin.setStillCaptureProcessor]. Called on the
 * camera executor thread — never on the main/UI thread.
 *
 * DO NOT call [ImageProxy.close] — [CameraManager] closes the proxy in a finally block after
 * [onStillCapture] returns, regardless of exceptions. The implementation must complete all
 * access to [ImageProxy] before returning; copy any data needed for background work first.
 *
 * Check [ImageProxy.getFormat] to distinguish YUV_420_888 from JPEG.
 */
interface StillCaptureProcessor {
    /**
     * Called when a still image has been captured.
     *
     * @param imageProxy The captured frame. Valid only for the duration of this call.
     *   Format is [android.graphics.ImageFormat.YUV_420_888] or [android.graphics.ImageFormat.JPEG].
     * @param captureResult Camera2 capture metadata for this frame, or null if unavailable.
     * @param save True when triggered by the user (Dart) requesting a photo save to disk.
     *   False when triggered internally by the stitcher — process but do not save.
     */
    fun onStillCapture(
        imageProxy: ImageProxy,
        captureResult: TotalCaptureResult?,
        save: Boolean,
    )
}
