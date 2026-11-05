import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Transform;
import 'package:flutter/services.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';

/// "Prompt for AI": what you want, copied together with the MCJ guide
/// (and, for an open project, the project itself) - for any chatbot. No
/// network: only the clipboard.
Future<void> showAiPromptDialog(BuildContext context, {AppState? app}) {
  return showDialog<void>(context: context, builder: (_) => _PromptDialog(app: app));
}

class _PromptDialog extends StatefulWidget {
  final AppState? app;
  const _PromptDialog({this.app});

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  final _text = TextEditingController();
  GuideLevel _level = GuideLevel.compact;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    final app = widget.app;
    final current = app == null
        ? null
        : compactToMcj(app.project,
            width: app.frameWidth, height: app.frameHeight, fps: fps, duration: app.maxFrame);
    await Clipboard.setData(ClipboardData(text: buildAiPrompt(_text.text, current: current, level: _level, fonts: registeredFonts())));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Copied. Paste it into any chatbot, then bring its reply back with "Import from text".')));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.app == null ? 'Prompt for AI' : 'Edit this project with AI'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            key: const ValueKey('ai-request'),
            controller: _text,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
                labelText: 'What should it make?', hintText: 'A red ball bounces in from the left...', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Guide:', style: TextStyle(fontSize: 12)),
            ChoiceChip(
              key: const ValueKey('ai-level-compact'),
              label: const Text('compact'),
              selected: _level == GuideLevel.compact,
              onSelected: (_) => setState(() => _level = GuideLevel.compact),
            ),
            ChoiceChip(
              key: const ValueKey('ai-level-full'),
              label: const Text('full'),
              selected: _level == GuideLevel.full,
              onSelected: (_) => setState(() => _level = GuideLevel.full),
            ),
          ]),
          const Text('Compact fits a phone chat; full has every parameter and recipe.',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton.icon(
          key: const ValueKey('ai-copy-prompt'),
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy prompt'),
          onPressed: _copy,
        ),
      ],
    );
  }
}

/// "Import from text": paste a chatbot's reply; the report of what was
/// dropped or clamped shows before anything is made. Null: cancelled.
Future<McjResult?> showAiImportDialog(BuildContext context, {String title = 'Import from text'}) {
  return showDialog<McjResult>(context: context, builder: (_) => _ImportDialog(title: title));
}

class _ImportDialog extends StatefulWidget {
  final String title;
  const _ImportDialog({required this.title});

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _text = TextEditingController();
  String? _error;
  McjResult? _result;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _read() {
    try {
      final r = expandMcj(extractMcjJson(_text.text));
      setState(() {
        _result = r;
        _error = null;
      });
    } on FormatException catch (e) {
      setState(() {
        _error = e.message;
        _result = null;
      });
    } catch (e) {
      setState(() => _error = 'This text can\'t be read as a project ($e).');
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (r == null) ...[
              TextField(
                key: const ValueKey('ai-paste'),
                controller: _text,
                minLines: 6,
                maxLines: 12,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(hintText: 'Paste the AI\'s reply here', border: OutlineInputBorder()),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('Paste from clipboard'),
                  onPressed: () async {
                    final d = await Clipboard.getData(Clipboard.kTextPlain);
                    if (d?.text != null) setState(() => _text.text = d!.text!);
                  },
                ),
              ),
              if (_error != null)
                Text(_error!, key: const ValueKey('ai-error'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ] else ...[
              Text('${r.project.layers.length} layer${r.project.layers.length == 1 ? '' : 's'}, '
                  '${r.width.round()} × ${r.height.round()}, ${r.fps} fps, ${r.duration} frames'),
              const SizedBox(height: 8),
              if (r.report.isEmpty)
                const Text('Everything came in as written.')
              else ...[
                Text('Changed on the way in (${r.report.length}):', style: const TextStyle(fontWeight: FontWeight.bold)),
                for (final line in r.report)
                  Text('• $line', style: const TextStyle(fontSize: 12)),
              ],
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (r == null)
          FilledButton(key: const ValueKey('ai-read'), onPressed: _read, child: const Text('Read'))
        else
          FilledButton(key: const ValueKey('ai-import'), onPressed: () => Navigator.pop(context, r), child: const Text('Import')),
      ],
    );
  }
}

/// Settings: the full agent guide as a file to share or save.
Future<String?> exportAgentGuide() => FilePicker.platform.saveFile(
      dialogTitle: 'Save the AI guide',
      fileName: 'MCORE_AGENT_GUIDE.md',
      bytes: Uint8List.fromList(utf8.encode(buildAgentGuide())),
    );
