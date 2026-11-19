import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    setStageSize(1000, 600);
    clearStateCaches();
  });

  test('the default camera shows the plane z = 0 as the flat frame', () {
    final v = View3(defaultCamera3(1000, 600), 1000, 600);
    for (final p in [
      [0.0, 0.0],
      [1000.0, 600.0],
      [250.0, 420.0],
    ]) {
      final s = v.project([p[0], p[1], 0]);
      expect(s[0], closeTo(p[0], 1e-6));
      expect(s[1], closeTo(p[1], 1e-6));
      final m = apply4(v.matrix(), p[0], p[1], 0);
      expect(m[0] / m[3], closeTo(p[0], 1e-6));
      expect(m[1] / m[3], closeTo(p[1], 1e-6));
    }
    // farther away: smaller, toward the middle.
    final far = v.project([0, 0, 500]);
    expect(far[0], greaterThan(0));
    expect(far[1], greaterThan(0));
  });

  test('a flat layer in a 3D project draws where it did; z and turns move it', () {
    final l = createLayer('rect')..id = 'A'..durationFrames = 100;
    l.transform.anchor.keyframes = [Keyframe(frame: 0, value: <double>[0.3, 0.5])];
    final p = Project(layers: [l])..space3d = true;
    final v = View3(cameraOf(p, 1000, 600), 1000, 600);
    final m = layerPictureMatrix(v, p, l, 0);
    final a = apply4(m, 300, 300, 0);
    expect(a[0] / a[3], closeTo(300, 1e-6));
    expect(a[1] / a[3], closeTo(300, 1e-6));
    final near = layerDepth3d(v, p, l, 0);

    l.transform.z.keyframes = [Keyframe(frame: 0, value: 400.0)];
    clearStateCaches();
    expect(layerDepth3d(v, p, l, 0), closeTo(near + 400, 1e-6));

    // turned 90 about y: its right side goes into the depth.
    l.transform.z.keyframes = [];
    l.transform.rotationY.keyframes = [Keyframe(frame: 0, value: 90.0)];
    clearStateCaches();
    final t = layerTilt3d(p, l, 0);
    final r = apply4(t, 400, 300, 0); // 100 px right of the anchor
    expect(r[0], closeTo(300, 1e-6));
    expect(r[2], closeTo(-100, 1e-6));
    // the anchor stays.
    final o = apply4(t, 300, 300, 0);
    expect(o[0], closeTo(300, 1e-6));
    expect(o[2], closeTo(0, 1e-6));
  });

  test('a picture point back to the plane it was on', () {
    final v = View3(orbitCamera3([500, 300, 0], 30, 20, 900), 1000, 600);
    final w = [420.0, 250.0, 120.0];
    final s = v.project(w);
    final back = v.onPlaneZ(s[0], s[1], 120)!;
    expect(back[0], closeTo(w[0], 1e-6));
    expect(back[1], closeTo(w[1], 1e-6));
  });

  test('a segment going behind the camera is cut, all behind: none', () {
    final v = View3(defaultCamera3(1000, 600), 1000, 600);
    final eyeZ = v.eye[2];
    expect(v.segment([0, 0, eyeZ - 10], [10, 0, eyeZ - 20]), isNull);
    final s = v.segment([500, 300, 0], [500, 300, eyeZ - 100]);
    expect(s, isNotNull);
    expect(s![0], closeTo(500, 1e-6));
  });

  test('3D tracks and the camera go through the file', () {
    final l = createLayer('rect')..id = 'A';
    l.transform.rotationX.keyframes = [Keyframe(frame: 0, value: 30.0)];
    final j = transformToJson(l.transform);
    final back = transformFromJson(j);
    expect(back.rotationX.keyframes.single.value, 30.0);
    expect(back.z.keyframes, isEmpty);
    final c = camera3FromJson(camera3ToJson(orbitCamera3([1, 2, 3], 10, 5, 100)));
    expect(c.target, [1, 2, 3]);
    expect(c.fov, 50);
  });

  test('inside a picture polygon', () {
    final sq = [
      [0.0, 0.0],
      [10.0, 0.0],
      [10.0, 10.0],
      [0.0, 10.0],
    ];
    expect(insidePolygon(sq, 5, 5), isTrue);
    expect(insidePolygon(sq, 15, 5), isFalse);
  });
}
