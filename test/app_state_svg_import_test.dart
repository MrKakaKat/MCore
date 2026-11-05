import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

/// Real, run coverage of AppState.importSvgLayers - createLayer/
/// addImageLayer's sibling for SVG import (see add_layer_dialog.dart's
/// own "Import SVG..." UI entry point, which hands this the layers
/// already parsed by movement_core's own importShapesFromSvg).
void main() {
  test('importSvgLayers appends every parsed layer, selects the last one, and pushes an undo state', () {
    final app = AppState();
    final before = app.project.layers.length;

    final result = importShapesFromSvg('<svg><rect x="0" y="0" width="10" height="10"/><circle cx="50" cy="50" r="5"/></svg>');
    expect(result.errors, isEmpty);
    expect(result.layers, hasLength(2));

    app.importSvgLayers(result.layers);

    expect(app.project.layers.length, equals(before + 2));
    expect(app.selection.selectedLayer, equals(result.layers.last.id));

    app.undo.undo(app.project, app.selection);
    expect(app.project.layers.length, equals(before));
  });

  test('importSvgLayers is a no-op for an empty list (every element failed to import)', () {
    final app = AppState();
    final before = app.project.layers.length;
    final beforeSelection = app.selection.selectedLayer;

    app.importSvgLayers(const []);

    expect(app.project.layers.length, equals(before));
    expect(app.selection.selectedLayer, equals(beforeSelection));
  });
}
