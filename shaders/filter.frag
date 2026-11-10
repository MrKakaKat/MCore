#version 460 core
#include <flutter/runtime_effect.glsl>

// Filters (lib/render/canvas_renderer.dart, _shaderPass): fractal warp
// (the picture pushed around by fractal noise) and the gamma wheel (an
// exponent per channel).
uniform vec2 uSize;
uniform float uWarp;
uniform float uScale;
uniform float uTime;
uniform vec3 uGamma;
uniform sampler2D uImage;

out vec4 fragColor;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
             mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 5; i++) {
    v += a * noise(p);
    p *= 2.0;
    a *= 0.5;
  }
  return v;
}

void main() {
  vec2 pos = FlutterFragCoord().xy;
  vec2 q = pos / max(uScale, 1.0);
  vec2 off = vec2(fbm(q + vec2(uTime, 0.0)), fbm(q + vec2(5.2, 1.3 - uTime))) - 0.5;
  vec2 uv = (pos + off * 2.0 * uWarp) / uSize;
  vec4 c = texture(uImage, uv);
  if (c.a > 0.0) {
    vec3 rgb = pow(max(c.rgb / c.a, vec3(0.0)), uGamma);
    c = vec4(rgb * c.a, c.a);
  }
  fragColor = c;
}
