/// The filters of a layer as separate parts, each with a time of its
/// own on the timeline (an entry 'filter.<unit>' in the layer's effect
/// ranges and binds), and Match Colors ('match.<id>').
library;

import 'layer_detail.dart' show effectSpans;
import 'project.dart';

bool _on(Track t) => t.defaultValue != 0.0 || t.keyframes.isNotEmpty;

/// unit -> its name on the timeline, in the Filters tab's order.
const filterUnitNames = {
  'blur': 'blur',
  'negative': 'negative',
  'grade': 'colour wheels',
  'vignette': 'vignette',
  'warp': 'fractal warp',
  'mosaic': 'mosaic',
  'dither': 'dither',
  'lightWrap': 'light wrap',
  'choke': 'choker',
  'dissolve': 'dissolve',
};

/// Whether `unit` is switched on in `f`.
bool filterUnitOn(LayerFilters f, String unit) => switch (unit) {
      'blur' => _on(f.blur),
      'negative' => _on(f.negative),
      'grade' => f.graded,
      'vignette' => _on(f.vignette),
      'warp' => _on(f.warp),
      'mosaic' => _on(f.mosaic),
      'dither' => f.dither,
      'lightWrap' => f.lightWrap > 0,
      'choke' => _on(f.choke),
      'dissolve' => f.dissolve != 'none',
      _ => false,
    };

/// `unit` switched off in `f` (a copy's).
void _offUnit(LayerFilters f, String unit) {
  switch (unit) {
    case 'blur':
      f.blur = Track(0.0, false);
    case 'negative':
      f.negative = Track(0.0, false);
    case 'grade':
      f.lift = [0, 0, 0];
      f.gamma = [0, 0, 0];
      f.gain = [0, 0, 0];
    case 'vignette':
      f.vignette = Track(0.0, false);
    case 'warp':
      f.warp = Track(0.0, false);
    case 'mosaic':
      f.mosaic = Track(0.0, false);
    case 'dither':
      f.dither = false;
    case 'lightWrap':
      f.lightWrap = 0;
    case 'choke':
      f.choke = Track(0.0, false);
    case 'dissolve':
      f.dissolve = 'none';
  }
}

/// The timeline entry of a filter unit.
String filterEntryId(String unit) => 'filter.$unit';

/// The filter units switched on, with their entry ids and names.
List<(String id, String label)> filterEntries(Layer layer) => [
      for (final u in filterUnitNames.keys)
        if (filterUnitOn(layer.filters, u)) (filterEntryId(u), filterUnitNames[u]!),
      for (final m in layer.filters.matches) (m.entryId, 'match colour'),
    ];

/// The layer's filters as they act at `globalFrame`: the parts outside
/// their time (or the time of the layer they are tied to) left out. The
/// layer's own filters when every part acts (no copy).
LayerFilters activeFiltersAt(Project? project, Layer layer, num globalFrame) {
  final f = layer.filters;
  if (layer.effectRanges.isEmpty && layer.effectBinds.isEmpty) return f;
  final lf = globalFrame - layer.startFrame;
  final off = [
    for (final u in filterUnitNames.keys)
      if (filterUnitOn(f, u) && !effectActiveAt(layer, filterEntryId(u), lf, project)) u
  ];
  final offMatches = [
    for (final m in f.matches)
      if (!effectActiveAt(layer, m.entryId, lf, project)) m
  ];
  if (off.isEmpty && offMatches.isEmpty) return f;
  final c = f.copy();
  for (final u in off) {
    _offUnit(c, u);
  }
  c.matches.removeWhere((m) => offMatches.any((o) => o.id == m.id));
  return c;
}

/// The entries that can be tied to another layer's time: effects (as in
/// the Effects tab), filter parts, matches - with their names.
List<(String id, String label)> bindableEntries(Layer layer) => [
      for (final s in effectSpans(layer)) (s.id, s.label),
    ];
