/**
 * Method 1 — synchronous TextureView getBitmap() readback for ML inference.
 *
 * How it works:
 *   1. Requires [PreviewView] in [PreviewView.ImplementationMode.COMPATIBLE] (wraps TextureView).
 *      Set this on the PreviewView BEFORE binding CameraX.
 *   2. A dedicated background [HandlerThread] polls [PreviewView.getBitmap] at up to [targetFps].
 *   3. The returned Bitmap is always the same pre-allocated instance — no per-frame GC pressure.
 *
 * Caveats:
 *   - [PreviewView.getBitmap] blocks until the GL pipeline copies the frame: expect 10–40 ms/frame.
 *   - COMPATIBLE mode disables hardware surface transforms; preview may not auto-rotate.
 *   - Instantiate AFTER CameraX is bound and the preview is running, NOT before.
 *   - Always call [stop] in onDestroyView() / onDestroy() to release the background thread.
 *   - Output bitmap dimensions are [captureWidth] × [captureHeight]; the raw PreviewView bitmap
 *     is scaled to fit. Do not deallocate or recycle the Bitmap passed to [FrameCallback].
 */
package com.example.eva_minimal_demo.readback

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import androidx.camera.view.PreviewView

class TextureViewBitmapCapture(
    private val previewView: PreviewView,
    private val captureWidth: Int,
    private val captureHeight: Int,
    targetFps: Float,
    private val callback: FrameCallback,
) {
    companion object {
        private const val TAG = "TextureBitmapCapture"
    }

    interface FrameCallback {
        fun onFrameReady(bitmap: Bitmap, profile: CaptureProfile)
    }

    data class CaptureProfile(
        val frameCount: Int,
        val lastCaptureMs: Long,
        val avgCaptureMs: Float,
        val achievedFps: Float,
    ) {
        fun summary(): String =
            "TextureCapture | frames=$frameCount | " +
                "lastMs=$lastCaptureMs | avgMs=${"%.1f".format(avgCaptureMs)} | " +
                "fps=${"%.2f".format(achievedFps)}"
    }

    private val intervalMs: Long = (1000f / targetFps).toLong().coerceAtLeast(1L)

    // Pre-allocated output bitmap — reused every frame to avoid heap churn.
    private val outputBitmap: Bitmap =
        Bitmap.createBitmap(captureWidth, captureHeight, Bitmap.Config.ARGB_8888)
    private val destRect = Rect(0, 0, captureWidth, captureHeight)

    private val thread = HandlerThread("TextureCapture").also { it.start() }
    private val handler = Handler(thread.looper)

    @Volatile private var running = true

    // Profiling state (accessed only on GL thread)
    private var frameCount = 0
    private var totalCaptureMs = 0L
    private var lastFrameWallMs = 0L

    init {
        scheduleNext(0L)
    }

    private fun scheduleNext(delayMs: Long) {
        handler.postDelayed(::captureFrame, delayMs)
    }

    private fun captureFrame() {
        if (!running) return
        val frameStart = SystemClock.elapsedRealtime()

        val rawBitmap = previewView.bitmap
        if (rawBitmap != null) {
            // Scale raw preview frame into the pre-allocated output bitmap.
            val canvas = Canvas(outputBitmap)
            canvas.drawBitmap(rawBitmap, null, destRect, null)
            rawBitmap.recycle()

            val captureMs = SystemClock.elapsedRealtime() - frameStart
            frameCount++
            totalCaptureMs += captureMs

            val now = SystemClock.elapsedRealtime()
            val achievedFps = if (lastFrameWallMs > 0L) 1000f / (now - lastFrameWallMs) else 0f
            lastFrameWallMs = now

            val profile =
                CaptureProfile(
                    frameCount = frameCount,
                    lastCaptureMs = captureMs,
                    avgCaptureMs = totalCaptureMs.toFloat() / frameCount,
                    achievedFps = achievedFps,
                )
            Log.d(TAG, profile.summary())
            callback.onFrameReady(outputBitmap, profile)
        } else {
            Log.w(TAG, "getBitmap() returned null — preview not ready yet")
        }

        val elapsed = SystemClock.elapsedRealtime() - frameStart
        val nextDelay = (intervalMs - elapsed).coerceAtLeast(0L)
        if (running) scheduleNext(nextDelay)
    }

    fun stop() {
        running = false
        handler.removeCallbacksAndMessages(null)
        thread.quitSafely()
        outputBitmap.recycle()
    }
}
