import 'native_media.dart';
import 'video_service.dart';

/// The concrete VideoService the rest of the app depends on - a single
/// wiring point, so swapping implementations is a one-line change here,
/// not a search-and-replace across every caller (see video_service.dart's
/// own doc comment on why this seam exists). Now Android's own codecs
/// (NativeVideoService); before that a bundled ffmpeg.
VideoService createVideoService() => NativeVideoService();
