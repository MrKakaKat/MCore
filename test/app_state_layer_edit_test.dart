import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/preset_store.dart';

/// The timeline's layer action row (split / start to playhead / fit to
/// playhead), the Layers tab's replace content and copy/paste
/// parameters, presets, and the Crop tab's actions.
void main() {
  late AppState app;
  late Layer layer;
  setUp(() {
    app = AppState();
    layer = app.project.layers.last;
    layer
      ..startFrame = 20
      ..durationFrames = 100; // 20..120
  });
  tearDown(() {
    cropEditing = false;
    app.dispose();
  });

  group('action row', () {
    test('split at the playhead makes two layers, one undo step', () {
      final before = app.project.layers.length;
      app.setFrame(50);
      app.splitLayerAtPlayhead(layer.id);
      expect(app.project.layers.length, before + 1);
      expect([layer.startFrame, layer.durationFrames], [20, 30]);
      final right = app.project.layers[app.project.layers.indexOf(layer) + 1];
      expect([right.startFrame, right.durationFrames], [50, 70]);
      expect(app.selection.selectedLayer, right.id);

      app.performUndo();
      expect(app.project.layers.length, before);
    });

    test('split outside the layer does nothing', () {
      final before = app.project.layers.length;
      app.setFrame(10);
      app.splitLayerAtPlayhead(layer.id);
      expect(app.project.layers.length, before);
    });

    test('move start to playhead', () {
      app.setFrame(60);
      app.moveLayerStartToPlayhead(layer.id);
      expect([layer.startFrame, layer.durationFrames], [60, 100]);
    });

    test('fit to playhead: past the end extends the end, before the start extends the start', () {
      app.setMaxFrame(300);
      app.setFrame(150);
      app.fitLayerEdgeToPlayhead(layer.id);
      expect([layer.startFrame, layer.durationFrames], [20, 130]);

      app.setFrame(5);
      app.fitLayerEdgeToPlayhead(layer.id);
      expect([layer.startFrame, layer.durationFrames], [5, 145]);
    });

    test('fit to playhead inside the layer shrinks the nearest edge', () {
      app.setFrame(30); // 10 from the start, 90 from the end
      app.fitLayerEdgeToPlayhead(layer.id);
      expect([layer.startFrame, layer.durationFrames], [30, 90]);

      app.setFrame(110); // nearer the end (120)
      app.fitLayerEdgeToPlayhead(layer.id);
      expect([layer.startFrame, layer.durationFrames], [30, 80]);
    });
  });

  test('replace content keeps the parameters', () {
    layer.transform.rotation.defaultValue = 33.0;
    layer.effectStack.add(createEffectInstance('bend_arc', 'fx_x', layer));
    app.replaceLayerContentWith(layer.id, createLayer('circle').content);
    expect(layer.content.shape, 'circle');
    expect(layer.transform.rotation.defaultValue, 33.0);
    expect(layer.effectStack.single.effectId, 'bend_arc');
  });

  test('copy parameters from one layer, paste into another', () {
    final other = app.project.layers.first;
    layer.transform.opacity.defaultValue = 0.25;
    layer.mirrorX = true;
    expect(app.copiedLayerParams, isNull);
    app.copyLayerParamsOf(layer.id);
    app.pasteLayerParamsInto(other.id);
    expect(other.transform.opacity.defaultValue, 0.25);
    expect(other.mirrorX, isTrue);
    app.performUndo();
    // undo restores layer snapshots, so look the layer up again.
    expect(findLayer(app.project, other.id)!.mirrorX, isFalse, reason: 'one undo step');
  });

  test('presets are saved to disk and apply to a layer in another project', () async {
    final dir = Directory.systemTemp.createTempSync('presets_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = PresetStore(dir);
    layer.transform.scale.defaultValue = [3.0, 1.5];
    await store.save('Wide', layerParamsToJson(layer));

    // a completely separate app/project, same preset folder.
    final other = AppState()..presetStore = PresetStore(dir);
    addTearDown(other.dispose);
    final presets = await other.presetStore!.list();
    expect(presets.map((p) => p.name), ['Wide']);
    final target = other.project.layers.first;
    other.applyParamsTo(target.id, presets.single.params);
    expect(target.transform.scale.defaultValue, [3.0, 1.5]);

    await store.rename(presets.single, 'Wider');
    expect((await store.list()).single.name, 'Wider');
    await store.delete((await store.list()).single);
    expect(await store.list(), isEmpty);
  });

  group('crop & mirror', () {
    setUp(() => app.selectLayer(layer.id));

    test('insets, aspect and reset', () {
      app.setCropInset(2, 0.3);
      expect(layer.crop, [0.0, 0.0, 0.3, 0.0]);
      app.setCropInset(0, 0.9); // clamped so 5% stays visible
      expect(layer.crop[0], closeTo(0.65, 1e-9));
      app.resetCrop();
      expect(layerHasCrop(layer), isFalse);

      app.setCropAspect('1:1');
      expect(layer.cropAspect, '1:1');
      final b = croppedBox(layer);
      final s = layer.transform.scale.defaultValue as List<double>;
      expect((b.maxX - b.minX) * s[0], closeTo((b.maxY - b.minY) * s[1], 1e-6));
    });

    test('mirror toggles, and crop editing turns off when the selection changes', () {
      app.toggleMirror(horizontal: true);
      app.toggleMirror(horizontal: false);
      expect([layer.mirrorX, layer.mirrorY], [true, true]);
      app.toggleCropEditing();
      expect(cropEditing, isTrue);
      app.selectLayer(app.project.layers.first.id);
      expect(cropEditing, isFalse);
    });
  });
}
