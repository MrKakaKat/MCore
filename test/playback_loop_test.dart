import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/app_state.dart';

void main() {
  test('an empty project does not play', () {
    final app = AppState();
    app.project.layers.clear();
    expect(app.canPlay, isFalse);
    app.togglePlay();
    expect(app.playing, isFalse);
    app.dispose();
  });

  testWidgets('loop off: playback stops on the last frame; loop on: it wraps', (tester) async {
    final app = AppState()..setMaxFrame(30);
    app.loopPlayback = false;
    app.togglePlay();
    expect(app.playing, isTrue);
    app.playTick(const Duration(seconds: 5), 0);
    expect(app.currentFrame, 30);
    expect(app.playing, isFalse);
    // play again at the end: starts over from frame 0.
    app.togglePlay();
    expect(app.currentFrame, 0);
    app.togglePlay();

    app.toggleLoopPlayback();
    app.togglePlay();
    app.playTick(const Duration(milliseconds: 600), 0); // 36 frames at 60 fps
    expect(app.currentFrame, 36 % 31);
    expect(app.playing, isTrue);
    app.togglePlay();
    app.dispose();
  });
}
