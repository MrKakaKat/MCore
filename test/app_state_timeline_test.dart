import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

/// Real, run coverage of AppState's timeline-length controls - both the real
/// bug fix (dragging a layer shorter never shrunk maxFrame back) and the new
/// direct control, plus moveSelectedLayerToFrame ("move to frame" for the
/// selected layer, as opposed to the existing "go to frame" for the playhead).
void main() {
  test('shortening the timeline trims layers to the new end; it stays short; one undo restores', () {
    final app = AppState();
    app.project.layers.clear();
    app.addLayer('rect');
    app.addLayer('circle');
    final a = app.project.layers[0]..startFrame = 0..durationFrames = 200;
    final b = app.project.layers[1]..startFrame = 150..durationFrames = 100;
    app.commitEdit();
    app.setMaxFrame(90); // 1.5 s
    expect(a.startFrame + a.durationFrames, 90);
    expect(b.startFrame + b.durationFrames, lessThanOrEqualTo(90), reason: 'a layer wholly past the end ends there');
    expect(b.durationFrames, 90);
    app.addLayer('triangle'); // refits the timeline
    expect(app.maxFrame, 90, reason: 'nothing grows it back');
    app.performUndo(); // the triangle
    app.performUndo(); // the trim
    expect(app.project.layers.map((l) => l.startFrame + l.durationFrames), [200, 250]);
  });

  test('setMaxFrame sets the timeline length directly and becomes the new floor', () {
    final app = AppState();
    app.setMaxFrame(300);
    expect(app.maxFrame, equals(300));
  });

  test('setMaxFrame is authoritative even when a layer extends past the requested value (real bug: it used to silently snap back to fit instead)', () {
    final app = AppState();
    final layer = app.project.layers.last;
    layer.startFrame = 500;
    layer.durationFrames = 100; // end = 600

    // setMaxFrame used to re-run recomputeMaxFrameToFit(clamped), i.e.
    // max(clamped, furthest layer extent + 1s) - so a value smaller than
    // existing content silently snapped back to the larger number, with zero
    // feedback. The typed value is now authoritative: it's what maxFrame
    // actually becomes, full stop (a layer that no longer fits is a disclosed,
    // deliberate consequence of the explicit choice, not something this call
    // silently overrides).
    app.setMaxFrame(50); // far shorter than what the layer actually needs
    expect(app.maxFrame, equals(50));
  });

  // setMaxFrame's own floor persisting through a later drag is already
  // covered below by 'endLayerDrag never shrinks the timeline below a
  // floor the user explicitly set via setMaxFrame' - now doubly true
  // since updateLayerDrag's own live recompute (not just endLayerDrag's)
  // respects that same floor.

  test('setMaxFrame clamps the playhead if it now sits past the new (shorter) length', () {
    final app = AppState();
    // recomputeMaxFrameToFit always adds fps worth of headroom on top of
    // the furthest layer end, so shrink both default layers down first
    // and request a floor comfortably above that headroom (200 >> 10 +
    // fps) - otherwise the headroom itself would silently win over a
    // too-small requested floor, independent of this test's own point.
    for (final l in app.project.layers) {
      l.startFrame = 0;
      l.durationFrames = 10;
    }
    app.currentFrame = 500; // direct assignment - setFrame() would clamp to the OLD maxFrame (180) first
    app.setMaxFrame(200);
    expect(app.maxFrame, equals(200));
    expect(app.currentFrame, equals(200));
  });

  test('dragging a layer shorter shrinks maxFrame back down LIVE, not only once the drag ends', () {
    final app = AppState();
    // both default layers, not just the one being dragged - otherwise
    // the OTHER layer's own untouched default duration (180) would set
    // its own floor via recomputeMaxFrameToFit, masking the actual
    // shrink behavior this test means to check.
    for (final l in app.project.layers) {
      l.startFrame = 0;
      l.durationFrames = 10;
    }
    final layer = app.project.layers.last;

    app.beginLayerDrag(layer.id, LayerDragMode.trimRight);
    app.updateLayerDrag(500); // extends duration -> grows the timeline live
    expect(app.maxFrame, greaterThan(180));

    // growing a layer live-extended the timeline, but shrinking used to only
    // contract it once the drag was released - updateLayerDrag now calls the
    // shrink-capable recomputeMaxFrameToFit on every move, so shrinking is
    // equally live, no "confirm" step needed.
    app.updateLayerDrag(-490); // cumulative from the grab point -> duration snaps back down
    expect(app.maxFrame, equals(10),
        reason: 'shrinking must be live too, symmetric with growing - no need to release the drag first');

    app.endLayerDrag();
    expect(app.maxFrame, equals(10));
  });

  test('a live drag never shrinks the timeline below a floor the user explicitly set via setMaxFrame', () {
    final app = AppState();
    app.setMaxFrame(400); // explicit, larger-than-needed length

    final layer = app.project.layers.last;
    layer.startFrame = 0;
    layer.durationFrames = 10; // needs far less than 400

    app.beginLayerDrag(layer.id, LayerDragMode.move);
    app.updateLayerDrag(5);
    // the live recompute inside updateLayerDrag itself (not just
    // endLayerDrag's, now removed) must also respect this floor.
    expect(app.maxFrame, equals(400),
        reason: 'the user\'s own explicit timeline length must survive a LIVE drag that needs less space');
    app.endLayerDrag();

    expect(app.maxFrame, equals(400),
        reason: 'the user\'s own explicit timeline length must survive a layer drag that needs less space');
  });

  test('moveSelectedLayerToFrame moves the selected layer to an arbitrary frame, unbounded', () {
    final app = AppState();
    final layer = app.project.layers.last;
    app.selectLayer(layer.id);

    app.moveSelectedLayerToFrame(75);
    expect(layer.startFrame, equals(75));
  });

  test('moveSelectedLayerToFrame grows the timeline to fit, same as a drag would', () {
    final app = AppState();
    final layer = app.project.layers.last;
    app.selectLayer(layer.id);

    app.moveSelectedLayerToFrame(1000);
    expect(app.maxFrame, greaterThan(1000));
  });

  test('moveSelectedLayerToFrame clamps at 0, never negative', () {
    final app = AppState();
    final layer = app.project.layers.last;
    app.selectLayer(layer.id);

    app.moveSelectedLayerToFrame(-50);
    expect(layer.startFrame, equals(0));
  });

  test('moveSelectedLayerToFrame is a no-op with nothing selected', () {
    final app = AppState();
    app.selectLayer(null);
    final before = app.project.layers.map((l) => l.startFrame).toList();

    app.moveSelectedLayerToFrame(42);
    expect(app.project.layers.map((l) => l.startFrame).toList(), equals(before));
  });

  test('snapTimelineLayersEnabled off (default): updateLayerDrag never snaps to another layer\'s edge', () {
    final app = AppState();
    final layers = app.project.layers;
    layers[0].startFrame = 0;
    layers[0].durationFrames = 50; // other layer's end = 50
    final moved = layers[1];
    moved.startFrame = 60;
    moved.durationFrames = 20;

    app.beginLayerDrag(moved.id, LayerDragMode.move);
    app.updateLayerDrag(-6); // would land at startFrame=54, 4 frames from the other layer's end
    expect(moved.startFrame, equals(54),
        reason: 'snapping is off by default - must not silently move the layer past the raw drag delta');
  });

  test('snapTimelineLayersEnabled on: a move-drag near another layer\'s edge snaps to it', () {
    final app = AppState();
    app.toggleSnapTimelineLayers();
    final layers = app.project.layers;
    layers[0].startFrame = 0;
    layers[0].durationFrames = 50; // other layer's end = 50
    final moved = layers[1];
    moved.startFrame = 60;
    moved.durationFrames = 20;

    app.beginLayerDrag(moved.id, LayerDragMode.move);
    app.updateLayerDrag(-6); // drags to startFrame=54, within the 6-frame snap threshold of 50
    expect(moved.startFrame, equals(50));
  });

  test('the timeline fits the layers - no 3-second default floor past a shorter layer', () {
    final app = AppState();
    for (final l in app.project.layers) {
      l.startFrame = 0;
      l.durationFrames = 120;
    }
    app.addLayer('rect'); // any layer-list change refits
    final added = app.project.layers.last;
    app.deleteLayerById(added.id);
    expect(app.maxFrame, equals(120));
  });

  test('deleting the longest layer shrinks the timeline; undo grows it back', () {
    final app = AppState();
    final a = app.project.layers.first, b = app.project.layers.last;
    a.startFrame = 0;
    a.durationFrames = 50;
    b.startFrame = 0;
    b.durationFrames = 150;
    app.deleteLayerById(b.id);
    expect(app.maxFrame, equals(50));
    app.performUndo();
    expect(app.maxFrame, equals(150));
  });

  test('an explicit timeline length still acts as the floor after a refit', () {
    final app = AppState();
    for (final l in app.project.layers) {
      l.durationFrames = 10;
      l.startFrame = 0;
    }
    app.setMaxFrame(400);
    app.addLayer('rect');
    expect(app.maxFrame, equals(400));
  });
}
