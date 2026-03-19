package com.example.eva_camera

import android.graphics.SurfaceTexture
import android.opengl.*
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
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
 *                           Log.d("ML", profile.summary())
 *                           runMlInference(buffer, 4000, 3000)
 *                       }
 *
 *                       override fun onProfileUpdate(profile: GpuToCpuSurfaceProvider.GlFrameProfile) {
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
    private val callback: FrameCallback,
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
        val frameIndex: Int,
        val readbackIndex: Int,
        val oesUpdateMs: Float,
        val displayRenderMs: Float,
        val fboRenderMs: Float,
        val pboKickoffMs: Float,
        val pboMapMs: Float,
        val callbackMs: Float,
        val totalPipelineMs: Float,
        val achievedPreviewFps: Float,
        val achievedReadbackFps: Float,
        val isReadbackFrame: Boolean,
    ) {
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

    private val glThread = HandlerThread("CameraGL-${instanceCounter++}").also { it.start() }
    private val glHandler = Handler(glThread.looper)
    private val glExecutor = Executor { command -> glHandler.post(command) }

    // ── EGL state ─────────────────────────────────────────────────────────────

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglWindowSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var eglPbuffer: EGLSurface = EGL14.EGL_NO_SURFACE

    // ── GL Object IDs ─────────────────────────────────────────────────────────

    private var oesTextureId = 0
    private var fboId = 0
    private var fboTextureId = 0
    private var shaderProgram = 0

    // ── PBO double-buffer ─────────────────────────────────────────────────────

    private val pboIds = IntArray(2)
    private var pboWriteIdx = 0
    private var pboReadIdx = 1

    private val pboByteSize: Long = cameraWidth.toLong() * cameraHeight.toLong() * 4L

    // ── Camera Surface / SurfaceTexture ───────────────────────────────────────

    private var surfaceTexture: SurfaceTexture? = null
    private val oesTransformMatrix = FloatArray(16)

    // ── State tracking ────────────────────────────────────────────────────────

    private var frameIndex = 0
    private var readbackIndex = 0
    private var pboReadbackPending = false
    private var prevFrameStartNs = 0L
    private var prevReadbackStartNs = 0L

    private val readbackIntervalMs = (1000f / targetReadbackFps).toLong()
    private var lastReadbackTriggerMs = 0L

    // ── Preview.SurfaceProvider ───────────────────────────────────────────────

    override fun onSurfaceRequested(request: SurfaceRequest) {
        glHandler.post {
            initEgl()
            initGl()

            val st =
                SurfaceTexture(oesTextureId).also {
                    it.setDefaultBufferSize(cameraWidth, cameraHeight)
                    it.setOnFrameAvailableListener({ st -> processFrame(st) }, glHandler)
                }
            surfaceTexture = st

            val cameraSurface = Surface(st)

            request.provideSurface(cameraSurface, glExecutor) { _ ->
                Log.d(TAG, "CameraX released our surface — cleaning up GL resources")
                cameraSurface.release()
                st.release()
                releaseGl()
                releaseEgl()
                glThread.quitSafely()
            }

            Log.i(
                TAG,
                "Surface provided to CameraX: ${cameraWidth}x${cameraHeight}, " +
                    "pboSize=${pboByteSize / 1024 / 1024}MB × 2",
            )
        }
    }

    // ── Per-frame pipeline ────────────────────────────────────────────────────

    private fun processFrame(st: SurfaceTexture) {
        val frameStart = System.nanoTime()

        // ── Stage 1: Latch the newest camera frame ────────────────────────────
        val oesStart = System.nanoTime()
        st.updateTexImage()
        st.getTransformMatrix(oesTransformMatrix)
        val oesMs = nsToMs(System.nanoTime() - oesStart)

        // ── Stage 2: Render OES → visible display window ──────────────────────
        val displayStart = System.nanoTime()
        EGL14.eglMakeCurrent(eglDisplay, eglWindowSurface, eglWindowSurface, eglContext)
        GLES30.glViewport(0, 0, displayWidth, displayHeight)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        drawOesQuad(oesTransformMatrix)
        EGL14.eglSwapBuffers(eglDisplay, eglWindowSurface)
        val displayMs = nsToMs(System.nanoTime() - displayStart)

        // ── Stage 3: Map previous frame's PBO (if a readback was pending) ─────
        var pboMapMs = 0f
        var callbackMs = 0f
        var isReadback = false

        if (pboReadbackPending) {
            EGL14.eglMakeCurrent(eglDisplay, eglPbuffer, eglPbuffer, eglContext)

            val mapStart = System.nanoTime()
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pboIds[pboReadIdx])
            val mappedBuffer =
                GLES30.glMapBufferRange(
                    GLES30.GL_PIXEL_PACK_BUFFER,
                    0,
                    pboByteSize,
                    GLES30.GL_MAP_READ_BIT,
                ) as? ByteBuffer
            pboMapMs = nsToMs(System.nanoTime() - mapStart)

            if (mappedBuffer != null) {
                isReadback = true
                val readbackFps =
                    if (prevReadbackStartNs > 0) {
                        1e9f / (frameStart - prevReadbackStartNs)
                    } else {
                        0f
                    }
                prevReadbackStartNs = frameStart

                val previewFps =
                    if (prevFrameStartNs > 0) 1e9f / (frameStart - prevFrameStartNs) else 0f

                val profile =
                    GlFrameProfile(
                        frameIndex = frameIndex,
                        readbackIndex = readbackIndex++,
                        oesUpdateMs = oesMs,
                        displayRenderMs = displayMs,
                        fboRenderMs = 0f, // filled in below after we know
                        pboKickoffMs = 0f,
                        pboMapMs = pboMapMs,
                        callbackMs = 0f,
                        totalPipelineMs = 0f,
                        achievedPreviewFps = previewFps,
                        achievedReadbackFps = readbackFps,
                        isReadbackFrame = true,
                    )

                val cbStart = System.nanoTime()
                mappedBuffer.order(ByteOrder.nativeOrder())
                callback.onFrameReady(mappedBuffer, profile)
                callbackMs = nsToMs(System.nanoTime() - cbStart)
            }

            GLES30.glUnmapBuffer(GLES30.GL_PIXEL_PACK_BUFFER)
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
        }

        // ── Stage 4: Render OES → FBO (full camera resolution) ────────────────
        val shouldReadback =
            System.currentTimeMillis() - lastReadbackTriggerMs >= readbackIntervalMs

        var fboRenderMs = 0f
        var pboKickoffMs = 0f

        if (shouldReadback) {
            EGL14.eglMakeCurrent(eglDisplay, eglPbuffer, eglPbuffer, eglContext)

            val fboStart = System.nanoTime()
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboId)
            GLES30.glViewport(0, 0, cameraWidth, cameraHeight)
            GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
            drawOesQuad(oesTransformMatrix)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
            fboRenderMs = nsToMs(System.nanoTime() - fboStart)

            // ── Stage 5: Kick async PBO readback ─────────────────────────────
            val kickStart = System.nanoTime()
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pboIds[pboWriteIdx])
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboId)
            GLES30.glReadPixels(
                0,
                0,
                cameraWidth,
                cameraHeight,
                GLES30.GL_RGBA,
                GLES30.GL_UNSIGNED_BYTE,
                0,
            )
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
            pboKickoffMs = nsToMs(System.nanoTime() - kickStart)

            // Swap PBO indices for next frame
            val tmp = pboWriteIdx
            pboWriteIdx = pboReadIdx
            pboReadIdx = tmp

            pboReadbackPending = true
            lastReadbackTriggerMs = System.currentTimeMillis()
        }

        val totalMs = nsToMs(System.nanoTime() - frameStart)
        val previewFps = if (prevFrameStartNs > 0) 1e9f / (frameStart - prevFrameStartNs) else 0f
        prevFrameStartNs = frameStart

        val readbackFps =
            if (prevReadbackStartNs > 0) 1e9f / (frameStart - prevReadbackStartNs) else 0f

        val profile =
            GlFrameProfile(
                frameIndex = frameIndex++,
                readbackIndex = readbackIndex,
                oesUpdateMs = oesMs,
                displayRenderMs = displayMs,
                fboRenderMs = fboRenderMs,
                pboKickoffMs = pboKickoffMs,
                pboMapMs = pboMapMs,
                callbackMs = callbackMs,
                totalPipelineMs = totalMs,
                achievedPreviewFps = previewFps,
                achievedReadbackFps = readbackFps,
                isReadbackFrame = isReadback,
            )

        callback.onProfileUpdate(profile)
    }

    // ── GL Lifecycle ──────────────────────────────────────────────────────────

    fun release() {
        glHandler.post {
            surfaceTexture?.release()
            surfaceTexture = null
            releaseGl()
            releaseEgl()
            glThread.quitSafely()
        }
    }

    // ── EGL setup ─────────────────────────────────────────────────────────────

    private fun initEgl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        EGL14.eglInitialize(eglDisplay, null, 0, null, 0)

        val configAttribs =
            intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE,
                EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_SURFACE_TYPE,
                EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE,
                8,
                EGL14.EGL_GREEN_SIZE,
                8,
                EGL14.EGL_BLUE_SIZE,
                8,
                EGL14.EGL_ALPHA_SIZE,
                8,
                EGL14.EGL_NONE,
            )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0)
        val eglConfig = configs[0]!!

        val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)

        val windowAttribs = intArrayOf(EGL14.EGL_NONE)
        eglWindowSurface = EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, displaySurface, windowAttribs, 0)

        val pbufferAttribs = intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE)
        eglPbuffer = EGL14.eglCreatePbufferSurface(eglDisplay, eglConfig, pbufferAttribs, 0)

        EGL14.eglMakeCurrent(eglDisplay, eglWindowSurface, eglWindowSurface, eglContext)
    }

    private fun releaseEgl() {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return
        EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        if (eglWindowSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglWindowSurface)
        if (eglPbuffer != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglPbuffer)
        if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
        EGL14.eglTerminate(eglDisplay)
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglWindowSurface = EGL14.EGL_NO_SURFACE
        eglPbuffer = EGL14.EGL_NO_SURFACE
    }

    // ── GL object setup ───────────────────────────────────────────────────────

    private fun initGl() {
        // OES texture for camera frames
        val texIds = IntArray(1)
        GLES30.glGenTextures(1, texIds, 0)
        oesTextureId = texIds[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)

        // FBO color texture (full camera resolution)
        val fboTexIds = IntArray(1)
        GLES30.glGenTextures(1, fboTexIds, 0)
        fboTextureId = fboTexIds[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, fboTextureId)
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8, cameraWidth, cameraHeight, 0, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)

        // FBO
        val fboIds = IntArray(1)
        GLES30.glGenFramebuffers(1, fboIds, 0)
        fboId = fboIds[0]
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboId)
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, fboTextureId, 0)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        // PBOs
        GLES30.glGenBuffers(2, pboIds, 0)
        for (id in pboIds) {
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, id)
            GLES30.glBufferData(GLES30.GL_PIXEL_PACK_BUFFER, pboByteSize, null, GLES30.GL_STREAM_READ)
        }
        GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)

        // Shader program
        shaderProgram = createShaderProgram()

        Log.i(TAG, "GL objects initialized: oes=$oesTextureId fbo=$fboId pbo=${pboIds.toList()}")
    }

    private fun releaseGl() {
        if (shaderProgram != 0) {
            GLES30.glDeleteProgram(shaderProgram)
            shaderProgram = 0
        }
        if (pboIds[0] != 0) GLES30.glDeleteBuffers(2, pboIds, 0)
        if (fboId != 0) {
            GLES30.glDeleteFramebuffers(1, intArrayOf(fboId), 0)
            fboId = 0
        }
        if (fboTextureId != 0) {
            GLES30.glDeleteTextures(1, intArrayOf(fboTextureId), 0)
            fboTextureId = 0
        }
        if (oesTextureId != 0) {
            GLES30.glDeleteTextures(1, intArrayOf(oesTextureId), 0)
            oesTextureId = 0
        }
    }

    // ── Rendering ─────────────────────────────────────────────────────────────

    private val quadVertices: FloatBuffer by lazy {
        // Full-screen quad: (x, y, u, v) interleaved — two triangles
        val verts =
            floatArrayOf(
                -1f, -1f, 0f, 0f,
                1f, -1f, 1f, 0f,
                -1f, 1f, 0f, 1f,
                1f, 1f, 1f, 1f,
            )
        ByteBuffer.allocateDirect(verts.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
            put(verts)
            rewind()
        }
    }

    private fun drawOesQuad(texMatrix: FloatArray) {
        GLES30.glUseProgram(shaderProgram)

        val posLoc = GLES30.glGetAttribLocation(shaderProgram, "aPosition")
        val texLoc = GLES30.glGetAttribLocation(shaderProgram, "aTexCoord")
        val matLoc = GLES30.glGetUniformLocation(shaderProgram, "uTexMatrix")
        val samplerLoc = GLES30.glGetUniformLocation(shaderProgram, "uTexture")

        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glUniform1i(samplerLoc, 0)
        GLES30.glUniformMatrix4fv(matLoc, 1, false, texMatrix, 0)

        quadVertices.position(0)
        GLES30.glVertexAttribPointer(posLoc, 2, GLES30.GL_FLOAT, false, 4 * 4, quadVertices)
        GLES30.glEnableVertexAttribArray(posLoc)

        quadVertices.position(2)
        GLES30.glVertexAttribPointer(texLoc, 2, GLES30.GL_FLOAT, false, 4 * 4, quadVertices)
        GLES30.glEnableVertexAttribArray(texLoc)

        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)

        GLES30.glDisableVertexAttribArray(posLoc)
        GLES30.glDisableVertexAttribArray(texLoc)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES30.glUseProgram(0)
    }

    // ── GLSL Shaders ──────────────────────────────────────────────────────────

    private fun createShaderProgram(): Int {
        val vertSrc =
            """
            attribute vec4 aPosition;
            attribute vec2 aTexCoord;
            uniform mat4 uTexMatrix;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uTexMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;
            }
            """.trimIndent()

        val fragSrc =
            """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES uTexture;
            varying vec2 vTexCoord;
            void main() {
                gl_FragColor = texture2D(uTexture, vTexCoord);
            }
            """.trimIndent()

        val vs = compileShader(GLES30.GL_VERTEX_SHADER, vertSrc)
        val fs = compileShader(GLES30.GL_FRAGMENT_SHADER, fragSrc)

        val program = GLES30.glCreateProgram()
        GLES30.glAttachShader(program, vs)
        GLES30.glAttachShader(program, fs)
        GLES30.glLinkProgram(program)

        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)

        return program
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, src)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            Log.e(TAG, "Shader compile error: ${GLES30.glGetShaderInfoLog(shader)}")
        }
        return shader
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    companion object {
        private const val TAG = "GpuToCpuSurface"
        private var instanceCounter = 0

        private fun nsToMs(ns: Long): Float = ns / 1_000_000f
    }
}
