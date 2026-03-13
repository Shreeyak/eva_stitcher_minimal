package com.example.eva_camera

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
    ): Float
}
