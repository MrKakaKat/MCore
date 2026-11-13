/// Text tab, "Separate into layers": the text becomes a layer per word (or
/// per letter), each a full text layer of its own - same look, same
/// animation - standing exactly where its letters were.
library;

import '../core/interpolation.dart' show evaluateTrack;
import '../core/state_cache.dart';
import '../model/project.dart';
import '../model/timeline_rows.dart' show normalizeTimelineRows;
import '../ui_geometry/drag_ops.dart' show anchorLocalFromScreen;
import '../ui_geometry/handles.dart' show toFrameMatrix;
import '../core/math.dart' show applyAffine;
import 'text_layout.dart';

/// [start, end) code point ranges of `text`'s words ('word': runs without
/// spaces or line breaks) or letters ('char': every visible letter).
List<(int, int)> textPieces(String text, String by) {
  final runes = text.runes.toList();
  bool blank(int r) => r == 0x20 || r == 0x09 || r == 0x0a || r == 0x0d;
  final out = <(int, int)>[];
  if (by == 'char') {
    for (var i = 0; i < runes.length; i++) {
      if (!blank(runes[i])) out.add((i, i + 1));
    }
    return out;
  }
  int? from;
  for (var i = 0; i <= runes.length; i++) {
    final isBlank = i == runes.length || blank(runes[i]);
    if (!isBlank && from == null) from = i;
    if (isBlank && from != null) {
      out.add((from, i));
      from = null;
    }
  }
  return out;
}

/// Replaces text layer `text` by a layer per word / letter (`by`: 'word' |
/// 'char') at the place its letters show at `globalFrame`; returns them
/// (none: nothing to split - the text stays).
List<Layer> splitTextIntoLayers(Project project, Layer text, String by, int globalFrame) {
  final spec0 = text.content.text;
  if (spec0 == null) return const [];
  final local = layerLocalFrame(text, globalFrame);
  final shown = spec0.atFrame(local);
  final pieces = textPieces(shown.text, by);
  if (pieces.length < 2) return const [];
  final layout = layoutText(shown, text.content.offset, text.content.size);
  final runes = shown.text.runes.toList();
  final m = toFrameMatrix(getLayerStateAt(project, text.id, globalFrame).matrix);
  final anchorNow = (evaluateTrack(project, text.transform.anchor, local.toDouble(), text) as List).cast<num>();
  final made = <Layer>[];
  for (final (a, b) in pieces) {
    final first = layout.glyphs.where((g) => g.index >= a && g.index < b).firstOrNull;
    if (first == null) continue;
    final spec = shown.copy()
      ..text = String.fromCharCodes(runes.sublist(a, b))
      ..groupsEnabled = false
      ..hidden = const {}
      ..spans = [
        for (final s in shown.spans)
          if (s.end > a && s.start < b)
            s.copy()
              ..start = (s.start - a).clamp(0, b - a)
              ..end = (s.end - a).clamp(0, b - a)
      ];
    spec.keys.clear();
    final box = fitTextBox(spec);
    // where its first letter lands laid out alone, against where it is in
    // the whole text: the piece's own middle in the text's space.
    final alone = layoutText(spec, const [0, 0], box).glyphs.firstOrNull;
    if (alone == null) continue;
    final mid = [first.x - alone.x, first.baseline - alone.baseline];
    final l = cloneLayer(text)
      ..id = createLayer('text').id
      ..name = ''
      ..rowId = null
      ..parentId = text.parentId;
    l.content
      ..text = spec
      ..offset = [0, 0]
      ..size = box;
    // its own middle is its place: the anchor moves there (every key by
    // the same amount - the animation stays).
    final at = applyAffine(m, mid);
    final want = anchorLocalFromScreen(project, text, at[0], at[1], globalFrame);
    final d = [want[0] - anchorNow[0], want[1] - anchorNow[1]];
    List<double> shift(dynamic v) => [((v as List)[0] as num) + d[0], (v[1] as num) + d[1]];
    l.transform.anchor.defaultValue = shift(l.transform.anchor.defaultValue);
    for (final k in l.transform.anchor.keyframes) {
      k.value = shift(k.value);
    }
    l.name = 'Text "${spec.text}"';
    made.add(l);
  }
  if (made.isEmpty) return const [];
  final at = project.layers.indexOf(text);
  project.layers
    ..removeAt(at)
    ..insertAll(at, made);
  // what hung on the text hangs on its first piece.
  for (final o in project.layers) {
    if (o.parentId == text.id) o.parentId = made.first.id;
  }
  normalizeTimelineRows(project);
  clearStateCaches();
  return made;
}
