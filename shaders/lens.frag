#version 460 core
#include <flutter/runtime_effect.glsl>

// Lens (lib/render/canvas_renderer.dart, _drawLens): what is under a
// round lens, seen with its angle of view - a point at angle theta from
// the lens's axis (theta grows evenly to the rim: a fish eye's image)
// shows the scene at tan(theta), against a 50 degree view that shows it
// as it is.
uniform vec2 uSize;
uniform vec2 uCenter;
uniform float uRadius;
uniform float uHalfFov;   // radians
uniform float uZoom;
uniform float uVignette;
uniform float uSoft;
uniform sampler2D uImage;

out vec4 fragColor;

void main() {
  vec2 pos = FlutterFragCoord().xy;
  vec2 d = pos - uCenter;
  float r = length(d);
  float rn = r / max(uRadius, 1.0);
  if (rn >= 1.0) {
    fragColor = vec4(0.0);
    return;
  }
  float theta = min(rn * uHalfFov, 1.5359);
  float rs = tan(theta) / 0.46630766 / max(uZoom, 0.01) * uRadius;
  vec2 src = uCenter + (r > 0.0001 ? d / r * rs : vec2(0.0));
  vec2 uv = src / uSize;
  vec4 c = vec4(0.0);
  if (uv.x >= 0.0 && uv.y >= 0.0 && uv.x <= 1.0 && uv.y <= 1.0) c = texture(uImage, uv);
  c.rgb *= 1.0 - uVignette * rn * rn;
  float edge = uSoft > 0.0 ? clamp((1.0 - rn) / uSoft, 0.0, 1.0) : 1.0;
  fragColor = c * edge;
}
