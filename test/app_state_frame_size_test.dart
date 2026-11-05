import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/app_state.dart';

/// Real, run coverage of AppState.setFrameSize/toggleShowOffCanvasContent
/// - configurable frame aspect ratio + the off-canvas toggle.
///   frameWidth/frameHeight used to be `static const`; this exercises them as
///   the mutable instance fields they are now, and confirms the cascade all
///   the way down to movement_core's own stageSize global (what every layer's
///   normalized coordinates are actually measured against - see
///   AppState.setFrameSize's own doc comment).
void main() {
  test(
      'setFrameSize updates frameWidth/frameHeight and cascades to movement_core\'s stageSize global',
      () {
    final app = AppState();
    expect(app.frameWidth, equals(480));
    expect(app.frameHeight, equals(480));

    app.setFrameSize(1080, 1920); // a 9:16 portrait preset

    expect(app.frameWidth, equals(1080));
    expect(app.frameHeight, equals(1920));
    expect(stageSize.width, equals(1080));
    expect(stageSize.height, equals(1920));
  });

  test(
      'toggleShowOffCanvasContent flips the flag both ways and notifies listeners',
      () {
    final app = AppState();
    expect(app.showOffCanvasContent, isFalse);

    var notified = 0;
    app.addListener(() => notified++);

    app.toggleShowOffCanvasContent();
    expect(app.showOffCanvasContent, isTrue);
    expect(notified, equals(1));

    app.toggleShowOffCanvasContent();
    expect(app.showOffCanvasContent, isFalse);
    expect(notified, equals(2));
  });
}
