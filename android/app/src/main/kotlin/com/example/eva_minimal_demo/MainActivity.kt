package com.example.eva_minimal_demo

import android.Manifest
import android.content.pm.PackageManager
import android.hardware.camera2.TotalCaptureResult
import android.os.Build
import android.os.Environment
import android.util.Log
import androidx.camera.core.ImageProxy
import androidx.core.content.ContextCompat
import com.example.eva_camera.EvaCameraPlugin
import com.example.eva_camera.FrameProcessor
import com.example.eva_camera.PhotoCaptureProcessor
import com.example.eva_camera.StillFrameSaver
import com.example.eva_camera.StitchFrameProcessor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val STITCH_CHANNEL = "com.example.eva/stitch"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // ── Register frame processors BEFORE super.configureFlutterEngine ─────
        // super.configureFlutterEngine calls onAttachedToActivity synchronously,
        // which creates CameraManager and copies companion processor references
        // into instance fields at that moment. If we called set* after super,
        // CameraManager would capture null and analysis frames would be silently
        // dropped (frameProcessor ?: return in processFrame).
        EvaCameraPlugin.setFrameProcessor(
            object : FrameProcessor {
                override fun processFrame(
                    imageProxy: ImageProxy,
                    captureResult: TotalCaptureResult?,
                ): Float {
                    NativeStitcher.processAnalysisFrame(
                        imageProxy.planes[0].buffer,
                        imageProxy.width,
                        imageProxy.height,
                        imageProxy.planes[0].rowStride,
                        imageProxy.imageInfo.rotationDegrees,
                        imageProxy.imageInfo.timestamp,
                    )
                    return 0f
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

        // StitchFrameProcessor is unused in v3 (inline analysis-only stitch path).
        EvaCameraPlugin.setStitchFrameProcessor(
            object : StitchFrameProcessor {
                override fun onStitchFrame(
                    imageProxy: ImageProxy,
                    captureResult: TotalCaptureResult?,
                ) {
                    // No-op: stitching is now inline in processAnalysisFrame.
                }
            },
        )

        super.configureFlutterEngine(flutterEngine)

        // ── Stitch MethodChannel ───────────────────────────────────────────
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STITCH_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "initEngine" -> {
                    val analysisW = call.argument<Int>("analysisW") ?: 0
                    val analysisH = call.argument<Int>("analysisH") ?: 0
                    val cacheDir = "${filesDir.absolutePath}/tile_cache".also {
                        java.io.File(it).mkdirs()
                    }
                    NativeStitcher.initEngine(analysisW, analysisH, cacheDir)
                    result.success(null)
                }
                "getNavigationState" -> {
                    result.success(NativeStitcher.getNavigationState())
                }
                "getCanvasPreview" -> {
                    val maxDim = call.argument<Int>("maxDim") ?: 1024
                    result.success(NativeStitcher.getCanvasPreview(maxDim))
                }
                "resetEngine" -> {
                    NativeStitcher.resetEngine()
                    result.success(null)
                }
                "startScanning" -> {
                    NativeStitcher.startScanning()
                    result.success(null)
                }
                "stopScanning" -> {
                    NativeStitcher.stopScanning()
                    result.success(null)
                }
                "saveCanvas" -> {
                    try {
                        // Check WRITE_EXTERNAL_STORAGE permission (required on Android 12+)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            if (ContextCompat.checkSelfPermission(
                                    this,
                                    Manifest.permission.WRITE_EXTERNAL_STORAGE
                                ) != PackageManager.PERMISSION_GRANTED
                            ) {
                                result.error(
                                    "PERMISSION_DENIED",
                                    "WRITE_EXTERNAL_STORAGE permission not granted",
                                    null
                                )
                                return@setMethodCallHandler
                            }
                        }

                        val outputDir = File(
                            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                            "EvaWSI"
                        ).apply { mkdirs() }
                        val status = NativeStitcher.saveCanvasToDisk(outputDir.absolutePath)
                        if (status == 0) {
                            result.success(mapOf("success" to true, "path" to outputDir.absolutePath))
                        } else {
                            result.error("SAVE_ERROR", "Native save returned $status", null)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "saveCanvas error: ${e.message}")
                        result.error("EXCEPTION", e.message, e.stackTraceToString())
                    }
                }
                else -> {
                    Log.w(TAG, "Unhandled stitch method: ${call.method}")
                    result.notImplemented()
                }
            }
        }
    }
}
