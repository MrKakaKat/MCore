import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

/// Random runs of edits (layers, folders, groups moved in time, splits):
/// undone all the way, the project is as it was; redone, as it was after.
void main() {
  String snap(AppState app) => jsonEncode(projectLayersToJson(app.project));

  for (var seed = 1; seed <= 25; seed++) {
    test('random edits undone and redone (seed $seed)', () {
      final r = math.Random(seed);
      final app = AppState();
      app.project.layers.clear();
      for (var i = 0; i < 3 + r.nextInt(4); i++) {
        app.project.layers.add(createLayer('rect')
          ..id = 'L$i'
          ..name = 'L$i'
          ..startFrame = r.nextInt(60)
          ..durationFrames = 10 + r.nextInt(60)
          ..folder = r.nextBool() ? ['F', 'G'][r.nextInt(2)] : null);
      }
      app.maxFrame = 300;
      final start = snap(app);
      final steps = 10 + r.nextInt(20);
      for (var s = 0; s < steps; s++) {
        final ls = app.project.layers;
        if (ls.isEmpty) break;
        final l = ls[r.nextInt(ls.length)];
        switch (r.nextInt(9)) {
          case 0:
            app.duplicateLayer(l.id);
          case 1:
            if (ls.length > 1) app.deleteLayerById(l.id);
          case 2:
            app.toggleHidden(l.id);
          case 3:
            app.moveLayer(l.id, r.nextInt(ls.length));
          case 4:
            app.duplicateFolder(['F', 'G'][r.nextInt(2)]);
          case 5:
            app.moveFolderLayers(['F', 'G'][r.nextInt(2)], [null, 'F', 'G', 'H'][r.nextInt(4)]);
          case 6:
            app.deleteFolder(['F', 'G', 'H'][r.nextInt(3)], withLayers: r.nextInt(3) == 0 && ls.length > 3);
          case 7:
            app.selectLayer(l.id);
            app.selectLayerGroup([for (final x in ls) if (r.nextBool() || x == l) x.id]);
            app.beginLayerDrag(l.id, LayerDragMode.move);
            app.updateLayerDrag(r.nextInt(40) - 20);
            app.endLayerDrag();
          case 8:
            app.setFrame(l.startFrame + 1 + r.nextInt(math.max(1, l.durationFrames - 1)));
            app.splitLayerAtPlayhead(l.id);
        }
        // nothing broken on the way: every layer whole.
        for (final x in app.project.layers) {
          expect(x.durationFrames, greaterThan(0), reason: 'step $s');
          expect(x.startFrame, greaterThanOrEqualTo(0), reason: 'step $s');
        }
        expect(app.project.layers.map((x) => x.id).toSet().length, app.project.layers.length, reason: 'ids unique');
      }
      final end = snap(app);
      var n = 0;
      while (app.undo.canUndo && n++ < 100) {
        app.performUndo();
      }
      expect(snap(app), start, reason: 'undone all the way');
      n = 0;
      while (app.undo.length > 0 && snap(app) != end && n++ < 100) {
        app.performRedo();
      }
      expect(snap(app), end, reason: 'redone all the way');
      app.dispose();
    });
  }
}
