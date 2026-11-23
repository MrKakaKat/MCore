import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => setStageSize(640, 400));

  Layer layer() => Layer(
        id: 'g',
        name: 'g',
        startFrame: 0,
        durationFrames: 120,
        transform: Transform(
            anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
        content: Content(shape: 'rect', offset: [0, 0], size: [40, 20]),
      );

  test('bursts jump: the colours split now and then, at once, back to calm between', () {
    final l = layer();
    applyGlitchPreset(l, 'bursts');
    final ks = l.filters.blur.keyframes;
    expect(l.filters.blurKind, 'chromatic');
    expect(ks.length, greaterThan(4));
    expect(ks.every((k) => k.temporal.hold), isTrue);
    expect(ks.every((k) => k.frame >= 0 && k.frame < 120), isTrue);
    final p = Project(layers: [l]);
    // between two keys the value stays the first one's (no sliding).
    final a = ks[1], b = ks[2];
    if (b.frame - a.frame > 1) {
      expect(evaluateTrackOwn(p, l.filters.blur, (b.frame - 1).toDouble(), l), closeTo(a.value as double, 1e-9));
    }
  });

  test('heavy turns everything on; clearing takes it all off', () {
    final l = layer();
    applyGlitchPreset(l, 'heavy');
    expect(l.wiggle.enabled, isTrue);
    expect(l.timeQuantize.enabled, isTrue);
    expect(l.filters.negative.keyframes, isNotEmpty);
    expect(l.filters.warp.keyframes, isNotEmpty);
    clearGlitch(l);
    expect(l.wiggle.enabled, isFalse);
    expect(l.timeQuantize.enabled, isFalse);
    expect([l.filters.negative.keyframes, l.filters.warp.keyframes, l.filters.blur.keyframes], [isEmpty, isEmpty, isEmpty]);
  });

  test('every preset applies', () {
    for (final (k, _) in glitchPresets) {
      applyGlitchPreset(layer(), k);
    }
  });
}
