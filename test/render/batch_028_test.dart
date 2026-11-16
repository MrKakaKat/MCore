import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('albums pinned to the front: in the order pinned, unpinned again, kept as an app preference', () {
    final app = AppState();
    app.togglePinnedAlbum('a');
    app.togglePinnedAlbum('b');
    expect(app.pinnedAlbums, ['a', 'b']);
    app.togglePinnedAlbum('a');
    expect(app.pinnedAlbums, ['b']);
    app.togglePinnedAlbum('b');
    expect(app.pinnedAlbums, isEmpty);
  });
}
