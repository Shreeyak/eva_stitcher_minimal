package com.example.eva_camera

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.ColorSpaceTransform
import android.os.Build
import android.util.Log
import android.util.Range
import android.util.Size
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import java.io.File
import java.lang.reflect.Modifier
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Handles generating and saving a comprehensive camera settings dump.
 */
object CameraSettingsDumper {
    private const val TAG = "CameraSettingsDumper"

    data class CameraSettingsDump(
        val content: String,
        val keyCount: Int,
        val supportedKeyCount: Int,
    )

    /**
     * Dumps all available CameraCharacteristics keys and active camera properties.
     */
    @OptIn(ExperimentalCamera2Interop::class)
    fun dump(
        context: Context,
        camera: Camera,
        captureResult: TotalCaptureResult?,
        callback: (Map<String, Any>?, Exception?) -> Unit,
    ) {
        try {
            val cam2Info = Camera2CameraInfo.from(camera.cameraInfo)
            val dump = buildDump(camera, cam2Info, captureResult)

            val outDir = context.getExternalFilesDir(null) ?: context.filesDir
            val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
            val outFile = File(outDir, "camera_settings_dump_$timestamp.txt")
            outFile.writeText(dump.content)

            Log.i(TAG, "=== Camera settings dump begin ===")
            dump.content.lineSequence().forEach { Log.i(TAG, it) }
            Log.i(TAG, "Saved camera settings dump to: ${outFile.absolutePath}")
            Log.i(TAG, "=== Camera settings dump end ===")

            callback(
                mapOf(
                    "filePath" to outFile.absolutePath,
                    "keyCount" to dump.keyCount,
                    "supportedKeyCount" to dump.supportedKeyCount,
                ),
                null,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to dump active camera settings", e)
            callback(null, e)
        }
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun buildDump(
        cam: Camera,
        cam2Info: Camera2CameraInfo,
        captureResult: TotalCaptureResult?,
    ): CameraSettingsDump {
        val timestamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())
        val sb = StringBuilder()
        val cameraId = runCatching { cam2Info.cameraId }.getOrElse { "<unknown>" }

        sb.appendLine("# CameraX + Camera2 Settings Dump")
        sb.appendLine("# Generated: $timestamp")
        sb.appendLine("# Device: ${Build.MANUFACTURER} ${Build.MODEL} (API ${Build.VERSION.SDK_INT})")
        sb.appendLine("# Active Camera ID: $cameraId")

        section(sb, "ACTIVE CAMERAX CAMERA PROPERTIES")
        sb.appendLine("Has flash unit                                          : ${cam.cameraInfo.hasFlashUnit()}")
        sb.appendLine("Torch state                                             : ${cam.cameraInfo.torchState.value}")

        val zoomState = cam.cameraInfo.zoomState.value
        sb.appendLine(
            "Zoom ratio (current/min/max)                            : ${zoomState?.zoomRatio} / ${zoomState?.minZoomRatio} / ${zoomState?.maxZoomRatio}",
        )

        val exposureState = cam.cameraInfo.exposureState
        sb.appendLine("Exposure compensation index (current)                   : ${exposureState.exposureCompensationIndex}")
        sb.appendLine(
            "Exposure compensation range                             : [${exposureState.exposureCompensationRange.lower}, ${exposureState.exposureCompensationRange.upper}]",
        )
        sb.appendLine("Exposure compensation step                              : ${exposureState.exposureCompensationStep}")

        if (captureResult != null) {
            section(sb, "LATEST CAPTURE RESULT (Real-time hardware state)")

            val resultKeyFields =
                CaptureResult::class.java.fields
                    .filter {
                        Modifier.isStatic(it.modifiers) &&
                            CaptureResult.Key::class.java.isAssignableFrom(it.type)
                    }.sortedBy { it.name }

            for (field in resultKeyFields) {
                val key = runCatching { field.get(null) as? CaptureResult.Key<Any> }.getOrNull()
                if (key == null) continue

                val value = runCatching { captureResult.get(key) }.getOrNull()
                sb.append(field.name.padEnd(60))
                sb.append(": ")
                sb.appendLine(formatResultValue(value))
            }
        }

        section(sb, "ALL CAMERA2 CHARACTERISTICS KEYS (via Camera2CameraInfo)")

        val keyFields =
            CameraCharacteristics::class.java.fields
                .filter {
                    Modifier.isStatic(it.modifiers) &&
                        CameraCharacteristics.Key::class.java.isAssignableFrom(it.type)
                }.sortedBy { it.name }

        var keyCount = 0
        var supportedKeyCount = 0

        for (field in keyFields) {
            val key = runCatching { field.get(null) as? CameraCharacteristics.Key<Any> }.getOrNull()
            if (key == null) continue

            keyCount += 1
            val value = runCatching { cam2Info.getCameraCharacteristic(key) }.getOrNull()
            if (value != null) supportedKeyCount += 1

            sb.append(field.name.padEnd(60))
            sb.append(": ")
            sb.appendLine(formatCharacteristicValue(value))
        }

        section(sb, "SUMMARY")
        sb.appendLine("Total CameraCharacteristics keys reflected              : $keyCount")
        sb.appendLine("Supported/non-null keys on active camera                : $supportedKeyCount")
        sb.appendLine()
        sb.appendLine("# --- END OF DUMP ---")

        return CameraSettingsDump(
            content = sb.toString(),
            keyCount = keyCount,
            supportedKeyCount = supportedKeyCount,
        )
    }

    private fun section(
        sb: StringBuilder,
        title: String,
    ) {
        sb.appendLine()
        sb.appendLine("# ── $title " + "─".repeat(maxOf(0, 60 - title.length)))
    }

    private fun formatResultValue(value: Any?): String =
        when (value) {
            null -> {
                "<null>"
            }

            is FloatArray -> {
                value.joinToString(prefix = "[", postfix = "]") { "%.6f".format(it) }
            }

            is IntArray -> {
                value.contentToString()
            }

            is LongArray -> {
                value.contentToString()
            }

            is Range<*> -> {
                "[${value.lower}, ${value.upper}]"
            }

            is Size -> {
                "${value.width}x${value.height}"
            }

            is ColorSpaceTransform -> {
                val mat = FloatArray(9)
                var idx = 0
                for (r in 0..2) {
                    for (c in 0..2) {
                        mat[idx++] = value.getElement(c, r).toFloat()
                    }
                }
                mat.joinToString(prefix = "[", postfix = "]") { "%.4f".format(it) }
            }

            else -> {
                value.toString()
            }
        }

    private fun formatCharacteristicValue(value: Any?): String =
        when (value) {
            null -> {
                "<not supported>"
            }

            is FloatArray -> {
                value.joinToString(prefix = "[", postfix = "]") { "%.6f".format(it) }
            }

            is IntArray -> {
                value.joinToString(prefix = "[", postfix = "]")
            }

            is LongArray -> {
                value.joinToString(prefix = "[", postfix = "]")
            }

            is DoubleArray -> {
                value.joinToString(prefix = "[", postfix = "]") { "%.6f".format(it) }
            }

            is ByteArray -> {
                value.joinToString(prefix = "[", postfix = "]") { it.toInt().and(0xFF).toString() }
            }

            is Array<*> -> {
                value.joinToString(prefix = "[", postfix = "]") { formatCharacteristicValue(it) }
            }

            is android.hardware.camera2.params.StreamConfigurationMap -> {
                formatStreamConfigurationMap(value)
            }

            else -> {
                formatSingleCharacteristicValue(value)
            }
        }

    private fun formatSingleCharacteristicValue(v: Any?): String =
        when (v) {
            null -> {
                "null"
            }

            is Range<*> -> {
                "[${v.lower}, ${v.upper}]"
            }

            is Size -> {
                "${v.width}x${v.height}"
            }

            is android.util.SizeF -> {
                "${v.width}x${v.height}"
            }

            is android.util.Rational -> {
                "${v.numerator}/${v.denominator}"
            }

            is android.graphics.Rect -> {
                "(${v.left},${v.top})-(${v.right},${v.bottom})"
            }

            is android.hardware.camera2.params.BlackLevelPattern -> {
                "[${v.getOffsetForIndex(0,0)}, ${v.getOffsetForIndex(1,0)}, ${v.getOffsetForIndex(0,1)}, ${v.getOffsetForIndex(1,1)}]"
            }

            is ColorSpaceTransform -> {
                buildString {
                    append("[")
                    for (row in 0..2) {
                        for (col in 0..2) {
                            append(
                                "${v.getElement(col, row).numerator}/${v.getElement(col, row).denominator}",
                            )
                            if (!(row == 2 && col == 2)) append(", ")
                        }
                    }
                    append("]")
                }
            }

            else -> {
                v.toString()
            }
        }

    private fun formatStreamConfigurationMap(map: android.hardware.camera2.params.StreamConfigurationMap): String {
        val outputs =
            map.outputFormats.joinToString(separator = "; ") { format ->
                val sizes =
                    map
                        .getOutputSizes(format)
                        ?.joinToString(prefix = "[", postfix = "]") { "${it.width}x${it.height}" }
                        ?: "[]"
                "${imageFormatName(format)}=$sizes"
            }

        val inputs =
            map.inputFormats.joinToString(separator = "; ") { format ->
                val sizes =
                    map
                        .getInputSizes(format)
                        ?.joinToString(prefix = "[", postfix = "]") { "${it.width}x${it.height}" }
                        ?: "[]"
                "${imageFormatName(format)}=$sizes"
            }

        return "outputs{$outputs} inputs{$inputs}"
    }

    private fun imageFormatName(format: Int): String =
        when (format) {
            ImageFormat.YUV_420_888 -> "YUV_420_888"
            ImageFormat.JPEG -> "JPEG"
            ImageFormat.RAW_SENSOR -> "RAW_SENSOR"
            ImageFormat.PRIVATE -> "PRIVATE"
            ImageFormat.DEPTH16 -> "DEPTH16"
            ImageFormat.DEPTH_JPEG -> "DEPTH_JPEG"
            ImageFormat.HEIC -> "HEIC"
            else -> "format_$format"
        }
}
