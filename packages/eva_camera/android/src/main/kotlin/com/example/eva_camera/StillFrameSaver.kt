package com.example.eva_camera

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import androidx.camera.core.ImageProxy
import androidx.exifinterface.media.ExifInterface
import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Utility for saving an [ImageProxy] to the MediaStore gallery.
 *
 * - YUV_420_888 frames are saved as PNG (lossless, converted via YUV→NV21→Bitmap).
 * - JPEG frames are saved as JPEG (planes[0] bytes written directly).
 *
 * All functions are blocking — call from a background thread, e.g. inside
 * [StillCaptureProcessor.onStillCapture]. The caller retains ownership of [imageProxy]
 * and must still call [ImageProxy.close] after this returns.
 */
object StillFrameSaver {
    private const val TAG = "StillFrameSaver"
    private const val RELATIVE_PATH = "Pictures/EvaWSI"

    /**
     * Save [imageProxy] to MediaStore.
     *
     * @return Relative path of the saved file, e.g. "Pictures/EvaWSI/EVA_20260313_120000_000.png".
     */
    fun saveToMediaStore(
        context: Context,
        imageProxy: ImageProxy,
    ): String =
        if (imageProxy.format == ImageFormat.JPEG) {
            saveJpegProxy(context, imageProxy)
        } else {
            saveYuvProxyAsPng(context, imageProxy)
        }

    // ── YUV → PNG ────────────────────────────────────────────────────────

    private fun saveYuvProxyAsPng(
        context: Context,
        imageProxy: ImageProxy,
    ): String {
        val bitmap = yuvProxyToBitmap(imageProxy)
        val filename = "EVA_${timestamp()}.png"
        val cv =
            ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
                put(MediaStore.MediaColumns.MIME_TYPE, "image/png")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Images.Media.RELATIVE_PATH, RELATIVE_PATH)
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
            }

        val uri =
            context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv)
                ?: throw IllegalStateException("MediaStore insert returned null")

        context.contentResolver.openOutputStream(uri)?.use { os ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, os)
        }
        bitmap.recycle()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            context.contentResolver.update(
                uri,
                ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
                null,
                null,
            )
        }

        val path = "$RELATIVE_PATH/$filename"
        Log.i(TAG, "Saved YUV ${imageProxy.width}x${imageProxy.height} as PNG → $path")
        return path
    }

    // ── JPEG planes[0] → JPEG ─────────────────────────────────────────────

    private fun saveJpegProxy(
        context: Context,
        imageProxy: ImageProxy,
    ): String {
        val filename = "EVA_${timestamp()}.jpg"
        val cv =
            ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
                put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Images.Media.RELATIVE_PATH, RELATIVE_PATH)
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
            }

        val uri =
            context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cv)
                ?: throw IllegalStateException("MediaStore insert returned null")

        val buf = imageProxy.planes[0].buffer
        context.contentResolver.openOutputStream(uri)?.use { os ->
            val bytes = ByteArray(buf.remaining())
            buf.get(bytes)
            os.write(bytes)
        }
        writeExifRotation(context, uri, imageProxy.imageInfo.rotationDegrees)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            context.contentResolver.update(
                uri,
                ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
                null,
                null,
            )
        }

        val path = "$RELATIVE_PATH/$filename"
        Log.i(TAG, "Saved JPEG ${imageProxy.width}x${imageProxy.height} → $path")
        return path
    }

    // ── YUV → Bitmap ─────────────────────────────────────────────────────

    /**
     * Convert YUV_420_888 [ImageProxy] to a [Bitmap] via an NV21 intermediate.
     *
     * Routes through [YuvImage.compressToJpeg] at 100% quality then decodes with
     * [BitmapFactory] — the standard Android YUV→RGB path with no extra dependencies.
     * Reads [ImageProxy.getPlanes] ByteBuffers directly without an intermediate ByteArray copy.
     */
    private fun yuvProxyToBitmap(imageProxy: ImageProxy): Bitmap {
        val yPlane = imageProxy.planes[0]
        val uPlane = imageProxy.planes[1]
        val vPlane = imageProxy.planes[2]
        val nv21 =
            yuv420ToNv21(
                yBuf = yPlane.buffer,
                uBuf = uPlane.buffer,
                vBuf = vPlane.buffer,
                width = imageProxy.width,
                height = imageProxy.height,
                yRowStride = yPlane.rowStride,
                uvRowStride = uPlane.rowStride,
                uvPixelStride = uPlane.pixelStride,
            )
        val yuvImage = YuvImage(nv21, ImageFormat.NV21, imageProxy.width, imageProxy.height, null)
        val out = ByteArrayOutputStream()
        yuvImage.compressToJpeg(Rect(0, 0, imageProxy.width, imageProxy.height), 100, out)
        val bytes = out.toByteArray()
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    }

    /**
     * Repack YUV_420_888 plane ByteBuffers (arbitrary stride/pixelStride) into tightly-packed NV21.
     * NV21 layout: Y plane, then interleaved V/U pairs.
     * Reads planes in-place from ByteBuffers — no intermediate ByteArray allocation.
     */
    private fun yuv420ToNv21(
        yBuf: java.nio.ByteBuffer,
        uBuf: java.nio.ByteBuffer,
        vBuf: java.nio.ByteBuffer,
        width: Int,
        height: Int,
        yRowStride: Int,
        uvRowStride: Int,
        uvPixelStride: Int,
    ): ByteArray {
        val nv21 = ByteArray(width * height * 3 / 2)

        // Copy Y rows, stripping row padding.
        for (row in 0 until height) {
            val rowOffset = row * yRowStride
            yBuf.position(rowOffset)
            yBuf.get(nv21, row * width, width)
        }

        // Interleave V then U into NV21 chroma region.
        var dstIdx = width * height
        for (row in 0 until height / 2) {
            for (col in 0 until width / 2) {
                val srcIdx = row * uvRowStride + col * uvPixelStride
                nv21[dstIdx++] = vBuf[srcIdx]
                nv21[dstIdx++] = uBuf[srcIdx]
            }
        }
        return nv21
    }

    private fun writeExifRotation(
        context: Context,
        uri: android.net.Uri,
        rotationDegrees: Int,
    ) {
        val exifOrientation =
            when (rotationDegrees) {
                90 -> ExifInterface.ORIENTATION_ROTATE_90
                180 -> ExifInterface.ORIENTATION_ROTATE_180
                270 -> ExifInterface.ORIENTATION_ROTATE_270
                else -> ExifInterface.ORIENTATION_NORMAL
            }
        try {
            context.contentResolver.openFileDescriptor(uri, "rw")?.use { pfd ->
                ExifInterface(pfd.fileDescriptor).apply {
                    setAttribute(ExifInterface.TAG_ORIENTATION, exifOrientation.toString())
                    saveAttributes()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not write EXIF orientation", e)
        }
    }

    private fun timestamp(): String = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).format(Date())
}
