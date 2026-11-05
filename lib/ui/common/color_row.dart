import 'package:flutter/material.dart';

import '../stage/stage_settings_dialog.dart' show parseHexColor;

// white, black and the colours new shapes get.
const _swatches = ['#00000000', '#ffffff', '#000000', '#e0a06a', '#7fc4a8', '#e07f9a', '#8ab4d8', '#c9a8e0', '#e0d47f', '#d8d8d8'];

/// The palette last copied (Palettes tab, or a colour field) - any
/// colour field can paste it; null: nothing copied.
final ValueNotifier<List<String>?> copiedPalette = ValueNotifier(null);

/// Palettes pasted into colour fields, by the field's label: shown with
/// its swatches (while the app runs).
final ValueNotifier<Map<String, List<String>>> fieldPalettes = ValueNotifier({});

/// Starts the stage eyedropper (press on the stage, a loupe shows the
/// colour, lift to take it) - the editor sets it; null hides the button.
void Function(ValueChanged<String> onPick)? startColorEyedropper;

/// Stops the eyedropper without taking a colour.
void Function()? cancelColorEyedropper;

/// The colour row whose eyedropper is on (null: none) - its button shows
/// it, and a second tap turns it off.
final ValueNotifier<Object?> eyedropperOwner = ValueNotifier(null);

/// A colour setting: folded, one swatch of the current colour (tap it to
/// open the palette); open, the palette swatches plus a custom hex entry.
class ColorRow extends StatefulWidget {
  final String label;
  final String hex;
  final ValueChanged<String> onPick;
  final bool initiallyOpen;
  const ColorRow({super.key, required this.label, required this.hex, required this.onPick, this.initiallyOpen = false});

  @override
  State<ColorRow> createState() => _ColorRowState();
}

class _ColorRowState extends State<ColorRow> {
  late bool _open = widget.initiallyOpen;

  @override
  void dispose() {
    // its field went away (another tab): its eyedropper stops too.
    if (identical(eyedropperOwner.value, this)) {
      cancelColorEyedropper?.call();
      eyedropperOwner.value = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hex = widget.hex;
    Widget swatch(String h, {Widget? child, VoidCallback? onTap}) => InkWell(
          onTap: onTap ?? () => widget.onPick(h),
          child: Container(
            width: 26,
            height: 26,
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              color: child == null && (parseHexColor(h)?.alpha ?? 255) > 0 ? parseHexColor(h) : null,
              border: Border.all(
                color: child == null && h.toLowerCase() == hex.toLowerCase() ? Colors.white : Colors.white24,
                width: child == null && h.toLowerCase() == hex.toLowerCase() ? 2 : 1,
              ),
            ),
            // transparent: a red slash across an empty square.
            child: child ?? ((parseHexColor(h)?.alpha ?? 255) == 0 ? CustomPaint(painter: _SlashPainter()) : null),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 72, child: Text(widget.label, style: const TextStyle(fontSize: 12))),
          Expanded(
            child: _open
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      // a pasted palette first, then the usual swatches.
                      for (final s in fieldPalettes.value[widget.label] ?? const <String>[]) swatch(s),
                      if ((fieldPalettes.value[widget.label] ?? const []).isNotEmpty)
                        Container(width: 1, height: 22, color: Colors.white24, margin: const EdgeInsets.only(right: 4)),
                      for (final s in _swatches) swatch(s),
                      // the whole square in the current colour, the pencil
                      // cut out of it.
                      InkWell(
                        onTap: () => _custom(context),
                        child: Tooltip(
                          message: 'custom colour',
                          child: Container(
                            width: 26,
                            height: 26,
                            margin: const EdgeInsets.only(right: 4),
                            decoration: BoxDecoration(border: Border.all(color: Colors.white24)),
                            // the colour all around, the pencil a silhouette
                            // in the panel's own colour.
                            child: Container(
                              color: parseHexColor(hex),
                              alignment: Alignment.center,
                              child: Icon(Icons.colorize, size: 16, color: Theme.of(context).scaffoldBackgroundColor),
                            ),
                          ),
                        ),
                      ),
                    ]),
                  )
                : Row(children: [
                    Tooltip(
                      message: 'show the palette',
                      child: swatch(hex, onTap: () => setState(() => _open = true)),
                    ),
                    Text(hex, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  ]),
          ),
          if (startColorEyedropper != null)
            ValueListenableBuilder<Object?>(
              valueListenable: eyedropperOwner,
              builder: (context, owner, _) {
                final on = identical(owner, this);
                return IconButton(
                  key: ValueKey('eyedropper-${widget.label}'),
                  icon: Icon(Icons.colorize, size: 16, color: on ? Theme.of(context).colorScheme.primary : null),
                  tooltip: on ? 'stop picking' : 'pick a colour from the stage',
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () {
                    if (on) {
                      cancelColorEyedropper?.call();
                      eyedropperOwner.value = null;
                    } else {
                      eyedropperOwner.value = this;
                      startColorEyedropper!(widget.onPick);
                    }
                  },
                );
              },
            ),
          if (_open)
            ValueListenableBuilder<List<String>?>(
              valueListenable: copiedPalette,
              builder: (context, copied, _) => PopupMenuButton<String>(
                key: ValueKey('palette-menu-${widget.label}'),
                icon: const Icon(Icons.palette_outlined, size: 16),
                tooltip: 'palettes',
                padding: EdgeInsets.zero,
                onSelected: (v) {
                  final pals = {...fieldPalettes.value};
                  switch (v) {
                    case 'paste':
                      pals[widget.label] = [...copied!];
                    case 'copy':
                      copiedPalette.value = [
                        ...?fieldPalettes.value[widget.label],
                        if (!(fieldPalettes.value[widget.label] ?? const []).contains(widget.hex)) widget.hex,
                      ];
                    case 'clear':
                      pals.remove(widget.label);
                  }
                  fieldPalettes.value = pals;
                  setState(() {});
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'paste',
                      enabled: copied != null,
                      child: Text(copied == null ? 'Paste palette (copy one first)' : 'Paste palette (${copied.length})')),
                  const PopupMenuItem(value: 'copy', child: Text('Copy this field\'s palette')),
                  if ((fieldPalettes.value[widget.label] ?? const []).isNotEmpty)
                    const PopupMenuItem(value: 'clear', child: Text('Take the palette away')),
                ],
              ),
            ),
          IconButton(
            icon: Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18),
            tooltip: _open ? 'fold the palette' : 'show the palette',
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => setState(() => _open = !_open),
          ),
        ],
      ),
    );
  }

  Future<void> _custom(BuildContext context) async {
    final controller = TextEditingController(text: widget.hex.replaceFirst('#', ''));
    final color = await showDialog<Color>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Custom ${widget.label.toLowerCase()}'),
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
    if (color == null) return;
    final v = color.value & 0xFFFFFF;
    widget.onPick('#${v.toRadixString(16).padLeft(6, '0')}');
  }
}


class _SlashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) => canvas.drawLine(
      Offset(size.width, 0),
      Offset(0, size.height),
      Paint()
        ..color = const Color(0xFFE05050)
        ..strokeWidth = 1.5);

  @override
  bool shouldRepaint(_SlashPainter old) => false;
}
