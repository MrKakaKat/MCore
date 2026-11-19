import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';
import 'package:movement_mobile/io/project_store.dart';

void main() {
  late Directory root, cache;
  late AppState app;
  setUp(() {
    root = Directory.systemTemp.createTempSync('mcore_docs_test_');
    cache = Directory.systemTemp.createTempSync('mcore_cachex_test_');
    app = AppState()..projectStore = ProjectStore(root);
    app.project.layers.clear();
  });
  tearDown(() {
    // (not disposed: a picture's decoding may still report back)
    root.deleteSync(recursive: true);
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  Layer picture(String path) => createImageLayer(imageSourceType: 'file', imagePath: path, naturalWidth: 10, naturalHeight: 10)
    ..id = 'P';

  test('a picture by reference to a passing copy in the cache is kept in the app\'s own files', () async {
    final f = File('${cache.path}/cache/file_picker/123/photo.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    final l = picture(f.path);
    app.project.layers.add(l);
    expect(await app.keepReferencedImages(), 1);
    expect(l.content.imagePath, startsWith('${root.path}/images/'));
    expect(l.content.imagePath, endsWith('_photo.png'));
    f.parent.parent.deleteSync(recursive: true); // the cache cleared
    expect(File(l.content.imagePath!).existsSync(), isTrue);
    expect(app.missingImageLayers, isEmpty);
  });

  test('lost pictures found again by their name, and kept', () async {
    final l = picture('${cache.path}/cache/file_picker/9/IMG_1.jpg');
    app.project.layers.add(l);
    expect(app.missingImageLayers.map((x) => x.id), ['P']);
    final original = File('${cache.path}/DCIM/IMG_1.jpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync([7]);
    final n = await app.findMissingImages((name) async => name == 'IMG_1.jpg' ? original : null);
    expect(n, 1);
    expect(app.missingImageLayers, isEmpty);
    expect(l.content.imagePath, startsWith('${root.path}/images/'));
    app.performUndo();
    expect(findLayer(app.project, 'P')!.content.imagePath, contains('file_picker'), reason: 'one undo step');
  });
}
