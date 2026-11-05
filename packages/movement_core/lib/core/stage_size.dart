/// stage pixel dimensions, kept as plain numbers (not read from a real
/// canvas/render surface) so core/ stays render-backend-agnostic - the
/// chosen Renderer implementation syncs this once at startup from
/// whatever surface size it actually has. Ported from
/// movement-core/src/core/stageSize.js.
library;

class StageSize {
  double width;
  double height;
  StageSize({this.width = 640, this.height = 400});
}

final stageSize = StageSize();

void setStageSize(double width, double height) {
  stageSize.width = width;
  stageSize.height = height;
}
