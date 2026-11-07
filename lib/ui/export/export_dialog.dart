import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:movement_core/movement_core.dart';

import '../../app_state.dart';
import '../common/hint.dart';
import '../../services/native_media.dart' show NativeVideoService;
import '../../io/export.dart';

/// the export dialog covering all three: a still image of the CURRENT playhead
/// position (PNG/JPG, JPEG quality), a GIF over a frame range (fps/delay, loop
/// count), and video (bitrate OR quality, fps, alpha) via VideoService.
///
/// Follows the same showXxxDialog(context, app) + XxxView split
/// stage_settings_dialog.dart already established - this dialog has no
/// tab-rail equivalent (it's a one-off action, not an ongoing settings
/// panel), so it's dialog-only, no separate tab.
Future<void> showExportDialog(BuildContext context, AppState app) {
  return showDialog<void>(
    context: context,
    // the whole screen: room for the formats and their settings.
    builder: (context) => Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Export'),
          leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        ),
        body: SafeArea(child: ExportView(app: app)),
      ),
    ),
  );
}

enum _ExportKind { image, gif, video, svg, audio }

/// SVG: the whole animation (true) or the current frame.
bool _svgAnimated = true;

class ExportView extends StatefulWidget {
  final AppState app;
  const ExportView({super.key, required this.app});

  @override
  State<ExportView> createState() => _ExportViewState();
}

class _ExportViewState extends State<ExportView> {
  _ExportKind _kind = _ExportKind.image;

  String _imageFormat = 'png'; // "png" | "jpg"
  double _jpegQuality = 100;

  // the whole animation from its start, wherever the playhead is.
  int _gifStart = 0;
  late int _gifEnd = widget.app.maxFrame;
  // the project's frame rate by default (GIF tops out at 50).
  double _gifFps = fps.clamp(1, 50).toDouble();
  bool _gifLoopForever = true;
  // GIF transparency: on for a transparent project; turning it on for a
  // project with a background colour leaves that colour out of the GIF.
  late bool _gifTransparent = widget.app.background == null;
  // GIF quality 0..100 (colours, dithering, change tolerance) and size:
  // the short side, 480 px by default (a full-size GIF is huge and slow).
  double _gifQuality = 100;
  int? _gifShort = 480;

  double _videoFps = fps.clamp(1, 60).toDouble();

  /// Output resolution (short side px) for video and images; null: the
  /// project's own size.
  int? _outShort;
  // 'vp9' (WebM) or 'h264' (MP4) - both by the phone's own encoders.
  String _videoCodec = 'vp9';
  bool? _hwH264; // null until checked
  bool? _vp9; // null until checked
  // 'low' | 'medium' | 'high' | 'max' (from the size and frame rate), or
  // 'custom' (the Mbit/s slider).
  String _videoQualityPreset = 'max';
  int _videoBitrateKbps = 4000;
  // the project's sound, on whenever there is any.
  bool _videoSound = true;

  /// The sound's quality (kbit/s) - in a video and on its own.
  int _audioKbps = 160;

  /// Sound alone: 'wav' (exact, big) or 'compressed' (Opus / AAC).
  String _audioFormat = 'compressed';

  @override
  void initState() {
    super.initState();
    // the project's own settings by default (no "Auto" button to press).
    _applyAuto(initial: true);
    final vs = widget.app.videoService;
    vs.hardwareH264Available().then((ok) {
      if (mounted) setState(() => _hwH264 = ok);
    }).catchError((_) {
      if (mounted) setState(() => _hwH264 = false);
    });
    final vp9 = vs is NativeVideoService ? vs.vp9Available() : Future.value(true);
    vp9.then((ok) {
      if (!mounted) return;
      setState(() {
        _vp9 = ok;
        // no VP9 encoder on this phone: MP4.
        if (!ok && _videoCodec == 'vp9') _videoCodec = 'h264';
      });
    }).catchError((_) {
      if (mounted) setState(() => _vp9 = false);
    });
  }

  /// Bits per pixel per frame for each quality preset.
  static const _bpp = {'low': 0.04, 'medium': 0.07, 'high': 0.11, 'max': 0.2};

  /// The bitrate a preset gives at the current size and frame rate (kbit/s).
  /// Output pixels per frame (the chosen resolution).
  double get _outPixels {
    final w = widget.app.frameWidth, h = widget.app.frameHeight;
    final short = math.min(w, h);
    final k = _outShort == null || short <= 0 ? 1.0 : _outShort! / short;
    return w * h * k * k;
  }

  int _presetKbps(String preset) => (_outPixels * _videoFps * (_bpp[preset] ?? 0.11) / 1000)
      .round()
      .clamp(300, 80000);

  int get _effectiveKbps => _videoQualityPreset == 'custom' ? _videoBitrateKbps : _presetKbps(_videoQualityPreset);

  /// Seconds of the whole animation.
  double get _seconds => (widget.app.maxFrame + 1) / fps;

  static String _mb(double bytes) => bytes < 1e6 ? '${(bytes / 1e3).round()} KB' : '${(bytes / 1e6).toStringAsFixed(1)} MB';
  static String _sec(double s) => '${s.toStringAsFixed(s < 10 ? 2 : 1)} s';

  bool _busy = false;

  /// Cancel was pressed: the running export stops at its next frame.
  bool _cancelRequested = false;
  int _autoRuns = 0;
  String? _status;
  // (add some kind of progress indicator, so it's clear whether export is even
  // working) - a real 0.1 value for every phase (capture, preparing, ffmpeg
  // encoding via its statistics callback); null only between phases.
  double? _progress;

  // the vector export kind only makes sense (is only offered) when every layer
  // is a plain shape - SVG export has no representation for a bitmap image
  // layer at all (see svg.dart's own doc comment on scope). hidden pictures
  // don't count: they aren't exported anyway.
  bool get _projectIsShapeOnly => widget.app.project.layers.every((l) => l.hidden || !isMediaShape(l.content.shape));

  static const _kindLabels = {
    _ExportKind.image: ('Image', Icons.image_outlined, 'One picture: the frame under the playhead'),
    _ExportKind.gif: ('GIF', Icons.gif_box_outlined, 'A short looping animation, no sound'),
    _ExportKind.video: ('Video', Icons.movie_outlined, 'The whole animation, with its sound'),
    _ExportKind.svg: ('SVG', Icons.polyline_outlined, 'Shapes as vectors: sharp at any size'),
    _ExportKind.audio: ('Sound', Icons.music_note_outlined, 'Only the sound, all of it mixed'),
  };

  @override
  Widget build(BuildContext context) {
    final kinds = [
      _ExportKind.image,
      _ExportKind.gif,
      _ExportKind.video,
      if (_projectIsShapeOnly) _ExportKind.svg,
      if (widget.app.hasAudio) _ExportKind.audio,
    ];
    final theme = Theme.of(context);
    Widget section(String title, Widget child) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            child,
          ]),
        );
    return Column(children: [
      Expanded(
        child: Theme(
          data: theme.copyWith(
            visualDensity: VisualDensity.compact,
            listTileTheme: theme.listTileTheme.copyWith(dense: true, minVerticalPadding: 0, visualDensity: VisualDensity.compact),
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              // the formats: a name and what it is for, one per line.
              section(
                  'Format',
                  Column(children: [
                    for (final k in kinds)
                      Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        color: _kind == k ? theme.colorScheme.primaryContainer : null,
                        child: InkWell(
                          key: ValueKey('export-kind-${k.name}'),
                          borderRadius: BorderRadius.circular(12),
                          onTap: _busy ? null : () => setState(() => _kind = k),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: Row(children: [
                              Icon(_kindLabels[k]!.$2, size: 22),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(_kindLabels[k]!.$1, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  Text(_kindLabels[k]!.$3, style: theme.textTheme.bodySmall),
                                ]),
                              ),
                              if (_kind == k) const Icon(Icons.check_circle, size: 20),
                            ]),
                          ),
                        ),
                      ),
                  ])),
              // what will be made.
              section('You get', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _summary(_summaryLines()),
                if (_kind == _ExportKind.video) ...[
                  const SizedBox(height: 6),
                  _summary(['File: about ${_videoBytes()}'], key: const ValueKey('export-file-size')),
                ],
              ])),
              // its settings, open (the project's own values to start with).
              section(
                  'Settings',
                  KeyedSubtree(
                    key: const ValueKey('export-settings'),
                    child: switch (_kind) {
                      _ExportKind.image => _buildImageSection(),
                      _ExportKind.gif => _buildGifSection(),
                      _ExportKind.video => _buildVideoSection(),
                      _ExportKind.svg => _buildSvgSection(),
                      _ExportKind.audio => _buildAudioSection(),
                    },
                  )),
            ],
          ),
        ),
      ),
      // at the bottom, always in reach: progress, what happened, Export.
      Material(
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_busy) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 6),
            ],
            if (_status != null) Text(_status!, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            Row(children: [
              if (_busy)
                TextButton(
                  key: const ValueKey('export-cancel'),
                  onPressed: _cancelRequested ? null : () => setState(() => _cancelRequested = true),
                  child: const Text('Cancel'),
                ),
              const Spacer(),
              FilledButton.icon(
                key: const ValueKey('export-go'),
                onPressed: _busy ? null : _export,
                icon: const Icon(Icons.ios_share, size: 18),
                label: Text(_busy ? 'Exporting...' : 'Export ${_kindLabels[_kind]!.$1}'),
              ),
            ]),
          ]),
        ),
      ),
    ]);
  }

  /// The summary of what the picked format will make.
  List<String> _summaryLines() {
    final app = widget.app;
    final size = '${app.frameWidth.round()} x ${app.frameHeight.round()} px';
    switch (_kind) {
      case _ExportKind.image:
        final f = app.currentFrame;
        return ['${_imageFormat.toUpperCase()} - frame $f', size];
      case _ExportKind.gif:
        final frames = exportFrameNumbers(_gifStart, _gifEnd, _gifFps).length;
        return [
          'GIF - ${_sec(math.max(0, _gifEnd - _gifStart) / fps)}, ${_gifFps.round()} fps ($frames pictures)',
          '${_gifShort == null ? size : 'short side $_gifShort px'}, quality ${_gifQuality.round()}'
              '${_gifTransparent ? ', transparent' : ''}${_gifLoopForever ? ', loops' : ''}',
          if (app.hasAudio) 'No sound (GIF has none)',
        ];
      case _ExportKind.video:
        final frames = exportFrameNumbers(0, app.maxFrame, _videoFps).length;
        final kbps = _effectiveKbps;
        final sound = _videoSound && app.hasAudio;
        return [
          '${_videoCodec == 'h264' ? 'MP4 (H.264)' : 'WebM (VP9)'} - Length: ${_sec(_seconds)}, ${_videoFps.round()} fps ($frames pictures)',
          '$size, ${(kbps / 1000).toStringAsFixed(1)} Mbit/s${sound ? ', with sound' : ''}',
        ];
      case _ExportKind.svg:
        return [
          _svgAnimated ? 'SVG animation - frames 0 - ${app.maxFrame}, looping' : 'SVG - frame ${app.currentFrame}',
          size,
        ];
      case _ExportKind.audio:
        return [
          _audioFormat == 'wav' ? 'Sound - WAV (exact), ${_sec(_seconds)}' : 'Sound - Opus or AAC, ${_sec(_seconds)}',
          _audioFormat == 'wav'
              ? 'about ${_mb(_seconds * 48000 * 4)}'
              : '$_audioKbps kbit/s, about ${_mb(_seconds * _audioKbps * 1000 / 8)}',
        ];
    }
  }

  String _videoBytes() {
    final sound = _videoSound && widget.app.hasAudio;
    return _mb(_effectiveKbps * 1000 / 8 * _seconds + (sound ? 20000 * _seconds : 0));
  }

  /// The project's own export settings (see autoExportSettings): the
  /// format and its settings when the window opens.
  void _applyAuto({bool initial = false}) {
    final app = widget.app;
    final a = autoExportSettings(
      width: app.frameWidth,
      height: app.frameHeight,
      frames: app.maxFrame + 1,
      projectFps: fps,
      hasSound: app.hasAudio,
      hasMedia: app.project.layers.any((l) => isMediaShape(l.content.shape)),
      transparent: app.background == null,
    );
    void apply() {
      switch (a.kind) {
        case 'image':
          _kind = _ExportKind.image;
          _imageFormat = 'png';
        case 'gif':
          _kind = _ExportKind.gif;
          _gifStart = 0;
          _gifEnd = app.maxFrame;
          _gifFps = a.fps;
          _gifTransparent = a.alpha;
          _gifLoopForever = true;
        default:
          _kind = _ExportKind.video;
      }
      // the video settings follow the project whichever format leads.
      _videoFps = math.min(fps, 60).toDouble();
      _videoQualityPreset = 'max';
      _videoSound = true;
      _autoRuns++; // the frame fields show the new range
    }

    initial ? apply() : setState(apply);
  }

  /// A labelled block: a short title, its controls, and one short grey
  /// line on what it changes.
  Widget _group(String title, List<Widget> children, {String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 2),
          ...children,
          if (hint != null) Text(hint, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      );

  Widget _summary(List<String> lines, {Key key = const ValueKey('export-summary')}) => Container(
        key: key,
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(lines.join('\n'), style: const TextStyle(fontSize: 12)),
      );

  /// The output resolution: the project's own size, or a short side.
  Widget _resolutionGroup() {
    final w = widget.app.frameWidth, h = widget.app.frameHeight;
    final short = math.min(w, h);
    String size(int? s) {
      final k = s == null || short <= 0 ? 1.0 : s / short;
      int even(double v) => k == 1 ? v.round() : (v * k / 2).round() * 2;
      return '${even(w)} × ${even(h)}';
    }

    return _group('Resolution: ${size(_outShort)} px', [
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Wrap(spacing: 6, children: [
        ChoiceChip(
          key: const ValueKey('export-res-project'),
          label: const Text('Project'),
          selected: _outShort == null,
          onSelected: (_) => setState(() => _outShort = null),
        ),
        for (final (px, name) in exportResolutions)
          ChoiceChip(
            key: ValueKey('export-res-$px'),
            label: Text(name),
            selected: _outShort == px,
            onSelected: (_) => setState(() => _outShort = px),
          ),
      ])),
    ], hint: 'Shapes and text stay sharp at any size; pictures and video layers are only as sharp as they came in');
  }

  Widget _buildImageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _resolutionGroup(),
        _group('Format', [
          Wrap(spacing: 6, children: [
            ChoiceChip(label: const Text('PNG'), selected: _imageFormat == 'png', onSelected: (_) => setState(() => _imageFormat = 'png')),
            ChoiceChip(label: const Text('JPG'), selected: _imageFormat == 'jpg', onSelected: (_) => setState(() => _imageFormat = 'jpg')),
          ]),
        ]),
        if (_imageFormat == 'jpg')
          _group('JPG quality: ${_jpegQuality.round()} %', [
            Slider(value: _jpegQuality, min: 1, max: 100, divisions: 99, onChanged: (v) => setState(() => _jpegQuality = v)),
          ], hint: '100 % = best picture, biggest file'),
      ],
    );
  }

  Widget _buildGifSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _group('Part of the timeline', [
          Row(children: [
            Expanded(
              child: TextFormField(
                key: ValueKey('gif-start-$_autoRuns'),
                initialValue: '$_gifStart',
                decoration: const InputDecoration(labelText: 'From frame', isDense: true),
                keyboardType: TextInputType.number,
                onChanged: (v) => setState(() => _gifStart = int.tryParse(v) ?? _gifStart),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                key: ValueKey('gif-end-$_autoRuns'),
                initialValue: '$_gifEnd',
                decoration: const InputDecoration(labelText: 'To frame', isDense: true),
                keyboardType: TextInputType.number,
                onChanged: (v) => setState(() => _gifEnd = int.tryParse(v) ?? _gifEnd),
              ),
            ),
          ]),
        ], hint: 'The project runs $fps frames per second: frame $fps is 1 s'),
        _gifSizeGroup(),
        _group('Quality: ${_gifQuality.round()}', [
          Slider(
              key: const ValueKey('gif-quality'),
              value: _gifQuality,
              min: 0,
              max: 100,
              divisions: 20,
              onChanged: (v) => setState(() => _gifQuality = v)),
        ], hint: _gifQualityHint()),
        _group('Smoothness: ${_gifFps.round()} frames per second', [
          Slider(value: _gifFps, min: 1, max: 50, divisions: 49, onChanged: (v) => setState(() => _gifFps = v)),
        ], hint: 'More is smoother but a bigger file'),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Play in a loop'),
          value: _gifLoopForever,
          onChanged: (v) => setState(() => _gifLoopForever = v),
        ),
        SwitchListTile(
          key: const ValueKey('gif-transparent'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Transparent background'),
          value: _gifTransparent,
          onChanged: (v) => setState(() => _gifTransparent = v),
        ),
      ],
    );
  }

  String _gifQualityHint() {
    final o = GifOptions.quality(_gifQuality.round());
    return '${o.maxColors} colours${o.dither ? ', smooth gradients' : ''}'
        '${o.lossy == 0 ? ', exact' : ', small changes skipped (smaller file)'}';
  }

  Widget _gifSizeGroup() {
    final w = widget.app.frameWidth, h = widget.app.frameHeight;
    final short = math.min(w, h);
    String size(int? s) {
      final k = s == null || short <= 0 ? 1.0 : s / short;
      int even(double v) => k == 1 ? v.round() : (v * k / 2).round() * 2;
      return '${even(w)} × ${even(h)}';
    }

    return _group('Size: ${size(_gifShort)} px', [
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Wrap(spacing: 6, children: [
        for (final px in const [240, 360, 480, 720])
          if (px < short)
            ChoiceChip(
              key: ValueKey('gif-res-$px'),
              label: Text('${px}p'),
              selected: _gifShort == px,
              onSelected: (_) => setState(() => _gifShort = px),
            ),
        ChoiceChip(
          key: const ValueKey('gif-res-project'),
          label: const Text('Project'),
          selected: _gifShort == null || _gifShort! >= short,
          onSelected: (_) => setState(() => _gifShort = null),
        ),
      ])),
    ], hint: 'Smaller is much faster and lighter; GIFs are usually 360-480p');
  }

  Widget _buildVideoSection() {
    final h264 = _videoCodec == 'h264';
    final kbps = _effectiveKbps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _resolutionGroup(),
        _group('File type', [
          RadioListTile<String>(
            key: const ValueKey('codec-vp9'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: 'vp9',
            groupValue: _videoCodec,
            onChanged: _vp9 == false ? null : (v) => setState(() => _videoCodec = v!),
            title: const Text('WebM (VP9)'),
            subtitle: _vp9 == false
                ? const Text('This phone has no VP9 encoder', style: TextStyle(fontSize: 11))
                : hint('Free of licence fees. Plays in browsers'),
          ),
          RadioListTile<String>(
            key: const ValueKey('codec-h264'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: 'h264',
            groupValue: _videoCodec,
            onChanged: _hwH264 == false ? null : (v) => setState(() => _videoCodec = v!),
            title: const Text('MP4 (H.264)'),
            subtitle: _hwH264 == false
                ? const Text('This phone has no H.264 encoder', style: TextStyle(fontSize: 11))
                : hint('Plays everywhere'),
          ),
        ]),
        _group('Smoothness: ${_videoFps.round()} frames per second', [
          Slider(value: _videoFps, min: 1, max: 60, divisions: 59, onChanged: (v) => setState(() => _videoFps = v)),
        ], hint: 'The project runs $fps; more than that only repeats frames'),
        _group('Picture quality', [
          Wrap(spacing: 6, children: [
            for (final (key, label) in const [('low', 'Low'), ('medium', 'Medium'), ('high', 'High'), ('max', 'Best'), ('custom', 'Custom')])
              ChoiceChip(
                key: ValueKey('quality-$key'),
                label: Text(label),
                selected: _videoQualityPreset == key,
                onSelected: (_) => setState(() {
                  if (key == 'custom') _videoBitrateKbps = _effectiveKbps;
                  _videoQualityPreset = key;
                }),
              ),
          ]),
          if (_videoQualityPreset == 'custom')
            Slider(
              key: const ValueKey('bitrate-slider'),
              value: (_videoBitrateKbps / 1000).clamp(0.3, 40.0),
              min: 0.3,
              max: 40,
              onChanged: (v) => setState(() => _videoBitrateKbps = (v * 1000).round()),
            ),
        ], hint: 'Data per second: ${(kbps / 1000).toStringAsFixed(1)} Mbit/s - more is a clearer picture and a bigger file'),
        if (widget.app.hasAudio)
          SwitchListTile(
            key: const ValueKey('export-sound'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(h264 ? 'Sound (AAC)' : 'Sound (Opus)'),
            value: _videoSound,
            onChanged: (v) => setState(() => _videoSound = v),
          ),
        if (widget.app.hasAudio && _videoSound) _audioQualityGroup(),
      ],
    );
  }

  /// The sound's quality, kbit/s.
  Widget _audioQualityGroup() => _group('Sound quality: $_audioKbps kbit/s', [
        Wrap(spacing: 6, children: [
          for (final k in const [96, 128, 160, 256, 320])
            ChoiceChip(
              key: ValueKey('audio-kbps-$k'),
              label: Text('$k'),
              selected: _audioKbps == k,
              onSelected: (_) => setState(() => _audioKbps = k),
            ),
        ]),
      ], hint: '128 is fine for speech, 160 - 256 for music');

  Widget _buildAudioSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _group('File type', [
          Wrap(spacing: 6, children: [
            ChoiceChip(
              key: const ValueKey('audio-format-compressed'),
              label: const Text('Opus / AAC'),
              selected: _audioFormat == 'compressed',
              onSelected: (_) => setState(() => _audioFormat = 'compressed'),
            ),
            ChoiceChip(
              key: const ValueKey('audio-format-wav'),
              label: const Text('WAV'),
              selected: _audioFormat == 'wav',
              onSelected: (_) => setState(() => _audioFormat = 'wav'),
            ),
          ]),
        ], hint: 'WAV: exact and large. Opus (AAC on older phones): small'),
        if (_audioFormat != 'wav') _audioQualityGroup(),
      ]);

  /// Sound alone: every audio layer mixed over the whole timeline.
  Future<void> _exportAudio() async {
    final app = widget.app;
    final tempDir = await Directory.systemTemp.createTemp('movement_mobile_sound_');
    try {
      setState(() => _status = 'Mixing sound');
      final wav = await app.buildAudioMix(into: File('${tempDir.path}/sound.wav'));
      if (wav == null) {
        setState(() => _status = 'Nothing to hear');
        return;
      }
      if (_audioFormat == 'wav') {
        final path = await _saveBytes(exportFileName(app.projectName, 'wav'), await wav.readAsBytes());
        setState(() => _status = path == null ? 'Cancelled' : 'Saved to $path');
        return;
      }
      setState(() => _status = 'Encoding sound');
      // the encoder takes the bare samples (the WAV without its header).
      final bytes = await wav.readAsBytes();
      final pcm = File('${tempDir.path}/sound.pcm');
      await pcm.writeAsBytes(bytes.sublist(44));
      final out = await app.audioService.encodePcm(pcm, '${tempDir.path}/sound.ogg', kbps: _audioKbps);
      final ext = out.path.split('.').last;
      final path = await _saveBytes(exportFileName(app.projectName, ext), await out.readAsBytes());
      setState(() => _status = path == null ? 'Cancelled' : 'Saved to $path');
    } finally {
      await tempDir.delete(recursive: true);
    }
  }

  Widget _buildSvgSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<bool>(
          key: const ValueKey('svg-animated'),
          segments: const [
            ButtonSegment(value: true, label: Text('Animation')),
            ButtonSegment(value: false, label: Text('One frame')),
          ],
          selected: {_svgAnimated},
          onSelectionChanged: (s) => setState(() => _svgAnimated = s.first),
        ),
        const SizedBox(height: 8),
        Text(
            _svgAnimated
                ? 'Frames 0 - ${widget.app.maxFrame} at ${fps.round()} fps, looping'
                : 'Current frame: ${widget.app.currentFrame}',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _status = null;
      _progress = null;
    });
    // the Chroma contrast view is a preview only - never exported.
    final matte = widget.app.renderer.chromaMatteLayerId;
    widget.app.renderer.chromaMatteLayerId = null;
    // the picture is what the stage camera sees.
    final camera = widget.app.renderer.useStageCamera;
    widget.app.renderer.useStageCamera = true;
    // mask regions: their episodes baked in full before any frame goes out.
    widget.app.renderer.bakeRegionsNow = true;
    // the stage's handle cuts are a view thing - never exported.
    final cuts = widget.app.renderer.stageCuts;
    widget.app.renderer.stageCuts = null;
    // the chosen resolution (video and images).
    final short = math.min(widget.app.frameWidth, widget.app.frameHeight);
    final outShort = _kind == _ExportKind.gif ? _gifShort : _outShort;
    widget.app.renderer.outputScale =
        outShort == null || short <= 0 || !(_kind == _ExportKind.image || _kind == _ExportKind.video || _kind == _ExportKind.gif)
            ? 1
            : outShort / short;
    try {
      switch (_kind) {
        case _ExportKind.image:
          await _exportImage();
        case _ExportKind.gif:
          await _exportGif();
        case _ExportKind.video:
          await _exportVideo();
        case _ExportKind.svg:
          await _exportSvg();
        case _ExportKind.audio:
          await _exportAudio();
      }
    } on ExportCancelled {
      if (mounted) {
        setState(() {
          _status = 'Export cancelled';
          _progress = null;
        });
      }
    } catch (e) {
      setState(() => _status = 'Export failed: $e');
    } finally {
      // exporting drives the renderer through arbitrary frames (GIF/
      // video capture a whole range) - restore the live view to
      // whatever frame the user actually has selected before returning.
      widget.app.renderer.chromaMatteLayerId = matte;
      widget.app.renderer.useStageCamera = camera;
      widget.app.renderer.bakeRegionsNow = false;
      widget.app.renderer.stageCuts = cuts;
      widget.app.renderer.outputScale = 1;
      widget.app.setFrame(widget.app.currentFrame);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportImage() async {
    final bytes = await exportStillFrame(
      renderer: widget.app.renderer,
      project: widget.app.project,
      frame: widget.app.currentFrame,
      format: _imageFormat,
      jpegQuality: _jpegQuality.round(),
    );
    final path = await _saveBytes(exportFileName(widget.app.projectName, _imageFormat, frame: widget.app.currentFrame), bytes);
    setState(() => _status = path == null ? 'Cancelled' : 'Saved to $path');
  }

  Future<void> _exportSvg() async {
    if (_svgAnimated) {
      final svg = exportProjectToAnimatedSvg(widget.app.project, 0, widget.app.maxFrame, fps.toDouble(),
          widget.app.frameWidth, widget.app.frameHeight,
          mirrorX: widget.app.stageMirrorX, mirrorY: widget.app.stageMirrorY);
      final path = await _saveBytes(exportFileName(widget.app.projectName, 'svg'), utf8.encode(svg));
      setState(() => _status = path == null ? 'Cancelled' : 'Saved to $path');
      return;
    }
    final svg = exportProjectToSvg(widget.app.project, widget.app.currentFrame, widget.app.frameWidth, widget.app.frameHeight,
        mirrorX: widget.app.stageMirrorX, mirrorY: widget.app.stageMirrorY);
    final path = await _saveBytes(exportFileName(widget.app.projectName, 'svg', frame: widget.app.currentFrame), utf8.encode(svg));
    setState(() => _status = path == null ? 'Cancelled' : 'Saved to $path');
  }

  Future<void> _exportGif() async {
    final renderer = widget.app.renderer;
    final background = renderer.backgroundColor;
    if (_gifTransparent) renderer.backgroundColor = null;
    renderer.beginExportReuse(widget.app.project);
    final List<int> bytes;
    try {
      bytes = await exportGif(
      renderer: widget.app.renderer,
      project: widget.app.project,
      startFrame: _gifStart,
      endFrame: _gifEnd,
      fps: _gifFps,
      loopCount: _gifLoopForever ? 0 : 1,
      quality: _gifQuality.round(),
      cancelled: () => _cancelRequested,
      onProgress: (current, total) {
        if (!mounted) return;
        setState(() {
          _progress = current / total;
          _status = 'Encoding frame $current/$total';
        });
      },
    );
    } finally {
      renderer.backgroundColor = background;
      renderer.endExportReuse();
    }
    final path = await _saveBytes(exportFileName(widget.app.projectName, 'gif'), bytes);
    setState(() {
      _progress = null;
      _status = path == null ? 'Cancelled' : 'Saved to $path';
    });
  }

  /// "Export failed: Invalid argument(s): Bytes are required on Android & iOS
  /// when saving a file." - the old code called `FilePicker.platform.saveFile`
  /// for a destination path BEFORE encoding (ffmpeg needs a real path to write
  /// to), but file_picker requires `bytes:` on mobile, which isn't available
  /// until AFTER encoding. Fixed by encoding to a throwaway temp path first
  /// (same pattern ffmpeg_video_service.dart already uses internally for its
  /// own intermediate frames), then reading those bytes back and reusing the
  /// existing `_saveBytes` helper - the same "encode first, prompt for a
  /// destination second" order the image/ GIF export paths above already use
  /// correctly.
  Future<void> _exportVideo() async {
    final app = widget.app;
    final codec = _videoCodec;
    final fileName = exportFileName(app.projectName, codec == 'h264' ? 'mp4' : 'webm');
    final tempDir = await Directory.systemTemp.createTemp('movement_mobile_export_');
    final renderer = app.renderer;
    // layers that never change are drawn once for the whole export.
    renderer.beginExportReuse(app.project);
    try {
      // sampled by time at the output rate - the video plays at the
      // animation's real speed.
      final frameNumbers = exportFrameNumbers(0, app.maxFrame, _videoFps);
      final total = frameNumbers.length;

      // the sound: every audio layer mixed from frame 0, exactly as long
      // as the frames.
      File? sound;
      if (_videoSound && app.hasAudio) {
        setState(() => _status = 'Mixing sound');
        sound = await app.buildAudioMix(seconds: total / _videoFps, into: File('${tempDir.path}/sound.wav'));
      }

      // each frame is drawn and handed to the encoder while it works on
      // the ones before (no PNGs, nothing kept in memory).
      final encoded = await app.videoService.encodeStream(
        width: renderer.pixelWidth,
        height: renderer.pixelHeight,
        frameCount: total,
        frameAt: (i) async {
          if (_cancelRequested) throw const ExportCancelled();
          await prepareExportFrame(renderer, app.project, frameNumbers[i]);
          renderer.renderFrame(app.project, frameNumbers[i]);
          final image = await renderer.captureFrame();
          final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
          image.dispose();
          return data!.buffer.asUint8List();
        },
        fps: _videoFps,
        outputPath: '${tempDir.path}/$fileName',
        codec: codec,
        // Android's encoders make no alpha: the video is opaque.
        bitrateKbps: _effectiveKbps,
        audioPath: sound?.path,
        audioKbps: _audioKbps,
        onProgress: (phase, done, n) {
          if (!mounted) return;
          setState(() {
            _progress = n == 0 ? null : done / n;
            _status = phase == 'Drawing' ? 'Drawing and encoding: frame $done of $n' : 'Encoding: frame $done of $n';
          });
        },
      );

      final bytes = await encoded.readAsBytes();
      final path = await _saveBytes(fileName, bytes);
      setState(() => _status = path == null ? 'Cancelled' : 'Saved to $path');
    } finally {
      renderer.endExportReuse();
      await tempDir.delete(recursive: true);
    }
  }

  /// picks a save location via the platform file picker; on platforms
  /// where saveFile's own `bytes` param doesn't already write the file
  /// (desktop), writes it here explicitly - see this file's own doc
  /// comment on this being genuinely platform-dependent, untested
  /// behavior.
  Future<String?> _saveBytes(String suggestedName, List<int> bytes) async {
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Export',
      fileName: suggestedName,
      bytes: Uint8List.fromList(bytes),
    );
    if (result == null) return null;
    final file = File(result);
    final alreadyWritten = await file.exists() && await file.length() > 0;
    if (!alreadyWritten) {
      await file.writeAsBytes(bytes);
    }
    return result;
  }
}

/// Export resolutions (short side px), with their names.
const exportResolutions = [(720, '720p'), (1080, '1080p'), (1440, '2K'), (1620, '3K'), (2160, '4K')];

/// A file name no earlier export has: the project's name, the frame for a
/// still, and the date and time down to the second - "My clip_f42_
/// 2026-10-19_14-03-27.png". Saving twice never collides with (or
/// silently replaces) an earlier file.
String exportFileName(String projectName, String extension, {int? frame, DateTime? now}) {
  final t = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}-${two(t.minute)}-${two(t.second)}';
  var name = projectName.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
  if (name.isEmpty) name = 'export';
  final base = '$name${frame == null ? '' : '_f$frame'}_$stamp';
  // two exports within the same second get a counter.
  var candidate = '$base.$extension';
  for (var n = 2; _issuedExportNames.contains(candidate); n++) {
    candidate = '${base}_$n.$extension';
  }
  _issuedExportNames.add(candidate);
  return candidate;
}

final Set<String> _issuedExportNames = {};

/// The export "Auto" picks:
/// - one frame: a PNG;
/// - short and small with no sound or video (at most 8 s, 720 px): a GIF
///   - at the project's rate up to 3 s, at most 25 fps beyond (size);
/// - anything else: WebM at the project's rate (at most 60), with a
///   bitrate for the resolution (about 0.1 bit per pixel per frame, 0.8 -
///   16 Mbit/s), with sound when there is any.
/// Transparency is kept when the project's background is transparent.
({String kind, double fps, int bitrateKbps, bool alpha, String reason}) autoExportSettings({
  required double width,
  required double height,
  required int frames,
  required int projectFps,
  required bool hasSound,
  required bool hasMedia,
  required bool transparent,
}) {
  final seconds = frames / math.max(1, projectFps);
  if (frames <= 1) {
    return (kind: 'image', fps: projectFps.toDouble(), bitrateKbps: 0, alpha: transparent, reason: 'a single frame - PNG');
  }
  final big = math.max(width, height) > 720;
  if (!hasSound && !hasMedia && seconds <= 8 && !big) {
    final gifFps = (seconds <= 3 ? math.min(projectFps, 50) : math.min(projectFps, 25)).toDouble();
    return (
      kind: 'gif',
      fps: gifFps,
      bitrateKbps: 0,
      alpha: transparent,
      reason: 'short (${seconds.toStringAsFixed(1)} s), small, no sound - GIF at ${gifFps.round()} fps'
    );
  }
  final videoFps = math.min(projectFps, 60).toDouble();
  final kbps = ((width * height * videoFps * 0.1 / 1000).clamp(800, 16000) / 100).round() * 100;
  return (
    kind: 'video',
    fps: videoFps,
    bitrateKbps: kbps,
    alpha: transparent,
    reason: '${hasSound ? 'has sound' : hasMedia ? 'has video / images' : big ? 'large frame' : 'long'} - '
        'WebM ${videoFps.round()} fps, ${(kbps / 1000).toStringAsFixed(1)} Mbit/s${transparent ? ', transparent' : ''}'
  );
}
