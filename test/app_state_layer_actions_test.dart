import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';

/// Real, run coverage of the Layers-tab reconstruction's new per-layer
/// actions - duplicate (new) and deleteLayerById (deleteSelected's
/// sibling, parametrized by an explicit id instead of always reading
/// the current selection).
void main() {
  test('duplicateLayer inserts a clone right after the source, with a new id and name, and selects it', () {
    final app = AppState();
    final src = app.project.layers.last;
    final before = app.project.layers.length;

    app.duplicateLayer(src.id);

    expect(app.project.layers.length, equals(before + 1));
    final srcIdx = app.project.layers.indexWhere((l) => l.id == src.id);
    final clone = app.project.layers[srcIdx + 1];
    expect(clone.id, isNot(equals(src.id)));
    expect(clone.name, equals('${src.name}_copy'));
    expect(clone.content.shape, equals(src.content.shape));
    expect(app.selection.selectedLayer, equals(clone.id));
  });

  test('duplicateLayer preserves the source layer\'s own fields (a real deep copy, not a shared reference)', () {
    final app = AppState();
    final src = app.project.layers.last;
    src.startFrame = 42;
    src.color = '#abcdef';

    app.duplicateLayer(src.id);
    final clone = app.project.layers.firstWhere((l) => l.name == '${src.name}_copy');

    expect(clone.startFrame, equals(42));
    expect(clone.color, equals('#abcdef'));

    // mutating the clone afterward must not affect the source - proves
    // it's a real deep copy, not the same underlying object.
    clone.startFrame = 999;
    expect(src.startFrame, equals(42));
  });

  test('duplicateLayer is a no-op for an unknown id', () {
    final app = AppState();
    final before = app.project.layers.length;
    app.duplicateLayer('not-a-real-id');
    expect(app.project.layers.length, equals(before));
  });

  test('duplicateLayer pushes an undo state, so the duplication can be undone', () {
    final app = AppState();
    final src = app.project.layers.last;
    final before = app.project.layers.length;

    app.duplicateLayer(src.id);
    expect(app.project.layers.length, equals(before + 1));

    app.undo.undo(app.project, app.selection);
    expect(app.project.layers.length, equals(before));
  });

  test('deleteLayerById removes exactly that layer, whether or not it was selected', () {
    final app = AppState();
    final layers = app.project.layers.toList();
    final toDelete = layers.first; // NOT the one selectLayer defaults to (the last one)
    app.selectLayer(layers.last.id);
    expect(app.selection.selectedLayer, isNot(equals(toDelete.id)));

    app.deleteLayerById(toDelete.id);

    expect(app.project.layers.any((l) => l.id == toDelete.id), isFalse);
    expect(app.project.layers.length, equals(layers.length - 1));
  });

  test('deleteSelected is now a thin wrapper over deleteLayerById for the current selection', () {
    final app = AppState();
    final layer = app.project.layers.last;
    app.selectLayer(layer.id);
    final before = app.project.layers.length;

    app.deleteSelected();

    expect(app.project.layers.any((l) => l.id == layer.id), isFalse);
    expect(app.project.layers.length, equals(before - 1));
  });

  test('deleteSelected stays a no-op with nothing selected', () {
    final app = AppState();
    app.selectLayer(null);
    final before = app.project.layers.length;
    app.deleteSelected();
    expect(app.project.layers.length, equals(before));
  });
}
