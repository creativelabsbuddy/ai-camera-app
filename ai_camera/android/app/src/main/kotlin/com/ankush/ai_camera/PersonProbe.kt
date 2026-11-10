package com.ankush.ai_camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.FaceDetector

/**
 * Lightweight "is there a person?" check for outfit / person AI looks.
 * Uses the framework's built-in android.media.FaceDetector (no ML Kit
 * download, no APK size). Frontal-ish faces only, so the app treats a
 * miss as a warning ("Apply anyway"), never a block.
 */
object PersonProbe {
    private const val MAX_LONG = 1024
    private const val MAX_FACES = 5

    /** Number of faces found, or -1 when the image can't be read. */
    fun countFaces(path: String): Int {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return -1
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_LONG) {
            sample *= 2
        }
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.RGB_565
        }
        var bmp = BitmapFactory.decodeFile(path, opts) ?: return -1
        val rotation = try {
            when (ExifInterface(path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL,
            )) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } catch (e: Exception) {
            0f
        }
        if (rotation != 0f) {
            val m = Matrix().apply { postRotate(rotation) }
            bmp = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, m, true)
        }
        // FaceDetector needs RGB_565 and an even width.
        val evenW = bmp.width and 1.inv()
        if (evenW != bmp.width) bmp = Bitmap.createBitmap(bmp, 0, 0, evenW, bmp.height)
        if (bmp.config != Bitmap.Config.RGB_565) bmp = bmp.copy(Bitmap.Config.RGB_565, false)
        val faces = arrayOfNulls<FaceDetector.Face>(MAX_FACES)
        return FaceDetector(bmp.width, bmp.height, MAX_FACES).findFaces(bmp, faces)
    }
}
