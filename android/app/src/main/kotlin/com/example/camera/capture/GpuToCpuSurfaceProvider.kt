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
 *   an entire frame&#39;s time to complete that DMA — so the map is usually instant.
 *   This is called &#34;double-buffered PBO readback&#34; and eliminates pipeline stalls.
 *
 * WHAT YOU GET:
 *   - True camera-sensor-resolution pixels (4000×3000 RGBA)
 *   - RGBA byte order: [R, G, B, A] per pixel (unlike Bitmap which is ARGB)
 *   - One frame of inherent latency (you always read the previous frame&#39;s PBO)
 *   - Zero GPU pipeline stall in steady state
 *   - Zero impact on preview rendering (runs on same GL thread, same context)
 *
 * ── PREREQUISITES ─────────────────────────────────────────────────────────────
 *
 *   In AndroidManifest.xml (PBOs require GLES 3.0):
 *     
 *
 *   In build.gradle:
 *     implementation &#34;androidx.camera:camera-camera2:1.3.x&#34;
 *     implementation &#34;androidx.camera:camera-lifecycle:1.3.x&#34;
 *
 * ── INTEGRATION STEPS ─────────────────────────────────────────────────────────
 *
 * STEP 1 — Layout XML (use SurfaceView, NOT PreviewView):
 *
 *   
 *
 * STEP 2 — In your Fragment/Activity:
 *
 *   private var glSurfaceProvider: GpuToCpuSurfaceProvider? = null
 *
 *   override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
 *       super.onViewCreated(view, savedInstanceState)
 *
 *       val surfaceView = view.findViewById(R.id.cameraSurfaceView)
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
 *                           Log.d(&#34;ML&#34;, profile.summary())
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
 *                    the frame is correctly oriented for the device&#39;s display.
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
         * If this is consistently &gt;5ms, something is wrong (maybe PBOs not allocated).
         */
        val pboKickoffMs: Float,

        /**
         * Time for glMapBufferRange() on the PREVIOUS frame&#39;s PBO.
         * If double-buffering is working correctly, the DMA will have finished
         * during the previous frame&#39;s render time, so this should be 0–5ms.
         * Consistently high values here mean the GPU can&#39;t complete a 48MB DMA
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
            append(&#34;Frame#$frameIndex &#34;)
            if (isReadbackFrame) append(&#34;[READBACK#$readbackIndex] &#34;)
            append(&#34;oes=${oesUpdateMs}ms disp=${displayRenderMs}ms fbo=${fboRenderMs}ms &#34;)
            append(&#34;kick=${pboKickoffMs}ms map=${pboMapMs}ms cb=${callbackMs}ms | &#34;)
            append(&#34;total=${totalPipelineMs}ms &#34;)
            append(&#34;prevFps=${String.format(&#34;%.1f&#34;, achievedPreviewFps)} &#34;)
            append(&#34;readFps=${String.format(&#34;%.1f&#34;, achievedReadbackFps)}&#34;)
        }
    }

    // ── GL Thread ─────────────────────────────────────────────────────────────
    //
    // ALL EGL and GLES calls MUST run on this thread.
    // Never call any gl* or EGL* function from another thread.

    private val glThread = HandlerThread(&#34;CameraGL-${instanceCounter++}&#34;).also { it.start() }
    private val glHandler = Handler(glThread.looper)
    private val glExecutor = Executor { command -&gt; glHandler.post(command) }

    // ── EGL state ─────────────────────────────────────────────────────────────

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT

    /**
     * Window surface — backed by displaySurface (the SurfaceView&#39;s Surface).
     * We render the camera preview here and call eglSwapBuffers to show it.
     */
    private var eglWindowSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    /**
     * PBuffer surface — a tiny (1×1) offscreen surface used when we switch
     * context to do FBO/PBO work without disturbing the window surface&#39;s state.
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
    private var pboReadIdx  = 1   // CPU reads from this PBO this frame (prev frame&#39;s data)

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
                it.setOnFrameAvailableListener({ st -&gt; processFrame(st) }, glHandler)
            }
            surfaceTexture = st

            val cameraSurface = Surface(st)

            // 4. Hand the surface to CameraX
            //    When CameraX is done (camera closed / use case unbound), the result
            //    lambda fires — we clean up there.
            request.provideSurface(cameraSurface, glExecutor) { _ -&gt;
                Log.d(TAG, &#34;CameraX released our surface — cleaning up GL resources&#34;)
                cameraSurface.release()
                st.release()
                releaseGl()
                releaseEgl()
                glThread.quitSafely()
            }

            Log.i(TAG, &#34;Surface provided to CameraX: ${cameraWidth}x${cameraHeight}, &#34; +
                       &#34;pboSize=${pboByteSize / 1024 / 1024}MB × 2&#34;)
        }
    }

    // ── Per-frame pipeline ────────────────────────────────────────────────────

    private fun processFrame(st: SurfaceTexture) {
        val frameStart = System.nanoTime()

        // ── Stage 1: Latch the newest camera frame ────────────────────────────
        //
        // updateTexImage() pulls the latest buffer from the SurfaceTexture&#39;s
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
        // Note: displayWidth/displayHeight are the SurfaceView&#39;s on-screen pixels,
        // not the camera resolution. The GPU scales automatically.

        val displayStart = System.nanoTime()
        EGL14.eglMakeCurrent(eglDisplay, eglWindowSurface, eglWindowSurface, eglContext)
        GLES30.glViewport(0, 0, displayWidth, displayHeight)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        drawOesQuad(oesTransformMatrix)
        EGL14.eglSwapBuffers(eglDisplay, eglWindowSurface) // → screen
        val displayMs = nsToMs(System.nanoTime() - displayStart)

        // ── Stage 3: Map previous frame&#39;s PBO (if a readback was pending) ─────
        //
        // We do this BEFORE kicking the new readback so that:
        //   (a) The GPU has had a full frame&#39;s worth of time to complete the DMA
        //       that was kicked at the end of the previous readback frame.
        //   (b) The buffer we map is from the previous kick — still valid.
        //
        // glMapBufferRange with GL_MAP_READ_BIT will block if the DMA isn&#39;t done.
        // With correct double-buffering and a full frame gap, this should be ~0ms.

        var pboMapMs    = 0f
        var callbackMs  = 0f
        var isReadback  = false

        if (pboReadbackPending) {
            // Switch to pbuffer context for FBO/PBO work
            EGL14.eglMakeCurrent(eglDisplay, eglPbuffer, eglPbuffer, eglContext)

            val mapStart = System.nanoTime()
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pboIds[pb
```

```
