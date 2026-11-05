import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  test('harmonies turn round the colour wheel; the colour itself comes first', () {
    expect(harmonyColors('#ff0000', 'complementary'), ['#ff0000', '#00ffff']);
    expect(harmonyColors('#ff0000', 'triadic'), ['#ff0000', '#00ff00', '#0000ff']);
    expect(harmonyColors('#336699', 'monochrome'), hasLength(6));
    expect(harmonyColors('#336699', 'tetradic'), hasLength(4));
  });
}
