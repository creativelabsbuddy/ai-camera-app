package com.ankush.ai_camera

import android.os.Build
import android.util.Log
import android.view.Display
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.DisplayOrientedMeteringPointFactory
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.extensions.ExtensionMode
import androidx.camera.extensions.ExtensionsManager
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * v11 Portrait in NORMAL mode: the phone maker's own BOKEH effect through
 * CameraX Extensions (no fake blur). Only offered when
 * ExtensionsManager.isExtensionAvailable(lens, BOKEH) is true; otherwise the
 * app says Portrait isn't supported in Normal and suggests Pro AI.
 *
 * The Flutter camera plugin's controller is disposed while this session
 * runs (one camera user at a time); the preview goes to a Flutter
 * SurfaceProducer texture. Bound to the activity lifecycle, so CameraX
 * closes / reopens the camera itself on background / foreground.
 *
 * Channel `ai_camera/bokeh`: available(front) · start(front, zoom) →
 * {textureId, handlesCropAndRotation, sensorOrientation, minZoom, maxZoom}
 * · capture(dir) → path · setZoom(zoom) · focus(x, y) · stop().
 */
class BokehSession(
    private val activity: FlutterActivity,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler {
    private val tag = "BokehSession"
    private val main = ContextCompat.getMainExecutor(activity)
    private var provider: ProcessCameraProvider? = null
    private var extensions: ExtensionsManager? = null
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var preview: Preview? = null
    private var imageCapture: ImageCapture? = null
    private var camera: Camera? = null
    private var boundSelector: CameraSelector? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val front = call.argument<Boolean>("front") ?: false
        when (call.method) {
            "available" -> ensure({ _, em ->
                result.success(isAvailable(em, front))
            }, { result.success(false) })
            "start" -> start(front, (call.argument<Double>("zoom") ?: 1.0).toFloat(), result)
            "capture" -> capture(call.argument<String>("dir"), result)
            "setZoom" -> {
                val z = (call.argument<Double>("zoom") ?: 1.0).toFloat()
                try {
                    camera?.cameraControl?.setZoomRatio(z)
                } catch (t: Throwable) {
                    Log.w(tag, "setZoom: $t")
                }
                result.success(null)
            }
            "focus" -> focus(call.argument<Double>("x") ?: 0.5, call.argument<Double>("y") ?: 0.5, result)
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun base(front: Boolean): CameraSelector =
        if (front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA

    private fun isAvailable(em: ExtensionsManager, front: Boolean): Boolean = try {
        em.isExtensionAvailable(base(front), ExtensionMode.BOKEH)
    } catch (t: Throwable) {
        Log.w(tag, "isExtensionAvailable: $t")
        false
    }

    private fun ensure(
        ok: (ProcessCameraProvider, ExtensionsManager) -> Unit,
        fail: (Throwable) -> Unit,
    ) {
        val p = provider
        val e = extensions
        if (p != null && e != null) {
            ok(p, e)
            return
        }
        val pf = ProcessCameraProvider.getInstance(activity)
        pf.addListener({
            try {
                val prov = pf.get()
                val ef = ExtensionsManager.getInstanceAsync(activity, prov)
                ef.addListener({
                    try {
                        val em = ef.get()
                        provider = prov
                        extensions = em
                        ok(prov, em)
                    } catch (t: Throwable) {
                        fail(t)
                    }
                }, main)
            } catch (t: Throwable) {
                fail(t)
            }
        }, main)
    }

    private fun selector4x3(): ResolutionSelector = ResolutionSelector.Builder()
        .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
        .build()

    private fun start(front: Boolean, zoom: Float, result: MethodChannel.Result) {
        ensure({ prov, em ->
            try {
                if (!isAvailable(em, front)) {
                    result.error("unsupported", "Bokeh extension not available", null)
                    return@ensure
                }
                val sel = em.getExtensionEnabledCameraSelector(base(front), ExtensionMode.BOKEH)
                val prod = producer ?: textures.createSurfaceProducer().also { producer = it }
                val pv = Preview.Builder().setResolutionSelector(selector4x3()).build()
                pv.setSurfaceProvider(main) { request ->
                    val size = request.resolution
                    prod.setSize(size.width, size.height)
                    request.provideSurface(prod.surface, main) { }
                }
                prod.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                    override fun onSurfaceAvailable() {
                        // Surface re-created (e.g. after background): rebind.
                        val s = boundSelector ?: return
                        try {
                            prov.unbindAll()
                            camera = prov.bindToLifecycle(activity, s, pv, imageCapture!!)
                        } catch (t: Throwable) {
                            Log.w(tag, "rebind: $t")
                        }
                    }

                    override fun onSurfaceCleanup() {}
                })
                val ic = ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
                    .setResolutionSelector(selector4x3())
                    .build()
                prov.unbindAll()
                val cam = prov.bindToLifecycle(activity, sel, pv, ic)
                preview = pv
                imageCapture = ic
                camera = cam
                boundSelector = sel
                try {
                    cam.cameraControl.setZoomRatio(zoom)
                } catch (_: Throwable) {
                }
                val zs = cam.cameraInfo.zoomState.value
                result.success(
                    mapOf(
                        "textureId" to prod.id(),
                        "handlesCropAndRotation" to prod.handlesCropAndRotation(),
                        "sensorOrientation" to cam.cameraInfo.sensorRotationDegrees,
                        "minZoom" to (zs?.minZoomRatio ?: 1f).toDouble(),
                        "maxZoom" to (zs?.maxZoomRatio ?: 1f).toDouble(),
                    ),
                )
            } catch (t: Throwable) {
                Log.w(tag, "start failed: $t")
                stop()
                result.error("start_failed", "${t.javaClass.simpleName}: ${t.message}", null)
            }
        }, { t -> result.error("no_provider", "${t.message}", null) })
    }

    private fun capture(dir: String?, result: MethodChannel.Result) {
        val ic = imageCapture
        if (ic == null || dir == null) {
            result.error("not_started", "Bokeh session not running", null)
            return
        }
        val out = File(dir, "bokeh_${System.currentTimeMillis()}.jpg")
        val opts = ImageCapture.OutputFileOptions.Builder(out).build()
        ic.takePicture(opts, main, object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(r: ImageCapture.OutputFileResults) {
                result.success(out.absolutePath)
            }

            override fun onError(e: ImageCaptureException) {
                result.error("capture_failed", "${e.imageCaptureError}: ${e.message}", null)
            }
        })
    }

    private fun focus(x: Double, y: Double, result: MethodChannel.Result) {
        val cam = camera
        if (cam == null) {
            result.success(false)
            return
        }
        try {
            @Suppress("DEPRECATION")
            val display: Display = if (Build.VERSION.SDK_INT >= 30) {
                activity.display!!
            } else {
                activity.windowManager.defaultDisplay
            }
            val f = DisplayOrientedMeteringPointFactory(display, cam.cameraInfo, 1f, 1f)
            val action = FocusMeteringAction.Builder(f.createPoint(x.toFloat(), y.toFloat()))
                .setAutoCancelDuration(5, TimeUnit.SECONDS)
                .build()
            cam.cameraControl.startFocusAndMetering(action)
            result.success(true)
        } catch (t: Throwable) {
            Log.w(tag, "focus: $t")
            result.success(false)
        }
    }

    fun stop() {
        try {
            provider?.unbindAll()
        } catch (t: Throwable) {
            Log.w(tag, "unbind: $t")
        }
        camera = null
        preview = null
        imageCapture = null
        boundSelector = null
        try {
            producer?.release()
        } catch (_: Throwable) {
        }
        producer = null
    }
}
