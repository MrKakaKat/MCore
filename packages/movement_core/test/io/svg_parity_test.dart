import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    registerBuiltinEffects();
    setStageSize(400, 400);
    clearStateCaches();
  });

  test('SVG: shadow, glow, rounded polygon, folded paper and the stage camera, as on the stage', () {
    final sh = createLayer('rect', size: 50)..fill.shadow.enabled = true;
    final g = createLayer('rect', size: 50)..fill.gradient = true;
    g.fill.glows.add(GlowEmitter(id: 'g1'));
    final tri = createLayer('triangle', size: 60)..fill.cornerRadius = 10;
    final fold = createLayer('rect', size: 60);
    fold.effectStack.add(createEffectInstance('origami_fold', 'o', fold)..params['angle'] = track(180.0));
    final cam = createLayer('rect', size: 100)..content.shape = 'camera';
    cam.content.size = [200, 200];
    final p = Project(layers: [sh, g, tri, fold, cam]);
    final svg = exportProjectToSvg(p, 0, 400, 400);
    expect(svg, contains('opacity="0.6"'), reason: 'the shadow');
    expect(svg, contains('<radialGradient'), reason: 'the glow');
    expect(svg, contains('fill-rule="nonzero"'), reason: 'folded pieces add up');
    // the camera shows a 200 px box on 400 px: everything twice as big.
    expect(svg, contains('<g transform="matrix(2,0,0,2,'));
    final anim = exportProjectToAnimatedSvg(p, 0, 2, 30, 400, 400);
    expect(anim, contains('<radialGradient'));
    expect(anim, contains('<g transform="matrix(2,0,0,2,'));
  });
}
