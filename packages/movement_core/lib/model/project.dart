/// ============================================================
/// PROJECT DATA MODEL
/// - fps fixed at 60 (base tick), all frame numbers are integers
/// - each layer has local time: startFrame/durationFrames on the
///   global timeline; every keyframe stored inside a layer is in
///   LOCAL frame units (0 = layer's own start)
/// - each animatable parameter is its own track (list of keyframes)
/// - coordinates are normalized (0..1), mapped to canvas size at
///   render time only
/// - ANCHOR replaces the classic AE split of anchor-point + position:
///   there is ONE animatable world-space point (transform.anchor) that
///   is both the rotation/scale pivot AND the placement. Where the
///   layer's actual geometry sits relative to that point is a
///   separate, non-animated rig setting (layer.content.offset) - not
///   its own keyframe track.
///
/// Ported from movement-core/src/model/project.js. `value`/`default`
/// stay `dynamic` (a double for scalar tracks, a `List<double>` for
/// vec2 ones) exactly like the JS - this mirrors movement-core's own
/// runtime `Array.isArray` checks rather than splitting into two
/// generic Track types, so the JSON shape stays identical for
/// desktop<->mobile project file compatibility. `default` is a
/// reserved word in Dart, so the field is `defaultValue` here; project
/// files still serialize it under the JSON key "default" (see
/// io/save_load.dart).
/// ============================================================
library;

import 'dart:math' as math;

import 'line_path.dart' show LineNode, straightLineNodes, syncLineBox;
import '../text/text_animators.dart' show TextAnimator;
import '../effects/motion/follow.dart' show FollowSettings;

int fps = 60;

// global override: force every layer to render as outline-only, so you
// can see through overlapping shapes at a glance without changing each
// layer's own renderMode setting one by one.
bool globalOutlineMode = false;

// hides ALL on-screen interactive handles (transform box, corner-pin
// points, path indicator/stations) - purely visual/interaction, never
// affects the underlying data. "Physical" in movement-mobile-gesture-
// spec.md's terms: anything touchable.
bool hideHandles = false;

// mobile-only (movement-mobile-gesture-spec.md): hides "visual" stage
// clutter that ISN'T touchable - parent/child link lines, the path's
// dotted line, station points as plain markers. Deliberately separate
// from hideHandles: that one is about not touching something by
// accident, this one is about not having the view of the actual
// artwork cluttered - two different problems, so two independent
// toggles rather than one that conflates them. Never affects
// interactivity, purely a render-layer gate (a station's touch target
// stays draggable under hideHandles=false even if hideVisualLayer=true
// makes its dot invisible - see stage_gesture_controller.dart).
bool hideVisualLayer = false;

// touch-friendly stand-in for shift-click - when on, tapping a marker
// toggles it in/out of the selection instead of replacing it.
bool kfMultiselectMode = false;

// ui_geometry/keyframe_strip.dart's selected keyframe GROUP, as GLOBAL
// frame numbers - mirrors JS's own kfSelection.frames (module-level
// mutable Set). Cleared whenever the selected layer changes - a
// selection tied to a different layer's tracks doesn't mean anything
// here (the UI layer, not this file, is responsible for clearing it on
// selection change, same as JS leaves that to its own caller).
Set<int> kfSelectedFrames = {};

// ===== snapping (mobile-only for now, movement-mobile-snapping-
// spec.md) - plain top-level globals, same pattern as hideHandles/
// hideVisualLayer above: ui_geometry/drag_ops.dart (pure Dart, no
// Flutter/camera) reads these directly during AnchorDragOp/
// ScaleDragOp's apply(), so they can't live behind an AppState import. =====

// master gate - everything below is inert while this is false. OFF by
// default, matching every other not-yet-battle-tested toggle in this
// file (layerQuickSwitchEnabled/timelineEdgeAutoScrollEnabled in
// AppState) - a large, brand-new drag behavior shouldn't change how
// dragging feels until a user opts in.
bool snapEnabled = false;

// per-category enabled - OFF by default: the master toggle alone used to also
// switch on every category at once, which surprised users mid-drag with
// unexpected snapping in categories they never asked for. Each one is now its
// own explicit opt-in.
bool snapEdgeToEdgeEnabled = false;
bool snapCenterToCenterEnabled = false;
bool snapCenterHorizontalEnabled = false;
bool snapCenterVerticalEnabled = false;
bool snapCenterDiagonalEnabled = false;
// a genuinely independent 4th sub-toggle: fits a THIRD object onto the line
// through any two OTHER objects' centers, at whatever angle they actually form
// (not limited to snapDiagonalAngleIncrementDeg multiples like Diagonal
// above). Equal spacing below is the distance-match on top of THIS line, not
// Diagonal's fixed-angle one (a real bug fixed alongside this toggle - see
// snapping.dart's own doc comments).
bool snapCenterLineEnabled = false;
// gates the continue-line candidate's distance-match bonus
// specifically (see snapping.dart) - attaches to snapCenterLineEnabled
// (the any-angle line, above), NOT to Diagonal's fixed-angle one.
bool snapEqualSpacingEnabled = false;
bool snapCornerToCornerEnabled = false;
bool snapEqualSizeEnabled = false;
// "can a drag snap to the grid's line positions" - independent of whether the
// grid overlay is even visible (see gridOverlayEnabled below and
// stage_painter.dart's own _paintSnapGrid gating) - this toggle is purely the
// snap-interaction capability; the grid's own visibility lives entirely
// outside the Snapping feature now.
bool snapGridEnabled = false;
bool snapFrameBoundaryEnabled = false;

// guide-visibility: a SEPARATE flag from hideVisualLayer above (see
// stage_painter.dart's own wiring) - a more targeted way to hide just
// the transient snap guide lines specifically, without touching the
// rest of the visual category (parent-links, path visual, etc).
// Visible by default, matching hideVisualLayer's own "visible unless
// opted out" convention.
bool snapGuidesVisible = true;

// per-category sensitivity, in FRAME-SPACE pixels - this file has no
// camera and can never convert screen px itself. The user-facing,
// screen-px, zoom-aware preference lives in AppState
// (movement_mobile); stage_gesture_controller.dart re-derives these
// via camera.radiusInFrameSpace on every relevant pointer move, the
// same "recompute fresh, never cache" approach _magnetCapture already
// uses for handleRadius/pathBodyRadius. Equal-spacing has no slider of
// its own - it reuses snapCenterToCenterFrameRadius, per the spec.
double snapEdgeToEdgeFrameRadius = 8;
double snapCenterToCenterFrameRadius = 8;
double snapCornerToCornerFrameRadius = 8;
double snapEqualSizeFrameRadius = 8;

/// Rotation snapping: also to the mirror of a nearby shape's angle (-a).
bool snapRotationMirrorEnabled = true;
double snapGridFrameRadius = 8;
// slightly larger default: the one candidate meant to feel "sticky" -
// the canvas edge is always structurally meaningful (what actually
// ends up in the export), so it's allowed a bit more pull than an
// ordinary object.
double snapFrameBoundaryFrameRadius = 10;

// equal-size / equal-spacing shared measurement setting - "how
// distance is measured between two differently-sized objects," kept as
// one setting rather than duplicated per feature, per the spec.
enum SnapSizeMeasurement { edgeGap, centerDistance }

SnapSizeMeasurement snapSizeMeasurement = SnapSizeMeasurement.edgeGap;

// a FIXED target gap, in FRAME pixels (a property of the artwork, like
// content.size/offset - NOT screen px, NOT zoom-scaled) - settable
// independent of which measurement mode above is active.
double snapFixedGapFrame = 40;

// center-to-center's extendable fixed angle set: multiples of this
// increment around the full circle. 0/180 feed the "horizontal"
// candidate pool, 90/270 feed "vertical", everything else (45/135/225/
//315 at the default) feeds "diagonal" - see snapping.dart.
double snapDiagonalAngleIncrementDeg = 45;

// ===== rotation snapping (RotateDragOp only) ===== + - two independent
// mechanisms: fixed-increment (reusing snapDiagonalAngleIncrementDeg above for
// its own "diagonal" set - "diagonal" should mean the same angle set
// everywhere) and matching another nearby object's own current rotation,
// whatever it is.
bool snapRotationEnabled = false; // category master
bool snapRotationHorizontalEnabled = false; // 0 / 180
bool snapRotationVerticalEnabled = false; // 90 / 270
bool snapRotationDiagonalEnabled =
    false; // non-90 multiples of snapDiagonalAngleIncrementDeg
bool snapRotationMatchNearbyEnabled =
    false; // copy another in-range layer's own rotation
// DEGREES, not a px radius. An angle means the same thing at every zoom
// level, so - unlike every other snap sensitivity in this file - this
// needs no AppState px-mirror and no stage_gesture_controller.dart
// _refreshSnapRadii entry. Same precedent as snapFixedGapFrame above (a
// core global written directly from the UI, no px conversion).
double snapRotationToleranceDeg = 5;

// grid overlay: N x M, always evenly auto-fit - no stated spec
// default, 4x4 is an unremarkable, easily-adjusted starting point.
int snapGridCols = 4;
int snapGridRows = 4;

// ===== grid overlay (decoupled from Snapping - see the note on
// snapGridEnabled above) - purely whether the visual grid lines are
// DRAWN on stage at all. stage_painter.dart's own _paintSnapGrid gates
// on this alone, never on snapEnabled - you can see a grid you never
// snap to, or snap to a grid you never see. Off by default, same
// reasoning as every other not-yet-battle-tested visual toggle in this
// file. =====
bool gridOverlayEnabled = false;

class SpatialTangent {
  List<double> inTan;
  List<double> outTan;
  SpatialTangent({required this.inTan, required this.outTan});
  SpatialTangent.zero()
      : inTan = [0, 0],
        outTan = [0, 0];
  SpatialTangent copy() =>
      SpatialTangent(inTan: [...inTan], outTan: [...outTan]);
}

/// temporal easing {x1,y1,x2,y2} - same shape as a keyframe's `temporal`
/// and a spatial track's `globalEasing`.
class Easing {
  final double x1, y1, x2, y2;

  /// 'bezier' (the x1..y2 curve), 'overshoot': the value passes the end
  /// by about `amount` (0..1 of the change) and settles back after
  /// `bounces` extra swings, or 'anticipate': the same backwards (a
  /// swing back before leaving the start). x1..y2 are kept so switching
  /// back restores the bezier.
  final String kind;
  final double amount;
  final int bounces;
  const Easing(this.x1, this.y1, this.x2, this.y2, {this.kind = 'bezier', this.amount = 0.2, this.bounces = 0});
  bool get isOvershoot => kind == 'overshoot' || kind == 'anticipate';
  Easing copy() => Easing(x1, y1, x2, y2, kind: kind, amount: amount, bounces: bounces);
  Easing withBezier(double x1, double y1, double x2, double y2) =>
      Easing(x1, y1, x2, y2, kind: kind, amount: amount, bounces: bounces);
  Easing withOvershoot({String? kind, double? amount, int? bounces}) => Easing(x1, y1, x2, y2,
      kind: kind ?? this.kind, amount: amount ?? this.amount, bounces: bounces ?? this.bounces);
}

const easingPresets = <String, Easing>{
  'linear': Easing(0, 0, 1, 1),
  'easeInOut': Easing(0.42, 0, 0.58, 1),
  'easeIn': Easing(0.42, 0, 1, 1),
  'easeOut': Easing(0, 0, 0.58, 1),
};

/// Settings: the ease new keys get (a name of easingPresets).
String defaultKeyEasingName = 'easeInOut';

/// The ease for a key being added now.
Easing newKeyEasing() => easingPresets[defaultKeyEasingName] ?? easingPresets['easeInOut']!;

/// Settings: editing the ease of a key at a frame where every parameter
/// is keyed (a master key) gives all of them that ease.
bool masterKeysShareEase = true;

class Keyframe {
  int frame;
  dynamic value; // double, or List<double> for vec2 tracks
  Easing temporal;
  SpatialTangent spatialTangent;
  Keyframe({
    required this.frame,
    required this.value,
    Easing? temporal,
    SpatialTangent? spatialTangent,
  })  : temporal = temporal ?? easingPresets['linear']!,
        spatialTangent = spatialTangent ?? SpatialTangent.zero();
}

class Track {
  dynamic defaultValue; // double, or List<double>
  // only meaningful for vec2 tracks - true means keyframes form a
  // literal path in space (bezier tangents apply), false means the
  // array is just independent per-component channels (e.g. scale.x
  // and scale.y aren't "coordinates", so no motion-path concept)
  bool spatial;
  List<Keyframe> keyframes;
  bool loop;
  double? tension;
  Easing? globalEasing;

  /// Spatial tracks: the keys keep their places, but the object moves
  /// along the whole path at one speed from the first key to the last
  /// (their own times are ignored, not changed). Only the whole-path
  /// curve (globalEasing), if any, shapes the pace.
  bool constantSpeed = false;

  /// Layered keys: animation layers on top of this track's own keys, each
  /// with keys of its own; in every frame they add up (or multiply, for
  /// scale and opacity) with it - e.g. a path A..C plus a sway B..D.
  List<AnimLayer> animLayers = [];
  String? expression;
  // display-only: hides this track's keyframe diamonds from
  // LayersTimelineView. Never consulted by animation evaluation, copy/
  // paste, or any other data operation - collectLayerKeyframeFrames
  // (used by those) is deliberately untouched by this flag.
  bool hidden;

  Track(this.defaultValue, [this.spatial = false])
      : keyframes = [],
        loop = false,
        hidden = false;
}

/// One animation layer of a track (see Track.animLayers).
class AnimLayer {
  Track track;
  bool multiply;
  bool enabled;
  AnimLayer({required this.track, this.multiply = false, this.enabled = true});
}

/// Global: which animation layer edits go to - 0 the track's own keys,
/// n its n-th animation layer (where it has one).
int activeAnimLayer = 0;

Track track(dynamic defaultValue, [bool spatial = false]) =>
    Track(defaultValue, spatial);

class PathFollow {
  bool enabled;
  String? sourceLayerId;
  Track t;
  String parametrization; // "arcLength" | "vertex"
  PathFollow(
      {this.enabled = false,
      this.sourceLayerId,
      Track? t,
      this.parametrization = 'arcLength'})
      : t = t ?? track(0.0);
}

class Transform {
  Track anchor;
  Track scale;
  Track rotation;
  Track opacity;
  PathFollow pathFollow;
  Transform({
    required this.anchor,
    required this.scale,
    required this.rotation,
    required this.opacity,
    PathFollow? pathFollow,
  }) : pathFollow = pathFollow ?? PathFollow();
}

/// A text layer's shadow: a copy of the text behind it.
class TextShadowSpec {
  bool enabled;
  double dx, dy;
  String color;
  double opacity;
  /// Long shadow: the shadow joined to the letters all the way along its
  /// offset - an extruded, 3D depth look.
  bool long;

  /// Size of the shadow against the text (about the text's middle); a long
  /// shadow grows to it along its length.
  double scale;

  /// Lag: the shadow trails its text on a spring (Speed = stiffness,
  /// Bounciness 0..100 %) - a long shadow's far end only. Per letter: a
  /// spring for each animated unit.
  bool lag;
  double lagSpeed, lagBounciness;
  bool perLetter;

  /// Echo: `echoCount` copies of the text along the offset, the farthest
  /// `echoFade` (0..1) more see-through than the nearest. (Long shadow
  /// joins them up instead.)
  bool echo;
  int echoCount;

  /// Keyable (0..1).
  Track echoFade;
  TextShadowSpec(
      {this.enabled = false,
      this.dx = 4,
      this.dy = 4,
      this.color = '#000000',
      this.opacity = 0.6,
      this.long = false,
      this.scale = 1,
      this.lag = false,
      this.lagSpeed = 60,
      this.lagBounciness = 30,
      this.perLetter = false,
      this.echo = false,
      this.echoCount = 5,
      Track? echoFade})
      : echoFade = echoFade ?? Track(0.8, false);
  TextShadowSpec copy() => TextShadowSpec(
      enabled: enabled,
      dx: dx,
      dy: dy,
      color: color,
      opacity: opacity,
      long: long,
      scale: scale,
      lag: lag,
      lagSpeed: lagSpeed,
      lagBounciness: lagBounciness,
      perLetter: perLetter,
      echo: echo,
      echoCount: echoCount,
      echoFade: cloneTrack(echoFade));
}

/// Letter styles: characters [start, end) of the text drawn differently.
/// Null fields keep the text's own.
/// A part of a text (Text tab, "Parts"): letters start..end, with their
/// own look - size, colour, font, baseline shift - and their own motion,
/// on top of the whole text's: move [dx, dy], turn (degrees), scale,
/// opacity (keyable), from local frame `from` to `to` (null: always).
/// Parts later in the list draw over earlier ones where letters meet.
class TextStyleSpan {
  int start, end;

  /// Size as a multiple of the text's font size.
  double? size;
  String? color;

  /// Baseline shift, px (up is negative, like y).
  double? rise;

  /// Its own font (null: the text's).
  String? fontId;
  String name;

  /// Its own motion (null: none).
  Track? move, turn, scale, opacity;

  /// Its own effects (null: none): blur (px), letter spacing (px), shake
  /// (px, letters wander), wobble (degrees, letters rock) and a tint
  /// ([tintColor] over its colour, 0..1).
  Track? blur, spacing, shake, wobble, tint;
  String? tintColor;

  /// When it acts, local frames (null: from the start / to the end).
  int? from, to;
  TextStyleSpan(this.start, this.end,
      {this.size, this.color, this.rise, this.fontId, this.name = '', this.move, this.turn, this.scale, this.opacity, this.from, this.to,
      this.blur, this.spacing, this.shake, this.wobble, this.tint, this.tintColor});
  TextStyleSpan copy() => TextStyleSpan(start, end,
      size: size,
      color: color,
      rise: rise,
      fontId: fontId,
      name: name,
      move: move == null ? null : cloneTrack(move!),
      turn: turn == null ? null : cloneTrack(turn!),
      scale: scale == null ? null : cloneTrack(scale!),
      opacity: opacity == null ? null : cloneTrack(opacity!),
      from: from,
      to: to,
      blur: blur == null ? null : cloneTrack(blur!),
      spacing: spacing == null ? null : cloneTrack(spacing!),
      shake: shake == null ? null : cloneTrack(shake!),
      wobble: wobble == null ? null : cloneTrack(wobble!),
      tint: tint == null ? null : cloneTrack(tint!),
      tintColor: tintColor);
  bool covers(int i) => i >= start && i < end;

  /// It moves the letters (needs the per-letter pass).
  bool get moves =>
      move != null ||
      turn != null ||
      scale != null ||
      opacity != null ||
      blur != null ||
      spacing != null ||
      shake != null ||
      wobble != null ||
      tint != null;

  /// It acts at local frame `f`.
  bool activeAt(num f) => (from == null || f >= from!) && (to == null || f <= to!);
}

/// A text layer's background block: a rectangle behind the text box.
class TextBackgroundSpec {
  bool enabled;
  String color;
  double opacity;
  double padding;

  /// Rounded corners of the block, px, and the rounding's shape (0 cut,
  /// ~0.55 circle, 1 sharp).
  double radius;
  double radiusShape;
  TextBackgroundSpec(
      {this.enabled = false, this.color = '#000000', this.opacity = 0.6, this.padding = 8, this.radius = 0, this.radiusShape = 0.5523});
  TextBackgroundSpec copy() => TextBackgroundSpec(
      enabled: enabled, color: color, opacity: opacity, padding: padding, radius: radius, radiusShape: radiusShape);
}

/// Text style clipboard (Text tab: Copy style / Paste style).
TextSpec? copiedTextStyle;

/// Everything about how `from` looks onto `to` - font, size, spacing,
/// colours, outline, shadow, background, animations - its words and their
/// own coloured spans stay.
void applyTextStyle(TextSpec from, TextSpec to) {
  to
    ..fontId = from.fontId
    ..fontSize = from.fontSize
    ..letterSpacing = from.letterSpacing
    ..lineSpacing = from.lineSpacing
    ..align = from.align
    ..color = from.color
    ..knockout = from.knockout
    ..strokeWidth = from.strokeWidth
    ..strokeColor = from.strokeColor
    ..shadow = from.shadow.copy()
    ..background = from.background.copy()
    ..animators = [for (final a in from.animators) a.copy()];
}

/// Vector text (shape "text"): laid out inside the content box
/// (offset/size), wrapping to its width and centred in its height.
class TextSpec {
  String text;
  String fontId;
  double fontSize;
  double letterSpacing; // extra px between letters
  double lineSpacing; // multiple of the font's line height
  String align; // 'left' | 'center' | 'right'
  String color;

  /// See-through letters: the text cuts its shape out of everything under
  /// it (its colour then only says how much: opaque cuts fully).
  bool knockout = false;
  double strokeWidth; // letter outline, px (0 = none)
  String strokeColor;
  TextShadowSpec shadow;
  TextBackgroundSpec background;

  /// Text keys: a key's value is the text shown from its frame on (until
  /// the next key). A track like any other (the timeline moves, selects
  /// and deletes them), holding its value - never interpolated.
  Track textKeys;

  /// The keys, by frame.
  List<Keyframe> get keys => textKeys.keyframes;

  /// Letter styles, later ones over earlier ones.
  List<TextStyleSpan> spans;

  /// Auto box: the box grows (and shrinks) to fit the text as it's typed.
  bool autoBox;

  /// Text animators (text/text_animators.dart), applied in order.
  List<TextAnimator> animators;

  /// Text groups: letters between two `groupChar`s ("#T#ext") are a group
  /// a child layer can take over (moved, animated, given effects) while
  /// still part of the text. The markers never show.
  bool groupsEnabled;
  String groupChar;

  /// Letters (code point index in the shown text) left out of the drawing
  /// - kept in the layout, so the rest doesn't move. Not saved: the
  /// renderer sets it for a text whose groups are drawn by their layers.
  Set<int> hidden = const {};
  TextSpec({
    this.groupsEnabled = false,
    this.groupChar = '#',
    List<TextAnimator>? animators,
    this.autoBox = false,
    Track? textKeys,
    List<TextStyleSpan>? spans,
    this.text = 'Text',
    this.fontId = 'roboto',
    this.fontSize = 48,
    this.letterSpacing = 0,
    this.lineSpacing = 1.2,
    this.align = 'center',
    this.color = '#ffffff',
    this.strokeWidth = 0,
    this.strokeColor = '#000000',
    TextShadowSpec? shadow,
    TextBackgroundSpec? background,
  })  : shadow = shadow ?? TextShadowSpec(),
        background = background ?? TextBackgroundSpec(),
        textKeys = textKeys ?? Track('', false),
        animators = animators ?? [],
        spans = spans ?? [];

  /// The text shown at local frame `f`: the last key at or before it,
  /// else [text].
  String textAt(num f) {
    var out = text;
    for (final k in keys) {
      if (k.frame <= f) out = k.value as String;
    }
    return out;
  }

  /// The key in effect at local frame `f` (null: the base text shows).
  Keyframe? keyAt(num f) {
    Keyframe? out;
    for (final k in keys) {
      if (k.frame <= f) out = k;
    }
    return out;
  }

  /// Sets the text at local frame `f`: the key there (or in effect), else
  /// the base text.
  void setTextAt(num f, String v) {
    final k = keyAt(f);
    k == null ? text = v : k.value = v;
  }

  /// A text key at local frame `f` with what shows there now (kept as is
  /// when one is already there).
  void addKey(int f) {
    if (keys.any((k) => k.frame == f)) return;
    keys
      ..add(Keyframe(frame: f, value: textAt(f)))
      ..sort((a, b) => a.frame.compareTo(b.frame));
  }

  /// This spec with the text of local frame `f` (itself when it's the same).
  TextSpec atFrame(num f) {
    var t = textAt(f);
    if (groupsEnabled) t = parseTextGroups(t, groupChar).text;
    return t == text ? this : (copy()..text = t);
  }

  /// The groups at local frame `f`: [start, end) code point ranges of the
  /// shown text (none unless groups are on).
  List<(int, int)> groupsAt(num f) => groupsEnabled ? parseTextGroups(textAt(f), groupChar).groups : const [];

  TextSpec copy() => TextSpec(
        groupsEnabled: groupsEnabled,
        groupChar: groupChar,
        autoBox: autoBox,
        animators: [for (final a in animators) a.copy()],
        textKeys: cloneTrack(textKeys),
        spans: [for (final s in spans) s.copy()],
        text: text,
        fontId: fontId,
        fontSize: fontSize,
        letterSpacing: letterSpacing,
        lineSpacing: lineSpacing,
        align: align,
        color: color,
        strokeWidth: strokeWidth,
        strokeColor: strokeColor,
        shadow: shadow.copy(),
        background: background.copy(),
      )
        ..hidden = hidden
        ..knockout = knockout;
}

/// "#T#ext" -> "Text" and its groups as [start, end) code point ranges
/// of the result. Every `marker` toggles a group; one left open runs to
/// the end. Empty groups are dropped.
({String text, List<(int, int)> groups}) parseTextGroups(String raw, String marker) {
  final m = marker.runes.isEmpty ? null : marker.runes.first;
  if (m == null || !raw.runes.contains(m)) return (text: raw, groups: const []);
  final out = StringBuffer();
  final groups = <(int, int)>[];
  var n = 0;
  int? open;
  for (final r in raw.runes) {
    if (r == m) {
      if (open == null) {
        open = n;
      } else {
        if (n > open) groups.add((open, n));
        open = null;
      }
      continue;
    }
    out.writeCharCode(r);
    n++;
  }
  if (open != null && n > open) groups.add((open, n));
  return (text: out.toString(), groups: groups);
}

class Content {
  String shape; // "rect" | "circle" | "triangle" | "ngon" | "polygon" | "image" | "video" | "text" | "compound"
  List<double> offset;
  List<double> size;
  int? sides;
  List<List<double>>? points; // only for shape == "polygon"

  // image content (only meaningful when shape == "image"; geometrically an
  // image behaves exactly like "rect" - offset/size place it the same way, see
  // geometry/shapes.dart's isRectLikeShape - only the render backend treats it
  // differently, drawing the decoded bitmap instead of a solid fill). (image
  // import), with the follow-up answer (support both storage modes, user's
  // choice) - so a project can EITHER embed the source bytes directly
  // (portable, larger file) or reference an external file path (smaller file,
  // breaks if the file moves) per image, not a single global policy.
  String? imageSourceType; // "embedded" | "file"
  String?
      imageData; // base64-encoded source bytes, when imageSourceType == "embedded"
  String? imagePath; // filesystem path, when imageSourceType == "file"
  int? imageNaturalWidth; // the source image's own pixel dimensions,
  int?
      imageNaturalHeight; // used to size a freshly-imported layer at its true aspect ratio

  /// shape "text": the text and its style (the box is offset/size).
  TextSpec? text;

  // ===== shape "video" (placed like an image: offset/size) =====
  /// The app-owned copy of the source file.
  String? videoPath;

  /// Identifies the extracted-frame cache (and the app-owned copy).
  String? videoAssetId;

  /// Seconds into the source where the layer's local frame 0 starts - so
  /// a split's right half, or a trimmed start, continue the clip instead
  /// of restarting it. Video and audio alike (see isTimedMedia).
  double sourceIn;

  /// Video: plays its stretch of the clip backwards (Reverse tab).
  bool playReversed = false;

  /// Frame rate of the extracted (constant-rate) frames, and how many.
  double? videoFps;
  int? videoFrameCount;

  /// Frames were extracted keeping transparency (PNG cache).
  bool videoAlpha;

  // ===== shape "audio" (no picture; size [0, 0]) =====
  /// The app-owned copy of the source file.
  String? audioPath;

  /// Identifies the decoded sound (PCM + waveform) and the copy.
  String? audioAssetId;

  /// Length of the whole source, seconds.
  double? audioDuration;

  /// Loudness 0..2 (1 = as recorded), animatable; set for audio only.
  Track? volume;

  bool audioMuted;

  /// shape "compound": closed outlines filled together (non-zero), e.g.
  /// text turned into a shape - letters with holes. Content-local, inside
  /// the offset/size box.
  List<List<List<double>>>? contours;

  /// Merged shapes: each contour's own colour (null: the layer's).
  List<String?>? contourColors;

  /// Merged shapes: true where a contour goes with the one before it (one
  /// shape's holes, after masks and cuts) - filled together, non-zero.
  List<bool>? contourJoin;

  // ===== shape "line" with nodes (model/line_path.dart) =====
  /// The points of a vector line (null: a legacy thin-rectangle line).
  List<LineNode>? lineNodes;

  /// Stroke width, px.
  double lineWidth = 4;

  /// Closed into a loop (the last point joins the first).
  bool lineClosed = false;

  /// Filled (a closed line as a shape).
  bool lineFilled = false;

  /// Not drawn (only an editor guide line shows where it is).
  bool lineHidden = false;

  /// Can't be moved on the stage.
  bool lineLocked = false;

  /// The stage shows the shape's square box instead of the line's points.
  bool lineShowBox = false;

  /// Reveal: where the drawn part starts / ends, fractions of the length.
  Track? lineTrimStart, lineTrimEnd;

  /// A rect's own grid (an editor guide, never drawn into the picture):
  /// columns and rows, or null for none. Centre to centre snaps onto its
  /// crossings.
  int? gridCols, gridRows;

  /// A filled line: what the fill reaches - 'outer' (to the outer edge of
  /// its width: the line keeps its thickness and the shape of its
  /// points), 'points' (through the points' centres only, the old way) or
  /// 'inner' (to the inner edge: the width eats into the fill).
  String lineFillMode = 'outer';

  /// An open line's ends: 'round' | 'square' | 'triangle'.
  String lineCap = 'round';

  /// Square ends: how round their corners are (0 sharp - 1 a half circle).
  double lineCapRound = 0;

  /// Square ends: the corner rounding's shape (0 cut, ~0.55 circle, 1 sharp).
  double lineCapShape = 0.5523;

  /// Triangle ends: how far the tip reaches past the point, in half widths
  /// (1: a right angle at the tip; more: sharper and longer).
  double lineCapLength = 1;

  /// Where the line turns at a point: 'round' | 'miter' (the edges carry
  /// on until they meet) | 'bevel' (cut straight).
  String lineJoin = 'round';

  /// Miter: the longest a corner may reach, in half widths (a very sharp
  /// turn is cut straight beyond it).
  double lineMiterLimit = 4;

  /// Bezier: dragging one handle of a point turns the other the opposite
  /// way; with this also the same length.
  bool lineMirrorLength = true;

  /// Media (image file, video, sound): SHA-256 of the source file, so a
  /// moved or shared project can find the same file by content (see
  /// resolveMediaPath).
  String? mediaHash;

  // ===== shape "projectRef": another saved project, rendered live (see
  // model/project_ref.dart) =====
  /// The source project's stable id.
  String? refProjectId;

  /// Initial size: "contain" (fits the frame) | "original".
  String refFit = 'contain';

  /// After the source's end: "hold" | "loop" | "hide".
  String refEndBehavior = 'hide';

  /// The source revision last acknowledged here ("updated" badge).
  int refLastSeenRevision = 0;

  /// Unlinked: a frozen copy of the source's file (it no longer updates).
  Map<String, dynamic>? refEmbedded;

  // ===== shape "textGroup": a group of its parent text's letters (text
  // groups, "#T#ext"), drawn by this layer, shifted by `offset` =====
  /// Which group (in order) of the parent's text.
  int textGroup = 0;

  /// A stand-in for media (an AI-written project): a labelled box to
  /// replace with a picture or video (Replace content).
  bool placeholder = false;

  /// The group's middle in the parent's content px when it was made: the
  /// layer sits there (its pivot) and draws the letters shifted back.
  List<double> textGroupPivot = const [0, 0];

  Content({
    required this.shape,
    required this.offset,
    required this.size,
    this.sides,
    this.points,
    this.imageSourceType,
    this.imageData,
    this.imagePath,
    this.imageNaturalWidth,
    this.imageNaturalHeight,
    this.text,
    this.contours,
    this.videoPath,
    this.videoAssetId,
    this.sourceIn = 0,
    this.videoFps,
    this.videoFrameCount,
    this.videoAlpha = false,
    this.audioPath,
    this.audioAssetId,
    this.audioDuration,
    this.volume,
    this.audioMuted = false,
  });
}

class Mask {
  bool enabled;
  /// How it combines with the masks above it (R) - logic on "seen":
  /// "add" R or S, "subtract" R and not S, "intersect" R and S,
  /// "exclude" R xor S, "implication" not R or S, "equivalence" R iff S.
  String mode;
  String? sourceLayerId;

  /// A text source: only this part of it (Text tab "Parts"; null: all).
  int? sourcePart;

  /// More sources: the mask's shape is all of them together (with
  /// [sourceLayerId]).
  List<String> moreSources;

  /// Every source layer of the mask (the first, then the others).
  List<String> get sourceIds => [if (sourceLayerId != null) sourceLayerId!, ...moreSources];

  /// The source's shape turned inside out (S becomes everything but S).
  bool invert;
  Track feather;

  /// How far the feather may reach past the mask's edge, 0..1 of its
  /// spread: 1 = as far out as in (a soft edge centred on the outline),
  /// 0 = not at all (the gradient stays inside the shape).
  double featherOutside;

  /// When it works: local frames [start, end] of its layer, or null for
  /// the whole layer.
  List<int>? range;
  Mask(
      {this.enabled = true,
      this.mode = 'add',
      this.sourceLayerId,
      Track? feather,
      this.featherOutside = 1,
      this.invert = false,
      this.range,
      List<String>? moreSources,
      this.sourcePart})
      : feather = feather ?? track(0.0),
        moreSources = moreSources ?? [];

  /// Whether it works at local frame `f`.
  bool activeAt(num f) => range == null || (f >= range![0] && f <= range![1]);
}

/// Mask regions: up to [maxRegionSources] source layers (A, B, C...) split
/// the stage into regions by signature - which sources a point is inside
/// (bit i set: inside source i). Each region has its own opacity (0..1,
/// keys ok); the outside of everything (signature 0) is a region too.
class MaskRegions {
  bool enabled;
  List<String> sources;

  /// signature -> opacity. A missing one is hidden (0).
  Map<int, Track> opacity;

  /// Soft edge per source (px), by source index.
  List<double> feather;

  /// Number the overlap pieces as the animation makes them (vector
  /// sources only - see region_episodes.dart).
  bool numbered;

  /// "When a region appears / disappears -> a region's opacity".
  List<RegionCommand> commands;
  MaskRegions(
      {this.enabled = true,
      List<String>? sources,
      Map<int, Track>? opacity,
      List<double>? feather,
      this.numbered = false,
      List<RegionCommand>? commands})
      : sources = sources ?? [],
        opacity = opacity ?? {},
        feather = feather ?? [],
        commands = commands ?? [];

  MaskRegions copy() => MaskRegions(
      enabled: enabled,
      sources: [...sources],
      opacity: {for (final e in opacity.entries) e.key: cloneTrack(e.value)},
      feather: [...feather],
      numbered: numbered,
      commands: [for (final c in commands) c.copy()]);

  /// Source i's soft edge (0 when not set).
  double featherOf(int i) => i < feather.length ? feather[i] : 0;

  /// Every signature of the current sources (2^N).
  int get signatureCount => 1 << sources.length;
}

const maxRegionSources = 6;

/// A shape layer with mask regions is one of its own shapes (its regions
/// are where it is: inside it alone, its overlaps, Outer). Older regions
/// listed only the other shapes: the layer goes in last and every region
/// keeps what it showed (and the commands their target), so nothing
/// looks different. Pictures, video and groups stay content masked by the
/// others. Returns whether it changed anything.
bool ensureRegionSelf(Layer layer) {
  final mr = layer.maskRegions;
  if (mr == null || mr.sources.contains(layer.id) || mr.sources.length >= maxRegionSources) return false;
  final shape = layer.content.shape;
  if (const {'image', 'video', 'projectRef', 'audio', 'camera', 'null'}.contains(shape)) return false;
  if (layer.precompose ?? false) return false;
  final bit = 1 << mr.sources.length;
  final old = mr.opacity;
  mr.sources.add(layer.id);
  mr.opacity = {
    for (var sig = 0; sig < (bit << 1); sig++)
      if (old[sig & (bit - 1)] case final t?) sig: cloneTrack(t)
  };
  for (final c in mr.commands) {
    c.targetSig |= bit;
  }
  return true;
}

/// A rule on mask regions: when region `whenSig` (piece `whenNumber`, or
/// any piece) appears or disappears, region `targetSig` (piece
/// `targetNumber`, or the whole region) goes to `opacity` over `frames`
/// (0: at once) with `ease`.
class RegionCommand {
  String when; // 'appears' | 'disappears'
  int whenSig;
  int? whenNumber;
  int targetSig;
  int? targetNumber;
  double opacity;
  int frames;
  String ease;

  /// Gradually (over `frames`, with `ease`); off (the default): at once.
  bool timed;
  RegionCommand(
      {this.when = 'appears',
      this.whenSig = 3,
      this.whenNumber,
      this.targetSig = 3,
      this.targetNumber,
      this.opacity = 0,
      this.frames = 10,
      this.ease = 'easeInOut',
      this.timed = false});

  RegionCommand copy() => RegionCommand(
      when: when,
      whenSig: whenSig,
      whenNumber: whenNumber,
      targetSig: targetSig,
      targetNumber: targetNumber,
      opacity: opacity,
      frames: frames,
      ease: ease,
      timed: timed);

  Map<String, dynamic> toJson() => {
        'when': when,
        'whenSig': whenSig,
        if (whenNumber != null) 'whenNumber': whenNumber,
        'targetSig': targetSig,
        if (targetNumber != null) 'targetNumber': targetNumber,
        'opacity': opacity,
        'frames': frames,
        'ease': ease,
        'timed': timed,
      };

  static RegionCommand fromJson(Map j) => RegionCommand(
        when: j['when'] as String? ?? 'appears',
        whenSig: (j['whenSig'] as num?)?.toInt() ?? 3,
        whenNumber: (j['whenNumber'] as num?)?.toInt(),
        targetSig: (j['targetSig'] as num?)?.toInt() ?? 3,
        targetNumber: (j['targetNumber'] as num?)?.toInt(),
        opacity: (j['opacity'] as num?)?.toDouble() ?? 0,
        frames: (j['frames'] as num?)?.toInt() ?? 10,
        ease: j['ease'] as String? ?? 'easeInOut',
        // saved before it was written out: on then.
        timed: j['timed'] != false,
      );
}

/// "A·¬B" for a signature (letters for the sources, outside = ¬).
String regionSignatureLabel(int sig, int sourceCount) {
  if (sourceCount == 0) return 'everything';
  return [
    for (var i = 0; i < sourceCount; i++) '${(sig >> i) & 1 == 1 ? '' : '¬'}${String.fromCharCode(65 + i)}'
  ].join('·');
}

const maskModes = ['add', 'subtract', 'intersect', 'exclude', 'implication', 'equivalence'];

/// Whether the first mask in this mode starts from everything shown
/// (else from nothing): "all minus S", "all and S"...
bool maskStartsFull(String mode) =>
    mode == 'subtract' || mode == 'intersect' || mode == 'implication' || mode == 'equivalence';

/// one instance of a registered effect on a layer's effectStack. params
/// values are either a Track (animatable) or a plain value (rows/cols on
/// mesh_warp, baseAxis enum on bend_arc) - same dynamic shape as the JS
/// `inst.params` object.
class EffectInstance {
  String id;
  String effectId;
  bool enabled;
  Map<String, dynamic> params;
  EffectInstance(
      {required this.id,
      required this.effectId,
      this.enabled = true,
      Map<String, dynamic>? params})
      : params = params ?? {};
}

class MotionBlur {
  bool enabled;
  double shutterAngle;
  int samples;
  MotionBlur({this.enabled = false, this.shutterAngle = 180, this.samples = 8});
}

class Wiggle {
  bool enabled;
  double speed;
  double amplitude;
  double smoothness;
  double? wiggleSeed; // layer._wiggleSeed
  Wiggle(
      {this.enabled = false,
      this.speed = 30,
      this.amplitude = 20,
      this.smoothness = 70,
      this.wiggleSeed});
}

class Pendulum {
  bool enabled;
  double frequency;
  double damping;
  double sensitivity;
  Track pivotOffset;
  double maxAngle;
  double freeze;
  bool rotateWithLine;

  /// The weight: the line's other end (content-local), what hangs from the
  /// grip point and decides which way the lever points. Null: the middle
  /// of the content.
  List<double>? weightPoint;
  Pendulum({
    this.enabled = false,
    this.frequency = 20,
    this.damping = 50,
    this.sensitivity = 50,
    Track? pivotOffset,
    this.maxAngle = 40,
    this.freeze = 60,
    this.rotateWithLine = true,
    this.weightPoint,
  }) : pivotOffset = pivotOffset ?? track([0.0, 0.0], true);
}

/// Chroma key (image layers): pixels close to `color` become
/// transparent. `strength` is how close counts as the key, `softness`
/// the width of the soft edge; with scope 'region' only the inside of
/// `region` (a closed outline, points as fractions 0..1 of the image) is
/// keyed.
class ChromaKey {
  bool enabled;
  String color;
  double strength;
  double softness;
  String scope; // 'whole' | 'region'
  List<List<double>> region;

  /// Only the colour connected to the picked point (`seed`, image
  /// fractions) is keyed - like a magic wand: the same colour elsewhere,
  /// cut off by other colours (e.g. inside an object), stays.
  bool contiguous = false;
  List<double>? seed;

  /// Grows the keyed area by this many pixels before the edge (eats a
  /// fringe left around the cut-out).
  double expand = 0;

  /// Keeps only the key colour instead of removing it.
  bool invert = false;

  /// Softens the cut's edge over this many pixels.
  double feather = 0;

  /// Keys already submitted ("removed colours"): each is applied before
  /// the one being edited; `enabled` off hides it without deleting it.
  List<ChromaKey> applied;
  ChromaKey({
    this.enabled = false,
    this.color = '#00ff00',
    this.strength = 0.4,
    this.softness = 0.2,
    this.scope = 'whole',
    List<List<double>>? region,
    List<ChromaKey>? applied,
  })  : region = region ?? [],
        applied = applied ?? [];

  /// Whether anything is keyed at all (the edited key or a submitted one).
  bool get active => enabled || applied.any((k) => k.enabled);

  ChromaKey copy() => ChromaKey(
      enabled: enabled,
      color: color,
      strength: strength,
      softness: softness,
      scope: scope,
      region: [for (final p in region) [...p]],
      applied: [for (final k in applied) k.copy()])
    ..contiguous = contiguous
    ..seed = seed == null ? null : [...seed!]
    ..expand = expand
    ..invert = invert
    ..feather = feather;
}

/// "Time quantize": plays this layer at its own, lower frame rate - its
/// animation (and everything evaluated from it) holds each pose for
/// 60/fps frames, a stop-motion look.
/// Contour physics (Contour tab, Physics): layers with Collide on in the
/// same group can't overlap - one animated into another pushes it (see
/// physics/contour_physics.dart).
class PhysicsSettings {
  bool collide;
  String group;
  String role; // 'pushable' | 'immovable'
  double weight; // 0.1..10, how a push splits between two pushables
  double gap; // px: contours count as touching this far apart

  /// Inertia 0..1: a pushed object keeps sliding after the push ends,
  /// keeping this much of its speed each frame (0: stops at once).
  double inertia;

  /// Soft push 0..1: overlapping objects part over a few frames instead of
  /// at once - the deeper they are in, the harder they push; nearly apart,
  /// gently (0: hard, as before). A negative gap lets them sink in that
  /// far first.
  double softness;

  /// Leash: pulled toward a point (frame px) like on a spring, once
  /// farther from it than `leashLength`; `leashStrength` 0..1 how hard.
  bool leash;
  List<double> leashPoint;
  double leashLength;
  double leashStrength;
  PhysicsSettings(
      {this.collide = false,
      this.group = '1',
      this.role = 'pushable',
      this.weight = 1,
      this.gap = 0,
      this.inertia = 0,
      this.softness = 0,
      this.leash = false,
      List<double>? leashPoint,
      this.leashLength = 0,
      this.leashStrength = 0.2})
      : leashPoint = leashPoint ?? [0, 0];
  bool get immovable => role == 'immovable';
  PhysicsSettings copy() => PhysicsSettings(
      collide: collide,
      group: group,
      role: role,
      weight: weight,
      gap: gap,
      inertia: inertia,
      softness: softness,
      leash: leash,
      leashPoint: [...leashPoint],
      leashLength: leashLength,
      leashStrength: leashStrength);
  Map<String, dynamic> toJson() => {
        'collide': collide,
        'group': group,
        'role': role,
        'weight': weight,
        'gap': gap,
        if (inertia > 0) 'inertia': inertia,
        if (softness > 0) 'softness': softness,
        if (leash) 'leash': {'point': leashPoint, 'length': leashLength, 'strength': leashStrength},
      };
  static PhysicsSettings fromJson(Map<String, dynamic> j) {
    final l = j['leash'] as Map?;
    return PhysicsSettings(
      collide: j['collide'] as bool? ?? false,
      group: j['group'] as String? ?? '1',
      role: j['role'] as String? ?? 'pushable',
      weight: (j['weight'] as num?)?.toDouble() ?? 1,
      gap: (j['gap'] as num?)?.toDouble() ?? 0,
      inertia: (j['inertia'] as num?)?.toDouble() ?? 0,
      softness: (j['softness'] as num?)?.toDouble() ?? 0,
      leash: l != null,
      leashPoint: l == null ? null : [for (final v in l['point'] as List) (v as num).toDouble()],
      leashLength: (l?['length'] as num?)?.toDouble() ?? 0,
      leashStrength: (l?['strength'] as num?)?.toDouble() ?? 0.2,
    );
  }
}

class TimeQuantize {
  bool enabled;
  double fps;
  TimeQuantize({this.enabled = false, this.fps = 12});
}

/// A cut through a layer made by "detach a piece": a closed outline in
/// the layer's content-local space. `inside` keeps only what is inside it
/// (the detached piece), otherwise only what is outside (the layer it was
/// taken from). Applied like crop, at render time.
class PieceClip {
  List<List<double>> points;
  bool inside;
  PieceClip({required this.points, required this.inside});
  PieceClip copy() => PieceClip(points: [for (final p in points) [...p]], inside: inside);
}

/// One glow of a gradient fill: a point, or a line between two points,
/// that lights the shape in its own colour, strongest on itself and
/// fading out to nothing at `radius` from it. Positions are fractions of
/// the content's bounding box (0..1, may go outside), `radius` a fraction
/// of the box's larger side, `strength` 0..1 - all animatable.
class GlowEmitter {
  String id;
  String kind; // 'point' | 'line'
  String color;
  bool enabled;
  Track position;
  Track end; // the line's second end (unused for a point)
  Track radius;
  Track strength;
  GlowEmitter({
    required this.id,
    this.kind = 'point',
    this.color = '#ffffff',
    this.enabled = true,
    Track? position,
    Track? end,
    Track? radius,
    Track? strength,
  })  : position = position ?? track([0.5, 0.5], true),
        end = end ?? track([0.8, 0.5], true),
        radius = radius ?? track(0.5),
        strength = strength ?? track(1.0);

  GlowEmitter copy() => GlowEmitter(
        id: id,
        kind: kind,
        color: color,
        enabled: enabled,
        position: cloneTrack(position),
        end: cloneTrack(end),
        radius: cloneTrack(radius),
        strength: cloneTrack(strength),
      );
}

/// A shape's fill: its plain colour (Layer.color) or, with `gradient` on,
/// that colour as the base with the glows lit over it, in list order (a
/// later one draws over an earlier one).
class ShapeFill {
  bool gradient;
  List<GlowEmitter> glows;

  /// Rounded corners of a shape, px (0: sharp).
  double cornerRadius;

  /// The rounded corners stay circles however the layer is scaled (off:
  /// they stretch with it into ovals).
  bool cornersKeepRound;

  /// The rounding's shape: 0 cut straight, ~0.55 a circle, 1 sharp.
  double cornerShape;

  /// Corners pointing inward (more than 180 degrees inside - a merged
  /// shape's joins, a polygon's notches) rounded by adding to the shape,
  /// px (0: sharp).
  double outerRadius;

  /// A shape's drop shadow (TextShadowSpec: offset, colour, opacity, long,
  /// scale) - off unless enabled.
  TextShadowSpec shadow;

  /// A paint gradient over the whole shape (an imported SVG's
  /// linear/radial gradient): it replaces the colour, its stops' opacity
  /// included. Null: the layer's own colour.
  FillGradient? paint;
  ShapeFill(
      {this.gradient = false,
      List<GlowEmitter>? glows,
      this.cornerRadius = 0,
      this.cornersKeepRound = true,
      this.cornerShape = 0.5523,
      this.outerRadius = 0,
      TextShadowSpec? shadow,
      this.paint})
      : glows = glows ?? [],
        shadow = shadow ?? TextShadowSpec();
  bool get active => gradient && glows.any((g) => g.enabled);
  ShapeFill copy() => ShapeFill(
      gradient: gradient,
      glows: [for (final g in glows) g.copy()],
      cornerRadius: cornerRadius,
      cornersKeepRound: cornersKeepRound,
      cornerShape: cornerShape,
      outerRadius: outerRadius,
      shadow: shadow.copy(),
      paint: paint?.copy());
}

/// A gradient stop: where (0..1), colour "#rrggbb", opacity 0..1.
class GradientStop {
  double offset;
  String color;
  double opacity;
  GradientStop(this.offset, this.color, [this.opacity = 1]);
  GradientStop copy() => GradientStop(offset, color, opacity);
}

/// A linear (x1 y1 -> x2 y2) or radial (centre cx cy, radius r) gradient,
/// in its own space; `matrix` [a b c d e f] maps that space into the
/// layer's content px, so it moves, turns and scales with the layer.
/// `spread`: 'pad' | 'reflect' | 'repeat'.
class FillGradient {
  String type;
  double x1, y1, x2, y2, cx, cy, r;
  List<double> matrix;
  List<GradientStop> stops;
  String spread;
  FillGradient({
    this.type = 'linear',
    this.x1 = 0,
    this.y1 = 0,
    this.x2 = 1,
    this.y2 = 0,
    this.cx = 0.5,
    this.cy = 0.5,
    this.r = 0.5,
    List<double>? matrix,
    List<GradientStop>? stops,
    this.spread = 'pad',
  })  : matrix = matrix ?? [1, 0, 0, 1, 0, 0],
        stops = stops ?? [];
  FillGradient copy() => FillGradient(
      type: type,
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      cx: cx,
      cy: cy,
      r: r,
      matrix: List<double>.from(matrix),
      stops: [for (final s in stops) s.copy()],
      spread: spread);
}

/// A dependency: one property of this layer moves with one property of
/// another (the source) - its change since this layer's first frame,
/// times `factor`, is added. 'x' / 'y' (px), 'rotation' (degrees),
/// 'scaleX' / 'scaleY', 'opacity'.
class PropLink {
  bool enabled;
  String? sourceId;
  String from;
  String to;
  double factor;

  /// The source's value when the link was made: its change from this
  /// moves the layer, so a moved source shows at once. Null (older files):
  /// measured from the layer's first frame instead.
  double? base;
  PropLink({this.enabled = true, this.sourceId, this.from = 'x', this.to = 'x', this.factor = 1, this.base});
  PropLink copy() => PropLink(enabled: enabled, sourceId: sourceId, from: from, to: to, factor: factor, base: base);
}

const linkProps = ['x', 'y', 'rotation', 'scaleX', 'scaleY', 'opacity'];

/// Cut by layer: this layer's shape combined with another layer's (the
/// cutter), the cutter grown by `gap` first - a live boolean.
class CutByLayer {
  bool enabled;
  String? cutterId;

  /// 'subtract' | 'intersect' | 'union' | 'exclude'.
  String mode;

  /// px the cutter grows (negative: shrinks) before the boolean; keyable.
  Track gap;

  /// The grown cutter's corners: 'miter' | 'round' | 'bevel'.
  String join;

  /// The cutter itself isn't drawn - only what it does here.
  bool hideCutter;

  /// The cut (and its gap) works only while the cutter itself touches
  /// this layer; apart, nothing is cut even when the gap would reach.
  bool onlyWhenTouching;
  CutByLayer({
    this.onlyWhenTouching = false,
    this.enabled = true,
    this.cutterId,
    this.mode = 'subtract',
    Track? gap,
    this.join = 'miter',
    this.hideCutter = false,
  }) : gap = gap ?? Track(0.0, false);
  CutByLayer copy() => CutByLayer(
      enabled: enabled,
      cutterId: cutterId,
      mode: mode,
      gap: cloneTrack(gap),
      join: join,
      hideCutter: hideCutter,
      onlyWhenTouching: onlyWhenTouching);
}

/// Colour filters on a layer, applied to everything it draws.
class LayerFilters {
  /// Negative: 0 (off) .. 1 (colours inverted), keyable.
  Track negative;
  LayerFilters({Track? negative}) : negative = negative ?? Track(0.0, false);
  bool get any => negative.defaultValue != 0.0 || negative.keyframes.isNotEmpty;
  LayerFilters copy() => LayerFilters(negative: cloneTrack(negative));
}

/// "Swing": the layer rocks around its rotation, a sine between
/// `minAngle` and `maxAngle` (degrees, added to its own rotation) at
/// `frequency` Hz starting at `phase` degrees; `damping` (per second)
/// makes the swing die down gradually toward the middle of the range.
class Swing {
  bool enabled;
  double minAngle;
  double maxAngle;
  double frequency;
  double phase;
  double damping;
  Swing({
    this.enabled = false,
    this.minAngle = -20,
    this.maxAngle = 20,
    this.frequency = 1,
    this.phase = 0,
    this.damping = 0,
  });

  Swing copy() => Swing(
      enabled: enabled,
      minAngle: minAngle,
      maxAngle: maxAngle,
      frequency: frequency,
      phase: phase,
      damping: damping);
}

/// The swing angle (degrees) at the layer's own local frame.
double evaluateSwing(Swing s, num localFrame) {
  if (!s.enabled) return 0;
  final t = localFrame / fps;
  final center = (s.minAngle + s.maxAngle) / 2;
  final amp = (s.maxAngle - s.minAngle) / 2;
  final decay = s.damping <= 0 ? 1.0 : math.exp(-s.damping * t);
  return center + amp * decay * math.sin(2 * math.pi * s.frequency * t + s.phase * math.pi / 180);
}

/// Loop (timeline): past its end the layer starts over and keeps
/// repeating until `layer.loopUntil` (a global frame), or with no limit
/// (to the end of the timeline).
bool layerLoops(Layer layer) => layer.loopEnabled && layer.durationFrames > 0;

/// The end of the layer on the timeline including its repeats - null
/// when it loops without a limit.
int? layerVisibleEnd(Layer layer) {
  final end = layer.startFrame + layer.durationFrames;
  if (!layerLoops(layer)) return end;
  final until = layer.loopUntil;
  return until == null ? null : math.max(end, until);
}

/// `globalFrame` mapped into the layer's first pass when it falls on one
/// of its loop repeats; unchanged otherwise.
num loopedFrame(Layer layer, num globalFrame) {
  if (!layerLoops(layer)) return globalFrame;
  final end = layer.startFrame + layer.durationFrames;
  if (globalFrame < end) return globalFrame;
  final until = layer.loopUntil;
  if (until != null && globalFrame >= until) return globalFrame;
  return layer.startFrame + (globalFrame - layer.startFrame) % layer.durationFrames;
}

/// The layer's own frame (0..duration) at `globalFrame`, loops included -
/// what edits at the playhead write to.
double layerLocalFrame(Layer layer, num globalFrame) =>
    math.min(layer.durationFrames, math.max(0, loopedFrame(layer, globalFrame) - layer.startFrame)).toDouble();

/// The frame `layer` is actually evaluated at for `globalFrame`: the
/// frame itself (mapped into the first pass on a loop repeat), or - with
/// time quantize on - the start of the step it
/// falls in, counted from the layer's own start.
/// Whether the Effects-tab entry `id` acts at `localFrame` (its own time
/// range, if it has one).
bool effectActiveAt(Layer layer, String id, num localFrame) {
  final r = layer.effectRanges[id];
  return r == null || (localFrame >= r[0] && localFrame <= r[1]);
}

num layerTimeFrame(Layer layer, num globalFrame) {
  globalFrame = loopedFrame(layer, globalFrame);
  final q = layer.timeQuantize;
  if (!effectActiveAt(layer, 'timeQuantize', globalFrame - layer.startFrame)) return globalFrame;
  if (!q.enabled || q.fps <= 0 || q.fps >= fps) return globalFrame;
  final step = fps / q.fps;
  final local = globalFrame - layer.startFrame;
  return layer.startFrame + (local / step).floor() * step;
}

class Layer {
  String id;
  String name;
  String? parentId;
  int startFrame;
  int durationFrames;
  Transform transform;
  Content content;
  List<Mask> masks;
  List<EffectInstance> effectStack;
  String? color;
  String renderMode; // "fill" | "outline"
  bool hidden;
  MotionBlur motionBlur;
  Wiggle wiggle;
  Pendulum pendulum;
  TimeQuantize timeQuantize;
  PhysicsSettings physics;
  ChromaKey chromaKey;
  List<String>? groupedChildren; // set only on a group null
  bool? precompose;
  String?
      preGroupParentId; // child._preGroupParentId, set only mid group/ungroup

  /// Crop: insets [left, top, right, bottom] as fractions of the content's
  /// bounding box (0 = uncropped). Applied at render time only - the
  /// content, its effects and their handles keep the full box.
  List<double> crop;

  /// Crop aspect lock: 'free' | 'original' | '1:1' | '4:3' | '16:9' | '9:16'.
  String cropAspect;

  /// Mirror: flips the content about its own centre.
  bool mirrorX;
  bool mirrorY;

  /// Origami folds keep their angles on screen when the layer is
  /// stretched (its scale does not skew them).
  bool foldsIgnoreScale;

  /// The Effects tab's list order: effect-instance ids plus 'motionBlur',
  /// 'wiggle' and 'pendulum' (see effectPanelEntries). UI-only - the
  /// render order of geometry effects is effectStack's own.
  List<String> effectPanelOrder;

  /// Effect time ranges: an Effects-tab entry id (an effect instance's id,
  /// or 'motionBlur' / 'wiggle' / 'pendulum' / 'swing' / 'timeQuantize')
  /// -> [start, end] local frames it is active in. Missing: the whole
  /// layer.
  Map<String, List<int>> effectRanges = {};

  /// Parenting for a time only (global frames, null: open-ended): before
  /// `parentFrom` and after `parentUntil` the parent counts as it was at
  /// that frame - so the child is free there, and nothing jumps where
  /// the link starts or ends.
  int? parentFrom, parentUntil;

  /// Mirror: this layer's shape becomes a window showing, flipped, what
  /// the layer `mirrorSourceId` (the base) covers in the layers below.
  /// Moving the base changes what is reflected; moving the mirror moves
  /// the reflection along. A mirror shows the mirrors below it too (a few
  /// levels deep).
  String? mirrorSourceId;

  /// A mirror's probe: a copy of the mirror's shape that is never drawn -
  /// only its outline on the stage. What lies under it shows in the
  /// mirror.
  bool mirrorProbe = false;

  /// A mirror showing every layer under its copy (not only the layers
  /// below it).
  bool mirrorAllLayers = false;

  /// Locked: it can't be picked or moved on the stage (its panels still
  /// edit it).
  bool locked = false;

  /// Parenting keeps the difference: the parent growing makes this layer
  /// grow by as many pixels (not by the same factor), and its distance
  /// from the parent isn't stretched.
  bool parentKeepDifference = false;

  /// Layers tab folder it sits in (null: none).
  String? folder;
  String mirrorAxis = 'x'; // 'x' (left-right) | 'y' (upside down) | 'both' | 'none'

  /// Timeline row: layers with the same id share one row of the timeline
  /// (they never overlap in time) - see timeline_rows.dart. Null = the
  /// layer has a row of its own.
  String? rowId;

  /// Name of the layer this one was split from (its first piece): split
  /// pieces are numbered root_2, root_3, ... instead of root_2_2.
  String? splitRoot;

  /// Loop: repeat the layer after its end (see loopedFrame) until
  /// `loopUntil` (global frame) or, when null, to the timeline end.
  bool loopEnabled;
  int? loopUntil;

  /// Selective parenting: which parts of the parent's motion this layer
  /// follows. A part switched off stays as the parent had it on this
  /// layer's first frame.
  bool inheritPosition;
  bool inheritRotation;
  bool inheritScale;

  Swing swing;

  /// Follow: lazily trails another layer (effects/motion/follow.dart).
  FollowSettings follow;

  /// Colour filters over the whole layer (Filters tab).
  LayerFilters filters;

  /// Cut by layer: live booleans against other layers, in order.
  List<CutByLayer> cuts;

  /// Dependencies: single properties taken from other layers.
  List<PropLink> links;

  /// Masks by regions (the Masks tab's Regions mode): when set and on,
  /// they decide what shows instead of the mask stack.
  MaskRegions? maskRegions;

  /// Detach-a-piece cuts (see PieceClip), all applied.
  List<PieceClip> pieceClips;

  /// "Confirm shape" history: what the layer was before each confirm (its
  /// content and the effect that was baked, as saved JSON, with a label) -
  /// so editing can pick up where it was. Newest last.
  List<Map<String, dynamic>> confirmHistory = [];

  /// Edge matte (Masks tab): the soft, half-transparent edges (a feathered
  /// mask, a keyed-out background) are tinted toward `edgeMatteColor` by
  /// `edgeMatteStrength`, so they sit cleanly on a background of that
  /// colour (black or white) instead of showing a fringe.
  bool edgeMatte;
  String edgeMatteColor;
  double edgeMatteStrength;

  /// Gradient fill of a vector shape (see ShapeFill).
  ShapeFill fill;

  /// Timeline link: layers with the same id move together in time (see
  /// time_links.dart). Null = not linked.
  String? linkId;

  Layer({
    required this.id,
    required this.name,
    this.parentId,
    this.startFrame = 0,
    this.durationFrames = 180,
    required this.transform,
    required this.content,
    List<Mask>? masks,
    List<EffectInstance>? effectStack,
    this.color,
    this.renderMode = 'fill',
    this.hidden = false,
    MotionBlur? motionBlur,
    Wiggle? wiggle,
    Pendulum? pendulum,
    TimeQuantize? timeQuantize,
    ChromaKey? chromaKey,
    this.groupedChildren,
    this.precompose,
    this.preGroupParentId,
    List<double>? crop,
    this.cropAspect = 'free',
    this.mirrorX = false,
    this.mirrorY = false,
    this.foldsIgnoreScale = true,
    List<String>? effectPanelOrder,
    this.rowId,
    this.splitRoot,
    this.loopEnabled = false,
    this.loopUntil,
    this.inheritPosition = true,
    this.inheritRotation = true,
    this.inheritScale = true,
    Swing? swing,
    PhysicsSettings? physics,
    List<PieceClip>? pieceClips,
    this.edgeMatte = false,
    this.edgeMatteColor = '#000000',
    this.edgeMatteStrength = 1,
    ShapeFill? fill,
    this.linkId,
    FollowSettings? follow,
    LayerFilters? filters,
    List<CutByLayer>? cuts,
    List<PropLink>? links,
    this.maskRegions,
  })  : follow = follow ?? FollowSettings(),
        cuts = cuts ?? [],
        links = links ?? [],
        filters = filters ?? LayerFilters(),
        swing = swing ?? Swing(),
        physics = physics ?? PhysicsSettings(),
        fill = fill ?? ShapeFill(),
        pieceClips = pieceClips ?? [],
        crop = crop ?? [0.0, 0.0, 0.0, 0.0],
        effectPanelOrder = effectPanelOrder ?? [],
        masks = masks ?? [],
        effectStack = effectStack ?? [],
        motionBlur = motionBlur ?? MotionBlur(),
        wiggle = wiggle ?? Wiggle(),
        pendulum = pendulum ?? Pendulum(),
        timeQuantize = timeQuantize ?? TimeQuantize(),
        chromaKey = chromaKey ?? ChromaKey();
}

class Project {
  int fps;
  List<Layer> layers;

  /// Collide: the frame's edges are walls for every colliding object.
  bool stageWalls;
  Project({this.fps = 60, List<Layer>? layers, this.stageWalls = false}) : layers = layers ?? [];
}

Transform _defaultTransform(List<double> anchorDefault,
        {bool anchorSpatial = true}) =>
    Transform(
      anchor: track(anchorDefault, anchorSpatial),
      scale: track([1.0, 1.0]),
      rotation: track(0.0),
      opacity: track(1.0),
    );

Project createDefaultProject() {
  final parent = Layer(
    id: 'L_parent',
    name: 'controller',
    parentId: null,
    transform: _defaultTransform([0.5, 0.55]),
    content: Content(
        shape: 'rect',
        offset: [0, 0],
        size: [0, 0]), // pure rig controller, draws nothing
  );
  final child = Layer(
    id: 'L_child',
    name: 'object_a',
    parentId: 'L_parent',
    transform: _defaultTransform([0.0, 0.0]),
    content: Content(
        shape: 'rect',
        offset: [0, 0],
        size: [46, 46]), // geometry sits centered on the anchor by default
    color: '#d8d8d8',
  );
  return Project(layers: [parent, child]);
}

/// deep-copy helpers - the Dart equivalent of the JS `JSON.parse(JSON.
/// stringify(v))` round-trip movement-core uses for both undo snapshots
/// and copyLayerParams (this data has no functions or circular
/// references, so a field-by-field copy is exactly equivalent, just
/// type-safe and without an actual JSON detour).
dynamic cloneValue(dynamic v) => v is List<double> ? [...v] : v;

Track cloneTrack(Track src) {
  final t = Track(cloneValue(src.defaultValue), src.spatial);
  t.loop = src.loop;
  t.tension = src.tension;
  t.globalEasing = src.globalEasing?.copy();
  t.constantSpeed = src.constantSpeed;
  t.animLayers = [
    for (final a in src.animLayers) AnimLayer(track: cloneTrack(a.track), multiply: a.multiply, enabled: a.enabled)
  ];
  t.expression = src.expression;
  t.keyframes = [
    for (final k in src.keyframes)
      Keyframe(
          frame: k.frame,
          value: cloneValue(k.value),
          temporal: k.temporal.copy(),
          spatialTangent: k.spatialTangent.copy()),
  ];
  return t;
}

Layer cloneLayer(Layer src) {
  return Layer(
    id: src.id,
    name: src.name,
    parentId: src.parentId,
    rowId: src.rowId,
    splitRoot: src.splitRoot,
    loopEnabled: src.loopEnabled,
    loopUntil: src.loopUntil,
    inheritPosition: src.inheritPosition,
    inheritRotation: src.inheritRotation,
    inheritScale: src.inheritScale,
    swing: src.swing.copy(),
    filters: src.filters.copy(),
    cuts: [for (final c in src.cuts) c.copy()],
    links: [for (final k in src.links) k.copy()],
    maskRegions: src.maskRegions?.copy(),
    follow: src.follow.copy(),
    pieceClips: [for (final c in src.pieceClips) c.copy()],
    edgeMatte: src.edgeMatte,
    edgeMatteColor: src.edgeMatteColor,
    edgeMatteStrength: src.edgeMatteStrength,
    fill: src.fill.copy(),
    linkId: src.linkId,
    startFrame: src.startFrame,
    durationFrames: src.durationFrames,
    transform: Transform(
      anchor: cloneTrack(src.transform.anchor),
      scale: cloneTrack(src.transform.scale),
      rotation: cloneTrack(src.transform.rotation),
      opacity: cloneTrack(src.transform.opacity),
      pathFollow: PathFollow(
        enabled: src.transform.pathFollow.enabled,
        sourceLayerId: src.transform.pathFollow.sourceLayerId,
        t: cloneTrack(src.transform.pathFollow.t),
        parametrization: src.transform.pathFollow.parametrization,
      ),
    ),
    content: Content(
      shape: src.content.shape,
      offset: [...src.content.offset],
      size: [...src.content.size],
      sides: src.content.sides,
      points: src.content.points?.map((p) => [...p]).toList(),
      imageSourceType: src.content.imageSourceType,
      imageData: src.content.imageData,
      imagePath: src.content.imagePath,
      imageNaturalWidth: src.content.imageNaturalWidth,
      imageNaturalHeight: src.content.imageNaturalHeight,
      text: src.content.text?.copy(),
      videoPath: src.content.videoPath,
      videoAssetId: src.content.videoAssetId,
      sourceIn: src.content.sourceIn,
      videoFps: src.content.videoFps,
      videoFrameCount: src.content.videoFrameCount,
      videoAlpha: src.content.videoAlpha,
      audioPath: src.content.audioPath,
      audioAssetId: src.content.audioAssetId,
      audioDuration: src.content.audioDuration,
      volume: src.content.volume == null ? null : cloneTrack(src.content.volume!),
      audioMuted: src.content.audioMuted,
      contours: src.content.contours?.map((c) => c.map((p) => [...p]).toList()).toList(),
    )
      ..lineNodes = src.content.lineNodes?.map((n) => n.copy()).toList()
      ..lineWidth = src.content.lineWidth
      ..lineClosed = src.content.lineClosed
      ..lineFilled = src.content.lineFilled
      ..lineHidden = src.content.lineHidden
      ..lineLocked = src.content.lineLocked
      ..lineShowBox = src.content.lineShowBox
      ..gridCols = src.content.gridCols
      ..gridRows = src.content.gridRows
      ..lineFillMode = src.content.lineFillMode
      ..lineCap = src.content.lineCap
      ..lineCapRound = src.content.lineCapRound
      ..lineCapLength = src.content.lineCapLength
      ..lineCapShape = src.content.lineCapShape
      ..lineJoin = src.content.lineJoin
      ..lineMiterLimit = src.content.lineMiterLimit
      ..lineMirrorLength = src.content.lineMirrorLength
      ..lineTrimStart = src.content.lineTrimStart == null ? null : cloneTrack(src.content.lineTrimStart!)
      ..lineTrimEnd = src.content.lineTrimEnd == null ? null : cloneTrack(src.content.lineTrimEnd!)
      ..mediaHash = src.content.mediaHash
      ..refProjectId = src.content.refProjectId
      ..refFit = src.content.refFit
      ..refEndBehavior = src.content.refEndBehavior
      ..refLastSeenRevision = src.content.refLastSeenRevision
      ..refEmbedded = src.content.refEmbedded
      ..textGroup = src.content.textGroup
      ..placeholder = src.content.placeholder
      ..textGroupPivot = List<double>.from(src.content.textGroupPivot),
    masks: [
      for (final m in src.masks)
        Mask(
            enabled: m.enabled,
            mode: m.mode,
            sourceLayerId: m.sourceLayerId,
            moreSources: [...m.moreSources],
            sourcePart: m.sourcePart,
            range: m.range == null ? null : [...m.range!],
            feather: cloneTrack(m.feather),
            featherOutside: m.featherOutside,
            invert: m.invert),
    ],
    effectStack: [
      for (final i in src.effectStack)
        EffectInstance(
            id: i.id,
            effectId: i.effectId,
            enabled: i.enabled,
            params: {
              for (final entry in i.params.entries)
                entry.key: entry.value is Track
                    ? cloneTrack(entry.value as Track)
                    : entry.value,
            }),
    ],
    color: src.color,
    renderMode: src.renderMode,
    hidden: src.hidden,
    motionBlur: MotionBlur(
        enabled: src.motionBlur.enabled,
        shutterAngle: src.motionBlur.shutterAngle,
        samples: src.motionBlur.samples),
    wiggle: Wiggle(
        enabled: src.wiggle.enabled,
        speed: src.wiggle.speed,
        amplitude: src.wiggle.amplitude,
        smoothness: src.wiggle.smoothness,
        wiggleSeed: src.wiggle.wiggleSeed),
    pendulum: Pendulum(
      enabled: src.pendulum.enabled,
      frequency: src.pendulum.frequency,
      damping: src.pendulum.damping,
      sensitivity: src.pendulum.sensitivity,
      pivotOffset: cloneTrack(src.pendulum.pivotOffset),
      maxAngle: src.pendulum.maxAngle,
      freeze: src.pendulum.freeze,
      rotateWithLine: src.pendulum.rotateWithLine,
      weightPoint: src.pendulum.weightPoint == null ? null : [...src.pendulum.weightPoint!],
    ),
    timeQuantize: TimeQuantize(enabled: src.timeQuantize.enabled, fps: src.timeQuantize.fps),
    physics: src.physics.copy(),
    chromaKey: src.chromaKey.copy(),
    groupedChildren:
        src.groupedChildren == null ? null : [...src.groupedChildren!],
    precompose: src.precompose,
    preGroupParentId: src.preGroupParentId,
    crop: [...src.crop],
    cropAspect: src.cropAspect,
    mirrorX: src.mirrorX,
    mirrorY: src.mirrorY,
    effectPanelOrder: [...src.effectPanelOrder],
  )
    ..confirmHistory = [for (final h in src.confirmHistory) Map<String, dynamic>.from(h)]
    ..effectRanges = {for (final e in src.effectRanges.entries) e.key: [...e.value]}
    ..content.playReversed = src.content.playReversed
    ..content.contourColors = src.content.contourColors == null ? null : [...src.content.contourColors!]
    ..content.contourJoin = src.content.contourJoin == null ? null : [...src.content.contourJoin!]
    ..parentFrom = src.parentFrom
    ..parentUntil = src.parentUntil
    ..mirrorSourceId = src.mirrorSourceId
    ..mirrorProbe = src.mirrorProbe
    ..mirrorAllLayers = src.mirrorAllLayers
    ..locked = src.locked
    ..parentKeepDifference = src.parentKeepDifference
    ..folder = src.folder
    ..mirrorAxis = src.mirrorAxis;
}

/// True when any side is cropped.
bool layerHasCrop(Layer layer) => layer.crop.any((v) => v > 0);

Layer? findLayer(Project project, String? id) {
  if (id == null) return null;
  for (final l in project.layers) {
    if (l.id == id) return l;
  }
  return null;
}

int layerCounter = 0;
const layerPalette = [
  '#d8d8d8',
  '#e0a06a',
  '#7fc4a8',
  '#e07f9a',
  '#8ab4d8',
  '#c9a8e0',
  '#e0d47f',
];

/// A new layer's name: 'Rect 1', 'Image 3' (capital, a space, no '_').
String niceLayerName(String kind, int n) =>
    '${kind.isEmpty ? kind : kind[0].toUpperCase() + kind.substring(1)} $n';

/// `size`: the shape's width/height in frame pixels (46 fits a 480px
/// frame; callers scale it to the actual resolution).
Layer createLayer(String presetShape, {double size = 46}) {
  layerCounter++;
  final layer = Layer(
    id: 'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$layerCounter',
    name: niceLayerName(presetShape, layerCounter),
    parentId: null,
    transform: _defaultTransform([0.5, 0.5]),
    content: Content(
      shape: presetShape,
      offset: [0, 0],
      size: [size, size],
      sides: presetShape == 'circle' ? 48 : 6,
    )..lineNodes = presetShape == 'line' ? straightLineNodes(size * 3) : null,

    color: presetShape == 'null'
        ? null
        : layerPalette[layerCounter % layerPalette.length],
  )..content.lineWidth = math.max(2.0, size / 12);
  syncLineBox(layer.content);
  return layer;
}

/// createLayer's sibling for imported images - sized to the source
/// image's own aspect ratio (never a distorted square default like the
/// preset shapes) capped at `maxDimension` on its longer side, so a
/// freshly-imported photo starts at a sane, on-screen size instead of
/// needing an immediate manual resize.
Layer createImageLayer({
  required String imageSourceType, // "embedded" | "file"
  String? imageData,
  String? imagePath,
  required int naturalWidth,
  required int naturalHeight,
  double maxDimension = 200,
}) {
  if (imageSourceType == 'embedded' && imageData == null) {
    throw ArgumentError(
        'imageData is required when imageSourceType is "embedded"');
  }
  if (imageSourceType == 'file' && imagePath == null) {
    throw ArgumentError('imagePath is required when imageSourceType is "file"');
  }
  layerCounter++;
  final aspect = (naturalWidth <= 0 || naturalHeight <= 0)
      ? 1.0
      : naturalWidth / naturalHeight;
  final w = aspect >= 1 ? maxDimension : maxDimension * aspect;
  final h = aspect >= 1 ? maxDimension / aspect : maxDimension;
  return Layer(
    id: 'L_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$layerCounter',
    name: niceLayerName('image', layerCounter),
    parentId: null,
    transform: _defaultTransform([0.5, 0.5]),
    content: Content(
      shape: 'image',
      offset: [0, 0],
      size: [w, h],
      imageSourceType: imageSourceType,
      imageData: imageData,
      imagePath: imagePath,
      imageNaturalWidth: naturalWidth,
      imageNaturalHeight: naturalHeight,
    ),
  );
}

/// mirrors movement-core's addKeyframe(layerId, param, frame, value, easing, group) -
/// `group` selects which track on the layer to target: null/omitted -> a
/// transform.* track, "mask:<idx>" -> that mask's track, "pathFollow" ->
/// pathFollow.t, "effect:<instId>" -> that effect instance's param.
void addKeyframe(
  Project project,
  String layerId,
  String param,
  int frame,
  dynamic value,
  String easing, [
  String? group,
]) {
  final layer = findLayer(project, layerId);
  if (layer == null) return;
  Track trk;
  if (group != null && group.startsWith('mask:')) {
    final idx = int.parse(group.substring(5));
    trk = layer
        .masks[idx].feather; // masks currently only expose `feather` as a track
  } else if (group == 'pathFollow') {
    trk = layer.transform.pathFollow.t;
  } else if (group != null && group.startsWith('effect:')) {
    final instId = group.substring(7);
    final inst = layer.effectStack.firstWhere((i) => i.id == instId);
    trk = inst.params[param] as Track;
  } else {
    trk = _transformTrack(layer.transform, param);
  }
  trk.keyframes.add(Keyframe(
    frame: frame,
    value: value,
    temporal: easingPresets[easing] ?? easingPresets['linear'],
  ));
  trk.keyframes.sort((a, b) => a.frame.compareTo(b.frame));
}

Track _transformTrack(Transform t, String param) {
  switch (param) {
    case 'anchor':
      return t.anchor;
    case 'scale':
      return t.scale;
    case 'rotation':
      return t.rotation;
    case 'opacity':
      return t.opacity;
    default:
      throw ArgumentError('unknown transform track "$param"');
  }
}
