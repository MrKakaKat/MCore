import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/render/canvas_renderer.dart';

/// Decompose: a placed project's layers put into the host look as the
/// placed project did - its place, size, turn and its layers' moves.
void main() {
  setUpAll(registerBuiltinEffects);
  test('decomposed layers draw as the placed project did', () async {
    fps = 30;
    // the source: 200 x 100, two layers, one a child of the other, moving.
    final a = createLayer('rect')
      ..id = 'a'
      ..name = 'a'
      ..color = '#ff0000'
      ..durationFrames = 60
      ..content = Content(shape: 'rect', offset: [0, 0], size: [40, 30]);
    a.transform.anchor.spatial = true;
    a.transform.anchor.keyframes.addAll([
      Keyframe(frame: 0, value: [0.2, 0.3]),
      Keyframe(frame: 60, value: [0.8, 0.6]),
    ]);
    final b = createLayer('rect')
      ..id = 'b'
      ..name = 'b'
      ..color = '#0000ff'
      ..parentId = 'a'
      ..durationFrames = 60
      ..content = Content(shape: 'rect', offset: [0, 0], size: [10, 10]);
    b.transform.anchor.defaultValue = [0.1, 0.1];
    final src = RefSource(
        id: 'src', name: 'inner', revision: 1, project: Project(fps: 30, layers: [a, b]), fps: 30, width: 200, height: 100, durationFrames: 60);
    final ref = createProjectRefLayer(src, id: 'R', frameW: 300, frameH: 300, hostFps: 30)..startFrame = 5;
    ref.transform.anchor.defaultValue = [0.45, 0.55];
    ref.transform.rotation.defaultValue = 20.0;
    ref.transform.scale.defaultValue = [0.8, 0.8];
    final host = Project(fps: 30, layers: [ref]);

    Future<ByteDataView> draw(int frame) async {
      setStageSize(300, 300);
      clearStateCaches();
      final r = CanvasRenderer()..setSize(300, 300);
      r.backgroundColor = null;
      r.refSources['src'] = src;
      r.refChain = ['host'];
      r.renderFrame(host, frame);
      final img = await r.captureFrame();
      final bd = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return ByteDataView(bd);
    }

    final before = [await draw(20), await draw(50)];
    int seen(ByteDataView v) {
      var k = 0;
      for (var i = 3; i < v.d.lengthInBytes; i += 4) {
        if (v.d.getUint8(i) > 128) k++;
      }
      return k;
    }
    expect(seen(before[0]), greaterThan(500), reason: 'the placed project shows');
    var n = 0;
    final copies = decomposeProjectRef(host, ref, src, hostFps: 30, hostW: 300, hostH: 300, newId: () => 'C${n++}')!;
    expect(copies.map((l) => l.name), ['a', 'b']);
    expect(ref.content.shape, 'null');
    expect([copies[0].parentId, copies[1].parentId], ['R', 'C0'], reason: 'their parent kept among them');
    expect(copies.every((l) => l.folder == 'inner'), isTrue);
    expect(copies[0].startFrame, 5);
    final after = [await draw(20), await draw(50)];
    for (var f = 0; f < 2; f++) {
      var off = 0;
      for (var i = 3; i < before[f].d.lengthInBytes; i += 4) {
        if ((before[f].d.getUint8(i) - after[f].d.getUint8(i)).abs() > 128) off++;
      }
      // only antialiased edge pixels may differ.
      expect(off, lessThan(60), reason: 'frame ${[20, 50][f]}: $off pixels differ');
    }
  });
}

class ByteDataView {
  final ByteData d;
  ByteDataView(this.d);
}
