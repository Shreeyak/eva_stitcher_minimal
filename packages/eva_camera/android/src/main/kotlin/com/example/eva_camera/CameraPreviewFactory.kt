package com.example.eva_camera

import android.content.Context
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Factory that creates CameraPreviewView instances on demand. Registered with Flutter as viewType
 * "camerax-preview".
 */
class CameraPreviewFactory(
    private val onViewCreated: (androidx.camera.view.PreviewView) -> Unit,
    private val onViewDisposed: () -> Unit,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(
        context: Context,
        viewId: Int,
        args: Any?,
    ): PlatformView {
        @Suppress("UNCHECKED_CAST")
        val params = args as? Map<String, Any>
        return CameraPreviewView(context, viewId, params, onViewCreated, onViewDisposed)
    }
}
