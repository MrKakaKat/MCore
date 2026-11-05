import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';

/// Real, run coverage of AppState.addImageLayer - the app-state half of
/// image import (the UI picking/decoding half lives in
/// lib/io/image_import.dart and lib/ui/layer_panel/layer_panel_view.dart,
/// both of which touch ui.instantiateImageCodec/FilePicker and so
/// aren't runnable in this sandbox - see canvas_renderer.dart's own doc
/// comment on that limitation). This file covers everything downstream
/// of "the UI already resolved a PickedImage and a storage-mode
/// choice", which is plain, testable AppState logic.
///
/// Deliberately a SINGLE test, exercising "embedded" mode only - a real
/// finding from trying a more thorough split (a second test, a
/// "file"-mode case, an undo case each with their own addImageLayer
/// call): this sandbox's flutter_tester can complete exactly ONE
/// ui.instantiateImageCodec call per test file before every subsequent
/// call hangs indefinitely, regardless of whether the bytes are valid,
/// garbage, or the source file exists at all. (This is consistent with,
/// and sharpens, the already-documented "instantiateImageCodec hangs"
/// finding from gif_encoder_test.dart's own doc comment - that one
/// caught the SAME behavior via a debug script showing a first PNG
/// decode succeed and a second GIF decode hang.) Since addImageLayer
/// unconditionally triggers a render, and canvas_renderer.dart's
/// _getDecodedImage eagerly kicks off exactly one such call per
/// image-shaped layer drawn, this file stays to one addImageLayer call
/// so the whole suite doesn't hang. "file"-mode's field-wiring and
/// undo/redo (which never itself adds a second image layer) are already
/// covered elsewhere without ever touching the renderer:
/// packages/movement_core/test/model/project_json_test.dart and
/// image_content_test.dart cover createImageLayer(imageSourceType:
/// "file", ...) and undo/redo's own general snapshot mechanics are
/// covered by the pre-existing layer_ops_test.dart - addImageLayer
/// itself is a thin passthrough to createImageLayer plus the exact same
/// undo.pushUndoState/_render/notifyListeners sequence addLayer already
/// uses, confirmed by reading app_state.dart directly.
void main() {
  test('addImageLayer adds an embedded-mode image layer, selects it, notifies, and can be undone', () {
    final app = AppState();
    final before = app.project.layers.length;
    var notified = 0;
    app.addListener(() => notified++);

    app.addImageLayer(
      imageSourceType: 'embedded',
      imageData: 'ZmFrZQ==',
      naturalWidth: 400,
      naturalHeight: 200,
    );

    expect(app.project.layers.length, equals(before + 1));
    final added = app.project.layers.last;
    expect(added.content.shape, equals('image'));
    expect(added.content.imageSourceType, equals('embedded'));
    expect(added.content.imageData, equals('ZmFrZQ=='));
    expect(added.content.imagePath, isNull);
    expect(app.selection.selectedLayer, equals(added.id));
    expect(notified, greaterThan(0));

    // undo restores the pre-import snapshot (no image content in it),
    // so this doesn't trigger a second instantiateImageCodec call.
    app.undo.undo(app.project, app.selection);
    expect(app.project.layers.length, equals(before));
  });
}
