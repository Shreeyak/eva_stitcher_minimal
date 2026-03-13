package com.example.eva_camera

import android.hardware.camera2.TotalCaptureResult
import androidx.camera.core.ImageProxy

/**
 * Callback interface for handling user-triggered photo captures.
 *
 * Register via [EvaCameraPlugin.setPhotoCaptureProcessor]. Called on the camera
 * executor thread.
 *
 * DO NOT call [ImageProxy.close] — [CameraManager] closes the proxy in a finally
 * block after [onPhotoCapture] returns.
 */
interface PhotoCaptureProcessor {
    /**
     * Called when a still image has been captured for photo-save flows.
     *
     * @param imageProxy Captured frame. Valid only during this call.
     * @param captureResult Camera2 metadata for this frame, or null if unavailable.
     */
    fun onPhotoCapture(
        imageProxy: ImageProxy,
        captureResult: TotalCaptureResult?,
    )
}
