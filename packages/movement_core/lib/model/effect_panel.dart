/// The Effects tab's single list: geometry effect instances plus the
/// motion add-ons (motion blur, wiggle, pendulum, time quantize), in a user-chosen order.
/// Geometry effects render in effectStack order, so reordering the list
/// re-sorts effectStack; the motion add-ons' place is cosmetic.
library;

import 'dart:convert';

import 'project.dart';
import 'project_json.dart';

const motionPanelIds = ['motionBlur', 'wiggle', 'pendulum', 'swing', 'timeQuantize'];

bool _motionOn(Layer layer, String id) => switch (id) {
      'motionBlur' => layer.motionBlur.enabled,
      'wiggle' => layer.wiggle.enabled,
      'pendulum' => layer.pendulum.enabled,
      'swing' => layer.swing.enabled,
      'timeQuantize' => layer.timeQuantize.enabled,
      _ => false,
    };

/// The list as shown: the saved order filtered to what exists, then
/// anything not in it yet (instances in stack order, then enabled motion
/// add-ons).
List<String> effectPanelEntries(Layer layer) {
  final instanceIds = [for (final i in layer.effectStack) i.id];
  bool exists(String id) => motionPanelIds.contains(id) ? _motionOn(layer, id) : instanceIds.contains(id);
  final out = [for (final id in layer.effectPanelOrder) if (exists(id)) id];
  for (final id in [...instanceIds, ...motionPanelIds]) {
    if (!out.contains(id) && exists(id)) out.add(id);
  }
  return out;
}

/// Moves list entry `from` to `to` (a post-removal index), saves the
/// order, and re-sorts effectStack to match the instances' new order.
void reorderEffectPanel(Layer layer, int from, int to) {
  final entries = effectPanelEntries(layer);
  if (from < 0 || from >= entries.length) return;
  final moved = entries.removeAt(from);
  entries.insert(to.clamp(0, entries.length), moved);
  setEffectPanelOrder(layer, entries);
}

/// Saves the list order and re-sorts effectStack to match it.
void setEffectPanelOrder(Layer layer, List<String> entries) {
  layer.effectPanelOrder = entries;
  final rank = {for (var i = 0; i < entries.length; i++) entries[i]: i};
  layer.effectStack.sort((a, b) => (rank[a.id] ?? 0).compareTo(rank[b.id] ?? 0));
}

/// Adds a motion add-on to the list (enabled, with defaults).
void addMotionPanelEntry(Layer layer, String id) {
  switch (id) {
    case 'motionBlur':
      layer.motionBlur = MotionBlur(enabled: true);
    case 'wiggle':
      layer.wiggle = Wiggle(enabled: true);
    case 'pendulum':
      layer.pendulum = Pendulum(enabled: true);
    case 'swing':
      layer.swing = Swing(enabled: true);
    case 'timeQuantize':
      layer.timeQuantize = TimeQuantize(enabled: true);
    default:
      return;
  }
  layer.effectPanelOrder = [...effectPanelEntries(layer).where((e) => e != id), id];
}

/// Removes a motion add-on: off, back to defaults, out of the list.
void removeMotionPanelEntry(Layer layer, String id) {
  switch (id) {
    case 'motionBlur':
      layer.motionBlur = MotionBlur();
    case 'wiggle':
      layer.wiggle = Wiggle();
    case 'pendulum':
      layer.pendulum = Pendulum();
    case 'swing':
      layer.swing = Swing();
    case 'timeQuantize':
      layer.timeQuantize = TimeQuantize();
    default:
      return;
  }
  layer.effectPanelOrder = layer.effectPanelOrder.where((e) => e != id).toList();
}

/// One Effects-list entry as plain JSON, for the copy-effect button:
/// {'kind': 'instance', 'instance': ...} or {'kind': <motion id>, 'settings': ...}.
Map<String, dynamic>? effectEntryToJson(Layer layer, String id) {
  switch (id) {
    case 'motionBlur':
      return {'kind': id, 'settings': motionBlurToJson(layer.motionBlur)};
    case 'wiggle':
      return {'kind': id, 'settings': wiggleToJson(layer.wiggle)};
    case 'pendulum':
      return {'kind': id, 'settings': pendulumToJson(layer.pendulum)};
    case 'swing':
      return {'kind': id, 'settings': swingToJson(layer.swing)};
    case 'timeQuantize':
      return {'kind': id, 'settings': timeQuantizeToJson(layer.timeQuantize)};
  }
  for (final inst in layer.effectStack) {
    if (inst.id == id) return {'kind': 'instance', 'instance': effectInstanceToJson(inst)};
  }
  return null;
}

int _pasteCounter = 0;

/// Pastes a copied entry onto `layer`: an effect instance is added as a
/// new copy at the end of the list; a motion add-on replaces that
/// add-on's settings (and switches it on). Returns the pasted entry's id.
String? pasteEffectEntry(Layer layer, Map<String, dynamic> entry) {
  // a private copy, so the same clipboard can be pasted again.
  final j = jsonDecode(jsonEncode(entry)) as Map<String, dynamic>;
  final kind = j['kind'] as String?;
  if (kind == 'instance') {
    final inst = effectInstanceFromJson(j['instance'] as Map<String, dynamic>)
      ..id = 'fx_${DateTime.now().microsecondsSinceEpoch}_${_pasteCounter++}';
    layer.effectStack.add(inst);
    layer.effectPanelOrder = [...effectPanelEntries(layer).where((e) => e != inst.id), inst.id];
    return inst.id;
  }
  final settings = j['settings'] as Map<String, dynamic>?;
  if (settings == null || !motionPanelIds.contains(kind)) return null;
  switch (kind) {
    case 'motionBlur':
      layer.motionBlur = motionBlurFromJson(settings)..enabled = true;
    case 'wiggle':
      layer.wiggle = wiggleFromJson(settings)..enabled = true;
    case 'pendulum':
      layer.pendulum = pendulumFromJson(settings)..enabled = true;
    case 'swing':
      layer.swing = swingFromJson(settings)..enabled = true;
    case 'timeQuantize':
      layer.timeQuantize = timeQuantizeFromJson(settings)..enabled = true;
  }
  if (!layer.effectPanelOrder.contains(kind)) {
    layer.effectPanelOrder = [...effectPanelEntries(layer).where((e) => e != kind), kind!];
  }
  return kind;
}
