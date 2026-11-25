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
// softness: near the pattern's threshold a pixel blends the two levels
// (colours) it falls between instead of jumping (0: hard)
uniform float uSoft;
// only lighter (0/1): a darkening turned into the same lightening
uniform float uLighten;
// brightness squeezed toward the middle before dithering (0..1)
uniform float uSqueeze;
// pattern hold: the top step squeezed so the light parts keep the
// pattern (1: white lands halfway between the two top levels)
uniform float uHold;
// dissolve: the share of pixels kept whole (< 0: off) and the draw of
// the dice (another each frame for "dancing")
uniform float uKeep;
uniform float uSeed;
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

// the classic 4x4 ordered table (0 8 2 10 / 12 4 14 6 / 3 11 1 9 /
// 15 7 13 5), 0..1: four of the 2x2 one, each step within one of them.
float m2(vec2 a) {
  a = mod(floor(a), 2.0);
  return a.y < 0.5 ? 2.0 * a.x : (a.x < 0.5 ? 3.0 : 1.0);
}
float classic4(vec2 cell) {
  return (4.0 * m2(cell) + m2(floor(cell / 2.0)) + 0.5) / 16.0;
}

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
  if (uPattern < 9.5) return fract(cell.x * 0.25 + mod(cell.y, 2.0) * 0.5 + 0.125);
  // the classic table, laid so a pixel turns up where its step is passed
  return 1.0 - classic4(cell);
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

// `x` in steps (0..n): the step below plus how far toward the next - a
// jump at the threshold `th`, or (soft) a blend around it.
float quant(float x, float n, float th) {
  x = clamp(x, 0.0, n);
  // the light end: the top step pressed down - the pattern doesn't run
  // out into flat white
  if (x > n - 1.0) x = (n - 1.0) + (x - (n - 1.0)) * (1.0 - 0.5 * clamp(uHold, 0.0, 1.0));
  float b = floor(x);
  float fr = x - b;
  float s = clamp(uSoft, 0.0, 1.0);
  float w = s < 0.001 ? step(th, fr) : smoothstep(th - s * 0.5, th + s * 0.5, fr);
  return min(b + w, n);
}

// the palette's nearest colour and the next nearest
void nearestTwo(vec3 c, inout vec3 p1, inout vec3 p2, vec3 p) {
  if (dist(c, p) < dist(c, p1)) {
    p2 = p1;
    p1 = p;
  } else if (dist(c, p) < dist(c, p2)) {
    p2 = p;
  }
}

vec3 paletteSoft(vec3 c, float th) {
  vec3 p1 = uPal0;
  vec3 p2 = uPal1;
  if (dist(c, p2) < dist(c, p1)) {
    p1 = uPal1;
    p2 = uPal0;
  }
  if (uPalCount > 2.5) nearestTwo(c, p1, p2, uPal2);
  if (uPalCount > 3.5) nearestTwo(c, p1, p2, uPal3);
  if (uPalCount > 4.5) nearestTwo(c, p1, p2, uPal4);
  if (uPalCount > 5.5) nearestTwo(c, p1, p2, uPal5);
  if (uPalCount > 6.5) nearestTwo(c, p1, p2, uPal6);
  if (uPalCount > 7.5) nearestTwo(c, p1, p2, uPal7);
  // how far from the nearest toward the next (0..1 along between them)
  vec3 d = p2 - p1;
  float f = clamp(dot(c - p1, d) / max(dot(d, d), 1e-6), 0.0, 1.0);
  float s = clamp(uSoft, 0.0, 1.0);
  return mix(p1, p2, smoothstep(th - s * 0.5, th + s * 0.5, f));
}

vec3 dither(vec3 c0, vec2 pos) {
  vec2 cell = ditherCell(pos);
  float t = threshold(cell) - 0.5;
  // where between two steps a pixel turns to the upper one
  float th = 0.5 - t * uSpread;
  float sq = 1.0 - clamp(uSqueeze, 0.0, 1.0);
  // (two colours: the squeeze is on the brightness only, below - the
  // picture's own colours are kept as they are)
  vec3 c = uMode > 2.5 ? c0 : (c0 - 0.5) * sq + 0.5;
  c = mix(c, vec3(1.0) - c, clamp(uInvert, 0.0, 1.0));
  vec3 res;
  float n = max(uLevels - 1.0, 1.0);
  if (uMode > 2.5) {
    // two colours: the brightness in steps, laid from dark to light
    float l = (dot(c0, vec3(0.299, 0.587, 0.114)) - 0.5) * sq + 0.5;
    l = mix(l, 1.0 - l, clamp(uInvert, 0.0, 1.0));
    float q = quant(l * n, n, th) / n;
    vec3 keep = c0 * (q / max(l, 0.001));
    res = mix(keep, mix(uDark, uLight, q), clamp(uColorize, 0.0, 1.0));
  } else if (uMode > 1.5) {
    if (uSoft > 0.001) {
      res = paletteSoft(c, th);
    } else {
      // the step between palette colours: about one over their count.
      float step = 1.0 / max(uPalCount - 1.0, 1.0);
      res = palette(clamp(c + vec3(t * uSpread * step), 0.0, 1.0));
    }
  } else if (uMode > 0.5) {
    float g = dot(c, vec3(0.299, 0.587, 0.114));
    res = vec3(quant(g * n, n, th) / n);
  } else {
    res = vec3(quant(c.r * n, n, th), quant(c.g * n, n, th), quant(c.b * n, n, th)) / n;
  }
  if (uLighten > 0.5) res = clamp(c + abs(res - c), 0.0, 1.0);
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
        vec2 dc = ditherCell(p);
        rgb = (uPattern > 9.5 ? classic4(dc) : bayer8(dc)) <= o ? d : rgb;
      } else {
        rgb = mix(rgb, d, o);
      }
    }
    c = vec4(rgb * c.a, c.a);
  }
  if (uKeep >= 0.0) {
    vec2 px = floor(FlutterFragCoord().xy);
    if (hash(px + vec2(uSeed * 17.31, uSeed * 7.77)) >= uKeep) c = vec4(0.0);
  }
  fragColor = c;
}
