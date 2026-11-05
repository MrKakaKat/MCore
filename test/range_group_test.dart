import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('turning the range on keeps the selected layer; its edge buttons undo', () {
    final app = AppState();
    final sel = app.selection.selectedLayer;
    expect(sel, isNotNull);
    app.setTimeRangeEnabled(true);
    expect(app.selection.selectedLayer, sel);
    final before = app.timeRange;
    app.setFrame(app.timeRange!.b + 20);
    app.setTimeRangeEdge(start: false);
    expect(app.timeRange, isNot(before));
    app.performUndo();
    expect(app.timeRange, before);
  });

  test('dragging the range slides only the range (layers stay), one undo step', () {
    final app = AppState();
    final l = app.project.layers.first;
    final start = l.startFrame;
    app.setTimeRangeEnabled(true);
    final r = app.timeRange!;
    app.beginRangeMove();
    app.updateRangeMove(15);
    app.endRangeMove();
    expect(l.startFrame, start, reason: 'the layers stay');
    expect(app.timeRange, (a: r.a + 15, b: r.b + 15));
    app.performUndo();
    expect(app.project.layers.first.startFrame, start);
    expect(app.timeRange, r);
  });

  test('deleting every layer puts the playhead at 0', () {
    final app = AppState();
    app.setFrame(63);
    for (final l in [...app.project.layers]) {
      app.deleteLayerById(l.id);
    }
    expect(app.currentFrame, 0);
  });

  test('trimming the range undoes', () {
    final app = AppState();
    app.timeRange = (a: 20, b: 60);
    app.rangeEdit((a, b) => trimLayersToRange(app.project, a, b));
    expect(app.project.layers.first.startFrame, 20);
    app.performUndo();
    expect(app.project.layers.first.startFrame, 0);
  });

  test('an effect on every layer in the range, only inside it', () {
    final app = AppState();
    app.timeRange = (a: 20, b: 60);
    final n = app.rangeAddEffect(effectRegistry.keys.first);
    expect(n, app.project.layers.length);
    final l = app.project.layers.first;
    expect(l.effectRanges[l.effectStack.last.id], [20 - l.startFrame, 60 - l.startFrame]);
  });

  test('a group trims together', () {
    final app = AppState();
    app.addLayer('circle');
    final a = app.project.layers[0], b = app.project.layers[1];
    app.selectLayer(a.id);
    app.toggleMultiSelect(b.id);
    final bEnd = b.startFrame + b.durationFrames;
    app.beginLayerDrag(a.id, LayerDragMode.trimRight);
    app.updateLayerDrag(-30);
    app.endLayerDrag();
    expect(b.startFrame + b.durationFrames, bEnd - 30);
  });

  test('a group moves rows together', () {
    final app = AppState();
    app.addLayer('circle');
    app.addLayer('triangle');
    final ids = [app.project.layers[0].id, app.project.layers[1].id];
    int rowOf(String id) => timelineRows(app.project).indexWhere((r) => r.any((l) => l.id == id));
    final before = [for (final id in ids) rowOf(id)];
    app.moveGroupRows(ids, 1);
    expect([for (final id in ids) rowOf(id)], isNot(before));
    app.performUndo();
    expect([for (final id in ids) rowOf(id)], before);
  });

  test('a mask added over the range works only inside it, and is saved', () {
    final app = AppState();
    app.addLayer('circle');
    final a = app.project.layers[0], src = app.project.layers[1];
    app.timeRange = (a: 20, b: 60);
    app.rangeAddMask(src.id);
    final m = a.masks.single;
    expect(m.range, [20 - a.startFrame, 60 - a.startFrame]);
    expect(m.activeAt(10), isFalse);
    expect(m.activeAt(30), isTrue);
    expect(maskFromJson(maskToJson(m)).range, m.range);
  });

  test('a null is a point with a square: its corner grows the square, not the point', () {
    final app = AppState();
    app.addLayer('null');
    final n = app.project.layers.last;
    final tb = getTransformBoxHandles(app.project, n, 0);
    expect(tb.bbox.maxX - tb.bbox.minX, n.content.size[0], reason: 'its square is its size');
    final scale = List.of(n.transform.scale.defaultValue as List);
    final far = tb.screen['scaleCorner']!;
    NullSizeDragOp(layer: n).apply(app.project, 0, [far[0] - 20, far[1] - 20]);
    expect(n.content.size[0], greaterThan(tb.bbox.maxX - tb.bbox.minX));
    expect(n.transform.scale.defaultValue, scale);
    expect(n.name, 'Null 1');
  });

  test('a line is a long thin vector shape', () {
    final app = AppState();
    app.addLayer('line');
    final l = app.project.layers.last;
    expect(l.content.size[0], greaterThan(l.content.size[1] * 10));
    expect(isRectLikeShape('line'), isTrue);
    expect(l.name, 'Line 1');
  });
}
