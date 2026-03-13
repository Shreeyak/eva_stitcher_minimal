package com.example.eva_minimal_demo

import android.hardware.camera2.TotalCaptureResult
import com.example.eva_camera.EvaCameraPlugin
import com.example.eva_camera.FrameProcessor
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
    }
}
