import 'package:file_picker/file_picker.dart';

/// Every file the app picks goes through here: the file exactly as it is.
///
/// file_picker defaults to `allowCompression: true, compressionQuality: 30`,
/// which on Android re-encodes a picked image as a JPEG - a transparent PNG
/// came in opaque (and blurrier). Media is imported as-is instead.
Future<FilePickerResult?> pickOriginalFiles({
  FileType type = FileType.any,
  List<String>? allowedExtensions,
}) =>
    FilePicker.platform.pickFiles(
      type: type,
      allowedExtensions: allowedExtensions,
      allowCompression: false,
      compressionQuality: 0,
    );
