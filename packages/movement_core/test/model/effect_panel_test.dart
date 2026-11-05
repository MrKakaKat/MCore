import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Layer _layer() => Layer(
      id: 'L_fx',
      name: 'fx',
      transform: Transform(
          anchor: track([0.5, 0.5], true), scale: track([1.0, 1.0]), rotation: track(0.0), opacity: track(1.0)),
      content: Content(shape: 'rect', offset: [0, 0], size: [40, 20]),
    );

void main() {
  setUpAll(registerBuiltinEffects);

  test('the list is the effect stack plus enabled motion add-ons', () {
    final l = _layer();
    l.effectStack.addAll([createEffectInstance('bend_arc', 'a', l), createEffectInstance('rotate_3d', 'b', l)]);
    expect(effectPanelEntries(l), ['a', 'b']);
    addMotionPanelEntry(l, 'wiggle');
    expect(l.wiggle.enabled, isTrue);
    expect(effectPanelEntries(l), ['a', 'b', 'wiggle']);
  });

  test('reordering keeps motion anywhere and re-sorts the geometry stack', () {
    final l = _layer();
    l.effectStack.addAll([createEffectInstance('bend_arc', 'a', l), createEffectInstance('rotate_3d', 'b', l)]);
    addMotionPanelEntry(l, 'pendulum');
    reorderEffectPanel(l, 2, 0); // pendulum to the top
    expect(effectPanelEntries(l), ['pendulum', 'a', 'b']);
    reorderEffectPanel(l, 2, 1); // b above a
    expect(effectPanelEntries(l), ['pendulum', 'b', 'a']);
    expect(l.effectStack.map((i) => i.id), ['b', 'a']);
  });

  test('removing a motion add-on turns it off, resets it and drops it from the list', () {
    final l = _layer();
    addMotionPanelEntry(l, 'motionBlur');
    l.motionBlur.shutterAngle = 90;
    removeMotionPanelEntry(l, 'motionBlur');
    expect(l.motionBlur.enabled, isFalse);
    expect(l.motionBlur.shutterAngle, MotionBlur().shutterAngle);
    expect(effectPanelEntries(l), isEmpty);
  });

  test('the order survives JSON', () {
    final l = _layer()..effectPanelOrder = ['wiggle', 'a'];
    expect(layerFromJson(layerToJson(l)).effectPanelOrder, ['wiggle', 'a']);
  });
}
