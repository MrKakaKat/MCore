import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Transform;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../common/color_row.dart';
import '../common/keyed_param_row.dart';
import '../common/param_editor.dart';
import '../common/reset_button.dart';
import '../../io/file_pick.dart';

/// Text tab: the selected text layer's words, font (the bundled Roboto
/// plus any loaded .ttf/.otf), size, letter and line spacing, alignment,
/// colour, letter outline, shadow and background block. The text box
/// itself is resized on the stage with the side handles.
class TextView extends StatelessWidget {
  final AppState app;
  const TextView({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final layer = findLayer(app.project, app.selection.selectedLayer);
        final t = layer?.content.text;
        if (layer == null || t == null || layer.content.shape != 'text') {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Select a text layer, or add one'),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: app.addTextLayer,
                  icon: const Icon(Icons.text_fields),
                  label: const Text('Add text'),
                ),
              ],
            ),
          );
        }
        return _TextEditor(key: ValueKey(layer.id), app: app, layer: layer, t: t);
      },
    );
  }
}

class _TextEditor extends StatefulWidget {
  final AppState app;
  final Layer layer;
  final TextSpec t;
  const _TextEditor({super.key, required this.app, required this.layer, required this.t});

  @override
  State<_TextEditor> createState() => _TextEditorState();
}

class _TextEditorState extends State<_TextEditor> {
  late final TextEditingController _text = TextEditingController(text: widget.t.textAt(_local));
  final FocusNode _focus = FocusNode();
  bool _undoPushed = false;

  AppState get app => widget.app;
  String get id => widget.layer.id;

  /// The layer's own frame at the playhead (text keys).
  int get _local => layerLocalFrame(widget.layer, app.currentFrame).round();

  @override
  void initState() {
    super.initState();
    // one undo step per typing session.
    _focus.addListener(() {
      if (!_focus.hasFocus) _undoPushed = false;
    });
    app.frameNotifier.addListener(_onFrame);
  }

  // the playhead moved: the field shows the text of the key there (a new
  // typing session if the key changed).
  Keyframe? _shownKey;
  void _onFrame() {
    if (!mounted) return;
    final key = widget.t.keyAt(_local);
    final shown = widget.t.textAt(_local);
    if (!identical(key, _shownKey) || (!_focus.hasFocus && _text.text != shown)) {
      _shownKey = key;
      _undoPushed = false;
      if (_text.text != shown) _text.text = shown;
    }
    // the "Key at N" button follows the playhead on every frame.
    setState(() {});
  }

  @override
  void didUpdateWidget(_TextEditor old) {
    super.didUpdateWidget(old);
    // undo/redo or another edit changed the text: show it.
    final shown = widget.t.textAt(_local);
    // undo / redo bring back another text object: the field follows it
    // even while typing.
    final replaced = !identical(old.t, widget.t) && _undoPushedFor != widget.t;
    if ((!_focus.hasFocus || replaced) && _text.text != shown) {
      _text.value = TextEditingValue(text: shown, selection: TextSelection.collapsed(offset: shown.length));
      _undoPushed = false;
    }
  }

  @override
  void dispose() {
    selectedTextPart = null; // the part's box leaves the stage with the tab
    app.frameNotifier.removeListener(_onFrame);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  // the text object our typing session edits.
  TextSpec? _undoPushedFor;

  void _typed(String v) {
    if (!_undoPushed) {
      app.pushUndo();
      _undoPushed = true;
    }
    _undoPushedFor = widget.t;
    final f = _local;
    app.editTextLive(id, (t) => t.setTextAt(f, v));
  }

  /// The text field's selection as letter indices [start, end), or null.
  (int, int)? _selectedLetters() {
    final sel = _text.selection;
    if (!sel.isValid || sel.isCollapsed) return null;
    final s = _text.text;
    int letters(int i) => s.substring(0, i.clamp(0, s.length)).runes.length;
    return (letters(sel.start), letters(sel.end));
  }

  List<Widget> _keysSection(TextSpec t) {
    final f = _local;
    return [
      Row(children: [
        const Spacer(),
        TextButton.icon(
          key: const ValueKey('text-key-add'),
          onPressed: t.keys.any((k) => k.frame == f) ? null : () => app.editText(id, (t) => t.addKey(f)),
          icon: const Icon(Icons.add, size: 16),
          label: Text('Key at $f'),
        ),
      ]),
      const Hint(
          'From each key on, the layer shows that key\'s text. Type above to change the text where the playhead is.'),
      for (final k in t.keys)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          selected: identical(t.keyAt(f), k),
          leading: Text('${k.frame}', style: const TextStyle(fontSize: 12)),
          title: Text((k.value as String).replaceAll('\n', ' / '), maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => app.setFrame(widget.layer.startFrame + k.frame),
          trailing: IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'remove key',
            onPressed: () => app.editText(id, (t) => t.keys.removeWhere((x) => x.frame == k.frame)),
          ),
        ),
    ];
  }

  /// Parts of the text (sublayers): made from the selection, or the whole
  /// text split into letters / words. Each has its own look (size, rise,
  /// colour, font) and motion (move, turn, scale, opacity - keyable) for a
  /// stretch of time; later parts draw over earlier ones.
  List<Widget> _spansSection(TextSpec t) {
    final shown = t.textAt(_local).runes.toList();
    String part(TextStyleSpan s) =>
        String.fromCharCodes(shown.sublist(s.start.clamp(0, shown.length), s.end.clamp(0, shown.length)));
    void split(String by) => app.editText(id, (t) {
          final runes = t.textAt(_local).runes.toList();
          var i = 0;
          while (i < runes.length) {
            final space = runes[i] == 0x20 || runes[i] == 0x0A || runes[i] == 0x09;
            if (space) {
              i++;
              continue;
            }
            var j = i + 1;
            if (by == 'word') {
              while (j < runes.length && !(runes[j] == 0x20 || runes[j] == 0x0A || runes[j] == 0x09)) {
                j++;
              }
            }
            t.spans.add(TextStyleSpan(i, j, name: String.fromCharCodes(runes.sublist(i, j))));
            i = j;
          }
        });
    return [
      Wrap(spacing: 4, children: [
        TextButton.icon(
          key: const ValueKey('text-span-add'),
          onPressed: () {
            final r = _selectedLetters();
            if (r == null) {
              ScaffoldMessenger.maybeOf(context)
                  ?.showSnackBar(const SnackBar(content: Text('Select letters in the text first')));
              return;
            }
            // nothing changes until a setting is touched.
            app.editText(id, (t) => t.spans.add(TextStyleSpan(r.$1, r.$2, name: String.fromCharCodes(shown.sublist(
                r.$1.clamp(0, shown.length), r.$2.clamp(0, shown.length))))));
          },
          icon: const Icon(Icons.format_shapes, size: 16),
          label: const Text('Part from selection'),
        ),
        TextButton(
          key: const ValueKey('text-split-letters'),
          onPressed: () => split('char'),
          child: const Text('Split: letters'),
        ),
        TextButton(
          key: const ValueKey('text-split-words'),
          onPressed: () => split('word'),
          child: const Text('Split: words'),
        ),
        if (t.spans.isNotEmpty)
          TextButton(
            key: const ValueKey('text-parts-clear'),
            onPressed: () => app.editText(id, (t) => t.spans.clear()),
            child: const Text('Remove all'),
          ),
      ]),
      for (var i = 0; i < t.spans.length; i++) _partCard(t, i, part(t.spans[i])),
    ];
  }

  /// One part: folded to a line; open, its look, motion and time.
  Widget _partCard(TextSpec t, int i, String letters) {
    final sp = t.spans[i];
    final f = _local;
    // edits go to this text only (parts are its own).
    void edit(void Function(TextStyleSpan s) e) => app.editText(id, (t) => e(t.spans[i]));
    Widget value(String key, String label, double v, double def, ParamScale scale, void Function(TextStyleSpan s, double v) set) =>
        ParamEditor(
          key: ValueKey('text-part-$i-$key'),
          prefKey: 'text.part.$key',
          label: label,
          values: [v],
          scale: scale,
          onEditStart: app.pushUndo,
          onChanged: (x) => app.editTextLive(id, (t) => set(t.spans[i], x.first.clamp(scale.min, scale.max).toDouble())),
          onCommit: (x) => app.editTextLive(id, (t) => set(t.spans[i], x.first.clamp(scale.min, scale.max).toDouble())),
          trailing: [ResetIconButton(onPressed: () => edit((s) => set(s, def)))],
        );
    // a motion value: its track made on first touch, keys at this frame.
    Widget motion(String key, String label, Track? Function(TextStyleSpan s) get, void Function(TextStyleSpan s, Track t) make,
        dynamic def, ParamScale scale) {
      final trk = get(sp);
      final v = trk == null ? def : evaluateTrack(null, trk, f.toDouble());
      final vals = v is List ? [for (final e in v) (e as num).toDouble()] : [(v as num).toDouble()];
      final keyed = trk?.keyframes.any((k) => k.frame == f) ?? false;
      dynamic out(List<double> x) => vals.length > 1 ? x : x.first;
      void put(TextStyleSpan s, List<double> x) {
        final t0 = get(s) ?? (Track(def is List ? List<double>.from(def) : def, false));
        if (get(s) == null) make(s, t0);
        setTrackValueAt(t0, f, out(x));
      }

      return ParamEditor(
        key: ValueKey('text-part-$i-$key'),
        prefKey: 'text.part.$key',
        label: label,
        values: vals,
        scale: scale,
        componentLabels: vals.length > 1 ? const ['x', 'y'] : null,
        onEditStart: app.pushUndo,
        onChanged: (x) => app.editTextLive(id, (t) => put(t.spans[i], x)),
        onCommit: (x) => app.editTextLive(id, (t) => put(t.spans[i], x)),
        trailing: [
          IconButton(
            icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
            tooltip: 'toggle keyframe at current frame',
            visualDensity: VisualDensity.compact,
            onPressed: () => edit((s) {
              final t0 = get(s) ?? Track(def is List ? List<double>.from(def) : def, false);
              if (get(s) == null) make(s, t0);
              final at = t0.keyframes.indexWhere((k) => k.frame == f);
              if (at >= 0) {
                t0.keyframes.removeAt(at);
              } else {
                t0.keyframes
                  ..add(Keyframe(frame: f, value: v, temporal: newKeyEasing()))
                  ..sort((a, b) => a.frame.compareTo(b.frame));
              }
            }),
          ),
        ],
      );
    }

    final fonts = registeredFonts();
    return Card(
      key: ValueKey('text-part-$i'),
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ExpansionTile(
        dense: true,
        // open: shown on the stage (drag it there to move it).
        initiallyExpanded: selectedTextPart == i,
        onExpansionChanged: (open) {
          selectedTextPart = open ? i : (selectedTextPart == i ? null : selectedTextPart);
          app.notifyListeners();
        },
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        title: Text('"$letters"  ${sp.from != null || sp.to != null ? '(${sp.from ?? 0}-${sp.to ?? '...'})' : ''}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          // order: later parts draw over earlier ones.
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 16),
            tooltip: 'draw it earlier (under the others)',
            visualDensity: VisualDensity.compact,
            onPressed: i == 0 ? null : () => app.editText(id, (t) => t.spans.insert(i - 1, t.spans.removeAt(i))),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'remove the part',
            visualDensity: VisualDensity.compact,
            onPressed: () => app.editText(id, (t) => t.spans.removeAt(i)),
          ),
        ]),
        children: [
          Row(children: [
            const SizedBox(width: 60, child: Text('Font', style: TextStyle(fontSize: 12))),
            Expanded(
              child: DropdownButton<String?>(
                isExpanded: true,
                value: fonts.containsKey(sp.fontId) ? sp.fontId : null,
                hint: const Text('the text\'s'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('the text\'s')),
                  for (final e in fonts.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => edit((s) => s.fontId = v),
              ),
            ),
          ]),
          value('size', 'size ×', sp.size ?? 1, 1, const ParamScale.slider(0.1, 5, decimals: 2), (s, v) => s.size = v),
          value('rise', 'rise', sp.rise ?? 0, 0, const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25),
              (s, v) => s.rise = v),
          ColorRow(label: 'Colour', hex: sp.color ?? t.color, onPick: (c) => edit((s) => s.color = c)),
          motion('move', 'move', (s) => s.move, (s, t) => s.move = t, [0.0, 0.0],
              const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25)),
          motion('turn', 'turn', (s) => s.turn, (s, t) => s.turn = t, 0.0, ParamScale.degrees),
          motion('scale', 'scale', (s) => s.scale, (s, t) => s.scale = t, [1.0, 1.0],
              const ParamScale.ruler(unitsPerPixel: 0.005, minorTick: 0.1, majorTick: 0.5)),
          motion('opacity', 'opacity', (s) => s.opacity, (s, t) => s.opacity = t, 1.0, const ParamScale.slider(0, 1)),
          // its own effects (keyable too).
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Effects', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          motion('blur', 'blur', (s) => s.blur, (s, t) => s.blur = t, 0.0, const ParamScale.slider(0, 20)),
          motion('spacing', 'letter spacing', (s) => s.spacing, (s, t) => s.spacing = t, 0.0,
              const ParamScale.ruler(unitsPerPixel: 0.1, minorTick: 1, majorTick: 10)),
          motion('shake', 'shake', (s) => s.shake, (s, t) => s.shake = t, 0.0, const ParamScale.slider(0, 30)),
          motion('wobble', 'wobble °', (s) => s.wobble, (s, t) => s.wobble = t, 0.0, const ParamScale.slider(0, 45)),
          motion('tint', 'tint', (s) => s.tint, (s, t) => s.tint = t, 0.0, const ParamScale.slider(0, 1)),
          ColorRow(label: 'Tint colour', hex: sp.tintColor ?? '#ffffff', onPick: (c) => edit((s) => s.tintColor = c)),
          // when it acts.
          Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Acts', style: TextStyle(fontSize: 12)),
            ActionChip(
              key: ValueKey('text-part-$i-from'),
              label: Text(sp.from == null ? 'from the start' : 'from ${sp.from}'),
              onPressed: () => edit((s) => s.from = s.from == null ? f : null),
            ),
            ActionChip(
              key: ValueKey('text-part-$i-to'),
              label: Text(sp.to == null ? 'to the end' : 'to ${sp.to}'),
              onPressed: () => edit((s) => s.to = s.to == null ? f : null),
            ),
          ]),
          const Hint('Tap "from" / "to" to set them to the current frame (tap again: back to always).'),
        ],
      ),
    );
  }

  Future<void> _loadFont() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final result = await pickOriginalFiles(type: FileType.any);
      final path = result?.files.single.path;
      if (path == null) return;
      final lower = path.toLowerCase();
      if (!lower.endsWith('.ttf') && !lower.endsWith('.otf')) {
        messenger?.showSnackBar(const SnackBar(content: Text('Choose a .ttf or .otf font file')));
        return;
      }
      await app.importFontFor(id, await File(path).readAsBytes(), path);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Could not load the font: $e')));
    }
  }

  /// The loaded fonts, each with a delete button (the built-in default
  /// font can't be deleted).
  Future<void> _manageFonts() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final fonts = registeredFonts().entries.where((e) => e.key != defaultFontId).toList();
          return AlertDialog(
            title: const Text('Loaded fonts'),
            content: SizedBox(
              width: 320,
              child: fonts.isEmpty
                  ? const Text('Only the built-in font is left.')
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final f in fonts)
                          ListTile(
                            dense: true,
                            title: Text(f.value, overflow: TextOverflow.ellipsis),
                            subtitle: app.textLayersUsingFont(f.key) > 0
                                ? Text('used by ${app.textLayersUsingFont(f.key)} text layer(s) here')
                                : null,
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'delete ${f.value}',
                              onPressed: () async {
                                final used = app.textLayersUsingFont(f.key);
                                final ok = await showDialog<bool>(
                                  context: dialogContext,
                                  builder: (c) => AlertDialog(
                                    title: Text('Delete ${f.value}?'),
                                    content: Text(used > 0
                                        ? 'It is removed from the app. $used text layer(s) here switch to the built-in font.'
                                        : 'It is removed from the app; text in other projects that used it shows the built-in font.'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                                      TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                                    ],
                                  ),
                                );
                                if (ok != true) return;
                                await app.deleteFont(f.key);
                                setDialogState(() {});
                              },
                            ),
                          ),
                      ],
                    ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close'))],
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final fonts = registeredFonts();
    final fontValue = fonts.containsKey(t.fontId) ? t.fontId : (fonts.isEmpty ? null : fonts.keys.first);
    // the text field stays on top; the rest scrolls under it.
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
        child: TextField(
          key: const ValueKey('text-field'),
          controller: _text,
          focusNode: _focus,
          minLines: 1,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: 'Text',
            border: const OutlineInputBorder(),
            isDense: true,
            // clear it all at once.
            // copy it, clear it all at once.
            suffixIcon: _text.text.isEmpty
                ? null
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      key: const ValueKey('text-copy'),
                      icon: const Icon(Icons.copy, size: 18),
                      tooltip: 'copy the text',
                      onPressed: () => Clipboard.setData(ClipboardData(text: _text.text)),
                    ),
                    IconButton(
                      key: const ValueKey('text-clear'),
                      icon: const Icon(Icons.clear, size: 18),
                      tooltip: 'clear the text',
                      onPressed: () {
                        _text.clear();
                        _typed('');
                        setState(() {});
                      },
                    ),
                  ]),
          ),
          onChanged: (v) {
            _typed(v);
            if (v.isEmpty || _text.text.length <= 1) setState(() {});
          },
        ),
      ),
      Expanded(
          child: ListView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: [
          // the whole look of this text onto others (and their sublayers).
          Wrap(children: [
            TextButton.icon(
              key: const ValueKey('text-style-copy'),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy style'),
              onPressed: () {
                copiedTextStyle = t.copy();
                setState(() {});
              },
            ),
            TextButton.icon(
              key: const ValueKey('text-style-paste'),
              icon: const Icon(Icons.content_paste, size: 16),
              label: const Text('Paste style'),
              onPressed: copiedTextStyle == null ? null : () => app.editTextAll(id, (t) => applyTextStyle(copiedTextStyle!, t)),
            ),
          ]),
          if (app.textStyleTargets(id).length > 1)
            Padding(
              key: const ValueKey('text-multi-note'),
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('Style changes go to all ${app.textStyleTargets(id).length} selected texts',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary)),
            ),
          Row(
            children: [
              const SizedBox(width: 72, child: Text('Font', style: TextStyle(fontSize: 12))),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: fontValue,
                  items: [
                    for (final e in fonts.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) {
                    if (v != null) app.editTextAll(id, (t) => t.fontId = v);
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.upload_file, size: 18),
                tooltip: 'load a font (.ttf / .otf)',
                onPressed: _loadFont,
              ),
              IconButton(
                icon: const Icon(Icons.folder_delete_outlined, size: 18),
                tooltip: 'loaded fonts',
                onPressed: fonts.length > 1 ? _manageFonts : null,
              ),
            ],
          ),
          // parts of the text: letters / words / any stretch as their own
          // sublayers (look and motion of their own), on top.
          ..._section('Parts', _spansSection(t), open: t.spans.isNotEmpty),
          ..._section(
              'Type',
              [
                _number(
                    'size',
                    t.fontSize,
                    TextSpec().fontSize,
                    const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 4, majorTick: 20, min: 1, decimals: 1),
                    (t, v) => t.fontSize = v),
                _number(
                    'letters',
                    t.letterSpacing,
                    0,
                    const ParamScale.ruler(unitsPerPixel: 0.1, minorTick: 1, majorTick: 5, decimals: 1),
                    (t, v) => t.letterSpacing = v),
                _number('lines', t.lineSpacing, TextSpec().lineSpacing, const ParamScale.slider(0.5, 3),
                    (t, v) => t.lineSpacing = v),
                ColorRow(label: 'Colour', hex: t.color, onPick: (c) => app.editTextAll(id, (t) => t.color = c)),
                SwitchListTile(
                  key: const ValueKey('text-knockout'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('See-through (cuts out what is under it)', style: TextStyle(fontSize: 13)),
                  value: t.knockout,
                  onChanged: (v) => app.editTextAll(id, (t) => t.knockout = v),
                ),
              ],
              open: true),
          ..._section('Box', [
            // where the text sits in its box, and the box itself.
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final a in const ['left', 'center', 'right'])
                  ChoiceChip(
                    label: Icon(
                        a == 'left'
                            ? Icons.format_align_left
                            : a == 'right'
                                ? Icons.format_align_right
                                : Icons.format_align_center,
                        size: 16),
                    tooltip: 'align $a',
                    selected: t.align == a,
                    onSelected: (_) => app.editTextAll(id, (t) => t.align = a),
                  ),
                TextButton(onPressed: () => app.fitTextBoxOf(id), child: const Text('Fit box to text')),
                FilterChip(
                  key: const ValueKey('text-auto-box'),
                  label: const Text('Auto box'),
                  tooltip: 'the box grows to fit the text as you type',
                  selected: t.autoBox,
                  onSelected: (v) => app.editTextAll(id, (t) => t.autoBox = v),
                ),
              ],
            ),
          ]),
          ..._section('Outline', [
            _number(
                'width', t.strokeWidth, 0, const ParamScale.slider(0, 20, decimals: 1), (t, v) => t.strokeWidth = v),
            ColorRow(label: 'Colour', hex: t.strokeColor, onPick: (c) => app.editTextAll(id, (t) => t.strokeColor = c)),
          ]),
          ..._section('Shadow', [
            _switchRow('Shadow', t.shadow.enabled, (v) => app.editTextAll(id, (t) => t.shadow.enabled = v)),
            if (t.shadow.enabled) ...[
              // x and y together (the XY pad too).
              ParamEditor(
                prefKey: 'text.shadow offset',
                label: 'offset',
                values: [t.shadow.dx, t.shadow.dy],
                componentLabels: const ['x', 'y'],
                scale: const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25),
                padCenter: const [0, 0],
                padSpan: 400,
                onEditStart: app.pushUndo,
                onChanged: (v) => app.editTextLiveAll(
                    id,
                    (t) => t
                      ..shadow.dx = v[0]
                      ..shadow.dy = v[1]),
                onCommit: (v) => app.editTextAll(
                    id,
                    (t) => t
                      ..shadow.dx = v[0]
                      ..shadow.dy = v[1]),
                trailing: [
                  ResetIconButton(
                      onPressed: () => app.editTextAll(
                          id,
                          (t) => t
                            ..shadow.dx = TextShadowSpec().dx
                            ..shadow.dy = TextShadowSpec().dy)),
                ],
              ),
              _number('shadow scale', t.shadow.scale, 1, const ParamScale.slider(0.1, 3), (t, v) => t.shadow.scale = v),
              _number('opacity', t.shadow.opacity, TextShadowSpec().opacity, const ParamScale.slider(0, 1),
                  (t, v) => t.shadow.opacity = v),
              ColorRow(
                  label: 'Colour', hex: t.shadow.color, onPick: (c) => app.editTextAll(id, (t) => t.shadow.color = c)),
              SwitchListTile(
                key: const ValueKey('text-long-shadow'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Long shadow (3D depth)', style: TextStyle(fontSize: 13)),
                subtitle: hint('Joins the shadow to the letters along its whole offset.'),
                value: t.shadow.long,
                onChanged: (v) => app.editTextAll(id, (t) => t.shadow.long = v),
              ),
              if (!t.shadow.long) ...[
                SwitchListTile(
                  key: const ValueKey('text-shadow-echo'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Echo', style: TextStyle(fontSize: 13)),
                  subtitle: hint('Copies of the text along the offset, each farther one fainter.'),
                  value: t.shadow.echo,
                  onChanged: (v) => app.editTextAll(id, (t) => t.shadow.echo = v),
                ),
                if (t.shadow.echo) ...[
                  _number('echo copies', t.shadow.echoCount.toDouble(), 5,
                      const ParamScale.slider(1, 30, integer: true), (t, v) => t.shadow.echoCount = v.round()),
                  keyedParamRow(
                      app: app,
                      prefKey: 'text.echo fade',
                      label: 'echo fade',
                      trk: t.shadow.echoFade,
                      localFrame: layerLocalFrame(widget.layer, app.currentFrame),
                      defaultValue: 0.8,
                      scale: const ParamScale.slider(0, 1),
                      layer: widget.layer),
                ],
              ],
              SwitchListTile(
                key: const ValueKey('text-shadow-lag'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Lag', style: TextStyle(fontSize: 13)),
                subtitle: hint('The shadow trails the text when it moves and settles back when it stops. '
                    'A long shadow stretches: only its far end lags.'),
                value: t.shadow.lag,
                onChanged: (v) => app.editTextAll(id, (t) => t.shadow.lag = v),
              ),
              if (t.shadow.lag) ...[
                _number('lag speed', t.shadow.lagSpeed, 60, const ParamScale.slider(1, 500, decimals: 0),
                    (t, v) => t.shadow.lagSpeed = v.clamp(1, 500).toDouble()),
                _number('lag bounciness %', t.shadow.lagBounciness, 30, const ParamScale.slider(0, 100, decimals: 0),
                    (t, v) => t.shadow.lagBounciness = v.clamp(0, 100).toDouble()),
                if (t.animators.isNotEmpty)
                  SwitchListTile(
                    key: const ValueKey('text-shadow-per-letter'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Per letter', style: TextStyle(fontSize: 13)),
                    subtitle: hint('Each animated unit\'s shadow trails that unit on its own.'),
                    value: t.shadow.perLetter,
                    onChanged: (v) => app.editTextAll(id, (t) => t.shadow.perLetter = v),
                  ),
              ],
            ],
          ]),
          ..._section('Text keys', _keysSection(t)),
          ..._section('Animators', _animatorsSection(t)),
          ..._section('Groups', _groupsSection(t)),
          ..._section('Background block', [
            _switchRow(
                'Background block', t.background.enabled, (v) => app.editTextAll(id, (t) => t.background.enabled = v)),
            if (t.background.enabled) ...[
              _number(
                  'size',
                  t.background.padding,
                  TextBackgroundSpec().padding,
                  const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25, min: 0),
                  (t, v) => t.background.padding = v),
              _number('opacity', t.background.opacity, TextBackgroundSpec().opacity, const ParamScale.slider(0, 1),
                  (t, v) => t.background.opacity = v),
              _number('rounded corners', t.background.radius, 0,
                  const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25, min: 0), (t, v) => t.background.radius = v),
              if (t.background.radius > 0)
                _number('rounding shape (0 cut, 0.55 circle, 1 sharp)', t.background.radiusShape, circleRoundK,
                    const ParamScale.slider(0, 1, decimals: 3), (t, v) => t.background.radiusShape = v),
              ColorRow(
                  label: 'Colour',
                  hex: t.background.color,
                  onPick: (c) => app.editTextAll(id, (t) => t.background.color = c)),
            ],
          ]),
          ..._section('Use as a mask', _maskSection()),
          const SizedBox(height: 12),
          const Hint('The side handles on the stage resize the text box - the text wraps to it. '
              'Changing a corner pin or mesh warp turns the text into a plain vector shape.'),
        ],
      )),
    ]);
  }

  // ===== text animators =====

  void _editAnim(void Function() change) {
    app.pushUndo();
    change();
    app.commitEdit();
  }

  List<Widget> _animatorsSection(TextSpec t) {
    final sel = app.selectedTextAnimator;
    return [
      Row(children: [
        const Spacer(),
        PopupMenuButton<String>(
          key: const ValueKey('text-anim-add'),
          tooltip: 'add an animator',
          // the text field's keyboard stays down (the menu would hand the
          // focus back to it).
          onOpened: () => FocusManager.instance.primaryFocus?.unfocus(),
          onSelected: (v) {
            app.addTextAnimator(id, v == 'Empty' ? null : v);
            WidgetsBinding.instance.addPostFrameCallback((_) => FocusManager.instance.primaryFocus?.unfocus());
          },
          onCanceled: () =>
              WidgetsBinding.instance.addPostFrameCallback((_) => FocusManager.instance.primaryFocus?.unfocus()),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'Empty', child: Text('Empty')),
            const PopupMenuDivider(),
            for (final p in textAnimatorPresets) PopupMenuItem(value: p, child: Text(p)),
          ],
          child: Listener(
            onPointerDown: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            child: const Padding(
              padding: EdgeInsets.all(6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.add, size: 16), Text(' Add')]),
            ),
          ),
        ),
      ]),
      const Hint('Letters, words or lines picked by a range get offset, turned, scaled, faded, tinted... '
          'Move the range over time for reveals and waves.'),
      SwitchListTile(
        key: const ValueKey('text-anim-overlay'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Show the range on the stage', style: TextStyle(fontSize: 13)),
        value: app.showTextRangeOverlay,
        onChanged: (v) => app.setTextRangeOverlay(v),
      ),
      for (var i = 0; i < t.animators.length; i++) ...[
        Row(children: [
          Switch(
            key: ValueKey('text-anim-on-$i'),
            value: t.animators[i].enabled,
            onChanged: (v) => _editAnim(() => t.animators[i].enabled = v),
          ),
          Expanded(
            child: InkWell(
              key: ValueKey('text-anim-$i'),
              onTap: () => app.selectTextAnimator(sel == i ? null : i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(t.animators[i].name,
                    style: TextStyle(fontWeight: sel == i ? FontWeight.bold : FontWeight.normal)),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 16),
            tooltip: 'earlier',
            visualDensity: VisualDensity.compact,
            onPressed: i == 0 ? null : () => _editAnim(() => t.animators.insert(i - 1, t.animators.removeAt(i))),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'remove the animator',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              _editAnim(() => t.animators.removeAt(i));
              app.selectTextAnimator(null);
            },
          ),
        ]),
        if (sel == i) ..._animatorPanel(t.animators[i]),
      ],
    ];
  }

  List<Widget> _animatorPanel(TextAnimator a) {
    final local = layerLocalFrame(widget.layer, app.currentFrame);
    final r = a.range;
    return [
      // Breathe and the like: which way the letters stretch, first.
      if (a.props.containsKey('liveScale'))
        SwitchListTile(
          key: const ValueKey('text-anim-live-vertical'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Vertical', style: TextStyle(fontSize: 13)),
          subtitle: hint('The random scale stretches the letters taller instead of wider.'),
          value: a.liveVertical,
          onChanged: (v) => _editAnim(() => a.liveVertical = v),
        ),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final (v, label) in const [('char', 'Letters'), ('word', 'Words'), ('line', 'Lines')])
          ChoiceChip(
            key: ValueKey('text-anim-unit-$v'),
            label: Text(label),
            selected: a.unit == v,
            onSelected: (_) => _editAnim(() => a.unit = v),
          ),
        if (a.unit == 'char')
          FilterChip(
            label: const Text('Spaces count'),
            selected: a.includeSpaces,
            onSelected: (v) => _editAnim(() => a.includeSpaces = v),
          ),
      ]),
      const SizedBox(height: 6),
      const Text('Range', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
      _animTrack('start', r.start, local, const ParamScale.slider(0, 100, decimals: 1)),
      _animTrack('end', r.end, local, const ParamScale.slider(0, 100, decimals: 1)),
      _animTrack('offset', r.offset, local, const ParamScale.slider(-100, 100, decimals: 1)),
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
        const Text('Shape', style: TextStyle(fontSize: 12)),
        DropdownButton<String>(
          value: r.shape,
          items: [
            for (final s in const ['square', 'rampUp', 'rampDown', 'triangle', 'round', 'smooth'])
              DropdownMenuItem(value: s, child: Text(s)),
          ],
          onChanged: (v) => _editAnim(() => r.shape = v!),
        ),
        const Text('Order', style: TextStyle(fontSize: 12)),
        DropdownButton<String>(
          value: r.order,
          items: [
            for (final s in const ['forward', 'reverse', 'random', 'fromCenter', 'fromEdges'])
              DropdownMenuItem(value: s, child: Text(s)),
          ],
          onChanged: (v) => _editAnim(() => r.order = v!),
        ),
      ]),
      _animValue('ease high', r.easeHigh, const ParamScale.slider(0, 100, integer: true), (v) => r.easeHigh = v),
      _animValue('ease low', r.easeLow, const ParamScale.slider(0, 100, integer: true), (v) => r.easeLow = v),
      if (r.order == 'random')
        _animValue(
            'seed', r.seed.toDouble(), const ParamScale.slider(1, 999, integer: true), (v) => r.seed = v.round()),
      Wrap(spacing: 6, runSpacing: 6, children: [
        FilterChip(
          label: const Text('Wrap around'),
          selected: r.wrap,
          onSelected: (v) => _editAnim(() => r.wrap = v),
        ),
        // a letter appears at once (no fading in).
        FilterChip(
          key: const ValueKey('text-anim-whole'),
          label: const Text('Whole letters'),
          selected: r.whole,
          onSelected: (v) => _editAnim(() => r.whole = v),
        ),
        FilterChip(
          key: const ValueKey('text-anim-loop'),
          label: const Text('Loop offset'),
          selected: r.offset.loop,
          onSelected: (v) => _editAnim(() => r.offset.loop = v),
        ),
      ]),
      const SizedBox(height: 6),
      Row(children: [
        const Expanded(child: Text('Properties', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
        PopupMenuButton<String>(
          key: const ValueKey('text-anim-prop-add'),
          tooltip: 'add a property',
          onSelected: (k) => _editAnim(() {
            if (k == 'fillColor') {
              a.fillColor = '#ff9800';
            } else if (k == 'scramble') {
              a.scramble = true;
            } else {
              a.props[k] = TextAnimator.defaultProp(k);
            }
          }),
          itemBuilder: (_) => [
            for (final k in textAnimatorProps)
              if (!(a.props.containsKey(k) ||
                  (k == 'fillColor' && a.fillColor != null) ||
                  (k == 'scramble' && a.scramble)))
                PopupMenuItem(value: k, child: Text(k)),
          ],
          child: const Padding(padding: EdgeInsets.all(6), child: Text('+ Property')),
        ),
      ]),
      for (final k in a.props.keys.toList())
        _animTrack(
            k,
            a.props[k]!,
            local,
            switch (k) {
              'opacity' => const ParamScale.slider(0, 1),
              'blur' => const ParamScale.slider(0, 50, decimals: 1),
              'liveScale' => const ParamScale.slider(0, 2),
              'jitter' => const ParamScale.slider(0, 40, decimals: 1),
              'roll' => const ParamScale.slider(0, 180, decimals: 1),
              'rotation' => ParamScale.degrees,
              'scale' => const ParamScale.ruler(unitsPerPixel: 0.01, minorTick: 0.1, majorTick: 0.5),
              _ => const ParamScale.ruler(unitsPerPixel: 0.25, minorTick: 5, majorTick: 25),
            },
            remove: () => _editAnim(() => a.props.remove(k))),
      if (a.fillColor != null)
        Row(children: [
          Expanded(
              child: ColorRow(label: 'Colour', hex: a.fillColor!, onPick: (c) => _editAnim(() => a.fillColor = c))),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: () => _editAnim(() => a.fillColor = null),
          ),
        ]),
      if (a.props.containsKey('liveScale') || a.props.containsKey('jitter') || a.props.containsKey('roll')) ...[
        _animValue('speed', a.liveSpeed, const ParamScale.slider(0.1, 20, decimals: 1), (v) => a.liveSpeed = v),
        // hold the live motion still, at a pose picked anywhere.
        SwitchListTile(
          key: const ValueKey('text-anim-static'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Static (hold one pose)'),
          value: a.liveStatic,
          onChanged: (v) => _editAnim(() => a.liveStatic = v),
        ),
        if (a.liveStatic)
          _animValue('pose (seconds in)', a.liveStaticAt, const ParamScale.slider(0, 30, decimals: 2), (v) => a.liveStaticAt = v),
      ],
      if (a.scramble)
        Row(children: [
          Expanded(
            child: _animValue('scramble every', a.scrambleEvery.toDouble(),
                const ParamScale.slider(1, 30, integer: true), (v) => a.scrambleEvery = v.round()),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: () => _editAnim(() => a.scramble = false),
          ),
        ]),
    ];
  }

  Widget _animValue(String label, double value, ParamScale scale, void Function(double) set) => ParamEditor(
        prefKey: 'text.anim.$label',
        label: label,
        values: [value],
        scale: scale,
        onEditStart: app.pushUndo,
        onChanged: (v) {
          set(v.first.clamp(scale.min, scale.max).toDouble());
          app.commitEdit();
        },
        onCommit: (v) => _editAnim(() => set(v.first.clamp(scale.min, scale.max).toDouble())),
      );

  /// An animator's keyable value: editor, key toggle, (remove).
  Widget _animTrack(String label, Track trk, double local, ParamScale scale, {VoidCallback? remove}) {
    final raw = evaluateTrack(app.project, trk, local);
    final values = raw is List ? [for (final v in raw) (v as num).toDouble()] : [(raw as num).toDouble()];
    final frame = local.round();
    final keyed = trk.keyframes.any((k) => k.frame == frame);
    dynamic out(List<double> v) => values.length == 1 ? v.first : [...v];
    return ParamEditor(
      prefKey: 'text.anim.$label',
      label: label,
      values: values,
      scale: scale,
      componentLabels: values.length == 2 ? const ['x', 'y'] : null,
      onEditStart: app.pushUndo,
      onChanged: (v) {
        setTrackValueAt(trk, frame, out(v));
        app.commitEdit();
      },
      onCommit: (v) => _editAnim(() => setTrackValueAt(trk, frame, out(v))),
      trailing: [
        IconButton(
          key: ValueKey('text-anim-key-$label'),
          icon: Icon(keyed ? Icons.diamond : Icons.diamond_outlined, size: 16),
          tooltip: 'toggle keyframe at current frame',
          visualDensity: VisualDensity.compact,
          onPressed: () => _editAnim(() {
            if (keyed) {
              trk.keyframes.removeWhere((k) => k.frame == frame);
            } else {
              trk.keyframes
                ..add(Keyframe(frame: frame, value: raw, temporal: newKeyEasing()))
                ..sort((a, b) => a.frame.compareTo(b.frame));
            }
          }),
        ),
        if (remove != null)
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: 'remove the property',
            visualDensity: VisualDensity.compact,
            onPressed: remove,
          ),
      ],
    );
  }

  /// Which sections are open (kept while the app runs).
  static final Map<String, bool> _open = {};

  /// A folding section: its title, then (open) its rows.
  List<Widget> _section(String title, List<Widget> rows, {bool open = false}) {
    final isOpen = _open[title] ?? open;
    return [
      const Divider(height: 12),
      InkWell(
        key: ValueKey('text-section-$title'),
        onTap: () => setState(() => _open[title] = !isOpen),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
            Icon(isOpen ? Icons.expand_less : Icons.expand_more, size: 18),
          ]),
        ),
      ),
      if (isOpen) ...rows,
    ];
  }

  /// The text as a mask: its letters become the outline of the layers
  /// ticked here (a mask on each of them, see the Masks tab for mode and
  /// feather); the text itself is usually hidden then.
  List<Widget> _maskSection() {
    final self = findLayer(app.project, id);
    final targets = [
      for (final l in app.project.layers)
        if (l.id != id && !isAudioShape(l.content.shape)) l
    ];
    return [
      const Hint('Its letters become the outline of the layers ticked below.'),
      if (targets.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text('No other layers yet.', style: TextStyle(fontSize: 12)),
        ),
      for (final l in targets)
        CheckboxListTile(
          key: ValueKey('text-mask-${l.id}'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(l.name, overflow: TextOverflow.ellipsis),
          value: l.masks.any((m) => m.sourceLayerId == id),
          onChanged: (v) => app.setTextMask(id, l.id, v ?? false),
        ),
      if (self != null)
        SwitchListTile(
          key: const ValueKey('text-mask-show-self'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Show the text itself', style: TextStyle(fontSize: 13)),
          value: !self.hidden,
          onChanged: (_) => app.toggleHidden(id),
        ),
    ];
  }

  /// Text groups: letters between two markers ("#T#ext") are drawn by a
  /// layer of their own, parented to the text.
  List<Widget> _groupsSection(TextSpec t) {
    final layer = findLayer(app.project, id);
    final groups = t.groupsAt(layerLocalFrame(layer!, app.currentFrame));
    final taken = textGroupLayers(app.project, layer);
    final missing = [
      for (var g = 0; g < groups.length; g++)
        if (!taken.containsKey(g)) g
    ].length;
    return [
      SwitchListTile(
        key: const ValueKey('text-groups'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Letter groups', style: TextStyle(fontSize: 13)),
        subtitle: hint('Put letters between two markers - #T#ext - and they get a layer of their own: '
            'move, key and add effects to it while it stays part of the text.'),
        value: t.groupsEnabled,
        onChanged: (v) => app.editText(id, (t) => t.groupsEnabled = v),
      ),
      if (t.groupsEnabled) ...[
        Row(children: [
          const SizedBox(width: 80, child: Text('Marker')),
          SizedBox(
            width: 56,
            child: TextFormField(
              key: ValueKey('text-group-char-${t.groupChar}'),
              initialValue: t.groupChar,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(isDense: true, counterText: ''),
              maxLength: 2,
              onChanged: (v) {
                final r = v.runes;
                if (r.isEmpty) return;
                app.editText(id, (t) => t.groupChar = String.fromCharCode(r.last));
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text('${groups.length} group${groups.length == 1 ? '' : 's'}, ${taken.length} with a layer')),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('text-groups-make'),
            icon: const Icon(Icons.call_split, size: 18),
            label: Text(missing == 0
                ? 'Every group has its layer'
                : 'Make layers for $missing group${missing == 1 ? '' : 's'}'),
            onPressed: missing == 0 ? null : () => app.addTextGroupLayersOf(id),
          ),
        ),
        const Hint('A group\'s letters keep the text\'s font, colour and animators and move with it; '
            'delete its layer and they are drawn by the text again.'),
      ],
    ];
  }

  Widget _switchRow(String label, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        value: value,
        onChanged: onChanged,
      );

  Widget _number(
      String label, double value, double defaultValue, ParamScale scale, void Function(TextSpec t, double v) set,
      {String? key}) {
    double clamp(double v) => v.clamp(scale.min, scale.max).toDouble();
    return ParamEditor(
      prefKey: 'text.${key ?? label}',
      label: label,
      values: [value],
      scale: scale,
      onEditStart: app.pushUndo,
      onChanged: (v) => app.editTextLiveAll(id, (t) => set(t, clamp(v.first))),
      onCommit: (v) => app.editTextAll(id, (t) => set(t, clamp(v.first))),
      trailing: [ResetIconButton(onPressed: () => app.editTextAll(id, (t) => set(t, defaultValue)))],
    );
  }
}
