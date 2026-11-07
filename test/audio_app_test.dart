import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Transform;
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/audio_asset_store.dart';
import 'package:movement_mobile/io/project_store.dart';
import 'package:movement_mobile/services/audio_playback.dart';
import 'package:movement_mobile/services/audio_service.dart';
import 'package:movement_mobile/services/video_service.dart' show CancelToken;
import 'package:movement_mobile/ui/audio/audio_view.dart';
import 'package:movement_mobile/ui/common/param_editor.dart';
import 'package:movement_mobile/ui/timeline/layers_timeline_view.dart';

/// Audio in the app: importing (fake decoder - real decoding needs the
/// native ffmpeg), the preview mix, the sound as the playback clock, the
/// Audio tab, and that a sound layer draws nothing.
void main() {
  late Directory dir;
  late AppState app;
  late _FakeAudioService decoder;
  late _FakePlayback playback;

  setUp(() async {
    fps = 60;
    ParamEditor.resetModes(expanded: true);
    dir = await Directory.systemTemp.createTemp('audio_test_');
    decoder = _FakeAudioService(seconds: 2);
    playback = _FakePlayback();
    app = AppState()
      ..audioStore = AudioAssetStore(documents: dir, cache: Directory('${dir.path}/cache'))
      ..audioService = decoder
      ..audioPlaybackFactory = (() => playback);
    app.project.layers.clear();
  });
  tearDown(() async {
    app.dispose();
    await dir.delete(recursive: true);
  });

  Future<File> sourceFile() async => File('${dir.path}/song.mp3')..writeAsBytesSync([1, 2, 3]);

  testWidgets('import: a layer as long as the sound, with its waveform; undo removes it', (tester) async {
    await tester.runAsync(() async => app.importAudio(await sourceFile()));
    final layer = app.project.layers.single;
    expect(layer.content.shape, 'audio');
    expect(layer.durationFrames, 120);
    expect(layer.name, 'Audio 1');
    expect(app.selection.selectedLayer, layer.id);
    expect(app.maxFrame, greaterThanOrEqualTo(120));
    final peaks = app.audioPeaks(layer.content.audioAssetId)!;
    expect(peaks.length, 2 * audioPeaksPerSecond);
    expect(peaks.first, lessThan(peaks.last), reason: 'the fake sound gets louder');
    expect(File(layer.content.audioPath!).existsSync(), isTrue, reason: 'kept in app storage');
    expect(app.hasAudio, isTrue);
    app.performUndo();
    expect(app.project.layers, isEmpty);
  });

  testWidgets('a failed or cancelled import leaves nothing behind', (tester) async {
    decoder.fail = true;
    await tester.runAsync(() async {
      await expectLater(app.importAudio(await sourceFile()), throwsStateError);
    });
    expect(app.project.layers, isEmpty);
    expect(Directory('${dir.path}/audio').listSync(), isEmpty);
  });

  testWidgets('the preview mix is a WAV as long as the timeline', (tester) async {
    await tester.runAsync(() async {
      await app.importAudio(await sourceFile());
      app.setMaxFrame(179); // 3 s
      final mix = (await app.buildAudioMix())!;
      final bytes = mix.readAsBytesSync();
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect((bytes.length - 44) ~/ 4, 3 * audioSampleRate, reason: 'stereo 16-bit, 3 s');
      app.setAudioMuted(app.project.layers.single.id, true);
      expect(await app.buildAudioMix(), isNull, reason: 'nothing to hear');
    });
  });

  testWidgets('with sound the frames follow the player, not the frame timer', (tester) async {
    await tester.runAsync(() async {
      await app.importAudio(await sourceFile());
      app.setFrame(30);
      app.togglePlay();
      // the mix is made and the player started at the playhead.
      for (var i = 0; i < 100 && !app.playingWithSound; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(app.playingWithSound, isTrue);
    expect(playback.loaded, isNotNull);
    expect(playback.startedAt, const Duration(milliseconds: 500), reason: 'frame 30 at 60 fps');

    playback.position = const Duration(milliseconds: 1500);
    app.playTick(const Duration(seconds: 10), 30); // real time says otherwise - ignored
    expect(app.currentFrame, 90);
    playback.position = const Duration(milliseconds: 1250);
    app.playTick(const Duration(seconds: 11), 30);
    expect(app.currentFrame, 75, reason: 'follows the sound exactly, even if it lags behind');

    app.togglePlay();
    expect(app.playingWithSound, isFalse);
    expect(playback.paused, isTrue);
  });

  testWidgets('without sound playback counts real time as before', (tester) async {
    app.project.layers.add(createLayer('rect')..id = 'r');
    app.setMaxFrame(179);
    app.togglePlay();
    expect(app.playingWithSound, isFalse);
    app.playTick(const Duration(seconds: 1), 0);
    expect(app.currentFrame, 60);
    app.togglePlay();
  });

  testWidgets('Audio tab: mute and volume of the selected sound', (tester) async {
    await tester.runAsync(() async => app.importAudio(await sourceFile()));
    final layer = app.project.layers.single;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 420, height: 600, child: AudioView(app: app)))));
    await tester.pumpAndSettle();
    expect(find.text('Volume'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('audio-mute')));
    await tester.pump();
    expect(layer.content.audioMuted, isTrue);
    expect(app.hasAudio, isFalse);
    app.performUndo();
    await tester.pump();
    expect(findLayer(app.project, layer.id)!.content.audioMuted, isFalse);

    app.selectLayer(null);
    await tester.pump();
    expect(find.byKey(const ValueKey('audio-import')), findsOneWidget);
  });

  testWidgets('a sound layer draws nothing and has no stage box', (tester) async {
    await tester.runAsync(() async => app.importAudio(await sourceFile()));
    app.renderer.renderFrame(app.project, 10);
    late ByteData bytes;
    await tester.runAsync(() async {
      final img = await app.renderer.captureFrame();
      bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    var opaque = 0;
    for (var i = 3; i < bytes.lengthInBytes; i += 4) {
      if (bytes.getUint8(i) != 0) opaque++;
    }
    expect(opaque, 0);
  });

  testWidgets('the timeline draws the sound lane with its waveform', (tester) async {
    await tester.runAsync(() async => app.importAudio(await sourceFile()));
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SizedBox(width: 600, height: 200, child: LayersTimelineView(app: app)))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final painted = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((w) => w.painter?.runtimeType.toString());
    expect(painted, contains('_LaneLinePainter'));
  });

  testWidgets('the waveform is recorded once, not again when the playhead moves or the lane repaints', (tester) async {
    await tester.runAsync(() async => app.importAudio(await sourceFile()));
    clearWaveformPictures();
    waveformRecordings = 0;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SizedBox(width: 600, height: 200, child: LayersTimelineView(app: app)))));
    await tester.pumpAndSettle();
    expect(waveformRecordings, 1);
    for (var f = 1; f < 40; f += 3) {
      app.setFrame(f, quiet: true);
      await tester.pump();
    }
    app.selectLayer(app.project.layers.first.id); // a full rebuild, the lane repaints
    await tester.pumpAndSettle();
    expect(waveformRecordings, 1, reason: 'the same audio, trim and zoom reuse the recorded picture');
    app.project.layers.first.content.sourceIn = 0.5; // trimmed: the bars change
    app.commitEdit();
    await tester.pumpAndSettle();
    expect(waveformRecordings, 2);
  });

  test('project cleanup removes sounds no project uses', () async {
    final store = ProjectStore(dir);
    final kept = store.audios.newAssetId();
    await Directory('${dir.path}/audio').create(recursive: true);
    File('${dir.path}/audio/$kept.mp3').writeAsBytesSync([1]);
    File('${dir.path}/audio/aGONE.mp3').writeAsBytesSync([1]);
    await Directory('${dir.path}/projects').create(recursive: true);
    File('${dir.path}/projects/p.json').writeAsStringSync('{"audioAssetId": "$kept"}');
    await store.cleanupVideos();
    expect(File('${dir.path}/audio/$kept.mp3').existsSync(), isTrue);
    expect(File('${dir.path}/audio/aGONE.mp3').existsSync(), isFalse);
  });
}

/// Writes `seconds` of a rising sawtooth instead of decoding.
class _FakeAudioService implements AudioService {
  @override
  Future<File> encodePcm(File pcm, String outputPath, {int kbps = 160}) => throw UnimplementedError();

  final double seconds;
  bool fail = false;
  _FakeAudioService({required this.seconds});

  @override
  Future<DecodedAudio> decodeToPcm(File source, File outPcm,
      {void Function(double fraction)? onProgress, CancelToken? cancel}) async {
    if (fail) throw StateError('not a sound');
    final frames = (seconds * audioSampleRate).round();
    final pcm = Int16List(frames * audioChannels);
    for (var i = 0; i < frames; i++) {
      final v = (i * 30000 ~/ frames) * (i.isEven ? 1 : -1);
      pcm[i * 2] = v;
      pcm[i * 2 + 1] = v;
    }
    await outPcm.parent.create(recursive: true);
    await outPcm.writeAsBytes(pcm.buffer.asUint8List());
    onProgress?.call(1);
    return DecodedAudio(seconds);
  }
}

class _FakePlayback implements AudioPlayback {
  String? loaded;
  Duration? startedAt;
  bool paused = false;
  @override
  Duration position = Duration.zero;

  @override
  Future<void> load(String path) async => loaded = path;

  @override
  Future<void> start(Duration from, {double speed = 1}) async {
    startedAt = from;
    position = from;
    paused = false;
  }

  @override
  Future<void> pause() async => paused = true;

  @override
  Future<void> dispose() async {}
}
