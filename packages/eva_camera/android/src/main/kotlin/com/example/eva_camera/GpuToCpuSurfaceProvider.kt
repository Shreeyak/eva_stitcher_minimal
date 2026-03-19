package com.example.camera.capture

import android.graphics.SurfaceTexture
import android.opengl.*
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.Executor

/**
 * ══════════════════════════════════════════════════════════════════════════════
 * METHOD 2: Custom GL SurfaceProvider + Double-Buffered PBOs
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * HOW IT WORKS:
 *   This class owns a complete OpenGL ES 3.0 pipeline on a single dedicated
 *   GL thread. It intercepts the camera output at the GL level — before it
 *   ever reaches a PreviewView — giving you full control over both display
 *   and CPU readback.
 *
 *   Pipeline per camera frame:
 *
 *     Camera HAL
 *         │
 *         ▼
 *     OES Texture (GPU)          ← SurfaceTexture backed by GL_TEXTURE_EXTERNAL_OES
 *         │
 *         ├──► Render to Window Surface ──► eglSwapBuffers ──► SurfaceView (screen)
 *         │
 *         └──► Render to FBO (4000×3000) ──► glReadPixels (async, PBO)
 *                                                   │
 *                                       [next frame] glMapBufferRange
 *                                                   │
 *                                               ByteBuffer (CPU)
 *                                                   │
 *                                            onFrameReady callback
 *
 *   KEY: glReadPixels with a bound GL_PIXEL_PACK_BUFFER is ASYNCHRONOUS.
 *   It returns ~immediately, queuing a DMA from GPU→PBO memory.
 *   By the time we call glMapBufferRange on the NEXT frame, the GPU has had
 *   an entire frame's time to complete that DMA — so the map is usually instant.
 *   This is called "double-buffered PBO readback" and eliminates pipeline stalls.
 *
 * WHAT YOU GET:
 *   - True camera-sensor-resolution pixels (4000×3000 RGBA)
 *   - RGBA byte order: [R, G, B, A] per pixel (unlike Bitmap which is ARGB)
 *   - One frame of inherent latency (you always read the previous frame's PBO)
 *   - Zero GPU pipeline stall in steady state
 *   - Zero impact on preview rendering (runs on same GL thread, same context)
 *
 * ── PREREQUISITES ─────────────────────────────────────────────────────────────
 *
 *   In AndroidManifest.xml (PBOs require GLES 3.0):
 *     <uses-feature android:glEsVersion="0x00030000" android:required="true" />
 *
 *   In build.gradle:
 *     implementation "androidx.camera:camera-camera2:1.3.x"
 *     implementation "androidx.camera:camera-lifecycle:1.3.x"
 *
 * ── INTEGRATION STEPS ─────────────────────────────────────────────────────────
 *
 * STEP 1 — Layout XML (use SurfaceView, NOT PreviewView):
 *
 *   <SurfaceView
 *       android:id="@+id/cameraSurfaceView"
 *       android:layout_width="match_parent"
 *       android:layout_height="match_parent" />
 *
 * STEP 2 — In your Fragment/Activity:
 *
 *   private var glSurfaceProvider: GpuToCpuSurfaceProvider? = null
 *
 *   override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
 *       super.onViewCreated(view, savedInstanceState)
 *
 *       val surfaceView = view.findViewById<SurfaceView>(R.id.cameraSurfaceView)
 *
 *       surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
 *
 *           override fun surfaceCreated(holder: SurfaceHolder) {
 *               // Surface is ready — build the provider now
 *               glSurfaceProvider = GpuToCpuSurfaceProvider(
 *                   displaySurface  = holder.surface,
 *                   displayWidth    = surfaceView.width,
 *                   displayHeight   = surfaceView.height,
 *                   cameraWidth     = 4000,
 *                   cameraHeight    = 3000,
 *                   targetReadbackFps = 3f,
 *                   callback = object : GpuToCpuSurfaceProvider.FrameCallback {
 *
 *                       override fun onFrameReady(
 *                           buffer: ByteBuffer,
 *                           profile: GpuToCpuSurfaceProvider.GlFrameProfile
 *                       ) {
 *                           // ⚠️  Called on the GL thread
 *                           // ⚠️  buffer is a MAPPED PBO — valid ONLY during this call
 *                           // ⚠️  buffer is RGBA, NOT ARGB
 *                           // If ML needs the data after this returns, copy it first:
 *                           //   val copy = ByteBuffer.allocate(buffer.remaining())
 *                           //   copy.put(buffer); copy.rewind()
 *                           Log.d("ML", profile.summary())
 *                           runMlInference(buffer)
 *                       }
 *
 *                       override fun onProfileUpdate(profile: GpuToCpuSurfaceProvider.GlFrameProfile) {
 *                           // Optional: update a performance overlay on the UI thread
 *                           runOnUiThread { updatePerfOverlay(profile) }
 *                       }
 *                   }
 *               )
 *               bindCamera()
 *           }
 *
 *           override fun surfaceDestroyed(holder: SurfaceHolder) {
 *               glSurfaceProvider?.release()
 *               glSurfaceProvider = null
 *           }
 *
 *           override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {}
 *       })
 *   }
 *
 *   private fun bindCamera() {
 *       val cameraProviderFuture = ProcessCameraProvider.getInstance(requireContext())
 *       cameraProviderFuture.addListener({
 *           val cameraProvider = cameraProviderFuture.get()
 *           val preview = Preview.Builder()
 *               .setTargetResolution(Size(4000, 3000))
 *               .build()
 *
 *           // ← Pass OUR provider, NOT previewView.surfaceProvider
 *           preview.setSurfaceProvider(glSurfaceProvider!!)
 *
 *           cameraProvider.bindToLifecycle(
 *               viewLifecycleOwner,
 *               CameraSelector.DEFAULT_BACK_CAMERA,
 *               preview
 *           )
 *       }, ContextCompat.getMainExecutor(requireContext()))
 *   }
 *
 *   override fun onDestroyView() {
 *       super.onDestroyView()
 *       glSurfaceProvider?.release()
 *       glSurfaceProvider = null
 *   }
 *
 * ── NOTES ON BUFFER FORMAT ────────────────────────────────────────────────────
 *
 *   The ByteBuffer delivered to onFrameReady is:
 *     - Size:      4000 × 3000 × 4 = 48,000,000 bytes
 *     - Format:    RGBA, 8 bits per channel (GL_RGBA / GL_UNSIGNED_BYTE)
 *     - Byte order: [R0, G0, B0, A0, R1, G1, B1, A1, ...]
 *     - Row order:  bottom-left origin (OpenGL convention).
 *                   If your ML expects top-left origin, flip vertically.
 *     - Orientation: already corrected by the uTexMatrix shader uniform —
 *                    the frame is correctly oriented for the device's display.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 */
class GpuToCpuSurfaceProvider(
    private val displaySurface: Surface,
    private val displayWidth: Int,
    private val displayHeight: Int,
    private val cameraWidth: Int,
    private val cameraHeight: Int,
    private val targetReadbackFps: Float = 3f,
    private val callback: FrameCallback
) : Preview.SurfaceProvider {

    // ── Public types ──────────────────────────────────────────────────────────

    interface FrameCallback {
        /**
         * Fired on the GL thread each time a readback frame is ready.
         *
         * The [buffer] is a memory-mapped PBO — a direct pointer into GPU-accessible
         * memory. It is ONLY valid for the duration of this function call.
         * After this function returns, the buffer is unmapped and must not be accessed.
         *
         * Format: RGBA, 4 bytes/pixel, [cameraWidth × cameraHeight × 4] bytes total.
         * Row order: bottom-left (OpenGL convention). Flip vertically if needed.
         */
        fun onFrameReady(buffer: ByteBuffer, profile: GlFrameProfile)

        /**
         * Called on the GL thread every camera frame (not just readback frames).
         * Use this to drive a live performance overlay without waiting for readbacks.
         * Implementation is optional — default is a no-op.
         */
        fun onProfileUpdate(profile: GlFrameProfile) {}
    }

    /**
     * Complete per-frame timing breakdown.
     * All durations are in milliseconds (Float for sub-ms precision).
     */
    data class GlFrameProfile(
        /** Camera frame index since the pipeline started. Increments every frame. */
        val frameIndex: Int,

        /** How many CPU readback buffers have been delivered so far. */
        val readbackIndex: Int,

        /**
         * Time for SurfaceTexture.updateTexImage() + getTransformMatrix().
         * This latches the newest camera frame into the OES texture.
         * Typically 0.5–2ms.
         */
        val oesUpdateMs: Float,

        /**
         * Time to render the OES texture to the visible display window.
         * Includes the eglSwapBuffers() call (queue the buffer for display).
         * Typically 3–15ms.
         */
        val displayRenderMs: Float,

        /**
         * Time to render the OES texture to the full-resolution FBO.
         * This is what gets read back to CPU. Typically 10–40ms at 4K.
         */
        val fboRenderMs: Float,

        /**
         * Time for glReadPixels() with a bound PBO.
         * Should be near 0ms — this call is asynchronous with PBOs.
         * If this is consistently >5ms, something is wrong (maybe PBOs not allocated).
         */
        val pboKickoffMs: Float,

        /**
         * Time for glMapBufferRange() on the PREVIOUS frame's PBO.
         * If double-buffering is working correctly, the DMA will have finished
         * during the previous frame's render time, so this should be 0–5ms.
         * Consistently high values here mean the GPU can't complete a 48MB DMA
         * within one frame period — consider reducing camera resolution.
         */
        val pboMapMs: Float,

        /**
         * Wall-clock time your onFrameReady callback took to execute.
         * This is your ML inference time. If this is longer than targetReadbackInterval,
         * you will miss readback opportunities — consider a separate inference thread.
         */
        val callbackMs: Float,

        /**
         * Total wall-clock time for the entire frame from updateTexImage() start
         * to end of all readback work. Your main end-to-end latency indicator.
         */
        val totalPipelineMs: Float,

        /** Measured preview render rate (reciprocal of inter-frame gap). */
        val achievedPreviewFps: Float,

        /** Measured readback delivery rate (reciprocal of inter-readback gap). */
        val achievedReadbackFps: Float,

        /** True if a CPU buffer was delivered this frame (via onFrameReady). */
        val isReadbackFrame: Boolean
    ) {
        /** Single-line summary suitable for Logcat or an on-screen overlay. */
        fun summary(): String = buildString {
            append("Frame#$frameIndex ")
            if (isReadbackFrame) append("[READBACK#$readbackIndex] ")
            append("oes=${oesUpdateMs}ms disp=${displayRenderMs}ms fbo=${fboRenderMs}ms ")
            append("kick=${pboKickoffMs}ms map=${pboMapMs}ms cb=${callbackMs}ms | ")
            append("total=${totalPipelineMs}ms ")
            append("prevFps=${String.format("%.1f", achievedPreviewFps)} ")
            append("readFps=${String.format("%.1f", achievedReadbackFps)}")
        }
    }

    // ── GL Thread ─────────────────────────────────────────────────────────────
    //
    // ALL EGL and GLES calls MUST run on this thread.
    // Never call any gl* or EGL* function from another thread.

    private val glThread = HandlerThread("CameraGL-${instanceCounter++}").also { it.start() }
    private val glHandler = Handler(glThread.looper)
    private val glExecutor = Executor { command -> glHandler.post(command) }

    // ── EGL state ─────────────────────────────────────────────────────────────

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT

    /**
     * Window surface — backed by displaySurface (the SurfaceView's Surface).
     * We render the camera preview here and call eglSwapBuffers to show it.
     */
    private var eglWindowSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    /**
     * PBuffer surface — a tiny (1×1) offscreen surface used when we switch
     * context to do FBO/PBO work without disturbing the window surface's state.
     */
    private var eglPbuffer: EGLSurface = EGL14.EGL_NO_SURFACE

    // ── GL Object IDs ─────────────────────────────────────────────────────────

    /** GL_TEXTURE_EXTERNAL_OES — the camera writes into this each frame. */
    private var oesTextureId = 0

    /** Framebuffer Object — full-resolution offscreen render target for readback. */
    private var fboId = 0

    /** GL_TEXTURE_2D attached to the FBO as colour attachment 0. */
    private var fboTextureId = 0

    /** Compiled GLSL program: samples OES, outputs RGBA. */
    private var shaderProgram = 0

    // ── PBO double-buffer ─────────────────────────────────────────────────────
    //
    // Two PBOs are used in alternation:
    //
    //   Frame N:   kick glReadPixels into pboIds[writeIdx]  → DMA starts asynchronously
    //   Frame N+1: map  pboIds[readIdx] from Frame N        → DMA is done, data ready
    //              kick glReadPixels into pboIds[writeIdx]  → next DMA starts
    //
    //   writeIdx and readIdx are swapped each readback frame.

    private val pboIds = IntArray(2)
    private var pboWriteIdx = 0   // GPU writes into this PBO this frame
    private var pboReadIdx  = 1   // CPU reads from this PBO this frame (prev frame's data)

    /** 4000 × 3000 × 4 bytes RGBA = 48 MB per PBO. Two PBOs = 96 MB GPU-accessible memory. */
    private val pboByteSize: Long = cameraWidth.toLong() * cameraHeight.toLong() * 4L

    // ── Camera Surface / SurfaceTexture ───────────────────────────────────────

    /** Wraps oesTextureId. CameraX writes frames here. */
    private var surfaceTexture: SurfaceTexture? = null

    /** Updated every frame by SurfaceTexture.getTransformMatrix(). */
    private val oesTransformMatrix = FloatArray(16)

    // ── State tracking ────────────────────────────────────────────────────────

    private var frameIndex    = 0
    private var readbackIndex = 0

    /** Was a glReadPixels PBO kickoff issued last readback frame? */
    private var pboReadbackPending = false

    /** System.nanoTime() at the start of the previous frame (for fps calculation). */
    private var prevFrameStartNs = 0L

    /** System.nanoTime() at the start of the previous readback (for readback fps). */
    private var prevReadbackStartNs = 0L

    // Throttle readbacks to targetReadbackFps
    private val readbackIntervalMs = (1000f / targetReadbackFps).toLong()
    private var lastReadbackTriggerMs = 0L

    // ── Preview.SurfaceProvider ───────────────────────────────────────────────

    /**
     * Called by CameraX when it needs a Surface to deliver camera frames to.
     * We respond with a Surface backed by our OES texture — keeping the entire
     * pipeline inside our own GL context.
     */
    override fun onSurfaceRequested(request: SurfaceRequest) {
        glHandler.post {
            // 1. Set up EGL context, window surface, and pbuffer
            initEgl()

            // 2. Set up GL objects (textures, FBO, PBOs, shaders)
            initGl()

            // 3. Create SurfaceTexture backed by our OES texture
            //    CameraX will write camera frames into this
            val st = SurfaceTexture(oesTextureId).also {
                it.setDefaultBufferSize(cameraWidth, cameraHeight)
                // Frame-available listener fires on glHandler — keeps everything on GL thread
                it.setOnFrameAvailableListener({ st -> processFrame(st) }, glHandler)
            }
            surfaceTexture = st

            val cameraSurface = Surface(st)

            // 4. Hand the surface to CameraX
            //    When CameraX is done (camera closed / use case unbound), the result
            //    lambda fires — we clean up there.
            request.provideSurface(cameraSurface, glExecutor) { _ ->
                Log.d(TAG, "CameraX released our surface — cleaning up GL resources")
                cameraSurface.release()
                st.release()
                releaseGl()
                releaseEgl()
                glThread.quitSafely()
            }

            Log.i(TAG, "Surface provided to CameraX: ${cameraWidth}x${cameraHeight}, " +
                       "pboSize=${pboByteSize / 1024 / 1024}MB × 2")
        }
    }

    // ── Per-frame pipeline ────────────────────────────────────────────────────

    private fun processFrame(st: SurfaceTexture) {
        val frameStart = System.nanoTime()

        // ── Stage 1: Latch the newest camera frame ────────────────────────────
        //
        // updateTexImage() pulls the latest buffer from the SurfaceTexture's
        // queue and binds it to oesTextureId. Must be called before rendering.
        //
        // getTransformMatrix() retrieves a 4×4 matrix that corrects for:
        //   - Camera sensor physical orientation (e.g. 90° rotated on most phones)
        //   - Vertical flip (OpenGL is bottom-left origin, cameras are top-left)
        //   - Any crop from the camera HAL
        // This matrix MUST be applied in the vertex shader as uTexMatrix.
        // Calling it after updateTexImage() is mandatory — it can change per frame.

        val oesStart = System.nanoTime()
        st.updateTexImage()
        st.getTransformMatrix(oesTransformMatrix)
        val oesMs = nsToMs(System.nanoTime() - oesStart)

        // ── Stage 2: Render OES → visible display window ──────────────────────
        //
        // Switch to the window EGL surface (backed by the SurfaceView) and
        // draw the OES texture at display resolution. eglSwapBuffers queues
        // the buffer for SurfaceFlinger to composite onto the screen.
        //
        // Note: displayWidth/displayHeight are the SurfaceView's on-screen pixels,
        // not the camera resolution. The GPU scales automatically.

        val displayStart = System.nanoTime()
        EGL14.eglMakeCurrent(eglDisplay, eglWindowSurface, eglWindowSurface, eglContext)
        GLES30.glViewport(0, 0, displayWidth, displayHeight)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        drawOesQuad(oesTransformMatrix)
        EGL14.eglSwapBuffers(eglDisplay, eglWindowSurface) // → screen
        val displayMs = nsToMs(System.nanoTime() - displayStart)

        // ── Stage 3: Map previous frame's PBO (if a readback was pending) ─────
        //
        // We do this BEFORE kicking the new readback so that:
        //   (a) The GPU has had a full frame's worth of time to complete the DMA
        //       that was kicked at the end of the previous readback frame.
        //   (b) The buffer we map is from the previous kick — still valid.
        //
        // glMapBufferRange with GL_MAP_READ_BIT will block if the DMA isn't done.
        // With correct double-buffering and a full frame gap, this should be ~0ms.

        var pboMapMs    = 0f
        var callbackMs  = 0f
        var isReadback  = false

        if (pboReadbackPending) {
            // Switch to pbuffer context for FBO/PBO work
            EGL14.eglMakeCurrent(eglDisplay, eglPbuffer, eglPbuffer, eglContext)

            val mapStart = System.nanoTime()
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pboIds[pboReadIdx])

            // This call maps pboIds[pboReadIdx] into CPU-accessible address space.
            // The returned ByteBuffer is a direct pointer into GPU driver memory.
            // ONLY valid until glUnmapBuffer is called below.
            val mappedBuffer = GLES30.glMapBufferRange(
                GLES30.GL_PIXEL_PACK_BUFFER,
                0,
                pboByteSize,
                GLES30.GL_MAP_READ_BIT   // read-only access from CPU
            ) as? ByteBuffer

            pboMapMs = nsToMs(System.nanoTime() - mapStart)

            if (mappedBuffer != null) {
                mappedBuffer.order(ByteOrder.nativeOrder())
                mappedBuffer.rewind()

                // Build the profile (callbackMs not yet known — will update after)
                val readFps = if (prevReadbackStartNs > 0L) {
                    1_000_000_000f / (frameStart - prevReadbackStartNs)
                } else 0f

                val tempProfile = buildProfile(
                    frameIndex, readbackIndex,
                    oesMs, displayMs, fboRenderMsHolder, 0f,
                    pboMapMs, 0f, 0f,
                    achievedPreviewFps = if (prevFrameStartNs > 0L)
                        1_000_000_000f / (frameStart - prevFrameStartNs) else 0f,
                    achievedReadbackFps = readFps,
                    isReadback = true
                )

                // ── Deliver to caller ──────────────────────────────────────────
                // buffer is ONLY valid here. Caller must not retain a reference.
                val cbStart = System.nanoTime()
                callback.onFrameReady(mappedBuffer, tempProfile)
                callbackMs = nsToMs(System.nanoTime() - cbStart)

                readbackIndex++
                prevReadbackStartNs = frameStart
                isReadback = true
            } else {
                Log.e(TAG, "glMapBufferRange returned null on frame $frameIndex — " +
                           "possible PBO allocation failure or GL error")
                checkGlError("glMapBufferRange")
            }

            // Unmap MUST happen before any further GPU commands touch this PBO
            GLES30.glUnmapBuffer(GLES30.GL_PIXEL_PACK_BUFFER)
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
        }

        // ── Stage 4: Render OES → full-resolution FBO ─────────────────────────
        //
        // This is the source for the PBO readback. We render at the full camera
        // resolution (4000×3000) into an offscreen FBO.
        //
        // We do this AFTER mapping the previous PBO so the GPU is free to
        // start the new render while the CPU is busy in the callback above.

        EGL14.eglMakeCurrent(eglDisplay, eglPbuffer, eglPbuffer, eglContext)
        val fboStart = System.nanoTime()
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboId)
        GLES30.glViewport(0, 0, cameraWidth, cameraHeight)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        drawOesQuad(oesTransformMatrix)
        val fboMs = nsToMs(System.nanoTime() - fboStart)
        fboRenderMsHolder = fboMs // store for profile building above (next readback)

        // ── Stage 5: Kick off async PBO readback (if throttle allows) ─────────
        //
        // glReadPixels with GL_PIXEL_PACK_BUFFER bound is ASYNCHRONOUS.
        // It queues a DMA: FBO colour buffer → pboIds[pboWriteIdx].
        // This call returns in ~0ms. The DMA runs while the next frame renders.
        //
        // On the NEXT readback frame, we map pboIds[pboReadIdx] (which is this
        // frame's pboWriteIdx after the swap below) to get the completed data.

        var pboKickoffMs = 0f
        val nowMs = System.currentTimeMillis()
        val shouldReadback = (nowMs - lastReadbackTriggerMs) >= readbackIntervalMs

        if (shouldReadback) {
            // Swap: the PBO we just read from (pboReadIdx) is now safe to write into
            val tmp  = pboWriteIdx
            pboWriteIdx = pboReadIdx
            pboReadIdx  = tmp

            val kickStart = System.nanoTime()
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pboIds[pboWriteIdx])

            // Offset = 0 means "write from byte 0 of the PBO".
            // This call returns immediately — DMA is queued asynchronously.
            GLES30.glReadPixels(
                0, 0, cameraWidth, cameraHeight,
                GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE,
                0L // offset into PBO, not a CPU pointer
            )
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
            pboKickoffMs = nsToMs(System.nanoTime() - kickStart)

            pboReadbackPending = true
            lastReadbackTriggerMs = nowMs
        }

        // Unbind FBO — subsequent GL calls target the default framebuffer
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        // ── Profiling ─────────────────────────────────────────────────────────

        val totalMs = nsToMs(System.nanoTime() - frameStart)
        val previewFps = if (prevFrameStartNs > 0L)
            1_000_000_000f / (frameStart - prevFrameStartNs) else 0f
        val readFps = if (prevReadbackStartNs > 0L)
            1_000_000_000f / (frameStart - prevReadbackStartNs) else 0f

        val profile = buildProfile(
            frameIndex, readbackIndex,
            oesMs, displayMs, fboMs, pboKickoffMs,
            pboMapMs, callbackMs, totalMs,
            previewFps, readFps, isReadback
        )
        Log.v(TAG, profile.summary())
        callback.onProfileUpdate(profile)

        prevFrameStartNs = frameStart
        frameIndex++
    }

    // Carries fboMs from Stage 4 to the next frame's profile (for the map-then-render ordering)
    private var fboRenderMsHolder = 0f

    // ── GL draw call ──────────────────────────────────────────────────────────

    /**
     * Draws the OES texture (camera frame) as a fullscreen quad using [texMatrix]
     * to correctly orient and crop the image.
     *
     * This is called twice per frame:
     *   1. With the window EGL surface current → renders to display at display resolution
     *   2. With the pbuffer EGL surface current, FBO bound → renders to FBO at camera resolution
     */
    private fun drawOesQuad(texMatrix: FloatArray) {
        GLES30.glUseProgram(shaderProgram)

        // Upload the OES correction matrix — corrects orientation, flip, and crop
        val matLoc = GLES30.glGetUniformLocation(shaderProgram, "uTexMatrix")
        GLES30.glUniformMatrix4fv(matLoc, 1, false, texMatrix, 0)

        // Bind OES texture to texture unit 0
        val samplerLoc = GLES30.glGetUniformLocation(shaderProgram, "uTexture")
        GLES30.glUniform1i(samplerLoc, 0)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES11Ext.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)

        // Bind vertex attribute arrays from pre-allocated quad buffer
        val posLoc = GLES30.glGetAttribLocation(shaderProgram, "aPosition")
        val texLoc = GLES30.glGetAttribLocation(shaderProgram, "aTexCoord")

        GLES30.glEnableVertexAttribArray(posLoc)
        GLES30.glEnableVertexAttribArray(texLoc)

        // Stride = 4 floats × 4 bytes = 16 bytes per vertex (x,y,u,v interleaved)
        quadVerts.position(0)
        GLES30.glVertexAttribPointer(posLoc, 2, GLES30.GL_FLOAT, false, 16, quadVerts)
        quadVerts.position(2)
        GLES30.glVertexAttribPointer(texLoc, 2, GLES30.GL_FLOAT, false, 16, quadVerts)

        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)

        GLES30.glDisableVertexAttribArray(posLoc)
        GLES30.glDisableVertexAttribArray(texLoc)
    }

    // ── EGL initialisation ────────────────────────────────────────────────────

    private fun initEgl() {
        // Get the default EGL display (the GPU)
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "eglGetDisplay failed" }

        val version = IntArray(2)
        check(EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) { "eglInitialize failed" }

        // Request an 8-bit RGBA config that supports both window and pbuffer surfaces
        val configAttribs = intArrayOf(
            EGL14.EGL_RED_SIZE,         8,
            EGL14.EGL_GREEN_SIZE,       8,
            EGL14.EGL_BLUE_SIZE,        8,
            EGL14.EGL_ALPHA_SIZE,       8,
            EGL14.EGL_RENDERABLE_TYPE,  EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE,     EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE
        )
        val configs    = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0)
        val eglConfig = requireNotNull(configs[0]) {
            "No compatible EGL config found — does the device support GLES 3.0?"
        }

        // Create a GLES 3.0 context (required for PBOs)
        val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
        check(eglContext != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }

        // Window surface: backed by the caller's SurfaceView surface → visible preview
        eglWindowSurface = EGL14.eglCreateWindowSurface(
            eglDisplay, eglConfig, displaySurface, intArrayOf(EGL14.EGL_NONE), 0
        )
        check(eglWindowSurface != EGL14.EGL_NO_SURFACE) { "eglCreateWindowSurface failed" }

        // PBuffer: tiny 1×1 offscreen surface used when context needs to be current
        // but we're rendering to an FBO (not a window). Size doesn't matter for FBO work.
        val pbAttribs = intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE)
        eglPbuffer = EGL14.eglCreatePbufferSurface(eglDisplay, eglConfig, pbAttribs, 0)
        check(eglPbuffer != EGL14.EGL_NO_SURFACE) { "eglCreatePbufferSurface failed" }

        // Make context current on the window surface to start
        EGL14.eglMakeCurrent(eglDisplay, eglWindowSurface, eglWindowSurface, eglContext)

        Log.i(TAG, "EGL ready | renderer=${GLES30.glGetString(GLES30.GL_RENDERER)} " +
                   "version=${GLES30.glGetString(GLES30.GL_VERSION)}")
    }

    // ── GL resource initialisation ────────────────────────────────────────────

    private fun initGl() {
        // ── OES input texture ─────────────────────────────────────────────────
        // The camera HAL writes YUV frames into this texture via the SurfaceTexture.
        // It cannot be attached to an FBO (OES limitation) — hence the two-pass render.
        val oesId = IntArray(1)
        GLES30.glGenTextures(1, oesId, 0)
        oesTextureId = oesId[0]
        GLES11Ext.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES11Ext.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES11Ext.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES11Ext.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S,     GLES30.GL_CLAMP_TO_EDGE)
        GLES11Ext.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T,     GLES30.GL_CLAMP_TO_EDGE)

        // ── FBO RGBA texture ──────────────────────────────────────────────────
        // A regular GL_TEXTURE_2D — can be attached to FBO and read by glReadPixels.
        // Allocated at full camera resolution: 4000×3000×4 = 48 MB on the GPU.
        val fboTexId = IntArray(1)
        GLES30.glGenTextures(1, fboTexId, 0)
        fboTextureId = fboTexId[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, fboTextureId)
        GLES30.glTexImage2D(
            GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8,
            cameraWidth, cameraHeight, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null  // null = allocate, don't fill
        )
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST)

        // ── Framebuffer Object ────────────────────────────────────────────────
        // Bind fboTextureId as the colour output. Rendering with this FBO bound
        // writes into fboTextureId instead of the screen.
        val fboIdArr = IntArray(1)
        GLES30.glGenFramebuffers(1, fboIdArr, 0)
        fboId = fboIdArr[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboId)
        GLES30.glFramebufferTexture2D(
            GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, fboTextureId, 0
        )
        val fbStatus = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER)
        check(fbStatus == GLES30.GL_FRAMEBUFFER_COMPLETE) {
            "FBO incomplete — status: 0x${fbStatus.toString(16)}"
        }
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        // ── PBOs ─────────────────────────────────────────────────────────────
        // Two PBOs pre-allocated at 48 MB each = 96 MB total GPU buffer memory.
        // GL_STREAM_READ: hints to driver that GPU writes once, CPU reads once.
        // This is the optimal usage pattern for readback PBOs.
        GLES30.glGenBuffers(2, pboIds, 0)
        for (id in pboIds) {
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, id)
            GLES30.glBufferData(
                GLES30.GL_PIXEL_PACK_BUFFER,
                pboByteSize,
                null,                        // null = allocate storage, leave uninitialised
                GLES30.GL_STREAM_READ
            )
        }
        GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)

        // ── Shader program ────────────────────────────────────────────────────
        shaderProgram = buildShaderProgram()

        checkGlError("initGl")
        Log.i(TAG, "GL ready | OES=$oesTextureId FBO=$fboId " +
                   "PBOs=${pboIds.toList()} pboSizeMB=${pboByteSize / 1024 / 1024}")
    }

    // ── Shaders ───────────────────────────────────────────────────────────────

    private fun buildShaderProgram(): Int {
        // Vertex shader: transforms NDC positions, applies OES correction matrix to UVs
        val vertSrc = """
            attribute vec4 aPosition;   // NDC position of fullscreen quad vertex
            attribute vec2 aTexCoord;   // Raw texture coordinate [0,1]
            uniform mat4 uTexMatrix;    // SurfaceTexture transform (orientation + flip + crop)
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                // Apply OES transform: corrects sensor rotation, vertical flip, HAL crop
                vTexCoord = (uTexMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;
            }
        """.trimIndent()

        // Fragment shader: samples the OES texture (camera frame in YUV, converted by driver)
        // The #extension directive is REQUIRED to use samplerExternalOES
        val fragSrc = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES uTexture;
            varying vec2 vTexCoord;
            void main() {
                gl_FragColor = texture2D(uTexture, vTexCoord);
            }
        """.trimIndent()

        val vert = compileShader(GLES30.GL_VERTEX_SHADER,   vertSrc)
        val frag = compileShader(GLES30.GL_FRAGMENT_SHADER, fragSrc)

        val prog = GLES30.glCreateProgram()
        GLES30.glAttachShader(prog, vert)
        GLES30.glAttachShader(prog, frag)
        GLES30.glLinkProgram(prog)

        val linkStatus = IntArray(1)
        GLES30.glGetProgramiv(prog, GLES30.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == GLES30.GL_FALSE) {
            val log = GLES30.glGetProgramInfoLog(prog)
            GLES30.glDeleteProgram(prog)
            error("Shader program link failed: $log")
        }

        // Shaders are linked — they can be deleted now (program retains the compiled code)
        GLES30.glDeleteShader(vert)
        GLES30.glDeleteShader(frag)
        return prog
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, src)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == GLES30.GL_FALSE) {
            val log = GLES30.glGetShaderInfoLog(shader)
            GLES30.glDeleteShader(shader)
            error("Shader compile failed (type=$type): $log")
        }
        return shader
    }

    // ── GL resource teardown ──────────────────────────────────────────────────

    private fun releaseGl() {
        GLES30.glDeleteBuffers(2, pboIds, 0)
        GLES30.glDeleteFramebuffers(1, intArrayOf(fboId), 0)
        GLES30.glDeleteTextures(1, intArrayOf(fboTextureId), 0)
        GLES30.glDeleteTextures(1, intArrayOf(oesTextureId), 0)
        GLES30.glDeleteProgram(shaderProgram)
        Log.d(TAG, "GL resources released")
    }

    private fun releaseEgl() {
        EGL14.eglMakeCurrent(
            eglDisplay,
            EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
            EGL14.EGL_NO_CONTEXT
        )
        EGL14.eglDestroySurface(eglDisplay, eglWindowSurface)
        EGL14.eglDestroySurface(eglDisplay, eglPbuffer)
        EGL14.eglDestroyContext(eglDisplay, eglContext)
        EGL14.eglTerminate(eglDisplay)
        Log.d(TAG, "EGL released")
    }

    /**
     * Release all GPU resources and stop the GL thread.
     * Call from surfaceDestroyed() or onDestroyView().
     * After this call, this instance is dead — do not reuse.
     */
    fun release() {
        glHandler.post {
            releaseGl()
            releaseEgl()
            glThread.quitSafely()
        }
    }

    // ── Utilities ─────────────────────────────────────────────────────────────

    private fun checkGlError(tag: String) {
        val err = GLES30.glGetError()
        if (err != GLES30.GL_NO_ERROR) {
            Log.e(TAG, "GL error at [$tag]: 0x${err.toString(16)}")
        }
    }

    private fun nsToMs(ns: Long): Float = ns / 1_000_000f

    private fun buildProfile(
        frameIdx: Int, readbackIdx: Int,
        oesMs: Float, displayMs: Float, fboMs: Float,
        kickMs: Float, mapMs: Float, cbMs: Float, totalMs: Float,
        achievedPreviewFps: Float, achievedReadbackFps: Float,
        isReadback: Boolean
    ) = GlFrameProfile(
        frameIndex          = frameIdx,
        readbackIndex       = readbackIdx,
        oesUpdateMs         = oesMs,
        displayRenderMs     = displayMs,
        fboRenderMs         = fboMs,
        pboKickoffMs        = kickMs,
        pboMapMs            = mapMs,
        callbackMs          = cbMs,
        totalPipelineMs     = totalMs,
        achievedPreviewFps  = achievedPreviewFps,
        achievedReadbackFps = achievedReadbackFps,
        isReadbackFrame     = isReadback
    )

    // ── Static quad geometry ──────────────────────────────────────────────────

    companion object {
        private const val TAG = "GpuToCpuSurfaceProvider"

        @Volatile private var instanceCounter = 0

        /**
         * Fullscreen quad as TRIANGLE_STRIP.
         * Each vertex: [x, y, u, v] — position in NDC, texture coord in [0,1].
         *
         * Vertex order (TRIANGLE_STRIP):
         *   2 ── 4       NDC: (-1,-1) = bottom-left of screen
         *   │  ╲ │             ( 1, 1) = top-right of screen
         *   1 ── 3
         */
        private val QUAD_VERTS = floatArrayOf(
            // x      y      u     v
            -1.0f, -1.0f,  0.0f, 0.0f,  // vertex 1: bottom-left
             1.0f, -1.0f,  1.0f, 0.0f,  // vertex 2: bottom-right
            -1.0f,  1.0f,  0.0f, 1.0f,  // vertex 3: top-left
             1.0f,  1.0f,  1.0f, 1.0f,  // vertex 4: top-right
        )

        /**
         * Pre-allocated FloatBuffer containing the quad vertices.
         * Allocated once at class-load time — never allocates during frame processing.
         */
        private val quadVerts: FloatBuffer = ByteBuffer
            .allocateDirect(QUAD_VERTS.size * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .also { buf -> buf.put(QUAD_VERTS).rewind() }
    }
}
