import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  late AppState app;
  setUp(() {
    app = AppState();
    app.project.layers.clear();
  });
  tearDown(() => app.dispose());

  Layer add(String id, {String? folder}) {
    final l = createLayer('rect')
      ..id = id
      ..durationFrames = 40
      ..folder = folder;
    app.project.layers.add(l);
    return l;
  }

  test('a folder deleted: its layers stay, out of it; or go with it', () {
    final a = add('A', folder: 'F'), b = add('B', folder: 'F');
    add('C');
    app.deleteFolder('F');
    expect([a.folder, b.folder], [null, null]);
    expect(app.project.layers.length, 3);
    a.folder = 'G';
    b.folder = 'G';
    app.moveFolderLayers('G', 'H');
    expect([a.folder, b.folder], ['H', 'H']);
    app.deleteFolder('H', withLayers: true);
    expect(app.project.layers.map((l) => l.id), ['C']);
  });
}
