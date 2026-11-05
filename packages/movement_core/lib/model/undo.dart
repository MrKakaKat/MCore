/// ============================================================
/// UNDO / REDO
/// - snapshot-based: project.layers is plain cloneable data, so a full
///   deep clone (cloneLayer, see project.dart) is simple and correct -
///   no custom diffing needed.
/// - pushed BEFORE a mutation, capturing "what it looked like right
///   before this action" - undo pops that back; redo pushes the
///   CURRENT state onto its own stack first so it can return to it.
///
/// Ported from movement-core/src/model/undo.js. `UndoHistory` is a
/// plain class (not Dart-global state) so tests - and, if the app ever
/// hosts multiple independent projects at once - each get their own
/// stack, the same reasoning as `Project`/`Selection` not being
/// singletons either.
/// ============================================================
library;

import 'layer_ops.dart';
import 'project.dart';

const _maxUndo = 50;

class UndoHistory {
  final List<List<Layer>> _undoStack = [];
  final List<List<Layer>> _redoStack = [];

  /// ui/ registers how to repaint after an undo/redo restores
  /// project.layers wholesale (layer list, params panel, the stage
  /// itself) - model/ has no business depending on ui/ directly.
  void Function() onRestore = () {};

  /// App state kept beside each step that isn't in the layers (the
  /// timeline range): captured with every snapshot, given back on undo /
  /// redo.
  Object? Function() captureExtra = () => null;
  void Function(Object? extra) restoreExtra = (_) {};
  final List<Object?> _undoExtra = [];
  final List<Object?> _redoExtra = [];

  List<Layer> snapshotProject(Project project) => [for (final l in project.layers) cloneLayer(l)];

  void pushUndoState(Project project) {
    _undoStack.add(snapshotProject(project));
    _undoExtra.add(captureExtra());
    if (_undoStack.length > _maxUndo) {
      _undoStack.removeAt(0);
      _undoExtra.removeAt(0);
    }
    _redoStack.clear(); // a fresh action invalidates any redo history
    _redoExtra.clear();
  }

  /// Drops the most recent undo entry - for an action that pushed its
  /// "before" state and was then cancelled, leaving nothing to undo.
  bool get canUndo => _undoStack.isNotEmpty;

  void discardLastUndoState() {
    if (_undoStack.isNotEmpty) {
      _undoStack.removeLast();
      _undoExtra.removeLast();
    }
  }

  /// Every layer list undo or redo can bring back (to know which media
  /// they still need).
  Iterable<List<Layer>> get snapshots => [..._undoStack, ..._redoStack];

  /// Undo + redo steps held.
  int get length => _undoStack.length + _redoStack.length;

  void clearHistory() {
    _undoStack.clear();
    _redoStack.clear();
    _undoExtra.clear();
    _redoExtra.clear();
  }

  void _restoreSnapshot(Project project, Selection selection, List<Layer> snapshot) {
    project.layers = snapshot;
    if (findLayer(project, selection.selectedLayer) == null) {
      selection.selectedLayer = project.layers.isNotEmpty ? project.layers.first.id : null;
    }
    selection.groupSelection.clear();
    onRestore();
  }

  void undo(Project project, Selection selection) {
    if (_undoStack.isEmpty) return;
    _redoStack.add(snapshotProject(project));
    _redoExtra.add(captureExtra());
    restoreExtra(_undoExtra.removeLast());
    _restoreSnapshot(project, selection, _undoStack.removeLast());
  }

  void redo(Project project, Selection selection) {
    if (_redoStack.isEmpty) return;
    _undoStack.add(snapshotProject(project));
    _undoExtra.add(captureExtra());
    restoreExtra(_redoExtra.removeLast());
    _restoreSnapshot(project, selection, _redoStack.removeLast());
  }
}
