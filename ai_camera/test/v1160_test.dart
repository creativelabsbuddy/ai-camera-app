// v11.60 tests: live-preview zoom policies, wide→close tracking (chained
// similarity registration), the bounded zoom burst merge, tracked sharp
// source integration. Synthetic scenes with KNOWN transforms; no network,
// no paid calls.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_camera/services/burst_merge.dart';
import 'package:ai_camera/services/enhance_service.dart';
import 'package:ai_camera/services/frame_stats.dart';
import 'package:ai_camera/services/image_register.dart';
import 'package:ai_camera/services/tracked_source.dart';
import 'package:ai_camera/services/zoom_ladder.dart';
import 'package:ai_camera/services/zoom_preview_policy.dart';
import 'package:ai_camera/services/zoom_source.dart';
import 'package:ai_camera/services/zoom_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/synth_scene.dart';

typedef View = (double, double, double, double); // cx, cy, fov, angle

const _aspect = kTrackH / kTrackW;

GreyImage proxyOf(SynthScene s, View v, {double blur = 0, int seed = 1}) =>
    s.view(
      kTrackW,
      kTrackH,
      cx: v.$1,
      cy: v.$2,
      fov: v.$3,
      angle: v.$4,
      blur: blur,
      noise: 3,
      seed: seed,
    );

/// A handheld zoom from 1x to [to] with drift; every [blurEvery]th frame
/// heavily blurred. Returns the views and the tracker after feeding them.
(List<View>, ZoomTracker, List<TrackUpdate>) zoomRun(
  SynthScene s, {
  double to = 8,
  double driftX = 0.004,
  double driftY = 0.003,
  int blurEvery = 4,
  double step = 1.08,
}) {
  final tr = ZoomTracker();
  final views = <View>[];
  final ups = <TrackUpdate>[];
  var cx = 0.0, cy = 0.0, z = 1.0;
  var i = 0;
  final t0 = DateTime(2026, 11, 11);
  while (z < to) {
    cx += driftX * ((i % 5) - 1.5) / z;
    cy += driftY * ((i % 3) - 0.8) / z;
    final v = (cx, cy, 1 / z, 0.002 * (i % 4));
    views.add(v);
    final blur = blurEvery > 0 && i % blurEvery == blurEvery - 1 ? 4.0 : 0.0;
    ups.add(
      tr.update(
        TrackFrame(
          proxyOf(s, v, blur: blur, seed: i),
          z * 1.04, // camera zoom report a little off (a guess only)
          t0.add(Duration(milliseconds: 250 * i)),
        ),
      ),
    );
    z *= step;
    i++;
  }
  return (views, tr, ups);
}

/// Ground-truth rect of view [v]'s whole frame inside view [ref].
NRect truthRoi(View v, View ref, {double frac = 1}) =>
    mapRect(trueMap(v, ref), NRect.centre(frac, frac, _aspect));

void expectRect(NRect a, NRect b, double tol) {
  expect((a.l - b.l).abs(), lessThan(tol), reason: '$a vs $b');
  expect((a.t - b.t).abs(), lessThan(tol), reason: '$a vs $b');
  expect((a.r - b.r).abs(), lessThan(tol), reason: '$a vs $b');
  expect((a.b - b.b).abs(), lessThan(tol), reason: '$a vs $b');
}

RgbFrame rgbView(
  SynthScene s,
  int w,
  int h,
  View v, {
  double noise = 0,
  int seed = 1,
  double blur = 0,
}) => RgbFrame(
  w,
  h,
  toRgb(
    s.view(
      w,
      h,
      cx: v.$1,
      cy: v.$2,
      fov: v.$3,
      angle: v.$4,
      noise: noise,
      seed: seed,
      blur: blur,
      ss: 1,
    ),
  ),
);

GreyImage lumaOf(RgbFrame f) {
  final d = Float32List(f.width * f.height);
  for (var i = 0; i < d.length; i++) {
    d[i] = f.lumaAt(i);
  }
  return GreyImage(f.width, f.height, d);
}

GreyImage cropGrey(GreyImage g, (int, int, int, int) r) {
  final (x, y, w, h) = r;
  final d = Float32List(w * h);
  for (var yy = 0; yy < h; yy++) {
    for (var xx = 0; xx < w; xx++) {
      d[yy * w + xx] = g.data[(y + yy) * g.width + x + xx];
    }
  }
  return GreyImage(w, h, d);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('version 1.11.62+75', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('version: 1.11.62+75'),
    );
  });

  group('similarity registration', () {
    final s = SynthScene(3);

    test('compose / inverse are exact', () {
      final a = Similarity.of(scale: 0.5, angle: 0.1, tx: 0.03, ty: -0.02);
      final b = Similarity.of(scale: 1.7, angle: -0.05, tx: -0.1, ty: 0.04);
      final id = a.compose(a.inverse());
      expect(id.a, closeTo(1, 1e-12));
      expect(id.b, closeTo(0, 1e-12));
      expect(id.tx, closeTo(0, 1e-12));
      final (u, v) = b.compose(a).apply(0.2, -0.1);
      final (u1, v1) = a.apply(0.2, -0.1);
      final (u2, v2) = b.apply(u1, v1);
      expect(u, closeTo(u2, 1e-12));
      expect(v, closeTo(v2, 1e-12));
    });

    test('recovers translation + scale + rotation of a cropped view', () {
      const wide = (0.0, 0.0, 1.0, 0.0);
      const close = (0.06, -0.04, 0.5, 0.03);
      final r = registerSimilarity(
        proxyOf(s, close, blur: 1),
        proxyOf(s, wide),
        guess: Similarity.of(scale: 0.45), // zoom guess 10 % off
        scaleFactors: const [0.85, 0.92, 1.0, 1.08, 1.18],
        radius: 4,
      );
      final t = trueMap(close, wide);
      expect(r.score, greaterThan(0.95));
      expect(r.transform.scale, closeTo(t.scale, 0.01));
      expect(r.transform.angle, closeTo(t.angle, 0.01));
      expect(r.transform.tx, closeTo(t.tx, 0.004));
      expect(r.transform.ty, closeTo(t.ty, 0.004));
    });

    test('blurry + noisy intermediates still register (matched density)', () {
      const wide = (0.0, 0.0, 1.0, 0.0);
      for (final (blur, z) in [(3.0, 0.7), (6.0, 0.7), (4.0, 0.5)]) {
        final v = (0.03, 0.02, z, 0.0);
        final r = registerSimilarity(
          proxyOf(s, v, blur: blur),
          proxyOf(s, wide),
          guess: Similarity.of(scale: z * 1.1),
          scaleFactors: const [0.85, 0.92, 1.0, 1.08, 1.18],
          radius: 4,
        );
        expect(r.score, greaterThan(kTrackMinScore), reason: 'blur $blur');
        expect(r.transform.tx, closeTo(0.03, 0.006));
        expect(r.transform.scale, closeTo(z, 0.01));
      }
    });

    test('a different scene stays below the tracking threshold', () {
      final wide = proxyOf(s, (0, 0, 1, 0));
      for (var seed = 10; seed < 22; seed++) {
        final other = SynthScene(seed).view(kTrackW, kTrackH, fov: 0.5);
        final r = registerSimilarity(
          other,
          wide,
          guess: Similarity.of(scale: 0.5),
          scaleFactors: const [0.85, 0.92, 1.0, 1.08, 1.18],
          radius: 4,
        );
        expect(r.score, lessThan(kTrackMinScore), reason: 'seed $seed');
      }
    });

    test('flat image → no evidence (score −1), never a match', () {
      final flat = GreyImage(
        kTrackW,
        kTrackH,
        Float32List(kTrackW * kTrackH)..fillRange(0, kTrackW * kTrackH, 120),
      );
      final r = registerSimilarity(flat, proxyOf(s, (0, 0, 1, 0)));
      expect(r.score, -1);
    });
  });

  group('wide → close tracking', () {
    test('chained ROI through 1x→8x with drift + blurry frames', () {
      final s = SynthScene(3);
      final (views, tr, ups) = zoomRun(s);
      expect(tr.state, TrackState.tracking);
      expect(ups.where((u) => u.note.contains('key')).length, greaterThan(2));
      final est = tr.rootToCur!;
      // Final region (digital 1.25 on top) inside the 1x reference.
      final roi = roiInRef(
        rootToCur: est,
        ref: const TrackedRef(
          path: '',
          cameraZoom: 1,
          rootToRef: Similarity.identity(),
          sharpness: 1,
        ),
        finalRoi: NRect.centre(0.8, 0.8, _aspect),
        aspect: _aspect,
      )!;
      final truth = truthRoi(views.last, views.first, frac: 0.8);
      // ≤ 0.4 % of the frame width (≈ 16 px on a 4000 px still)
      expectRect(roi, truth, 0.004);
      // A whole-frame centre guess would be clearly off (the user drifted).
      final centre = NRect.centre(0.8 / 7.9, 0.8 / 7.9, _aspect);
      expect(
        (centre.cx - truth.cx).abs() + (centre.cy - truth.cy).abs(),
        greaterThan(0.004),
      );
    });

    test('blurry frames never become keyframes; chain kept', () {
      final s = SynthScene(5);
      final (_, tr, ups) = zoomRun(s, to: 5, blurEvery: 2);
      expect(tr.state, TrackState.tracking);
      for (var i = 1; i < ups.length; i += 2) {
        expect(ups[i].note.contains('key'), isFalse, reason: 'frame $i');
      }
      expect(tr.misses, 0);
    });

    test('chained transform to an intermediate reference', () {
      final s = SynthScene(7);
      final tr = ZoomTracker();
      final t0 = DateTime(2026);
      var k = 0;
      View? refView;
      Similarity? rootToRef;
      final views = <View>[];
      for (var z = 1.0; z < 7; z *= 1.1) {
        final v = (0.02 * math.sin(k / 3), 0.015 * math.cos(k / 4), 1 / z, 0.0);
        views.add(v);
        tr.update(TrackFrame(proxyOf(s, v, seed: k), z, t0));
        if (refView == null && z >= 2.5) {
          refView = v;
          rootToRef = tr.rootToCur; // the reference photo's tracked view
        }
        k++;
      }
      final roi = roiInRef(
        rootToCur: tr.rootToCur!,
        ref: TrackedRef(
          path: '',
          cameraZoom: 2.5,
          rootToRef: rootToRef!,
          sharpness: 1,
        ),
        finalRoi: NRect.frame(_aspect),
        aspect: _aspect,
      )!;
      final truth = truthRoi(views.last, refView!);
      // ≤ 4 % of the region's own width (the 1.3× search margin and the
      // strict re-alignment absorb this)
      expectRect(roi, truth, truth.w * 0.04);
    });

    test('different subject → lost after the miss budget, refs invalid', () {
      final s = SynthScene(3);
      final (_, tr, _) = zoomRun(s, to: 3);
      final other = SynthScene(41);
      final t0 = DateTime(2027);
      for (var i = 0; i < kTrackLostAfter - 1; i++) {
        tr.update(TrackFrame(other.view(kTrackW, kTrackH, fov: 0.33), 3, t0));
        expect(tr.state, TrackState.tracking, reason: 'one miss is not loss');
        expect(tr.rootToCur, isNotNull);
      }
      tr.update(TrackFrame(other.view(kTrackW, kTrackH, fov: 0.33), 3, t0));
      expect(tr.state, TrackState.lost);
      expect(tr.rootToCur, isNull);
      expect(tr.debugText, 'track lost (mismatch)');
    });

    test('moving outside the reference bounds → lost (left reference)', () {
      final s = SynthScene(3);
      final tr = ZoomTracker();
      final t0 = DateTime(2026);
      tr.update(TrackFrame(proxyOf(s, (0, 0, 1, 0)), 1, t0));
      var cx = 0.0;
      for (var i = 0; i < 12 && tr.state == TrackState.tracking; i++) {
        cx += 0.06; // panning away at 2x
        tr.update(TrackFrame(proxyOf(s, (cx, 0, 0.5, 0), seed: i), 2, t0));
      }
      expect(tr.state, TrackState.lost);
      expect(tr.lostReason, 'left reference');
    });

    test('reset clears the chain and diagnostics; rebase starts fresh', () {
      final s = SynthScene(3);
      final (views, tr, _) = zoomRun(s, to: 3);
      expect(tr.debugText, startsWith('track ok'));
      tr.reset();
      expect(tr.state, TrackState.idle);
      expect(tr.rootToCur, isNull);
      expect(tr.debugText, 'track idle');
      expect(tr.misses, 0);
      tr.rebase(TrackFrame(proxyOf(s, views.last), 3, DateTime(2026)));
      expect(tr.rootToCur!.scale, 1);
      expect(tr.debugText, startsWith('track ok 1.00 k1'));
    });

    test('aspect change / orientation → unsupported, no transform', () {
      final s = SynthScene(3);
      final tr = ZoomTracker();
      final t0 = DateTime(2026);
      tr.update(TrackFrame(proxyOf(s, (0, 0, 1, 0)), 1, t0));
      tr.update(TrackFrame(s.view(kTrackW, 40, fov: 0.9), 1.1, t0));
      expect(tr.state, TrackState.unsupported);
      expect(tr.rootToCur, isNull);
      expect(tr.debugText, 'track off (aspect)');
      tr.reset();
      tr.disable('orientation');
      expect(tr.state, TrackState.unsupported);
      expect(
        tr.update(TrackFrame(proxyOf(s, (0, 0, 1, 0)), 1, t0)).state,
        TrackState.unsupported,
      );
    });

    test('roiInRef: outside / large rotation → null (fail closed)', () {
      const ref = TrackedRef(
        path: '',
        cameraZoom: 2,
        rootToRef: Similarity.identity(),
        sharpness: 1,
      );
      // current view panned off the reference
      final off = Similarity.of(scale: 4, tx: -2.4).inverse().inverse();
      expect(
        roiInRef(
          rootToCur: off,
          ref: ref,
          finalRoi: NRect.frame(_aspect),
          aspect: _aspect,
        ),
        isNull,
      );
      expect(
        roiInRef(
          rootToCur: Similarity.of(scale: 4, angle: 0.4),
          ref: ref,
          finalRoi: NRect.frame(_aspect),
          aspect: _aspect,
        ),
        isNull,
      );
      final ok = roiInRef(
        rootToCur: Similarity.of(scale: 4),
        ref: ref,
        finalRoi: NRect.frame(_aspect),
        aspect: _aspect,
      )!;
      expect(ok.w, closeTo(0.25, 1e-9));
    });

    test('roiPixelRect: margin, clamped inside, reduced margin at edges', () {
      // centred ¼-width region in a 4000×3000 (portrait 3000×4000) still
      const roi = NRect(-0.125, -0.1667, 0.125, 0.1667);
      final ((x, y, w, h), m, long) = roiPixelRect(roi, 3000, 4000);
      expect(m, kTrackedSourceMargin);
      expect(w, (750 * kTrackedSourceMargin).round());
      expect(x, 1500 - w ~/ 2);
      expect(long, closeTo(1000, 1));
      expect(y + h, lessThanOrEqualTo(4000));
      // near the edge: shifted inside, never outside the image
      const edge = NRect(0.3, -0.1, 0.5, 0.1);
      final ((ex, _, ew, _), _, _) = roiPixelRect(edge, 3000, 4000);
      expect(ex + ew, lessThanOrEqualTo(3000));
      // region nearly the whole frame: margin reduced to fit
      const big = NRect(-0.48, -0.64, 0.48, 0.64);
      final (_, bm, _) = roiPixelRect(big, 3000, 4000);
      expect(bm, lessThan(kTrackedSourceMargin));
      expect(bm, greaterThanOrEqualTo(1));
    });
  });

  group('analysis proxy', () {
    // NV21 with luma = x (sensor coords) so the rotation is visible.
    Uint8List nv21(int w, int h) {
      final b = Uint8List(w * h * 3 ~/ 2);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          b[y * w + x] = (x * 255 ~/ (w - 1));
        }
      }
      return b;
    }

    test('upright mapping + aspect from the frame (rotation 90)', () {
      final p = trackProxy(nv21(64, 48), 64, 48, 64, 90, 36, 48);
      // sensor x → upright y (rotation 90: fx = v)
      expect(p[0], lessThan(20));
      expect(p[47 * 36], greaterThan(235));
      expect((p[0] - p[35]).abs(), lessThan(3)); // a row is constant
    });

    test('rotation 0 keeps x; box-averaged', () {
      final p = trackProxy(nv21(64, 48), 64, 48, 64, 0, 32, 24);
      expect(p[0], lessThan(20));
      expect(p[31], greaterThan(235));
    });

    test('frame stats: proxy only when tracking is on', () {
      final b = nv21(640, 480);
      final on = frameStatsFromNv21(b, 640, 480, rotation: 90, track: true);
      expect(on.trackWidth, kTrackProxyW);
      expect(on.trackHeight, 96); // portrait 3:4 from a 4:3 sensor frame
      expect(on.trackLuma!.length, kTrackProxyW * 96);
      final off = frameStatsFromNv21(b, 640, 480, rotation: 90);
      expect(off.trackLuma, isNull);
    });
  });

  group('live preview policies', () {
    final now = DateTime(2026, 11, 11, 12);
    bool af({
      int? state = kAfPassiveUnfocused,
      Duration rest = const Duration(seconds: 2),
      DateTime? last,
      bool user = false,
      double zoom = 4,
    }) => zoomAfNudgeDue(
      lowEnd: true,
      backLens: true,
      zoom: zoom,
      now: now,
      zoomChangedAt: now.subtract(rest),
      lastNudgeAt: last,
      afState: state,
      userFocus: user,
      busy: false,
    );

    test('AF nudge only with evidence, after rest, rate limited', () {
      expect(af(), isTrue);
      expect(af(state: kAfNotFocusedLocked), isTrue);
      expect(af(state: null), isFalse, reason: 'no AF state → no nudge');
      expect(af(state: 2), isFalse, reason: 'passive focused');
      expect(af(state: 4), isFalse, reason: 'focused locked');
      expect(af(rest: const Duration(milliseconds: 500)), isFalse);
      expect(af(last: now.subtract(const Duration(seconds: 2))), isFalse);
      expect(af(last: now.subtract(const Duration(seconds: 6))), isTrue);
      expect(af(user: true), isFalse, reason: 'user tap / lock wins');
      expect(af(zoom: 1.5), isFalse);
    });

    test('metering region never tiny (camera-frame fraction)', () {
      expect(meteringSizeForZoom(1), 0.15);
      expect(meteringSizeForZoom(3), 0.15);
      expect(meteringSizeForZoom(5), closeTo(0.10, 1e-9));
      expect(meteringSizeForZoom(40), 0.10);
      expect(meteringSizeForZoom(double.nan), 0.15);
      for (var z = 1.0; z < 100; z *= 1.3) {
        expect(meteringSizeForZoom(z), greaterThanOrEqualTo(0.10));
      }
    });

    bool ref({
      double cam = 4,
      List<double> refs = const [2],
      Duration rest = const Duration(seconds: 1),
      bool steady = true,
      bool tracked = true,
      double motion = 0.005,
      bool busy = false,
      bool flashOff = true,
      double hw = 10,
    }) => shouldCaptureReference(
      cameraZoom: cam,
      hardwareMax: hw,
      refZooms: refs,
      now: now,
      zoomChangedAt: now.subtract(rest),
      gyroSteady: steady,
      tracked: tracked,
      motion: motion,
      busy: busy,
      flashOff: flashOff,
    );

    test('reference stills: rested, steady, tracked, optically new only', () {
      expect(ref(), isTrue);
      // v11.61: the first reference is the low-zoom ROOT only.
      expect(ref(refs: const []), isFalse, reason: 'root must be ≤ 2x');
      expect(ref(refs: const [], cam: 1), isTrue);
      expect(ref(refs: const [], cam: 2), isTrue);
      expect(ref(cam: 2.5), isFalse, reason: '< 1.5× the last reference');
      expect(ref(cam: 12), isFalse, reason: 'above hardware max (no pixels)');
      expect(ref(refs: const [1, 2, 3, 4]), isFalse, reason: 'max 4');
      expect(ref(rest: const Duration(milliseconds: 300)), isFalse);
      expect(ref(steady: false), isFalse);
      expect(ref(tracked: false), isFalse);
      expect(ref(motion: 0.05), isFalse);
      expect(ref(busy: true), isFalse);
      expect(ref(flashOff: false), isFalse);
    });

    test('home: no per-checkpoint stills or centre-AF storms remain', () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(
        h,
        isNot(
          contains('Timer(kLadderSettle, () => unawaited(_takeLadderShot()))'),
        ),
      );
      expect(h, isNot(contains('meteringSizeFor(plan.digitalZoom)')));
      expect(h, contains('meteringSizeForZoom(plan.digitalZoom)'));
      expect(h, contains('zoomAfNudgeDue('));
      expect(h, contains('shouldCaptureReference('));
      // preview stays at the max resolution the phone supports
      expect(h, contains('ResolutionPreset.max'));
    });
  });

  group('burst merge', () {
    final s = SynthScene(11);
    const w = 180, h = 240;
    const inner = (14, 18, 152, 204);

    test('adaptive count: 2–4 frames, budget, slow capture stops', () {
      expect(burstWantsMore(taken: 0, elapsedMs: 0, lastCaptureMs: 0), isTrue);
      expect(
        burstWantsMore(taken: 1, elapsedMs: 900, lastCaptureMs: 900),
        isTrue,
        reason: 'minimum 2 frames even on a slow phone',
      );
      expect(
        burstWantsMore(taken: 2, elapsedMs: 1000, lastCaptureMs: 900),
        isFalse,
        reason: 'slow capture ends the burst',
      );
      expect(
        burstWantsMore(taken: 2, elapsedMs: 600, lastCaptureMs: 300),
        isTrue,
      );
      expect(
        burstWantsMore(taken: 3, elapsedMs: 1700, lastCaptureMs: 300),
        isFalse,
        reason: 'budget',
      );
      expect(
        burstWantsMore(taken: kBurstMaxFrames, elapsedMs: 0, lastCaptureMs: 1),
        isFalse,
      );
      expect(kBurstMaxFrames, lessThanOrEqualTo(4));
      expect(kBurstMaxRegionPixels, lessThanOrEqualTo(3000000));
    });

    test('shouldBurstZoom: native zoom (Pro AI Zoom 2x…max) kept', () {
      expect(
        shouldBurstZoom(
          lowEnd: true,
          digital: 1.0,
          regionPixels: 12000000,
          plainPhoto: true,
          nativeZoom: true,
        ),
        isTrue,
        reason: 'v11.9 coverage: full-res native-zoom frames, banded',
      );
      expect(
        shouldBurstZoom(
          lowEnd: true,
          digital: 1.0,
          regionPixels: 12000000,
          plainPhoto: true,
        ),
        isFalse,
      );
      expect(
        shouldBurstZoom(
          lowEnd: false,
          digital: 1.0,
          regionPixels: 12000000,
          plainPhoto: true,
          nativeZoom: true,
        ),
        isFalse,
      );
      expect(kBurstMaxBandedPixels, lessThanOrEqualTo(16000000));
      expect(kBurstBandPixels, lessThanOrEqualTo(1500000));
    });

    test('shouldBurstZoom: small digitally zoomed regions only', () {
      bool b(double d, int px, {bool low = true, bool plain = true}) =>
          shouldBurstZoom(
            lowEnd: low,
            digital: d,
            regionPixels: px,
            plainPhoto: plain,
          );
      expect(b(2, 2000000), isTrue);
      expect(b(1.1, 2000000), isFalse);
      expect(b(2, 5000000), isTrue, reason: 'banded: big regions merge');
      expect(b(2, 20000000), isFalse, reason: 'memory / time bound');
      expect(b(2, 2000000, low: false), isFalse);
      expect(b(2, 2000000, plain: false), isFalse);
    });

    List<(View, RgbFrame)> burst({double noise = 10, int n = 4}) => [
      for (var i = 0; i < n; i++)
        () {
          final v = (
            0.003 * math.sin(i * 1.7),
            0.002 * math.cos(i * 2.3),
            0.6,
            0.004 * math.sin(i * 0.9),
          );
          return (v, rgbView(s, w, h, v, noise: noise, seed: 100 + i));
        }(),
    ];

    test('aligned merge reduces noise and preserves content', () {
      final fr = burst();
      final r = mergeBurst([for (final f in fr) f.$2], inner: inner);
      expect(r.used, greaterThanOrEqualTo(3), reason: r.debugText);
      final truth = cropGrey(lumaOf(rgbView(s, w, h, fr[r.anchor].$1)), inner);
      final anchorOnly = cropGrey(lumaOf(fr[r.anchor].$2), inner);
      final merged = lumaOf(r.image!);
      final eA = rms(anchorOnly, truth), eM = rms(merged, truth);
      expect(eM, lessThan(eA * 0.8), reason: 'anchor $eA merged $eM');
      expect(ncc(merged, truth), greaterThan(0.97));
      expect(r.image!.width, inner.$3);
      expect(r.image!.height, inner.$4);
    });

    test('anchor = the sharpest frame (a blurred first frame is not it)', () {
      final fr = burst(noise: 4);
      final blurred = rgbView(s, w, h, fr[0].$1, blur: 4, noise: 4);
      final r = mergeBurst([
        blurred,
        for (final f in fr.skip(1)) f.$2,
      ], inner: inner);
      expect(r.anchor, isNot(0));
    });

    test('moving patch → anchor kept there (no ghost)', () {
      final fr = burst(noise: 6);
      final frames = [for (final f in fr) f.$2];
      // frame 1 and 2: a bright object moved into the middle
      for (final k in [1, 2]) {
        final b = Uint8List.fromList(frames[k].rgb);
        for (var y = 100; y < 140; y++) {
          for (var x = 70; x < 110; x++) {
            b.fillRange((y * w + x) * 3, (y * w + x) * 3 + 3, 250);
          }
        }
        frames[k] = RgbFrame(w, h, b);
      }
      final r = mergeBurst(frames, inner: inner, budgetMs: 60000);
      final out = lumaOf(r.image!);
      final anc = cropGrey(lumaOf(frames[r.anchor]), inner);
      // inside the patch (inner coords) the result follows the anchor
      var maxDiff = 0.0;
      for (var y = 100 - inner.$2 + 4; y < 140 - inner.$2 - 4; y++) {
        for (var x = 70 - inner.$1 + 4; x < 110 - inner.$1 - 4; x++) {
          final i = y * inner.$3 + x;
          maxDiff = math.max(maxDiff, (out.data[i] - anc.data[i]).abs());
        }
      }
      expect(maxDiff, lessThan(40), reason: 'ghost of the moved object');
      expect(r.ghostTiles, greaterThan(0));
    });

    test('other exposure / other subject → left out, never averaged', () {
      final fr = burst(noise: 4, n: 2);
      final dark = RgbFrame(
        w,
        h,
        Uint8List.fromList([for (final v in fr[1].$2.rgb) (v * 0.6).round()]),
      );
      final other = rgbView(SynthScene(77), w, h, (0, 0, 0.6, 0), noise: 4);
      final r = mergeBurst([fr[0].$2, dark, other], inner: inner);
      expect(r.used, 1);
      final st = {for (final n in r.notes) n.index: n.status};
      expect(st.values, containsAll(['exposure', 'unaligned']));
      expect(r.debugText, startsWith('best of 3'));
      // the output is the anchor's region, untouched
      final all = [fr[0].$2, dark, other];
      expect(r.image!.rgb, frames0(all[r.anchor], inner));
    });

    test('no halos: merged + sharpened stays within local extremes', () {
      // a hard step edge, identical clean frames
      final b = Uint8List(w * h * 3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          b.fillRange((y * w + x) * 3, (y * w + x) * 3 + 3, x < 90 ? 40 : 200);
        }
      }
      final f = RgbFrame(w, h, b);
      // add texture so registration has evidence
      final tex = rgbView(s, w, h, (0, 0, 0.6, 0));
      final mix = RgbFrame(
        w,
        h,
        Uint8List.fromList([
          for (var i = 0; i < b.length; i++) ((b[i] * 3 + tex.rgb[i]) ~/ 4),
        ]),
      );
      final r = mergeBurst([mix, mix, f.rgb.isEmpty ? mix : mix], inner: inner);
      var mn = 255, mx = 0;
      for (final v in mix.rgb) {
        mn = math.min(mn, v);
        mx = math.max(mx, v);
      }
      for (final v in r.image!.rgb) {
        expect(v, inInclusiveRange(mn, mx));
      }
    });

    test('time budget exceeded → anchor alone, flagged', () {
      final fr = burst(noise: 8);
      final r = mergeBurst(
        [for (final f in fr) f.$2],
        inner: inner,
        budgetMs: -1,
      );
      expect(r.timedOut, isTrue);
      expect(r.used, 1);
    });

    test('cancellable isolate job: result, files, cancel → null', () async {
      final dir = Directory.systemTemp.createTempSync('v1160b');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fr = burst(noise: 8);
      final files = <String>[];
      for (var i = 0; i < fr.length; i++) {
        final p = '${dir.path}/f$i.png';
        File(p).writeAsBytesSync(img.encodePng(rgbImage(fr[i].$2)));
        files.add(p);
      }
      final out = '${dir.path}/out.jpg';
      final job = await BurstJob.start(
        paths: files,
        region: (0, 0, w, h),
        inner: inner,
        outJpeg: out,
        native: false,
      );
      final r = await job.result.timeout(const Duration(seconds: 60));
      expect(r, isNotNull);
      expect(r!.used, greaterThanOrEqualTo(2), reason: r.debugText);
      final jpg = img.decodeJpg(File(out).readAsBytesSync())!;
      expect(jpg.width, inner.$3);
      expect(jpg.height, inner.$4);
      // cancel right away → completes (null), no hang
      final job2 = await BurstJob.start(
        paths: files,
        region: (0, 0, w, h),
        inner: inner,
        outJpeg: '${dir.path}/out2.jpg',
        native: false,
      );
      job2.cancel();
      expect(await job2.result.timeout(const Duration(seconds: 10)), isNull);
      deleteQuietly(files);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(files.every((f) => !File(f).existsSync()), isTrue);
    });

    RegionReader memReader(Map<String, RgbFrame> m) => (p, rect, sample) async {
      final f = m[p]!;
      final (x, y, rw, rh) = rect;
      final ow = (rw / sample).floor(), oh = (rh / sample).floor();
      final o = Uint8List(ow * oh * 3);
      for (var yy = 0; yy < oh; yy++) {
        for (var xx = 0; xx < ow; xx++) {
          final si = ((y + yy * sample) * f.width + x + xx * sample) * 3;
          o.setRange((yy * ow + xx) * 3, (yy * ow + xx) * 3 + 3, f.rgb, si);
        }
      }
      return RgbFrame(ow, oh, o);
    };

    test(
      'banded merge: identical to one band (no seams), sub-region',
      () async {
        final fr = burst(noise: 10);
        final m = {for (var i = 0; i < fr.length; i++) 'f$i': fr[i].$2};
        final paths = m.keys.toList();
        // region = a margin-cropped part of the still; inner off the tile grid
        const region = (6, 4, 170, 230);
        const inn = (11, 13, 141, 197);
        final (one, r1) = await mergeBurstBanded(
          paths: paths,
          region: region,
          inner: inn,
          read: memReader(m),
          rows: 100000,
        );
        final (many, r2) = await mergeBurstBanded(
          paths: paths,
          region: region,
          inner: inn,
          read: memReader(m),
          rows: 16,
        );
        expect(one, isNotNull);
        expect(r1.used, greaterThanOrEqualTo(3), reason: r1.debugText);
        expect(r2.used, r1.used);
        expect(many, one, reason: 'bands must not leave seams');
        expect(one!.length, inn.$3 * inn.$4 * 3);
        // and it really denoises vs the anchor alone
        final truth = cropGrey(lumaOf(rgbView(s, w, h, fr[r1.anchor].$1)), (
          region.$1 + inn.$1,
          region.$2 + inn.$2,
          inn.$3,
          inn.$4,
        ));
        final anchorOnly = cropGrey(lumaOf(fr[r1.anchor].$2), (
          region.$1 + inn.$1,
          region.$2 + inn.$2,
          inn.$3,
          inn.$4,
        ));
        final merged = lumaOf(RgbFrame(inn.$3, inn.$4, one));
        expect(rms(merged, truth), lessThan(rms(anchorOnly, truth) * 0.8));
      },
    );

    test(
      'banded merge: band reads stay bounded (no full-frame decode)',
      () async {
        final fr = burst(noise: 8);
        final m = {for (var i = 0; i < fr.length; i++) 'f$i': fr[i].$2};
        final reads = <(int, int, int, int)>[];
        final base = memReader(m);
        Future<RgbFrame> spy(String p, (int, int, int, int) r, int sample) {
          reads.add(r);
          return base(p, r, sample);
        }

        final (out, _) = await mergeBurstBanded(
          paths: m.keys.toList(),
          region: (0, 0, w, h),
          inner: inner,
          read: spy,
          rows: 32,
        );
        expect(out, isNotNull);
        // after the n proxy + n centre reads: band reads only (32 rows +
        // whole-tile context + the mapped margin), never the whole frame
        final bands = reads.skip(2 * m.length).toList();
        expect(bands.length, greaterThan(m.length * 3));
        final maxFull = bands.map((r) => r.$3 * r.$4).reduce(math.max);
        expect(maxFull, lessThan(w * h ~/ 2), reason: 'max $maxFull px');
      },
    );

    test('banded merge over time → null image, flagged (caller keeps the '
        'sharpest full still)', () async {
      final fr = burst(noise: 8);
      final m = {for (var i = 0; i < fr.length; i++) 'f$i': fr[i].$2};
      final (out, r) = await mergeBurstBanded(
        paths: m.keys.toList(),
        region: (0, 0, w, h),
        inner: inner,
        read: memReader(m),
        budgetMs: -1,
      );
      expect(out, isNull);
      expect(r.timedOut, isTrue);
      expect(r.used, 1);
    });

    test('Dart region decode fallback: upright crop of the still', () async {
      final dir = Directory.systemTemp.createTempSync('v1160d');
      addTearDown(() => dir.deleteSync(recursive: true));
      final im = img.Image(width: 60, height: 80);
      for (var y = 0; y < 80; y++) {
        for (var x = 0; x < 60; x++) {
          im.setPixelRgb(x, y, x * 4, y * 3, 9);
        }
      }
      final p = '${dir.path}/s.png';
      File(p).writeAsBytesSync(img.encodePng(im));
      expect(await uprightSize(p), (60, 80));
      final (rp, rw, rh) = await decodeRegion(p, (
        10,
        20,
        30,
        40,
      ), '${dir.path}/r.rgb');
      expect((rw, rh), (30, 40));
      final b = File(rp).readAsBytesSync();
      expect(b.length, 30 * 40 * 3);
      expect(b[0], 40); // x = 10 → 40
      expect(b[1], 60); // y = 20 → 60
    });

    test('home: Normal + Pro, offline too; temp files cleaned', () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      final i = h.indexOf(
        'final b = await _zoomBurst(c, snap, nativeZoom: nativeZoomMerge);',
      );
      expect(i, greaterThan(0));
      final cond = h.substring(h.lastIndexOf('} else if (', i), i);
      expect(cond, isNot(contains('snap.ai')), reason: 'Normal mode too');
      expect(cond, isNot(contains('online')), reason: 'local, works offline');
      expect(cond, contains('snap.digital > 1.2 || nativeZoomMerge'));
      // v11.9 coverage: Pro AI Zoom mode 2x … native max on cheap phones
      final nz = h.substring(h.indexOf('final nativeZoomMerge ='));
      expect(
        nz.substring(0, 260),
        allOf(
          contains('snap.ai'),
          contains('_zoomModeActive'),
          contains('shouldMergeZoom('),
        ),
      );
      expect(h, contains('BurstJob.start(\n        paths: paths,'));
      expect(h, contains('final keep = paths[res.anchor];'));
      expect(h, contains('_deletePaths(paths);'));
      expect(h, contains('_burstJob?.cancel()'));
      expect(h, isNot(contains('rgbs')));
    });
  });

  group('tracked sharp source (integration)', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('v1160s'));
    tearDown(() => dir.deleteSync(recursive: true));

    File jpgOf(GreyImage g, String name, {int q = 95}) {
      final im = img.Image.fromBytes(
        width: g.width,
        height: g.height,
        bytes: toRgb(g).buffer,
        numChannels: 3,
      );
      return File('${dir.path}/$name')
        ..writeAsBytesSync(img.encodeJpg(im, quality: q));
    }

    test(
      'final region found in the clear 1x reference via tracking; content = truth',
      () async {
        final s = SynthScene(3);
        // user drifts clearly while zooming to ~4x
        final (views, tr, _) = zoomRun(s, to: 4.2, driftX: 0.02, driftY: 0.012);
        expect(tr.state, TrackState.tracking);
        final root = views.first;
        final wide = s.view(
          720,
          960,
          cx: root.$1,
          cy: root.$2,
          fov: root.$3,
          ss: 1,
        );
        final ref = jpgOf(wide, 'ref.jpg');
        final last = views.last;
        const frac = 0.8; // digital 1.25 on top
        final fv = (last.$1, last.$2, last.$3 * frac, last.$4);
        final fin = jpgOf(
          s.view(
            300,
            400,
            cx: fv.$1,
            cy: fv.$2,
            fov: fv.$3,
            angle: fv.$4,
            blur: 5,
            ss: 1,
          ),
          'final.jpg',
        );
        final tc = await trackedSourceCandidates(
          refs: [
            LadderShot(
              checkpoint: 1,
              path: ref.path,
              cameraZoom: 1,
              sharpness: 100,
              rootToRef: const Similarity.identity(),
            ),
          ],
          rootToCur: tr.rootToCur!,
          trackAspect: _aspect,
          finalFrac: (frac, frac),
          outDir: dir.path,
        );
        expect(tc.notes.single, startsWith('1.0x roi '));
        expect(tc.notes.single, endsWith('px opt 1x'));
        final d = await pickZoomSource(
          finalAreaPath: fin.path,
          candidates: tc.candidates,
        );
        expect(d.ok, isTrue, reason: d.debugText);
        // The chosen source shows exactly the final region (ground truth).
        final src = img.decodeJpg(File(d.path!).readAsBytesSync())!;
        final g = GreyImage(
          src.width,
          src.height,
          Float32List.fromList([for (final p in src) p.r.toDouble()]),
        );
        final truth = s.view(
          src.width,
          src.height,
          cx: fv.$1,
          cy: fv.$2,
          fov: fv.$3,
          angle: fv.$4,
          ss: 1,
        );
        expect(ncc(g, truth), greaterThan(0.9));
        // The AI payload: the tracked source is the primary image, the
        // (blurry / merged) final only framing.
        final job = EnhanceJob(
          image: fin,
          zoomSource: File(d.path!),
          zoom: 5,
          opticalLimit: 1,
          zoomClean: true,
        );
        expect(job.primaryImage.path, d.path);
        expect(job.sentSteps.single.path, fin.path);
      },
    );

    test(
      'untracked / aspect-mismatched refs → no candidates (fail closed)',
      () async {
        final s = SynthScene(3);
        final ref = jpgOf(s.view(120, 160, ss: 1), 'r.jpg');
        final odd = jpgOf(s.view(160, 120, ss: 1), 'o.jpg');
        final tc = await trackedSourceCandidates(
          refs: [
            LadderShot(
              checkpoint: 1,
              path: ref.path,
              cameraZoom: 1,
              sharpness: 9,
            ),
            LadderShot(
              checkpoint: 2,
              path: odd.path,
              cameraZoom: 2,
              sharpness: 9,
              rootToRef: const Similarity.identity(),
            ),
          ],
          rootToCur: Similarity.of(scale: 3),
          trackAspect: _aspect,
          finalFrac: (1, 1),
          outDir: dir.path,
        );
        expect(tc.candidates, isEmpty);
        expect(tc.notes, ['1.0x untracked', '2.0x aspect']);
        final d = await pickZoomSource(
          finalAreaPath: ref.path,
          candidates: tc.candidates,
        );
        expect(d.ok, isFalse);
        expect(d.reason, ZoomSourceReason.noClearRef);
      },
    );

    test('home: ladder sources come only from the tracking chain', () {
      final h = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(h, contains('s.rootToRef != null && File(s.path).existsSync()'));
      expect(h, contains('trackedSourceCandidates('));
      expect(h, contains('candidates: tc?.candidates ?? const []'));
      // no centre-cut ladder references any more
      expect(h, isNot(contains('kZoomSourceMargin\n')));
      expect(h, contains('_snack(zoomFailMessage('));
      expect(h, contains('_dropTrackedRefs('));
      // rotation / lens switch → reset + fresh reference (no disabling)
      expect(h, isNot(contains("disable('orientation')")));
      expect(h, contains("_invalidateTracking('rotation')"));
      expect(h, contains("_invalidateTracking('lens switch')"));
      expect(h, contains("info['activePhysicalId']"));
      expect(
        h,
        contains('detectStillRotation(ana, proxy, landscape: landscape)'),
      );
      expect(h, contains('shutterRot: trackRot,'));
      // tracker work is off the UI isolate
      expect(h, contains('TrackerWorker.start()'));
      expect(h, isNot(contains('_tracker.update(')));
      expect(h, isNot(contains('ZoomTracker()')));
    });
  });
}

Uint8List frames0(RgbFrame f, (int, int, int, int) r) {
  final (x, y, w, h) = r;
  final o = Uint8List(w * h * 3);
  for (var yy = 0; yy < h; yy++) {
    o.setRange(
      yy * w * 3,
      (yy + 1) * w * 3,
      f.rgb,
      ((y + yy) * f.width + x) * 3,
    );
  }
  return o;
}

img.Image rgbImage(RgbFrame f) => img.Image.fromBytes(
  width: f.width,
  height: f.height,
  bytes: f.rgb.buffer,
  numChannels: 3,
);
