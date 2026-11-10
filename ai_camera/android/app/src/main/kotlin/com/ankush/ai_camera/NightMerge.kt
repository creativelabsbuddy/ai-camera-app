package com.ankush.ai_camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.media.Image
import java.io.File
import java.io.FileOutputStream
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * v11 Night: streaming burst merge (one frame in memory at a time).
 *
 * add(frame): global-shift alignment against the first frame (coarse 160 px
 * ±6 → fine 320 px ±2 SAD search on a luma proxy; frames that don't match
 * — big motion — are skipped), then accumulated into planar Y (full) + U/V
 * (half) sums. finish(): average → black point → tone curve → chroma
 * denoise → luma denoise in the lifted shadows → RGB, rotated upright, JPEG.
 *
 * Tone ("bright" = Normal Night, Samsung-like bright; "natural" = Pro Night
 * before the AI, keeps the night look): S(y) = (1 − e^(−a·y)) / (1 − e^(−a)),
 * never clips (S(1) = 1); `a` is solved so the mean reaches the target, with
 * the shadow gain capped. Mirrored in lib/services/night_tone.dart (tests).
 */
class NightMerge(
    private val w: Int,
    private val h: Int,
    private val tone: String,
) {
    private val cw = (w + 1) / 2
    private val ch = (h + 1) / 2
    private val sumY = ShortArray(w * h)
    private val sumU = ShortArray(cw * ch)
    private val sumV = ShortArray(cw * ch)
    private var refProxy: IntArray? = null
    private var refProxySmall: IntArray? = null
    private val pw = 320
    private val ph = max(1, (320.0 * h / w).roundToInt())
    var used = 0
        private set
    var offered = 0
        private set
    val shifts = ArrayList<IntArray>()

    // Scratch rows for one input frame (planar, upright-unrotated).
    private val y8 = ByteArray(w * h)
    private val u8 = ByteArray(cw * ch)
    private val v8 = ByteArray(cw * ch)

    /** Copy a YUV_420_888 camera image into the scratch planes. */
    fun loadImage(img: Image) {
        val yp = img.planes[0]
        val up = img.planes[1]
        val vp = img.planes[2]
        val yb = yp.buffer
        val yRow = yp.rowStride
        val row = ByteArray(yRow)
        for (r in 0 until h) {
            yb.position(r * yRow)
            val n = min(yRow, yb.remaining())
            yb.get(row, 0, n)
            System.arraycopy(row, 0, y8, r * w, w)
        }
        val uRow = up.rowStride
        val vRow = vp.rowStride
        val ups = up.pixelStride
        val vps = vp.pixelStride
        val ub = up.buffer
        val vb = vp.buffer
        for (r in 0 until ch) {
            for (c in 0 until cw) {
                val ui = r * uRow + c * ups
                val vi = r * vRow + c * vps
                u8[r * cw + c] = if (ui < ub.limit()) ub.get(ui) else 128.toByte()
                v8[r * cw + c] = if (vi < vb.limit()) vb.get(vi) else 128.toByte()
            }
        }
    }

    /** Load an (EXIF-unrotated) bitmap of exactly w×h into the scratch planes. */
    fun loadBitmap(bmp: Bitmap) {
        val px = IntArray(w)
        for (r in 0 until h) {
            bmp.getPixels(px, 0, w, 0, r, w, 1)
            for (c in 0 until w) {
                val p = px[c]
                val R = (p shr 16) and 255
                val G = (p shr 8) and 255
                val B = p and 255
                y8[r * w + c] = clamp8(0.299 * R + 0.587 * G + 0.114 * B).toByte()
                if ((r and 1) == 0 && (c and 1) == 0) {
                    val i = (r / 2) * cw + c / 2
                    u8[i] = clamp8(128 - 0.168736 * R - 0.331264 * G + 0.5 * B).toByte()
                    v8[i] = clamp8(128 + 0.5 * R - 0.418688 * G - 0.081312 * B).toByte()
                }
            }
        }
    }

    private fun proxy(width: Int, height: Int): IntArray {
        val out = IntArray(width * height)
        for (py in 0 until height) {
            val sy = min(h - 1, (py * h) / height)
            for (px in 0 until width) {
                val sx = min(w - 1, (px * w) / width)
                // 2×2 mean at the sample point (cheap noise reduction).
                val sx1 = min(w - 1, sx + 1)
                val sy1 = min(h - 1, sy + 1)
                out[py * width + px] = ((y8[sy * w + sx].toInt() and 255) +
                    (y8[sy * w + sx1].toInt() and 255) +
                    (y8[sy1 * w + sx].toInt() and 255) +
                    (y8[sy1 * w + sx1].toInt() and 255)) / 4
            }
        }
        return out
    }

    /** Mean abs diff (0..255) of [a] shifted by (dx, dy) vs [ref], central 80 %. */
    private fun sad(ref: IntArray, a: IntArray, width: Int, height: Int, dx: Int, dy: Int): Double {
        val mx = width / 10 + abs(dx)
        val my = height / 10 + abs(dy)
        var sum = 0L
        var n = 0
        var y = my
        while (y < height - my) {
            var x = mx
            val ro = y * width
            val ao = (y + dy) * width + dx
            while (x < width - mx) {
                sum += abs(ref[ro + x] - a[ao + x])
                n++
                x += 1
            }
            y += 1
        }
        return if (n == 0) 1e9 else sum.toDouble() / n
    }

    /** Accumulate the frame in the scratch planes; returns false if rejected. */
    fun addLoaded(): Boolean {
        offered++
        val sw = 160
        val sh = max(1, (160.0 * h / w).roundToInt())
        val small = proxy(sw, sh)
        val big = proxy(pw, ph)
        var dx = 0
        var dy = 0
        val ref = refProxy
        val refS = refProxySmall
        if (ref == null || refS == null) {
            refProxy = big
            refProxySmall = small
        } else {
            var best = Double.MAX_VALUE
            var bx = 0
            var by = 0
            for (yy in -6..6) for (xx in -6..6) {
                val e = sad(refS, small, sw, sh, xx, yy)
                if (e < best) {
                    best = e; bx = xx; by = yy
                }
            }
            best = Double.MAX_VALUE
            var fx = bx * 2
            var fy = by * 2
            val cx = fx
            val cy = fy
            for (yy in -2..2) for (xx in -2..2) {
                val e = sad(ref, big, pw, ph, cx + xx, cy + yy)
                if (e < best) {
                    best = e; fx = cx + xx; fy = cy + yy
                }
            }
            if (best > MAX_ALIGN_ERR) return false
            dx = (fx.toDouble() * w / pw).roundToInt()
            dy = (fy.toDouble() * h / ph).roundToInt()
        }
        // Accumulate with the shift (clamped sampling at the borders).
        for (r in 0 until h) {
            val sr = min(h - 1, max(0, r + dy)) * w
            val o = r * w
            for (c in 0 until w) {
                val sc = min(w - 1, max(0, c + dx))
                sumY[o + c] = (sumY[o + c] + (y8[sr + sc].toInt() and 255)).toShort()
            }
        }
        val cdx = dx / 2
        val cdy = dy / 2
        for (r in 0 until ch) {
            val sr = min(ch - 1, max(0, r + cdy)) * cw
            val o = r * cw
            for (c in 0 until cw) {
                val sc = min(cw - 1, max(0, c + cdx))
                sumU[o + c] = (sumU[o + c] + (u8[sr + sc].toInt() and 255)).toShort()
                sumV[o + c] = (sumV[o + c] + (v8[sr + sc].toInt() and 255)).toShort()
            }
        }
        used++
        shifts.add(intArrayOf(dx, dy))
        return true
    }

    class Output(
        val path: String,
        val width: Int,
        val height: Int,
        val mean: Double,
        val brightFrac: Double,
        val p99: Double,
        val toneA: Double,
    )

    /** Average + tone map + denoise → upright JPEG at [outPath]. */
    fun finish(outPath: String, rotationDegrees: Int, quality: Int = 94): Output {
        val n = max(1, used)
        // Histogram of the averaged luma (4096 bins over 0..1).
        val bins = 4096
        val hist = IntArray(bins)
        for (i in 0 until w * h) {
            val yv = (sumY[i].toInt() and 0xFFFF).toDouble() / n / 255.0
            hist[min(bins - 1, (yv * (bins - 1)).toInt())]++
        }
        val total = (w * h).toDouble()
        // Black point: 0.5th percentile, capped (avoids milky shadows).
        var acc = 0.0
        var bpBin = 0
        for (b in 0 until bins) {
            acc += hist[b]
            if (acc >= total * 0.005) {
                bpBin = b; break
            }
        }
        val bp = min(MAX_BLACK_POINT, bpBin.toDouble() / (bins - 1))
        val params = NightTone.forName(tone)
        val a = NightTone.solveA(hist, bp, params)
        val lut = DoubleArray(bins)
        for (b in 0 until bins) {
            val y = b.toDouble() / (bins - 1)
            lut[b] = NightTone.curve(max(0.0, (y - bp) / (1 - bp)), a)
        }
        // Chroma: box blur (radius 2) of the averaged chroma planes.
        val uAvg = blurChroma(sumU, n)
        val vAvg = blurChroma(sumV, n)
        val maxGain = NightTone.slope0(a)
        val lumaNr = min(0.6, max(0.0, (maxGain - 1.0) / 6.0))

        val rot = ((rotationDegrees % 360) + 360) % 360
        val ow = if (rot == 90 || rot == 270) h else w
        val oh = if (rot == 90 || rot == 270) w else h
        val bmp = Bitmap.createBitmap(ow, oh, Bitmap.Config.ARGB_8888)
        val row = IntArray(ow)
        val outHist = IntArray(256)
        for (oy in 0 until oh) {
            for (ox in 0 until ow) {
                // Destination (ox, oy) → source (sx, sy) for a clockwise rotation.
                val sx: Int
                val sy: Int
                when (rot) {
                    90 -> { sx = oy; sy = h - 1 - ox }
                    180 -> { sx = w - 1 - ox; sy = h - 1 - oy }
                    270 -> { sx = w - 1 - oy; sy = ox }
                    else -> { sx = ox; sy = oy }
                }
                val i = sy * w + sx
                var yv = (sumY[i].toInt() and 0xFFFF).toDouble() / n / 255.0
                if (lumaNr > 0) {
                    // 3×3 mean blended into the darker (most lifted) pixels.
                    var s = 0.0
                    for (ky in -1..1) {
                        val yy = min(h - 1, max(0, sy + ky)) * w
                        for (kx in -1..1) {
                            s += (sumY[yy + min(w - 1, max(0, sx + kx))].toInt() and 0xFFFF).toDouble()
                        }
                    }
                    val m = s / 9.0 / n / 255.0
                    val wgt = lumaNr * (1.0 - min(1.0, yv * 3.0))
                    yv = yv * (1 - wgt) + m * wgt
                }
                val t = lut[min(bins - 1, (yv * (bins - 1)).toInt())]
                val gain = if (yv > 1e-4) t / yv else maxGain
                val cg = min(params.maxChromaGain, max(1.0, gain)) * params.saturation
                val ci = (sy / 2) * cw + (sx / 2)
                val u = (uAvg[ci] - 128.0) * cg
                val v = (vAvg[ci] - 128.0) * cg
                val yy8 = t * 255.0
                val r = clamp8(yy8 + 1.402 * v)
                val g = clamp8(yy8 - 0.344136 * u - 0.714136 * v)
                val b = clamp8(yy8 + 1.772 * u)
                row[ox] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
                outHist[clamp8(yy8)]++
            }
            bmp.setPixels(row, 0, ow, 0, oy, ow, 1)
        }
        FileOutputStream(File(outPath)).use { bmp.compress(Bitmap.CompressFormat.JPEG, quality, it) }
        bmp.recycle()
        // Stats of the result (the Pro Night darkness gate uses the same
        // metrics on the JPEG, see image_guard).
        var sum = 0.0
        var bright = 0
        for (v in 0 until 256) {
            sum += v.toDouble() * outHist[v]
            if (v / 255.0 > 0.25) bright += outHist[v]
        }
        var cum = 0
        var p99 = 255
        for (v in 0 until 256) {
            cum += outHist[v]
            if (cum >= total * 0.99) {
                p99 = v; break
            }
        }
        return Output(outPath, ow, oh, sum / total / 255.0, bright / total, p99 / 255.0, a)
    }

    private fun blurChroma(sum: ShortArray, n: Int): FloatArray {
        val src = FloatArray(cw * ch) { (sum[it].toInt() and 0xFFFF).toFloat() / n }
        val tmp = FloatArray(cw * ch)
        val out = FloatArray(cw * ch)
        val r = 2
        for (y in 0 until ch) {
            for (x in 0 until cw) {
                var s = 0f
                var k = 0
                for (dx in -r..r) {
                    val xx = x + dx
                    if (xx in 0 until cw) {
                        s += src[y * cw + xx]; k++
                    }
                }
                tmp[y * cw + x] = s / k
            }
        }
        for (y in 0 until ch) {
            for (x in 0 until cw) {
                var s = 0f
                var k = 0
                for (dy in -r..r) {
                    val yy = y + dy
                    if (yy in 0 until ch) {
                        s += tmp[yy * cw + x]; k++
                    }
                }
                out[y * cw + x] = s / k
            }
        }
        return out
    }

    companion object {
        const val MAX_ALIGN_ERR = 18.0
        const val MAX_BLACK_POINT = 0.03

        fun clamp8(v: Double): Int = if (v < 0) 0 else if (v > 255) 255 else v.toInt()

        /**
         * Merge camera-plugin JPEG frames (fallback when Camera2 manual capture
         * isn't available). Frames are decoded one at a time (≤ ~9 MP).
         */
        fun mergeJpegs(paths: List<String>, outPath: String, tone: String): Map<String, Any?> {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(paths[0], bounds)
            var sample = 1
            while ((bounds.outWidth / sample).toLong() * (bounds.outHeight / sample) > MAX_PIXELS) sample *= 2
            val opts = BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            val first = BitmapFactory.decodeFile(paths[0], opts)
                ?: throw IllegalArgumentException("cannot decode frame")
            val w = first.width
            val h = first.height
            val m = NightMerge(w, h, tone)
            m.loadBitmap(first)
            first.recycle()
            m.addLoaded()
            for (p in paths.drop(1)) {
                val b = BitmapFactory.decodeFile(p, opts) ?: continue
                if (b.width == w && b.height == h) {
                    m.loadBitmap(b)
                    m.addLoaded()
                }
                b.recycle()
            }
            val rot = try {
                when (ExifInterface(paths[0]).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> 90
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180
                    ExifInterface.ORIENTATION_ROTATE_270 -> 270
                    else -> 0
                }
            } catch (_: Throwable) {
                0
            }
            val out = m.finish(outPath, rot)
            return m.resultMap(out, manual = false)
        }

        const val MAX_PIXELS = 9_500_000L
    }

    fun resultMap(o: Output, manual: Boolean, extra: Map<String, Any?> = emptyMap()): Map<String, Any?> =
        hashMapOf<String, Any?>(
            "path" to o.path,
            "used" to used,
            "offered" to offered,
            "width" to o.width,
            "height" to o.height,
            "mean" to o.mean,
            "brightFrac" to o.brightFrac,
            "p99" to o.p99,
            "toneA" to o.toneA,
            "manual" to manual,
            "shifts" to shifts.map { listOf(it[0], it[1]) },
        ).apply { putAll(extra) }
}

/** Tone parameters + curve (mirrored in lib/services/night_tone.dart). */
object NightTone {
    class Params(
        val targetMean: Double,
        val maxShadowGain: Double,
        val saturation: Double,
        val maxChromaGain: Double,
    )

    val BRIGHT = Params(targetMean = 0.38, maxShadowGain = 6.0, saturation = 1.06, maxChromaGain = 3.0)
    val NATURAL = Params(targetMean = 0.20, maxShadowGain = 2.5, saturation = 0.96, maxChromaGain = 1.8)

    fun forName(n: String): Params = if (n == "natural") NATURAL else BRIGHT

    fun curve(y: Double, a: Double): Double =
        if (a < 1e-3) y else (1 - exp(-a * y)) / (1 - exp(-a))

    /** Shadow gain S'(0) = a / (1 − e^(−a)). */
    fun slope0(a: Double): Double = if (a < 1e-3) 1.0 else a / (1 - exp(-a))

    /** Largest `a` with slope0(a) ≤ maxGain (bisection). */
    fun maxA(maxGain: Double): Double {
        var lo = 0.0
        var hi = 40.0
        repeat(50) {
            val mid = (lo + hi) / 2
            if (slope0(mid) > maxGain) hi = mid else lo = mid
        }
        return lo
    }

    /** `a` so the mean of the curve over the histogram ≈ target (never darkens). */
    fun solveA(hist: IntArray, bp: Double, p: Params): Double {
        val bins = hist.size
        var total = 0.0
        for (c in hist) total += c
        fun meanFor(a: Double): Double {
            var s = 0.0
            for (b in 0 until bins) {
                if (hist[b] == 0) continue
                val y = max(0.0, (b.toDouble() / (bins - 1) - bp) / (1 - bp))
                s += curve(y, a) * hist[b]
            }
            return s / total
        }
        val aMax = maxA(p.maxShadowGain)
        if (meanFor(0.0) >= p.targetMean) return 0.0
        if (meanFor(aMax) <= p.targetMean) return aMax
        var lo = 0.0
        var hi = aMax
        repeat(40) {
            val mid = (lo + hi) / 2
            if (meanFor(mid) < p.targetMean) lo = mid else hi = mid
        }
        return (lo + hi) / 2
    }
}
