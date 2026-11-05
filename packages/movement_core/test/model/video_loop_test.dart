import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

void main() {
  setUp(() => fps = 30);
  tearDown(() => loopExtendedVideos = false);

  Content clip({double sourceIn = 0}) =>
      Content(shape: 'video', offset: [0, 0], size: [10, 10])
        ..videoFrameCount = 30
        ..videoFps = 30
        ..sourceIn = sourceIn;

  test('a video longer than its clip holds the last frame, or loops with the setting', () {
    expect(videoSourceFrame(clip(), 45), 29);
    loopExtendedVideos = true;
    expect(videoSourceFrame(clip(), 45), 15);
    expect(videoSourceFrame(clip(), 29), 29);
    // from its in-point again, not from the clip's start.
    expect(videoSourceFrame(clip(sourceIn: 0.5), 15), 15);
    expect(videoSourceFrame(clip(sourceIn: 0.5), 16), 16);
  });
}
