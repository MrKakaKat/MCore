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

  test('SVG keeps the crop, detached cuts, filters and pictures as vectors / elements', () {
    final r = createLayer('rect', size: 100)..crop = [0.25, 0, 0, 0];
    r.pieceClips.add(PieceClip(points: [[0, 0], [50, 0], [50, 50]], inside: false));
    final f = createLayer('rect', size: 50)
      ..filters.negative = Track(1.0, false)
      ..filters.blur = Track(6.0, false)
      ..filters.warp = Track(10.0, false);
    final img = createImageLayer(imageSourceType: 'embedded', imageData: 'iVBORw0KGgo=', naturalWidth: 10, naturalHeight: 10);
    final p = Project(layers: [r, f, img]);
    final svg = exportProjectToSvg(p, 0, 400, 400, mediaHref: (l) => 'data:image/png;base64,${l.content.imageData}');
    // the crop: a clip from 25% in (x -25 of a 100 wide box at 0).
    expect(svg, contains('<clipPath id="cut-${r.id}-0"><path d="M-25 -50L50 -50L50 50L-25 50Z"/>'));
    expect(svg, contains('clip-rule="evenodd"'));
    expect(svg, contains('<feColorMatrix type="matrix" values="-1 0 0 0 1'));
    expect(svg, contains('<feGaussianBlur stdDeviation="3"/>'));
    expect(svg, contains('<feTurbulence'));
    expect(svg, contains('<image '));
    expect(svg, contains('href="data:image/png;base64,iVBORw0KGgo="'));
    // without a way to its bytes, a picture is left out.
    expect(exportProjectToSvg(p, 0, 400, 400), isNot(contains('<image ')));
    final anim = exportProjectToAnimatedSvg(p, 0, 2, 30, 400, 400, mediaHref: (l) => 'x');
    expect(anim, contains('<clipPath id="cut-${r.id}-a-0">'));
    expect(anim, contains('<image '));
  });
}
