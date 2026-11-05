/// ============================================================
/// Parent-link stage visualization - NEW, no JS/desktop equivalent
/// (movement-mobile-gesture-spec.md: "parenting there is a plain
/// dropdown with zero on-stage indication that a relationship exists at
/// all"). Pure position/graph computation, same reasoning as
/// handles.dart for keeping this dart:ui-free and real-test-covered.
///
/// Global overlay: covers EVERY parent/child relationship in the
/// project, not scoped to the current selection or to a layer's own
/// in-range frame window - the spec calls it "always drawn," and a
/// rig's parent chain is a structural fact of the project, not
/// something that should flicker on/off as playback crosses a
/// particular layer's own startFrame/durationFrames window.
/// ============================================================
library;

import '../core/state_cache.dart';
import '../core/stage_size.dart';
import '../model/project.dart';

List<double> _anchorScreen(Project project, String layerId, int globalFrame) {
  final m = getLayerStateAt(project, layerId, globalFrame).matrix;
  return [m[4] * stageSize.width, m[5] * stageSize.height];
}

/// one parent/child relationship - parentScreen/childScreen are the two
/// line endpoints; the painter draws a hollow circle at the parent end,
/// a filled dot at the child end (spec's own per-edge convention).
class ParentLinkEdge {
  final String parentLayerId;
  final String childLayerId;
  final List<double> parentScreen;
  final List<double> childScreen;
  ParentLinkEdge({
    required this.parentLayerId,
    required this.childLayerId,
    required this.parentScreen,
    required this.childScreen,
  });
}

/// a layer that IS some other layer's parent but has no parent of its
/// own - the top of a chain. Resolves the ambiguity a plain edge-count
/// reading can't: a root with exactly one child produces exactly one
/// line, indistinguishable by count alone from an ordinary leaf (which
/// also has exactly one line, to ITS parent) - the root marker is what
/// makes "read the diagram by counting lines touching a point" valid
/// at all, not a decorative extra.
class ParentLinkRoot {
  final String layerId;
  final List<double> screen;
  ParentLinkRoot({required this.layerId, required this.screen});
}

class ParentLinkGeometry {
  final List<ParentLinkEdge> edges;
  final List<ParentLinkRoot> roots;
  ParentLinkGeometry({required this.edges, required this.roots});
}

ParentLinkGeometry computeParentLinkGeometry(Project project, int globalFrame) {
  final edges = <ParentLinkEdge>[];
  final referencedAsParent = <String>{};

  for (final layer in project.layers) {
    final parentId = layer.parentId;
    if (parentId == null) continue;
    if (findLayer(project, parentId) == null) continue; // dangling ref - nothing to draw
    referencedAsParent.add(parentId);
    edges.add(ParentLinkEdge(
      parentLayerId: parentId,
      childLayerId: layer.id,
      parentScreen: _anchorScreen(project, parentId, globalFrame),
      childScreen: _anchorScreen(project, layer.id, globalFrame),
    ));
  }

  final roots = <ParentLinkRoot>[];
  for (final id in referencedAsParent) {
    final layer = findLayer(project, id)!; // already confirmed to resolve above
    if (layer.parentId == null) {
      roots.add(ParentLinkRoot(layerId: id, screen: _anchorScreen(project, id, globalFrame)));
    }
  }

  return ParentLinkGeometry(edges: edges, roots: roots);
}
