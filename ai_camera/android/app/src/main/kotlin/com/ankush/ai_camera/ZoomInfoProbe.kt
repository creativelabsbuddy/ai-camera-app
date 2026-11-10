package com.ankush.ai_camera

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraExtensionCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build

/**
 * Read-only Camera2 probe used to work out a phone-wise zoom range.
 *
 * Enumerates CameraManager.cameraIdList, the physical sub-cameras of logical
 * multi-cameras (API 28+), and a few unlisted numeric ids (some OEMs hide
 * lenses from cameraIdList). Never opens a camera — only reads
 * CameraCharacteristics, so no CAMERA permission is required.
 *
 * Every value is a plain Map/List/Double/Int/String/Boolean so it can travel
 * over the Flutter StandardMessageCodec.
 */
object ZoomInfoProbe {
    /** 35mm-eq focal below this is treated as ultra-wide (never "main"). */
    private const val ULTRAWIDE_MAX_EQ_MM = 19.0

    /** Extra numeric ids probed when not present in cameraIdList. */
    private const val HIDDEN_ID_PROBE_MAX = 15

    fun probe(context: Context): Map<String, Any?> {
        val out = HashMap<String, Any?>()
        val errors = ArrayList<String>()
        out["sdkInt"] = Build.VERSION.SDK_INT
        out["manufacturer"] = Build.MANUFACTURER ?: ""
        out["model"] = Build.MODEL ?: ""
        out["errors"] = errors

        val manager = try {
            context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
        } catch (e: Exception) {
            null
        }
        if (manager == null) {
            out["error"] = "CameraManager unavailable"
            out["cameras"] = ArrayList<Map<String, Any?>>()
            return out
        }

        val listed: List<String> = try {
            manager.cameraIdList.toList()
        } catch (e: Exception) {
            errors.add("cameraIdList: ${e.javaClass.simpleName}: ${e.message}")
            emptyList()
        }
        out["cameraIdList"] = ArrayList(listed)

        val cameras = LinkedHashMap<String, HashMap<String, Any?>>()

        // 1) Cameras the framework lists.
        for (id in listed) {
            describe(manager, id, "listed", errors)?.let { cameras[id] = it }
        }

        // 2) Physical sub-cameras of logical multi-cameras (API 28+).
        if (Build.VERSION.SDK_INT >= 28) {
            for (id in listed) {
                val parent = cameras[id] ?: continue
                @Suppress("UNCHECKED_CAST")
                val phys = parent["physicalIds"] as? List<String> ?: continue
                for (pid in phys) {
                    val existing = cameras[pid]
                    if (existing != null) {
                        if (existing["parentId"] == null) existing["parentId"] = id
                        continue
                    }
                    describe(manager, pid, "physical", errors)?.let {
                        it["parentId"] = id
                        cameras[pid] = it
                    }
                }
            }
        }

        // 3) Unlisted numeric ids (diagnostic; OEMs sometimes hide lenses).
        for (n in 0..HIDDEN_ID_PROBE_MAX) {
            val id = n.toString()
            if (cameras.containsKey(id)) continue
            describe(manager, id, "hidden", null)?.let { cameras[id] = it }
        }

        computeSummary(cameras.values.toList(), listed, out)
        out["cameras"] = ArrayList<Map<String, Any?>>(cameras.values)
        probeNightExtension(manager, listed, out, errors)
        return out
    }

    /**
     * Camera2 extensions (API 31+): does the OEM ship a Night extension for
     * the back camera? Info only — the Flutter camera plugin cannot bind
     * CameraX/Camera2 extension sessions, so the app's night mode uses its
     * own burst merge. Reported in Settings.
     */
    private fun probeNightExtension(
        manager: CameraManager,
        listed: List<String>,
        out: HashMap<String, Any?>,
        errors: ArrayList<String>,
    ) {
        if (Build.VERSION.SDK_INT < 31) {
            out["nightExtension"] = null
            return
        }
        val ids = ArrayList<String>()
        for (id in listed) {
            try {
                val ext = manager.getCameraExtensionCharacteristics(id)
                if (ext.supportedExtensions.contains(CameraExtensionCharacteristics.EXTENSION_NIGHT)) {
                    ids.add(id)
                }
            } catch (e: Exception) {
                errors.add("extensions($id): ${e.javaClass.simpleName}")
            }
        }
        out["nightExtensionIds"] = ids
        val back = out["primaryBackId"]?.toString()
        out["nightExtension"] = if (back != null) ids.contains(back) else ids.isNotEmpty()
    }

    private fun describe(
        manager: CameraManager,
        id: String,
        source: String,
        errors: MutableList<String>?,
    ): HashMap<String, Any?>? {
        return try {
            val ch = manager.getCameraCharacteristics(id)
            val m = HashMap<String, Any?>()
            m["id"] = id
            m["source"] = source
            m["lensFacing"] = when (ch.get(CameraCharacteristics.LENS_FACING)) {
                CameraCharacteristics.LENS_FACING_BACK -> "back"
                CameraCharacteristics.LENS_FACING_FRONT -> "front"
                CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
                else -> "unknown"
            }

            val caps = ch.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
                ?: IntArray(0)
            var isLogical = false
            val physicalIds = ArrayList<String>()
            if (Build.VERSION.SDK_INT >= 28) {
                isLogical = caps.contains(
                    CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA,
                )
                try {
                    physicalIds.addAll(ch.physicalCameraIds.sorted())
                } catch (e: Exception) {
                    errors?.add("physicalIds($id): ${e.message}")
                }
            }
            m["isLogical"] = isLogical
            m["physicalIds"] = physicalIds

            val focals = ch.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                ?.map { it.toDouble() } ?: emptyList()
            m["focalLengths"] = ArrayList(focals)

            val phys = ch.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
            m["sensorWidthMm"] = phys?.width?.toDouble()
            m["sensorHeightMm"] = phys?.height?.toDouble()

            val active = ch.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
            m["activeArrayWidth"] = active?.width()
            m["activeArrayHeight"] = active?.height()

            // Full pixel array (e.g. 50MP tele / 200MP main). Used on the Dart
            // side to decide whether a 2x in-sensor crop is "optical quality".
            val pixels = ch.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
            m["pixelArrayWidth"] = pixels?.width
            m["pixelArrayHeight"] = pixels?.height
            // Max-resolution (remosaic) array on API 31+ quad-bayer sensors.
            if (Build.VERSION.SDK_INT >= 31) {
                try {
                    val maxRes = ch.get(
                        CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE_MAXIMUM_RESOLUTION,
                    )
                    m["pixelArrayMaxResWidth"] = maxRes?.width
                    m["pixelArrayMaxResHeight"] = maxRes?.height
                } catch (e: Exception) {
                    // Not supported on this device.
                }
            }

            val maxDigital =
                ch.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)?.toDouble()
            m["maxDigitalZoom"] = maxDigital

            var zoomMin: Double? = null
            var zoomMax: Double? = null
            if (Build.VERSION.SDK_INT >= 30) {
                val range = ch.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
                zoomMin = range?.lower?.toDouble()
                zoomMax = range?.upper?.toDouble()
            }
            m["zoomRatioMin"] = zoomMin
            m["zoomRatioMax"] = zoomMax

            // v11 Macro: closest focus (diopters = 1/m; 0 = fixed focus).
            m["minFocusDiopters"] =
                ch.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)?.toDouble()
            // v11 Night: manual exposure support + limits.
            m["manualSensor"] = caps.contains(
                CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR,
            )
            m["maxExposureNs"] =
                ch.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)?.upper
            m["maxIso"] = ch.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)?.upper

            val reported = listOfNotNull(zoomMax, maxDigital).maxOrNull()
            m["reportedMaxZoom"] = reported

            // 35mm-equivalent focal = focal * 36 / sensorWidth (long side).
            val minFocal = focals.minOrNull()
            val sensorLong = if (phys != null) maxOf(phys.width, phys.height).toDouble() else null
            m["eqFocalMm"] = if (minFocal != null && sensorLong != null && sensorLong > 0) {
                minFocal * 36.0 / sensorLong
            } else {
                null
            }
            m
        } catch (e: Exception) {
            errors?.add("characteristics($id): ${e.javaClass.simpleName}: ${e.message}")
            null
        }
    }

    private fun computeSummary(
        cameras: List<HashMap<String, Any?>>,
        listed: List<String>,
        out: HashMap<String, Any?>,
    ) {
        val back = cameras.filter { it["lensFacing"] == "back" }
        if (back.isEmpty()) {
            out["primaryBackId"] = null
            out["reportedMaxZoom"] = null
            out["opticalMultipliers"] = ArrayList<Double>()
            out["teleMultiplier"] = null
            return
        }

        // Back camera CameraX will most likely open: first listed back logical
        // camera, else the first listed back camera.
        val listedBack = listed.mapNotNull { id -> back.firstOrNull { it["id"] == id } }
        val primary = listedBack.firstOrNull { it["isLogical"] == true }
            ?: listedBack.firstOrNull()
            ?: back.first()
        out["primaryBackId"] = primary["id"]
        out["reportedMaxZoom"] = primary["reportedMaxZoom"]

        // Individual lenses: non-logical back cameras (listed, physical, hidden).
        var lenses = back.filter { it["isLogical"] != true && it["eqFocalMm"] != null }
        if (lenses.isEmpty()) lenses = back.filter { it["eqFocalMm"] != null }
        if (lenses.isEmpty()) {
            out["opticalMultipliers"] = ArrayList<Double>()
            out["teleMultiplier"] = null
            return
        }

        // Main = widest non-ultrawide lens (~24mm eq, the stock "1x").
        val nonUw = lenses.filter { (it["eqFocalMm"] as Double) >= ULTRAWIDE_MAX_EQ_MM }
        val main = nonUw.minByOrNull { it["eqFocalMm"] as Double }
            ?: (primary.takeIf { it["eqFocalMm"] != null })
            ?: lenses.maxByOrNull { it["eqFocalMm"] as Double }!!
        val mainEq = main["eqFocalMm"] as Double
        out["mainCameraId"] = main["id"]
        out["mainEqFocalMm"] = mainEq

        for (c in back) {
            val eq = c["eqFocalMm"] as? Double ?: continue
            c["opticalMultiplier"] = eq / mainEq
            c["isMain"] = c === main
        }

        val multipliers = lenses
            .mapNotNull { it["opticalMultiplier"] as? Double }
            .map { Math.round(it * 100.0) / 100.0 }
            .distinct()
            .sorted()
        out["opticalMultipliers"] = ArrayList(multipliers)
        out["teleMultiplier"] = multipliers.filter { it >= 1.5 }.maxOrNull()
    }
}
