import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';

/// Height of one detail row under the focused layer.
const double detailRowHeight = 12;

/// How many detail rows the focused layer shows now.
int detailRowCount(AppState app, Layer layer) =>
    effectRowCount(app, layer) + maskRowCount(app, layer) + (app.showKeyRows ? keyDetailRows(layer).length : 0);

/// The mask time lines' rows (after the effects'); with mask regions, the
/// rows of their episodes.
int maskRowCount(AppState app, Layer layer) {
  // mask regions: their areas' rows show under the selected layer by
  // themselves.
  if (_regionsOn(layer)) return regionEpisodeRows(app.project, layer).length;
  if (!app.showMaskRows) return 0;
  return layer.masks.length;
}

/// Whether the layer's mask regions are on (their rows show).
bool regionRowsOn(Layer layer) => _regionsOn(layer);

bool _regionsOn(Layer layer) =>
    layer.maskRegions != null && layer.maskRegions!.enabled && layer.maskRegions!.sources.isNotEmpty;

/// The layer's region episodes in rows: a row per area (its pieces that
/// overlap in time stack in more rows of that area), the overlaps of most
/// shapes first. The outside of all isn't shown.
List<List<RegionEpisode>> regionEpisodeRows(Project project, Layer layer) {
  final owned = ownedRegionSigs(layer).toSet();
  final eps = [
    for (final e in regionEpisodesReady(project, layer).episodes)
      if (e.sig != 0 && owned.contains(e.sig)) e
  ];
  int bits(int s) => s == 0 ? 0 : (s & 1) + bits(s >> 1);
  final sigs = {for (final e in eps) e.sig}.toList()
    ..sort((a, b) => bits(b) != bits(a) ? bits(b).compareTo(bits(a)) : a.compareTo(b));
  final rows = <List<RegionEpisode>>[];
  final last = layer.startFrame + layer.durationFrames;
  for (final sig in sigs) {
    final mine = [for (final e in eps) if (e.sig == sig) e]..sort((a, b) => a.start.compareTo(b.start));
    final ends = <int>[];
    final start = rows.length;
    for (final e in mine) {
      var r = ends.indexWhere((x) => x < e.start);
      if (r < 0) {
        rows.add([]);
        ends.add(-1);
        r = ends.length - 1;
      }
      rows[start + r].add(e);
      ends[r] = e.end ?? last;
    }
  }
  return rows;
}

/// Mask regions on the timeline: each episode (a piece's life) is a bar
/// with its region's name, stacked when they overlap. A bar still open at
/// the end has a dashed end; a repeat that breaks through shows its old
/// number up to a marker, its own after. Tapping a bar picks that region
/// and jumps to its largest frame.
class RegionEpisodeRows extends StatelessWidget {
  final AppState app;
  final Layer layer;
  final double pixelsPerFrame;
  const RegionEpisodeRows({super.key, required this.app, required this.layer, required this.pixelsPerFrame});

  @override
  Widget build(BuildContext context) {
    final rows = regionEpisodeRows(app.project, layer);
    final last = layer.startFrame + layer.durationFrames;
    return Stack(clipBehavior: Clip.none, children: [
      for (var r = 0; r < rows.length; r++)
        for (final e in rows[r])
          Positioned(
            key: ValueKey('region-episode-${e.key()}'),
            left: e.start * pixelsPerFrame,
            top: r * detailRowHeight,
            width: math.max(4.0, ((e.end ?? last) - e.start + 1) * pixelsPerFrame),
            height: detailRowHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                app.selectRegion(e.sig, e.numberAt(e.peakFrame));
                app.setFrame(e.peakFrame);
              },
              child: CustomPaint(
                painter: _EpisodePainter(
                  label: regionLabel(app.project, layer, e.sig),
                  numberBefore: e.breakthrough != null ? e.pendingAs : e.numberAt(e.start),
                  numberAfter: e.number,
                  breakX: e.breakthrough == null ? null : (e.breakthrough! - e.start) * pixelsPerFrame,
                  open: e.end == null,
                  selected: app.selectedRegionSig == e.sig &&
                      (app.selectedRegionNumber == null || app.selectedRegionNumber == e.numberAt(e.peakFrame)),
                ),
              ),
            ),
          ),
    ]);
  }
}

class _EpisodePainter extends CustomPainter {
  final String label;
  final int? numberBefore, numberAfter;
  final double? breakX;
  final bool open, selected;
  _EpisodePainter(
      {required this.label,
      this.numberBefore,
      this.numberAfter,
      this.breakX,
      required this.open,
      required this.selected});

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final paint = Paint()
      ..color = maskSpanColor.withOpacity(selected ? 1 : 0.7)
      ..strokeWidth = selected ? 5 : 3;
    final solidEnd = open ? math.max(0.0, size.width - 12) : size.width;
    canvas.drawLine(Offset(0, cy), Offset(solidEnd, cy), paint);
    if (open) {
      // still going where the bake ends: a dashed end.
      for (var x = solidEnd; x < size.width; x += 4) {
        canvas.drawLine(Offset(x, cy), Offset(math.min(x + 2, size.width), cy), paint);
      }
    }
    final b = breakX;
    if (b != null) {
      canvas.drawLine(Offset(b, 0), Offset(b, size.height), Paint()
        ..color = const Color(0xFFFF9800)
        ..strokeWidth = 2);
    }
    void text(String t, double x) {
      final tp = TextPainter(
          text: TextSpan(text: t, style: const TextStyle(fontSize: 8, color: Colors.white)),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(x + 2, cy - tp.height / 2));
    }

    text('$label${numberBefore == null ? '' : ' #$numberBefore'}', 0);
    if (b != null && numberAfter != null) text('#$numberAfter', b);
  }

  @override
  bool shouldRepaint(covariant _EpisodePainter old) =>
      old.label != label ||
      old.numberBefore != numberBefore ||
      old.numberAfter != numberAfter ||
      old.breakX != breakX ||
      old.open != open ||
      old.selected != selected;
}

/// Mask time lines: their own colour (teal, half see-through).
const maskSpanColor = Color(0x9980CBC4);

/// The effect lines' rows (they come first).
int effectRowCount(AppState app, Layer layer) => app.showEffectRows ? effectSpans(layer).length : 0;

/// Every effect line in one colour (purple).
const _effectColors = [Color(0x99B388FF)]; // half-see-through purple

/// Each params tab's colour in the expanded key view (its key shape is
/// its own too, see _KeyShapePainter).
const keyDetailColors = {
  'Movement': Color(0xFFFFD54F),
  'Effects': Color(0xFFB388FF), // purple, like the effect lines
  'Masks': Color(0xFF4DB6AC),
  'Figures': Color(0xFFFF8A65),
  'Filters': Color(0xFFE0E0E0),
  'Audio': Color(0xFF81C784),
  'Text': Color(0xFFFF9800), // orange
  'Line': Color(0xFF4FC3F7),
};

/// An effect line's colour (its place in the Effects tab's list).
Color effectSpanColor(Layer layer, String id) {
  final i = effectSpans(layer).indexWhere((s) => s.id == id);
  return _effectColors[(i < 0 ? 0 : i) % _effectColors.length];
}

/// A row's colour; an animation layer's row is the Movement colour, lighter.
Color keyDetailColor(String tab) => keyDetailColors[tab] ?? keyDetailColors['Movement']!;

/// Effect time ranges: a thin line per effect, each in its own row (so
/// overlapping effects never hide each other). Tapping a line edits it:
/// it thickens, the other lines and the layer dim, and two indicators
/// across the whole timeline (like the range's) mark its edges - drag
/// them to change its range. Tapping it again ends the edit.
class EffectSpanRows extends StatelessWidget {
  final AppState app;
  final Layer layer;
  final double pixelsPerFrame;
  final ValueChanged<bool> onDragActiveChanged;
  const EffectSpanRows(
      {super.key, required this.app, required this.layer, required this.pixelsPerFrame, required this.onDragActiveChanged});

  @override
  Widget build(BuildContext context) {
    final spans = effectSpans(layer);
    final editing = app.editingEffectId;
    double x(int local) => (layer.startFrame + local) * pixelsPerFrame;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (var i = 0; i < spans.length; i++) ...() {
          final s = spans[i];
          final color = _effectColors[i % _effectColors.length];
          final isEditing = editing == s.id;
          final dim = editing != null && !isEditing;
          final top = i * detailRowHeight;
          return [
            Positioned(
              key: ValueKey('effect-span-${s.id}'),
              left: x(s.start),
              top: top,
              width: math.max(4.0, x(s.end) - x(s.start)),
              height: detailRowHeight,
              child: Tooltip(
                message: s.label,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    app.setEditingEffect(s.id);
                    if (app.editingEffectId != null) app.showTab('Effects');
                  },
                  child: Center(
                    child: Container(
                      height: isEditing ? 5 : 2,
                      decoration: BoxDecoration(
                        color: color.withOpacity(dim ? 0.3 : 1),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ];
        }(),
      ],
    );
  }
}

/// Mask time: a thin line per mask, each in its own row. Tapping a line
/// edits it (two indicators across the timeline mark its edges - drag
/// them); tapping it again ends the edit.
class MaskSpanRows extends StatelessWidget {
  final AppState app;
  final Layer layer;
  final double pixelsPerFrame;
  const MaskSpanRows({super.key, required this.app, required this.layer, required this.pixelsPerFrame});

  @override
  Widget build(BuildContext context) {
    final spans = maskSpans(layer);
    final editing = app.editingMaskIndex;
    double x(int local) => (layer.startFrame + local) * pixelsPerFrame;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final s in spans)
          Positioned(
            key: ValueKey('mask-span-${s.index}'),
            left: x(s.start),
            top: s.index * detailRowHeight,
            width: math.max(4.0, x(s.end) - x(s.start)),
            height: detailRowHeight,
            child: Tooltip(
              message: 'mask ${s.index + 1}',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  app.setEditingMask(s.index);
                  if (app.editingMaskIndex != null) app.showTab('Masks');
                },
                child: Center(
                  child: Container(
                    height: editing == s.index ? 5 : 2,
                    decoration: BoxDecoration(
                      color: maskSpanColor.withOpacity(editing != null && editing != s.index ? 0.3 : 0.6),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The expanded key view: a row per params tab with keys (each tab its
/// own colour and shape) and lines between them where the animation runs.
/// Tapping a line selects it, opens its tab and puts the playhead in its
/// middle; the selected line's delete button removes both its keys.
class KeyDetailRows extends StatefulWidget {
  final AppState app;
  final Layer layer;
  final double pixelsPerFrame;
  const KeyDetailRows({super.key, required this.app, required this.layer, required this.pixelsPerFrame});

  @override
  State<KeyDetailRows> createState() => _KeyDetailRowsState();
}

class _KeyDetailRowsState extends State<KeyDetailRows> {
  double? _dragX;
  int _moved = 0;
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final layer = widget.layer;
    final rows = keyDetailRows(layer);
    final spans = keyDetailSpans(layer);
    double x(int local) => (layer.startFrame + local) * widget.pixelsPerFrame;
    var sel = app.keyDetailSelection;
    if (sel != null &&
        (sel.layerId != layer.id ||
            !(spans[sel.tab]?.any((s) => s.a == sel!.a && s.b == sel.b && (sel.track == null || s.track == sel.track)) ??
                false))) {
      sel = null;
    }
    // contour physics: where pushes start / end, on the Movement row (to
    // see, not to drag).
    final pushMarkers = layer.physics.collide
        ? [for (final f in physicsWorldOf(app.project).contactMarkers(layer.id)) (f - layer.startFrame) * 1.0]
        : const <double>[];
    final tabs = rows.keys.toList();
    final width = x(layer.durationFrames) + 40;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (var r = 0; r < tabs.length; r++)
          Positioned(
            key: ValueKey('key-detail-${tabs[r]}'),
            left: 0,
            top: r * detailRowHeight,
            width: width,
            height: detailRowHeight,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (d) =>
                  _tapRow(tabs[r], spans[tabs[r]] ?? const [], d.localPosition.dx / widget.pixelsPerFrame - layer.startFrame),
              // the selected line drags sideways: both its keys move.
              onHorizontalDragStart: sel?.tab == tabs[r]
                  ? (d) {
                      final f = d.localPosition.dx / widget.pixelsPerFrame - layer.startFrame;
                      final s = app.keyDetailSelection;
                      if (s == null || f < s.a - 2 || f > s.b + 2) return;
                      app.pushUndo();
                      _dragX = d.localPosition.dx;
                      _moved = 0;
                    }
                  : null,
              onHorizontalDragUpdate: sel?.tab == tabs[r]
                  ? (d) {
                      final x0 = _dragX;
                      if (x0 == null) return;
                      final total = ((d.localPosition.dx - x0) / widget.pixelsPerFrame).round();
                      if (total == _moved) return;
                      app.moveSelectedKeySpan(total - _moved, total - _moved);
                      _moved = total;
                    }
                  : null,
              onHorizontalDragEnd: (_) => _dragX = null,
              child: CustomPaint(
                painter: _KeyRowPainter(
                  xs: [for (final f in rows[tabs[r]]!) x(f)],
                  spans: [for (final s in spans[tabs[r]] ?? const <KeySpan>[]) (x(s.a), x(s.b))],
                  markers: tabs[r] == 'Movement' ? [for (final f in pushMarkers) f * widget.pixelsPerFrame + x(0)] : const [],
                  color: keyDetailColor(tabs[r]),
                  // the text's and the line's keys: diamonds like the
                  // Movement row's.
                  shape: tabs[r].startsWith('Layer ') || tabs[r] == 'Text' || tabs[r] == 'Line' ? 'Movement' : tabs[r],
                  selected: [
                    for (final s in [if (sel != null) sel, ...app.keyDetailExtra])
                      if (s.layerId == layer.id && s.tab == tabs[r]) (x(s.a), x(s.b))
                  ],
                  // order keys: an open range trails to the playhead.
                  trailTo: _openTrail(tabs[r], rows[tabs[r]]!) ? x(app.currentFrame - layer.startFrame) : null,
                ),
              ),
            ),
          ),
      ],
    );
  }

  bool _openTrail(String tab, List<int> frames) {
    if (!tab.startsWith('Layer ') || frames.length != 1) return false;
    return openOrderLayer(widget.layer) == int.tryParse(tab.substring(6));
  }

  /// Tapping a line selects it (its delete button is in the layer's action
  /// row), opens its tab and puts the playhead in its middle; tapping it
  /// again, or off any line, clears the selection.
  void _tapRow(String tab, List<KeySpan> spans, double localFrame) {
    final app = widget.app;
    // the line of ONE parameter under the finger - the shortest one
    // where several overlap.
    KeySpan? best;
    for (final s in spans) {
      if (localFrame < s.a || localFrame > s.b) continue;
      if (best == null || s.b - s.a < best.b - best.a) best = s;
    }
    if (best != null) {
      final hit = (layerId: widget.layer.id, tab: tab, a: best.a, b: best.b, track: best.track as String?);
      // select several: lines add up.
      if (app.timelineGroupPick) {
        app.toggleKeyDetailExtra(hit);
        return;
      }
      if (app.keyDetailSelection == hit) {
        app.selectKeyDetailSpan(null);
        return;
      }
      app.selectKeyDetailSpan(hit);
      // its tab is the one the sheet opens on next (not opened now).
      app.showTab(tab.startsWith('Layer ') ? 'Keyframes' : tab, open: false);
      app.setFrame(widget.layer.startFrame + ((hit.a + hit.b) / 2).round());
      return;
    }
    app.selectKeyDetailSpan(null);
  }
}

class _KeyRowPainter extends CustomPainter {
  final List<double> xs;
  final List<(double, double)> spans;
  final List<double> markers;
  final Color color;
  final String shape;
  final List<(double, double)> selected;
  final double? trailTo;
  _KeyRowPainter(
      {required this.xs,
      required this.color,
      required this.shape,
      this.spans = const [],
      this.markers = const [],
      this.selected = const [],
      this.trailTo});

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    // the lines in the keys' own colour, not faded.
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    // each parameter's own lines (they may overlap).
    for (final s in spans) {
      canvas.drawLine(Offset(s.$1, cy), Offset(s.$2, cy), line);
    }
    // physics push markers: squares, not keys.
    for (final m in markers) {
      canvas.drawRect(Rect.fromCenter(center: Offset(m, cy), width: 6, height: 6), Paint()..color = color);
    }
    // an open order-key range: dashes from its key to the playhead.
    final t = trailTo;
    if (t != null && xs.isNotEmpty) {
      final dash = Paint()
        ..color = color.withOpacity(0.5)
        ..strokeWidth = 1.5;
      final dir = t >= xs.first ? 1.0 : -1.0;
      for (var x0 = xs.first; dir * (t - x0) > 0; x0 += dir * 6) {
        final x1 = dir > 0 ? (x0 + 3 < t ? x0 + 3 : t) : (x0 - 3 > t ? x0 - 3 : t);
        canvas.drawLine(Offset(x0, cy), Offset(x1, cy), dash);
      }
    }
    const r = 3.5;
    // selected: as thick as the keys are tall (up to the diamonds' tips).
    for (final sel in selected) {
      canvas.drawLine(Offset(sel.$1, cy), Offset(sel.$2, cy), Paint()
        ..color = color
        ..strokeWidth = 2 * r);
    }
    final fill = Paint()..color = color;
    for (final x in xs) {
      final c = Offset(x, cy);
      switch (shape) {
        case 'Movement':
          canvas.drawPath(
              Path()
                ..moveTo(x, cy - r)
                ..lineTo(x + r, cy)
                ..lineTo(x, cy + r)
                ..lineTo(x - r, cy)
                ..close(),
              fill);
        case 'Effects':
          canvas.drawCircle(c, r, fill);
        case 'Masks':
          canvas.drawRect(Rect.fromCenter(center: c, width: 2 * r - 1, height: 2 * r - 1), fill);
        case 'Figures':
          canvas.drawPath(
              Path()
                ..moveTo(x, cy - r)
                ..lineTo(x + r, cy + r)
                ..lineTo(x - r, cy + r)
                ..close(),
              fill);
        default:
          canvas.drawRect(Rect.fromCenter(center: c, width: 2, height: 2 * r), fill);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _KeyRowPainter old) =>
      old.color != color ||
      old.shape != shape ||
      old.selected.join() != selected.join() ||
      old.trailTo != trailTo ||
      old.xs.join() != xs.join() ||
      old.spans.join() != spans.join() ||
      old.markers.join() != markers.join();
}
