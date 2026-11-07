import 'dart:typed_data';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    registerBuiltinEffects();
    setStageSize(400, 400);
    clearStateCaches();
    fps = 60;
  });
  tearDown(() => soundPeaksProvider = null);

  test('a sound link: silent gives min, loud gives max; smoothing evens it out', () {
    // one second of silence, then one second at full.
    final peaks = Uint8List(2 * audioPeaksPerSecond)..fillRange(audioPeaksPerSecond, 2 * audioPeaksPerSecond, 255);
    soundPeaksProvider = (_) => peaks;
    final sound = createLayer('rect')
      ..content.shape = 'audio'
      ..content.audioAssetId = 'a1'
      ..durationFrames = 120;
    final l = createLayer('rect')
      ..links.add(PropLink(from: 'sound', to: 'scaleX', sourceId: sound.id, min: 0, max: 0.5, smooth: 0));
    final p = Project(layers: [sound, l]);
    expect(linkOffset(p, l, 'scaleX', 30), closeTo(0, 1e-9));
    expect(linkOffset(p, l, 'scaleX', 90), closeTo(0.5, 0.02));
    // smoothed: just after it starts, still on the way up.
    l.links.first.smooth = 1;
    final early = linkOffset(p, l, 'scaleX', 62);
    expect(early, greaterThan(0));
    expect(early, lessThan(0.4));
    final back = layerFromJson(layerToJson(l));
    expect(back.links.single.fromSound, isTrue);
    expect(back.links.single.max, 0.5);
  });

  test('a rect lengthens instead of stretching, the far side stays', () {
    final l = createLayer('rect')..content.size = [100, 100];
    final p = Project(layers: [l]);
    rectExtendMode = true;
    addTearDown(() => rectExtendMode = false);
    final m = getTransformBoxHandles(p, l, 0).mCanvas;
    ScaleDragOp(layer: l, handle: 'right').apply(p, 0, applyAffine(m, const [100, 0]));
    expect(l.content.size[0], closeTo(150, 1e-6));
    expect(l.content.offset[0] - l.content.size[0] / 2, closeTo(-50, 1e-6), reason: 'the left side where it was');
    expect((l.transform.scale.defaultValue as List)[0], 1.0, reason: 'not stretched');
  });

  test('rounding: only the corners switched on; off keeps its size for later', () {
    final ring = roundedRectRing(0, 0, 100, 100, 20, 20, corners: [true, false, true, true]);
    expect(ring.any((q) => q[0] == 50 && q[1] == -50), isTrue, reason: 'top right stays sharp');
    expect(ring.any((q) => q[0] == -50 && q[1] == -50), isFalse, reason: 'top left rounded');
    final f = ShapeFill(cornerRadius: 12);
    expect(f.roundingOn, isTrue);
    expect(ShapeFill().roundingOn, isFalse);
  });

  test('merged lines keep their shape (the stroke, not the box)', () {
    final a = createLayer('line', size: 46)..content.lineWidth = 10;
    final b = createLayer('line', size: 46)..content.lineWidth = 10;
    b.transform.anchor.defaultValue = [0.5, 0.6];
    final p = Project(layers: [a, b]);
    final merged = mergeLayers(p, [a, b], 'm', 0)!;
    final ys = merged.content.contours!.expand((r) => r).map((q) => q[1]);
    // two thin bands, not tall boxes: each ring only the line's width tall.
    for (final r in merged.content.contours!) {
      final ry = r.map((q) => q[1]);
      expect(ry.reduce((x, y) => x > y ? x : y) - ry.reduce((x, y) => x < y ? x : y), lessThan(12));
    }
    expect(ys, isNotEmpty);
  });
}
