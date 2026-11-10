import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

double area(List<List<List<double>>> rings) {
  var a = 0.0;
  for (final r in rings) {
    var s = 0.0;
    for (var i = 0; i < r.length; i++) {
      final p = r[i], q = r[(i + 1) % r.length];
      s += p[0] * q[1] - q[0] * p[1];
    }
    a += s / 2;
  }
  return a.abs();
}

void main() {
  test('fill takes what the stage shows: a cropped square fills its visible half, on top', () async {
    final app = AppState()..setFrameSize(200, 100);
    app.project.layers.clear();
    final sq = createLayer('rect')
      ..id = 'sq'
      ..color = '#000000'
      ..content.offset = [0, 0]
      ..content.size = [80, 80]
      ..transform.anchor.defaultValue = [0.5, 0.5]
      ..crop = [0.5, 0, 0, 0]; // the left half cut away
    final top = createLayer('rect')
      ..id = 'top'
      ..color = '#0000ff'
      ..content.size = [10, 10]
      ..transform.anchor.defaultValue = [0.05, 0.1];
    app.project.layers.addAll([sq, top]);
    app.fillBleed = false;
    // the visible half: x 100..140, y 10..90.
    final f = (await app.fillAt([120, 50]))!;
    expect(app.project.layers.last, same(f), reason: 'always on top');
    expect(area(f.content.contours!), closeTo(40 * 80, 60));
    final m = getLayerStateAt(app.project, f.id, 0).matrix;
    expect(m[4] * 200, closeTo(120, 1), reason: 'where it was tapped, the visible half');
    // where the crop took the square away: the background around it.
    final bg = (await app.fillAt([80, 50]))!;
    expect(area(bg.content.contours!), greaterThan(200 * 100 - 3200 - 100 - 400));
    expect(app.fillNotice.value, contains('filled'));
  });
}
