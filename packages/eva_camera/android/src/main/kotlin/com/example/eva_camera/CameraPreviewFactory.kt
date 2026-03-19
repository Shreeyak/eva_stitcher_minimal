package com.example.eva_camera

import android.content.Context
import android.view.SurfaceView
import androidx.camera.view.PreviewView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Factory that creates [CameraPreviewView] instances on demand. Registered with Flutter as
 * viewType "camerax-preview".
 */
class CameraPreviewFactory(
    private val onPreviewViewCreated: (PreviewView) -> Unit,
    private val onSurfaceViewCreated: ((SurfaceView) -> Unit)? = null,
    private val onViewDisposed: () -> Unit,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(
        context: Context,
        viewId: Int,
        args: Any?,
    ): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any>
        return CameraPreviewView(
            context = context,
            viewId = viewId,
            creationParams = params,
            onPreviewViewCreated = onPreviewViewCreated,
            onSurfaceViewCreated = onSurfaceViewCreated,
            onViewDisposed = onViewDisposed,
        )
    }
}
