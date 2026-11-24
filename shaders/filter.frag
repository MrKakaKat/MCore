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
// mosaic: cell px (<= 1: off)
uniform float uMosaic;
// dither: on (0/1), mode (0 levels, 1 greys, 2 palette), levels,
// pattern (0 none, 1 bayer2, 2 bayer4, 3 bayer8, 4 noise), spread, dot px
uniform float uDither;
uniform float uMode;
uniform float uLevels;
uniform float uPattern;
uniform float uSpread;
uniform float uDot;
uniform float uPalCount;
uniform vec3 uPal0;
uniform vec3 uPal1;
uniform vec3 uPal2;
uniform vec3 uPal3;
uniform vec3 uPal4;
uniform vec3 uPal5;
uniform vec3 uPal6;
uniform vec3 uPal7;
// how much of the dither shows (0..1), the pattern's turn (radians), the
// eye's weights for the nearest colour (0/1)
uniform float uOpacity;
uniform float uAngle;
uniform float uPerceptual;
// two colours (mode 3): dark and light ends, how much of them over the
// picture's own colours; brightness turned over; screen rows; opacity as
// dots (0/1)
uniform vec3 uDark;
uniform vec3 uLight;
uniform float uColorize;
uniform float uInvert;
uniform float uScanlines;
uniform float uStipple;
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

// ordered dither thresholds (0..1), built up from the 2x2 one.
float bayer2(vec2 a) {
  a = floor(a);
  return fract(a.x / 2.0 + a.y * a.y * 0.75);
}
float bayer4(vec2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
float bayer8(vec2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }

float threshold(vec2 cell) {
  if (uPattern < 0.5) return 0.5;
  if (uPattern < 1.5) return bayer2(cell);
  if (uPattern < 2.5) return bayer4(cell);
  if (uPattern < 3.5) return bayer8(cell);
  if (uPattern < 4.5) return hash(cell);
  // round dots growing from the middle of each 4x4 tile (halftone)
  if (uPattern < 5.5) return clamp(length(fract(cell / 4.0) - 0.5) * 1.4142, 0.0, 1.0);
  if (uPattern < 6.5) return fract((cell.y + 0.5) / 4.0);
  if (uPattern < 7.5) return fract((cell.x + cell.y + 0.5) / 4.0);
  // even noise without clumps (interleaved gradient noise)
  if (uPattern < 8.5) return fract(52.9829189 * fract(0.06711056 * cell.x + 0.00583715 * cell.y));
  // dashes: across, every other row shifted half
  return fract(cell.x * 0.25 + mod(cell.y, 2.0) * 0.5 + 0.125);
}

float dist(vec3 a, vec3 b) {
  vec3 d = a - b;
  vec3 w = uPerceptual > 0.5 ? vec3(0.299, 0.587, 0.114) : vec3(1.0);
  return dot(d * d, w);
}

vec3 nearest(vec3 c, vec3 p, vec3 best) {
  return dist(c, p) < dist(c, best) ? p : best;
}

vec3 palette(vec3 c) {
  vec3 b = uPal0;
  b = nearest(c, uPal1, b);
  if (uPalCount > 2.5) b = nearest(c, uPal2, b);
  if (uPalCount > 3.5) b = nearest(c, uPal3, b);
  if (uPalCount > 4.5) b = nearest(c, uPal4, b);
  if (uPalCount > 5.5) b = nearest(c, uPal5, b);
  if (uPalCount > 6.5) b = nearest(c, uPal6, b);
  if (uPalCount > 7.5) b = nearest(c, uPal7, b);
  return b;
}

vec2 ditherCell(vec2 pos) {
  float cellPx = uMosaic > 1.0 ? uMosaic : max(uDot, 1.0);
  // the pattern turned (about the frame's corner); with a mosaic, the
  // cell's own middle: one value per cell
  vec2 rp = vec2(cos(uAngle) * pos.x - sin(uAngle) * pos.y, sin(uAngle) * pos.x + cos(uAngle) * pos.y);
  return floor((uMosaic > 1.0 ? (floor(pos / uMosaic) + 0.5) * uMosaic : rp) / cellPx);
}

vec3 dither(vec3 c0, vec2 pos) {
  vec2 cell = ditherCell(pos);
  float t = threshold(cell) - 0.5;
  vec3 c = mix(c0, vec3(1.0) - c0, clamp(uInvert, 0.0, 1.0));
  vec3 res;
  float n = max(uLevels - 1.0, 1.0);
  if (uMode > 2.5) {
    // two colours: the brightness in steps, laid from dark to light
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    float q = floor(clamp(l * n + t * uSpread + 0.5, 0.0, n)) / n;
    vec3 keep = c * (q / max(l, 0.001));
    res = mix(keep, mix(uDark, uLight, q), clamp(uColorize, 0.0, 1.0));
  } else if (uMode > 1.5) {
    // the step between palette colours: about one over their count.
    float step = 1.0 / max(uPalCount - 1.0, 1.0);
    res = palette(clamp(c + vec3(t * uSpread * step), 0.0, 1.0));
  } else if (uMode > 0.5) {
    float g = dot(c, vec3(0.299, 0.587, 0.114));
    res = vec3(floor(clamp(g * n + t * uSpread + 0.5, 0.0, n)) / n);
  } else {
    res = floor(clamp(c * n + vec3(t * uSpread) + 0.5, 0.0, n)) / n;
  }
  // screen rows: every other row of dots darker
  res *= 1.0 - clamp(uScanlines, 0.0, 1.0) * 0.45 * mod(cell.y, 2.0);
  return res;
}

void main() {
  vec2 pos = FlutterFragCoord().xy;
  // mosaic: every pixel of a cell takes the colour of the cell's middle.
  if (uMosaic > 1.0) pos = (floor(pos / uMosaic) + 0.5) * uMosaic;
  vec2 q = pos / max(uScale, 1.0);
  vec2 off = vec2(fbm(q + vec2(uTime, 0.0)), fbm(q + vec2(5.2, 1.3 - uTime))) - 0.5;
  vec2 uv = (pos + off * 2.0 * uWarp) / uSize;
  vec4 c = texture(uImage, uv);
  if (c.a > 0.0) {
    vec3 rgb = pow(max(c.rgb / c.a, vec3(0.0)), uGamma);
    if (uDither > 0.5) {
      vec2 p = FlutterFragCoord().xy;
      vec3 d = dither(rgb, p);
      float o = clamp(uOpacity, 0.0, 1.0);
      // opacity as dots: a share of the cells dithered, the rest left
      // as they were (no blend)
      if (uStipple > 0.5) {
        rgb = bayer8(ditherCell(p)) < o ? d : rgb;
      } else {
        rgb = mix(rgb, d, o);
      }
    }
    c = vec4(rgb * c.a, c.a);
  }
  fragColor = c;
}
