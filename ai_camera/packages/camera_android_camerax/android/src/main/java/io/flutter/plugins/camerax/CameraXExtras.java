// AI Camera fork (v11.35): small extras on top of camera_android_camerax 0.7.2.
// - Live capture-result info (active physical lens, focus distance, exposure,
//   ISO, zoom ratio) via a Camera2Interop session callback on the Preview.
// - Manual focus-to-infinity and manual short exposure through
//   Camera2CameraControl (only when the camera allows it).
// Channel: "ai_camera/camerax_extras". See FORK.md.
package io.flutter.plugins.camerax;

import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraMetadata;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.CaptureResult;
import android.hardware.camera2.TotalCaptureResult;
import android.hardware.camera2.CameraCaptureSession;
import android.os.Build;
import android.util.Range;
import androidx.annotation.NonNull;
import androidx.camera.camera2.interop.Camera2CameraControl;
import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.camera2.interop.CaptureRequestOptions;
import androidx.camera.core.Camera;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import java.util.HashMap;
import java.util.Map;

@SuppressWarnings("UnsafeOptInUsageError")
final class CameraXExtras {
  static volatile Camera camera;
  static volatile String activePhysicalId;
  static volatile Float focusDistance;
  static volatile Long exposureNs;
  static volatile Integer iso;
  static volatile Float zoomRatio;
  static volatile Integer afState;
  static volatile Integer aeComp;
  static volatile boolean manualOn = false;
  // v11.42: preview stabilisation wanted (re-applied after clearManual).
  static volatile boolean stabOn = false;
  static volatile String stabApplied = "";

  static final CameraCaptureSession.CaptureCallback CALLBACK =
      new CameraCaptureSession.CaptureCallback() {
        @Override
        public void onCaptureCompleted(
            @NonNull CameraCaptureSession s,
            @NonNull CaptureRequest r,
            @NonNull TotalCaptureResult res) {
          if (Build.VERSION.SDK_INT >= 29) {
            activePhysicalId =
                res.get(CaptureResult.LOGICAL_MULTI_CAMERA_ACTIVE_PHYSICAL_ID);
          }
          focusDistance = res.get(CaptureResult.LENS_FOCUS_DISTANCE);
          exposureNs = res.get(CaptureResult.SENSOR_EXPOSURE_TIME);
          iso = res.get(CaptureResult.SENSOR_SENSITIVITY);
          afState = res.get(CaptureResult.CONTROL_AF_STATE);
          aeComp = res.get(CaptureResult.CONTROL_AE_EXPOSURE_COMPENSATION);
          if (Build.VERSION.SDK_INT >= 30) {
            zoomRatio = res.get(CaptureResult.CONTROL_ZOOM_RATIO);
          }
        }
      };

  private CameraXExtras() {}

  static void setUp(BinaryMessenger messenger) {
    new MethodChannel(messenger, "ai_camera/camerax_extras")
        .setMethodCallHandler(
            (call, result) -> {
              try {
                switch (call.method) {
                  case "info":
                    result.success(info());
                    break;
                  case "setManual":
                    Boolean inf = call.argument("focusInfinity");
                    Long exp = call.argument("exposureNs") instanceof Number
                        ? ((Number) call.argument("exposureNs")).longValue() : null;
                    Integer is = call.argument("iso");
                    result.success(setManual(inf != null && inf, exp, is));
                    break;
                  case "setStabilization":
                    Boolean on = call.argument("on");
                    result.success(setStabilization(on != null && on));
                    break;
                  case "clearManual":
                    clearManual();
                    result.success(true);
                    break;
                  default:
                    result.notImplemented();
                }
              } catch (Exception e) {
                result.error("extras", e.getMessage(), null);
              }
            });
  }

  private static Map<String, Object> info() {
    final Map<String, Object> m = new HashMap<>();
    m.put("activePhysicalId", activePhysicalId);
    m.put("focusDistance", focusDistance == null ? null : focusDistance.doubleValue());
    m.put("exposureNs", exposureNs);
    m.put("iso", iso);
    m.put("zoomRatio", zoomRatio == null ? null : zoomRatio.doubleValue());
    m.put("afState", afState);
    m.put("aeComp", aeComp);
    m.put("manualOn", manualOn);
    m.put("stabilization", stabApplied);
    final Camera c = camera;
    if (c != null) {
      final Camera2CameraInfo ci = Camera2CameraInfo.from(c.getCameraInfo());
      m.put("cameraId", ci.getCameraId());
      m.put("manualSensor", hasCap(ci, CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR));
      final Float minFocus = ci.getCameraCharacteristic(
          CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE);
      m.put("minFocusDistance", minFocus == null ? null : minFocus.doubleValue());
      final Range<Integer> comp = ci.getCameraCharacteristic(
          CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE);
      if (comp != null) {
        m.put("aeCompMin", comp.getLower());
        m.put("aeCompMax", comp.getUpper());
      }
    }
    return m;
  }

  private static boolean hasCap(Camera2CameraInfo ci, int cap) {
    final int[] caps = ci.getCameraCharacteristic(
        CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES);
    if (caps == null) return false;
    for (int c : caps) if (c == cap) return true;
    return false;
  }

  /** Focus to infinity and/or manual exposure. Returns what was applied. */
  private static String setManual(boolean focusInfinity, Long exposureNs, Integer iso) {
    final Camera c = camera;
    if (c == null) return "no camera";
    final Camera2CameraInfo ci = Camera2CameraInfo.from(c.getCameraInfo());
    final boolean manual = hasCap(ci, CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR);
    final Float minFocus = ci.getCameraCharacteristic(
        CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE);
    final CaptureRequestOptions.Builder b = new CaptureRequestOptions.Builder();
    final StringBuilder done = new StringBuilder();
    if (focusInfinity && minFocus != null && minFocus > 0f) {
      b.setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF);
      b.setCaptureRequestOption(CaptureRequest.LENS_FOCUS_DISTANCE, 0f);
      done.append("focus inf ");
    }
    if (exposureNs != null && iso != null && manual) {
      b.setCaptureRequestOption(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF);
      b.setCaptureRequestOption(CaptureRequest.SENSOR_EXPOSURE_TIME, exposureNs);
      b.setCaptureRequestOption(CaptureRequest.SENSOR_SENSITIVITY, iso);
      done.append("manual exp ");
    }
    if (done.length() == 0) return "not supported";
    Camera2CameraControl.from(c.getCameraControl()).addCaptureRequestOptions(b.build());
    manualOn = true;
    return done.toString().trim();
  }

  /** v11.36: remove ALL our request options so CameraX's own AF / AE run again. */
  private static void clearManual() {
    final Camera c = camera;
    manualOn = false;
    if (c == null) return;
    Camera2CameraControl.from(c.getCameraControl()).clearCaptureRequestOptions();
    if (stabOn) setStabilization(true); // v11.42: keep stabilisation on
  }

  private static boolean hasMode(int[] modes, int mode) {
    if (modes == null) return false;
    for (int m : modes) if (m == mode) return true;
    return false;
  }

  /**
   * v11.42: optical stabilisation on where the lens has it, plus preview
   * (electronic) stabilisation where the camera offers it (API 33+). Only
   * modes the camera lists are set. Returns what was applied.
   */
  private static String setStabilization(boolean on) {
    stabOn = on;
    final Camera c = camera;
    if (c == null) return "no camera";
    if (!on) {
      stabApplied = "";
      return "off";
    }
    final Camera2CameraInfo ci = Camera2CameraInfo.from(c.getCameraInfo());
    final CaptureRequestOptions.Builder b = new CaptureRequestOptions.Builder();
    final StringBuilder done = new StringBuilder();
    final int[] ois = ci.getCameraCharacteristic(
        CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION);
    if (hasMode(ois, CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON)) {
      b.setCaptureRequestOption(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
          CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON);
      done.append("OIS ");
    }
    if (Build.VERSION.SDK_INT >= 33) {
      final int[] vs = ci.getCameraCharacteristic(
          CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES);
      if (hasMode(vs, CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_PREVIEW_STABILIZATION)) {
        b.setCaptureRequestOption(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
            CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_PREVIEW_STABILIZATION);
        done.append("EIS-preview ");
      }
    }
    if (done.length() == 0) {
      stabApplied = "none";
      return "not supported";
    }
    Camera2CameraControl.from(c.getCameraControl()).addCaptureRequestOptions(b.build());
    stabApplied = done.toString().trim();
    return stabApplied;
  }

}
