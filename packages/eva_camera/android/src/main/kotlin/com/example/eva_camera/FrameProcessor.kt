package com.example.eva_camera

import android.hardware.camera2.TotalCaptureResult
import java.nio.ByteBuffer

/**
 * Callback interface for processing RGBA_8888 analysis frames from CameraX.
 *
 * Register an implementation via [EvaCameraPlugin.setFrameProcessor] to receive
 * every analysis frame. The plugin copies the pixel buffer and closes the ImageProxy
 * before invoking this callback, so implementations run on a dedicated analysis
 * executor thread — never on the camera or main thread.
 */
interface FrameProcessor {
    /**
     * Process a single ImageAnalysis frame.
     *
     * [buf] is a heap-backed RGBA_8888 ByteBuffer valid for the duration of this call.
     * The ImageProxy has already been closed before this is invoked.
     *
     * @param captureResult The latest TotalCaptureResult, or null if not yet available.
     * @return 1.0f if the capture gate fired and a stitch ImageCapture should be triggered;
     *         0.0f otherwise.
     */
    fun processFrame(
        buf: ByteBuffer,
        w: Int,
        h: Int,
        stride: Int,
        rotation: Int,
        timestampNs: Long,
        captureResult: TotalCaptureResult? = null,
    ): Float
}
