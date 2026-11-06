import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';

/// Crop & Mirror tab: trims the object's sides (on the canvas with its
/// own handles, or with the sliders here), optionally locked to an
/// aspect ratio, and flips it horizontally/vertically. Applies to every
/// kind of object - shapes and media alike.
class CropView extends StatelessWidget {
  final AppState app;
  const CropView({super.key, required this.app});

  static const _sides = ['left', 'top', 'right', 'bottom'];
  static const _aspectLabels = {
    'free': 'Free',
    'original': 'Original',
    '1:1': '1:1',
    '4:3': '4:3',
    '16:9': '16:9',
    '9:16': '9:16',
  };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        if (layer == null) return const Center(child: Text('No layer selected'));
        return ListView(
          padding: const EdgeInsets.all(8),
          children: [
            Row(
              children: [
                const Expanded(child: Text('Crop', style: TextStyle(fontWeight: FontWeight.bold))),
                const Text('Edit on canvas', style: TextStyle(fontSize: 12)),
                Switch(value: cropEditing, onChanged: (_) => app.toggleCropEditing()),
              ],
            ),
            // the settings start folded; editing on canvas opens them.
            ExpansionTile(
              key: ValueKey('crop-settings-$cropEditing'),
              title: const Text('Crop settings', style: TextStyle(fontSize: 13)),
              initiallyExpanded: cropEditing,
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              dense: true,
              children: [
                Wrap(
                  spacing: 6,
                  children: [
                    for (final a in cropAspectOptions)
                      ChoiceChip(
                        label: Text(_aspectLabels[a]!),
                        selected: layer.cropAspect == a,
                        onSelected: (_) => app.setCropAspect(a),
                      ),
                  ],
                ),
                for (var i = 0; i < 4; i++)
                  ParamEditor(
                    prefKey: 'crop.${_sides[i]}',
                    label: _sides[i],
                    values: [layer.crop[i] * 100],
                    scale: const ParamScale.slider(0, 95, decimals: 0, suffix: '%', stops: [25, 50, 75]),
                    onEditStart: app.pushUndo,
                    onChanged: (v) => app.setCropInsetLive(i, v.first / 100),
                    onCommit: (v) => app.setCropInset(i, v.first / 100),
                    trailing: [ResetIconButton(onPressed: () => app.setCropInset(i, 0))],
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: layerHasCrop(layer) ? app.resetCrop : null,
                    icon: const Icon(Icons.crop_free, size: 18),
                    label: const Text('Reset crop'),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _DetachSection(app: app, layer: layer),
            const Divider(height: 20),
            const Text('Fit to frame', style: TextStyle(fontWeight: FontWeight.bold)),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => app.fitSelectedToStage('fit'),
                  icon: const Icon(Icons.fit_screen, size: 18),
                  label: const Text('Fit'),
                ),
                OutlinedButton.icon(
                  onPressed: () => app.fitSelectedToStage('fill'),
                  icon: const Icon(Icons.crop_square, size: 18),
                  label: const Text('Fill'),
                ),
                OutlinedButton.icon(
                  onPressed: () => app.fitSelectedToStage('stretch'),
                  icon: const Icon(Icons.open_in_full, size: 18),
                  label: const Text('Stretch'),
                ),
              ],
            ),
            const Hint('Fit: all of it visible. Fill: covers the frame. Stretch: exactly the frame. '
              'The visible (cropped) part is fitted; rotation is reset.'),
            const Divider(height: 20),
            const Text('Mirror', style: TextStyle(fontWeight: FontWeight.bold)),
            Row(
              children: [
                FilterChip(
                  avatar: const Icon(Icons.flip, size: 16),
                  label: const Text('Horizontal'),
                  selected: layer.mirrorX,
                  onSelected: (_) => app.toggleMirror(horizontal: true),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  avatar: const RotatedBox(quarterTurns: 1, child: Icon(Icons.flip, size: 16)),
                  label: const Text('Vertical'),
                  selected: layer.mirrorY,
                  onSelected: (_) => app.toggleMirror(horizontal: false),
                ),
              ],
            ),
            SwitchListTile(
              key: const ValueKey('mirror-moves-layer'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Move it too', style: TextStyle(fontSize: 13)),
              subtitle: const Text('Flipping also moves the layer to the mirror place (about the frame\'s middle)',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              value: app.mirrorMovesLayer,
              onChanged: (v) => app.setAppPreference('mirrorMovesLayer', v),
            ),
          ],
        );
      },
    );
  }
}


/// Detach a piece: a part of the object becomes a layer of its own (the
/// rest stays on the original) - by a rectangle drawn on the stage, or by
/// the shape of another layer.
class _DetachSection extends StatefulWidget {
  final AppState app;
  final Layer layer;
  const _DetachSection({required this.app, required this.layer});

  @override
  State<_DetachSection> createState() => _DetachSectionState();
}

class _DetachSectionState extends State<_DetachSection> {
  String? _referenceId;

  @override
  void dispose() {
    pieceRectTool = false; // the stage tools belong to this tab
    pieceInsets = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app, layer = widget.layer;
    final others = [for (final l in app.project.layers) if (l.id != layer.id && l.id != 'L_parent') l];
    final ref = others.where((l) => l.id == _referenceId).firstOrNull ?? others.firstOrNull;
    final cuts = layer.pieceClips.where((c) => !c.inside).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Detach a piece', style: TextStyle(fontWeight: FontWeight.bold)),
        const Hint('The part becomes a separate layer right above this one; this layer keeps the rest. '
          'Nothing is deleted - at first it looks the same, then the piece can be moved on its own.'),
        const SizedBox(height: 4),
        FilterChip(
          key: const ValueKey('piece-rect-tool'),
          avatar: const Icon(Icons.crop_square, size: 16),
          label: const Text('Draw a rectangle on the stage'),
          selected: pieceRectTool,
          onSelected: (_) => app.togglePieceRectTool(),
        ),
        if (pieceRectTool)
          const Hint('Drag over the object; lifting the finger detaches what is inside.'),
        // the same frame as Crop: four sides (stops at the quarters) and
        // the handles on the stage, then detach.
        FilterChip(
          key: const ValueKey('piece-crop-tool'),
          avatar: const Icon(Icons.crop, size: 16),
          label: const Text('Select like a crop'),
          selected: pieceInsets != null,
          onSelected: (_) => app.togglePieceCropTool(),
        ),
        if (pieceInsets != null) ...[
          for (var i = 0; i < 4; i++)
            ParamEditor(
              key: ValueKey('piece-inset-$i'),
              prefKey: 'piece.${CropView._sides[i]}',
              label: CropView._sides[i],
              values: [pieceInsets![i] * 100],
              scale: const ParamScale.slider(0, 95, decimals: 0, suffix: '%', stops: [25, 50, 75]),
              onEditStart: () {},
              onChanged: (v) => app.setPieceInset(i, v.first / 100),
              onCommit: (v) => app.setPieceInset(i, v.first / 100),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const ValueKey('piece-crop-detach'),
              onPressed: () => app.detachPieceInsets(layer.id),
              icon: const Icon(Icons.content_cut, size: 18),
              label: const Text('Detach this part'),
            ),
          ),
        ],
        const SizedBox(height: 6),
        Row(
          children: [
            const Text('By the shape of', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButton<String>(
                key: const ValueKey('piece-reference'),
                isExpanded: true,
                value: ref?.id,
                hint: const Text('no other layer'),
                items: [
                  for (final l in others) DropdownMenuItem(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _referenceId = v),
              ),
            ),
            IconButton(
              key: const ValueKey('piece-by-layer'),
              icon: const Icon(Icons.content_cut, size: 18),
              tooltip: 'detach the part under that layer',
              onPressed: ref == null ? null : () => app.detachPieceByLayer(layer.id, ref.id),
            ),
          ],
        ),
        const Hint('Uses that layer\'s shape as it is now, at the current frame.'),
        if (layer.pieceClips.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => app.clearPieceCuts(layer.id),
              icon: const Icon(Icons.restore, size: 18),
              label: Text(cuts > 0 ? 'Fill the cut-out holes back in ($cuts)' : 'Remove this piece\'s cut'),
            ),
          ),
      ],
    );
  }
}
