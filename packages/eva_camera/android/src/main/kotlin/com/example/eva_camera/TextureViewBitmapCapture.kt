package com.example.camera.capture

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
 * ── INTEGRATION STEPS ────────────────────────────────────────────────────────
 *
 * STEP 1 — Layout XML (no changes needed from a normal CameraX layout):
 *
 *   <androidx.camera.view.PreviewView
 *       android:id="@+id/previewView"
 *       android:layout_width="match_parent"
 *       android:layout_height="match_parent" />
 *
 * STEP 2 — In your Fragment/Activity, BEFORE binding CameraX, force TextureView mode:
 *
 *   // Must be set before the camera is bound — cannot be changed at runtime
 *   previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
 *
 * STEP 3 — Bind CameraX as normal:
 *
 *   val preview = Preview.Builder()
 *       .setTargetResolution(Size(4000, 3000))
 *       .build()
 *       .also { it.setSurfaceProvider(previewView.surfaceProvider) }
 *
 *   cameraProvider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview)
 *
 * STEP 4 — Create and start the capture AFTER CameraX is bound:
 *
 *   val capture = TextureViewBitmapCapture(
 *       previewView   = previewView,
 *       captureWidth  = 4000,
 *       captureHeight = 3000,
 *       targetFps     = 3f,
 *       callback      = object : TextureViewBitmapCapture.FrameCallback {
 *           override fun onFrameReady(bitmap: Bitmap, profile: TextureViewBitmapCapture.CaptureProfile) {
 *               // ⚠️  Called on a BACKGROUND thread — do NOT touch UI here
 *               // ⚠️  bitmap is REUSED every frame — copy it if you need to keep it
 *               Log.d("ML", profile.summary())
 *               runMlInference(bitmap)   // must complete before this function returns
 *           }
 *           override fun onFrameFailed(reason: String) {
 *               Log.w("Capture", "Failed: $reason")
 *           }
 *       }
 *   )
 *   capture.start()
 *
 * STEP 5 — Lifecycle cleanup:
 *
 *   override fun onDestroyView() {
 *       super.onDestroyView()
 *       capture.stop()
 *   }
 *
 * ── KNOWN LIMITATIONS ────────────────────────────────────────────────────────
 *
 *   • GPU pipeline stall: each call briefly blocks the GPU, which can cause
 *     the preview to stutter if captures are too frequent. Minimum recommended
 *     gap between captures is ~150ms (≤6fps). At 2–3fps this is imperceptible.
 *
 *   • Frame timing: you cannot select a specific camera frame. You get whatever
 *     was last composited when getBitmap() completes. At 15fps preview this
 *     means up to ~67ms of implicit latency above the readback cost.
 *
 *   • The bitmap is ARGB, not RGBA. Byte order is [A, R, G, B] per pixel
 *     when accessed via Bitmap.copyPixelsToBuffer(). Plan accordingly in ML.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 */
class TextureViewBitmapCapture(
    private val previewView: PreviewView,
    private val captureWidth: Int,
    private val captureHeight: Int,
    private val targetFps: Float = 3f,
    private val callback: FrameCallback
) {

    // ── Public API ────────────────────────────────────────────────────────────

    interface FrameCallback {
        /**
         * Invoked on a background thread each time a frame is captured.
         *
         * @param bitmap  The captured frame. This Bitmap object is REUSED on every call.
         *                If you need to keep the pixel data past this function's return,
         *                you must copy it: bitmap.copy(bitmap.config, false)
         *                or use Bitmap.copyPixelsToBuffer() into your own ByteBuffer.
         *
         * @param profile Timing breakdown for this specific capture. Log or display
         *                this to understand real-world performance on each device.
         */
        fun onFrameReady(bitmap: Bitmap, profile: CaptureProfile)

        /**
         * Called if a capture attempt could not produce a frame.
         * Common causes: TextureView not yet attached, surface not ready.
         */
        fun onFrameFailed(reason: String) {}
    }

    /**
     * Timing breakdown for a single getBitmap() call.
     * All times are in milliseconds.
     */
    data class CaptureProfile(
        /** Sequential index of this frame since start() was called. */
        val frameIndex: Int,

        /**
         * Total wall-clock time from the start of the getBitmap() call
         * to when the Bitmap was ready. This is (GPU stall + DMA + any overhead).
         * This is your PRIMARY performance indicator.
         */
        val totalReadbackMs: Float,

        /**
         * Time spent inside getBitmap() specifically.
         * Should be close to totalReadbackMs unless scheduling overhead is large.
         */
        val getBitmapMs: Float,

        /**
         * How long after the previous frame this frame was started (wall clock).
         * Use this to compute the actual inter-frame gap, which includes any
         * time your callback took (ML inference time).
         */
        val interFrameGapMs: Float,

        /**
         * Reciprocal of totalReadbackMs — the maximum fps achievable by readback
         * alone, ignoring ML inference time and scheduling overhead.
         */
        val readbackOnlyFps: Float,

        /**
         * Reciprocal of interFrameGapMs — the actual end-to-end fps being achieved,
         * including ML inference and scheduling. This is your TRUE throughput.
         */
        val endToEndFps: Float,

        /** Whether getBitmap() returned a non-null result. */
        val success: Boolean
    ) {
        /** Formatted one-line summary for Logcat. */
        fun summary(): String =
            "Frame#$frameIndex | total=${totalReadbackMs}ms getBitmap=${getBitmapMs}ms " +
            "gap=${interFrameGapMs}ms | readbackFps=${String.format("%.2f", readbackOnlyFps)} " +
            "endToEndFps=${String.format("%.2f", endToEndFps)} | success=$success"
    }

    // ── Internal state ────────────────────────────────────────────────────────

    // Dedicated background thread — getBitmap() blocks here, never on the UI thread
    private val captureThread = HandlerThread("BitmapCapture").also { it.start() }
    private val captureHandler = Handler(captureThread.looper)

    // Pre-allocated bitmap — allocated ONCE, reused on every frame
    // At 4000×3000 ARGB_8888 this is 48 MB. Never re-allocate inside the loop.
    private val reusedBitmap: Bitmap = Bitmap.createBitmap(
        captureWidth, captureHeight, Bitmap.Config.ARGB_8888
    )

    // Interval in ms derived from targetFps, with a floor to protect preview rendering
    // Below ~150ms between calls, GPU stalls become visible as preview micro-stutters
    private val targetIntervalMs: Long = maxOf(
        (1000f / targetFps).toLong(),
        MIN_INTER_FRAME_GAP_MS
    )

    @Volatile private var running = false
    private var frameIndex = 0
    private var lastFrameStartNs = 0L   // for inter-frame gap measurement

    // ── Public methods ────────────────────────────────────────────────────────

    /**
     * Begin the capture loop. Safe to call multiple times — subsequent calls are no-ops.
     * Call this AFTER CameraX has been bound and the preview is running.
     */
    fun start() {
        if (running) return
        running = true
        Log.i(TAG, "Starting capture: ${captureWidth}x${captureHeight} @ target ${targetFps}fps " +
                   "(interval ${targetIntervalMs}ms)")
        captureHandler.post(::doCapture)
    }

    /**
     * Stop the capture loop and release the background thread.
     * After calling stop(), this instance cannot be restarted — create a new one.
     */
    fun stop() {
        running = false
        captureThread.quitSafely()
        Log.i(TAG, "Capture stopped after $frameIndex frames")
    }

    // ── Capture loop ──────────────────────────────────────────────────────────

    private fun doCapture() {
        if (!running) return

        val frameStart = System.nanoTime()
        val interFrameGapMs = if (lastFrameStartNs > 0L) {
            nsToMs(frameStart - lastFrameStartNs)
        } else 0f
        lastFrameStartNs = frameStart

        // Find the TextureView that PreviewView wraps in COMPATIBLE mode.
        // PreviewView adds it as a direct child; we search all children defensively.
        val textureView = findTextureView()
        if (textureView == null) {
            val reason = "TextureView not found. " +
                "Ensure previewView.implementationMode = COMPATIBLE is set before binding."
            Log.w(TAG, reason)
            callback.onFrameFailed(reason)
            scheduleNext(frameStart)
            return
        }

        // ── THE CORE CALL ─────────────────────────────────────────────────────
        //
        // getBitmap(Bitmap) reuses the provided allocation — no heap pressure.
        //
        // Internally this:
        //   1. Acquires a lock on the TextureView's backing hardware canvas
        //   2. Issues a GPU draw command to render the current OES frame into the canvas
        //   3. STALLS until the GPU finishes (this is the expensive part)
        //   4. DMAs the result into reusedBitmap's pixel buffer
        //   5. Returns the same Bitmap reference (or null if the surface was lost)
        //
        // This BLOCKS captureThread. The UI thread is unaffected.
        // ─────────────────────────────────────────────────────────────────────
        val getBitmapStart = System.nanoTime()
        val result = textureView.getBitmap(reusedBitmap)
        val getBitmapMs = nsToMs(System.nanoTime() - getBitmapStart)

        val totalMs = nsToMs(System.nanoTime() - frameStart)

        val profile = CaptureProfile(
            frameIndex        = frameIndex++,
            totalReadbackMs   = totalMs,
            getBitmapMs       = getBitmapMs,
            interFrameGapMs   = interFrameGapMs,
            readbackOnlyFps   = if (totalMs > 0f) 1000f / totalMs else 0f,
            endToEndFps       = if (interFrameGapMs > 0f) 1000f / interFrameGapMs else 0f,
            success           = result != null
        )

        Log.v(TAG, profile.summary())

        if (result != null) {
            // Deliver to callback — this runs synchronously on captureThread.
            // If your ML inference is long, it will delay the next frame.
            // For heavy models, copy the bitmap and post ML work to a separate thread.
            callback.onFrameReady(reusedBitmap, profile)
        } else {
            callback.onFrameFailed("getBitmap() returned null — surface may be temporarily unavailable")
        }

        scheduleNext(frameStart)
    }

    private fun scheduleNext(frameStartNs: Long) {
        if (!running) return
        val elapsedMs = nsToMs(System.nanoTime() - frameStartNs).toLong()

        // Wait the remainder of our target interval.
        // If the callback (ML inference) took longer than the interval, fire immediately.
        // The extra MIN_INTER_FRAME_GAP_MS floor ensures there is always a small
        // breathing gap between captures, reducing sustained GPU stall pressure.
        val delayMs = maxOf(targetIntervalMs - elapsedMs, MIN_INTER_FRAME_GAP_MS)
        captureHandler.postDelayed(::doCapture, delayMs)
    }

    private fun findTextureView(): TextureView? {
        // PreviewView in COMPATIBLE mode contains exactly one TextureView child.
        // We iterate rather than cast directly in case the internal structure ever changes.
        for (i in 0 until previewView.childCount) {
            val child = previewView.getChildAt(i)
            if (child is TextureView) return child
        }
        return null
    }

    private fun nsToMs(ns: Long): Float = ns / 1_000_000f

    companion object {
        private const val TAG = "BitmapCapture"

        /**
         * Minimum milliseconds between capture attempts.
         * Below this, consecutive GPU stalls can cause visible preview micro-stutters.
         * At 150ms this caps you at ~6fps regardless of targetFps — raise with caution.
         */
        private const val MIN_INTER_FRAME_GAP_MS = 150L
    }
}
