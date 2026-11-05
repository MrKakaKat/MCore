import 'dart:convert';

import 'package:movement_core/movement_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> _file(String id, Project p, {int fps = 60, int frames = 120, int revision = 1, double w = 400, double h = 200}) => {
      'version': 1,
      'id': id,
      'revision': revision,
      'name': 'P$id',
      'project': {'layers': projectLayersToJson(p)},
      'maxFrame': frames,
      'frameWidth': w,
      'frameHeight': h,
      if (fps != 60) 'fps': fps,
    };

RefSource _src(String id, {int fps = 60, int frames = 120, Project? p}) =>
    RefSource.fromFileJson(_file(id, p ?? Project(), fps: fps, frames: frames))!;

void main() {
  group('time', () {
    test('30 fps source in a 60 fps host: hold, loop, hide', () {
      final s = _src('A', fps: 30, frames: 30); // one second
      expect(refSourceFrameAt(0, s, 60, 'hide'), 0);
      expect(refSourceFrameAt(10, s, 60, 'hide'), 5);
      expect(refSourceFrameAt(59, s, 60, 'hide'), 29);
      expect(refSourceFrameAt(60, s, 60, 'hide'), isNull);
      expect(refSourceFrameAt(60, s, 60, 'hold'), 29);
      expect(refSourceFrameAt(90, s, 60, 'hold'), 29);
      expect(refSourceFrameAt(60, s, 60, 'loop'), 0);
      expect(refSourceFrameAt(70, s, 60, 'loop'), 5);
    });

    test('60 fps source in a 24 fps host', () {
      final s = _src('A', fps: 60, frames: 120); // two seconds
      expect(refSourceFrameAt(12, s, 24, 'hide'), 30);
      expect(refSourceFrameAt(47, s, 24, 'hide'), 117);
      expect(refSourceFrameAt(48, s, 24, 'hide'), isNull);
      expect(refSourceFrameAt(48, s, 24, 'hold'), 119);
      expect(refSourceFrameAt(54, s, 24, 'loop'), 15);
    });

    test('the default length of a reference is the source duration', () {
      expect(refDefaultDuration(_src('A', fps: 30, frames: 90), 60), 180);
      expect(refDefaultDuration(_src('A', fps: 60, frames: 120), 24), 48);
      final l = createProjectRefLayer(_src('A', fps: 30, frames: 45), id: 'r', frameW: 800, frameH: 800, hostFps: 60);
      expect(l.durationFrames, 90);
      expect(l.content.size, [800, 400], reason: 'contain: 400x200 fit into 800x800');
    });
  });

  group('safety', () {
    test('cycles: direct, a 3-project chain, refused at add', () {
      final graph = {
        'A': {'B'},
        'B': {'C'},
        'C': <String>{},
      };
      expect(refWouldCycle('A', 'A', graph), isTrue, reason: 'itself');
      expect(refWouldCycle('B', 'A', graph), isTrue, reason: 'A -> B, so B may not hold A');
      expect(refWouldCycle('C', 'A', graph), isTrue, reason: 'A -> B -> C');
      expect(refWouldCycle('A', 'C', graph), isFalse);
      expect(refWouldCycle('D', 'A', graph), isFalse);
    });

    test('a cycle met at load draws a placeholder, not a recursion', () {
      final ref = Content(shape: 'projectRef', offset: [0, 0], size: [10, 10])..refProjectId = 'A';
      final sources = {'A': _src('A')};
      expect(refStatus(ref, sources, ['A', 'B']), RefStatus.cycle);
      expect(refStatus(ref, sources, ['B']), RefStatus.ok);
    });

    test('nesting is capped at 4 levels', () {
      final ref = Content(shape: 'projectRef', offset: [0, 0], size: [10, 10])..refProjectId = 'X';
      final sources = {'X': _src('X')};
      expect(refStatus(ref, sources, ['1', '2', '3', '4']), RefStatus.ok);
      expect(refStatus(ref, sources, ['1', '2', '3', '4', '5']), RefStatus.tooDeep);
    });

    test('a missing source is a placeholder; the layer keeps its transform; relink works', () {
      final l = createProjectRefLayer(_src('A'), id: 'r', frameW: 400, frameH: 200, hostFps: 60);
      l.transform.rotation.defaultValue = 0.5;
      l.transform.anchor.defaultValue = [0.3, 0.7];
      expect(refStatus(l.content, {}, const ['H']), RefStatus.missing);
      final json = projectLayersToJson(Project(layers: [l]));
      final back = projectLayersFromJson(jsonDecode(jsonEncode(json)) as List).single;
      expect(back.transform.rotation.defaultValue, 0.5);
      expect(back.transform.anchor.defaultValue, [0.3, 0.7]);
      expect(back.content.refProjectId, 'A');
      final b = RefSource.fromFileJson(_file('B', Project(), w: 100, h: 100))!;
      relinkProjectRef(back, b);
      expect(refStatus(back.content, {'B': b}, const ['H']), RefStatus.ok);
      expect(back.content.size, [400, 400], reason: 'the box keeps its longer side');
      expect(back.transform.anchor.defaultValue, [0.3, 0.7]);
    });
  });

  test('unlink: a frozen copy shows the same frames and no longer follows the source', () {
    final a = createDefaultProject();
    final src = RefSource.fromFileJson(_file('A', a))!;
    final l = createProjectRefLayer(src, id: 'r', frameW: 400, frameH: 200, hostFps: 60);
    final linked = refSourceOf(l.content, {'A': src})!;
    unlinkProjectRef(l, _file('A', a));
    // the source changes later (another revision): the copy doesn't.
    final changed = RefSource.fromFileJson(_file('A', Project(), revision: 9))!;
    final frozen = refSourceOf(l.content, {'A': changed})!;
    expect(frozen.revision, 1);
    expect(projectLayersToJson(frozen.project), projectLayersToJson(linked.project));
    for (final f in [0, 30, 77]) {
      expect(refSourceFrame(l, f, frozen, 60), refSourceFrame(l, f, linked, 60));
    }
    expect(directRefs(Project(layers: [l])), isEmpty, reason: 'nothing to load any more');
    expect(refUpdated(l.content, {'A': changed}), isFalse);
  });

  test('a pendulum inside the source is bit-identical to the source alone', () {
    Project scene() {
      final p = createDefaultProject();
      p.layers[1].pendulum.enabled = true;
      return p;
    }

    final alone = scene();
    final src = RefSource.fromFileJson(_file('A', scene(), fps: 30, frames: 90))!;
    final ref = createProjectRefLayer(src, id: 'r', frameW: 400, frameH: 200, hostFps: 60);
    // the nested render runs under the source's own stage and frame rate.
    setStageSize(src.width, src.height);
    fps = src.fps;
    addTearDown(() => fps = 60);
    for (final hostFrame in [0, 13, 64, 150]) {
      final sf = refSourceFrame(ref, hostFrame, src, 60)!;
      clearStateCaches();
      final nested = getLayerStateAt(src.project, 'L_child', sf).matrix;
      clearStateCaches();
      final own = getLayerStateAt(alone, 'L_child', sf).matrix;
      expect(nested, own, reason: 'host frame $hostFrame -> source frame $sf');
    }
  });

  test('updated badge and static detection', () {
    final s1 = _src('A');
    final l = createProjectRefLayer(s1, id: 'r', frameW: 400, frameH: 200, hostFps: 60);
    expect(refUpdated(l.content, {'A': s1}), isFalse);
    final s2 = RefSource.fromFileJson(_file('A', Project(), revision: 2))!;
    expect(refUpdated(l.content, {'A': s2}), isTrue);
    expect(projectIsStatic(Project(layers: [createDefaultProject().layers[1]])), isTrue);
    final moving = createDefaultProject();
    moving.layers[1].pendulum.enabled = true;
    expect(projectIsStatic(moving), isFalse);
  });

  test('show in context: the host frame for a source frame, clamped to the instance', () {
    final s = _src('A', fps: 30, frames: 30);
    final l = createProjectRefLayer(s, id: 'r', frameW: 400, frameH: 200, hostFps: 60, startFrame: 100);
    expect(contextHostFrame(l, 15, s, 60), (frame: 130, outside: false));
    expect(contextHostFrame(l, 200, s, 60), (frame: 160, outside: true));
  });

  test('sha256 and media lookup by hash', () {
    expect(sha256Hex(utf8.encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(sha256Hex(const []), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(sha256Hex(List.filled(1000, 97)).length, 64);
    final c = Content(shape: 'video', offset: [0, 0], size: [1, 1])..mediaHash = 'h1';
    final back = contentFromJson(jsonDecode(jsonEncode(contentToJson(c))) as Map<String, dynamic>);
    expect(back.mediaHash, 'h1');
    expect(resolveMediaPath('/a', 'h1', (p) => p == '/a', {'h1': '/b'}), '/a');
    expect(resolveMediaPath('/gone', 'h1', (p) => false, {'h1': '/b'}), '/b');
    expect(resolveMediaPath('/gone', 'h2', (p) => false, {'h1': '/b'}), isNull);
  });
}
