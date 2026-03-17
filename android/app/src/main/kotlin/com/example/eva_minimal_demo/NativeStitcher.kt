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
     * [cacheDir] is a writable directory for evicted canvas tile PNGs; provided by
     * the host app so the engine stays context-free.
     * Must be called once after [startCamera] returns its resolved dimensions.
     */
    @JvmStatic
    external fun initEngine(analysisW: Int, analysisH: Int, cacheDir: String)

    /**
     * Process one RGBA8888 analysis frame.
     * The ByteBuffer must be direct (GetDirectBufferAddress — no copy).
     * The buffer is only valid during this call; do not hold a reference.
     */
    @JvmStatic
    external fun processAnalysisFrame(
        frameBuf: ByteBuffer,
        w: Int,
        h: Int,
        stride: Int,
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

    /**
     * Save all committed canvas tiles to the specified output directory.
     * Returns 0 on success, non-zero on error.
     */
    @JvmStatic
    external fun saveCanvasToDisk(outputDir: String): Int
}
