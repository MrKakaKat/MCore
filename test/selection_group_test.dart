import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('layers selected together move together on the stage and the timeline', () {
    final app = AppState();
    app.addLayer('rect');
    app.addLayer('circle');
    final a = app.project.layers[0], b = app.project.layers[1];
    app.selectLayer(a.id);
    app.toggleMultiSelect(b.id);
    expect(app.selectedGroup, {a.id, b.id});

    final bAnchor = [...b.transform.anchor.defaultValue as List<double>];
    app.beginGroupTransform();
    setTrackValueAt(a.transform.anchor, 0, [0.6, 0.5]);
    app.applyGroupTransform();
    app.endGroupTransform();
    final moved = evaluateTrack(app.project, b.transform.anchor, 0) as List<double>;
    expect(moved[0], closeTo(bAnchor[0] + 0.1, 1e-9));

    final bStart = b.startFrame, aStart = a.startFrame;
    app.beginLayerDrag(b.id, LayerDragMode.move);
    app.updateLayerDrag(5);
    app.endLayerDrag();
    expect(app.selectedGroup, {a.id, b.id}, reason: 'dragging another of the group keeps it');
    expect([a.startFrame, b.startFrame], [aStart + 5, bStart + 5]);

    app.selectLayer(b.id);
    expect(app.selectedGroup, {b.id}, reason: 'a plain tap selects one again');
  });

  test('a group resize keeps its shape: each one moves round the middle', () {
    final app = AppState()..project.layers.clear();
    app.addLayer('rect');
    app.addLayer('rect');
    final a = app.project.layers[0], b = app.project.layers[1];
    setTrackValueAt(a.transform.anchor, 0, [0.4, 0.5]);
    setTrackValueAt(b.transform.anchor, 0, [0.6, 0.5]);
    app.selectLayer(a.id);
    app.toggleMultiSelect(b.id);
    app.beginGroupTransform();
    setTrackValueAt(a.transform.scale, 0, [2.0, 2.0]);
    app.applyGroupTransform();
    app.endGroupTransform();
    final pa = evaluateTrack(app.project, a.transform.anchor, 0) as List<double>;
    final pb = evaluateTrack(app.project, b.transform.anchor, 0) as List<double>;
    expect(pa[0], closeTo(0.3, 1e-9));
    expect(pb[0], closeTo(0.7, 1e-9));
    expect((evaluateTrack(app.project, b.transform.scale, 0) as List<double>)[0], closeTo(2, 1e-9));

    // off: each stays on its spot.
    app.groupKeepsShape = false;
    app.beginGroupTransform();
    setTrackValueAt(a.transform.scale, 0, [1.0, 1.0]);
    app.applyGroupTransform();
    app.endGroupTransform();
    expect((evaluateTrack(app.project, b.transform.anchor, 0) as List<double>)[0], closeTo(0.7, 1e-9));
  });

  test('the selection rectangle picks the layers under it, leaving out the skipped kinds', () {
    final app = AppState()..project.layers.clear();
    app.addLayer('rect');
    app.addLayer('circle');
    final a = app.project.layers[0], b = app.project.layers[1];
    setTrackValueAt(a.transform.anchor, 0, [0.2, 0.5]);
    setTrackValueAt(b.transform.anchor, 0, [0.8, 0.5]);
    app.commitEdit();
    final w = stageSize.width, h = stageSize.height;
    app.selectInRect(0, 0, w, h);
    expect(app.selectedGroup, {a.id, b.id});
    app.selectInRect(0, 0, w * 0.4, h);
    expect(app.selectedGroup, {a.id});
    app.marqueeSkip = {'rect'};
    app.selectInRect(0, 0, w, h);
    expect(app.selectedGroup, {b.id});
  });

  test('picking a parent\'s children: taps in, taps out, done links them where they are', () {
    final app = AppState()..project.layers.clear();
    app.addLayer('rect');
    app.addLayer('circle');
    app.addLayer('triangle');
    final p = app.project.layers[0], a = app.project.layers[1], b = app.project.layers[2];
    app.startParentPick(p.id);
    app.toggleParentPick(a.id);
    app.toggleParentPick(b.id);
    app.toggleParentPick(b.id);
    app.toggleParentPick(p.id); // never itself
    expect(app.parentPicked, {a.id});
    app.finishParentPick();
    expect(a.parentId, p.id);
    expect(b.parentId, isNull);
    expect(app.parentPickFor, isNull);
    // a child can't become the parent of its parent.
    app.startParentPick(a.id);
    app.toggleParentPick(p.id);
    expect(app.parentPicked, isEmpty);
    app.finishParentPick(apply: false);
  });

  test('several texts selected: a style change goes to all of them, the words stay each its own', () {
    final app = AppState()..project.layers.clear();
    app.addTextLayer();
    app.addTextLayer();
    final a = app.project.layers[0], b = app.project.layers[1];
    app.selectLayer(a.id);
    app.toggleMultiSelect(b.id);
    app.editTextAll(a.id, (t) => t.fontSize = 77);
    expect(a.content.text!.fontSize, 77);
    expect(b.content.text!.fontSize, 77);
    app.selectLayer(a.id);
    app.editTextAll(a.id, (t) => t.fontSize = 20);
    expect(b.content.text!.fontSize, 77, reason: 'alone again: only it');
  });

  test('a shape drawn on the stage takes the dragged box; a line goes from start to end', () {
    final app = AppState()..project.layers.clear();
    app.startPlacing('rect');
    app.placeShapeIn([100, 50], [300, 150]);
    final r = app.project.layers.last;
    expect(r.content.size, [200.0, 100.0]);
    final b = layerFrameBounds(app.project, r, app.currentFrame)!;
    expect(b.$1, closeTo(100, 1e-6));
    expect(b.$4, closeTo(150, 1e-6));
    app.startPlacing('line');
    app.placeShapeIn([10, 10], [110, 10]);
    final l = app.project.layers.last;
    final pts = lineFramePoints(app.project, l, app.currentFrame);
    expect(pts.first[0], closeTo(10, 1e-6));
    expect(pts.last[0], closeTo(110, 1e-6));
    expect(app.lineTapAdd, isTrue);
  });
}
