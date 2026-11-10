# camera_android_camerax 0.7.2 — AI Camera fork (v11.35)

Vendored copy used via `dependency_overrides` (path). Minimal changes:

1. `AndroidCameraCameraX.meteringPointSize` (Dart, static): focus/exposure
   metering points use `createPointWithSize(x, y, size)` when set (app sets
   0.15 / digitalZoom so tap/bright metering matches the visible crop).
2. `CameraXExtras.java` + MethodChannel `ai_camera/camerax_extras`:
   - `info`: live capture result (LOGICAL_MULTI_CAMERA_ACTIVE_PHYSICAL_ID,
     LENS_FOCUS_DISTANCE, exposure, ISO, CONTROL_ZOOM_RATIO, AF state, AE
     comp) + camera id, MANUAL_SENSOR, AE comp range, min focus distance.
   - `setManual(focusInfinity, exposureNs, iso)`: Camera2CameraControl
     options (AF off + LENS_FOCUS_DISTANCE 0; AE off + manual exposure/ISO
     only with MANUAL_SENSOR). `clearManual` restores continuous AF / auto AE.
3. Hooks: Preview builder gets a Camera2Interop session capture callback;
   `bindToLifecycle` stores the bound Camera; plugin registers the channel.

4. v11.42: `setStabilization(on)` on the extras channel (OIS where the lens
   lists it, CONTROL_VIDEO_STABILIZATION_MODE_PREVIEW_STABILIZATION on API 33+
   where offered; re-applied after `clearManual`). ImageAnalysis uses a
   ~640x480 4:3 selector (`AndroidCameraCameraX.analysisMaxWidth/Height`);
   preview and ImageCapture keep the preset.
