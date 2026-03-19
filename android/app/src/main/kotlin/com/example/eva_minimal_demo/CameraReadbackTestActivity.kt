package com.example.eva_minimal_demo

import android.graphics.Bitmap
import android.os.Bundle
import android.util.Log
import android.util.Size
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.example.camera.capture.GpuToCpuSurfaceProvider
import com.example.camera.capture.TextureViewBitmapCapture
import java.nio.ByteBuffer

/**
 * Test activity for GPU→CPU camera frame readback methods.
 * Toggleable between Method 1 (TextureViewBitmapCapture) and Method 2 (GpuToCpuSurfaceProvider).
 */
class CameraReadbackTestActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "CameraReadbackTest"
        
        // Toggle between the two methods
        private const val USE_GL_METHOD = false  // false = Method 1, true = Method 2
    }

    // Method 1 components
    private var previewView: PreviewView? = null
    private var textureCapture: TextureViewBitmapCapture? = null

    // Method 2 components
    private var surfaceView: SurfaceView? = null
    private var glSurfaceProvider: GpuToCpuSurfaceProvider? = null

    // Common
    private var perfOverlay: TextView? = null
    private var lastProfileUpdate = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (USE_GL_METHOD) {
            setupMethod2()
        } else {
            setupMethod1()
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // METHOD 1: TextureViewBitmapCapture
    // ═══════════════════════════════════════════════════════════════════════════

    private fun setupMethod1() {
        // Create layout programmatically for simplicity
        previewView = PreviewView(this).apply {
            layoutParams = android.view.ViewGroup.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.MATCH_PARENT
            )
            // CRITICAL: Must be set BEFORE camera is bound
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        }

        perfOverlay = TextView(this).apply {
            layoutParams = android.view.ViewGroup.LayoutParams(
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setTextColor(android.graphics.Color.YELLOW)
            setBackgroundColor(android.graphics.Color.argb(128, 0, 0, 0))
            setPadding(16, 16, 16, 16)
            textSize = 12f
        }

        val frameLayout = android.widget.FrameLayout(this).apply {
            addView(previewView)
            addView(perfOverlay)
        }
        setContentView(frameLayout)

        bindCameraForMethod1()
    }

    private fun bindCameraForMethod1() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()
            val preview = Preview.Builder()
                .setTargetResolution(Size(4000, 3000))
                .build()
                .also { it.setSurfaceProvider(previewView!!.surfaceProvider) }

            cameraProvider.unbindAll()
            cameraProvider.bindToLifecycle(
                this,
                CameraSelector.DEFAULT_BACK_CAMERA,
                preview
            )

            // Start capture AFTER camera is bound
            textureCapture = TextureViewBitmapCapture(
                previewView = previewView!!,
                captureWidth = 4000,
                captureHeight = 3000,
                targetFps = 3f,
                callback = object : TextureViewBitmapCapture.FrameCallback {
                    override fun onFrameReady(
                        bitmap: Bitmap,
                        profile: TextureViewBitmapCapture.CaptureProfile
                    ) {
                        Log.d(TAG, profile.summary())
                        runMlInference(bitmap, bitmap.width, bitmap.height)
                        updatePerfOverlay(profile.summary())
                    }

                    override fun onFrameFailed(reason: String) {
                        Log.w(TAG, "Frame failed: $reason")
                    }
                }
            )
            textureCapture?.start()

        }, ContextCompat.getMainExecutor(this))
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // METHOD 2: GpuToCpuSurfaceProvider
    // ═══════════════════════════════════════════════════════════════════════════

    private fun setupMethod2() {
        surfaceView = SurfaceView(this).apply {
            layoutParams = android.view.ViewGroup.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        perfOverlay = TextView(this).apply {
            layoutParams = android.view.ViewGroup.LayoutParams(
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setTextColor(android.graphics.Color.YELLOW)
            setBackgroundColor(android.graphics.Color.argb(128, 0, 0, 0))
            setPadding(16, 16, 16, 16)
            textSize = 12f
        }

        val frameLayout = android.widget.FrameLayout(this).apply {
            addView(surfaceView)
            addView(perfOverlay)
        }
        setContentView(frameLayout)

        surfaceView?.holder?.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                glSurfaceProvider = GpuToCpuSurfaceProvider(
                    displaySurface = holder.surface,
                    displayWidth = surfaceView!!.width,
                    displayHeight = surfaceView!!.height,
                    cameraWidth = 4000,
                    cameraHeight = 3000,
                    targetReadbackFps = 3f,
                    callback = object : GpuToCpuSurfaceProvider.FrameCallback {
                        override fun onFrameReady(
                            buffer: ByteBuffer,
                            profile: GpuToCpuSurfaceProvider.GlFrameProfile
                        ) {
                            // Called on GL thread
                            Log.d(TAG, profile.summary())
                            
                            // Copy buffer if ML inference takes >100ms
                            val copy = ByteBuffer.allocate(buffer.remaining())
                            copy.put(buffer)
                            copy.rewind()
                            
                            runMlInference(copy, 4000, 3000)
                        }

                        override fun onProfileUpdate(profile: GpuToCpuSurfaceProvider.GlFrameProfile) {
                            // Update UI on main thread
                            runOnUiThread {
                                updatePerfOverlay(profile.summary())
                            }
                        }
                    }
                )
                bindCameraForMethod2()
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                glSurfaceProvider?.release()
                glSurfaceProvider = null
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {}
        })
    }

    private fun bindCameraForMethod2() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()
            val preview = Preview.Builder()
                .setTargetResolution(Size(4000, 3000))
                .build()

            // Use OUR GL surface provider, not PreviewView's
            preview.setSurfaceProvider(glSurfaceProvider!!)

            cameraProvider.unbindAll()
            cameraProvider.bindToLifecycle(
                this,
                CameraSelector.DEFAULT_BACK_CAMERA,
                preview
            )

        }, ContextCompat.getMainExecutor(this))
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ML INFERENCE STUB
    // ═══════════════════════════════════════════════════════════════════════════

    private fun runMlInference(data: Any, width: Int, height: Int) {
        // TODO: replace with real model
        when (data) {
            is Bitmap -> {
                // Method 1: Bitmap in ARGB_8888 format
                Log.v(TAG, "ML stub: received Bitmap ${width}x${height}")
            }
            is ByteBuffer -> {
                // Method 2: ByteBuffer in RGBA, bottom-left row order
                Log.v(TAG, "ML stub: received ByteBuffer ${width}x${height}, ${data.remaining()} bytes")
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PROFILING OVERLAY
    // ═══════════════════════════════════════════════════════════════════════════

    private fun updatePerfOverlay(summary: String) {
        val now = System.currentTimeMillis()
        if (now - lastProfileUpdate >= 1000) {
            lastProfileUpdate = now
            runOnUiThread {
                perfOverlay?.text = summary
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    override fun onDestroy() {
        textureCapture?.stop()
        textureCapture = null
        glSurfaceProvider?.release()
        glSurfaceProvider = null
        super.onDestroy()
    }
}
