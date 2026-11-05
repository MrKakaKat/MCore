/// Mask regions over time: the pieces of each region, followed frame by
/// frame as episodes (a piece's life), numbered by where they first touch
/// (their footprints), and the commands that react to them.
///
/// Sequential like Collide: baked from the layer's first frame, kept while
/// the inputs (every frame's shapes) stay the same. Vector sources only.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../core/interpolation.dart' show evaluateTrack, easeProgress;
import '../core/math.dart' show applyAffine, invertAffine;
import '../core/stage_size.dart';
import '../model/project_json.dart' show layerToJson;
import '../core/state_cache.dart' show getLayerStateAt;
import '../model/project.dart';
import '../ui_geometry/handles.dart' show toFrameMatrix;
import 'contour_layer.dart' show regionCells, regionSelfIndex, MaskRegion;
import 'polygon_boolean.dart';

typedef Rings = List<List<List<double>>>;

/// Smallest piece that counts (px²) and frames a piece may be missing
/// before its episode ends (no flicker at a grazing touch).
const _minArea = 2.0;
const _hysteresis = 2;

/// "Inside" a footprint: at least 95 % of the piece, with a 1.5 px margin.
const _insideShare = 0.95;
const _insideMargin = 1.5;

double ringsArea(Rings rings) {
  var a = 0.0;
  for (final r in rings) {
    var s = 0.0;
    for (var i = 0; i < r.length; i++) {
      final p = r[i], q = r[(i + 1) % r.length];
      s += p[0] * q[1] - q[0] * p[1];
    }
    a += s / 2;
  }
  return a.abs();
}

bool _pointInRing(List<double> p, List<List<double>> r) {
  var inside = false;
  for (var i = 0, j = r.length - 1; i < r.length; j = i++) {
    final a = r[i], b = r[j];
    if ((a[1] > p[1]) != (b[1] > p[1]) && p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]) {
      inside = !inside;
    }
  }
  return inside;
}

/// The rings of a region split into its separate pieces: each outer ring
/// with the holes inside it.
List<Rings> splitPieces(Rings rings) {
  final outers = <int>[], holes = <int>[];
  for (var i = 0; i < rings.length; i++) {
    if (rings[i].length < 3) continue;
    var depth = 0;
    for (var j = 0; j < rings.length; j++) {
      if (j != i && rings[j].length >= 3 && _pointInRing(rings[i][0], rings[j])) depth++;
    }
    (depth.isEven ? outers : holes).add(i);
  }
  final pieces = [
    for (final o in outers) <List<List<double>>>[rings[o]]
  ];
  for (final h in holes) {
    // the innermost outer around it.
    int? best;
    var bestArea = double.infinity;
    for (var k = 0; k < outers.length; k++) {
      if (!_pointInRing(rings[h][0], rings[outers[k]])) continue;
      final a = ringsArea([rings[outers[k]]]);
      if (a < bestArea) {
        bestArea = a;
        best = k;
      }
    }
    if (best != null) pieces[best].add(rings[h]);
  }
  return pieces;
}

List<double> _centroid(Rings r) {
  var x = 0.0, y = 0.0, n = 0;
  for (final p in r.first) {
    x += p[0];
    y += p[1];
    n++;
  }
  return n == 0 ? [0, 0] : [x / n, y / n];
}

List<double> _box(Rings r) {
  var x0 = double.infinity, y0 = double.infinity, x1 = -double.infinity, y1 = -double.infinity;
  for (final ring in r) {
    for (final p in ring) {
      x0 = math.min(x0, p[0]);
      y0 = math.min(y0, p[1]);
      x1 = math.max(x1, p[0]);
      y1 = math.max(y1, p[1]);
    }
  }
  return [x0, y0, x1, y1];
}

bool _boxesMeet(List<double> a, List<double> b, double pad) =>
    a[0] <= b[2] + pad && b[0] <= a[2] + pad && a[1] <= b[3] + pad && b[1] <= a[3] + pad;

Rings _map(Rings r, List<double> m) => [
      for (final ring in r) [for (final p in ring) applyAffine(m, p)]
    ];

/// Whether piece `p` (source-local) lies inside footprint `fp`.
bool _insideFootprint(Rings p, Rings fp) {
  final a = ringsArea(p);
  if (a <= 0) return true;
  final grown = offsetRings(fp, _insideMargin);
  final out = polygonBoolean(p, grown, BoolOp.subtract);
  return ringsArea(out) <= (1 - _insideShare) * a;
}

/// One piece's life.
class RegionEpisode {
  final int sig;
  final int start;

  /// The last frame it was there (null: still there at the bake's end).
  int? end;

  /// Its number (null: not numbered, or still counting as `pendingAs`).
  int? number;

  /// A repeat inside footprint N: counts as N until it breaks through.
  int? pendingAs;

  /// The frame it broke through (got its own number).
  int? breakthrough;

  int peakFrame;
  double peakArea = 0;

  /// Its piece on every frame it was there (frame px).
  final Map<int, Rings> pieces = {};
  RegionEpisode(this.sig, this.start) : peakFrame = start;

  /// The number it shows as at `frame` (its own after the breakthrough,
  /// the footprint's before).
  int? numberAt(int frame) => number != null && (breakthrough == null || frame >= breakthrough!) ? number : pendingAs ?? number;

  String key() => '$sig@$start';
}

/// The largest shape of a numbered region, kept in the space of the
/// pair's first source - the same contact anywhere on the stage is the
/// same region.
class RegionFootprint {
  final int sig;
  final int number;
  Rings local;
  double area;

  /// Who drew it, and the frame it stops growing for good (null: open).
  final RegionEpisode owner;
  RegionFootprint(this.sig, this.number, this.local, this.area, this.owner);

  bool openAt(int frame) => owner.end == null || frame <= owner.end!;
}

class RegionBake {
  final List<RegionEpisode> episodes;
  final List<RegionFootprint> footprints;

  /// Numbers that changed since the last bake (sig:number), when any did.
  final Set<String> renumbered;
  RegionBake(this.episodes, this.footprints, {this.renumbered = const {}});

  static final empty = RegionBake(const [], const []);

  /// The pieces there at `frame`, with their episode.
  Iterable<(RegionEpisode, Rings)> piecesAt(int frame) sync* {
    for (final e in episodes) {
      final p = e.pieces[frame];
      if (p != null) yield (e, p);
    }
  }
}

/// Whether region `sig` gets numbers: the overlaps (two sources or more),
/// or any region with a single source.
bool regionNumberable(int sig, int sourceCount) {
  if (sig == 0) return false;
  if (sourceCount < 2) return true;
  var n = 0;
  for (var s = sig; s != 0; s >>= 1) {
    n += s & 1;
  }
  return n >= 2;
}

// One bake per set of shapes, shared by every layer whose regions use
// that set (the overlap of A and B is born, peaks and is numbered once,
// whichever of A, B or a third layer shows it). Kept in the set's own
// order (ids sorted); each layer reads it in its own order (see _view).
final Map<String, (String, RegionBake)> _bakes = {};

List<String> _canon(MaskRegions mr) => [...mr.sources]..sort();

String _keyOf(Project project, List<String> ids) => '${identityHashCode(project)}|${ids.join(',')}';

/// The inputs of a bake: the shapes and every layer they hang from, as
/// data - one snapshot instead of every frame's shapes.
String _inputsOf(Project project, List<String> ids) {
  final involved = <String>{};
  void up(String? id) {
    while (id != null && involved.add(id)) {
      id = findLayer(project, id)?.parentId;
    }
  }

  for (final id in ids) {
    up(id);
  }
  return jsonEncode([
    stageSize.width,
    stageSize.height,
    for (final l in project.layers)
      if (involved.contains(l.id)) layerToJson(l)
  ]);
}

/// The frames a set of shapes is baked over: from the first one's start to
/// the last one's end.
(int, int) _framesOf(Project project, List<String> ids) {
  var a = 1 << 30, b = 0;
  for (final id in ids) {
    final l = findLayer(project, id);
    if (l == null) continue;
    a = math.min(a, l.startFrame);
    b = math.max(b, l.startFrame + l.durationFrames);
  }
  return a > b ? (0, 0) : (a, b);
}

final _views = Expando<Map<String, RegionBake>>();

/// The shared bake in `mr`'s own source order (bit i: inside its source i).
RegionBake _view(RegionBake shared, List<String> canon, MaskRegions mr) {
  if (shared.episodes.isEmpty) return shared;
  final idx = [for (final id in mr.sources) canon.indexOf(id)];
  final key = idx.join(',');
  final cache = _views[shared] ??= {};
  final hit = cache[key];
  if (hit != null) return hit;
  int map(int c) {
    var o = 0;
    for (var i = 0; i < idx.length; i++) {
      if (idx[i] >= 0 && (c >> idx[i]) & 1 == 1) o |= 1 << i;
    }
    return o;
  }

  final eps = <RegionEpisode, RegionEpisode>{};
  for (final e in shared.episodes) {
    eps[e] = RegionEpisode(map(e.sig), e.start)
      ..end = e.end
      ..number = e.number
      ..pendingAs = e.pendingAs
      ..breakthrough = e.breakthrough
      ..peakFrame = e.peakFrame
      ..peakArea = e.peakArea
      ..pieces.addAll(e.pieces);
  }
  final out = RegionBake(
    [for (final e in shared.episodes) eps[e]!],
    [for (final f in shared.footprints) RegionFootprint(map(f.sig), f.number, f.local, f.area, eps[f.owner]!)],
    renumbered: {
      for (final r in shared.renumbered)
        '${map(int.parse(r.split(':')[0]))}:${r.split(':')[1]}'
    },
  );
  return cache[key] = out;
}

/// Baking a step at a time (the app's stage stays responsive): the frames
/// worked out so far, by set of shapes.
final Map<String, (String, List<List<MaskRegion>?>)> _partial = {};

bool _on(MaskRegions? mr) => mr != null && mr.enabled && mr.sources.isNotEmpty;

/// The bake as it is now: the current one, or (while a new one is being
/// worked out by [regionBakeStep]) the last one - or empty.
RegionBake regionEpisodesReady(Project project, Layer layer) {
  final mr = layer.maskRegions;
  if (!_on(mr)) return RegionBake.empty;
  final canon = _canon(mr!);
  final b = _bakes[_keyOf(project, canon)]?.$2;
  return b == null ? RegionBake.empty : _view(b, canon, mr);
}

/// Whether the layer's bake is up to date with its inputs.
bool regionBakeCurrent(Project project, Layer layer) {
  final mr = layer.maskRegions;
  if (!_on(mr)) return true;
  final canon = _canon(mr!);
  final prev = _bakes[_keyOf(project, canon)];
  return prev != null && prev.$1 == _inputsOf(project, canon);
}

/// Works on the layer's bake for about `budgetMs`; true once it is
/// current (then [regionEpisodesReady] gives it).
bool regionBakeStep(Project project, Layer layer, {int budgetMs = 8}) {
  final mr = layer.maskRegions;
  if (!_on(mr)) return true;
  final canon = _canon(mr!);
  final key = _keyOf(project, canon);
  final inputs = _inputsOf(project, canon);
  final prev = _bakes[key];
  if (prev != null && prev.$1 == inputs) return true;
  var part = _partial[key];
  if (part == null || part.$1 != inputs) part = _partial[key] = (inputs, []);
  final (first, last) = _framesOf(project, canon);
  final sw = Stopwatch()..start();
  while (first + part.$2.length <= last) {
    final g = regionCells(project, canon, first + part.$2.length);
    if (g == null) {
      _partial.remove(key);
      _bakes[key] = (inputs, RegionBake.empty);
      return true;
    }
    part.$2.add(g);
    if (sw.elapsedMilliseconds >= budgetMs) return false;
  }
  _partial.remove(key);
  _finish(project, canon, part.$2, first, key, inputs, prev);
  return true;
}

/// Forgets the baked episodes (tests).
void clearRegionBakes() {
  _bakes.clear();
  _partial.clear();
}

/// The layer's region episodes (in its own source order) - baked from the
/// shapes' first frame, shared with every layer using the same shapes,
/// kept while the shapes stay the same. Empty without vector regions.
RegionBake regionEpisodes(Project project, Layer layer) {
  final mr = layer.maskRegions;
  if (!_on(mr)) return RegionBake.empty;
  final canon = _canon(mr!);
  final inputs = _inputsOf(project, canon);
  final key = _keyOf(project, canon);
  final prev = _bakes[key];
  if (prev != null && prev.$1 == inputs) return _view(prev.$2, canon, mr);
  final (first, last) = _framesOf(project, canon);
  final geos = <List<MaskRegion>?>[];
  for (var f = first; f <= last; f++) {
    final g = regionCells(project, canon, f);
    geos.add(g);
    if (g == null) {
      _bakes[key] = (inputs, RegionBake.empty);
      return RegionBake.empty;
    }
  }
  return _view(_finish(project, canon, geos, first, key, inputs, prev), canon, mr);
}

RegionBake _finish(Project project, List<String> canon, List<List<MaskRegion>?> geos, int first, String key,
    String inputs, (String, RegionBake)? prev) {
  final bake = _bake(project, canon, geos, first);
  // renumbering: a number that differs for the same episode.
  final changed = <String>{};
  if (prev != null) {
    final before = {for (final e in prev.$2.episodes) e.key(): e.number};
    for (final e in bake.episodes) {
      final b = before[e.key()];
      if (before.containsKey(e.key()) && b != e.number) changed.add('${e.sig}:${b ?? e.number}');
    }
  }
  final out = RegionBake(bake.episodes, bake.footprints, renumbered: changed);
  if (_bakes.length > 32) _bakes.clear();
  _bakes[key] = (inputs, out);
  return out;
}

RegionBake _bake(Project project, List<String> ids, List<List<MaskRegion>?> geos, int first) {
  final n = ids.length;
  final episodes = <RegionEpisode>[];
  final footprints = <RegionFootprint>[];
  final nextNumber = <int, int>{};
  // per signature: the episodes still going, with how long they've been
  // missing.
  final active = <int, List<(RegionEpisode, Rings, int)>>{};
  for (var fi = 0; fi < geos.length; fi++) {
    final f = first + fi;
    final geo = geos[fi]!;
    for (final region in geo) {
      final sig = region.sig;
      if (sig == 0) continue;
      // numbered always (cheap); each layer shows the numbers or not.
      final numbering = regionNumberable(sig, n);
      // the pair's first source: footprints live in its space.
      final ownerIdx = sig == 0 ? 0 : (sig & -sig).bitLength - 1;
      final toLocal = invertAffine(
          toFrameMatrix(getLayerStateAt(project, ids[ownerIdx], f).matrix));
      final pieces = [
        for (final p in splitPieces(region.rings))
          if (ringsArea(p) >= _minArea) p
      ];
      final boxes = [for (final p in pieces) _box(p)];
      final live = active[sig] ?? [];
      // which pieces each going episode overlaps.
      final hits = <int, List<int>>{}; // piece -> live indices
      final byEp = <int, List<int>>{}; // live index -> pieces
      for (var li = 0; li < live.length; li++) {
        final lastBox = _box(live[li].$2);
        for (var pi = 0; pi < pieces.length; pi++) {
          if (!_boxesMeet(lastBox, boxes[pi], 1)) continue;
          final meet = polygonBoolean(live[li].$2, pieces[pi], BoolOp.intersect);
          final c = _centroid(pieces[pi]), c2 = _centroid(live[li].$2);
          if (ringsArea(meet) > 0.25 || (c[0] - c2[0]).abs() + (c[1] - c2[1]).abs() < 3) {
            (hits[pi] ??= []).add(li);
            (byEp[li] ??= []).add(pi);
          }
        }
      }
      double rank(RegionEpisode e) => (e.number ?? e.pendingAs ?? 1 << 30) * 1e6 + e.start;
      final continued = <int, int>{}; // piece -> live index
      final ended = <int>{};
      // merge: the lowest number goes on, the others end.
      for (var pi = 0; pi < pieces.length; pi++) {
        final ls = hits[pi];
        if (ls == null) continue;
        ls.sort((a, b) => rank(live[a].$1).compareTo(rank(live[b].$1)));
        continued[pi] = ls.first;
        for (final other in ls.skip(1)) {
          ended.add(other);
        }
      }
      // split: one episode in several pieces - the largest goes on, the
      // rest start their own.
      for (final e in byEp.entries) {
        final ps = [for (final pi in e.value) if (continued[pi] == e.key) pi];
        if (ps.length < 2) continue;
        ps.sort((a, b) => ringsArea(pieces[b]).compareTo(ringsArea(pieces[a])));
        for (final pi in ps.skip(1)) {
          continued.remove(pi);
        }
      }
      final nextLive = <(RegionEpisode, Rings, int)>[];
      for (var li = 0; li < live.length; li++) {
        final (ep, lastPiece, missed) = live[li];
        final pi = continued.entries.where((e) => e.value == li).map((e) => e.key).firstOrNull;
        if (pi != null && !ended.contains(li)) {
          final p = pieces[pi];
          ep.pieces[f] = p;
          final area = ringsArea(p);
          if (numbering) {
            final local = _map(p, toLocal);
            if (ep.pendingAs != null && ep.number == null) {
              final fp = footprints.firstWhere((x) => x.sig == sig && x.number == ep.pendingAs);
              if (!_insideFootprint(local, fp.local)) {
                // breaks through the earlier maximum: a number of its own.
                ep.number = (nextNumber[sig] = (nextNumber[sig] ?? 0) + 1);
                ep.breakthrough = f;
                footprints.add(RegionFootprint(sig, ep.number!, local, area, ep));
              }
            } else if (ep.number != null) {
              final fp = footprints.lastWhere((x) => x.sig == sig && x.number == ep.number && identical(x.owner, ep),
                  orElse: () => footprints.firstWhere((x) => x.sig == sig && x.number == ep.number));
              if (identical(fp.owner, ep) && area > fp.area) {
                fp.local = local;
                fp.area = area;
              }
            }
          }
          if (area > ep.peakArea) {
            ep.peakArea = area;
            ep.peakFrame = f;
          }
          nextLive.add((ep, p, 0));
        } else if (!ended.contains(li) && missed < _hysteresis) {
          nextLive.add((ep, lastPiece, missed + 1));
        } else {
          ep.end = ended.contains(li) ? f - 1 : f - missed - 1;
        }
      }
      // pieces born here (or split off): left to right, then top down.
      final born = [
        for (var pi = 0; pi < pieces.length; pi++)
          if (!continued.containsKey(pi)) pi
      ]..sort((a, b) {
          final ca = _centroid(pieces[a]), cb = _centroid(pieces[b]);
          final dx = ca[0] - cb[0];
          return dx.abs() > 0.5 ? dx.sign.toInt() : (ca[1] - cb[1]).sign.toInt();
        });
      for (final pi in born) {
        final p = pieces[pi];
        final ep = RegionEpisode(sig, f)
          ..pieces[f] = p
          ..peakArea = ringsArea(p);
        if (numbering) {
          final local = _map(p, toLocal);
          RegionFootprint? inside;
          for (final fp in footprints) {
            if (fp.sig != sig) continue;
            if (_insideFootprint(local, fp.local) && (inside == null || fp.number < inside.number)) inside = fp;
          }
          if (inside != null) {
            ep.pendingAs = inside.number;
          } else {
            ep.number = (nextNumber[sig] = (nextNumber[sig] ?? 0) + 1);
            footprints.add(RegionFootprint(sig, ep.number!, local, ep.peakArea, ep));
          }
        }
        episodes.add(ep);
        nextLive.add((ep, p, 0));
      }
      active[sig] = nextLive;
    }
  }
  return RegionBake(episodes, footprints);
}

/// An event of the bake: region `sig` (piece `number`) appears or
/// disappears at `frame`.
typedef RegionEvent = ({String kind, int sig, int? number, int frame});

List<RegionEvent> regionEvents(RegionBake bake) => [
      for (final e in bake.episodes) ...[
        (kind: 'appears', sig: e.sig, number: e.numberAt(e.start), frame: e.start),
        if (e.end != null) (kind: 'disappears', sig: e.sig, number: e.numberAt(e.end!), frame: e.end! + 1),
      ]
    ];

/// The opacity of region `sig` (or its piece `number`) at `globalFrame`:
/// its own keys, then every command that fired by then - each from the
/// value it found to its own, over its frames.
double regionOpacityAt(Project project, Layer layer, RegionBake bake, int sig, int? number, int globalFrame) {
  final mr = layer.maskRegions!;
  final lf = layerLocalFrame(layer, globalFrame);
  final t = mr.opacity[sig];
  double base(num frame) =>
      t == null ? 0 : (evaluateTrack(project, t, layerLocalFrame(layer, frame.round()), layer) as num).toDouble();
  final fired = <(int, RegionCommand)>[];
  if (mr.commands.isNotEmpty) {
    final events = regionEvents(bake);
    for (final c in mr.commands) {
      if (c.targetSig != sig || (c.targetNumber != null && c.targetNumber != number)) continue;
      for (final ev in events) {
        if (ev.kind != c.when || ev.sig != c.whenSig) continue;
        if (c.whenNumber != null && ev.number != c.whenNumber) continue;
        if (ev.frame <= globalFrame) fired.add((ev.frame, c));
      }
    }
    fired.sort((a, b) => a.$1.compareTo(b.$1));
  }
  // the value at frame f with the first k commands.
  double at(int f, int k) {
    if (k == 0) return base(f);
    final (e, c) = fired[k - 1];
    if (f < e) return at(f, k - 1);
    final from = at(e, k - 1);
    if (!c.timed || c.frames <= 0) return c.opacity;
    final x = ((f - e) / c.frames).clamp(0.0, 1.0);
    final ease = easingPresets[c.ease] ?? easingPresets['linear']!;
    return from + (c.opacity - from) * easeProgress(ease, x);
  }

  final v = fired.isEmpty ? base(globalFrame) : at(globalFrame, fired.length);
  return lf.isNaN ? 0 : v.clamp(0.0, 1.0);
}

/// Whether any command aims at a numbered piece of `sig` (then its pieces
/// are drawn one by one).
bool regionHasPieceCommands(MaskRegions mr, int sig) =>
    mr.commands.any((c) => c.targetSig == sig && c.targetNumber != null);

/// "inside Circle, outside Square" for a signature.
String regionInWords(Project project, MaskRegions mr, int sig) => [
      for (var i = 0; i < mr.sources.length; i++)
        '${(sig >> i) & 1 == 1 ? 'inside' : 'outside'} ${findLayer(project, mr.sources[i])?.name ?? '?'}'
    ].join(', ');

/// For tests and debugging: the bake as plain data (bit-identical check).
String regionBakeFingerprint(RegionBake b) => jsonEncode([
      for (final e in b.episodes)
        [e.sig, e.start, e.end, e.number, e.pendingAs, e.breakthrough, e.peakFrame, e.peakArea.toStringAsFixed(6)]
    ]);

/// A region named by its layers: "Rect 1 + Rect 2" where both are,
/// "Rect 1 − Rect 2" for Rect 1 without its overlap with Rect 2 (swap
/// them: the other one), "Stage − Rect 1 − Rect 2" outside all.
String regionName(Project project, MaskRegions mr, int sig) {
  final names = [for (final id in mr.sources) findLayer(project, id)?.name ?? '?'];
  if (names.isEmpty) return 'Everything';
  final inside = [for (var i = 0; i < names.length; i++) if ((sig >> i) & 1 == 1) names[i]];
  final outside = [for (var i = 0; i < names.length; i++) if ((sig >> i) & 1 == 0) names[i]];
  final plus = inside.isEmpty ? 'Stage' : inside.join(' + ');
  return outside.isEmpty ? plus : '$plus − ${outside.join(' − ')}';
}

/// An owned region's label: for a layer that is one of the shapes, its
/// overlaps carry the owner ("Rect 1 + Rect 2 · Rect 2" - the overlap
/// exists once per owner) and its outside is "Outer"; otherwise the name.
String regionLabel(Project project, Layer layer, int sig) {
  final mr = layer.maskRegions!;
  if (regionSelfIndex(layer) == null) return regionName(project, mr, sig);
  if (sig == 0) return 'Outer';
  final both = (sig & (sig - 1)) != 0;
  return both ? '${regionName(project, mr, sig)} · ${layer.name}' : regionName(project, mr, sig);
}
