package com.example.eva_minimal_demo

import android.content.ContentValues
import android.hardware.camera2.TotalCaptureResult
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import androidx.camera.core.ImageProxy
import com.example.eva_camera.EvaCameraPlugin
import com.example.eva_camera.FrameProcessor
import com.example.eva_camera.PhotoCaptureProcessor
import com.example.eva_camera.StillFrameSaver
import com.example.eva_camera.StitchFrameProcessor
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val STITCH_CHANNEL = "com.example.eva/stitch"
    }

    // Single-thread executor for the heavy C++ downscale+composite work.
    // Isolated from the camera executor so ImageProxy can be closed before processing starts.
    private val stitchExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "stitch-composite")
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
                    buf: ByteBuffer,
                    w: Int,
                    h: Int,
                    stride: Int,
                    rotation: Int,
                    timestampNs: Long,
                    captureResult: TotalCaptureResult?,
                ): Float {
                    val shouldCapture = NativeStitcher.processAnalysisFrame(
                        frameBuf    = buf,
                        w           = w,
                        h           = h,
                        stride      = stride,
                        rotation    = rotation,
                        timestampNs = timestampNs,
                    )
                    return if (shouldCapture) 1.0f else 0.0f
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
                    val plane = imageProxy.planes[0]  // RGBA_8888: single plane

                    // Copy pixel data into a direct ByteBuffer before returning so
                    // captureStill's finally block can close the ImageProxy immediately.
                    // Direct ByteBuffer: no Java GC pressure + JNI GetDirectBufferAddress works.
                    val buf = plane.buffer
                    val t0copy = System.currentTimeMillis()
                    val direct = ByteBuffer.allocateDirect(buf.remaining())
                    direct.put(buf)
                    direct.rewind()
                    val copyMs = System.currentTimeMillis() - t0copy
                    val w       = imageProxy.width
                    val h       = imageProxy.height
                    val stride  = plane.rowStride
                    val rotation = imageProxy.imageInfo.rotationDegrees
                    val tsNs    = imageProxy.imageInfo.timestamp
                    Log.i(TAG, "Stitch copy: ${w}x${h} size=${direct.capacity() / 1024}KB copyMs=$copyMs")

                    // Return here — imageProxy.close() fires in captureStill's finally block.
                    stitchExecutor.execute {
                        NativeStitcher.processStitchFrame(
                            frameBuf    = direct,
                            w           = w,
                            h           = h,
                            stride      = stride,
                            rotation    = rotation,
                            timestampNs = tsNs,
                        )
                    }
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
                        // Render the canvas as a single PNG into a temp file, then
                        // publish it to Pictures/EvaWSI via MediaStore (no permissions
                        // required on API 29+ scoped storage).
                        val tmpFile = File(cacheDir, "eva_canvas_tmp.png")
                        val status = NativeStitcher.saveCanvasAsImage(tmpFile.absolutePath)
                        if (status != 0) {
                            result.error("SAVE_ERROR", "Native save returned $status", null)
                            return@setMethodCallHandler
                        }

                        val timestamp = System.currentTimeMillis()
                        val fileName = "eva_canvas_$timestamp.png"
                        val values = ContentValues().apply {
                            put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                            put(MediaStore.Images.Media.RELATIVE_PATH,
                                "${Environment.DIRECTORY_PICTURES}/EvaWSI")
                            put(MediaStore.Images.Media.IS_PENDING, 1)
                        }
                        val uri: Uri? = contentResolver.insert(
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                        if (uri == null) {
                            tmpFile.delete()
                            result.error("SAVE_ERROR", "MediaStore insert failed", null)
                            return@setMethodCallHandler
                        }
                        contentResolver.openOutputStream(uri)?.use { out ->
                            tmpFile.inputStream().use { it.copyTo(out) }
                        }
                        values.clear()
                        values.put(MediaStore.Images.Media.IS_PENDING, 0)
                        contentResolver.update(uri, values, null, null)
                        tmpFile.delete()

                        result.success(mapOf(
                            "success" to true,
                            "path" to "${Environment.DIRECTORY_PICTURES}/EvaWSI/$fileName",
                        ))
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        stitchExecutor.shutdown()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
