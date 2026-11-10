import 'dart:convert';
import 'dart:io';

import 'package:ai_camera/models/ai_style.dart';
import 'package:ai_camera/models/products.dart';
import 'package:ai_camera/screens/video_screen.dart';
import 'package:ai_camera/services/account_service.dart';
import 'package:ai_camera/services/video_service.dart';
import 'package:ai_camera/services/video_style_catalog.dart';
import 'package:ai_camera/widgets/style_card_strip.dart';
import 'package:ai_camera/widgets/credit_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeBackend implements VideoBackend {
  FakeBackend({this.states = const ['queued', 'running', 'done'], this.fail});
  final List<String> states;
  final String? fail;
  int polls = 0;
  int cancels = 0;
  VideoRequest? submitted;

  @override
  bool get chargesLocally => true;
  @override
  Future<String> submit(VideoRequest r) async {
    submitted = r;
    return '${r.provider.name}~req123456';
  }

  @override
  Future<VideoStatus> status(String jobId) async {
    final s = states[polls < states.length ? polls : states.length - 1];
    polls++;
    if (s == 'failed') return VideoStatus('failed', error: fail ?? 'boom');
    return VideoStatus(s, url: s == 'done' ? 'https://x/v.mp4' : null);
  }

  @override
  Future<void> cancel(String jobId) async => cancels++;
}

Future<int> balance() async {
  final s = await AccountService.instance.refresh();
  return s.freeDaily + s.packCredits + s.subCredits;
}

File _tmp(String name) {
  final f = File('${Directory.systemTemp.path}/$name')..writeAsBytesSync([1, 2, 3]);
  return f;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('version bumped', () {
    expect(File('pubspec.yaml').readAsStringSync(), matches(RegExp(r'version: 1\.11\.5[3-9]\+')));
    expect(File('pubspec.yaml').readAsStringSync(), contains('video_player'));
  });

  test('provisional credit table (same as server)', () {
    final t = defaultVideoCredits();
    expect([t['wan_5_480p'], t['wan_5_580p'], t['wan_5_720p']], [3, 4, 7]);
    expect([t['minimax_8_480p'], t['minimax_10_480p'], t['minimax_15_480p']], [7, 9, 13]);
    expect([t['minimax_8_768p'], t['minimax_10_768p'], t['minimax_15_768p']], [11, 13, 20]);
  });

  test('routing + validation: 5 s Wan, longer MiniMax', () {
    expect(providerFor(5), VideoProvider.wan);
    expect(providerFor(8), VideoProvider.minimax);
    expect(resolutionsFor(5), ['480p', '580p', '720p']);
    expect(resolutionsFor(15), ['480p', '768p']);
    expect(const VideoRequest(kind: VideoKind.t2v, prompt: 'x', seconds: 10, resolution: '580p').validate(),
        isNotNull);
    expect(const VideoRequest(kind: VideoKind.i2v, prompt: 'x').validate(), 'Choose a photo');
    final ok = const VideoRequest(kind: VideoKind.t2v, prompt: 'waves', seconds: 10, resolution: '768p', aspect: '16:9');
    expect(ok.validate(), isNull);
    expect(ok.creditKey, 'minimax_10_768p');
    expect(ok.isMiniMax, isTrue);
  });

  group('VideoService', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest();
      await AccountService.instance.ledger.purchase(kProducts.firstWhere((p) => p.id == 'pack_25'));
    });

    VideoService svc(FakeBackend be, {List<String>? downloaded}) => VideoService(
      backend: (_) async => be,
      download: (u) async {
        downloaded?.add(u);
        return _tmp('v.mp4');
      },
      pollEvery: const Duration(milliseconds: 1),
    );

    Future<void> settle(VideoService s) async {
      for (var i = 0; i < 200 && s.job.value!.active; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }

    test('charged once, only after the video is delivered', () async {
      final be = FakeBackend();
      final dl = <String>[];
      final s = svc(be, downloaded: dl);
      final before = await balance();
      await s.start(const VideoRequest(kind: VideoKind.t2v, prompt: 'waves', seconds: 5, resolution: '580p'));
      expect(s.job.value!.credits, 4);
      await settle(s);
      expect(s.job.value!.phase, VideoPhase.done);
      expect(dl, ['https://x/v.mp4']);
      expect(s.job.value!.creditsCharged, 4);
      expect(await balance(), before - 4);
    });

    test('failure: no charge, error shown', () async {
      final s = svc(FakeBackend(states: ['running', 'failed'], fail: 'nsfw'));
      final before = await balance();
      await s.start(const VideoRequest(kind: VideoKind.t2v, prompt: 'x'));
      await settle(s);
      expect(s.job.value!.phase, VideoPhase.failed);
      expect(s.job.value!.error, 'nsfw');
      expect(await balance(), before);
    });

    test('cancel: provider cancel, no charge; leave-and-return keeps job', () async {
      final be = FakeBackend(states: ['running']);
      final s = svc(be);
      final before = await balance();
      await s.start(const VideoRequest(kind: VideoKind.t2v, prompt: 'x'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(s.job.value!.active, isTrue); // still polling with no screen
      expect((await SharedPreferences.getInstance()).getString('video_pending_v1'), isNotNull);
      await s.cancel();
      expect(s.job.value!.phase, VideoPhase.cancelled);
      expect(be.cancels, 1);
      expect(await balance(), before);
      expect((await SharedPreferences.getInstance()).getString('video_pending_v1'), isNull);
    });

    test('resume after restart polls the saved job', () async {
      final s1 = svc(FakeBackend(states: ['running']));
      await s1.start(const VideoRequest(kind: VideoKind.t2v, prompt: 'x', seconds: 8, resolution: '480p'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final be2 = FakeBackend();
      final s2 = svc(be2);
      await s2.resumePending();
      await settle(s2);
      expect(s2.job.value!.phase, VideoPhase.done);
      expect(be2.submitted, isNull); // never resubmitted
      expect(s2.job.value!.modelLabel, 'MiniMax H3');
    });

    test('precheck denies when credits are short', () async {
      SharedPreferences.setMockInitialValues({});
      AccountService.resetForTest();
      final s = svc(FakeBackend());
      expect(await s.precheck(const VideoRequest(kind: VideoKind.t2v, prompt: 'x', seconds: 15, resolution: '768p')),
          isNotNull);
    });
  });

  group('DirectVideoBackend wire format', () {
    test('Wan: path, body, status, cancel', () async {
      final calls = <http.Request>[];
      final be = DirectVideoBackend(
        client: MockClient((r) async {
          calls.add(r);
          if (r.url.path.endsWith('text-to-video')) return http.Response('{"requestId":"abcdef123"}', 200);
          if (r.url.path.startsWith('/status/')) {
            return http.Response('{"status":"COMPLETED","output":{"video_url":"https://cdn/x.mp4"}}', 200);
          }
          return http.Response('{}', 200);
        }),
      );
      final id = await be.submit(const VideoRequest(kind: VideoKind.t2v, prompt: 'waves', resolution: '720p', aspect: '16:9'));
      expect(id, 'wan~abcdef123');
      final body = jsonDecode(calls.first.body) as Map;
      expect(body, {'prompt': 'waves', 'resolution': '720p', 'aspect_ratio': '16:9', 'seconds': 5});
      expect(calls.first.url.path, '/wan-2.2/14b/text-to-video');
      final st = await be.status(id);
      expect(st.state, 'done');
      expect(st.url, 'https://cdn/x.mp4');
      await be.cancel(id);
      expect(calls.last.url.path, '/cancel/abcdef123');
    });

    test('Wan 402 balance error is readable', () async {
      final be = DirectVideoBackend(
        client: MockClient((r) async => http.Response('{"error":"insufficient balance"}', 402)),
      );
      await expectLater(
        be.submit(const VideoRequest(kind: VideoKind.t2v, prompt: 'x')),
        throwsA(predicate((e) => '$e'.contains('balance'))),
      );
    });

    test('MiniMax: upload, submit, completed → result url', () async {
      final paths = <String>[];
      Map? submit;
      final be = DirectVideoBackend(
        client: MockClient((r) async {
          paths.add(r.url.path);
          if (r.url.path.endsWith('/storage/image/upload')) return http.Response('{"s3_url":"https://s3/in.jpg"}', 200);
          if (r.url.path.endsWith('/inference/submit')) {
            submit = jsonDecode(r.body) as Map;
            return http.Response('{"request_id":"mm_req_1"}', 200);
          }
          if (r.url.path.contains('/inference/status/')) return http.Response('{"status":"completed"}', 200);
          if (r.url.path.contains('/inference/result/')) {
            return http.Response('{"data":{"video":{"url":"https://cdn/m.mp4"}}}', 200);
          }
          return http.Response('nope', 404);
        }),
      );
      final id = await be.submit(VideoRequest(
        kind: VideoKind.i2v, prompt: 'p', seconds: 10, resolution: '768p', image: _tmp('in.jpg')));
      expect(id, 'minimax~mm_req_1');
      expect(submit, {
        'prompt': 'p', 'resolution_tier': '768p', 'aspect_ratio': '9:16', 'duration': 10,
        'model': 'minimax/h3/image-to-video/turbo', 'image_url': 'https://s3/in.jpg',
      });
      final st = await be.status(id);
      expect(st.url, 'https://cdn/m.mp4');
      expect(paths, contains('/api/v1/inference/result/mm_req_1'));
    });
  });

  test('video catalog parses DB rows, keeps bundled previews', () {
    final c = VideoStyleCatalog(url: 'https://x', key: 'k', media: 'https://m');
    final l = c.parseRows([
      {'id': 'video_slow_zoom', 'name': 'Slow zoom', 'prompt': 'p', 'sort_order': 200, 'display_image': null},
      {'id': 'new_one', 'name': 'New', 'prompt': 'q', 'sort_order': 1, 'display_image': 'a.jpg'},
    ]);
    expect(l.map((s) => s.id), ['new_one', 'video_slow_zoom']);
    expect(l.first.imageUrl, 'https://m/a.jpg');
    expect(l.last.imageAsset, isNotNull);
  });

  test('style cards are bigger', () {
    const c = StyleCard(style: AiStyle(id: 'a', name: 'A', category: 'c', creditCost: 2), onTap: null);
    expect(c.width, greaterThanOrEqualTo(100));
    expect(c.height, greaterThanOrEqualTo(130));
  });

  testWidgets('video screen: custom options, MiniMax label, credits per choice', (t) async {
    SharedPreferences.setMockInitialValues({});
    AccountService.resetForTest();
    VideoService.resetForTest(VideoService(backend: (_) async => FakeBackend()));
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: VideoScreen()));
    await t.pump();
    expect(find.byKey(const ValueKey('video_style_video_slow_zoom')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('video_tab_custom')));
    await t.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => isCreditText(w, '580p · 🪙4')), findsOneWidget);
    expect(find.byKey(const ValueKey('minimax_label')), findsNothing);
    await t.tap(find.byKey(const ValueKey('video_len_10')));
    await t.pump();
    expect(find.byWidgetPredicate((w) => isCreditText(w, '768p · 🪙13')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => isCreditText(w, '580p · 🪙4')), findsNothing);
    expect(find.byKey(const ValueKey('minimax_label')), findsOneWidget);
    VideoService.resetForTest(VideoService());
  });

  testWidgets('result: player area, save to gallery, share, MiniMax label', (t) async {
    final saved = <String>[], shared = <String>[];
    VideoDeps.showPlayer = false;
    VideoDeps.saveVideo = (f) async => saved.add(f.path);
    VideoDeps.share = (f) async => shared.add(f.path);
    final s = VideoService(backend: (_) async => FakeBackend());
    final f = _tmp('done.mp4');
    s.job.value = VideoJob(
      request: const VideoRequest(kind: VideoKind.t2v, prompt: 'x', seconds: 8),
      phase: VideoPhase.done,
      started: DateTime.now(),
      credits: 7,
      file: f,
      creditsCharged: 7,
    );
    VideoService.resetForTest(s);
    await t.pumpWidget(const MaterialApp(home: VideoScreen()));
    await t.pump();
    expect(find.byKey(const ValueKey('minimax_label')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => isCreditText(w, '🪙7 used')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('video_save')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('video_share')));
    await t.pump();
    expect(saved, [f.path]);
    expect(shared, [f.path]);
    VideoService.resetForTest(VideoService());
  });
}
