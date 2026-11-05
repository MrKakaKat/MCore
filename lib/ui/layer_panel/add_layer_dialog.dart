import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import 'project_ref_ui.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../../io/image_import.dart';
import '../../services/audio_service.dart' show AudioImportCancelled;
import '../../services/video_service.dart' show CancelToken, VideoImportCancelled;
import '../../io/file_pick.dart';

/// Layers-tab reconstruction,
/// - a single "Add layer" button opening a picker with vector shapes and
/// media (image import); text/audio are explicitly future, not this
/// round. Replaces the 4 separate toolbar icons layer_panel_view.dart
/// used to have. The image-import trigger (file pick + storage-mode
/// choice) moves here from that file's own former private _importImage
/// - the underlying pick/decode logic in lib/io/image_import.dart is
///   unchanged, only this UI entry point moved. - confirmed root cause is a
///   DIFFERENT bug from the one already fixed: this dialog's own `builder:
///   (context) =>.` SHADOWS the function's outer `context` parameter. "Import
///   image." used to do `Navigator.pop(context)` then `await
///   _importImage(context, app)` with that SHADOWED, dialog-local context -
///   already unmounted the instant the dialog closes. _importImage's
///   `context.mounted` guards (from the previous fix) were working correctly,
///   just against the wrong context, so the storage-mode dialog silently never
///   appeared and addImageLayer was never called - indistinguishable from the
///   original silent-failure bug. Renaming the builder's own param to
///   `dialogContext` and using the CALLER's outer `context` (which stays
///   mounted for as long as whatever screen opened this dialog does, not tied
///   to the dialog's own lifecycle) for the async import calls fixes this -
///   `_importSvg` had the identical bug (silently losing its own success/error
///   SnackBars only, since importSvgLayers itself runs before any mounted
///   check), fixed the same way here for free. With `replaceId`, the same
///   choices REPLACE that layer's shape/media instead of adding a layer
///   (Layers tab: "Replace content."), keeping every parameter - see
///   AppState.replaceLayerContentWith.
Future<void> showAddLayerDialog(BuildContext context, AppState app, {String? replaceId}) {
  void shape(String presetShape) {
    if (replaceId == null && app.placeOnStage) {
      app.startPlacing(presetShape);
    } else if (replaceId == null) {
      app.addLayer(presetShape);
    } else {
      app.replaceLayerContentWith(replaceId, createLayer(presetShape).content);
    }
  }

  return showDialog<void>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(replaceId == null ? 'Add layer' : 'Replace content'),
      children: [
        // all the shape types in one folder.
        SimpleDialogOption(
          key: const ValueKey('add-shapes'),
          onPressed: () async {
            Navigator.pop(dialogContext);
            final picked = await showDialog<String>(
              context: context,
              builder: (shapesContext) => SimpleDialog(
                title: const Text('Shapes'),
                children: [
                  for (final (name, icon, label) in const [
                    ('rect', Icons.crop_square, 'Rectangle'),
                    ('circle', Icons.circle_outlined, 'Circle'),
                    ('triangle', Icons.change_history, 'Triangle'),
                    ('line', Icons.horizontal_rule, 'Line'),
                  ])
                    SimpleDialogOption(
                      key: ValueKey('add-shape-$name'),
                      onPressed: () => Navigator.pop(shapesContext, name),
                      child: Row(children: [Icon(icon), const SizedBox(width: 8), Text(label)]),
                    ),
                  // draw it on the stage (a box anywhere, any size), or
                  // straight in the middle.
                  if (replaceId == null)
                    StatefulBuilder(
                      builder: (context, set) => SwitchListTile(
                        key: const ValueKey('add-shape-place'),
                        dense: true,
                        title: const Text('Draw it on the stage'),
                        subtitle: const Text('off: it appears in the middle'),
                        value: app.placeOnStage,
                        onChanged: (v) {
                          app.setAppPreference('placeOnStage', v);
                          set(() {});
                        },
                      ),
                    ),
                ],
              ),
            );
            if (picked != null) shape(picked);
          },
          child: const Row(children: [
            Icon(Icons.category),
            SizedBox(width: 8),
            Expanded(child: Text('Shapes')),
            Icon(Icons.chevron_right),
          ]),
        ),
        // a null: an invisible point other layers can hang on.
        if (replaceId == null)
          SimpleDialogOption(
            key: const ValueKey('add-null'),
            onPressed: () {
              app.addLayer('null');
              Navigator.pop(dialogContext);
            },
            child: const Row(children: [
              Icon(Icons.radio_button_unchecked),
              SizedBox(width: 8),
              Text('Null point'),
            ]),
          ),
        if (replaceId == null)
          SimpleDialogOption(
            onPressed: () {
              app.addTextLayer();
              Navigator.pop(dialogContext);
            },
            child: const Row(children: [
              Icon(Icons.text_fields),
              SizedBox(width: 8),
              Text('Text'),
            ]),
          ),
        // another saved project, rendered live.
        if (replaceId == null && app.projectStore != null)
          SimpleDialogOption(
            key: const ValueKey('add-project-ref'),
            onPressed: () async {
              Navigator.pop(dialogContext);
              await addProjectRefFlow(context, app);
            },
            child: const Row(children: [
              Icon(Icons.folder_outlined),
              SizedBox(width: 8),
              Text('Project...'),
            ]),
          ),
        const Divider(),
        SimpleDialogOption(
          onPressed: () async {
            Navigator.pop(dialogContext);
            await _importImage(context, app, replaceId); // the CALLER's context, not the dialog's own - stays mounted
          },
          child: const Row(children: [
            Icon(Icons.add_photo_alternate),
            SizedBox(width: 8),
            Text('Import image...'),
          ]),
        ),
        SimpleDialogOption(
          onPressed: () async {
            Navigator.pop(dialogContext);
            await importVideoFlow(context, app, replaceId: replaceId);
          },
          child: const Row(children: [
            Icon(Icons.video_library),
            SizedBox(width: 8),
            Text('Import video...'),
          ]),
        ),
        SimpleDialogOption(
          key: const ValueKey('import-gif'),
          onPressed: () async {
            Navigator.pop(dialogContext);
            await importGifFlow(context, app, replaceId: replaceId);
          },
          child: const Row(children: [
            Icon(Icons.gif_box),
            SizedBox(width: 8),
            Text('Import GIF...'),
          ]),
        ),
        // a sound has no picture to put in another layer's place.
        if (replaceId == null)
          SimpleDialogOption(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await importAudioFlow(context, app);
            },
            child: const Row(children: [
              Icon(Icons.audiotrack),
              SizedBox(width: 8),
              Text('Import audio...'),
            ]),
          ),
        SimpleDialogOption(
          onPressed: () async {
            Navigator.pop(dialogContext);
            await _importSvg(context, app, replaceId); // same fix
          },
          child: const Row(children: [
            Icon(Icons.polyline),
            SizedBox(width: 8),
            Text('Import SVG...'),
          ]),
        ),
      ],
    ),
  );
}

/// picks a.svg file, parses it via movement_core's own importShapesFromSvg,
/// and adds every successfully-parsed shape as a new layer. Per-element parse
/// failures (an unsupported element, a curved path) don't block the rest of
/// the file - they're surfaced together in one summary SnackBar rather than
/// one popup per failed element.
Future<void> _importSvg(BuildContext context, AppState app, [String? replaceId]) async {
  final result = await pickOriginalFiles(type: FileType.custom, allowedExtensions: ['svg']);
  if (result == null || result.files.isEmpty) return; // user cancelled
  final path = result.files.single.path;
  if (path == null) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not import SVG: no accessible file path on this platform.')));
    return;
  }

  String source;
  try {
    source = await File(path).readAsString();
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not read SVG file: $e')));
    return;
  }

  final svgResult = importShapesFromSvg(source);
  if (replaceId != null) {
    // replacing takes the file's first shape.
    if (svgResult.layers.isNotEmpty) {
      app.replaceLayerContentWith(replaceId, svgResult.layers.first.content);
    }
  } else {
    app.importSvgLayers(svgResult.layers);
  }

  if (!context.mounted) return;
  if (svgResult.errors.isNotEmpty || svgResult.report.isNotEmpty) {
    // the import report: what failed, and what came in simplified.
    final imported = svgResult.layers.length;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Imported $imported shape${imported == 1 ? '' : 's'}'),
        content: SingleChildScrollView(
          child: Text([
            if (svgResult.errors.isNotEmpty) 'Not imported:\n${svgResult.errors.join('\n')}',
            if (svgResult.report.isNotEmpty) 'Simplified:\n${svgResult.report.join('\n')}',
          ].join('\n\n')),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
      ),
    );
  } else if (svgResult.layers.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No importable shapes found in this SVG.')));
  }
}

/// picks an image, then - asks which storage mode to use, unless the platform
/// never gave us a real file path to reference in the first place (then
/// "embedded" is the only option, so the dialog is skipped rather than
/// offering a choice with one dead option).
Future<void> _importImage(BuildContext context, AppState app, [String? replaceId]) async {
  PickedImage? picked;
  try {
    picked = await pickImageForImport();
  } catch (e) {
    // a failed pick/ read/decode used to fail completely silently
    // (pickImageForImport just returned null, indistinguishable from a plain
    // cancel). Now real failures throw, and the user actually sees why.
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not import image: $e')));
    return;
  }
  if (picked == null) return; // user cancelled the file picker

  var sourceType = 'embedded';
  if (picked.path != null) {
    if (!context.mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import image'),
        content: const Text(
          'Embed the image data directly in the project (portable, larger file), '
          'or reference the file on disk (smaller file, breaks if the file moves)?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'file'), child: const Text('Reference file')),
          TextButton(onPressed: () => Navigator.pop(context, 'embedded'), child: const Text('Embed')),
        ],
      ),
    );
    if (choice == null) return; // dismissed without choosing - cancel the import
    sourceType = choice;
  }

  if (replaceId != null) {
    app.replaceLayerContentWith(
        replaceId,
        createImageLayer(
          imageSourceType: sourceType,
          imageData: sourceType == 'embedded' ? encodeImageDataForEmbedding(picked.bytes) : null,
          imagePath: sourceType == 'file' ? picked.path : null,
          naturalWidth: picked.width,
          naturalHeight: picked.height,
        ).content);
    return;
  }
  app.addImageLayer(
    imageSourceType: sourceType,
    imageData: sourceType == 'embedded' ? encodeImageDataForEmbedding(picked.bytes) : null,
    imagePath: sourceType == 'file' ? picked.path : null,
    naturalWidth: picked.width,
    naturalHeight: picked.height,
  );
}

/// Video import: pick a file, choose whether to keep transparency (like
/// the embed / reference choice for images), then extract its frames with
/// a progress dialog that can be cancelled. Sound is not imported.
Future<void> importVideoFlow(BuildContext context, AppState app, {String? replaceId, String? pickedPath}) async {
  var path = pickedPath;
  if (path == null) {
    try {
      final result = await pickOriginalFiles(type: FileType.video);
      if (result == null || result.files.isEmpty) return;
      path = result.files.single.path;
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open the video: $e')));
      return;
    }
    if (path == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not import video: no accessible file path.')));
      return;
    }
  }
  if (!context.mounted) return;
  // its sound comes in as a separate audio layer, linked to the video on
  // the timeline (on by default; not when replacing another layer's
  // content).
  var withSound = replaceId == null;
  final alpha = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('Import video'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (replaceId == null)
              CheckboxListTile(
                key: const ValueKey('video-import-sound'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: withSound,
                onChanged: (v) => setDialogState(() => withSound = v ?? true),
                title: const Text('Import its sound'),
                subtitle: hint('as a separate audio layer, linked to the video on the timeline'),
              ),
            const Text(
              'Keep transparency only for clips that have it (WebM / VP9 with alpha). '
              'It is slower to import and takes more space; a normal video is imported as opaque frames.',
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Keep transparency')),
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Import')),
        ],
      ),
    ),
  );
  if (alpha == null || !context.mounted) return;
  final error = await showDialog<Object?>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        VideoImportProgressDialog(app: app, file: File(path!), alpha: alpha, withSound: withSound, replaceId: replaceId),
  );
  if (error == null || error is VideoImportCancelled || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not import video: $error')));
}

/// An animated GIF becomes an animated layer (through the video path:
/// its frames, at its own rate, with its transparency; no sound).
Future<void> importGifFlow(BuildContext context, AppState app, {String? replaceId}) async {
  String? path;
  try {
    final result = await pickOriginalFiles(type: FileType.custom, allowedExtensions: ['gif']);
    if (result == null || result.files.isEmpty) return;
    path = result.files.single.path;
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open the GIF: $e')));
    return;
  }
  if (path == null || !context.mounted) return;
  final error = await showDialog<Object?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => VideoImportProgressDialog(app: app, file: File(path!), alpha: true, replaceId: replaceId),
  );
  if (error == null || error is VideoImportCancelled || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not import the GIF: $error')));
}

/// Runs AppState.importVideo while showing its progress; Cancel stops the
/// extraction. Pops with null on success or the error.
class VideoImportProgressDialog extends StatefulWidget {
  final AppState app;
  final File file;
  final bool alpha;
  final bool withSound;
  final String? replaceId;
  const VideoImportProgressDialog(
      {super.key, required this.app, required this.file, required this.alpha, this.withSound = false, this.replaceId});

  @override
  State<VideoImportProgressDialog> createState() => _VideoImportProgressDialogState();
}

class _VideoImportProgressDialogState extends State<VideoImportProgressDialog> {
  final CancelToken _cancel = CancelToken();
  int _done = 0, _total = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    Object? error;
    try {
      await widget.app.importVideo(widget.file,
          alpha: widget.alpha,
          withSound: widget.withSound,
          replaceId: widget.replaceId,
          cancel: _cancel,
          onProgress: (done, total) {
            if (mounted) {
              setState(() {
                _done = done;
                _total = total;
              });
            }
          });
    } catch (e) {
      error = e;
    }
    if (mounted) Navigator.of(context).pop(error);
  }

  @override
  Widget build(BuildContext context) {
    final value = _total > 0 ? (_done / _total).clamp(0.0, 1.0) : null;
    return AlertDialog(
      title: const Text('Importing video'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: _cancel.isCancelled ? null : value),
          const SizedBox(height: 8),
          Text(_cancel.isCancelled
              ? 'Cancelling...'
              : _total > 0
                  ? 'Reading frames $_done / $_total'
                  : 'Reading frames $_done'),
          if (widget.withSound) ...[
            const SizedBox(height: 4),
            const Hint('Then its sound, as a linked audio layer.'),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _cancel.isCancelled ? null : () => setState(_cancel.cancel),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Files "Import audio..." offers: sound files, and videos (their sound).
const audioImportExtensions = [
  'mp3', 'm4a', 'm4b', 'aac', 'wav', 'aif', 'aiff', 'ogg', 'oga', 'opus', 'flac', 'amr', 'wma', //
  'mp4', 'mov', 'webm', 'mkv', '3gp',
];

/// Picks a sound (or a video, for its sound) and imports it as an audio
/// layer, showing the decoding progress.
Future<void> importAudioFlow(BuildContext context, AppState app, {String? pickedPath}) async {
  var path = pickedPath;
  if (path == null) {
    try {
      // any file, checked by its extension afterwards: an extension filter
      // maps to MIME types on Android, and m4a (audio/mp4) comes out greyed
      // out on some devices.
      final result = await pickOriginalFiles(type: FileType.any);
      if (result == null || result.files.isEmpty) return;
      path = result.files.single.path;
      final name = (path ?? result.files.single.name).toLowerCase();
      final dot = name.lastIndexOf('.');
      if (dot < 0 || !audioImportExtensions.contains(name.substring(dot + 1))) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Choose a sound file (${audioImportExtensions.take(8).join(', ')}...) or a video.')));
        return;
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open the file: $e')));
      return;
    }
    if (path == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not import audio: no accessible file path.')));
      return;
    }
  }
  if (!context.mounted) return;
  final error = await showDialog<Object?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AudioImportProgressDialog(app: app, file: File(path!)),
  );
  if (error == null || error is AudioImportCancelled || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not import audio: $error')));
}

/// Runs AppState.importAudio while showing its progress; Cancel stops the
/// decoding. Pops with null on success or the error.
class AudioImportProgressDialog extends StatefulWidget {
  final AppState app;
  final File file;
  const AudioImportProgressDialog({super.key, required this.app, required this.file});

  @override
  State<AudioImportProgressDialog> createState() => _AudioImportProgressDialogState();
}

class _AudioImportProgressDialogState extends State<AudioImportProgressDialog> {
  final CancelToken _cancel = CancelToken();
  double? _fraction;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    Object? error;
    try {
      await widget.app.importAudio(widget.file, cancel: _cancel, onProgress: (f) {
        if (mounted) setState(() => _fraction = f);
      });
    } catch (e) {
      error = e;
    }
    if (mounted) Navigator.of(context).pop(error);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Importing audio'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: _cancel.isCancelled ? null : _fraction),
          const SizedBox(height: 8),
          Text(_cancel.isCancelled
              ? 'Cancelling...'
              : _fraction == null
                  ? 'Reading the sound'
                  : 'Reading the sound ${(_fraction! * 100).round()}%'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _cancel.isCancelled ? null : () => setState(_cancel.cancel),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
