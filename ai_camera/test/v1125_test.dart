import 'dart:io';

import 'package:ai_camera/services/macro.dart';
import 'package:ai_camera/widgets/drift_popup.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ---- 1. popup + 5 s window ---------------------------------------------
  testWidgets('drift popup renders message, countdown, New subject', (t) async {
    var tapped = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: DriftPopup(
                  subject: 'Red mug',
                  secondsLeft: 5,
                  onNewSubject: () => tapped++,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('macro_drift_popup')), findsOneWidget);
    expect(find.text('Moved off subject — return to Red mug'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    await t.tap(find.text('New subject'));
    expect(tapped, 1);
  });

  test('5 s window with a 5-4-3-2-1 countdown', () {
    expect(kDriftReturnTimeout, const Duration(seconds: 5));
    final t0 = DateTime(2026);
    final ref = List<int>.generate(64, (i) => (i * 37) % 256);
    final d = DriftReturn()..start(ref, t0);
    final secs = [
      for (var ms = 0; ms < 5000; ms += 1000)
        d.secondsLeft(t0.add(Duration(milliseconds: ms + 1))),
    ];
    expect(secs, [5, 4, 3, 2, 1]);
    expect(
      d.update(null, t0.add(const Duration(milliseconds: 4900))),
      DriftState.waiting,
    );
    expect(d.update(null, t0.add(kDriftReturnTimeout)), DriftState.expired);
    expect(d.secondsLeft(t0.add(kDriftReturnTimeout)), 0);
    // back within 5 s → returned (card + timer gone, lock kept)
    d.start(ref, t0);
    expect(
      d.update(ref, t0.add(const Duration(seconds: 4))),
      DriftState.waiting,
    );
    expect(
      d.update(ref, t0.add(const Duration(milliseconds: 4500))),
      DriftState.returned,
    );
    expect(d.waiting, isFalse);
  });

  test(
    'home: popup overlay, New subject resets, toast after expiry',
    () {
      final s = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(s, contains('if (_macroActive && _driftReturn.waiting)'));
      expect(s, contains('DriftPopup('));
      expect(s, contains('_snack(kGuideDriftReset)'));
      expect(kGuideDriftReset, 'New subject? Tap 1.5x');
    },
    skip: 'v11.33: replaced by level chips + box check',
  );

  // ---- 3. keep the lock on 1x / 1.5x ---------------------------------------
  test('locked + matching view on 1.5x / 1x tap → keep lock, no AI call', () {
    for (final chip in [1.0, 1.5]) {
      expect(
        chipReturnAction(locked: true, chip: chip, score: 0.1),
        ChipReturnAction.keepLock,
      );
      expect(
        chipReturnAction(locked: true, chip: chip, score: null),
        ChipReturnAction.keepLock,
      );
    }
    // clearly different view
    expect(
      chipReturnAction(locked: true, chip: 1.5, score: 0.9),
      ChipReturnAction.redetect,
    );
    expect(
      chipReturnAction(locked: true, chip: 1.0, score: 0.9),
      ChipReturnAction.keepLock, // v11.26: 1x while locked is a no-op
    );
    // not locked / failed (Try again) / drift timer expired → old flow
    expect(
      chipReturnAction(locked: false, chip: 1.5, score: 0.0),
      ChipReturnAction.normal,
    );
    expect(
      chipReturnAction(locked: true, chip: 1.0, score: 0.0, drift: true),
      ChipReturnAction.normal,
    );
    // other chips unchanged
    expect(
      chipReturnAction(locked: true, chip: 3, score: 0.9),
      ChipReturnAction.normal,
    );
  });

  test(
    'home: 1x/1.5x with a lock skip reset, photo and detection',
    () {
      final s = File('lib/screens/home_camera_screen.dart').readAsStringSync();
      expect(
        s,
        contains(
          'final keepLock = !drift && _lockedSubject && isLockReturnChip(chip);',
        ),
      );
      expect(s, contains('if (!keepLock) _resetMacroFlow();'));
      expect(s, contains('unawaited(_checkLockOnReturn(chip, pz.camera));'));
      final a = s.indexOf('Future<void> _checkLockOnReturn(');
      final body = s.substring(a, s.indexOf('void _retryDetect()', a));
      expect(body, contains('case ChipReturnAction.keepLock:'));
      expect(body, isNot(contains('detectSubject')));
      expect(body, contains('driftMetric('));
    },
    skip: 'v11.33: replaced by level chips + box check',
  );

  // ---- 2. English only ----------------------------------------------------
  test('no Hindi / Hinglish user-facing text anywhere in lib/', () {
    final words = RegExp(
      r"\b(karo|karein|dabao|raho|nahi|paaye|aao|gaye|gaya|cheez|zyada|"
      r"zaroorat|jitna|chahiye|utna|hilo|jaane|wapas|dobara|phir|rakho|leni|"
      r"jis|nayi|aur|hai|hain|pehchaan|badal|kijiye|thoda|abhi|dekho)\b",
      caseSensitive: false,
    );
    final lit = RegExp(r"'(?:[^'\\\n]|\\.)*'");
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trim();
        if (l.startsWith('//')) continue;
        for (final m in lit.allMatches(l)) {
          if (words.hasMatch(m.group(0)!)) hits.add('${f.path}:${i + 1}');
        }
      }
      expect(
        File(f.path).readAsStringSync().contains(RegExp('[\u0900-\u097F]')),
        isFalse,
        reason: f.path,
      );
    }
    expect(hits, isEmpty);
    expect(kGuideStart, 'Point at what you want to shoot, then tap 1.5x');
    expect(guideFound('Red mug'), 'Found Red mug ✓ now tap 2x');
    expect(guideDriftBack(null), 'Moved off subject — return to the subject');
  });
}
