import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/project_store.dart';
import 'package:movement_mobile/io/video_asset_store.dart' show directorySize;
import 'package:movement_mobile/services/audio_service.dart';
import 'package:movement_mobile/services/video_service.dart';
import 'package:movement_mobile/ui/settings/settings_view.dart';

/// Imported media on disk (perf fixes §3, §4): kept while anything can
/// bring its layer back (a layer, an undo step, a saved project), deleted
/// once nothing does; "Clear undo cache"; and "Trim unused media", which
/// must leave every frame and every sample the project plays unchanged.
void main() {
  late Directory root;
  late ProjectStore store;
  late AppState app;
  late _FakeEncoders encoders;

  /// A frame image whose colour encodes the source frame number (the
  /// fake frame files hold that number as text).
  Future<ui.Image> solid(int index) {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(const ui.Rect.fromLTWH(0, 0, 4, 4),
        ui.Paint()..color = ui.Color.fromARGB(255, index % 256, index ~/ 256, 120));
    return rec.endRecording().toImage(4, 4);
  }

  Future<void> setUpApp() async {
    fps = 60;
    root = await Directory.systemTemp.createTemp('media_storage_');
    store = ProjectStore(root);
    final file = await store.create('P', 16, 16);
    encoders = _FakeEncoders();
    app = AppState()
      ..videoStore = store.videos
      ..audioStore = store.audios
      ..projectStore = store
      ..videoService = encoders
      ..audioService = encoders;
    await app.openProject(file);
    app.project.layers.clear();
    app.renderer.videoFrames.decoder = (path) async => solid(int.parse(await File(path).readAsString()));
  }

  /// A video asset on disk: `count` frames at 30 fps, frame i's file
  /// holding "i", and a source copy.
  Future<Layer> addVideo(String id, {int count = 300}) async {
    final frames = store.videos.framesDir(id);
    await frames.create(recursive: true);
    for (var i = 0; i < count; i++) {
      await File('${frames.path}/${videoFrameFileName(i, alpha: false)}').writeAsString('$i');
    }
    await store.videos.sourcesDir.create(recursive: true);
    final source = File('${store.videos.sourcesDir.path}/$id.mp4')..writeAsBytesSync(List.filled(count * 100, 7));
    final layer = createVideoLayer(
        path: source.path, assetId: id, width: 4, height: 4, sourceFps: 30, frameCount: count, maxDimension: 16);
    app.project.layers.add(layer);
    return layer;
  }

  /// A sound on disk: `seconds` of a ramp, decoded PCM + waveform + copy.
  Future<Layer> addSound(String id, {double seconds = 10}) async {
    final n = (seconds * audioSampleRate).round();
    final pcm = Int16List(n * audioChannels);
    for (var i = 0; i < n; i++) {
      pcm[i * 2] = (i % 30011) - 15000;
      pcm[i * 2 + 1] = (i % 17) * 100;
    }
    await store.audios.pcmRoot.create(recursive: true);
    await store.audios.pcmFile(id).writeAsBytes(pcm.buffer.asUint8List());
    await store.audios.writePeaks(id, computePeaks(pcm));
    await store.audios.sourcesDir.create(recursive: true);
    final source = File('${store.audios.sourcesDir.path}/$id.mp3')..writeAsBytesSync(List.filled(n ~/ 10, 3));
    final layer = createAudioLayer(path: source.path, assetId: id, durationSeconds: seconds);
    app.project.layers.add(layer);
    return layer;
  }

  bool videoOnDisk(String id) => store.videos.framesDir(id).existsSync() || store.videos.sourceOf(id) != null;

  group('reference counting', () {
    setUp(setUpApp);
    tearDown(() async {
      app.dispose();
      await root.delete(recursive: true);
    });

    testWidgets('kept while an undo step can bring the layer back; deleted once the history is cleared',
        (tester) async {
      await tester.runAsync(() async {
        final layer = await addVideo('vAAA', count: 10);
        await app.cleanupUnusedMedia();
        expect(videoOnDisk('vAAA'), isTrue, reason: 'a live layer uses it');

        app.deleteLayerById(layer.id);
        await app.cleanupUnusedMedia();
        expect(videoOnDisk('vAAA'), isTrue, reason: 'undo can still restore the layer');

        final overview = await app.storageOverview();
        expect(overview.undoSteps, greaterThan(0));
        expect(overview.undoMediaBytes, greaterThan(0), reason: 'the overview shows what only undo keeps');

        await app.clearUndoCache();
        expect(videoOnDisk('vAAA'), isFalse, reason: 'nothing references it any more');
        expect((await app.storageOverview()).undoSteps, 0);
      });
    });

    testWidgets('never deleted while a saved project references it', (tester) async {
      await tester.runAsync(() async {
        final layer = await addVideo('vBBB', count: 10);
        File('${root.path}/projects/other.json').writeAsStringSync('{"videoAssetId": "vBBB"}');
        app.deleteLayerById(layer.id);
        await app.clearUndoCache();
        expect(videoOnDisk('vBBB'), isTrue, reason: 'the other project still uses it');
      });
    });

    testWidgets('undo after the history was not cleared restores a layer whose frames are still on disk',
        (tester) async {
      await tester.runAsync(() async {
        final layer = await addVideo('vCCC', count: 10);
        app.deleteLayerById(layer.id);
        await app.cleanupUnusedMedia();
        app.performUndo();
        expect(app.project.layers.single.content.videoAssetId, 'vCCC');
        expect(store.videos.hasFrames('vCCC', 10, alpha: false), isTrue);
      });
    });
  });

  group('trim unused media', () {
    setUp(setUpApp);
    tearDown(() async {
      app.dispose();
      await root.delete(recursive: true);
    });

    Future<List<Uint8List>> renderAll() async {
      final out = <Uint8List>[];
      for (var f = 0; f <= app.maxFrame; f += 2) {
        await app.renderer.prepareFrame(app.project, f);
        app.renderer.renderFrame(app.project, f);
        final img = await app.renderer.captureFrame();
        out.add((await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List());
      }
      return out;
    }

    testWidgets('every frame and every sample plays the same before and after; in-points remapped; undo cleared',
        (tester) async {
      await tester.runAsync(() async {
        // a 10 s clip of which two short stretches are used, plus a sound
        // used in the middle.
        final a = await addVideo('vLONG', count: 300);
        a.content.sourceIn = 3.4;
        a.durationFrames = 45;
        final b = await addVideo('vLONG', count: 300);
        b
          ..id = 'L_second'
          ..startFrame = 50
          ..durationFrames = 40;
        b.content.sourceIn = 8.2;
        final s = await addSound('aLONG', seconds: 10);
        s
          ..startFrame = 10
          ..durationFrames = 70;
        s.content.sourceIn = 5.25;
        app.setMaxFrame(95);
        app.pushUndo();
        app.commitEdit();

        final picturesBefore = await renderAll();
        final mixBefore = await (await app.buildAudioMix(into: File('${root.path}/before.wav')))!.readAsBytes();
        final sizeBefore = await directorySize(root);
        final sourceInsBefore = [a.content.sourceIn, b.content.sourceIn, s.content.sourceIn];

        final preview = await app.previewMediaTrim();
        expect(preview.videos.keys, ['vLONG']);
        expect(preview.audios.keys, ['aLONG']);
        expect(preview.freedBytes, greaterThan(0));

        final failed = await app.trimUnusedMedia(preview);
        expect(failed, isEmpty);

        final picturesAfter = await renderAll();
        final mixAfter = await (await app.buildAudioMix(into: File('${root.path}/after.wav')))!.readAsBytes();
        expect(picturesAfter.length, picturesBefore.length);
        for (var i = 0; i < picturesBefore.length; i++) {
          expect(picturesAfter[i], picturesBefore[i], reason: 'frame ${i * 2} looks the same');
        }
        expect(picturesBefore.first.any((v) => v != 0), isTrue, reason: 'the frames do show the video');
        expect(mixAfter, mixBefore, reason: 'the sound is the same, sample for sample');

        expect([a.content.sourceIn, b.content.sourceIn, s.content.sourceIn], isNot(sourceInsBefore));
        expect(a.content.videoAssetId, isNot('vLONG'));
        expect(a.content.videoAssetId, b.content.videoAssetId, reason: 'both layers share the trimmed copy');
        expect(a.content.videoFrameCount, lessThan(300));
        expect(s.content.audioAssetId, isNot('aLONG'));
        expect(s.content.audioDuration, lessThan(10));
        expect(encoders.videoEncodes, 1);
        expect(encoders.audioEncodes, 1);
        expect(app.undo.length, 0, reason: 'the cut parts no longer exist, undo could not restore them');
        expect(videoOnDisk('vLONG'), isFalse, reason: 'the long original is gone');
        expect(store.audios.pcmFile('aLONG').existsSync(), isFalse);
        expect(await directorySize(root), lessThan(sizeBefore));
      });
    });

    testWidgets('a medium that cannot be re-encoded is left whole', (tester) async {
      await tester.runAsync(() async {
        final a = await addVideo('vKEEP', count: 300);
        a.durationFrames = 30;
        encoders.failVideo = true;
        final preview = await app.previewMediaTrim();
        final failed = await app.trimUnusedMedia(preview);
        expect(failed, [a.name]);
        expect(a.content.videoAssetId, 'vKEEP');
        expect(a.content.videoFrameCount, 300);
        expect(store.videos.hasFrames('vKEEP', 300, alpha: false), isTrue);
      });
    });
  });

  group('Settings', () {
    setUp(setUpApp);
    tearDown(() async {
      app.dispose();
      await root.delete(recursive: true);
    });

    /// Lets the real file I/O behind the section's futures run, step by step.
    // real file I/O: a loaded machine needs longer than a fixed few
    // round trips - wait until the overview has filled in (at most ~4 s).
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 200 && (i < 40 || find.textContaining('Undo:').evaluate().isEmpty); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
    }

    testWidgets('storage overview and "Clear undo cache" with its confirmation', (tester) async {
      late Layer layer;
      await tester.runAsync(() async {
        layer = await addVideo('vUI', count: 10);
      });
      app.deleteLayerById(layer.id);
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsView(app: app))));
      await tester.scrollUntilVisible(find.byKey(const ValueKey('storage-overview')), 300, scrollable: find.byType(Scrollable).first);
      await settle(tester);
      expect(find.textContaining('Undo: 1 steps'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('clear-undo-cache')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Deleted layers can no longer be brought back'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('storage-confirm')));
      await settle(tester);
      expect(app.undo.length, 0);
      expect(videoOnDisk('vUI'), isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Re-encoding stand-ins: write a small file instead of running ffmpeg.
class _FakeEncoders extends VideoService implements AudioService {
  int videoEncodes = 0, audioEncodes = 0;
  bool failVideo = false;

  @override
  Future<File> encodeFrameSequence(Directory dir, {required double fps, required bool alpha, required String outputPath}) async {
    if (failVideo) throw StateError('no encoder');
    videoEncodes++;
    final frames = dir.listSync().length;
    return File(outputPath)..writeAsBytesSync(List.filled(frames * 50, 1));
  }

  @override
  Future<File> encodePcm(File pcm, String outputPath) async {
    audioEncodes++;
    return File(outputPath)..writeAsBytesSync(List.filled(pcm.lengthSync() ~/ 20, 2));
  }

  @override
  bool get supportsAlphaChannel => true;

  @override
  Future<DecodedAudio> decodeToPcm(File source, File outPcm,
          {void Function(double fraction)? onProgress, CancelToken? cancel}) =>
      throw UnimplementedError();

  @override
  Future<ExtractedVideo> extractToCache(File source, Directory outDir,
          {required double maxWidth,
          required double maxHeight,
          bool alpha = false,
          void Function(int done, int total)? onProgress,
          CancelToken? cancel}) =>
      throw UnimplementedError();

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
