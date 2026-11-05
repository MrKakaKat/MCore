import 'dart:convert';
import 'dart:io';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

McjResult imp(String text) => expandMcj(extractMcjJson(text));

void main() {
  setUpAll(() {
    registerBuiltinEffects();
    registerFont(defaultFontId, File('../../assets/fonts/Roboto-Regular.ttf').readAsBytesSync());
  });
  setUp(() {
    clearStateCaches();
    clearCutCaches();
  });

  test('a minimal MCJ: a valid project with defaults', () {
    final r = imp('{"layers": [{"shape": "rect"}]}');
    expect(r.report, isEmpty);
    expect(r.width, 1080);
    expect(r.fps, 60);
    expect(r.duration, 180);
    final l = r.project.layers.single;
    expect(l.content.shape, 'rect');
    expect(l.durationFrames, 180);
  });

  test('round trip compact -> expand keeps shapes, timing, keys, eases, parenting, effect params', () {
    final src = imp(mcjRecipes.firstWhere((x) => x.title == 'Pendulum chain').json);
    expect(src.report, isEmpty);
    final mcj = compactToMcj(src.project, width: src.width, height: src.height, fps: src.fps, duration: src.duration);
    final back = expandMcj(jsonDecode(jsonEncode(mcj)) as Map<String, dynamic>);
    expect(back.report, isEmpty);
    expect(back.project.layers.map((l) => l.name), src.project.layers.map((l) => l.name));
    final bar = back.project.layers.first, bar0 = src.project.layers.first;
    expect(bar.transform.anchor.keyframes.map((k) => k.frame), bar0.transform.anchor.keyframes.map((k) => k.frame));
    expect(bar.transform.anchor.keyframes[1].temporal.x1, bar0.transform.anchor.keyframes[1].temporal.x1);
    final arm2 = back.project.layers.last;
    expect(findLayer(back.project, arm2.parentId)!.name, 'arm1');
    expect(arm2.pendulum.enabled, isTrue);
    expect(arm2.pendulum.maxAngle, 50);
    // a registered effect with keys, and a cut, survive too.
    final d = imp(mcjRecipes.firstWhere((x) => x.title == 'Notched diamond').json);
    final m2 = compactToMcj(d.project, width: 1080, height: 1080, duration: d.duration);
    final d2 = expandMcj(jsonDecode(jsonEncode(m2)) as Map<String, dynamic>);
    expect(d2.report, isEmpty);
    final big = d2.project.layers.last;
    expect(big.cuts.single.gap.defaultValue, 20.0);
    expect(findLayer(d2.project, big.cuts.single.cutterId)!.name, 'small');
    expect(big.effectStack.single.effectId, 'outline');
  });

  test('media become placeholders by design', () {
    final p = Project(layers: [createImageLayer(imageSourceType: 'file', imagePath: 'x.png', naturalWidth: 100, naturalHeight: 50)..name = 'logo']);
    final m = compactToMcj(p, width: 500, height: 500, duration: 60);
    expect((m['layers'] as List).single['shape'], 'placeholder');
    final back = expandMcj(m);
    expect(back.project.layers.single.content.placeholder, isTrue);
    expect(back.project.layers.single.name, 'logo');
  });

  group('bad AI replies: each gives its report, none throws', () {
    test('fenced, with prose before and after', () {
      final r = imp('Sure! Here it is:\n```json\n{"layers": [{"shape": "circle"}]}\n```\nEnjoy.');
      expect(r.project.layers.single.content.shape, 'circle');
    });
    test('truncated', () {
      expect(() => imp('{"layers": [{"shape": "circle", "size": [1'),
          throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('cut off'))));
    });
    test('trailing commas and // comments', () {
      final r = imp('{"layers": [{"shape": "rect", // a box\n "size": [10, 10],},],}');
      expect(r.report, isEmpty);
      expect(r.project.layers.single.content.size, [10.0, 10.0]);
    });
    test('unknown effect, out-of-range value, frame past duration', () {
      final r = imp('{"canvas": {"duration": 60}, "layers": [{"shape": "rect", "opacity": 3,'
          ' "rotation": [[0, 0], [400, 90]], "effects": [{"type": "glow"}]}]}');
      expect(r.report.join('\n'), allOf(contains('"glow" unknown'), contains('opacity'), contains('frame 400')));
      expect(r.project.layers.single.transform.opacity.defaultValue, 1.0);
      expect(r.project.layers.single.transform.rotation.keyframes.last.frame, 60);
    });
    test('parent cycle broken', () {
      final r = imp('{"layers": [{"name": "a", "shape": "rect", "parent": "b"}, {"name": "b", "shape": "rect", "parent": "a"}]}');
      expect(r.report.join('\n'), contains('circle'));
      expect(r.project.layers.where((l) => l.parentId != null), hasLength(1));
    });
    test('an expression is ignored', () {
      final r = imp('{"layers": [{"shape": "rect", "expression": "while(true){}"}]}');
      expect(r.report.single, contains('expressions are not allowed'));
    });
    test('not JSON at all', () {
      expect(() => imp('I can\'t do that.'), throwsA(isA<FormatException>()));
    });
  });

  test('every recipe imports with no report and evaluates its first and last frame', () {
    for (final r in mcjRecipes) {
      final res = imp(r.json);
      expect(res.report, isEmpty, reason: r.title);
      for (final f in [0, res.duration]) {
        clearStateCaches();
        for (final l in res.project.layers) {
          expect(() => getLayerStateAt(res.project, l.id, f), returnsNormally, reason: '${r.title} ${l.name} @$f');
          layerVectorRings(res.project, l, f);
        }
      }
    }
  });

  group('agent guide', () {
    test('lists every effect type, every parameter and every shape; nothing that no longer exists', () {
      final g = buildAgentGuide();
      for (final e in mcjEffects()) {
        expect(g, contains('`${e.type}`'), reason: e.type);
        for (final p in e.params) {
          expect(g, contains('`${p.name}`'), reason: '${e.type}.${p.name}');
        }
      }
      for (final id in effectRegistry.keys) {
        expect(g, contains('`$id`'));
      }
      for (final s in mcjShapes) {
        expect(g, contains(s));
      }
      // every effect type the guide documents is one the importer knows.
      final known = {for (final e in mcjEffects()) e.type};
      for (final m in RegExp(r'"type": "(\w+)"').allMatches(g)) {
        expect(known, contains(m.group(1)));
      }
    });

    test('compact stays within 1,500 words', () {
      final words = buildAgentGuide(level: GuideLevel.compact).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      expect(words, lessThanOrEqualTo(1500), reason: '$words words');
    });

    test('the skeleton and the format version match', () {
      final g = buildAgentGuide();
      expect(g, contains('"mcore": $mcjVersion'));
      final skeleton = RegExp(r'## Skeleton\n```json\n([\s\S]*?)```').firstMatch(g)!.group(1)!;
      expect(imp(skeleton).report, isEmpty);
    });

    test('no paths, packages or class names leak', () {
      for (final level in GuideLevel.values) {
        final g = buildAgentGuide(level: level);
        for (final bad in ['lib/', 'package:', '.dart', 'CutByLayer', 'FollowSettings', 'EffectInstance', 'Track(', 'Layer(']) {
          expect(g.contains(bad), isFalse, reason: '$bad in $level');
        }
      }
    });

    test('the prompt carries the request, and for an edit the current project', () {
      final p = buildAiPrompt('a red ball bouncing', current: {'mcore': 1, 'layers': []});
      expect(p, contains('a red ball bouncing'));
      expect(p, contains('The current project'));
      for (final e in mcjEffects()) {
        expect(p, contains('`${e.type}`'));
      }
    });
  });

  test('masks: imported in order with their mode, invert and hidden source; exported back', () {
    final r = expandMcj(extractMcjJson('''
{"mcore": 1, "canvas": {"width": 1080, "height": 1080, "fps": 60, "duration": 60},
 "layers": [
  {"name": "a", "shape": "circle", "size": [300, 300]},
  {"name": "b", "shape": "rect", "size": [200, 200]},
  {"name": "t", "shape": "rect", "size": [600, 600], "effects": [
    {"type": "mask", "source": "a"},
    {"type": "mask", "source": "b", "mode": "equivalence", "invert": true, "hideSource": false}]}
 ]}'''));
    final t = r.project.layers.last;
    expect(t.masks.map((m) => m.mode), ['add', 'equivalence']);
    expect(t.masks[1].invert, isTrue);
    expect(r.project.layers[0].hidden, isTrue);
    expect(r.project.layers[1].hidden, isFalse);
    final back = compactToMcj(r.project, width: 1080, height: 1080, fps: 60, duration: 60);
    final fx = ((back['layers'] as List).last as Map)['effects'] as List;
    expect(fx.where((e) => e['type'] == 'mask').length, 2);
  });
}
