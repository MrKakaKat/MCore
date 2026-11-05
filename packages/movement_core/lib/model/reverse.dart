/// The Reverse tab: plays a video backwards, or mirrors a layer's keys in
/// time (per params tab) - what happened at the start now happens at the
/// end, each move played exactly backwards (eases reversed, path tangents
/// swapped).
library;

import '../ui_geometry/keyframe_strip.dart' show reversedEasing, visitLayerTracksNamed;
import 'layer_detail.dart' show keyDetailTabOf;
import 'project.dart';

/// Mirrors `trk`'s keys about the middle of 0..`duration` (local frames).
void reverseTrackKeys(Track trk, int duration) {
  final kfs = trk.keyframes;
  if (kfs.isEmpty) return;
  // a segment's ease lives on its later key: after mirroring, the old
  // earlier key becomes the later one and takes the old later key's ease,
  // reversed.
  final eases = [for (final k in kfs) k.temporal];
  for (var i = 0; i < kfs.length; i++) {
    final k = kfs[i];
    k.frame = duration - k.frame;
    k.temporal = i + 1 < kfs.length ? reversedEasing(eases[i + 1]) : (easingPresets['linear']!);
    k.spatialTangent = SpatialTangent(inTan: [...k.spatialTangent.outTan], outTan: [...k.spatialTangent.inTan]);
  }
  trk.keyframes = kfs.reversed.toList();
}

/// Reverses the keys of the params tabs in `tabs` (see keyDetailTabs); the
/// effects' time ranges are mirrored along with the Effects tab.
void reverseLayerKeys(Layer layer, Set<String> tabs) {
  final d = layer.durationFrames;
  visitLayerTracksNamed(layer, (name, trk) {
    if (tabs.contains(keyDetailTabOf(name))) reverseTrackKeys(trk, d);
  });
  if (tabs.contains('Effects')) {
    layer.effectRanges = {
      for (final e in layer.effectRanges.entries) e.key: [d - e.value[1], d - e.value[0]],
    };
  }
}
