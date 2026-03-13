package com.example.eva_camera

import android.hardware.camera2.TotalCaptureResult
import androidx.camera.core.ImageProxy

/**
 * Callback interface for processing still-capture images from CameraX [ImageCapture].
 *
 * Register an implementation via [EvaCameraPlugin.setStillCaptureProcessor]. Called on the
 * camera executor thread — never on the main/UI thread.
 *
 * The implementation decides what to do with the frame:
 * - Access [ImageProxy.getPlanes] (zero-copy [java.nio.ByteBuffer] into camera memory)
 * - Convert to ARGB via [androidx.camera.core.ImageProxy.toBitmap] for blending
 * - Save to disk via [StillFrameSaver.saveToMediaStore]
 *
 * The implementation is responsible for calling [ImageProxy.close] when done.
 * Check [ImageProxy.getFormat] to distinguish YUV_420_888 from JPEG.
 */
interface StillCaptureProcessor {
    /**
     * Called when a still image has been captured.
     *
     * @param imageProxy The captured frame. Must call [ImageProxy.close] when done.
     *   Format is [android.graphics.ImageFormat.YUV_420_888] or [android.graphics.ImageFormat.JPEG].
     * @param captureResult Camera2 capture metadata for this frame, or null if unavailable.
     */
    fun onStillCapture(
        imageProxy: ImageProxy,
        captureResult: TotalCaptureResult?,
    )
}
