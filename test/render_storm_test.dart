import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('pictures asking for new frames without end: held until the next change', () async {
    final app = AppState();
    var frames = 0;
    app.addListener(() => frames++);
    final ask = app.renderer.onImageDecoded!;
    Future<void> storm(int n) async {
      for (var i = 0; i < n; i++) {
        ask();
        await Future<void>.delayed(Duration.zero);
      }
    }

    await storm(200);
    expect(frames, inInclusiveRange(55, 61));
    final held = frames;
    await storm(50);
    expect(frames, held, reason: 'held');
    // the frame moved: listened to again.
    app.setFrame(5);
    final after = frames;
    await storm(10);
    expect(frames, greaterThan(after));
  });
}
