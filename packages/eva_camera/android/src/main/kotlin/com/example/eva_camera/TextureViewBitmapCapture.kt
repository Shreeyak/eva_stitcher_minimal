package com.example.eva_camera

import android.graphics.Bitmap
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.TextureView
import androidx.camera.view.PreviewView

/**
 * ══════════════════════════════════════════════════════════════════════════════
 * METHOD 1: TextureView.getBitmap() — Simplest Full-Resolution GPU→CPU Readback
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * HOW IT WORKS:
 *   Each call to getBitmap() forces the GPU to:
 *     1. Finish all pending draw commands (pipeline stall)
 *     2. DMA-copy the framebuffer contents into the provided Bitmap's memory
 *   This call BLOCKS the calling thread for the full (stall + DMA) duration.
 *   At 4000×3000 RGBA (48 MB), expect 30–120ms per call depending on device.
 *
 * WHAT YOU GET:
 *   - True camera-resolution pixels (whatever resolution CameraX was configured with)
 *   - ARGB_8888 Bitmap — 4 bytes per pixel, pre-multiplied alpha
 *   - The frame is whatever was last rendered — may lag 1–2 frames behind real-time
 *
 * ── PREREQUISITES ────────────────────────────────────────────────────────────
 *
 *   The PreviewView MUST be set to COMPATIBLE mode BEFORE CameraX is bound.
 *   In PERFORMANCE mode (the default), PreviewView uses a SurfaceView which
 *   does NOT expose getBitmap(). Only TextureView (used in COMPATIBLE mode) does.
 *
 *     previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
 *     // ← set this BEFORE calling ProcessCameraProvider.bindToLifecycle()
 *
 * ── INTEGRATION STEPS ────────────────────────────────────────────────────────
 *
 * STEP 1 — Layout XML (no changes from a normal CameraX layout):
 *
 *   <androidx.camera.view.PreviewView
 *       android:id="@+id/previewView"
 *       android:layout_width="match_parent"
 *       android:layout_height="match_parent" />
 *
 * STEP 2 — In your Fragment/Activity (BEFORE binding CameraX):
 *
 *   previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
 *
 * STEP 3 — AFTER the camera is bound and the preview is running, instantiate:
 *
 *   val capture = TextureViewBitmapCapture(
 *       previewView    = previewView,
 *       captureWidth   = 4000,
 *       captureHeight  = 3000,
 *       targetFps      = 3f,
 *       callback = object : TextureViewBitmapCapture.FrameCallback {
 *           override fun onFrameReady(
 *               bitmap: Bitmap,
 *               profile: TextureViewBitmapCapture.BitmapFrameProfile
 *           ) {
 *               // ⚠️ Called on a background thread — NOT the main thread
 *               // ⚠️ bitmap is a SHARED pre-allocated buffer — do NOT hold a reference after this returns
 *               Log.d("ML", profile.summary())
 *               runMlInference(bitmap, bitmap.width, bitmap.height)
 *           }
 *       }
 *   )
 *
 * STEP 4 — In onDestroyView():
 *
 *   capture.stop()
 *
 * ── NOTES ────────────────────────────────────────────────────────────────────
 *
 *   - captureWidth / captureHeight should match the camera resolution you
 *     configured in Preview.Builder, NOT the on-screen display size.
 *   - The Bitmap is allocated once at construction — zero allocations per frame.
 *   - getBitmap() is synchronous and will block for 30–120ms at 4K.
 *     Always call on a background thread (this class does this for you).
 *   - If inference takes longer than (1000 / targetFps) ms, frames will be
 *     skipped, not queued — the next capture starts only after onFrameReady returns.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 */
class TextureViewBitmapCapture(
    private val previewView: PreviewView,
    private val captureWidth: Int = 4000,
    private val captureHeight: Int = 3000,
    private val targetFps: Float = 3f,
    private val callback: FrameCallback,
) {
    interface FrameCallback {
        /**
         * Fired on a background capture thread each time a bitmap is ready.
         *
         * The [bitmap] is a shared pre-allocated buffer — it is ONLY valid for the
         * duration of this call. Do NOT store a reference to it; copy pixels if needed.
         *
         * Format: ARGB_8888, top-left origin (standard Android/Bitmap convention).
         */
        fun onFrameReady(bitmap: Bitmap, profile: BitmapFrameProfile)
    }

    /**
     * Per-frame timing breakdown for Method 1.
     * All durations are in milliseconds (Float for sub-ms precision).
     */
    data class BitmapFrameProfile(
        val frameIndex: Int,
        val getBitmapMs: Float,
        val callbackMs: Float,
        val totalMs: Float,
        val achievedFps: Float,
    ) {
        fun summary(): String =
            "Frame#$frameIndex getBitmap=${getBitmapMs}ms cb=${callbackMs}ms " +
                "total=${totalMs}ms fps=${String.format("%.1f", achievedFps)}"
    }

    private val captureThread = HandlerThread("BitmapCapture").also { it.start() }
    private val captureHandler = Handler(captureThread.looper)

    // Pre-allocate the Bitmap once — no per-frame allocations
    private val bitmap = Bitmap.createBitmap(captureWidth, captureHeight, Bitmap.Config.ARGB_8888)

    private var frameIndex = 0
    private var prevFrameTimeNs = 0L
    private val intervalMs = (1000f / targetFps).toLong()

    @Volatile private var running = true

    init {
        scheduleCapture()
    }

    private fun scheduleCapture() {
        if (!running) return
        captureHandler.postDelayed({
            if (running) {
                captureFrame()
                scheduleCapture()
            }
        }, intervalMs)
    }

    private fun captureFrame() {
        val frameStart = System.nanoTime()

        val textureView = findTextureView(previewView) ?: run {
                Log.w(TAG, "No TextureView found in PreviewView — is COMPATIBLE mode set?")
                return
            }

        val getBitmapStart = System.nanoTime()
        val success = textureView.getBitmap(bitmap)
        val getBitmapMs = nsToMs(System.nanoTime() - getBitmapStart)

        if (!success) {
            Log.w(TAG, "getBitmap() returned false — preview not yet started?")
            return
        }

        val now = System.nanoTime()
        val achievedFps = if (prevFrameTimeNs > 0) 1e9f / (now - prevFrameTimeNs) else 0f
        prevFrameTimeNs = now

        val cbStart = System.nanoTime()
        val profileForCallback =
            BitmapFrameProfile(
                frameIndex = frameIndex,
                getBitmapMs = getBitmapMs,
                callbackMs = 0f,
                totalMs = 0f,
                achievedFps = achievedFps,
            )
        callback.onFrameReady(bitmap, profileForCallback)
        val cbMs = nsToMs(System.nanoTime() - cbStart)
        val totalMs = nsToMs(System.nanoTime() - frameStart)

        Log.d(TAG, profileForCallback.copy(callbackMs = cbMs, totalMs = totalMs).summary())
        frameIndex++
    }

    fun stop() {
        running = false
        captureHandler.removeCallbacksAndMessages(null)
        captureThread.quitSafely()
    }

    companion object {
        private const val TAG = "BitmapCapture"

        private fun nsToMs(ns: Long): Float = ns / 1_000_000f

        /** Recursively searches [root]'s view hierarchy for the first [TextureView]. */
        private fun findTextureView(root: android.view.View): TextureView? {
            if (root is TextureView) return root
            if (root is android.view.ViewGroup) {
                for (i in 0 until root.childCount) {
                    findTextureView(root.getChildAt(i))?.let { return it }
                }
            }
            return null
        }
    }
}
