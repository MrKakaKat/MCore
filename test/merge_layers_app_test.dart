import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('merging is one undo step and selects the new layer', () {
    final app = AppState();
    app.addLayer('rect');
    app.addLayer('circle');
    final ids = [for (final l in app.project.layers) l.id];
    expect(app.mergeLayersById(ids), isTrue);
    expect(app.project.layers, hasLength(1));
    expect(app.selection.selectedLayer, app.project.layers.single.id);
    app.performUndo();
    expect(app.project.layers.map((l) => l.id), ids);
  });
}
