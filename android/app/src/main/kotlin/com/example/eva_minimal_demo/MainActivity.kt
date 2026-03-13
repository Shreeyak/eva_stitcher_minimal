package com.example.eva_minimal_demo

import android.hardware.camera2.TotalCaptureResult
import androidx.camera.core.ImageProxy
import com.example.eva_camera.EvaCameraPlugin
import com.example.eva_camera.FrameProcessor
import com.example.eva_camera.PhotoCaptureProcessor
import com.example.eva_camera.StillFrameSaver
import com.example.eva_camera.StitchFrameProcessor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EvaCameraPlugin.setFrameProcessor(
            object : FrameProcessor {
                override fun processFrame(
                    width: Int,
                    height: Int,
                    yPlane: ByteArray,
                    uPlane: ByteArray,
                    vPlane: ByteArray,
                    yRowStride: Int,
                    uvRowStride: Int,
                    uvPixelStride: Int,
                    captureResult: TotalCaptureResult?,
                ): Float {
                    // TODO(Phase 2): Forward captureResult to NativeStitcher so the stitching
                    //  pipeline can read per-frame sensor metadata (exposure, ISO, focus distance)
                    //  for exposure-compensated blending. NativeStitcher.processFrame() must first
                    //  be extended to accept a TotalCaptureResult parameter.
                    return NativeStitcher.processFrame(
                        width,
                        height,
                        yPlane,
                        uPlane,
                        vPlane,
                        yRowStride,
                        uvRowStride,
                        uvPixelStride,
                    )
                }
            },
        )

        EvaCameraPlugin.setPhotoCaptureProcessor(
            object : PhotoCaptureProcessor {
                override fun onPhotoCapture(
                    imageProxy: ImageProxy,
                    captureResult: TotalCaptureResult?,
                ) {
                    StillFrameSaver.saveToMediaStore(applicationContext, imageProxy)
                }
            },
        )

        EvaCameraPlugin.setStitchFrameProcessor(
            object : StitchFrameProcessor {
                override fun onStitchFrame(
                    imageProxy: ImageProxy,
                    captureResult: TotalCaptureResult?,
                ) {
                    // TODO(Phase 2): Implement stitch-frame ingestion path.
                    // Suggested next steps:
                    // 1) Read YUV planes/strides from imageProxy.
                    // 2) Forward pixel data + captureResult to NativeStitcher.
                    // 3) Return quickly; heavy work should run natively.
                }
            },
        )
    }
}
