/// Layer names: `<Type> <n>` with the smallest number not in use, so a
/// deleted layer's number is reused and each type counts on its own
/// (Rect 1 and Circle 1 side by side).
library;

import 'project.dart';

/// `<Prefix> <n>` with the smallest n >= `from` that no layer in `project`
/// is called.
String nextFreeLayerName(Project project, String prefix, {int from = 1}) {
  final used = {for (final l in project.layers) l.name};
  if (prefix.isNotEmpty) prefix = prefix[0].toUpperCase() + prefix.substring(1);
  var n = from;
  while (used.contains('$prefix $n')) {
    n++;
  }
  return '$prefix $n';
}

/// The next split piece of `root`: 'root 2', 'root 3', ...
String nextSplitPieceName(Project project, String root) => nextFreeLayerName(project, root, from: 2);

final _numbered = RegExp(r'^(.*?)[ _]\d+$');

/// Renames a layer that's about to be added: its name's type prefix
/// ("Rect" of "Rect 7" or the old "rect_7") with the first free number.
void nameNewLayer(Project project, Layer layer) {
  final m = _numbered.firstMatch(layer.name);
  final prefix = m == null ? layer.name : m.group(1)!;
  layer.name = nextFreeLayerName(project, prefix);
}

/// `name`, or - when another layer (not `exceptId`) has it - the first
/// free "name 2", "name 3"...
String uniqueLayerName(Project project, String name, {String? exceptId}) {
  final used = {for (final l in project.layers) if (l.id != exceptId) l.name};
  if (!used.contains(name)) return name;
  var n = 2;
  while (used.contains('$name $n')) {
    n++;
  }
  return '$name $n';
}

/// No two layers share a name (folders may): a repeated one, after the
/// first, gets the next free number. True when it renamed any.
bool ensureUniqueLayerNames(Project project) {
  final seen = <String>{};
  var changed = false;
  for (final l in project.layers) {
    if (!seen.add(l.name)) {
      l.name = uniqueLayerName(project, l.name, exceptId: l.id);
      seen.add(l.name);
      changed = true;
    }
  }
  return changed;
}
