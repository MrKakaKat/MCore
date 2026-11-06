import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('every toggle switches, wherever it is kept (per app or per project)', () {
    final app = AppState();
    for (final name in ['placeOnStage', 'mirrorMovesLayer', 'lineHandlesMirrored', 'scaleKeepsOppositeEdge', 'showRegionTints']) {
      final before = app.appPreference(name);
      app.setAppPreference(name, !before);
      expect(app.appPreference(name), !before, reason: name);
      app.setAppPreference(name, before);
    }
    expect(lineHandlesMirrored, isTrue);
  });

  test('mirroring a line flips its points, not a picture of it', () {
    final app = AppState();
    app.addLayer('line');
    final l = app.project.layers.last;
    app.selection.selectedLayer = l.id;
    final x0 = l.content.lineNodes!.first.x;
    app.toggleMirror(horizontal: true);
    expect(l.mirrorX, isFalse);
    expect(l.content.lineNodes!.first.x, isNot(x0));
  });
}
