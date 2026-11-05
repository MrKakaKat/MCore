import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  test('Roll: a preset with the roll property; static holds one pose; it saves', () {
    final a = textAnimatorPreset('Roll');
    expect(a.props.containsKey('roll'), isTrue);
    a
      ..liveStatic = true
      ..liveStaticAt = 1.5;
    final back = TextAnimator.fromJson(a.toJson());
    expect(back.liveStatic, isTrue);
    expect(back.liveStaticAt, 1.5);
    expect(back.props.containsKey('roll'), isTrue);
  });
}
