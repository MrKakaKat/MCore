import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  test('a confirmed shape can be edited again: the old shape and its effect come back', () {
    final l = createLayer('rect', size: 100);
    final inst = createEffectInstance('corner_pin', 'fx1', l);
    l.effectStack.add(inst);
    recordConfirm(l, inst, 'Corner pin', 0);
    // what a confirm does: the shape becomes a polygon, the effect goes.
    l.content = Content(shape: 'polygon', points: [[0.0, 0.0], [10.0, 0.0], [0.0, 10.0]], offset: [0, 0], size: [10, 10]);
    l.effectStack.clear();
    final saved = layerFromJson(layerToJson(l));
    expect(saved.confirmHistory, hasLength(1));
    resumeConfirm(saved, 0);
    expect(saved.content.shape, 'rect');
    expect(saved.effectStack.single.effectId, 'corner_pin');
    expect(saved.confirmHistory, isEmpty);
  });
}
