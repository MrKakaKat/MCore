import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// 3D projects: the layers drawn as cards seen through the camera.
void main() {
  setUpAll(registerBuiltinEffects);
  setUp(clearStateCaches);

  Layer card(String id, String color, {double x = 0.5}) => createLayer('rect')
    ..id = id
    ..content.offset = [0, 0]
    ..content.size = [100, 100]
    ..color = color
    ..transform.anchor.keyframes = [Keyframe(frame: 0, value: <double>[x, 0.5])];

  Future<ByteData> draw(Project p, {Camera3? cam, bool guides = false}) async {
    setStageSize(400, 300);
    final r = CanvasRenderer()
      ..setSize(400, 300)
      ..viewCamera3 = cam
      ..show3dGuides = guides
      ..backgroundColor = const ui.Color(0xFF000000);
    r.renderFrame(p, 0);
    final img = await r.captureFrame();
    return (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  }

  int red(ByteData px, int x, int y) => px.getUint8((y * 400 + x) * 4);
  int blue(ByteData px, int x, int y) => px.getUint8((y * 400 + x) * 4 + 2);

  test('straight on, a card at z = 0 looks as in a flat project', () async {
    final p = Project(layers: [card('A', '#ff0000')])..space3d = true;
    final px = await draw(p);
    expect(red(px, 200, 150), greaterThan(240));
    expect(red(px, 240, 150), greaterThan(240), reason: '40 px right: still on the 100 px card');
    expect(red(px, 260, 150), lessThan(10));
  });

  test('deeper is smaller; turned 80 about y it is a sliver', () async {
    final l = card('A', '#ff0000');
    final p = Project(layers: [l])..space3d = true;
    l.transform.z.keyframes = [Keyframe(frame: 0, value: 600.0)];
    var px = await draw(p);
    expect(red(px, 200, 150), greaterThan(240));
    expect(red(px, 240, 150), lessThan(10), reason: 'smaller far away');
    l.transform.z.keyframes = [];
    l.transform.rotationY.keyframes = [Keyframe(frame: 0, value: 80.0)];
    clearStateCaches();
    px = await draw(p);
    expect(red(px, 230, 150), lessThan(10));
  });

  test('the nearer card covers the farther, whatever the layer order', () async {
    final near = card('N', '#0000ff'), far = card('F', '#ff0000');
    far.transform.z.keyframes = [Keyframe(frame: 0, value: 200.0)];
    // the far one listed on top: still behind.
    final p = Project(layers: [near, far])..space3d = true;
    final px = await draw(p);
    expect(blue(px, 200, 150), greaterThan(240));
    expect(red(px, 200, 150), lessThan(10));
  });

  test('a card going behind the camera is not drawn; guides do not break', () async {
    final l = card('A', '#ff0000');
    final p = Project(layers: [l])..space3d = true;
    final cam = defaultCamera3(400, 300);
    l.transform.z.keyframes = [Keyframe(frame: 0, value: cam.eye[2] - 10)];
    final px = await draw(p, cam: orbitCamera3([200, 150, 0], 35, 25, 800), guides: true);
    expect(px.lengthInBytes, 400 * 300 * 4);
    final behind = await draw(p);
    expect(red(behind, 200, 150), lessThan(10));
  });
}
