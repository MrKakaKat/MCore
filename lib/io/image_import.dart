import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'file_pick.dart';

/// Image import - no JS equivalent to port from (movement-core/desktop never
/// had this).
///
/// UNVERIFIED like the rest of the render path this feeds into (see
/// canvas_renderer.dart's own doc comment): ui.instantiateImageCodec was
/// confirmed to hang in this sandbox's headless flutter_tester, so the
/// decode step here has never actually run in this session either.
class PickedImage {
  final Uint8List bytes;
  final String? path; // null on platforms that don't expose a real path (e.g. web)
  final int width;
  final int height;
  PickedImage({required this.bytes, this.path, required this.width, required this.height});
}

/// opens the platform's file picker restricted to image types, reads
/// the chosen file's bytes, and decodes just far enough to learn its
/// natural pixel dimensions (needed for createImageLayer's
/// aspect-correct default sizing) - returns null if the user cancelled.
///
/// (media import doesn't work). Root cause: this used to pick with `withData:
/// true`, which loads the whole file into memory via file_picker's own path -
/// a documented source of silent null-bytes failures on some Android
/// devices/versions. Reading the path directly via dart:io instead is the
/// standard recommended file_picker pattern - lower peak memory, and any real
/// failure (missing path, unreadable file, undecodable image) now THROWS
/// instead of returning null, so the caller can tell "user cancelled" (null)
/// apart from "something went wrong" (an exception) and show real feedback for
/// the latter.
Future<PickedImage?> pickImageForImport() async {
  final result = await pickOriginalFiles(type: FileType.image);
  if (result == null || result.files.isEmpty) return null; // user cancelled
  final path = result.files.single.path;
  if (path == null) {
    throw StateError('The picked image has no accessible file path on this platform.');
  }
  final bytes = await File(path).readAsBytes();

  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return PickedImage(
    bytes: bytes,
    path: path,
    width: frame.image.width,
    height: frame.image.height,
  );
}

/// base64-encodes a picked image's bytes for the "embedded" storage
/// mode (Content.imageData) - kept as its own small function so the
/// encoding convention lives in exactly one place.
String encodeImageDataForEmbedding(Uint8List bytes) => base64Encode(bytes);
