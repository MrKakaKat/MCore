import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/audio_asset_store.dart';
import 'package:movement_mobile/io/video_asset_store.dart';
import 'package:movement_mobile/main.dart';
import 'package:movement_mobile/services/audio_service.dart';
import 'package:movement_mobile/services/video_service.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/text/text_view.dart';

/// Timeline links, text as a mask, the Text tab opening for a new text,
/// and a video's sound coming in as a linked layer.
void main() {
  setUpAll(() => registerFont(defaultFontId, File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync()));
  setUp(() {
    fps = 60;
    ParamEditor.resetModes(expanded: true);
  });

  Layer rect(String id, int start, int dur) => createLayer('rect')
    ..id = id
    ..name = id
    ..startFrame = start
    ..durationFrames = dur;

  group('timeline links', () {
    test('dragging one moves its linked layer along; one undo step; unlink frees it', () {
      final app = AppState();
      final a = rect('a', 0, 30), b = rect('b', 50, 30);
      app.project.layers
        ..clear()
        ..addAll([a, b]);
      app.linkLayersInTime('a', 'b');
      expect(areTimeLinked(a, b), isTrue);

      app.beginLayerDrag('a', LayerDragMode.move);
      app.updateLayerDrag(20);
      app.endLayerDrag();
      expect([a.startFrame, b.startFrame], [20, 70]);
      app.performUndo();
      expect([for (final l in app.project.layers) l.startFrame], [0, 50]);

      final a2 = findLayer(app.project, 'a')!, b2 = findLayer(app.project, 'b')!;
      app.setFrame(10);
      app.moveLayerStartToPlayhead('b');
      expect([a2.startFrame, b2.startFrame], [0, 50], reason: 'a is already at frame 0 - the group cannot go back');
      app.setFrame(60);
      app.moveLayerStartToPlayhead('b');
      expect([a2.startFrame, b2.startFrame], [10, 60]);

      app.unlinkLayerInTime('b');
      expect(a2.linkId, isNull);
      app.beginLayerDrag('a', LayerDragMode.move);
      app.updateLayerDrag(5);
      app.endLayerDrag();
      expect([a2.startFrame, b2.startFrame], [15, 60]);
    });

    test('with timeline snapping on, the partner follows the snapped leader', () {
      final app = AppState();
      final a = rect('a', 0, 30), b = rect('b', 100, 10), w = rect('w', 0, 63);
      app.project.layers
        ..clear()
        ..addAll([a, b, w]);
      app.linkLayersInTime('a', 'b');
      app.toggleSnapTimelineLayers();
      app.beginLayerDrag('a', LayerDragMode.move);
      app.updateLayerDrag(60); // a's start lands 3 frames short of w's end
      app.endLayerDrag();
      expect(a.startFrame, 63, reason: 'snapped to w');
      expect(b.startFrame, 163, reason: 'moved exactly as much');
    });
  });

  testWidgets('text as a mask: the layer shows through the letters only', (tester) async {
    final app = AppState()..setFrameSize(200, 200);
    app.project.layers.clear();
    final target = rect('photo', 0, 60)
      ..color = '#ffffff'
      ..content = Content(shape: 'rect', offset: [0, 0], size: [200, 200]);
    target.transform.anchor.defaultValue = [0.5, 0.5];
    app.project.layers.add(target);
    app.addTextLayer();
    final text = app.project.layers.last;
    app.editText(text.id, (t) => t
      ..text = 'O'
      ..fontSize = 140);
    app.fitTextBoxOf(text.id);
    app.setTextMask(text.id, target.id, true);
    app.toggleHidden(text.id); // only the letters' outline is wanted
    expect(target.masks.single.sourceLayerId, text.id);

    app.renderer.renderFrame(app.project, 0);
    late ByteData bytes;
    await tester.runAsync(() async {
      final img = await app.renderer.captureFrame();
      bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    int alpha(int x, int y) => bytes.getUint8((y * 200 + x) * 4 + 3);
    var opaque = 0;
    for (var i = 3; i < bytes.lengthInBytes; i += 4) {
      if (bytes.getUint8(i) > 128) opaque++;
    }
    final box = text.content.size[0] * text.content.size[1];
    expect(opaque, greaterThan(500), reason: 'the letter shows the photo');
    expect(opaque, lessThan(box * 0.7), reason: 'by its outline, not its whole box');
    expect(alpha(100, 100), 0, reason: 'the hole of the O is a hole');
    expect(alpha(2, 2), 0);

    app.setTextMask(text.id, target.id, false);
    expect(target.masks, isEmpty);
  });

  testWidgets('Text tab: tick layers to mask them with the text, hide the text itself', (tester) async {
    final app = AppState();
    final other = app.project.layers.first;
    app.addTextLayer();
    final text = app.project.layers.last;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 560, child: TextView(app: app)))));
    await tester.pumpAndSettle();
    final section = find.byKey(const ValueKey('text-section-Use as a mask'));
    await tester.scrollUntilVisible(section, 200, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    await tester.tap(section);
    await tester.pump();
    final box = find.byKey(ValueKey('text-mask-${other.id}'));
    await tester.ensureVisible(box);
    await tester.pumpAndSettle();
    await tester.tap(box);
    await tester.pump();
    expect(other.masks.single.sourceLayerId, text.id);
    await tester.ensureVisible(find.byKey(const ValueKey('text-mask-show-self')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('text-mask-show-self')));
    await tester.pump();
    expect(text.hidden, isTrue);
  });

  testWidgets('adding a text opens the Text tab', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = AppState();
    await tester.pumpWidget(MovementMobileApp(appState: app));
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Layers')).selected, isTrue);
    app.addTextLayer();
    await tester.pumpAndSettle();
    expect(app.requestedTab, 'Text');
    expect(find.byType(TextView), findsOneWidget, reason: 'the Text tab is showing');
  });

  group('a video with its sound', () {
    late Directory tmp;
    late AppState app;
    late _Sound sound;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('video_sound');
      sound = _Sound();
      app = AppState()
        ..videoService = _Frames()
        ..videoStore = VideoAssetStore(documents: Directory('${tmp.path}/docs'), cache: Directory('${tmp.path}/cache'))
        ..audioStore = AudioAssetStore(documents: Directory('${tmp.path}/docs'), cache: Directory('${tmp.path}/cache'))
        ..audioService = sound;
      app.project.layers.clear();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    testWidgets('comes in as a separate audio layer, linked; one undo step', (tester) async {
      await tester.runAsync(() => app.importVideo(File('${tmp.path}/in.mp4')..writeAsStringSync('v')));
      final video = app.project.layers.first, audio = app.project.layers.last;
      expect(app.project.layers.length, 2);
      expect(audio.content.shape, 'audio');
      expect(audio.name, '${video.name}_sound');
      expect(areTimeLinked(video, audio), isTrue);
      expect(audio.content.audioPath, video.content.videoPath, reason: 'played from the kept video copy');
      expect(sound.calls, 1);
      // the video copy stays while the sound layer uses it.
      final json = '{"audioPath": "${audio.content.audioPath}"}';
      expect(VideoAssetStore.assetIdsInProjectFile(json), contains(video.content.videoAssetId));
      app.performUndo();
      expect(app.project.layers, isEmpty);
    });

    testWidgets('a silent video, or sound switched off: just the video', (tester) async {
      sound.silent = true;
      await tester.runAsync(() => app.importVideo(File('${tmp.path}/in.mp4')..writeAsStringSync('v')));
      expect(app.project.layers.single.content.shape, 'video');
      expect(Directory('${tmp.path}/cache/audio_pcm').existsSync() ? Directory('${tmp.path}/cache/audio_pcm').listSync() : [],
          isEmpty);
      sound.silent = false;
      await tester.runAsync(() => app.importVideo(File('${tmp.path}/in.mp4')..writeAsStringSync('v'), withSound: false));
      expect(app.project.layers.length, 2);
      expect(app.project.layers.every((l) => l.content.shape == 'video'), isTrue);
    });
  });
}

class _Frames extends VideoService {
  @override
  Future<File> encodeFrameSequence(Directory dir, {required double fps, required bool alpha, required String outputPath}) =>
      throw UnimplementedError();

  @override
  bool get supportsAlphaChannel => true;

  @override
  Future<ExtractedVideo> extractToCache(File source, Directory outDir,
      {required double maxWidth,
      required double maxHeight,
      bool alpha = false,
      void Function(int done, int total)? onProgress,
      CancelToken? cancel}) async {
    await outDir.create(recursive: true);
    for (var i = 0; i < 30; i++) {
      File('${outDir.path}/${videoFrameFileName(i, alpha: alpha)}').writeAsStringSync('f');
    }
    return ExtractedVideo(fps: 30, frameCount: 30, width: 64, height: 36, alpha: alpha);
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

class _Sound implements AudioService {
  @override
  Future<File> encodePcm(File pcm, String outputPath, {int kbps = 160}) => throw UnimplementedError();

  int calls = 0;
  bool silent = false;

  @override
  Future<DecodedAudio> decodeToPcm(File source, File outPcm,
      {void Function(double fraction)? onProgress, CancelToken? cancel}) async {
    calls++;
    if (silent) throw StateError('This file has no sound.');
    final pcm = Int16List(audioSampleRate * audioChannels); // 1 s
    await outPcm.parent.create(recursive: true);
    await outPcm.writeAsBytes(pcm.buffer.asUint8List());
    return const DecodedAudio(1);
  }
}
