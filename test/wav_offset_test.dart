import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:movement_core/movement_core.dart';
import 'package:movement_mobile/services/native_media.dart';

void main() {
  test('the samples of a WAV start after its header - none of the header goes in as sound', () {
    final pcm = Int16List.fromList([100, -100, 200, -200]);
    final wav = wavBytes(pcm);
    final at = wavDataOffset(wav);
    expect(at, 44);
    expect(Int16List.sublistView(Uint8List.fromList(wav.sublist(at))), pcm);
    expect(wavDataOffset(Uint8List.fromList([1, 2, 3])), 0);
  });
}
