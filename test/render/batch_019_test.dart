import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart' hide Transform;
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/ui/audio/audio_view.dart';
import 'package:movement_mobile/ui/media/media_library.dart';
import 'package:photo_manager/photo_manager.dart' show AssetType;

void main() {
  setUp(() => setStageSize(200, 100));

  test('what a file is, by its name', () {
    expect(mediaExtension('a.jpg'), 'JPEG');
    expect(mediaExtension('clip.MP4'), 'MP4');
    expect(mediaExtension('noext', mime: 'image/png'), 'PNG');
    expect(mediaKindOf('x.gif', type: AssetType.image), 'gif');
    expect(mediaKindOf('x.png', type: AssetType.image), 'image');
    expect(mediaKindOf('song.mp3'), 'audio');
    expect(mediaKindOf('v.mov'), 'video');
  });

  test('recently used: newest first, no repeats, kept between runs', () {
    final app = AppState();
    app.addRecentMedia('/a.png', 'image', 'a.png');
    app.addRecentMedia('/b.mp4', 'video', 'b.mp4');
    app.addRecentMedia('/a.png', 'image', 'a.png');
    expect(app.recentMedia.map((r) => r.path), ['/a.png', '/b.mp4']);
  });

  test('a video and its linked sound change speed together', () {
    final app = AppState()..setFrameSize(200, 100);
    final v = createLayer('rect')
      ..id = 'V'
      ..content.shape = 'video'
      ..durationFrames = 100;
    final s = createAudioLayer(path: 'x', assetId: 'A', durationSeconds: 100 / fps)
      ..id = 'S'
      ..startFrame = v.startFrame;
    app.project.layers.addAll([v, s]);
    linkInTime(app.project, v, s);
    app.setMediaSpeedOf('V', 2);
    expect([v.content.mediaSpeed, s.content.mediaSpeed], [2, 2]);
    expect(v.durationFrames, 50);
    app.performUndo();
    expect(findLayer(app.project, 'V')!.content.mediaSpeed, 1);
  });

  testWidgets('Audio tab: a video shows its speed', (tester) async {
    final app = AppState()..setFrameSize(200, 100);
    final v = createLayer('rect')
      ..id = 'V'
      ..content.shape = 'video'
      ..durationFrames = 100;
    app.project.layers.add(v);
    app.selectLayer('V');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: AudioView(app: app))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('media-speed-0.5')));
    await tester.pumpAndSettle();
    expect(v.content.mediaSpeed, 0.5);
    expect(v.durationFrames, 200);
  });

  testWidgets('the media library opens on Recently used, with each file\'s type', (tester) async {
    final app = AppState();
    app.addRecentMedia('/nowhere/a.png', 'image', 'a.png');
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(onPressed: () => openMediaLibrary(context, app), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('media-section-recent')), findsOneWidget);
    expect(find.byKey(const ValueKey('media-section-gif')), findsOneWidget);
    expect(find.text('PNG'), findsOneWidget);
    // searching by name.
    await tester.enterText(find.byKey(const ValueKey('media-search')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('PNG'), findsNothing);
  });
}
