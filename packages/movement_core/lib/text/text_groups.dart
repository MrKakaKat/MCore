/// Text groups: letters marked off in a text ("#T#ext", the marker is the
/// text's `groupChar`) are drawn by child layers of shape "textGroup" -
/// moved, keyed and given effects on their own while staying part of the
/// text (same font, colour, animators, and the parent's motion). The text
/// leaves those letters out while their layer is there.
library;

import '../core/stage_size.dart';
import '../model/project.dart';
import 'text_layout.dart';

/// The group layers of `text`, by group index.
Map<int, Layer> textGroupLayers(Project project, Layer text) => {
      for (final l in project.layers)
        if (l.content.shape == 'textGroup' && l.parentId == text.id) l.content.textGroup: l
    };

/// Letters of `text` drawn by its group layers at local frame `f` (code
/// point indices of the shown text) - the text leaves them out.
Set<int> textGroupHidden(Project project, Layer text, num f) {
  final t = text.content.text;
  if (t == null || !t.groupsEnabled) return const {};
  final taken = textGroupLayers(project, text);
  if (taken.isEmpty) return const {};
  final groups = t.groupsAt(f);
  return {
    for (var g = 0; g < groups.length; g++)
      if (taken.containsKey(g)) for (var i = groups[g].$1; i < groups[g].$2; i++) i
  };
}

/// The spec a group layer draws at the parent's local frame `f`: the
/// parent's text with every other letter hidden; null when its group is
/// gone (the markers were removed).
TextSpec? textGroupSpec(Project project, Layer group, num f) {
  final parent = findLayer(project, group.parentId);
  final t = parent?.content.text;
  if (t == null || !t.groupsEnabled) return null;
  final groups = t.groupsAt(f);
  final gi = group.content.textGroup;
  if (gi >= groups.length) return null;
  final shown = t.atFrame(f);
  final n = shown.text.runes.length;
  final copy = shown.copy()
    ..background.enabled = false
    ..hidden = {
      for (var i = 0; i < n; i++)
        if (i < groups[gi].$1 || i >= groups[gi].$2) i
    };
  return copy;
}

/// Adds a layer for each group of `text` that has none (above the text,
/// parented to it, sitting on its letters). Returns the new layers.
List<Layer> addTextGroupLayers(Project project, Layer text) {
  final t = text.content.text;
  if (t == null || !t.groupsEnabled) return const [];
  final groups = t.groupsAt(0);
  final taken = textGroupLayers(project, text);
  final shown = t.atFrame(0);
  final layout = layoutText(shown, text.content.offset, text.content.size);
  final runes = shown.text.runes.toList();
  final out = <Layer>[];
  for (var g = 0; g < groups.length; g++) {
    if (taken.containsKey(g)) continue;
    final (a, b) = groups[g];
    var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
    for (final gl in layout.glyphs) {
      if (gl.index < a || gl.index >= b) continue;
      x0 = x0 < gl.x ? x0 : gl.x;
      x1 = x1 > gl.x + gl.advance ? x1 : gl.x + gl.advance;
      y0 = y0 < gl.baseline - gl.ascent ? y0 : gl.baseline - gl.ascent;
      y1 = y1 > gl.baseline + gl.descent ? y1 : gl.baseline + gl.descent;
    }
    if (x0 == double.infinity) continue; // only spaces
    final pivot = [(x0 + x1) / 2, (y0 + y1) / 2];
    final l = createLayer('rect')
      ..name = 'Group "${String.fromCharCodes(runes.sublist(a, b))}"'
      ..parentId = text.id
      ..startFrame = text.startFrame
      ..durationFrames = text.durationFrames
      ..color = text.color;
    l.content
      ..shape = 'textGroup'
      ..offset = [0, 0]
      ..size = [x1 - x0, y1 - y0]
      ..textGroup = g
      ..textGroupPivot = pivot;
    l.transform.anchor.defaultValue = [pivot[0] / stageSize.width, pivot[1] / stageSize.height];
    l.transform.anchor.keyframes = [];
    l.transform.scale.defaultValue = [1.0, 1.0];
    l.transform.scale.keyframes = [];
    l.transform.rotation.defaultValue = 0.0;
    l.transform.rotation.keyframes = [];
    project.layers.insert(project.layers.indexOf(text) + 1, l);
    out.add(l);
  }
  return out;
}
