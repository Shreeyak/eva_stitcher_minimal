package com.example.eva_camera

import android.content.Context
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.ColorSpaceTransform
import android.hardware.camera2.params.RggbChannelVector
import android.os.Handler
import android.os.Looper
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
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Manages all CameraX operations: preview, capture, analysis, and Camera2 interop. Analysis frames
 * stay native-side (no streaming to Dart). Frames are forwarded to a [FrameProcessor] if one is
 * registered.
 */
class CameraManager(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
) {
    companion object {
        private const val TAG = "EvaCamera"

        /** Identity color correction transform — fallback for manual WB. */
        private val IDENTITY_COLOR_TRANSFORM =
            ColorSpaceTransform(
                intArrayOf(1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1),
            )
    }

    /** Optional frame processor — set by the host app via [EvaCameraPlugin.setFrameProcessor]. */
    var frameProcessor: FrameProcessor? = null

    /** Optional photo processor — set via [EvaCameraPlugin.setPhotoCaptureProcessor]. */
    var photoCaptureProcessor: PhotoCaptureProcessor? = null

    /** Optional stitch-frame processor — set via [EvaCameraPlugin.setStitchFrameProcessor]. */
    var stitchFrameProcessor: StitchFrameProcessor? = null

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
    private var captureIntentPreview: Boolean = true
    private var captureFormatYuv: Boolean = true
    private var preferredCaptureSize: Size = Size(4208, 3120)
    private var preferredAnalysisSize: Size = Size(1280, 960)

    // Manual sensor settings (app always starts with AE off)
    private var storedExposureTimeNs: Long = 1_000_000L // 1ms per PLAN_ARCH spec
    private var storedSensitivityIso: Int = 200

    // Device capability ranges — populated from CameraCharacteristics after camera starts
    @Volatile private var exposureTimeRangeNs: Range<Long>? = null

    @Volatile private var sensitivityIsoRange: Range<Int>? = null

    @Volatile private var defaultAeTargetFpsRange: Range<Int>? = null

    @Volatile private var availableAeTargetFpsRanges: Array<Range<Int>> = emptyArray()
    private var aeTargetFpsRange: Range<Int>? = null

    // Focus distance captured from live AF results
    @Volatile private var capturedFocusDistance: Float? = null

    // Capture results (latest full telemetry)
    @Volatile private var latestCaptureResult: TotalCaptureResult? = null

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
    // Public API
    // ═══════════════════════════════════════════════════════════════════

    /** Set the PreviewView whose surface provider will receive the camera feed. */
    fun setPreviewView(view: PreviewView) {
        previewView = view
        Log.i(TAG, "PreviewView set")
        pendingStartCallback?.let { callback ->
            pendingStartCallback = null
            Log.i(TAG, "Executing deferred startCamera")
            startCamera(callback = callback)
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
    fun startCamera(
        captureWidth: Int? = null,
        captureHeight: Int? = null,
        analysisWidth: Int? = null,
        analysisHeight: Int? = null,
        callback: (Map<String, Any>?, Exception?) -> Unit,
    ) {
        try {
            applyStartResolutionOverrides(
                captureWidth = captureWidth,
                captureHeight = captureHeight,
                analysisWidth = analysisWidth,
                analysisHeight = analysisHeight,
            )
        } catch (e: IllegalArgumentException) {
            callback(null, e)
            return
        }

        val pv = previewView
        if (pv == null) {
            Log.i(TAG, "PreviewView not ready, deferring startCamera")
            pendingStartCallback = callback
            return
        }

        // Reset startup-resolved AE FPS metadata for a fresh bind session.
        defaultAeTargetFpsRange = null
        availableAeTargetFpsRanges = emptyArray()
        aeTargetFpsRange = null

        if (cameraExecutor == null || cameraExecutor!!.isShutdown) {
            cameraExecutor = Executors.newSingleThreadExecutor()
        }

        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener(
            {
                try {
                    val provider = cameraProviderFuture.get()
                    this.cameraProvider = provider

                    rebindUseCases(
                        pv = pv,
                        provider = provider,
                        includeCapabilitiesInResult = true,
                        callback = callback,
                    )
                } catch (e: Exception) {
                    Log.e(TAG, "Camera start failed", e)
                    callback(null, e)
                }
            },
            ContextCompat.getMainExecutor(context),
        )
    }

    /**
     * Build and bind all use cases (Preview, ImageCapture, ImageAnalysis) to the camera.
     * Called from [startCamera] and [setCaptureFormat] to apply format/resolution changes.
     */
    @OptIn(ExperimentalCamera2Interop::class)
    private fun rebindUseCases(
        pv: PreviewView,
        provider: ProcessCameraProvider,
        includeCapabilitiesInResult: Boolean = false,
        callback: (Map<String, Any>?, Exception?) -> Unit,
    ) {
        try {
            // ── Resolution selectors ──
            val captureResolution =
                ResolutionSelector
                    .Builder()
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            preferredCaptureSize,
                            ResolutionStrategy
                                .FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                        ),
                    ).build()

            val analysisResolution =
                ResolutionSelector
                    .Builder()
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            preferredAnalysisSize,
                            ResolutionStrategy
                                .FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                        ),
                    ).build()

            // ── Preview ──
            val preview =
                Preview
                    .Builder()
                    .setTargetRotation(Surface.ROTATION_0)
                    .build()
                    .also { it.setSurfaceProvider(pv.surfaceProvider) }

            // ── ImageCapture (ZSL, output format from captureFormatYuv state) ──
            val captureBuilder =
                ImageCapture
                    .Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_ZERO_SHUTTER_LAG)
                    .setResolutionSelector(captureResolution)
                    .setTargetRotation(Surface.ROTATION_0)

            if (captureFormatYuv) {
                captureBuilder.setBufferFormat(android.graphics.ImageFormat.YUV_420_888)
            }
            imageCapture = captureBuilder.build()

            // ── ImageAnalysis (YUV_420_888 for future C++ BGR conversion) ──
            val analysisBuilder =
                ImageAnalysis
                    .Builder()
                    .setResolutionSelector(analysisResolution)
                    .setOutputImageFormat(
                        ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888,
                    ).setBackpressureStrategy(
                        ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST,
                    ).setTargetRotation(Surface.ROTATION_0)

            // Attach Camera2 capture callback to snoop live AWB/AF values
            Camera2Interop
                .Extender(analysisBuilder)
                .setSessionCaptureCallback(
                    object : CameraCaptureSession.CaptureCallback() {
                        override fun onCaptureCompleted(
                            session: CameraCaptureSession,
                            request: CaptureRequest,
                            result: TotalCaptureResult,
                        ) {
                            // Capture live AWB CCM + gains while AWB is running
                            val awbMode =
                                result.get(CaptureResult.CONTROL_AWB_MODE)
                            if (awbMode == CameraMetadata.CONTROL_AWB_MODE_AUTO) {
                                result
                                    .get(
                                        CaptureResult
                                            .COLOR_CORRECTION_TRANSFORM,
                                    )?.let { capturedColorTransform = it }
                                result
                                    .get(CaptureResult.COLOR_CORRECTION_GAINS)
                                    ?.let { capturedColorGains = it }
                            }
                            // Capture live focus distance (only when AF is ON)
                            if (afEnabled) {
                                result.get(CaptureResult.LENS_FOCUS_DISTANCE)?.let {
                                    capturedFocusDistance = it
                                }
                            }

                            // Capture default AE target FPS range once.
                            if (defaultAeTargetFpsRange == null) {
                                result
                                    .get(
                                        CaptureResult
                                            .CONTROL_AE_TARGET_FPS_RANGE,
                                    )?.let {
                                        defaultAeTargetFpsRange = it
                                        Log.i(
                                            TAG,
                                            "Default AE FPS from first capture result: [${it.lower}, ${it.upper}]",
                                        )
                                    }
                            }

                            // Store latest capture result for diagnostic dumps
                            latestCaptureResult = result
                        }
                    },
                )

            imageAnalysis =
                analysisBuilder.build().also { analysis ->
                    analysis.setAnalyzer(cameraExecutor!!) { imageProxy ->
                        processFrame(imageProxy)
                    }
                }

            val cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA

            stopFpsTimer()
            provider.unbindAll()
            val cam =
                provider.bindToLifecycle(
                    lifecycleOwner,
                    cameraSelector,
                    preview,
                    imageCapture!!,
                    imageAnalysis!!,
                )
            this.camera = cam

            // Resolve and store supported/default/selected AE FPS ranges right after
            // camera bind.
            val selectedRange = resolveMaxAeFpsRange(cam)
            aeTargetFpsRange = selectedRange
            val availableRangesLabel =
                if (availableAeTargetFpsRanges.isEmpty()) {
                    "<none>"
                } else {
                    availableAeTargetFpsRanges.joinToString(", ") {
                        "[${it.lower}, ${it.upper}]"
                    }
                }
            val selectedRangeLabel =
                selectedRange?.let { "[${it.lower}, ${it.upper}]" } ?: "<none>"
            Log.i(TAG, "AE FPS ranges available: $availableRangesLabel")
            Log.i(TAG, "AE FPS selected max range: $selectedRangeLabel")

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
                    val payload = if (includeCapabilitiesInResult) gatherStartupInfo(cam) else gatherResolutionInfo()
                    callback(payload, null)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Camera bind failed", e)
            callback(null, e)
        }
    }

    /** Stop the camera and release resources. */
    fun stopCamera() {
        stopFpsTimer()
        cameraProvider?.unbindAll()
        camera = null
        latestCaptureResult = null
        imageCapture = null
        imageAnalysis?.clearAnalyzer()
        imageAnalysis = null
        defaultAeTargetFpsRange = null
        availableAeTargetFpsRanges = emptyArray()
        aeTargetFpsRange = null

        val executor = cameraExecutor
        if (executor == null) {
            cameraExecutor = null
            return
        }

        executor.shutdown()
        try {
            val terminated = executor.awaitTermination(2, TimeUnit.SECONDS)
            if (!terminated) {
                executor.shutdownNow()
            }
        } catch (_: InterruptedException) {
            executor.shutdownNow()
        }
        cameraExecutor = null
    }

    // ── Frame processing (native-side only) ─────────────────────────────

    private fun processFrame(imageProxy: ImageProxy) {
        try {
            frameCount++

            val processor = frameProcessor ?: return
            processor.processFrame(imageProxy = imageProxy, captureResult = latestCaptureResult)
        } finally {
            imageProxy.close()
        }
    }

    // ── AE FPS range resolution ─────────────────────────────────────────

    @OptIn(ExperimentalCamera2Interop::class)
    private fun resolveMaxAeFpsRange(camera: Camera): Range<Int>? {
        val ranges =
            Camera2CameraInfo
                .from(camera.cameraInfo)
                .getCameraCharacteristic(
                    CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES,
                )
                ?: return null

        if (ranges.isEmpty()) return null
        availableAeTargetFpsRanges = ranges

        val maxUpper = ranges.maxOf { it.upper }

        // Prefer fixed max FPS (e.g. [60,60]) if available.
        val fixedMax = ranges.firstOrNull { it.lower == maxUpper && it.upper == maxUpper }
        if (fixedMax != null) return fixedMax

        // Otherwise pick the range with highest lower bound among ranges that hit max upper.
        return ranges.filter { it.upper == maxUpper }.maxByOrNull { it.lower }
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
                        mapOf("frameCount" to frameCount, "fps" to currentFps),
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

    fun setAfEnabled(
        enabled: Boolean,
        callback: (Exception?) -> Unit,
    ) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        val prev = afEnabled
        afEnabled = enabled
        applyAllCaptureOptions(cam) { e ->
            if (e != null) {
                afEnabled = prev
                callback(e)
            } else {
                callback(null)
            }
        }
    }

    fun getCurrentFocusDistance(): Float = capturedFocusDistance ?: 0f

    fun setFocusDistance(
        distance: Float,
        callback: (Exception?) -> Unit,
    ) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        capturedFocusDistance = distance
        applyAllCaptureOptions(cam, callback)
    }

    // ── AE control ──────────────────────────────────────────────────────

    fun setAeEnabled(
        enabled: Boolean,
        callback: (Exception?) -> Unit,
    ) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        val prev = aeEnabled
        aeEnabled = enabled
        applyAllCaptureOptions(cam) { e ->
            if (e != null) {
                aeEnabled = prev
                callback(e)
            } else {
                callback(null)
            }
        }
    }

    // ── Manual sensor exposure / ISO ─────────────────────────────────

    /** Set the sensor exposure time (nanoseconds). */
    fun setExposureTimeNs(
        ns: Long,
        callback: (Exception?) -> Unit,
    ) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        storedExposureTimeNs = ns
        applyAllCaptureOptions(cam, callback)
    }

    /** Set the sensor ISO. */
    fun setIso(
        iso: Int,
        callback: (Exception?) -> Unit,
    ) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        storedSensitivityIso = iso
        applyAllCaptureOptions(cam, callback)
    }

    // ── Zoom control ────────────────────────────────────────────────────

    fun setZoomRatio(
        ratio: Float,
        callback: (Exception?) -> Unit,
    ) {
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
            ContextCompat.getMainExecutor(context),
        )
    }

    // ── White balance ────────────────────────────────────────────────────

    /**
     * Lock white balance: capture the current live AWB CCM + gains, then switch to
     * CONTROL_AWB_MODE_OFF with those values applied.
     */
    fun setWbLocked(
        locked: Boolean,
        callback: (Exception?) -> Unit,
    ) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        if (locked && (capturedColorTransform == null || capturedColorGains == null)) {
            return callback(
                IllegalStateException("No AWB data captured yet — wait for camera to stabilize"),
            )
        }
        val previous = wbLocked
        wbLocked = locked
        applyAllCaptureOptions(cam) { e ->
            if (e != null) {
                wbLocked = previous
                callback(e)
            } else {
                val message = if (locked) "WB locked with captured CCM + gains" else "WB unlocked — AUTO"
                Log.i(TAG, message)
                callback(null)
            }
        }
    }

    fun isWbLocked(): Boolean = wbLocked

    // ── Capture intent ──────────────────────────────────────────────────

    fun setCaptureIntent(
        intentName: String,
        callback: (Exception?) -> Unit,
    ) {
        val cam = camera ?: return callback(IllegalStateException("Camera not ready"))
        if (intentName != "preview" && intentName != "stillCapture") {
            return callback(IllegalArgumentException("Unknown capture intent: $intentName"))
        }
        val prev = captureIntentPreview
        captureIntentPreview = (intentName == "preview")
        applyAllCaptureOptions(cam) { e ->
            if (e != null) {
                captureIntentPreview = prev
                callback(e)
            } else {
                val label = if (captureIntentPreview) "PREVIEW" else "STILL_CAPTURE"
                Log.i(TAG, "Capture intent → $label")
                callback(null)
            }
        }
    }

    // ── Capture format ──────────────────────────────────────────────────

    /**
     * Switch ImageCapture output format between YUV_420_888 and JPEG.
     * Triggers a full camera rebind (brief preview interruption).
     */
    fun setCaptureFormat(
        formatName: String,
        callback: (Map<String, Any>?, Exception?) -> Unit,
    ) {
        val pv = previewView ?: return callback(null, IllegalStateException("PreviewView not ready"))
        val provider = cameraProvider ?: return callback(null, IllegalStateException("Camera not ready"))

        val prev = captureFormatYuv
        captureFormatYuv = (formatName == "yuv")
        Log.i(TAG, "setCaptureFormat → ${if (captureFormatYuv) "YUV_420_888" else "JPEG"}, rebinding…")
        rebindUseCases(pv = pv, provider = provider) { info, error ->
            if (error != null) captureFormatYuv = prev
            callback(info, error)
        }
    }

    // ── Still capture ────────────────────────────────────────────────────

    /**
     * Trigger a full-resolution still capture for photo-save flows.
     */
    fun capturePhoto(callback: (Exception?) -> Unit) {
        captureStill(
            onCapture = { imageProxy, captureResult ->
                val processor = photoCaptureProcessor
                if (processor != null) {
                    processor.onPhotoCapture(imageProxy, captureResult)
                } else {
                    Log.w(TAG, "capturePhoto: no PhotoCaptureProcessor registered")
                }
            },
            callback = callback,
        )
    }

    /**
     * Trigger a full-resolution still capture for stitching flows.
     */
    fun captureStitchFrame(callback: (Exception?) -> Unit) {
        captureStill(
            onCapture = { imageProxy, captureResult ->
                val processor = stitchFrameProcessor
                if (processor != null) {
                    processor.onStitchFrame(imageProxy, captureResult)
                } else {
                    Log.w(TAG, "captureStitchFrame: no StitchFrameProcessor registered")
                }
            },
            callback = callback,
        )
    }

    /**
     * Trigger a full-resolution still capture. The [ImageProxy] is delivered directly to
     * a dedicated native processor on the camera executor thread — no pixel data crosses the
     * MethodChannel. [ImageProxy.close] is always called here in a finally block.
     *
     * Can be called from Dart or directly from native Kotlin (for example by the stitcher).
     *
     * @param onCapture Processor callback executed on the camera executor thread.
     * @param callback Invoked on the main thread when capture completes or fails.
     */
    private fun captureStill(
        onCapture: (ImageProxy, TotalCaptureResult?) -> Unit,
        callback: (Exception?) -> Unit,
    ) {
        val capture =
            imageCapture ?: return callback(IllegalStateException("Camera not ready"))
        val executor =
            cameraExecutor
                ?: return callback(IllegalStateException("Camera executor not available"))

        capture.takePicture(
            executor,
            object : ImageCapture.OnImageCapturedCallback() {
                override fun onCaptureSuccess(imageProxy: ImageProxy) {
                    try {
                        onCapture(imageProxy, latestCaptureResult)
                    } finally {
                        imageProxy.close()
                    }
                    mainHandler.post { callback(null) }
                }

                override fun onError(exception: ImageCaptureException) {
                    Log.e(TAG, "captureStill failed", exception)
                    mainHandler.post { callback(exception) }
                }
            },
        )
    }

    /**
     * Dumps all available CameraCharacteristics keys and active camera properties for
     * the currently bound CameraX camera instance.
     */
    fun dumpActiveCameraSettings(callback: (Map<String, Any>?, Exception?) -> Unit) {
        val cam = camera ?: return callback(null, IllegalStateException("Camera not ready"))

        CameraSettingsDumper.dump(context, cam, latestCaptureResult, callback)
    }

    // ── Resolution info ─────────────────────────────────────────────────

    fun getResolutionInfo(): Map<String, Any> = gatherResolutionInfo()

    private fun applyStartResolutionOverrides(
        captureWidth: Int?,
        captureHeight: Int?,
        analysisWidth: Int?,
        analysisHeight: Int?,
    ) {
        if ((captureWidth == null) != (captureHeight == null)) {
            throw IllegalArgumentException("captureWidth and captureHeight must be provided together")
        }
        if ((analysisWidth == null) != (analysisHeight == null)) {
            throw IllegalArgumentException("analysisWidth and analysisHeight must be provided together")
        }

        if (captureWidth != null && captureHeight != null) {
            require(captureWidth > 0 && captureHeight > 0) {
                "captureWidth and captureHeight must be > 0"
            }
            preferredCaptureSize = Size(captureWidth, captureHeight)
        }

        if (analysisWidth != null && analysisHeight != null) {
            require(analysisWidth > 0 && analysisHeight > 0) {
                "analysisWidth and analysisHeight must be > 0"
            }
            preferredAnalysisSize = Size(analysisWidth, analysisHeight)
        }
    }

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

    @OptIn(ExperimentalCamera2Interop::class)
    private fun gatherStartupInfo(cam: Camera): Map<String, Any> {
        val result = gatherResolutionInfo().toMutableMap()

        val camera2Info = Camera2CameraInfo.from(cam.cameraInfo)
        val minFocusDistance =
            camera2Info.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)
                ?: 0f
        val zoomState = cam.cameraInfo.zoomState.value

        val exposureRange = exposureTimeRangeNs
        val isoRange = sensitivityIsoRange

        result["minFocusDistance"] = minFocusDistance.toDouble()
        result["minZoomRatio"] = (zoomState?.minZoomRatio ?: 1f).toDouble()
        result["maxZoomRatio"] = (zoomState?.maxZoomRatio ?: 1f).toDouble()
        result["exposureTimeRangeNs"] =
            if (exposureRange != null) {
                listOf(exposureRange.lower, exposureRange.upper)
            } else {
                listOf(1_000_000L, 1_000_000_000L)
            }
        result["isoRange"] =
            if (isoRange != null) {
                listOf(isoRange.lower, isoRange.upper)
            } else {
                listOf(100, 3200)
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
    private fun applyAllCaptureOptions(
        cam: Camera,
        callback: (Exception?) -> Unit,
    ) {
        val camera2Control = Camera2CameraControl.from(cam.cameraControl)

        val afMode =
            if (afEnabled) {
                CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE
            } else {
                CameraMetadata.CONTROL_AF_MODE_OFF
            }

        val aeMode =
            if (aeEnabled) {
                CameraMetadata.CONTROL_AE_MODE_ON
            } else {
                CameraMetadata.CONTROL_AE_MODE_OFF
            }

        val builder =
            CaptureRequestOptions
                .Builder()
                .setCaptureRequestOption(
                    CaptureRequest.CONTROL_MODE,
                    CameraMetadata.CONTROL_MODE_OFF,
                ).setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, afMode)
                .setCaptureRequestOption(CaptureRequest.CONTROL_AE_MODE, aeMode)

        // AE FPS range: keep the selected device-supported max range.
        aeTargetFpsRange?.let {
            builder.setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it)
        }

        // Manual exposure when AE is off
        if (!aeEnabled) {
            builder
                .setCaptureRequestOption(
                    CaptureRequest.SENSOR_EXPOSURE_TIME,
                    storedExposureTimeNs,
                ).setCaptureRequestOption(
                    CaptureRequest.SENSOR_SENSITIVITY,
                    storedSensitivityIso,
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
            builder
                .setCaptureRequestOption(
                    CaptureRequest.CONTROL_AWB_MODE,
                    CameraMetadata.CONTROL_AWB_MODE_OFF,
                ).setCaptureRequestOption(
                    CaptureRequest.COLOR_CORRECTION_MODE,
                    CameraMetadata.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX,
                ).setCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_TRANSFORM, ccm)
                .setCaptureRequestOption(CaptureRequest.COLOR_CORRECTION_GAINS, gains)
        } else {
            builder.setCaptureRequestOption(
                CaptureRequest.CONTROL_AWB_MODE,
                CameraMetadata.CONTROL_AWB_MODE_AUTO,
            )
        }

        // Scene mode disabled — prevent ISP from overriding manual 3A controls.
        builder
            .setCaptureRequestOption(
                CaptureRequest.CONTROL_SCENE_MODE,
                CameraMetadata.CONTROL_SCENE_MODE_DISABLED,
            )

        // Capture intent: PREVIEW for live scanning, STILL_CAPTURE for photo.
        val intent =
            if (captureIntentPreview) {
                CameraMetadata.CONTROL_CAPTURE_INTENT_PREVIEW
            } else {
                CameraMetadata.CONTROL_CAPTURE_INTENT_STILL_CAPTURE
            }
        builder.setCaptureRequestOption(CaptureRequest.CONTROL_CAPTURE_INTENT, intent)

        // ISP quality settings — fixed for WSI: minimise post-processing artefacts.
        builder
            .setCaptureRequestOption(CaptureRequest.EDGE_MODE, CameraMetadata.EDGE_MODE_OFF)
            .setCaptureRequestOption(
                CaptureRequest.NOISE_REDUCTION_MODE,
                CameraMetadata.NOISE_REDUCTION_MODE_FAST,
            ).setCaptureRequestOption(
                CaptureRequest.COLOR_CORRECTION_ABERRATION_MODE,
                CameraMetadata.COLOR_CORRECTION_ABERRATION_MODE_FAST,
            ).setCaptureRequestOption(
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
            ).setCaptureRequestOption(
                CaptureRequest.HOT_PIXEL_MODE,
                CameraMetadata.HOT_PIXEL_MODE_FAST,
            ).setCaptureRequestOption(
                CaptureRequest.SHADING_MODE,
                CameraMetadata.SHADING_MODE_FAST,
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
            ContextCompat.getMainExecutor(context),
        )
    }

    /** Read static CCM from camera characteristics (called once after camera starts). */
    @OptIn(ExperimentalCamera2Interop::class)
    private fun loadStaticColorTransform(cam: Camera) {
        val cam2Info = Camera2CameraInfo.from(cam.cameraInfo)
        staticColorTransform =
            cam2Info.getCameraCharacteristic(CameraCharacteristics.SENSOR_COLOR_TRANSFORM1)
                ?: cam2Info.getCameraCharacteristic(
                    CameraCharacteristics.SENSOR_COLOR_TRANSFORM2,
                )

        // Read device exposure/sensitivity ranges for manual mode
        val exposureRange: Range<Long>? =
            cam2Info.getCameraCharacteristic(
                CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE,
            )
        val sensitivityRange: Range<Int>? =
            cam2Info.getCameraCharacteristic(
                CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE,
            )
        exposureTimeRangeNs = exposureRange
        sensitivityIsoRange = sensitivityRange
        storedExposureTimeNs = exposureRange?.clamp(1_000_000L) ?: 1_000_000L
        storedSensitivityIso = sensitivityRange?.clamp(200) ?: 200

        Log.i(TAG, "Exposure range: $exposureRange → using ${storedExposureTimeNs}ns")
        Log.i(TAG, "Sensitivity range: $sensitivityRange → using ISO $storedSensitivityIso")
    }

    /** Push a typed event to Dart on the main thread. */
    private fun pushEvent(
        type: String,
        tag: String,
        message: String,
        data: Map<String, Any> = emptyMap(),
    ) {
        val event = mutableMapOf<String, Any>("type" to type, "tag" to tag, "message" to message)
        if (data.isNotEmpty()) event["data"] = data
        mainHandler.post { eventSink?.success(event) }
    }
}
