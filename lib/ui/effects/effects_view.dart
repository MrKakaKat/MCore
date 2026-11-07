import 'dart:math' as math;

import 'package:flutter/material.dart' hide Easing;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/color_row.dart';
import '../common/hint.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';
import '../graph_editor/graph_editor_view.dart';

/// Ported from movement-core/src/ui/paramsPanel/effectsSection.js - the
/// layer's effect stack (enable/reorder/delete, generic per-param
/// fields, corner_pin's "Confirm shape" bake, mesh_warp's pin-reset) plus
/// the three per-layer add-on modifiers that aren't vertex-deformation
/// effects (motion blur, wiggle, pendulum), grouped here the same way
/// JS groups them - visually distinct from the effect stack, but still
/// under "effects" rather than "movement".
///
/// Unlike JS's `if(layer.motionBlur)`/`if(layer.wiggle)`/
/// `if(layer.pendulum)` presence checks (meaningful in JS, where a layer
/// created before those features existed might lack the field entirely),
/// this port's `Layer` always constructs default `MotionBlur()`/
/// `Wiggle()`/`Pendulum()` instances (see model/project.dart) - so these
/// sections are always shown here, gated only on their own `enabled`
/// flag, same as JS's own inner gating once the presence check passes.
///
/// UNVERIFIED like the rest of ui/.
class EffectsView extends StatelessWidget {
  final AppState app;

  /// The Contour tab: the layer's contour and its physics. The Effects
  /// tab shows every effect (Outline too), by type.
  final bool contour;
  const EffectsView({super.key, required this.app, this.contour = false});

  /// The types the Effects tab sorts its effects into.
  static String typeOf(Layer layer, String id) {
    switch (id) {
      case 'wiggle' || 'pendulum' || 'swing':
        return 'Motion';
      case 'motionBlur' || 'timeQuantize':
        return 'Time';
    }
    final inst = layer.effectStack.where((e) => e.id == id).firstOrNull;
    if (inst?.effectId == 'outline') return 'Contour';
    return 'Shape';
  }

  static const effectTypes = ['Shape', 'Contour', 'Motion', 'Time'];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) return const Center(child: Text('No layer selected'));
        final localFrame = layerLocalFrame(layer, app.currentFrame);
        final entries = effectPanelEntries(layer);
        if (contour) {
          return ListView(
            padding: const EdgeInsets.all(8),
            children: [
              SwitchListTile(
                key: ValueKey('contour-show-${layer.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Show contour'),
                subtitle: hint('The rings the outline and physics follow, over the stage (outers orange, holes cyan). '
                    'Outline is in the Effects tab'),
                value: app.contourDebugLayers.contains(layer.id),
                onChanged: (_) => app.toggleContourDebug(layer.id),
              ),
              const Divider(height: 16),
              _physicsSection(context, layer),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            // by type: shape (deform), motion, time.
            for (final type in effectTypes)
              if (entries.any((id) => typeOf(layer, id) == type)) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 2),
                  child: Text(type, key: ValueKey('fx-type-$type'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                _effectList(context, layer, localFrame, [for (final id in entries) if (typeOf(layer, id) == type) id]),
              ],
            _addEffectRow(layer),
            // confirmed shapes: pick up the editing where it was.
            if (layer.confirmHistory.isNotEmpty) ...[
              const Divider(height: 16),
              const Text('Confirmed shapes', style: TextStyle(fontWeight: FontWeight.bold)),
              for (var i = layer.confirmHistory.length - 1; i >= 0; i--)
                ListTile(
                  key: ValueKey('fx-confirmed-$i'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history, size: 18),
                  title: Text('${layer.confirmHistory[i]['label']}'),
                  subtitle: Text(i == layer.confirmHistory.length - 1
                      ? 'the last one'
                      : '${layer.confirmHistory.length - 1 - i} later one(s) go too'),
                  trailing: TextButton(
                    key: ValueKey('fx-resume-$i'),
                    onPressed: () {
                      app.pushUndo();
                      resumeConfirm(layer, i);
                      app.commitEdit();
                    },
                    child: const Text('Edit again'),
                  ),
                ),
            ],
            const Divider(height: 16),
            _followSection(context, layer, localFrame),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------
  // effect stack
  // ---------------------------------------------------------------

  /// One list for every effect on the layer - geometry effects and the
  /// motion add-ons (motion blur, wiggle, pendulum) alike - each a card
  /// with a drag handle on its side, a collapse toggle and a remove
  /// button. Dragging reorders the list (and the geometry render order).
  Widget _effectList(BuildContext context, Layer layer, double localFrame, List<String> entries) {
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      // reordering within a type: the others keep their places.
      onReorder: (from, to) {
        app.pushUndo();
        final group = [...entries];
        final moved = group.removeAt(from);
        group.insert((from < to ? to - 1 : to).clamp(0, group.length), moved);
        final all = effectPanelEntries(layer);
        final slots = [for (var i = 0; i < all.length; i++) if (entries.contains(all[i])) i];
        for (var k = 0; k < slots.length; k++) {
          all[slots[k]] = group[k];
        }
        setEffectPanelOrder(layer, all);
        app.commitEdit();
      },
      children: [
        for (var i = 0; i < entries.length; i++)
          KeyedSubtree(
            key: ValueKey('fx-card-${entries[i]}'),
            child: _entryCard(context, layer, entries[i], i, localFrame),
          ),
      ],
    );
  }

  /// Collapsed cards, per layer + entry, for the session.
  static final Set<String> _collapsed = {};

  Widget _entryCard(BuildContext context, Layer layer, String id, int index, double localFrame) {
    final inst = layer.effectStack.where((e) => e.id == id).firstOrNull;
    final title = inst != null ? effectRegistry[inst.effectId]!.name : motionPanelNames[id]!;
    final collapseKey = '${layer.id}/$id';
    return StatefulBuilder(builder: (context, setLocal) {
      final collapsed = _collapsed.contains(collapseKey);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 4, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.drag_indicator, size: 18, color: Colors.grey),
                      ),
                    ),
                    if (inst != null)
                      Checkbox(
                        value: inst.enabled,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) {
                          inst.enabled = v ?? true;
                          app.commitEdit();
                        },
                      ),
                    Expanded(child: Text('${index + 1}. $title')),
                    IconButton(
                      icon: Icon(collapsed ? Icons.expand_more : Icons.expand_less, size: 18),
                      tooltip: collapsed ? 'expand' : 'collapse',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setLocal(() {
                        collapsed ? _collapsed.remove(collapseKey) : _collapsed.add(collapseKey);
                      }),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 16),
                      tooltip: 'copy effect',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => app.copyEffectEntry(layer.id, id),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      tooltip: 'remove effect',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        if (inst != null) {
                          _deleteInstance(layer, inst);
                        } else {
                          app.pushUndo();
                          removeMotionPanelEntry(layer, id);
                          app.commitEdit();
                        }
                      },
                    ),
                  ],
                ),
                if (!collapsed)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: inst != null
                        ? _instanceBody(context, layer, inst, localFrame)
                        : switch (id) {
                            'motionBlur' => _motionBlurBody(layer),
                            'wiggle' => _wiggleBody(layer),
                            'timeQuantize' => _timeQuantizeBody(layer),
                            'swing' => _swingBody(layer),
                            _ => _pendulumBody(context, layer),
                          },
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _instanceBody(BuildContext context, Layer layer, EffectInstance inst, double localFrame) {
    if (inst.effectId == 'bend_arc' && !isBendV2(inst)) _withBendBase(inst);
    // bends saved before "react" get it (at its no-op default).
    if (inst.effectId == 'bend_arc' && isBendV2(inst)) inst.params.putIfAbsent('react', () => track(0.0));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (inst.effectId == 'corner_pin') _confirmShapeButton(layer, inst, _confirmCornerPinShape),
        if (inst.effectId == 'mesh_warp') _meshWarpControls(layer, inst),
        if (inst.effectId == 'origami_fold') _origamiControls(inst),
        // colours (Outline): not animated, a palette.
        for (final def in effectRegistry[inst.effectId]?.params ?? const <ParamDef>[])
          if (def.type == 'color')
            ColorRow(
              key: ValueKey('fx-color-${inst.id}-${def.key}'),
              label: def.key,
              hex: inst.params[def.key] as String? ?? def.defaultValue as String,
              onPick: (h) {
                app.pushUndo();
                inst.params[def.key] = h;
                app.commitEdit();
              },
            ),
        if (inst.effectId != 'mesh_warp')
          for (final entry in inst.params.entries)
            if (entry.value is Track &&
                (inst.effectId != 'origami_fold' ||
                    origamiFoldOf(inst.params, entry.key) == null ||
                    origamiFoldOf(inst.params, entry.key) == _origamiSelected(inst)))
              _instanceParamRow(
                  context, inst, entry.key, entry.value as Track, localFrame, _paramDefault(inst, entry.key)),
        // non-animated choices (bend's base axis, 3D Rotate's back side)
        // at the bottom of the effect's settings.
        for (final def in effectRegistry[inst.effectId]?.params ?? const <ParamDef>[])
          if (def.options != null && inst.params[def.key] is String) _enumParamRow(inst, def),
        if (inst.effectId == 'outline')
          SwitchListTile(
            key: ValueKey('show-contour-${layer.id}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Show contour'),
            subtitle: hint('The rings the outline follows, over the stage (outers orange, holes cyan)'),
            value: app.contourDebugLayers.contains(layer.id),
            onChanged: (_) => app.toggleContourDebug(layer.id),
          ),
        if (inst.effectId == 'bend_arc' && isBendV2(inst))
          const Hint('Start / end: the two lines across the bend axis (drag them on the stage). Before the '
            'start nothing moves, between them the shape bends, after the end it is carried along. '
            'Inertia: it lags and rings when the object moves; spring: the angle overshoots its keys.'),
        if (inst.effectId == 'bend_arc' && !isBendV2(inst))
          OutlinedButton(
            key: const ValueKey('convert-bend'),
            onPressed: () {
              app.pushUndo();
              convertLegacyBend(inst);
              app.commitEdit();
            },
            child: const Text('Convert to the new bend (lines, joints, physics)'),
          ),
      ],
    );
  }

  void _deleteInstance(Layer layer, EffectInstance inst) {
    app.pushUndo();
    layer.effectStack.removeWhere((i) => i.id == inst.id);
    app.commitEdit();
  }

  /// "Confirm shape", shared by corner_pin and mesh_warp: bakes the
  /// CURRENTLY deformed outline into a new base polygon shape.
  ///
  /// once baked, a left-behind instance with its params merely reset to zero
  /// is dead weight - the shape's own points already ARE the deformation, so
  /// the instance has nothing left to contribute and just sits in the stack
  /// looking configurable while doing nothing. Disclosed deviation from JS
  /// (whose own corner_pin confirm keeps the zeroed instance around "ready to
  /// keep pinning from the new baseline", per effectsSection.js's own
  /// comment): this port removes the instance from the stack entirely after
  /// baking instead, on both corner_pin and mesh_warp.
  Widget _confirmShapeButton(Layer layer, EffectInstance inst, void Function(Layer, EffectInstance) confirm) {
    // text / vector-text shapes keep the effect live (baking would lose the
    // letters' holes).
    if (layer.content.shape == 'text' || layer.content.shape == 'compound') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: OutlinedButton(
        onPressed: () => confirm(layer, inst),
        child: const Text('Confirm shape'),
      ),
    );
  }

  void _confirmCornerPinShape(Layer layer, EffectInstance inst) {
    app.pushUndo();
    recordConfirm(layer, inst, 'Corner pin', app.currentFrame);
    final localFrame2 = layerLocalFrame(layer, app.currentFrame);
    List<List<double>> baked;
    // exact-N-point mode (triangle/polygon source) deforms the shape's
    // raw vertices directly - those ARE the bake source; bbox mode
    // (rect/circle/ngon) bakes the pinned bounding corners instead.
    if (inst.params.containsKey('p0')) {
      final naturalPts = shapePoints(layer.content);
      final pKeys = inst.params.keys.where((k) => RegExp(r'^p\d+$').hasMatch(k)).toList()
        ..sort((a, b) => int.parse(a.substring(1)).compareTo(int.parse(b.substring(1))));
      baked = [
        for (var i = 0; i < naturalPts.length; i++)
          _addOffset(
              naturalPts[i], evaluateTrack(app.project, inst.params[pKeys[i]] as Track, localFrame2) as List<double>),
      ];
    } else {
      final bbox = shapeBoundingBox(layer.content);
      final natural = <String, List<double>>{
        'tl': [bbox.minX, bbox.minY],
        'tr': [bbox.maxX, bbox.minY],
        'br': [bbox.maxX, bbox.maxY],
        'bl': [bbox.minX, bbox.maxY],
      };
      baked = [
        for (final k in ['tl', 'tr', 'br', 'bl'])
          _addOffset(natural[k]!, evaluateTrack(app.project, inst.params[k] as Track, localFrame2) as List<double>),
      ];
    }
    _bakePolygonAndRemoveInstance(layer, inst, baked);
  }

  List<double> _addOffset(List<double> p, List<double> off) => [p[0] + off[0], p[1] + off[1]];

  void _bakePolygonAndRemoveInstance(Layer layer, EffectInstance inst, List<List<double>> baked) {
    if (baked.length >= 3) {
      final xs = [for (final p in baked) p[0]], ys = [for (final p in baked) p[1]];
      layer.content = Content(
        shape: 'polygon',
        points: baked,
        offset: [0, 0],
        size: [xs.reduce(math.max) - xs.reduce(math.min), ys.reduce(math.max) - ys.reduce(math.min)],
      );
      layer.effectStack.removeWhere((i) => i.id == inst.id);
    }
    app.commitEdit();
  }

  /// Origami: which fold is being set (its settings show below).
  static final Map<String, int> _origamiFold = {};

  int _origamiSelected(EffectInstance inst) {
    final ns = [for (final f in origamiFolds(inst.params)) f.n];
    final n = _origamiFold[inst.id];
    return n != null && ns.contains(n) ? n : ns.first;
  }

  /// A fold's own settings (older saves shared direction / softness): it
  /// gets them, at the shared values.
  void _origamiOwnParams(EffectInstance inst, int n) {
    final f = origamiFolds(inst.params).firstWhere((x) => x.n == n);
    double shared(String k, double d) {
      final t = inst.params[k];
      return t is Track ? ((t.defaultValue as num?)?.toDouble() ?? d) : d;
    }

    inst.params.putIfAbsent(f.direction, () => track(shared('direction', 0)));
    inst.params.putIfAbsent(f.softness, () => track(shared('softness', 0)));
    inst.params.putIfAbsent(f.softShape, () => track(circleRoundK));
    inst.params.putIfAbsent(f.round, () => track(0.0));
    inst.params.putIfAbsent(f.roundShape, () => track(circleRoundK));
    // each fold's rows in one order: a size, then its shape right under it
    // (nothing jumps in between).
    final order = [
      for (final g in origamiFolds(inst.params))
        ...[g.angle, g.direction, g.position, g.softness, g.softShape, g.round, g.roundShape]
    ];
    final entries = [...inst.params.entries];
    int rank(String k) {
      final i = order.indexOf(k);
      return i < 0 ? order.length : i;
    }

    final sorted = [...entries]..sort((a, b) => rank(a.key).compareTo(rank(b.key)));
    if ([for (final e in sorted) e.key].join() != [for (final e in entries) e.key].join()) {
      inst.params
        ..clear()
        ..addEntries(sorted);
    }
  }

  /// Origami: the folds (pick one to set it; add one in a chosen part;
  /// remove), where it lies, the lines on the stage.
  Widget _origamiControls(EffectInstance inst) {
    final folds = origamiFolds(inst.params);
    final sel = _origamiSelected(inst);
    _origamiOwnParams(inst, sel);
    String regionLabel(String r) {
      if (r == 'free') return 'anywhere';
      final parts = r.split(':');
      return parts.length > 1 && parts[1] == 'near' ? 'fold ${parts[0]}: the part that stays' : 'fold ${parts[0]}: its folded part';
    }

    final regions = ['free', for (final f in folds) ...['${f.n}:far', '${f.n}:near']];
    final region = origamiRegion(inst.params, sel);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final f in folds)
          InputChip(
            key: ValueKey('origami-fold-${f.n}'),
            label: Text('fold ${f.n}'),
            selected: f.n == sel,
            visualDensity: VisualDensity.compact,
            onPressed: () {
              _origamiFold[inst.id] = f.n;
              app.notifyListeners();
            },
            onDeleted: f.n == 1
                ? null
                : () {
                    app.pushUndo();
                    removeOrigamiFold(inst, f.n);
                    app.commitEdit();
                  },
          ),
        // a new fold goes in a part of one already there.
        PopupMenuButton<String>(
          key: ValueKey('origami-add-${inst.id}'),
          tooltip: 'add a fold - pick the part it lies in',
          onSelected: (r) {
            app.pushUndo();
            final n = addOrigamiFold(inst, region: r);
            _origamiFold[inst.id] = n;
            app.commitEdit();
          },
          itemBuilder: (_) => [
            for (final r in regions.skip(1)) PopupMenuItem(value: r, child: Text('In ${regionLabel(r)}')),
            const PopupMenuItem(value: 'free', child: Text('Anywhere (across the others)')),
          ],
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.add, size: 16), SizedBox(width: 4), Text('Add fold')]),
          ),
        ),
      ]),
      if (sel != 1)
        Row(children: [
          const Text('Lies in', style: TextStyle(fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<String>(
              key: ValueKey('origami-region-${inst.id}'),
              isExpanded: true,
              value: regions.contains(region) ? region : 'free',
              items: [
                for (final r in regions)
                  if (!r.startsWith('$sel:'))
                    DropdownMenuItem(value: r, child: Text(r == 'free' ? 'anywhere (folds across the others)' : regionLabel(r)))
              ],
              onChanged: (v) {
                if (v == null) return;
                app.pushUndo();
                setOrigamiRegion(inst, sel, v);
                app.commitEdit();
              },
            ),
          ),
        ]),
      if (sel != 1) hint('In a part: the fold only bends that part (and moves with it). Anywhere: its crease folds every part it crosses.') ?? const SizedBox.shrink(),
      OutlinedButton.icon(
        key: ValueKey('origami-two-points-${inst.id}'),
        onPressed: () => app.startOrigamiPick(inst.id, sel),
        icon: Icon(app.origamiPick != null ? Icons.ads_click : Icons.timeline, size: 16),
        label: Text(app.origamiPick != null ? 'Tap two points on the shape...' : 'Fold \$sel through two points'),
      ),
      // shapes joined to the paper: they fold with it where they lie past
      // a crease (or along an edge, at its angle).
      OutlinedButton.icon(
        key: ValueKey('origami-attach-${inst.id}'),
        onPressed: () {
          final l = findLayer(app.project, app.selection.selectedLayer);
          if (l != null) app.startParentPick(l.id);
        },
        icon: const Icon(Icons.link, size: 16),
        label: const Text('Attach shapes (they fold with it)'),
      ),
      SwitchListTile(
        key: ValueKey('origami-stage-${inst.id}'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Move folds on the stage'),
        subtitle: hint('Drag a line\'s middle dot to move it, its end dot to turn it'),
        value: origamiFoldsOnStage,
        onChanged: (v) {
          origamiFoldsOnStage = v;
          app.notifyListeners();
        },
      ),
      SwitchListTile(
        key: ValueKey('origami-flat-${inst.id}'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Lines on the flat shape'),
        subtitle: hint('Off: the creases sit on the folded paper and move with it'),
        value: origamiLinesOnFlat,
        onChanged: (v) {
          origamiLinesOnFlat = v;
          app.notifyListeners();
        },
      ),
    ]);
  }

  /// mesh_warp's per-param UI is a "too many fields" case (16+ pins) -
  /// primary interaction is dragging directly on the stage. Offers
  /// "reset all pins" (wipe back to neutral, keep editing) and the same
  /// "Confirm shape" bake corner_pin has (freeze the current warp into
  /// the shape's own points, then drop the instance).
  Widget _meshWarpControls(Layer layer, EffectInstance inst) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Hint('${inst.params['rows']}×${inst.params['cols']} pins - drag directly on the stage', fontSize: 10),
          Row(
            children: [
              OutlinedButton(onPressed: () => _resetMeshPins(inst), child: const Text('Reset all pins')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => _confirmMeshWarpShape(layer, inst), child: const Text('Confirm shape')),
            ],
          ),
        ],
      ),
    );
  }

  void _resetMeshPins(EffectInstance inst) {
    app.pushUndo();
    for (final v in inst.params.values) {
      if (v is Track) {
        v.defaultValue = [0.0, 0.0];
        v.keyframes.clear();
      }
    }
    app.commitEdit();
  }

  /// bakes mesh_warp's OWN deformation only (not the layer's whole
  /// effect stack, in case other effects are also active) into a new
  /// polygon shape, via the SAME apply() function the renderer itself
  /// calls, fed an undeformed grid built to this instance's own
  /// rows/cols - matching corner_pin's scoped bake instead of using
  /// getContentOutline (which would bake the FULL stack's cumulative
  /// deformation, double-applying any other still-active effect).
  void _confirmMeshWarpShape(Layer layer, EffectInstance inst) {
    app.pushUndo();
    recordConfirm(layer, inst, 'Mesh warp', app.currentFrame);
    final def = effectRegistry[inst.effectId]!;
    final rows = inst.params['rows'] as int;
    final cols = inst.params['cols'] as int;
    final localFrame2 = layerLocalFrame(layer, app.currentFrame);
    final resolvedParams = resolveEffectParams(inst, localFrame2);
    final srcGrid = buildGrid(layer.content, cols, rows);
    final dstGrid = def.apply(srcGrid, resolvedParams, localFrame2);
    final boundary = [
      ...dstGrid[0],
      ...dstGrid.sublist(1).map((row) => row[cols - 1]),
      ...dstGrid[rows - 1].sublist(0, cols - 1).reversed,
      ...dstGrid.sublist(0, rows - 1).reversed.map((row) => row[0]),
    ];
    _bakePolygonAndRemoveInstance(layer, inst, boundary);
  }

  /// bend_arc's `baseAxis` is a non-animatable enum param (see
  /// bend_arc.dart's ParamDef) - stored as a plain string, not a Track,
  /// so it never shows up in the generic per-Track param loop below and
  /// needs its own dropdown, same as mesh_warp's rows/cols note.
  Widget _enumParamRow(EffectInstance inst, ParamDef def) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(capitalizeLabel(_paramLabels[def.key] ?? def.key), style: const TextStyle(fontSize: 12))),
          DropdownButton<String>(
            value: inst.params[def.key] as String,
            items: [for (final o in def.options!) DropdownMenuItem(value: o, child: Text(o))],
            onChanged: (v) {
              if (v == null) return;
              app.pushUndo();
              inst.params[def.key] = v;
              app.commitEdit();
            },
          ),
          const Spacer(),
          ResetIconButton(onPressed: () {
            app.pushUndo();
            inst.params[def.key] = def.defaultValue;
            app.commitEdit();
          }),
        ],
      ),
    );
  }

  dynamic _paramDefault(EffectInstance inst, String key) {
    if (inst.effectId == 'origami_fold' && key.endsWith('_angle')) return 45.0;
    if (inst.effectId == 'origami_fold' && key.endsWith('_position')) return 0.75;
    if (inst.effectId == 'origami_fold' && (key.endsWith('_direction') || RegExp(r'^direction\d$').hasMatch(key))) return 0.0;
    if (inst.effectId == 'origami_fold' && (key.endsWith('_softness') || key.endsWith('_round') || RegExp(r'^(softness|round)\d$').hasMatch(key))) return 0.0;
    if (inst.effectId == 'origami_fold' && key.contains('Shape')) return circleRoundK;
    final defs = effectRegistry[inst.effectId]?.params ?? const <ParamDef>[];
    final def = defs.where((p) => p.key == key);
    final v = def.isEmpty ? const [0.0, 0.0] : def.first.defaultValue;
    return v is List ? [for (final e in v) (e as num).toDouble()] : (v as num).toDouble();
  }

  static const _paramLabels = {
    'base': 'base height',
    'baseAxis': 'base',
    'axisAngle': 'axis angle',
    'start': 'start line',
    'end': 'end line',
    'inertia': 'inertia',
    'spring': 'spring',
    'frequency': 'frequency (Hz)',
    'damping': 'damping',
    'react': 'gives when pushed % (Collide on)',
    'pivot': 'pivot (0-1)',
    'softShape': 'softness shape (0 cut, 0.55 circle, 1 sharp)',
    'round': 'round the crease',
    'roundShape': 'rounding shape (0 cut, 0.55 circle, 1 sharp)',
  };

  /// Bend instances saved before the "base height" param existed get it
  /// (at its no-op default) so its row shows up.
  void _withBendBase(EffectInstance inst) {
    inst.params.putIfAbsent('base', () => track(0.0));
  }

  /// Slider or endless ruler for an effect param: a range spanning a full
  /// turn or more (angles) or no range at all -> ruler; otherwise a
  /// slider over the range.
  ParamScale _scaleFor(EffectInstance inst, String key) {
    // Origami's added folds.
    if (inst.effectId == 'origami_fold') {
      if (RegExp(r'^(angle|fold\d+_angle|angle\d)$').hasMatch(key)) return ParamScale.degreesWith(origamiAngleStops);
      if (RegExp(r'^(position|fold\d+_position|position\d)$').hasMatch(key)) return ParamScale.quarters;
      if (RegExp(r'^(direction|fold\d+_direction|direction\d)$').hasMatch(key)) return ParamScale.degrees;
      if (RegExp(r'^(fold\d+_softness|softness\d)$').hasMatch(key)) return const ParamScale.slider(0, 1);
      if (RegExp(r'^(round|fold\d+_round|round\d)$').hasMatch(key)) return const ParamScale.slider(0, 200, decimals: 1);
      if (RegExp(r'^(softShape|roundShape|fold\d+_(softShape|roundShape)|(softShape|roundShape)\d)$').hasMatch(key)) {
        return const ParamScale.slider(0, 1, decimals: 3);
      }
    }
    final defs = effectRegistry[inst.effectId]?.params ?? const <ParamDef>[];
    final def = defs.where((d) => d.key == key).firstOrNull;
    final range = def?.range;
    if (range != null && range.length == 2) {
      if (range[1] - range[0] >= 360) return ParamScale.degrees;
      return ParamScale.slider(range[0], range[1]);
    }
    if (inst.effectId == 'corner_pin' || inst.effectId == 'mesh_warp') {
      return const ParamScale.ruler(unitsPerPixel: 1, minorTick: 10, majorTick: 50, decimals: 1);
    }
    if (inst.effectId == 'rotate_3d' && key == 'pivot') {
      return const ParamScale.ruler(unitsPerPixel: 0.005, minorTick: 0.1, majorTick: 0.5, decimals: 3);
    }
    return const ParamScale.ruler(unitsPerPixel: 0.01, minorTick: 0.1, majorTick: 1);
  }

  /// One undo step for an edit; changing a corner pin / mesh warp on a
  /// text layer turns the text into a vector shape (same as on the stage).
  void _beginEdit(EffectInstance inst) {
    app.pushUndo();
    if (inst.effectId != 'corner_pin' && inst.effectId != 'mesh_warp') return;
    final layer = findLayer(app.project, app.selection.selectedLayer);
    if (layer != null && layer.content.shape == 'text' && layer.effectStack.contains(inst)) {
      app.convertTextLayer(layer);
    }
  }

  Widget _instanceParamRow(
      BuildContext context, EffectInstance inst, String key, Track trk, double localFrame, dynamic defaultValue) {
    final value = evaluateTrack(app.project, trk, localFrame);
    final valueList = value is List<double> ? value : [value as double];
    final frame = localFrame.round();
    final keyed = trk.keyframes.any((k) => k.frame == frame);
    dynamic out(List<double> v) => valueList.length > 1 ? v : v.first;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ParamEditor(
        prefKey: 'effect.${inst.effectId}.$key',
        label: _paramLabels[key] ??
            _paramLabels[key.replaceFirst(RegExp(r'^fold\d+_'), '')] ??
            key.replaceAllMapped(RegExp(r'^fold(\d+)_'), (m) => 'fold ${m[1]} '),
        values: valueList,
        scale: _scaleFor(inst, key),
        componentLabels: valueList.length > 1 ? const ['x', 'y'] : null,
        onEditStart: () => _beginEdit(inst),
        onChanged: (v) {
          setTrackValueAt(trk, frame, out(v));
          app.commitEdit();
        },
        onCommit: (v) {
          _beginEdit(inst);
          setTrackValueAt(trk, frame, out(v));
          app.commitEdit();
        },
        trailing: [
          if (trk.keyframes.length >= 2)
            IconButton(
              icon: const Icon(Icons.show_chart, size: 16),
              tooltip: 'edit easing curve',
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => showDialog(
                context: context,
                builder: (_) => GraphEditorView(app: app, track: trk, componentCount: valueList.length),
              ),
            ),
          ResetIconButton(onPressed: () {
            app.pushUndo();
            setTrackValueAt(trk, frame, defaultValue is List ? List<double>.from(defaultValue) : defaultValue);
            app.commitEdit();
          }),
          IconButton(
            icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
            tooltip: 'toggle keyframe at current frame',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () {
              app.pushUndo();
              if (keyed) {
                trk.keyframes.removeWhere((k) => k.frame == frame);
              } else {
                trk.keyframes.add(Keyframe(frame: frame, value: value, temporal: newKeyEasing()));
                trk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
              }
              app.commitEdit();
            },
          )
        ],
      ),
    );
  }

  Widget _addEffectRow(Layer layer) => _AddEffectRow(app: app, layer: layer);

  // ---------------------------------------------------------------
  // contour physics
  // ---------------------------------------------------------------

  Widget _physicsSection(BuildContext context, Layer layer) {
    final ph = layer.physics;
    void set(void Function() change) {
      app.pushUndo();
      change();
      app.commitEdit();
    }

    return Column(
      key: const ValueKey('physics-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const ValueKey('physics-collide'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Physics: collide', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: hint('Layers of one group with this on can\'t overlap: animate one into another and it pushes it. '
              'Its contour is the Outline\'s (threshold, offset)'),
          value: ph.collide,
          onChanged: (v) => set(() => ph.collide = v),
        ),
        if (ph.collide) ...[
          Row(children: [
            const SizedBox(width: 80, child: Text('Group')),
            for (final g in const ['1', '2', '3', '4'])
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: ChoiceChip(
                  key: ValueKey('physics-group-$g'),
                  label: Text(g),
                  selected: ph.group == g,
                  onSelected: (_) => set(() => ph.group = g),
                ),
              ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const SizedBox(width: 80, child: Text('Role')),
            Expanded(
              child: SegmentedButton<String>(
                key: const ValueKey('physics-role'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'pushable', label: Text('Pushable')),
                  ButtonSegment(value: 'immovable', label: Text('Immovable')),
                ],
                selected: {ph.role},
                onSelectionChanged: (s) => set(() => ph.role = s.first),
              ),
            ),
          ]),
          if (!ph.immovable)
            Row(children: [
              SizedBox(width: 80, child: Text('Weight ${ph.weight.toStringAsFixed(1)}')),
              Expanded(
                child: Slider(
                  key: const ValueKey('physics-weight'),
                  value: ph.weight.clamp(0.1, 10),
                  min: 0.1,
                  max: 10,
                  onChangeStart: (_) => app.pushUndo(),
                  onChanged: (v) {
                    ph.weight = (v * 10).round() / 10;
                    app.commitEdit();
                  },
                ),
              ),
            ]),
          if (!ph.immovable)
            Row(children: [
              SizedBox(width: 80, child: Text('Inertia ${(ph.inertia * 100).round()}%')),
              Expanded(
                child: Slider(
                  key: const ValueKey('physics-inertia'),
                  value: ph.inertia.clamp(0, 0.98),
                  max: 0.98,
                  onChangeStart: (_) => app.pushUndo(),
                  onChanged: (v) {
                    ph.inertia = (v * 100).round() / 100;
                    app.commitEdit();
                  },
                ),
              ),
            ]),
          SwitchListTile(
            key: const ValueKey('physics-stage-walls'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Frame edges collide', style: TextStyle(fontSize: 13)),
            subtitle: hint('The whole frame\'s outline is a wall for every colliding layer.'),
            value: app.project.stageWalls,
            onChanged: (v) {
              app.pushUndo();
              app.project.stageWalls = v;
              app.commitEdit();
            },
          ),
          Row(children: [
            SizedBox(width: 80, child: Text('Gap ${ph.gap.round()} px')),
            Expanded(
              child: Slider(
                key: const ValueKey('physics-gap'),
                // below 0: they may sink into each other this far.
                value: ph.gap.clamp(-50, 50),
                min: -50,
                max: 50,
                onChangeStart: (_) => app.pushUndo(),
                onChanged: (v) {
                  ph.gap = v.roundToDouble();
                  app.commitEdit();
                },
              ),
            ),
          ]),
          Row(children: [
            SizedBox(width: 80, child: Text('Soft ${(ph.softness * 100).round()}%')),
            Expanded(
              child: Slider(
                key: const ValueKey('physics-soft'),
                value: ph.softness.clamp(0, 0.95),
                max: 0.95,
                onChangeStart: (_) => app.pushUndo(),
                onChanged: (v) {
                  ph.softness = (v * 100).round() / 100;
                  app.commitEdit();
                },
              ),
            ),
          ]),
          const Hint('Weight: how a push splits between two pushable layers (equal: both yield). '
              'Gap: they count as touching this far apart; below 0 they may sink in that far. '
              'Soft: they part over a few frames - the deeper in, the harder the push.'),
          // leash: held near a point, like on a spring.
          if (!ph.immovable) ...[
            SwitchListTile(
              key: const ValueKey('physics-leash'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('On a leash', style: TextStyle(fontSize: 13)),
              subtitle: hint('Pulled back toward a point (where it is now when turned on) once farther than the '
                  'leash; with inertia it swings and settles.'),
              value: ph.leash,
              onChanged: (v) {
                app.pushUndo();
                ph.leash = v;
                if (v) {
                  final m = getLayerStateAt(app.project, layer.id, app.currentFrame).matrix;
                  ph.leashPoint = [m[4] * stageSize.width, m[5] * stageSize.height];
                }
                app.commitEdit();
              },
            ),
            if (ph.leash) ...[
              Row(children: [
                SizedBox(width: 80, child: Text('Length ${ph.leashLength.round()} px')),
                Expanded(
                  child: Slider(
                    key: const ValueKey('physics-leash-length'),
                    value: ph.leashLength.clamp(0, 500),
                    max: 500,
                    onChangeStart: (_) => app.pushUndo(),
                    onChanged: (v) {
                      ph.leashLength = v.roundToDouble();
                      app.commitEdit();
                    },
                  ),
                ),
              ]),
              Row(children: [
                SizedBox(width: 80, child: Text('Pull ${(ph.leashStrength * 100).round()}%')),
                Expanded(
                  child: Slider(
                    key: const ValueKey('physics-leash-strength'),
                    value: ph.leashStrength.clamp(0.01, 1),
                    min: 0.01,
                    max: 1,
                    onChangeStart: (_) => app.pushUndo(),
                    onChanged: (v) {
                      ph.leashStrength = (v * 100).round() / 100;
                      app.commitEdit();
                    },
                  ),
                ),
              ]),
              TextButton.icon(
                key: const ValueKey('physics-leash-here'),
                icon: const Icon(Icons.my_location, size: 16),
                label: const Text('Leash point: where it is now'),
                onPressed: () {
                  app.pushUndo();
                  final m = getLayerStateAt(app.project, layer.id, app.currentFrame).matrix;
                  ph.leashPoint = [m[4] * stageSize.width, m[5] * stageSize.height];
                  app.commitEdit();
                },
              ),
            ],
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('physics-bake'),
              icon: const Icon(Icons.push_pin_outlined, size: 18),
              label: const Text('Bake push to keys'),
              onPressed: () => app.bakePhysicsToKeys(layer.id),
            ),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------
  // follow
  // ---------------------------------------------------------------

  Widget _followSection(BuildContext context, Layer layer, double localFrame) {
    final f = layer.follow;
    void set(void Function() change) {
      app.pushUndo();
      change();
      app.commitEdit();
    }

    final others = [for (final l in app.project.layers) if (l.id != layer.id) l];
    final selected = app.editingEffectId == 'follow';
    Widget toggle(String label, bool value, void Function(bool) on) => FilterChip(
          key: ValueKey('follow-$label'),
          label: Text(label),
          selected: value,
          visualDensity: VisualDensity.compact,
          onSelected: (v) => set(() => on(v)),
        );
    return Column(
      key: const ValueKey('follow-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const ValueKey('follow-enabled'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          selected: selected,
          title: const Text('Follow', style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: hint('Lazily trails another layer: lags while it moves, catches up and settles when it stops. '
              'Its own keys still apply on top. Tap the title to show the line to the target'),
          value: f.enabled,
          onChanged: (v) => set(() => f.enabled = v),
        ),
        if (f.enabled) ...[
          InkWell(
            key: const ValueKey('follow-select'),
            onTap: () => app.setEditingEffect('follow'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                const SizedBox(width: 80, child: Text('Target')),
                Expanded(
                  child: DropdownButton<String?>(
                    key: const ValueKey('follow-target'),
                    isExpanded: true,
                    value: others.any((l) => l.id == f.targetId) ? f.targetId : null,
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('None')),
                      for (final l in others)
                        DropdownMenuItem<String?>(
                          value: l.id,
                          enabled: !followWouldCycle(app.project, layer, l.id),
                          child: Text(
                            followWouldCycle(app.project, layer, l.id) ? '${l.name} (circle)' : l.name,
                            style: followWouldCycle(app.project, layer, l.id)
                                ? TextStyle(color: Theme.of(context).disabledColor)
                                : null,
                          ),
                        ),
                    ],
                    onChanged: (id) {
                      if (id != null && followWouldCycle(app.project, layer, id)) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text(followCycleMessage)));
                        return;
                      }
                      set(() => f.targetId = id);
                    },
                  ),
                ),
                Icon(selected ? Icons.visibility : Icons.visibility_outlined, size: 18),
              ]),
            ),
          ),
          Wrap(spacing: 6, children: [
            toggle('Position', f.position, (v) => f.position = v),
            toggle('Rotation', f.rotation, (v) => f.rotation = v),
            toggle('Scale', f.scale, (v) => f.scale = v),
          ]),
          _keyedRow(context, 'follow.speed', 'Speed', f.speed, localFrame, 60.0,
              const ParamScale.slider(1, 500, decimals: 0)),
          if (f.advanced)
            _keyedRow(context, 'follow.damping', 'Damping', f.damping, localFrame, 14.0,
                const ParamScale.slider(0, 60, decimals: 1))
          else
            _keyedRow(context, 'follow.bounciness', 'Bounciness %', f.bounciness, localFrame, 30.0,
                const ParamScale.slider(0, 100, decimals: 0)),
          _keyedRow(context, 'follow.amount', 'Amount', f.amount, localFrame, 1.0,
              const ParamScale.slider(0, 1, decimals: 2)),
          if (f.offset != null)
            _keyedRow(context, 'follow.offset', 'Offset', f.offset!, localFrame, [0.0, 0.0],
                const ParamScale.slider(-500, 500, decimals: 0)),
          Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            FilterChip(
              key: const ValueKey('follow-offset'),
              label: const Text('Own offset'),
              tooltip: 'Off: keep the distance it starts at. On: set where on the target it aims (px, target space)',
              selected: f.offset != null,
              visualDensity: VisualDensity.compact,
              onSelected: (v) => set(() => f.offset = v ? Track(<double>[0.0, 0.0], true) : null),
            ),
            toggle('Advanced', f.advanced, (v) => f.advanced = v),
          ]),
          const Hint('Speed: how stiff the pull is. Bounciness: 0 settles without overshooting, more swings past. '
              'Advanced shows the raw damping. Bake it to keys in the layer menu'),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------
  // cut by layer
  // ---------------------------------------------------------------

  /// Shown in the Masks tab, above Mirror.
  Widget cutsSection(BuildContext context, Layer layer, double localFrame) {
    void set(void Function() change) {
      app.pushUndo();
      change();
      app.commitEdit();
    }

    final others = [for (final l in app.project.layers) if (l.id != layer.id && !isAudioShape(l.content.shape)) l];
    return Column(
      key: const ValueKey('cuts-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('cut-add'),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add'),
            onPressed: () => set(() => layer.cuts.add(CutByLayer(gap: Track(20.0, false)))),
          ),
        ]),
        const Hint('Another layer cuts this one live: subtract, keep the overlap, join or exclude. '
            'Gap grows the cutter first (negative: shrinks). The outline, collisions and fill follow the cut'),
        for (var i = 0; i < layer.cuts.length; i++) () {
          final c = layer.cuts[i];
          return Padding(
            key: ValueKey('cut-$i'),
            padding: const EdgeInsets.only(top: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Checkbox(value: c.enabled, onChanged: (v) => set(() => c.enabled = v ?? true)),
                const SizedBox(width: 56, child: Text('Cutter')),
                Expanded(
                  child: DropdownButton<String?>(
                    key: ValueKey('cut-cutter-$i'),
                    isExpanded: true,
                    value: others.any((l) => l.id == c.cutterId) ? c.cutterId : null,
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('None')),
                      for (final l in others)
                        DropdownMenuItem<String?>(
                          value: l.id,
                          enabled: !cutWouldCycle(app.project, layer, l.id),
                          child: Text(cutWouldCycle(app.project, layer, l.id) ? '${l.name} (circle)' : l.name,
                              overflow: TextOverflow.ellipsis,
                              style: cutWouldCycle(app.project, layer, l.id)
                                  ? TextStyle(color: Theme.of(context).disabledColor)
                                  : null),
                        ),
                    ],
                    onChanged: (id) {
                      if (id != null && cutWouldCycle(app.project, layer, id)) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(cutCycleMessage)));
                        return;
                      }
                      set(() => c.cutterId = id);
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  tooltip: 'remove this cut',
                  onPressed: () => set(() => layer.cuts.removeAt(i)),
                ),
              ]),
              Wrap(spacing: 6, children: [
                for (final (m, label) in const [
                  ('subtract', 'Subtract'),
                  ('intersect', 'Intersect'),
                  ('union', 'Union'),
                  ('exclude', 'Exclude')
                ])
                  ChoiceChip(
                    key: ValueKey('cut-mode-$i-$m'),
                    label: Text(label, style: const TextStyle(fontSize: 12)),
                    selected: c.mode == m,
                    onSelected: (_) => set(() => c.mode = m),
                  ),
              ]),
              _keyedRow(context, 'cut.gap', 'Gap', c.gap, localFrame, 0.0,
                  const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25)),
              Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                const Text('Corners', style: TextStyle(fontSize: 12)),
                for (final j in const ['miter', 'round', 'bevel'])
                  ChoiceChip(
                    key: ValueKey('cut-join-$i-$j'),
                    label: Text(j, style: const TextStyle(fontSize: 12)),
                    selected: c.join == j,
                    onSelected: (_) => set(() => c.join = j),
                  ),
              ]),
              SwitchListTile(
                key: ValueKey('cut-touching-$i'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Only when touching', style: TextStyle(fontSize: 13)),
                subtitle: hint('The cut and its gap work only while the cutter itself touches this layer'),
                value: c.onlyWhenTouching,
                onChanged: (v) => set(() => c.onlyWhenTouching = v),
              ),
              SwitchListTile(
                key: ValueKey('cut-hide-$i'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Hide cutter', style: TextStyle(fontSize: 13)),
                subtitle: hint('Only its cut shows here; the cutter layer itself isn\'t drawn'),
                value: c.hideCutter,
                onChanged: (v) => set(() => c.hideCutter = v),
              ),
            ]),
          );
        }(),
      ],
    );
  }

  /// A keyframeable number (or x/y) row bound to `trk` directly.
  Widget _keyedRow(BuildContext context, String prefKey, String label, Track trk, double localFrame,
      dynamic defaultValue, ParamScale scale) {
    final value = evaluateTrack(app.project, trk, localFrame);
    final valueList = value is List ? [for (final v in value) (v as num).toDouble()] : [(value as num).toDouble()];
    final frame = localFrame.round();
    final keyed = trk.keyframes.any((k) => k.frame == frame);
    dynamic out(List<double> v) => valueList.length > 1 ? v : v.first;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ParamEditor(
        prefKey: prefKey,
        label: label,
        values: valueList,
        scale: scale,
        componentLabels: valueList.length > 1 ? const ['x', 'y'] : null,
        onEditStart: app.pushUndo,
        onChanged: (v) {
          setTrackValueAt(trk, frame, out(v));
          app.commitEdit();
        },
        onCommit: (v) {
          app.pushUndo();
          setTrackValueAt(trk, frame, out(v));
          app.commitEdit();
        },
        trailing: [
          ResetIconButton(onPressed: () {
            app.pushUndo();
            setTrackValueAt(trk, frame, defaultValue is List ? List<double>.from(defaultValue) : defaultValue);
            app.commitEdit();
          }),
          IconButton(
            icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
            tooltip: 'toggle keyframe at current frame',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () {
              app.pushUndo();
              if (keyed) {
                trk.keyframes.removeWhere((k) => k.frame == frame);
              } else {
                trk.keyframes.add(Keyframe(frame: frame, value: value, temporal: newKeyEasing()));
                trk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
              }
              app.commitEdit();
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------
  // motion blur / wiggle / pendulum
  // ---------------------------------------------------------------

  Widget _motionBlurBody(Layer layer) {
    final mb = layer.motionBlur;
    void shutter(double v) {
      mb.shutterAngle = v.clamp(0, 360).toDouble();
      app.commitEdit();
    }

    void samples(double v) {
      mb.samples = v.round().clamp(2, 32);
      app.commitEdit();
    }

    return Column(children: [
      ParamEditor(
        prefKey: 'effect.motionBlur.shutter',
        label: 'shutter',
        values: [mb.shutterAngle],
        scale: const ParamScale.slider(0, 360, decimals: 0),
        onEditStart: app.pushUndo,
        onChanged: (v) => shutter(v.first),
        onCommit: (v) {
          app.pushUndo();
          shutter(v.first);
        },
        trailing: [
          ResetIconButton(onPressed: () {
            app.pushUndo();
            shutter(MotionBlur().shutterAngle);
          }),
        ],
      ),
      ParamEditor(
        prefKey: 'effect.motionBlur.samples',
        label: 'samples',
        values: [mb.samples.toDouble()],
        scale: const ParamScale.slider(2, 32, integer: true),
        onEditStart: app.pushUndo,
        onChanged: (v) => samples(v.first),
        onCommit: (v) {
          app.pushUndo();
          samples(v.first);
        },
        trailing: [
          ResetIconButton(onPressed: () {
            app.pushUndo();
            samples(MotionBlur().samples.toDouble());
          }),
        ],
      ),
    ]);
  }

  /// Time quantize: the layer's own frame rate (it holds each pose for
  /// 60/fps frames).
  Widget _timeQuantizeBody(Layer layer) {
    final q = layer.timeQuantize;
    void set(double v) {
      q.fps = v.roundToDouble().clamp(1, 30).toDouble();
      app.commitEdit();
    }

    return ParamEditor(
      prefKey: 'effect.timeQuantize.fps',
      label: 'fps',
      values: [q.fps],
      scale: const ParamScale.slider(1, 30, integer: true),
      onEditStart: app.pushUndo,
      onChanged: (v) => set(v.first),
      onCommit: (v) {
        app.pushUndo();
        set(v.first);
      },
      trailing: [
        ResetIconButton(onPressed: () {
          app.pushUndo();
          set(TimeQuantize().fps);
        })
      ],
    );
  }

  Widget _wiggleBody(Layer layer) {
    final w = layer.wiggle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sliderRow('speed', w.speed, 100, Wiggle().speed, (v) {
          w.speed = v;
          app.commitEdit();
        }),
        _sliderRow('amplitude', w.amplitude, 100, Wiggle().amplitude, (v) {
          w.amplitude = v;
          app.commitEdit();
        }),
        _sliderRow('smoothness', w.smoothness, 100, Wiggle().smoothness, (v) {
          w.smoothness = v;
          app.commitEdit();
        }),
      ],
    );
  }

  Widget _pendulumBody(BuildContext context, Layer layer) {
    final p = layer.pendulum;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sliderRow('max angle', p.maxAngle, 90, Pendulum().maxAngle, (v) {
          p.maxAngle = v;
          app.commitEdit();
        }),
        _sliderRow('frequency', p.frequency, 100, Pendulum().frequency, (v) {
          p.frequency = v;
          app.commitEdit();
        }),
        _sliderRow('damping', p.damping, 100, Pendulum().damping, (v) {
          p.damping = v;
          app.commitEdit();
        }),
        _sliderRow('freeze', p.freeze, 100, Pendulum().freeze, (v) {
          p.freeze = v;
          app.commitEdit();
        }),
        _sliderRow('sensitivity', p.sensitivity, 100, Pendulum().sensitivity, (v) {
          p.sensitivity = v;
          app.commitEdit();
        }),
        // the weight (the line's other end) is dragged on the stage.
        Row(children: [
          const Expanded(
            child: Hint('weight: drag the filled dot on the stage'),
          ),
          if (p.weightPoint != null)
            TextButton(
              key: const ValueKey('pendulum-weight-reset'),
              onPressed: () {
                app.pushUndo();
                p.weightPoint = null;
                app.commitEdit();
              },
              child: const Text('to the middle'),
            ),
        ]),
        Row(
          children: [
            Checkbox(
              value: p.rotateWithLine,
              onChanged: (v) {
                app.pushUndo();
                p.rotateWithLine = v ?? true;
                app.commitEdit();
              },
            ),
            const Text('Object rotates with line', style: TextStyle(fontSize: 11)),
          ],
        ),
        _pendulumPivotRow(layer),
        if (layer.parentId != null) _pivotToParentRow(layer),
      ],
    );
  }

  Widget _pendulumPivotRow(Layer layer) {
    final pivotTrk = layer.pendulum.pivotOffset;
    final localFrame = layerLocalFrame(layer, app.currentFrame);
    final frame = localFrame.round();
    final keyed = pivotTrk.keyframes.any((k) => k.frame == frame);
    return Row(
      children: [
        const Hint('Grip point'),
        IconButton(
          icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
          tooltip: 'keyframe grip point at this frame',
          onPressed: () {
            app.pushUndo();
            if (keyed) {
              pivotTrk.keyframes.removeWhere((k) => k.frame == frame);
            } else {
              final val = List<double>.from(evaluateTrack(app.project, pivotTrk, localFrame, layer) as List<double>);
              pivotTrk.keyframes.add(Keyframe(frame: frame, value: val, temporal: easingPresets['linear']));
              pivotTrk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
            }
            autoComputeTangents(pivotTrk);
            app.commitEdit();
          },
        ),
        OutlinedButton(
          onPressed: () {
            app.pushUndo();
            pivotTrk.defaultValue = [0.0, 0.0];
            pivotTrk.keyframes.clear();
            app.commitEdit();
          },
          child: const Text('Reset grip to center'),
        ),
      ],
    );
  }

  /// binds the grip point to wherever the PARENT's own center (anchor)
  /// currently sits, in THIS layer's local pixel space - useful for
  /// chains, where each link's swing should pivot exactly at the joint
  /// connecting it to the previous link.
  Widget _pivotToParentRow(Layer layer) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: OutlinedButton(
        onPressed: () => _pivotToParentCenter(layer),
        child: const Text('Pivot to parent center'),
      ),
    );
  }

  void _pivotToParentCenter(Layer layer) {
    app.pushUndo();
    final pivotTrk = layer.pendulum.pivotOffset;
    final myState = getLayerBaseStateAt(app.project, layer.id, app.currentFrame);
    final parentState = getLayerStateAt(app.project, layer.parentId!, app.currentFrame);
    final parentWorldPos = [parentState.matrix[4], parentState.matrix[5]];
    final myWorldPos = [myState.baseMatrix[4], myState.baseMatrix[5]];
    final deltaFraction = [parentWorldPos[0] - myWorldPos[0], parentWorldPos[1] - myWorldPos[1]];
    final deltaPixels = [deltaFraction[0] * stageSize.width, deltaFraction[1] * stageSize.height];
    final myLinear = [
      myState.baseMatrix[0],
      myState.baseMatrix[1],
      myState.baseMatrix[2],
      myState.baseMatrix[3],
      0.0,
      0.0
    ];
    final localPivot = applyAffine(invertAffine(myLinear), deltaPixels);
    final localFrame2 = (app.currentFrame - layer.startFrame).clamp(0, layer.durationFrames);
    setTrackValueAt(pivotTrk, localFrame2, localPivot);
    app.commitEdit();
  }

  /// Swing: rocks the layer's rotation in a sine between two angles;
  /// damping makes it die down toward the middle.
  Widget _swingBody(Layer layer) {
    final w = layer.swing;
    final d = Swing();
    Widget row(String key, String label, double value, double def, ParamScale scale, void Function(double v) set) =>
        ParamEditor(
          prefKey: 'effect.swing.$key',
          label: label,
          values: [value],
          scale: scale,
          onEditStart: app.pushUndo,
          onChanged: (v) {
            set(v.first);
            app.commitEdit();
          },
          onCommit: (v) {
            app.pushUndo();
            set(v.first);
            app.commitEdit();
          },
          trailing: [
            ResetIconButton(onPressed: () {
              app.pushUndo();
              set(def);
              app.commitEdit();
            })
          ],
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('min', 'min angle', w.minAngle, d.minAngle, ParamScale.degrees, (v) => w.minAngle = v),
        row('max', 'max angle', w.maxAngle, d.maxAngle, ParamScale.degrees, (v) => w.maxAngle = v),
        row('freq', 'frequency (Hz)', w.frequency, d.frequency, const ParamScale.slider(0.05, 10, decimals: 2),
            (v) => w.frequency = v.clamp(0.0, 30.0).toDouble()),
        row('phase', 'phase', w.phase, d.phase, ParamScale.degrees, (v) => w.phase = v),
        row('damping', 'damping', w.damping, d.damping, const ParamScale.slider(0, 5, decimals: 2),
            (v) => w.damping = v.clamp(0.0, 50.0).toDouble()),
        const Hint('Damping: how fast the swing dies down toward the middle of the range (0 = never).'),
      ],
    );
  }

  Widget _sliderRow(String label, double value, double max, double defaultValue, ValueChanged<double> onChanged) {
    return ParamEditor(
      prefKey: 'effect.$label',
      label: label,
      values: [value],
      scale: ParamScale.slider(0, max, decimals: 0),
      onEditStart: app.pushUndo,
      onChanged: (v) => onChanged(v.first.clamp(0, max).toDouble()),
      onCommit: (v) {
        app.pushUndo();
        onChanged(v.first.clamp(0, max).toDouble());
      },
      trailing: [
        ResetIconButton(onPressed: () {
          app.pushUndo();
          onChanged(defaultValue);
        })
      ],
    );
  }
}

const motionPanelNames = {
  'motionBlur': 'Motion blur',
  'wiggle': 'Wiggle',
  'pendulum': 'Pendulum',
  'swing': 'Swing',
  'timeQuantize': 'Time quantize',
};

/// separated into its own StatefulWidget purely to own the DropdownButton
/// selection locally (which effect id is currently chosen to add next) -
/// the rest of EffectsView is a StatelessWidget driven entirely by
/// AnimatedBuilder, and this is the one piece of pure UI-local state.
class _AddEffectRow extends StatefulWidget {
  final AppState app;
  final Layer layer;
  const _AddEffectRow({required this.app, required this.layer});

  @override
  State<_AddEffectRow> createState() => _AddEffectRowState();
}

class _AddEffectRowState extends State<_AddEffectRow> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    // geometry effects (any number of each) plus the motion add-ons not on
    // the layer yet (one each).
    final present = effectPanelEntries(widget.layer).toSet();
    // by type (a type's name heads its items).
    String typeOfOption(String key) => key.startsWith('motion:')
        ? (key == 'motion:motionBlur' || key == 'motion:timeQuantize' ? 'Time' : 'Motion')
        : (key == 'outline' ? 'Contour' : 'Shape');
    final all = <String, String>{
      for (final e in effectRegistry.entries) e.key: e.value.name,
      for (final m in motionPanelIds)
        if (!present.contains(m)) 'motion:$m': motionPanelNames[m]!,
    };
    final options = all;
    if (options.isEmpty) return const SizedBox.shrink();
    final selected = options.containsKey(_selected) ? _selected! : options.keys.first;
    final items = <DropdownMenuItem<String>>[
      for (final type in EffectsView.effectTypes) ...[
        if (options.keys.any((k) => typeOfOption(k) == type))
          DropdownMenuItem(
              enabled: false,
              value: 'header:$type',
              child: Text(type, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
        for (final o in options.entries)
          if (typeOfOption(o.key) == type)
            DropdownMenuItem(
                value: o.key,
                child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(o.value, overflow: TextOverflow.ellipsis))),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Flexible(
            child: DropdownButton<String>(
              value: selected,
              isExpanded: true,
              items: items,
              onChanged: (v) => setState(() => _selected = v),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () {
              widget.app.pushUndo();
              if (selected.startsWith('motion:')) {
                addMotionPanelEntry(widget.layer, selected.substring(7));
              } else {
                final instId = 'fx_${DateTime.now().microsecondsSinceEpoch}';
                widget.layer.effectStack.add(createEffectInstance(selected, instId, widget.layer));
              }
              widget.app.commitEdit();
            },
            child: const Text('+ effect'),
          ),
          // paste an effect copied from any card (on this or another object).
          if (widget.app.copiedEffect != null)
            IconButton(
              icon: const Icon(Icons.content_paste, size: 18),
              tooltip: 'paste effect',
              onPressed: () => widget.app.pasteEffectInto(widget.layer.id),
            ),
        ],
      ),
    );
  }
}
