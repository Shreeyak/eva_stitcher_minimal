package com.example.eva_camera

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class EvaCameraPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    companion object {
        private const val TAG = "EvaCameraPlugin"
        private const val METHOD_CHANNEL = "com.example.eva/control"
        private const val EVENTS_CHANNEL = "com.example.eva/events"
        private const val CAMERA_VIEW_TYPE = "camerax-preview"
        private const val CAMERA_PERMISSION_CODE = 1001

        @Volatile private var frameProcessor: FrameProcessor? = null

        @Volatile private var photoCaptureProcessor: PhotoCaptureProcessor? = null

        @Volatile private var stitchFrameProcessor: StitchFrameProcessor? = null

        /** Register a [FrameProcessor] to receive every ImageAnalysis frame. */
        @JvmStatic
        fun setFrameProcessor(processor: FrameProcessor?) {
            frameProcessor = processor
        }

        /** Register a [PhotoCaptureProcessor] for user-triggered photo captures. */
        @JvmStatic
        fun setPhotoCaptureProcessor(processor: PhotoCaptureProcessor?) {
            photoCaptureProcessor = processor
        }

        /** Register a [StitchFrameProcessor] for stitch-frame captures. */
        @JvmStatic
        fun setStitchFrameProcessor(processor: StitchFrameProcessor?) {
            stitchFrameProcessor = processor
        }
    }

    private var methodChannel: MethodChannel? = null
    private var eventsChannel: EventChannel? = null
    private var cameraManager: CameraManager? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    // ── FlutterPlugin ────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger

        // PlatformView factory — registered eagerly; CameraManager is set lazily
        // once an Activity (and therefore a LifecycleOwner) is available.
        binding.platformViewRegistry.registerViewFactory(
            CAMERA_VIEW_TYPE,
            CameraPreviewFactory(
                onViewCreated = { pv -> cameraManager?.setPreviewView(pv) },
                onViewDisposed = { cameraManager?.onPreviewDisposed() },
            ),
        )

        methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
        eventsChannel = EventChannel(messenger, EVENTS_CHANNEL)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventsChannel?.setStreamHandler(null)
        eventsChannel = null
        cameraManager?.stopCamera()
        cameraManager?.destroy()
        cameraManager = null
    }

    // ── ActivityAware ────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)

        val activity = binding.activity
        val lifecycleOwner =
            activity as? LifecycleOwner
                ?: throw IllegalStateException(
                    "EvaCameraPlugin requires the host Activity to implement LifecycleOwner",
                )

        val manager =
            CameraManager(activity, lifecycleOwner).also {
                it.frameProcessor = frameProcessor
                it.photoCaptureProcessor = photoCaptureProcessor
                it.stitchFrameProcessor = stitchFrameProcessor
            }
        cameraManager = manager

        setupMethodChannel(activity, manager)
        setupEventChannel(manager)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        cameraManager?.stopCamera()
        cameraManager = null
        methodChannel?.setMethodCallHandler(null)
        eventsChannel?.setStreamHandler(null)
    }

    // ── Permission callback ──────────────────────────────────────────

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != CAMERA_PERMISSION_CODE) return false
        val granted =
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
        return true
    }

    // ── Channel wiring ───────────────────────────────────────────────

    private fun setupMethodChannel(
        activity: Activity,
        manager: CameraManager,
    ) {
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> {
                    if (ContextCompat.checkSelfPermission(
                            activity,
                            Manifest.permission.CAMERA,
                        ) == PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success(true)
                    } else {
                        ActivityCompat.requestPermissions(
                            activity,
                            arrayOf(Manifest.permission.CAMERA),
                            CAMERA_PERMISSION_CODE,
                        )
                        pendingPermissionResult = result
                    }
                }

                "startCamera" -> {
                    val captureWidth = call.argument<Int>("captureWidth")
                    val captureHeight = call.argument<Int>("captureHeight")
                    val analysisWidth = call.argument<Int>("analysisWidth")
                    val analysisHeight = call.argument<Int>("analysisHeight")

                    manager.startCamera(
                        captureWidth = captureWidth,
                        captureHeight = captureHeight,
                        analysisWidth = analysisWidth,
                        analysisHeight = analysisHeight,
                    ) { info, error ->
                        if (error != null) {
                            result.error("CAMERA_START_FAILED", error.message, null)
                        } else {
                            result.success(info)
                        }
                    }
                }

                "stopCamera" -> {
                    manager.stopCamera()
                    result.success(null)
                }

                "dumpActiveCameraSettings" -> {
                    manager.dumpActiveCameraSettings { dumpInfo, error ->
                        if (error != null) {
                            result.error("DUMP_SETTINGS_FAILED", error.message, null)
                        } else {
                            result.success(dumpInfo)
                        }
                    }
                }

                "setWbLocked" -> {
                    val locked = call.argument<Boolean>("locked") ?: false
                    manager.setWbLocked(locked) { error ->
                        if (error != null) {
                            result.error("WB_SET_FAILED", error.message, null)
                        } else {
                            result.success(null)
                        }
                    }
                }

                "setAfEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    manager.setAfEnabled(enabled) { error ->
                        if (error != null) {
                            result.error("AF_SET_FAILED", error.message, null)
                        } else {
                            result.success(null)
                        }
                    }
                }

                "setAeEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    manager.setAeEnabled(enabled) { error ->
                        if (error != null) {
                            result.error("AE_SET_FAILED", error.message, null)
                        } else {
                            result.success(null)
                        }
                    }
                }

                "getCurrentFocusDistance" -> {
                    result.success(manager.getCurrentFocusDistance().toDouble())
                }

                "setFocusDistance" -> {
                    val distance = call.argument<Double>("distance")
                    if (distance != null) {
                        manager.setFocusDistance(distance.toFloat()) { error ->
                            if (error != null) {
                                result.error("FOCUS_SET_FAILED", error.message, null)
                            } else {
                                result.success(null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "Focus distance missing", null)
                    }
                }

                "setZoomRatio" -> {
                    val ratio = call.argument<Double>("ratio") ?: 1.0
                    manager.setZoomRatio(ratio.toFloat()) { error ->
                        if (error != null) {
                            result.error("ZOOM_RATIO_FAILED", error.message, null)
                        } else {
                            result.success(null)
                        }
                    }
                }

                "getResolution" -> {
                    result.success(manager.getResolutionInfo())
                }

                "setExposureTimeNs" -> {
                    val ns = (call.argument<Number>("ns") ?: 1_000_000L).toLong()
                    manager.setExposureTimeNs(ns) { error ->
                        if (error != null) {
                            result.error("EXPOSURE_SET_FAILED", error.message, null)
                        } else {
                            result.success(null)
                        }
                    }
                }

                "setIso" -> {
                    val iso = call.argument<Int>("iso") ?: 200
                    manager.setIso(iso) { error ->
                        if (error != null) {
                            result.error("ISO_SET_FAILED", error.message, null)
                        } else {
                            result.success(null)
                        }
                    }
                }

                "setCaptureIntent" -> {
                    val intentName = call.argument<String>("intent") ?: "preview"
                    manager.setCaptureIntent(intentName) { error ->
                        if (error != null) {
                            result.error("CAPTURE_INTENT_FAILED", error.message, null)
                        } else {
                            result.success(null)
                        }
                    }
                }

                "capturePhoto" -> {
                    manager.capturePhoto { error ->
                        if (error != null) {
                            result.error("CAPTURE_PHOTO_FAILED", error.message, null)
                        } else {
                            result.success(null)
                        }
                    }
                }

                "captureStitchFrame" -> {
                    manager.captureStitchFrame { error ->
                        if (error != null) {
                            result.error("CAPTURE_STITCH_FRAME_FAILED", error.message, null)
                        } else {
                            result.success(null)
                        }
                    }
                }

                "setCaptureFormat" -> {
                    val format = call.argument<String>("format") ?: "yuv"
                    manager.setCaptureFormat(format) { info, error ->
                        if (error != null) {
                            result.error("CAPTURE_FORMAT_FAILED", error.message, null)
                        } else {
                            result.success(info)
                        }
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun setupEventChannel(manager: CameraManager) {
        eventsChannel?.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(
                    arguments: Any?,
                    events: EventChannel.EventSink?,
                ) {
                    Log.i(TAG, "Events stream: Dart listener attached")
                    manager.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    Log.i(TAG, "Events stream: Dart listener detached")
                    manager.setEventSink(null)
                }
            },
        )
    }
}
