import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:movement_core/movement_core.dart';

import '../render/canvas_renderer.dart';
import '../render/renderer.dart';

/// Waits until everything frame `frame` draws is ready - the exact video
/// frames (not the editor's nearest-frame stand-in) and their keying.
Future<void> prepareExportFrame(Renderer renderer, Project project, int frame) async {
  if (renderer is CanvasRenderer) await renderer.prepareFrame(project, frame);
}

/// Still-frame (PNG/JPG) and GIF export logic (bitrate/quality/fps for
/// video, full GIF format config, and current-frame image export as jpg/png).
/// The video path is thin enough (just VideoService.encodeFrames over a
/// captured frame sequence) that it lives directly in the export dialog
/// instead of needing its own wrapper here.
///
/// PNG encoding itself (ui.ImageByteFormat.png) was spot-checked via a
/// throwaway probe this round and DOES complete correctly in this
/// sandbox (produced a plausible 108-byte PNG for a solid 8x8 square) -
/// but the flutter_tester process still hung afterward during test
/// teardown, the same "everything printed/completed but the process
/// never exits" pattern documented on the CustomPainter-instance hang
/// in layers_timeline_view.dart's own doc comment, not the
/// "instantiateImageCodec itself never returns" pattern documented on
/// gif_encoder_test.dart's. So: the actual encode logic below is more
/// trustworthy than "fully unverified" - it's the test HARNESS around
/// it in this specific sandbox that isn't safe to keep exercising, not
/// necessarily the encode calls themselves. No test in this codebase
/// calls exportStillFrame/exportGif for exactly this reason. Real,
/// harness-safe verification needs a device, per the user's own "write
/// code now, test later" instruction for this round.
Future<Uint8List> exportStillFrame({
  required Renderer renderer,
  required Project project,
  required int frame,
  required String format, // "png" | "jpg"
  int jpegQuality = 85,
}) async {
  await prepareExportFrame(renderer, project, frame);
  renderer.renderFrame(project, frame);
  final image = await renderer.captureFrame();
  final width = image.width, height = image.height;

  if (format == 'jpg') {
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    image.dispose(); // release native Skia memory promptly, don't wait for GC
    if (byteData == null) {
      throw StateError('failed to read raw pixel data from the captured frame');
    }
    return encodeJpeg(
      width: width,
      height: height,
      rgba: byteData.buffer.asUint8List(),
      quality: jpegQuality,
    );
  }

  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (byteData == null) {
    throw StateError('failed to PNG-encode the captured frame');
  }
  return byteData.buffer.asUint8List();
}

/// Frames are read as straight (non-premultiplied) RGBA so anti-aliased
/// edges over a transparent background keep their real color instead of
/// being darkened toward black.
///
/// exports a frame RANGE as an animated GIF - `fps` controls per-frame
/// delay (GIF's own delay unit is 1/100s, so this is necessarily
/// quantized; `loopCount` 0 means loop forever, matching gif_encoder.dart's
/// own convention).
///
/// Streams each captured frame directly into a `GifEncoderSink` instead of
/// accumulating a `List<GifFrame>` first - traced to this accumulation holding
/// `frameCount * width * height * 4` bytes simultaneously for a full-project
/// export, a genuine OOM risk on a mobile device. Streaming bounds peak memory
/// to roughly one frame's worth regardless of export length, and
/// `image.dispose` after each frame's `toByteData` call releases native Skia
/// memory promptly instead of waiting for GC.
///
/// (add some kind of loading/progress indicator during export, so it's clear
/// whether it's even working) - `onProgress`, when given, is called once per
/// frame with `(current, total)` (1-indexed `current`), real and granular
/// since this loop already captures+encodes one frame at a time. The timeline
/// frames an export at `outFps` samples, by time: output frame i shows the
/// timeline at i / outFps seconds - so the result plays at the animation's
/// real speed whatever the project's frame rate.
List<int> exportFrameNumbers(int startFrame, int endFrame, double outFps) {
  if (outFps <= 0) return [for (var f = startFrame; f <= endFrame; f++) f];
  final step = fps / outFps;
  final out = <int>[];
  for (var i = 0;; i++) {
    final f = startFrame + (i * step).round();
    if (f > endFrame) break;
    out.add(f);
  }
  return out;
}

/// Thrown when the person cancels an export: it stops, nothing is saved.
class ExportCancelled implements Exception {
  const ExportCancelled();
}

/// The GIF is encoded on a background isolate (the UI keeps running, and a big
/// frame's work never stalls it - slow, then crashed); the next frame is drawn
/// while the one before is encoded. `quality` 0.100 sets the colours,
/// dithering and how much a pixel may change and still count as unchanged (see
/// GifOptions.quality).
Future<Uint8List> exportGif({
  required Renderer renderer,
  required Project project,
  required int startFrame,
  required int endFrame,
  required double fps,
  int loopCount = 0,
  int quality = 100,
  bool Function()? cancelled,
  void Function(int current, int total)? onProgress,
}) async {
  if (endFrame < startFrame) {
    throw ArgumentError('endFrame must be >= startFrame');
  }
  final delayCentiseconds = (100 / fps).round().clamp(1, 65535);
  final frames = exportFrameNumbers(startFrame, endFrame, fps);
  final total = frames.length;
  final worker = await _GifWorker.start(loopCount, quality);
  try {
    var sent = 0;
    for (final f in frames) {
      if (cancelled?.call() ?? false) throw const ExportCancelled();
      await prepareExportFrame(renderer, project, f);
      renderer.renderFrame(project, f);
      final image = await renderer.captureFrame();
      final width = image.width, height = image.height;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      image.dispose();
      if (byteData == null) continue;
      // at most two frames waiting: drawing never runs far ahead.
      while (sent - worker.done > 1) {
        await worker.progress.first;
      }
      worker.add(width, height, byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes), delayCentiseconds);
      sent++;
      onProgress?.call(worker.done + 1 > sent ? sent : worker.done + 1, total);
    }
    if (sent == 0) throw StateError('no frames were captured for the requested range');
    while (worker.done < sent) {
      await worker.progress.first;
      onProgress?.call(worker.done, total);
    }
    return await worker.finish();
  } finally {
    worker.kill();
  }
}

/// The background encoder: frames go in, the GIF comes out at the end.
class _GifWorker {
  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _recv;
  final StreamController<int> _progress = StreamController<int>.broadcast();
  final Completer<Uint8List> _result = Completer<Uint8List>();
  int done = 0;

  _GifWorker._(this._isolate, this._send, this._recv);

  Stream<int> get progress => _progress.stream;

  static Future<_GifWorker> start(int loopCount, int quality) async {
    final recv = ReceivePort();
    final isolate = await Isolate.spawn(_gifIsolateMain, [recv.sendPort, loopCount, quality]);
    final first = Completer<SendPort>();
    late _GifWorker worker;
    recv.listen((m) {
      if (m is SendPort) {
        first.complete(m);
      } else if (m is int) {
        worker.done = m;
        worker._progress.add(m);
      } else if (m is TransferableTypedData) {
        worker._result.complete(m.materialize().asUint8List());
      } else if (m is String) {
        if (!worker._result.isCompleted) worker._result.completeError(StateError(m));
        worker._progress.addError(StateError(m));
      }
    });
    final send = await first.future;
    worker = _GifWorker._(isolate, send, recv);
    return worker;
  }

  void add(int w, int h, Uint8List rgba, int delay) =>
      _send.send([w, h, TransferableTypedData.fromList([rgba]), delay]);

  Future<Uint8List> finish() {
    _send.send('finish');
    return _result.future;
  }

  void kill() {
    _recv.close();
    _progress.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

void _gifIsolateMain(List<Object> args) {
  final reply = args[0] as SendPort;
  final sink = GifEncoderSink(loopCount: args[1] as int, options: GifOptions.quality(args[2] as int));
  final port = ReceivePort();
  reply.send(port.sendPort);
  var done = 0;
  port.listen((m) {
    try {
      if (m == 'finish') {
        final bytes = sink.finish();
        reply.send(TransferableTypedData.fromList([bytes]));
        port.close();
        return;
      }
      final l = m as List;
      sink.addFrame(GifFrame(
        width: l[0] as int,
        height: l[1] as int,
        rgba: (l[2] as TransferableTypedData).materialize().asUint8List(),
        delayCentiseconds: l[3] as int,
      ));
      reply.send(++done);
    } catch (e) {
      reply.send('$e');
      port.close();
    }
  });
}
