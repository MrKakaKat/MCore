import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/video_asset_store.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';
import 'package:movement_mobile/render/video_frame_cache.dart';
import 'package:movement_mobile/services/video_service.dart';

/// Video layers: the decoded-frame window (LRU bound, prefetch, holding
/// the nearest frame), export waiting for exact frames, the on-disk store
/// and its cleanup, and the import flow - all with a fake decoder / fake
/// ffmpeg (real extraction needs the native library, i.e. a device).
void main() {
  setUp(() => fps = 60);

  /// A solid 4x4 frame whose red channel encodes the frame number.
  Future<ui.Image> solid(int index) {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 4, 4),
        ui.Paint()..color = ui.Color.fromARGB(255, (index * 10) % 256, 0, 200));
    return rec.endRecording().toImage(4, 4);
  }

  int indexOfPath(String path) => int.parse(path.split('/').last.split('.').first) - 1;

  Content videoContent({int count = 100, double srcFps = 30, String id = 'a'}) => Content(
        shape: 'video',
        offset: [0, 0],
        size: [40, 40],
        videoAssetId: id,
        videoPath: '/src/$id.mp4',
        videoFps: srcFps,
        videoFrameCount: count,
      );

  group('frame window', () {
    late List<int> decoded;
    late VideoFrameCache cache;

    setUp(() {
      decoded = [];
      cache = VideoFrameCache(capacity: 8, prefetch: 3, decoder: (path) {
        final i = indexOfPath(path);
        decoded.add(i);
        return solid(i);
      })
        ..framesRoot = '/frames';
    });

    test('frames come from <root>/<asset>/000001.jpg, png with transparency', () {
      final c = videoContent();
      expect(cache.pathOf(c, 0), '/frames/a/000001.jpg');
      c.videoAlpha = true;
      expect(cache.pathOf(c, 41), '/frames/a/000042.png');
    });

    test('the window stays bounded however long the clip is', () async {
      final c = videoContent();
      for (var i = 0; i < 60; i++) {
        await cache.load(c, i);
        expect(cache.length, lessThanOrEqualTo(8));
      }
      expect(cache.isDecoded(c, 59), isTrue);
      expect(cache.isDecoded(c, 0), isFalse, reason: 'old frames left the window');
    });

    test('asking for a frame also decodes the next ones', () async {
      final c = videoContent();
      cache.frameFor(c, 10);
      await pumpEventQueue();
      expect(decoded.toSet(), {10, 11, 12, 13});
    });

    test('while the exact frame loads, the nearest decoded one is shown - never nothing', () async {
      final c = videoContent();
      await cache.load(c, 10);
      await cache.load(c, 30);
      final shown = cache.frameFor(c, 14)!;
      expect(shown.key, 'video:a:10', reason: '10 is nearer to 14 than 30');
      await pumpEventQueue();
      expect(cache.frameFor(c, 14)!.key, 'video:a:14', reason: 'exact once decoded');
    });

    test('an unreadable frame is not retried on every draw', () async {
      var calls = 0;
      cache.decoder = (_) {
        calls++;
        throw const FileSystemException('gone');
      };
      final c = videoContent(count: 1);
      expect(await cache.load(c, 0), isNull);
      cache.frameFor(c, 0);
      await pumpEventQueue();
      expect(calls, 1);
    });
  });

  group('renderer', () {
    late CanvasRenderer renderer;
    late Project project;
    late Layer layer;
    late Map<int, Completer<void>> gates;

    setUp(() {
      gates = {};
      renderer = CanvasRenderer()..setSize(40, 40);
      renderer.videoFrames
        ..framesRoot = '/frames'
        ..decoder = (path) async {
          final i = indexOfPath(path);
          await gates[i]?.future;
          return solid(i);
        };
      layer = Layer(
        id: 'L_v',
        name: 'v',
        durationFrames: 200,
        transform: Transform(
            anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
        content: videoContent(),
      );
      project = Project(layers: [layer]);
    });

    Future<int> redAtCentre() async {
      final img = await renderer.captureFrame();
      final px = (await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
      const o = (20 * 40 + 20) * 4;
      expect(px.getUint8(o + 3), 255, reason: 'something is drawn');
      return px.getUint8(o);
    }

    test('source frame follows project time: 60 fps project, 30 fps clip, sourceIn', () {
      expect(renderer.videoFrameIndex(layer, 20), 10);
      layer.content.sourceIn = 1.0; // skip the first second
      expect(renderer.videoFrameIndex(layer, 20), 40);
      expect(renderer.videoFrameIndex(layer, 190), 99, reason: 'past the end holds the last frame');
    });

    test('the editor draws the nearest decoded frame while the exact one loads', () async {
      await renderer.videoFrames.load(layer.content, 0);
      gates[10] = Completer();
      renderer.renderFrame(project, 20);
      expect(await redAtCentre(), 0, reason: 'frame 0 held, not blank');
      gates[10]!.complete();
    });

    test('export waits for the exact frame, motion-blur samples included', () async {
      await renderer.videoFrames.load(layer.content, 0);
      gates[10] = Completer();
      final prepared = renderer.prepareFrame(project, 20);
      var done = false;
      unawaited(prepared.then((_) => done = true));
      await pumpEventQueue();
      expect(done, isFalse, reason: 'frame 10 is not decoded yet');
      gates[10]!.complete();
      await prepared;
      renderer.renderFrame(project, 20);
      expect(await redAtCentre(), 100, reason: 'exactly frame 10');

      layer.motionBlur
        ..enabled = true
        ..samples = 5
        ..shutterAngle = 720; // samples at 19..21 -> frames 9..10
      await renderer.prepareFrame(project, 20);
      expect(renderer.videoFrames.isDecoded(layer.content, 9), isTrue);
    });
  });

  group('store', () {
    late Directory tmp;
    late VideoAssetStore store;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('video_store');
      store = VideoAssetStore(documents: Directory('${tmp.path}/docs'), cache: Directory('${tmp.path}/cache'));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void fakeAsset(String id, int frames) {
      store.sourcesDir.createSync(recursive: true);
      File('${store.sourcesDir.path}/$id.mp4').writeAsStringSync('x');
      store.framesDir(id).createSync(recursive: true);
      for (var i = 0; i < frames; i++) {
        File('${store.framesDir(id).path}/${videoFrameFileName(i, alpha: false)}').writeAsStringSync('x');
      }
    }

    test('the source is copied into app storage', () async {
      final picked = File('${tmp.path}/clip.MOV')..writeAsStringSync('data');
      final copy = await store.copySource(picked, 'v1');
      expect(copy.path, '${store.sourcesDir.path}/v1.MOV');
      expect(copy.readAsStringSync(), 'data');
    });

    test('cleanup removes videos no saved project uses', () async {
      fakeAsset('keep', 3);
      fakeAsset('drop', 3);
      final project = File('${tmp.path}/p.json')
        ..writeAsStringSync('{"layers":[{"content":{"shape":"video","videoAssetId":"keep"}}]}');
      expect(store.hasFrames('keep', 3, alpha: false), isTrue);
      final removed = await store.cleanup([project]);
      expect(removed, {'drop'});
      expect(store.hasFrames('keep', 3, alpha: false), isTrue);
      expect(store.framesDir('drop').existsSync(), isFalse);
      expect(File('${store.sourcesDir.path}/drop.mp4').existsSync(), isFalse);
    });
  });

  group('AppState import', () {
    late Directory tmp;
    late AppState app;
    late _FakeVideoService service;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('video_import');
      service = _FakeVideoService();
      app = AppState()
        ..videoService = service
        ..videoStore = VideoAssetStore(documents: Directory('${tmp.path}/docs'), cache: Directory('${tmp.path}/cache'));
      app.renderer.videoFrames.decoder = (path) => solid(indexOfPath(path));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('adds a layer as long as the clip, saved with its asset; one undo step', () async {
      final before = app.project.layers.length;
      final progress = <int>[];
      await app.importVideo(File('${tmp.path}/in.mp4')..writeAsStringSync('v'),
          onProgress: (done, _) => progress.add(done));
      final l = app.project.layers.last;
      expect(app.project.layers.length, before + 1);
      expect(l.content.shape, 'video');
      expect(l.durationFrames, 120, reason: '60 frames at 30 fps = 2 s = 120 frames at 60 fps');
      expect(l.content.videoFrameCount, 60);
      expect(File(l.content.videoPath!).existsSync(), isTrue, reason: 'the source copy is kept');
      expect(service.lastMax, [app.frameWidth, app.frameHeight], reason: 'frames fit the project size');
      expect(progress, isNotEmpty);
      expect(projectLayersToJson(app.project).toString(), contains(l.content.videoAssetId!));
      app.performUndo();
      expect(app.project.layers.length, before);
    });

    test('cancelling leaves nothing behind', () async {
      final token = CancelToken();
      service.onExtract = token.cancel;
      final before = app.project.layers.length;
      await expectLater(
          app.importVideo(File('${tmp.path}/in.mp4')..writeAsStringSync('v'), cancel: token),
          throwsA(isA<VideoImportCancelled>()));
      expect(app.project.layers.length, before);
      expect(app.videoStore!.sourcesDir.listSync(), isEmpty);
    });

    test('frames deleted from the cache are extracted again from the kept source', () async {
      await app.importVideo(File('${tmp.path}/in.mp4')..writeAsStringSync('v'));
      final l = app.project.layers.last;
      expect(app.failedImageLayerIds, isNot(contains(l.id)));
      app.videoStore!.framesDir(l.content.videoAssetId!).deleteSync(recursive: true);
      expect(app.failedImageLayerIds, isNot(contains(l.id)),
          reason: 'not checked on every draw - only when asked (resume / restore)');
      app.recheckVideoFrames();
      expect(app.failedImageLayerIds, contains(l.id), reason: 'shown as broken until rebuilt');
      await app.restoreVideoFrames();
      expect(service.calls, 2);
      expect(app.videoStore!.hasFrames(l.content.videoAssetId!, 60, alpha: false), isTrue);
      expect(app.failedImageLayerIds, isNot(contains(l.id)));
    });
  });
}

class _FakeVideoService extends VideoService {
  @override
  Future<File> encodeFrameSequence(Directory dir, {required double fps, required bool alpha, required String outputPath}) =>
      throw UnimplementedError();

  int calls = 0;
  List<double>? lastMax;
  void Function()? onExtract;

  @override
  bool get supportsAlphaChannel => true;

  @override
  Future<ExtractedVideo> extractToCache(File source, Directory outDir,
      {required double maxWidth,
      required double maxHeight,
      bool alpha = false,
      void Function(int done, int total)? onProgress,
      CancelToken? cancel}) async {
    calls++;
    lastMax = [maxWidth, maxHeight];
    onExtract?.call();
    if (cancel?.isCancelled ?? false) throw VideoImportCancelled();
    await outDir.create(recursive: true);
    for (var i = 0; i < 60; i++) {
      File('${outDir.path}/${videoFrameFileName(i, alpha: alpha)}').writeAsStringSync('f');
      onProgress?.call(i + 1, 60);
    }
    return ExtractedVideo(fps: 30, frameCount: 60, width: 64, height: 36, alpha: alpha);
  }

  @override
  Future<List<ui.Image>> extractFrames(File videoFile, {required double fps}) => throw UnimplementedError();

  @override
  Future<File> encodeFrames(List<ui.Image> frames,
          {required double fps,
          required String outputPath,
          bool alphaChannel = false,
          int? bitrateKbps,
          int? quality,
          VideoProgress? onProgress,
          String? audioPath}) =>
      throw UnimplementedError();
}
