import '../stage/marquee_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';
import '../graph_editor/graph_editor_view.dart';
import '../common/no_layer.dart';

/// Ported from the "movement" section of movement-core/src/ui/
/// paramsPanel/{index,shared,movementSection}.js - anchor/scale/
/// rotation/opacity editing with a per-parameter keyframe toggle at the
/// current frame, same edit convention as the original: editing a value
/// writes to the existing keyframe AT localFrame if one is there,
/// otherwise it writes the track's own default (see shared.js/
/// movementSection.js's `if(k) k.value = v; else trk.default = v`).
///
/// Also ports the parent selector from paramsPanel/layerSection.js's
/// `parentSel` - a plain dropdown, filtered the same way JS filters it
/// (excludes self and any layer that would close a cycle, via the same
/// wouldCreateCycle check), calling reparentPreservingWorldPosition on
/// change. NOTE this corrects an earlier, inaccurate doc comment
/// elsewhere in this app (layer_panel_view.dart) that described
/// "drag-to-reparent" as deferred gesture work, as if it were a port of
/// an existing JS feature - the JS engine never had drag-based
/// reparenting at all, only this dropdown. That was a mistake in how
/// the gap was described, not a real deferred feature; this dropdown is
/// the actual, correctly-scoped port of what JS has.
///
/// Also ports movementSection.js's path-tension and whole-path-easing
/// controls (anchor-only, gated on `anchor.keyframes.length >= 2` same
/// as JS - tension has no visible effect with fewer points, see
/// interpolation.dart's autoComputeTangents), and shared.js's makeParam
/// per-track "ease" button (gated on `trk.keyframes.length >= 2`) that
/// opens graph_editor/graph_editor_view.dart for per-segment easing.
///
/// The masks/effects sections (masksSection.js, effectsSection.js) and
/// per-track expression/loop toggles aren't ported yet - this covers the
/// core transform plus parenting plus easing, which is enough to pose,
/// animate, ease, and rig a layer by hand.
///
/// UNVERIFIED like the rest of ui/.
class ParamsPanelView extends StatelessWidget {
  /// The parent fold (its options and the layers linked to this one).
  static bool parentOpen = true;

  final AppState app;
  const ParamsPanelView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) {
          // picking several works with nothing selected yet.
          return ListView(padding: const EdgeInsets.all(8), children: [
            _pickSeveral(context),
            const SizedBox(height: 24),
            NoLayer(app: app, text: 'No layer selected'),
          ]);
        }
        final localFrame = layerLocalFrame(layer, app.currentFrame);
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            _pickSeveral(context),
            _parentSelector(context, layer),
            _vecParam(context, 'anchor', layer.transform.anchor, localFrame, [0.5, 0.5],
                const ParamScale.ruler(unitsPerPixel: 0.0005, minorTick: 0.01, majorTick: 0.1, decimals: 4)),
            _pathControls(context, layer.transform.anchor),
            _vecParam(context, 'scale', layer.transform.scale, localFrame, [1.0, 1.0],
                const ParamScale.ruler(unitsPerPixel: 0.005, minorTick: 0.1, majorTick: 0.5)),
            _scaleSwitches(layer),
            _scalarParam(context, 'rotation', layer.transform.rotation, localFrame, 0.0, ParamScale.degrees),
            _scalarParam(context, 'opacity', layer.transform.opacity, localFrame, 1.0, const ParamScale.slider(0, 1)),
          ],
        );
      },
    );
  }

  // keys of the animation layer being edited (or the track's own).
  bool _hasKeyAt(Track trk, double localFrame) => editTrackOf(trk).keyframes.any((k) => k.frame == localFrame.round());


  void _commit(Track trk, double localFrame, dynamic value) {
    app.pushUndo();
    _set(trk, localFrame, value);
    app.commitEdit();
  }

  /// A live drag step (slider/ruler) - the undo state was pushed once,
  /// when the drag started.
  void _live(Track trk, double localFrame, dynamic value) {
    _set(trk, localFrame, value);
    app.commitEdit();
  }

  /// Stage taps pick several layers (and the selection rectangle).
  Widget _pickSeveral(BuildContext context) => // stage taps pick several layers (and the selection rectangle).
      Row(children: [
        Expanded(
          child: SwitchListTile(
            key: const ValueKey('stage-multi-select'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(app.selectedGroup.length > 1
                ? 'Pick several on the stage (${app.selectedGroup.length} selected)'
                : 'Pick several on the stage'),
            value: app.stageMultiSelect,
            onChanged: (v) => app.setAppPreference('stageMultiSelect', v),
          ),
        ),
        // the selection rectangle and what it picks.
        IconButton(
          key: const ValueKey('marquee-settings'),
          icon: Icon(app.marqueeMode ? Icons.highlight_alt : Icons.select_all, size: 20),
          tooltip: 'select with a rectangle: options',
          onPressed: () => showMarqueeSettingsDialog(context, app),
        ),
      ]);

  /// Sets the selected layer's value - with several selected, the others
  /// follow: a move / turn / resize like on the stage (keeping the group's
  /// shape when that is on), the opacity the same value.
  void _set(Track trk, double localFrame, dynamic value) {
    final layer = findLayer(app.project, app.selection.selectedLayer);
    final group = app.selectedGroup;
    if (layer == null || group.length < 2) {
      setTrackValueAt(trk, localFrame.round(), value);
      return;
    }
    final t = layer.transform;
    if (identical(trk, t.opacity)) {
      setTrackValueAt(trk, localFrame.round(), value);
      for (final id in group) {
        final l = findLayer(app.project, id);
        if (l == null || l == layer) continue;
        setTrackValueAt(l.transform.opacity, layerLocalFrame(l, app.currentFrame).round(), value);
      }
      return;
    }
    if (identical(trk, t.anchor) || identical(trk, t.rotation) || identical(trk, t.scale)) {
      app.groupEdit(() => setTrackValueAt(trk, localFrame.round(), value));
      return;
    }
    setTrackValueAt(trk, localFrame.round(), value);
  }

  void _toggleKey(Track base, double localFrame) {
    app.pushUndo();
    // order keys: a new key opens a range layer of its own, or closes the
    // open one (transform parameters).
    final layer = findLayer(app.project, app.selection.selectedLayer);
    final t = layer?.transform;
    if (keyMode == 'order' && layer != null && t != null &&
        [t.anchor, t.rotation, t.scale, t.opacity].any((x) => identical(x, base)) &&
        !editTrackOf(base).keyframes.any((k) => k.frame == localFrame.round())) {
      orderKeyTarget(layer, localFrame.round());
    }
    // the keys of the animation layer being edited, if any.
    final trk = editTrackOf(base);
    final frame = localFrame.round();
    final existing = trk.keyframes.where((k) => k.frame == frame).isNotEmpty;
    if (existing) {
      trk.keyframes.removeWhere((k) => k.frame == frame);
    } else {
      final value = evaluateTrackOwn(app.project, trk, localFrame);
      trk.keyframes.add(Keyframe(frame: frame, value: value, temporal: newKeyEasing()));
      trk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
    }
    if (trk.spatial) autoComputeTangents(trk);
    // a closed range moves into an earlier layer it doesn't overlap.
    if (keyMode == 'order' && layer != null && activeAnimLayer > 0) packOrderLayer(layer, activeAnimLayer);
    app.commitEdit();
  }

  Widget _parentSelector(BuildContext context, Layer layer) {
    // same filter JS's parentSel applies: exclude self and any layer
    // that would close a cycle (i.e. is currently a descendant of this
    // layer) - assigning either would make getLayerStateAt's
    // parent-chain walk recurse forever.
    final candidates = app.project.layers.where((l) => l.id != layer.id && !wouldCreateCycle(app.project, layer.id, l.id)).toList();
    final children = [for (final l in app.project.layers) if (l.parentId == layer.id) l];
    final hasMore = layer.parentId != null || children.isNotEmpty;
    final selector = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(width: 56, child: Text('Parent')),
          Flexible(
            child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: DropdownButton<String?>(
              isExpanded: true,
              value: layer.parentId,
              hint: const Text('None'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('None')),
                for (final l in candidates) DropdownMenuItem<String?>(value: l.id, child: Text(l.name)),
              ],
              onChanged: (newParentId) {
                app.pushUndo();
                // preserves the layer's CURRENT on-screen position by
                // adjusting its whole anchor track by a constant delta -
                // same reasoning as JS's own parentSel.onchange (see
                // layerSection.js): a raw parentId assignment would leave
                // the anchor's existing numbers meaning something
                // completely different once relative to a new parent.
                reparentPreservingWorldPosition(app.project, layer, newParentId, app.currentFrame);
                app.commitEdit();
              },
            ),
          ),
          ),
          // pick this layer's children by tapping them on the stage.
          IconButton(
            key: const ValueKey('parent-pick-stage'),
            icon: Icon(app.parentPickFor == layer.id ? Icons.ads_click : Icons.account_tree_outlined, size: 18),
            tooltip: 'pick the layers linked to this one on the stage',
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                app.parentPickFor == layer.id ? app.finishParentPick() : app.startParentPick(layer.id),
          ),
          const Spacer(),
          if (hasMore)
            StatefulBuilder(
              builder: (context, set) => IconButton(
                key: const ValueKey('parent-fold'),
                icon: Icon(parentOpen ? Icons.expand_less : Icons.expand_more, size: 20),
                tooltip: parentOpen ? 'fold' : 'unfold',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  parentOpen = !parentOpen;
                  app.notifyListeners();
                },
              ),
            ),
        ],
      ),
    );
    if (!hasMore || !parentOpen) return selector;
    // the layers linked to this one, at the top of the fold.
    final linked = children.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            key: const ValueKey('parent-children'),
            padding: const EdgeInsets.only(left: 56, bottom: 4),
            child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Text('Linked to it:', style: TextStyle(fontSize: 12, color: Colors.grey)),
              for (final c in children)
                ActionChip(
                  label: Text(c.name, style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => app.selectLayer(c.id),
                ),
            ]),
          );
    if (layer.parentId == null) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [selector, linked]);
    // selective parenting: which parts of the parent this layer follows;
    // a part switched off stays as the parent had it on this layer's
    // first frame.
    Widget chip(String label, bool on, void Function(bool v) set) => FilterChip(
          label: Text(label, style: const TextStyle(fontSize: 12)),
          selected: on,
          onSelected: set,
          visualDensity: VisualDensity.compact,
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        selector,
        linked,
        Padding(
          padding: const EdgeInsets.only(left: 56),
          child: Wrap(
            spacing: 6,
            children: [
              chip('Position', layer.inheritPosition, (v) => app.setInherit(layer.id, position: v)),
              chip('Rotation', layer.inheritRotation, (v) => app.setInherit(layer.id, rotation: v)),
              chip('Scale', layer.inheritScale, (v) => app.setInherit(layer.id, scale: v)),
              chip('Keep difference', layer.parentKeepDifference, (v) => app.setInherit(layer.id, keepDifference: v)),
            ],
          ),
        ),
        // a link for a time only: it starts / ends at a frame, and the
        // child keeps its place there.
        Padding(
          padding: const EdgeInsets.only(left: 56),
          child: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final start in [true, false]) ...[
                Text(
                    start
                        ? 'from ${layer.parentFrom ?? 'the start'}'
                        : 'until ${layer.parentUntil ?? 'the end'}',
                    style: const TextStyle(fontSize: 12)),
                IconButton(
                  key: ValueKey(start ? 'parent-from-here' : 'parent-until-here'),
                  icon: Icon(start ? Icons.first_page : Icons.last_page, size: 18),
                  tooltip: start ? 'link starts at the playhead' : 'link ends at the playhead',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => start
                      ? app.setParentWindow(layer.id, from: app.currentFrame)
                      : app.setParentWindow(layer.id, until: app.currentFrame),
                ),
                if ((start ? layer.parentFrom : layer.parentUntil) != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: 'no limit',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => start
                        ? app.setParentWindow(layer.id, clearFrom: true)
                        : app.setParentWindow(layer.id, clearUntil: true),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _vecParam(BuildContext context, String label, Track trk, double localFrame, List<double> defaultValue, ParamScale scale) {
    final value = evaluateTrack(app.project, trk, localFrame) as List<double>;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ParamEditor(
        prefKey: 'movement.$label',
        label: label,
        values: value,
        scale: scale,
        componentLabels: const ['x', 'y'],
        // the pad's centre: the middle of the stage (positions are
        // fractions of it), the scale's 1:1.
        padCenter: label == 'scale' ? const [1.0, 1.0] : const [0.5, 0.5],
        padSpan: label == 'scale' ? 4 : 1,
        onEditStart: app.pushUndo,
        onChanged: (v) => _live(trk, localFrame, _linked(label, value, v)),
        onCommit: (v) => _commit(trk, localFrame, _linked(label, value, v)),
        trailing: [
          // scale: x and y together (keeping their ratio).
          if (label == 'scale')
            OpenOnly(
                child: IconButton(
              key: const ValueKey('scale-link'),
              icon: Icon(app.scaleLinked ? Icons.link : Icons.link_off, size: 18),
              tooltip: app.scaleLinked ? 'x and y change together' : 'x and y change apart',
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => app.setAppPreference('scaleLinked', !app.scaleLinked),
            )),
          // several selected: resize / turn as one figure (each moves
          // round the middle) or each on its own spot.
          if (label == 'scale' && app.selectedGroup.length > 1)
            OpenOnly(
                child: IconButton(
              key: const ValueKey('group-keeps-shape'),
              icon: Icon(app.groupKeepsShape ? Icons.workspaces : Icons.workspaces_outline, size: 18),
              tooltip: app.groupKeepsShape
                  ? 'the selected keep their overall shape (move round the middle)'
                  : 'each selected one resizes on its own spot',
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => app.setAppPreference('groupKeepsShape', !app.groupKeepsShape),
            )),
          ..._paramIcons(context, trk, localFrame, 2, () => _commit(trk, localFrame, List<double>.from(defaultValue))),
        ],
      ),
    );
  }

  /// Under scale: the size handles keep the far side in place; a stretched
  /// layer's origami folds keep their angles.
  Widget _scaleSwitches(Layer layer) {
    Widget sw(String key, String title, bool value, ValueChanged<bool> set) => SwitchListTile(
          key: ValueKey(key),
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: const EdgeInsets.only(left: 4),
          title: Text(title, style: const TextStyle(fontSize: 12)),
          value: value,
          onChanged: set,
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      sw('scale-keeps-opposite', 'Handles keep the opposite side in place', scaleKeepsOppositeEdge,
          (v) => app.setAppPreference('scaleKeepsOppositeEdge', v)),
      if (origamiInstances(layer).isNotEmpty)
        sw('scale-keeps-folds', 'Folds keep their angles when stretched', layer.foldsIgnoreScale, (v) {
          app.pushUndo();
          layer.foldsIgnoreScale = v;
          app.commitEdit();
        }),
    ]);
  }

  /// Linked scale: whichever of x / y changed, the other follows by the
  /// same factor.
  List<double> _linked(String label, List<double> before, List<double> next) {
    if (label != 'scale' || !app.scaleLinked || next.length < 2) return next;
    final dx = (next[0] - before[0]).abs(), dy = (next[1] - before[1]).abs();
    if (dx >= dy) {
      final k = before[0] == 0 ? 1.0 : next[0] / before[0];
      return [next[0], before[1] * k];
    }
    final k = before[1] == 0 ? 1.0 : next[1] / before[1];
    return [before[0] * k, next[1]];
  }

  Widget _scalarParam(BuildContext context, String label, Track trk, double localFrame, double defaultValue, ParamScale scale) {
    final value = evaluateTrack(app.project, trk, localFrame) as double;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ParamEditor(
        prefKey: 'movement.$label',
        label: label,
        values: [value],
        scale: scale,
        onEditStart: app.pushUndo,
        onChanged: (v) => _live(trk, localFrame, v.first),
        onCommit: (v) => _commit(trk, localFrame, v.first),
        trailing: _paramIcons(context, trk, localFrame, 1, () => _commit(trk, localFrame, defaultValue)),
      ),
    );
  }

  /// shared.js's makeParam: an "ease" button next to every param's
  /// keyframe toggle, gated on `trk.keyframes.length >= 2` (a single
  /// keyframe has no transition to ease) - opens the per-segment graph
  /// editor for THIS track.
  ///
  /// Also gated on `trk.globalEasing == null`: with whole-path easing active,
  /// evaluateTrack's whole-path branch (interpolation.dart) never even reads a
  /// segment's own `temporal` at all, so editing it here would silently have
  /// zero visible effect while still LOOKING editable, and the graph editor's
  /// own curve preview would show the whole-path result regardless of what
  /// segment tab is selected - confusing rather than merely inert. Hiding the
  /// button while whole-path is on is the direct fix the issue itself
  /// suggested, rather than leaving a control that "works" but does nothing
  /// observable.
  List<Widget> _paramIcons(BuildContext context, Track trk, double localFrame, int componentCount, VoidCallback onReset) {
    final keyed = _hasKeyAt(trk, localFrame);
    return [
      // constant speed: only the whole-path curve shapes the pace.
      // the ease of the keys being edited (an animation layer's too).
      if (editTrackOf(trk).keyframes.length >= 2 && trk.globalEasing == null && !trk.constantSpeed)
        _easeButton(context, editTrackOf(trk), componentCount),
      ResetIconButton(onPressed: onReset),
      IconButton(
        icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 18),
        tooltip: 'toggle keyframe at current frame',
        onPressed: () => _toggleKey(trk, localFrame),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(4),
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      ),
    ];
  }

  Widget _easeButton(BuildContext context, Track trk, int componentCount) {
    return IconButton(
      icon: const Icon(Icons.show_chart, size: 18),
      tooltip: 'edit easing curve',
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: () => showDialog(
        context: context,
        builder: (_) => GraphEditorView(app: app, track: trk, componentCount: componentCount),
      ),
    );
  }

  /// movementSection.js's path-tension + whole-path-easing controls,
  /// both gated on `anchor.keyframes.length >= 2` (with exactly 2,
  /// tension has no visible effect - all 4 bezier control points stay
  /// collinear; it starts actually bending the path at 3+).
  Widget _pathControls(BuildContext context, Track anchor) {
    if (anchor.keyframes.length < 2) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ParamEditor(
          prefKey: 'movement.tension',
          label: 'tension',
          values: [anchor.tension ?? 1.0],
          scale: const ParamScale.slider(0, 1),
          onEditStart: app.pushUndo,
          onChanged: (v) {
            anchor.tension = v.first.clamp(0.0, 1.0);
            autoComputeTangents(anchor);
            app.commitEdit();
          },
          onCommit: (v) {
            app.pushUndo();
            anchor.tension = v.first.clamp(0.0, 1.0);
            autoComputeTangents(anchor);
            app.commitEdit();
          },
          trailing: [
            ResetIconButton(onPressed: () {
              app.pushUndo();
              anchor.tension = null;
              autoComputeTangents(anchor);
              app.commitEdit();
            }),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const SizedBox(width: 90, child: Text('Whole path')),
              Checkbox(
                value: anchor.globalEasing != null,
                onChanged: (on) {
                  app.pushUndo();
                  anchor.globalEasing = (on ?? false) ? easingPresets['easeInOut'] : null;
                  app.commitEdit();
                },
              ),
              if (anchor.globalEasing != null)
                IconButton(
                  icon: const Icon(Icons.show_chart, size: 18),
                  tooltip: 'edit whole-path easing curve',
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => GraphEditorView(app: app, track: anchor, componentCount: 2, wholePath: true),
                  ),
                ),
            ],
          ),
        ),
        // one speed along the whole path; the keys stay where they are,
        // their own times are set aside (not changed) while this is on.
        Row(
          children: [
            const SizedBox(width: 90, child: Text('Constant speed')),
            Checkbox(
              key: const ValueKey('constant-speed'),
              value: anchor.constantSpeed,
              onChanged: (on) {
                app.pushUndo();
                anchor.constantSpeed = on ?? false;
                app.commitEdit();
              },
            ),
            if (anchor.constantSpeed)
              const Expanded(
                child: Hint('pace: the whole-path curve'),
              ),
          ],
        ),
      ],
    );
  }

}
