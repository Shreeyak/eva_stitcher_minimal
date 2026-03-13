package com.example.eva_camera

import android.content.Context
import android.view.View
import androidx.camera.view.PreviewView
import io.flutter.plugin.platform.PlatformView

/**
 * PlatformView wrapping CameraX PreviewView. Flutter creates this via CameraPreviewFactory; the
 * onViewCreated callback passes the PreviewView to CameraManager so it can bind the Preview use
 * case.
 */
class CameraPreviewView(
    context: Context,
    private val viewId: Int,
    creationParams: Map<String, Any>?,
    private val onViewCreated: (PreviewView) -> Unit,
    private val onViewDisposed: () -> Unit,
) : PlatformView {
    private val previewView: PreviewView =
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.PERFORMANCE
            scaleY = -1f
        }

    init {
        onViewCreated(previewView)
    }

    override fun getView(): View = previewView

    override fun dispose() {
        onViewDisposed()
    }
}
