package com.example.eva_minimal_demo

import android.content.ContentValues
import android.content.Context
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.ColorSpaceTransform
import android.hardware.camera2.params.RggbChannelVector
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.PrintWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Manages all CameraX operations: preview, capture, analysis, and Camera2 interop. Analysis frames
 * stay native-side (no streaming to Dart). In phase 2, frames will be passed to C++ via JNI for
 * stitching.
 */
class CameraManager(private val context: Context, private val lifecycleOwner: LifecycleOwner) {
    companion object {
        private const val TAG = "EvaCamera"

        /** Identity color correction transform — fallback for manual WB. */
        private val IDENTITY_COLOR_TRANSFORM =
                ColorSpaceTransform(
                        intArrayOf(1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1)
                )
    }

    // ── Camera state ────────────────────────────────────────────────────
    private var camera: Camera? = null
    private var imageCapture: ImageCapture? = null
    private var imageAnalysis: ImageAnalysis? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var cameraExecutor: ExecutorService? = null

    // ── Camera controls state ───────────────────────────────────────────
    private var afEnabled: Boolean = true
    private var aeEnabled: Boolean = false
    private var wbLocked: Boolean = false

    // Manual sensor settings (app always starts with AE off)
    private var storedExposureTimeNs: Long = 1_000_000L // 1ms per PLAN_ARCH spec
    private var storedSensitivityIso: Int = 200

    // Device capability ranges — populated from CameraCharacteristics after camera starts
    @Volatile private var exposureTimeRangeNs: Range<Long>? = null
    @Volatile private var sensitivityIsoRange: Range<Int>? = null

    // Focus distance captured from live AF results
    @Volatile private var capturedFocusDistance: Float? = null

    // WB lock: captured from live AWB TotalCaptureResults
    @Volatile private var capturedColorTransform: ColorSpaceTransform? = null
    @Volatile private var capturedColorGains: RggbChannelVector? = null
    // Static CCM from CameraCharacteristics (fallback)
    @Volatile private var staticColorTransform: ColorSpaceTransform? = null

    // ── Preview ─────────────────────────────────────────────────────────
    private var previewView: PreviewView? = null
    private var pendingStartCallback: ((Map<String, Any>?, Exception?) -> Unit)? = null

    // ── Event streaming to Dart ─────────────────────────────────────────
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // ── Frame counting / FPS ────────────────────────────────────────────
    @Volatile private var frameCount: Long = 0
    @Volatile private var lastFpsTime: Long = System.nanoTime()
    @Volatile private var lastFpsFrameCount: Long = 0
    @Volatile private var currentFps: Double = 0.0
    private var fpsTimer: Runnable? = null

    // ═══════════════════════════════════════════════════════════════════
    // Public API — called from MainActivity via MethodChannel
    // ═══════════════════════════════════════════════════════════════════

    /** Set the PreviewView whose surface provider will receive the camera feed. */
    fun setPreviewView(view: PreviewView) {
        previewView = view
        Log.i(TAG, "PreviewView set")
        pendingStartCallback?.let { callback ->
            pendingStartCallback = null
            Log.i(TAG, "Executing deferred startCamera")
            startCamera(callback)
        }
    }

    /** Called when the Flutter PlatformView is disposed. */
    fun onPreviewDisposed() {
        Log.i(TAG, "PreviewView disposed")
        previewView = null
        stopCamera()
    }

    /** Set the EventChannel sink for status/diagnostic events. */
    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    // ── Camera lifecycle ────────────────────────────────────────────────

    /**
     * Start the camera with Preview, ImageCapture, and ImageAnalysis use cases. Returns resolution
     * info via callback on the main thread.
     */
    @OptIn(ExperimentalCamera2Interop::class)
    fun startCamera(callback: (Map<String, Any>?, Exception?) -> Unit) {
        val pv = previewView
        if (pv == null) {
            Log.i(TAG, "PreviewView not ready, deferring startCamera")
            pendingStartCallback = callback
            return
        }

        if (cameraExecutor == null || cameraExecutor!!.isShutdown) {
            cameraExecutor = Executors.newSingleThreadExecutor()
        }

        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener(
                {
                    try {
                        val provider = cameraProviderFuture.get()
                        this.cameraProvider = provider

                        // ── Resolution selectors ──
                        val captureResolution =
                                ResolutionSelector.Builder()
                                        .setResolutionStrategy(
                                                ResolutionStrategy(
                                                        Size(3120, 2160),
                                                        ResolutionStrategy
                                                                .FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                                                )
                                        )
                                        .build()

                        val analysisResolution =
                                ResolutionSelector.Builder()
                                        .setResolutionStrategy(
                                                ResolutionStrategy(
                                                        Size(640, 480),
                                                        ResolutionStrategy
                                                                .FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                                                )
                                        )
                                        .build()

                        // ── Preview ──
                        val preview =
                                Preview.Builder()
                                        .setTargetRotation(Surface.ROTATION_0)
                                        .build()
                                        .also { it.setSurfaceProvider(pv.surfaceProvider) }

                        // ── ImageCapture ──
                        imageCapture =
                                ImageCapture.Builder()
                                        .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                                        .setResolutionSelector(captureResolution)
                                        .setTargetRotation(Surface.ROTATION_0)
                                        .build()

                        // ── ImageAnalysis (YUV_420_888 for future C++ BGR conversion) ──
                        val analysisBuilder =
                                ImageAnalysis.Builder()
                                        .setResolutionSelector(analysisResolution)
                                        .setOutputImageFormat(
                                                ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888
                                        )
                                        .setBackpressureStrategy(
                                                ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST
                                        )
                                        .setTargetRotation(Surface.ROTATION_0)

                        // Attach Camera2 capture callback to snoop live AWB/AF values
                        Camera2Interop.Extender(analysisBuilder)
                                .setSessionCaptureCallback(
                                        object : CameraCaptureSession.CaptureCallback() {
                                            override fun onCaptureCompleted(
                                                    session: CameraCaptureSession,
                                                    request: CaptureRequest,
                                                    result: TotalCaptureResult
                                            ) {
                                                // Capture live AWB CCM + gains while AWB is running
                                                val awbMode =
                                                        result.get(CaptureResult.CONTROL_AWB_MODE)
                                                if (awbMode == CameraMetadata.CONTROL_AWB_MODE_AUTO
                                                ) {
                                                    result.get(
                                                                    CaptureResult
                                                                            .COLOR_CORRECTION_TRANSFORM
                                                            )
                                                            ?.let { capturedColorTransform = it }
                                                    result.get(CaptureResult.COLOR_CORRECTION_GAINS)
                                                            ?.let { capturedColorGains = it }
                                                }
                                                // Capture live focus distance
                                                result.get(CaptureResult.LENS_FOCUS_DISTANCE)?.let {
                                                    capturedFocusDistance = it
                                                }
                                            }
                                        }
                                )

                        imageAnalysis =
                                analysisBuilder.build().also { analysis ->
                                    analysis.setAnalyzer(cameraExecutor!!) { imageProxy ->
                                        processFrame(imageProxy)
                                    }
                                }

                        val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

                        provider.unbindAll()
                        val cam =
                                provider.bindToLifecycle(
                                        lifecycleOwner,
                                        cameraSelector,
                                        preview,
                                        imageCapture!!,
                                        imageAnalysis!!
                                )
                        this.camera = cam

                        // Load static characteristics (CCM, ranges) and dump to file
                        loadStaticColorTransform(cam)

                        // Reset frame counter
                        frameCount = 0
                        lastFpsTime = System.nanoTime()
                        lastFpsFrameCount = 0
                        currentFps = 0.0

                        // Start FPS reporting timer
                        startFpsTimer()

                        applyAllCaptureOptions(cam) { error ->
                            if (error != null) {
                                Log.e(TAG, "Initial capture options apply failed", error)
                                callback(null, error)
                            } else {
                                callback(gatherResolutionInfo(), null)
                                pushEvent("status", "camera", "Camera started")
                                pushSettingsStatus()
                            }
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Camera start failed", e)
                        callback(null, e)
                    }
                },
                ContextCompat.getMainExecutor(context)
        )
    }

    /** Stop the camera and release resources. */
    fun stopCamera() {
        stopFpsTimer()
        cameraProvider?.unbindAll()
        camera = null
        imageCapture = null
        imageAnalysis?.clearAnalyzer()
        imageAnalysis = null

        cameraExecutor?.let { executor ->
            executor.shutdown()
            try {
                if (!executor.awaitTermination(2, TimeUnit.SECONDS)) {
                    executor.shutdownNow()
                }
            } catch (_: InterruptedException) {
                executor.shutdownNow()
            }
        }
        cameraExecutor = null
    }

    // ── Frame processing (native-side only) ─────────────────────────────

    /**
     * Process an analysis frame. Currently just counts frames for FPS tracking. In phase 2, the YUV
     * ImageProxy will be passed to C++ via JNI.
     */
    private fun processFrame(imageProxy: ImageProxy) {
        try {
            frameCount++

            // ── YUV → JNI → C++ OpenCV ────────────────────────────────────
            val yPlane = imageProxy.planes[0]
            val uPlane = imageProxy.planes[1]
            val vPlane = imageProxy.planes[2]

            val yBuf = yPlane.buffer
            val uBuf = uPlane.buffer
            val vBuf = vPlane.buffer

            val yBytes = ByteArray(yBuf.remaining()).also { yBuf.get(it) }
            val uBytes = ByteArray(uBuf.remaining()).also { uBuf.get(it) }
            val vBytes = ByteArray(vBuf.remaining()).also { vBuf.get(it) }

            val meanY =
                    NativeStitcher.processFrame(
                            width = imageProxy.width,
                            height = imageProxy.height,
                            yPlane = yBytes,
                            uPlane = uBytes,
                            vPlane = vBytes,
                            yRowStride = yPlane.rowStride,
                            uvRowStride = uPlane.rowStride,
                            uvPixelStride = uPlane.pixelStride,
                    )
        } finally {
            imageProxy.close()
        }
    }

    // ── FPS timer ───────────────────────────────────────────────────────

    private fun startFpsTimer() {
        stopFpsTimer()
        val timer =
                object : Runnable {
                    override fun run() {
                        val now = System.nanoTime()
                        val elapsed = (now - lastFpsTime) / 1_000_000_000.0
                        if (elapsed > 0) {
                            currentFps = (frameCount - lastFpsFrameCount) / elapsed
                            lastFpsTime = now
                            lastFpsFrameCount = frameCount
                        }
                        pushEvent(
                                "status",
                                "fps",
                                "Frames: $frameCount | FPS: ${"%.1f".format(currentFps)}",
                                mapOf("frameCount" to frameCount, "fps" to currentFps)
                        )
                        mainHandler.postDelayed(this, 500)
                    }
                }
        fpsTimer = timer
        mainHandler.postDelayed(timer, 500)
    }

    private fun stopFpsTimer() {
        fpsTimer?.let { mainHandler.removeCallbacks(it) }
        fpsTimer = null
    }

    // ── AF control ──────────────────────────────────────────────────────

    fun setAfEnabled(enabled: Boolean, callback: (Exception?) -> Unit) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        val prev = afEnabled
        afEnabled = enabled
        applyAllCaptureOptions(cam) { e ->
            if (e != null) {
                afEnabled = prev
                callback(e)
            } else {
                pushSettingsStatus()
                callback(null)
            }
        }
    }

    @OptIn(ExperimentalCamera2Interop::class)
    fun getMinFocusDistance(): Float {
        val cam = camera ?: return 0f
        return Camera2CameraInfo.from(cam.cameraInfo)
                .getCameraCharacteristic(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)
                ?: 0f
    }

    fun getCurrentFocusDistance(): Float = capturedFocusDistance ?: 0f

    fun setFocusDistance(distance: Float, callback: (Exception?) -> Unit) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        capturedFocusDistance = distance
        applyAllCaptureOptions(cam, callback)
    }

    // ── AE control ──────────────────────────────────────────────────────

    fun setAeEnabled(enabled: Boolean, callback: (Exception?) -> Unit) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        val prev = aeEnabled
        aeEnabled = enabled
        applyAllCaptureOptions(cam) { e ->
            if (e != null) {
                aeEnabled = prev
                callback(e)
            } else {
                pushSettingsStatus()
                callback(null)
            }
        }
    }

    fun getExposureOffsetStep(): Double {
        val cam = camera ?: return 0.0
        return cam.cameraInfo.exposureState.exposureCompensationStep.toDouble()
    }

    fun getExposureOffsetRange(): List<Int> {
        val cam = camera ?: return listOf(0, 0)
        val range = cam.cameraInfo.exposureState.exposureCompensationRange
        return listOf(range.lower, range.upper)
    }

    fun setExposureOffset(index: Int, callback: (Exception?) -> Unit) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        val future = cam.cameraControl.setExposureCompensationIndex(index)
        future.addListener(
                {
                    try {
                        future.get()
                        callback(null)
                    } catch (e: Exception) {
                        callback(e)
                    }
                },
                ContextCompat.getMainExecutor(context)
        )
    }

    // ── Manual sensor exposure / ISO ─────────────────────────────────

    /** Returns [min, max] sensor exposure time in nanoseconds, or a safe default. */
    fun getExposureTimeRangeNs(): List<Long> {
        val r = exposureTimeRangeNs ?: return listOf(1_000_000L, 1_000_000_000L)
        return listOf(r.lower, r.upper)
    }

    /** Set the sensor exposure time (nanoseconds). */
    fun setExposureTimeNs(ns: Long, callback: (Exception?) -> Unit) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        storedExposureTimeNs = ns
        applyAllCaptureOptions(cam, callback)
    }

    /** Returns [min, max] sensor sensitivity (ISO), or a safe default. */
    fun getIsoRange(): List<Int> {
        val r = sensitivityIsoRange ?: return listOf(100, 3200)
        return listOf(r.lower, r.upper)
    }

    /** Set the sensor ISO. */
    fun setIso(iso: Int, callback: (Exception?) -> Unit) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        storedSensitivityIso = iso
        applyAllCaptureOptions(cam, callback)
    }

    // ── Zoom control ────────────────────────────────────────────────────

    fun getMinZoomRatio(): Float = camera?.cameraInfo?.zoomState?.value?.minZoomRatio ?: 1f
    fun getMaxZoomRatio(): Float = camera?.cameraInfo?.zoomState?.value?.maxZoomRatio ?: 1f

    fun setZoomRatio(ratio: Float, callback: (Exception?) -> Unit) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        val future = cam.cameraControl.setZoomRatio(ratio)
        future.addListener(
                {
                    try {
                        future.get()
                        callback(null)
                    } catch (e: Exception) {
                        callback(e)
                    }
                },
                ContextCompat.getMainExecutor(context)
        )
    }

    // ── White balance — tap to lock / unlock ────────────────────────────

    /**
     * Lock white balance: capture the current live AWB CCM + gains, then switch to
     * CONTROL_AWB_MODE_OFF with those values applied.
     */
    fun lockWhiteBalance(callback: (Exception?) -> Unit) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        if (capturedColorTransform == null || capturedColorGains == null) {
            return callback(
                    IllegalStateException("No AWB data captured yet — wait for camera to stabilize")
            )
        }
        wbLocked = true
        applyAllCaptureOptions(cam) { e ->
            if (e != null) {
                wbLocked = false
                callback(e)
            } else {
                Log.i(TAG, "WB locked with captured CCM + gains")
                pushSettingsStatus()
                callback(null)
            }
        }
    }

    /** Unlock white balance: return to CONTROL_AWB_MODE_AUTO. */
    fun unlockWhiteBalance(callback: (Exception?) -> Unit) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        wbLocked = false
        applyAllCaptureOptions(cam) { e ->
            if (e != null) {
                wbLocked = true
                callback(e)
            } else {
                Log.i(TAG, "WB unlocked — AUTO")
                pushSettingsStatus()
                callback(null)
            }
        }
    }

    fun isWbLocked(): Boolean = wbLocked

    // ── Save frame ──────────────────────────────────────────────────────

    fun saveFrame(callback: (String?, Exception?) -> Unit) {
        val capture =
                imageCapture ?: return callback(null, IllegalStateException("Camera not ready"))
        val executor =
                cameraExecutor
                        ?: return callback(
                                null,
                                IllegalStateException("Camera executor not available")
                        )

        capture.takePicture(
                executor,
                object : ImageCapture.OnImageCapturedCallback() {
                    override fun onCaptureSuccess(imageProxy: ImageProxy) {
                        val w = imageProxy.width
                        val h = imageProxy.height
                        Log.i(TAG, "Captured image: ${w}x${h}")

                        val buffer = imageProxy.planes[0].buffer
                        val bytes = ByteArray(buffer.remaining())
                        buffer.get(bytes)
                        val rotation = imageProxy.imageInfo.rotationDegrees
                        imageProxy.close()

                        val name =
                                SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US)
                                        .format(System.currentTimeMillis())
                        val contentValues =
                                ContentValues().apply {
                                    put(MediaStore.MediaColumns.DISPLAY_NAME, "EVA_$name")
                                    put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
                                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                        put(
                                                MediaStore.Images.Media.RELATIVE_PATH,
                                                "Pictures/EvaWSI"
                                        )
                                        put(MediaStore.Images.Media.IS_PENDING, 1)
                                    }
                                }

                        try {
                            val uri =
                                    context.contentResolver.insert(
                                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                                            contentValues
                                    )
                                            ?: throw Exception("MediaStore insert returned null")

                            context.contentResolver.openOutputStream(uri)?.use { os ->
                                os.write(bytes)
                                os.flush()
                            }
                            writeExifRotation(uri, rotation)

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                val update =
                                        ContentValues().apply {
                                            put(MediaStore.Images.Media.IS_PENDING, 0)
                                        }
                                context.contentResolver.update(uri, update, null, null)
                            }

                            val path = "Pictures/EvaWSI/EVA_$name.jpg"
                            Log.i(TAG, "Saved ${w}x${h} to $path")
                            mainHandler.post { callback(path, null) }
                        } catch (e: Exception) {
                            Log.e(TAG, "Save failed", e)
                            mainHandler.post { callback(null, e) }
                        }
                    }

                    override fun onError(exception: ImageCaptureException) {
                        Log.e(TAG, "Capture failed", exception)
                        mainHandler.post { callback(null, exception) }
                    }
                }
        )
    }

    // ── Resolution info ─────────────────────────────────────────────────

    fun getResolutionInfo(): Map<String, Any> = gatherResolutionInfo()

    private fun gatherResolutionInfo(): Map<String, Any> {
        val result = mutableMapOf<String, Any>()
        imageCapture?.resolutionInfo?.resolution?.let {
            result["captureWidth"] = it.width
            result["captureHeight"] = it.height
        }
        imageAnalysis?.resolutionInfo?.resolution?.let {
            result["analysisWidth"] = it.width
            result["analysisHeight"] = it.height
        }
        return result
    }

    // ═══════════════════════════════════════════════════════════════════
    // Internal
    // ═══════════════════════════════════════════════════════════════════

    /**
     * Apply the FULL set of capture request options from current state.
     * Camera2CameraControl.setCaptureRequestOptions REPLACES all options — every call must write
     * ALL custom options together.
     */
    @OptIn(ExperimentalCamera2Interop::class)
    private fun applyAllCaptureOptions(cam: Camera, callback: (Exception?) -> Unit) {
        val camera2Control = Camera2CameraControl.from(cam.cameraControl)

        val afMode =
                if (afEnabled) CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE
                else CameraMetadata.CONTROL_AF_MODE_OFF

        val aeMode =
                if (aeEnabled) CameraMetadata.CONTROL_AE_MODE_ON
                else CameraMetadata.CONTROL_AE_MODE_OFF

        val builder =
                CaptureRequestOptions.Builder()
                        .setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, afMode)
                        .setCaptureRequestOption(CaptureRequest.CONTROL_AE_MODE, aeMode)

        // Manual exposure when AE is off
        if (!aeEnabled) {
            builder.setCaptureRequestOption(
                            CaptureRequest.SENSOR_EXPOSURE_TIME,
                            storedExposureTimeNs
                    )
                    .setCaptureRequestOption(
                            CaptureRequest.SENSOR_SENSITIVITY,
                            storedSensitivityIso
                    )
        }

        // Manual focus when AF is off
        if (!afEnabled) {
            capturedFocusDistance?.let {
                builder.setCaptureRequestOption(CaptureRequest.LENS_FOCUS_DISTANCE, it)
            }
        }

        // White balance
        if (wbLocked) {
            // Use captured CCM + gains from live AWB
            val ccm = capturedColorTransform ?: staticColorTransform ?: IDENTITY_COLOR_TRANSFORM
            val gains = capturedColorGains ?: RggbChannelVector(1f, 1f, 1f, 1f)
            builder.setCaptureRequestOption(
                            CaptureRequest.CONTROL_AWB_MODE,
                            CameraMetadata.CONTROL_AWB_MODE_OFF
                    )
                    .setCaptureRequestOption(
                            CaptureRequest.COLOR_CORRECTION_MODE,
                            CameraMetadata.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX
                    )
                    .setCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_TRANSFORM, ccm)
                    .setCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_GAINS, gains)
        } else {
            builder.setCaptureRequestOption(
                    CaptureRequest.CONTROL_AWB_MODE,
                    CameraMetadata.CONTROL_AWB_MODE_AUTO
            )
        }

        // ISP quality settings — fixed for WSI: minimise post-processing artefacts.
        builder.setCaptureRequestOption(CaptureRequest.EDGE_MODE, CameraMetadata.EDGE_MODE_OFF)
                .setCaptureRequestOption(
                        CaptureRequest.NOISE_REDUCTION_MODE,
                        CameraMetadata.NOISE_REDUCTION_MODE_FAST
                )
                .setCaptureRequestOption(
                        CaptureRequest.COLOR_CORRECTION_ABERRATION_MODE,
                        CameraMetadata.COLOR_CORRECTION_ABERRATION_MODE_FAST
                )
                .setCaptureRequestOption(
                        CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                        CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF
                )
                .setCaptureRequestOption(
                        CaptureRequest.HOT_PIXEL_MODE,
                        CameraMetadata.HOT_PIXEL_MODE_FAST
                )
                .setCaptureRequestOption(
                        CaptureRequest.SHADING_MODE,
                        CameraMetadata.SHADING_MODE_FAST
                )

        val future = camera2Control.setCaptureRequestOptions(builder.build())
        future.addListener(
                {
                    try {
                        future.get()
                        callback(null)
                    } catch (e: Exception) {
                        callback(e)
                    }
                },
                ContextCompat.getMainExecutor(context)
        )
    }

    /** Read static CCM from camera characteristics (called once after camera starts). */
    @OptIn(ExperimentalCamera2Interop::class)
    private fun loadStaticColorTransform(cam: Camera) {
        val cam2Info = Camera2CameraInfo.from(cam.cameraInfo)
        staticColorTransform =
                cam2Info.getCameraCharacteristic(CameraCharacteristics.SENSOR_COLOR_TRANSFORM1)
                        ?: cam2Info.getCameraCharacteristic(
                                CameraCharacteristics.SENSOR_COLOR_TRANSFORM2
                        )

        // Read device exposure/sensitivity ranges for manual mode
        val exposureRange: Range<Long>? =
                cam2Info.getCameraCharacteristic(
                        CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE
                )
        val sensitivityRange: Range<Int>? =
                cam2Info.getCameraCharacteristic(
                        CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE
                )
        exposureTimeRangeNs = exposureRange
        sensitivityIsoRange = sensitivityRange
        storedExposureTimeNs = exposureRange?.clamp(1_000_000L) ?: 1_000_000L
        storedSensitivityIso = sensitivityRange?.clamp(200) ?: 200

        Log.i(TAG, "Exposure range: $exposureRange → using ${storedExposureTimeNs}ns")
        Log.i(TAG, "Sensitivity range: $sensitivityRange → using ISO $storedSensitivityIso")

        // Dump all characteristics to a debug file
        dumpCameraCharacteristics(cam2Info)
    }

    /**
     * Dumps every available CameraCharacteristics key+value to a text file.
     *
     * Output: <app-external-files>/camera_dump.txt Readable at:
     * /sdcard/Android/data/com.example.eva_minimal_demo/files/camera_dump.txt (No special
     * permissions required on Android 10+)
     */
    @OptIn(ExperimentalCamera2Interop::class)
    @Suppress("UNCHECKED_CAST")
    private fun dumpCameraCharacteristics(cam2Info: Camera2CameraInfo) {
        val outDir = context.getExternalFilesDir(null) ?: context.filesDir
        val outFile = File(outDir, "camera_dump.txt")

        try {
            PrintWriter(outFile).use { pw ->
                val ts = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
                pw.println("# Camera2 Characteristics Dump")
                pw.println("# Generated: $ts")
                pw.println(
                        "# Device: ${Build.MANUFACTURER} ${Build.MODEL} (API ${Build.VERSION.SDK_INT})"
                )
                pw.println()

                // ── Sensor geometry ──────────────────────────────────────
                section(pw, "SENSOR GEOMETRY")
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_INFO_ACTIVE_ARRAY_SIZE",
                        CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_INFO_PIXEL_ARRAY_SIZE",
                        CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_INFO_PHYSICAL_SIZE",
                        CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE",
                        CameraCharacteristics.SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE
                )

                // ── Exposure / sensitivity ───────────────────────────────
                section(pw, "EXPOSURE & SENSITIVITY")
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_INFO_EXPOSURE_TIME_RANGE",
                        CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_INFO_SENSITIVITY_RANGE",
                        CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_MAX_ANALOG_SENSITIVITY",
                        CameraCharacteristics.SENSOR_MAX_ANALOG_SENSITIVITY
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_INFO_MAX_FRAME_DURATION",
                        CameraCharacteristics.SENSOR_INFO_MAX_FRAME_DURATION
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_AE_COMPENSATION_RANGE",
                        CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_AE_COMPENSATION_STEP",
                        CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES",
                        CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_AE_AVAILABLE_MODES",
                        CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_AE_LOCK_AVAILABLE",
                        CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE
                )

                // ── Lens optics ──────────────────────────────────────────
                section(pw, "LENS OPTICS")
                dumpKey(
                        pw,
                        cam2Info,
                        "LENS_INFO_AVAILABLE_FOCAL_LENGTHS",
                        CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "LENS_INFO_AVAILABLE_APERTURES",
                        CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "LENS_INFO_AVAILABLE_FILTER_DENSITIES",
                        CameraCharacteristics.LENS_INFO_AVAILABLE_FILTER_DENSITIES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION",
                        CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "LENS_INFO_FOCUS_DISTANCE_CALIBRATION",
                        CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "LENS_INFO_HYPERFOCAL_DISTANCE",
                        CameraCharacteristics.LENS_INFO_HYPERFOCAL_DISTANCE
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "LENS_INFO_MINIMUM_FOCUS_DISTANCE",
                        CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE
                )
                dumpKey(pw, cam2Info, "LENS_FACING", CameraCharacteristics.LENS_FACING)
                dumpKey(
                        pw,
                        cam2Info,
                        "LENS_POSE_REFERENCE",
                        CameraCharacteristics.LENS_POSE_REFERENCE
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "LENS_INTRINSIC_CALIBRATION",
                        CameraCharacteristics.LENS_INTRINSIC_CALIBRATION
                )
                dumpKey(pw, cam2Info, "LENS_DISTORTION", CameraCharacteristics.LENS_DISTORTION)
                @Suppress("DEPRECATION")
                dumpKey(
                        pw,
                        cam2Info,
                        "LENS_RADIAL_DISTORTION (deprecated)",
                        CameraCharacteristics.LENS_RADIAL_DISTORTION
                )

                // ── Focus / AF ───────────────────────────────────────────
                section(pw, "FOCUS / AF")
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_AF_AVAILABLE_MODES",
                        CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES
                )

                // ── AWB / colour ─────────────────────────────────────────
                section(pw, "AWB / COLOUR")
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_AWB_AVAILABLE_MODES",
                        CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_AWB_LOCK_AVAILABLE",
                        CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_COLOR_TRANSFORM1",
                        CameraCharacteristics.SENSOR_COLOR_TRANSFORM1
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_COLOR_TRANSFORM2",
                        CameraCharacteristics.SENSOR_COLOR_TRANSFORM2
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_FORWARD_MATRIX1",
                        CameraCharacteristics.SENSOR_FORWARD_MATRIX1
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_FORWARD_MATRIX2",
                        CameraCharacteristics.SENSOR_FORWARD_MATRIX2
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_CALIBRATION_TRANSFORM1",
                        CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM1
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_CALIBRATION_TRANSFORM2",
                        CameraCharacteristics.SENSOR_CALIBRATION_TRANSFORM2
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_REFERENCE_ILLUMINANT1",
                        CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT1
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_REFERENCE_ILLUMINANT2",
                        CameraCharacteristics.SENSOR_REFERENCE_ILLUMINANT2
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_BLACK_LEVEL_PATTERN",
                        CameraCharacteristics.SENSOR_BLACK_LEVEL_PATTERN
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_INFO_COLOR_FILTER_ARRANGEMENT",
                        CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SENSOR_INFO_WHITE_LEVEL",
                        CameraCharacteristics.SENSOR_INFO_WHITE_LEVEL
                )

                // ── Noise reduction ──────────────────────────────────────
                section(pw, "NOISE REDUCTION / EDGE / ISP")
                dumpKey(
                        pw,
                        cam2Info,
                        "NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES",
                        CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "EDGE_AVAILABLE_EDGE_MODES",
                        CameraCharacteristics.EDGE_AVAILABLE_EDGE_MODES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "HOT_PIXEL_AVAILABLE_HOT_PIXEL_MODES",
                        CameraCharacteristics.HOT_PIXEL_AVAILABLE_HOT_PIXEL_MODES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "COLOR_CORRECTION_AVAILABLE_ABERRATION_MODES",
                        CameraCharacteristics.COLOR_CORRECTION_AVAILABLE_ABERRATION_MODES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SHADING_AVAILABLE_MODES",
                        CameraCharacteristics.SHADING_AVAILABLE_MODES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "TONEMAP_AVAILABLE_TONE_MAP_MODES",
                        CameraCharacteristics.TONEMAP_AVAILABLE_TONE_MAP_MODES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "TONEMAP_MAX_CURVE_POINTS",
                        CameraCharacteristics.TONEMAP_MAX_CURVE_POINTS
                )

                // ── Flash / torch ────────────────────────────────────────
                section(pw, "FLASH / TORCH")
                dumpKey(
                        pw,
                        cam2Info,
                        "FLASH_INFO_AVAILABLE",
                        CameraCharacteristics.FLASH_INFO_AVAILABLE
                )
                if (Build.VERSION.SDK_INT >= 33) {
                    dumpKey(
                            pw,
                            cam2Info,
                            "FLASH_INFO_STRENGTH_MAXIMUM_LEVEL",
                            CameraCharacteristics.FLASH_INFO_STRENGTH_MAXIMUM_LEVEL
                    )
                    dumpKey(
                            pw,
                            cam2Info,
                            "FLASH_INFO_STRENGTH_DEFAULT_LEVEL",
                            CameraCharacteristics.FLASH_INFO_STRENGTH_DEFAULT_LEVEL
                    )
                }

                // ── Zoom / crop ──────────────────────────────────────────
                section(pw, "ZOOM / CROP")
                dumpKey(
                        pw,
                        cam2Info,
                        "SCALER_AVAILABLE_MAX_DIGITAL_ZOOM",
                        CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "SCALER_CROPPING_TYPE",
                        CameraCharacteristics.SCALER_CROPPING_TYPE
                )
                if (Build.VERSION.SDK_INT >= 30) {
                    dumpKey(
                            pw,
                            cam2Info,
                            "CONTROL_ZOOM_RATIO_RANGE",
                            CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE
                    )
                }

                // ── Video stabilisation ──────────────────────────────────
                section(pw, "STABILISATION")
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES",
                        CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES
                )

                // ── Capabilities & hardware level ────────────────────────
                section(pw, "CAPABILITIES")
                dumpKey(
                        pw,
                        cam2Info,
                        "INFO_SUPPORTED_HARDWARE_LEVEL",
                        CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "REQUEST_AVAILABLE_CAPABILITIES",
                        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "REQUEST_MAX_NUM_OUTPUT_RAW",
                        CameraCharacteristics.REQUEST_MAX_NUM_OUTPUT_RAW
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "REQUEST_MAX_NUM_OUTPUT_PROC",
                        CameraCharacteristics.REQUEST_MAX_NUM_OUTPUT_PROC
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "REQUEST_MAX_NUM_OUTPUT_PROC_STALLING",
                        CameraCharacteristics.REQUEST_MAX_NUM_OUTPUT_PROC_STALLING
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "REQUEST_PARTIAL_RESULT_COUNT",
                        CameraCharacteristics.REQUEST_PARTIAL_RESULT_COUNT
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "REQUEST_PIPELINE_MAX_DEPTH",
                        CameraCharacteristics.REQUEST_PIPELINE_MAX_DEPTH
                )

                // ── Scene modes ──────────────────────────────────────────
                section(pw, "SCENE / EFFECT MODES")
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_AVAILABLE_SCENE_MODES",
                        CameraCharacteristics.CONTROL_AVAILABLE_SCENE_MODES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_AVAILABLE_EFFECTS",
                        CameraCharacteristics.CONTROL_AVAILABLE_EFFECTS
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_MAX_REGIONS_AF",
                        CameraCharacteristics.CONTROL_MAX_REGIONS_AF
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_MAX_REGIONS_AE",
                        CameraCharacteristics.CONTROL_MAX_REGIONS_AE
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "CONTROL_MAX_REGIONS_AWB",
                        CameraCharacteristics.CONTROL_MAX_REGIONS_AWB
                )

                // ── Sync / latency ───────────────────────────────────────
                section(pw, "SYNC / LATENCY")
                dumpKey(pw, cam2Info, "SYNC_MAX_LATENCY", CameraCharacteristics.SYNC_MAX_LATENCY)

                // ── JPEG ─────────────────────────────────────────────────
                section(pw, "JPEG")
                dumpKey(
                        pw,
                        cam2Info,
                        "JPEG_AVAILABLE_THUMBNAIL_SIZES",
                        CameraCharacteristics.JPEG_AVAILABLE_THUMBNAIL_SIZES
                )

                // ── Statistics ───────────────────────────────────────────
                section(pw, "STATISTICS")
                dumpKey(
                        pw,
                        cam2Info,
                        "STATISTICS_INFO_AVAILABLE_FACE_DETECT_MODES",
                        CameraCharacteristics.STATISTICS_INFO_AVAILABLE_FACE_DETECT_MODES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "STATISTICS_INFO_MAX_FACE_COUNT",
                        CameraCharacteristics.STATISTICS_INFO_MAX_FACE_COUNT
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "STATISTICS_INFO_AVAILABLE_HOT_PIXEL_MAP_MODES",
                        CameraCharacteristics.STATISTICS_INFO_AVAILABLE_HOT_PIXEL_MAP_MODES
                )
                dumpKey(
                        pw,
                        cam2Info,
                        "STATISTICS_INFO_AVAILABLE_LENS_SHADING_MAP_MODES",
                        CameraCharacteristics.STATISTICS_INFO_AVAILABLE_LENS_SHADING_MAP_MODES
                )

                pw.println()
                pw.println("# --- END OF DUMP ---")
            }

            Log.i(TAG, "Camera characteristics dumped to: ${outFile.absolutePath}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to dump camera characteristics", e)
        }
    }

    /** Print a section header to the dump file. */
    private fun section(pw: PrintWriter, title: String) {
        pw.println()
        pw.println("# ── $title " + "─".repeat(maxOf(0, 60 - title.length)))
    }

    /**
     * Query one CameraCharacteristics key via Camera2CameraInfo and print it. Null means the device
     * doesn't support/expose this characteristic.
     */
    @OptIn(ExperimentalCamera2Interop::class)
    private fun <T> dumpKey(
            pw: PrintWriter,
            cam2Info: Camera2CameraInfo,
            label: String,
            key: CameraCharacteristics.Key<T>
    ) {
        val value: T? =
                try {
                    cam2Info.getCameraCharacteristic(key)
                } catch (e: Exception) {
                    null
                }
        val formatted =
                when (value) {
                    null -> "<not supported>"
                    is FloatArray -> value.joinToString(", ") { "%.6f".format(it) }
                    is IntArray -> value.joinToString(", ")
                    is LongArray -> value.joinToString(", ")
                    is ByteArray -> value.joinToString(", ") { it.toInt().and(0xFF).toString() }
                    is Array<*> -> value.joinToString(", ") { formatCharValue(it) }
                    else -> formatCharValue(value)
                }
        pw.println("%-55s %s".format(label, formatted))
    }

    /** Pretty-format a single CameraCharacteristics value (not arrays). */
    private fun formatCharValue(v: Any?): String =
            when (v) {
                null -> "null"
                is android.util.Range<*> -> "[${v.lower}, ${v.upper}]"
                is android.util.Size -> "${v.width}x${v.height}"
                is android.util.SizeF -> "${v.width}x${v.height}"
                is android.util.Rational -> "${v.numerator}/${v.denominator}"
                is android.graphics.Rect -> "(${v.left},${v.top})-(${v.right},${v.bottom})"
                is android.hardware.camera2.params.BlackLevelPattern ->
                        "[${v.getOffsetForIndex(0,0)}, ${v.getOffsetForIndex(1,0)}, " +
                                "${v.getOffsetForIndex(0,1)}, ${v.getOffsetForIndex(1,1)}]"
                is ColorSpaceTransform ->
                        buildString {
                            append("[")
                            for (row in 0..2) for (col in 0..2) {
                                val r = android.util.Rational(0, 1)
                                // ColorSpaceTransform stores 9 rationals in row-major order
                                append(
                                        "${v.getElement(col, row).numerator}/${v.getElement(col, row).denominator}"
                                )
                                if (!(row == 2 && col == 2)) append(", ")
                            }
                            append("]")
                        }
                is android.hardware.camera2.params.StreamConfigurationMap ->
                        "<StreamConfigurationMap — see log>"
                else -> v.toString()
            }

    /** Write EXIF orientation tag to saved JPEG. */
    private fun writeExifRotation(uri: android.net.Uri, rotationDegrees: Int) {
        val exifOrientation =
                when (rotationDegrees) {
                    90 -> ExifInterface.ORIENTATION_ROTATE_90
                    180 -> ExifInterface.ORIENTATION_ROTATE_180
                    270 -> ExifInterface.ORIENTATION_ROTATE_270
                    else -> ExifInterface.ORIENTATION_NORMAL
                }
        try {
            context.contentResolver.openFileDescriptor(uri, "rw")?.use { pfd ->
                val exif = ExifInterface(pfd.fileDescriptor)
                exif.setAttribute(ExifInterface.TAG_ORIENTATION, exifOrientation.toString())
                exif.saveAttributes()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not write EXIF orientation", e)
        }
    }

    /** Push a typed event to Dart on the main thread. */
    private fun pushEvent(
            type: String,
            tag: String,
            message: String,
            data: Map<String, Any> = emptyMap()
    ) {
        val event = mutableMapOf<String, Any>("type" to type, "tag" to tag, "message" to message)
        if (data.isNotEmpty()) event["data"] = data
        mainHandler.post { eventSink?.success(event) }
    }

    /** Push current AF/exposure/WB status to Dart. */
    private fun pushSettingsStatus() {
        val afLabel = if (afEnabled) "ON" else "OFF"
        val exposureLabel = if (aeEnabled) "Auto" else "Manual"
        val wbLabel = if (wbLocked) "Locked" else "Auto"
        pushEvent(
                "status",
                "cameraSettings",
                "AF: $afLabel | Exposure: $exposureLabel | WB: $wbLabel",
                mapOf("afEnabled" to afEnabled, "aeEnabled" to aeEnabled, "wbLocked" to wbLocked)
        )
    }
}
