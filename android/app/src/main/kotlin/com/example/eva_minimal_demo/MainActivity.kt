package com.example.eva_minimal_demo

import android.Manifest
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter activity that wires up:
 * - PlatformView factory for CameraX PreviewView ("camerax-preview")
 * - MethodChannel for camera control commands
 * - EventChannel for status/diagnostic events
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "EvaCamera"
        private const val METHOD_CHANNEL = "com.example.eva/control"
        private const val EVENTS_CHANNEL = "com.example.eva/events"
        private const val CAMERA_PERMISSION_CODE = 1001
    }

    private var cameraManager: CameraManager? = null
    private var methodChannel: MethodChannel? = null
    private var eventsChannel: EventChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val manager = CameraManager(this, this)
        cameraManager = manager

        // ── Register PlatformView factory ──
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "camerax-preview",
            CameraPreviewFactory(
                onViewCreated = { previewView -> manager.setPreviewView(previewView) },
                onViewDisposed = { manager.onPreviewDisposed() },
            ),
        )

        // ── MethodChannel for camera commands ──
        methodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "requestPermission" -> {
                            if (ContextCompat.checkSelfPermission(
                                    this,
                                    Manifest.permission.CAMERA,
                                ) == PackageManager.PERMISSION_GRANTED
                            ) {
                                result.success(true)
                            } else {
                                ActivityCompat.requestPermissions(
                                    this,
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

        // ── EventChannel for status/diagnostic events ──
        eventsChannel =
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS_CHANNEL).also { channel ->
                channel.setStreamHandler(
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

    // ── Permission handling ──────────────────────────────────────────────
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_CODE) {
            val granted =
                grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    override fun onDestroy() {
        cameraManager?.stopCamera()
        cameraManager = null
        methodChannel?.setMethodCallHandler(null)
        eventsChannel?.setStreamHandler(null)
        super.onDestroy()
    }
}
