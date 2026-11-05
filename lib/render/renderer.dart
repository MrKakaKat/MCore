import 'dart:ui' as ui;

/// Render-backend seam. v1's implementation (CanvasRenderer) wraps a
/// CustomPainter; a future GPU/native/Skia-plugin backend implements this
/// same interface. Nothing outside render/ should ever import a concrete
/// implementation directly - only this abstract type.
abstract class Renderer {
  /// Pull-model: given the full project state and a frame number, produce
  /// pixels. Called fresh on every playback tick or parameter edit - no
  /// incremental/diff-based updates, matching the same "always evaluate
  /// from scratch" philosophy the original engine used, and the same
  /// tradeoff (simplicity over squeezing out redundant recomputation,
  /// mitigated separately by frame-scoped memoization in core/state_cache.dart
  /// rather than by this interface trying to be clever about diffing).
  void renderFrame(dynamic project, int frame);

  /// Captures the current rendered frame as a still image - for PNG export
  /// or thumbnails. NOT the path the live on-screen view uses; that reads
  /// directly from whatever surface renderFrame drew into.
  Future<ui.Image> captureFrame();

  /// Release any native resources (textures, buffers) this implementation
  /// is holding. Every implementation must make this safe to call more
  /// than once.
  void dispose();
}
