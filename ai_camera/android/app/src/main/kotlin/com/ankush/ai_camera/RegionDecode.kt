package com.ankush.ai_camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Matrix
import android.graphics.Rect
import android.media.ExifInterface

/**
 * v11.60 burst merge: decode ONLY the zoomed region of a full-resolution
 * JPEG (BitmapRegionDecoder), upright (EXIF rotation applied), written as
 * packed RGB bytes. Avoids decoding 12–50 MP stills on cheap phones.
 * Mirrored EXIF orientations are not handled (error → Dart fallback).
 */
object RegionDecode {
    /** Upright size + EXIF orientation degrees, or null if unsupported. */
    fun info(path: String): Map<String, Any> {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, o)
        val deg = degrees(path) ?: throw IllegalStateException("mirrored orientation")
        val swap = deg == 90 || deg == 270
        return mapOf(
            "width" to (if (swap) o.outHeight else o.outWidth),
            "height" to (if (swap) o.outWidth else o.outHeight),
            "degrees" to deg,
        )
    }

    private fun degrees(path: String): Int? =
        when (ExifInterface(path).getAttributeInt(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.ORIENTATION_NORMAL,
        )) {
            ExifInterface.ORIENTATION_NORMAL, ExifInterface.ORIENTATION_UNDEFINED -> 0
            ExifInterface.ORIENTATION_ROTATE_90 -> 90
            ExifInterface.ORIENTATION_ROTATE_180 -> 180
            ExifInterface.ORIENTATION_ROTATE_270 -> 270
            else -> null
        }

    /**
     * Upright pixel rect (x, y, w, h), downscaled by [sample] (power of 2,
     * BitmapFactory inSampleSize), → packed RGB bytes + size.
     */
    fun decodeBytes(path: String, x: Int, y: Int, w: Int, h: Int, sample: Int): Map<String, Any> {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, o)
        val rw = o.outWidth
        val rh = o.outHeight
        val deg = degrees(path) ?: throw IllegalStateException("mirrored orientation")
        val uw = if (deg == 90 || deg == 270) rh else rw
        val uh = if (deg == 90 || deg == 270) rw else rh
        val l = x.coerceIn(0, uw - 1)
        val t = y.coerceIn(0, uh - 1)
        val r = (x + w).coerceIn(l + 1, uw)
        val b = (y + h).coerceIn(t + 1, uh)
        // Upright rect → stored (raw) rect.
        val raw = when (deg) {
            90 -> Rect(t, rh - r, b, rh - l)
            180 -> Rect(rw - r, rh - b, rw - l, rh - t)
            270 -> Rect(rw - b, l, rw - t, r)
            else -> Rect(l, t, r, b)
        }
        @Suppress("DEPRECATION")
        val dec = BitmapRegionDecoder.newInstance(path, false)
            ?: throw IllegalStateException("no region decoder")
        val opts = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inSampleSize = sample.coerceIn(1, 64)
        }
        var bmp = try {
            dec.decodeRegion(raw, opts)
        } finally {
            dec.recycle()
        }
        if (deg != 0) {
            val m = Matrix().apply { postRotate(deg.toFloat()) }
            val rot = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, false)
            if (rot !== bmp) bmp.recycle()
            bmp = rot
        }
        val ow = bmp.width
        val oh = bmp.height
        val row = IntArray(ow)
        val bytes = ByteArray(ow * oh * 3)
        var j = 0
        for (yy in 0 until oh) {
            bmp.getPixels(row, 0, ow, 0, yy, ow, 1)
            for (p in row) {
                bytes[j++] = (p shr 16 and 0xff).toByte()
                bytes[j++] = (p shr 8 and 0xff).toByte()
                bytes[j++] = (p and 0xff).toByte()
            }
        }
        bmp.recycle()
        return mapOf("width" to ow, "height" to oh, "rgb" to bytes)
    }
}
