import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  test('a new aspect never stretches: even scale, places kept round the middle', () {
    final project = Project(fps: 30);
    final r = createLayer('rect', size: 100);
    r.transform.anchor.defaultValue = [0.25, 0.5];
    project.layers.add(r);
    // 1000 x 1000 -> 2000 x 1000: scale 1 (the smaller change), x place kept in px.
    refitProjectEvenly(project, 1000, 1000, 2000, 1000);
    expect(r.content.size, [100.0, 100.0]);
    final a = r.transform.anchor.defaultValue as List<double>;
    // was 250 px from the left = 250 px left of the middle; the middle is now at 1000.
    expect(a[0] * 2000, closeTo(750, 1e-9));
    expect(a[1], closeTo(0.5, 1e-9));
    // half the size both ways: half everything.
    refitProjectEvenly(project, 2000, 1000, 1000, 500);
    expect(r.content.size, [50.0, 50.0]);
  });
}
