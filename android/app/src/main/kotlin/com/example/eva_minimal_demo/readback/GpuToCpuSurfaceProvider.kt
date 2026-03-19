/**
 * Method 2 — custom EGL/GLES 3.0 pipeline with double-buffered PBOs for GPU→CPU readback.
 *
 * How it works:
 *   1. Implements [Preview.SurfaceProvider]; CameraX delivers frames via an OES texture.
 *   2. A dedicated GL thread owns an EGL context with two EGL surfaces:
 *        - A window surface backed by [displaySurface] (renders preview to screen).
 *        - An offscreen pbuffer surface for context initialization.
 *   3. Each camera frame is drawn from the OES texture through a simple GLSL shader into an FBO
 *      at [cameraWidth] × [cameraHeight].
 *   4. Two Pixel Buffer Objects (PBOs) are double-buffered:
 *        - Even frame: glReadPixels into PBO[0] (async, returns immediately).
 *        - Odd frame:  map PBO[0] → callback, then glReadPixels into PBO[1].
 *      This keeps the GPU pipeline full while the CPU processes the previous frame.
 *   5. [FrameCallback.onFrameReady] is called at up to [targetReadbackFps] Hz.
 *      The [ByteBuffer] is a mapped PBO slice — INVALID after [onFrameReady] returns.
 *      If ML inference takes >100 ms, copy the buffer first:
 *          val copy = ByteBuffer.allocateDirect(buffer.remaining()); copy.put(buffer); copy.flip()
 *
 * Constraints:
 *   - Requires GLES 3.0 — declare in AndroidManifest.xml:
 *       <uses-feature android:glEsVersion="0x00030000" android:required="true"/>
 *   - Do NOT use a PreviewView for this method. Use a SurfaceView and pass its Surface here.
 *   - Bind CameraX inside SurfaceHolder.Callback.surfaceCreated(), not in onViewCreated().
 *   - Call [release] in both surfaceDestroyed() and onDestroyView() to avoid EGL leaks.
 *   - Pixel layout: RGBA, bottom-left row order (OpenGL convention). Flip rows if needed.
 *   - [cameraWidth]/[cameraHeight] define the FBO and readback resolution — keep full-res.
 *   - [displayWidth]/[displayHeight] define the preview window; preview is letter/pillar-boxed.
 */
package com.example.eva_minimal_demo.readback

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicBoolean

class GpuToCpuSurfaceProvider(
    private val displaySurface: Surface,
    private val displayWidth: Int,
    private val displayHeight: Int,
    private val cameraWidth: Int,
    private val cameraHeight: Int,
    targetReadbackFps: Float,
    private val frameCallback: FrameCallback,
    private val profileCallback: ProfileCallback? = null,
) : Preview.SurfaceProvider {
    companion object {
        private const val TAG = "GpuToCpuProvider"

        private val QUAD_VERTICES =
            floatArrayOf(
                -1f, -1f, 0f, 0f,
                1f, -1f, 1f, 0f,
                -1f, 1f, 0f, 1f,
                1f, 1f, 1f, 1f,
            )
        private const val VERTEX_STRIDE = 4 * 4

        // language=GLSL
        private val VERTEX_SHADER =
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

        // language=GLSL
        private val FRAGMENT_SHADER =
            """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES uTexture;
            varying vec2 vTexCoord;
            void main() {
                gl_FragColor = texture2D(uTexture, vTexCoord);
            }
            """.trimIndent()
    }

    interface FrameCallback {
        /** Called on the GL thread. [buffer] is a mapped PBO — copy it if inference takes >100 ms. */
        fun onFrameReady(buffer: ByteBuffer, width: Int, height: Int, profile: ReadbackProfile)
    }

    interface ProfileCallback {
        fun onProfileUpdate(profile: ReadbackProfile)
    }

    data class ReadbackProfile(
        val frameCount: Int,
        val achievedPreviewFps: Float,
        val achievedReadbackFps: Float,
        val lastReadbackMs: Long,
        val avgReadbackMs: Float,
    ) {
        fun summary(): String =
            "GpuToCpu | frames=$frameCount | " +
                "previewFps=${"%.1f".format(achievedPreviewFps)} | " +
                "readbackFps=${"%.1f".format(achievedReadbackFps)} | " +
                "lastReadMs=$lastReadbackMs | avgReadMs=${"%.1f".format(avgReadbackMs)}"
    }

    private val readbackIntervalMs: Long = (1000f / targetReadbackFps).toLong().coerceAtLeast(1L)

    private val glThread = HandlerThread("GlReadback").also { it.start() }
    private val glHandler = Handler(glThread.looper)

    private val released = AtomicBoolean(false)
    private var surfaceRequest: SurfaceRequest? = null

    // EGL handles (owned by GL thread)
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglWindowSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var eglPbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    // GL objects (owned by GL thread)
    private var oesTextureId = 0
    private var surfaceTexture: SurfaceTexture? = null
    private var cameraSurface: Surface? = null
    private var shaderProgram = 0
    private var fboId = 0
    private var fboTextureId = 0
    private val pboIds = IntArray(2)
    private val pboSize: Int = cameraWidth * cameraHeight * 4

    // Pre-allocated vertex buffer
    private val vertexBuffer: FloatBuffer =
        ByteBuffer
            .allocateDirect(QUAD_VERTICES.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .also { it.put(QUAD_VERTICES).position(0) }

    // Texture transform matrix from SurfaceTexture
    private val texMatrix = FloatArray(16).also { Matrix.setIdentityM(it, 0) }

    // Profiling state (GL thread only)
    private var previewFrameCount = 0
    private var readbackFrameCount = 0
    private var totalReadbackMs = 0L
    private var lastPreviewWallMs = 0L
    private var lastReadbackWallMs = 0L
    private var achievedPreviewFps = 0f
    private var achievedReadbackFps = 0f
    private var lastReadbackMs = 0L
    private var pboWriteIndex = 0

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // Preview.SurfaceProvider
    // ────────────────────────────────────────────────────────────────────────────────────────────

    override fun onSurfaceRequested(request: SurfaceRequest) {
        surfaceRequest = request
        glHandler.post { initEglAndCamera(request) }
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // EGL / GL initialisation (GL thread)
    // ────────────────────────────────────────────────────────────────────────────────────────────

    private fun initEglAndCamera(request: SurfaceRequest) {
        if (released.get()) {
            request.willNotProvideSurface()
            return
        }
        if (!initEgl()) {
            Log.e(TAG, "EGL init failed — aborting")
            request.willNotProvideSurface()
            return
        }
        initGlObjects()

        // Provide the camera surface backed by our OES SurfaceTexture.
        val st = checkNotNull(surfaceTexture)
        val surface = Surface(st)
        cameraSurface = surface

        request.provideSurface(surface, { glHandler.post(it) }) { result ->
            Log.d(TAG, "SurfaceRequest result: ${result.resultCode}")
            glHandler.post { releaseGlObjects() }
        }

        st.setOnFrameAvailableListener({ onCameraFrame() }, glHandler)
    }

    private fun initEgl(): Boolean {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return false

        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) return false

        val configAttribs =
            intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE, 8,
                EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_NONE,
            )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        if (!EGL14.eglChooseConfig(eglDisplay, configAttribs, 0, configs, 0, 1, numConfigs, 0)) {
            return false
        }
        val eglConfig = configs[0] ?: return false

        val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE)
        eglContext =
            EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) return false

        // Window surface for displaying the preview.
        val winAttribs = intArrayOf(EGL14.EGL_NONE)
        eglWindowSurface =
            EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, displaySurface, winAttribs, 0)
        if (eglWindowSurface == EGL14.EGL_NO_SURFACE) return false

        // Pbuffer surface needed to make the context current before the window surface is ready.
        val pbAttribs = intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE)
        eglPbufferSurface =
            EGL14.eglCreatePbufferSurface(eglDisplay, eglConfig, pbAttribs, 0)
        if (eglPbufferSurface == EGL14.EGL_NO_SURFACE) return false

        if (!EGL14.eglMakeCurrent(eglDisplay, eglWindowSurface, eglWindowSurface, eglContext)) {
            return false
        }
        return true
    }

    private fun initGlObjects() {
        // OES texture for camera frames.
        val texIds = IntArray(1)
        GLES30.glGenTextures(1, texIds, 0)
        oesTextureId = texIds[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)
        GLES30.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR,
        )
        GLES30.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR,
        )
        GLES30.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE,
        )
        GLES30.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE,
        )
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)

        surfaceTexture = SurfaceTexture(oesTextureId)
        surfaceTexture!!.setDefaultBufferSize(cameraWidth, cameraHeight)

        // Compile shader program.
        shaderProgram = buildProgram(VERTEX_SHADER, FRAGMENT_SHADER)

        // FBO + color attachment at full camera resolution.
        val fboIds = IntArray(1)
        GLES30.glGenFramebuffers(1, fboIds, 0)
        fboId = fboIds[0]

        val fboTexIds = IntArray(1)
        GLES30.glGenTextures(1, fboTexIds, 0)
        fboTextureId = fboTexIds[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, fboTextureId)
        GLES30.glTexImage2D(
            GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA8,
            cameraWidth, cameraHeight, 0,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, null,
        )
        GLES30.glTexParameteri(
            GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_NEAREST,
        )
        GLES30.glTexParameteri(
            GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_NEAREST,
        )
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, 0)

        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboId)
        GLES30.glFramebufferTexture2D(
            GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
            GLES30.GL_TEXTURE_2D, fboTextureId, 0,
        )
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        // Two PBOs for double-buffered async readback.
        GLES30.glGenBuffers(2, pboIds, 0)
        for (id in pboIds) {
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, id)
            GLES30.glBufferData(
                GLES30.GL_PIXEL_PACK_BUFFER, pboSize, null, GLES30.GL_STREAM_READ,
            )
        }
        GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // Per-frame rendering (GL thread)
    // ────────────────────────────────────────────────────────────────────────────────────────────

    private fun onCameraFrame() {
        if (released.get()) return
        val st = surfaceTexture ?: return

        st.updateTexImage()
        st.getTransformMatrix(texMatrix)

        val now = SystemClock.elapsedRealtime()
        previewFrameCount++
        achievedPreviewFps =
            if (lastPreviewWallMs > 0L) 1000f / (now - lastPreviewWallMs) else 0f
        lastPreviewWallMs = now

        // Render OES texture → FBO (full camera resolution).
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboId)
        GLES30.glViewport(0, 0, cameraWidth, cameraHeight)
        drawOesTexture()
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        // Render FBO texture → window surface (letter/pillar-boxed to display size).
        EGL14.eglMakeCurrent(eglDisplay, eglWindowSurface, eglWindowSurface, eglContext)
        GLES30.glViewport(0, 0, displayWidth, displayHeight)
        drawFboToDisplay()
        EGL14.eglSwapBuffers(eglDisplay, eglWindowSurface)

        // Throttled PBO readback.
        if (now - lastReadbackWallMs >= readbackIntervalMs) {
            doReadback(now)
        }
    }

    private fun drawOesTexture() {
        GLES30.glUseProgram(shaderProgram)

        val posLoc = GLES30.glGetAttribLocation(shaderProgram, "aPosition")
        val texLoc = GLES30.glGetAttribLocation(shaderProgram, "aTexCoord")
        val matLoc = GLES30.glGetUniformLocation(shaderProgram, "uTexMatrix")
        val texUni = GLES30.glGetUniformLocation(shaderProgram, "uTexture")

        GLES30.glUniformMatrix4fv(matLoc, 1, false, texMatrix, 0)
        GLES30.glUniform1i(texUni, 0)

        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTextureId)

        vertexBuffer.position(0)
        GLES30.glVertexAttribPointer(posLoc, 2, GLES30.GL_FLOAT, false, VERTEX_STRIDE, vertexBuffer)
        GLES30.glEnableVertexAttribArray(posLoc)

        vertexBuffer.position(2)
        GLES30.glVertexAttribPointer(texLoc, 2, GLES30.GL_FLOAT, false, VERTEX_STRIDE, vertexBuffer)
        GLES30.glEnableVertexAttribArray(texLoc)

        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4)

        GLES30.glDisableVertexAttribArray(posLoc)
        GLES30.glDisableVertexAttribArray(texLoc)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)
        GLES30.glUseProgram(0)
    }

    private fun drawFboToDisplay() {
        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        GLES30.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, fboId)
        GLES30.glBindFramebuffer(GLES30.GL_DRAW_FRAMEBUFFER, 0)
        GLES30.glBlitFramebuffer(
            0, 0, cameraWidth, cameraHeight,
            0, 0, displayWidth, displayHeight,
            GLES30.GL_COLOR_BUFFER_BIT, GLES30.GL_LINEAR,
        )
        GLES30.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, 0)
    }

    private fun doReadback(wallMs: Long) {
        val readStart = SystemClock.elapsedRealtime()
        val writeIdx = pboWriteIndex
        val readIdx = 1 - writeIdx

        // Kick off async glReadPixels into the write PBO.
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fboId)
        GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pboIds[writeIdx])
        GLES30.glReadPixels(
            0, 0, cameraWidth, cameraHeight,
            GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, 0,
        )
        GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)

        // Map the read PBO (the one written on the previous readback call).
        if (readbackFrameCount > 0) {
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, pboIds[readIdx])
            val mappedBuffer =
                GLES30.glMapBufferRange(
                    GLES30.GL_PIXEL_PACK_BUFFER, 0, pboSize,
                    GLES30.GL_MAP_READ_BIT,
                )
            if (mappedBuffer is ByteBuffer) {
                val buf = mappedBuffer.order(ByteOrder.nativeOrder())
                val readMs = SystemClock.elapsedRealtime() - readStart
                totalReadbackMs += readMs
                readbackFrameCount++
                achievedReadbackFps =
                    if (lastReadbackWallMs > 0L) 1000f / (wallMs - lastReadbackWallMs) else 0f
                lastReadbackWallMs = wallMs
                lastReadbackMs = readMs

                val profile =
                    ReadbackProfile(
                        frameCount = readbackFrameCount,
                        achievedPreviewFps = achievedPreviewFps,
                        achievedReadbackFps = achievedReadbackFps,
                        lastReadbackMs = readMs,
                        avgReadbackMs = totalReadbackMs.toFloat() / readbackFrameCount,
                    )
                Log.d(TAG, profile.summary())
                frameCallback.onFrameReady(buf, cameraWidth, cameraHeight, profile)
                profileCallback?.onProfileUpdate(profile)

                GLES30.glUnmapBuffer(GLES30.GL_PIXEL_PACK_BUFFER)
            }
            GLES30.glBindBuffer(GLES30.GL_PIXEL_PACK_BUFFER, 0)
        } else {
            // First readback — just count the write; next frame we'll map.
            readbackFrameCount++
            lastReadbackWallMs = wallMs
        }

        pboWriteIndex = 1 - pboWriteIndex
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // Cleanup (call from surfaceDestroyed AND onDestroyView)
    // ────────────────────────────────────────────────────────────────────────────────────────────

    fun release() {
        if (!released.compareAndSet(false, true)) return
        glHandler.post {
            releaseGlObjects()
            glThread.quitSafely()
        }
    }

    private fun releaseGlObjects() {
        surfaceTexture?.release()
        surfaceTexture = null
        cameraSurface?.release()
        cameraSurface = null

        if (eglDisplay != EGL14.EGL_NO_DISPLAY && eglContext != EGL14.EGL_NO_CONTEXT) {
            // Use the pbuffer surface for cleanup — the window surface may already be invalid.
            EGL14.eglMakeCurrent(
                eglDisplay, eglPbufferSurface, eglPbufferSurface, eglContext,
            )
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
            if (pboIds[0] != 0 || pboIds[1] != 0) {
                GLES30.glDeleteBuffers(2, pboIds, 0)
                pboIds[0] = 0
                pboIds[1] = 0
            }
            if (shaderProgram != 0) {
                GLES30.glDeleteProgram(shaderProgram)
                shaderProgram = 0
            }
            EGL14.eglMakeCurrent(
                eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
            )
        }
        if (eglWindowSurface != EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroySurface(eglDisplay, eglWindowSurface)
            eglWindowSurface = EGL14.EGL_NO_SURFACE
        }
        if (eglPbufferSurface != EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroySurface(eglDisplay, eglPbufferSurface)
            eglPbufferSurface = EGL14.EGL_NO_SURFACE
        }
        if (eglContext != EGL14.EGL_NO_CONTEXT) {
            EGL14.eglDestroyContext(eglDisplay, eglContext)
            eglContext = EGL14.EGL_NO_CONTEXT
        }
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglTerminate(eglDisplay)
            eglDisplay = EGL14.EGL_NO_DISPLAY
        }
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // GL helpers
    // ────────────────────────────────────────────────────────────────────────────────────────────

    private fun buildProgram(vertSrc: String, fragSrc: String): Int {
        val vs = compileShader(GLES30.GL_VERTEX_SHADER, vertSrc)
        val fs = compileShader(GLES30.GL_FRAGMENT_SHADER, fragSrc)
        val prog = GLES30.glCreateProgram()
        GLES30.glAttachShader(prog, vs)
        GLES30.glAttachShader(prog, fs)
        GLES30.glLinkProgram(prog)
        GLES30.glDeleteShader(vs)
        GLES30.glDeleteShader(fs)
        return prog
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES30.glCreateShader(type)
        GLES30.glShaderSource(shader, src)
        GLES30.glCompileShader(shader)
        val status = IntArray(1)
        GLES30.glGetShaderiv(shader, GLES30.GL_COMPILE_STATUS, status, 0)
        if (status[0] == GLES30.GL_FALSE) {
            Log.e(TAG, "Shader compile error: ${GLES30.glGetShaderInfoLog(shader)}")
        }
        return shader
    }
}
