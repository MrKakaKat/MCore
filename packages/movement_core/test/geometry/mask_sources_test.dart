import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

double _area(List<List<List<double>>> rings) {
  var t = 0.0;
  for (final r in rings) {
    var a = 0.0;
    for (var i = 0; i < r.length; i++) {
      final p = r[i], q = r[(i + 1) % r.length];
      a += p[0] * q[1] - q[0] * p[1];
    }
    t += a / 2;
  }
  return t.abs();
}

void main() {
  setUpAll(registerBuiltinEffects);
  test('a mask with two sources keeps what is under either of them', () {
    stageSize.width = 480;
    stageSize.height = 480;
    final project = Project(fps: 30);
    final target = createLayer('rect', size: 200);
    final a = createLayer('rect', size: 40), b = createLayer('rect', size: 40);
    a.transform.anchor.defaultValue = [0.4, 0.5];
    b.transform.anchor.defaultValue = [0.6, 0.5];
    project.layers.addAll([target, a, b]);
    target.masks.add(Mask(sourceLayerId: a.id));
    clearStateCaches();
    final one = _area(layerVectorRings(project, target, 0)!);
    target.masks.first.moreSources.add(b.id);
    clearStateCaches();
    final two = _area(layerVectorRings(project, target, 0)!);
    expect(one, closeTo(1600, 1));
    expect(two, closeTo(3200, 1));
    final back = maskFromJson(maskToJson(target.masks.first));
    expect(back.moreSources, [b.id]);
  });
}
