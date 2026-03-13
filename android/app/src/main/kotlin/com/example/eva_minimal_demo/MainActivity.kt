package com.example.eva_minimal_demo

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
                ): Float =
                    NativeStitcher.processFrame(
                        width,
                        height,
                        yPlane,
                        uPlane,
                        vPlane,
                        yRowStride,
                        uvRowStride,
                        uvPixelStride,
                    )
            },
        )
    }
}
