import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

/// Bend's "base" height: where along the object the bend starts.
void main() {
  setUpAll(registerBuiltinEffects);

  // a 1-column strip, x = 0, y from 0 (top) to 100 (bottom).
  final grid = [
    for (var y = 0; y <= 100; y += 25) [<double>[0, y.toDouble()]]
  ];
  List<List<List<double>>> bend(double angle, double base) =>
      effectRegistry['bend_arc']!.apply(grid, {'angle': angle, 'baseAxis': 'bottom', 'base': base}, 0);

  test('base 0 bends from the edge (the original behaviour): only the base point stays put', () {
    final out = bend(90, 0);
    expect(out.last.single, equals([0.0, 100.0]));
    expect(out[3].single[0], isNot(closeTo(0, 1e-6)));
  });

  test('points between the base edge and the base line stay rigid', () {
    final out = bend(90, 0.5); // base line at y = 50
    expect(out[4].single, equals([0.0, 100.0]));
    expect(out[3].single[0], closeTo(0, 1e-9));
    expect(out[3].single[1], closeTo(75, 1e-9));
    expect(out[2].single[0], closeTo(0, 1e-9), reason: 'the base line itself');
    expect(out[0].single[0], isNot(closeTo(0, 1e-6)), reason: 'the top still bends');
  });
}
