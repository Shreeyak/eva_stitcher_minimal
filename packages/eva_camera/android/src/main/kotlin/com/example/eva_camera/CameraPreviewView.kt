package com.example.eva_camera

import android.content.Context
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import androidx.camera.view.PreviewView
import io.flutter.plugin.platform.PlatformView

/**
 * PlatformView wrapping either a PreviewView (Method 1) or a SurfaceView (Method 2),
 * controlled by [CameraManager.USE_GL_METHOD].
 *
 * Method 1 (USE_GL_METHOD=false): PreviewView in COMPATIBLE mode — exposes an internal
 * TextureView for [TextureViewBitmapCapture].
 *
 * Method 2 (USE_GL_METHOD=true): SurfaceView — its [SurfaceHolder] surface is passed to
 * [GpuToCpuSurfaceProvider] as the display target and triggers camera binding once ready.
 */
class CameraPreviewView(
    context: Context,
    private val viewId: Int,
    creationParams: Map<String, Any>?,
    private val onPreviewViewCreated: (PreviewView) -> Unit,
    private val onSurfaceViewCreated: ((SurfaceView) -> Unit)?,
    private val onViewDisposed: () -> Unit,
) : PlatformView {

    private val rootView: View

    init {
        if (CameraManager.USE_GL_METHOD) {
            val sv = SurfaceView(context)
            sv.holder.addCallback(
                object : SurfaceHolder.Callback {
                    override fun surfaceCreated(holder: SurfaceHolder) {
                        onSurfaceViewCreated?.invoke(sv)
                    }

                    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

                    override fun surfaceDestroyed(holder: SurfaceHolder) {}
                },
            )
            rootView = sv
        } else {
            val pv =
                PreviewView(context).apply {
                    implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                    scaleY = -1f
                }
            onPreviewViewCreated(pv)
            rootView = pv
        }
    }

    override fun getView(): View = rootView

    override fun dispose() {
        onViewDisposed()
    }
}
