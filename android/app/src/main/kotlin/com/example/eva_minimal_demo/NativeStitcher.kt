package com.example.eva_minimal_demo

import android.util.Log
import java.nio.ByteBuffer

/**
 * JNI bridge to the native stitching library (libeva_stitcher.so).
 *
 * All analysis-frame methods are called on the CameraX executor thread.
 * State query methods (getNavigationState, getCanvasPreview) are called
 * from the main thread via MethodChannel.
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
     * Initialize the stitching engine with the actual analysis stream resolution.
     * Must be called once after [startCamera] returns its resolved dimensions.
     */
    @JvmStatic
    external fun initEngine(analysisW: Int, analysisH: Int)

    /**
     * Process one YUV_420_888 analysis frame.
     * All three ByteBuffers must be direct (GetDirectBufferAddress is used — no copy).
     * The buffers are only valid during this call; do not hold references.
     */
    @JvmStatic
    external fun processAnalysisFrame(
        yBuf: ByteBuffer,
        uBuf: ByteBuffer,
        vBuf: ByteBuffer,
        w: Int,
        h: Int,
        yStride: Int,
        uvStride: Int,
        uvPixelStride: Int,
        rotation: Int,
        timestampNs: Long,
    )

    /** Returns the 19-float navigation state snapshot. Thread-safe (mutex-protected). */
    @JvmStatic
    external fun getNavigationState(): FloatArray

    /**
     * Returns a JPEG-encoded canvas preview scaled to fit within [maxDim]×[maxDim].
     * Returns null if no frames have been committed yet.
     */
    @JvmStatic
    external fun getCanvasPreview(maxDim: Int): ByteArray?

    /** Reset engine state and clear the canvas. */
    @JvmStatic
    external fun resetEngine()

    /** Enable capture gating — frames start being committed to the canvas. */
    @JvmStatic
    external fun startScanning()

    /** Disable capture gating — navigation continues but no frames are committed. */
    @JvmStatic
    external fun stopScanning()
}
