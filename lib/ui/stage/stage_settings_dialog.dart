import 'package:flutter/material.dart';

import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/reset_button.dart';

/// aspect-ratio presets (a custom size) for the frame, plus the
/// off-canvas-content visibility toggle. The frame's own boundary always stays
/// drawn (stage_painter.dart never gates the outline on this widget's own
/// state) - this only controls the frame's actual resolution and whether
/// content beyond it is visible while zoomed out.
///
/// (I didn't see the aspect-ratio settings - they should be added as a
/// SEPARATE SECTION) - the icon-triggered dialog alone wasn't discoverable
/// enough, so `StageSettingsView` is now the shared CONTENT (no dialog
/// chrome), used by a "Stage" tab/drawer entry in main.dart's `_ParamsTabs` on
/// every layout.
///
/// (same goes for Stage settings - remove from the top icons) - the small
/// icon-triggered dialog that used to wrap this view
/// (`showStageSettingsDialog`) was pure duplication of the tab/drawer entry
/// above and has been removed; `showAspectRatioPickerDialog` below is
/// unrelated and stays (it's the PRESET picker's own dialog, opened from
/// inside this view itself, not a duplicate way to reach the view as a whole).
///
/// (put the aspect-ratio PRESET picker in its own separate dialog; keep custom
/// size inline in the tab) - the `Wrap` of preset chips moved out of this
/// tab's body into `showAspectRatioPickerDialog` below, triggered by a single
/// "Choose preset." button; "Custom size (px)" is unchanged, still inline
/// here.
class _Preset {
  final String label;
  final double width;
  final double height;
  const _Preset(this.label, this.width, this.height);
}

const _presets = [
  _Preset('16:9 (landscape)', 640, 360),
  _Preset('9:16 (portrait)', 360, 640),
  _Preset('1:1 (square)', 480, 480),
  _Preset('4:3', 640, 480),
  _Preset('3:4', 480, 640),
];

/// The preset picker's own separate dialog - a plain list, closing on
/// selection via the same `app.setFrameSize(...)` StageSettingsView's
/// custom-size field also uses.
Future<void> showAspectRatioPickerDialog(BuildContext context, AppState app) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Frame aspect ratio'),
      content: SizedBox(
        width: 280,
        child: AnimatedBuilder(
          animation: app,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final preset in _presets)
                ListTile(
                  title: Text(preset.label),
                  trailing: (app.frameWidth == preset.width && app.frameHeight == preset.height) ? const Icon(Icons.check) : null,
                  onTap: () {
                    app.setFrameSize(preset.width, preset.height);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ),
  );
}

class StageSettingsView extends StatefulWidget {
  final AppState app;
  const StageSettingsView({super.key, required this.app});

  @override
  State<StageSettingsView> createState() => _StageSettingsViewState();
}

class _StageSettingsViewState extends State<StageSettingsView> {
  late final TextEditingController _widthController = TextEditingController(text: widget.app.frameWidth.round().toString());
  late final TextEditingController _heightController = TextEditingController(text: widget.app.frameHeight.round().toString());

  @override
  void dispose() {
    _widthController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  String _currentPresetLabel() {
    for (final preset in _presets) {
      if (widget.app.frameWidth == preset.width && widget.app.frameHeight == preset.height) return preset.label;
    }
    return 'Choose preset...';
  }

  void _applyCustomSize() {
    final width = double.tryParse(_widthController.text);
    final height = double.tryParse(_heightController.text);
    if (width == null || height == null || width <= 0 || height <= 0) return;
    widget.app.setFrameSize(width, height);
  }

  /// The stage camera: a frame moved like a layer (keys, parent = follow
  /// an object); export and the player show what is inside it.
  Widget _cameraSection() {
    final app = widget.app;
    final cam = activeCamera(app.project);
    final others = [for (final l in app.project.layers) if (!identical(l, cam) && !isCameraShape(l.content.shape)) l];
    return Column(
      key: const ValueKey('stage-camera'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Camera', style: TextStyle(fontWeight: FontWeight.bold)),
        if (cam == null) ...[
          const Hint('Move, turn and zoom the whole picture: the camera\'s frame is what export shows.'),
          OutlinedButton.icon(
            key: const ValueKey('add-camera'),
            icon: const Icon(Icons.videocam_outlined, size: 18),
            label: const Text('Add camera'),
            onPressed: app.addStageCamera,
          ),
        ] else ...[
          const Hint('Select it and use its handles: move, turn, resize (bigger frame = zoomed out). '
              'Keys on it animate the camera.'),
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton(
              key: const ValueKey('select-camera'),
              onPressed: () => app.selectLayer(cam.id),
              child: const Text('Select camera'),
            ),
            FilterChip(
              key: const ValueKey('camera-view'),
              label: const Text('Camera view'),
              selected: app.cameraView,
              onSelected: app.setCameraView,
            ),
          ]),
          Row(children: [
            const SizedBox(width: 72, child: Text('Follow', style: TextStyle(fontSize: 12))),
            Expanded(
              child: DropdownButton<String?>(
                key: const ValueKey('camera-follow'),
                isExpanded: true,
                value: cam.parentId,
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('(nothing)')),
                  for (final l in others) DropdownMenuItem<String?>(value: l.id, child: Text(l.name)),
                ],
                onChanged: (id) {
                  app.pushUndo();
                  reparentPreservingWorldPosition(app.project, cam, id, app.currentFrame);
                  app.commitEdit();
                },
              ),
            ),
          ]),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.app,
      builder: (context, _) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cameraSection(),
              const Divider(),
              const Text('Background', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              // stage colors live in their own window, like the aspect-ratio
              // presets.
              Row(
                children: [
                  OutlinedButton.icon(
                    icon: SizedBox(
                      width: 18,
                      height: 18,
                      child: DecoratedBox(
                        decoration: BoxDecoration(border: Border.all(color: Colors.white38)),
                        child: widget.app.background == null
                            ? const CustomPaint(painter: _CheckerPainter())
                            : ColoredBox(color: widget.app.background!),
                      ),
                    ),
                    label: Text(widget.app.background == null ? 'Transparent' : _hex(widget.app.background!)),
                    onPressed: () => showBackgroundDialog(context, widget.app),
                  ),
                  ResetIconButton(onPressed: () => widget.app.setBackground(null)),
                ],
              ),
              const Hint('Fills the canvas only - the stage around it stays gray. Transparent keeps real transparency in PNG export.'),
              const Divider(height: 24),
              const Text('Frame aspect ratio', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.aspect_ratio),
                label: Text(_currentPresetLabel()),
                onPressed: () async {
                  await showAspectRatioPickerDialog(context, widget.app);
                  setState(() {
                    _widthController.text = widget.app.frameWidth.round().toString();
                    _heightController.text = widget.app.frameHeight.round().toString();
                  });
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Text('Scale objects with resolution', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Switch(
                    value: widget.app.scaleContentOnResize,
                    onChanged: (_) => widget.app.toggleScaleContentOnResize(),
                  ),
                  ResetIconButton(onPressed: () {
                    if (!widget.app.scaleContentOnResize) widget.app.toggleScaleContentOnResize();
                  }),
                ],
              ),
              const Hint('When on, changing the frame size (preset or custom) scales every layer\'s own size and position to match, so objects keep the same size relative to the canvas.'),
              Row(children: [
                const Expanded(child: Text('Never stretch objects', style: TextStyle(fontWeight: FontWeight.bold))),
                Switch(
                  key: const ValueKey('resize-evenly'),
                  value: widget.app.resizeEvenly,
                  onChanged: (v) => widget.app.setAppPreference('resizeEvenly', v),
                ),
              ]),
              const Hint('A new aspect ratio scales everything evenly (by the smaller change) and keeps each object in its '
                  'place around the middle - nothing gets squashed.'),
              OutlinedButton.icon(
                key: const ValueKey('fit-frame-to-media'),
                icon: const Icon(Icons.aspect_ratio, size: 18),
                label: const Text('Fit the frame to the picture / video'),
                onPressed: () {
                  if (!widget.app.fitFrameToMedia()) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No picture or video layer')));
                  }
                  setState(() {
                    _widthController.text = widget.app.frameWidth.round().toString();
                    _heightController.text = widget.app.frameHeight.round().toString();
                  });
                },
              ),
              const SizedBox(height: 12),
              const Text('Custom size (px)', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _widthController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Width'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _heightController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Height'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(onPressed: _applyCustomSize, child: const Text('Apply')),
                ],
              ),
              const Divider(height: 24),
              Row(
                children: [
                  const Expanded(child: Text('Mirror stage', style: TextStyle(fontWeight: FontWeight.bold))),
                  FilterChip(
                    label: const Text('Horizontal'),
                    selected: widget.app.stageMirrorX,
                    onSelected: (_) => widget.app.toggleStageMirror(horizontal: true),
                  ),
                  const SizedBox(width: 6),
                  FilterChip(
                    label: const Text('Vertical'),
                    selected: widget.app.stageMirrorY,
                    onSelected: (_) => widget.app.toggleStageMirror(horizontal: false),
                  ),
                  ResetIconButton(onPressed: widget.app.resetStageMirror),
                ],
              ),
              const Hint('Flips the whole frame - on the stage and in every export.'),
              const Divider(height: 24),
              Row(
                children: [
                  const Expanded(
                    child: Text('Show off-canvas content', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Switch(
                    value: widget.app.showOffCanvasContent,
                    onChanged: (_) => widget.app.toggleShowOffCanvasContent(),
                  ),
                  ResetIconButton(onPressed: () {
                    if (widget.app.showOffCanvasContent) widget.app.toggleShowOffCanvasContent();
                  }),
                ],
              ),
              const Hint('When on, layers positioned outside the frame stay visible once zoomed out - the frame\'s own boundary is always shown either way.'),
              const Divider(height: 24),
              Row(
                children: [
                  const Expanded(
                    child: Text('Outline added projects', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Switch(
                    key: const ValueKey('project-outlines'),
                    value: widget.app.showProjectOutlines,
                    onChanged: (_) => widget.app.toggleShowProjectOutlines(),
                  ),
                ],
              ),
              const Hint('A blue outline around each project placed here, with dashed lines continuing its edges. Not exported.'),
            ],
          ),
        );
      },
    );
  }
}

/// The canvas background picker in its own dialog.
Future<void> showBackgroundDialog(BuildContext context, AppState app) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Background'),
      content: SizedBox(
        width: 280,
        child: AnimatedBuilder(
          animation: app,
          builder: (_, __) => BackgroundPicker(app: app),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
    ),
  );
}

const _backgroundSwatches = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFF000000),
  Color(0xFF808080),
  Color(0xFF1E88E5),
  Color(0xFF43A047),
  Color(0xFFE53935),
  Color(0xFFFDD835),
];

/// Canvas background swatches: Transparent first (the default), a few
/// plain colors, and "Custom..." (hex entry).
class BackgroundPicker extends StatelessWidget {
  final AppState app;
  const BackgroundPicker({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final current = app.background;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Swatch(
          tooltip: 'Transparent',
          selected: current == null,
          onTap: () => app.setBackground(null),
          child: const CustomPaint(painter: _CheckerPainter()),
        ),
        for (final c in _backgroundSwatches)
          _Swatch(
            tooltip: _hex(c),
            selected: current == c,
            onTap: () => app.setBackground(c),
            child: ColoredBox(color: c),
          ),
        _Swatch(
          tooltip: 'Custom...',
          selected: current != null && !_backgroundSwatches.contains(current),
          onTap: () => _pickCustom(context),
          child: current != null && !_backgroundSwatches.contains(current)
              ? ColoredBox(color: current)
              : const Icon(Icons.colorize, size: 18),
        ),
      ],
    );
  }

  Future<void> _pickCustom(BuildContext context) async {
    final controller = TextEditingController(
        text: app.background == null ? '' : _hex(app.background!).substring(1));
    final color = await showDialog<Color>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Custom background'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(prefixText: '#', hintText: 'RRGGBB'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, parseHexColor(controller.text)),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (color != null) app.setBackground(color);
  }
}

/// "RRGGBB" / "#RRGGBB" -> opaque Color, or null if malformed.
Color? parseHexColor(String text) {
  final t = text.trim().replaceFirst('#', '');
  if (t.length != 6 && t.length != 8) return null;
  final v = int.tryParse(t, radix: 16);
  if (v == null) return null;
  // #rrggbbaa: its own alpha.
  return t.length == 8 ? Color(((v & 0xFF) << 24) | (v >> 8)) : Color(0xFF000000 | v);
}

String _hex(Color c) =>
    '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

class _Swatch extends StatelessWidget {
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  const _Swatch({required this.tooltip, required this.selected, required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? Theme.of(context).colorScheme.primary : Colors.white24,
              width: selected ? 3 : 1,
            ),
          ),
          child: ClipRect(child: Center(child: SizedBox.expand(child: child))),
        ),
      ),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const tile = 6.0;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF2A2A2A));
    final light = Paint()..color = const Color(0xFF5A5A5A);
    var row = 0;
    for (var y = 0.0; y < size.height; y += tile, row++) {
      for (var x = row.isEven ? 0.0 : tile; x < size.width; x += 2 * tile) {
        canvas.drawRect(Rect.fromLTWH(x, y, tile, tile), light);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
