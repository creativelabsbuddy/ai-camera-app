package com.ankush.ai_camera

import android.Manifest
import android.content.pm.PackageManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.ankush.ai_camera/permissions"
    private val zoomChannelName = "ai_camera/zoom_info"
    private val deviceChannelName = "ai_camera/device"
    private val personChannelName = "ai_camera/person"
    private val bokehChannelName = "ai_camera/bokeh"
    private val nightChannelName = "ai_camera/night"
    private val regionChannelName = "ai_camera/region"
    private var bokeh: BokehSession? = null
    private val requestCodeCamera = 19283
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkCamera" -> {
                        result.success(hasCameraPermission())
                    }
                    "requestCamera" -> {
                        if (hasCameraPermission()) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        if (pendingResult != null) {
                            result.error("PENDING", "Permission request already in progress", null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.CAMERA),
                            requestCodeCamera,
                        )
                    }
                    else -> result.notImplemented()
                }
            }

        // Read-only Camera2 zoom/lens probe (runs off the UI thread).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, zoomChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getZoomInfo" -> {
                        val appContext = applicationContext
                        Thread {
                            val payload: Map<String, Any?> = try {
                                ZoomInfoProbe.probe(appContext)
                            } catch (t: Throwable) {
                                mapOf(
                                    "error" to "${t.javaClass.simpleName}: ${t.message}",
                                    "cameras" to ArrayList<Map<String, Any?>>(),
                                )
                            }
                            runOnUiThread { result.success(payload) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }

        // On-device face check before outfit / person AI looks (background thread).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, personChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "countFaces" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.success(-1)
                            return@setMethodCallHandler
                        }
                        Thread {
                            val n = try {
                                PersonProbe.countFaces(path)
                            } catch (t: Throwable) {
                                -1
                            }
                            runOnUiThread { result.success(n) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }

        // v11.60 burst merge: decode only the zoomed region (worker thread).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, regionChannelName)
            .setMethodCallHandler { call, result ->
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("bad_args", "path", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "info", "decode" -> Thread {
                        try {
                            val r = if (call.method == "info") {
                                RegionDecode.info(path)
                            } else {
                                RegionDecode.decode(
                                    path,
                                    call.argument<Int>("x")!!,
                                    call.argument<Int>("y")!!,
                                    call.argument<Int>("w")!!,
                                    call.argument<Int>("h")!!,
                                    call.argument<String>("out")!!,
                                )
                            }
                            runOnUiThread { result.success(r) }
                        } catch (t: Throwable) {
                            runOnUiThread {
                                result.error("region_failed", "${t.javaClass.simpleName}: ${t.message}", null)
                            }
                        }
                    }.start()
                    else -> result.notImplemented()
                }
            }

        // v11 Portrait (Normal): vendor BOKEH extension via CameraX.
        val session = BokehSession(this, flutterEngine.renderer)
        bokeh = session
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, bokehChannelName)
            .setMethodCallHandler(session)

        // v11 Night: Camera2 manual-exposure burst + streaming merge, and the
        // same merge for camera-plugin JPEG bursts (fallback). Worker thread.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nightChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capture" -> {
                        val plan = try {
                            NightCapture.Plan(
                                cameraId = call.argument<String>("cameraId")!!,
                                frames = (call.argument<Int>("frames") ?: 10).coerceIn(1, 15),
                                boost = call.argument<Double>("boost") ?: 1.5,
                                maxFrameMs = call.argument<Int>("maxFrameMs") ?: 125,
                                zoom = call.argument<Double>("zoom") ?: 1.0,
                                tone = call.argument<String>("tone") ?: "bright",
                                outDir = call.argument<String>("outDir")!!,
                            )
                        } catch (t: Throwable) {
                            result.error("bad_args", t.message, null)
                            return@setMethodCallHandler
                        }
                        val ctx = applicationContext
                        Thread {
                            try {
                                val r = NightCapture.run(ctx, plan)
                                runOnUiThread { result.success(r) }
                            } catch (t: Throwable) {
                                runOnUiThread {
                                    result.error("night_failed", "${t.javaClass.simpleName}: ${t.message}", null)
                                }
                            }
                        }.start()
                    }
                    "mergeJpegs" -> {
                        val paths = call.argument<List<String>>("paths")
                        val out = call.argument<String>("out")
                        val tone = call.argument<String>("tone") ?: "bright"
                        if (paths.isNullOrEmpty() || out == null) {
                            result.error("bad_args", "paths/out required", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val r = NightMerge.mergeJpegs(paths, out, tone)
                                runOnUiThread { result.success(r) }
                            } catch (t: Throwable) {
                                runOnUiThread {
                                    result.error("merge_failed", "${t.javaClass.simpleName}: ${t.message}", null)
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }

        // Stable per-device id (ANDROID_ID: survives reinstall, scoped to the
        // app signing key). Used for one-time starter trials / credits ledger.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceId" -> {
                        val id = try {
                            Settings.Secure.getString(
                                contentResolver,
                                Settings.Secure.ANDROID_ID,
                            )
                        } catch (e: Exception) {
                            null
                        }
                        result.success(id)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        bokeh?.stop()
        bokeh = null
        super.onDestroy()
    }

    private fun hasCameraPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.CAMERA,
        ) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != requestCodeCamera) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingResult?.success(granted)
        pendingResult = null
    }
}
