import 'dart:io';

import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/models/shoot_mode.dart';
import 'package:ai_camera/models/style_preset.dart';
import 'package:ai_camera/screens/editor_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/barcode_actions.dart';
import 'package:ai_camera/services/document_scan.dart';
import 'package:ai_camera/services/hdr_merge.dart';
import 'package:ai_camera/services/live_look.dart';
import 'package:ai_camera/services/live_policies.dart';
import 'package:ai_camera/services/photo_edit.dart';
import 'package:ai_camera/services/scene_suggest.dart';
import 'package:ai_camera/widgets/document_sheet.dart';
import 'package:ai_camera/widgets/live_overlays.dart';
import 'package:ai_camera/widgets/mode_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

/// Black/white vertical stripes (sharp edges everywhere).
img.Image stripes(int w, int h) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = (x ~/ 4).isEven ? 255 : 0;
      im.setPixelRgb(x, y, v, v, v);
    }
  }
  return im;
}

/// Mean squared horizontal gradient in a column band (sharpness proxy —
/// squared so steeper edges score higher than the same step spread out).
double edgeEnergy(img.Image im, int x0, int x1) {
  var s = 0.0, n = 0;
  for (var y = 0; y < im.height; y += 2) {
    for (var x = x0; x < x1 - 1; x++) {
      final d = im.getPixel(x + 1, y).r - im.getPixel(x, y).r;
      s += d * d;
      n++;
    }
  }
  return s / n;
}

void main() {
  // ---------------------------------------------------------------------------
  group('mode routing (v11)', () {
    test('photo: faces + QR + scene labels + frame stats by default', () {
      final r = routeFor(ShootMode.photo);
      expect(r.capture, CaptureKind.single);
      expect(r.analyzers, {
        LiveAnalyzer.faces,
        LiveAnalyzer.barcodes,
        LiveAnalyzer.labels,
        LiveAnalyzer.frameStats,
      });
      expect(r.night || r.blocked, isFalse);
      expect(r.aiMode, 'photo');
    });

    test('night → burst, light stream (QR + frame stats)', () {
      final r = routeFor(ShootMode.night);
      expect(r.night, isTrue);
      expect(r.capture, CaptureKind.nightBurst);
      expect(r.analyzers, {LiveAnalyzer.barcodes, LiveAnalyzer.frameStats});
      expect(r.aiMode, 'photo');
      expect(routeFor(ShootMode.night, aiMode: true).aiMode, 'night');
      expect(
        routeFor(
          ShootMode.night,
          features: const CameraFeatures(scanQr: false),
        ).analyzers,
        {LiveAnalyzer.frameStats},
      );
    });

    test('document → scanner, no live stream', () {
      final r = routeFor(ShootMode.document);
      expect(r.capture, CaptureKind.documentScanner);
      expect(r.analyzers, isEmpty);
    });

    test('hdr → 3-frame bracket, no labels', () {
      // v11.49: HDR removed → single photo.
      final r = routeFor(ShootMode.hdr);
      expect(r.capture, CaptureKind.single);
    });

    test('pose → labels for scene ordering, no pose model', () {
      final r = routeFor(ShootMode.pose);
      expect(r.capture, CaptureKind.single);
      expect(r.analyzers, contains(LiveAnalyzer.labels));
    });

    test('toggles switch analyzers off', () {
      const off = CameraFeatures(
        scanQr: false,
        faceFocus: false,
        smileShot: false,
        sceneTips: false,
      );
      expect(routeFor(ShootMode.photo, features: off).analyzers, {
        LiveAnalyzer.frameStats,
      });
      expect(
        routeFor(
          ShootMode.photo,
          features: const CameraFeatures(faceFocus: false, smileShot: true),
        ).analyzers,
        contains(LiveAnalyzer.faces),
      );
    });

    test('CameraFeatures defaults + JSON round trip', () {
      const d = CameraFeatures();
      expect(d.scanQr && d.faceFocus && d.sceneTips && d.grid, isTrue);
      expect(d.smileShot || d.level, isFalse);
      final c = d.copyWith(level: true, smileShot: true);
      expect(CameraFeatures.fromJson(c.toJson()), c);
      expect(CameraFeatures.fromJson(null), d);
      expect(CameraFeatures.fromJson({'grid': 'yes'}).grid, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  group('QR / barcode chip', () {
    test('classifies common Indian payloads', () {
      final upi = classifyScan(
        'upi://pay?pa=shop@okaxis&pn=Sharma%20Store&am=50',
      )!;
      expect(upi.kind, ScanKind.upi);
      expect(upi.actionLabel, 'Open UPI app');
      expect(upi.label, contains('Sharma Store'));
      expect(upi.uri!.scheme, 'upi');

      final url = classifyScan('https://example.com/menu')!;
      expect(url.kind, ScanKind.url);
      expect(url.actionLabel, 'Open link');
      expect(
        classifyScan('www.example.in')!.uri.toString(),
        'https://www.example.in',
      );
      expect(classifyScan('tel:+919800000000')!.actionLabel, 'Call');
      expect(classifyScan('mailto:a@b.com')!.actionLabel, 'Email');
      final wifi = classifyScan('WIFI:S:Home;T:WPA;P:secret;;')!;
      expect(wifi.label, 'Wi-Fi: Home');
      expect(wifi.uri, isNull);
      final text = classifyScan('INV-2026-00042')!;
      expect(text.kind, ScanKind.text);
      expect(text.actionLabel, 'Copy');
      expect(classifyScan('   '), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  group('scene suggestions (image labeling)', () {
    final t0 = DateTime(2026, 10, 8, 9);
    test('labels → mode tips', () {
      expect(
        suggestFor(const [
          SceneLabel('Paper', 0.9),
        ], mode: ShootMode.photo)?.mode,
        ShootMode.document,
      );
      expect(
        suggestFor(const [
          SceneLabel('Food', 0.85),
        ], mode: ShootMode.photo)?.mode,
        ShootMode.portrait,
      );
      expect(
        suggestFor(const [SceneLabel('Food', 0.5)], mode: ShootMode.photo),
        isNull, // weak label
      );
      // Already in that mode → no tip.
      expect(
        suggestFor(const [
          SceneLabel('Food', 0.9),
        ], mode: ShootMode.portrait)?.mode,
        isNot(ShootMode.portrait),
      );
    });

    test('gate: 2 sightings, 20 s gap, dismiss forever', () {
      final g = SuggestionGate();
      const s = SceneSuggestion(
        id: 'doc',
        text: 'Document? Try Document scan',
        mode: ShootMode.document,
      );
      expect(g.offer(s, t0), isNull);
      expect(g.offer(s, t0.add(const Duration(seconds: 2))), s);
      expect(g.offer(s, t0.add(const Duration(seconds: 4))), isNull);
      g.dismiss('doc');
      expect(g.offer(s, t0.add(const Duration(minutes: 10))), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  group('live policies', () {
    final t0 = DateTime(2026, 10, 8, 9);
    const smile = LiveFace(
      box: Rect.fromLTWH(0.4, 0.3, 0.2, 0.2),
      smiling: 0.95,
    );
    const neutral = LiveFace(
      box: Rect.fromLTWH(0.4, 0.3, 0.2, 0.2),
      smiling: 0.1,
    );

    test('smile shot: 2 consecutive smiles, 4 s cooldown', () {
      final s = SmileTrigger();
      expect(s.update([smile], t0), isFalse);
      expect(
        s.update([smile], t0.add(const Duration(milliseconds: 200))),
        isTrue,
      );
      expect(
        s.update([smile], t0.add(const Duration(milliseconds: 400))),
        isFalse,
      );
      expect(s.update([smile], t0.add(const Duration(seconds: 1))), isFalse);
      expect(s.update([neutral], t0.add(const Duration(seconds: 5))), isFalse);
      expect(s.update([smile], t0.add(const Duration(seconds: 6))), isFalse);
      expect(s.update([smile], t0.add(const Duration(seconds: 7))), isTrue);
    });

    test('face-priority focus: largest face, rate-limited, yields to tap', () {
      final p = FaceFocusPolicy();
      const small = LiveFace(box: Rect.fromLTWH(0.1, 0.1, 0.1, 0.1));
      const big = LiveFace(box: Rect.fromLTWH(0.5, 0.4, 0.3, 0.3));
      final pt = p.decide([small, big], t0, userFocusActive: false);
      expect(pt, const Offset(0.65, 0.55));
      expect(
        p.decide(
          [big],
          t0.add(const Duration(seconds: 2)),
          userFocusActive: false,
        ),
        isNull, // same place, not stale
      );
      expect(
        p.decide(
          [const LiveFace(box: Rect.fromLTWH(0.1, 0.4, 0.3, 0.3))],
          t0.add(const Duration(seconds: 2)),
          userFocusActive: false,
        ),
        isNotNull, // moved
      );
      expect(
        p.decide(
          [big],
          t0.add(const Duration(seconds: 30)),
          userFocusActive: true,
        ),
        isNull,
      );
      expect(
        p.decide(
          [const LiveFace(box: Rect.fromLTWH(0.5, 0.5, 0.03, 0.03))],
          t0.add(const Duration(minutes: 1)),
          userFocusActive: false,
        ),
        isNull, // tiny face → continuous AF
      );
      expect(FaceFocusPolicy.captureFocusPoint([small, big]), big.center);
      expect(FaceFocusPolicy.captureFocusPoint(const []), isNull);
    });

    test('analyzer scheduler: intervals + busy drop', () {
      final s = AnalyzerScheduler();
      final all = LiveAnalyzer.values.toSet();
      expect(s.due(all, t0), all);
      expect(s.due(all, t0.add(const Duration(milliseconds: 100))), isEmpty);
      expect(s.due(all, t0.add(const Duration(milliseconds: 210))), {
        LiveAnalyzer.faces,
      });
      expect(
        s.due(all, t0.add(const Duration(milliseconds: 470))),
        containsAll([LiveAnalyzer.frameStats, LiveAnalyzer.barcodes]),
      );
      s.busy = true;
      expect(s.due(all, t0.add(const Duration(seconds: 5))), isEmpty);
    });

    test('level: roll, flat, tolerance, smoothing', () {
      expect(rollDegrees(0, 9.8), closeTo(0, 1e-9));
      expect(rollDegrees(9.8, 0), closeTo(90, 1e-9));
      expect(rollDegrees(0.17, 9.8), closeTo(1, 0.05));
      expect(isLevel(0.8), isTrue);
      expect(isLevel(1.5), isFalse);
      expect(isFlat(0.2, 0.3, 9.8), isTrue);
      expect(isFlat(0.2, 9.8, 0.3), isFalse);
      expect(smoothAngle(0, 10), closeTo(2, 1e-9));
    });
  });

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------
  group('basic editor ops (free)', () {
    img.Image grad(int w, int h) {
      final im = img.Image(width: w, height: h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          im.setPixelRgb(x, y, x * 255 ~/ (w - 1), y * 255 ~/ (h - 1), 100);
        }
      }
      return im;
    }

    test('identity → same pixels', () {
      const p = EditParams();
      expect(p.isIdentity, isTrue);
      final src = grad(40, 30);
      final out = applyEdits(src, p);
      expect(out.width, 40);
      expect(out.getPixel(10, 10).r, src.getPixel(10, 10).r);
    });

    test('rotate 90° swaps dimensions; crop keeps the right region', () {
      final src = grad(40, 30);
      final r = applyEdits(src, const EditParams(quarterTurns: 1));
      expect([r.width, r.height], [30, 40]);
      final c = applyEdits(
        src,
        const EditParams(crop: Rect.fromLTWH(0.5, 0, 0.5, 1)),
      );
      expect([c.width, c.height], [20, 30]);
      expect(c.getPixel(0, 0).r, greaterThan(120)); // right half → red-ish
    });

    test('rotatedClockwise maps the crop with the image', () {
      const p = EditParams(crop: Rect.fromLTWH(0.1, 0.2, 0.3, 0.4));
      final r = p.rotatedClockwise();
      expect(r.quarterTurns, 1);
      expect(r.crop.left, closeTo(1 - 0.2 - 0.4, 1e-9));
      expect(r.crop.top, closeTo(0.1, 1e-9));
      expect(r.crop.width, closeTo(0.4, 1e-9));
      expect(r.crop.height, closeTo(0.3, 1e-9));
    });

    test('clampCrop keeps the box inside the image', () {
      final c = clampCrop(const Rect.fromLTWH(0.8, -0.2, 0.5, 0.5));
      expect(c.left >= 0 && c.top >= 0, isTrue);
      expect(c.right <= 1.0001 && c.bottom <= 1.0001, isTrue);
    });

    test('brightness / saturation matrix', () {
      final bright = adjustMatrix(const EditParams(brightness: 0.5));
      expect(bright[4], closeTo(30, 1e-9));
      final grey = adjustMatrix(const EditParams(saturation: -1));
      expect(grey[0], closeTo(grey[5], 1e-9)); // R and G rows equal
      final out = applyEdits(grad(20, 20), const EditParams(saturation: -1));
      final px = out.getPixel(15, 3);
      expect((px.r - px.g).abs(), lessThan(2));
    });

    test('sharpness increases edge contrast', () {
      final soft = img.gaussianBlur(stripes(80, 40), radius: 1);
      final sharp = applyEdits(soft, const EditParams(sharpness: 1));
      expect(edgeEnergy(sharp, 0, 80), greaterThan(edgeEnergy(soft, 0, 80)));
    });

    test('centeredCrop for aspect presets', () {
      final sq = centeredCrop(4 / 3, 1);
      expect(sq.width, closeTo(0.75, 1e-9));
      expect(sq.height, closeTo(1, 1e-9));
      expect(centeredCrop(4 / 3, null), const Rect.fromLTWH(0, 0, 1, 1));
    });
  });

  // ---------------------------------------------------------------------------
  group('live preview of AI looks (no credits until the shutter)', () {
    test('grade keywords', () {
      expect(gradeKeyFor('Black and white'), 'mono');
      expect(gradeKeyFor('B&W noir'), 'mono');
      expect(gradeKeyFor('rainy moody'), 'moody');
      expect(gradeKeyFor('Diwali golden'), 'warm');
      expect(gradeKeyFor('a cat'), isNull);
    });

    test('AI filters → colour grade only (v11: no live blur)', () {
      for (final f in kStylePresets) {
        final l = liveLookForFilter(f);
        expect(l.matrix, isNotNull, reason: f.id);
        expect(l.caption, kLiveCaption);
      }
    });

    test('big changes → sample thumbnail; portrait → grade only', () {
      const paris = AiStyle(
        id: 'paris_eiffel',
        name: 'Paris Eiffel',
        category: 'Travel',
        creditCost: 2,
        imageAsset: 'assets/styles/samples/paris_eiffel.jpg',
      );
      final p = liveLookForStyle(paris);
      expect(p.hasThumb, isTrue);
      expect(p.sampleAsset, paris.imageAsset);
      const head = AiStyle(
        id: 'studio_headshot',
        name: 'Studio headshot',
        category: 'Portrait',
        creditCost: 2,
      );
      final h = liveLookForStyle(head);
      expect(h.hasThumb, isFalse);
      expect(liveLookForCustom('make it black and white').matrix, isNotNull);
      expect(liveLookForCustom('add a hat').matrix, isNull);
    });

    test('composeMatrices: identity is neutral', () {
      const id = [
        1.0, 0.0, 0.0, 0.0, 0.0, //
        0.0, 1.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 1.0, 0.0,
      ];
      final g = kLiveGrades['cinematic']!;
      expect(composeMatrices(id, g), g);
      expect(composeMatrices(g, id), g);
    });
  });

  // ---------------------------------------------------------------------------
  group('credit-free paths never touch the ledger', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest();
    });

    test('HDR + edits leave credits unchanged', () async {
      final before = (await AccountService.instance.refresh()).toJson();
      final frames = [
        for (final k in [1.0, 0.5, 2.0])
          img.Image(width: 64, height: 48)..clear(
            img.ColorRgb8(
              (100 * k).clamp(0, 255).round(),
              (90 * k).clamp(0, 255).round(),
              (80 * k).clamp(0, 255).round(),
            ),
          ),
      ];
      mergeHdr(frames, proxyWidth: 32, refineWidth: 64);
      applyEdits(stripes(40, 30), const EditParams(brightness: 0.3));
      expect((await AccountService.instance.refresh()).toJson(), before);
    });

    testWidgets('document scan sheet: share PDF + save pages (no AI)', (
      t,
    ) async {
      final shared = <String>[];
      final saved = <String>[];
      DocumentSheetDeps.sharePdf = (p) async => shared.add(p);
      DocumentSheetDeps.savePage = (f) async {
        saved.add(f.path);
        return f.path;
      };
      addTearDown(DocumentSheetDeps.reset);
      DocumentScan.scanner = () async => const ScannedDocument(
        pages: ['/tmp/p1.jpg', 'file:///tmp/p2.jpg'],
        pdfPath: '/docs/Scans/Scan_2026-10-08_09-00-00.pdf',
        pageCount: 2,
      );
      addTearDown(DocumentScan.reset);
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final d = await DocumentScan.scan();
                if (context.mounted) await showDocumentResultSheet(context, d!);
              },
              child: const Text('scan'),
            ),
          ),
        ),
      );
      await t.tap(find.text('scan'));
      await t.pumpAndSettle();
      expect(find.text('Scanned 2 pages'), findsOneWidget);
      expect(
        find.textContaining('Scan_2026-10-08_09-00-00.pdf'),
        findsOneWidget,
      );
      await t.tap(find.byKey(const ValueKey('doc_share_pdf')));
      await t.pump();
      expect(shared, ['/docs/Scans/Scan_2026-10-08_09-00-00.pdf']);
      await t.tap(find.byKey(const ValueKey('doc_save_pages')));
      await t.pumpAndSettle();
      expect(saved, ['/tmp/p1.jpg', '/tmp/p2.jpg']);
      expect(find.text('Saved 2 pages to Gallery'), findsOneWidget);
    });

    test('scan file name', () {
      expect(
        scanFileName(DateTime(2026, 10, 8, 9, 5, 7)),
        'Scan_2026-10-08_09-05-07.pdf',
      );
    });
  });

  // ---------------------------------------------------------------------------
  group('widgets', () {
    testWidgets('More sheet: camera toggles', (t) async {
      CameraFeatures? feats;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMoreModesSheet(
                context,
                features: const CameraFeatures(),
                onFeatures: (f) => feats = f,
              ),
              child: const Text('more'),
            ),
          ),
        ),
      );
      await t.tap(find.text('more'));
      await t.pumpAndSettle();
      for (final k in [
        'feat_qr',
        'feat_smile',
        'feat_face_focus',
        'feat_tips',
        'feat_grid',
        'feat_level',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      await t.tap(find.byKey(const ValueKey('feat_level')));
      await t.pump();
      expect(feats?.level, isTrue);
    });

    testWidgets('scan chip + scene tip chip callbacks', (t) async {
      var tapped = 0, closed = 0, tip = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ScanChip(
                  action: classifyScan('https://example.com')!,
                  onTap: () => tapped++,
                  onDismiss: () => closed++,
                ),
                SuggestionChip(
                  text: 'Food? Try Portrait for a soft background',
                  onTap: () => tip++,
                  onDismiss: () {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.textContaining('Open link'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('scan_chip')));
      await t.tap(find.byKey(const ValueKey('scan_chip_close')));
      await t.tap(find.byKey(const ValueKey('scene_tip')));
      expect([tapped, closed, tip], [1, 1, 1]);
    });

    testWidgets('editor: rotate + adjust → save returns the edited file', (
      t,
    ) async {
      final dir = Directory.systemTemp.createTempSync('edit');
      addTearDown(() => dir.deleteSync(recursive: true));
      final src = File('${dir.path}/in.jpg')
        ..writeAsBytesSync(img.encodeJpg(stripes(80, 60)));
      EditParams? got;
      File? result;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<File>(
                  MaterialPageRoute(
                    builder: (_) => EditorScreen(
                      file: src,
                      saver: (f, p) async {
                        got = p;
                        return File('${dir.path}/out.jpg')
                          ..writeAsBytesSync(f.readAsBytesSync());
                      },
                    ),
                  ),
                );
              },
              child: const Text('edit'),
            ),
          ),
        ),
      );
      await t.tap(find.text('edit'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('edit_rotate')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('crop_1:1')));
      await t.pump();
      await t.tap(find.text('Adjust'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('adj_brightness')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('edit_save')));
      await t.pumpAndSettle();
      expect(got?.quarterTurns, 1);
      expect(got!.crop.width, lessThan(1));
      expect(result?.path, endsWith('out.jpg'));
    });
  });
}
