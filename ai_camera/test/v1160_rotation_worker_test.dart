// v11.60 regression fixes: still rotation (portrait / landscape /
// upside-down) mapping + crop correctness, and the off-UI tracker worker
// (single in-flight, stale frames dropped, epoch reset). Synthetic only.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ai_camera/services/image_register.dart';
import 'package:ai_camera/services/tracked_source.dart';
import 'package:ai_camera/services/zoom_ladder.dart';
import 'package:ai_camera/services/zoom_tracker.dart';
import 'package:ai_camera/services/zoom_tracker_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support/synth_scene.dart';

const _aspect = kTrackH / kTrackW;

GreyImage crop(GreyImage g, (int, int, int, int) r) {
  final (x, y, w, h) = r;
  return GreyImage(
    w,
    h,
    Float32List.fromList([
      for (var yy = 0; yy < h; yy++)
        for (var xx = 0; xx < w; xx++) g.data[(y + yy) * g.width + x + xx],
    ]),
  );
}

GreyImage fromJpg(String p) {
  final im = img.decodeJpg(File(p).readAsBytesSync())!;
  return GreyImage(
    im.width,
    im.height,
    Float32List.fromList([
      for (final px in im)
        (0.299 * px.r + 0.587 * px.g + 0.114 * px.b).toDouble(),
    ]),
  );
}

Future<void> until(bool Function() f) async {
  for (var i = 0; i < 400 && !f(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(f(), isTrue, reason: 'timeout');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final s = SynthScene(5);
  // portrait-up, landscape (both ways), upside-down
  const names = {
    0: 'portrait',
    1: 'landscape cw',
    2: 'upside-down',
    3: 'landscape ccw',
  };

  group('still rotation', () {
    test('rotateGreyCw: 4 turns = identity; one turn moves corners', () {
      final g = s.view(6, 4, ss: 1);
      final r1 = rotateGreyCw(g, 1);
      expect((r1.width, r1.height), (4, 6));
      // top-left of the rotated = bottom-left of the source
      expect(r1.data[0], g.data[(4 - 1) * 6]);
      expect(rotateGreyCw(g, 4).data, g.data);
      expect(rotateGreyCw(rotateGreyCw(g, 3), 1).data, g.data);
    });

    test('finalRoiInAnalysis swaps axes for quarter turns', () {
      final a = finalRoiInAnalysis(0.5, 0.25, _aspect, 1);
      final b = NRect.centre(0.25, 0.5, _aspect);
      expect((a.l, a.t, a.r, a.b), (b.l, b.t, b.r, b.b));
      final c = finalRoiInAnalysis(0.5, 0.25, _aspect, 2);
      final d = NRect.centre(0.5, 0.25, _aspect);
      expect((c.l, c.t, c.r, c.b), (d.l, d.t, d.r, d.b));
    });

    for (final k in [0, 1, 2, 3]) {
      test('ROI mapping + crop content: ${names[k]} (k=$k)', () {
        const w = 360, h = 480;
        final view = s.view(w, h, ss: 1);
        final still = rotateGreyCw(view, k);
        // off-centre region in analysis coords
        const roi = NRect(-0.30, -0.10, 0.05, 0.35);
        final sr = roiToStill(roi, h / w, k, still.width, still.height);
        final (rect, _, _) = roiPixelRect(
          sr,
          still.width,
          still.height,
          margin: 1,
        );
        final got = rotateGreyCw(crop(still, rect), 4 - k);
        final (tRect, _, _) = roiPixelRect(roi, w, h, margin: 1);
        final want = crop(view, tRect);
        expect((got.width - want.width).abs(), lessThanOrEqualTo(1));
        expect((got.height - want.height).abs(), lessThanOrEqualTo(1));
        final gw = math.min(got.width, want.width);
        final gh = math.min(got.height, want.height);
        expect(
          ncc(crop(got, (0, 0, gw, gh)), crop(want, (0, 0, gw, gh))),
          greaterThan(0.98),
        );
      });

      test('detectStillRotation decides k=$k (${names[k]}) by image', () {
        final ana = s.view(kTrackW, kTrackH, noise: 3, seed: 2);
        final hi = s.view(96 * 3, 128 * 3, ss: 1, noise: 2, seed: 9);
        final still = resizeGrey(
          rotateGreyCw(hi, k),
          k.isOdd ? 128 : 96,
          k.isOdd ? 96 : 128,
        );
        final r = detectStillRotation(ana, still, landscape: k.isOdd);
        expect(r.k, k, reason: 'score ${r.score} margin ${r.margin}');
        expect(r.margin, greaterThanOrEqualTo(kRotationMargin));
        // contradicting metadata (portrait vs landscape) → not verified
        final bad = detectStillRotation(ana, still, landscape: !k.isOdd);
        expect(bad.ok, isFalse);
      });
    }

    test('different scene / flat still → rotation unverified (no ref)', () {
      final ana = s.view(kTrackW, kTrackH, noise: 3);
      final other = SynthScene(91).view(96, 128, ss: 1);
      expect(detectStillRotation(ana, other, landscape: false).ok, isFalse);
      final flat = GreyImage(
        96,
        128,
        Float32List(96 * 128)..fillRange(0, 96 * 128, 90),
      );
      expect(detectStillRotation(ana, flat, landscape: false).ok, isFalse);
    });

    test('tracked source from a LANDSCAPE / UPSIDE-DOWN ref = the portrait '
        'crop (content), wrong rotation → aspect', () async {
      final dir = Directory.systemTemp.createTempSync('v1160r');
      addTearDown(() => dir.deleteSync(recursive: true));
      String jpg(GreyImage g, String n) {
        final im = img.Image.fromBytes(
          width: g.width,
          height: g.height,
          bytes: toRgb(g).buffer,
          numChannels: 3,
        );
        final p = '${dir.path}/$n';
        File(p).writeAsBytesSync(img.encodeJpg(im, quality: 95));
        return p;
      }

      final wide = s.view(720, 960, ss: 1);
      final t = Similarity.of(scale: 2.5, tx: 0.06, ty: -0.04);
      Future<TrackedCandidates> run(int refK, int stillRot, int shutterRot) =>
          trackedSourceCandidates(
            refs: [
              LadderShot(
                checkpoint: 1,
                path: jpg(rotateGreyCw(wide, refK), 'r${refK}_$stillRot.jpg'),
                cameraZoom: 1,
                sharpness: 9,
                rootToRef: const Similarity.identity(),
                stillRot: stillRot,
              ),
            ],
            rootToCur: t,
            trackAspect: _aspect,
            finalFrac: shutterRot.isOdd ? (0.8, 0.6) : (0.6, 0.8),
            shutterRot: shutterRot,
            outDir: dir.path,
          );
      final base = await run(0, 0, 0);
      expect(base.candidates, hasLength(1), reason: '${base.notes}');
      final want = fromJpg(base.candidates.single.refCropPath);
      for (final k in [1, 2, 3]) {
        final tc = await run(k, k, k);
        expect(tc.candidates, hasLength(1), reason: '${names[k]} ${tc.notes}');
        final got = rotateGreyCw(
          fromJpg(tc.candidates.single.refCropPath),
          4 - k,
        );
        expect((got.width - want.width).abs(), lessThanOrEqualTo(2));
        final gw = math.min(got.width, want.width);
        final gh = math.min(got.height, want.height);
        expect(
          ncc(crop(got, (0, 0, gw, gh)), crop(want, (0, 0, gw, gh))),
          greaterThan(0.97),
          reason: names[k],
        );
      }
      // a landscape still claimed portrait → aspect check fails closed
      final bad = await run(1, 0, 0);
      expect(bad.candidates, isEmpty);
      expect(bad.notes, ['1.0x aspect']);
    });
  });

  group('tracker worker (off the UI isolate)', () {
    List<TrackFrame> frames(int n) {
      final t0 = DateTime(2026, 11, 11);
      var z = 1.0;
      return [
        for (var i = 0; i < n; i++)
          () {
            final f = TrackFrame(
              s.view(
                kTrackW,
                kTrackH,
                cx: 0.003 * i,
                cy: -0.002 * i,
                fov: 1 / z,
                noise: 3,
                seed: i,
              ),
              z,
              t0.add(Duration(milliseconds: 250 * i)),
            );
            z *= 1.1;
            return f;
          }(),
      ];
    }

    test('same chain as the in-process tracker', () async {
      final w = await TrackerWorker.start();
      addTearDown(w.dispose);
      final ref = ZoomTracker();
      for (final f in frames(8)) {
        ref.update(f);
        final n = w.processed;
        w.submit(f);
        await until(() => w.processed == n + 1);
      }
      expect(w.snapshot.state, ref.state);
      final a = w.snapshot.rootToCur!, b = ref.rootToCur!;
      expect((a.a - b.a).abs() + (a.b - b.b).abs(), lessThan(1e-6));
      expect((a.tx - b.tx).abs() + (a.ty - b.ty).abs(), lessThan(1e-6));
      expect(w.snapshot.debugText, ref.debugText);
      expect(w.dropped, 0);
    });

    test('one update in flight; stale frames dropped, newest kept', () async {
      final w = await TrackerWorker.start();
      addTearDown(w.dispose);
      final fs = frames(12);
      for (final f in fs) {
        w.submit(f);
      }
      await until(() => w.idle);
      expect(w.maxInFlight, 1);
      expect(w.dropped, greaterThan(0));
      expect(w.processed + w.dropped, fs.length);
      // the newest frame was processed last
      expect(w.snapshot.curAt, fs.last.at);
    });

    test('reset: replies from before it are ignored (epoch)', () async {
      final w = await TrackerWorker.start();
      addTearDown(w.dispose);
      final got = <TrackSnapshot>[];
      w.onUpdate = got.add;
      final fs = frames(3);
      w.submit(fs[0]);
      w.submit(fs[1]);
      w.reset();
      await until(() => w.idle);
      expect(got, isEmpty, reason: 'stale replies delivered');
      expect(w.snapshot.state, TrackState.idle);
      expect(w.snapshot.rootToCur, isNull);
      w.submit(fs[2]);
      await until(() => w.idle && got.isNotEmpty);
      expect(got.single.epoch, w.epoch);
      expect(got.single.curAt, fs[2].at);
      w.disable('test');
      expect(w.snapshot.state, TrackState.unsupported);
    });
  });
}
