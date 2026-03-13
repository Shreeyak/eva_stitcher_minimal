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

        private var frameProcessor: FrameProcessor? = null

        /** Register a [FrameProcessor] to receive every ImageAnalysis frame. */
        @JvmStatic
        fun setFrameProcessor(processor: FrameProcessor?) {
            frameProcessor = processor
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
                    manager.startCamera { info, error ->
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

                "saveFrame" -> {
                    manager.saveFrame { path, error ->
                        if (error != null) {
                            result.error("SAVE_FAILED", error.message, null)
                        } else {
                            result.success(path)
                        }
                    }
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

                "lockWhiteBalance" -> {
                    manager.lockWhiteBalance { error ->
                        if (error != null) {
                            result.error("WB_LOCK_FAILED", error.message, null)
                        } else {
                            result.success(true)
                        }
                    }
                }

                "unlockWhiteBalance" -> {
                    manager.unlockWhiteBalance { error ->
                        if (error != null) {
                            result.error("WB_UNLOCK_FAILED", error.message, null)
                        } else {
                            result.success(true)
                        }
                    }
                }

                "isWbLocked" -> {
                    result.success(manager.isWbLocked())
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

                "getExposureOffsetStep" -> {
                    result.success(manager.getExposureOffsetStep())
                }

                "getExposureOffsetRange" -> {
                    result.success(manager.getExposureOffsetRange())
                }

                "setExposureOffset" -> {
                    val index = call.argument<Int>("index") ?: 0
                    manager.setExposureOffset(index) { error ->
                        if (error != null) {
                            result.error("EXPOSURE_OFFSET_FAILED", error.message, null)
                        } else {
                            result.success(null)
                        }
                    }
                }

                "getMinFocusDistance" -> {
                    result.success(manager.getMinFocusDistance().toDouble())
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

                "getMinZoomRatio" -> {
                    result.success(manager.getMinZoomRatio().toDouble())
                }

                "getMaxZoomRatio" -> {
                    result.success(manager.getMaxZoomRatio().toDouble())
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

                "getExposureTimeRangeNs" -> {
                    result.success(manager.getExposureTimeRangeNs())
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

                "getIsoRange" -> {
                    result.success(manager.getIsoRange())
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
