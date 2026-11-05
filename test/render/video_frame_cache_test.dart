import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/render/video_frame_cache.dart';

/// The decoded-frame cache under fast scrubbing and memory pressure (perf
/// fixes §2.1 and §3): stale decode requests are dropped, the nearest
/// frame is held meanwhile, only the settled frame is decoded, and all
/// videos together stay within one memory budget, frames of videos no
/// layer uses going first.
void main() {
  /// 4x4 RGBA = 64 bytes per frame.
  Future<ui.Image> solid(int index) {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 4, 4), ui.Paint()..color = ui.Color(0xFF000000 | index));
    return rec.endRecording().toImage(4, 4);
  }

  String assetOfPath(String path) => path.split('/').reversed.elementAt(1);
  int indexOfPath(String path) => int.parse(path.split('/').last.split('.').first) - 1;

  Content video(String id, {int count = 200}) => Content(
        shape: 'video',
        offset: [0, 0],
        size: [4, 4],
        videoAssetId: id,
        videoPath: '/src/$id.mp4',
        videoFps: 30,
        videoFrameCount: count,
      );

  group('scrubbing', () {
    late List<int> decoded;
    late Map<int, Completer<void>> gates;
    late VideoFrameCache cache;

    setUp(() {
      decoded = [];
      gates = {};
      cache = VideoFrameCache(prefetch: 6, maxConcurrent: 2, settle: const Duration(milliseconds: 30), decoder: (p) async {
        final i = indexOfPath(p);
        decoded.add(i);
        await gates[i]?.future;
        return solid(i);
      })
        ..framesRoot = '/frames';
    });
    tearDown(() => cache.dispose());

    test('fast scrub: stale requests dropped, nearest frame held, only the settled frame decoded', () async {
      final c = video('a');
      // playback at frame 0: 0 and 1 start decoding, 2..6 wait in the queue.
      gates[0] = Completer();
      gates[1] = Completer();
      cache.frameFor(c, 0);
      await pumpEventQueue();
      expect(decoded, [0, 1]);

      // the finger flies over the timeline.
      for (final f in [40, 75, 110, 150]) {
        cache.frameFor(c, f);
      }
      expect(cache.staleDropped, 5, reason: 'the prefetch of 2..6 is stale once the playhead jumped away');

      gates[0]!.complete();
      gates[1]!.complete();
      await pumpEventQueue();
      expect(decoded, [0, 1], reason: 'nothing the finger passed over is decoded while it moves');
      final held = cache.frameFor(c, 150)!;
      expect(held.key, 'video:a:1', reason: 'the nearest decoded frame is shown meanwhile');
      expect(cache.holds, greaterThan(0));

      // the finger rests: the exact frame is decoded, and only it.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue();
      expect(decoded, [0, 1, 150]);
      expect(cache.frameFor(c, 150)!.key, 'video:a:150');
      expect(cache.decodeCount, 3);
      expect(cache.avgDecodeMs, greaterThanOrEqualTo(0));
    });

    test('a frame that is no longer the latest when the playhead rests is not decoded', () async {
      final c = video('a');
      cache.frameFor(c, 0);
      await pumpEventQueue();
      decoded.clear();
      cache.frameFor(c, 100);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cache.frameFor(c, 30); // moved on before 100 settled
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue();
      expect(decoded, [30]);
    });

    test('playing forward keeps prefetching the frames ahead, dropping the ones behind', () async {
      final c = video('a');
      cache.frameFor(c, 0);
      await pumpEventQueue();
      for (var f = 1; f <= 12; f++) {
        cache.frameFor(c, f);
        await pumpEventQueue();
      }
      for (var f = 0; f <= 12; f++) {
        expect(cache.isDecoded(c, f), isTrue, reason: 'frame $f');
      }
      expect(cache.isDecoded(c, 18), isTrue, reason: 'prefetched ahead of the playhead');
    });
  });

  group('memory budget', () {
    late List<String> decoded;
    late VideoFrameCache cache;
    const frameBytes = 64;

    setUp(() {
      decoded = [];
      cache = VideoFrameCache(budgetBytes: frameBytes * 5, prefetch: 0, decoder: (p) {
        decoded.add('${assetOfPath(p)}:${indexOfPath(p)}');
        return solid(indexOfPath(p));
      })
        ..framesRoot = '/frames';
    });
    tearDown(() => cache.dispose());

    test('all videos together stay within the budget; videos no layer uses are evicted first', () async {
      final a = video('a'), b = video('b');
      cache.liveAssets = {'a', 'b'};
      for (var i = 0; i < 3; i++) {
        await cache.load(b, i);
      }
      for (var i = 0; i < 2; i++) {
        await cache.load(a, i);
      }
      expect(cache.bytes, frameBytes * 5);

      // the layer of video b is deleted (kept only by undo).
      cache.liveAssets = {'a'};
      for (var i = 2; i < 8; i++) {
        await cache.load(a, i);
        expect(cache.bytes, lessThanOrEqualTo(cache.budgetBytes));
      }
      for (var i = 0; i < 3; i++) {
        expect(cache.isDecoded(b, i), isFalse, reason: 'b went first although it was used more recently than a:0');
      }
      expect(cache.isDecoded(a, 7), isTrue);
      expect(cache.imageStats().bytes, cache.bytes);

      // undo brings the layer back: its frames refill from disk, with the
      // nearest decoded frame... none of b is left, so nothing until then.
      cache.liveAssets = {'a', 'b'};
      decoded.clear();
      expect(cache.frameFor(b, 1), isNull);
      await pumpEventQueue();
      expect(decoded, ['b:1']);
      expect(cache.frameFor(b, 1)!.key, 'video:b:1');
      expect(cache.bytes, lessThanOrEqualTo(cache.budgetBytes));
    });

    test('releaseUnused frees the frames of videos no layer uses', () async {
      final a = video('a'), b = video('b');
      cache.liveAssets = {'a'};
      await cache.load(a, 0);
      await cache.load(b, 0);
      cache.releaseUnused();
      expect(cache.isDecoded(a, 0), isTrue);
      expect(cache.isDecoded(b, 0), isFalse);
      expect(cache.bytes, frameBytes);
    });

    test('the renderer tells the cache which videos the project uses', () {
      final renderer = CanvasRenderer()..setSize(8, 8);
      Layer layer(String id, String asset) => Layer(
            id: id,
            name: id,
            durationFrames: 10,
            transform: Transform(
                anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
            content: video(asset),
          );
      final project = Project(layers: [layer('L1', 'a'), layer('L2', 'b')]);
      renderer.renderFrame(project, 0);
      expect(renderer.videoFrames.liveAssets, {'a', 'b'});
      project.layers.removeAt(1);
      renderer.renderFrame(project, 0);
      expect(renderer.videoFrames.liveAssets, {'a'});
    });
  });
}
