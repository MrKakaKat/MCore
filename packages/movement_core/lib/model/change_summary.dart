/// A short description of what changed between two states of a project's
/// layers - for the toast after an undo / redo ("Undo: rotation of
/// rect_1"). Worked out by comparing the layers, so every edit gets one
/// without each having to name itself.
library;

import 'dart:convert';

import 'project.dart';
import 'project_json.dart';

const _partNames = {
  'anchor': 'position',
  'rotation': 'rotation',
  'scale': 'size',
  'opacity': 'opacity',
  'pathFollow': 'path follow',
  'effectStack': 'effects',
  'effectPanelOrder': 'effect order',
  'masks': 'masks',
  'content': 'shape',
  'startFrame': 'timing',
  'durationFrames': 'timing',
  'loop': 'loop',
  'color': 'colour',
  'fill': 'fill',
  'renderMode': 'outline mode',
  'hidden': 'visibility',
  'name': 'name',
  'parentId': 'parent',
  'inherit': 'parenting',
  'motionBlur': 'motion blur',
  'wiggle': 'wiggle',
  'pendulum': 'pendulum',
  'swing': 'swing',
  'crop': 'crop',
  'cropAspect': 'crop',
  'mirrorX': 'mirror',
  'mirrorY': 'mirror',
  'chromaKey': 'chroma key',
  'pieces': 'cut',
  'link': 'link',
  'row': 'timeline row',
  'timeQuantize': 'time steps',
  'precompose': 'group',
  'groupedChildren': 'group',
};

/// What differs from `before` to `after`, e.g. "rotation of rect_1",
/// "deleting circle_2", "3 layers". Empty string if nothing did.
String describeLayerChange(List<Layer> before, List<Layer> after) {
  final b = {for (final l in before) l.id: l}, a = {for (final l in after) l.id: l};
  final added = [for (final l in after) if (!b.containsKey(l.id)) l.name];
  final removed = [for (final l in before) if (!a.containsKey(l.id)) l.name];
  if (added.isNotEmpty && removed.isEmpty) return 'adding ${_names(added)}';
  if (removed.isNotEmpty && added.isEmpty) return 'deleting ${_names(removed)}';
  if (added.isNotEmpty) return 'layers ${_names([...removed, ...added])}';

  final changed = <String, Set<String>>{};
  for (final l in after) {
    final old = b[l.id]!;
    final oj = layerToJson(old), nj = layerToJson(l);
    final parts = <String>{};
    for (final key in {...oj.keys, ...nj.keys}) {
      if (jsonEncode(oj[key]) == jsonEncode(nj[key])) continue;
      if (key == 'transform') {
        final ot = oj[key] as Map, nt = nj[key] as Map;
        for (final tk in {...ot.keys, ...nt.keys}) {
          if (jsonEncode(ot[tk]) != jsonEncode(nt[tk])) parts.add(_partNames[tk] ?? '$tk');
        }
      } else {
        parts.add(_partNames[key] ?? key);
      }
    }
    if (parts.isNotEmpty) changed[l.name] = parts;
  }
  if (changed.isEmpty) {
    final order = [for (final l in after) l.id].join() != [for (final l in before) l.id].join();
    return order ? 'layer order' : '';
  }
  if (changed.length > 1) return '${changed.length} layers';
  final name = changed.keys.single, parts = changed.values.single.toList();
  final what = parts.length > 3 ? '${parts.take(3).join(', ')}, ...' : parts.join(', ');
  return '$what of $name';
}

String _names(List<String> names) => names.length > 2 ? '${names.length} layers' : names.join(', ');
