import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';

/// Real, run coverage of AppState.moveLayer - the shared primitive behind both
/// the Layers tab's ReorderableListView and the timeline's new
/// fixed-right-edge drag handles.
void main() {
  test('moveLayer moves a layer up (toward the front/last index)', () {
    final app = AppState();
    app.addLayer('rect');
    app.addLayer('rect');
    final ids = app.project.layers.map((l) => l.id).toList();
    final expected = List<String>.from(ids)
      ..removeAt(0)
      ..insert(2, ids[0]);

    app.moveLayer(ids[0], 2);

    expect(app.project.layers.map((l) => l.id).toList(), equals(expected));
  });

  test('moveLayer moves a layer down (toward the back/first index)', () {
    final app = AppState();
    app.addLayer('rect');
    app.addLayer('rect');
    final ids = app.project.layers.map((l) => l.id).toList();
    final last = ids.last;
    final expected = List<String>.from(ids)
      ..remove(last)
      ..insert(0, last);

    app.moveLayer(last, 0);

    expect(app.project.layers.map((l) => l.id).toList(), equals(expected));
  });

  test('moveLayer to index 0 (bottom boundary)', () {
    final app = AppState();
    app.addLayer('rect');
    final ids = app.project.layers.map((l) => l.id).toList();

    app.moveLayer(ids[1], 0);

    expect(app.project.layers.first.id, equals(ids[1]));
  });

  test('moveLayer to the last index (top/front boundary)', () {
    final app = AppState();
    app.addLayer('rect');
    final ids = app.project.layers.map((l) => l.id).toList();

    app.moveLayer(ids[0], ids.length - 1);

    expect(app.project.layers.last.id, equals(ids[0]));
  });

  test('moveLayer is a no-op when newIndex equals the current index', () {
    final app = AppState();
    app.addLayer('rect');
    final before = app.project.layers.map((l) => l.id).toList();

    app.moveLayer(before[0], 0);

    expect(app.project.layers.map((l) => l.id).toList(), equals(before));
  });

  test('moveLayer is a no-op for an unknown id', () {
    final app = AppState();
    final before = app.project.layers.map((l) => l.id).toList();

    app.moveLayer('not-a-real-id', 0);

    expect(app.project.layers.map((l) => l.id).toList(), equals(before));
  });

  test('a single undo() call fully reverts a reorder', () {
    final app = AppState();
    app.addLayer('rect');
    final before = app.project.layers.map((l) => l.id).toList();

    app.moveLayer(before[0], before.length - 1);
    expect(app.project.layers.map((l) => l.id).toList(), isNot(equals(before)));

    app.undo.undo(app.project, app.selection);

    expect(app.project.layers.map((l) => l.id).toList(), equals(before));
  });
}
