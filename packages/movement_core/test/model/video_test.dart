import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _video({double srcFps = 30, int count = 90}) =>
    createVideoLayer(path: '/v.mp4', assetId: 'a1', width: 1920, height: 1080, sourceFps: srcFps, frameCount: count);

void main() {
  setUp(() => fps = 60);
  tearDown(() => fps = 60);

  test('time mapping: project frames to source frames, held past the ends', () {
    final l = _video();
    expect(l.durationFrames, 180, reason: '90 frames at 30 fps = 3 s = 180 project frames');
    expect(l.content.size, [200, 112.5]);
    final c = l.content;
    expect(videoSourceFrame(c, 0), 0);
    expect(videoSourceFrame(c, 1), 0);
    expect(videoSourceFrame(c, 2), 1);
    expect(videoSourceFrame(c, 179), 89);
    expect(videoSourceFrame(c, 400), 89, reason: 'last frame holds');
    expect(videoSourceFrame(c, -10), 0);
    c.sourceIn = 1.0;
    expect(videoSourceFrame(c, 0), 30);
    fps = 24;
    expect(videoSourceFrame(c, 24), 60, reason: 'one second later at any project rate');
  });

  test('split: the right half continues from the cut', () {
    final l = _video();
    final p = Project(layers: [l]);
    final right = splitLayer(p, l, 60, 'R')!;
    expect(l.content.sourceIn, 0);
    expect(right.content.sourceIn, closeTo(1.0, 1e-9));
    expect(videoSourceFrame(right.content, 0), videoSourceFrame(l.content, 60));
  });

  test('left trim shifts the in-point; right trim and moving do not', () {
    final l = _video()..startFrame = 60;
    final frameAt120 = videoSourceFrame(l.content, 120 - l.startFrame);
    LayerTrackDragOp.grab(l, LayerDragMode.trimLeft).apply(30);
    expect(l.startFrame, 90);
    expect(l.content.sourceIn, closeTo(0.5, 1e-9));
    expect(videoSourceFrame(l.content, 120 - l.startFrame), frameAt120, reason: 'the picture stays put');
    LayerTrackDragOp.grab(l, LayerDragMode.trimRight).apply(-20);
    LayerTrackDragOp.grab(l, LayerDragMode.move).apply(10);
    expect(l.content.sourceIn, closeTo(0.5, 1e-9));
  });

  test('JSON round-trip and defaults', () {
    final l = _video()..content.sourceIn = 2.5;
    l.content.videoAlpha = true;
    final back = layerFromJson(jsonDecode(jsonEncode(layerToJson(l))) as Map<String, dynamic>);
    final c = back.content;
    expect([c.shape, c.videoPath, c.videoAssetId, c.sourceIn, c.videoFps, c.videoFrameCount, c.videoAlpha],
        ['video', '/v.mp4', 'a1', 2.5, 30.0, 90, true]);
    final old = contentFromJson({'shape': 'rect', 'offset': [0, 0], 'size': [1, 1]});
    expect(old.sourceIn, 0);
    expect(old.videoAlpha, isFalse);
    expect(videoAssetIds(Project(layers: [l, createLayer('rect')])), {'a1'});
  });

  test('project retiming keeps a video in sync', () {
    final l = _video();
    final p = Project(layers: [l]);
    retimeProject(p, 30);
    expect(l.durationFrames, 90);
    expect(videoSourceFrame(l.content, 45), 45);
  });
}
