package com.ankush.ai_camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Rect
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * v11 Night burst straight from Camera2 (the Flutter camera plugin is
 * closed meanwhile). Blocking — call from a worker thread.
 *
 * 1. Meter: AE/AF run on a small YUV stream until converged (≤ 1.2 s).
 * 2. Manual exposure (MANUAL_SENSOR devices): the metered exposure × boost
 *    is re-split into a LONGER per-frame shutter (≤ maxFrameMs) and lower
 *    ISO → less noise per frame. Focus is locked at the metered distance and
 *    white balance is locked so all frames match.
 *    Fallback (no manual sensor): AE stays on with max exposure
 *    compensation, the slowest AE frame-rate range and AE/AWB locked.
 * 3. captureBurst of N full-size YUV frames, each merged as it arrives
 *    (NightMerge, one frame in memory) → tone map → upright JPEG.
 */
object NightCapture {
    private const val TAG = "NightCapture"

    private class Metered {
        @Volatile var exp: Long? = null
        @Volatile var iso: Int? = null
        @Volatile var focus: Float? = null
        @Volatile var ae: Int? = null
        @Volatile var af: Int? = null
    }

    data class Plan(
        val cameraId: String,
        val frames: Int,
        val boost: Double,
        val maxFrameMs: Int,
        val zoom: Double,
        val tone: String,
        val outDir: String,
    )

    @SuppressLint("MissingPermission")
    fun run(ctx: Context, plan: Plan): Map<String, Any?> {
        val mgr = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val chars = mgr.getCameraCharacteristics(plan.cameraId)
        val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: IntArray(0)
        val manual = caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR)
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: throw IllegalStateException("no stream map")
        val yuvSizes = map.getOutputSizes(ImageFormat.YUV_420_888) ?: emptyArray()
        val main = pickMainSize(yuvSizes) ?: throw IllegalStateException("no YUV size")
        val meter = pickMeterSize(yuvSizes)
        val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

        val thread = HandlerThread("night-cam").apply { start() }
        val handler = Handler(thread.looper)
        val work = HandlerThread("night-merge").apply { start() }
        val workHandler = Handler(work.looper)
        var device: CameraDevice? = null
        var session: CameraCaptureSession? = null
        val mainReader = ImageReader.newInstance(main.width, main.height, ImageFormat.YUV_420_888, 3)
        val meterReader = ImageReader.newInstance(meter.width, meter.height, ImageFormat.YUV_420_888, 2)
        try {
            // -- open -----------------------------------------------------------
            val opened = CountDownLatch(1)
            var openError: String? = null
            mgr.openCamera(plan.cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(d: CameraDevice) {
                    device = d; opened.countDown()
                }

                override fun onDisconnected(d: CameraDevice) {
                    openError = "disconnected"; d.close(); opened.countDown()
                }

                override fun onError(d: CameraDevice, error: Int) {
                    openError = "error $error"; d.close(); opened.countDown()
                }
            }, handler)
            if (!opened.await(4, TimeUnit.SECONDS) || device == null) {
                throw IllegalStateException("camera open failed: ${openError ?: "timeout"}")
            }
            val dev = device!!

            // -- session --------------------------------------------------------
            val configured = CountDownLatch(1)
            @Suppress("DEPRECATION")
            dev.createCaptureSession(
                listOf(meterReader.surface, mainReader.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) {
                        session = s; configured.countDown()
                    }

                    override fun onConfigureFailed(s: CameraCaptureSession) {
                        configured.countDown()
                    }
                },
                handler,
            )
            if (!configured.await(4, TimeUnit.SECONDS) || session == null) {
                throw IllegalStateException("session configure failed")
            }
            val ses = session!!

            // -- meter ----------------------------------------------------------
            meterReader.setOnImageAvailableListener({ r -> r.acquireLatestImage()?.close() }, handler)
            val aeComp = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
            val fpsRanges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            val slowFps = fpsRanges?.minWithOrNull(compareBy<Range<Int>>({ it.lower }, { it.upper }))
            val meterReq = dev.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(meterReader.surface)
                set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                if (slowFps != null) set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, slowFps)
                applyZoom(this, chars, plan.zoom)
            }
            val m = Metered()
            ses.setRepeatingRequest(meterReq.build(), object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(s: CameraCaptureSession, r: CaptureRequest, res: TotalCaptureResult) {
                    m.exp = res.get(CaptureResult.SENSOR_EXPOSURE_TIME)
                    m.iso = res.get(CaptureResult.SENSOR_SENSITIVITY)
                    m.focus = res.get(CaptureResult.LENS_FOCUS_DISTANCE)
                    m.ae = res.get(CaptureResult.CONTROL_AE_STATE)
                    m.af = res.get(CaptureResult.CONTROL_AF_STATE)
                }
            }, handler)
            val t0 = System.currentTimeMillis()
            while (System.currentTimeMillis() - t0 < 1200) {
                Thread.sleep(50)
                val ae = m.ae
                val af = m.af
                val aeOk = ae == CaptureResult.CONTROL_AE_STATE_CONVERGED ||
                    ae == CaptureResult.CONTROL_AE_STATE_FLASH_REQUIRED
                val afOk = af == null || af == CaptureResult.CONTROL_AF_STATE_PASSIVE_FOCUSED ||
                    af == CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED ||
                    af == CaptureResult.CONTROL_AF_STATE_INACTIVE
                if (System.currentTimeMillis() - t0 > 400 && aeOk && afOk) break
            }
            ses.stopRepeating()
            try {
                ses.abortCaptures()
            } catch (_: Throwable) {
            }
            meterReader.setOnImageAvailableListener(null, null)

            // -- burst request --------------------------------------------------
            val expRange = chars.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
            val isoRange = chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
            val metExp = m.exp
            val metIso = m.iso
            val useManual = manual && metExp != null && metIso != null && expRange != null && isoRange != null
            var frameExpNs = 0L
            var frameIso = 0
            val burst = dev.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
                addTarget(mainReader.surface)
                set(CaptureRequest.NOISE_REDUCTION_MODE, CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY)
                set(CaptureRequest.CONTROL_AWB_LOCK, true)
                applyZoom(this, chars, plan.zoom)
                if (useManual) {
                    val total = metExp!!.toDouble() * metIso!!.toDouble() * plan.boost
                    val maxNs = min(plan.maxFrameMs * 1_000_000L, expRange!!.upper)
                    // Longer shutter than metered (up to maxNs), ISO takes the rest.
                    var exp = min(maxNs, max(metExp, (total / max(isoRange!!.lower, 1)).toLong()))
                    exp = max(expRange.lower, exp)
                    var iso = (total / exp).toInt()
                    iso = min(isoRange.upper, max(isoRange.lower, iso))
                    frameExpNs = exp
                    frameIso = iso
                    set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
                    set(CaptureRequest.SENSOR_EXPOSURE_TIME, exp)
                    set(CaptureRequest.SENSOR_SENSITIVITY, iso)
                    set(CaptureRequest.SENSOR_FRAME_DURATION, exp + 2_000_000L)
                    val f = m.focus
                    if (f != null) {
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                        set(CaptureRequest.LENS_FOCUS_DISTANCE, f)
                    }
                } else {
                    set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                    if (aeComp != null) set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, aeComp.upper)
                    if (slowFps != null) set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, slowFps)
                    set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                }
            }.build()

            // -- burst + streaming merge ---------------------------------------
            val merge = NightMerge(main.width, main.height, plan.tone)
            val done = CountDownLatch(plan.frames)
            val arrived = AtomicInteger(0)
            mainReader.setOnImageAvailableListener({ r ->
                val img = try {
                    r.acquireNextImage()
                } catch (t: Throwable) {
                    null
                } ?: return@setOnImageAvailableListener
                try {
                    merge.loadImage(img)
                } finally {
                    img.close() // free the buffer before the (slower) merge
                }
                try {
                    merge.addLoaded()
                } catch (t: Throwable) {
                    Log.w(TAG, "merge frame: $t")
                }
                arrived.incrementAndGet()
                done.countDown()
            }, workHandler)
            ses.captureBurst(List(plan.frames) { burst }, object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureFailed(s: CameraCaptureSession, r: CaptureRequest, f: CaptureFailure) {
                    done.countDown()
                }

                override fun onCaptureBufferLost(s: CameraCaptureSession, r: CaptureRequest, t: Surface, frame: Long) {
                    done.countDown()
                }
            }, handler)
            val perFrameMs = max(frameExpNs / 1_000_000L, 66L) + 400L
            done.await(2_000L + plan.frames * perFrameMs, TimeUnit.MILLISECONDS)
            try {
                ses.close()
            } catch (_: Throwable) {
            }
            try {
                dev.close()
            } catch (_: Throwable) {
            }
            device = null
            session = null
            // Wait for an in-flight merge on the worker, then stop it.
            val idle = CountDownLatch(1)
            workHandler.post { idle.countDown() }
            idle.await(5, TimeUnit.SECONDS)
            mainReader.setOnImageAvailableListener(null, null)
            if (merge.used == 0) throw IllegalStateException("no frames captured")

            val out = File(plan.outDir, "night_${System.currentTimeMillis()}.jpg").absolutePath
            val res = merge.finish(out, sensorOrientation)
            return merge.resultMap(
                res,
                manual = useManual,
                extra = mapOf(
                    "frameExposureMs" to if (useManual) frameExpNs / 1e6 else null,
                    "frameIso" to if (useManual) frameIso else null,
                    "meteredExposureMs" to metExp?.let { it / 1e6 },
                    "meteredIso" to metIso,
                    "requested" to plan.frames,
                    "arrived" to arrived.get(),
                    "sourceWidth" to main.width,
                    "sourceHeight" to main.height,
                ),
            )
        } finally {
            try {
                session?.close()
            } catch (_: Throwable) {
            }
            try {
                device?.close()
            } catch (_: Throwable) {
            }
            mainReader.close()
            meterReader.close()
            thread.quitSafely()
            work.quitSafely()
        }
    }

    /** Largest 4:3 YUV size up to ~9.5 MP (memory-safe streaming merge). */
    private fun pickMainSize(sizes: Array<Size>): Size? {
        val ok = sizes.filter { it.width.toLong() * it.height <= NightMerge.MAX_PIXELS }
        val fourThree = ok.filter { abs(it.width.toDouble() / it.height - 4.0 / 3.0) < 0.02 }
        return (fourThree.ifEmpty { ok }).maxByOrNull { it.width.toLong() * it.height }
    }

    private fun pickMeterSize(sizes: Array<Size>): Size {
        val small = sizes.filter { it.width <= 800 && it.height <= 600 }
        return small.maxByOrNull { it.width * it.height }
            ?: sizes.minByOrNull { it.width * it.height }
            ?: Size(640, 480)
    }

    private fun applyZoom(b: CaptureRequest.Builder, ch: CameraCharacteristics, zoom: Double) {
        if (Build.VERSION.SDK_INT >= 30) {
            val range = ch.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
            if (range != null) {
                val z = zoom.toFloat().coerceIn(range.lower, range.upper)
                b.set(CaptureRequest.CONTROL_ZOOM_RATIO, z)
                return
            }
        }
        if (zoom <= 1.0) return
        val active = ch.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return
        val maxD = ch.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
        val z = min(zoom, maxD.toDouble())
        val cw = (active.width() / z).toInt()
        val chh = (active.height() / z).toInt()
        val l = active.left + (active.width() - cw) / 2
        val t = active.top + (active.height() - chh) / 2
        b.set(CaptureRequest.SCALER_CROP_REGION, Rect(l, t, l + cw, t + chh))
    }
}
