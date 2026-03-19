package com.example.eva_minimal_demo.readback

import android.graphics.Bitmap
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.example.eva_minimal_demo.R
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Demonstrates two GPU→CPU camera frame readback methods for ML inference.
 *
 * Toggle [USE_GL_METHOD] to switch between:
 *   false → Method 1: [TextureViewBitmapCapture] via TextureView.getBitmap()
 *   true  → Method 2: [GpuToCpuSurfaceProvider] via EGL + double-buffered PBOs
 */
class FrameReadbackActivity : ComponentActivity() {
    companion object {
        private const val TAG = "FrameReadbackActivity"

        /** Compile-time flag: true = GL/PBO pipeline; false = TextureView getBitmap(). */
        const val USE_GL_METHOD: Boolean = false

        private const val CAMERA_WIDTH = 4208
        private const val CAMERA_HEIGHT = 3120
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var overlayText: TextView? = null

    // Method 1 state
    private var textureBitmapCapture: TextureViewBitmapCapture? = null

    // Method 2 state
    private var glSurfaceProvider: GpuToCpuSurfaceProvider? = null

    private var cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // Lifecycle
    // ────────────────────────────────────────────────────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (USE_GL_METHOD) {
            setContentView(R.layout.activity_frame_readback_gl)
            overlayText = findViewById(R.id.overlayText)
            setupGlMethod()
        } else {
            setContentView(R.layout.activity_frame_readback_texture)
            overlayText = findViewById(R.id.overlayText)
            setupTextureMethod()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        textureBitmapCapture?.stop()
        textureBitmapCapture = null
        glSurfaceProvider?.release()
        glSurfaceProvider = null
        cameraExecutor.shutdown()
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // Method 1 — TextureViewBitmapCapture
    // ────────────────────────────────────────────────────────────────────────────────────────────

    private fun setupTextureMethod() {
        val previewView = findViewById<PreviewView>(R.id.previewView)
        // MUST set COMPATIBLE mode before CameraX is bound.
        previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE

        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener(
            {
                val cameraProvider = cameraProviderFuture.get()
                val preview =
                    Preview.Builder().build().also {
                        it.setSurfaceProvider(previewView.surfaceProvider)
                    }
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                )

                // Instantiate AFTER camera is bound and preview is running.
                textureBitmapCapture =
                    TextureViewBitmapCapture(
                        previewView = previewView,
                        captureWidth = 4000,
                        captureHeight = 3000,
                        targetFps = 3f,
                        callback =
                            object : TextureViewBitmapCapture.FrameCallback {
                                override fun onFrameReady(
                                    bitmap: Bitmap,
                                    profile: TextureViewBitmapCapture.CaptureProfile,
                                ) {
                                    Log.d(TAG, profile.summary())
                                    runMlInference(bitmap, bitmap.width, bitmap.height)
                                    mainHandler.post {
                                        overlayText?.text = profile.summary()
                                    }
                                }
                            },
                    )
            },
            ContextCompat.getMainExecutor(this),
        )
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // Method 2 — GpuToCpuSurfaceProvider
    // ────────────────────────────────────────────────────────────────────────────────────────────

    private fun setupGlMethod() {
        val surfaceView = findViewById<SurfaceView>(R.id.surfaceView)
        surfaceView.holder.addCallback(
            object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    val w = surfaceView.width.takeIf { it > 0 } ?: 1920
                    val h = surfaceView.height.takeIf { it > 0 } ?: 1080

                    val provider =
                        GpuToCpuSurfaceProvider(
                            displaySurface = holder.surface,
                            displayWidth = w,
                            displayHeight = h,
                            cameraWidth = CAMERA_WIDTH,
                            cameraHeight = CAMERA_HEIGHT,
                            targetReadbackFps = 3f,
                            frameCallback =
                                object : GpuToCpuSurfaceProvider.FrameCallback {
                                    override fun onFrameReady(
                                        buffer: ByteBuffer,
                                        width: Int,
                                        height: Int,
                                        profile: GpuToCpuSurfaceProvider.ReadbackProfile,
                                    ) {
                                        // PBO buffer is only valid inside this callback.
                                        // Copy immediately if inference takes >100ms.
                                        val copy =
                                            ByteBuffer.allocateDirect(buffer.remaining()).also {
                                                it.put(buffer)
                                                it.flip()
                                            }
                                        cameraExecutor.execute {
                                            runMlInference(copy, width, height)
                                        }
                                        mainHandler.post {
                                            overlayText?.text = profile.summary()
                                        }
                                    }
                                },
                            profileCallback =
                                object : GpuToCpuSurfaceProvider.ProfileCallback {
                                    override fun onProfileUpdate(
                                        profile: GpuToCpuSurfaceProvider.ReadbackProfile,
                                    ) {
                                        mainHandler.post {
                                            overlayText?.text =
                                                "Preview: ${"%.1f".format(profile.achievedPreviewFps)} fps  " +
                                                    "Readback: ${"%.1f".format(profile.achievedReadbackFps)} fps\n" +
                                                    profile.summary()
                                        }
                                    }
                                },
                        )
                    glSurfaceProvider = provider

                    // Bind CameraX inside surfaceCreated — NOT in onCreate.
                    bindCameraForGlMethod(provider)
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) = Unit

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    glSurfaceProvider?.release()
                    glSurfaceProvider = null
                }
            },
        )
    }

    private fun bindCameraForGlMethod(provider: GpuToCpuSurfaceProvider) {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener(
            {
                val cameraProvider = cameraProviderFuture.get()
                val preview = Preview.Builder().build().also { it.setSurfaceProvider(provider) }
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(
                    this,
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    preview,
                )
            },
            ContextCompat.getMainExecutor(this),
        )
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────
    // ML inference stub
    // ────────────────────────────────────────────────────────────────────────────────────────────

    /**
     * Placeholder for real ML inference. Method 1 passes a [Bitmap]; Method 2 passes a [ByteBuffer]
     * (RGBA, bottom-left row order — flip rows before feeding to a top-down model).
     */
    @Suppress("UNUSED_PARAMETER")
    fun runMlInference(data: Any, width: Int, height: Int) {
        // TODO: replace with real model
    }
}
