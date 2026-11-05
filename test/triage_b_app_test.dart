import 'package:flutter_test/flutter_test.dart';
import 'package:movement_mobile/ui/export/export_dialog.dart';

void main() {
  test('Auto export: one frame is a PNG, short silent clips a GIF, else WebM', () {
    ({String kind, double fps, int bitrateKbps, bool alpha, String reason}) auto(
            {int frames = 120, bool sound = false, bool media = false, double w = 540, bool transparent = false}) =>
        autoExportSettings(
            width: w, height: w, frames: frames, projectFps: 60, hasSound: sound, hasMedia: media, transparent: transparent);
    expect(auto(frames: 1).kind, 'image');
    final gif = auto(transparent: true);
    expect(gif.kind, 'gif');
    expect(gif.fps, 50);
    expect(gif.alpha, isTrue);
    expect(auto(frames: 400).fps, 25);
    expect(auto(sound: true).kind, 'video');
    expect(auto(w: 1920).kind, 'video');
    final v = auto(media: true, w: 1080);
    expect(v.bitrateKbps, inInclusiveRange(800, 16000));
  });
}
