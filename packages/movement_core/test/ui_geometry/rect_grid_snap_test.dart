import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(registerBuiltinEffects);
  test("a centre snaps onto a crossing of a rect's own grid", () {
    stageSize.width = 480;
    stageSize.height = 480;
    final project = Project(fps: 30);
    final big = createLayer('rect', size: 300)
      ..content.gridCols = 3
      ..content.gridRows = 3;
    final dot = createLayer('circle', size: 10);
    project.layers.addAll([big, dot]);
    clearStateCaches();
    final pts = rectGridCrossingsFrame(project, big, 0);
    expect(pts, hasLength(4));
    final target = pts.first;
    snapEnabled = true;
    snapCenterToCenterEnabled = true;
    snapCenterToCenterFrameRadius = 8;
    final r = computeAnchorSnap(
        project: project,
        layer: dot,
        globalFrame: 0,
        newLocal: [(target[0] + 3) / 480, (target[1] - 2) / 480]);
    expect(r.newLocal[0] * 480, closeTo(target[0], 1e-6));
    expect(r.newLocal[1] * 480, closeTo(target[1], 1e-6));
    snapEnabled = false;
  });
}
